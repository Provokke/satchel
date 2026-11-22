--!strict
-- Start-up sanity checks for Config. Returns a list of problems, empty when the config is fine.
local ConfigCheck = {}

function ConfigCheck.check(config: any): { string }
	local problems: { string } = {}
	local function add(message: string)
		table.insert(problems, message)
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
