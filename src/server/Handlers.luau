--!strict
-- Server-side request handling, kept free of Roblox services so it can be tested with fakes.
-- The entry script wires one remote to `handle` and calls `tick` on a timer.
--
-- Clients send intent only. A call is dropped and counted when the action is unknown, the rate
-- limit is spent, an argument is the wrong type or out of range, or a game rule refuses it.
-- Nothing is ever reported back to the caller about why.
local Handlers = {}
Handlers.__index = Handlers

type Stack = { id: string, count: number }

export type Deps = {
	validate: any,
	inventory: any,
	newTrade: (a: number, b: number) -> any, -- builds a Trade for two player ids
	defs: any,
	capacity: number,
	equipSlots: { [string]: boolean },
	limiter: { take: (self: any, key: any, cost: number?) -> boolean },
	getInventory: (userId: number) -> any, -- live inventory, or nil when not loaded or lost
	isNear: (a: number, b: number) -> boolean,
	clock: () -> number,
	countdown: number,
	requestTimeout: number,
	notify: (userId: number) -> (), -- the entry script sends that player a Sync
	onTradeDone: (a: number, b: number) -> (), -- both players are saved straight after a commit
}

type Request = { from: number, at: number }

export type Handlers = typeof(setmetatable(
	{} :: {
		deps: Deps,
		trades: { [number]: any },
		requests: { [number]: Request }, -- keyed by the player being asked
		seen: { [any]: string },
		rejected: number,
	},
	Handlers
))

local MAX_USER_ID = 2 ^ 53
local MAX_COUNT = 9999

local ACTIONS: { [string]: boolean } = {
	move = true,
	split = true,
	equip = true,
	unequip = true,
	tradeRequest = true,
	tradeRespond = true,
	tradeOffer = true,
	tradeRetract = true,
	tradeConfirm = true,
	tradeCancel = true,
}

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, trades = {}, requests = {}, seen = {}, rejected = 0 }, Handlers)
end

local function outgoing(self: Handlers, userId: number): number?
	for target, request in self.requests do
		if request.from == userId then
			return target
		end
	end
	return nil
end

local function busy(self: Handlers, userId: number): boolean
	return self.trades[userId] ~= nil or self.requests[userId] ~= nil or outgoing(self, userId) ~= nil
end

local function endTrade(self: Handlers, trade: any)
	self.trades[trade.a] = nil
	self.trades[trade.b] = nil
	self.seen[trade] = nil
end

-- Tells both players about the trade, and cleans up once it has finished or been cancelled.
local function settle(self: Handlers, trade: any, force: boolean)
	local state = trade.state
	if state == "done" and self.seen[trade] ~= "done" then
		self.deps.onTradeDone(trade.a, trade.b)
	end
	if force or self.seen[trade] ~= state then
		self.deps.notify(trade.a)
		self.deps.notify(trade.b)
	end
	self.seen[trade] = state
	if state == "done" or state == "cancelled" then
		endTrade(self, trade)
	end
end

local function reject(self: Handlers): boolean
	self.rejected += 1
	return false
end

-- Returns true when the call was accepted and did its work.
function Handlers.handle(self: Handlers, userId: number, action: any, a: any, b: any, c: any): boolean
	local deps = self.deps
	local v = deps.validate
	if type(action) ~= "string" or ACTIONS[action] == nil then
		return reject(self)
	end
	if not deps.limiter:take(userId) then
		return reject(self)
	end
	local inv = deps.getInventory(userId)
	if inv == nil then
		return reject(self)
	end

	if action == "move" then
		if not (v.isInteger(a, 1, deps.capacity) and v.isInteger(b, 1, deps.capacity)) then
			return reject(self)
		end
		if not deps.inventory.move(inv, deps.defs, deps.capacity, a, b) then
			return reject(self)
		end
	elseif action == "split" then
		if
			not (
				v.isInteger(a, 1, deps.capacity)
				and v.isInteger(b, 1, MAX_COUNT)
				and v.isInteger(c, 1, deps.capacity)
			)
		then
			return reject(self)
		end
		if not deps.inventory.split(inv, deps.capacity, a, b, c) then
			return reject(self)
		end
	elseif action == "equip" then
		if not v.isInteger(a, 1, deps.capacity) then
			return reject(self)
		end
		if not deps.inventory.equip(inv, deps.defs, deps.capacity, a) then
			return reject(self)
		end
	elseif action == "unequip" then
		if not v.isOneOf(a, deps.equipSlots) then
			return reject(self)
		end
		if not deps.inventory.unequip(inv, deps.defs, deps.capacity, a) then
			return reject(self)
		end
	elseif action == "tradeRequest" then
		if not v.isInteger(a, 1, MAX_USER_ID) or a == userId then
			return reject(self)
		end
		if
			deps.getInventory(a) == nil
			or busy(self, userId)
			or busy(self, a)
			or not deps.isNear(userId, a)
		then
			return reject(self)
		end
		self.requests[a] = { from = userId, at = deps.clock() }
		deps.notify(a)
		deps.notify(userId)
		return true
	elseif action == "tradeRespond" then
		if type(a) ~= "boolean" then
			return reject(self)
		end
		local request = self.requests[userId]
		if request == nil then
			return reject(self)
		end
		self.requests[userId] = nil
		local from = request.from
		if not a then
			deps.notify(userId)
			deps.notify(from)
			return true
		end
		if
			deps.clock() - request.at > deps.requestTimeout
			or self.trades[from] ~= nil
			or deps.getInventory(from) == nil
			or not deps.isNear(from, userId)
		then
			deps.notify(userId)
			deps.notify(from)
			return reject(self)
		end
		local trade = deps.newTrade(from, userId)
		self.trades[from] = trade
		self.trades[userId] = trade
		settle(self, trade, true)
		return true
	else
		local trade = self.trades[userId]
		if trade == nil then
			return reject(self)
		end
		if action == "tradeOffer" then
			if not (v.isInteger(a, 1, deps.capacity) and v.isInteger(b, 1, MAX_COUNT)) then
				return reject(self)
			end
			if not trade:offer(userId, a, b) then
				return reject(self)
			end
		elseif action == "tradeRetract" then
			if not v.isInteger(a, 1, deps.capacity) then
				return reject(self)
			end
			if not trade:retract(userId, a) then
				return reject(self)
			end
		elseif action == "tradeConfirm" then
			if type(a) ~= "boolean" then
				return reject(self)
			end
			if a then
				if not trade:confirm(userId) then
					return reject(self)
				end
			else
				trade:unconfirm(userId)
			end
		else -- tradeCancel
			trade:cancel("cancelled")
		end
		settle(self, trade, true)
		return true
	end

	deps.notify(userId)
	return true
end

-- Called on a timer. Runs trade countdowns, drops trades whose players have drifted apart and
-- lets unanswered requests lapse.
function Handlers.tick(self: Handlers)
	local deps = self.deps
	local visited: { [any]: boolean } = {}
	for _, trade in self.trades do
		if not visited[trade] then
			visited[trade] = true
			if trade.state == "open" or trade.state == "countdown" then
				if not deps.isNear(trade.a, trade.b) then
					trade:cancel("distance")
				else
					trade:tick()
				end
			end
			settle(self, trade, false)
		end
	end
	for target, request in self.requests do
		if deps.clock() - request.at > deps.requestTimeout then
			self.requests[target] = nil
			deps.notify(target)
			deps.notify(request.from)
		end
	end
end

-- Called when a player leaves, before their session is released.
function Handlers.playerLeft(self: Handlers, userId: number)
	local trade = self.trades[userId]
	if trade ~= nil then
		trade:cancel("left")
		settle(self, trade, true)
	end
	local incoming = self.requests[userId]
	self.requests[userId] = nil
	if incoming ~= nil then
		self.deps.notify(incoming.from)
	end
	local target = outgoing(self, userId)
	if target ~= nil then
		self.requests[target] = nil
		self.deps.notify(target)
	end
end

local function copyStacks(list: { Stack }): { Stack }
	local out = {}
	for _, stack in list do
		table.insert(out, { id = stack.id, count = stack.count })
	end
	return out
end

-- What a player should be shown: their trade, a request waiting for them, or one they sent.
function Handlers.view(self: Handlers, userId: number): { trade: any?, request: any?, sentTo: number? }
	local trade = self.trades[userId]
	local tradeView = nil
	if trade ~= nil then
		local them = if trade.a == userId then trade.b else trade.a
		local secondsLeft = nil
		if trade.state == "countdown" and trade.confirmedAt ~= nil then
			secondsLeft = math.max(0, trade.confirmedAt + self.deps.countdown - self.deps.clock())
		end
		tradeView = {
			withId = them,
			state = trade.state,
			reason = trade.reason,
			mine = copyStacks(trade.offers[userId]),
			theirs = copyStacks(trade.offers[them]),
			iConfirmed = trade.confirmed[userId],
			theyConfirmed = trade.confirmed[them],
			secondsLeft = secondsLeft,
		}
	end
	local request = self.requests[userId]
	return {
		trade = tradeView,
		request = if request then { fromId = request.from } else nil,
		sentTo = outgoing(self, userId),
	}
end

return Handlers
