local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local Network = {}

function Network.spawnUnit(pos: Vector3)
	RemoteHandler.get(Config.REMOTES.SpawnUnit):FireServer(pos)
end

function Network.moveUnits(ids: {string}, target: Vector3)
	RemoteHandler.get(Config.REMOTES.MoveUnits):FireServer(ids, target)
end

function Network.placeBuilding(pos: Vector3)
	RemoteHandler.get(Config.REMOTES.PlaceBuilding):FireServer(pos)
end

function Network.onResourceSync(fn: (number) -> ())
	RemoteHandler.get(Config.REMOTES.SyncResources).OnClientEvent:Connect(fn)
end

function Network.onUnitSpawned(fn: (string, number, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitSpawned).OnClientEvent:Connect(fn)
end

function Network.onBuildingPlaced(fn: (string, number, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.BuildingPlaced).OnClientEvent:Connect(fn)
end

function Network.onUnitsOrderedMove(fn: ({string}, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove).OnClientEvent:Connect(fn)
end

return Network
