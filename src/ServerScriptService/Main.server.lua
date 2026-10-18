--[[
	Main (ServerScriptService.Main)
	===============================
	Server bootstrap. Runs once when the server starts.

	Right now it only:
	  1. Verifies the static Remotes tree exists (ReplicatedStorage.Remotes).
	  2. Initializes the service stubs, which validates every require-path at
	     boot instead of at first gameplay use.

	Gameplay is NOT implemented yet -- this prompt delivers structure, arena
	and config only.
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

-- 2) Initialize service modules (stubs for now)
local SERVICES = {
	"MatchService",
	"EggService",
	"CombatService",
	"ScoringService",
	"DataService",
}

for _, name in SERVICES do
	local service = require(ServerScriptService:WaitForChild(name))
	if type(service.Init) == "function" then
		service.Init()
	end
end

print("[Clutch the Egg] Server bootstrap complete -- structure + arena only, gameplay not built yet")
