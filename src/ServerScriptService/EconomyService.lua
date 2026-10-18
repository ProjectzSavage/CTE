--[[
	EconomyService (ServerScriptService.EconomyService)
	===================================================
	Awards the meta currency once per completed match.

	Clout (soft currency), per real player in the final standings:
	  participation + hold seconds + knockdowns + steals
	  + round wins + MVP bonus                       (all Config.Economy)

	Egg Fragments, ranked by TOTAL match hold time:
	  rank 1..6 -> Config.Economy.FragmentsByRank (top 3 earn more,
	  ranks 4-6 still earn some -- never zero).

	Pity: every match WITHOUT a round win bumps MatchesSinceRoundWin;
	after Config.Economy.PityMatchesWithoutRoundWin (10) winless matches
	the player's NEXT round win instantly grants a GUARANTEED-RARE egg
	and resets the counter (tracked in data, survives rejoins).

	Knockdown/steal counting listens to the server-side ServerFeedback
	BindableEvent (Main creates it; CombatService/EggService mirror every
	FeedbackEvent into it) -- so no gameplay module has to know the economy
	exists. Bots earn nothing (they have no profiles).

	Fired: MatchRewards (per client) with the full breakdown; lifetime
	hold time / MatchesPlayed / RoundWins / MVPs update in data.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local DataService = require(ServerScriptService:WaitForChild("DataService"))
local HatcheryService = require(ServerScriptService:WaitForChild("HatcheryService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local MatchRewards = Remotes:WaitForChild("MatchRewards")

local EconomyService = {}

local matchStats = {}   -- { [Player] = { Knockdowns = n, Steals = n } }
local serverFeedback = nil
local initialized = false

local function getStats(player)
	local stats = matchStats[player]
	if not stats then
		stats = { Knockdowns = 0, Steals = 0 }
		matchStats[player] = stats
	end
	return stats
end

-- Called by MatchService (injected by Main) at the start of every match.
function EconomyService.ResetMatchStats()
	matchStats = {}
	for _, player in ipairs(Players:GetPlayers()) do
		matchStats[player] = { Knockdowns = 0, Steals = 0 }
	end
end

---------------------------------------------------------------------------
-- Match settlement
---------------------------------------------------------------------------

local function awardPlayer(player, entry, rank)
	local profile = DataService.GetProfile(player)
	if not profile then
		return -- data never loaded: skip silently (they keep playing)
	end
	local stats = getStats(player)

	-- 1) Clout breakdown.
	local knockdowns = math.min(stats.Knockdowns, Config.Economy.MaxKnockdownsCredited)
	local steals = math.min(stats.Steals, Config.Economy.MaxStealsCredited)
	local holdSeconds = math.floor(entry.TotalHoldTime or 0)

	local clout = Config.Economy.CloutParticipation
		+ holdSeconds * Config.Economy.CloutPerHoldSecond
		+ knockdowns * Config.Economy.CloutPerKnockdown
		+ steals * Config.Economy.CloutPerSteal
		+ (entry.RoundsWon or 0) * Config.Economy.CloutPerRoundWin
		+ (entry.IsMVP and Config.Economy.CloutMVPBonus or 0)

	-- 2) Fragments by final rank (never zero).
	local fragments = Config.Economy.FragmentsByRank[rank]
		or Config.Economy.FragmentsByRank[#Config.Economy.FragmentsByRank]

	-- 3) Pity: winless-match counter, guaranteed-rare egg on the next win.
	local roundsWon = entry.RoundsWon or 0
	local pityEgg = false
	if roundsWon > 0 then
		if (profile.MatchesSinceRoundWin or 0) >= Config.Economy.PityMatchesWithoutRoundWin then
			pityEgg = true
		end
		DataService.Set(player, "MatchesSinceRoundWin", 0)
	else
		DataService.Set(player, "MatchesSinceRoundWin",
			(profile.MatchesSinceRoundWin or 0) + 1)
	end

	-- 4) Apply.
	local newClout = DataService.AddClout(player, clout)
	local newFragments = DataService.AddFragments(player, fragments)
	DataService.AddLifetimeHold(player, entry.TotalHoldTime or 0)
	DataService.Set(player, "MatchesPlayed", (profile.MatchesPlayed or 0) + 1)
	DataService.Set(player, "RoundWins", (profile.RoundWins or 0) + roundsWon)
	if entry.IsMVP then
		DataService.Set(player, "MVPs", (profile.MVPs or 0) + 1)
	end
	local grantedEgg = nil
	if pityEgg then
		grantedEgg = HatcheryService.GrantEgg(player, "Pity", true)
	end

	-- 5) Tell the client (GUI toast + panel refresh).
	MatchRewards:FireClient(player, {
		Rank = rank,
		Clout = clout,
		Fragments = fragments,
		NewClout = math.floor(newClout or 0),
		NewFragments = math.floor(newFragments or 0),
		Knockdowns = knockdowns,
		Steals = steals,
		HoldSeconds = holdSeconds,
		RoundsWon = roundsWon,
		IsMVP = entry.IsMVP and true or false,
		PityEgg = pityEgg,
		EggGranted = grantedEgg ~= nil,
		PityProgress = {
			SinceRoundWin = DataService.Get(player, "MatchesSinceRoundWin", 0),
			Needed = Config.Economy.PityMatchesWithoutRoundWin,
		},
	})

	if Config.DebugVerboseLogging then
		print(("[Economy] %s: rank %d -> +%d Clout (total %d), +%d Frags (total %d)%s"):format(
			player.Name, rank, clout, math.floor(newClout or 0),
			fragments, math.floor(newFragments or 0),
			pityEgg and "  [PITY: guaranteed-rare egg granted!]" or ""))
	end
end

-- Called by MatchService (injected by Main) right after MatchEnded fires.
function EconomyService.SettleMatch(final)
	if type(final) ~= "table" or type(final.Standings) ~= "table" then
		return
	end
	for rank, entry in ipairs(final.Standings) do
		local player = entry.Player
		if player and player:IsA("Player") and player.Parent and not entry.Left then
			awardPlayer(player, entry, rank)
		end
		-- Bots and leavers earn nothing.
	end
	-- Hatchery snapshots refresh so egg/pity changes show immediately.
	for _, player in ipairs(Players:GetPlayers()) do
		HatcheryService.SendSnapshot(player)
	end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function EconomyService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Mirror of every FeedbackEvent, server-side (Main creates the bindable).
	serverFeedback = ServerScriptService:FindFirstChild("ServerFeedback")
	if serverFeedback and serverFeedback:IsA("BindableEvent") then
		serverFeedback.Event:Connect(function(kind, data)
			if type(data) ~= "table" then
				return
			end
			if kind == "PunchHit" and data.Result == "Hit" and data.Attacker then
				local attacker = data.Attacker
				if attacker:IsA("Player") then
					getStats(attacker).Knockdowns = getStats(attacker).Knockdowns + 1
				end
			elseif kind == "EggStolen" and data.Attacker then
				local attacker = data.Attacker
				if attacker:IsA("Player") then
					getStats(attacker).Steals = getStats(attacker).Steals + 1
				end
			elseif kind == "DashFumble" and data.Player then
				-- Dash-fumbling the carrier counts as a steal for the dasher.
				local dasher = data.Player
				if dasher:IsA("Player") then
					getStats(dasher).Steals = getStats(dasher).Steals + 1
				end
			end
		end)
	else
		warn("[EconomyService] ServerScriptService.ServerFeedback missing -- knockdown/steal stats disabled")
	end

	Players.PlayerRemoving:Connect(function(player)
		matchStats[player] = nil
	end)

	print("[EconomyService] Initialized: match rewards (Clout + fragments + pity) live")
end

function EconomyService.DebugState()
	local parts = {}
	for player, stats in pairs(matchStats) do
		if player.Parent then
			table.insert(parts, ("%s[kd=%d steals=%d]"):format(
				player.Name, stats.Knockdowns, stats.Steals))
		end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "(no stats yet)"
end

return EconomyService
