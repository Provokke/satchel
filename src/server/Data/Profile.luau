--!strict
-- The shape of one player's saved data: what a brand new profile holds, and how the session form
-- is turned into the stored form and back. The Inventory module and the item rules come in
-- through `Profile.new`.
--
-- encode and decode copy every field and reshape only `inventory`, so a field added to
-- defaultData is saved and loaded without anyone having to remember to list it here.
local Profile = {}

type Data = { [string]: any }

export type Deps = {
	inventory: any, -- the Inventory module
	defs: any, -- item definitions
	capacity: number,
	startingItems: { { id: string, count: number } },
}

export type Profile = {
	defaultData: () -> Data,
	encode: (data: Data) -> Data,
	decode: (saved: Data) -> Data,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

function Profile.new(deps: Deps): Profile
	local Inventory = deps.inventory

	-- The starting items are part of the default data, so the claim that creates the record
	-- writes them. A player who leaves (or a server that crashes) before the first save still
	-- has them next time, and they are never granted twice.
	local function defaultData(): Data
		local inv = Inventory.empty()
		for _, item in deps.startingItems do
			Inventory.add(inv, deps.defs, deps.capacity, item.id, item.count)
		end
		return { inventory = inv }
	end

	-- Session form to stored form. Runs inside UpdateAsync transforms, so it must not yield.
	local function encode(data: Data): Data
		local out = deepCopy(data)
		out.inventory = Inventory.encode(data.inventory)
		return out
	end

	-- Stored form to session form. Data that isn't a table is refused, so the load fails and the
	-- record is left alone instead of being opened as an empty profile.
	local function decode(saved: Data): Data
		if type(saved) ~= "table" then
			error("saved data is not a table")
		end
		local out = deepCopy(saved)
		out.inventory = Inventory.decode(saved.inventory)
		return out
	end

	return { defaultData = defaultData, encode = encode, decode = decode }
end

return Profile
