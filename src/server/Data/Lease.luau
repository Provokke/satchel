--!strict
-- Session lease rules. A lease says "this server owns this record until expiresAt".
--
-- UpdateAsync may call a transform more than once, so the transforms must be pure and must not
-- mutate `stored`. They build a new table.
local Lease = {}

export type LeaseInfo = { jobId: string, expiresAt: number }
export type Record = { schema: number, data: { [string]: any }, lease: LeaseInfo?, savedAt: number }

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local function build(stored: Record, data: { [string]: any }, lease: LeaseInfo?, now: number): Record
	return { schema = stored.schema, data = data, lease = lease, savedAt = now }
end

-- Load transform. Outcomes: "new", "taken", "stolen", or "held" (returns nil, so UpdateAsync cancels).
-- A new record carries schema 0: the caller stamps the real schema version.
function Lease.claim(
	stored: Record?,
	jobId: string,
	now: number,
	leaseSeconds: number,
	defaultData: () -> { [string]: any }
): (Record?, string)
	local mine: LeaseInfo = { jobId = jobId, expiresAt = now + leaseSeconds }
	if stored == nil then
		return { schema = 0, data = defaultData(), lease = mine, savedAt = now }, "new"
	end
	local theirs = stored.lease
	local outcome = "taken"
	if theirs ~= nil and theirs.jobId ~= jobId then
		if theirs.expiresAt > now then
			return nil, "held"
		end
		outcome = "stolen"
	end
	return build(stored, deepCopy(stored.data), mine, now), outcome
end

local function owns(stored: Record?, jobId: string): boolean
	return stored ~= nil and stored.lease ~= nil and stored.lease.jobId == jobId
end

-- Autosave transform. "saved", or "lost" when the lease is missing or not ours (returns nil).
function Lease.refresh(
	stored: Record?,
	jobId: string,
	now: number,
	leaseSeconds: number,
	data: { [string]: any },
	writeData: boolean
): (Record?, string)
	if stored == nil or not owns(stored, jobId) then
		return nil, "lost"
	end
	local nextData = if writeData then deepCopy(data) else deepCopy(stored.data)
	return build(stored, nextData, { jobId = jobId, expiresAt = now + leaseSeconds }, now), "saved"
end

-- Leave transform. Writes data (if writeData) and clears the lease. "released" or "lost".
function Lease.release(
	stored: Record?,
	jobId: string,
	now: number,
	data: { [string]: any },
	writeData: boolean
): (Record?, string)
	if stored == nil or not owns(stored, jobId) then
		return nil, "lost"
	end
	local nextData = if writeData then deepCopy(data) else deepCopy(stored.data)
	return build(stored, nextData, nil, now), "released"
end

return Lease
