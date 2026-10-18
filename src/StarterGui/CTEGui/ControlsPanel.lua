--[[
	ControlsPanel (ModuleScript inside StarterGui.CTEGui)
	=====================================================
	The ONLY thing on screen in the lobby: a small, unobtrusive, collapsible
	controls list parked on the right side of the screen (no full-screen
	menus -- the match starts automatically).

	Api:
	  ControlsPanel.Create(parentGui) -> panel
	  panel:SetCollapsed(bool)
]]

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local ControlsPanel = {}
ControlsPanel.__index = ControlsPanel

local HEADER_HEIGHT = 0.05
local PANEL_WIDTH = 0.235

-- key, action pairs (keyboard/gamepad; mobile uses the on-screen buttons).
local CONTROLS = {
	{ "LMB · X", "Attack (no egg)" },
	{ "Q F · Y", "Throw (has egg)" },
	{ "RMB · L1", "Block (hold)" },
	{ "E · R1", "Dash" },
	{ "Shift · R2", "Sprint (hold)" },
	{ "Space", "Jump" },
}

function ControlsPanel.Create(parentGui)
	local self = setmetatable({}, ControlsPanel)

	self.root = UiKit.frame({
		Name = "ControlsPanel",
		Size = UDim2.fromScale(PANEL_WIDTH, 0.05 + 0.052 * (#CONTROLS + 1)),
		Position = UDim2.fromScale(1 - PANEL_WIDTH - 0.012, 0.30),
		BackgroundColor3 = UiKit.Theme.Panel,
		BackgroundTransparency = 0.3,
	}, parentGui)

	-- Header doubles as the collapse toggle.
	self.header = UiKit.button({
		Name = "Header",
		Size = UDim2.fromScale(1, HEADER_HEIGHT / self.root.Size.Y.Scale),
		Text = "CONTROLS  –",
		BackgroundColor3 = UiKit.Theme.Panel,
		BackgroundTransparency = 0.15,
		Font = UiKit.Theme.FontMain,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.root)
	UiKit.padding(self.header, 0.06)

	self.body = UiKit.frame({
		Name = "Body",
		Size = UDim2.fromScale(1, 1 - HEADER_HEIGHT / self.root.Size.Y.Scale),
		Position = UDim2.fromScale(0, HEADER_HEIGHT / self.root.Size.Y.Scale),
		BackgroundTransparency = 1,
	}, self.root)

	local rowHeight = 0.9 / #CONTROLS
	for index, control in ipairs(CONTROLS) do
		local rowY = (index - 1) * rowHeight
		UiKit.label({
			Name = "Key" .. index,
			Size = UDim2.fromScale(0.42, rowHeight * 0.8),
			Position = UDim2.fromScale(0.04, rowY + rowHeight * 0.1),
			Text = control[1],
			Font = UiKit.Theme.FontMain,
			TextColor3 = UiKit.Theme.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, self.body)
		UiKit.label({
			Name = "Action" .. index,
			Size = UDim2.fromScale(0.52, rowHeight * 0.8),
			Position = UDim2.fromScale(0.46, rowY + rowHeight * 0.1),
			Text = control[2],
			Font = UiKit.Theme.FontSoft,
			TextColor3 = UiKit.Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, self.body)
	end

	UiKit.label({
		Name = "Footer",
		Size = UDim2.fromScale(0.92, rowHeight * 0.8),
		Position = UDim2.fromScale(0.04, #CONTROLS * rowHeight + rowHeight * 0.1),
		Text = "Touch the egg to grab it!",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.body)

	self.collapsed = false
	self.expandedHeight = HEADER_HEIGHT + 0.052 * (#CONTROLS + 1)
	self.headerFraction = HEADER_HEIGHT / self.expandedHeight
	self.header.Activated:Connect(function()
		self:SetCollapsed(not self.collapsed)
	end)

	return self
end

function ControlsPanel:SetCollapsed(collapsed)
	self.collapsed = collapsed
	self.body.Visible = not collapsed
	self.header.Text = collapsed and "CONTROLS  +" or "CONTROLS  –"
	self.root.Size = collapsed
		and UDim2.fromScale(PANEL_WIDTH, HEADER_HEIGHT)
		or UDim2.fromScale(PANEL_WIDTH, self.expandedHeight)
	-- Collapsed: the header IS the whole panel. Expanded: just the top strip.
	self.header.Size = collapsed
		and UDim2.fromScale(1, 1)
		or UDim2.fromScale(1, self.headerFraction)
end

function ControlsPanel:SetVisible(visible)
	self.root.Visible = visible
end

return ControlsPanel
