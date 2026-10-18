--[[
	HudScreen (ModuleScript inside StarterGui.CTEGui)
	=================================================
	The in-match HUD:

	  * Round timer (big, center top) + "Round 1/3" indicator + countdown.
	  * Hold-time board: one row per arena slot (Config.MaxPlayers) with the
	    player's accumulated hold time, a relative fill bar, and a gold
	    highlight for the current carrier. Data comes straight from the
	    HoldTimeUpdated / EggPossessionChanged remotes -- no game logic here.
	  * Four ability buttons (ATTACK / THROW / BLOCK / DASH):
	      - contextual greying from the replicated HasEgg attribute
	        ("Hands Full" / "Need Egg")
	      - DASH greys out when the replicated Stamina attribute is below the
	        dash cost (carry-aware, costs read from Config = presentation only)
	      - cooldown wipe overlay, started from SUCCESS feedback events
	        (PunchSwing / DashStart) so keyboard users see it too
	      - BLOCK is a hold button (press/release callbacks)
	  * Stamina bar (rounded "Stamina" player attribute).
	  * Steal feed (GuiMain pushes strings from FeedbackEvent).

	All sizes are Scale-based; text is TextScaled (mobile-friendly).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local HudScreen = {}
HudScreen.__index = HudScreen

local ABILITY_ORDER = { "ATTACK", "THROW", "BLOCK", "DASH" }
local FEED_MAX = 4
local FEED_LIFETIME = 3.2

function HudScreen.Create(parentGui)
	local self = setmetatable({}, HudScreen)

	self.OnAbility = nil   -- GuiMain sets: function(abilityName, isDown)
	self.OnSettings = nil
	self.OnHatchery = nil

	self.carrier = nil
	self.holdTimes = {}    -- { [Player] = seconds } from HoldTimeUpdated
	self.hasEgg = false
	self.stamina = Config.StaminaMax
	self.abilities = {}

	self.root = UiKit.frame({
		Name = "HUD",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, parentGui)
	self.root.Visible = false

	-------------------------------------------------------------------
	-- Top center: timer + round indicator + countdown overlay
	-------------------------------------------------------------------
	self.timerLabel = UiKit.label({
		Name = "RoundTimer",
		Size = UDim2.fromScale(0.24, 0.085),
		Position = UDim2.fromScale(0.38, 0.012),
		Text = "--",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
	}, self.root)

	self.roundLabel = UiKit.label({
		Name = "RoundIndicator",
		Size = UDim2.fromScale(0.24, 0.035),
		Position = UDim2.fromScale(0.38, 0.10),
		Text = ("Round -/%d"):format(Config.RoundsPerMatch),
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, self.root)

	-- Lobby/flow status line (sits between the board and the corner buttons).
	self.statusLabel = UiKit.label({
		Name = "Status",
		Size = UDim2.fromScale(0.32, 0.035),
		Position = UDim2.fromScale(0.34, 0.138),
		Text = "",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, self.root)

	self.countdownLabel = UiKit.label({
		Name = "Countdown",
		Size = UDim2.fromScale(0.6, 0.22),
		Position = UDim2.fromScale(0.2, 0.30),
		Text = "",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
		Visible = false,
	}, self.root)

	-------------------------------------------------------------------
	-- Top left: hold-time board
	-------------------------------------------------------------------
	self.boardFrame = UiKit.frame({
		Name = "HoldTimeBoard",
		Size = UDim2.fromScale(0.31, 0.055 + 0.055 * Config.MaxPlayers),
		Position = UDim2.fromScale(0.015, 0.145),
		BackgroundColor3 = UiKit.Theme.Panel,
		BackgroundTransparency = 0.25,
	}, self.root)

	UiKit.label({
		Name = "Header",
		Size = UDim2.fromScale(0.96, 0.055 / (0.055 + 0.055 * Config.MaxPlayers)),
		Position = UDim2.fromScale(0.02, 0.008),
		Text = "HOLD TIME",
		Font = UiKit.Theme.FontMain,
		TextColor3 = UiKit.Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.boardFrame)

	self.rows = {}
	local rowHeight = 0.86 / Config.MaxPlayers -- share of board below the header
	for index = 1, Config.MaxPlayers do
		local rowY = 0.12 + (index - 1) * rowHeight
		local row = UiKit.frame({
			Name = "Row" .. index,
			Size = UDim2.fromScale(0.96, rowHeight * 0.86),
			Position = UDim2.fromScale(0.02, rowY),
			BackgroundColor3 = UiKit.Theme.PanelAlt,
			BackgroundTransparency = 0.55,
		}, self.boardFrame)

		local fill = UiKit.frame({
			Name = "Fill",
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = UiKit.Theme.AccentDark,
			BackgroundTransparency = 0.35,
		}, row)

		local nameLabel = UiKit.label({
			Name = "PlayerName",
			Size = UDim2.fromScale(0.62, 0.8),
			Position = UDim2.fromScale(0.025, 0.1),
			Text = "",
			Font = UiKit.Theme.FontMain,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)

		local timeLabel = UiKit.label({
			Name = "HoldTime",
			Size = UDim2.fromScale(0.3, 0.8),
			Position = UDim2.fromScale(0.68, 0.1),
			Text = "",
			Font = UiKit.Theme.FontMain,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, row)

		self.rows[index] = {
			frame = row,
			fill = fill,
			nameLabel = nameLabel,
			timeLabel = timeLabel,
		}
	end

	-------------------------------------------------------------------
	-- Left, under the board: steal/event feed
	-------------------------------------------------------------------
	self.feedFrame = UiKit.frame({
		Name = "Feed",
		Size = UDim2.fromScale(0.31, 0.20),
		Position = UDim2.fromScale(0.015, 0.145 + 0.075 + 0.055 * Config.MaxPlayers),
		BackgroundTransparency = 1,
	}, self.root)
	UiKit.listLayout(self.feedFrame, Enum.FillDirection.Vertical, 0.012)

	-------------------------------------------------------------------
	-- Bottom center (above the ability buttons): stamina bar.
	-- Kept OUT of the bottom-left corner on purpose: that is where the
	-- native mobile thumbstick lives.
	-------------------------------------------------------------------
	self.staminaFrame = UiKit.frame({
		Name = "StaminaBar",
		Size = UDim2.fromScale(0.24, 0.032),
		Position = UDim2.fromScale(0.38, 0.80),
		BackgroundColor3 = UiKit.Theme.Disabled,
	}, self.root)

	self.staminaFill = UiKit.frame({
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.Theme.Stamina,
	}, self.staminaFrame)

	self.staminaLabel = UiKit.label({
		Name = "Label",
		Size = UDim2.fromScale(0.96, 0.8),
		Position = UDim2.fromScale(0.02, 0.1),
		Text = "STAMINA",
		Font = UiKit.Theme.FontMain,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.staminaFrame)

	-------------------------------------------------------------------
	-- Bottom center: ability buttons
	-------------------------------------------------------------------
	self.abilitiesFrame = UiKit.frame({
		Name = "Abilities",
		Size = UDim2.fromScale(0.48, 0.14),
		Position = UDim2.fromScale(0.26, 0.845),
		BackgroundTransparency = 1,
	}, self.root)

	for index, abilityName in ABILITY_ORDER do
		self:createAbilityButton(index, abilityName)
	end

	-------------------------------------------------------------------
	-- Top right: settings gear (mobile players need mute mid-match)
	-------------------------------------------------------------------
	self.settingsButton = UiKit.button({
		Name = "SettingsButton",
		Size = UDim2.fromScale(0.075, 0.055),
		Position = UDim2.fromScale(0.905, 0.025),
		Text = "SET",
	}, self.root)
	self.settingsButton.Activated:Connect(function()
		if self.OnSettings then self.OnSettings() end
	end)

	-- Small hatchery button (the meta layer lives behind one click, not a
	-- full-screen lobby).
	self.hatcheryButton = UiKit.button({
		Name = "HatcheryButton",
		Size = UDim2.fromScale(0.09, 0.055),
		Position = UDim2.fromScale(0.805, 0.025),
		Text = "HATCHERY",
	}, self.root)
	self.hatcheryButton.Activated:Connect(function()
		if self.OnHatchery then self.OnHatchery() end
	end)

	-- Keep the roster rows fresh as players come and go.
	Players.PlayerAdded:Connect(function() self:refreshBoard() end)
	Players.PlayerRemoving:Connect(function() self:refreshBoard() end)

	-- Bots join/leave via Workspace.Bots (created by the server on demand).
	local function watchBotsFolder(folder)
		folder.ChildAdded:Connect(function() self:refreshBoard() end)
		folder.ChildRemoved:Connect(function() self:refreshBoard() end)
	end
	local botsFolder = Workspace:FindFirstChild("Bots")
	if botsFolder then
		watchBotsFolder(botsFolder)
	else
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Bots" then
				watchBotsFolder(child)
			end
		end)
	end

	self:refreshBoard()

	return self
end

---------------------------------------------------------------------------
-- Ability buttons
---------------------------------------------------------------------------

function HudScreen:createAbilityButton(index, abilityName)
	local slotWidth = 0.235
	local gap = (1 - slotWidth * 4) / 5
	local button = UiKit.button({
		Name = abilityName,
		Size = UDim2.fromScale(slotWidth, 0.92),
		Position = UDim2.fromScale(gap + (index - 1) * (slotWidth + gap), 0.04),
		Text = "",
		BackgroundColor3 = UiKit.Theme.Button,
	}, self.abilitiesFrame)
	UiKit.stroke(button, UiKit.Theme.PanelAlt, 2)

	local titleLabel = UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.92, 0.40),
		Position = UDim2.fromScale(0.04, 0.13),
		Text = abilityName,
		Font = UiKit.Theme.FontTitle,
	}, button)

	local stateLabel = UiKit.label({
		Name = "StateLabel",
		Size = UDim2.fromScale(0.96, 0.26),
		Position = UDim2.fromScale(0.02, 0.60),
		Text = "",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, button)

	-- Cooldown wipe: covers the button top-down, shrinks to nothing.
	local cooldown = UiKit.frame({
		Name = "Cooldown",
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
	}, button)

	local entry = {
		button = button,
		titleLabel = titleLabel,
		stateLabel = stateLabel,
		cooldown = cooldown,
		cooldownTween = nil,
		disabled = false,
	}
	self.abilities[abilityName] = entry

	-- Press (mouse down / touch begin) -> down; release -> up. GuiMain maps
	-- these to _G.CTEInput (one-shot abilities ignore isDown=false).
	button.InputBegan:Connect(function(input)
		if UiKit.isPress(input) then
			self:pressAbility(abilityName, true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if UiKit.isPress(input) then
			self:pressAbility(abilityName, false)
		end
	end)
end

function HudScreen:pressAbility(abilityName, isDown)
	if not self.OnAbility then
		return
	end
	if isDown and self.abilities[abilityName].disabled then
		return -- contextually unavailable: do not even send the request
	end
	self.OnAbility(abilityName, isDown)
end

function HudScreen:refreshAbilityStates()
	local attack = self.abilities["ATTACK"]
	local throw = self.abilities["THROW"]
	local dash = self.abilities["DASH"]

	-- Contextual rules (mirrors the server's validation for DISPLAY only).
	attack.disabled = self.hasEgg
	attack.stateLabel.Text = self.hasEgg and "Hands Full" or ""

	throw.disabled = not self.hasEgg
	throw.stateLabel.Text = self.hasEgg and "" or "Need Egg"

	local dashCost = self.hasEgg and Config.DashStaminaCostCarrying or Config.DashStaminaCost
	dash.disabled = self.stamina < dashCost
	dash.stateLabel.Text = dash.disabled and "No Stamina" or ""

	for _, entry in pairs(self.abilities) do
		if entry.disabled then
			entry.button.BackgroundColor3 = UiKit.Theme.Disabled
			entry.titleLabel.TextColor3 = UiKit.Theme.TextDim
		else
			entry.button.BackgroundColor3 = UiKit.Theme.Button
			entry.titleLabel.TextColor3 = UiKit.Theme.Text
		end
	end
end

-- Started by GuiMain from SUCCESS feedback (PunchSwing / DashStart), so the
-- wipe shows for keyboard players too. Purely visual; server stays authority.
function HudScreen:StartCooldown(abilityName, duration)
	local entry = self.abilities[abilityName]
	if not entry or not duration or duration <= 0 then
		return
	end
	if entry.cooldownTween then
		entry.cooldownTween:Cancel()
	end
	entry.cooldown.Visible = true
	entry.cooldown.Size = UDim2.fromScale(1, 1)
	entry.cooldownTween = TweenService:Create(
		entry.cooldown,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(1, 0) }
	)
	entry.cooldownTween.Completed:Connect(function()
		entry.cooldown.Visible = false
	end)
	entry.cooldownTween:Play()
end

---------------------------------------------------------------------------
-- State updates (all driven by remotes / replicated attributes)
---------------------------------------------------------------------------

function HudScreen:SetVisible(visible)
	self.root.Visible = visible
end

-- Small one-line status under the timer ("Waiting for players…", etc).
function HudScreen:SetStatus(text)
	self.statusLabel.Text = text or ""
end

function HudScreen:SetRoundInfo(roundNumber, roundsPerMatch)
	self.roundLabel.Text = ("Round %d/%d"):format(roundNumber, roundsPerMatch or Config.RoundsPerMatch)
end

function HudScreen:SetTimeLeft(seconds)
	self.countdownLabel.Visible = false
	if type(seconds) == "number" then
		self.timerLabel.Text = tostring(math.max(0, math.ceil(seconds)))
	end
end

function HudScreen:ShowCountdown(startsIn)
	if type(startsIn) ~= "number" then
		return
	end
	self.timerLabel.Text = "--"
	self.countdownLabel.Visible = true
	self.countdownLabel.Text = startsIn > 0 and tostring(startsIn) or "GO!"
end

function HudScreen:SetCarrier(carrierPlayerOrNil)
	self.carrier = carrierPlayerOrNil
	self:refreshBoard()
end

function HudScreen:UpdateHoldTimes(entries)
	self.holdTimes = {}
	if type(entries) == "table" then
		for _, entry in ipairs(entries) do
			if entry.Player then
				self.holdTimes[entry.Player] = entry.HoldTime or 0
			end
		end
	end
	self:refreshBoard()
end

function HudScreen:SetHasEgg(hasEgg)
	self.hasEgg = hasEgg and true or false
	self:refreshAbilityStates()
end

function HudScreen:SetStamina(value)
	self.stamina = tonumber(value) or 0
	local fraction = math.clamp(self.stamina / Config.StaminaMax, 0, 1)
	self.staminaFill.Size = UDim2.fromScale(fraction, 1)
	self.staminaLabel.Text = ("STAMINA %d"):format(math.floor(self.stamina + 0.5))
	-- Low stamina reads red.
	if fraction <= 0.25 then
		self.staminaFill.BackgroundColor3 = UiKit.Theme.Bad
	else
		self.staminaFill.BackgroundColor3 = UiKit.Theme.Stamina
	end
	self:refreshAbilityStates()
end

function HudScreen:refreshBoard()
	local localPlayer = Players.LocalPlayer

	-- Display list: players with hold time first (desc), then the rest of the
	-- roster (INCLUDING bots from Workspace.Bots), then empty arena slots.
	local list = {}
	local seen = {}
	local function addEntity(entity)
		if entity == nil or seen[entity] then
			return
		end
		if typeof(entity) == "Instance" and not entity.Parent then
			return -- despawned bot / left player
		end
		seen[entity] = true
		table.insert(list, {
			player = entity,
			time = self.holdTimes[entity] or 0,
		})
	end

	for _, player in ipairs(Players:GetPlayers()) do
		addEntity(player)
	end
	local botsFolder = Workspace:FindFirstChild("Bots")
	if botsFolder then
		for _, model in ipairs(botsFolder:GetChildren()) do
			if model:IsA("Model") then
				addEntity(model)
			end
		end
	end
	-- Anyone still holding time (e.g. a bot that just despawned mid-push).
	for entity in pairs(self.holdTimes) do
		addEntity(entity)
	end
	table.sort(list, function(a, b)
		if math.abs(a.time - b.time) > 0.005 then
			return a.time > b.time
		end
		return a.player.Name < b.player.Name
	end)

	local maxTime = list[1] and list[1].time or 0
	if maxTime < 1 then
		maxTime = 1 -- keeps the fill bar readable early in a round
	end

	for index, row in ipairs(self.rows) do
		local data = list[index]
		if data then
			local isCarrier = (data.player == self.carrier)
			local isLocal = (data.player == localPlayer)
			row.nameLabel.Text = UiKit.playerName(data.player) .. (isLocal and " (you)" or "")
			row.timeLabel.Text = ("%.1fs"):format(data.time)
			row.fill.Size = UDim2.fromScale(math.clamp(data.time / maxTime, 0, 1), 1)

			if isCarrier then
				row.frame.BackgroundColor3 = UiKit.Theme.Accent
				row.frame.BackgroundTransparency = 0.15
				row.nameLabel.TextColor3 = UiKit.Theme.Background
				row.timeLabel.TextColor3 = UiKit.Theme.Background
			else
				row.frame.BackgroundColor3 = UiKit.Theme.PanelAlt
				row.frame.BackgroundTransparency = 0.55
				row.nameLabel.TextColor3 = UiKit.Theme.Text
				row.timeLabel.TextColor3 = UiKit.Theme.TextDim
			end
		else
			row.nameLabel.Text = "—"
			row.timeLabel.Text = ""
			row.fill.Size = UDim2.fromScale(0, 1)
			row.frame.BackgroundColor3 = UiKit.Theme.PanelAlt
			row.frame.BackgroundTransparency = 0.75
			row.nameLabel.TextColor3 = UiKit.Theme.TextDim
		end
	end
end

---------------------------------------------------------------------------
-- Feed
---------------------------------------------------------------------------

function HudScreen:PushFeed(message, color)
	local label = UiKit.label({
		Name = "FeedMessage",
		Size = UDim2.fromScale(1, 0.2),
		Text = message,
		Font = UiKit.Theme.FontMain,
		TextColor3 = color or UiKit.Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		BackgroundTransparency = 1,
	}, self.feedFrame)

	-- Cap the stack: oldest messages go first (count labels, not the layout).
	local function countMessages()
		local count = 0
		for _, child in ipairs(self.feedFrame:GetChildren()) do
			if child:IsA("TextLabel") then
				count = count + 1
			end
		end
		return count
	end
	while countMessages() > FEED_MAX do
		local oldest = nil
		for _, child in ipairs(self.feedFrame:GetChildren()) do
			if child:IsA("TextLabel") then
				oldest = child
				break
			end
		end
		if not oldest then
			break
		end
		oldest:Destroy()
	end

	task.delay(FEED_LIFETIME, function()
		if label.Parent then
			UiKit.tween(label, 0.5, { TextTransparency = 1 })
			task.delay(0.55, function()
				label:Destroy()
			end)
		end
	end)
end

return HudScreen
