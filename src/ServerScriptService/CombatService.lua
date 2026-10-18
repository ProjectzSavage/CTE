--[[
	CombatService (ServerScriptService.CombatService)
	=================================================
	STATUS: stub -- gameplay not implemented yet.

	Future responsibilities
	-----------------------
	* Validate RequestAttack on the server: attacker must NOT be holding the
	  egg ("HANDS FULL" feedback otherwise), plus cooldown / range
	  (Config.AttackRange) / stamina checks. Apply knockback
	  (Config.AttackKnockback), reduced by the victim's block
	  (Config.BlockKnockbackReduction) and negated by dash i-frames.
	  Hitting the carrier knocks the egg loose (hand off to EggService).
	* Validate RequestThrow: only while holding the egg; lob it with
	  Config.ThrowSpeed + Config.ThrowUpwardBias (hand off to EggService).
	* Validate RequestDash: cooldown / stamina; carrying players get the
	  shorter no-i-frame dash, and dashing into a player drops the egg.
	* Track block state (RequestBlockStart / RequestBlockEnd): speed
	  multiplier, stamina drain, knockback reduction. Blocking while carrying
	  still accrues hold time (that rule lives in EggService/ScoringService).
	* Manage the stamina pool (spend + regen) for every player.
	* Fire FeedbackEvent for every hit / dash / block / "HANDS FULL" deny so
	  VFX, SFX and GUI polish can hook in later.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local CombatService = {}

function CombatService.Init()
	-- TODO(combat): remote handlers, validation, knockback, stamina.
	if Config.DebugVerboseLogging then
		print("[CombatService] stub initialized")
	end
end

return CombatService
