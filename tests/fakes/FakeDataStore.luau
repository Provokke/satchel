--!strict
-- In-memory stand-in for a DataStore. Two instances built on the same `records` table behave
-- like two servers talking to one store.
local Deep = require("./Deep")

local FakeDataStore = {}
FakeDataStore.__index = FakeDataStore

export type FakeDataStore = typeof(setmetatable(
	{} :: { records: { [string]: any }, calls: number, failures: number, failMessage: string },
	FakeDataStore
))

function FakeDataStore.new(records: { [string]: any }?): FakeDataStore
	return setmetatable({ records = records or {}, calls = 0, failures = 0, failMessage = "" }, FakeDataStore)
end

function FakeDataStore.failNext(self: FakeDataStore, n: number, message: string)
	self.failures = n
	self.failMessage = message
end

function FakeDataStore.UpdateAsync(self: FakeDataStore, key: string, transform: (any) -> any): any
	self.calls += 1
	if self.failures > 0 then
		self.failures -= 1
		error(self.failMessage)
	end
	local stored = Deep.copy(self.records[key])
	local result = transform(stored)
	if result == nil then
		return stored
	end
	self.records[key] = Deep.copy(result)
	return Deep.copy(result)
end

return FakeDataStore
