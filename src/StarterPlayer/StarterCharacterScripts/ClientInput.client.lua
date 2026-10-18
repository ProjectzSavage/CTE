--[[
	ClientInput (StarterPlayer.StarterCharacterScripts.ClientInput)
	===============================================================
	Client-side input controller (runs on every character spawn).

	Philosophy: this script ONLY translates input into Request* RemoteEvent
	fires. It never applies gameplay locally -- the server validates cooldowns,
	stamina and the contextual rules (has egg / hands full) and rejects
	cheaters. The only client-side gating is a soft possession check (don't
	even send obviously-invalid requests); the server re-checks everything.

	Bindings
	--------
	  Attack : Left Mouse, Gamepad X         (only when NOT carrying)
	  Throw  : Q or F, Gamepad Y             (only when carrying)
	  Block  : Right Mouse (hold), Gamepad L1
	  Dash   : E, Gamepad R1                 (Space is pure jump again)
	  Sprint : Left Shift (hold), Gamepad R2 -- drains stamina while held

	Mobile scheme (final): the NATIVE left thumbstick handles movement
	(Roblox's default TouchMovementMode -- this script never touches it),
	and the four HUD buttons in StarterGui.CTEGui (ATTACK / THROW / BLOCK /
	DASH) call the _G.CTEInput API below with the same contextual rules
	(the server enforces context, cooldowns and stamina regardless).
	ContextActionService touch buttons are DISABLED (createTouchButton =
	false) so no duplicate default buttons appear. Sprint is intentionally
	keyboard/gamepad-only on the spec's 4-button layout.

	GUI hook: the API is exposed on _G for GUI scripts (buttons live in the
	CTEGui screen, or in your hand-built replacement):
	  _G.CTEInput.Attack()
	  _G.CTEInput.Throw()
	  _G.CTEInput.Dash()
	  _G.CTEInput.Block(true)    -- press
	  _G.CTEInput.Block(false)   -- release
	  _G.CTEInput.Sprint(true)   -- press
	  _G.CTEInput.Sprint(false)  -- release

	Note: GUI TextButtons sink input, so clicking HUD buttons does NOT also
	trigger the MouseButton1 attack binding.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local RequestThrow = Remotes:WaitForChild("RequestThrow")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestBlockStart = Remotes:WaitForChild("RequestBlockStart")
local RequestBlockEnd = Remotes:WaitForChild("RequestBlockEnd")
local RequestSprintStart = Remotes:WaitForChild("RequestSprintStart")
local RequestSprintEnd = Remotes:WaitForChild("RequestSprintEnd")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

local player = Players.LocalPlayer

---------------------------------------------------------------------------
-- Ability requests (also the public API for the future GUI)
---------------------------------------------------------------------------

local function attack()
	-- Soft gate only: the server is authoritative and answers "HandsFull".
	if player:GetAttribute("HasEgg") then
		return
	end
	RequestAttack:FireServer()
end

local function throwEgg()
	-- Soft gate only: the server answers "NotCarrying" if we are wrong.
	if not player:GetAttribute("HasEgg") then
		return
	end
	RequestThrow:FireServer()
end

local function dash()
	RequestDash:FireServer()
end

-- Hold-style abilities (block/sprint): mouse button + key can overlap, so
-- count the holds and only tell the server about the first press / final
-- release.
local blockDepth = 0

local function setBlocking(blocking)
	if blocking then
		blockDepth = blockDepth + 1
		if blockDepth == 1 then
			RequestBlockStart:FireServer()
		end
	else
		blockDepth = math.max(0, blockDepth - 1)
		if blockDepth == 0 then
			RequestBlockEnd:FireServer()
		end
	end
end

local sprintDepth = 0

local function setSprinting(sprinting)
	if sprinting then
		sprintDepth = sprintDepth + 1
		if sprintDepth == 1 then
			RequestSprintStart:FireServer()
		end
	else
		sprintDepth = math.max(0, sprintDepth - 1)
		if sprintDepth == 0 then
			RequestSprintEnd:FireServer()
		end
	end
end

_G.CTEInput = {
	Attack = attack,
	Throw = throwEgg,
	Dash = dash,
	Block = setBlocking,
	Sprint = setSprinting,
}

---------------------------------------------------------------------------
-- ContextActionService bindings (keyboard + mouse + gamepad + touch buttons)
---------------------------------------------------------------------------

local function attackAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		attack()
	end
	return Enum.ContextActionResult.Pass
end

local function throwAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		throwEgg()
	end
	return Enum.ContextActionResult.Pass
end

local function dashAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		dash()
	end
	return Enum.ContextActionResult.Pass
end

local function holdAction(setter)
	return function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			setter(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			setter(false)
		end
		return Enum.ContextActionResult.Pass
	end
end

-- createTouchButton = false: mobile uses the native left thumbstick plus the
-- four HUD buttons in CTEGui (which call the _G.CTEInput API above), so CAS
-- must NOT spawn its own duplicate on-screen buttons. Rebinding the same
-- names on respawn replaces the previous character's bindings.
ContextActionService:BindAction("CTE_Attack", attackAction, false,
	Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX)
ContextActionService:BindAction("CTE_Throw", throwAction, false,
	Enum.KeyCode.Q, Enum.KeyCode.F, Enum.KeyCode.ButtonY)
ContextActionService:BindAction("CTE_Block", holdAction(setBlocking), false,
	Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL1)
ContextActionService:BindAction("CTE_Dash", dashAction, false,
	Enum.KeyCode.E, Enum.KeyCode.ButtonR1)
ContextActionService:BindAction("CTE_Sprint", holdAction(setSprinting), false,
	Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonR2)

---------------------------------------------------------------------------
-- Personal feedback (rejection reasons) -- print for now, GUI toast later
---------------------------------------------------------------------------

local PERSONAL_FEEDBACK = {
	HandsFull = true,
	NotCarrying = true,
	NoStamina = true,
	OnCooldown = true,
	Stunned = true,
	PunchWhiff = true,
	Exhausted = true,
}

FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if PERSONAL_FEEDBACK[kind] and Config.DebugVerboseLogging then
		local ability = type(data) == "table" and data.Ability or ""
		print(("[CTE] %s %s"):format(kind, ability)) -- TODO(gui): toast/flash instead
	end
end)
