--[[
	Main (ServerScriptService.Main)
	===============================
	Server bootstrap. Runs once when the server starts.

	  1. Creates ServerScriptService.ServerFeedback (BindableEvent) -- the
	     server-side mirror of every FeedbackEvent (EconomyService counts
	     knockdowns/steals through it). MUST exist before services init.
	  2. Verifies the static Remotes tree exists (ReplicatedStorage.Remotes).
	  3. Initializes the service modules IN ORDER:
	       Data -> Egg -> Combat -> Scoring -> Hatchery -> Economy
	       -> Bots -> Matchmaking -> AntiCheat -> Match (last: its loop
	          starts immediately and orchestrates everything).
	  4. Cross-service wiring (dependency injection, one-directional graph):
	       * EggService  -> CombatService.HandleEggImpact (thrown-egg hits)
	       * MatchService-> EconomyService.ResetMatchStats / SettleMatch
	       * HatcheryService <- DataService.OnProfileReady (snapshot push)
	  5. Debug bridges (STUDIO ONLY, gated by Config.DebugAllowCommandBar):

	     a) ReplicatedStorage.Remotes.DebugCommand (RemoteEvent) -- from the
	        Studio command bar while PLAYING (client context):

	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("respawn_egg")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("grantegg")        -- mystery egg
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("grantegg", "rare")-- guaranteed rare
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("clout", "1000")   -- add clout
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("frags", "10")     -- add fragments
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("hatchnow")        -- finish hatch timers

	     b) ServerScriptService.DebugCommands (BindableEvent) -- same from
	        server-side code / "Run" mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

-- 1) Server-side feedback mirror (created BEFORE any service initializes).
local debugCommands = Instance.new("BindableEvent")
debugCommands.Name = "DebugCommands"
debugCommands.Parent = ServerScriptService

local serverFeedback = Instance.new("BindableEvent")
serverFeedback.Name = "ServerFeedback"
serverFeedback.Parent = ServerScriptService

-- 2) Verify remotes (static instances declared in default.project.json)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local EXPECTED_REMOTES = {
	-- client -> server (input requests; server validates everything)
	"RequestAttack",
	"RequestThrow",
	"RequestDash",
	"RequestBlockStart",
	"RequestBlockEnd",
	"RequestSprintStart",
	"RequestSprintEnd",
	-- server -> client (replicated state + polish hooks)
	"EggPossessionChanged",
	"HoldTimeUpdated",
	"MatchStateChanged",
	"RoundEnded",
	"MatchEnded",
	"FeedbackEvent",
	-- meta layer (economy / hatchery)
	"MatchRewards",
	"HatcheryRequest",
	"HatcheryUpdated",
	-- studio-only debug bridge (see below)
	"DebugCommand",
}

for _, name in EXPECTED_REMOTES do
	if not Remotes:WaitForChild(name, 10) then
		warn("[Main] Missing remote: " .. name)
	end
end

-- 3) Require + initialize services
local DataService = require(ServerScriptService:WaitForChild("DataService"))
local EggService = require(ServerScriptService:WaitForChild("EggService"))
local CombatService = require(ServerScriptService:WaitForChild("CombatService"))
local ScoringService = require(ServerScriptService:WaitForChild("ScoringService"))
local HatcheryService = require(ServerScriptService:WaitForChild("HatcheryService"))
local EconomyService = require(ServerScriptService:WaitForChild("EconomyService"))
local BotService = require(ServerScriptService:WaitForChild("BotService"))
local MatchmakingService = require(ServerScriptService:WaitForChild("MatchmakingService"))
local AntiCheatService = require(ServerScriptService:WaitForChild("AntiCheatService"))
local MatchService = require(ServerScriptService:WaitForChild("MatchService"))

-- Init order matters: Data first (profiles feed everything meta), Match LAST
-- (its state machine starts immediately and drives the other services).
for _, service in ipairs({
	DataService, EggService, CombatService, ScoringService,
	HatcheryService, EconomyService, BotService, MatchmakingService,
	AntiCheatService, MatchService,
}) do
	if type(service.Init) == "function" then
		service.Init()
	end
end

-- 4) Cross-service wiring (dependency injection keeps requires acyclic).
EggService.SetImpactHandler(function(player, eggVelocity)
	CombatService.HandleEggImpact(player, eggVelocity)
end)
MatchService.SetMatchStartHandler(function()
	EconomyService.ResetMatchStats()
end)
MatchService.SetMatchEndHandler(function(final)
	EconomyService.SettleMatch(final)
end)

-- 5) Debug bridges (Studio only)
local function runDebugCommand(command, argument, player)
	if typeof(command) ~= "string" then
		warn('[Debug] usage: "fumble" | "respawn_egg" | "state" | "grantegg" '
			.. '| "clout" | "frags" | "hatchnow" [, argument]')
		return
	end
	command = command:lower()
	if command == "fumble" then
		EggService.Fumble(argument, "DebugCommand")
	elseif command == "respawn_egg" then
		EggService.RespawnEggNow()
	elseif command == "state" then
		print("[Debug] match : " .. MatchService.DebugState())
		print("[Debug] egg   : " .. EggService.DebugState())
		print("[Debug] combat: " .. CombatService.DebugState())
		print("[Debug] score : " .. ScoringService.DebugState())
		print("[Debug] bots  : " .. BotService.DebugState())
		print("[Debug] data  : " .. DataService.DebugState())
		print("[Debug] econ  : " .. EconomyService.DebugState())
		print("[Debug] hatch : " .. HatcheryService.DebugState())
		print("[Debug] queue : " .. MatchmakingService.DebugState())
		print("[Debug] cheat : " .. AntiCheatService.DebugState())
	elseif command == "grantegg" then
		if player then
			HatcheryService.GrantEgg(player, "Debug", argument == "rare")
		end
	elseif command == "clout" then
		if player then
			DataService.AddClout(player, tonumber(argument) or 1000)
			HatcheryService.SendSnapshot(player)
		end
	elseif command == "frags" then
		if player then
			DataService.AddFragments(player, tonumber(argument) or 10)
			HatcheryService.SendSnapshot(player)
		end
	elseif command == "hatchnow" then
		if player then
			local profile = DataService.GetProfile(player)
			if profile then
				for _, egg in ipairs(profile.Eggs) do
					egg.UnlocksAt = os.time()
				end
				HatcheryService.SendSnapshot(player)
			end
		end
	else
		warn('[Debug] unknown command "' .. command .. '"')
	end
end

-- a) RemoteEvent path -- reachable from the command bar during Play because
--    ReplicatedStorage replicates to the client. Hard-gated to Studio.
local debugRemote = Remotes:FindFirstChild("DebugCommand")
if debugRemote and debugRemote:IsA("RemoteEvent") then
	debugRemote.OnServerEvent:Connect(function(player, command, argument)
		if not (RunService:IsStudio() and Config.DebugAllowCommandBar) then
			return -- never trust debug commands outside Studio
		end
		runDebugCommand(command, argument, player)
	end)
else
	warn("[Main] Remotes.DebugCommand missing -- command-bar debugging unavailable")
end

-- b) BindableEvent path -- for server-side automation and "Run" mode.
debugCommands.Event:Connect(function(command, argument)
	runDebugCommand(command, argument, nil)
end)

print("[Clutch the Egg] Server bootstrap complete -- match + bots + economy + "
	.. "hatchery + matchmaking + anti-cheat live (Tasks 6-7)")
