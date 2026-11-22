--!strict
-- Satchel client entry. Builds the UI and talks to the server. The client never changes the bag
-- itself: it sends what the player tried to do and redraws from the next Sync.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Satchel")
local Config = require(Shared:WaitForChild("Config"))

local InventoryGrid = require(script.InventoryGrid)
local Theme = require(script.Theme)
local TradeWindow = require(script.TradeWindow)

local localPlayer = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("SatchelRemotes")
local request = remotes:WaitForChild("Request") :: RemoteFunction
local sync = remotes:WaitForChild("Sync") :: RemoteEvent

local playerGui = localPlayer:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "Satchel"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- The drag ghost lives in its own gui so it draws above everything else.
local dragLayer = Instance.new("ScreenGui")
dragLayer.Name = "SatchelDrag"
dragLayer.ResetOnSpawn = false
dragLayer.IgnoreGuiInset = true
dragLayer.DisplayOrder = 20
dragLayer.Parent = playerGui

local function send(action: string, a: any?, b: any?, c: any?)
	task.spawn(function()
		request:InvokeServer(action, a, b, c)
	end)
end

local inTrade = false

-- Both are assigned below, before the player can click anything.
local tradeWindow: any
local grid: any
grid = InventoryGrid.new({
	theme = Theme,
	parent = gui,
	dragLayer = dragLayer,
	items = Config.Items,
	capacity = Config.InventoryCapacity,
	equipSlots = Config.EquipSlots,
	onMove = function(from, to)
		send("move", from, to)
	end,
	onSplit = function(from, count, to)
		send("split", from, count, to)
	end,
	onEquip = function(from)
		send("equip", from)
	end,
	onUnequip = function(slot)
		send("unequip", slot)
	end,
	onClick = function(slot, shift)
		local stack = grid.slots[slot]
		if stack == nil then
			return
		end
		if inTrade then
			-- While trading, a click puts the stack (or one of it, with Shift) on the table.
			send("tradeOffer", slot, if shift then 1 else stack.count)
		else
			local def = Config.Items[stack.id]
			if def ~= nil and def.slot ~= nil then
				send("equip", slot)
			end
		end
	end,
	onTrade = function()
		tradeWindow:togglePicker()
	end,
})

tradeWindow = TradeWindow.new({
	theme = Theme,
	parent = gui,
	items = Config.Items,
	listPlayers = function()
		local others = {}
		for _, player in Players:GetPlayers() do
			if player ~= localPlayer then
				table.insert(others, { id = player.UserId, name = player.DisplayName })
			end
		end
		return others
	end,
	send = send,
})

-- Sync sends the bag with string slot keys. Turn them back into numbers.
local function decode(saved: any): ({ [number]: { id: string, count: number } }, { [string]: string })
	local slots = {}
	for key, stack in saved.slots do
		local index = tonumber(key)
		if index ~= nil then
			slots[index] = { id = stack.id, count = stack.count }
		end
	end
	return slots, saved.equipped
end

-- Messages the server sends when it refuses something the player can't fix by trying again.
local NOTICES: { [string]: string } = {
	view_only = "Your bag is view-only on this server. Rejoin to change or trade it.",
	partner_view_only = "That player can't trade on this server right now.",
}

sync.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.notice) == "string" then
		grid:flash(NOTICES[payload.notice] or "That can't be done right now.")
	end
	if payload.inventory == nil then
		return -- a notice on its own: the bag and the trade are unchanged
	end
	local slots, equipped = decode(payload.inventory)
	grid:render(slots, equipped)
	grid:setViewOnly(payload.viewOnly == true)
	local trade = payload.trade
	inTrade = trade ~= nil and (trade.state == "open" or trade.state == "countdown")
	tradeWindow:update(payload)
end)

-- B shows and hides the bag.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.KeyCode == Enum.KeyCode.B then
		grid.root.Visible = not grid.root.Visible
	end
end)
