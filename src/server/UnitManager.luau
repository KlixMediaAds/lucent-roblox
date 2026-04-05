local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local UnitManager = {}

type UnitData = {
	part        : BasePart,
	owner       : Player,
	target      : Vector3?,
	hp          : number,
	maxHp       : number,
	attackTimer : number,
	attackDmg   : number,
}

type QueueItem = { unitType: string, trainTime: number, player: Player, spawnPos: Vector3 }

local units: { [string]: UnitData } = {}
local counter    = 0
local unitsFolder: Folder
local buildingManagerRef: any   -- set via setBuildingManager after init
local resourceManagerRef:  any  -- set in init

local barrackQueues:     { [string]: { QueueItem } } = {}
local barrackIsTraining: { [string]: boolean }       = {}
local barrackTrainStart: { [string]: number }        = {}

local MAX_QUEUE = 5

-- ── Health bar helpers ────────────────────────────────────────────────────────

local function addHealthBar(part: BasePart)
	local bb           = Instance.new("BillboardGui")
	bb.Name            = "HealthBar"
	bb.Size            = UDim2.new(0, 60, 0, 7)
	bb.StudsOffset     = Vector3.new(0, part.Size.Y / 2 + 1.5, 0)
	bb.AlwaysOnTop     = false
	bb.Enabled         = false   -- hidden at full HP
	bb.Parent          = part

	local bg           = Instance.new("Frame")
	bg.Size            = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	bg.BorderSizePixel = 0
	bg.Parent          = bb

	local fill         = Instance.new("Frame")
	fill.Name          = "Fill"
	fill.Size          = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel = 0
	fill.Parent        = bg
end

local function applyHP(data: UnitData)
	local bb = data.part:FindFirstChild("HealthBar") :: BillboardGui?
	if not bb then return end
	local ratio = math.clamp(data.hp / data.maxHp, 0, 1)
	local bg    = bb:FindFirstChildWhichIsA("Frame")
	if not bg then return end
	local fill  = bg:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		local r = math.clamp(2 * (1 - ratio), 0, 1)
		local g = math.clamp(2 * ratio, 0, 1)
		fill.BackgroundColor3 = Color3.new(r, g, 0)
	end
	bb.Enabled = data.hp < data.maxHp
end

-- ── Spawn / move (internal) ───────────────────────────────────────────────────

local function spawnUnit(player: Player, position: Vector3, unitType: string)
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return end

	counter += 1
	local id = "u" .. counter

	local part          = Instance.new("Part")
	part.Name           = id
	part.Size           = typeDef.size
	part.Position       = Vector3.new(position.X, typeDef.size.Y / 2 + 0.1, position.Z)
	part.BrickColor     = player.TeamColor
	part.Material       = Enum.Material.SmoothPlastic
	part.Anchored       = true
	part.CastShadow     = false

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = part

	local tv        = Instance.new("StringValue")
	tv.Name         = "UnitType"
	tv.Value        = unitType
	tv.Parent       = part

	part.Parent = unitsFolder

	local maxHp = (Config.UNIT_HP :: any)[unitType] or 100
	local dmg   = (Config.UNIT_ATTACK_DAMAGE :: any)[unitType] or 10
	addHealthBar(part)

	units[id] = {
		part        = part,
		owner       = player,
		target      = nil,
		hp          = maxHp,
		maxHp       = maxHp,
		attackTimer = math.random() * Config.UNIT_ATTACK_RATE,
		attackDmg   = dmg,
	}

	RemoteHandler.get(Config.REMOTES.UnitSpawned):FireAllClients(id, player.UserId, part.Position)
end

local function moveUnits(player: Player, ids: { string }, targetPos: Vector3)
	local valid = {}
	for _, id in ids do
		if units[id] and units[id].owner == player then
			table.insert(valid, id)
		end
	end

	local cols = math.max(1, math.ceil(math.sqrt(#valid)))
	for i, id in valid do
		local c = (i - 1) % cols
		local r = math.floor((i - 1) / cols)
		units[id].target = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
	end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
end

-- ── Barracks queue helpers ────────────────────────────────────────────────────

local function fireTrainingUpdate(barrackId: string, player: Player)
	if not player.Parent then return end
	local q = barrackQueues[barrackId] or {}
	local progress = 0
	if barrackIsTraining[barrackId] and #q > 0 and barrackTrainStart[barrackId] then
		local elapsed = tick() - barrackTrainStart[barrackId]
		progress = math.clamp(elapsed / q[1].trainTime, 0, 1)
	end
	local types: { string } = {}
	for _, item in q do table.insert(types, item.unitType) end
	RemoteHandler.get(Config.REMOTES.TrainingUpdate):FireClient(player, barrackId, types, progress)
end

local function startNextInQueue(barrackId: string)
	local q = barrackQueues[barrackId]
	if not q or #q == 0 then
		barrackIsTraining[barrackId] = false
		return
	end

	barrackIsTraining[barrackId] = true
	barrackTrainStart[barrackId] = tick()
	local item = q[1]
	local player = item.player

	fireTrainingUpdate(barrackId, player)

	-- Periodic progress updates for the client progress bar
	task.spawn(function()
		local startSnapshot = barrackTrainStart[barrackId]
		while true do
			task.wait(0.2)
			local q2 = barrackQueues[barrackId]
			if not q2 or #q2 == 0 then break end
			if barrackTrainStart[barrackId] ~= startSnapshot then break end
			if not player.Parent then break end
			fireTrainingUpdate(barrackId, player)
		end
	end)

	task.delay(item.trainTime, function()
		local q2 = barrackQueues[barrackId]
		if not q2 or q2[1] ~= item then return end
		table.remove(q2, 1)
		local bf = workspace:FindFirstChild("Buildings")
		if bf and bf:FindFirstChild(barrackId) then
			spawnUnit(player, item.spawnPos, item.unitType)
		end
		fireTrainingUpdate(barrackId, player)
		startNextInQueue(barrackId)
	end)
end

-- ── Public AI API ─────────────────────────────────────────────────────────────

-- Server-side equivalent of the TrainUnit remote — AI calls this directly so
-- training goes through the same queue / progress pipeline as player training.
function UnitManager.trainFromBarracks(barrackId: string, unitType: string, player: any): boolean
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return false end

	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return false end
	local building = buildingsFolder:FindFirstChild(barrackId)
	if not building then return false end

	local base = building:FindFirstChild("Base") :: BasePart?
	if not base then return false end

	local q = barrackQueues[barrackId] or {}
	if #q >= MAX_QUEUE then return false end

	if not resourceManagerRef then return false end
	if not resourceManagerRef.spend(player, typeDef.cost) then return false end

	local spawnPos  = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
	local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0

	if trainTime <= 0 then
		spawnUnit(player, spawnPos, unitType)
		return true
	end

	barrackQueues[barrackId] = q
	table.insert(q, {
		unitType  = unitType,
		trainTime = trainTime,
		player    = player,
		spawnPos  = spawnPos,
	})

	if not barrackIsTraining[barrackId] then
		startNextInQueue(barrackId)
	end
	return true
end

function UnitManager.spawnUnitAt(player: Player, position: Vector3, unitType: string)
	local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0
	if trainTime > 0 then
		task.delay(trainTime, function()
			spawnUnit(player, position, unitType)
		end)
	else
		spawnUnit(player, position, unitType)
	end
end

function UnitManager.getUnitCount(player: Player): number
	local n = 0
	for _, data in units do
		if data.owner == player then n += 1 end
	end
	return n
end

function UnitManager.sendAllUnitsTo(player: Player, targetPos: Vector3)
	local ids = {}
	for id, data in units do
		if data.owner == player then table.insert(ids, id) end
	end
	if #ids > 0 then moveUnits(player, ids, targetPos) end
end

function UnitManager.removeAllUnitsFor(player: any)
	local toRemove = {}
	for id, data in units do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		units[id].part:Destroy()
		units[id] = nil
	end
end

function UnitManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

-- Returns (hit, hitPosition) — hit is true if an enemy unit was found and damaged.
function UnitManager.damageNearestUnit(fromPos: Vector3, attackerOwnerIdStr: string, range: number, damage: number): (boolean, Vector3?)
	local bestId, bestDist = nil :: string?, math.huge
	for id, data in units do
		if data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.part.Position - fromPos).Magnitude
		if d <= range and d < bestDist then
			bestDist = d; bestId = id
		end
	end
	if not bestId then return false, nil end
	local data = units[bestId]
	local hitPos = data.part.Position
	data.hp -= damage
	applyHP(data)
	if data.hp <= 0 then
		data.part:Destroy()
		units[bestId] = nil
	end
	return true, hitPos
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function UnitManager.init(resourceManager)
	resourceManagerRef = resourceManager
	unitsFolder        = Instance.new("Folder")
	unitsFolder.Name   = "Units"
	unitsFolder.Parent = workspace

	-- Movement + combat tick
	RunService.Heartbeat:Connect(function(dt)
		local toRemove: { string } = {}

		for id, data in units do
			-- Movement
			if data.target then
				local pos   = data.part.Position
				local flat  = Vector3.new(data.target.X, pos.Y, data.target.Z)
				local delta = flat - pos
				if delta.Magnitude < 0.5 then
					data.target = nil
				else
					local step         = math.min(Config.UNIT_MOVE_SPEED * dt, delta.Magnitude)
					data.part.Position = pos + delta.Unit * step
				end
			end

			-- Combat
			if data.hp <= 0 then continue end
			data.attackTimer += dt
			if data.attackTimer < Config.UNIT_ATTACK_RATE then continue end
			data.attackTimer -= Config.UNIT_ATTACK_RATE

			local myPos      = data.part.Position
			local myOwnerStr = tostring(data.owner.UserId)
			local attacked   = false

			-- Attack nearest enemy unit in range
			for otherId, other in units do
				if other.hp <= 0 then continue end
				if tostring(other.owner.UserId) == myOwnerStr then continue end
				if (other.part.Position - myPos).Magnitude <= Config.UNIT_ATTACK_RANGE then
					other.hp -= data.attackDmg
					applyHP(other)
					if other.hp <= 0 then
						table.insert(toRemove, otherId)
					end
					attacked = true
					break
				end
			end

			-- Attack nearest enemy building in range (if no unit was hit)
			if not attacked and buildingManagerRef then
				local bId = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, Config.UNIT_ATTACK_RANGE)
				if bId then
					buildingManagerRef.damage(bId, data.attackDmg)
				end
			end
		end

		-- Remove dead units after iteration
		for _, id in toRemove do
			local data = units[id]
			if data then
				data.part:Destroy()
				units[id] = nil
			end
		end
	end)

	-- Train a unit from a barracks (queue-based)
	RemoteHandler.get(Config.REMOTES.TrainUnit).OnServerEvent:Connect(function(player, barrackId, unitType)
		if type(barrackId) ~= "string" or type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end

		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end
		local building = buildingsFolder:FindFirstChild(barrackId)
		if not building then return end

		local ownerVal = building:FindFirstChild("OwnerId")
		if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then return end

		local base = building:FindFirstChild("Base") :: BasePart
		if not base then return end

		-- Cap queue length
		local q = barrackQueues[barrackId] or {}
		if #q >= MAX_QUEUE then return end

		if not resourceManagerRef.spend(player, typeDef.cost) then return end

		local spawnPos  = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
		local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0

		if trainTime <= 0 then
			spawnUnit(player, spawnPos, unitType)
			return
		end

		barrackQueues[barrackId] = q
		table.insert(q, { unitType = unitType, trainTime = trainTime, player = player, spawnPos = spawnPos })

		if not barrackIsTraining[barrackId] then
			startNextInQueue(barrackId)
		else
			fireTrainingUpdate(barrackId, player)
		end
	end)

	RemoteHandler.get(Config.REMOTES.MoveUnits).OnServerEvent:Connect(function(player, ids, targetPos)
		if type(ids) ~= "table" or typeof(targetPos) ~= "Vector3" then return end
		moveUnits(player, ids, targetPos)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Remove units
		local toRemove = {}
		for id, data in units do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do
			units[id].part:Destroy()
			units[id] = nil
		end
		-- Clear barracks queues owned by this player
		local qToClean = {}
		for barrackId, q in barrackQueues do
			if #q > 0 and q[1].player == player then
				table.insert(qToClean, barrackId)
			end
		end
		for _, bid in qToClean do
			barrackQueues[bid] = nil
			barrackIsTraining[bid] = nil
			barrackTrainStart[bid] = nil
		end
	end)
end

return UnitManager
