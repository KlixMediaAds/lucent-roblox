--[[
	AIManager v2 — server-side AI bots

	Bots behave like real players:
	  • Follow the building requirement chain (Mine → Barracks → Turret)
	  • Train units through the barracks queue (same pipeline as human players)
	  • Fog-of-war vision: only "see" enemies within their unit/building sight
	    radius; remember the last spotted position for a limited time; explore
	    the map with scouts when no enemy is known

	Chat commands: /ai easy | /ai medium | /ai hard
--]]

local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local AIManager = {}

-- ── Difficulty profiles ───────────────────────────────────────────────────────

type DifficultyProfile = {
	thinkInterval:    number,   -- seconds between AI decisions
	maxUnits:         number,   -- army population cap
	maxMines:         number,   -- how many mines to build
	maxBarracks:      number,   -- how many barracks to build
	maxTurrets:       number,   -- how many turrets to build
	unitWeights:      { [string]: number },
	visionRadius:     number,   -- studs; own units/buildings reveal within this
	enemyMemory:      number,   -- seconds before forgetting a spotted position
	minUnitsToAttack: number,   -- army size required before pushing out
}

local DIFFICULTY: { [string]: DifficultyProfile } = {
	easy = {
		thinkInterval    = 8,
		maxUnits         = 6,
		maxMines         = 1,
		maxBarracks      = 1,
		maxTurrets       = 0,
		unitWeights      = { Soldier = 1 },
		visionRadius     = 45,
		enemyMemory      = 15,
		minUnitsToAttack = 3,
	},
	medium = {
		thinkInterval    = 4,
		maxUnits         = 16,
		maxMines         = 2,
		maxBarracks      = 1,
		maxTurrets       = 2,
		unitWeights      = { Soldier = 6, Tank = 4 },
		visionRadius     = 58,
		enemyMemory      = 45,
		minUnitsToAttack = 6,
	},
	hard = {
		thinkInterval    = 2,
		maxUnits         = 999,
		maxMines         = 3,
		maxBarracks      = 2,
		maxTurrets       = 4,
		unitWeights      = { Soldier = 2, Tank = 8 },
		visionRadius     = 65,
		enemyMemory      = 120,
		minUnitsToAttack = 8,
	},
}

-- ── Placement candidate offsets (relative to AI base) ────────────────────────

-- Multiple candidates so the AABB overlap check in BuildingManager can filter
-- bad slots and we still find a free one.
local BARRACKS_CANDIDATES: { Vector3 } = {
	Vector3.new( 20, 0,  0),
	Vector3.new(-20, 0,  0),
	Vector3.new(  0, 0, 20),
	Vector3.new(  0, 0,-20),
	Vector3.new( 20, 0, 20),
	Vector3.new(-20, 0,-20),
	Vector3.new( 20, 0,-20),
	Vector3.new(-20, 0, 20),
}

local TURRET_CANDIDATES: { Vector3 } = {
	Vector3.new(-25, 0,  0),
	Vector3.new( 25, 0,  0),
	Vector3.new(  0, 0,-25),
	Vector3.new(  0, 0, 25),
	Vector3.new(-25, 0,-25),
	Vector3.new( 25, 0, 25),
	Vector3.new(-25, 0, 25),
	Vector3.new( 25, 0,-25),
	Vector3.new(-30, 0,  0),
	Vector3.new(  0, 0,-30),
	Vector3.new( 30, 0,  0),
	Vector3.new(  0, 0, 30),
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

local botByUserId: { [number]: any } = {}

-- ── Utility helpers ───────────────────────────────────────────────────────────

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

local function pickWeighted(weights: { [string]: number }): string
	local total, cum = 0, 0
	for _, w in weights do total += w end
	local r = math.random() * total
	for name, w in weights do
		cum += w
		if r <= cum then return name end
	end
	for name in weights do return name end
	return "Soldier"
end

local function nearestFreeDeposit(fromPos: Vector3): Vector3?
	local folder = workspace:FindFirstChild("Deposits")
	if not folder then return nil end
	local best, bestDist = nil :: Vector3?, math.huge
	for _, part in folder:GetChildren() do
		local p2 = Vector3.new(part.Position.X, 0, part.Position.Z)
		local d  = (p2 - Vector3.new(fromPos.X, 0, fromPos.Z)).Magnitude
		if d < bestDist then bestDist = d; best = p2 end
	end
	return best
end

-- Try each candidate offset until one placement succeeds.
-- Returns (true, buildingId) or (false, nil).
local function tryPlace(player: any, base: Vector3, buildingType: string, candidates: { Vector3 }): (boolean, string?)
	for _, offset in candidates do
		local ok, id = buildingManager.placeForPlayer(player, snapGrid(base + offset), buildingType)
		if ok then return true, id end
	end
	return false, nil
end

-- ── Fog-of-war: detect enemies within AI vision radius ───────────────────────

-- Returns the world position of the closest enemy unit or building that falls
-- within any own unit's or building's vision radius. nil if nothing spotted.
local function detectEnemiesInVision(ai: any): Vector3?
	local myStr = tostring(ai.player.UserId)
	local r2    = ai.diff.visionRadius * ai.diff.visionRadius

	-- Gather all "eyes": own unit + building positions
	local eyes: { Vector3 } = {}

	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr and p:IsA("BasePart") then
				table.insert(eyes, (p :: BasePart).Position)
			end
		end
	end

	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr then
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then table.insert(eyes, base.Position) end
			end
		end
	end

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

	-- Check enemy units
	if unitsF then
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if p:IsA("BasePart") then check((p :: BasePart).Position) end
		end
	end

	-- Check enemy buildings
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

-- ── Exploration waypoints ─────────────────────────────────────────────────────

-- Generates a list of map positions for the AI to patrol when no enemy is
-- known. Points are ordered from home → mid-map → likely enemy territory.
local function generateExplorePoints(base: Vector3): { Vector3 }
	-- Direction signs pointing from this base toward map center
	local sx = -math.sign(base.X)   -- toward center in X
	local sz = -math.sign(base.Z)   -- toward center in Z

	return {
		snapGrid(Vector3.new(base.X + sx * 30, 0, base.Z)),         -- step toward center X
		snapGrid(Vector3.new(base.X,            0, base.Z + sz*30)), -- step toward center Z
		snapGrid(Vector3.new(sx * 70,  0, sz * 30)),                 -- mid-field
		snapGrid(Vector3.new(sx * 30,  0, sz * 70)),                 -- mid-field
		Vector3.new(0, 0, 0),                                        -- map centre
		snapGrid(Vector3.new(sx * 100, 0, 0)),                       -- enemy X axis
		snapGrid(Vector3.new(0,        0, sz * 100)),                 -- enemy Z axis
		snapGrid(Vector3.new(sx * 120, 0, sz * 40)),                 -- near enemy corner A
		snapGrid(Vector3.new(sx * 40,  0, sz * 120)),                -- near enemy corner B
		snapGrid(Vector3.new(sx * 120, 0, sz * 120)),                -- far enemy corner
	}
end

-- ── AI state type ─────────────────────────────────────────────────────────────

type AIState = {
	player:      any,
	diff:        DifficultyProfile,
	base:        Vector3,

	-- Infrastructure tracking
	hasCC:       boolean,
	mineCount:   number,
	barrackIds:  { string },
	turretCount: number,

	-- Fog-of-war memory
	lastKnownEnemyPos: Vector3?,
	lastEnemySeenTick: number,

	-- Exploration
	explorePoints: { Vector3 },
	exploreIdx:    number,
	exploreTimer:  number,
}

-- ── Per-bot think tick ────────────────────────────────────────────────────────

local function think(ai: AIState)
	local player = ai.player
	local diff   = ai.diff

	-- ── Phase 0: Place Command Center ──────────────────────────────────────
	if not ai.hasCC then
		local ok = buildingManager.placeForPlayer(player, ai.base, "CommandCenter")
		if ok then ai.hasCC = true end
		return   -- nothing else until CC is up
	end

	-- ── Phase 1: First Mine (unlocks Barracks) ─────────────────────────────
	if ai.mineCount < 1 then
		local deposit = nearestFreeDeposit(ai.base)
		if deposit then
			local ok = buildingManager.placeForPlayer(player, deposit, "Mine")
			if ok then ai.mineCount += 1 end
		end
		return   -- block here; Barracks placement will fail without a Mine
	end

	-- ── Phase 2: First Barracks (unlocks training + Turret) ───────────────
	if #ai.barrackIds < 1 then
		local ok, id = tryPlace(player, ai.base, "Barracks", BARRACKS_CANDIDATES)
		if ok and id then table.insert(ai.barrackIds, id) end
		return   -- block here until we can train
	end

	-- ── Phase 3 (parallel): Expand mines ──────────────────────────────────
	if ai.mineCount < diff.maxMines then
		local deposit = nearestFreeDeposit(ai.base)
		if deposit then
			local ok = buildingManager.placeForPlayer(player, deposit, "Mine")
			if ok then ai.mineCount += 1 end
		end
	end

	-- ── Phase 4 (parallel): Additional barracks ────────────────────────────
	if #ai.barrackIds < diff.maxBarracks then
		-- Skip the first candidate (already used); try the rest
		local rest: { Vector3 } = {}
		for i = 2, #BARRACKS_CANDIDATES do
			table.insert(rest, BARRACKS_CANDIDATES[i])
		end
		local ok, id = tryPlace(player, ai.base, "Barracks", rest)
		if ok and id then table.insert(ai.barrackIds, id) end
	end

	-- ── Phase 5 (parallel): Turrets ───────────────────────────────────────
	if ai.turretCount < diff.maxTurrets then
		local ok = tryPlace(player, ai.base, "Turret", TURRET_CANDIDATES)
		if ok then ai.turretCount += 1 end
	end

	-- ── Phase 6: Train units via barracks queue ────────────────────────────
	-- Identical pipeline to human players (respects build time, shows progress bar)
	if unitManager.getUnitCount(player) < diff.maxUnits then
		local unitType = pickWeighted(diff.unitWeights)
		for _, barrackId in ai.barrackIds do
			if unitManager.trainFromBarracks(barrackId, unitType, player) then
				break   -- queued in one barracks; don't queue in multiple per tick
			end
		end
	end

	-- ── Phase 7: Fog-of-war vision check ──────────────────────────────────
	local detected = detectEnemiesInVision(ai)
	if detected then
		ai.lastKnownEnemyPos = detected
		ai.lastEnemySeenTick = tick()
	elseif ai.lastKnownEnemyPos then
		-- Forget the last position after enemyMemory seconds
		if tick() - ai.lastEnemySeenTick > diff.enemyMemory then
			ai.lastKnownEnemyPos = nil
		end
	end

	-- ── Phase 8: Move army — attack or explore ────────────────────────────
	local armySize = unitManager.getUnitCount(player)
	if armySize == 0 then return end

	if ai.lastKnownEnemyPos and armySize >= diff.minUnitsToAttack then
		-- March on last known enemy position
		unitManager.sendAllUnitsTo(player, ai.lastKnownEnemyPos)
	else
		-- Explore the map to find the enemy
		local target = ai.explorePoints[ai.exploreIdx]
		unitManager.sendAllUnitsTo(player, target)

		ai.exploreTimer += diff.thinkInterval
		if ai.exploreTimer >= 12 then
			ai.exploreTimer = 0
			ai.exploreIdx   = (ai.exploreIdx % #ai.explorePoints) + 1
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function AIManager.init(um, bm, rm)
	unitManager     = um
	buildingManager = bm
	resourceManager = rm
end

function AIManager.resetBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end
	ai.hasCC             = false
	ai.mineCount         = 0
	ai.barrackIds        = {}
	ai.turretCount       = 0
	ai.lastKnownEnemyPos = nil
	ai.lastEnemySeenTick = 0
	ai.exploreIdx        = 1
	ai.exploreTimer      = 0
	resourceManager.add(ai.player, Config.STARTING_RESOURCES)
	print("[AIManager] Bot", userId, "was eliminated — resetting to rebuild")
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
	local ai: AIState = {
		player     = aiPlayer,
		diff       = diff,
		base       = base,

		hasCC      = false,
		mineCount  = 0,
		barrackIds = {},
		turretCount = 0,

		lastKnownEnemyPos = nil,
		lastEnemySeenTick = 0,

		explorePoints = generateExplorePoints(base),
		exploreIdx    = 1,
		exploreTimer  = 0,
	}

	botByUserId[aiPlayer.UserId] = ai

	task.spawn(function()
		while true do
			task.wait(diff.thinkInterval)
			local ok, err = pcall(think, ai)
			if not ok then
				warn("[AIManager] bot error:", err)
			end
		end
	end)

	print(string.format("[AIManager] Spawned %s AI #%d at %s",
		difficulty, aiCounter, tostring(base)))
	return true
end

return AIManager
