--!strict
-- Lease ownership across sessions, retries and releases.
local FakeClock = require("../fakes/FakeClock")
local StoreServer = require("../fakes/StoreServer")

local server = StoreServer.new

return {
	{
		name = "two loads of one key on one server don't share the lease",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "JOB")
			local first = store:load("p1")
			assert(first ~= nil)
			local second, outcome = store:load("p1")
			assert(second == nil and outcome == "locked", `same-server reload must be locked, got {outcome}`)
			assert(records.p1.lease.owner == first.owner, "the first session still holds the lease")
			-- control: once the first session has released, the same server loads it again
			assert(first:release() == true)
			local third, outcome3 = store:load("p1")
			assert(third ~= nil and outcome3 == "taken", outcome3)
			assert(third.owner ~= first.owner, "a new session gets a new owner")
			assert(records.p1.lease.owner == third.owner)
			third.data.gold = 9
			assert(third:save() == true and records.p1.data.gold == 9)
		end,
	},
	{
		name = "a session's lease owner is the job id plus a nonce from the load",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "JOB", {
				nonce = function()
					return "fixed-guid"
				end,
			})
			local session = store:load("p1")
			assert(session ~= nil and session.owner == "JOB:fixed-guid", session and session.owner)
			assert(records.p1.lease.owner == "JOB:fixed-guid")
		end,
	},
	{
		name = "a claim that landed but errored is retried as this session's own lease",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "JOB")
			ds:commitThenFailNext(1, "timed out")
			local session, outcome = store:load("p1")
			assert(session ~= nil and outcome == "taken", `expected taken on the retry, got {outcome}`)
			assert(ds.calls == 2)
			assert(records.p1.lease.owner == session.owner)
			-- control: a different session on the same server is still locked out
			local other, otherOutcome = store:load("p1")
			assert(other == nil and otherOutcome == "locked", otherOutcome)
		end,
	},
}
