--!strict
-- Stacking inventory and equip slots. Pure functions over plain tables.
--
-- Every mutating function works on a clone and copies the result into `inv` only on success,
-- so a refused call leaves `inv` exactly as it was.
local Inventory = {}

export type Stack = { id: string, count: number }
export type InventoryData = { slots: { [number]: Stack }, equipped: { [string]: string } }
-- itemDefs: { [id]: { maxStack: number, slot: string? } }
type Defs = { [string]: { maxStack: number, slot: string? } }

local function isCount(n: any): boolean
	return type(n) == "number" and n == n and n >= 1 and n % 1 == 0 and n ~= math.huge
end

function Inventory.empty(): InventoryData
	return { slots = {}, equipped = {} }
end

function Inventory.clone(inv: InventoryData): InventoryData
	local copy = Inventory.empty()
	for i, stack in inv.slots do
		copy.slots[i] = { id = stack.id, count = stack.count }
	end
	for slot, id in inv.equipped do
		copy.equipped[slot] = id
	end
	return copy
end

-- Copies a successful working inventory back into the live one.
local function commit(inv: InventoryData, work: InventoryData)
	table.clear(inv.slots)
	table.clear(inv.equipped)
	for i, stack in work.slots do
		inv.slots[i] = stack
	end
	for slot, id in work.equipped do
		inv.equipped[slot] = id
	end
end

local function validSlot(slot: any, capacity: number): boolean
	return type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= capacity
end

-- The mutation itself, on a clone the caller owns. Returns nil on success or a reason.
local function addTo(work: InventoryData, defs: Defs, capacity: number, id: string, count: number): string?
	local def = defs[id]
	if def == nil then
		return "unknown_item"
	end
	if not isCount(count) then
		return "bad_count"
	end
	local remaining = count
	for i = 1, capacity do
		local stack = work.slots[i]
		if remaining > 0 and stack ~= nil and stack.id == id and stack.count < def.maxStack then
			local room = math.min(def.maxStack - stack.count, remaining)
			stack.count += room
			remaining -= room
		end
	end
	for i = 1, capacity do
		if remaining > 0 and work.slots[i] == nil then
			local put = math.min(def.maxStack, remaining)
			work.slots[i] = { id = id, count = put }
			remaining -= put
		end
	end
	if remaining > 0 then
		return "full"
	end
	return nil
end

local function finish(inv: InventoryData, work: InventoryData, reason: string?): (boolean, string?)
	if reason ~= nil then
		return false, reason
	end
	commit(inv, work)
	return true, nil
end

-- Fills existing stacks, then empty slots. All or nothing.
function Inventory.add(
	inv: InventoryData,
	defs: Defs,
	capacity: number,
	id: string,
	count: number
): (boolean, string?)
	local work = Inventory.clone(inv)
	return finish(inv, work, addTo(work, defs, capacity, id, count))
end

function Inventory.countOf(inv: InventoryData, id: string): number
	local total = 0
	for _, stack in inv.slots do
		if stack.id == id then
			total += stack.count
		end
	end
	return total
end

local function removeFrom(work: InventoryData, id: string, count: number): string?
	if not isCount(count) then
		return "bad_count"
	end
	if Inventory.countOf(work, id) < count then
		return "not_enough"
	end
	local remaining = count
	local indexes: { number } = {}
	for i in work.slots do
		table.insert(indexes, i)
	end
	table.sort(indexes)
	for _, i in indexes do
		local stack = work.slots[i]
		if remaining > 0 and stack.id == id then
			local take = math.min(stack.count, remaining)
			stack.count -= take
			remaining -= take
			if stack.count == 0 then
				work.slots[i] = nil
			end
		end
	end
	return nil
end

-- Takes from stacks in slot order. All or nothing.
function Inventory.remove(inv: InventoryData, id: string, count: number): (boolean, string?)
	local work = Inventory.clone(inv)
	return finish(inv, work, removeFrom(work, id, count))
end

-- To an empty slot: move. Same item: merge up to maxStack, the rest stays. Another item: swap.
function Inventory.move(
	inv: InventoryData,
	defs: Defs,
	capacity: number,
	from: number,
	to: number
): (boolean, string?)
	if not validSlot(from, capacity) or not validSlot(to, capacity) then
		return false, "bad_slot"
	end
	if from == to then
		return false, "same_slot"
	end
	local work = Inventory.clone(inv)
	local source = work.slots[from]
	if source == nil then
		return false, "empty_slot"
	end
	local target = work.slots[to]
	if target == nil then
		work.slots[to] = source
		work.slots[from] = nil
	elseif target.id == source.id then
		local def = defs[source.id]
		if def == nil then
			return false, "unknown_item"
		end
		local room = def.maxStack - target.count
		if room <= 0 then
			return false, "full"
		end
		local moved = math.min(room, source.count)
		target.count += moved
		source.count -= moved
		if source.count == 0 then
			work.slots[from] = nil
		end
	else
		work.slots[to] = source
		work.slots[from] = target
	end
	commit(inv, work)
	return true, nil
end

-- Moves `count` from a stack into an empty slot. 0 < count < stack.count.
function Inventory.split(
	inv: InventoryData,
	capacity: number,
	from: number,
	count: number,
	to: number
): (boolean, string?)
	if not validSlot(from, capacity) or not validSlot(to, capacity) then
		return false, "bad_slot"
	end
	local work = Inventory.clone(inv)
	local source = work.slots[from]
	if source == nil then
		return false, "empty_slot"
	end
	if work.slots[to] ~= nil then
		return false, "occupied"
	end
	if not isCount(count) or count >= source.count then
		return false, "bad_count"
	end
	source.count -= count
	work.slots[to] = { id = source.id, count = count }
	commit(inv, work)
	return true, nil
end

-- Takes one item from the stack into its equip slot. Whatever was there goes back into the bag
-- first, or the call fails with "full". `capacity` is the bag size.
function Inventory.equip(
	inv: InventoryData,
	defs: Defs,
	capacity: number,
	fromSlot: number
): (boolean, string?)
	if not validSlot(fromSlot, capacity) then
		return false, "bad_slot"
	end
	local work = Inventory.clone(inv)
	local stack = work.slots[fromSlot]
	if stack == nil then
		return false, "empty_slot"
	end
	local def = defs[stack.id]
	local slot = if def then def.slot else nil
	if slot == nil then
		return false, "not_equippable"
	end
	local id = stack.id
	stack.count -= 1
	if stack.count == 0 then
		work.slots[fromSlot] = nil
	end
	local previous = work.equipped[slot]
	if previous ~= nil then
		local reason = addTo(work, defs, capacity, previous, 1)
		if reason ~= nil then
			return false, reason
		end
	end
	work.equipped[slot] = id
	commit(inv, work)
	return true, nil
end

function Inventory.unequip(
	inv: InventoryData,
	defs: Defs,
	capacity: number,
	equipSlot: string
): (boolean, string?)
	local work = Inventory.clone(inv)
	local id = work.equipped[equipSlot]
	if id == nil then
		return false, "nothing_equipped"
	end
	local reason = addTo(work, defs, capacity, id, 1)
	if reason ~= nil then
		return false, reason
	end
	work.equipped[equipSlot] = nil
	commit(inv, work)
	return true, nil
end

-- DataStore-safe form: slot numbers become string keys, so a bag with gaps is never a sparse array.
function Inventory.encode(inv: InventoryData): { slots: { [string]: Stack }, equipped: { [string]: string } }
	local slots: { [string]: Stack } = {}
	for i, stack in inv.slots do
		slots[tostring(i)] = { id = stack.id, count = stack.count }
	end
	local equipped = table.clone(inv.equipped)
	return { slots = slots, equipped = equipped }
end

-- Reverses encode. Anything malformed is dropped rather than trusted.
function Inventory.decode(saved: any): InventoryData
	local inv = Inventory.empty()
	if type(saved) ~= "table" then
		return inv
	end
	if type(saved.slots) == "table" then
		for key, stack in saved.slots do
			local index = tonumber(key)
			if
				index ~= nil
				and index >= 1
				and index % 1 == 0
				and type(stack) == "table"
				and type(stack.id) == "string"
				and isCount(stack.count)
			then
				inv.slots[index] = { id = stack.id, count = stack.count }
			end
		end
	end
	if type(saved.equipped) == "table" then
		for slot, id in saved.equipped do
			if type(slot) == "string" and type(id) == "string" then
				inv.equipped[slot] = id
			end
		end
	end
	return inv
end

return Inventory
