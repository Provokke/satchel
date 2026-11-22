--!strict
-- Satchel server entry. This is where services, remotes and the DataStore are touched. The rules
-- themselves live in the leaf modules next to it and are covered by the Lune tests.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Satchel")
local Config = require(Shared:WaitForChild("Config"))
local ConfigCheck = require(Shared:WaitForChild("ConfigCheck"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Validate = require(Shared:WaitForChild("Validate"))

local Handlers = require(script.Handlers)
local Inventory = require(script.Inventory.Inventory)
local Lease = require(script.Data.Lease)
local MemoryStore = require(script.Data.MemoryStore)
local Migrations = require(script.Data.Migrations)
local Steps = require(script.Data.Steps)
local Store = require(script.Data.Store)
local Trade = require(script.Trade.Trade)

local problems = ConfigCheck.check(Config, Steps)
if #problems > 0 then
	for _, problem in problems do
		warn("[Satchel] config problem: " .. problem)
	end
	warn("[Satchel] not starting until the config is fixed")
	return
end

-- Data store. Studio uses an in-memory table unless ServerStorage has SatchelUseDataStore = true.
local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("SatchelUseDataStore") == true
local dataStore: any
if useRealStore then
	dataStore = DataStoreService:GetDataStore(Config.DataStoreName)
else
	dataStore = MemoryStore.new()
	print(
		"[Satchel] Studio: using an in-memory store. Set ServerStorage attribute SatchelUseDataStore to use the real one."
	)
end

local jobId = if game.JobId ~= "" then game.JobId else "studio"

local store = Store.new({
	dataStore = dataStore,
	lease = Lease,
	migrations = Migrations,
	clock = os.time,
	wait = task.wait,
	budget = function(_kind: string): number
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end,
	jobId = jobId,
	nonce = function(): string
		return HttpService:GenerateGUID(false)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	leaseSeconds = Config.LeaseSeconds,
	retries = Config.LoadRetries,
	retryBase = Config.RetryBaseSeconds,
	schema = Config.SchemaVersion,
	steps = Steps,
	defaultData = function()
		return { inventory = Inventory.empty() }
	end,
	log = function(message: string)
		warn("[Satchel] " .. message)
	end,
	-- The bag is stored with string slot keys, so a bag with gaps never becomes a sparse array.
	encode = function(data)
		return { inventory = Inventory.encode(data.inventory) }
	end,
	decode = function(saved)
		return { inventory = Inventory.decode(saved.inventory) }
	end,
})

local sessions: { [number]: any } = {}
local releasing = 0

-- waitLimit is how long the release may spend retrying; nil means the store's default (the lease
-- length), which is right while the server is running.
local function releaseSession(session: any, waitLimit: number?)
	releasing += 1
	task.spawn(function()
		local ok, err = pcall(function()
			session:release(waitLimit)
		end)
		if not ok then
			warn("[Satchel] release failed: " .. tostring(err))
		end
		releasing -= 1
	end)
end

local function liveInventory(userId: number): any
	local session = sessions[userId]
	if session == nil or session.lost then
		return nil
	end
	return session.data.inventory
end

-- A read-only or lost session can be looked at but must not change or trade: nothing it does
-- would be saved.
local function writable(userId: number): boolean
	local session = sessions[userId]
	return session ~= nil and not session.lost and not session.readOnly
end

-- Remotes
local remotes = Instance.new("Folder")
remotes.Name = "SatchelRemotes"
local request = Instance.new("RemoteFunction")
request.Name = "Request"
request.Parent = remotes
local sync = Instance.new("RemoteEvent")
sync.Name = "Sync"
sync.Parent = remotes
remotes.Parent = ReplicatedStorage

local equipSlots: { [string]: boolean } = {}
for _, slot in Config.EquipSlots do
	equipSlots[slot] = true
end

local function positionOf(userId: number): Vector3?
	local player = Players:GetPlayerByUserId(userId)
	local character = if player then player.Character else nil
	if character == nil then
		return nil
	end
	return character:GetPivot().Position
end

local limiter = RateLimiter.new(Config.Limits.BurstPerPlayer, Config.Limits.RefillPerSecond, os.clock)

local handlers: any
handlers = Handlers.new({
	validate = Validate,
	inventory = Inventory,
	newTrade = function(a: number, b: number)
		return Trade.new(a, b, {
			inventory = Inventory,
			defs = Config.Items,
			capacity = Config.InventoryCapacity,
			clock = os.clock,
			countdown = Config.Trade.CountdownSeconds,
			maxOfferSlots = Config.Trade.MaxOfferSlots,
			getInventory = liveInventory,
			writable = writable,
		})
	end,
	defs = Config.Items,
	capacity = Config.InventoryCapacity,
	equipSlots = equipSlots,
	limiter = limiter,
	getInventory = liveInventory,
	writable = writable,
	tell = function(userId: number, notice: string)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			sync:FireClient(player, { notice = notice })
		end
	end,
	isNear = function(a: number, b: number): boolean
		local pa, pb = positionOf(a), positionOf(b)
		return pa ~= nil and pb ~= nil and (pa - pb).Magnitude <= Config.Trade.MaxDistance
	end,
	clock = os.clock,
	countdown = Config.Trade.CountdownSeconds,
	requestTimeout = Config.Trade.RequestTimeoutSeconds,
	notify = function(userId: number)
		local player = Players:GetPlayerByUserId(userId)
		local inv = liveInventory(userId)
		if player == nil or inv == nil then
			return
		end
		local view = handlers:view(userId)
		local function nameOf(id: number?): string
			local other = if id then Players:GetPlayerByUserId(id) else nil
			return if other then other.DisplayName else "Someone"
		end
		if view.trade then
			view.trade.withName = nameOf(view.trade.withId)
		end
		if view.request then
			view.request.fromName = nameOf(view.request.fromId)
		end
		sync:FireClient(player, {
			inventory = Inventory.encode(inv),
			viewOnly = not writable(userId),
			trade = view.trade,
			request = view.request,
			sentTo = view.sentTo,
		})
	end,
	-- A trade writes two DataStore keys, which is not atomic. Both are saved straight away. Each
	-- save builds its payload when it writes, and saves for one session queue rather than race,
	-- so an older autosave can't land after this save. A crash between the two writes can still
	-- lose or duplicate the traded items.
	onTradeDone = function(a: number, b: number)
		for _, userId in { a, b } do
			local session = sessions[userId]
			if session ~= nil then
				task.spawn(function()
					session:save()
				end)
			end
		end
	end,
})

request.OnServerInvoke = function(player: Player, action: any, a: any, b: any, c: any)
	local ok, err = pcall(function()
		handlers:handle(player.UserId, action, a, b, c)
	end)
	if not ok then
		warn("[Satchel] request error: " .. tostring(err))
	end
	-- Nothing is sent back. The client learns the result from the next Sync.
	return nil
end

-- Sessions
local function onPlayerAdded(player: Player)
	local userId = player.UserId
	local session, outcome = store:load("Player_" .. userId)
	if session == nil then
		if outcome == "locked" then
			player:Kick("Your data is still open on another server. Rejoin in a minute.")
		else
			player:Kick("Couldn't load your data. Please rejoin.")
		end
		return
	end
	if player.Parent == nil then
		releaseSession(session) -- they left while the load was running
		return
	end
	if outcome == "new" then
		for _, item in Config.StartingItems do
			Inventory.add(session.data.inventory, Config.Items, Config.InventoryCapacity, item.id, item.count)
		end
	end
	sessions[userId] = session
	local inv = liveInventory(userId)
	if inv ~= nil then
		sync:FireClient(player, { inventory = Inventory.encode(inv), viewOnly = not writable(userId) })
	end
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	handlers:playerLeft(userId)
	limiter:forget(userId)
	local session = sessions[userId]
	sessions[userId] = nil
	if session ~= nil then
		releaseSession(session)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Trade countdowns, drifting players and lapsed requests.
task.spawn(function()
	while true do
		task.wait(0.25)
		handlers:tick()
	end
end)

-- Autosave. A session that has lost its lease is kicked rather than allowed to carry on unsaved.
task.spawn(function()
	while true do
		task.wait(Config.AutosaveSeconds)
		for userId, session in sessions do
			task.spawn(function()
				if not session:save() and session.lost then
					local player = Players:GetPlayerByUserId(userId)
					if player then
						player:Kick("Your data was opened on another server.")
					end
				end
			end)
		end
	end
end)

game:BindToClose(function()
	for userId, session in sessions do
		sessions[userId] = nil
		releaseSession(session, Config.CloseTimeoutSeconds)
	end
	local deadline = os.clock() + Config.CloseTimeoutSeconds
	while releasing > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)
