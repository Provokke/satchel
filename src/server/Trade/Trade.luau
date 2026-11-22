--!strict
-- A two-player trade. Offers hold references only; items move in one step when both sides have
-- confirmed and the countdown has run out. Players are opaque keys (usually UserIds), and the
-- inventory module and everything else comes in through `Trade.new`.
local Trade = {}
Trade.__index = Trade

type Stack = { id: string, count: number }

export type Deps = {
	inventory: any,
	defs: any,
	capacity: number,
	clock: () -> number,
	countdown: number,
	maxOfferSlots: number,
	getInventory: (key: any) -> any,
}

export type Trade = typeof(setmetatable(
	{} :: {
		a: any,
		b: any,
		deps: Deps,
		state: string, -- "open" | "countdown" | "done" | "cancelled"
		reason: string?,
		offers: { [any]: { Stack } },
		confirmed: { [any]: boolean },
		confirmedAt: number?,
	},
	Trade
))

function Trade.new(a: any, b: any, deps: Deps): Trade
	assert(a ~= b, "a trade needs two different players")
	return setmetatable({
		a = a,
		b = b,
		deps = deps,
		state = "open",
		reason = nil,
		offers = { [a] = {}, [b] = {} },
		confirmed = { [a] = false, [b] = false },
		confirmedAt = nil,
	}, Trade)
end

local function isLive(self: Trade): boolean
	return self.state == "open" or self.state == "countdown"
end

local function isMember(self: Trade, who: any): boolean
	return who == self.a or who == self.b
end

local function other(self: Trade, who: any): any
	if who == self.a then
		return self.b
	end
	return self.a
end

-- Any change to the table puts both players back to unconfirmed and stops the countdown.
local function reset(self: Trade)
	self.confirmed[self.a] = false
	self.confirmed[self.b] = false
	self.confirmedAt = nil
	if self.state == "countdown" then
		self.state = "open"
	end
end

local function offeredOf(self: Trade, who: any, id: string): number
	local total = 0
	for _, stack in self.offers[who] do
		if stack.id == id then
			total += stack.count
		end
	end
	return total
end

function Trade.offer(self: Trade, who: any, fromSlot: number, count: number): (boolean, string?)
	if not isLive(self) or not isMember(self, who) then
		return false, "closed"
	end
	local inv = self.deps.getInventory(who)
	if inv == nil then
		return false, "left"
	end
	if type(count) ~= "number" or count ~= count or count < 1 or count % 1 ~= 0 then
		return false, "bad_count"
	end
	local stack = inv.slots[fromSlot]
	if stack == nil then
		return false, "empty_slot"
	end
	if
		count > stack.count
		or offeredOf(self, who, stack.id) + count > self.deps.inventory.countOf(inv, stack.id)
	then
		return false, "not_enough"
	end
	if #self.offers[who] >= self.deps.maxOfferSlots then
		return false, "too_many_offers"
	end
	table.insert(self.offers[who], { id = stack.id, count = count })
	reset(self)
	return true, nil
end

function Trade.retract(self: Trade, who: any, offerIndex: number): (boolean, string?)
	if not isLive(self) or not isMember(self, who) then
		return false, "closed"
	end
	local list = self.offers[who]
	if type(offerIndex) ~= "number" or offerIndex % 1 ~= 0 or list[offerIndex] == nil then
		return false, "no_such_offer"
	end
	table.remove(list, offerIndex)
	reset(self)
	return true, nil
end

function Trade.confirm(self: Trade, who: any): (boolean, string?)
	if not isLive(self) or not isMember(self, who) then
		return false, "closed"
	end
	self.confirmed[who] = true
	if self.state == "open" and self.confirmed[other(self, who)] then
		self.state = "countdown"
		self.confirmedAt = self.deps.clock()
	end
	return true, nil
end

function Trade.unconfirm(self: Trade, who: any)
	if not isLive(self) or not isMember(self, who) then
		return
	end
	self.confirmed[who] = false
	self.confirmedAt = nil
	if self.state == "countdown" then
		self.state = "open"
	end
end

function Trade.cancel(self: Trade, reason: string)
	if not isLive(self) then
		return
	end
	self.state = "cancelled"
	self.reason = reason
end

-- Works out both new inventories on clones, and writes them back only if every step worked.
local function commit(self: Trade)
	local deps = self.deps
	local invA = deps.getInventory(self.a)
	local invB = deps.getInventory(self.b)
	if invA == nil or invB == nil then
		self:cancel("left")
		return
	end
	local Inventory = deps.inventory
	local workA = Inventory.clone(invA)
	local workB = Inventory.clone(invB)

	-- Take everything off the table first, so space freed by one side counts for the other.
	for _, stack in self.offers[self.a] do
		if not Inventory.remove(workA, stack.id, stack.count) then
			self:cancel("changed")
			return
		end
	end
	for _, stack in self.offers[self.b] do
		if not Inventory.remove(workB, stack.id, stack.count) then
			self:cancel("changed")
			return
		end
	end
	for _, stack in self.offers[self.a] do
		if not Inventory.add(workB, deps.defs, deps.capacity, stack.id, stack.count) then
			self:cancel("changed")
			return
		end
	end
	for _, stack in self.offers[self.b] do
		if not Inventory.add(workA, deps.defs, deps.capacity, stack.id, stack.count) then
			self:cancel("changed")
			return
		end
	end

	for _, pair in { { invA, workA }, { invB, workB } } do
		local live, work = pair[1], pair[2]
		table.clear(live.slots)
		table.clear(live.equipped)
		for i, stack in work.slots do
			live.slots[i] = stack
		end
		for slot, id in work.equipped do
			live.equipped[slot] = id
		end
	end
	self.state = "done"
end

function Trade.tick(self: Trade): string
	if not isLive(self) then
		return self.state
	end
	if self.deps.getInventory(self.a) == nil or self.deps.getInventory(self.b) == nil then
		self:cancel("left")
		return self.state
	end
	local startedAt = self.confirmedAt
	if
		self.state == "countdown"
		and startedAt ~= nil
		and self.deps.clock() >= startedAt + self.deps.countdown
	then
		commit(self)
	end
	return self.state
end

return Trade
