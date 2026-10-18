--[[
	UiKit (ModuleScript inside StarterGui.CTEGui)
	=============================================
	Tiny helper library for building clean, mobile-friendly GUI in code.

	Rules enforced here:
	  * ALL sizes/positions use Scale only (UDim2.fromScale / UDim.fromScale)
	    so everything scales from phones to desktops. No Offset sizing.
	  * Every text element uses TextScaled = true.
	  * One shared Theme table -> restyling the whole game later = edit here.
]]

local TweenService = game:GetService("TweenService")

local UiKit = {}

---------------------------------------------------------------------------
-- Theme (restyle the whole game by editing this table)
---------------------------------------------------------------------------

UiKit.Theme = {
	Background = Color3.fromRGB(20, 22, 30),
	Panel = Color3.fromRGB(32, 35, 46),
	PanelAlt = Color3.fromRGB(43, 47, 61),
	Button = Color3.fromRGB(55, 60, 78),
	Accent = Color3.fromRGB(255, 200, 60),   -- egg gold
	AccentDark = Color3.fromRGB(122, 95, 32),
	Text = Color3.fromRGB(238, 240, 246),
	TextDim = Color3.fromRGB(158, 164, 180),
	Good = Color3.fromRGB(110, 210, 130),
	Bad = Color3.fromRGB(235, 95, 95),
	Info = Color3.fromRGB(95, 170, 255),
	Stamina = Color3.fromRGB(90, 200, 250),
	Disabled = Color3.fromRGB(26, 28, 36),
	Scrim = Color3.fromRGB(10, 11, 15),
	FontTitle = Enum.Font.GothamBlack,
	FontMain = Enum.Font.GothamBold,
	FontSoft = Enum.Font.Gotham,
	Corner = UDim.new(0.14, 0), -- scale-based rounding (no offsets)
}

---------------------------------------------------------------------------
-- Core helpers
---------------------------------------------------------------------------

local function withDefaults(defaults, overrides)
	local props = {}
	for key, value in pairs(defaults) do
		props[key] = value
	end
	for key, value in pairs(overrides or {}) do
		props[key] = value
	end
	return props
end

function UiKit.new(className, props, parent)
	local instance = Instance.new(className)
	for key, value in pairs(props or {}) do
		instance[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UiKit.corner(instance, radius)
	return UiKit.new("UICorner", { CornerRadius = radius or UiKit.Theme.Corner }, instance)
end

function UiKit.stroke(instance, color, thickness, transparency)
	return UiKit.new("UIStroke", {
		Color = color or UiKit.Theme.PanelAlt,
		Thickness = thickness or 2,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, instance)
end

function UiKit.frame(props, parent)
	local frame = UiKit.new("Frame", withDefaults({
		BackgroundColor3 = UiKit.Theme.Panel,
		BorderSizePixel = 0,
	}, props), parent)
	if frame.BackgroundTransparency == 0 then
		UiKit.corner(frame)
	end
	return frame
end

function UiKit.label(props, parent)
	return UiKit.new("TextLabel", withDefaults({
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		TextColor3 = UiKit.Theme.Text,
		Font = UiKit.Theme.FontMain,
		RichText = true,
		TextTruncate = Enum.TextTruncate.Ellipsis,
	}, props), parent)
end

function UiKit.button(props, parent)
	local button = UiKit.new("TextButton", withDefaults({
		BackgroundColor3 = UiKit.Theme.Button,
		BorderSizePixel = 0,
		Text = "",
		TextScaled = true,
		TextColor3 = UiKit.Theme.Text,
		Font = UiKit.Theme.FontMain,
		AutoButtonColor = true,
	}, props), parent)
	UiKit.corner(button)
	return button
end

-- Scale-only padding (UIPadding accepts UDim; scale works relative to parent).
function UiKit.padding(parent, all)
	return UiKit.new("UIPadding", {
		PaddingTop = UDim.new(all, 0),
		PaddingBottom = UDim.new(all, 0),
		PaddingLeft = UDim.new(all, 0),
		PaddingRight = UDim.new(all, 0),
	}, parent)
end

function UiKit.listLayout(parent, fillDirection, padding, horizontalAlign, verticalAlign)
	return UiKit.new("UIListLayout", {
		FillDirection = fillDirection or Enum.FillDirection.Vertical,
		Padding = UDim.new(padding or 0.02, 0),
		HorizontalAlignment = horizontalAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = verticalAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, parent)
end

function UiKit.tween(instance, time, props, style)
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance, info, props)
	tween:Play()
	return tween
end

-- A dark full-screen scrim used behind overlay panels.
function UiKit.scrim(parent, transparency)
	return UiKit.new("Frame", {
		Name = "Scrim",
		BackgroundColor3 = UiKit.Theme.Scrim,
		BackgroundTransparency = transparency or 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, parent)
end

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------

-- Display-friendly player name (instances may be nil in ghost standings).
function UiKit.playerName(playerOrNil, fallbackName)
	if playerOrNil then
		local displayName = playerOrNil.DisplayName
		if displayName and displayName ~= "" then
			return displayName
		end
		return playerOrNil.Name
	end
	return fallbackName or "?"
end

-- True when a GuiObject input should count as a "press" (mouse click/touch).
function UiKit.isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

return UiKit
