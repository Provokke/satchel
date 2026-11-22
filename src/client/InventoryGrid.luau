--!strict
-- The bag and the equip slots. Dragging is done with UserInputService so it works the same for
-- mouse and touch. Every drop only sends intent to the server; the grid redraws from the next
-- Sync, never from its own guess.
local UserInputService = game:GetService("UserInputService")

local InventoryGrid = {}
InventoryGrid.__index = InventoryGrid

type Stack = { id: string, count: number }

export type Deps = {
	theme: any,
	parent: Instance,
	dragLayer: Instance, -- a ScreenGui that draws above everything, for the drag ghost
	items: any, -- Config.Items
	capacity: number,
	equipSlots: { string },
	onMove: (from: number, to: number) -> (),
	onSplit: (from: number, count: number, to: number) -> (),
	onEquip: (from: number) -> (),
	onUnequip: (slot: string) -> (),
	onClick: (slot: number, shift: boolean) -> (), -- a click that did not turn into a drag
	onTrade: () -> (), -- the "Trade" button
}

type Cell = { frame: Frame, swatch: Frame, name: TextLabel, count: TextLabel }

type Drag = {
	slot: number?, -- bag slot being dragged, or nil for an equip slot
	equip: string?, -- equip slot being dragged
	ghost: Frame,
	start: Vector2,
	moved: boolean,
	split: boolean,
}

export type InventoryGrid = typeof(setmetatable(
	{} :: {
		deps: Deps,
		root: Frame,
		cells: { [number]: Cell },
		equipCells: { [string]: Cell },
		slots: { [number]: Stack },
		equipped: { [string]: string },
		drag: Drag?,
		notice: TextLabel,
		viewOnly: boolean,
		flashToken: number,
		flashing: boolean,
	},
	InventoryGrid
))

local CELL = 64
local PAD = 6
local COLUMNS = 6
local DRAG_THRESHOLD = 6 -- pixels before a press counts as a drag rather than a click
local FLASH_SECONDS = 4
local VIEW_ONLY_TEXT = "View-only: this server can't save your bag, so nothing can change or be traded here."

local function makeCell(deps: Deps, parent: Instance, size: number): Cell
	local theme = deps.theme
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(size, size)
	frame.Active = true
	frame.Parent = parent
	theme.style(frame, theme.cell)

	local swatch = Instance.new("Frame")
	swatch.AnchorPoint = Vector2.new(0.5, 0)
	swatch.Position = UDim2.new(0.5, 0, 0, 8)
	swatch.Size = UDim2.fromOffset(size - 32, size - 32)
	swatch.Visible = false
	swatch.Parent = frame
	theme.style(swatch, theme.muted, theme.stroke)

	local name = theme.label(frame, "", 12, theme.muted)
	name.AnchorPoint = Vector2.new(0, 1)
	name.Position = UDim2.new(0, 4, 1, -2)
	name.Size = UDim2.new(1, -8, 0, 14)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local count = theme.label(frame, "", 13, theme.text)
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.new(1, -5, 0, 3)
	count.Size = UDim2.fromOffset(34, 14)
	count.TextXAlignment = Enum.TextXAlignment.Right

	return { frame = frame, swatch = swatch, name = name, count = count }
end

local function inside(frame: GuiObject, point: Vector2): boolean
	local position, size = frame.AbsolutePosition, frame.AbsoluteSize
	return point.X >= position.X
		and point.X <= position.X + size.X
		and point.Y >= position.Y
		and point.Y <= position.Y + size.Y
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

function InventoryGrid.new(deps: Deps): InventoryGrid
	local theme = deps.theme
	local rows = math.ceil(deps.capacity / COLUMNS)

	local root = Instance.new("Frame")
	root.Name = "Bag"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -16)
	root.Size = UDim2.fromOffset(COLUMNS * (CELL + PAD) + PAD, rows * (CELL + PAD) + PAD + 92)
	root.Parent = deps.parent
	theme.style(root, theme.panel)

	local title = theme.label(root, "Satchel", 18)
	title.FontFace = theme.fontBold
	title.Position = UDim2.fromOffset(PAD + 4, 6)
	title.Size = UDim2.fromOffset(120, 22)

	-- One line above the panel for messages from the server.
	local notice = theme.label(root, "", 14, theme.bad)
	notice.AnchorPoint = Vector2.new(0, 1)
	notice.Position = UDim2.new(0, 0, 0, -6)
	notice.Size = UDim2.new(1, 0, 0, 36)
	notice.TextWrapped = true
	notice.TextXAlignment = Enum.TextXAlignment.Center
	notice.Visible = false

	local tradeButton = theme.button(root, "Trade")
	tradeButton.AnchorPoint = Vector2.new(1, 0)
	tradeButton.Position = UDim2.new(1, -PAD - 4, 0, 6)
	tradeButton.Size = UDim2.fromOffset(72, 24)
	tradeButton.Activated:Connect(deps.onTrade)

	-- Equip slots along the top.
	local equipRow = Instance.new("Frame")
	equipRow.BackgroundTransparency = 1
	equipRow.Position = UDim2.fromOffset(PAD, 34)
	equipRow.Size = UDim2.new(1, -PAD * 2, 0, 50)
	equipRow.Parent = root
	local equipLayout = Instance.new("UIListLayout")
	equipLayout.FillDirection = Enum.FillDirection.Horizontal
	equipLayout.Padding = UDim.new(0, PAD)
	equipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	equipLayout.Parent = equipRow

	local self = setmetatable({
		deps = deps,
		root = root,
		cells = {},
		equipCells = {},
		slots = {},
		equipped = {},
		drag = nil,
		notice = notice,
		viewOnly = false,
		flashToken = 0,
		flashing = false,
	}, InventoryGrid)

	for order, slotName in deps.equipSlots do
		local cell = makeCell(deps, equipRow, 50)
		cell.frame.LayoutOrder = order
		cell.frame.Name = slotName
		cell.name.Text = slotName
		self.equipCells[slotName] = cell
		cell.frame.InputBegan:Connect(function(input: InputObject)
			if isPress(input) and self.equipped[slotName] ~= nil then
				self:beginDrag(nil, slotName, input)
			end
		end)
	end

	-- The bag.
	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(PAD, 92)
	grid.Size = UDim2.new(1, -PAD * 2, 1, -92 - PAD)
	grid.Parent = root
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CELL, CELL)
	layout.CellPadding = UDim2.fromOffset(PAD, PAD)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	for slot = 1, deps.capacity do
		local cell = makeCell(deps, grid, CELL)
		cell.frame.LayoutOrder = slot
		cell.frame.Name = "Slot" .. slot
		self.cells[slot] = cell
		cell.frame.InputBegan:Connect(function(input: InputObject)
			if isPress(input) and self.slots[slot] ~= nil then
				self:beginDrag(slot, nil, input)
			end
		end)
	end

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local drag = self.drag
		if drag == nil then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		then
			local point = Vector2.new(input.Position.X, input.Position.Y)
			drag.ghost.Position = UDim2.fromOffset(point.X, point.Y)
			if (point - drag.start).Magnitude > DRAG_THRESHOLD then
				drag.moved = true
				drag.ghost.Visible = true
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if self.drag ~= nil and isPress(input) then
			self:endDrag(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)

	return self
end

function InventoryGrid.beginDrag(self: InventoryGrid, slot: number?, equip: string?, input: InputObject)
	local deps = self.deps
	local ghost = Instance.new("Frame")
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Size = UDim2.fromOffset(40, 40)
	ghost.Visible = false
	ghost.ZIndex = 10
	ghost.Parent = deps.dragLayer
	local id = if slot then self.slots[slot].id else self.equipped[equip :: string]
	local def = deps.items[id]
	deps.theme.style(ghost, deps.theme.colour(if def then def.colour else nil), deps.theme.accent)
	local start = Vector2.new(input.Position.X, input.Position.Y)
	ghost.Position = UDim2.fromOffset(start.X, start.Y)
	self.drag = {
		slot = slot,
		equip = equip,
		ghost = ghost,
		start = start,
		moved = false,
		split = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift),
	}
end

function InventoryGrid.endDrag(self: InventoryGrid, point: Vector2)
	local drag = self.drag
	if drag == nil then
		return
	end
	self.drag = nil
	drag.ghost:Destroy()
	local deps = self.deps

	if not drag.moved then
		if drag.slot ~= nil then
			deps.onClick(drag.slot, drag.split)
		end
		return
	end

	local targetSlot: number? = nil
	for slot, cell in self.cells do
		if inside(cell.frame, point) then
			targetSlot = slot
			break
		end
	end
	local targetEquip: string? = nil
	for slotName, cell in self.equipCells do
		if inside(cell.frame, point) then
			targetEquip = slotName
			break
		end
	end

	if drag.slot ~= nil then
		if targetEquip ~= nil then
			deps.onEquip(drag.slot)
		elseif targetSlot ~= nil and targetSlot ~= drag.slot then
			local stack = self.slots[drag.slot]
			if drag.split and stack ~= nil and stack.count > 1 then
				deps.onSplit(drag.slot, stack.count // 2, targetSlot)
			else
				deps.onMove(drag.slot, targetSlot)
			end
		end
	elseif drag.equip ~= nil and targetSlot ~= nil then
		deps.onUnequip(drag.equip)
	end
end

local function show(deps: Deps, cell: Cell, id: string?, count: number?)
	local theme = deps.theme
	if id == nil then
		cell.swatch.Visible = false
		cell.count.Text = ""
		return
	end
	local def = deps.items[id]
	cell.swatch.Visible = true
	cell.swatch.BackgroundColor3 = theme.colour(if def then def.colour else nil)
	cell.name.Text = if def then def.name else id
	cell.name.TextColor3 = theme.text
	cell.count.Text = if count ~= nil and count > 1 then tostring(count) else ""
end

local function showNotice(self: InventoryGrid)
	if self.flashing then
		return
	end
	self.notice.Visible = self.viewOnly
	self.notice.Text = if self.viewOnly then VIEW_ONLY_TEXT else ""
end

-- The view-only line stays up for as long as the server says the session can't be saved.
function InventoryGrid.setViewOnly(self: InventoryGrid, on: boolean)
	self.viewOnly = on
	showNotice(self)
end

-- Shows a message for a few seconds, then goes back to the view-only line (if any).
function InventoryGrid.flash(self: InventoryGrid, text: string)
	self.flashToken += 1
	local token = self.flashToken
	self.flashing = true
	self.notice.Text = text
	self.notice.Visible = true
	task.delay(FLASH_SECONDS, function()
		if self.flashToken == token then
			self.flashing = false
			showNotice(self)
		end
	end)
end

-- `slots` and `equipped` come from the latest Sync.
function InventoryGrid.render(self: InventoryGrid, slots: { [number]: Stack }, equipped: { [string]: string })
	self.slots = slots
	self.equipped = equipped
	for slot, cell in self.cells do
		local stack = slots[slot]
		if stack then
			show(self.deps, cell, stack.id, stack.count)
		else
			show(self.deps, cell, nil, nil)
			cell.name.Text = ""
		end
	end
	for slotName, cell in self.equipCells do
		local id = equipped[slotName]
		if id then
			show(self.deps, cell, id, 1)
		else
			show(self.deps, cell, nil, nil)
			cell.name.Text = slotName
			cell.name.TextColor3 = self.deps.theme.muted
		end
	end
end

return InventoryGrid
