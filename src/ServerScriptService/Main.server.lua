--[[
	Main (ServerScriptService.Main)
	===============================
	Server bootstrap. Runs once when the server starts.

	  1. Verifies the static Remotes tree exists (ReplicatedStorage.Remotes).
	  2. Initializes the service modules. As of Task 2, EggService is LIVE
	     (egg spawn / auto-pickup / carry / hold time / fumble / respawn);
	     Match, Combat, Scoring and Data remain documented stubs.
	  3. Creates ServerScriptService.DebugCommands (BindableEvent) so server
	     functions can be triggered from the Studio command bar while playing:

	       game.ServerScriptService.DebugCommands:Fire("fumble")          -- drop the current carrier's egg
	       game.ServerScriptService.DebugCommands:Fire("fumble", "Name")  -- drop a specific player's egg
	       game.ServerScriptService.DebugCommands:Fire("respawn_egg")     -- force the egg back to center
	       game.ServerScriptService.DebugCommands:Fire("state")           -- print egg state + hold times
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- 1) Verify remotes (static instances declared in default.project.json)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local EXPECTED_REMOTES = {
	-- client -> server (input requests; server validates everything)
	"RequestAttack",
	"RequestThrow",
	"RequestDash",
	"RequestBlockStart",
	"RequestBlockEnd",
	-- server -> client (replicated state + polish hooks)
	"EggPossessionChanged",
	"HoldTimeUpdated",
	"MatchStateChanged",
	"RoundEnded",
	"MatchEnded",
	"FeedbackEvent",
}

for _, name in EXPECTED_REMOTES do
	if not Remotes:WaitForChild(name, 10) then
		warn("[Main] Missing remote: " .. name)
	end
end

-- 2) Require + initialize services
local MatchService = require(ServerScriptService:WaitForChild("MatchService"))
local EggService = require(ServerScriptService:WaitForChild("EggService"))
local CombatService = require(ServerScriptService:WaitForChild("CombatService"))
local ScoringService = require(ServerScriptService:WaitForChild("ScoringService"))
local DataService = require(ServerScriptService:WaitForChild("DataService"))

for _, service in ipairs({ MatchService, EggService, CombatService, ScoringService, DataService }) do
	if type(service.Init) == "function" then
		service.Init()
	end
end

-- 3) Debug commands: a BindableEvent bridge from the Studio command bar into
--    the running server. Works even where the command bar cannot share the
--    game's require() cache.
local debugCommands = Instance.new("BindableEvent")
debugCommands.Name = "DebugCommands"
debugCommands.Parent = ServerScriptService

debugCommands.Event:Connect(function(command, argument)
	if typeof(command) ~= "string" then
		warn('[DebugCommands] usage: Fire("fumble" | "respawn_egg" | "state" [, playerName])')
		return
	end
	command = command:lower()
	if command == "fumble" then
		EggService.Fumble(argument, "DebugCommand")
	elseif command == "respawn_egg" then
		EggService.RespawnEggNow()
	elseif command == "state" then
		print("[DebugCommands] " .. EggService.DebugState())
	else
		warn('[DebugCommands] unknown command "' .. command .. '" (try: fumble, respawn_egg, state)')
	end
end)

print("[Clutch the Egg] Server bootstrap complete -- egg system live (Task 2); match/combat/scoring are stubs")
