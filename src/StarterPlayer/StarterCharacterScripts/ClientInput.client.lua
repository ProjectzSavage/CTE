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
	  Attack : Left Mouse, Gamepad X        (only when NOT carrying)
	  Throw  : Q or F, Gamepad Y            (only when carrying)
	  Block  : Right Mouse or E (hold), Gamepad L1
	  Dash   : Left Shift or Space, Gamepad R1
	           (Space intentionally still jumps too -- air-dashes are legal)

	Mobile: ContextActionService touch buttons are created for all four
	abilities as a functional placeholder. The real mobile GUI comes in a
	later prompt and should call the exposed functions below.

	GUI hook (later prompt): the API is exposed on _G for other client
	scripts (ScreenGui buttons live in a different LocalScript):
	  _G.CTEInput.Attack()
	  _G.CTEInput.Throw()
	  _G.CTEInput.Dash()
	  _G.CTEInput.Block(true)   -- press
	  _G.CTEInput.Block(false)  -- release

	TODO(gui): when real buttons exist, consider sinking MouseButton1 here or
	unbinding it so clicks on the HUD do not also punch.
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

-- Block is a HOLD: mouse button + key can overlap, so count the holds and
-- only tell the server about the first press / final release.
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

_G.CTEInput = {
	Attack = attack,
	Throw = throwEgg,
	Dash = dash,
	Block = setBlocking,
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

local function blockAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		setBlocking(true)
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		setBlocking(false)
	end
	return Enum.ContextActionResult.Pass
end

local function dashAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		dash()
	end
	return Enum.ContextActionResult.Pass -- Pass so Space still jumps (air-dash)
end

-- createTouchButton = true gives free (ugly) on-screen buttons on mobile
-- until the real GUI is wired up. Rebinding the same names on respawn
-- replaces the previous character's bindings.
ContextActionService:BindAction("CTE_Attack", attackAction, true,
	Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX)
ContextActionService:BindAction("CTE_Throw", throwAction, true,
	Enum.KeyCode.Q, Enum.KeyCode.F, Enum.KeyCode.ButtonY)
ContextActionService:BindAction("CTE_Block", blockAction, true,
	Enum.UserInputType.MouseButton2, Enum.KeyCode.E, Enum.KeyCode.ButtonL1)
ContextActionService:BindAction("CTE_Dash", dashAction, true,
	Enum.KeyCode.LeftShift, Enum.KeyCode.Space, Enum.KeyCode.ButtonR1)

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
}

FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if PERSONAL_FEEDBACK[kind] and Config.DebugVerboseLogging then
		local ability = type(data) == "table" and data.Ability or ""
		print(("[CTE] %s %s"):format(kind, ability)) -- TODO(gui): toast/flash instead
	end
end)
