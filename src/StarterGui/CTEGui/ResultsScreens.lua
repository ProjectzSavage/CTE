--[[
	ResultsScreens (ModuleScript inside StarterGui.CTEGui)
	======================================================
	Round-end and match-end overlay panels. Pure presentation of the
	RoundEnded / MatchEnded remote payloads (built by ScoringService):

	  ShowRoundEnd(roundNumber, results)   -- winner + ranked round standings
	  ShowMatchEnd(finalStandings)         -- MVP banner + final standings
	                                        -- + Play Again / Back to Lobby

	The two bottom buttons are flow-cosmetic for now: the server returns to
	the lobby automatically after the intermission, so both simply close the
	panel (a ready-up system can wire them to real remotes later).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local ResultsScreens = {}
ResultsScreens.__index = ResultsScreens

local ROW_HEIGHT = 0.075

local function entryName(entry)
	return UiKit.playerName(entry.Player, entry.Name)
end

---------------------------------------------------------------------------
-- Generic ranked-rows panel builder
---------------------------------------------------------------------------

local function buildPanel(parentGui, panelName, size, position)
	local scrim = UiKit.scrim(parentGui, 0.45)
	scrim.Name = panelName .. "Scrim"
	scrim.Visible = false

	local panel = UiKit.frame({
		Name = panelName,
		Size = size,
		Position = position,
		BackgroundColor3 = UiKit.Theme.Panel,
		Visible = false,
	}, parentGui)
	UiKit.stroke(panel, UiKit.Theme.AccentDark, 3)

	return scrim, panel
end

local function makeRow(panel, index, columns, rowTop)
	local row = UiKit.frame({
		Name = "Row" .. index,
		Size = UDim2.fromScale(0.94, ROW_HEIGHT),
		Position = UDim2.fromScale(0.03, rowTop + (index - 1) * (ROW_HEIGHT + 0.012)),
		BackgroundColor3 = UiKit.Theme.PanelAlt,
		BackgroundTransparency = 0.35,
	}, panel)

	local labels = {}
	for columnIndex, column in ipairs(columns) do
		labels[columnIndex] = UiKit.label({
			Name = "Col" .. columnIndex,
			Size = UDim2.fromScale(column.width, 0.72),
			Position = UDim2.fromScale(column.x, 0.14),
			Text = "",
			Font = column.font or UiKit.Theme.FontSoft,
			TextColor3 = UiKit.Theme.Text,
			TextXAlignment = column.align or Enum.TextXAlignment.Left,
		}, row)
	end
	return row, labels
end

function ResultsScreens.Create(parentGui)
	local self = setmetatable({}, ResultsScreens)

	self.OnPlayAgain = nil
	self.OnBackToLobby = nil

	-------------------------------------------------------------------
	-- Round end panel
	-------------------------------------------------------------------
	self.roundScrim, self.roundPanel = buildPanel(
		parentGui, "RoundEndPanel",
		UDim2.fromScale(0.62, 0.62), UDim2.fromScale(0.19, 0.19)
	)

	self.roundTitle = UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.94, 0.10),
		Position = UDim2.fromScale(0.03, 0.03),
		Text = "ROUND",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
	}, self.roundPanel)

	self.roundWinner = UiKit.label({
		Name = "Winner",
		Size = UDim2.fromScale(0.94, 0.07),
		Position = UDim2.fromScale(0.03, 0.135),
		Text = "",
		Font = UiKit.Theme.FontMain,
	}, self.roundPanel)

	self.roundHeader, self.roundHeaderLabels = makeRow(self.roundPanel, 0, {
		{ x = 0.02, width = 0.08 },
		{ x = 0.11, width = 0.40 },
		{ x = 0.52, width = 0.16, align = Enum.TextXAlignment.Right },
		{ x = 0.69, width = 0.16, align = Enum.TextXAlignment.Right },
		{ x = 0.86, width = 0.12, align = Enum.TextXAlignment.Right },
	}, 0.215)
	self.roundHeader.BackgroundTransparency = 1
	self.roundHeaderLabels[1].Text = "#"
	self.roundHeaderLabels[2].Text = "PLAYER"
	self.roundHeaderLabels[3].Text = "ROUND"
	self.roundHeaderLabels[4].Text = "MATCH"
	self.roundHeaderLabels[5].Text = "WON"
	for _, label in ipairs(self.roundHeaderLabels) do
		label.TextColor3 = UiKit.Theme.TextDim
	end

	self.roundRows = {}
	for index = 1, 6 do
		local row, labels = makeRow(self.roundPanel, index, {
			{ x = 0.02, width = 0.08 },
			{ x = 0.11, width = 0.40 },
			{ x = 0.52, width = 0.16, align = Enum.TextXAlignment.Right },
			{ x = 0.69, width = 0.16, align = Enum.TextXAlignment.Right },
			{ x = 0.86, width = 0.12, align = Enum.TextXAlignment.Right },
		}, 0.215 + ROW_HEIGHT + 0.012)
		self.roundRows[index] = { row = row, labels = labels }
	end

	-------------------------------------------------------------------
	-- Match end panel
	-------------------------------------------------------------------
	self.matchScrim, self.matchPanel = buildPanel(
		parentGui, "MatchEndPanel",
		UDim2.fromScale(0.66, 0.78), UDim2.fromScale(0.17, 0.11)
	)

	UiKit.label({
		Name = "Title",
		Size = UDim2.fromScale(0.94, 0.085),
		Position = UDim2.fromScale(0.03, 0.025),
		Text = "MATCH OVER",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Accent,
	}, self.matchPanel)

	self.mvpBanner = UiKit.label({
		Name = "MVP",
		Size = UDim2.fromScale(0.94, 0.075),
		Position = UDim2.fromScale(0.03, 0.115),
		Text = "",
		Font = UiKit.Theme.FontTitle,
		TextColor3 = UiKit.Theme.Good,
	}, self.matchPanel)

	self.matchHeader, self.matchHeaderLabels = makeRow(self.matchPanel, 0, {
		{ x = 0.02, width = 0.08 },
		{ x = 0.11, width = 0.38 },
		{ x = 0.50, width = 0.22, align = Enum.TextXAlignment.Right },
		{ x = 0.73, width = 0.12, align = Enum.TextXAlignment.Right },
		{ x = 0.86, width = 0.12 },
	}, 0.20)
	self.matchHeader.BackgroundTransparency = 1
	self.matchHeaderLabels[1].Text = "#"
	self.matchHeaderLabels[2].Text = "PLAYER"
	self.matchHeaderLabels[3].Text = "TOTAL HOLD"
	self.matchHeaderLabels[4].Text = "WON"
	self.matchHeaderLabels[5].Text = ""
	for _, label in ipairs(self.matchHeaderLabels) do
		label.TextColor3 = UiKit.Theme.TextDim
	end

	self.matchRows = {}
	for index = 1, 6 do
		local row, labels = makeRow(self.matchPanel, index, {
			{ x = 0.02, width = 0.08 },
			{ x = 0.11, width = 0.38 },
			{ x = 0.50, width = 0.22, align = Enum.TextXAlignment.Right },
			{ x = 0.73, width = 0.12, align = Enum.TextXAlignment.Right },
			{ x = 0.86, width = 0.12 },
		}, 0.20 + ROW_HEIGHT + 0.012)
		self.matchRows[index] = { row = row, labels = labels }
	end

	-- Bottom buttons
	self.playAgainButton = UiKit.button({
		Name = "PlayAgain",
		Size = UDim2.fromScale(0.36, 0.085),
		Position = UDim2.fromScale(0.11, 0.875),
		Text = "PLAY AGAIN",
		TextColor3 = UiKit.Theme.Background,
	}, self.matchPanel)
	self.playAgainButton.BackgroundColor3 = UiKit.Theme.Accent

	self.backToLobbyButton = UiKit.button({
		Name = "BackToLobby",
		Size = UDim2.fromScale(0.36, 0.085),
		Position = UDim2.fromScale(0.53, 0.875),
		Text = "BACK TO LOBBY",
	}, self.matchPanel)

	self.playAgainButton.Activated:Connect(function()
		self:HideMatchEnd()
		if self.OnPlayAgain then self.OnPlayAgain() end
	end)
	self.backToLobbyButton.Activated:Connect(function()
		self:HideMatchEnd()
		if self.OnBackToLobby then self.OnBackToLobby() end
	end)

	return self
end

---------------------------------------------------------------------------
-- Round end
---------------------------------------------------------------------------

function ResultsScreens:ShowRoundEnd(roundNumber, results)
	self.roundTitle.Text = ("ROUND %d"):format(roundNumber or 0)

	if results.WinnerName then
		local tieText = results.Tied and "  (tie!)" or ""
		self.roundWinner.Text = ("Winner: %s — %.1fs hold%s"):format(
			UiKit.playerName(results.WinnerPlayer, results.WinnerName),
			results.TopTime or 0, tieText)
		self.roundWinner.TextColor3 = UiKit.Theme.Accent
	else
		self.roundWinner.Text = "Nobody held the egg — no winner"
		self.roundWinner.TextColor3 = UiKit.Theme.TextDim
	end

	for index, entry in ipairs(results.Entries or {}) do
		local row = self.roundRows[index]
		if row then
			row.labels[1].Text = tostring(index)
			row.labels[2].Text = entryName(entry)
			row.labels[3].Text = ("%.1fs"):format(entry.RoundTime or 0)
			row.labels[4].Text = ("%.1fs"):format(entry.MatchTime or 0)
			row.labels[5].Text = tostring(entry.RoundsWon or 0)

			if entry.IsWinner then
				row.row.BackgroundColor3 = UiKit.Theme.AccentDark
				row.row.BackgroundTransparency = 0.15
			else
				row.row.BackgroundColor3 = UiKit.Theme.PanelAlt
				row.row.BackgroundTransparency = 0.35
			end
			row.row.Visible = true
		end
	end
	for index = #(results.Entries or {}) + 1, #self.roundRows do
		self.roundRows[index].row.Visible = false
	end

	self.roundScrim.Visible = true
	self.roundPanel.Visible = true
end

function ResultsScreens:HideRoundEnd()
	self.roundScrim.Visible = false
	self.roundPanel.Visible = false
end

---------------------------------------------------------------------------
-- Match end
---------------------------------------------------------------------------

function ResultsScreens:ShowMatchEnd(final)
	if #final.MVPNames > 0 then
		self.mvpBanner.Text = ("★ MVP: %s — %.1fs total hold ★"):format(
			table.concat(final.MVPNames, " + "), final.BestTotalHoldTime or 0)
	else
		self.mvpBanner.Text = "★ MVP: nobody — no hold time recorded ★"
	end

	for index, entry in ipairs(final.Standings or {}) do
		local row = self.matchRows[index]
		if row then
			row.labels[1].Text = tostring(index)
			row.labels[2].Text = entryName(entry)
			row.labels[3].Text = ("%.1fs"):format(entry.TotalHoldTime or 0)
			row.labels[4].Text = tostring(entry.RoundsWon or 0)
			row.labels[5].Text = (entry.IsMVP and "★" or "") .. (entry.Left and "left" or "")
			row.labels[5].TextColor3 = entry.IsMVP and UiKit.Theme.Accent or UiKit.Theme.TextDim

			if entry.IsMVP then
				row.row.BackgroundColor3 = UiKit.Theme.AccentDark
				row.row.BackgroundTransparency = 0.1
			else
				row.row.BackgroundColor3 = UiKit.Theme.PanelAlt
				row.row.BackgroundTransparency = 0.35
			end
			row.row.Visible = true
		end
	end
	for index = #(final.Standings or {}) + 1, #self.matchRows do
		self.matchRows[index].row.Visible = false
	end

	self.matchScrim.Visible = true
	self.matchPanel.Visible = true
end

function ResultsScreens:HideMatchEnd()
	self.matchScrim.Visible = false
	self.matchPanel.Visible = false
end

return ResultsScreens
