--!strict
local Config = require("../../src/shared/Config")
local ConfigCheck = require("../../src/shared/ConfigCheck")

-- Builds a config the checks accept, then lets a test break one thing.
local function good(): any
	return {
		AutosaveSeconds = 60,
		LeaseSeconds = 180,
		LoadRetries = 5,
		CloseTimeoutSeconds = 25,
		InventoryCapacity = 24,
		EquipSlots = { "Head", "Body", "Weapon" },
		Items = {
			apple = { maxStack = 20, slot = nil },
			helm = { maxStack = 1, slot = "Head" },
		},
		Trade = { MaxOfferSlots = 8 },
		StartingItems = { { id = "apple", count = 5 } },
	}
end

local function hasProblem(problems: { string }, needle: string): boolean
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return true
		end
	end
	return false
end

return {
	{
		name = "the shipped config has no problems",
		run = function()
			local problems = ConfigCheck.check(Config)
			assert(#problems == 0, table.concat(problems, "; "))
		end,
	},
	{
		name = "a good test config passes (negative control)",
		run = function()
			assert(#ConfigCheck.check(good()) == 0)
		end,
	},
	{
		name = "lease shorter than twice the autosave is flagged",
		run = function()
			local c = good()
			c.LeaseSeconds = 100
			assert(hasProblem(ConfigCheck.check(c), "LeaseSeconds"))
			c.LeaseSeconds = 120
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "zero load retries is flagged",
		run = function()
			local c = good()
			c.LoadRetries = 0
			assert(hasProblem(ConfigCheck.check(c), "LoadRetries"))
			c.LoadRetries = 1
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "a close timeout over 28 seconds is flagged",
		run = function()
			local c = good()
			c.CloseTimeoutSeconds = 29
			assert(hasProblem(ConfigCheck.check(c), "CloseTimeoutSeconds"))
			c.CloseTimeoutSeconds = 28
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "a bad maxStack is flagged",
		run = function()
			local c = good()
			c.Items.apple.maxStack = 0
			assert(hasProblem(ConfigCheck.check(c), "maxStack"))
			c.Items.apple.maxStack = 2.5
			assert(hasProblem(ConfigCheck.check(c), "maxStack"))
			c.Items.apple.maxStack = 1
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "an item slot that is not an equip slot is flagged",
		run = function()
			local c = good()
			c.Items.helm.slot = "Feet"
			assert(hasProblem(ConfigCheck.check(c), "slot"))
			c.Items.helm.slot = "Body"
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "a starting item that does not exist is flagged",
		run = function()
			local c = good()
			c.StartingItems = { { id = "ghost", count = 1 } }
			assert(hasProblem(ConfigCheck.check(c), "ghost"))
			c.StartingItems = { { id = "helm", count = 1 } }
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
	{
		name = "MaxOfferSlots outside 1..InventoryCapacity is flagged",
		run = function()
			local c = good()
			c.Trade.MaxOfferSlots = 0
			assert(hasProblem(ConfigCheck.check(c), "MaxOfferSlots"))
			c.Trade.MaxOfferSlots = 25
			assert(hasProblem(ConfigCheck.check(c), "MaxOfferSlots"))
			c.Trade.MaxOfferSlots = 24
			assert(#ConfigCheck.check(c) == 0)
		end,
	},
}
