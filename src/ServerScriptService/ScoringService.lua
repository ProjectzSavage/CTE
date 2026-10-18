--[[
	ScoringService (ServerScriptService.ScoringService)
	===================================================
	Hold-time bookkeeping: per-round accumulation, round winners, match
	totals, rounds won, and MVP computation. Driven by MatchService:

	  StartRound()        -- zero the round clock and begin accumulating
	  EndRound()          -- stop accumulating, settle the final partial tick,
	                         merge round times into match totals, award the
	                         round win(s), return ranked results
	  GetFinalStandings() -- MatchEnded payload (standings + MVPs)
	  ResetMatch()        -- clear everything between matches

	Accumulation: a 10 Hz ticker adds dt to the CURRENT carrier's round time
	(read from EggService.GetCarrier()). While the egg is loose, respawning,
	or nobody carries it, accumulation pauses automatically. EndRound settles
	the remaining partial tick first, so a player carrying at the EXACT moment
	the round expires keeps that time.

	Rules implemented:
	  * Round winner = most hold time this round (exact ties share the win and
	    each get a round win; all-zero round = no winner).
	  * MVP = highest TOTAL hold time across all rounds, chosen among players
	    still in the server at match end (ties share MVP).

	Leavers: when a player leaves mid-match their match totals migrate to a
	"ghost" record (name + userId) so final standings stay complete. The
	partial round they were in is forfeited (not merged into totals).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
-- One-directional dependency: Scoring reads possession from EggService.
local EggService = require(ServerScriptService:WaitForChild("EggService"))
-- Participants = real Players + bot Models (bots can win rounds and MVP,
-- they just earn no currency -- EconomyService pays Players only).
local BotRegistry = require(ServerScriptService:WaitForChild("BotRegistry"))

local ScoringService = {}

local SCORING_TICK = 0.1 -- 10 Hz accumulation

local roundTimes = {}  -- { [Player] = seconds } current round only
local matchTimes = {}  -- { [Player] = seconds } summed across finished rounds
local roundsWon = {}   -- { [Player] = int }
local ghosts = {}      -- { [UserId] = {Name, UserId, MatchTime, RoundsWon} } leavers
local roundActive = false
local lastAccumTime = 0
local initialized = false

local EPSILON = 0.005 -- float tie tolerance (times are accumulated in dt steps)

local function now()
	return os.clock()
end

-- Add elapsed time to the current carrier's round total (pauses implicitly
-- whenever there is no carrier: loose egg, respawning, between rounds).
local function accumulate(dt)
	if dt <= 0 then
		return
	end
	local carrier = EggService.GetCarrier()
	if carrier and carrier.Parent then
		roundTimes[carrier] = (roundTimes[carrier] or 0) + dt
	end
end

local function settle()
	local currentTime = now()
	local dt = currentTime - lastAccumTime
	lastAccumTime = currentTime
	if dt > SCORING_TICK * 3 then
		dt = SCORING_TICK * 3 -- clamp: hitches must not award bonus time
	end
	accumulate(dt)
end

local function startTicker()
	task.spawn(function()
		while initialized do
			if roundActive then
				settle()
			end
			task.wait(SCORING_TICK)
		end
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ScoringService.Init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerRemoving:Connect(function(player)
		-- Preserve what they earned; forfeit the in-progress round partial.
		local total = matchTimes[player]
		local won = roundsWon[player]
		if (total and total > 0) or (won and won > 0) then
			ghosts[player.UserId] = {
				Name = player.Name,
				UserId = player.UserId,
				MatchTime = total or 0,
				RoundsWon = won or 0,
			}
		end
		roundTimes[player] = nil
		matchTimes[player] = nil
		roundsWon[player] = nil
	end)

	startTicker()
	print("[ScoringService] Initialized: hold-time bookkeeping live")
end

function ScoringService.StartRound()
	roundTimes = {}
	roundActive = true
	lastAccumTime = now()
end

--[[
	Ends the round and returns:
	{
	  WinnerPlayer : Player?      (nil when nobody scored; first of a tie)
	  WinnerName   : string?
	  Tied         : boolean      (multiple players shared the win)
	  TopTime      : number       (winning round time)
	  Entries      : { {Player, Name, UserId, RoundTime, MatchTime,
	                    RoundsWon, IsWinner?} }  sorted by RoundTime desc
	}
	Round wins are awarded (and merged match totals updated) by this call.
]]
function ScoringService.EndRound()
	if roundActive then
		settle() -- the carrier at the exact expiry keeps their partial time
	end
	roundActive = false

	-- Merge round times into match totals.
	for player, time in pairs(roundTimes) do
		matchTimes[player] = (matchTimes[player] or 0) + time
	end

	-- Ranked entries for everyone in the match (players + bots).
	local entries = {}
	for _, entity in ipairs(BotRegistry.GetParticipants()) do
		table.insert(entries, {
			Player = entity,
			Name = entity.Name,
			UserId = BotRegistry.GetUserId(entity),
			RoundTime = roundTimes[entity] or 0,
			MatchTime = matchTimes[entity] or 0,
			RoundsWon = roundsWon[entity] or 0,
		})
	end
	table.sort(entries, function(a, b)
		if math.abs(a.RoundTime - b.RoundTime) > EPSILON then
			return a.RoundTime > b.RoundTime
		end
		return a.Name < b.Name -- stable, deterministic order for ties
	end)

	-- Winner(s): everyone tied at the top time, provided anyone scored.
	local topTime = entries[1] and entries[1].RoundTime or 0
	local winners = {}
	if topTime > EPSILON then
		for _, entry in ipairs(entries) do
			if entry.RoundTime >= topTime - EPSILON then
				entry.IsWinner = true
				roundsWon[entry.Player] = (roundsWon[entry.Player] or 0) + 1
				entry.RoundsWon = roundsWon[entry.Player]
				table.insert(winners, entry)
			end
		end
	end

	return {
		WinnerPlayer = winners[1] and winners[1].Player or nil,
		WinnerName = winners[1] and winners[1].Name or nil,
		Tied = #winners > 1,
		TopTime = topTime,
		Entries = entries,
	}
end

--[[
	Final standings for MatchEnded:
	{
	  Standings : { {Player?, Name, UserId, TotalHoldTime, RoundsWon,
	                 Left, IsMVP?} } sorted by TotalHoldTime desc
	  MVPs      : subset of Standings (present players only, ties included)
	  MVPNames  : { string }
	  BestTotalHoldTime : number
	}
]]
function ScoringService.GetFinalStandings()
	local standings = {}
	for _, entity in ipairs(BotRegistry.GetParticipants()) do
		table.insert(standings, {
			Player = entity,
			Name = entity.Name,
			UserId = BotRegistry.GetUserId(entity),
			TotalHoldTime = matchTimes[entity] or 0,
			RoundsWon = roundsWon[entity] or 0,
			Left = false,
		})
	end
	for _, ghost in pairs(ghosts) do
		table.insert(standings, {
			Player = nil, -- left the server: name/userId only (remote-safe)
			Name = ghost.Name,
			UserId = ghost.UserId,
			TotalHoldTime = ghost.MatchTime,
			RoundsWon = ghost.RoundsWon,
			Left = true,
		})
	end
	table.sort(standings, function(a, b)
		if math.abs(a.TotalHoldTime - b.TotalHoldTime) > EPSILON then
			return a.TotalHoldTime > b.TotalHoldTime
		end
		return a.Name < b.Name
	end)

	-- MVP among players still present (ties share the title).
	local best = 0
	local mvps = {}
	for _, entry in ipairs(standings) do
		if not entry.Left then
			if entry.TotalHoldTime > best + EPSILON then
				best = entry.TotalHoldTime
				mvps = { entry }
			elseif best > EPSILON and entry.TotalHoldTime >= best - EPSILON then
				table.insert(mvps, entry)
			end
		end
	end
	local mvpNames = {}
	for _, entry in ipairs(mvps) do
		entry.IsMVP = true
		table.insert(mvpNames, entry.Name)
	end

	return {
		Standings = standings,
		MVPs = mvps,
		MVPNames = mvpNames,
		BestTotalHoldTime = best,
	}
end

function ScoringService.ResetMatch()
	roundTimes = {}
	matchTimes = {}
	roundsWon = {}
	ghosts = {}
	roundActive = false
end

function ScoringService.GetRoundTime(player)
	return roundTimes[player] or 0
end

function ScoringService.GetMatchTime(player)
	return matchTimes[player] or 0
end

function ScoringService.GetRoundsWon(player)
	return roundsWon[player] or 0
end

function ScoringService.DebugState()
	local parts = {}
	for player, time in pairs(matchTimes) do
		if player.Parent then
			table.insert(parts, ("%s[round=%.1f match=%.1f won=%d]"):format(
				player.Name, roundTimes[player] or 0, time, roundsWon[player] or 0))
		end
	end
	table.sort(parts)
	return "roundActive=" .. tostring(roundActive)
		.. " | " .. (#parts > 0 and table.concat(parts, ", ") or "(no scores)")
end

return ScoringService
