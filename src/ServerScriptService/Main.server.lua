--[[
	Main (ServerScriptService.Main)
	===============================
	Server bootstrap. Runs once when the server starts.

	  1. Verifies the static Remotes tree exists (ReplicatedStorage.Remotes).
	  2. Initializes the service modules. As of Task 4, Egg, Combat, Scoring
	     and Match are LIVE (full match loop: lobby -> countdown -> 3 rounds
	     of 75s -> MVP + standings). Match initializes LAST because its state
	     machine starts immediately and drives the other services. Only Data
	     remains a reserved stub.
	  3. Wires CombatService into EggService as the thrown-egg impact handler
	     (dependency injection -- keeps the require graph one-directional).
	  4. Creates the debug bridges (STUDIO ONLY, gated by
	     Config.DebugAllowCommandBar):

	     a) ReplicatedStorage.Remotes.DebugCommand (RemoteEvent) -- use this
	        from the Studio command bar while PLAYING. The command bar runs in
	        CLIENT context, which cannot see ServerScriptService children:

	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("fumble", "PlayerName")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("respawn_egg")
	          game.ReplicatedStorage.Remotes.DebugCommand:FireServer("state")

	     b) ServerScriptService.DebugCommands (BindableEvent) -- same commands
	        from server-side code / "Run" mode:

	          game.ServerScriptService.DebugCommands:Fire("fumble")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

-- 1) Verify remotes (static instances declared in default.project.json)
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
	-- studio-only debug bridge (see below)
	"DebugCommand",
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

-- Init order matters: MatchService last -- its loop starts immediately and
-- orchestrates EggService (round spawns/pickup gating) and ScoringService
-- (round bookkeeping), which must already be live.
for _, service in ipairs({ EggService, CombatService, ScoringService, MatchService, DataService }) do
	if type(service.Init) == "function" then
		service.Init()
	end
end

-- 3) Cross-service wiring: EggService reports thrown-egg impacts,
--    CombatService applies the knockback. Injected here so neither module
--    has to require the other in both directions.
EggService.SetImpactHandler(function(player, eggVelocity)
	CombatService.HandleEggImpact(player, eggVelocity)
end)

-- 4) Debug bridges (Studio only)
local function runDebugCommand(command, argument)
	if typeof(command) ~= "string" then
		warn('[Debug] usage: "fumble" | "respawn_egg" | "state" [, playerName]')
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
	else
		warn('[Debug] unknown command "' .. command .. '" (try: fumble, respawn_egg, state)')
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
		runDebugCommand(command, argument)
	end)
else
	warn("[Main] Remotes.DebugCommand missing -- command-bar debugging unavailable")
end

-- b) BindableEvent path -- for server-side automation and "Run" mode.
local debugCommands = Instance.new("BindableEvent")
debugCommands.Name = "DebugCommands"
debugCommands.Parent = ServerScriptService

debugCommands.Event:Connect(function(command, argument)
	runDebugCommand(command, argument)
end)

print("[Clutch the Egg] Server bootstrap complete -- egg + combat + scoring + match loop live (Task 4)")
