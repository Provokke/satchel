--!strict
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Inventory = require("../../src/server/Inventory/Inventory")
local Trade = require("../../src/server/Trade/Trade")

local defs = {
	apple = { maxStack = 20, slot = nil },
	coin = { maxStack = 99, slot = nil },
	sword = { maxStack = 1, slot = "Weapon" },
}

local function bag(slots: { [number]: { id: string, count: number } }): any
	local inv = Inventory.empty()
	for i, stack in slots do
		inv.slots[i] = stack
	end
	return inv
end

-- Two players, "a" and "b". Returns the trade, the clock and the live inventories table.
local function setup(invA: any, invB: any, capacity: number?)
	local clock = FakeClock.new(0)
	local live: { [any]: any } = { a = invA, b = invB }
	local unsaved: { [any]: boolean } = {} -- keys whose session can't be saved
	local trade = Trade.new("a", "b", {
		inventory = Inventory,
		defs = defs,
		capacity = capacity or 4,
		clock = function()
			return clock:now()
		end,
		countdown = 3,
		maxOfferSlots = 2,
		getInventory = function(key: any)
			return live[key]
		end,
		writable = function(key: any)
			return not unsaved[key]
		end,
	})
	return trade, clock, live, unsaved
end

local function confirmBoth(trade: any)
	assert(trade:confirm("a") == true)
	assert(trade:confirm("b") == true)
end

return {
	{
		name = "a straight swap moves the items both ways",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 50 } })
			local trade, clock = setup(invA, invB)
			assert(trade:offer("a", 1, 4) == true)
			assert(trade:offer("b", 1, 30) == true)
			assert(Inventory.countOf(invA, "apple") == 10, "offering does not move anything yet")
			confirmBoth(trade)
			clock:advance(3)
			assert(trade:tick() == "done")
			assert(Inventory.countOf(invA, "apple") == 6 and Inventory.countOf(invA, "coin") == 30)
			assert(Inventory.countOf(invB, "coin") == 20 and Inventory.countOf(invB, "apple") == 4)
		end,
	},
	{
		name = "an offer during the countdown clears confirmations and the trade stays open",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 50 } })
			local trade, clock = setup(invA, invB)
			trade:offer("a", 1, 4)
			confirmBoth(trade)
			assert(trade:tick() == "countdown")
			trade:offer("b", 1, 5)
			assert(trade.state == "open")
			assert(trade.confirmed.a == false and trade.confirmed.b == false)
			clock:advance(10)
			assert(trade:tick() == "open", "no commit without fresh confirmations")
			assert(Inventory.countOf(invA, "apple") == 10)
		end,
	},
	{
		name = "a commit after one side spent the item cancels as changed with nothing moved",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 50 } })
			local trade, clock = setup(invA, invB)
			trade:offer("a", 1, 8)
			trade:offer("b", 1, 5)
			confirmBoth(trade)
			Inventory.remove(invA, "apple", 5) -- spent elsewhere, leaving 5 of the 8 offered
			local snapA, snapB = Deep.copy(invA), Deep.copy(invB)
			clock:advance(3)
			assert(trade:tick() == "cancelled")
			assert(trade.reason == "changed", tostring(trade.reason))
			assert(Deep.equal(invA, snapA) and Deep.equal(invB, snapB), "inventories must not change")
		end,
	},
	{
		name = "the same trade commits when nothing was spent",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 50 } })
			local trade, clock = setup(invA, invB)
			trade:offer("a", 1, 8)
			trade:offer("b", 1, 5)
			confirmBoth(trade)
			clock:advance(3)
			assert(trade:tick() == "done")
			assert(Inventory.countOf(invB, "apple") == 8)
		end,
	},
	{
		name = "a receiver with a full bag cancels as changed and nothing moves",
		run = function()
			local invA = bag({ { id = "sword", count = 1 } })
			local invB = bag({ { id = "coin", count = 50 }, { id = "apple", count = 3 } })
			local trade, clock = setup(invA, invB, 2)
			trade:offer("a", 1, 1)
			confirmBoth(trade)
			local snapA, snapB = Deep.copy(invA), Deep.copy(invB)
			clock:advance(3)
			assert(trade:tick() == "cancelled" and trade.reason == "changed", tostring(trade.reason))
			assert(Deep.equal(invA, snapA) and Deep.equal(invB, snapB), "inventories must not change")
			-- control: with a free slot the same trade goes through
			local freeA = bag({ { id = "sword", count = 1 } })
			local freeB = bag({ { id = "coin", count = 50 } })
			local trade2, clock2 = setup(freeA, freeB, 2)
			trade2:offer("a", 1, 1)
			confirmBoth(trade2)
			clock2:advance(3)
			assert(trade2:tick() == "done")
			assert(Inventory.countOf(freeB, "sword") == 1)
		end,
	},
	{
		name = "a player who leaves before the commit cancels the trade as left",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 50 } })
			local trade, clock, live = setup(invA, invB)
			trade:offer("a", 1, 4)
			confirmBoth(trade)
			live.b = nil
			clock:advance(3)
			assert(trade:tick() == "cancelled" and trade.reason == "left", tostring(trade.reason))
			assert(Inventory.countOf(invA, "apple") == 10, "nothing moved")
		end,
	},
	{
		name = "offering more than is held is refused, offering what is held works",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local trade = setup(invA, bag({}))
			local ok, reason = trade:offer("a", 1, 11)
			assert(ok == false and reason == "not_enough", tostring(reason))
			assert(#trade.offers.a == 0)
			assert(trade:offer("a", 1, 10) == true)
			assert(#trade.offers.a == 1 and trade.offers.a[1].count == 10)
			local ok2 = trade:offer("a", 1, 1) -- already offered all ten
			assert(ok2 == false, "the same apples cannot be offered twice")
		end,
	},
	{
		name = "more offers than maxOfferSlots is refused",
		run = function()
			local invA = bag({
				{ id = "apple", count = 10 },
				{ id = "coin", count = 10 },
				{ id = "sword", count = 1 },
			})
			local trade = setup(invA, bag({}))
			assert(trade:offer("a", 1, 1) == true)
			assert(trade:offer("a", 2, 1) == true)
			local ok, reason = trade:offer("a", 3, 1)
			assert(ok == false and reason == "too_many_offers", tostring(reason))
			assert(#trade.offers.a == 2)
			assert(trade:retract("a", 1) == true)
			assert(trade:offer("a", 3, 1) == true, "a retracted offer frees the slot")
		end,
	},
	{
		name = "the countdown does not commit at 2.9 seconds and commits at 3.0",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({})
			local trade, clock = setup(invA, invB)
			trade:offer("a", 1, 4)
			confirmBoth(trade)
			clock:advance(2.9)
			assert(trade:tick() == "countdown")
			assert(Inventory.countOf(invB, "apple") == 0)
			clock:advance(0.1)
			assert(trade:tick() == "done")
			assert(Inventory.countOf(invB, "apple") == 4)
		end,
	},
	{
		name = "a one-sided gift works",
		run = function()
			local invA = bag({ { id = "sword", count = 1 } })
			local invB = bag({})
			local trade, clock = setup(invA, invB)
			trade:offer("a", 1, 1)
			confirmBoth(trade)
			clock:advance(3)
			assert(trade:tick() == "done")
			assert(Inventory.countOf(invA, "sword") == 0 and Inventory.countOf(invB, "sword") == 1)
		end,
	},
	{
		name = "unconfirm stops the countdown, and a cancelled trade stays cancelled",
		run = function()
			local invA = bag({ { id = "apple", count = 10 } })
			local trade, clock = setup(invA, bag({}))
			trade:offer("a", 1, 4)
			confirmBoth(trade)
			assert(trade:tick() == "countdown")
			trade:unconfirm("b")
			assert(trade.state == "open")
			clock:advance(5)
			assert(trade:tick() == "open")
			trade:cancel("declined")
			assert(trade.state == "cancelled" and trade.reason == "declined")
			trade:cancel("other")
			assert(trade.reason == "declined", "the first reason is kept")
			assert(trade:offer("a", 1, 1) == false, "no offers on a closed trade")
		end,
	},
	{
		name = "commit cancels when either side can't be saved, and nothing moves",
		run = function()
			for _, side in { "a", "b" } do
				local invA = bag({ { id = "apple", count = 10 } })
				local invB = bag({ { id = "coin", count = 5 } })
				local trade, clock, _live, unsaved = setup(invA, invB)
				assert(trade:offer("a", 1, 4) == true)
				assert(trade:offer("b", 1, 5) == true)
				confirmBoth(trade)
				unsaved[side] = true
				clock:advance(3)
				assert(trade:tick() == "cancelled" and trade.reason == "view_only", trade.reason)
				assert(Inventory.countOf(invA, "apple") == 10 and Inventory.countOf(invA, "coin") == 0)
				assert(Inventory.countOf(invB, "coin") == 5 and Inventory.countOf(invB, "apple") == 0)
			end
			-- control: both sides savable, the same trade commits
			local invA = bag({ { id = "apple", count = 10 } })
			local invB = bag({ { id = "coin", count = 5 } })
			local trade, clock = setup(invA, invB)
			assert(trade:offer("a", 1, 4) == true)
			assert(trade:offer("b", 1, 5) == true)
			confirmBoth(trade)
			clock:advance(3)
			assert(trade:tick() == "done")
			assert(Inventory.countOf(invA, "coin") == 5 and Inventory.countOf(invB, "apple") == 4)
		end,
	},
}
