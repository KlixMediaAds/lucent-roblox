--[[
	AIManager v4 — Overhauled behavior-tree AI for server bots.

	Architecture:
	  • Strategy tick (5–10 s):  build order, research grants, squad rebuild,
	                              adaptive composition.
	  • Reaction tick (1–2 s):   vision scan, unit training, army commands.
	  • BT primitives: seq / act → SUCCESS / FAILURE / RUNNING.

	Build order per difficulty:
	  CC → Mine → Barracks → (more Mines → more Barracks → Turrets → Relays)
	  Hard AI also builds a Monument when flush with resources.

	Research grants:
	  AI bots can't trigger condition-based auto-unlocks (ResearchManager skips
	  negative UserIds). Instead, AIManager calls startForPlayer directly when
	  it meets internal thresholds.
	  - 2 Barracks built   → Relay research (lets AI expand build zone)
	  - 3 Barracks built   → MedicUnit
	  - 3 Turrets built    → TurretUpgrades + BetterMines
	  - 5 Soldiers trained → EliteUnits
	  - Hard AI only: ConcussionShells (early grant), RocketBarrage (after 3 tanks trained)

	Building lookup:
	  All building IDs are read live from workspace each tick (no stale-ID bugs).

	Threat scoring (reaction tick):
	  Monument(200) > CC(100) > Mine(60) > Barracks(50) > Turret(30)
	  Elite(35) > Tank(30) > Soldier(20) > CreepySoldier(15) > Medic(10)
	  Closer targets score higher. Garrison responds when base is under attack.

	Adaptive composition (strategy tick):
	  ≥ 2 enemy turrets  → lean Elite (outranges turrets at 30 studs)
	  ≥ 4 enemy units    → lean Tank  (splash + HP pool)
	  Medic added once MedicUnit research unlocked.
	  Elite zeroed until EliteUnits research unlocked.

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

local function act(fn)
	return function(ai) return fn(ai) end
end

-- ── Threat weights ────────────────────────────────────────────────────────────

local THREAT_BUILDING = {
	Monument      = 200,
	CommandCenter = 100,
	Mine          = 60,
	Barracks      = 50,
	Turret        = 30,
	Relay         = 15,
}

local THREAT_UNIT = {
	Elite         = 35,
	Tank          = 30,
	Soldier       = 20,
	CreepySoldier = 15,
	Medic         = 10,
}

-- ── Difficulty profiles ───────────────────────────────────────────────────────

type DifficultyProfile = {
	strategyInterval: number,
	reactionInterval: number,
	maxUnits:         number,
	maxMines:         number,
	maxBarracks:      number,
	maxTurrets:       number,
	maxRelays:        number,
	buildMonument:    boolean,
	baseWeights:      { [string]: number },
	visionRadius:     number,
	enemyMemory:      number,
	minUnitsToAttack: number,
	garrisonRatio:    number,
	scoutCount:       number,
	reserveResources: number,
}

-- Balanced AI — five distinct difficulty profiles (level 1 = weakest, 5 = brutal).
-- Territorial and Waves are placeholders that borrow the Balanced profile for now.
local BALANCED_PROFILES: { DifficultyProfile } = {
	-- Level 1
	{
		strategyInterval = 14,  reactionInterval = 2.5,
		maxUnits         = 6,
		maxMines         = 1,   maxBarracks      = 1,   maxTurrets = 1, maxRelays = 0,
		buildMonument    = false,
		baseWeights      = { Soldier = 1 },
		visionRadius     = 40,  enemyMemory      = 10,
		minUnitsToAttack = 4,   garrisonRatio    = 0.35,
		scoutCount       = 0,   reserveResources = 40,
	},
	-- Level 2
	{
		strategyInterval = 11,  reactionInterval = 2,
		maxUnits         = 10,
		maxMines         = 2,   maxBarracks      = 1,   maxTurrets = 2, maxRelays = 0,
		buildMonument    = false,
		baseWeights      = { Soldier = 3, Tank = 1 },
		visionRadius     = 50,  enemyMemory      = 25,
		minUnitsToAttack = 4,   garrisonRatio    = 0.30,
		scoutCount       = 0,   reserveResources = 60,
	},
	-- Level 3
	{
		strategyInterval = 8,   reactionInterval = 1.5,
		maxUnits         = 16,
		maxMines         = 2,   maxBarracks      = 2,   maxTurrets = 3, maxRelays = 1,
		buildMonument    = false,
		baseWeights      = { Soldier = 3, Tank = 3 },
		visionRadius     = 58,  enemyMemory      = 45,
		minUnitsToAttack = 5,   garrisonRatio    = 0.22,
		scoutCount       = 1,   reserveResources = 90,
	},
	-- Level 4
	{
		strategyInterval = 6,   reactionInterval = 1.2,
		maxUnits         = 28,
		maxMines         = 3,   maxBarracks      = 3,   maxTurrets = 4, maxRelays = 1,
		buildMonument    = false,
		baseWeights      = { Soldier = 2, Tank = 5, Elite = 0 },
		visionRadius     = 65,  enemyMemory      = 70,
		minUnitsToAttack = 5,   garrisonRatio    = 0.18,
		scoutCount       = 1,   reserveResources = 130,
	},
	-- Level 5 (brutal)
	{
		strategyInterval = 4.5, reactionInterval = 0.8,
		maxUnits         = 999,
		maxMines         = 4,   maxBarracks      = 4,   maxTurrets = 5, maxRelays = 2,
		buildMonument    = false,
		baseWeights      = { Soldier = 2, Tank = 6, Elite = 0 },
		visionRadius     = 72,  enemyMemory      = 90,
		minUnitsToAttack = 6,   garrisonRatio    = 0.15,
		scoutCount       = 1,   reserveResources = 150,
	},
}

local VALID_PERSONALITIES = { balanced = true, territorial = true, waves = true, nightmare = true, trainer = true }

-- ── Trainer profile ───────────────────────────────────────────────────────────
-- Stat caps are dynamically overridden each strategy tick based on the human
-- player's current state. These are startup defaults only.
local TRAINER_PROFILE: DifficultyProfile = {
	strategyInterval = 10,  reactionInterval = 2,
	maxUnits         = 8,   -- overridden by mirror logic every tick
	maxMines         = 1,   maxBarracks = 1, maxTurrets = 1, maxRelays = 0,
	buildMonument    = false,
	baseWeights      = { Soldier = 3, Tank = 1 },
	visionRadius     = 52,  enemyMemory = 30,
	minUnitsToAttack = 4,   garrisonRatio = 0.35,
	scoutCount       = 0,   reserveResources = 55,
}

-- ── Nightmare profile ─────────────────────────────────────────────────────────
-- Starting values only — strategyTree overwrites the mutable fields every tick
-- using exponential scaling based on elapsed time. The AI starts at roughly
-- level-3 strength and becomes unbound within minutes.
local NIGHTMARE_PROFILE: DifficultyProfile = {
	strategyInterval = 8,    reactionInterval = 1.5,
	maxUnits         = 999,
	maxMines         = 2,    maxBarracks      = 2,    maxTurrets = 2, maxRelays = 1,
	buildMonument    = true,
	baseWeights      = { Soldier = 2, Tank = 4, Elite = 3 },
	visionRadius     = 85,   enemyMemory      = 999,
	minUnitsToAttack = 4,    garrisonRatio    = 0.15,
	scoutCount       = 2,    reserveResources = 0,
}

local function buildProfile(personality: string, level: number): DifficultyProfile
	level = math.clamp(level, 1, 5)
	if personality == "nightmare" then
		local weights = {}
		for k, v in NIGHTMARE_PROFILE.baseWeights do weights[k] = v end
		return {
			strategyInterval = NIGHTMARE_PROFILE.strategyInterval,
			reactionInterval = NIGHTMARE_PROFILE.reactionInterval,
			maxUnits         = NIGHTMARE_PROFILE.maxUnits,
			maxMines         = NIGHTMARE_PROFILE.maxMines,
			maxBarracks      = NIGHTMARE_PROFILE.maxBarracks,
			maxTurrets       = NIGHTMARE_PROFILE.maxTurrets,
			maxRelays        = NIGHTMARE_PROFILE.maxRelays,
			buildMonument    = NIGHTMARE_PROFILE.buildMonument,
			baseWeights      = weights,
			visionRadius     = NIGHTMARE_PROFILE.visionRadius,
			enemyMemory      = NIGHTMARE_PROFILE.enemyMemory,
			minUnitsToAttack = NIGHTMARE_PROFILE.minUnitsToAttack,
			garrisonRatio    = NIGHTMARE_PROFILE.garrisonRatio,
			scoutCount       = NIGHTMARE_PROFILE.scoutCount,
			reserveResources = NIGHTMARE_PROFILE.reserveResources,
		}
	end
	-- Trainer: fixed moderate profile; level ignored (all logic is dynamic)
	if personality == "trainer" then
		local weights = {}
		for k, v in TRAINER_PROFILE.baseWeights do weights[k] = v end
		return {
			strategyInterval = TRAINER_PROFILE.strategyInterval,
			reactionInterval = TRAINER_PROFILE.reactionInterval,
			maxUnits         = TRAINER_PROFILE.maxUnits,
			maxMines         = TRAINER_PROFILE.maxMines,
			maxBarracks      = TRAINER_PROFILE.maxBarracks,
			maxTurrets       = TRAINER_PROFILE.maxTurrets,
			maxRelays        = TRAINER_PROFILE.maxRelays,
			buildMonument    = TRAINER_PROFILE.buildMonument,
			baseWeights      = weights,
			visionRadius     = TRAINER_PROFILE.visionRadius,
			enemyMemory      = TRAINER_PROFILE.enemyMemory,
			minUnitsToAttack = TRAINER_PROFILE.minUnitsToAttack,
			garrisonRatio    = TRAINER_PROFILE.garrisonRatio,
			scoutCount       = TRAINER_PROFILE.scoutCount,
			reserveResources = TRAINER_PROFILE.reserveResources,
		}
	end
	-- Placeholder personalities borrow balanced behavior (capped at lv 2 for now)
	if personality == "territorial" or personality == "waves" then
		level = math.min(level, 2)
	end
	local p = BALANCED_PROFILES[level]
	-- Deep-copy so individual AIs don't share the weights table
	local weights = {}
	for k, v in p.baseWeights do weights[k] = v end
	return {
		strategyInterval = p.strategyInterval, reactionInterval = p.reactionInterval,
		maxUnits         = p.maxUnits,
		maxMines         = p.maxMines,         maxBarracks      = p.maxBarracks,
		maxTurrets       = p.maxTurrets,       maxRelays        = p.maxRelays,
		buildMonument    = p.buildMonument,
		baseWeights      = weights,
		visionRadius     = p.visionRadius,     enemyMemory      = p.enemyMemory,
		minUnitsToAttack = p.minUnitsToAttack, garrisonRatio    = p.garrisonRatio,
		scoutCount       = p.scoutCount,       reserveResources = p.reserveResources,
	}
end


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

local botByUserId:  { [number]: any }     = {}
local takenBaseIdx: { [number]: boolean } = {}  -- AI_BASES index → claimed

-- Swarm gamemode: when on, every AI spawned builds only nests + creepy structures
-- and fields an army of Lampreys / Hagfish / Creepy Soldiers (no Barracks army).
local swarmMode = false

-- ── Utility helpers ───────────────────────────────────────────────────────────

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

-- Live lookup: scans the Buildings folder for a player's buildings of a given type.
-- Returns their model Names (= building IDs). Never returns stale IDs.
local function getOwnedBuildingIds(ownerStr: string, buildType: string): { string }
	local ids: { string } = {}
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return ids end
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		local tv = model:FindFirstChild("BuildingType")
		if ov and ov.Value == ownerStr and tv and tv.Value == buildType then
			table.insert(ids, model.Name)
		end
	end
	return ids
end

-- Count how many of a given building type a player currently owns (live).
local function countOwnedBuildings(ownerStr: string, buildType: string): number
	return #getOwnedBuildingIds(ownerStr, buildType)
end

local function countAllOwnedBuildings(ownerStr: string): number
	local n = 0
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return n end
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		if ov and ov.Value == ownerStr then n += 1 end
	end
	return n
end

local function nearestFreeDeposit(fromPos: Vector3): Vector3?
	local folder = workspace:FindFirstChild("Deposits")
	if not folder then return nil end

	-- Build a set of deposit positions already targeted by a live harvester (any owner)
	-- so the AI doesn't pile multiple harvesters onto one field.
	local minedKeys: { [string]: true } = {}
	if unitManager then
		for _, hp in unitManager.getActiveHarvestPoints() do
			minedKeys[math.round(hp.X) .. "," .. math.round(hp.Z)] = true
		end
	end

	local baseXZ   = Vector3.new(fromPos.X, 0, fromPos.Z)
	local best: Vector3?, bestDist = nil :: Vector3?, math.huge
	for _, obj in folder:GetChildren() do
		local wpos = obj:GetPivot().Position
		local p2   = Vector3.new(wpos.X, 0, wpos.Z)
		local key  = math.round(p2.X) .. "," .. math.round(p2.Z)
		if minedKeys[key] then continue end  -- already has a mine
		local d = (p2 - baseXZ).Magnitude
		if d < bestDist then bestDist = d; best = p2 end
	end
	return best
end

-- ── Placement helpers ─────────────────────────────────────────────────────────

-- Try up to 20 random positions around an anchor at a random distance in [minR, maxR].
-- Fully random each call — no two AI games will build identically.
local function tryPlaceRandom(player: any, anchor: Vector3, buildType: string, minR: number, maxR: number): boolean
	for _ = 1, 20 do
		local angle = math.random() * math.pi * 2
		local r     = minR + math.random() * (maxR - minR)
		local pos   = snapGrid(anchor + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		if buildingManager.placeForPlayer(player, pos, buildType) then return true end
	end
	return false
end

-- Collect positions of all owned Relays so buildings can be anchored to them.
local function getRelayAnchors(ownerStr: string): { Vector3 }
	local anchors: { Vector3 } = {}
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return anchors end
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		local tv = model:FindFirstChild("BuildingType")
		if ov and ov.Value == ownerStr and tv and tv.Value == "Relay" then
			local base = model:FindFirstChild("Base") :: BasePart?
			if base then table.insert(anchors, Vector3.new(base.Position.X, 0, base.Position.Z)) end
		end
	end
	return anchors
end

-- Try placing around the AI's CC base, then around any owned Relays.
-- This is what lets Relays actually extend the build zone for the AI.
local function tryPlaceAnywhere(player: any, ownerStr: string, base: Vector3, buildType: string, minR: number, maxR: number): boolean
	if tryPlaceRandom(player, base, buildType, minR, maxR) then return true end
	for _, anchor in getRelayAnchors(ownerStr) do
		if tryPlaceRandom(player, anchor, buildType, 5, maxR) then return true end
	end
	return false
end

-- ── Trainer helpers ───────────────────────────────────────────────────────────

-- Count buildings owned by real (human) players — UserId > 0.
-- Pass "any" for buildType to count all structures.
local function countHumanBuildings(btype: string): number
	local n = 0
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return n end
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		if not ov then continue end
		local uid = tonumber(ov.Value) or 0
		if uid <= 0 then continue end
		if btype == "any" then
			n += 1
		else
			local tv = model:FindFirstChild("BuildingType")
			if tv and tv.Value == btype then n += 1 end
		end
	end
	return n
end

-- Count all units currently owned by real players.
local function countHumanArmy(): number
	local n = 0
	local folder = workspace:FindFirstChild("Units")
	if not folder then return n end
	for _, p in folder:GetChildren() do
		if not p:IsA("BasePart") then continue end
		local ov = p:FindFirstChild("OwnerId")
		if not ov then continue end
		local uid = tonumber(ov.Value) or 0
		if uid > 0 then n += 1 end
	end
	return n
end

-- ── Research grants ───────────────────────────────────────────────────────────

-- Grant a tech directly (AI shortcut — ResearchManager.startForPlayer bypasses conditions).
-- Silently skips if already done or tech doesn't exist.
local function grantTech(player: any, techName: string)
	if not researchManager then return end
	researchManager.startForPlayer(player, "", techName)
end

-- Called each strategy tick. Grants techs the AI has earned based on internal
-- tracking. For kill-based techs, we grant them by time / kill milestone instead.
local function checkAndGrantResearch(ai: any)
	if not researchManager then return end

	local lv        = ai.level
	if lv < 2 then return end  -- level 1 gets no research

	local bBarracks = ai.builtBarracks
	local bTurrets  = ai.builtTurrets
	local bMines    = ai.builtMines
	local tSoldiers = ai.trainedSoldiers
	local tTanks    = ai.trainedTanks

	-- Level 2+: basic economy and elite unlock
	if bTurrets >= 2 then grantTech(ai.player, "BetterMines") end
	if tSoldiers >= 5 then grantTech(ai.player, "EliteUnits") end

	-- Level 3+: build-zone expansion, medics, turret upgrades
	if lv >= 3 then
		if bBarracks >= 2 then grantTech(ai.player, "Relay") end
		if bBarracks >= 3 then grantTech(ai.player, "MedicUnit") end
		if bTurrets  >= 3 then grantTech(ai.player, "TurretUpgrades") end
	end

	-- Level 4+: mobile CC
	if lv >= 4 then
		if bMines >= 2  then grantTech(ai.player, "MobileCC") end
	end

	-- Level 5: combat techs (monument-building AI)
	if lv >= 5 then
		grantTech(ai.player, "ConcussionShells")
		if tTanks >= 3 then grantTech(ai.player, "RocketBarrage") end
	end
end

-- ── Fog-of-war vision ─────────────────────────────────────────────────────────

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

-- ── Threat scanning ───────────────────────────────────────────────────────────

type ThreatResult = {
	priorityTarget:  Vector3?,
	enemyTurretCount: number,
	enemyUnitCount:  number,
	baseUnderAttack: boolean,  -- enemy units within 55 studs of AI base
}

local function scanThreats(ai: any): ThreatResult
	local myStr   = ai.ownerStr
	local r2      = ai.diff.visionRadius * ai.diff.visionRadius
	local vR      = ai.diff.visionRadius
	local eyes    = gatherEyes(myStr)

	local result: ThreatResult = {
		priorityTarget   = nil,
		enemyTurretCount = 0,
		enemyUnitCount   = 0,
		baseUnderAttack  = false,
	}

	if #eyes == 0 then return result end

	local function minDistToEyes(epos: Vector3): number
		local minD2 = math.huge
		for _, eye in eyes do
			local dx = epos.X - eye.X
			local dz = epos.Z - eye.Z
			local d2 = dx * dx + dz * dz
			if d2 < minD2 then minD2 = d2 end
		end
		return math.sqrt(minD2)
	end

	local bestScore = -math.huge

	local buildingsF = workspace:FindFirstChild("Buildings")
	local unitsF     = workspace:FindFirstChild("Units")

	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base") :: BasePart?
			if not base then continue end

			local dist = minDistToEyes(base.Position)
			if dist > vR then continue end

			local tv    = model:FindFirstChild("BuildingType")
			local btype = tv and tv.Value or "Barracks"
			if btype == "Turret" then result.enemyTurretCount += 1 end

			local baseScore  = THREAT_BUILDING[btype] or 25
			local distFactor = 1 - math.clamp(dist / vR, 0, 0.8)
			local score      = baseScore * (1 + distFactor)
			if score > bestScore then
				bestScore = score
				result.priorityTarget = Vector3.new(base.Position.X, 0, base.Position.Z)
			end
		end
	end

	if unitsF then
		local baseXZ = Vector3.new(ai.base.X, 0, ai.base.Z)
		for _, p in unitsF:GetChildren() do
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if not p:IsA("BasePart") then continue end
			local epos = (p :: BasePart).Position

			local dist = minDistToEyes(epos)
			if dist > vR then continue end
			result.enemyUnitCount += 1

			-- Check if enemy is near our base
			local distToBase = (Vector3.new(epos.X, 0, epos.Z) - baseXZ).Magnitude
			if distToBase < 55 then result.baseUnderAttack = true end

			local ut = p:FindFirstChild("UnitType")
			local utype = ut and ut.Value or "Soldier"
			local baseScore  = (THREAT_UNIT :: any)[utype] or 20
			local distFactor = 1 - math.clamp(dist / vR, 0, 0.8)
			local score      = baseScore * (1 + distFactor)
			if score > bestScore then
				bestScore = score
				result.priorityTarget = Vector3.new(epos.X, 0, epos.Z)
			end
		end
	end

	return result
end

-- ── Exploration waypoints ─────────────────────────────────────────────────────
-- 36 points in 5 concentric layers from own base outward to enemy base.
-- Random jitter per point so no two AI games patrol identically.

local function generateExplorePoints(base: Vector3): { Vector3 }
	local pts: { Vector3 } = {}
	local B = 380  -- safe bound (map is ±432)

	local function ringPt(cx: number, cz: number, r: number, i: number, n: number): Vector3
		local a = (i / n) * math.pi * 2 + (math.random() - 0.5) * (math.pi * 2 / n) * 0.6
		return snapGrid(Vector3.new(
			math.clamp(cx + math.cos(a) * r, -B, B), 0,
			math.clamp(cz + math.sin(a) * r, -B, B)
		))
	end

	-- Layer 1: own perimeter (8 pts, ~45 studs from base)
	for i = 0, 7 do
		table.insert(pts, ringPt(base.X, base.Z, 45 + math.random(-8, 8), i, 8))
	end
	-- Layer 2: mid own territory (8 pts)
	local m1x, m1z = base.X * 0.55, base.Z * 0.55
	for i = 0, 7 do
		table.insert(pts, ringPt(m1x, m1z, 70 + math.random(-12, 12), i, 8))
	end
	-- Layer 3: map centre zone (8 pts)
	for i = 0, 7 do
		table.insert(pts, ringPt(0, 0, 75 + math.random(-15, 15), i, 8))
	end
	-- Layer 4: enemy territory (8 pts)
	local m2x, m2z = -base.X * 0.55, -base.Z * 0.55
	for i = 0, 7 do
		table.insert(pts, ringPt(m2x, m2z, 65 + math.random(-12, 12), i, 8))
	end
	-- Layer 5: near enemy base (4 pts)
	for i = 0, 3 do
		table.insert(pts, ringPt(-base.X, -base.Z, 45 + math.random(-8, 8), i, 4))
	end

	return pts  -- 36 total
end

-- ── Squad partitioning ────────────────────────────────────────────────────────

local function rebuildSquads(ai: any)
	local allUnits = unitManager.getPlayerUnitData(ai.player)
	local total    = #allUnits
	if total == 0 then
		ai.mainForce = {}; ai.garrison = {}; ai.scouts = {}
		return
	end

	local scoutN    = math.min(ai.diff.scoutCount, math.max(0, total - 2))
	local remaining = total - scoutN
	local garrisonN = math.max(1, math.floor(remaining * ai.diff.garrisonRatio))
	local mainN     = remaining - garrisonN

	ai.scouts    = {}
	ai.garrison  = {}
	ai.mainForce = {}

	for i, ud in allUnits do
		if i <= scoutN then
			table.insert(ai.scouts, ud.id)
		elseif i <= scoutN + mainN then
			table.insert(ai.mainForce, ud.id)
		else
			table.insert(ai.garrison, ud.id)
		end
	end
end

-- ── Adaptive composition ──────────────────────────────────────────────────────

local function updateComposition(ai: any)
	-- Nightmare: fully randomize composition each tick for unpredictability
	if ai.isNightmare then
		local hasElite = researchManager and researchManager.hasResearch(ai.player, "EliteUnits")
		local hasMedic = researchManager and researchManager.hasResearch(ai.player, "MedicUnit")
		ai.currentWeights = {
			Soldier = math.random(1, 5),
			Tank    = math.random(1, 6),
			Elite   = hasElite and math.random(0, 5) or 0,
			Medic   = hasMedic and math.random(0, 3) or 0,
		}
		return
	end

	local w: { [string]: number } = {}
	for k, v in ai.diff.baseWeights do w[k] = v end

	-- Lots of enemy turrets → lean Elite (30-stud range outpaces turrets)
	if ai.enemyTurretCount >= 2 then
		w["Elite"]   = (w["Elite"]   or 0) + ai.enemyTurretCount * 3
		w["Soldier"] = math.max(1, (w["Soldier"] or 1) - 1)
	end

	-- Lots of enemy units → lean Tank (splash clears blobs, high HP)
	if ai.enemyUnitCount >= 4 then
		w["Tank"] = (w["Tank"] or 0) + math.floor(ai.enemyUnitCount / 2)
	end

	-- Gate Elite on research
	if (w["Elite"] or 0) > 0 then
		if not (researchManager and researchManager.hasResearch(ai.player, "EliteUnits")) then
			w["Elite"] = 0
		end
	end

	-- Add Medic slot once unlocked and army is large enough
	if researchManager and researchManager.hasResearch(ai.player, "MedicUnit") then
		local totalArmy = unitManager.getUnitCount(ai.player)
		if totalArmy >= 6 then
			w["Medic"] = math.max(w["Medic"] or 0, 1)
		end
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
	if ai.builtMines >= 1 then return SUCCESS end
	local deposit = nearestFreeDeposit(ai.base)
	if not deposit then return FAILURE end
	if not canAfford(ai.player, Config.MINE_COST, 0) then return RUNNING end
	local ok = buildingManager.placeForPlayer(ai.player, deposit, "Mine")
	if ok then ai.builtMines += 1; return SUCCESS end
	return RUNNING
end

local function btBuildFirstBarracks(ai)
	local live = countOwnedBuildings(ai.ownerStr, "Barracks")
	if live >= 1 then
		if ai.builtBarracks < 1 then ai.builtBarracks = 1 end
		return SUCCESS
	end
	if not canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then return RUNNING end
	if tryPlaceRandom(ai.player, ai.base, "Barracks", 15, 35) then
		ai.builtBarracks += 1; return SUCCESS
	end
	return RUNNING
end

local function btExpansionPhase(ai)
	-- Sync live counts (buildings can be destroyed)
	local liveMines    = unitManager.getActiveHarvesterCount(ai.player)
	local liveBarracks = countOwnedBuildings(ai.ownerStr, "Barracks")
	local liveTurrets  = countOwnedBuildings(ai.ownerStr, "Turret")
	local liveRelays   = countOwnedBuildings(ai.ownerStr, "Relay")

	-- Priority 1: Replace lost barracks first (army production)
	if liveBarracks < math.min(ai.diff.maxBarracks, ai.builtBarracks) then
		if canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Barracks", 15, 35) then
				ai.builtBarracks += 1
			end
		end
	end

	-- Priority 2: More mines (economy)
	if liveMines < ai.diff.maxMines then
		if canAfford(ai.player, Config.MINE_COST, ai.diff.reserveResources) then
			local deposit = nearestFreeDeposit(ai.base)
			if deposit then
				if buildingManager.placeForPlayer(ai.player, deposit, "Mine") then
					ai.builtMines += 1
				end
			end
		end
	end

	-- Priority 3: Expand barracks (up to cap)
	if liveBarracks < ai.diff.maxBarracks then
		if canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Barracks", 15, 35) then
				ai.builtBarracks = math.max(ai.builtBarracks, liveBarracks + 1)
			end
		end
	end

	-- Priority 4: Relays (push the build zone outward before placing more buildings)
	if liveRelays < ai.diff.maxRelays then
		if researchManager and researchManager.hasResearch(ai.player, "Relay") then
			if canAfford(ai.player, Config.RELAY_COST, ai.diff.reserveResources) then
				if tryPlaceRandom(ai.player, ai.base, "Relay", 45, 75) then
					ai.builtRelays += 1
				end
			end
		end
	end

	-- Priority 5: Turrets (defense) — anchor to base or any relay for spread coverage
	if liveTurrets < ai.diff.maxTurrets then
		if canAfford(ai.player, Config.TURRET_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Turret", 20, 45) then
				ai.builtTurrets = math.max(ai.builtTurrets, liveTurrets + 1)
			end
		end
	end

	-- Grant research based on current progress
	checkAndGrantResearch(ai)

	-- Only reshuffle squads when army size changes to avoid constant direction reversals
	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai)
		ai.lastSquadCount = currentCount
	end
	updateComposition(ai)

	return SUCCESS
end

-- ── Reaction leaves ───────────────────────────────────────────────────────────

local function btUpdateVision(ai)
	local threats = scanThreats(ai)

	ai.enemyTurretCount = threats.enemyTurretCount
	ai.enemyUnitCount   = threats.enemyUnitCount
	ai.baseUnderAttack  = threats.baseUnderAttack

	if threats.priorityTarget then
		ai.lastKnownEnemyPos = threats.priorityTarget
		ai.lastEnemySeenTick = tick()
	elseif ai.lastKnownEnemyPos then
		if tick() - ai.lastEnemySeenTick > ai.diff.enemyMemory then
			ai.lastKnownEnemyPos = nil
		end
	end

	-- Priority target: fresh scan > memory
	ai.priorityTarget = threats.priorityTarget or ai.lastKnownEnemyPos
	return SUCCESS
end

local function btTrainUnit(ai)
	if unitManager.getUnitCount(ai.player) >= ai.diff.maxUnits then return FAILURE end

	local barrackIds = getOwnedBuildingIds(ai.ownerStr, "Barracks")
	if #barrackIds == 0 then return FAILURE end

	local unitType = pickWeighted(ai.currentWeights)
	local typeDef  = Config.UNIT_TYPES[unitType]
	local cost     = typeDef and typeDef.cost or 25
	if not canAfford(ai.player, cost, ai.diff.reserveResources) then return FAILURE end

	-- Check research gate (Elite / Medic)
	if typeDef and typeDef.researchReq then
		if not (researchManager and researchManager.hasResearch(ai.player, typeDef.researchReq)) then
			-- Fallback to Soldier
			unitType = "Soldier"
			local sd = Config.UNIT_TYPES["Soldier"]
			cost     = sd and sd.cost or 25
			if not canAfford(ai.player, cost, ai.diff.reserveResources) then return FAILURE end
		end
	end

	for _, barrackId in barrackIds do
		if unitManager.trainFromBarracks(barrackId, unitType, ai.player) then
			-- Track training counts for research grants
			if unitType == "Soldier" then
				ai.trainedSoldiers += 1
			elseif unitType == "Tank" then
				ai.trainedTanks += 1
			end
			return SUCCESS
		end
	end
	return FAILURE
end

-- Send units in small groups with a random spread so they don't all stack on one tile.
local function sendSpread(player, units, target)
	local SPREAD = 10
	for i = 1, #units, 3 do
		local chunk = {}
		for j = i, math.min(i + 2, #units) do table.insert(chunk, units[j]) end
		local angle = math.random() * math.pi * 2
		local r     = math.random(0, SPREAD)
		local dest  = snapGrid(target + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		unitManager.sendUnitsTo(player, chunk, dest)
	end
end

-- Fan a unit list across multiple waypoints: each group of GROUP_SIZE gets a
-- different point from the explore list, spaced evenly apart so the army
-- covers different sectors of the map simultaneously.
local function fanAcrossMap(ai, units, pts, groupSize)
	local n         = #units
	if n == 0 then return end
	local numGroups = math.ceil(n / groupSize)
	local ptSpread  = math.max(1, math.floor(#pts / numGroups))
	for g = 0, numGroups - 1 do
		local chunk = {}
		for j = g * groupSize + 1, math.min((g + 1) * groupSize, n) do
			table.insert(chunk, units[j])
		end
		local ptIdx = ((ai.exploreIdx - 1 + g * ptSpread) % #pts) + 1
		sendSpread(ai.player, chunk, pts[ptIdx])
	end
end

-- ── Combat helpers ───────────────────────────────────────────────────────────

-- Return a random position among enemy buildings of [btype], or nil.
local function findEnemyBuilding(ownerStr: string, btype: string): Vector3?
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return nil end
	local found: { Vector3 } = {}
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		local tv = model:FindFirstChild("BuildingType")
		if ov and ov.Value ~= ownerStr and tv and tv.Value == btype then
			local base = model:FindFirstChild("Base") :: BasePart?
			if base then
				table.insert(found, Vector3.new(base.Position.X, 0, base.Position.Z))
			end
		end
	end
	if #found == 0 then return nil end
	return found[math.random(1, #found)]
end

-- Weighted target pick: visible target (45%) > Mine (20%) > Barracks (17%) > CC (18%).
local function pickAttackTarget(ai): Vector3?
	local own = ai.ownerStr
	if ai.priorityTarget and math.random() < 0.45 then
		return ai.priorityTarget
	end
	local r = math.random()
	local t: Vector3?
	if r < 0.36 then
		t = findEnemyBuilding(own, "Mine")
	elseif r < 0.67 then
		t = findEnemyBuilding(own, "Barracks")
	else
		t = findEnemyBuilding(own, "CommandCenter")
	end
	return t or ai.priorityTarget or findEnemyBuilding(own, "CommandCenter")
end

-- Point at [dist] studs from [target] at [angle] radians, clamped to map bounds.
local function approachPoint(target: Vector3, angle: number, dist: number): Vector3
	local B = 380
	return snapGrid(Vector3.new(
		math.clamp(target.X + math.cos(angle) * dist, -B, B), 0,
		math.clamp(target.Z + math.sin(angle) * dist, -B, B)
	))
end

-- ── Army command: 4-phase combat state machine ───────────────────────────────
--  gather  → spread army across map until enemy found + enough force assembled
--  staging → hold at rally point for a random delay (masks intent)
--  attack  → commit; optional 65/35 flanking split; retreat on losses/timeout
--  retreat → pull back to base for cooldown, then re-enter gather
local function btCommandArmy(ai)
	local armySize = unitManager.getUnitCount(ai.player)
	if armySize == 0 then return FAILURE end

	local pts            = ai.explorePoints
	local garrisonTarget = ai.baseUnderAttack and ai.base
		or snapGrid(ai.base + Vector3.new(0, 0, 18))

	-- Scouts probe enemy territory independently every 10 s
	local function updateScouts()
		if #ai.scouts == 0 then return end
		ai.scoutTimer += ai.diff.reactionInterval
		if ai.scoutTimer >= 10 then
			ai.scoutTimer = 0
			local farStart = math.floor(#pts * 0.6)
			ai.scoutIdx    = math.random(farStart, #pts)
		end
		unitManager.sendUnitsTo(ai.player, ai.scouts, pts[ai.scoutIdx])
	end

	-- Garrison always holds / defends
	if #ai.garrison > 0 then
		unitManager.sendUnitsTo(ai.player, ai.garrison, garrisonTarget)
	end
	updateScouts()

	-- Snap to retreat when base is suddenly under attack
	if ai.baseUnderAttack and ai.combatPhase ~= "retreat" then
		if #ai.mainForce > 0 then
			sendSpread(ai.player, ai.mainForce, ai.base)
		end
		ai.combatPhase     = "retreat"
		ai.phaseTimer      = 0
		ai.attackTarget    = nil
		ai.feintTarget     = nil
		ai.retreatDuration = math.random(8, 18)
		return SUCCESS
	end

	-- ── Nightmare: no phases, immediate attack + random flanking ──────────────
	if ai.isNightmare then
		local target = pickAttackTarget(ai)
		if target then
			local n = #ai.mainForce
			if n >= 4 and math.random() < 0.4 then
				local mainCount = math.floor(n * 0.6)
				local mainChunk, flankChunk = {}, {}
				for i, id in ai.mainForce do
					if i <= mainCount then table.insert(mainChunk, id)
					else               table.insert(flankChunk, id) end
				end
				local fa = math.random() * math.pi * 2
				local ft = approachPoint(target, fa, 35 + math.random(0, 30))
				sendSpread(ai.player, mainChunk,  target)
				sendSpread(ai.player, flankChunk, ft)
			else
				sendSpread(ai.player, ai.mainForce, target)
			end
		else
			local n         = #ai.mainForce
			local numGroups = math.ceil(n / 2)
			local ptSpread  = math.max(1, math.floor(#pts / math.max(numGroups, 1)))
			for g = 0, numGroups - 1 do
				local chunk = {}
				for j = g * 2 + 1, math.min((g + 1) * 2, n) do
					table.insert(chunk, ai.mainForce[j])
				end
				local ptIdx = math.random() < 0.25
					and math.random(1, #pts)
					or  ((ai.exploreIdx - 1 + g * ptSpread) % #pts) + 1
				sendSpread(ai.player, chunk, pts[ptIdx])
			end
			ai.exploreTimer += ai.diff.reactionInterval
			if ai.exploreTimer >= 6 then
				ai.exploreTimer = 0
				ai.exploreIdx   = (ai.exploreIdx % #pts) + 1
			end
		end
		return SUCCESS
	end

	-- ── Standard AI: phase state machine ──────────────────────────────────────
	ai.phaseTimer += ai.diff.reactionInterval

	-- GATHER: fan force across map until target found and army is ready
	if ai.combatPhase == "gather" then
		if #ai.mainForce > 0 then
			fanAcrossMap(ai, ai.mainForce, pts, 2)
			ai.exploreTimer += ai.diff.reactionInterval
			if ai.exploreTimer >= 8 then
				ai.exploreTimer = 0
				ai.exploreIdx   = (ai.exploreIdx % #pts) + 1
			end
		end

		if ai.priorityTarget and armySize >= ai.diff.minUnitsToAttack then
			local target = pickAttackTarget(ai)
			if target then
				local approachAngle  = math.random() * math.pi * 2
				ai.combatPhase       = "staging"
				ai.phaseTimer        = 0
				ai.attackTarget      = target
				ai.flankAngle        = approachAngle + math.pi + (math.random() - 0.5) * 1.2
				ai.stageDuration     = math.random(7, 18)
				ai.rallyPoint        = approachPoint(target, approachAngle, 50 + math.random(0, 25))
				ai.retreatThreshold  = 0.30 + math.random() * 0.25
				ai.attackDuration    = math.random(18, 40)
				ai.retreatDuration   = math.random(10, 25)
				ai.lastArmySize      = armySize
			end
		end

	-- STAGING: hold at rally point for stageDuration before committing
	elseif ai.combatPhase == "staging" then
		if #ai.mainForce > 0 and ai.rallyPoint then
			sendSpread(ai.player, ai.mainForce, ai.rallyPoint)
		end

		if not ai.priorityTarget and not ai.attackTarget then
			ai.combatPhase = "gather"
			ai.phaseTimer  = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			local doFlank = ai.level >= 3 and math.random() < 0.30 and #ai.mainForce >= 5
			ai.isFlankingAttack = doFlank
			if doFlank then
				local btypes    = { "Mine", "Barracks", "Turret" }
				local candidate = findEnemyBuilding(ai.ownerStr, btypes[math.random(1, 3)])
				ai.feintTarget  = (candidate ~= ai.attackTarget) and candidate or nil
				if not ai.feintTarget then ai.isFlankingAttack = false end
			end
			ai.combatPhase = "attack"
			ai.phaseTimer  = 0
			ai.wavesSent  += 1
		end

	-- ATTACK: strike target; optional 65/35 flank; retreat on losses or timeout
	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then
			ai.combatPhase = "gather"
			ai.phaseTimer  = 0
			return SUCCESS
		end

		local n = #ai.mainForce
		if ai.isFlankingAttack and ai.feintTarget and n >= 5 then
			local mainCount = math.floor(n * 0.65)
			local mainChunk, flankChunk = {}, {}
			for i, id in ai.mainForce do
				if i <= mainCount then table.insert(mainChunk, id)
				else               table.insert(flankChunk, id) end
			end
			sendSpread(ai.player, mainChunk,  target)
			sendSpread(ai.player, flankChunk, ai.feintTarget)
		else
			sendSpread(ai.player, ai.mainForce, target)
		end

		local lossRatio = ai.lastArmySize > 0
			and (ai.lastArmySize - armySize) / ai.lastArmySize
			or 0
		if lossRatio >= ai.retreatThreshold or ai.phaseTimer >= ai.attackDuration then
			ai.combatPhase      = "retreat"
			ai.phaseTimer       = 0
			ai.feintTarget      = nil
			ai.isFlankingAttack = false
		end

	-- RETREAT: pull back to base; then re-enter gather for next wave
	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then
			sendSpread(ai.player, ai.mainForce, ai.base)
		end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase  = "gather"
			ai.phaseTimer   = 0
			ai.attackTarget = nil
			ai.rallyPoint   = nil
			ai.feintTarget  = nil
			ai.lastArmySize = 0
		end
	end

	return SUCCESS
end

-- ── Trainer personality ────────────────────────────────────────────────────────
--[[
	The Trainer is a teaching opponent. It:
	  • Mirrors the human player's economy and army size (with a lag)
	  • Sends probing waves every 60-110 seconds — never all-in
	  • Commits only 50-60 % of its main force per wave; rest holds at rally
	  • Retreats quickly (20-40 s) then gives a long breathing gap (40-70 s)
	  • Backs off further when the player is actively building
	  • Never builds a Monument (cannot win by design)
	  • Enters Concede after the player kills ≥ 8 trainer units across waves
	    OR destroys ≥ 2 trainer buildings — after that it stops training and
	    stops attacking so the player can clean it up.
	  • Hard time-cap: also concedes after 7 minutes regardless.
--]]

-- Trainer strategy: mirror player builds, manage building caps, check concede.
local function trainerStrategyTree(ai: any)

	-- ── Mirror player economy / army ──────────────────────────────────────────
	local playerMines    = unitManager.getHumanHarvesterCount()
	local playerBarracks = countHumanBuildings("Barracks")
	local playerAllBld   = countHumanBuildings("any")
	local playerArmy     = countHumanArmy()

	-- Cap mirrors: stay slightly behind the player, never too strong
	ai.diff.maxMines    = math.clamp(playerMines,    1, 2)
	ai.diff.maxBarracks = math.clamp(playerBarracks, 1, 2)
	ai.diff.maxTurrets  = 1     -- one turret for light base defence only
	ai.diff.maxRelays   = 0
	-- Army cap: player count + 1-2 unit buffer, hard-capped at 14
	ai.diff.maxUnits    = math.clamp(playerArmy + math.random(1, 2), 4, 14)

	-- ── Detect building activity (player is expanding → give breathing room) ──
	local playerBldGrew = playerAllBld > (ai.trainerLastBldCount or 0)
	ai.trainerLastBldCount = playerAllBld
	if playerBldGrew then
		-- Push the next wave interval out if player is clearly expanding
		ai.trainerWaveInterval = math.max(ai.trainerWaveInterval, 70)
	end

	-- ── Track own building losses ──────────────────────────────────────────────
	local ownBldNow = countAllOwnedBuildings(ai.ownerStr)
	if ownBldNow < (ai.trainerLastOwnBldCount or 0) then
		ai.trainerBldLost += (ai.trainerLastOwnBldCount - ownBldNow)
	end
	ai.trainerLastOwnBldCount = ownBldNow

	-- ── Concede check ──────────────────────────────────────────────────────────
	if not ai.trainerConceded then
		local elapsed = tick() - ai.startTime
		if ai.trainerUnitsLost >= 8 or ai.trainerBldLost >= 2 or elapsed >= 420 then
			ai.trainerConceded = true
			ai.trainerMode     = "concede"
			print("[Trainer] Conceding — unitsLost:", ai.trainerUnitsLost,
				"bldLost:", ai.trainerBldLost,
				"elapsed:", math.floor(elapsed) .. "s")
		end
	end

	-- ── Mode escalation: shadow → press after first wave lands ────────────────
	if ai.trainerMode == "shadow" and ai.wavesSent >= 1 then
		ai.trainerMode = "press"
	end

	-- ── Build order ────────────────────────────────────────────────────────────
	if btBuildCC(ai) ~= SUCCESS then return end
	btBuildFirstMine(ai)
	btBuildFirstBarracks(ai)

	-- In concede: stop all expansion so the player can finish off the AI
	if ai.trainerConceded then
		local currentCount = unitManager.getUnitCount(ai.player)
		if currentCount ~= ai.lastSquadCount then
			rebuildSquads(ai)
			ai.lastSquadCount = currentCount
		end
		return
	end

	-- Inline expansion (bypasses checkAndGrantResearch to keep trainer tech-free)
	local liveMines    = unitManager.getActiveHarvesterCount(ai.player)
	local liveBarracks = countOwnedBuildings(ai.ownerStr, "Barracks")
	local liveTurrets  = countOwnedBuildings(ai.ownerStr, "Turret")

	-- Replace destroyed barracks first (army production)
	if liveBarracks < math.min(ai.diff.maxBarracks, ai.builtBarracks) then
		if canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Barracks", 15, 35) then
				ai.builtBarracks += 1
			end
		end
	end
	-- More mines (follow player economy)
	if liveMines < ai.diff.maxMines then
		if canAfford(ai.player, Config.MINE_COST, ai.diff.reserveResources) then
			local deposit = nearestFreeDeposit(ai.base)
			if deposit and buildingManager.placeForPlayer(ai.player, deposit, "Mine") then
				ai.builtMines += 1
			end
		end
	end
	-- More barracks (follow player)
	if liveBarracks < ai.diff.maxBarracks then
		if canAfford(ai.player, Config.BUILDING_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Barracks", 15, 35) then
				ai.builtBarracks = math.max(ai.builtBarracks, liveBarracks + 1)
			end
		end
	end
	-- One defensive turret
	if liveTurrets < 1 then
		if canAfford(ai.player, Config.TURRET_COST, ai.diff.reserveResources) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Turret", 20, 40) then
				ai.builtTurrets = math.max(ai.builtTurrets, 1)
			end
		end
	end
	-- Relay research + placement once player has 2+ barracks (extends build zone)
	if ai.builtBarracks >= 2 then
		grantTech(ai.player, "Relay")
		local liveRelays = countOwnedBuildings(ai.ownerStr, "Relay")
		if liveRelays < 1 then
			if canAfford(ai.player, Config.RELAY_COST, ai.diff.reserveResources) then
				if tryPlaceRandom(ai.player, ai.base, "Relay", 45, 70) then
					ai.builtRelays += 1
				end
			end
		end
	end

	-- Squad rebuild and composition when army count changes
	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai)
		ai.lastSquadCount = currentCount
	end
	updateComposition(ai)
end

-- Trainer army: wave-based probing with partial commitment and long cooling-off.
local function btCommandArmyTrainer(ai: any)
	local armySize = unitManager.getUnitCount(ai.player)
	if armySize == 0 then return FAILURE end

	local garrisonTarget = ai.baseUnderAttack and ai.base
		or snapGrid(ai.base + Vector3.new(0, 0, 18))

	-- Garrison always stays close to base
	if #ai.garrison > 0 then
		unitManager.sendUnitsTo(ai.player, ai.garrison, garrisonTarget)
	end

	-- ── Concede: everyone retreats home, AI stops fighting ────────────────────
	if ai.trainerConceded then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if #ai.garrison   > 0 then unitManager.sendUnitsTo(ai.player, ai.garrison, ai.base) end
		ai.combatPhase = "gather"
		return SUCCESS
	end

	-- ── Emergency defence: snap to base if attacked ───────────────────────────
	if ai.baseUnderAttack and ai.combatPhase ~= "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		ai.combatPhase      = "retreat"
		ai.phaseTimer       = 0
		ai.retreatDuration  = math.random(20, 35)
		ai.trainerWaveTimer = 0  -- reset so next gather starts fresh
		return SUCCESS
	end

	ai.phaseTimer += ai.diff.reactionInterval

	-- ── GATHER: patrol own perimeter; wait for wave interval ─────────────────
	if ai.combatPhase == "gather" then
		ai.trainerWaveTimer += ai.diff.reactionInterval

		-- Only patrol own near territory — no deep scouting
		local pts = ai.explorePoints
		local nearPts: { Vector3 } = {}
		for i = 1, math.min(8, #pts) do table.insert(nearPts, pts[i]) end
		if #ai.mainForce > 0 and #nearPts > 0 then
			ai.exploreTimer += ai.diff.reactionInterval
			if ai.exploreTimer >= 10 then
				ai.exploreTimer = 0
				ai.exploreIdx   = (ai.exploreIdx % #nearPts) + 1
			end
			fanAcrossMap(ai, ai.mainForce, nearPts, 3)
		end

		-- Launch wave when interval ready, army ready, target visible
		local waveReady = ai.trainerWaveTimer >= ai.trainerWaveInterval
		local armyReady = armySize >= ai.diff.minUnitsToAttack
		if waveReady and armyReady and ai.priorityTarget then
			local target = pickAttackTarget(ai)
			if target then
				local approachAngle  = math.random() * math.pi * 2
				ai.combatPhase       = "staging"
				ai.phaseTimer        = 0
				ai.attackTarget      = target
				ai.rallyPoint        = approachPoint(target, approachAngle, 60 + math.random(0, 20))
				ai.stageDuration     = math.random(5, 10)
				ai.attackDuration    = math.random(10, 16)
				ai.retreatDuration   = math.random(20, 40)
				-- Retreat earlier if losing units — triggers at 20-30 % losses
				ai.retreatThreshold  = 0.20 + math.random() * 0.10
				ai.lastArmySize      = armySize
				ai.trainerAttackStartArmy = armySize
			end
		end

	-- ── STAGING: hold at rally point before committing ────────────────────────
	elseif ai.combatPhase == "staging" then
		if #ai.mainForce > 0 and ai.rallyPoint then
			sendSpread(ai.player, ai.mainForce, ai.rallyPoint)
		end
		-- Abandon if target lost
		if not ai.priorityTarget and not ai.attackTarget then
			ai.combatPhase = "gather"
			ai.phaseTimer  = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			ai.combatPhase = "attack"
			ai.phaseTimer  = 0
			ai.wavesSent  += 1
		end

	-- ── ATTACK: commit 50-60 % of main force; rest holds at rally ────────────
	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then
			ai.combatPhase = "retreat"
			ai.phaseTimer  = 0
			return SUCCESS
		end

		-- Split: commit chunk rushes target, hold chunk waits at rally
		local n           = #ai.mainForce
		local commitRatio = 0.50 + math.random() * 0.10  -- 50-60 %
		local commitCount = math.max(1, math.floor(n * commitRatio))
		local commitChunk: { string } = {}
		local holdChunk:   { string } = {}
		for i, id in ai.mainForce do
			if i <= commitCount then table.insert(commitChunk, id)
			else                     table.insert(holdChunk, id)   end
		end
		sendSpread(ai.player, commitChunk, target)
		if ai.rallyPoint and #holdChunk > 0 then
			sendSpread(ai.player, holdChunk, ai.rallyPoint)
		end

		-- Loss check (compare vs. army size when attack started)
		local lossRatio = ai.trainerAttackStartArmy > 0
			and (ai.trainerAttackStartArmy - armySize) / ai.trainerAttackStartArmy
			or 0
		if lossRatio >= ai.retreatThreshold or ai.phaseTimer >= ai.attackDuration then
			-- Record kills for concede counter before leaving
			ai.trainerUnitsLost += math.max(0, ai.trainerAttackStartArmy - armySize)
			ai.combatPhase       = "retreat"
			ai.phaseTimer        = 0
			ai.feintTarget       = nil
			ai.isFlankingAttack  = false
		end

	-- ── RETREAT: pull back; then set next wave interval and re-enter gather ───
	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase  = "gather"
			ai.phaseTimer   = 0
			ai.attackTarget = nil
			ai.rallyPoint   = nil
			ai.feintTarget  = nil
			ai.lastArmySize = 0

			-- Next wave interval: longer if player is actively growing their army
			local playerArmy    = countHumanArmy()
			local playerGrowing = playerArmy > (ai.trainerLastPlayerArmy or 0)
			ai.trainerWaveInterval   = playerGrowing
				and math.random(60, 90)   -- give them breathing room while they build
				or  math.random(40, 65)   -- standard gap
			ai.trainerLastPlayerArmy = playerArmy
			ai.trainerWaveTimer      = 0  -- start fresh countdown in gather
		end
	end

	return SUCCESS
end

-- Trainer reaction tree
local function trainerReactionTree(ai: any)
	btUpdateVision(ai)
	-- Do not train once conceding
	if not ai.trainerConceded then
		btTrainUnit(ai)
	end
	btCommandArmyTrainer(ai)
end

-- ── Swarm gamemode behavior ────────────────────────────────────────────────────
-- Swarm AIs build only economy (CC + mines) plus Lamprey Nests and Creepy Blobs,
-- and field an army entirely of Lampreys / Hagfish / Creepy Soldiers. Army command
-- reuses the standard btCommandArmy (it operates on owned units of any type).

-- Per-level structure caps: { nests, blobs, mines }.
local function swarmCaps(level: number): (number, number, number)
	if level <= 1 then return 1, 0, 1
	elseif level == 2 then return 1, 1, 2
	elseif level == 3 then return 2, 1, 2
	elseif level == 4 then return 3, 2, 3
	else return 4, 3, 4 end
end

local function swarmStrategyTree(ai)
	-- Nightmare swarm: keep coffers full and raise the caps so the tide never stops.
	if ai.isNightmare then
		local current = resourceManager.get(ai.player)
		if current < 9999 then resourceManager.add(ai.player, 9999 - current) end
	end

	if btBuildCC(ai) ~= SUCCESS then return end

	-- Grant the Creepy Blob unlock once so the AI may place blobs. Set the flag
	-- first: grantTech records the tech before its (AI-unsafe) client ping, so the
	-- unlock sticks even if that ping is swallowed by the tick's pcall.
	if not ai.swarmTechGranted then
		ai.swarmTechGranted = true
		grantTech(ai.player, "CreepyBlob")
	end

	local maxNests, maxBlobs, maxMines = swarmCaps(ai.level)
	if ai.isNightmare then maxNests += 2; maxBlobs += 2 end

	-- Economy: harvesters on nearby deposits fund the swarm.
	local liveMines = unitManager.getActiveHarvesterCount(ai.player)
	if liveMines < maxMines and canAfford(ai.player, Config.MINE_COST, ai.diff.reserveResources) then
		local deposit = nearestFreeDeposit(ai.base)
		if deposit and buildingManager.placeForPlayer(ai.player, deposit, "Mine") then
			ai.builtMines += 1
		end
	end

	-- Primary production: Lamprey Nests (Lamprey + Hagfish).
	local liveNests = countOwnedBuildings(ai.ownerStr, "LampreyNest")
	if liveNests < maxNests and canAfford(ai.player, Config.LAMPREY_NEST_COST, ai.diff.reserveResources) then
		tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "LampreyNest", 15, 45)
	end

	-- Secondary production: Creepy Blobs (Creepy Soldier factories).
	local liveBlobs = countOwnedBuildings(ai.ownerStr, "CreepyBlob")
	if liveBlobs < maxBlobs and canAfford(ai.player, Config.CREEPY_BLOB_COST, ai.diff.reserveResources) then
		tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "CreepyBlob", 15, 45)
	end

	-- Reshuffle squads when the army size changes.
	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai)
		ai.lastSquadCount = currentCount
	end
end

local function btProduceSwarm(ai)
	if unitManager.getUnitCount(ai.player) >= ai.diff.maxUnits then return end

	-- Nests: lay one egg each, alternating Lamprey / Hagfish. The nest egg cap and
	-- resource reserve naturally throttle output.
	for _, nestId in getOwnedBuildingIds(ai.ownerStr, "LampreyNest") do
		ai.swarmEggToggle = not ai.swarmEggToggle
		local kind = if ai.swarmEggToggle then "Lamprey" else "Hagfish"
		local cost = if kind == "Hagfish" then Config.HAGFISH_EGG_COST else Config.LAMPREY_EGG_COST
		if canAfford(ai.player, cost, ai.diff.reserveResources) then
			buildingManager.requestNestEgg(ai.player, nestId, kind)
		end
	end

	-- Blobs: spawn Creepy Soldiers when off cooldown.
	for _, blobId in getOwnedBuildingIds(ai.ownerStr, "CreepyBlob") do
		if canAfford(ai.player, Config.BLOB_SOLDIER_COST, ai.diff.reserveResources) then
			buildingManager.requestBlobSoldier(ai.player, blobId)
		end
	end
end

-- ── Behavior Trees ────────────────────────────────────────────────────────────

local function strategyTree(ai)
	if ai.swarm then swarmStrategyTree(ai); return end
	if ai.personality == "trainer" then trainerStrategyTree(ai); return end
	-- Nightmare: exponential scaling — every stat grows with elapsed time.
	-- scale ≈ 2× at 1 min, ≈ 7× at 3 min, ≈ 28× at 5 min (math.exp(t/90)).
	if ai.isNightmare then
		local elapsed = tick() - ai.startTime
		local scale   = math.exp(elapsed / 90)

		ai.diff.maxMines         = math.ceil(2   * scale)
		ai.diff.maxBarracks      = math.ceil(2   * scale)
		ai.diff.maxTurrets       = math.ceil(2   * scale)
		ai.diff.maxRelays        = math.max(1, math.ceil(scale - 0.5))
		ai.diff.strategyInterval = math.max(0.5, 8   / math.sqrt(scale))
		ai.diff.reactionInterval = math.max(0.2, 1.5 / math.sqrt(scale))
		ai.diff.minUnitsToAttack = math.max(1,   math.floor(4 / scale))
		ai.diff.garrisonRatio    = math.max(0.01, 0.15 / scale)

		local current = resourceManager.get(ai.player)
		if current < 9999 then
			resourceManager.add(ai.player, 9999 - current)
		end
	end

	-- CC must be placed first; if it hasn't been, don't do anything else
	if btBuildCC(ai) ~= SUCCESS then return end

	-- Mine and barracks are best-effort starters — their failure doesn't block
	-- the expansion phase (which handles all building anyway).
	btBuildFirstMine(ai)
	btBuildFirstBarracks(ai)

	btExpansionPhase(ai)
end

local function reactionTree(ai)
	if ai.swarm then
		btUpdateVision(ai)
		btProduceSwarm(ai)
		btCommandArmy(ai)
		return
	end
	if ai.personality == "trainer" then trainerReactionTree(ai); return end
	btUpdateVision(ai)
	btTrainUnit(ai)
	btCommandArmy(ai)
end

-- ── AI state type ─────────────────────────────────────────────────────────────

type AIState = {
	player:      any,
	ownerStr:    string,
	diff:        DifficultyProfile,
	base:        Vector3,
	personality: string,
	level:       number,
	isNightmare: boolean,

	-- Swarm gamemode
	swarm:           boolean,
	swarmTechGranted: boolean,
	swarmEggToggle:  boolean,

	-- Infrastructure flags
	hasCC:       boolean,
	hasMonument: boolean,

	-- Lifetime counters (used for research grant thresholds; not decremented on building death)
	builtMines:    number,
	builtBarracks: number,
	builtTurrets:  number,
	builtRelays:   number,

	-- Unit training counters
	trainedSoldiers: number,
	trainedTanks:    number,

	-- Vision memory
	lastKnownEnemyPos: Vector3?,
	lastEnemySeenTick: number,
	priorityTarget:    Vector3?,

	-- Threat intel (updated every reaction tick)
	enemyTurretCount: number,
	enemyUnitCount:   number,
	baseUnderAttack:  boolean,

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

	-- Scout patrol (independent from main force)
	scoutIdx:   number,
	scoutTimer: number,

	-- Squad rebuild gate (only reshuffle when count changes)
	lastSquadCount: number,

	-- Combat state machine
	combatPhase:        string,
	phaseTimer:         number,
	attackTarget:       Vector3?,
	rallyPoint:         Vector3?,
	feintTarget:        Vector3?,
	flankAngle:         number,
	isFlankingAttack:   boolean,
	lastArmySize:       number,
	retreatThreshold:   number,
	stageDuration:      number,
	attackDuration:     number,
	retreatDuration:    number,
	wavesSent:          number,

	-- Tick accumulators
	strategyTimer: number,
	reactionTimer: number,

	startTime: number,  -- wall-clock time of spawn/reset (for nightmare scaling)

	-- Trainer personality state (initialized for all AIs; only used when personality == "trainer")
	trainerMode:            string,   -- "shadow" | "press" | "concede"
	trainerWaveTimer:       number,   -- seconds since gather phase started
	trainerWaveInterval:    number,   -- seconds to wait before next wave
	trainerUnitsLost:       number,   -- cumulative AI units killed during attacks
	trainerBldLost:         number,   -- cumulative AI buildings destroyed by player
	trainerAttackStartArmy: number,   -- army size at start of current attack
	trainerLastBldCount:    number,   -- human building count last strategy tick
	trainerLastOwnBldCount: number,   -- own building count last strategy tick
	trainerLastPlayerArmy:  number,   -- human army count last retreat end
	trainerConceded:        boolean,  -- whether concede mode has been triggered
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

-- Toggle Swarm gamemode for all subsequently-spawned AI bots.
function AIManager.setSwarmMode(on: boolean)
	swarmMode = on and true or false
end

function AIManager.resetBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end
	ai.hasCC             = false
	ai.hasMonument       = false
	ai.swarmTechGranted  = false
	ai.swarmEggToggle    = false
	ai.builtMines        = 0
	ai.builtBarracks     = 0
	ai.builtTurrets      = 0
	ai.builtRelays       = 0
	ai.trainedSoldiers   = 0
	ai.trainedTanks      = 0
	ai.lastKnownEnemyPos = nil
	ai.lastEnemySeenTick = 0
	ai.priorityTarget    = nil
	ai.enemyTurretCount  = 0
	ai.enemyUnitCount    = 0
	ai.baseUnderAttack   = false
	ai.mainForce         = {}
	ai.garrison          = {}
	ai.scouts            = {}
	ai.currentWeights    = {}
	for k, v in ai.diff.baseWeights do ai.currentWeights[k] = v end
	ai.exploreIdx        = 1
	ai.exploreTimer      = 0
	ai.scoutIdx          = math.floor(#ai.explorePoints * 0.6) + 1
	ai.scoutTimer        = 0
	ai.lastSquadCount    = 0
	ai.combatPhase       = "gather"
	ai.phaseTimer        = 0
	ai.attackTarget      = nil
	ai.rallyPoint        = nil
	ai.feintTarget       = nil
	ai.flankAngle        = 0
	ai.isFlankingAttack  = false
	ai.lastArmySize      = 0
	ai.retreatThreshold  = 0.40
	ai.stageDuration     = 12
	ai.attackDuration    = 25
	ai.retreatDuration   = 15
	ai.wavesSent         = 0
	ai.strategyTimer     = ai.diff.strategyInterval
	ai.reactionTimer     = ai.diff.reactionInterval
	ai.startTime         = tick()
	ai.trainerMode            = "shadow"
	ai.trainerWaveTimer       = 0
	ai.trainerWaveInterval    = 60
	ai.trainerUnitsLost       = 0
	ai.trainerBldLost         = 0
	ai.trainerAttackStartArmy = 0
	ai.trainerLastBldCount    = 0
	ai.trainerLastOwnBldCount = 0
	ai.trainerLastPlayerArmy  = 0
	ai.trainerConceded        = false
	resourceManager.add(ai.player, Config.STARTING_RESOURCES)
	print("[AIManager] Bot", userId, "reset to rebuild")
end

function AIManager.resetAllBots()
	takenBaseIdx = {}
	for userId in botByUserId do
		AIManager.resetBot(userId)
	end
end

-- Pick the AI_BASES corner that is furthest from all existing Command Centers
-- (player CCs already placed + other AI bases already claimed this session).
local function pickBestBase(): (Vector3, number)
	local existingCCPositions: { Vector3 } = {}

	-- Scan workspace for all placed CCs
	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local tv = model:FindFirstChild("BuildingType")
			if tv and tv.Value == "CommandCenter" then
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then
					table.insert(existingCCPositions, Vector3.new(base.Position.X, 0, base.Position.Z))
				end
			end
		end
	end

	-- Also treat already-claimed base corners as occupied
	for idx, taken in takenBaseIdx do
		if taken then
			local c = AI_BASES[idx]
			table.insert(existingCCPositions, Vector3.new(c.X, 0, c.Z))
		end
	end

	-- Find the unclaimed corner with the greatest minimum distance to all CCs
	local bestIdx: number = -1
	local bestScore = -1

	for i, corner in AI_BASES do
		if takenBaseIdx[i] then continue end
		local cornerXZ = Vector3.new(corner.X, 0, corner.Z)
		local minDist = math.huge
		for _, ccPos in existingCCPositions do
			local d = (cornerXZ - ccPos).Magnitude
			if d < minDist then minDist = d end
		end
		if #existingCCPositions == 0 then minDist = math.huge end
		if minDist > bestScore then
			bestScore = minDist
			bestIdx   = i
		end
	end

	-- Fallback: any unclaimed corner
	if bestIdx == -1 then
		for i in AI_BASES do
			if not takenBaseIdx[i] then bestIdx = i; break end
		end
	end

	-- Last resort: cycle
	if bestIdx == -1 then
		bestIdx = ((aiCounter - 1) % #AI_BASES) + 1
	end

	takenBaseIdx[bestIdx] = true
	return AI_BASES[bestIdx], bestIdx
end

function AIManager.spawnAI(personality: string, level: number, baseOverride: Vector3?): boolean
	personality = tostring(personality):lower()
	level       = math.clamp(math.floor(tonumber(level) or 3), 1, 5)

	if not VALID_PERSONALITIES[personality] then
		warn("[AIManager] Unknown personality:", personality, "— use balanced / territorial / waves / nightmare")
		return false
	end

	local diff = buildProfile(personality, level)

	aiCounter += 1
	local base: Vector3
	local colorIdx: number
	if baseOverride then
		colorIdx = ((aiCounter - 1) % #AI_COLORS) + 1
		base     = baseOverride
	else
		base, colorIdx = pickBestBase()
	end

	local team          = Instance.new("Team")
	team.Name           = string.format("AI [%s lv%d] %d", personality, level, aiCounter)
	team.TeamColor      = AI_COLORS[colorIdx]
	team.AutoAssignable = false
	team.Parent         = Teams

	local aiPlayer = {
		UserId    = -aiCounter,
		TeamColor = AI_COLORS[colorIdx],
		Team      = team,
		Name      = "AI_" .. aiCounter,
		Parent    = workspace,
	}

	resourceManager.add(aiPlayer, Config.STARTING_RESOURCES)

	local ai: AIState = {
		player      = aiPlayer,
		ownerStr    = tostring(aiPlayer.UserId),
		diff        = diff,
		base        = base,
		personality = personality,
		level       = personality == "nightmare" and 5 or personality == "trainer" and 1 or level,
		isNightmare = personality == "nightmare",

		swarm            = swarmMode,
		swarmTechGranted = false,
		swarmEggToggle   = false,

		hasCC       = false,
		hasMonument = false,

		builtMines    = 0,
		builtBarracks = 0,
		builtTurrets  = 0,
		builtRelays   = 0,

		trainedSoldiers = 0,
		trainedTanks    = 0,

		lastKnownEnemyPos = nil,
		lastEnemySeenTick = 0,
		priorityTarget    = nil,

		enemyTurretCount = 0,
		enemyUnitCount   = 0,
		baseUnderAttack  = false,

		mainForce = {},
		garrison  = {},
		scouts    = {},

		currentWeights = diff.baseWeights,

		explorePoints = generateExplorePoints(base),
		exploreIdx    = 1,
		exploreTimer  = 0,

		scoutIdx   = 0,  -- resolved below after explorePoints is computed
		scoutTimer = 0,

		lastSquadCount = 0,

		combatPhase      = "gather",
		phaseTimer       = 0,
		attackTarget     = nil,
		rallyPoint       = nil,
		feintTarget      = nil,
		flankAngle       = 0,
		isFlankingAttack = false,
		lastArmySize     = 0,
		retreatThreshold = 0.40,
		stageDuration    = 12,
		attackDuration   = 25,
		retreatDuration  = 15,
		wavesSent        = 0,

		strategyTimer = diff.strategyInterval,
		reactionTimer = diff.reactionInterval,

		startTime = tick(),

		-- Trainer state (safe defaults; only meaningful when personality == "trainer")
		trainerMode            = "shadow",
		trainerWaveTimer       = 0,
		trainerWaveInterval    = 60,  -- first wave after ~60 s of gather
		trainerUnitsLost       = 0,
		trainerBldLost         = 0,
		trainerAttackStartArmy = 0,
		trainerLastBldCount    = 0,
		trainerLastOwnBldCount = 0,
		trainerLastPlayerArmy  = 0,
		trainerConceded        = false,
	}

	-- Start scouts in enemy territory (far half of the explore list)
	ai.scoutIdx = math.floor(#ai.explorePoints * 0.6) + 1

	botByUserId[aiPlayer.UserId] = ai

	task.spawn(function()
		while true do
			local dt = task.wait(0.5)
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

	print(string.format("[AIManager] Spawned %s AI lv%d #%d at %s", personality, level, aiCounter, tostring(base)))
	return true
end

return AIManager
