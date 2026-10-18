--[[
	MatchService (ServerScriptService.MatchService)
	===============================================
	The match state machine:

	  Lobby -> Countdown -> RoundPlaying -> RoundEnd -+-> (next round)
	                                                  +-> MatchEnd -> Lobby

	Lobby        : waits until at least Config.MinPlayersToStart (2) are in
	               (up to Config.MaxPlayers = 6; slot capping is Roblox's job).
	               Egg pickups are disabled; the egg sits at center.
	Countdown    : Config.RoundStartCountdown seconds, re-checked every tick --
	               if players drop below the minimum it aborts back to Lobby.
	RoundPlaying : Config.RoundLength seconds (75). EggService spawns a fresh
	               egg at center, pickups enabled; ScoringService accumulates
	               hold time for whoever carries (pauses while the egg is
	               loose/respawning -- there is no carrier then). A 1 Hz
	               MatchStateChanged clock keeps GUIs in sync.
	RoundEnd     : scoring settles FIRST (a carrier at the exact expiry keeps
	               their partial-second time), then the egg is fumbled and
	               parked at center. RoundEnded fires with ranked results and
	               the round winner is printed to output. Round hold times are
	               cleared; MATCH totals persist.
	MatchEnd     : after Config.RoundsPerMatch (3) rounds -- MVP = highest
	               total hold time across all rounds (present players only,
	               ties shared). MatchEnded fires with final standings
	               (total hold time + rounds won per player) and everything
	               is printed to output. After Config.IntermissionLength it
	               resets and returns to Lobby.

	Leavers      : a player leaving mid-round fumbles (EggService) and their
	               match totals become "ghost" standings (ScoringService);
	               the round/match simply continues with whoever is left.

	Remote payloads
	---------------
	MatchStateChanged(stateName, data)
	  Lobby        : { Players, MinPlayersToStart, MaxPlayers }
	  Countdown    : { StartsIn }                  (StartsIn = 0 means GO)
	  RoundPlaying : { Round, RoundsPerMatch, RoundLength?, TimeLeft }  (~1 Hz)
	  RoundEnd     : { Round, WinnerName?, NextRoundIn }
	  MatchEnd     : { MVPNames, BestTotalHoldTime, NextLobbyIn }
	RoundEnded(roundNumber, results)   -- results = ScoringService.EndRound()
	MatchEnded(finalStandings)         -- ScoringService.GetFinalStandings()

	Testing: set Config.DebugQuickMatch = true for 15-second rounds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local EggService = require(ServerScriptService:WaitForChild("EggService"))
local ScoringService = require(ServerScriptService:WaitForChild("ScoringService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local MatchStateChanged = Remotes:WaitForChild("MatchStateChanged")
local RoundEnded = Remotes:WaitForChild("RoundEnded")
local MatchEnded = Remotes:WaitForChild("MatchEnded")

local MatchService = {}

local currentState = "Boot"
local currentRound = 0
local loopStarted = false

local function now()
	return os.clock()
end

local function countPlayers()
	return #Players:GetPlayers()
end

local function getRoundLength()
	if Config.DebugQuickMatch then
		return Config.DebugQuickMatchRoundLength
	end
	return Config.RoundLength
end

local function setState(stateName, data)
	currentState = stateName
	MatchStateChanged:FireAllClients(stateName, data or {})
	if Config.DebugVerboseLogging then
		print("[Match] State -> " .. stateName)
	end
end

---------------------------------------------------------------------------
-- States
---------------------------------------------------------------------------

local function waitForPlayers()
	EggService.SetEnabled(false) -- no pickups in the lobby
	local lastCount = -1
	while true do
		local count = countPlayers()
		if count ~= lastCount then
			lastCount = count
			setState("Lobby", {
				Players = count,
				MinPlayersToStart = Config.MinPlayersToStart,
				MaxPlayers = Config.MaxPlayers,
			})
		end
		if count >= Config.MinPlayersToStart then
			return
		end
		task.wait(0.5)
	end
end

-- Returns true when the countdown completed with enough players.
local function runCountdown()
	for count = Config.RoundStartCountdown, 1, -1 do
		if countPlayers() < Config.MinPlayersToStart then
			return false
		end
		setState("Countdown", { StartsIn = count })
		task.wait(1)
	end
	if countPlayers() < Config.MinPlayersToStart then
		return false
	end
	setState("Countdown", { StartsIn = 0 }) -- GO!
	return true
end

local function playRound(roundNumber)
	local length = getRoundLength()

	-- Fresh round: reset per-round scoring, egg to center, pickups live.
	ScoringService.StartRound()
	EggService.StartRound()
	EggService.SetEnabled(true)

	setState("RoundPlaying", {
		Round = roundNumber,
		RoundsPerMatch = Config.RoundsPerMatch,
		RoundLength = length,
		TimeLeft = length,
	})
	print(("[Match] --- Round %d/%d started (%ds) ---"):format(
		roundNumber, Config.RoundsPerMatch, length))

	-- Round clock with a 1 Hz broadcast for GUI timers. This fires the remote
	-- directly (not setState) so the verbose log only shows real transitions.
	local deadline = now() + length
	local lastAnnounced = length
	while true do
		local remaining = deadline - now()
		if remaining <= 0 then
			break
		end
		local timeLeft = math.ceil(remaining)
		if timeLeft ~= lastAnnounced then
			lastAnnounced = timeLeft
			MatchStateChanged:FireAllClients("RoundPlaying", {
				Round = roundNumber,
				RoundsPerMatch = Config.RoundsPerMatch,
				TimeLeft = timeLeft,
			})
		end
		task.wait(0.2)
	end

	-- Time! Score FIRST so whoever is carrying at the exact expiry keeps
	-- their partial-second hold time, then park the egg and lock pickups.
	EggService.SetEnabled(false)
	local results = ScoringService.EndRound()
	EggService.EndRound()

	RoundEnded:FireAllClients(roundNumber, results)

	-- Announce the round to the output (deliverable: results in output).
	if results.WinnerName then
		print(("[Match] Round %d winner: %s (%.1fs hold)%s"):format(
			roundNumber, results.WinnerName, results.TopTime,
			results.Tied and "  [TIED]" or ""))
	else
		print(("[Match] Round %d: nobody held the egg - no winner"):format(roundNumber))
	end
	for rank, entry in ipairs(results.Entries) do
		print(("    #%d  %-20s round %6.2fs | match %6.2fs | rounds won %d"):format(
			rank, entry.Name, entry.RoundTime, entry.MatchTime, entry.RoundsWon))
	end

	setState("RoundEnd", {
		Round = roundNumber,
		WinnerName = results.WinnerName,
		NextRoundIn = Config.RoundEndFreeze,
	})
	task.wait(Config.RoundEndFreeze)
end

local function playMatch()
	currentRound = 1
	ScoringService.ResetMatch()
	EggService.ResetHoldTimes()

	while currentRound <= Config.RoundsPerMatch do
		playRound(currentRound)
		currentRound = currentRound + 1
	end

	-- Match over: MVP + final standings.
	local final = ScoringService.GetFinalStandings()
	MatchEnded:FireAllClients(final)

	print("[Match] ================= MATCH OVER =================")
	if #final.MVPNames > 0 then
		print(("[Match] MVP: %s (%.1fs total hold time)"):format(
			table.concat(final.MVPNames, " + "), final.BestTotalHoldTime))
	else
		print("[Match] MVP: nobody (no hold time was recorded)")
	end
	print("[Match] Final standings:")
	for rank, entry in ipairs(final.Standings) do
		print(("    #%d  %-20s total %7.2fs | rounds won %d%s%s"):format(
			rank, entry.Name, entry.TotalHoldTime, entry.RoundsWon,
			entry.IsMVP and " | MVP" or "",
			entry.Left and " | left match" or ""))
	end
	print("[Match] =============================================")

	setState("MatchEnd", {
		MVPNames = final.MVPNames,
		BestTotalHoldTime = final.BestTotalHoldTime,
		NextLobbyIn = Config.IntermissionLength,
	})
	task.wait(Config.IntermissionLength)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function MatchService.Init()
	if loopStarted then
		return
	end
	loopStarted = true

	task.spawn(function()
		while true do
			waitForPlayers()
			if runCountdown() then
				playMatch()
			end
		end
	end)

	print("[MatchService] Initialized: Lobby -> Countdown -> Rounds -> MatchEnd loop running")
end

function MatchService.GetState()
	return currentState
end

function MatchService.GetRound()
	return currentRound
end

function MatchService.DebugState()
	return ("state=%s round=%d/%d players=%d"):format(
		currentState, currentRound, Config.RoundsPerMatch, countPlayers())
end

return MatchService
