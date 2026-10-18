--[[
	HatcheryPanel (ModuleScript inside StarterGui.CTEGui)
	=====================================================
	The meta-game panel, opened from the small HATCHERY button:

	  * Wallet row: Clout, Fragments (x/10), pity progress.
	  * BUY EGG (Clout) / CONVERT 10 FRAGMENTS buttons.
	  * Eggs in progress: hatch countdowns (computed from the server
	    snapshot's Now), OPEN button when ready.
	  * Pet collection: rarity-colored rows with size/mutation/grip and
	    EQUIP buttons (one equipped pet = its tiny capped grip bonus).

	Pure presentation + request buttons: every action goes through the
	HatcheryRequest RemoteEvent and the SERVER validates + answers with a
	fresh HatcheryUpdated snapshot. Nothing is computed locally except the
	countdown display.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Config"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HatcheryRequest = Remotes:WaitForChild("HatcheryRequest")

local HatcheryPanel = {}
HatcheryPanel.__index = HatcheryPanel

local RARITY_COLORS = {
	Common = Color3.fromRGB(158, 164, 180),
	Rare = Color3.fromRGB(95, 170, 255),
	Epic = Color3.fromRGB(180, 100, 255),
	Legendary = Color3.fromRGB(255, 165, 60),
	Mythic = Color3.fromRGB(255, 85, 120),
}

local function request(action, id)
	HatcheryRequest:FireServer(action, id)
end

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

function HatcheryPanel.Create(parentGui)
	local self = setmetatable({}, HatcheryPanel)
	self.snapshot = nil
	self.receivedAt = 0

	self.scrim = UiKit.scrim(parentGui, 0.5)
	self.scrim.Name = "HatcheryScrim"
	self.scrim.Visible = false

	self.panel = UiKit.frame({
		Name = "HatcheryPanel",
		Size = UDim2.fromScale(0.58, 0.74),
		Position = UDim2.fromScale(0.21, 0.13),
		BackgroundColor3 = UiKit.Theme.Panel,
		Visible = false,
	}, parentGui)
	UiKit.stroke(self.panel, UiKit.Theme.AccentDark, 3)

	UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.6, 0.075),
		Position = UDim2.fromScale(0.04, 0.02),
		Text = "HATCHERY",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	self.closeButton = UiKit.button({
		Name = "Close",
		Size = UDim2.fromScale(0.07, 0.06),
		Position = UDim2.fromScale(0.91, 0.02),
		Text = "X",
	}, self.panel)
	self.closeButton.Activated:Connect(function()
		self:SetVisible(false)
	end)
	self.scrim.InputBegan:Connect(function(input)
		if UiKit.isPress(input) then
			self:SetVisible(false)
		end
	end)

	-- Wallet row
	self.walletLabel = UiKit.label({
		Name = "Wallet",
		Size = UDim2.fromScale(0.92, 0.05),
		Position = UDim2.fromScale(0.04, 0.10),
		Text = "Loading…",
		Font = UiKit.Theme.FontMain,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	-- Action buttons
	self.buyButton = UiKit.button({
		Name = "BuyEgg",
		Size = UDim2.fromScale(0.44, 0.065),
		Position = UDim2.fromScale(0.04, 0.165),
		Text = ("BUY EGG — %d CLOUT"):format(Config.Economy.EggCloutCost),
	}, self.panel)
	self.buyButton.Activated:Connect(function()
		request("BuyEgg")
	end)

	self.convertButton = UiKit.button({
		Name = "ConvertFragments",
		Size = UDim2.fromScale(0.44, 0.065),
		Position = UDim2.fromScale(0.52, 0.165),
		Text = ("CONVERT %d FRAGMENTS"):format(Config.Economy.EggFragmentCost),
	}, self.panel)
	self.convertButton.Activated:Connect(function()
		request("ConvertFragments")
	end)

	-- Eggs section
	UiKit.label({
		Name = "EggsHeader",
		Size = UDim2.fromScale(0.92, 0.04),
		Position = UDim2.fromScale(0.04, 0.245),
		Text = "EGGS",
		Font = UiKit.Theme.FontMain,
		TextColor3 = UiKit.Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	self.eggsFrame = UiKit.new("ScrollingFrame", {
		Name = "Eggs",
		Size = UDim2.fromScale(0.92, 0.17),
		Position = UDim2.fromScale(0.04, 0.285),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, self.panel)
	UiKit.listLayout(self.eggsFrame, Enum.FillDirection.Vertical, 0.04)

	-- Pets section
	self.petsHeader = UiKit.label({
		Name = "PetsHeader",
		Size = UDim2.fromScale(0.92, 0.04),
		Position = UDim2.fromScale(0.04, 0.47),
		Text = "PETS",
		Font = UiKit.Theme.FontMain,
		TextColor3 = UiKit.Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	self.petsFrame = UiKit.new("ScrollingFrame", {
		Name = "Pets",
		Size = UDim2.fromScale(0.92, 0.40),
		Position = UDim2.fromScale(0.04, 0.51),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, self.panel)
	UiKit.listLayout(self.petsFrame, Enum.FillDirection.Vertical, 0.025)

	self.noteLabel = UiKit.label({
		Name = "Note",
		Size = UDim2.fromScale(0.92, 0.035),
		Position = UDim2.fromScale(0.04, 0.945),
		Text = "",
		Font = UiKit.Theme.FontSoft,
		TextColor3 = UiKit.Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.panel)

	-- 1 Hz countdown refresh while open.
	task.spawn(function()
		while true do
			task.wait(1)
			if self.panel.Visible and self.snapshot then
				self:renderEggs()
			end
		end
	end)

	return self
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function HatcheryPanel:serverNow()
	-- Snapshot's Now + time elapsed on this client since it arrived.
	return (self.snapshot and self.snapshot.Now or os.time())
		+ math.floor(tick() - self.receivedAt)
end

function HatcheryPanel:renderEggs()
	local snap = self.snapshot
	if not snap then
		return
	end
	clearChildren(self.eggsFrame)

	if #snap.Eggs == 0 then
		UiKit.label({
			Size = UDim2.fromScale(1, 0.4),
			Text = "No eggs yet — buy one or convert fragments!",
			Font = UiKit.Theme.FontSoft,
			TextColor3 = UiKit.Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, self.eggsFrame)
		return
	end

	local serverNow = self:serverNow()
	for _, egg in ipairs(snap.Eggs) do
		local row = UiKit.frame({
			Name = "Egg_" .. tostring(egg.Id),
			Size = UDim2.fromScale(1, 0.4),
			BackgroundColor3 = UiKit.Theme.PanelAlt,
			BackgroundTransparency = 0.35,
		}, self.eggsFrame)

		local title = egg.GuaranteedRare and "RARE Egg" or "Mystery Egg"
		UiKit.label({
			Size = UDim2.fromScale(0.5, 0.7),
			Position = UDim2.fromScale(0.03, 0.15),
			Text = ("%s  <font color='#9ea4b4'>(%s)</font>"):format(title, tostring(egg.Source)),
			Font = UiKit.Theme.FontMain,
			TextColor3 = egg.GuaranteedRare and RARITY_COLORS.Rare or UiKit.Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)

		local remaining = (egg.UnlocksAt or 0) - serverNow
		if remaining > 0 then
			UiKit.label({
				Size = UDim2.fromScale(0.4, 0.7),
				Position = UDim2.fromScale(0.57, 0.15),
				Text = ("hatching… %d:%02d"):format(
					math.floor(remaining / 60), remaining % 60),
				Font = UiKit.Theme.FontSoft,
				TextColor3 = UiKit.Theme.TextDim,
				TextXAlignment = Enum.TextXAlignment.Right,
			}, row)
		else
			local openButton = UiKit.button({
				Size = UDim2.fromScale(0.38, 0.72),
				Position = UDim2.fromScale(0.59, 0.14),
				Text = "OPEN",
				TextColor3 = UiKit.Theme.Background,
			}, row)
			openButton.BackgroundColor3 = UiKit.Theme.Accent
			openButton.Activated:Connect(function()
				request("OpenEgg", egg.Id)
			end)
		end
	end
end

function HatcheryPanel:renderPets()
	local snap = self.snapshot
	if not snap then
		return
	end
	clearChildren(self.petsFrame)
	self.petsHeader.Text = ("PETS (%d)"):format(#snap.Pets)

	if #snap.Pets == 0 then
		UiKit.label({
			Size = UDim2.fromScale(1, 0.15),
			Text = "No pets yet — hatch an egg!",
			Font = UiKit.Theme.FontSoft,
			TextColor3 = UiKit.Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, self.petsFrame)
		return
	end

	for _, pet in ipairs(snap.Pets) do
		local row = UiKit.frame({
			Name = "Pet_" .. tostring(pet.Id),
			Size = UDim2.fromScale(1, 0.2),
			BackgroundColor3 = UiKit.Theme.PanelAlt,
			BackgroundTransparency = 0.35,
		}, self.petsFrame)

		UiKit.label({
			Size = UDim2.fromScale(0.42, 0.7),
			Position = UDim2.fromScale(0.03, 0.15),
			Text = pet.Name or "?",
			Font = UiKit.Theme.FontMain,
			TextColor3 = RARITY_COLORS[pet.Rarity] or UiKit.Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)

		local details = pet.Rarity .. " · " .. tostring(pet.Size)
		if pet.Mutation then
			details = details .. " · " .. pet.Mutation
		end
		details = details .. (" · grip +%.1f%%"):format(pet.GripBonus or 0)
		UiKit.label({
			Size = UDim2.fromScale(0.36, 0.7),
			Position = UDim2.fromScale(0.44, 0.15),
			Text = details,
			Font = UiKit.Theme.FontSoft,
			TextColor3 = UiKit.Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)

		local equipped = (snap.EquippedPetId == pet.Id)
		local equipButton = UiKit.button({
			Size = UDim2.fromScale(0.16, 0.72),
			Position = UDim2.fromScale(0.82, 0.14),
			Text = equipped and "ON" or "EQUIP",
		}, row)
		if equipped then
			equipButton.BackgroundColor3 = UiKit.Theme.Good
			equipButton.TextColor3 = UiKit.Theme.Background
			equipButton.AutoButtonColor = false
		else
			equipButton.Activated:Connect(function()
				request("EquipPet", pet.Id)
			end)
		end
	end
end

function HatcheryPanel:SetSnapshot(snapshot)
	self.snapshot = snapshot
	self.receivedAt = tick()
	if not snapshot then
		self.walletLabel.Text = "Loading…"
		return
	end
	self.walletLabel.Text = ("Clout: %d    Fragments: %d/%d    Pity: %d/%d"):format(
		snapshot.Clout, snapshot.Fragments, Config.Economy.EggFragmentCost,
		snapshot.PityProgress and snapshot.PityProgress.SinceRoundWin or 0,
		snapshot.PityProgress and snapshot.PityProgress.Needed
			or Config.Economy.PityMatchesWithoutRoundWin)
	self.noteLabel.Text = snapshot.StoreOK and ""
		or "Data is TEMPORARY this session (DataStore unavailable)."
	if self.panel.Visible then
		self:renderEggs()
		self:renderPets()
	end
end

function HatcheryPanel:SetVisible(visible)
	self.scrim.Visible = visible
	self.panel.Visible = visible
	if visible then
		self:renderEggs()
		self:renderPets()
		request("Refresh") -- make sure we show fresh numbers
	end
end

function HatcheryPanel:Toggle()
	self:SetVisible(not self.panel.Visible)
end

return HatcheryPanel
