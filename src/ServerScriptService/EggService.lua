--[[
	EggService (ServerScriptService.EggService)
	===========================================
	STATUS: stub -- gameplay not implemented yet.

	Future responsibilities
	-----------------------
	* Create and own the egg Part on the server (simple Part for now; visuals
	  are swapped in later via FeedbackEvent hooks).
	* Auto-pickup on touch (no button): Touched -> server validates -> egg
	  becomes carried by that player.
	* Track possession and accrue HOLD TIME (seconds) for the carrier.
	* Handle throws (lob at Config.ThrowSpeed), knock-loose pops when the
	  carrier is attacked, and the dash-collision drop rule
	  (Config.EggDropOnDashCollision).
	* Egg leaves the arena -> hold time pauses (Config.HoldTimePausesWhenLoose)
	  and the egg respawns at Workspace.Arena.EggSpawnPoint after
	  Config.EggRespawnDelay seconds.
	* Fire EggPossessionChanged / HoldTimeUpdated / FeedbackEvent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local EggService = {}

function EggService.Init()
	-- TODO(egg): spawn logic, possession state, hold-time accrual.
	if Config.DebugVerboseLogging then
		print("[EggService] stub initialized")
	end
end

return EggService
