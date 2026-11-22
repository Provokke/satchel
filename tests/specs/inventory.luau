--!strict
local Deep = require("../fakes/Deep")
local Inventory = require("../../src/server/Inventory/Inventory")

local defs = {
	apple = { maxStack = 20, slot = nil },
	coin = { maxStack = 99, slot = nil },
	sword = { maxStack = 1, slot = "Weapon" },
	knife = { maxStack = 5, slot = "Weapon" },
	helm = { maxStack = 1, slot = "Head" },
}

local function bag(slots: { [number]: { id: string, count: number } }?, equipped: { [string]: string }?): any
	local inv = Inventory.empty()
	for i, stack in slots or {} do
		inv.slots[i] = stack
	end
	for slot, id in equipped or {} do
		inv.equipped[slot] = id
	end
	return inv
end

local function unchanged(inv: any, snapshot: any)
	assert(Deep.equal(inv, snapshot), "inventory changed after a refused call")
end

return {
	{
		name = "add puts a new item in the first empty slot",
		run = function()
			local inv = bag()
			local ok = Inventory.add(inv, defs, 4, "apple", 5)
			assert(ok == true)
			assert(inv.slots[1].id == "apple" and inv.slots[1].count == 5)
			assert(Inventory.countOf(inv, "apple") == 5)
		end,
	},
	{
		name = "add fills a part stack before using a new slot",
		run = function()
			local inv = bag({ { id = "apple", count = 18 } })
			assert(Inventory.add(inv, defs, 4, "apple", 5) == true)
			assert(inv.slots[1].count == 20, "first stack topped up to 20")
			assert(inv.slots[2].id == "apple" and inv.slots[2].count == 3, "remaining 3 in a new slot")
		end,
	},
	{
		name = "add that does not fit is refused and leaves the bag alone",
		run = function()
			local inv = bag({ { id = "apple", count = 18 }, { id = "sword", count = 1 } })
			local snapshot = Deep.copy(inv)
			local ok, reason = Inventory.add(inv, defs, 2, "apple", 3)
			assert(ok == false and reason == "full", tostring(reason))
			unchanged(inv, snapshot)
			-- control: two more apples fit in the part stack
			assert(Inventory.add(inv, defs, 2, "apple", 2) == true)
			assert(inv.slots[1].count == 20)
		end,
	},
	{
		name = "add refuses an unknown item",
		run = function()
			local inv = bag()
			local ok, reason = Inventory.add(inv, defs, 4, "ghost", 1)
			assert(ok == false and reason == "unknown_item", tostring(reason))
			assert(next(inv.slots) == nil)
			assert(Inventory.add(inv, defs, 4, "apple", 1) == true)
		end,
	},
	{
		name = "add refuses a count of 0 or 1.5",
		run = function()
			local inv = bag()
			local ok0, reason0 = Inventory.add(inv, defs, 4, "apple", 0)
			local okFraction, reasonFraction = Inventory.add(inv, defs, 4, "apple", 1.5)
			assert(ok0 == false and reason0 == "bad_count", tostring(reason0))
			assert(okFraction == false and reasonFraction == "bad_count", tostring(reasonFraction))
			assert(next(inv.slots) == nil, "nothing should have been added")
			assert(Inventory.add(inv, defs, 4, "apple", 1) == true)
			assert(Inventory.countOf(inv, "apple") == 1)
		end,
	},
	{
		name = "remove takes across two stacks",
		run = function()
			local inv = bag({ { id = "apple", count = 5 }, { id = "apple", count = 4 } })
			assert(Inventory.remove(inv, "apple", 7) == true)
			assert(Inventory.countOf(inv, "apple") == 2)
			assert(inv.slots[1] == nil, "emptied stack is cleared")
			assert(inv.slots[2].count == 2)
		end,
	},
	{
		name = "remove of more than held is refused and leaves the bag alone",
		run = function()
			local inv = bag({ { id = "apple", count = 5 }, { id = "apple", count = 4 } })
			local snapshot = Deep.copy(inv)
			local ok, reason = Inventory.remove(inv, "apple", 10)
			assert(ok == false and reason == "not_enough", tostring(reason))
			unchanged(inv, snapshot)
			assert(Inventory.remove(inv, "apple", 9) == true)
			assert(next(inv.slots) == nil)
		end,
	},
	{
		name = "move to an empty slot moves the stack",
		run = function()
			local inv = bag({ { id = "apple", count = 7 } })
			assert(Inventory.move(inv, defs, 4, 1, 3) == true)
			assert(inv.slots[1] == nil)
			assert(inv.slots[3].id == "apple" and inv.slots[3].count == 7)
		end,
	},
	{
		name = "move merges same items up to the stack limit and keeps the rest",
		run = function()
			local inv = bag({ { id = "apple", count = 15 }, { id = "apple", count = 10 } })
			assert(Inventory.move(inv, defs, 4, 1, 2) == true)
			assert(inv.slots[2].count == 20, "target filled to the limit")
			assert(inv.slots[1].count == 5, "overflow stays behind")
		end,
	},
	{
		name = "move onto a different item swaps them",
		run = function()
			local inv = bag({ { id = "apple", count = 3 }, { id = "coin", count = 9 } })
			assert(Inventory.move(inv, defs, 4, 1, 2) == true)
			assert(inv.slots[1].id == "coin" and inv.slots[1].count == 9)
			assert(inv.slots[2].id == "apple" and inv.slots[2].count == 3)
		end,
	},
	{
		name = "split moves part of a stack to an empty slot",
		run = function()
			local inv = bag({ { id = "apple", count = 10 } })
			assert(Inventory.split(inv, 4, 1, 4, 3) == true)
			assert(inv.slots[1].count == 6)
			assert(inv.slots[3].id == "apple" and inv.slots[3].count == 4)
		end,
	},
	{
		name = "split into an occupied slot is refused, into an empty one it works",
		run = function()
			local inv = bag({ { id = "apple", count = 10 }, { id = "coin", count = 1 } })
			local snapshot = Deep.copy(inv)
			local ok, reason = Inventory.split(inv, 4, 1, 4, 2)
			assert(ok == false and reason == "occupied", tostring(reason))
			unchanged(inv, snapshot)
			assert(Inventory.split(inv, 4, 1, 4, 3) == true)
			assert(inv.slots[3].count == 4)
		end,
	},
	{
		name = "equip and unequip round-trip",
		run = function()
			local inv = bag({ { id = "knife", count = 3 } })
			assert(Inventory.equip(inv, defs, 4, 1) == true)
			assert(inv.equipped.Weapon == "knife")
			assert(inv.slots[1].count == 2, "only one is taken from the stack")
			assert(Inventory.unequip(inv, defs, 4, "Weapon") == true)
			assert(inv.equipped.Weapon == nil)
			assert(inv.slots[1].count == 3, "it goes back onto the stack")
		end,
	},
	{
		name = "equip with a full bag and an occupied equip slot is refused and unchanged",
		run = function()
			local inv = bag({ { id = "knife", count = 2 }, { id = "coin", count = 1 } }, { Weapon = "sword" })
			local snapshot = Deep.copy(inv)
			local ok, reason = Inventory.equip(inv, defs, 2, 1)
			assert(ok == false and reason == "full", tostring(reason))
			unchanged(inv, snapshot)
			-- control: with room for the old weapon the swap goes through
			assert(Inventory.equip(inv, defs, 3, 1) == true)
			assert(inv.equipped.Weapon == "knife")
			assert(Inventory.countOf(inv, "sword") == 1)
		end,
	},
	{
		name = "equip refuses an item with no equip slot",
		run = function()
			local inv = bag({ { id = "apple", count = 2 } })
			local snapshot = Deep.copy(inv)
			local ok, reason = Inventory.equip(inv, defs, 4, 1)
			assert(ok == false and reason == "not_equippable", tostring(reason))
			unchanged(inv, snapshot)
			inv.slots[2] = { id = "helm", count = 1 }
			assert(Inventory.equip(inv, defs, 4, 2) == true)
			assert(inv.equipped.Head == "helm")
		end,
	},
	{
		name = "encode gives string keys and decode restores the same inventory",
		run = function()
			local inv = bag(
				{ [3] = { id = "apple", count = 4 }, [7] = { id = "coin", count = 9 } },
				{ Head = "helm" }
			)
			local saved = Inventory.encode(inv)
			assert(saved.slots["3"].id == "apple" and saved.slots["3"].count == 4)
			assert(saved.slots[3] == nil, "no numeric keys in the stored form")
			assert(saved.equipped.Head == "helm")
			local restored = Inventory.decode(saved)
			assert(Deep.equal(restored, inv), "round trip should restore the bag")
		end,
	},
	{
		name = "decode drops malformed stacks and survives a missing table",
		run = function()
			local restored = Inventory.decode({
				slots = {
					["2"] = { id = "apple", count = 0 },
					x = { id = "apple", count = 1 },
					["4"] = { id = "coin", count = 3 },
				},
			})
			assert(restored.slots[2] == nil, "a zero count is dropped")
			assert(restored.slots[4].id == "coin" and restored.slots[4].count == 3, "a good stack is kept")
			assert(next(Inventory.decode(nil).slots) == nil)
		end,
	},
}
