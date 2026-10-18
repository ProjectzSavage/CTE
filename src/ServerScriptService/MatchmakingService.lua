--[[
	MatchmakingService (ServerScriptService.MatchmakingService)
	===========================================================
	Simple in-server ELO queue. The server gathers up to
	Config.MaxPlayers (6) players for the next match and prefers similar
	skill:

	  * Each waiting player has an ELO from DataService
	    (Config.Matchmaking.DefaultElo for fresh profiles).
	  * The queue SEED is the longest-waiting player. Everyone within
	    BaseRange + WidenPerSecond * secondsWaited (capped at MaxRange) of
	    the seed's ELO is eligible.
	  * Once 6 are eligible (or the seed has waited MaxWaitSeconds, or the
	    caller forces readiness -- bots fill the rest either way) the 6
	    closest-to-seed players are selected; the others wait for the next
	    match. With <= 6 players in the server (the normal case) everyone is
	    always selected and BotService tops the match up to 6.

	  * After each match, SettleMatch(final) applies EloByRank deltas to the
	    real players (bots excluded) and saves via DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local DataService = require(ServerScriptService:WaitForChild("DataService"))

local MatchmakingService = {}

local queueJoinedAt = {} -- { [Player] = os.clock() } arrival order for seeds
local initialized = false

local function now()
	return os.clock()
end

local function getElo(player)
	return DataService.GetElo(player) or Config.Matchmaking.DefaultElo
end

local function joinedAt(player)
	local time = queueJoinedAt[player]
	if not time then
		time = now()
		queueJoinedAt[player] = time
	end
	return time
end

--[[
	MatchmakingService.SelectParticipants(candidates, forceReady)
	  candidates : array of Players waiting in the lobby
	  forceReady : true = the lobby grace has elapsed, pick NOW even if the
	               skill window has not gathered 6 yet
	Returns an array of up to Config.MaxPlayers Players (possibly everyone),
]]
function MatchmakingService.SelectParticipants(candidates, forceReady)
	if #candidates <= Config.MaxPlayers then
		return candidates -- normal case: everybody plays, bots fill the rest
	end

	-- Seed = longest waiting player.
	local seed = candidates[1]
	for _, player in ipairs(candidates) do
		if joinedAt(player) < joinedAt(seed) then
			seed = player
		end
	end
	local seedElo = getElo(seed)
	local waited = now() - joinedAt(seed)

	-- Widen the acceptable ELO window the longer the queue waits.
	local range = math.min(
		Config.Matchmaking.MaxRange,
		Config.Matchmaking.BaseRange + Config.Matchmaking.WidenPerSecond * waited)

	local eligible = {}
	for _, player in ipairs(candidates) do
		if player == seed or math.abs(getElo(player) - seedElo) <= range then
			table.insert(eligible, player)
		end
	end

	if #eligible < Config.MaxPlayers and not forceReady
		and waited < Config.Matchmaking.MaxWaitSeconds then
		return nil -- keep queueing: window still widening
	end

	-- Take the seed + the closest ELOs (ties -> whoever arrived first).
	table.sort(eligible, function(a, b)
		local da, db = math.abs(getElo(a) - seedElo), math.abs(getElo(b) - seedElo)
		if da ~= db then
			return da < db
		end
		return joinedAt(a) < joinedAt(b)
	end)
	-- Keep the seed first regardless (it sorts to distance 0 anyway).
	local selected = {}
	for index = 1, math.min(Config.MaxPlayers, #eligible) do
		table.insert(selected, eligible[index])
	end
	return selected
end

-- Applies ELO deltas from the final standings (bots/ghosts excluded).
function MatchmakingService.SettleMatch(final)
	if type(final) ~= "table" or type(final.Standings) ~= "table" then
		return
	end
	for rank, entry in ipairs(final.Standings) do
		local player = entry.Player
		if player and player:IsA("Player") and player.Parent and not entry.Left then
			local delta = Config.Matchmaking.EloByRank[rank] or 0
			local old = getElo(player)
			DataService.SetElo(player, old + delta)
			if Config.DebugVerboseLogging then
				print(("[Matchmaking] %s: ELO %d -> %d (rank %d, %+d)")
					:format(player.Name, old, DataService.GetElo(player), rank, delta))
			end
		end
	end
end

function MatchmakingService.Init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerAdded:Connect(function(player)
		queueJoinedAt[player] = now()
	end)
	Players.PlayerRemoving:Connect(function(player)
		queueJoinedAt[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		queueJoinedAt[player] = now()
	end

	print("[MatchmakingService] Initialized: ELO queue live (default "
		.. Config.Matchmaking.DefaultElo .. ", widening window)")
end

function MatchmakingService.GetQueueInfo()
	local parts = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(parts, ("%s[%d]"):format(player.Name, getElo(player)))
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "(queue empty)"
end

function MatchmakingService.DebugState()
	return "queue: " .. MatchmakingService.GetQueueInfo()
end

return MatchmakingService
