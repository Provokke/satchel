--!strict
-- Start-up sanity checks for Config and the migration steps. Returns a list of problems, empty
-- when everything is fine.
local ConfigCheck = {}

function ConfigCheck.check(config: any, steps: { any }): { string }
	local problems: { string } = {}
	local function add(message: string)
		table.insert(problems, message)
	end

	local schema = config.SchemaVersion
	if type(schema) ~= "number" or schema < 1 or schema % 1 ~= 0 then
		add("SchemaVersion must be a whole number of 1 or more")
	else
		-- A missing step only shows up when an old record loads, so catch it at start-up instead.
		local count = 0
		for _ in steps do
			count += 1
		end
		local allFunctions = true
		for i = 1, schema - 1 do
			if type(steps[i]) ~= "function" then
				allFunctions = false
			end
		end
		if count ~= schema - 1 or not allFunctions then
			add(`SchemaVersion {schema} needs exactly {schema - 1} migration step(s), one per bump`)
		end
	end

	if config.LeaseSeconds < 2 * config.AutosaveSeconds then
		add("LeaseSeconds must be at least twice AutosaveSeconds")
	end
	if config.LoadRetries < 1 then
		add("LoadRetries must be at least 1")
	end
	if config.CloseTimeoutSeconds > 28 then
		add("CloseTimeoutSeconds must be 28 or less, BindToClose only gets about 30 seconds")
	end

	local equipSlots: { [string]: boolean } = {}
	for _, slot in config.EquipSlots do
		equipSlots[slot] = true
	end

	for id, def in config.Items do
		local maxStack = def.maxStack
		if type(maxStack) ~= "number" or maxStack < 1 or maxStack % 1 ~= 0 then
			add(`item {id}: maxStack must be an integer of 1 or more`)
		end
		if def.slot ~= nil and not equipSlots[def.slot] then
			add(`item {id}: slot "{tostring(def.slot)}" is not one of EquipSlots`)
		end
	end

	for _, entry in config.StartingItems do
		if config.Items[entry.id] == nil then
			add(`StartingItems refers to unknown item "{tostring(entry.id)}"`)
		end
	end

	local offers = config.Trade.MaxOfferSlots
	if offers < 1 or offers > config.InventoryCapacity then
		add("Trade.MaxOfferSlots must be between 1 and InventoryCapacity")
	end

	return problems
end

return ConfigCheck
