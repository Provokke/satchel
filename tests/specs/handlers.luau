--!strict
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Handlers = require("../../src/server/Handlers")
local Inventory = require("../../src/server/Inventory/Inventory")
local RateLimiter = require("../../src/shared/RateLimiter")
local Trade = require("../../src/server/Trade/Trade")
local Validate = require("../../src/shared/Validate")

local defs = {
	apple = { maxStack = 20, slot = nil },
	coin = { maxStack = 99, slot = nil },
	sword = { maxStack = 1, slot = "Weapon" },
}

-- Players 1 and 2 stand together. Player 3 is far away. Returns the handlers and the world.
local function setup(burst: number?)
	local clock = FakeClock.new(0)
	local now = function()
		return clock:now()
	end
	local world: any = {
		inv = {
			[1] = Inventory.empty(),
			[2] = Inventory.empty(),
			[3] = Inventory.empty(),
		},
		apart = {},
		viewOnly = {}, -- players whose session can't be saved (read-only or lost)
		notified = {},
		told = {},
		done = {},
	}
	world.inv[1].slots[1] = { id = "apple", count = 10 }
	world.inv[1].slots[2] = { id = "sword", count = 1 }
	world.inv[2].slots[1] = { id = "coin", count = 50 }
	local handlers = Handlers.new({
		validate = Validate,
		inventory = Inventory,
		newTrade = function(a: number, b: number)
			return Trade.new(a, b, {
				inventory = Inventory,
				defs = defs,
				capacity = 6,
				clock = now,
				countdown = 3,
				maxOfferSlots = 4,
				getInventory = function(key: any)
					return world.inv[key]
				end,
				writable = function(key: any)
					return not world.viewOnly[key]
				end,
			})
		end,
		defs = defs,
		capacity = 6,
		equipSlots = { Head = true, Body = true, Weapon = true },
		limiter = RateLimiter.new(burst or 100, 100, now),
		getInventory = function(userId: number)
			return world.inv[userId]
		end,
		writable = function(userId: number)
			return not world.viewOnly[userId]
		end,
		tell = function(userId: number, notice: string)
			table.insert(world.told, `{userId}:{notice}`)
		end,
		isNear = function(a: number, b: number)
			return not (world.apart[a] or world.apart[b])
		end,
		clock = now,
		countdown = 3,
		requestTimeout = 20,
		notify = function(userId: number)
			world.notified[userId] = (world.notified[userId] or 0) + 1
		end,
		onTradeDone = function(a: number, b: number)
			table.insert(world.done, { a, b })
		end,
	})
	world.apart[3] = true
	return handlers, world, clock
end

local function startTrade(handlers: any)
	assert(handlers:handle(1, "tradeRequest", 2) == true)
	assert(handlers:handle(2, "tradeRespond", true) == true)
end

return {
	{
		name = "move, split, equip and unequip change the caller's own inventory",
		run = function()
			local handlers, world = setup()
			local inv = world.inv[1]
			assert(handlers:handle(1, "move", 1, 4) == true)
			assert(inv.slots[4].id == "apple" and inv.slots[1] == nil)
			assert(handlers:handle(1, "split", 4, 3, 5) == true)
			assert(inv.slots[4].count == 7 and inv.slots[5].count == 3)
			assert(handlers:handle(1, "equip", 2) == true)
			assert(inv.equipped.Weapon == "sword")
			assert(handlers:handle(1, "unequip", "Weapon") == true)
			assert(inv.equipped.Weapon == nil and Inventory.countOf(inv, "sword") == 1)
			assert(handlers.rejected == 0)
		end,
	},
	{
		name = "bad arguments are dropped and counted, and leave the inventory alone",
		run = function()
			local handlers, world = setup()
			local snapshot = Deep.copy(world.inv[1])
			local bad: { { any } } = {
				{ "move", 0, 3 },
				{ "move", 1.5, 3 },
				{ "move", 1, 7 },
				{ "move", 0 / 0, 3 },
				{ "move", "1", 3 },
				{ "move", math.huge, 3 },
				{ "split", 1, 0, 3 },
				{ "equip", 99 },
				{ "unequip", "Feet" },
				{ "unequip", 3 },
				{ "teleport", 1, 2 },
				{ 42, 1, 2 },
			}
			for _, call in bad do
				assert(handlers:handle(1, call[1], call[2], call[3], call[4]) == false, tostring(call[1]))
			end
			assert(handlers.rejected == #bad, `rejected {handlers.rejected}`)
			assert(Deep.equal(world.inv[1], snapshot), "inventory changed")
			assert(handlers:handle(1, "move", 1, 3) == true, "a valid call still works")
		end,
	},
	{
		name = "the rate limit drops calls past the burst and recovers with time",
		run = function()
			local handlers, world, clock = setup(3)
			assert(handlers:handle(1, "move", 1, 3) == true)
			assert(handlers:handle(1, "move", 3, 4) == true)
			assert(handlers:handle(1, "move", 4, 5) == true)
			assert(handlers:handle(1, "move", 5, 6) == false, "fourth call is over the burst")
			assert(world.inv[1].slots[5] ~= nil and world.inv[1].slots[6] == nil, "dropped call did nothing")
			clock:advance(1)
			assert(handlers:handle(1, "move", 5, 6) == true, "after time passes it goes through")
		end,
	},
	{
		name = "a player whose data is not loaded gets nothing done",
		run = function()
			local handlers, world = setup()
			world.inv[1] = nil
			assert(handlers:handle(1, "move", 1, 3) == false)
			assert(handlers:handle(1, "tradeRequest", 2) == false)
			assert(handlers.rejected == 2)
		end,
	},
	{
		name = "a trade request needs the players close together",
		run = function()
			local handlers = setup()
			assert(handlers:handle(1, "tradeRequest", 3) == false, "player 3 is out of range")
			assert(handlers:handle(1, "tradeRequest", 1) == false, "no trading with yourself")
			assert(handlers:handle(1, "tradeRequest", 2) == true, "player 2 is in range")
			assert(handlers:view(2).request.fromId == 1)
			assert(handlers:view(1).sentTo == 2)
		end,
	},
	{
		name = "a player already in a trade cannot be asked or ask again",
		run = function()
			local handlers, world = setup()
			world.apart[3] = false
			startTrade(handlers)
			assert(handlers:handle(3, "tradeRequest", 2) == false, "2 is busy")
			assert(handlers:handle(1, "tradeRequest", 3) == false, "1 is busy")
			handlers:handle(1, "tradeCancel")
			assert(handlers:handle(3, "tradeRequest", 2) == true, "once it is over, 2 can be asked")
		end,
	},
	{
		name = "declining or letting a request lapse starts no trade",
		run = function()
			local handlers, _, clock = setup()
			handlers:handle(1, "tradeRequest", 2)
			assert(handlers:handle(2, "tradeRespond", false) == true)
			assert(handlers:view(1).trade == nil and handlers:view(2).request == nil)
			handlers:handle(1, "tradeRequest", 2)
			clock:advance(21)
			assert(handlers:handle(2, "tradeRespond", true) == false, "too late to accept")
			assert(handlers:view(2).trade == nil)
			handlers:handle(1, "tradeRequest", 2)
			assert(handlers:handle(2, "tradeRespond", true) == true, "a fresh request can be accepted")
			assert(handlers:view(2).trade ~= nil)
		end,
	},
	{
		name = "tradeOffer and the rest are refused without a trade",
		run = function()
			local handlers, world = setup()
			local snapshot = Deep.copy(world.inv[1])
			assert(handlers:handle(1, "tradeOffer", 1, 2) == false)
			assert(handlers:handle(1, "tradeConfirm", true) == false)
			assert(Deep.equal(world.inv[1], snapshot))
			startTrade(handlers)
			assert(handlers:handle(1, "tradeOffer", 1, 2) == true, "the same call works inside a trade")
		end,
	},
	{
		name = "a full trade swaps the items, saves both players and clears the trade",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			assert(handlers:handle(1, "tradeOffer", 1, 4) == true)
			assert(handlers:handle(2, "tradeOffer", 1, 30) == true)
			assert(handlers:handle(1, "tradeConfirm", true) == true)
			assert(handlers:handle(2, "tradeConfirm", true) == true)
			assert(handlers:view(1).trade.state == "countdown")
			clock:advance(2)
			handlers:tick()
			assert(Inventory.countOf(world.inv[2], "apple") == 0, "not yet")
			clock:advance(1)
			handlers:tick()
			assert(
				Inventory.countOf(world.inv[1], "apple") == 6
					and Inventory.countOf(world.inv[1], "coin") == 30
			)
			assert(
				Inventory.countOf(world.inv[2], "apple") == 4
					and Inventory.countOf(world.inv[2], "coin") == 20
			)
			assert(
				#world.done == 1 and world.done[1][1] == 1 and world.done[1][2] == 2,
				"both players saved once"
			)
			assert(handlers:view(1).trade == nil and handlers:view(2).trade == nil, "trade cleared")
		end,
	},
	{
		name = "players who walk apart mid-trade lose the trade and nothing moves",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			handlers:handle(1, "tradeOffer", 1, 4)
			handlers:handle(1, "tradeConfirm", true)
			handlers:handle(2, "tradeConfirm", true)
			world.apart[2] = true
			clock:advance(3)
			handlers:tick()
			assert(Inventory.countOf(world.inv[1], "apple") == 10, "nothing moved")
			assert(#world.done == 0)
			assert(handlers:view(1).trade == nil)
			-- control: close together, the same trade commits
			world.apart[2] = false
			startTrade(handlers)
			handlers:handle(1, "tradeOffer", 1, 4)
			handlers:handle(1, "tradeConfirm", true)
			handlers:handle(2, "tradeConfirm", true)
			clock:advance(3)
			handlers:tick()
			assert(Inventory.countOf(world.inv[2], "apple") == 4)
		end,
	},
	{
		name = "a player leaving cancels their trade and tells the other player",
		run = function()
			local handlers, world = setup()
			startTrade(handlers)
			handlers:handle(1, "tradeOffer", 1, 4)
			local before = world.notified[2] or 0
			handlers:playerLeft(1)
			assert(handlers:view(2).trade == nil, "the trade is gone")
			assert((world.notified[2] or 0) > before, "the other player was told")
			assert(Inventory.countOf(world.inv[1], "apple") == 10)
		end,
	},
	{
		name = "tick does not spam notifications for an idle open trade",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			local before = world.notified[1] or 0
			for _ = 1, 5 do
				clock:advance(1)
				handlers:tick()
			end
			assert((world.notified[1] or 0) == before, "no change, no sync")
		end,
	},
	{
		name = "a view-only player can't change their bag and is told why",
		run = function()
			local handlers, world = setup()
			world.viewOnly[1] = true
			local before = Deep.copy(world.inv[1])
			assert(handlers:handle(1, "move", 1, 3) == false)
			assert(Deep.equal(world.inv[1], before), "the bag is untouched")
			assert(table.concat(world.told, ",") == "1:view_only", table.concat(world.told, ","))
			-- control: once the session can save, the same move works
			world.viewOnly[1] = nil
			assert(handlers:handle(1, "move", 1, 3) == true)
			assert(world.inv[1].slots[3].id == "apple" and world.inv[1].slots[1] == nil)
		end,
	},
	{
		name = "nobody can trade with a view-only player, and the asker is told why",
		run = function()
			local handlers, world = setup()
			world.viewOnly[2] = true
			assert(handlers:handle(1, "tradeRequest", 2) == false)
			assert(handlers:view(2).request == nil, "no request was sent")
			assert(table.concat(world.told, ",") == "1:partner_view_only", table.concat(world.told, ","))
			-- control
			world.viewOnly[2] = nil
			assert(handlers:handle(1, "tradeRequest", 2) == true)
			assert(handlers:view(2).request ~= nil)
		end,
	},
	{
		name = "accepting a request from a player who can no longer save opens no trade",
		run = function()
			local handlers, world = setup()
			assert(handlers:handle(1, "tradeRequest", 2) == true)
			world.viewOnly[1] = true -- player 1's lease was lost after asking
			assert(handlers:handle(2, "tradeRespond", true) == false)
			assert(handlers:view(2).trade == nil and handlers:view(1).trade == nil)
			assert(table.concat(world.told, ",") == "2:partner_view_only", table.concat(world.told, ","))
			-- control
			world.viewOnly[1] = nil
			startTrade(handlers)
			assert(handlers:view(2).trade ~= nil)
		end,
	},
	{
		name = "a trade is cancelled at commit when one side can no longer save, and nothing moves",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			handlers:handle(1, "tradeOffer", 1, 4)
			handlers:handle(1, "tradeConfirm", true)
			handlers:handle(2, "tradeConfirm", true)
			world.viewOnly[2] = true
			clock:advance(3)
			handlers:tick()
			assert(Inventory.countOf(world.inv[1], "apple") == 10 and Inventory.countOf(world.inv[2], "apple") == 0)
			assert(#world.done == 0, "no saves for a trade that did not happen")
			assert(handlers:view(1).trade == nil, "the trade has ended")
			-- control
			world.viewOnly[2] = nil
			startTrade(handlers)
			handlers:handle(1, "tradeOffer", 1, 4)
			handlers:handle(1, "tradeConfirm", true)
			handlers:handle(2, "tradeConfirm", true)
			clock:advance(3)
			handlers:tick()
			assert(Inventory.countOf(world.inv[2], "apple") == 4 and #world.done == 1)
		end,
	},
	{
		name = "leaving mid-countdown cancels the trade, and ticking past the countdown moves nothing",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			assert(handlers:handle(1, "tradeOffer", 1, 4) == true)
			assert(handlers:handle(2, "tradeOffer", 1, 10) == true)
			assert(handlers:handle(1, "tradeConfirm", true) == true)
			assert(handlers:handle(2, "tradeConfirm", true) == true)
			assert(handlers:view(1).trade.state == "countdown", "the countdown is running")
			clock:advance(1)
			handlers:playerLeft(2)
			world.inv[2] = nil -- their session is gone
			clock:advance(5)
			handlers:tick()
			assert(Inventory.countOf(world.inv[1], "apple") == 10 and Inventory.countOf(world.inv[1], "coin") == 0)
			assert(#world.done == 0, "no saves")
			assert(handlers:view(1).trade == nil)
			-- control: staying through the countdown commits the same trade
			local handlers2, world2, clock2 = setup()
			startTrade(handlers2)
			handlers2:handle(1, "tradeOffer", 1, 4)
			handlers2:handle(2, "tradeOffer", 1, 10)
			handlers2:handle(1, "tradeConfirm", true)
			handlers2:handle(2, "tradeConfirm", true)
			clock2:advance(6)
			handlers2:tick()
			assert(Inventory.countOf(world2.inv[1], "coin") == 10 and Inventory.countOf(world2.inv[2], "apple") == 4)
			assert(#world2.done == 1)
		end,
	},
	{
		name = "a player whose session is gone can't act, and their open trade cancels",
		run = function()
			local handlers, world, clock = setup()
			startTrade(handlers)
			assert(handlers:handle(1, "tradeOffer", 1, 4) == true)
			local inv1 = world.inv[1]
			world.inv[1] = nil -- the lease was lost: getInventory now gives nil
			assert(handlers:handle(1, "tradeConfirm", true) == false)
			assert(handlers:handle(1, "move", 1, 3) == false)
			clock:advance(1)
			handlers:tick()
			assert(handlers:view(2).trade == nil, "the trade is over")
			assert(Inventory.countOf(inv1, "apple") == 10 and Inventory.countOf(world.inv[2], "apple") == 0)
			-- control: with the session back the same move works
			world.inv[1] = inv1
			assert(handlers:handle(1, "move", 1, 3) == true)
		end,
	},
}
