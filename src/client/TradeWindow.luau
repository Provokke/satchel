--!strict
-- Trade UI: a player picker, an incoming-request banner, and the two-sided offer window with a
-- confirm button and the countdown. Like the grid, it only sends intent and redraws from Sync.
local RunService = game:GetService("RunService")

local TradeWindow = {}
TradeWindow.__index = TradeWindow

type Stack = { id: string, count: number }

export type Deps = {
	theme: any,
	parent: Instance,
	items: any, -- Config.Items
	listPlayers: () -> { { id: number, name: string } }, -- everyone except the local player
	send: (action: string, a: any?, b: any?, c: any?) -> (),
}

export type TradeWindow = typeof(setmetatable(
	{} :: {
		deps: Deps,
		window: Frame,
		title: TextLabel,
		mineList: Frame,
		theirsList: Frame,
		mineHeader: TextLabel,
		theirsHeader: TextLabel,
		confirm: TextButton,
		status: TextLabel,
		banner: Frame,
		bannerText: TextLabel,
		picker: Frame,
		countdownEnd: number?,
		iConfirmed: boolean,
		hideToken: number,
		finished: boolean, -- the closing message is showing
	},
	TradeWindow
))

local REASONS: { [string]: string } = {
	changed = "Something changed, so the trade was cancelled.",
	left = "The other player left.",
	distance = "You moved too far apart.",
	cancelled = "The trade was cancelled.",
}

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function listLayout(parent: Instance, padding: number)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
end

local function column(deps: Deps, parent: Instance, xScale: number): (Frame, TextLabel)
	local theme = deps.theme
	local holder = Instance.new("Frame")
	holder.Position = UDim2.new(xScale, if xScale == 0 then 12 else 6, 0, 44)
	holder.Size = UDim2.new(0.5, -18, 1, -130)
	holder.Parent = parent
	theme.style(holder, theme.background)
	local header = theme.label(holder, "", 14, theme.muted)
	header.Position = UDim2.fromOffset(8, 4)
	header.Size = UDim2.new(1, -16, 0, 18)
	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(8, 26)
	list.Size = UDim2.new(1, -16, 1, -32)
	list.Parent = holder
	listLayout(list, 4)
	return list, header
end

function TradeWindow.new(deps: Deps): TradeWindow
	local theme = deps.theme

	local window = Instance.new("Frame")
	window.Name = "Trade"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.4)
	window.Size = UDim2.fromOffset(460, 330)
	window.Visible = false
	window.Parent = deps.parent
	theme.style(window, theme.panel)

	local title = theme.label(window, "Trade", 18)
	title.FontFace = theme.fontBold
	title.Position = UDim2.fromOffset(14, 10)
	title.Size = UDim2.new(1, -28, 0, 24)

	local mineList, mineHeader = column(deps, window, 0)
	local theirsList, theirsHeader = column(deps, window, 0.5)

	local status = theme.label(window, "Click items in your bag to add them to your offer.", 14, theme.muted)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 14, 1, -54)
	status.Size = UDim2.new(1, -28, 0, 18)

	local confirm = theme.button(window, "Confirm", theme.accent)
	confirm.AnchorPoint = Vector2.new(0, 1)
	confirm.Position = UDim2.new(0, 12, 1, -12)
	confirm.Size = UDim2.new(0.5, -18, 0, 34)

	local cancel = theme.button(window, "Cancel")
	cancel.AnchorPoint = Vector2.new(1, 1)
	cancel.Position = UDim2.new(1, -12, 1, -12)
	cancel.Size = UDim2.new(0.5, -18, 0, 34)

	-- Incoming request banner.
	local banner = Instance.new("Frame")
	banner.Name = "TradeRequest"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 16)
	banner.Size = UDim2.fromOffset(340, 50)
	banner.Visible = false
	banner.Parent = deps.parent
	theme.style(banner, theme.panel, theme.accent)
	local bannerText = theme.label(banner, "", 15)
	bannerText.Position = UDim2.fromOffset(12, 0)
	bannerText.Size = UDim2.new(1, -150, 1, 0)
	bannerText.TextTruncate = Enum.TextTruncate.AtEnd
	local accept = theme.button(banner, "Accept", theme.good)
	accept.AnchorPoint = Vector2.new(1, 0.5)
	accept.Position = UDim2.new(1, -74, 0.5, 0)
	accept.Size = UDim2.fromOffset(64, 30)
	local decline = theme.button(banner, "Decline")
	decline.AnchorPoint = Vector2.new(1, 0.5)
	decline.Position = UDim2.new(1, -8, 0.5, 0)
	decline.Size = UDim2.fromOffset(64, 30)

	-- Player picker, opened from the bag's Trade button.
	local picker = Instance.new("Frame")
	picker.Name = "TradePicker"
	picker.AnchorPoint = Vector2.new(0.5, 0.5)
	picker.Position = UDim2.fromScale(0.5, 0.4)
	picker.Size = UDim2.fromOffset(260, 220)
	picker.Visible = false
	picker.Parent = deps.parent
	theme.style(picker, theme.panel)
	local pickerTitle = theme.label(picker, "Trade with", 16)
	pickerTitle.FontFace = theme.fontBold
	pickerTitle.Position = UDim2.fromOffset(12, 8)
	pickerTitle.Size = UDim2.new(1, -24, 0, 22)
	local pickerList = Instance.new("Frame")
	pickerList.Name = "List"
	pickerList.BackgroundTransparency = 1
	pickerList.Position = UDim2.fromOffset(12, 36)
	pickerList.Size = UDim2.new(1, -24, 1, -48)
	pickerList.Parent = picker
	listLayout(pickerList, 4)

	local self = setmetatable({
		deps = deps,
		window = window,
		title = title,
		mineList = mineList,
		theirsList = theirsList,
		mineHeader = mineHeader,
		theirsHeader = theirsHeader,
		confirm = confirm,
		status = status,
		banner = banner,
		bannerText = bannerText,
		picker = picker,
		countdownEnd = nil,
		iConfirmed = false,
		hideToken = 0,
		finished = false,
	}, TradeWindow)

	confirm.Activated:Connect(function()
		deps.send("tradeConfirm", not self.iConfirmed)
	end)
	cancel.Activated:Connect(function()
		deps.send("tradeCancel")
	end)
	accept.Activated:Connect(function()
		deps.send("tradeRespond", true)
	end)
	decline.Activated:Connect(function()
		deps.send("tradeRespond", false)
	end)

	RunService.RenderStepped:Connect(function()
		local finish = self.countdownEnd
		if finish ~= nil then
			local left = math.max(0, math.ceil(finish - os.clock()))
			self.status.Text = `Both confirmed. Trading in {left}...`
			self.status.TextColor3 = theme.good
		end
	end)

	return self
end

-- Called from the bag's Trade button.
function TradeWindow.togglePicker(self: TradeWindow)
	local deps = self.deps
	local picker = self.picker
	picker.Visible = not picker.Visible
	if not picker.Visible then
		return
	end
	local list = picker:FindFirstChild("List") :: Frame
	clear(list)
	local others = deps.listPlayers()
	if #others == 0 then
		local none = deps.theme.label(list, "No one else is here yet.", 14, deps.theme.muted)
		none.Size = UDim2.new(1, 0, 0, 20)
		return
	end
	for index, other in others do
		local button = deps.theme.button(list, other.name)
		button.LayoutOrder = index
		button.Size = UDim2.new(1, 0, 0, 30)
		button.Activated:Connect(function()
			picker.Visible = false
			deps.send("tradeRequest", other.id)
		end)
	end
end

local function drawOffers(self: TradeWindow, container: Frame, stacks: { Stack }, mine: boolean)
	local deps = self.deps
	local theme = deps.theme
	clear(container)
	for index, stack in stacks do
		local def = deps.items[stack.id]
		local row = Instance.new("Frame")
		row.LayoutOrder = index
		row.Size = UDim2.new(1, 0, 0, 26)
		row.Parent = container
		theme.style(row, theme.cell)
		local swatch = Instance.new("Frame")
		swatch.Position = UDim2.fromOffset(6, 5)
		swatch.Size = UDim2.fromOffset(16, 16)
		swatch.Parent = row
		theme.style(swatch, theme.colour(if def then def.colour else nil))
		local text = theme.label(row, `{if def then def.name else stack.id} x{stack.count}`, 14)
		text.Position = UDim2.fromOffset(30, 0)
		text.Size = UDim2.new(1, -62, 1, 0)
		if mine then
			local remove = theme.button(row, "x")
			remove.AnchorPoint = Vector2.new(1, 0.5)
			remove.Position = UDim2.new(1, -4, 0.5, 0)
			remove.Size = UDim2.fromOffset(22, 20)
			remove.Activated:Connect(function()
				deps.send("tradeRetract", index)
			end)
		end
	end
end

-- Redraws from a Sync. `view` is { trade, request, sentTo } as the server built it.
function TradeWindow.update(self: TradeWindow, view: any)
	local theme = self.deps.theme

	local request = view.request
	self.banner.Visible = request ~= nil
	if request ~= nil then
		self.bannerText.Text = `{request.fromName} wants to trade`
	end

	local trade = view.trade
	if trade == nil then
		if not self.finished then
			self.window.Visible = false
		end
		self.countdownEnd = nil
		self.iConfirmed = false
		return
	end

	self.hideToken += 1
	self.finished = false
	self.window.Visible = true
	self.picker.Visible = false
	self.title.Text = `Trading with {trade.withName}`
	self.mineHeader.Text = "Your offer"
	self.theirsHeader.Text = `{trade.withName}'s offer`
	drawOffers(self, self.mineList, trade.mine, true)
	drawOffers(self, self.theirsList, trade.theirs, false)
	self.iConfirmed = trade.iConfirmed == true

	if trade.state == "done" or trade.state == "cancelled" then
		self.countdownEnd = nil
		self.finished = true
		self.confirm.Active = false
		if trade.state == "done" then
			self.status.Text = "Trade complete."
			self.status.TextColor3 = theme.good
		else
			self.status.Text = REASONS[trade.reason or "cancelled"] or REASONS.cancelled
			self.status.TextColor3 = theme.bad
		end
		local token = self.hideToken
		task.delay(2.5, function()
			if self.hideToken == token then
				self.finished = false
				self.window.Visible = false
			end
		end)
		return
	end

	self.confirm.Active = true
	if trade.state == "countdown" and trade.secondsLeft ~= nil then
		self.countdownEnd = os.clock() + trade.secondsLeft
		self.confirm.Text = "Cancel confirmation"
		return
	end
	self.countdownEnd = nil
	if trade.iConfirmed and not trade.theyConfirmed then
		self.confirm.Text = "Waiting for them..."
		self.status.Text = "You have confirmed. Changing the offer clears both confirmations."
		self.status.TextColor3 = theme.muted
	elseif trade.theyConfirmed and not trade.iConfirmed then
		self.confirm.Text = "Confirm"
		self.status.Text = `{trade.withName} has confirmed.`
		self.status.TextColor3 = theme.accent
	else
		self.confirm.Text = "Confirm"
		self.status.Text = "Click items in your bag to add them to your offer."
		self.status.TextColor3 = theme.muted
	end
end

return TradeWindow
