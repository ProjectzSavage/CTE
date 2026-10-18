--[[
	SettingsPanel (ModuleScript inside StarterGui.CTEGui)
	=====================================================
	Simple settings overlay:
	  * Mute toggle -- actually sets SoundService.Volume (0/1) for this client.
	  * Sensitivity stepper -- PLACEHOLDER: stores the value on _G.CTESettings
	    and does nothing else until camera/gameplay code consumes it later.

	Api:
	  SettingsPanel.Create(parentGui) -> panel
	  panel:Toggle() / panel:SetVisible(bool)
]]

local SoundService = game:GetService("SoundService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local SettingsPanel = {}
SettingsPanel.__index = SettingsPanel

function SettingsPanel.Create(parentGui)
	local self = setmetatable({}, SettingsPanel)

	self.muted = false
	self.sensitivity = 5

	_G.CTESettings = _G.CTESettings or {}
	_G.CTESettings.Sensitivity = self.sensitivity

	self.scrim = UiKit.scrim(parentGui, 0.5)
	self.scrim.Name = "SettingsScrim"
	self.scrim.Visible = false

	self.panel = UiKit.frame({
		Name = "SettingsPanel",
		Size = UDim2.fromScale(0.44, 0.46),
		Position = UDim2.fromScale(0.28, 0.27),
		BackgroundColor3 = UiKit.Theme.Panel,
		Visible = false,
	}, parentGui)
	UiKit.stroke(self.panel, UiKit.Theme.AccentDark, 3)

	UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.8, 0.12),
		Position = UDim2.fromScale(0.05, 0.04),
		Text = "SETTINGS",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
	}, self.panel)

	self.closeButton = UiKit.button({
		Name = "Close",
		Size = UDim2.fromScale(0.09, 0.10),
		Position = UDim2.fromScale(0.88, 0.035),
		Text = "X",
	}, self.panel)

	-- Mute row
	UiKit.label({
		Name = "SoundLabel",
		Size = UDim2.fromScale(0.45, 0.10),
		Position = UDim2.fromScale(0.05, 0.24),
		Text = "Sound",
		Font = UiKit.Theme.FontMain,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	self.muteButton = UiKit.button({
		Name = "MuteToggle",
		Size = UDim2.fromScale(0.4, 0.11),
		Position = UDim2.fromScale(0.55, 0.235),
		Text = "MUTE: OFF",
	}, self.panel)

	-- Sensitivity row (placeholder)
	UiKit.label({
		Name = "SensLabel",
		Size = UDim2.fromScale(0.45, 0.10),
		Position = UDim2.fromScale(0.05, 0.44),
		Text = "Sensitivity",
		Font = UiKit.Theme.FontMain,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	self.sensDown = UiKit.button({
		Name = "SensDown",
		Size = UDim2.fromScale(0.11, 0.11),
		Position = UDim2.fromScale(0.55, 0.435),
		Text = "-",
	}, self.panel)

	self.sensValue = UiKit.label({
		Name = "SensValue",
		Size = UDim2.fromScale(0.14, 0.10),
		Position = UDim2.fromScale(0.675, 0.44),
		Text = tostring(self.sensitivity),
	}, self.panel)

	self.sensUp = UiKit.button({
		Name = "SensUp",
		Size = UDim2.fromScale(0.11, 0.11),
		Position = UDim2.fromScale(0.83, 0.435),
		Text = "+",
	}, self.panel)

	UiKit.label({
		Name = "SensNote",
		Size = UDim2.fromScale(0.9, 0.08),
		Position = UDim2.fromScale(0.05, 0.58),
		Text = "Sensitivity is a placeholder — it is not wired to anything yet.",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
		TextWrapped = true,
	}, self.panel)

	-- Wiring
	self.closeButton.Activated:Connect(function()
		self:SetVisible(false)
	end)
	self.scrim.InputBegan:Connect(function(input)
		if UiKit.isPress(input) then
			self:SetVisible(false)
		end
	end)

	self.muteButton.Activated:Connect(function()
		self.muted = not self.muted
		self.muteButton.Text = self.muted and "MUTE: ON" or "MUTE: OFF"
		self.muteButton.BackgroundColor3 = self.muted
			and UiKit.Theme.Bad or UiKit.Theme.Button
		-- Real (client-local) mute:
		pcall(function()
			SoundService.Volume = self.muted and 0 or 1
		end)
	end)

	self.sensDown.Activated:Connect(function()
		self.sensitivity = math.max(1, self.sensitivity - 1)
		self:refreshSensitivity()
	end)
	self.sensUp.Activated:Connect(function()
		self.sensitivity = math.min(10, self.sensitivity + 1)
		self:refreshSensitivity()
	end)

	return self
end

function SettingsPanel:refreshSensitivity()
	self.sensValue.Text = tostring(self.sensitivity)
	_G.CTESettings = _G.CTESettings or {}
	_G.CTESettings.Sensitivity = self.sensitivity
	-- TODO(settings): consumed by camera/aim code in a later pass.
end

function SettingsPanel:SetVisible(visible)
	self.scrim.Visible = visible
	self.panel.Visible = visible
end

function SettingsPanel:Toggle()
	self:SetVisible(not self.panel.Visible)
end

return SettingsPanel
