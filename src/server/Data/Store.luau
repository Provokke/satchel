--!strict
-- Session-locked player data over a DataStore. Every dependency comes in through `Store.new`.
--
-- load() claims the record with a lease, save() refreshes it, release() hands it back. Each call
-- is one UpdateAsync, so the lease check and the write happen together on the DataStore side.
local Store = {}
Store.__index = Store

local Session = {}
Session.__index = Session

type Data = { [string]: any }

export type Deps = {
	dataStore: { UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any },
	lease: any,
	migrations: any, -- the Lease and Migrations modules
	clock: () -> number,
	wait: (seconds: number) -> (),
	budget: (kind: string) -> number, -- "update"; the entry script maps it to Enum.DataStoreRequestType.UpdateAsync
	jobId: string,
	leaseSeconds: number,
	retries: number,
	retryBase: number,
	schema: number,
	steps: { (any) -> any },
	defaultData: () -> Data,
	log: (message: string) -> (),
	-- Optional. encode turns session data into the form that is stored (for example, no sparse
	-- arrays); decode reverses it. Migrations run on the stored form.
	encode: ((data: Data) -> Data)?,
	decode: ((saved: Data) -> Data)?,
}

export type Session = typeof(setmetatable(
	{} :: {
		key: string,
		data: Data,
		readOnly: boolean,
		lost: boolean,
		released: boolean,
		deps: Deps,
	},
	Session
))

export type Store = typeof(setmetatable({} :: { deps: Deps }, Store))

local BUDGET_WAIT_LIMIT = 10 -- seconds spent waiting for request budget before calling anyway

local function waitForBudget(deps: Deps)
	local waited = 0
	while deps.budget("update") < 1 and waited < BUDGET_WAIT_LIMIT do
		deps.wait(1)
		waited += 1
	end
end

-- Runs one UpdateAsync through pcall. `transform` returns the new record and an outcome string;
-- UpdateAsync only ever sees the record. Returns ok, the outcome of the last transform run
-- (UpdateAsync may run it more than once) and the record it produced.
local function update(
	deps: Deps,
	key: string,
	transform: (stored: any) -> (any, string)
): (boolean, string?, any)
	waitForBudget(deps)
	local outcome: string? = nil
	local produced: any = nil
	local ok, err = pcall(function()
		return deps.dataStore:UpdateAsync(key, function(stored: any)
			local record, result = transform(stored)
			outcome = result
			produced = record
			return record
		end)
	end)
	if not ok then
		deps.log(`UpdateAsync failed for {key}: {tostring(err)}`)
		return false, nil, nil
	end
	return true, outcome, produced
end

function Store.new(deps: Deps): Store
	return setmetatable({ deps = deps }, Store)
end

function Store.load(self: Store, key: string): (Session?, string)
	local deps = self.deps
	local encode = deps.encode
	local decode = deps.decode
	local function freshData(): Data
		local data = deps.defaultData()
		if encode then
			return encode(data)
		end
		return data
	end

	local lastFailure = "error"
	for attempt = 1, deps.retries do
		local ok, outcome, record = update(deps, key, function(stored: any)
			local claimed, result =
				deps.lease.claim(stored, deps.jobId, deps.clock(), deps.leaseSeconds, freshData)
			if claimed ~= nil and result == "new" then
				claimed.schema = deps.schema
			end
			return claimed, result
		end)
		if ok and outcome ~= "held" and record ~= nil then
			local saved, readOnly = deps.migrations.run(record, deps.steps, deps.schema)
			local data = if decode then decode(saved) else saved
			local session = setmetatable({
				key = key,
				data = data,
				readOnly = readOnly,
				lost = false,
				released = false,
				deps = deps,
			}, Session)
			return session, outcome :: string
		end
		lastFailure = if ok then "locked" else "error"
		deps.wait(deps.retryBase * 2 ^ (attempt - 1))
	end
	return nil, lastFailure
end

local function stored(session: Session): Data
	local encode = session.deps.encode
	if encode then
		return encode(session.data)
	end
	return session.data
end

function Session.save(self: Session): boolean
	if self.lost or self.released then
		return false
	end
	local deps = self.deps
	local writeData = not self.readOnly
	local payload = stored(self)
	local ok, outcome = update(deps, self.key, function(current: any)
		local record, result =
			deps.lease.refresh(current, deps.jobId, deps.clock(), deps.leaseSeconds, payload, writeData)
		if record ~= nil and writeData then
			record.schema = deps.schema
		end
		return record, result
	end)
	if not ok then
		return false -- a failed write is not a lost lease: the next autosave tries again
	end
	if outcome == "lost" then
		self.lost = true
		deps.log(`lease lost for {self.key}`)
		return false
	end
	return true
end

function Session.release(self: Session): boolean
	if self.released then
		return true
	end
	if self.lost then
		return false
	end
	local deps = self.deps
	local writeData = not self.readOnly
	local payload = stored(self)
	local attempts = math.min(deps.retries, 3)
	for attempt = 1, attempts do
		local ok, outcome = update(deps, self.key, function(current: any)
			local record, result = deps.lease.release(current, deps.jobId, deps.clock(), payload, writeData)
			if record ~= nil and writeData then
				record.schema = deps.schema
			end
			return record, result
		end)
		if ok then
			if outcome == "lost" then
				self.lost = true
				deps.log(`lease lost for {self.key}`)
				return false
			end
			self.released = true
			return true
		end
		if attempt < attempts then
			deps.wait(deps.retryBase * 2 ^ (attempt - 1))
		end
	end
	return false
end

return Store
