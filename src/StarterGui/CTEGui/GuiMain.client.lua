--[[
	GuiMain (LocalScript inside StarterGui.CTEGui)
	==============================================
	Builds and routes the whole GUI. Runs once per player (PlayerGui copy of
	the StarterGui screen, ResetOnSpawn = false), so it survives respawns.

	Data sources (NO game logic is duplicated here -- everything is state read
	from the server):
	  MatchStateChanged  -> which screen is visible, round clock, countdown
	  RoundEnded         -> round-end results panel
	  MatchEnded         -> match-end results panel (MVP + standings)
	  HoldTimeUpdated    -> hold-time board rows
	  EggPossessionChanged -> carrier highlight
	  FeedbackEvent      -> steal feed toasts + cooldown wipes (from SUCCESS
	                        events like PunchSwing/DashStart, so keyboard and
	                        button users both see them)
	  Player attributes  -> HasEgg (button context states), Stamina (bar +
	                        dash availability)

	Buttons call _G.CTEInput (exposed by ClientInput) which fires the Request*
	RemoteEvents; the server validates everything.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local MatchStateChanged = Remotes:WaitForChild("MatchStateChanged")
local RoundEnded = Remotes:WaitForChild("RoundEnded")
local MatchEnded = Remotes:WaitForChild("MatchEnded")
local HoldTimeUpdated = Remotes:WaitForChild("HoldTimeUpdated")
local EggPossessionChanged = Remotes:WaitForChild("EggPossessionChanged")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")

-- Fallbacks if _G.CTEInput is not ready yet (should never happen mid-match).
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local RequestThrow = Remotes:WaitForChild("RequestThrow")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestBlockStart = Remotes:WaitForChild("RequestBlockStart")
local RequestBlockEnd = Remotes:WaitForChild("RequestBlockEnd")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local LobbyScreen = require(script.Parent:WaitForChild("LobbyScreen"))
local HudScreen = require(script.Parent:WaitForChild("HudScreen"))
local ResultsScreens = require(script.Parent:WaitForChild("ResultsScreens"))
local SettingsPanel = require(script.Parent:WaitForChild("SettingsPanel"))

local player = Players.LocalPlayer
local gui = script.Parent -- the CTEGui ScreenGui (already in PlayerGui)
gui.ResetOnSpawn = false
-- Keep the HUD clear of core buttons (chat/menu) on phones, where available.
pcall(function()
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeArea
end)

---------------------------------------------------------------------------
-- Build screens. Creation order = paint order (later siblings draw on top).
---------------------------------------------------------------------------

local hud = HudScreen.Create(gui)
local lobby = LobbyScreen.Create(gui)
local results = ResultsScreens.Create(gui)
local settings = SettingsPanel.Create(gui)

-- Info toast (top-center, under the timer) for placeholder/flow messages.
local toastFrame = UiKit.frame({
	Name = "Toasts",
	Size = UDim2.fromScale(0.5, 0.12),
	Position = UDim2.fromScale(0.25, 0.14),
	BackgroundTransparency = 1,
}, gui)
UiKit.listLayout(toastFrame, Enum.FillDirection.Vertical, 0.02,
	Enum.HorizontalAlignment.Center)

local function toast(message, color)
	local label = UiKit.frame({
		Name = "Toast",
		Size = UDim2.fromScale(1, 0.4),
		BackgroundColor3 = UiKit.Theme.Panel,
		BackgroundTransparency = 0.1,
	}, toastFrame)
	UiKit.label({
		Size = UDim2.fromScale(0.96, 0.7),
		Position = UDim2.fromScale(0.02, 0.15),
		Text = message,
		Font = UiKit.Theme.FontMain,
		TextColor3 = color or UiKit.Theme.Text,
		TextWrapped = true,
	}, label)

	task.delay(2.6, function()
		if label.Parent then
			UiKit.tween(label, 0.4, { BackgroundTransparency = 1 })
			for _, child in ipairs(label:GetChildren()) do
				if child:IsA("TextLabel") then
					UiKit.tween(child, 0.4, { TextTransparency = 1 })
				end
			end
			task.delay(0.45, function()
				label:Destroy()
			end)
		end
	end)
end

---------------------------------------------------------------------------
-- Ability buttons -> ClientInput (which fires the Request* remotes)
---------------------------------------------------------------------------

local function callInput(functionName, fallbackRemote, ...)
	local api = _G.CTEInput
	if api and type(api[functionName]) == "function" then
		api[functionName](...)
	elseif fallbackRemote then
		fallbackRemote:FireServer()
	end
end

hud.OnAbility = function(abilityName, isDown)
	if abilityName == "ATTACK" and isDown then
		callInput("Attack", RequestAttack)
	elseif abilityName == "THROW" and isDown then
		callInput("Throw", RequestThrow)
	elseif abilityName == "DASH" and isDown then
		callInput("Dash", RequestDash)
	elseif abilityName == "BLOCK" then
		callInput("Block", isDown and RequestBlockStart or RequestBlockEnd, isDown)
	end
end

hud.OnSettings = function()
	settings:Toggle()
end
lobby.OnSettings = function()
	settings:Toggle()
end

lobby.OnPlay = function()
	toast(("Matches start automatically at %d+ players — ready-up coming soon!")
		:format(Config.MinPlayersToStart), UiKit.Theme.Info)
end
lobby.OnMode2v2v2 = function()
	toast("2v2v2 is a placeholder for now — team mode arrives in a later update!",
		UiKit.Theme.Info)
end

results.OnPlayAgain = function()
	toast("The next match starts automatically after the intermission.", UiKit.Theme.Info)
end
results.OnBackToLobby = function()
	toast("Heading back to the lobby…", UiKit.Theme.Info)
end

---------------------------------------------------------------------------
-- Screen state router (server-driven; the GUI never decides the flow)
---------------------------------------------------------------------------

local matchEndPayload = nil
local currentState = "Lobby"

local function applyState(stateName, data)
	currentState = stateName
	data = data or {}

	lobby:SetVisible(stateName == "Lobby")
	hud:SetVisible(stateName ~= "Lobby")

	if stateName == "Lobby" then
		lobby:SetPlayerCount(data.Players or #Players:GetPlayers())
		results:HideRoundEnd()
		results:HideMatchEnd()
	elseif stateName == "Countdown" then
		results:HideRoundEnd()
		results:HideMatchEnd()
		hud:ShowCountdown(data.StartsIn or 3)
	elseif stateName == "RoundPlaying" then
		results:HideRoundEnd()
		results:HideMatchEnd()
		matchEndPayload = nil
		if data.Round then
			hud:SetRoundInfo(data.Round, data.RoundsPerMatch)
		end
		hud:SetTimeLeft(data.TimeLeft)
	elseif stateName == "RoundEnd" then
		results:HideMatchEnd()
		-- panel content arrives via RoundEnded (fired just before this state)
	elseif stateName == "MatchEnd" then
		results:HideRoundEnd()
		if matchEndPayload then
			results:ShowMatchEnd(matchEndPayload)
		end
	end
end

MatchStateChanged.OnClientEvent:Connect(applyState)

RoundEnded.OnClientEvent:Connect(function(roundNumber, resultsData)
	if type(resultsData) == "table" then
		results:ShowRoundEnd(roundNumber, resultsData)
	end
end)

MatchEnded.OnClientEvent:Connect(function(final)
	matchEndPayload = final
	if currentState == "MatchEnd" then
		results:ShowMatchEnd(final)
	end
end)

HoldTimeUpdated.OnClientEvent:Connect(function(entries)
	hud:UpdateHoldTimes(entries)
end)

EggPossessionChanged.OnClientEvent:Connect(function(newCarrier)
	hud:SetCarrier(newCarrier)
end)

---------------------------------------------------------------------------
-- FeedbackEvent: steal feed + cooldown wipes (success events only)
---------------------------------------------------------------------------

FeedbackEvent.OnClientEvent:Connect(function(kind, data)
	if type(data) ~= "table" then
		data = {}
	end

	-- Feed messages (world events).
	if kind == "EggStolen" then
		local attacker = UiKit.playerName(data.Attacker, "?")
		local victim = UiKit.playerName(data.Victim, "?")
		hud:PushFeed(("%s stole the egg from %s!"):format(attacker, victim), UiKit.Theme.Accent)
	elseif kind == "EggPickup" then
		hud:PushFeed(("%s grabbed the egg!"):format(UiKit.playerName(data.Player, "?")),
			UiKit.Theme.Good)
	elseif kind == "EggThrown" then
		hud:PushFeed(("%s threw the egg!"):format(UiKit.playerName(data.Player, "?")),
			UiKit.Theme.Info)
	elseif kind == "DashFumble" then
		hud:PushFeed(("%s fumbled the egg mid-dash!"):format(UiKit.playerName(data.Player, "?")),
			UiKit.Theme.Bad)
	elseif kind == "EggOutOfBounds" then
		hud:PushFeed("The egg flew out of the arena — respawning…", UiKit.Theme.Bad)
	end

	-- Cooldown wipes for the LOCAL player, driven by server success events.
	if data.Player == player then
		if kind == "PunchSwing" then
			hud:StartCooldown("ATTACK", Config.AttackCooldown)
		elseif kind == "DashStart" then
			local cooldown = data.Carrying and Config.DashCooldownCarrying or Config.DashCooldown
			hud:StartCooldown("DASH", cooldown)
		end
	end
end)

---------------------------------------------------------------------------
-- Replicated attributes: HasEgg (context buttons) + Stamina (bar/dash gate)
---------------------------------------------------------------------------

local function refreshHasEgg()
	hud:SetHasEgg(player:GetAttribute("HasEgg") == true)
end
local function refreshStamina()
	hud:SetStamina(player:GetAttribute("Stamina") or Config.StaminaMax)
end

player:GetAttributeChangedSignal("HasEgg"):Connect(refreshHasEgg)
player:GetAttributeChangedSignal("Stamina"):Connect(refreshStamina)
refreshHasEgg()
refreshStamina()

---------------------------------------------------------------------------
-- Initial state (the server resyncs us via MatchStateChanged shortly after
-- join if a match is already running)
---------------------------------------------------------------------------

lobby:SetPlayerCount(#Players:GetPlayers())
Players.PlayerAdded:Connect(function()
	if currentState == "Lobby" then
		lobby:SetPlayerCount(#Players:GetPlayers())
	end
end)
Players.PlayerRemoving:Connect(function()
	if currentState == "Lobby" then
		lobby:SetPlayerCount(#Players:GetPlayers() - 1)
	end
end)

applyState("Lobby", { Players = #Players:GetPlayers() })
