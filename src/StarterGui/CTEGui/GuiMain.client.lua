--[[
	GuiMain (LocalScript inside StarterGui.CTEGui)
	==============================================
	Builds and routes the whole GUI. Runs once per player (PlayerGui copy of
	the StarterGui screen, ResetOnSpawn = false), so it survives respawns.

	Layout philosophy: NO full-screen menus. The HUD is always up; the lobby
	is just the idle HUD + a small collapsible CONTROLS panel + a HATCHERY
	button. Matches start automatically (bots fill empty slots), results
	panels overlay the HUD, and toasts report rewards.

	Data sources (NO game logic is duplicated here -- everything is state read
	from the server):
	  MatchStateChanged  -> timer/round/status line, countdown, screen flow
	  RoundEnded         -> round-end results panel
	  MatchEnded         -> match-end results panel (MVP + standings)
	  MatchRewards       -> "+Clout / +Fragments" toast (personal)
	  HoldTimeUpdated    -> hold-time board rows (players AND bots)
	  EggPossessionChanged -> carrier highlight
	  HatcheryUpdated    -> hatchery panel snapshot
	  FeedbackEvent      -> steal/grip feed + cooldown wipes + pet/egg toasts
	  Player attributes  -> HasEgg (button context states), Stamina (bar/dash)

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
local MatchRewards = Remotes:WaitForChild("MatchRewards")
local HoldTimeUpdated = Remotes:WaitForChild("HoldTimeUpdated")
local EggPossessionChanged = Remotes:WaitForChild("EggPossessionChanged")
local FeedbackEvent = Remotes:WaitForChild("FeedbackEvent")
local HatcheryRequest = Remotes:WaitForChild("HatcheryRequest")
local HatcheryUpdated = Remotes:WaitForChild("HatcheryUpdated")

-- Fallbacks if _G.CTEInput is not ready yet (should never happen mid-match).
local RequestAttack = Remotes:WaitForChild("RequestAttack")
local RequestThrow = Remotes:WaitForChild("RequestThrow")
local RequestDash = Remotes:WaitForChild("RequestDash")
local RequestBlockStart = Remotes:WaitForChild("RequestBlockStart")
local RequestBlockEnd = Remotes:WaitForChild("RequestBlockEnd")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local ControlsPanel = require(script.Parent:WaitForChild("ControlsPanel"))
local HudScreen = require(script.Parent:WaitForChild("HudScreen"))
local ResultsScreens = require(script.Parent:WaitForChild("ResultsScreens"))
local SettingsPanel = require(script.Parent:WaitForChild("SettingsPanel"))
local HatcheryPanel = require(script.Parent:WaitForChild("HatcheryPanel"))

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
local results = ResultsScreens.Create(gui)
local settings = SettingsPanel.Create(gui)
local controls = ControlsPanel.Create(gui)
local hatchery = HatcheryPanel.Create(gui) -- above controls: it is an overlay

hud:SetVisible(true) -- the HUD is always up now (idle in the lobby)

-- Info toast (top-center, under the timer) for rewards/flow messages.
local toastFrame = UiKit.frame({
	Name = "Toasts",
	Size = UDim2.fromScale(0.5, 0.16),
	Position = UDim2.fromScale(0.25, 0.18),
	BackgroundTransparency = 1,
}, gui)
UiKit.listLayout(toastFrame, Enum.FillDirection.Vertical, 0.02,
	Enum.HorizontalAlignment.Center)

local function toast(message, color)
	local label = UiKit.frame({
		Name = "Toast",
		Size = UDim2.fromScale(1, 0.3),
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

	task.delay(3.2, function()
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
hud.OnHatchery = function()
	hatchery:Toggle()
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

	if stateName == "Lobby" then
		results:HideRoundEnd()
		results:HideMatchEnd()
		hud.timerLabel.Text = "--"
		hud.countdownLabel.Visible = false
		hud.roundLabel.Text = "Lobby"
		controls:SetCollapsed(false)
		if data.BotsEnabled then
			hud:SetStatus("Waiting for players… bots fill empty slots")
		elseif data.PrivateServer then
			hud:SetStatus("Private server — start when ready")
		else
			hud:SetStatus(("Need %d+ players to start"):format(
				data.MinPlayersToStart or Config.MinPlayersToStart))
		end
	elseif stateName == "Countdown" then
		results:HideRoundEnd()
		results:HideMatchEnd()
		controls:SetCollapsed(true)
		hud:SetStatus("")
		hud:ShowCountdown(data.StartsIn or 3)
	elseif stateName == "RoundPlaying" then
		results:HideRoundEnd()
		results:HideMatchEnd()
		matchEndPayload = nil
		hud:SetStatus("")
		if data.Round then
			hud:SetRoundInfo(data.Round, data.RoundsPerMatch)
		end
		hud:SetTimeLeft(data.TimeLeft)
	elseif stateName == "RoundEnd" then
		results:HideMatchEnd()
		hud:SetStatus("Round over")
		-- panel content arrives via RoundEnded (fired just before this state)
	elseif stateName == "MatchEnd" then
		results:HideRoundEnd()
		hud:SetStatus("Match over")
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
-- Meta layer: rewards toast + hatchery snapshot
---------------------------------------------------------------------------

MatchRewards.OnClientEvent:Connect(function(rewards)
	if type(rewards) ~= "table" then
		return
	end
	toast(("Match rewards: +%d Clout, +%d Fragments (rank #%d)")
		:format(rewards.Clout or 0, rewards.Fragments or 0, rewards.Rank or 0),
		UiKit.Theme.Accent)
	if rewards.IsMVP then
		toast("MVP bonus: +" .. Config.Economy.CloutMVPBonus .. " Clout ★", UiKit.Theme.Good)
	end
	if rewards.PityEgg or rewards.EggGranted then
		toast("PITY UNLOCKED: a guaranteed-RARE egg was granted! Check the hatchery.",
			UiKit.Theme.Info)
	end
	if Config.DebugVerboseLogging then
		print(("[CTE] rewards: clout=+%d frags=+%d kd=%d steals=%d hold=%ds rank=%d mvp=%s pity=%s")
			:format(rewards.Clout or 0, rewards.Fragments or 0, rewards.Knockdowns or 0,
				rewards.Steals or 0, rewards.HoldSeconds or 0, rewards.Rank or 0,
				tostring(rewards.IsMVP), tostring(rewards.PityEgg)))
	end
end)

HatcheryUpdated.OnClientEvent:Connect(function(snapshot)
	hatchery:SetSnapshot(snapshot)
end)

---------------------------------------------------------------------------
-- FeedbackEvent: feed + toasts + cooldown wipes (success events only)
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
	elseif kind == "GripSave" then
		hud:PushFeed(("%s's pet GRIPPED the egg!"):format(
			UiKit.playerName(data.Player, "?")), UiKit.Theme.Good)
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

	-- Personal toasts (meta layer).
	if kind == "PetHatched" and data.Pet then
		local pet = data.Pet
		toast(("You hatched %s! (%s · %s · grip +%.1f%%)"):format(
			pet.Name or "a pet", pet.Rarity or "?", pet.Size or "?", pet.GripBonus or 0),
			UiKit.Theme.Accent)
	elseif kind == "EggGranted" then
		toast("You received an egg! Open it in the HATCHERY when it hatches.",
			UiKit.Theme.Info)
	elseif kind == "NotEnoughClout" then
		toast(("Not enough Clout (need %d, have %d)"):format(data.Need or 0, data.Have or 0),
			UiKit.Theme.Bad)
	elseif kind == "NotEnoughFragments" then
		toast(("Not enough fragments (need %d, have %d)"):format(data.Need or 0, data.Have or 0),
			UiKit.Theme.Bad)
	elseif kind == "EggNotReady" then
		toast("That egg is still hatching…", UiKit.Theme.Bad)
	elseif kind == "DataNotReady" then
		toast("Your profile is still loading — try again in a second.", UiKit.Theme.Info)
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
-- join if a match is already running, and pushes a HatcheryUpdated snapshot
-- as soon as the profile loads)
---------------------------------------------------------------------------

applyState("Lobby", { BotsEnabled = Config.Bots.Enabled })
task.delay(2, function()
	HatcheryRequest:FireServer("Refresh")
end)
