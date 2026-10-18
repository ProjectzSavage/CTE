--[[
	VFXBridge (StarterPlayer.StarterPlayerScripts.VFXBridge)
	========================================================
	THE ONE FILE FOR THE ART/VFX POLISH PASS. Everything below the routing
	section is a STUB: fill the four functions (PlayPunchVFX, PlayStealVFX,
	PlayCrackVFX, ScreenShake) with particles/beams/sounds/screenspace juice
	and every combat moment lights up -- no other file needs editing.

	Server combat/gameplay code fires FeedbackEvents; this bridge is the
	single client subscriber that routes them into the stubs. Events arrive
	for ALL participants, so `params.InvolvesLocalPlayer` tells you whether
	the local player is the actor/victim (useful for first-person-only FX),
	and world positions are included for distance checks.

	Bots: entities can be Players OR bot Models. params.*Character is the
	resolved character Model either way (safe to attach emitters to).

	CONFIRMED EVENT PAYLOADS (FeedbackEvent kind -> data)
	-----------------------------------------------------
	World (FireAllClients -- everyone receives):
	  PunchSwing   { Player, Position }                       -- swing started (success only)
	  PunchHit     { Attacker, Victim, Position, Result }     -- Result: "Hit" | "Blocked" | "IFramed"
	  BlockedHit   { Attacker, Victim, Position }             -- victim was blocking
	  IFrameDodge  { Attacker, Victim, Position }             -- victim dash-i-framed it
	  EggStolen    { Attacker, Victim, Position }             -- punch knocked the egg loose
	  GripSave     { Player, Victim? no -- Player = saver, Attacker }  -- pet grip saved the steal
	  EggThrown    { Player, Direction, Position }            -- Direction = unit Vector3
	  EggFumble    { Player, Reason, Position }               -- Reason: "Attacked" | "DashCollision"
	                                                        --   | "Died" | "CharacterRemoved" | "Left"
	                                                        --   | "RoundStart" | "RoundEnd" | "BotDespawned"
	                                                        --   | "Manual" | "DebugCommand"
	  DashFumble   { Player, Victim, Position }               -- carrier dashed into someone
	  DashStart    { Player, Carrying }
	  EggImpact    { Player, Position }                       -- hot thrown egg beaned someone
	  EggPickup    { Player, Position }
	  EggOutOfBounds { Position }
	  EggRespawn   { Position }
	  BlockStart / BlockEnd / BlockBroken { Player }
	  SprintStart / SprintEnd { Player }
	  RoundStart   { Round, RoundsPerMatch, RoundLength }     -- kickoff of each round
	  RoundEnd     { Round, WinnerName?, WinnerPlayer?, Tied, TopTime, NextRoundIn }
	  MatchEnd     { MVPNames, MVPs, BestTotalHoldTime, NextLobbyIn }

	Personal (FireClient -- only the involved player receives):
	  PetHatched   { Pet = {Id, Name, Species, Rarity, Size, Mutation?, GripBonus} }
	  EggGranted   { Egg = {Id, Source, GuaranteedRare, UnlocksAt} }
	  HandsFull / NotCarrying / NoStamina / OnCooldown / Stunned / PunchWhiff
	  Exhausted    { Ability }
	  GripSave     (also personal echo)
	  NotEnoughClout / NotEnoughFragments { Need, Have }
	  EggNotReady  { ReadyAt }   DataNotReady {}

	Match flow also exists as structured remotes (MatchStateChanged,
	RoundEnded, MatchEnded) -- see GameREADME for those payloads.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local FeedbackEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FeedbackEvent")

local player = Players.LocalPlayer

local VFXBridge = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Player -> their Character; bot Model -> itself; nil-safe.
local function resolveCharacter(entity)
	if entity == nil then
		return nil
	end
	if entity:IsA("Player") then
		return entity.Character
	end
	if entity:IsA("Model") then
		return entity
	end
	return nil
end

local function involvesLocalPlayer(data)
	return data.Player == player
		or data.Attacker == player
		or data.Victim == player
end

local function localRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

-- True when a world position is close enough to matter for shake/FX.
local function nearLocalPlayer(position, radius)
	local mine = localRootPosition()
	if not mine or typeof(position) ~= "Vector3" then
		return false
	end
	return (position - mine).Magnitude <= (radius or Config.Camera.ShakeRadius)
end

---------------------------------------------------------------------------
-- STUBS -- fill these in during the polish pass
---------------------------------------------------------------------------

--[[
	PunchVFX: a punch CONNECTED (PunchHit).
	params = {
	  Attacker, Victim          : Player | bot Model
	  AttackerCharacter,
	  VictimCharacter           : Model?  (attach emitters here)
	  Position                  : Vector3 (victim's torso)
	  Result                    : "Hit" | "Blocked" | "IFramed"
	  InvolvesLocalPlayer       : boolean
	  NearLocalPlayer           : boolean
	}
	Suggestions: hit spark at Position, "Blocked" -> shield ripple,
	"IFramed" -> afterimage/whoosh, impact sound pitch by Result.
]]
function VFXBridge.PlayPunchVFX(params)
	-- TODO(art): punch impact VFX/SFX.
end

--[[
	StealVFX: the egg was knocked loose out of someone's hands (EggStolen).
	params = {
	  Attacker, Victim          : Player | bot Model
	  AttackerCharacter, VictimCharacter : Model?
	  Position                  : Vector3 (where the steal happened)
	  InvolvesLocalPlayer       : boolean
	  NearLocalPlayer           : boolean
	}
	Suggestions: gold burst + egg trail, victim "loss" flash, crowd sting SFX.
]]
function VFXBridge.PlayStealVFX(params)
	-- TODO(art): steal VFX/SFX.
end

--[[
	CrackVFX: anything egg-shaped happening (throws, fumbles, impacts,
	out-of-bounds, respawns).
	params = {
	  Reason                    : "Thrown" | "Fumble" | "DashFumble" | "Impact"
	                            | "OutOfBounds" | "Respawn"
	  Position                  : Vector3
	  Egg                       : the egg Part? (Workspace.Egg)
	  Player                    : Player | bot Model? (actor when applicable)
	  PlayerCharacter           : Model?
	  Victim                    : Player | bot Model? ("Impact" only)
	  FumbleReason              : string? (raw EggFumble Reason for "Fumble")
	  InvolvesLocalPlayer       : boolean
	  NearLocalPlayer           : boolean
	}
	Suggestions: shell-crack particles, "Respawn" -> materialize beam at
	center pad, "OutOfBounds" -> warning flash.
]]
function VFXBridge.PlayCrackVFX(params)
	-- TODO(art): egg crack/throw/impact VFX/SFX.
end

--[[
	ScreenShake: subtle camera shake. Default implementation forwards to
	CameraController (_G.CTECamera.AddShake) so it already works; replace or
	extend with screenspace effects (blur kick, chromatic hit, etc).
	  intensity : number, roughly 0.4 (small) .. 1.0 (big)
	  position  : Vector3? world position of the cause (nil = local-only)
]]
function VFXBridge.ScreenShake(intensity, position)
	local cameraApi = _G.CTECamera
	if cameraApi and type(cameraApi.AddShake) == "function" then
		cameraApi.AddShake(intensity)
	end
	-- TODO(art): extra screenspace juice here.
end

--[[
	Catch-all for every other FeedbackEvent kind (pickup, dash start, block,
	sprint, round/match flow, personal meta toasts...). Add cases as needed.
]]
function VFXBridge.OnOtherEvent(kind, data)
	-- TODO(art): e.g. RoundStart -> announcer VO, PetHatched -> confetti.
end

---------------------------------------------------------------------------
-- Routing (no need to edit below unless you want different trigger rules)
---------------------------------------------------------------------------

local function buildParams(data)
	return {
		Attacker = data.Attacker,
		Victim = data.Victim,
		Player = data.Player,
		AttackerCharacter = resolveCharacter(data.Attacker),
		VictimCharacter = resolveCharacter(data.Victim),
		PlayerCharacter = resolveCharacter(data.Player),
		Position = data.Position,
		Result = data.Result,
		InvolvesLocalPlayer = involvesLocalPlayer(data),
		NearLocalPlayer = nearLocalPlayer(data.Position),
	}
end

local function eggParams(data, reason)
	local params = buildParams(data)
	params.Reason = reason
	params.Egg = workspace:FindFirstChild("Egg")
	params.FumbleReason = data.Reason
	return params
end

FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if type(data) ~= "table" then
		data = {}
	end

	if kind == "PunchHit" then
		local params = buildParams(data)
		VFXBridge.PlayPunchVFX(params)
		if data.Result == "Hit" and (params.InvolvesLocalPlayer or params.NearLocalPlayer) then
			VFXBridge.ScreenShake(Config.Camera.ShakePerPunchHit, data.Position)
		end

	elseif kind == "EggStolen" then
		VFXBridge.PlayStealVFX(buildParams(data))

	elseif kind == "EggThrown" then
		VFXBridge.PlayCrackVFX(eggParams(data, "Thrown"))

	elseif kind == "EggFumble" then
		VFXBridge.PlayCrackVFX(eggParams(data, "Fumble"))

	elseif kind == "DashFumble" then
		local params = eggParams(data, "DashFumble")
		VFXBridge.PlayCrackVFX(params)
		if params.InvolvesLocalPlayer or params.NearLocalPlayer then
			VFXBridge.ScreenShake(Config.Camera.ShakePerDashFumble, data.Position)
		end

	elseif kind == "EggImpact" then
		local params = eggParams(data, "Impact")
		VFXBridge.PlayCrackVFX(params)
		if params.InvolvesLocalPlayer or params.NearLocalPlayer then
			VFXBridge.ScreenShake(Config.Camera.ShakePerEggImpact, data.Position)
		end

	elseif kind == "EggOutOfBounds" then
		VFXBridge.PlayCrackVFX(eggParams(data, "OutOfBounds"))
		if nearLocalPlayer(data.Position) then
			VFXBridge.ScreenShake(Config.Camera.ShakePerEggOut, data.Position)
		end

	elseif kind == "EggRespawn" then
		VFXBridge.PlayCrackVFX(eggParams(data, "Respawn"))

	else
		VFXBridge.OnOtherEvent(kind, data)
	end
end)

if Config.DebugVerboseLogging then
	print("[VFXBridge] Listening: fill PlayPunchVFX/PlayStealVFX/PlayCrackVFX/ScreenShake to add juice")
end
