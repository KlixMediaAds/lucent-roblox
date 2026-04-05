--[[
	AIManager v3 — Behavior-tree AI for server bots.

	Architecture:
	  • Strategy tick (5–10 s):  build order, squad rebuild, composition update,
	                              research queuing.
	  • Reaction tick (1–2 s):   vision scan, unit training, army command.
	  • BT primitives:  seq / sel / cond / act  → SUCCESS / FAILURE / RUNNING.

	Squad roles (rebuilt each strategy tick):
	  main force  ≈ 70 %  — attacks priority target or explores.
	  garrison    ≈ 20 %  — holds near base.
	  scouts      1–2 u   — patrol a different waypoint for vision.

	Threat scoring (reaction tick):
	  Each visible enemy target is scored; highest score drives priorityTarget.
	  CC(100) > Mine(60) > Barracks(50) > Workshop(40) > Turret(30) > unit(20).
	  Score is boosted for closer targets.

	Adaptive composition (strategy tick):
	  ≥2 enemy turrets → add Elite weight (long range).
	  ≥4 enemy units   → add Tank weight (splash + HP).
	  Elite weight is zeroed if EliteUnits research is not done.

	Chat command: /ai easy | /ai medium | /ai hard
--]]

local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local AIManager = {}

-- ── BT return values ──────────────────────────────────────────────────────────

local SUCCESS = 1
local FAILURE = 2
local RUNNING = 3

-- ── BT combinators ────────────────────────────────────────────────────────────

-- seq: run children left-to-right; stop and return on first non-SUCCESS.
local function seq(...)
	local children = { ... }
	return function(ai)
		for _, child in children do
			local r = child(ai)
			if r ~= SUCCESS then return r end
		end
		return SUCCESS
	end
end

-- act: wrap a plain function as a BT leaf (function must return SUCCESS/FAILURE/RUNNING).
local function act(fn)
	return function(ai) return fn(ai) end
end

-- ── Threat weights ────────────────────────────────────────────────────────────

local THREAT_BUILDING = {
	CommandCenter = 100,
	Mine          = 60,
	Barracks      = 50,
	Workshop      = 40,
	Turret        = 30,
}
local THREAT_UNIT = 20

-- ── Difficulty profiles ───────────────────────────────────────────────────────

type DifficultyProfile = {
	strategyInterval: number,   -- seconds between strategy ticks
	reactionInterval: number,   -- seconds between reaction ticks
	maxUnits:         number,
	maxMines:         number,
	maxBarracks:      number,
	maxTurrets:       number,
	maxWorkshops:     number,
	doResearch:       boolean,
	baseWeights:      { [string]: number },
	visionRadius:     number,
	enemyMemory:      number,   -- seconds before forgetting last spotted position
	minUnitsToAttack: number,
	garrisonRatio:    number,   -- fraction of army to keep at base
	scoutCount:       number,   -- units dedicated to scouting
	reserveResources: number,   -- do not spend below this balance
}

local DIFFICULTY: { [string]: DifficultyProfile } = {
	easy = {
		strategyInterval = 10,
		reactionInterval = 2,
		maxUnits         = 6,
		maxMines         = 1,
		maxBarracks      = 1,
		maxTurrets       = 0,
		maxWorkshops     = 0,
		doResearch       = false,
		baseWeights      = { Soldier = 1 },
		visionRadius     = 45,
		enemyMemory      = 15,
		minUnitsToAttack = 3,
		garrisonRatio    = 0.3,
		scoutCount       = 0,
		reserveResources = 50,
	},
	medium = {
		strategyInterval = 7,
		reactionInterval = 1.5,
		maxUnits         = 16,
		maxMines         = 2,
		maxBarracks      = 1,
		maxTurrets       = 2,
		maxWorkshops     = 0,
		doResearch       = false,
		baseWeights      = { Soldier = 6, Tank = 4 },
		visionRadius     = 58,
		enemyMemory      = 45,
		minUnitsToAttack = 6,
		garrisonRatio    = 0.2,
		scoutCount       = 1,
		reserveResources = 100,
	},
	hard = {
		strategyInterval = 5,
		reactionInterval = 1,
		maxUnits         = 999,
		maxMines         = 3,
		maxBarracks      = 2,
		maxTurrets       = 4,
		maxWorkshops     = 1,
		doResearch       = true,
		baseWeights      = { Soldier = 2, Tank = 6, Elite = 0 },
		visionRadius     = 65,
		enemyMemory      = 120,
		minUnitsToAttack = 8,
		garrisonRatio    = 0.2,
		scoutCount       = 1,
		reserveResources = 150,
	},
}

-- ── Placement candidate offsets ───────────────────────────────────────────────

local BARRACKS_CANDIDATES: { Vector3 } = {
	Vector3.new( 20, 0,  0), Vector3.new(-20, 0,  0),
	Vector3.new(  0, 0, 20), Vector3.new(  0, 0,-20),
	Vector3.new( 20, 0, 20), Vector3.new(-20, 0,-20),
	Vector3.new( 20, 0,-20), Vector3.new(-20, 0, 20),
	Vector3.new( 30, 0,  0), Vector3.new(-30, 0,  0),
}

local TURRET_CANDIDATES: { Vector3 } = {
	Vector3.new(-25, 0,  0), Vector3.new( 25, 0,  0),
	Vector3.new(  0, 0,-25), Vector3.new(  0, 0, 25),
	Vector3.new(-25, 0,-25), Vector3.new( 25, 0, 25),
	Vector3.new(-25, 0, 25), Vector3.new( 25, 0,-25),
	Vector3.new(-35, 0,  0), Vector3.new( 35, 0,  0),
	Vector3.new(  0, 0,-35), Vector3.new(  0, 0, 35),
}

local WORKSHOP_CANDIDATES: { Vector3 } = {
	Vector3.new(  0, 0, 30), Vector3.new(  0, 0,-30),
	Vector3.new( 30, 0,  0), Vector3.new(-30, 0,  0),
	Vector3.new( 25, 0, 25), Vector3.new(-25, 0, 25),
}

-- ── Bot spawn configuration ───────────────────────────────────────────────────

local AI_COLORS = {
	BrickColor.new("Magenta"),
	BrickColor.new("Teal"),
	BrickColor.new("Cyan"),
	BrickColor.new("Bright orange"),
}

local AI_BASES = {
	Vector3.new( 120, 0,  120),
	Vector3.new(-120, 0,  120),
	Vector3.new( 120, 0, -120),
	Vector3.new(-120, 0, -120),
}

-- ── Module state ──────────────────────────────────────────────────────────────

local aiCounter    = 0
local unitManager:     any
local buildingManager: any
local resourceManager: any
local researchManager: any

local botByUserId: { [number]: any } = {}

-- ── Utility ───────────────────────────────────────────────────────────────────

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

local function pickWeighted(weights: { [string]: number }): string
	local total = 0
	for _, w in weights do total += w end
	if total <= 0 then return "Soldier" end
	local r, cum = math.random() * total, 0
	for name, w in weights do
		cum += w
		if r <= cum then return name end
	end
	for name in weights do return name end
	return "Soldier"
end

local function canAfford(player: any, cost: number, reserve: number): boolean
	return resourceManager.get(player) >= cost + reserve
end

local function nearestFreeDeposit(fromPos: Vector3): Vector3?
	local folder = workspace:FindFirstChild("Deposits")
	if not folder then return nil end
	local best, bestDist = nil :: Vector3?, math.huge
	for _, obj in folder:GetChildren() do
		local wpos = obj:GetPivot().Position
		local p2   = Vector3.new(wpos.X, 0, wpos.Z)
		local d    = (p2 - Vector3.new(fromPos.X, 0, fromPos.Z)).Magnitude
		if d < bestDist then bestDist = d; best = p2 end
	end
	return best
end

local function tryPlace(player: any, base: Vector3, buildingType: string, candidates: { Vector3 }): (boolean, string?)
	for _, offset in candidates do
		local ok, id = buildingManager.placeForPlayer(player, snapGrid(base + offset), buildingType)
		if ok then return true, id end
	end
	return false, nil
end

-- ── Fog-of-war vision ─────────────────────────────────────────────────────────

-- Gathers world positions of all own units + buildings as "eye" positions.
local function gatherEyes(myStr: string): { Vector3 }
	local eyes: { Vector3 } = {}
	local unitsF     = workspace:FindFirstChild("Units")
	local buildingsF = workspace:FindFirstChild("Buildings")
	if unitsF then
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr and p:IsA("BasePart") then
				table.insert(eyes, (p :: BasePart).Position)
			end
		end
	end
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr then
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then table.insert(eyes, base.Position) end
			end
		end
	end
	return eyes
end

-- Kept from v2: returns nearest detected enemy position, or nil.
local function detectEnemiesInVision(ai: any): Vector3?
	local myStr = tostring(ai.player.UserId)
	local r2    = ai.diff.visionRadius * ai.diff.visionRadius
	local eyes  = gatherEyes(myStr)
	if #eyes == 0 then return nil end

	local bestPos: Vector3? = nil
	local bestD2  = math.huge

	local function check(epos: Vector3)
		for _, eye in eyes do
			local dx = epos.X - eye.X
			local dz = epos.Z - eye.Z
			local d2 = dx * dx + dz * dz
			if d2 <= r2 and d2 < bestD2 then
				bestD2  = d2
				bestPos = epos
			end
		end
	end

	local unitsF     = workspace:FindFirstChild("Units")
	local buildingsF = workspace:FindFirstChild("Buildings")
	if unitsF then
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if p:IsA("BasePart") then check((p :: BasePart).Position) end
		end
	end
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base") :: BasePart?
			if base then check(base.Position) end
		end
	end
	return bestPos
end

-- ── Threat scoring ────────────────────────────────────────────────────────────

-- Scans all enemies in vision range, scores each target, and returns:
--   (priorityTarget, enemyTurretCount, enemyUnitCount)
-- Higher threat score = more valuable target to attack.
local function scanThreats(ai: any): (Vector3?, number, number)
	local myStr    = tostring(ai.player.UserId)
	local r2       = ai.diff.visionRadius * ai.diff.visionRadius
	local visionR  = ai.diff.visionRadius
	local eyes     = gatherEyes(myStr)
	if #eyes == 0 then return nil, 0, 0 end

	local function inVision(epos: Vector3): (boolean, number)
		local minD2 = math.huge
		for _, eye in eyes do
			local dx = epos.X - eye.X
			local dz = epos.Z - eye.Z
			local d2 = dx * dx + dz * dz
			if d2 <= r2 and d2 < minD2 then minD2 = d2 end
		end
		return minD2 <= r2, math.sqrt(minD2)
	end

	local bestScore   = -math.huge
	local bestPos: Vector3? = nil
	local turretCount = 0
	local unitCount   = 0

	local buildingsF = workspace:FindFirstChild("Buildings")
	local unitsF     = workspace:FindFirstChild("Units")

	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base") :: BasePart?
			if not base then continue end
			local vis, dist = inVision(base.Position)
			if not vis then continue end

			local tv    = model:FindFirstChild("BuildingType")
			local btype = tv and tv.Value or "Barracks"
			if btype == "Turret" then turretCount += 1 end

			local base_score  = THREAT_BUILDING[btype] or 30
			local distFactor  = 1 - math.clamp(dist / visionR, 0, 0.8)
			local score       = base_score * (1 + distFactor)
			if score > bestScore then bestScore = score; bestPos = base.Position end
		end
	end

	if unitsF then
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if not p:IsA("BasePart") then continue end
			local epos = (p :: BasePart).Position
			local vis, dist = inVision(epos)
			if not vis then continue end
			unitCount += 1

			local distFactor = 1 - math.clamp(dist / visionR, 0, 0.8)
			local score      = THREAT_UNIT * (1 + distFactor)
			if score > bestScore then bestScore = score; bestPos = epos end
		end
	end

	return bestPos, turretCount, unitCount
end

-- ── Exploration waypoints ─────────────────────────────────────────────────────

-- Kept from v2: ordered patrol route from home → enemy territory.
local function generateExplorePoints(base: Vector3): { Vector3 }
	local sx = -math.sign(base.X)
	local sz = -math.sign(base.Z)
	return {
		snapGrid(Vector3.new(base.X + sx * 30, 0, base.Z)),
		snapGrid(Vector3.new(base.X,            0, base.Z + sz*30)),
		snapGrid(Vector3.new(sx * 70,  0, sz * 30)),
		snapGrid(Vector3.new(sx * 30,  0, sz * 70)),
		Vector3.new(0, 0, 0),
		snapGrid(Vector3.new(sx * 100, 0, 0)),
		snapGrid(Vector3.new(0,        0, sz * 100)),
		snapGrid(Vector3.new(sx * 120, 0, sz * 40)),
		snapGrid(Vector3.new(sx * 40,  0, sz * 120)),
		snapGrid(Vector3.new(sx * 120, 0, sz * 120)),
	}
end

-- ── Squad partitioning ────────────────────────────────────────────────────────

local function rebuildSquads(ai: any)
	local allUnits = unitManager.getPlayerUnitData(ai.player)
	local total    = #allUnits
	if total == 0 then
		ai.mainForce = {}; ai.garrison = {}; ai.scouts = {}
		return
	end

	local scoutN    = math.min(ai.diff.scoutCount, total)
	local remaining = total - scoutN
	local garrisonN = math.floor(remaining * ai.diff.garrisonRatio)
	-- main force gets the rest

	ai.scouts    = {}
	ai.garrison  = {}
	ai.mainForce = {}

	for i, ud in allUnits do
		if i <= scoutN then
			table.insert(ai.scouts, ud.id)
		elseif i <= scoutN + (remaining - garrisonN) then
			table.insert(ai.mainForce, ud.id)
		else
			table.insert(ai.garrison, ud.id)
		end
	end
end

-- ── Adaptive unit composition ─────────────────────────────────────────────────

local function updateComposition(ai: any)
	local w = {}
	for k, v in ai.diff.baseWeights do w[k] = v end

	-- Lots of enemy turrets → lean on Elite (longer range, outranges turrets)
	if ai.enemyTurretCount >= 2 then
		w["Elite"]   = (w["Elite"]   or 0) + ai.enemyTurretCount * 2
		w["Soldier"] = math.max(1, (w["Soldier"] or 1) - 1)
	end

	-- Lots of enemy units → lean on Tank (splash + HP pool)
	if ai.enemyUnitCount >= 4 then
		w["Tank"] = (w["Tank"] or 0) + math.floor(ai.enemyUnitCount / 2)
	end

	-- Respect research gate: zero Elite weight until unlocked
	if (w["Elite"] or 0) > 0 then
		local unlocked = researchManager and researchManager.hasResearch(ai.player, "EliteUnits")
		if not unlocked then w["Elite"] = 0 end
	end

	ai.currentWeights = w
end

-- ── BT leaf actions ───────────────────────────────────────────────────────────

local function btBuildCC(ai)
	if ai.hasCC then return SUCCESS end
	local ok = buildingManager.placeForPlayer(ai.player, ai.base, "CommandCenter")
	if ok then ai.hasCC = true; return SUCCESS end
	return RUNNING
end

local function btBuildFirstMine(ai)
	if ai.mineCount >= 1 then return SUCCESS end
	local deposit = nearestFreeDeposit(ai.base)
	if not deposit then return FAILURE end
	if not canAfford(ai.player, Config.MINE_COST, 0) then return RUNNING end
	local ok = buildingManager.placeForPlayer(ai.player, deposit, "Mine")
	if ok then ai.mineCount += 1; return SUCCESS end
	return RUNNING
end

local function btBuildFirstBarracks(ai)
	if #ai.barrackIds >= 1 then return SUCCESS end
	if not canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then return RUNNING end
	local ok, id = tryPlace(ai.player, ai.base, "Barracks", BARRACKS_CANDIDATES)
	if ok and id then table.insert(ai.barrackIds, id); return SUCCESS end
	return RUNNING
end

-- Expansion: runs all opportunistic actions; always returns SUCCESS so the
-- seq continues. Each sub-action is best-effort (ignored on failure).
local function btExpansionPhase(ai)
	-- More mines
	if ai.mineCount < ai.diff.maxMines then
		if canAfford(ai.player, Config.MINE_COST, ai.diff.reserveResources) then
			local deposit = nearestFreeDeposit(ai.base)
			if deposit then
				local ok = buildingManager.placeForPlayer(ai.player, deposit, "Mine")
				if ok then ai.mineCount += 1 end
			end
		end
	end

	-- More barracks
	if #ai.barrackIds < ai.diff.maxBarracks then
		if canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then
			local rest: { Vector3 } = {}
			for i = 2, #BARRACKS_CANDIDATES do table.insert(rest, BARRACKS_CANDIDATES[i]) end
			local ok, id = tryPlace(ai.player, ai.base, "Barracks", rest)
			if ok and id then table.insert(ai.barrackIds, id) end
		end
	end

	-- Turrets
	if ai.turretCount < ai.diff.maxTurrets then
		if canAfford(ai.player, Config.TURRET_COST, ai.diff.reserveResources) then
			local ok = tryPlace(ai.player, ai.base, "Turret", TURRET_CANDIDATES)
			if ok then ai.turretCount += 1 end
		end
	end

	-- Workshop
	if not ai.workshopId and ai.diff.doResearch then
		if canAfford(ai.player, Config.WORKSHOP_COST, ai.diff.reserveResources) then
			local ok, id = tryPlace(ai.player, ai.base, "Workshop", WORKSHOP_CANDIDATES)
			if ok and id then ai.workshopId = id end
		end
	end

	-- Research (hard AI only): BetterMines → EliteUnits
	if ai.diff.doResearch and ai.workshopId and researchManager then
		local order = { "BetterMines", "EliteUnits" }
		for _, tech in order do
			if not researchManager.hasResearch(ai.player, tech) then
				researchManager.startForPlayer(ai.player, ai.workshopId, tech)
				break   -- only queue one at a time
			end
		end
	end

	-- Rebuild squads and update composition
	rebuildSquads(ai)
	updateComposition(ai)

	return SUCCESS
end

-- Reaction leaves (all three always run via direct calls)

local function btUpdateVision(ai)
	local detected = detectEnemiesInVision(ai)
	local priority, turrets, enemyUnits = scanThreats(ai)

	ai.enemyTurretCount = turrets
	ai.enemyUnitCount   = enemyUnits

	if detected then
		ai.lastKnownEnemyPos = detected
		ai.lastEnemySeenTick = tick()
	elseif ai.lastKnownEnemyPos then
		if tick() - ai.lastEnemySeenTick > ai.diff.enemyMemory then
			ai.lastKnownEnemyPos = nil
		end
	end

	ai.priorityTarget = priority or ai.lastKnownEnemyPos
	return SUCCESS
end

local function btTrainUnit(ai)
	if unitManager.getUnitCount(ai.player) >= ai.diff.maxUnits then return FAILURE end
	if #ai.barrackIds == 0 then return FAILURE end

	local unitType = pickWeighted(ai.currentWeights)
	local typeDef  = Config.UNIT_TYPES[unitType]
	local cost     = typeDef and typeDef.cost or 25
	if not canAfford(ai.player, cost, ai.diff.reserveResources) then return FAILURE end

	for _, barrackId in ai.barrackIds do
		if unitManager.trainFromBarracks(barrackId, unitType, ai.player) then
			return SUCCESS
		end
	end
	return FAILURE
end

local function btCommandArmy(ai)
	local armySize = unitManager.getUnitCount(ai.player)
	if armySize == 0 then return FAILURE end

	-- Main force: attack priority target or explore
	if #ai.mainForce > 0 then
		if ai.priorityTarget and armySize >= ai.diff.minUnitsToAttack then
			unitManager.sendUnitsTo(ai.player, ai.mainForce, ai.priorityTarget)
		else
			local target = ai.explorePoints[ai.exploreIdx]
			unitManager.sendUnitsTo(ai.player, ai.mainForce, target)
			ai.exploreTimer += ai.diff.reactionInterval
			if ai.exploreTimer >= 12 then
				ai.exploreTimer = 0
				ai.exploreIdx   = (ai.exploreIdx % #ai.explorePoints) + 1
			end
		end
	end

	-- Garrison: hold near base
	if #ai.garrison > 0 then
		local guardPos = snapGrid(ai.base + Vector3.new(0, 0, 18))
		unitManager.sendUnitsTo(ai.player, ai.garrison, guardPos)
	end

	-- Scouts: patrol a different waypoint for vision coverage
	if #ai.scouts > 0 then
		local scoutIdx = ((ai.exploreIdx + 4) % #ai.explorePoints) + 1
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.explorePoints[scoutIdx])
	end

	return SUCCESS
end

-- ── Behavior Trees ────────────────────────────────────────────────────────────

-- Strategy tree: build order + squad management.
-- seq means early phases block later ones until done.
-- Once CC/mine/barracks are built they always return SUCCESS, so btExpansionPhase
-- runs every strategy tick without delay.
local strategyTree = seq(
	act(btBuildCC),
	act(btBuildFirstMine),
	act(btBuildFirstBarracks),
	act(btExpansionPhase)
)

-- Reaction tree: always runs all three regardless of individual outcomes.
local function reactionTree(ai)
	btUpdateVision(ai)
	btTrainUnit(ai)
	btCommandArmy(ai)
end

-- ── AI state type ─────────────────────────────────────────────────────────────

type AIState = {
	player:      any,
	diff:        DifficultyProfile,
	base:        Vector3,

	-- Infrastructure
	hasCC:       boolean,
	mineCount:   number,
	barrackIds:  { string },
	turretCount: number,
	workshopId:  string?,

	-- Vision memory
	lastKnownEnemyPos: Vector3?,
	lastEnemySeenTick: number,
	priorityTarget:    Vector3?,

	-- Threat intel
	enemyTurretCount: number,
	enemyUnitCount:   number,

	-- Squads
	mainForce: { string },
	garrison:  { string },
	scouts:    { string },

	-- Adaptive composition
	currentWeights: { [string]: number },

	-- Exploration
	explorePoints: { Vector3 },
	exploreIdx:    number,
	exploreTimer:  number,

	-- Tick accumulators
	strategyTimer: number,
	reactionTimer: number,
}

-- ── Public API ────────────────────────────────────────────────────────────────

function AIManager.init(um, bm, rm)
	unitManager     = um
	buildingManager = bm
	resourceManager = rm
end

function AIManager.setResearchManager(rm: any)
	researchManager = rm
end

function AIManager.resetBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end
	ai.hasCC             = false
	ai.mineCount         = 0
	ai.barrackIds        = {}
	ai.turretCount       = 0
	ai.workshopId        = nil
	ai.lastKnownEnemyPos = nil
	ai.lastEnemySeenTick = 0
	ai.priorityTarget    = nil
	ai.enemyTurretCount  = 0
	ai.enemyUnitCount    = 0
	ai.mainForce         = {}
	ai.garrison          = {}
	ai.scouts            = {}
	ai.currentWeights    = {}
	for k, v in ai.diff.baseWeights do ai.currentWeights[k] = v end
	ai.exploreIdx        = 1
	ai.exploreTimer      = 0
	ai.strategyTimer     = ai.diff.strategyInterval   -- trigger strategy on next tick
	ai.reactionTimer     = ai.diff.reactionInterval
	resourceManager.add(ai.player, Config.STARTING_RESOURCES)
	print("[AIManager] Bot", userId, "eliminated — resetting to rebuild")
end

function AIManager.spawnAI(difficulty: string): boolean
	local diff = DIFFICULTY[difficulty]
	if not diff then
		warn("[AIManager] Unknown difficulty:", difficulty, "— use easy / medium / hard")
		return false
	end

	aiCounter += 1
	local idx = ((aiCounter - 1) % #AI_BASES) + 1

	local team          = Instance.new("Team")
	team.Name           = "AI [" .. difficulty .. "] " .. aiCounter
	team.TeamColor      = AI_COLORS[idx]
	team.AutoAssignable = false
	team.Parent         = Teams

	local aiPlayer = {
		UserId    = -aiCounter,
		TeamColor = AI_COLORS[idx],
		Team      = team,
		Name      = "AI_" .. aiCounter,
		Parent    = workspace,
	}

	resourceManager.add(aiPlayer, Config.STARTING_RESOURCES)

	local base = AI_BASES[idx]
	local initWeights = {}
	for k, v in diff.baseWeights do initWeights[k] = v end

	local ai: AIState = {
		player     = aiPlayer,
		diff       = diff,
		base       = base,

		hasCC       = false,
		mineCount   = 0,
		barrackIds  = {},
		turretCount = 0,
		workshopId  = nil,

		lastKnownEnemyPos = nil,
		lastEnemySeenTick = 0,
		priorityTarget    = nil,

		enemyTurretCount  = 0,
		enemyUnitCount    = 0,

		mainForce = {},
		garrison  = {},
		scouts    = {},

		currentWeights = initWeights,

		explorePoints = generateExplorePoints(base),
		exploreIdx    = 1,
		exploreTimer  = 0,

		-- Trigger both trees on the very first master tick
		strategyTimer = diff.strategyInterval,
		reactionTimer = diff.reactionInterval,
	}

	botByUserId[aiPlayer.UserId] = ai

	task.spawn(function()
		while true do
			local dt = task.wait(0.5)   -- master tick: 2 Hz
			ai.strategyTimer += dt
			ai.reactionTimer += dt

			if ai.strategyTimer >= ai.diff.strategyInterval then
				ai.strategyTimer = 0
				local ok, err = pcall(strategyTree, ai)
				if not ok then warn("[AIManager] strategy error:", err) end
			end

			if ai.reactionTimer >= ai.diff.reactionInterval then
				ai.reactionTimer = 0
				local ok, err = pcall(reactionTree, ai)
				if not ok then warn("[AIManager] reaction error:", err) end
			end
		end
	end)

	print(string.format("[AIManager] Spawned %s AI #%d at %s",
		difficulty, aiCounter, tostring(base)))
	return true
end

return AIManager
