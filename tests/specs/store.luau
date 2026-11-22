--!strict
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local FakeDataStore = require("../fakes/FakeDataStore")
local Lease = require("../../src/server/Data/Lease")
local Migrations = require("../../src/server/Data/Migrations")
local Store = require("../../src/server/Data/Store")

local function defaultData(): { [string]: any }
	return { gold = 0, inventory = { slots = {}, equipped = {} } }
end

-- Builds one "server" over a shared backing table.
local function server(records: any, clock: any, jobId: string, overrides: { [string]: any }?)
	local ds = FakeDataStore.new(records)
	local waits: { number } = {}
	local logs: { string } = {}
	local deps: any = {
		dataStore = ds,
		lease = Lease,
		migrations = Migrations,
		clock = function()
			return clock:now()
		end,
		wait = function(seconds: number)
			table.insert(waits, seconds)
		end,
		budget = function(_kind: string)
			return 100
		end,
		jobId = jobId,
		leaseSeconds = 180,
		retries = 3,
		retryBase = 1,
		schema = 1,
		steps = {},
		defaultData = defaultData,
		log = function(message: string)
			table.insert(logs, message)
		end,
	}
	if overrides then
		for k, v in overrides do
			deps[k] = v
		end
	end
	return Store.new(deps), ds, waits, logs
end

return {
	{
		name = "a fresh load is new with default data, and save writes data and our lease",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "A")
			local session, outcome = store:load("p1")
			assert(outcome == "new", outcome)
			assert(session ~= nil)
			assert(Deep.equal(session.data, defaultData()))
			session.data.gold = 12
			assert(session:save() == true)
			assert(records.p1.data.gold == 12, "backing data should hold the save")
			assert(records.p1.lease.jobId == "A", "backing lease should be ours")
			assert(records.p1.schema == 1, "schema stamped on the record")
		end,
	},
	{
		name = "a second server is locked out until the first releases",
		run = function()
			local records = {}
			local clock = FakeClock.new(0)
			local storeA = server(records, clock, "A")
			local storeB, _, waitsB = server(records, clock, "B", { retries = 2 })
			local a = storeA:load("p1")
			assert(a ~= nil)
			local b, outcome = storeB:load("p1")
			assert(b == nil and outcome == "locked", outcome)
			assert(#waitsB == 2 and waitsB[1] == 1 and waitsB[2] == 2, "waits should be 1 then 2")
			assert(a:release() == true)
			local b2, outcome2 = storeB:load("p1")
			assert(b2 ~= nil and outcome2 == "taken", outcome2)
		end,
	},
	{
		name = "a server steals an expired lease and the old owner then finds it lost",
		run = function()
			local records = {}
			local clock = FakeClock.new(0)
			local storeA = server(records, clock, "A")
			local storeB = server(records, clock, "B")
			local a = storeA:load("p1")
			assert(a ~= nil)
			clock:advance(181)
			local b, outcome = storeB:load("p1")
			assert(b ~= nil and outcome == "stolen", outcome)
			b.data.gold = 50
			assert(b:save() == true)
			a.data.gold = 999
			assert(a:save() == false, "the old owner's save should fail")
			assert(a.lost == true, "the old owner should know it lost the lease")
			assert(records.p1.data.gold == 50, "the new owner's data must not be overwritten")
			assert(records.p1.lease.jobId == "B")
		end,
	},
	{
		name = "a throwing load is retried until it works",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "A", { retries = 3 })
			ds:failNext(2, "502 service unavailable")
			local session, outcome = store:load("p1")
			assert(session ~= nil and outcome == "new", outcome)
			assert(ds.calls == 3, "third attempt succeeds")
			assert(records.p1.lease.jobId == "A")
		end,
	},
	{
		name = "a persistent failure gives error after exactly the retry count",
		run = function()
			local store, ds = server({}, FakeClock.new(0), "A", { retries = 3 })
			ds:failNext(100, "502 service unavailable")
			local session, outcome = store:load("p1")
			assert(session == nil and outcome == "error", outcome)
			assert(ds.calls == 3, `expected 3 calls, got {ds.calls}`)
		end,
	},
	{
		name = "the request budget is waited out before the call",
		run = function()
			local readings = { 0, 0, 0, 1 }
			local index = 0
			local store, ds, waits = server({}, FakeClock.new(0), "A", {
				budget = function(_kind: string)
					index += 1
					return readings[math.min(index, #readings)]
				end,
			})
			local session = store:load("p1")
			assert(session ~= nil)
			assert(#waits == 3, `expected 3 waits, got {#waits}`)
			assert(ds.calls == 1)
		end,
	},
	{
		name = "a record from a newer schema loads read-only and only the lease is extended",
		run = function()
			local clock = FakeClock.new(0)
			local records = { p1 = { schema = 9, data = { gold = 5 }, savedAt = 0 } }
			local store = server(records, clock, "A")
			local session = store:load("p1")
			assert(session ~= nil and session.readOnly == true)
			session.data.x = 1
			clock:advance(60)
			assert(session:save() == true)
			assert(records.p1.data.x == nil, "read-only data must not be written")
			assert(records.p1.data.gold == 5)
			assert(records.p1.schema == 9)
			assert(records.p1.lease.expiresAt == 240, "lease extended from the save time")
		end,
	},
	{
		name = "releasing twice only writes once",
		run = function()
			local store, ds = server({}, FakeClock.new(0), "A")
			local session = store:load("p1")
			assert(session ~= nil)
			local before = ds.calls
			assert(session:release() == true)
			assert(ds.calls == before + 1)
			assert(session:release() == true)
			assert(ds.calls == before + 1, "second release must not call UpdateAsync")
		end,
	},
	{
		name = "saved data round-trips through release and a new store",
		run = function()
			local records = {}
			local clock = FakeClock.new(0)
			local first = server(records, clock, "A")
			local session = first:load("p1")
			assert(session ~= nil)
			session.data.inventory.slots[3] = { id = "apple", count = 4 }
			assert(session:save() == true)
			assert(session:release() == true)
			local second = server(records, clock, "B")
			local again, outcome = second:load("p1")
			assert(again ~= nil and outcome == "taken", outcome)
			assert(again.data.inventory.slots[3].id == "apple" and again.data.inventory.slots[3].count == 4)
		end,
	},
	{
		name = "encode and decode hooks shape what is stored and what the session holds",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "A", {
				encode = function(data: any)
					return { packed = data.gold }
				end,
				decode = function(saved: any)
					return { gold = saved.packed or 0 }
				end,
			})
			local session = store:load("p1")
			assert(session ~= nil)
			session.data.gold = 7
			assert(session:save() == true)
			assert(
				records.p1.data.packed == 7 and records.p1.data.gold == nil,
				"stored form is the encoded one"
			)
			assert(session:release() == true)
			local again = store:load("p1")
			assert(again ~= nil and again.data.gold == 7, "session data is the decoded form")
		end,
	},
}
