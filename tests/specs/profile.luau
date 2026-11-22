--!strict
-- What a new profile holds and how it is stored.
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Inventory = require("../../src/server/Inventory/Inventory")
local Profile = require("../../src/server/Data/Profile")
local StoreServer = require("../fakes/StoreServer")

local defs = { apple = { maxStack = 20 }, gem = { maxStack = 1 } }

local function profile(starting: { { id: string, count: number } }?): any
	return Profile.new({
		inventory = Inventory,
		defs = defs,
		capacity = 24,
		startingItems = starting or { { id = "apple", count = 5 } },
	})
end

return {
	{
		name = "a new profile already holds the starting items",
		run = function()
			local data = profile().defaultData()
			assert(Inventory.countOf(data.inventory, "apple") == 5)
			-- control: no starting items, an empty bag
			local empty = profile({}).defaultData()
			assert(Inventory.countOf(empty.inventory, "apple") == 0 and next(empty.inventory.slots) == nil)
		end,
	},
	{
		name = "starting items are written by the first claim, once, even if the player leaves at once",
		run = function()
			local p = profile()
			local records: any = {}
			local store = StoreServer.new(records, FakeClock.new(0), "JOB", {
				defaultData = p.defaultData,
				encode = p.encode,
				decode = p.decode,
			})
			local first, outcome = store:load("p1")
			assert(first ~= nil and outcome == "new", outcome)
			local stored = Inventory.decode(records.p1.data.inventory)
			assert(Inventory.countOf(stored, "apple") == 5, "the claim itself wrote the starting items")
			assert(first:release() == true) -- they left before any save
			local again, outcome2 = store:load("p1")
			assert(again ~= nil and outcome2 == "taken", outcome2)
			assert(Inventory.countOf(again.data.inventory, "apple") == 5, "granted once, not again")
		end,
	},
	{
		name = "encode and decode keep every field, not only the bag",
		run = function()
			local p = profile()
			local fresh = p.defaultData()
			assert(Deep.equal(p.decode(p.encode(fresh)), fresh), "defaults round-trip whole")
			local data = p.defaultData()
			data.gold = 7
			data.settings = { music = false }
			data.inventory.slots[4] = { id = "gem", count = 1 }
			data.inventory.slots[1] = nil -- a bag with gaps
			local saved = p.encode(data)
			assert(saved.gold == 7 and saved.settings.music == false, "fields outside the bag are stored")
			assert(saved.inventory.slots["4"] ~= nil, "the bag is stored with string keys")
			assert(Deep.equal(p.decode(saved), data), "and everything comes back as it was")
		end,
	},
	{
		name = "encode copies, so a payload never shares tables with the session",
		run = function()
			local p = profile()
			local data = p.defaultData()
			data.settings = { music = true }
			local saved = p.encode(data)
			saved.settings.music = false
			saved.inventory.slots["1"].count = 99
			assert(data.settings.music == true and data.inventory.slots[1].count == 5)
		end,
	},
	{
		name = "decode refuses saved data that isn't a table",
		run = function()
			local p = profile()
			assert(not pcall(p.decode, nil))
			assert(not pcall(p.decode, "junk"))
			-- control
			assert(pcall(p.decode, p.encode(p.defaultData())))
		end,
	},
}
