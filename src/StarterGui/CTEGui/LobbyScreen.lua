--[[
	LobbyScreen (ModuleScript inside StarterGui.CTEGui)
	===================================================
	The lobby screen: title, Play button, mode selector (FFA / 2v2v2),
	player count and a settings button.

	Presentation only -- the server decides when the match actually starts
	(MatchService auto-counts-down at MinPlayersToStart). The Play button and
	the 2v2v2 mode are placeholders that surface a toast via callbacks.

	Api:
	  LobbyScreen.Create(parentGui) -> screen
	  screen:SetVisible(bool)
	  screen:SetPlayerCount(count)
	  screen.OnPlay / screen.OnMode2v2v2 / screen.OnSettings   (callbacks)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local LobbyScreen = {}
LobbyScreen.__index = LobbyScreen

function LobbyScreen.Create(parentGui)
	local self = setmetatable({}, LobbyScreen)

	self.OnPlay = nil
	self.OnMode2v2v2 = nil
	self.OnSettings = nil

	self.root = UiKit.frame({
		Name = "LobbyScreen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.Theme.Background,
	}, parentGui)

	-- Title block
	UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.9, 0.14),
		Position = UDim2.fromScale(0.05, 0.10),
		Text = "CLUTCH THE EGG",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
	}, self.root)

	UiKit.label({
		Name = "Subtitle",
		Size = UDim2.fromScale(0.9, 0.05),
		Position = UDim2.fromScale(0.05, 0.245),
		Text = "Grab the egg. Hold it. Don't get caught.",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, self.root)

	-- Play button
	self.playButton = UiKit.button({
		Name = "PlayButton",
		Size = UDim2.fromScale(0.36, 0.10),
		Position = UDim2.fromScale(0.32, 0.42),
		Text = "PLAY",
		TextColor3 = UiKit.Theme.Background,
	}, self.root)
	self.playButton.BackgroundColor3 = UiKit.Theme.Accent
	UiKit.stroke(self.playButton, UiKit.Theme.AccentDark, 3)

	self.playHint = UiKit.label({
		Name = "PlayHint",
		Size = UDim2.fromScale(0.6, 0.035),
		Position = UDim2.fromScale(0.2, 0.53),
		Text = ("Auto-starts at %d+ players"):format(Config.MinPlayersToStart),
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, self.root)

	-- Mode selector (FFA selected; 2v2v2 is a placeholder)
	self.modeFrame = UiKit.frame({
		Name = "ModeSelector",
		Size = UDim2.fromScale(0.36, 0.07),
		Position = UDim2.fromScale(0.32, 0.60),
		BackgroundColor3 = UiKit.Theme.Panel,
	}, self.root)

	self.ffaButton = UiKit.button({
		Name = "FFA",
		Size = UDim2.fromScale(0.48, 0.84),
		Position = UDim2.fromScale(0.01, 0.08),
		Text = "FFA",
	}, self.modeFrame)

	self.teamButton = UiKit.button({
		Name = "Teams",
		Size = UDim2.fromScale(0.48, 0.84),
		Position = UDim2.fromScale(0.51, 0.08),
		Text = "2v2v2",
		TextColor3 = UiKit.Theme.TextDim,
	}, self.modeFrame)

	self:refreshModeButtons()

	-- Player count
	self.countLabel = UiKit.label({
		Name = "PlayerCount",
		Size = UDim2.fromScale(0.5, 0.055),
		Position = UDim2.fromScale(0.25, 0.72),
		Text = ("Players: 0/%d"):format(Config.MaxPlayers),
		Font = UiKit.Theme.FontMain,
	}, self.root)

	-- Controls hint (desktop testers)
	UiKit.label({
		Name = "ControlsHint",
		Size = UDim2.fromScale(0.94, 0.035),
		Position = UDim2.fromScale(0.03, 0.93),
		Text = "LMB attack  ·  Q/F throw  ·  RMB block (hold)  ·  E dash  ·  Shift sprint (hold)",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
	}, self.root)

	-- Settings button (top right)
	self.settingsButton = UiKit.button({
		Name = "SettingsButton",
		Size = UDim2.fromScale(0.075, 0.055),
		Position = UDim2.fromScale(0.905, 0.025),
		Text = "SET",
	}, self.root)

	-- Wiring
	self.playButton.Activated:Connect(function()
		if self.OnPlay then self.OnPlay() end
	end)
	self.teamButton.Activated:Connect(function()
		if self.OnMode2v2v2 then self.OnMode2v2v2() end
	end)
	self.ffaButton.Activated:Connect(function()
		self:refreshModeButtons() -- FFA is the only live mode for now
	end)
	self.settingsButton.Activated:Connect(function()
		if self.OnSettings then self.OnSettings() end
	end)

	return self
end

function LobbyScreen:refreshModeButtons()
	self.ffaButton.BackgroundColor3 = UiKit.Theme.Accent
	self.ffaButton.TextColor3 = UiKit.Theme.Background
	self.teamButton.BackgroundColor3 = UiKit.Theme.Button
	self.teamButton.TextColor3 = UiKit.Theme.TextDim
end

function LobbyScreen:SetVisible(visible)
	self.root.Visible = visible
end

function LobbyScreen:SetPlayerCount(count)
	self.countLabel.Text = ("Players: %d/%d"):format(count or 0, Config.MaxPlayers)
end

return LobbyScreen
