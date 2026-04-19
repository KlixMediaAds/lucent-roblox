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

function Network.focusAttack(ids: {string}, targetId: string, targetType: string)
	RemoteHandler.get(Config.REMOTES.FocusAttack):FireServer(ids, targetId, targetType)
end

function Network.onUnitDied(fn: (unitType: string, pos: Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitDied).OnClientEvent:Connect(fn)
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

-- mineId, income amount produced this tick
function Network.onMineIncome(fn: (string, number) -> ())
	RemoteHandler.get(Config.REMOTES.MineIncome).OnClientEvent:Connect(fn)
end

-- mineId, emitterPos, depositPositions: extraction beam VFX update
function Network.onMineBeams(fn: (string, Vector3, {Vector3}) -> ())
	RemoteHandler.get(Config.REMOTES.MineBeams).OnClientEvent:Connect(fn)
end

-- Fired when the player needs to (re)place their Command Center
function Network.onNeedCommandCenter(fn: () -> ())
	RemoteHandler.get(Config.REMOTES.NeedCommandCenter).OnClientEvent:Connect(fn)
end

-- barrackId, queue (array of unitType strings), frontProgress (0-1)
function Network.onTrainingUpdate(fn: (string, {string}, number) -> ())
	RemoteHandler.get(Config.REMOTES.TrainingUpdate).OnClientEvent:Connect(fn)
end

-- barrelTip, targetPos, upgradeType (nil = base turret)
function Network.onTurretShot(fn: (Vector3, Vector3, string?) -> ())
	RemoteHandler.get(Config.REMOTES.TurretShot).OnClientEvent:Connect(fn)
end

-- fromPos, toPos, unitType: unit landed a hit
function Network.onUnitHit(fn: (Vector3, Vector3, string) -> ())
	RemoteHandler.get(Config.REMOTES.UnitHit).OnClientEvent:Connect(fn)
end

function Network.upgradeMine(mineId: string, upgradeType: string)
	RemoteHandler.get(Config.REMOTES.UpgradeMine):FireServer(mineId, upgradeType)
end

function Network.upgradeTurret(turretId: string, upgradeType: string)
	RemoteHandler.get(Config.REMOTES.UpgradeTurret):FireServer(turretId, upgradeType)
end

-- techName
function Network.onUnlockGranted(fn: (string) -> ())
	RemoteHandler.get(Config.REMOTES.UnlockGranted).OnClientEvent:Connect(fn)
end

-- group name, options array
function Network.onUnlockChoice(fn: (string, {string}) -> ())
	RemoteHandler.get(Config.REMOTES.UnlockChoice).OnClientEvent:Connect(fn)
end

-- player chooses a grouped tech
function Network.sendUnlockChoose(techName: string)
	RemoteHandler.get(Config.REMOTES.UnlockChoose):FireServer(techName)
end

function Network.buildMonument()
	RemoteHandler.get(Config.REMOTES.BuildMonument):FireServer()
end

-- ownerUserId, timeRemaining: nil = destroyed, -1 = constructing, >0 = seconds left
function Network.onMonumentProgress(fn: (number, number?) -> ())
	RemoteHandler.get(Config.REMOTES.MonumentProgress).OnClientEvent:Connect(fn)
end

-- winnerUserId
function Network.onPlayerWon(fn: (number) -> ())
	RemoteHandler.get(Config.REMOTES.PlayerWon).OnClientEvent:Connect(fn)
end

-- Fired by server when the local player's CC takes damage (throttled ~5 s)
function Network.onCCAttacked(fn: () -> ())
	RemoteHandler.get(Config.REMOTES.CCAttacked).OnClientEvent:Connect(fn)
end

-- Fired by server when a mine owned by the local player is depleted
function Network.onMineDepletionWarning(fn: (mineId: string) -> ())
	RemoteHandler.get(Config.REMOTES.MineDepletionWarning).OnClientEvent:Connect(fn)
end

-- fromPos, toPos: medic heal beam VFX
function Network.onHealBeam(fn: (Vector3, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.HealBeam).OnClientEvent:Connect(fn)
end

-- turretId, headPos, target1?, target2?, target3?: evolved turret tentacle animation tick
function Network.onTentacleTargets(fn: (string, Vector3, Vector3?, Vector3?, Vector3?) -> ())
	RemoteHandler.get(Config.REMOTES.TentacleTargets).OnClientEvent:Connect(fn)
end

return Network
