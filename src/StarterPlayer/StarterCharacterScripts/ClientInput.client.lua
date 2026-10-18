--[[
	ClientInput (StarterPlayer.StarterCharacterScripts.ClientInput)
	===============================================================
	STATUS: stub -- no input handling yet.

	This LocalScript runs every time a character spawns. When input is built
	it will:
	  * Bind Attack / Throw / Block / Dash on keyboard, gamepad AND mobile
	    (on-screen buttons via ContextActionService).
	  * Fire the matching Request* RemoteEvent -- it NEVER applies gameplay
	    locally; the server validates and applies everything.
	  * Listen to EggPossessionChanged / MatchStateChanged / FeedbackEvent to
	    drive the HUD and cosmetic feedback later.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Cache the input remotes now so this require-path is validated on every spawn.
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local RequestThrow = Remotes:WaitForChild("RequestThrow")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestBlockStart = Remotes:WaitForChild("RequestBlockStart")
local RequestBlockEnd = Remotes:WaitForChild("RequestBlockEnd")

-- TODO(input): ContextActionService bindings -> FireServer() calls go here.
-- Hold onto the locals so linters stay quiet until the bindings exist.
local _cachedRemotes = { RequestAttack, RequestThrow, RequestDash, RequestBlockStart, RequestBlockEnd }
