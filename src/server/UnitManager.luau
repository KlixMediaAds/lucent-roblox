local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local UnitBlueprints    = require(Shared:WaitForChild("UnitBlueprints"))
local AlertManager      = require(script.Parent:WaitForChild("AlertManager"))

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
	hpBarHideAt : number?,   -- tick() timestamp; hide health bar after this time
	slowUntil          : number?,  -- tick() timestamp; unit moves at TANK_SLOW_MULT speed until then
	stimUntil          : number?,  -- tick() timestamp; soldier stims active until then
	stimCooldownUntil  : number?,  -- tick() timestamp; stims cannot reactivate until then
	incomingHarpoons   : number?,  -- count of active harpoons embedded in this unit (stacks slow)
	harpoonCount       : number?,  -- nil for non-trappers; current available harpoons (0–5)
	harpoonRestockAt   : number?,  -- tick() timestamp when next harpoon restocks
	trapperHarpooned   : {[string]: number}?,  -- unitId → expiry tick() for active harpoons this trapper fired
	rollerAngle        : number?,   -- accumulated Z-roll radians
	rollerCharging     : boolean?,  -- dashing toward charge target
	rollerChargingOut  : boolean?,  -- bouncing back from charge
	rollerChargeTarget : Vector3?,  -- charge destination
	rollerChargeHome   : Vector3?,  -- position to return to after charge
	-- Foamer deploy state machine
	foamState       : string?,    -- nil = not a foamer; "mobile"|"deploying"|"deployed"|"undeploying"
	foamDeployStart : number?,    -- tick() when current transition began
	foamSinkBaseY   : number?,    -- body Y when deploy/undeploy transition started
	foamBarrelDec   : Decorator?, -- cached ref to the FoamBarrel decorator for barrel animation
	-- Foam debuff received by any unit (including non-foamers)
	foamedUntil     : number?,    -- tick() when foam expires on this unit; nil = not foamed
	foamDotAccum    : number?,    -- accumulated dt for 1-s DoT tick
}

type QueueItem = { unitType: string, trainTime: number, player: Player, spawnPos: Vector3 }

local units: { [string]: UnitData } = {}
local counter    = 0
local unitsFolder: Folder
local buildingManagerRef:  any
local resourceManagerRef:  any
local researchManagerRef:  any
local mineralManagerRef:   any

local barrackQueues:     { [string]: { QueueItem } } = {}
local barrackIsTraining: { [string]: boolean }       = {}
local barrackTrainStart: { [string]: number }        = {}

local MAX_QUEUE = 5
local laneModeActive = false

-- Deployer unit tracking: forward (deployerId → set of unitIds) and reverse maps
local deployerUnits:   { [string]: { [string]: boolean } } = {}
local unitToDeployer:  { [string]: string }                = {}

local aggroScanFrame = 0
local AGGRO_SCAN_EVERY = 18   -- ~0.3 s at 60 Hz

local SEP_DIST   = 5.5   -- studs: same-team separation trigger radius
local SEP_PUSH   = 0.18  -- studs pushed per frame per overlapping neighbour
local MOVE_BOUND = 427   -- studs: clamp units inside the ±432 boundary walls
local HP_BAR_SHOW_SECS = 3

-- Spatial grid rebuilt each Heartbeat; maps a packed (cx, cz) integer key to the
-- list of unit IDs in that cell.  GRID_CELL > SEP_DIST so separation queries cover
-- at most a 2×2 block; AGGRO queries cover a small fixed neighbourhood regardless of n.
local GRID_CELL   = 16    -- studs per cell side
local GRID_OFFSET = 30    -- shifts cell index: world [-432..432] → cx/cz [3..57]
local GRID_STRIDE = 70    -- column count for packing (cx, cz) into one integer key
local spatialGrid: { [number]: { string } } = {}
local gridOccupied: { number }               = {}
local gridOccupiedCount                      = 0

-- Reusable scratch buffer for grid-range queries — avoids a table alloc per lookup.
local gridScratch: { string } = {}
local gridScratchN             = 0

-- Active Howitzer fire zones: persist for FULL+FADE seconds, deal DoT to all units.
type FireZone = { pos: Vector3, elapsed: number, dotAccum: number }
local fireZones: { FireZone } = {}

-- Per-unit anchored decorator parts (treads, pill body, eyes, etc.).
-- Replaced unanchored+WeldConstraint parts to cut physics body count.
type Decorator = { part: Part, localCF: CFrame }
local unitDecorators: { [string]: { Decorator } } = {}

-- Live unit count per player userId (for unit cap enforcement).
local playerUnitCount: { [number]: number } = {}
local MAX_UNITS_PER_PLAYER = 30

local function rebuildSpatialGrid()
	for i = 1, gridOccupiedCount do
		local cell = spatialGrid[gridOccupied[i]]
		for j = 1, #cell do cell[j] = nil end
	end
	gridOccupiedCount = 0
	for id, data in units do
		local pos = data.part.Position
		local cx  = math.floor(pos.X / GRID_CELL) + GRID_OFFSET
		local cz  = math.floor(pos.Z / GRID_CELL) + GRID_OFFSET
		local k   = cx * GRID_STRIDE + cz
		local cell = spatialGrid[k]
		if not cell then
			cell = {}
			spatialGrid[k] = cell
			gridOccupiedCount += 1
			gridOccupied[gridOccupiedCount] = k
		end
		cell[#cell + 1] = id
	end
end

-- Fill gridScratch with every unit ID whose cell overlaps a circle of `range` around
-- `fromPos`. No table allocation — callers iterate gridScratch[1..gridScratchN].
local function fillGridScratch(fromPos: Vector3, range: number)
	gridScratchN = 0
	local cx0 = math.floor((fromPos.X - range) / GRID_CELL) + GRID_OFFSET
	local cx1 = math.floor((fromPos.X + range) / GRID_CELL) + GRID_OFFSET
	local cz0 = math.floor((fromPos.Z - range) / GRID_CELL) + GRID_OFFSET
	local cz1 = math.floor((fromPos.Z + range) / GRID_CELL) + GRID_OFFSET
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			local cell = spatialGrid[cx * GRID_STRIDE + cz]
			if cell then
				for _, id in cell do
					gridScratchN += 1
					gridScratch[gridScratchN] = id
				end
			end
		end
	end
end

-- ── Decorator construction ────────────────────────────────────────────────────

-- Builds a unit's static decorator parts from its shared blueprint (see
-- UnitBlueprints). Anchored parts are tracked in `unitDecorators` so the
-- Heartbeat re-applies `bodyCF * localCF` each frame as the body moves.
local function buildFromBlueprint(id: string, body: BasePart, bp: UnitBlueprints.Blueprint)
	if bp.rootTransparent then body.Transparency = 1 end
	local teamColor = body.Color
	local decs      = unitDecorators[id]
	for _, spec in bp.parts do
		local p   = UnitBlueprints.instantiate(spec, body.CFrame, teamColor)
		p.Parent  = body
		decs[#decs + 1] = { part = p, localCF = spec.cf }
	end
	if bp.healthBarY then
		local bb = body:FindFirstChild("HealthBar")
		if bb and bb:IsA("BillboardGui") then
			bb.StudsOffset = Vector3.new(0, bp.healthBarY, 0)
		end
	end
end

-- Howitzer-only: continuous black smoke from both smokestacks. Server-side only
-- (previews omit particles). The stacks are named by the blueprint.
local function attachHowitzerSmoke(body: BasePart)
	for _, stackName in { "_HwStack1", "_HwStack2" } do
		local stk = body:FindFirstChild(stackName) :: BasePart?
		if not stk then continue end
		-- The stack is an upright cylinder: its length runs along local X and the
		-- blueprint rotates it Z+90° so that axis points up. Place the emitter at
		-- the top face and cancel that rotation (Z−90°) so the emitter's Top (+Y,
		-- the default EmissionDirection) points world-up and smoke rises.
		local att      = Instance.new("Attachment")
		att.CFrame     = CFrame.new(stk.Size.X / 2, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2)
		att.Parent     = stk
		local pe                = Instance.new("ParticleEmitter")
		pe.Color                = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(90, 90, 90)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(55, 55, 55)),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(28, 28, 28)),
		})
		pe.LightEmission        = 0
		pe.LightInfluence       = 0.5
		pe.Lifetime             = NumberRange.new(2.0, 3.5)
		pe.Rate                 = if stackName == "_HwStack1" then 10 else 7
		pe.Rotation             = NumberRange.new(0, 360)
		pe.RotSpeed             = NumberRange.new(-25, 25)
		pe.Size                 = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.5),
			NumberSequenceKeypoint.new(0.5, 2.0),
			NumberSequenceKeypoint.new(1,   3.2),
		})
		pe.Transparency         = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.10),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1,   1.00),
		})
		pe.Speed                = NumberRange.new(2.5, 5)
		pe.SpreadAngle          = Vector2.new(12, 12)
		pe.VelocityInheritance  = 0.2
		pe.Parent               = att
	end
end

-- Track which players have the Eye Upgrade so newly spawned units get eyes too
local eyeUpgradePlayers: { [number]: boolean } = {}

local function addCreepyEyes(id: string, body: BasePart, unitType: string)
	if body:FindFirstChild("_EyeL") then return end
	local decs = unitDecorators[id]

	local function makeEye(localCF: CFrame, name: string, eyeSize: number)
		local irisLocal  = localCF * CFrame.new(0, 0, -eyeSize * 0.3)
		local pupilLocal = localCF * CFrame.new(0, 0, -eyeSize * 0.44)

		local sclera        = Instance.new("Part")
		sclera.Name         = name
		sclera.Shape        = Enum.PartType.Ball
		sclera.Size         = Vector3.new(eyeSize, eyeSize, eyeSize)
		sclera.Color        = Color3.fromRGB(255, 255, 255)
		sclera.Material     = Enum.Material.SmoothPlastic
		sclera.Anchored     = true
		sclera.CanCollide   = false
		sclera.CastShadow   = false
		sclera.CanQuery     = false
		sclera.CFrame       = body.CFrame * localCF
		sclera.Parent       = body
		decs[#decs + 1]     = { part = sclera, localCF = localCF }

		local iris          = Instance.new("Part")
		iris.Name           = "_Iris"
		iris.Shape          = Enum.PartType.Ball
		iris.Size           = Vector3.new(eyeSize * 0.42, eyeSize * 0.42, eyeSize * 0.42)
		iris.Color          = Color3.fromRGB(255, 30, 0)
		iris.Material       = Enum.Material.Neon
		iris.Anchored       = true
		iris.CanCollide     = false
		iris.CastShadow     = false
		iris.CanQuery       = false
		iris.CFrame         = body.CFrame * irisLocal
		iris.Parent         = body
		decs[#decs + 1]     = { part = iris, localCF = irisLocal }

		local pupil         = Instance.new("Part")
		pupil.Name          = "_Pupil"
		pupil.Shape         = Enum.PartType.Ball
		pupil.Size          = Vector3.new(eyeSize * 0.2, eyeSize * 0.2, eyeSize * 0.2)
		pupil.Color         = Color3.fromRGB(0, 0, 0)
		pupil.Material      = Enum.Material.SmoothPlastic
		pupil.Anchored      = true
		pupil.CanCollide    = false
		pupil.CastShadow    = false
		pupil.CanQuery      = false
		pupil.CFrame        = body.CFrame * pupilLocal
		pupil.Parent        = body
		decs[#decs + 1]     = { part = pupil, localCF = pupilLocal }
	end

	if unitType == "Soldier" then
		local halfX   = 1.0
		local eyeSize = 1.4
		makeEye(CFrame.new(-halfX + eyeSize * 0.1, 0.4, 0) * CFrame.Angles(0,  math.pi / 2, 0), "_EyeL", eyeSize)
		makeEye(CFrame.new( halfX - eyeSize * 0.1, 0.4, 0) * CFrame.Angles(0, -math.pi / 2, 0), "_EyeR", eyeSize)
	else
		local topY    = body.Size.Y / 2
		local halfX   = body.Size.X * 0.22
		local fwdZ    = -(body.Size.Z / 2) + 0.15
		local eyeSize = 1.5
		makeEye(CFrame.new(-halfX, topY * 0.28, fwdZ), "_EyeL", eyeSize)
		makeEye(CFrame.new( halfX, topY * 0.28, fwdZ), "_EyeR", eyeSize)
	end
end

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

local function applyHP(data: UnitData, tookDamage: boolean?)
	-- Notify the owner that their army is under attack here (throttled per region).
	if tookDamage and data.hp > 0 then
		AlertManager.report(data.owner, data.part.Position, "army")
	end
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
	if data.hp >= data.maxHp then
		bb.Enabled       = false
		data.hpBarHideAt = nil
	elseif tookDamage then
		bb.Enabled = true
		local t = tick() + HP_BAR_SHOW_SECS
		data.hpBarHideAt = t
		task.delay(HP_BAR_SHOW_SECS, function()
			if data.hpBarHideAt == t and bb.Parent then
				bb.Enabled = false
			end
		end)
	end
end

-- Returns the effective damage dealt to a unit after applying Hardened Armor.
local function calcDamage(targetData: UnitData, rawDmg: number): number
	if targetData.unitType == "Soldier" and researchManagerRef
		and researchManagerRef.hasResearch(targetData.owner, "HardenedArmor") then
		return math.max(1, rawDmg - Config.SOLDIER_ARMOR)
	end
	return rawDmg
end

-- ── Spawn ─────────────────────────────────────────────────────────────────────

local function spawnUnit(player: Player, position: Vector3, unitType: string): string?
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return nil end

	-- Enforce per-player unit cap
	if (playerUnitCount[player.UserId] or 0) >= MAX_UNITS_PER_PLAYER then return nil end

	counter += 1
	local id = "u" .. counter

	-- Initialize decorator list before any decoration function is called
	unitDecorators[id] = {}

	local part          = Instance.new("Part")
	part.Name           = id
	part.Size           = typeDef.size
	part.Position       = Vector3.new(position.X, typeDef.size.Y / 2 + 0.1, position.Z)
	part.BrickColor     = player.TeamColor
	part.Material       = Enum.Material.SmoothPlastic
	part.Anchored       = true
	part.CastShadow     = false

	-- CreepySoldier: always black regardless of team color
	if unitType == "CreepySoldier" then
		part.BrickColor = BrickColor.new("Black")
	end

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

	-- Static body geometry comes from the shared blueprint (single source of
	-- truth, also used by the ViewportFrame previews in UnitVisuals).
	local blueprint = UnitBlueprints.get(unitType, part.Size)
	if blueprint then
		buildFromBlueprint(id, part, blueprint)
	end

	-- Per-unit extras that aren't plain geometry:
	if unitType == "Tank" then
		local hv   = Instance.new("NumberValue")
		hv.Name    = "HarpoonCount"
		hv.Value   = 0
		hv.Parent  = part
	end
	if unitType == "Howitzer" then
		attachHowitzerSmoke(part)
	end
	if unitType == "Lamprey" then
		-- The entire creature is drawn by the client LampreyBody animator; the body
		-- part is just an invisible, ground-snapped pivot used for movement/targeting.
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 2.5, 0) end  -- just above the reared head
	end
	if eyeUpgradePlayers[player.UserId] then addCreepyEyes(id, part, unitType) end

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

	playerUnitCount[player.UserId] = (playerUnitCount[player.UserId] or 0) + 1
	RemoteHandler.get(Config.REMOTES.UnitSpawned):FireAllClients(id, player.UserId, part.Position)

	-- Foamer: initialise deploy state and cache the barrel decorator reference
	if unitType == "Foamer" then
		units[id].foamState = "mobile"
		for _, dec in unitDecorators[id] do
			if dec.part.Name == "FoamBarrel" then
				units[id].foamBarrelDec = dec
				break
			end
		end
	end

	return id
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
			if researchManagerRef and player.UserId > 0 then
				researchManagerRef.recordUnitTrained(player, item.unitType)
			end
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

-- Spawns immediately and returns the unit ID (for turret-spawned units that need tracking).
function UnitManager.spawnUnitNow(player: Player, position: Vector3, unitType: string): string?
	return spawnUnit(player, position, unitType)
end

-- Spawns a unit for a Deployer and records it in the tracking tables.
-- Deployed units automatically attack-march toward enemy territory at no resource cost.
function UnitManager.spawnForDeployer(deployerId: string, player: Player, spawnPos: Vector3, unitType: string?)
	local spawnType = unitType or "Soldier"
	local uid = spawnUnit(player, spawnPos, spawnType)
	if uid then
		if not deployerUnits[deployerId] then deployerUnits[deployerId] = {} end
		deployerUnits[deployerId][uid] = true
		unitToDeployer[uid] = deployerId
		local data = units[uid]
		if data then
			-- March toward the opposite corner of the map from the spawn point.
			-- atkMoveDest keeps the aggro scan active so the unit fights enemies it
			-- passes; when a kill clears aggroId the unit resumes the march.
			local marchX    = math.clamp(-spawnPos.X * 3, -MOVE_BOUND, MOVE_BOUND)
			local marchZ    = math.clamp(-spawnPos.Z * 3, -MOVE_BOUND, MOVE_BOUND)
			local marchDest = Vector3.new(marchX, 0, marchZ)
			data.target      = marchDest
			data.home        = marchDest
			data.atkMoveDest = marchDest
		end
	end
end

-- Returns the number of soldiers currently alive that belong to this Deployer.
function UnitManager.getDeployerAliveCount(deployerId: string): number
	local set = deployerUnits[deployerId]
	if not set then return 0 end
	local count = 0
	for uid in set do
		if units[uid] then count += 1 end
	end
	return count
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
		local dep = unitToDeployer[id]
		if dep then
			unitToDeployer[id] = nil
			if deployerUnits[dep] then deployerUnits[dep][id] = nil end
		end
	end
end

function UnitManager.resetAll()
	for id, data in units do
		if data.part and data.part.Parent then data.part:Destroy() end
	end
	units            = {}
	unitDecorators   = {}
	playerUnitCount  = {}
	eyeUpgradePlayers = {}
end

function UnitManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

function UnitManager.setResearchManager(rm: any)
	researchManagerRef = rm
	rm.addCompletionHook(function(player: any, techName: string)
		if techName == "EyeUpgrade" then
			UnitManager.applyEyeUpgrade(player)
		end
	end)
end

-- Called when a player completes EyeUpgrade: adds eyes to all their existing units
-- and marks them so future spawns also get eyes.
function UnitManager.applyEyeUpgrade(player: any)
	eyeUpgradePlayers[player.UserId] = true
	for id, data in units do
		if data.owner == player then
			if not unitDecorators[id] then unitDecorators[id] = {} end
			addCreepyEyes(id, data.part, data.unitType)
		end
	end
end

function UnitManager.setMineralManager(mm: any)
	mineralManagerRef = mm
end

-- Returns world positions of all of `ownerStr`'s living units. Used by the
-- Artillery spotter check to decide whether a far target is out of the fog.
function UnitManager.getOwnerUnitPositions(ownerStr: string): { Vector3 }
	local out: { Vector3 } = {}
	for _, data in units do
		if data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == ownerStr then
			out[#out + 1] = data.part.Position
		end
	end
	return out
end

-- `canTarget` (optional): predicate `(targetPos) -> boolean`. When supplied, only
-- enemies it approves are eligible (Artillery uses it to require a spotter).
function UnitManager.damageNearestUnit(fromPos: Vector3, attackerOwnerIdStr: string, range: number, damage: number, canTarget: ((Vector3) -> boolean)?): (boolean, Vector3?)
	local bestId, bestDist = nil :: string?, math.huge
	fillGridScratch(fromPos, range)
	for i = 1, gridScratchN do
		local id   = gridScratch[i]
		local data = units[id]
		if not data or data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.part.Position - fromPos).Magnitude
		if d <= range and d < bestDist and (not canTarget or canTarget(data.part.Position)) then
			bestDist = d; bestId = id
		end
	end
	if not bestId then return false, nil end
	local data   = units[bestId]
	local hitPos = data.part.Position + Vector3.new(0, data.part.Size.Y * 0.5, 0)
	data.hp -= calcDamage(data, damage)
	applyHP(data, true)
	if data.hp <= 0 then
		if data.trapperHarpooned then
			for tId, _ in data.trapperHarpooned do
				local tgt = units[tId]
				if tgt then
					local n = (tgt.incomingHarpoons or 1) - 1
					tgt.incomingHarpoons = if n > 0 then n else nil
				end
			end
		end
		if (data.unitType == "Tank" or data.unitType == "Soldier")
			and data.owner.UserId > 0 and data.owner.Parent then
			RemoteHandler.get(Config.REMOTES.UnitDied):FireClient(data.owner, data.unitType, hitPos)
		end
		if researchManagerRef and data.owner.UserId ~= tonumber(attackerOwnerIdStr) then
			researchManagerRef.recordEnemyKilled(attackerOwnerIdStr)
		end
		unitDecorators[bestId] = nil
		playerUnitCount[data.owner.UserId] = math.max(0, (playerUnitCount[data.owner.UserId] or 1) - 1)
		data.part:Destroy()
		units[bestId] = nil
		local dep = unitToDeployer[bestId]
		if dep then
			unitToDeployer[bestId] = nil
			if deployerUnits[dep] then deployerUnits[dep][bestId] = nil end
		end
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
	local unitHitRemote  = RemoteHandler.get(Config.REMOTES.UnitHit)
	local unitDiedRemote = RemoteHandler.get(Config.REMOTES.UnitDied)
	local healBeamRemote = RemoteHandler.get(Config.REMOTES.HealBeam)

	-- Terrain-height snapping: cast straight down to find the surface Y at any XZ.
	-- Filters to Terrain only so buildings/units don't interfere.
	local terrainRp = RaycastParams.new()
	terrainRp.FilterType = Enum.RaycastFilterType.Include
	terrainRp.FilterDescendantsInstances = { workspace.Terrain }

	local function getGroundY(x: number, z: number, halfSizeY: number): number
		local result = workspace:Raycast(
			Vector3.new(x, 22, z),
			Vector3.new(0, -34, 0),
			terrainRp
		)
		return if result then result.Position.Y + halfSizeY else halfSizeY + 0.1
	end

	RunService.Heartbeat:Connect(function(dt)
		local toRemove: { string } = {}
		rebuildSpatialGrid()
		aggroScanFrame = (aggroScanFrame + 1) % AGGRO_SCAN_EVERY
		local doAggro  = aggroScanFrame == 0

		for id, data in units do
			local isRoller  = data.unitType == "Soldier" and researchManagerRef ~= nil
				and researchManagerRef.hasResearch(data.owner, "Rollers")
			if isRoller then data.attackRange = Config.ROLLER_ATTACK_RANGE end

			local isFoamer  = data.foamState ~= nil
			local foamState = data.foamState or ""

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

			-- ── Foamer: deploy / undeploy state machine ───────────────────────
			if isFoamer then
				local ft = tick()
				if foamState == "mobile" then
					-- Deploy when aggro target enters attack range
					if data.aggroId then
						local aggroTarget = units[data.aggroId]
						if aggroTarget and aggroTarget.hp > 0 then
							local dist = (aggroTarget.part.Position - data.part.Position).Magnitude
							if dist <= data.attackRange then
								foamState            = "deploying"
								data.foamState       = "deploying"
								data.foamDeployStart = ft
								data.foamSinkBaseY   = data.part.Position.Y
								data.target          = nil
								data.velocity        = Vector3.zero
							end
						end
					end
				else
					-- Freeze movement in all non-mobile states
					data.target   = nil
					data.velocity = Vector3.zero
					if foamState == "deploying" then
						local elapsed  = ft - (data.foamDeployStart :: number)
						local progress = math.min(elapsed / Config.FOAMER_DEPLOY_TIME, 1)
						-- Sink body
						local sinkY = (data.foamSinkBaseY :: number) - Config.FOAMER_SINK_DEPTH * progress
						data.part.CFrame = CFrame.new(data.part.Position.X, sinkY, data.part.Position.Z) * data.part.CFrame.Rotation
						-- Raise barrel (localCF.Y interpolates from 0.3 → 3.5)
						if data.foamBarrelDec then
							(data.foamBarrelDec :: Decorator).localCF = CFrame.new(0, 0.3 + 3.2 * progress, 0)
						end
						if progress >= 1 then
							foamState      = "deployed"
							data.foamState = "deployed"
						end
					elseif foamState == "deployed" then
						-- Undeploy if no enemies remain in range
						local hasEnemy = false
						local fmPos    = data.part.Position
						local fmStr    = tostring(data.owner.UserId)
						fillGridScratch(fmPos, data.attackRange)
						for fgi = 1, gridScratchN do
							local fmOther = units[gridScratch[fgi]]
							if fmOther and fmOther.hp > 0 and tostring(fmOther.owner.UserId) ~= fmStr then
								hasEnemy = true; break
							end
						end
						if not hasEnemy then
							foamState            = "undeploying"
							data.foamState       = "undeploying"
							data.foamDeployStart = ft
							data.foamSinkBaseY   = data.part.Position.Y
							data.aggroId         = nil
							data.aggroHome       = nil
						end
					elseif foamState == "undeploying" then
						local elapsed  = ft - (data.foamDeployStart :: number)
						local progress = math.min(elapsed / Config.FOAMER_UNDEPLOY_TIME, 1)
						-- Rise body back
						local riseY = (data.foamSinkBaseY :: number) + Config.FOAMER_SINK_DEPTH * progress
						data.part.CFrame = CFrame.new(data.part.Position.X, riseY, data.part.Position.Z) * data.part.CFrame.Rotation
						-- Retract barrel (localCF.Y interpolates from 3.5 → 0.3)
						if data.foamBarrelDec then
							(data.foamBarrelDec :: Decorator).localCF = CFrame.new(0, 3.5 - 3.2 * progress, 0)
						end
						if progress >= 1 then
							foamState      = "mobile"
							data.foamState = "mobile"
							-- Re-snap to ground after undeploy
							local fpos3   = data.part.Position
							local groundY = getGroundY(fpos3.X, fpos3.Z, data.part.Size.Y / 2)
							data.part.CFrame = CFrame.new(fpos3.X, groundY, fpos3.Z) * data.part.CFrame.Rotation
						end
					end
				end
			end
			-- ────────────────────────────────────────────────────────────────────

			-- ── 2. Velocity-based movement ────────────────────────────────────
			local pos = data.part.Position

			-- Roller charge: fast dash to target and bounce back, bypasses normal movement
			if isRoller and (data.rollerCharging or data.rollerChargingOut) then
				local chargeTarget = if data.rollerCharging
					then (data.rollerChargeTarget :: Vector3)
					else (data.rollerChargeHome  :: Vector3)
				local cDelta = Vector3.new(chargeTarget.X - pos.X, 0, chargeTarget.Z - pos.Z)
				local cDist  = cDelta.Magnitude
				if cDist < 1.5 then
					if data.rollerCharging then
						data.rollerCharging    = false
						data.rollerChargingOut = true
					else
						data.rollerChargingOut  = false
						data.rollerChargeHome   = nil
						data.rollerChargeTarget = nil
					end
				else
					local step   = math.min(Config.ROLLER_CHARGE_SPEED * dt, cDist)
					local np     = pos + cDelta.Unit * step
					local newPos = Vector3.new(np.X, getGroundY(np.X, np.Z, data.part.Size.Y / 2), np.Z)
					data.rollerAngle = ((data.rollerAngle or 0) + step * Config.ROLLER_ROLL_PER_STUD) % (2 * math.pi)
					data.part.CFrame = CFrame.lookAt(newPos, newPos + cDelta.Unit) * CFrame.Angles(-data.rollerAngle, 0, 0)
				end
			else
				-- Normal velocity-based movement
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
						local effSpeed = data.moveSpeed
						local t = tick()
						if data.slowUntil and t < (data.slowUntil :: number) then
							effSpeed = effSpeed * Config.TANK_SLOW_MULT
						end
						if data.incomingHarpoons and (data.incomingHarpoons :: number) > 0 then
							effSpeed = effSpeed * (Config.TRAPPER_SLOW_MULT ^ (data.incomingHarpoons :: number))
						end
						if data.foamedUntil and t < (data.foamedUntil :: number) then
							effSpeed = effSpeed * Config.FOAMER_FOAM_SLOW_MULT
						end
						if data.unitType == "Soldier" and data.stimUntil and t < (data.stimUntil :: number) then
							effSpeed = effSpeed * Config.SOLDIER_STIM_SPEED
						end
						if isRoller then effSpeed = effSpeed * Config.ROLLER_SPEED_MULT end
						desired = delta.Unit * effSpeed

						-- Terrain obstacle avoidance: repel from obstacle edges.
						-- Elevated units (on ramps/platforms) skip this so the platform
						-- obstacle parts don't push them sideways off the terrain.
						local unitIsElevated = pos.Y > data.part.Size.Y / 2 + 4
						local terrainF = if unitIsElevated then nil else workspace:FindFirstChild("TerrainObstacles")
						if terrainF then
							local repX, repZ = 0, 0
							local AVOID_R = Config.TERRAIN_AVOIDANCE_RADIUS
							for _, obs in terrainF:GetChildren() do
								if not obs:IsA("BasePart") then continue end
								local hw = obs.Size.X / 2
								local hd = obs.Size.Z / 2
								local ox = obs.Position.X
								local oz = obs.Position.Z
								local cx2 = math.clamp(pos.X, ox - hw, ox + hw)
								local cz2 = math.clamp(pos.Z, oz - hd, oz + hd)
								local sx  = pos.X - cx2
								local sz  = pos.Z - cz2
								local sd  = math.sqrt(sx * sx + sz * sz)
								if sd < AVOID_R then
									local nx, nz
									if sd > 0.05 then
										nx = sx / sd; nz = sz / sd
									else
										nx = 1; nz = 0  -- emergency escape
									end
									local strength = (1 - sd / AVOID_R) ^ 2
									repX = repX + nx * strength
									repZ = repZ + nz * strength
								end
							end
							if repX ~= 0 or repZ ~= 0 then
								desired = desired + Vector3.new(repX, 0, repZ) * effSpeed * 2
								local dMag = desired.Magnitude
								if dMag > effSpeed then
									desired = desired * (effSpeed / dMag)
								end
							end
						end
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
					local newX   = math.clamp(pos.X + vel.X * dt, -MOVE_BOUND, MOVE_BOUND)
					local newZ   = math.clamp(pos.Z + vel.Z * dt, -MOVE_BOUND, MOVE_BOUND)
					local newY   = getGroundY(newX, newZ, data.part.Size.Y / 2)
					local newPos = Vector3.new(newX, newY, newZ)
					local flatVel = Vector3.new(vel.X, 0, vel.Z)
					if flatVel.Magnitude > 0.5 then
						if isRoller then
							data.rollerAngle = ((data.rollerAngle or 0) + vel.Magnitude * dt * Config.ROLLER_ROLL_PER_STUD) % (2 * math.pi)
							data.part.CFrame = CFrame.lookAt(newPos, newPos + flatVel) * CFrame.Angles(-data.rollerAngle, 0, 0)
						else
							data.part.CFrame = CFrame.lookAt(newPos, newPos + flatVel)
						end
					else
						data.part.Position = newPos
					end
				end
			end

			-- ── 3. Aggro scan (idle + A-moving units only; Medics/frozen Foamers skip) ──
			if doAggro and not data.aggroId and not data.focusBldId and data.unitType ~= "Medic"
				and not (isFoamer and foamState ~= "mobile") then
				if data.target == nil or data.atkMoveDest ~= nil then
					local myStr = tostring(data.owner.UserId)
					local myPos = data.part.Position
					local bestId2, bestDist2 = nil :: string?, AGGRO + 1
					local acx0 = math.floor((myPos.X - AGGRO) / GRID_CELL) + GRID_OFFSET
					local acx1 = math.floor((myPos.X + AGGRO) / GRID_CELL) + GRID_OFFSET
					local acz0 = math.floor((myPos.Z - AGGRO) / GRID_CELL) + GRID_OFFSET
					local acz1 = math.floor((myPos.Z + AGGRO) / GRID_CELL) + GRID_OFFSET
					for gx = acx0, acx1 do
						for gz = acz0, acz1 do
							local cell = spatialGrid[gx * GRID_STRIDE + gz]
							if not cell then continue end
							for _, otherId in cell do
								local other = units[otherId]
								if not other or other.hp <= 0 then continue end
								if tostring(other.owner.UserId) == myStr then continue end
								local dx = other.part.Position.X - myPos.X
								local dz = other.part.Position.Z - myPos.Z
								local d  = math.sqrt(dx * dx + dz * dz)
								if d <= AGGRO and d < bestDist2 then
									bestDist2 = d; bestId2 = otherId
								end
							end
						end
					end
					if bestId2 then
						data.aggroId   = bestId2
						data.aggroHome = data.part.Position
						-- Auto-trigger Combat Stims on engagement
						if data.unitType == "Soldier" and researchManagerRef
							and researchManagerRef.hasResearch(data.owner, "CombatStims") then
							local t = tick()
							if not data.stimCooldownUntil or t >= (data.stimCooldownUntil :: number) then
								data.stimUntil         = t + Config.SOLDIER_STIM_DURATION
								data.stimCooldownUntil = t + Config.SOLDIER_STIM_DURATION + Config.SOLDIER_STIM_COOLDOWN
							end
						end
					end
				end
			end

			-- ── 4. Combat ─────────────────────────────────────────────────────
			if data.hp <= 0 then continue end

			-- Foamer: foam attack when deployed; skip normal combat in all states
			if isFoamer then
				if foamState == "deployed" then
					data.attackTimer += dt
					if data.attackTimer >= data.attackRate then
						data.attackTimer -= data.attackRate
						local fmPos  = data.part.Position
						local fmStr  = tostring(data.owner.UserId)
						local fmBest: string?  = nil
						local fmDist           = math.huge
						fillGridScratch(fmPos, data.attackRange)
						for fgi = 1, gridScratchN do
							local otherId = gridScratch[fgi]
							local other   = units[otherId]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == fmStr then continue end
							local d = (other.part.Position - fmPos).Magnitude
							if d <= data.attackRange and d < fmDist then
								fmDist = d; fmBest = otherId
							end
						end
						if fmBest then
							local other   = units[fmBest]
							local hitPos  = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							-- Apply foam debuff only if the target is not already foamed
							local now = tick()
							if not other.foamedUntil or now >= (other.foamedUntil :: number) then
								other.foamedUntil  = now + Config.FOAMER_FOAM_DURATION
								other.foamDotAccum = 0
							end
							-- Small direct-hit damage
							other.hp -= calcDamage(other, data.attackDmg)
							applyHP(other, true)
							if other.hp <= 0 then table.insert(toRemove, fmBest) end
							-- Face the target
							local flatDir = Vector3.new(hitPos.X - fmPos.X, 0, hitPos.Z - fmPos.Z)
							if flatDir.Magnitude > 0.1 then
								data.part.CFrame = CFrame.lookAt(fmPos, fmPos + flatDir)
							end
							-- Fire foam VFX from barrel tip
							local barrelTip = fmPos + Vector3.new(0, data.part.Size.Y / 2 + 2, 0)
							unitHitRemote:FireAllClients(barrelTip, hitPos, "Foam")
						end
					end
				end
				continue  -- Foamers skip all standard combat paths
			end

			data.attackTimer += dt
			local effectiveRate = data.attackRate
			if data.unitType == "Soldier" and data.stimUntil and tick() < (data.stimUntil :: number) then
				effectiveRate = effectiveRate * Config.SOLDIER_STIM_RATE
			end
			-- Trapper uses a fast check interval so it reacts quickly when a harpoon slot opens
			if data.unitType == "Tank" and researchManagerRef
				and researchManagerRef.hasResearch(data.owner, "Trapper") then
				effectiveRate = math.min(effectiveRate, 0.5)
			end
			if data.attackTimer < effectiveRate then continue end
			data.attackTimer -= effectiveRate

			local myPos      = data.part.Position
			local myOwnerStr = tostring(data.owner.UserId)
			local hitPos:  Vector3? = nil
			local vfxType: string   = data.unitType

			local atkRange = data.attackRange

			-- ── Medic: heal most-damaged nearby friendly unit ──────────────────
			if data.unitType == "Medic" then
				local bestId2: string?  = nil
				local lowestRatio       = 1.0
				fillGridScratch(myPos, atkRange)
				for gi = 1, gridScratchN do
					local otherId = gridScratch[gi]
					if otherId == id then continue end
					local other = units[otherId]
					if not other or other.hp <= 0 then continue end
					if tostring(other.owner.UserId) ~= myOwnerStr then continue end
					local ratio = other.hp / other.maxHp
					if ratio >= 1.0 then continue end
					local d = (other.part.Position - myPos).Magnitude
					if d <= atkRange and ratio < lowestRatio then
						lowestRatio = ratio; bestId2 = otherId
					end
				end
				if bestId2 then
					local other    = units[bestId2]
					other.hp       = math.min(other.maxHp, other.hp + data.attackDmg)
					applyHP(other)
					local targetTop = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
					local myTop     = myPos + Vector3.new(0, data.part.Size.Y * 0.5, 0)
					-- Face the patient
					local flatDir = Vector3.new(targetTop.X - myPos.X, 0, targetTop.Z - myPos.Z)
					if flatDir.Magnitude > 0.1 then
						data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
					end
					healBeamRemote:FireAllClients(myTop, targetTop)
				end
				continue  -- Medics never attack buildings or miners
			end

			if data.unitType == "Tank" then
				-- Tanks: buildings first (+ AoE splash on nearby units), fall back to units.
				-- With RocketBarrage researched: fires 3 rockets (each 65% damage) instead of
				-- one shell, with random landing spread and individual splash per rocket.
				-- With Trapper researched (mutually exclusive with RocketBarrage): fires harpoons
				-- that slow enemies by 90% for 7 s without dealing damage.
				local hasConcussion = researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "ConcussionShells")
				local hasBarrage    = researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "RocketBarrage")
				local hasTrapper    = not hasBarrage and researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "Trapper")

				if hasTrapper then
					-- ── Trapper: harpoon launcher ────────────────────────────────
					-- Initialize harpoon state the first time this tank fires as a trapper
					if not data.harpoonCount then
						data.harpoonCount     = Config.TRAPPER_HARPOON_MAX
						data.harpoonRestockAt = 0
						data.trapperHarpooned = {}
						local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
						if hv then hv.Value = Config.TRAPPER_HARPOON_MAX end
					end

					local t      = tick()
					local hrp    = data.trapperHarpooned :: {[string]: number}
					local hCount = data.harpoonCount :: number
					local restAt = data.harpoonRestockAt :: number

					-- Expire old harpoons and decrement the target's incoming-harpoon counter
					for tId, exp in hrp do
						if t >= exp then
							hrp[tId] = nil
							local tgt = units[tId]
							if tgt then
								local n = (tgt.incomingHarpoons or 1) - 1
								tgt.incomingHarpoons = if n > 0 then n else nil
							end
						end
					end

					-- Restock one harpoon if the timer has elapsed
					if hCount < Config.TRAPPER_HARPOON_MAX and t >= restAt then
						hCount += 1
						data.harpoonCount = hCount
						if hCount < Config.TRAPPER_HARPOON_MAX then
							data.harpoonRestockAt = t + Config.TRAPPER_RESTOCK_TIME
						end
						local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
						if hv then hv.Value = hCount end
					end

					-- Fire a harpoon at the nearest enemy unit not already harpooned
					if hCount > 0 then
						local bestId2: string? = nil
						local bestDist2 = math.huge
						fillGridScratch(myPos, atkRange)
						for gi = 1, gridScratchN do
							local otherId = gridScratch[gi]
							local other = units[otherId]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							if hrp[otherId] then continue end
							local d = (other.part.Position - myPos).Magnitude
							if d <= atkRange and d < bestDist2 then
								bestDist2 = d; bestId2 = otherId
							end
						end
						if bestId2 then
							local other = units[bestId2]
							hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							-- Increment stacking slow counter on target
							other.incomingHarpoons = (other.incomingHarpoons or 0) + 1
							hrp[bestId2] = t + Config.TRAPPER_SLOW_DURATION
							hCount -= 1
							data.harpoonCount = hCount
							-- Start restock countdown for the consumed harpoon
							if hCount < Config.TRAPPER_HARPOON_MAX and t >= restAt then
								data.harpoonRestockAt = t + Config.TRAPPER_RESTOCK_TIME
							end
							local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
							if hv then hv.Value = hCount end
							vfxType = "TankHarpoon"
						end
					end
				else
					-- ── Normal tank / Rocket Barrage ─────────────────────────────
					local slowEnd = tick() + Config.TANK_SLOW_DURATION

					-- Per-shot stats: barrage = 3 rockets × 65%; normal = 1 shell × 100%
					local shotCount = hasBarrage and Config.ROCKET_BARRAGE_COUNT    or 1
					local shotDmg   = hasBarrage
						and math.floor(data.attackDmg * Config.ROCKET_BARRAGE_DMG_MULT)
						or  data.attackDmg
					local spreadR   = hasBarrage and Config.ROCKET_BARRAGE_SPREAD or 0.0

					local function applySplash(centre: Vector3, skipId: string?)
						local splashR   = Config.TANK_SPLASH_RANGE
						local splashDmg = math.floor(shotDmg * Config.TANK_SPLASH_DAMAGE_MULT)
						for otherId, other in units do
							if other.hp <= 0 then continue end
							if skipId and otherId == skipId then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							if (other.part.Position - centre).Magnitude <= splashR then
								other.hp -= calcDamage(other, splashDmg)
								applyHP(other, true)
								if hasConcussion then other.slowUntil = slowEnd end
								if other.hp <= 0 then table.insert(toRemove, otherId) end
							end
						end
					end

					if buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
						end
						if bId and bPos then
							buildingManagerRef.damage(bId, shotDmg)
							hitPos = bPos
							for _ = 1, shotCount do
								local ox = (math.random() - 0.5) * 2 * spreadR
								local oz = (math.random() - 0.5) * 2 * spreadR
								applySplash(bPos + Vector3.new(ox, 0, oz), nil)
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
							hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							other.hp -= calcDamage(other, shotDmg)
							applyHP(other, true)
							if hasConcussion and other.hp > 0 then other.slowUntil = slowEnd end
							if other.hp <= 0 then table.insert(toRemove, bestId2) end
							for _ = 1, shotCount do
								local ox = (math.random() - 0.5) * 2 * spreadR
								local oz = (math.random() - 0.5) * 2 * spreadR
								applySplash(hitPos + Vector3.new(ox, 0, oz), bestId2)
							end
						end
					end

					if hasBarrage and hitPos then vfxType = "TankBarrage" end
				end
			else
				if isRoller then
					-- Roller: melee charge attack — find target, deal damage, start dash
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
						hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
						other.hp -= calcDamage(other, data.attackDmg)
						applyHP(other, true)
						if other.hp <= 0 then table.insert(toRemove, bestId2) end
						if not data.rollerCharging and not data.rollerChargingOut then
							data.rollerCharging     = true
							local chargeDir = (other.part.Position - myPos)
							data.rollerChargeTarget = myPos + chargeDir.Unit * Config.ROLLER_CHARGE_DIST
							data.rollerChargeHome   = myPos
						end
					elseif buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
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
							if not data.rollerCharging and not data.rollerChargingOut then
								data.rollerCharging     = true
								local chargeDir = (bPos - myPos)
								data.rollerChargeTarget = myPos + chargeDir.Unit * Config.ROLLER_CHARGE_DIST
								data.rollerChargeHome   = myPos
							end
						end
					end
				else
					-- Soldiers / Elite: nearest enemy unit first, fall back to buildings
					local bestId2, bestDist2 = nil :: string?, math.huge
					fillGridScratch(myPos, atkRange)
					for gi = 1, gridScratchN do
						local otherId = gridScratch[gi]
						local other = units[otherId]
						if not other or other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myOwnerStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= atkRange and d < bestDist2 then
							bestDist2 = d; bestId2 = otherId
						end
					end
					if bestId2 then
						local other = units[bestId2]
						hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
						other.hp -= calcDamage(other, data.attackDmg)
						applyHP(other, true)
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
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
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
			end

			-- Last resort: attack nearest enemy miner if no unit/building in range
			if not hitPos and mineralManagerRef then
				local hit, mPos = mineralManagerRef.damageNearestMiner(
					myPos, myOwnerStr, atkRange, data.attackDmg)
				if hit then hitPos = mPos end
			end

			-- Face attack target, then fire VFX
			if hitPos then
				if not isRoller then
					local flatDir = Vector3.new(hitPos.X - myPos.X, 0, hitPos.Z - myPos.Z)
					if flatDir.Magnitude > 0.1 then
						data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
					end
				end
				unitHitRemote:FireAllClients(myPos, hitPos, vfxType)
				-- Howitzer: leave a fire zone at the impact site
				if data.unitType == "Howitzer" then
					fireZones[#fireZones + 1] = {
						pos      = Vector3.new(hitPos.X, 0, hitPos.Z),
						elapsed  = 0,
						dotAccum = 0,
					}
				end
			end
		end

		-- ── Foam DoT tick ──────────────────────────────────────────────────────
		do
			local now = tick()
			for dotId, dotData in units do
				if not dotData.foamedUntil then continue end
				if now >= (dotData.foamedUntil :: number) then
					dotData.foamedUntil  = nil
					dotData.foamDotAccum = nil
					continue
				end
				dotData.foamDotAccum = (dotData.foamDotAccum or 0) + dt
				if (dotData.foamDotAccum :: number) >= 1.0 then
					dotData.foamDotAccum = (dotData.foamDotAccum :: number) - 1.0
					dotData.hp -= Config.FOAMER_FOAM_DOT
					applyHP(dotData, true)
					if dotData.hp <= 0 then table.insert(toRemove, dotId) end
				end
			end
		end

		-- ── Howitzer fire zone DoT (damages ALL units, both teams) ─────────────
		do
			local FIRE_FULL  = Config.HOWITZER_FIRE_FULL_DURATION
			local FIRE_FADE  = Config.HOWITZER_FIRE_FADE_DURATION
			local FIRE_TOTAL = FIRE_FULL + FIRE_FADE
			local FIRE_R     = Config.HOWITZER_FIRE_RADIUS
			local FIRE_DPS   = Config.HOWITZER_FIRE_DMG_PER_SEC
			local fzi = #fireZones
			while fzi > 0 do
				local fz    = fireZones[fzi]
				fz.elapsed += dt
				if fz.elapsed >= FIRE_TOTAL then
					table.remove(fireZones, fzi)
				else
					local dps = FIRE_DPS
					if fz.elapsed > FIRE_FULL then
						dps = FIRE_DPS * (1 - (fz.elapsed - FIRE_FULL) / FIRE_FADE)
					end
					fz.dotAccum += dt
					if fz.dotAccum >= 1.0 then
						fz.dotAccum -= 1.0
						local dmgTick = math.max(1, math.floor(dps))
						fillGridScratch(fz.pos, FIRE_R)
						for gi = 1, gridScratchN do
							local uid   = gridScratch[gi]
							local udata = units[uid]
							if not udata or udata.hp <= 0 then continue end
							if (udata.part.Position - fz.pos).Magnitude > FIRE_R then continue end
							udata.hp -= dmgTick
							applyHP(udata, true)
							if udata.hp <= 0 then table.insert(toRemove, uid) end
						end
					end
				end
				fzi -= 1
			end
		end

		-- ── Separation pass ────────────────────────────────────────────────────
		for id, data in units do
			local myPos = data.part.Position
			local myStr = tostring(data.owner.UserId)
			local pushX, pushZ = 0, 0
			local count = 0

			local scx0 = math.floor((myPos.X - SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scx1 = math.floor((myPos.X + SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scz0 = math.floor((myPos.Z - SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scz1 = math.floor((myPos.Z + SEP_DIST) / GRID_CELL) + GRID_OFFSET
			for gx = scx0, scx1 do
				for gz = scz0, scz1 do
					local cell = spatialGrid[gx * GRID_STRIDE + gz]
					if not cell then continue end
					for _, otherId in cell do
						if otherId == id then continue end
						local other = units[otherId]
						if not other then continue end
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
				end
			end

			-- Deployed Foamers are frozen in place; separation would fight the sink animation
			if count > 0 and not (data.foamState and data.foamState ~= "mobile") then
				local mag = math.sqrt(pushX * pushX + pushZ * pushZ)
				if mag > 0.01 then
					local nx = myPos.X + (pushX / mag) * SEP_PUSH
					local nz = myPos.Z + (pushZ / mag) * SEP_PUSH
					data.part.CFrame = CFrame.new(nx, getGroundY(nx, nz, data.part.Size.Y / 2), nz) * data.part.CFrame.Rotation
				end
			end
		end

		-- Update anchored decorator parts (treads, pill body, eyes, etc.) to match body CFrame.
		-- This replaces the old WeldConstraint physics pass for all decorated units.
		for id, data in units do
			local decs = unitDecorators[id]
			if not decs then continue end
			local bodyCF = data.part.CFrame
			for _, d in decs do
				d.part.CFrame = bodyCF * d.localCF
			end
		end

		-- Remove dead units
		for _, id in toRemove do
			local d = units[id]
			if d then
				if d.trapperHarpooned then
					for tId, _ in d.trapperHarpooned do
						local tgt = units[tId]
						if tgt then
							local n = (tgt.incomingHarpoons or 1) - 1
							tgt.incomingHarpoons = if n > 0 then n else nil
						end
					end
				end
				if (d.unitType == "Tank" or d.unitType == "Soldier")
					and d.owner.UserId > 0 and d.owner.Parent then
					unitDiedRemote:FireClient(d.owner, d.unitType, d.part.Position)
				end
				unitDecorators[id] = nil
				playerUnitCount[d.owner.UserId] = math.max(0, (playerUnitCount[d.owner.UserId] or 1) - 1)
				d.part:Destroy()
				units[id] = nil
				local dep = unitToDeployer[id]
				if dep then
					unitToDeployer[id] = nil
					if deployerUnits[dep] then deployerUnits[dep][id] = nil end
				end
			end
		end
	end)

	-- Train remote
	RemoteHandler.get(Config.REMOTES.TrainUnit).OnServerEvent:Connect(function(player, barrackIds, unitType)
		if type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end

		-- Research gate: if this unit type requires a tech, verify the player has it
		if typeDef.researchReq then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, typeDef.researchReq) then
				return
			end
		end

		local ids = type(barrackIds) == "string" and {barrackIds} or barrackIds
		if type(ids) ~= "table" then return end

		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end

		for _, barrackId in ids do
			if type(barrackId) ~= "string" then continue end
			local building = buildingsFolder:FindFirstChild(barrackId)
			if not building then continue end

			local ownerVal = building:FindFirstChild("OwnerId")
			if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then continue end

			local base = building:FindFirstChild("Base") :: BasePart
			if not base then continue end

			local q = barrackQueues[barrackId] or {}
			if #q >= MAX_QUEUE then continue end

			if not resourceManagerRef.spend(player, typeDef.cost) then continue end

			local spawnPos  = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
			local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0

			if trainTime <= 0 then
				spawnUnit(player, spawnPos, unitType)
				continue
			end

			barrackQueues[barrackId] = q
			table.insert(q, { unitType = unitType, trainTime = trainTime, player = player, spawnPos = spawnPos })

			if not barrackIsTraining[barrackId] then
				startNextInQueue(barrackId)
			else
				fireTrainingUpdate(barrackId, player)
			end
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

	RemoteHandler.get(Config.REMOTES.SpawnLaneUnit).OnServerEvent:Connect(function(player, unitType)
		if not laneModeActive then return end
		if type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef or unitType == "CreepySoldier" then return end
		if not resourceManagerRef.spend(player, typeDef.cost) then return end
		local ccPos = buildingManagerRef and buildingManagerRef.getCCPosition(player)
		if not ccPos then
			resourceManagerRef.add(player, typeDef.cost)
			return
		end
		local id = spawnUnit(player, Vector3.new(ccPos.X, 0, ccPos.Z), unitType)
		if id then
			local data = units[id]
			if data then
				-- Auto-march toward enemy end of the lane
				local marchTarget = Vector3.new(ccPos.X, 0, -ccPos.Z * 1.2)
				data.target    = marchTarget
				data.home      = marchTarget
				data.atkMoveDest = marchTarget
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		AlertManager.clearPlayer(player.UserId)
		local toRemove = {}
		for id, data in units do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do
			units[id].part:Destroy()
			units[id] = nil
			local dep = unitToDeployer[id]
			if dep then
				unitToDeployer[id] = nil
				if deployerUnits[dep] then deployerUnits[dep][id] = nil end
			end
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

function UnitManager.setLaneMode(enabled: boolean)
	laneModeActive = enabled
end

return UnitManager
