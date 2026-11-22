--!strict
return table.freeze({
	DataStoreName = "SatchelPlayerData_v1", -- change it and every player starts fresh
	SchemaVersion = 1, -- bump when the saved data shape changes, and add a migration step
	AutosaveSeconds = 60, -- how often each session is written
	LeaseSeconds = 180, -- must be well over AutosaveSeconds, or a busy server loses its own lock
	LoadRetries = 5, -- attempts to load a profile before giving up
	RetryBaseSeconds = 1, -- doubles each retry: 1, 2, 4, 8, 16
	CloseTimeoutSeconds = 25, -- BindToClose gets about 30 s in total, leave headroom
	InventoryCapacity = 24, -- number of bag slots
	EquipSlots = table.freeze({ "Head", "Body", "Weapon" }), -- named slots an item can be worn in
	Items = table.freeze({ -- item definitions, keyed by id
		apple = table.freeze({ name = "Apple", maxStack = 20, slot = nil, colour = { 200, 60, 60 } }),
		bread = table.freeze({ name = "Bread", maxStack = 10, slot = nil, colour = { 210, 170, 100 } }),
		coin = table.freeze({ name = "Gold Coin", maxStack = 99, slot = nil, colour = { 240, 200, 60 } }),
		leather_cap = table.freeze({
			name = "Leather Cap",
			maxStack = 1,
			slot = "Head",
			colour = { 140, 100, 70 },
		}),
		iron_helm = table.freeze({
			name = "Iron Helm",
			maxStack = 1,
			slot = "Head",
			colour = { 150, 155, 165 },
		}),
		tunic = table.freeze({ name = "Tunic", maxStack = 1, slot = "Body", colour = { 70, 120, 190 } }),
		wooden_sword = table.freeze({
			name = "Wooden Sword",
			maxStack = 1,
			slot = "Weapon",
			colour = { 170, 130, 80 },
		}),
		throwing_knife = table.freeze({
			name = "Throwing Knife",
			maxStack = 5,
			slot = "Weapon",
			colour = { 190, 195, 205 },
		}),
	}),
	Trade = table.freeze({ -- trade window rules
		MaxOfferSlots = 8, -- stacks one side can put on the table
		CountdownSeconds = 3, -- both confirmed, then this long before items move
		RequestTimeoutSeconds = 20, -- an unanswered request lapses after this
		MaxDistance = 20, -- studs between the two players
	}),
	Limits = table.freeze({ BurstPerPlayer = 10, RefillPerSecond = 4 }), -- remote rate limit per player
	StartingItems = table.freeze({ { id = "apple", count = 5 } }), -- granted to a brand new profile
})
