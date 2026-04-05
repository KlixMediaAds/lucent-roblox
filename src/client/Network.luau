local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local Network = {}

function Network.trainUnit(barrackId: string, unitType: string)
	RemoteHandler.get(Config.REMOTES.TrainUnit):FireServer(barrackId, unitType)
end

function Network.moveUnits(ids: {string}, target: Vector3)
	RemoteHandler.get(Config.REMOTES.MoveUnits):FireServer(ids, target)
end

function Network.attackMoveUnits(ids: {string}, target: Vector3)
	RemoteHandler.get(Config.REMOTES.AttackMoveUnits):FireServer(ids, target)
end

-- buildingType: "Barracks" or "Mine"
function Network.placeBuilding(pos: Vector3, buildingType: string)
	RemoteHandler.get(Config.REMOTES.PlaceBuilding):FireServer(pos, buildingType)
end

function Network.onResourceSync(fn: (number) -> ())
	RemoteHandler.get(Config.REMOTES.SyncResources).OnClientEvent:Connect(fn)
end

function Network.onUnitSpawned(fn: (string, number, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitSpawned).OnClientEvent:Connect(fn)
end

-- Now carries buildingType as 4th arg
function Network.onBuildingPlaced(fn: (string, number, Vector3, string) -> ())
	RemoteHandler.get(Config.REMOTES.BuildingPlaced).OnClientEvent:Connect(fn)
end

function Network.onUnitsOrderedMove(fn: ({string}, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove).OnClientEvent:Connect(fn)
end

-- Mineral / Mine events
function Network.onSyncDeposits(fn: ({Vector3}) -> ())
	RemoteHandler.get(Config.REMOTES.SyncDeposits).OnClientEvent:Connect(fn)
end

function Network.onDepositClaimed(fn: (Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.DepositClaimed).OnClientEvent:Connect(fn)
end

-- mineId, ownerUserId, new total miner count for that mine
function Network.onMinerSpawned(fn: (string, number, number) -> ())
	RemoteHandler.get(Config.REMOTES.MinerSpawned).OnClientEvent:Connect(fn)
end

-- Fired when the player needs to (re)place their Command Center
function Network.onNeedCommandCenter(fn: () -> ())
	RemoteHandler.get(Config.REMOTES.NeedCommandCenter).OnClientEvent:Connect(fn)
end

-- barrackId, queue (array of unitType strings), frontProgress (0-1)
function Network.onTrainingUpdate(fn: (string, {string}, number) -> ())
	RemoteHandler.get(Config.REMOTES.TrainingUpdate).OnClientEvent:Connect(fn)
end

-- barrelTip, targetPos: spawn a projectile visual
function Network.onTurretShot(fn: (Vector3, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.TurretShot).OnClientEvent:Connect(fn)
end

-- fromPos, toPos, unitType: unit landed a hit
function Network.onUnitHit(fn: (Vector3, Vector3, string) -> ())
	RemoteHandler.get(Config.REMOTES.UnitHit).OnClientEvent:Connect(fn)
end

return Network
