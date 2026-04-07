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
	attackRate  : number,
	unitType    : string,
	home        : Vector3,
	aggroId     : string?,
	aggroHome   : Vector3?,
	atkMoveDest : Vector3?,
	velocity    : Vector3,   -- current world-space velocity (XZ only)
	moveSpeed   : number,    -- max speed in studs/s
	accel       : number,    -- velocity lerp factor (higher = snappier)
	focusBldId  : string?,   -- building ID to focus-fire (nil = none)
}

type QueueItem = { unitType: string, trainTime: number, player: Player, spawnPos: Vector3 }

local units: { [string]: UnitData } = {}
local counter    = 0
local unitsFolder: Folder
local buildingManagerRef:  any
local resourceManagerRef:  any
local researchManagerRef:  any

local barrackQueues:     { [string]: { QueueItem } } = {}
local barrackIsTraining: { [string]: boolean }       = {}
local barrackTrainStart: { [string]: number }        = {}

local MAX_QUEUE = 5

local aggroScanFrame = 0
local AGGRO_SCAN_EVERY = 18   -- ~0.3 s at 60 Hz

local SEP_DIST = 5.5   -- studs: same-team separation trigger radius
local SEP_PUSH = 0.18  -- studs pushed per frame per overlapping neighbour

-- ── Health bar ────────────────────────────────────────────────────────────────

local function addHealthBar(part: BasePart)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.new(0, 60, 0, 7)
	bb.StudsOffset      = Vector3.new(0, part.Size.Y / 2 + 1.5, 0)
	bb.AlwaysOnTop      = false
	bb.Enabled          = false
	bb.Parent           = part

	local bg            = Instance.new("Frame")
	bg.Size             = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	bg.BorderSizePixel  = 0
	bg.Parent           = bb

	local fill          = Instance.new("Frame")
	fill.Name           = "Fill"
	fill.Size           = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel  = 0
	fill.Parent         = bg
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

-- ── Spawn ─────────────────────────────────────────────────────────────────────

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

	local maxHp    = (Config.UNIT_HP :: any)[unitType] or 100
	local dmg      = (Config.UNIT_ATTACK_DAMAGE :: any)[unitType] or 10
	local atkRate  = (Config.UNIT_ATTACK_RATE :: any)[unitType] or 1.0
	local spd      = (Config.UNIT_MOVE_SPEED :: any)[unitType] or 22
	local acc      = (Config.UNIT_ACCEL :: any)[unitType] or 8
	local atkRange = (Config.UNIT_ATTACK_RANGE :: any)[unitType] or 15
	addHealthBar(part)

	units[id] = {
		part        = part,
		owner       = player,
		target      = nil,
		hp          = maxHp,
		maxHp       = maxHp,
		attackTimer = math.random() * atkRate,
		attackDmg   = dmg,
		attackRate  = atkRate,
		attackRange = atkRange,
		unitType    = unitType,
		home        = position,
		aggroId     = nil,
		aggroHome   = nil,
		atkMoveDest = nil,
		velocity    = Vector3.zero,
		moveSpeed   = spd,
		accel       = acc,
		focusBldId  = nil,
	}

	RemoteHandler.get(Config.REMOTES.UnitSpawned):FireAllClients(id, player.UserId, part.Position)
end

-- ── Move helpers ──────────────────────────────────────────────────────────────

local function applyFormation(valid: { string }, targetPos: Vector3)
	local cols = math.max(1, math.ceil(math.sqrt(#valid)))
	for i, id in valid do
		local c = (i - 1) % cols
		local r = math.floor((i - 1) / cols)
		local formPos = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
		local data = units[id]
		data.target     = formPos
		data.aggroId    = nil
		data.aggroHome  = nil
		data.focusBldId = nil
	end
end

local function moveUnits(player: Player, ids: { string }, targetPos: Vector3)
	local valid = {}
	for _, id in ids do
		if units[id] and units[id].owner == player then
			table.insert(valid, id)
		end
	end
	applyFormation(valid, targetPos)
	for _, id in valid do units[id].atkMoveDest = nil end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
end

local function attackMoveUnits(player: Player, ids: { string }, targetPos: Vector3)
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
		local formPos = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
		local data = units[id]
		data.target      = formPos
		data.aggroId     = nil
		data.aggroHome   = nil
		data.focusBldId  = nil
		data.atkMoveDest = formPos
	end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
end

-- ── Barracks queue ────────────────────────────────────────────────────────────

local function fireTrainingUpdate(barrackId: string, player: Player)
	if not player.Parent then return end
	if player.UserId < 0 then return end
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
	local item   = q[1]
	local player = item.player
	fireTrainingUpdate(barrackId, player)

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

function UnitManager.trainFromBarracks(barrackId: string, unitType: string, player: any): boolean
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return false end

	if typeDef.researchReq then
		if not researchManagerRef or not researchManagerRef.hasResearch(player, typeDef.researchReq) then
			return false
		end
	end

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
	table.insert(q, { unitType = unitType, trainTime = trainTime, player = player, spawnPos = spawnPos })

	if not barrackIsTraining[barrackId] then
		startNextInQueue(barrackId)
	end
	return true
end

function UnitManager.spawnUnitAt(player: Player, position: Vector3, unitType: string)
	local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0
	if trainTime > 0 then
		task.delay(trainTime, function() spawnUnit(player, position, unitType) end)
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

-- Send a specific subset of unit IDs to a position (used by AI squad system).
function UnitManager.sendUnitsTo(player: any, ids: { string }, targetPos: Vector3)
	if #ids > 0 then moveUnits(player :: Player, ids, targetPos) end
end

-- Return a list of { id, part, unitType } for all units owned by player.
-- Used by the AI to rebuild squad role assignments each strategy tick.
function UnitManager.getPlayerUnitData(player: any): { { id: string, part: BasePart, unitType: string } }
	local result = {}
	for id, data in units do
		if data.owner == player then
			table.insert(result, { id = id, part = data.part, unitType = data.unitType })
		end
	end
	return result
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

function UnitManager.resetAll()
	for id, data in units do
		if data.part and data.part.Parent then data.part:Destroy() end
	end
	units = {}
end

function UnitManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

function UnitManager.setResearchManager(rm: any)
	researchManagerRef = rm
end

function UnitManager.damageNearestUnit(fromPos: Vector3, attackerOwnerIdStr: string, range: number, damage: number): (boolean, Vector3?)
	local bestId, bestDist = nil :: string?, math.huge
	for id, data in units do
		if data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.part.Position - fromPos).Magnitude
		if d <= range and d < bestDist then bestDist = d; bestId = id end
	end
	if not bestId then return false, nil end
	local data   = units[bestId]
	local hitPos = data.part.Position
	data.hp -= damage
	applyHP(data)
	if data.hp <= 0 then
		if (data.unitType == "Tank" or data.unitType == "Soldier") and data.owner.Parent then
			RemoteHandler.get(Config.REMOTES.UnitDied):FireClient(data.owner, data.unitType, hitPos)
		end
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

	local LEASH         = Config.UNIT_LEASH_RANGE
	local AGGRO         = Config.UNIT_AGGRO_RADIUS
	local unitHitRemote = RemoteHandler.get(Config.REMOTES.UnitHit)
	local unitDiedRemote = RemoteHandler.get(Config.REMOTES.UnitDied)

	RunService.Heartbeat:Connect(function(dt)
		local toRemove: { string } = {}
		aggroScanFrame = (aggroScanFrame + 1) % AGGRO_SCAN_EVERY
		local doAggro  = aggroScanFrame == 0

		for id, data in units do

			-- ── 1. Aggro: update chase target or resolve ───────────────────────
			if data.aggroId then
				local aggroTarget = units[data.aggroId]
				if not aggroTarget or aggroTarget.hp <= 0 then
					data.aggroId   = nil
					data.aggroHome = nil
					data.target    = data.atkMoveDest or data.home
				else
					local ep    = aggroTarget.part.Position
					local myPos = data.part.Position
					local dx    = ep.X - myPos.X
					local dz    = ep.Z - myPos.Z
					local dist  = math.sqrt(dx * dx + dz * dz)
					local stopAt = data.attackRange * 0.85
					if dist > stopAt then
						local frac  = (dist - stopAt) / dist
						data.target = Vector3.new(myPos.X + dx * frac, 0, myPos.Z + dz * frac)
					else
						data.target = nil   -- already in range, hold position
					end

					if data.aggroHome then
						if (myPos - data.aggroHome).Magnitude > LEASH then
							data.aggroId   = nil
							data.aggroHome = nil
							data.target    = data.atkMoveDest or data.home
						end
					end
				end
			end

			-- ── 1b. Focus building: approach and hold at attack range ──────────
			if data.focusBldId and not data.aggroId then
				local bf    = workspace:FindFirstChild("Buildings")
				local model = bf and bf:FindFirstChild(data.focusBldId)
				local base  = model and model:FindFirstChild("Base")
				if not base or not (base :: BasePart).Parent then
					data.focusBldId = nil
				else
					local bpos  = (base :: BasePart).Position
					local myPos = data.part.Position
					local dx    = bpos.X - myPos.X
					local dz    = bpos.Z - myPos.Z
					local dist  = math.sqrt(dx * dx + dz * dz)
					local stopAt = data.attackRange * 0.85
					if dist > stopAt then
						local frac  = (dist - stopAt) / dist
						data.target = Vector3.new(myPos.X + dx * frac, 0, myPos.Z + dz * frac)
					else
						data.target = nil   -- in range, hold position
					end
				end
			end

			-- ── 2. Velocity-based movement ────────────────────────────────────
			local pos = data.part.Position

			-- Compute desired velocity toward target (zero when no target or arrived)
			local desired = Vector3.zero
			if data.target then
				local flat  = Vector3.new(data.target.X, pos.Y, data.target.Z)
				local delta = flat - pos
				if delta.Magnitude < 1.5 then
					-- Arrived
					data.target = nil
					if not data.aggroId then
						data.home = pos
						if data.atkMoveDest and (pos - data.atkMoveDest).Magnitude < 3 then
							data.atkMoveDest = nil
						end
					end
				else
					desired = delta.Unit * data.moveSpeed
				end
			end

			-- Lerp velocity: decelerate faster than accelerate for snappier stops
			local lerpFactor = if desired.Magnitude < 0.1
				then math.min(data.accel * 2.5 * dt, 1)
				else math.min(data.accel * dt, 1)
			data.velocity = data.velocity:Lerp(desired, lerpFactor)

			-- Apply velocity and face the direction of travel
			local vel = data.velocity
			if vel.Magnitude > 0.15 then
				local newPos = Vector3.new(pos.X + vel.X * dt, pos.Y, pos.Z + vel.Z * dt)
				local flatVel = Vector3.new(vel.X, 0, vel.Z)
				if flatVel.Magnitude > 0.5 then
					data.part.CFrame = CFrame.lookAt(newPos, newPos + flatVel)
				else
					data.part.Position = newPos
				end
			end

			-- ── 3. Aggro scan (idle + A-moving units only) ─────────────────────
			if doAggro and not data.aggroId and not data.focusBldId then
				if data.target == nil or data.atkMoveDest ~= nil then
					local myStr = tostring(data.owner.UserId)
					local myPos = data.part.Position
					local bestId2, bestDist2 = nil :: string?, AGGRO + 1
					for otherId, other in units do
						if other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= AGGRO and d < bestDist2 then
							bestDist2 = d; bestId2 = otherId
						end
					end
					if bestId2 then
						data.aggroId   = bestId2
						data.aggroHome = data.part.Position
					end
				end
			end

			-- ── 4. Combat ─────────────────────────────────────────────────────
			if data.hp <= 0 then continue end
			data.attackTimer += dt
			if data.attackTimer < data.attackRate then continue end
			data.attackTimer -= data.attackRate

			local myPos      = data.part.Position
			local myOwnerStr = tostring(data.owner.UserId)
			local hitPos: Vector3? = nil

			local atkRange = data.attackRange

			if data.unitType == "Tank" then
				-- Tanks: buildings first (+ splash on nearby units), fall back to units
				if buildingManagerRef then
					local bId: string?, bPos: Vector3?
					if data.focusBldId then
						local bf    = workspace:FindFirstChild("Buildings")
						local model = bf and bf:FindFirstChild(data.focusBldId)
						local base  = model and model:FindFirstChild("Base")
						if base and (base :: BasePart).Parent then
							local bp = base :: BasePart
							if (bp.Position - myPos).Magnitude <= atkRange then
								bId = data.focusBldId; bPos = bp.Position
							end
						else
							data.focusBldId = nil
						end
					end
					if not bId then
						bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
					end
					if bId and bPos then
						buildingManagerRef.damage(bId, data.attackDmg)
						hitPos = bPos
						local splashR = Config.TANK_SPLASH_RANGE
						for otherId, other in units do
							if other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							if (other.part.Position - bPos).Magnitude <= splashR then
								other.hp -= math.floor(data.attackDmg * 0.5)
								applyHP(other)
								if other.hp <= 0 then table.insert(toRemove, otherId) end
							end
						end
					end
				end
				if not hitPos then
					local bestId2, bestDist2 = nil :: string?, math.huge
					for otherId, other in units do
						if other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myOwnerStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= atkRange and d < bestDist2 then
							bestDist2 = d; bestId2 = otherId
						end
					end
					if bestId2 then
						local other = units[bestId2]
						hitPos = other.part.Position
						other.hp -= data.attackDmg
						applyHP(other)
						if other.hp <= 0 then table.insert(toRemove, bestId2) end
					end
				end
			else
				-- Soldiers / Elite: nearest enemy unit first, fall back to buildings
				local bestId2, bestDist2 = nil :: string?, math.huge
				for otherId, other in units do
					if other.hp <= 0 then continue end
					if tostring(other.owner.UserId) == myOwnerStr then continue end
					local d = (other.part.Position - myPos).Magnitude
					if d <= atkRange and d < bestDist2 then
						bestDist2 = d; bestId2 = otherId
					end
				end
				if bestId2 then
					local other = units[bestId2]
					hitPos = other.part.Position
					other.hp -= data.attackDmg
					applyHP(other)
					if other.hp <= 0 then table.insert(toRemove, bestId2) end
				elseif buildingManagerRef then
					local bId: string?, bPos: Vector3?
					if data.focusBldId then
						local bf    = workspace:FindFirstChild("Buildings")
						local model = bf and bf:FindFirstChild(data.focusBldId)
						local base  = model and model:FindFirstChild("Base")
						if base and (base :: BasePart).Parent then
							local bp = base :: BasePart
							if (bp.Position - myPos).Magnitude <= atkRange then
								bId = data.focusBldId; bPos = bp.Position
							end
						else
							data.focusBldId = nil
						end
					end
					if not bId then
						bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
					end
					if bId and bPos then
						buildingManagerRef.damage(bId, data.attackDmg)
						hitPos = bPos
					end
				end
			end

			-- Face attack target, then fire VFX
			if hitPos then
				local flatDir = Vector3.new(hitPos.X - myPos.X, 0, hitPos.Z - myPos.Z)
				if flatDir.Magnitude > 0.1 then
					data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
				end
				unitHitRemote:FireAllClients(myPos, hitPos, data.unitType)
			end
		end

		-- ── Separation pass ────────────────────────────────────────────────────
		-- Nudge overlapping same-team units apart so they don't stack.
		-- Runs every frame; n is small enough that O(n²) is fine.
		for id, data in units do
			local myPos = data.part.Position
			local myStr = tostring(data.owner.UserId)
			local pushX, pushZ = 0, 0
			local count = 0

			for otherId, other in units do
				if otherId == id then continue end
				if tostring(other.owner.UserId) ~= myStr then continue end
				local dx   = myPos.X - other.part.Position.X
				local dz   = myPos.Z - other.part.Position.Z
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist < SEP_DIST and dist > 0.01 then
					local strength = (SEP_DIST - dist) / SEP_DIST
					pushX += (dx / dist) * strength
					pushZ += (dz / dist) * strength
					count += 1
				end
			end

			if count > 0 then
				local mag = math.sqrt(pushX * pushX + pushZ * pushZ)
				if mag > 0.01 then
					local nx = myPos.X + (pushX / mag) * SEP_PUSH
					local nz = myPos.Z + (pushZ / mag) * SEP_PUSH
					-- Preserve facing rotation, only move position
					data.part.CFrame = CFrame.new(nx, myPos.Y, nz) * data.part.CFrame.Rotation
				end
			end
		end

		-- Remove dead units
		for _, id in toRemove do
			local d = units[id]
			if d then
				if (d.unitType == "Tank" or d.unitType == "Soldier") and d.owner.Parent then
					unitDiedRemote:FireClient(d.owner, d.unitType, d.part.Position)
				end
				d.part:Destroy()
				units[id] = nil
			end
		end
	end)

	-- Train remote
	RemoteHandler.get(Config.REMOTES.TrainUnit).OnServerEvent:Connect(function(player, barrackId, unitType)
		if type(barrackId) ~= "string" or type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end

		-- Research gate: if this unit type requires a tech, verify the player has it
		if typeDef.researchReq then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, typeDef.researchReq) then
				return
			end
		end

		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end
		local building = buildingsFolder:FindFirstChild(barrackId)
		if not building then return end

		local ownerVal = building:FindFirstChild("OwnerId")
		if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then return end

		local base = building:FindFirstChild("Base") :: BasePart
		if not base then return end

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

	RemoteHandler.get(Config.REMOTES.AttackMoveUnits).OnServerEvent:Connect(function(player, ids, targetPos)
		if type(ids) ~= "table" or typeof(targetPos) ~= "Vector3" then return end
		attackMoveUnits(player, ids, targetPos)
	end)

	RemoteHandler.get(Config.REMOTES.FocusAttack).OnServerEvent:Connect(function(player, ids, targetId, targetType)
		if type(ids) ~= "table" or type(targetId) ~= "string" or type(targetType) ~= "string" then return end
		for _, id in ids do
			local data = units[id]
			if not data or data.owner ~= player then continue end
			data.atkMoveDest = nil
			data.target      = nil
			if targetType == "unit" then
				if units[targetId] then
					data.aggroId    = targetId
					data.aggroHome  = nil   -- no leash on manual focus attacks
					data.focusBldId = nil
				end
			elseif targetType == "building" then
				data.focusBldId = targetId
				data.aggroId    = nil
				data.aggroHome  = nil
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local toRemove = {}
		for id, data in units do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do
			units[id].part:Destroy()
			units[id] = nil
		end
		local qToClean = {}
		for barrackId, q in barrackQueues do
			if #q > 0 and q[1].player == player then
				table.insert(qToClean, barrackId)
			end
		end
		for _, bid in qToClean do
			barrackQueues[bid]     = nil
			barrackIsTraining[bid] = nil
			barrackTrainStart[bid] = nil
		end
	end)
end

return UnitManager
