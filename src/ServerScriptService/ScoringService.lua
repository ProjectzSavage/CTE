--[[
	ScoringService (ServerScriptService.ScoringService)
	===================================================
	STATUS: stub -- gameplay not implemented yet.

	Future responsibilities
	-----------------------
	* Record hold time per player per round (fed by EggService at
	  Config.HoldTimeSyncInterval).
	* Round winner = most TOTAL hold time in that round (tie -> shared/no win,
	  decided when built).
	* Match MVP = most hold time accumulated across ALL
	  Config.RoundsPerMatch rounds.
	* Expose results to MatchService and include them in the RoundEnded /
	  MatchEnded remote payloads for the GUI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local ScoringService = {}

function ScoringService.Init()
	-- TODO(scoring): per-round and per-match hold-time bookkeeping.
	if Config.DebugVerboseLogging then
		print("[ScoringService] stub initialized")
	end
end

return ScoringService
