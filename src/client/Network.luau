local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local Network = {}

function Network.trainUnit(barrackIds: {string}, unitType: string)
	RemoteHandler.get(Config.REMOTES.TrainUnit):FireServer(barrackIds, unitType)
end

function Network.moveUnits(ids: {string}, target: Vector3)
	RemoteHandler.get(Config.REMOTES.MoveUnits):FireServer(ids, target)
end

function Network.attackMoveUnits(ids: {string}, target: Vector3)
	RemoteHandler.get(Config.REMOTES.AttackMoveUnits):FireServer(ids, target)
end

-- Drag-formation move: parallel arrays — positions[i] is the slot for ids[i].
function Network.formationMove(ids: {string}, positions: {Vector3}, attackMove: boolean)
	RemoteHandler.get(Config.REMOTES.FormationMove):FireServer(ids, positions, attackMove)
end

function Network.focusAttack(ids: {string}, targetId: string, targetType: string)
	RemoteHandler.get(Config.REMOTES.FocusAttack):FireServer(ids, targetId, targetType)
end

-- Re-kit the given units into `toType` (e.g. upgrade selected Survivors to Snipers).
function Network.upgradeUnit(ids: {string}, toType: string)
	RemoteHandler.get(Config.REMOTES.UpgradeUnit):FireServer(ids, toType)
end

function Network.onUnitDied(fn: (unitType: string, pos: Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.UnitDied).OnClientEvent:Connect(fn)
end

-- buildingType: "Barracks", "Foundry", etc.
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

-- Mineral deposit events
function Network.onSyncDeposits(fn: ({Vector3}) -> ())
	RemoteHandler.get(Config.REMOTES.SyncDeposits).OnClientEvent:Connect(fn)
end

-- foundryId, income earned this tick → drives the floating "+N" popup
function Network.onFoundryIncome(fn: (string, number) -> ())
	RemoteHandler.get(Config.REMOTES.FoundryIncome).OnClientEvent:Connect(fn)
end

-- Engineering Post research
function Network.engineeringStart(buildingId: string)
	RemoteHandler.get(Config.REMOTES.EngineeringStart):FireServer(buildingId)
end
function Network.engineeringCollect(buildingId: string)
	RemoteHandler.get(Config.REMOTES.EngineeringCollect):FireServer(buildingId)
end
function Network.engineeringRequest(buildingId: string)
	RemoteHandler.get(Config.REMOTES.EngineeringRequest):FireServer(buildingId)
end
-- buildingId, payload { state, remaining, history, discovery? }
function Network.onEngineeringSync(fn: (string, any) -> ())
	RemoteHandler.get(Config.REMOTES.EngineeringSync).OnClientEvent:Connect(fn)
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

function Network.upgradeTurret(turretIds: {string}, upgradeType: string)
	RemoteHandler.get(Config.REMOTES.UpgradeTurret):FireServer(turretIds, upgradeType)
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

-- Player clicked UPGRADE on a tech in the research panel.
function Network.requestUpgrade(techName: string)
	RemoteHandler.get(Config.REMOTES.RequestUpgrade):FireServer(techName)
end

-- techName, endTime (server clock seconds): a research has begun
function Network.onUpgradeStarted(fn: (string, number) -> ())
	RemoteHandler.get(Config.REMOTES.UpgradeStarted).OnClientEvent:Connect(fn)
end

-- { kills, builds, trained } progress payload from server
function Network.onCondProgressSync(fn: (any) -> ())
	RemoteHandler.get(Config.REMOTES.CondProgressSync).OnClientEvent:Connect(fn)
end

function Network.buildMonument()
	RemoteHandler.get(Config.REMOTES.BuildMonument):FireServer()
end

-- ownerUserId, timeRemaining: nil = destroyed, -1 = constructing, >0 = seconds left
function Network.onMonumentProgress(fn: (number, number?) -> ())
	RemoteHandler.get(Config.REMOTES.MonumentProgress).OnClientEvent:Connect(fn)
end

-- blobIds array, productType ("CreepySoldier" | "CreepyWorm" | "CreepyTurret")
function Network.blobProduce(blobIds: {string}, productType: string)
	RemoteHandler.get(Config.REMOTES.BlobProduce):FireServer(blobIds, productType)
end

-- blobId, cooldownRemaining (seconds; 0 = ready)
function Network.onBlobUpdate(fn: (string, number) -> ())
	RemoteHandler.get(Config.REMOTES.BlobUpdate).OnClientEvent:Connect(fn)
end

-- nestIds array — requests one egg from each Lamprey Nest (server caps concurrency).
-- unitType selects which creature the egg hatches into ("Lamprey" | "Hagfish").
function Network.lampreyEgg(nestIds: {string}, unitType: string?)
	RemoteHandler.get(Config.REMOTES.LampreyEgg):FireServer(nestIds, unitType or "Lamprey")
end

-- hagPos, strikePositions: a hagfish slapped its head down — erupt the ground tentacles
function Network.onHagfishStrike(fn: (Vector3, {Vector3}) -> ())
	RemoteHandler.get(Config.REMOTES.HagfishStrike).OnClientEvent:Connect(fn)
end

-- deathPos: a Broodmother was killed — play its collapse/birth VFX + nearby camera shake
function Network.onBroodmotherDeath(fn: (Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.BroodmotherDeath).OnClientEvent:Connect(fn)
end

-- nestIds array — unlock the rally launcher upgrade on each Lamprey Nest
function Network.upgradeNest(nestIds: {string})
	RemoteHandler.get(Config.REMOTES.UpgradeNest):FireServer(nestIds)
end

-- nestId, target — set where an upgraded nest launches its eggs (server clamps range)
function Network.setNestRally(nestId: string, target: Vector3)
	RemoteHandler.get(Config.REMOTES.SetNestRally):FireServer(nestId, target)
end

-- position: where the worm erupted
function Network.onWormBurst(fn: (Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.WormBurst).OnClientEvent:Connect(fn)
end

-- winnerUserId
function Network.onPlayerWon(fn: (number) -> ())
	RemoteHandler.get(Config.REMOTES.PlayerWon).OnClientEvent:Connect(fn)
end

-- winnerUserId, reason, statsTable, duration
function Network.onShowEndScreen(fn: (number, string, any, number) -> ())
	RemoteHandler.get(Config.REMOTES.ShowEndScreen).OnClientEvent:Connect(fn)
end

-- Fired by server to the local player when their CC is destroyed mid-match
-- (not the final 1v1). stats = this player's stats, duration = seconds.
function Network.onShowDefeatScreen(fn: (any, number) -> ())
	RemoteHandler.get(Config.REMOTES.ShowDefeatScreen).OnClientEvent:Connect(fn)
end

-- Request the server respawn the local player's base into the running match.
function Network.playAgain()
	RemoteHandler.get(Config.REMOTES.PlayAgain):FireServer()
end

-- Fired by server when the local player's CC takes damage (throttled ~5 s)
function Network.onCCAttacked(fn: () -> ())
	RemoteHandler.get(Config.REMOTES.CCAttacked).OnClientEvent:Connect(fn)
end

-- Fired by server when the local player's base/army is under attack (throttled
-- per region). worldPos = where, category = "base" or "army".
function Network.onAttackAlert(fn: (worldPos: Vector3, category: string) -> ())
	RemoteHandler.get(Config.REMOTES.AttackAlert).OnClientEvent:Connect(fn)
end

-- ccId: toggle mobility unlock/on/off
function Network.mobilizeCC(ccId: string)
	RemoteHandler.get(Config.REMOTES.MobilizeCC):FireServer(ccId)
end

-- ccId, target: right-click movement order when CC is mobile
function Network.moveMobileCC(ccId: string, pos: Vector3)
	RemoteHandler.get(Config.REMOTES.MoveMobileCC):FireServer(ccId, pos)
end

-- ccId, unitType: the Hollowed Mother trains a unit beside itself (Leech)
function Network.trainFromMother(ccId: string, unitType: string)
	RemoteHandler.get(Config.REMOTES.TrainFromMother):FireServer(ccId, unitType)
end

-- ccId: buy one Egg Sacs upgrade on the Mother (plants nests + raises the Embryo cap)
function Network.upgradeEggSacs(ccId: string)
	RemoteHandler.get(Config.REMOTES.UpgradeEggSacs):FireServer(ccId)
end

-- ccId: buy the Mother's one-time Evolve unlock (lets Embryos evolve thereafter)
function Network.unlockEvolve(ccId: string)
	RemoteHandler.get(Config.REMOTES.UnlockEvolve):FireServer(ccId)
end

-- unitId: toggle a Leech between burrowed (structure/income) and mobile
function Network.toggleBurrow(unitId: string)
	RemoteHandler.get(Config.REMOTES.ToggleBurrow):FireServer(unitId)
end

-- embryoId, targetType ("Lamprey"/"Hagfish"/"Mother"): evolve an Embryo
function Network.evolveEmbryo(embryoId: string, targetType: string)
	RemoteHandler.get(Config.REMOTES.EvolveEmbryo):FireServer(embryoId, targetType)
end

-- unitId: a burrowed Leech just paid out income → play its harvest animation
function Network.onLeechHarvest(fn: (string) -> ())
	RemoteHandler.get(Config.REMOTES.LeechHarvest).OnClientEvent:Connect(fn)
end

-- egg: a Mother egg just settled → sprout its enveloping tentacles
function Network.onMotherEggLand(fn: (BasePart) -> ())
	RemoteHandler.get(Config.REMOTES.MotherEggLand).OnClientEvent:Connect(fn)
end

-- ccId, isUnlocked, isMobile
function Network.onCCMobileSync(fn: (string, boolean, boolean) -> ())
	RemoteHandler.get(Config.REMOTES.CCMobileSync).OnClientEvent:Connect(fn)
end

-- fromPos, toPos: medic heal beam VFX
function Network.onHealBeam(fn: (Vector3, Vector3) -> ())
	RemoteHandler.get(Config.REMOTES.HealBeam).OnClientEvent:Connect(fn)
end

-- turretId, headPos, target1?, target2?, target3?: evolved turret tentacle animation tick
function Network.onTentacleTargets(fn: (string, Vector3, Vector3?, Vector3?, Vector3?) -> ())
	RemoteHandler.get(Config.REMOTES.TentacleTargets).OnClientEvent:Connect(fn)
end

function Network.spawnLaneUnit(unitType: string)
	RemoteHandler.get(Config.REMOTES.SpawnLaneUnit):FireServer(unitType)
end

-- Player chose "Leave Match" — forfeit the current match (server destroys our CC).
function Network.forfeitMatch()
	RemoteHandler.get(Config.REMOTES.ForfeitMatch):FireServer()
end

-- Sell the given structures for a partial refund (server validates ownership).
function Network.sellBuildings(ids: { string })
	RemoteHandler.get(Config.REMOTES.SellBuilding):FireServer(ids)
end

function Network.setDeployerType(deployerId: string, unitType: string)
	RemoteHandler.get(Config.REMOTES.SetDeployerType):FireServer(deployerId, unitType)
end

-- Empower one or more bonfires: +capacity and faster summon (scaling price per
-- purchase). Pass a list to upgrade a multi-selection (server upgrades the lowest levels).
function Network.upgradeDeployer(deployerIds: { string } | string)
	RemoteHandler.get(Config.REMOTES.UpgradeDeployer):FireServer(deployerIds)
end

-- deployerId, unitType, progress (0–1), level, capacity, nextCost, justUpgraded
function Network.onDeployerUpdate(fn: (string, string, number, number?, number?, number?, boolean?) -> ())
	RemoteHandler.get(Config.REMOTES.DeployerUpdate).OnClientEvent:Connect(fn)
end

-- ── TEST building ───────────────────────────────────────────────────────────
function Network.setTestType(testId: string, unitType: string)
	RemoteHandler.get(Config.REMOTES.SetTestType):FireServer(testId, unitType)
end

-- Upgrade a TEST building's "supply" (capacity) or "rate" (summon speed), separately.
function Network.upgradeTest(testId: string, kind: string)
	RemoteHandler.get(Config.REMOTES.UpgradeTest):FireServer(testId, kind)
end

-- testId, unitType, progress (0–1), supplyLevel, rateLevel, capacity, supplyCost, rateCost, justUpgraded
function Network.onTestUpdate(fn: (string, string, number, number, number, number, number, number, boolean?) -> ())
	RemoteHandler.get(Config.REMOTES.TestUpdate).OnClientEvent:Connect(fn)
end

return Network
