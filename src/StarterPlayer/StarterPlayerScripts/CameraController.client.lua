--[[
	CameraController (StarterPlayer.StarterPlayerScripts.CameraController)
	======================================================================
	Camera polish layer. The stock Roblox Custom camera ALREADY provides the
	smooth follow + full player look/zoom control, so this script never
	fights it -- it only ADDS two damped effects on top:

	  1. FOV dynamics: slight zoom-OUT while carrying the egg
	     (+Config.Camera.CarryFOVBonus), a subtle sprint kick
	     (+SprintFOVBonus), all lerped at FovLerpSpeed so nothing snaps.
	  2. Screen shake: small decaying ROTATIONAL offsets applied right
	     after the default camera update (RenderPriority.Camera + 1), fed
	     by VFXBridge.ScreenShake -> _G.CTECamera.AddShake(intensity).
	     Capped at Config.Camera.ShakeMaxDegrees (subtle, never sickening).

	Everything is tunable in Config.Camera. Public API for other client
	scripts (VFXBridge):
	  _G.CTECamera.AddShake(intensity)
	  _G.CTECamera.GetShake()      -- current magnitude (debug)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local FeedbackEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FeedbackEvent")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local CamCfg = Config.Camera

local shakeMagnitude = 0
local sprinting = false

---------------------------------------------------------------------------
-- Public API (consumed by VFXBridge.ScreenShake)
---------------------------------------------------------------------------

_G.CTECamera = {
	AddShake = function(intensity)
		intensity = tonumber(intensity) or 0
		if intensity <= 0 then
			return
		end
		shakeMagnitude = math.min(1.5, shakeMagnitude + intensity)
	end,
	GetShake = function()
		return shakeMagnitude
	end,
}

---------------------------------------------------------------------------
-- State sources: carry = HasEgg attribute, sprint = server SprintStart/End
---------------------------------------------------------------------------

local function isCarrying()
	return player:GetAttribute("HasEgg") == true
end

FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if type(data) ~= "table" or data.Player ~= player then
		return
	end
	if kind == "SprintStart" then
		sprinting = true
	elseif kind == "SprintEnd" or kind == "BlockBroken" or kind == "Exhausted" then
		sprinting = false
	end
end)

---------------------------------------------------------------------------
-- Per-frame layer: runs AFTER the default camera update
---------------------------------------------------------------------------

local function targetFOV()
	local fov = CamCfg.BaseFOV
	if isCarrying() then
		fov = fov + CamCfg.CarryFOVBonus -- zoom out a touch: see threats coming
	end
	if sprinting and not isCarrying() then
		fov = fov + CamCfg.SprintFOVBonus
	end
	return fov
end

RunService:BindToRenderState("CTECamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	-- 1) Smooth FOV (damped lerp; frame-rate independent).
	local current = camera.FieldOfView
	local goal = targetFOV()
	local alpha = 1 - math.exp(-CamCfg.FovLerpSpeed * dt)
	local next = current + (goal - current) * alpha
	if math.abs(next - current) > 0.01 then
		camera.FieldOfView = next
	end

	-- 2) Shake: decaying random rotational kick on top of whatever the
	--    default camera produced this frame (never touches position, so
	--    movement/look control is unaffected).
	if shakeMagnitude > 0.001 then
		local degrees = math.min(shakeMagnitude, 1.5) * CamCfg.ShakeMaxDegrees
		local radians = math.rad(degrees)
		camera.CFrame = camera.CFrame * CFrame.Angles(
			(math.random() * 2 - 1) * radians,
			(math.random() * 2 - 1) * radians,
			(math.random() * 2 - 1) * radians * 0.5
		)
		shakeMagnitude = shakeMagnitude * math.exp(-CamCfg.ShakeDecay * dt)
		if shakeMagnitude <= 0.001 then
			shakeMagnitude = 0
		end
	end
end)

if Config.DebugVerboseLogging then
	print("[CameraController] Live: carry zoom-out + sprint kick + shake hook (_G.CTECamera.AddShake)")
end
