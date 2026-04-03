local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local ResourceManager   = {}
local store: {[number]: number} = {}

local function sync(player: Player)
	RemoteHandler.get(Config.REMOTES.SyncResources):FireClient(player, store[player.UserId] or 0)
end

function ResourceManager.init()
	Players.PlayerAdded:Connect(function(player)
		store[player.UserId] = Config.STARTING_RESOURCES
		task.defer(sync, player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		store[player.UserId] = nil
	end)
end

function ResourceManager.get(player: Player): number
	return store[player.UserId] or 0
end

function ResourceManager.spend(player: Player, amount: number): boolean
	local current = store[player.UserId] or 0
	if current < amount then return false end
	store[player.UserId] = current - amount
	sync(player)
	return true
end

function ResourceManager.add(player: Player, amount: number)
	store[player.UserId] = (store[player.UserId] or 0) + amount
	sync(player)
end

return ResourceManager
