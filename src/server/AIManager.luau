--[[
	AIManager v5 — Strategic Commander.

	The old AI ran one linear build order, a near-fixed composition, and a single
	gather→stage→attack→retreat loop for every difficulty. v5 replaces that brain
	with a strategic layer while keeping the spawn/lifecycle scaffolding intact.

	Core ideas:
	  • ARCHETYPES — each bot adopts a strategic identity (Aggressor / Mechanized /
	    Economist / Defender / Waves). "balanced" rolls a RANDOM archetype per game,
	    so two same-difficulty bots play differently. Each archetype defines economy
	    targets, per-phase composition, a tech plan, a preferred turret upgrade, and
	    aggression knobs.
	  • PHASES — opening / expand / mid / late, derived from time + economy, gate the
	    composition tier, tech depth, and aggression.
	  • DESIRED-STATE ECONOMY — instead of a fixed ladder, each strategy tick computes
	    desired building/harvester counts, builds a priority-scored shopping list, and
	    buys top-down through the budget (honoring a reserve). Spending adapts to bank
	    size and live threats.
	  • COUNTER-COMPOSITION — scouts enemy unit types + defenses and answers them:
	    Howitzers vs turret lines (only unit out-ranging a turret), Tank+Foamer vs
	    cheap masses, Elite+Foamer vs heavy mech. Demanded tech is self-granted.
	  • TECH + TURRET UPGRADES — the AI grants itself research (which its units use
	    automatically) and upgrades turrets via BuildingManager.upgradeTurretForPlayer.
	  • VALUE-BASED COMBAT — commits/retreats on relative force VALUE, not a clock.
	    Adds harassment squads that hunt enemy Harvesters and composition-aware
	    positioning (Howitzers hold at range, Medics trail, line units lead).

	Difficulty levels 1-5 scale economy caps, army cap, tech depth, cadence, micro
	competence and aggression — tuned stronger than v4 overall.

	The AI never races the Monument (a pressure opponent, not a clock).

	Chat command: /ai balanced|territorial|waves|nightmare|trainer [1-5]
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

-- ── Difficulty levels (1 = weakest, 5 = brutal) ────────────────────────────────
-- caps:  h=harvesters  b=barracks  t=turrets  r=relays
-- techTier: how deep into an archetype's tech plan this level reaches (0 = none)
-- competence: 0..1, gates scouting / flanking / micro polish
-- firstStrike: seconds of opening "peace" before the bot launches its FIRST
--   committed assault. During this window it only ECONOMIES, SCOUTS and lurks at
--   the edge of the player's vision — it does not march the main army in. Lower
--   difficulties stalk longer; higher ones strike sooner (but never instantly).
type Level = {
	maxUnits: number,
	hcap: number, bcap: number, tcap: number, rcap: number,
	reserve: number,
	strat: number, react: number,
	vision: number, mem: number,
	minAtk: number,
	techTier: number,
	competence: number,
	firstStrike: number,
}

-- Caps tuned so even mid difficulties build a real, defended, spread-out base
-- (more turrets + relays so a cleared army doesn't leave the base wide open).
local LEVELS: { Level } = {
	{ maxUnits = 8,   hcap = 2, bcap = 1, tcap = 2, rcap = 1, reserve = 30, strat = 9.5, react = 2.2, vision = 46, mem = 12,  minAtk = 4, techTier = 0, competence = 0.40, firstStrike = 210 },
	{ maxUnits = 15,  hcap = 3, bcap = 2, tcap = 3, rcap = 1, reserve = 40, strat = 8.0, react = 1.8, vision = 55, mem = 25,  minAtk = 4, techTier = 1, competence = 0.55, firstStrike = 175 },
	{ maxUnits = 24,  hcap = 4, bcap = 3, tcap = 5, rcap = 2, reserve = 50, strat = 6.5, react = 1.4, vision = 63, mem = 45,  minAtk = 5, techTier = 2, competence = 0.70, firstStrike = 145 },
	{ maxUnits = 36,  hcap = 6, bcap = 3, tcap = 6, rcap = 3, reserve = 65, strat = 5.0, react = 1.1, vision = 70, mem = 75,  minAtk = 5, techTier = 3, competence = 0.85, firstStrike = 115 },
	{ maxUnits = 999, hcap = 7, bcap = 4, tcap = 8, rcap = 3, reserve = 75, strat = 4.0, react = 0.8, vision = 78, mem = 999, minAtk = 6, techTier = 4, competence = 1.00, firstStrike = 90 },
}

-- ── Strategic archetypes ───────────────────────────────────────────────────────
-- desired: target counts the archetype wants (clamped by level caps each tick)
-- comp:    per-phase base unit weights (counters layer on top)
-- techPlan: ordered tech grants (level techTier limits depth)
-- turret:  preferred turret upgrade
-- engageRatio: commit when myValue >= enemyLocalValue * engageRatio
-- garrison: fraction of army held at home
type Archetype = {
	label: string,
	desired: { harvesters: number, barracks: number, turrets: number, relays: number, deployers: number },
	comp: { [string]: { [string]: number } },
	techPlan: { string },
	turret: string,
	engageRatio: number,
	harass: boolean,
	waveMode: boolean,
	turtle: boolean,
	noCounter: boolean,
	garrison: number,
	reserveMult: number,
	stageMin: number, stageMax: number,
}

local ARCHETYPES: { [string]: Archetype } = {
	Aggressor = {
		label = "Aggressor",
		desired = { harvesters = 3, barracks = 2, turrets = 3, relays = 1, deployers = 0 },
		comp = {
			opening = { Soldier = 4 },
			expand  = { Soldier = 4, Elite = 2 },
			mid     = { Soldier = 3, Elite = 3, Foamer = 1 },
			late    = { Soldier = 2, Elite = 4, Foamer = 1, Tank = 1 },
		},
		techPlan = { "EliteUnits", "CombatStims", "HardenedArmor", "Rollers" },
		turret = "Flamethrower",
		engageRatio = 0.85, harass = true, waveMode = false, turtle = false, noCounter = false,
		garrison = 0.22, reserveMult = 0.6, stageMin = 3, stageMax = 8,
	},
	Mechanized = {
		label = "Mechanized",
		desired = { harvesters = 4, barracks = 3, turrets = 4, relays = 2, deployers = 1 },
		comp = {
			opening = { Soldier = 3 },
			expand  = { Soldier = 2, Tank = 3 },
			mid     = { Tank = 4, Howitzer = 1, Elite = 1 },
			late    = { Tank = 4, Howitzer = 2, Elite = 2, Medic = 1 },
		},
		techPlan = { "ConcussionShells", "EliteUnits", "RocketBarrage", "MedicUnit" },
		turret = "Artillery",
		engageRatio = 1.20, harass = false, waveMode = false, turtle = false, noCounter = false,
		garrison = 0.30, reserveMult = 1.2, stageMin = 8, stageMax = 18,
	},
	Economist = {
		label = "Economist",
		desired = { harvesters = 6, barracks = 3, turrets = 4, relays = 3, deployers = 1 },
		comp = {
			opening = { Soldier = 3 },
			expand  = { Soldier = 3, Tank = 1 },
			mid     = { Soldier = 2, Tank = 2, Elite = 2, Medic = 1 },
			late    = { Tank = 3, Elite = 3, Howitzer = 1, Medic = 2 },
		},
		techPlan = { "EliteUnits", "MedicUnit", "ConcussionShells", "TurretUpgrades" },
		turret = "RocketLauncher",
		engageRatio = 1.05, harass = true, waveMode = false, turtle = false, noCounter = false,
		garrison = 0.30, reserveMult = 1.0, stageMin = 6, stageMax = 14,
	},
	Defender = {
		label = "Defender",
		desired = { harvesters = 5, barracks = 3, turrets = 8, relays = 3, deployers = 1 },
		comp = {
			opening = { Soldier = 3 },
			expand  = { Soldier = 3, Foamer = 1 },
			mid     = { Soldier = 2, Foamer = 2, Howitzer = 1, Tank = 1 },
			late    = { Howitzer = 3, Foamer = 2, Tank = 2, Elite = 2, Medic = 1 },
		},
		techPlan = { "TurretUpgrades", "EliteUnits", "ConcussionShells", "MedicUnit" },
		turret = "Artillery",
		engageRatio = 1.40, harass = false, waveMode = false, turtle = true, noCounter = false,
		garrison = 0.45, reserveMult = 1.3, stageMin = 10, stageMax = 20,
	},
	Waves = {
		label = "Waves",
		desired = { harvesters = 4, barracks = 3, turrets = 4, relays = 2, deployers = 0 },
		comp = {
			opening = { Soldier = 4 },
			expand  = { Soldier = 3, Tank = 1 },
			mid     = { Soldier = 2, Tank = 3, Elite = 1 },
			late    = { Tank = 3, Howitzer = 2, Elite = 2, Foamer = 1 },
		},
		techPlan = { "EliteUnits", "ConcussionShells", "TurretUpgrades", "RocketBarrage" },
		turret = "RocketLauncher",
		engageRatio = 0.90, harass = false, waveMode = true, turtle = false, noCounter = false,
		garrison = 0.32, reserveMult = 1.0, stageMin = 4, stageMax = 10,
	},
	-- Teaching opponent: simple comp, no counters, no deep tech.
	Trainer = {
		label = "Trainer",
		desired = { harvesters = 2, barracks = 2, turrets = 1, relays = 0, deployers = 0 },
		comp = {
			opening = { Soldier = 3 },
			expand  = { Soldier = 3, Tank = 1 },
			mid     = { Soldier = 3, Tank = 1, Foamer = 1 },
			late    = { Soldier = 3, Tank = 1, Foamer = 1 },
		},
		techPlan = {},
		turret = "Flamethrower",
		engageRatio = 1.5, harass = false, waveMode = false, turtle = true, noCounter = true,
		garrison = 0.35, reserveMult = 1.0, stageMin = 6, stageMax = 10,
	},
	-- Swarm gamemode: combat knobs only (production handled by btProduceSwarm).
	Swarm = {
		label = "Swarm",
		desired = { harvesters = 4, barracks = 0, turrets = 0, relays = 0, deployers = 0 },
		comp = { opening = { Soldier = 1 }, expand = { Soldier = 1 }, mid = { Soldier = 1 }, late = { Soldier = 1 } },
		techPlan = {},
		turret = "Flamethrower",
		engageRatio = 0.8, harass = true, waveMode = false, turtle = false, noCounter = true,
		garrison = 0.12, reserveMult = 1.0, stageMin = 3, stageMax = 7,
	},
}

local BALANCED_ROLL = { "Aggressor", "Mechanized", "Economist" }
local NIGHTMARE_ROLL = { "Aggressor", "Mechanized", "Economist", "Defender", "Waves" }

local VALID_PERSONALITIES = { balanced = true, territorial = true, waves = true, nightmare = true, trainer = true }

local RETREAT_RATIO = 0.45  -- retreat when myValue < enemyLocalValue * this

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
local takenBaseIdx: { [number]: boolean } = {}

local swarmMode = false

-- ── Generic helpers ─────────────────────────────────────────────────────────

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

local function pickFrom(list: { string }): string
	return list[math.random(1, #list)]
end

local function unitValue(unitType: string): number
	local d = Config.UNIT_TYPES[unitType]
	if d and d.cost and d.cost > 0 then return d.cost end
	return 20  -- free units (CreepySoldier) still count for something
end

local function canAfford(player: any, cost: number, reserve: number): boolean
	return resourceManager.get(player) >= cost + reserve
end

local function hasTech(ai: any, techName: string): boolean
	return researchManager ~= nil and researchManager.hasResearch(ai.player, techName)
end

-- ── Building scans (live; never stale) ─────────────────────────────────────────

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

-- ── Placement helpers ─────────────────────────────────────────────────────────

local function tryPlaceRandom(player: any, anchor: Vector3, buildType: string, minR: number, maxR: number): boolean
	for _ = 1, 20 do
		local angle = math.random() * math.pi * 2
		local r     = minR + math.random() * (maxR - minR)
		local pos   = snapGrid(anchor + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		if buildingManager.placeForPlayer(player, pos, buildType) then return true end
	end
	return false
end

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

local function tryPlaceAnywhere(player: any, ownerStr: string, base: Vector3, buildType: string, minR: number, maxR: number): boolean
	if tryPlaceRandom(player, base, buildType, minR, maxR) then return true end
	for _, anchor in getRelayAnchors(ownerStr) do
		if tryPlaceRandom(player, anchor, buildType, 5, maxR) then return true end
	end
	return false
end

-- ── Trainer measurement helpers ────────────────────────────────────────────────

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

-- ── Research grants ─────────────────────────────────────────────────────────

local function grantTech(player: any, techName: string)
	if not researchManager then return end
	researchManager.startForPlayer(player, "", techName)
end

-- Grant a tech, first granting any prerequisite it lists (e.g. RocketBarrage
-- needs ConcussionShells before its units actually fire rockets).
local function grantTechDeep(ai: any, techName: string)
	local u = (Config.UNLOCKS :: any)[techName]
	if not u then return end
	if u.requires and not hasTech(ai, u.requires) then
		grantTech(ai.player, u.requires)
	end
	grantTech(ai.player, techName)
end

-- ── Vision / threat scanning ────────────────────────────────────────────────

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

-- Sum of enemy combat value (units + defensive turrets) within radius of a point.
local function enemyValueNear(ownerStr: string, pos: Vector3, radius: number): number
	local r2    = radius * radius
	local total = 0
	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		for _, p in unitsF:GetChildren() do
			if not p:IsA("BasePart") then continue end
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == ownerStr then continue end
			local dx = (p :: BasePart).Position.X - pos.X
			local dz = (p :: BasePart).Position.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				local ut = p:FindFirstChild("UnitType")
				total += unitValue(ut and ut.Value or "Soldier")
			end
		end
	end
	local bF = workspace:FindFirstChild("Buildings")
	if bF then
		for _, m in bF:GetChildren() do
			local ov = m:FindFirstChild("OwnerId")
			local tv = m:FindFirstChild("BuildingType")
			if ov and ov.Value ~= ownerStr and tv and tv.Value == "Turret" then
				local base = m:FindFirstChild("Base") :: BasePart?
				if base then
					local dx = base.Position.X - pos.X
					local dz = base.Position.Z - pos.Z
					if dx * dx + dz * dz <= r2 then total += 55 end
				end
			end
		end
	end
	return total
end

type ThreatResult = {
	priorityTarget:   Vector3?,
	enemyTurretCount: number,
	enemyUnitCount:   number,
	enemyArmyValue:   number,
	baseUnderAttack:  boolean,
	enemyComp:        { [string]: number },
	enemyHarvesters:  { Vector3 },
}

local THREAT_BUILDING = {
	Monument = 200, CommandCenter = 100, LampreyNest = 70,
	Turret = 30, CreepyBlob = 35, Deployer = 50, Relay = 15,
}
local THREAT_UNIT = {
	Broodmother = 46, Howitzer = 38, Elite = 35, Lamprey = 32, Tank = 30, Soldier = 20,
	Foamer = 18, CreepySoldier = 15, Hagfish = 14, Medic = 10, Harvester = 8,
}

local function scanThreats(ai: any): ThreatResult
	local myStr = ai.ownerStr
	local vR    = ai.visionRadius
	local eyes  = gatherEyes(myStr)

	local result: ThreatResult = {
		priorityTarget   = nil,
		enemyTurretCount = 0,
		enemyUnitCount   = 0,
		enemyArmyValue   = 0,
		baseUnderAttack  = false,
		enemyComp        = {},
		enemyHarvesters  = {},
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

	local bestScore  = -math.huge
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

			local baseScore  = (THREAT_BUILDING :: any)[btype] or 25
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

			local ut    = p:FindFirstChild("UnitType")
			local utype = ut and ut.Value or "Soldier"

			result.enemyUnitCount += 1
			result.enemyComp[utype] = (result.enemyComp[utype] or 0) + 1
			result.enemyArmyValue += unitValue(utype)
			if utype == "Harvester" then
				table.insert(result.enemyHarvesters, Vector3.new(epos.X, 0, epos.Z))
			end

			local distToBase = (Vector3.new(epos.X, 0, epos.Z) - baseXZ).Magnitude
			if distToBase < 60 then result.baseUnderAttack = true end

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

local function generateExplorePoints(base: Vector3): { Vector3 }
	local pts: { Vector3 } = {}
	local B = 380

	local function ringPt(cx: number, cz: number, r: number, i: number, n: number): Vector3
		local a = (i / n) * math.pi * 2 + (math.random() - 0.5) * (math.pi * 2 / n) * 0.6
		return snapGrid(Vector3.new(
			math.clamp(cx + math.cos(a) * r, -B, B), 0,
			math.clamp(cz + math.sin(a) * r, -B, B)
		))
	end

	for i = 0, 7 do table.insert(pts, ringPt(base.X, base.Z, 45 + math.random(-8, 8), i, 8)) end
	local m1x, m1z = base.X * 0.55, base.Z * 0.55
	for i = 0, 7 do table.insert(pts, ringPt(m1x, m1z, 70 + math.random(-12, 12), i, 8)) end
	for i = 0, 7 do table.insert(pts, ringPt(0, 0, 75 + math.random(-15, 15), i, 8)) end
	local m2x, m2z = -base.X * 0.55, -base.Z * 0.55
	for i = 0, 7 do table.insert(pts, ringPt(m2x, m2z, 65 + math.random(-12, 12), i, 8)) end
	for i = 0, 3 do table.insert(pts, ringPt(-base.X, -base.Z, 45 + math.random(-8, 8), i, 4)) end

	return pts  -- 36 total
end

local function approachPoint(target: Vector3, angle: number, dist: number): Vector3
	local B = 380
	return snapGrid(Vector3.new(
		math.clamp(target.X + math.cos(angle) * dist, -B, B), 0,
		math.clamp(target.Z + math.sin(angle) * dist, -B, B)
	))
end

local function findEnemyBuilding(ownerStr: string, btype: string): Vector3?
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return nil end
	local found: { Vector3 } = {}
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		local tv = model:FindFirstChild("BuildingType")
		if ov and ov.Value ~= ownerStr and tv and tv.Value == btype then
			local base = model:FindFirstChild("Base") :: BasePart?
			if base then table.insert(found, Vector3.new(base.Position.X, 0, base.Position.Z)) end
		end
	end
	if #found == 0 then return nil end
	return found[math.random(1, #found)]
end

-- Weighted target: visible threat (50%) > production > defense > CC.
local function pickAttackTarget(ai: any): Vector3?
	if ai.priorityTarget and math.random() < 0.5 then return ai.priorityTarget end
	local own = ai.ownerStr
	local r = math.random()
	local t: Vector3?
	if r < 0.38 then
		t = findEnemyBuilding(own, "Deployer") or findEnemyBuilding(own, "LampreyNest")
	elseif r < 0.58 then
		t = findEnemyBuilding(own, "Turret")
	elseif r < 0.74 then
		t = findEnemyBuilding(own, "Relay")
	else
		t = findEnemyBuilding(own, "CommandCenter")
	end
	return t or ai.priorityTarget or findEnemyBuilding(own, "CommandCenter") or findEnemyBuilding(own, "LampreyNest")
end

-- ── Movement helpers ────────────────────────────────────────────────────────

local function sendSpread(player: any, units: { string }, target: Vector3)
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

local function fanAcrossMap(ai: any, units: { string }, pts: { Vector3 }, groupSize: number)
	local n = #units
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

-- Composition-aware commit: Howitzers hold at standoff, Medics trail, line leads.
-- Optional 65/35 flank split of the line force onto a feint target.
local function commitAttack(ai: any, data: any, target: Vector3)
	local mainSet: { [string]: boolean } = {}
	for _, id in ai.mainForce do mainSet[id] = true end

	local siege, line, support = {}, {}, {}
	for _, u in data do
		if not mainSet[u.id] then continue end
		if u.unitType == "Howitzer" then table.insert(siege, u.id)
		elseif u.unitType == "Medic" then table.insert(support, u.id)
		else table.insert(line, u.id) end
	end

	local dirAngle = math.atan2(target.Z - ai.base.Z, target.X - ai.base.X)

	if ai.isFlankingAttack and ai.feintTarget and #line >= 5 then
		local mainCount = math.floor(#line * 0.65)
		local a, b = {}, {}
		for i, id in line do
			if i <= mainCount then table.insert(a, id) else table.insert(b, id) end
		end
		sendSpread(ai.player, a, target)
		sendSpread(ai.player, b, ai.feintTarget)
	elseif #line > 0 then
		sendSpread(ai.player, line, target)
	end

	if #siege > 0 then
		-- Howitzer range is 65; hold ~52 studs back on the approach side.
		sendSpread(ai.player, siege, approachPoint(target, dirAngle + math.pi, 52))
	end
	if #support > 0 then
		unitManager.sendUnitsTo(ai.player, support, approachPoint(target, dirAngle + math.pi, 20))
	end
end

-- ── Scout / stalker behavior ──────────────────────────────────────────────────
-- The scout is not a map-reconner — it is a lurker. It creeps to the EDGE of the
-- player's vision near their base or last-seen position and then behaves
-- unpredictably: it WATCHES (stands dead still, just out of the fog, staring),
-- WANDERS (drifts along the perimeter), or VANISHES (slips back into the fog,
-- then reappears from a new angle). Random dwell times and transitions make it
-- impossible to read — that flicker of a unit at the fog line is the scare.

-- A "fog-edge" ring distance: far enough to stay mostly hidden, close enough that
-- a building/unit at the rim of its vision catches a glimpse. (Player units reveal
-- ~65 studs, the CC ~75.)
local LURK_MIN, LURK_MAX = 72, 96

local function lurkAnchor(ai: any): Vector3?
	-- Prefer the live threat, then last-known enemy position, then a discovered
	-- enemy CC; fall back to the far edge of our explore ring (toward the enemy).
	return ai.priorityTarget
		or ai.lastKnownEnemyPos
		or findEnemyBuilding(ai.ownerStr, "CommandCenter")
		or findEnemyBuilding(ai.ownerStr, "Deployer")
end

local function updateScouts(ai: any, pts: { Vector3 })
	if #ai.scouts == 0 then ai.scoutState = nil; return end

	ai.scoutTimer = (ai.scoutTimer or 0) + ai.reactionInterval
	local anchor  = lurkAnchor(ai)

	-- No idea where the enemy is yet → patrol the far explore points to FIND them,
	-- biasing toward fresh angles so the search itself looks restless.
	if not anchor then
		ai.scoutState = "search"
		if ai.scoutTimer >= 9 then
			ai.scoutTimer = 0
			ai.scoutIdx   = math.random(math.max(1, math.floor(#pts * 0.55)), #pts)
		end
		unitManager.sendUnitsTo(ai.player, ai.scouts, pts[ai.scoutIdx])
		return
	end

	-- Found something to haunt. Run a little state machine with random dwell times.
	if not ai.scoutState or ai.scoutState == "search" then
		ai.scoutState   = "approach"
		ai.scoutTimer   = 0
		ai.scoutDwell   = 0
		ai.scoutAngle   = math.random() * math.pi * 2
	end

	if ai.scoutTimer < (ai.scoutDwell or 0) then
		-- Still holding the current behavior; only "wander" keeps nudging the target.
		if ai.scoutState == "wander" and ai.scoutPoint then
			unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)
		end
		return
	end

	-- Dwell elapsed → pick the next state. Weighted for unpredictability.
	ai.scoutTimer = 0
	local prev = ai.scoutState
	local r    = math.random()

	if prev == "approach" then
		-- Arrived at the fog edge → mostly stop and watch, sometimes immediately drift.
		ai.scoutState = (r < 0.7) and "watch" or "wander"
	elseif prev == "watch" then
		-- After staring a while: drift along the rim, or melt back into the fog.
		ai.scoutState = (r < 0.45) and "wander" or (r < 0.8) and "vanish" or "watch"
	elseif prev == "wander" then
		ai.scoutState = (r < 0.4) and "watch" or (r < 0.7) and "vanish" or "approach"
	else -- "vanish" → reappear from a brand-new angle
		ai.scoutState = "approach"
		ai.scoutAngle = math.random() * math.pi * 2
	end

	local dist = LURK_MIN + math.random() * (LURK_MAX - LURK_MIN)

	if ai.scoutState == "approach" then
		ai.scoutDwell = math.random(3, 5)
		ai.scoutPoint = approachPoint(anchor, ai.scoutAngle, dist)
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)

	elseif ai.scoutState == "watch" then
		-- Stand dead still and stare. Long, varied hold = the unsettling part.
		ai.scoutDwell = math.random(4, 9)
		ai.scoutPoint = ai.scoutPoint or approachPoint(anchor, ai.scoutAngle, dist)
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)

	elseif ai.scoutState == "wander" then
		-- Creep sideways around the perimeter to a neighbouring angle.
		ai.scoutDwell = math.random(2, 4)
		ai.scoutAngle = (ai.scoutAngle or 0) + (math.random() < 0.5 and -1 or 1) * (0.5 + math.random() * 0.7)
		ai.scoutPoint = approachPoint(anchor, ai.scoutAngle, dist)
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)

	else -- "vanish": retreat deep into the fog, then it'll re-approach from elsewhere.
		ai.scoutDwell = math.random(4, 8)
		local hideAngle = ai.scoutAngle or 0
		unitManager.sendUnitsTo(ai.player, ai.scouts, approachPoint(anchor, hideAngle, dist + 70))
	end
end

-- Harassment squad hunts enemy economy (Harvesters first), then soft buildings.
-- Held back during the opening peace window so the first thing the player ever
-- sees the bot do is lurk, not kill harvesters.
local function updateHarass(ai: any)
	if #ai.harass == 0 then return end
	if ai.harassUnlockTime and tick() < ai.harassUnlockTime then
		-- Not yet allowed to harass: shadow the enemy economy from a distance
		-- instead, so the squad reads as a second creeping scout, not an attacker.
		-- Re-pick a standoff point only every few seconds so it drifts, not twitches.
		ai.harassTimer += ai.reactionInterval
		if ai.harassTimer >= 6 or not ai.harassTarget then
			ai.harassTimer = 0
			if ai.lastKnownEnemyPos then
				local a = math.random() * math.pi * 2
				ai.harassTarget = approachPoint(ai.lastKnownEnemyPos, a, 80 + math.random(0, 35))
			else
				ai.harassTarget = ai.base
			end
		end
		if ai.harassTarget then sendSpread(ai.player, ai.harass, ai.harassTarget) end
		return
	end
	ai.harassTimer += ai.reactionInterval
	if ai.harassTimer >= 4 or not ai.harassTarget then
		ai.harassTimer = 0
		local tgt: Vector3?
		if ai.enemyHarvesters and #ai.enemyHarvesters > 0 then
			tgt = ai.enemyHarvesters[math.random(1, #ai.enemyHarvesters)]
		end
		tgt = tgt or findEnemyBuilding(ai.ownerStr, "Relay")
			or findEnemyBuilding(ai.ownerStr, "Deployer")
			or findEnemyBuilding(ai.ownerStr, "CommandCenter")
			or ai.explorePoints[#ai.explorePoints]
		ai.harassTarget = tgt
	end
	if ai.harassTarget then sendSpread(ai.player, ai.harass, ai.harassTarget) end
end

-- ── Squad partitioning ────────────────────────────────────────────────────────
-- Carves out scouts + a harass squad (preferring the fastest units), then splits
-- the remainder into a garrison and a main force.

local function rebuildSquads(ai: any)
	local allUnits = unitManager.getPlayerUnitData(ai.player)
	local total    = #allUnits
	ai.scouts, ai.harass, ai.mainForce, ai.garrison = {}, {}, {}, {}
	if total == 0 then return end

	-- Always peel off a lurker once there's an army to spare — the stalker at the
	-- fog edge is core atmosphere, not a competence perk. Skilled bots field two.
	-- (Trainer keeps its own careful loop and never lurks.)
	local scoutN  = (total >= 4 and ai.personality ~= "trainer") and 1 or 0
	if ai.competence >= 0.85 and total >= 10 and ai.personality ~= "trainer" then scoutN = 2 end
	local harassN = 0
	if ai.archetype.harass and total >= 8 then
		harassN = math.min(3, math.floor(total * 0.2))
	end

	-- Fastest units first → good scouts / harassers.
	local fast = table.clone(allUnits)
	table.sort(fast, function(a, b)
		local sa = (Config.UNIT_MOVE_SPEED :: any)[a.unitType] or 20
		local sb = (Config.UNIT_MOVE_SPEED :: any)[b.unitType] or 20
		return sa > sb
	end)

	local picked: { [string]: boolean } = {}
	for i = 1, scoutN do
		local u = fast[i]; if u then table.insert(ai.scouts, u.id); picked[u.id] = true end
	end
	for i = scoutN + 1, scoutN + harassN do
		local u = fast[i]; if u then table.insert(ai.harass, u.id); picked[u.id] = true end
	end

	local rest = {}
	for _, u in allUnits do
		if not picked[u.id] then table.insert(rest, u.id) end
	end

	local garrisonN = math.max(rest[1] and 1 or 0, math.floor(#rest * ai.garrisonRatio))
	local mainN     = #rest - garrisonN
	for i, id in rest do
		if i <= mainN then table.insert(ai.mainForce, id)
		else table.insert(ai.garrison, id) end
	end
end

-- ── Counter-composition ───────────────────────────────────────────────────────

local function computeComposition(ai: any)
	local arche = ai.archetype
	local base  = arche.comp[ai.phase] or arche.comp.mid
	local w: { [string]: number } = {}
	for k, v in base do w[k] = v end

	-- Wave archetype: escalate the tier with each wave launched.
	if arche.waveMode then
		local tier = math.min(ai.wavesSent, 4)
		w["Tank"] = (w["Tank"] or 0) + tier
		if tier >= 2 then w["Elite"]    = (w["Elite"] or 0) + 1 end
		if tier >= 3 then w["Howitzer"] = (w["Howitzer"] or 0) + 1 end
	end

	if not arche.noCounter then
		local comp = ai.enemyComp or {}
		local cheapMass = (comp.Soldier or 0) + (comp.CreepySoldier or 0) + (comp.Hagfish or 0)
		local heavy     = (comp.Tank or 0) + (comp.Howitzer or 0) + (comp.Elite or 0) + (comp.Lamprey or 0)

		-- Turret lines: only the Howitzer (65) out-ranges a turret (50).
		if ai.enemyTurretCount >= 2 then
			w["Howitzer"] = (w["Howitzer"] or 0) + ai.enemyTurretCount
			w["Elite"]    = (w["Elite"] or 0) + 1
		end
		-- Cheap masses: Tank splash + Foamer AoE slow.
		if cheapMass >= 4 then
			w["Tank"]   = (w["Tank"] or 0) + math.floor(cheapMass / 3)
			w["Foamer"] = (w["Foamer"] or 0) + 1
		end
		-- Heavy mech: Elite + Foamer to peel, backed by Soldiers.
		if heavy >= 3 then
			w["Elite"]   = (w["Elite"] or 0) + 2
			w["Foamer"]  = (w["Foamer"] or 0) + 1
			w["Soldier"] = (w["Soldier"] or 0) + 1
		end
	end

	-- Medic support once researched and the army is large enough to be worth it.
	if hasTech(ai, "MedicUnit") and unitManager.getUnitCount(ai.player) >= 6 then
		w["Medic"] = math.max(w["Medic"] or 0, 1)
	end

	-- Gate research-locked units; record demand so planTech grants what we want.
	ai.compDemand = {}
	local gated = { Elite = "EliteUnits", Medic = "MedicUnit" }
	for unitName, tech in gated do
		if (w[unitName] or 0) > 0 and not hasTech(ai, tech) then
			ai.compDemand[tech] = true
			w[unitName] = 0
		end
	end

	-- Nightmare: jitter for unpredictability.
	if ai.isNightmare then
		for k, v in w do w[k] = v + math.random(0, 2) end
		if hasTech(ai, "EliteUnits") then w["Elite"] = (w["Elite"] or 0) + math.random(0, 3) end
	end

	local total = 0
	for _, v in w do total += v end
	if total <= 0 then w["Soldier"] = 1 end

	ai.currentWeights = w
end

-- ── Desired-state economy planner ──────────────────────────────────────────────

local function planEconomy(ai: any)
	local arche = ai.archetype
	local phase = ai.phase
	local reserve = ai.reserve

	-- The Bonfire (internal type "Deployer") is the AI's primary military structure now
	-- that the Barracks is gone — it free-summons the army and gates turrets/nests.
	local liveFound     = countOwnedBuildings(ai.ownerStr, "Foundry")
	local liveBarracks  = countOwnedBuildings(ai.ownerStr, "Deployer")
	local liveTurrets   = countOwnedBuildings(ai.ownerStr, "Turret")
	local liveRelays    = countOwnedBuildings(ai.ownerStr, "Relay")

	local econMult = (phase == "opening" and 0.5)
		or (phase == "expand" and 0.75)
		or (phase == "mid" and 1.0)
		or 1.25

	local wantFound = math.min(ai.caps.h, math.max(1, math.ceil(arche.desired.harvesters * econMult)))
	local wantBar  = (phase == "opening") and math.min(ai.caps.b, 1)
		or math.min(ai.caps.b, arche.desired.barracks)
	local wantTur  = math.min(ai.caps.t, math.max(0, math.ceil(arche.desired.turrets * econMult)))
	if arche.turtle and phase ~= "opening" then wantTur = math.min(ai.caps.t, arche.desired.turrets) end
	local wantRel  = (phase ~= "opening") and math.min(ai.caps.r, arche.desired.relays) or 0

	if ai.baseUnderAttack         then wantTur = math.min(ai.caps.t, wantTur + 1) end
	if ai.enemyUnitCount >= 5      then wantTur = math.min(ai.caps.t, wantTur + 1) end

	-- Defensive floor: every base keeps a turret line that grows through the game,
	-- so losing the field army never leaves the base wide open — even for aggressive
	-- archetypes whose `desired.turrets` is low.
	local turretFloor = (phase == "opening" and 1)
		or (phase == "expand" and 2)
		or (phase == "mid" and 3)
		or 4
	wantTur = math.min(ai.caps.t, math.max(wantTur, turretFloor))

	-- Priority-scored shopping list.
	local items: { { prio: number, cost: number, fn: () -> any } } = {}
	local function add(prio: number, cost: number, fn: () -> any)
		table.insert(items, { prio = prio, cost = cost, fn = fn })
	end

	if liveBarracks < 1 then
		add(100, Config.DEPLOYER_COST, function()
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Deployer", 15, 35) then
				ai.builtBarracks = math.max(ai.builtBarracks, 1); return true
			end
			return false
		end)
	end
	if ai.baseUnderAttack and liveTurrets < ai.caps.t then
		add(95, Config.TURRET_COST, function()
			return tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Turret", 18, 42)
		end)
	end
	if liveFound < wantFound then
		-- Foundry cost scales with how many we already own (matches BuildingManager).
		local foundryCost = Config.scaledBuildingCost(Config.FOUNDRY_COST, "Foundry", liveFound)
		add(90, foundryCost, function()
			-- Place the Foundry near base so its boost radius covers the seeded deposits.
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Foundry", 22, 48) then
				ai.builtMines += 1; return true
			end
			return false
		end)
	end
	-- Build-up bonfires (the from-zero case is the prio-100 item above).
	if liveBarracks >= 1 and liveBarracks < wantBar then
		add(80, Config.DEPLOYER_COST, function()
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Deployer", 15, 35) then
				ai.builtBarracks = math.max(ai.builtBarracks, liveBarracks + 1); return true
			end
			return false
		end)
	end
	if liveRelays < wantRel and hasTech(ai, "Relay") then
		add(60, Config.RELAY_COST, function()
			if tryPlaceRandom(ai.player, ai.base, "Relay", 45, 75) then ai.builtRelays += 1; return true end
			return false
		end)
	end
	if liveTurrets < wantTur then
		add(arche.turtle and 84 or 70, Config.TURRET_COST, function()
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Turret", 20, 45) then
				ai.builtTurrets = math.max(ai.builtTurrets, liveTurrets + 1); return true
			end
			return false
		end)
	end
	table.sort(items, function(a, b) return a.prio > b.prio end)

	-- Nightmare is deliberately unbound — buy everything affordable, top-down.
	if ai.isNightmare then
		for _, it in items do
			if resourceManager.get(ai.player) >= it.cost + reserve then it.fn() end
		end
		return
	end

	-- Everyone else builds like a human: only ONE structure under construction at a
	-- time, and at most one purchase per planning tick. Combined with the strategy
	-- cadence + each building's assembly time, this paces AI expansion to roughly
	-- the player's own build speed instead of a whole base appearing at once.
	if buildingManager.countConstructing and buildingManager.countConstructing(ai.player) > 0 then
		return
	end
	for _, it in items do
		if resourceManager.get(ai.player) >= it.cost + reserve then
			if it.fn() then break end
		end
	end
end

-- ── Tech & turret-upgrade planning ─────────────────────────────────────────────

local function planTech(ai: any)
	if not researchManager then return end

	-- Nightmare: grab the whole toolbox fast.
	if ai.isNightmare then
		for _, t in { "EliteUnits", "MedicUnit", "ConcussionShells", "RocketBarrage",
			"TurretUpgrades", "Relay", "CombatStims", "HardenedArmor", "Rollers" } do
			grantTechDeep(ai, t)
		end
		return
	end

	local tier = ai.techTier
	if tier <= 0 then return end

	-- Satisfy composition counters first (so the units we want unlock).
	if ai.compDemand then
		for tech in ai.compDemand do grantTechDeep(ai, tech) end
	end

	-- Walk the archetype tech plan, paced by how many units we've trained and
	-- limited in depth by the difficulty level.
	for i, tech in ipairs(ai.archetype.techPlan) do
		if i > tier then break end
		if ai.totalTrained >= (i - 1) * 2 then
			grantTechDeep(ai, tech)
		end
	end

	-- Enable turret upgrades once we actually have turrets to upgrade.
	if tier >= 2 and countOwnedBuildings(ai.ownerStr, "Turret") >= 1 then
		grantTech(ai.player, "TurretUpgrades")
	end
	-- Relay for build-zone expansion once we are scaling up.
	if tier >= 1 and ai.builtBarracks >= 2 then
		grantTech(ai.player, "Relay")
	end
end

local function planTurretUpgrades(ai: any)
	if not buildingManager.upgradeTurretForPlayer then return end
	if not hasTech(ai, "TurretUpgrades") then return end
	local pref = ai.archetype.turret or "RocketLauncher"
	local cost = (Config.TURRET_UPGRADE_COST :: any)[pref] or 999
	for _, tid in getOwnedBuildingIds(ai.ownerStr, "Turret") do
		if resourceManager.get(ai.player) < cost + ai.reserve then break end
		buildingManager.upgradeTurretForPlayer(ai.player, tid, pref)
	end
end

-- ── BT leaves ─────────────────────────────────────────────────────────────────

local function btBuildCC(ai: any)
	if ai.hasCC then return SUCCESS end
	local ok = buildingManager.placeForPlayer(ai.player, ai.base, "CommandCenter")
	if ok then ai.hasCC = true; return SUCCESS end
	return RUNNING
end

-- Trainer-only build-order starters (the strategic AI uses planEconomy instead).
local function btBuildFirstMine(ai: any)
	if countOwnedBuildings(ai.ownerStr, "Foundry") >= 1 then ai.builtMines = math.max(ai.builtMines, 1); return SUCCESS end
	if not canAfford(ai.player, Config.FOUNDRY_COST, 0) then return RUNNING end
	if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Foundry", 22, 48) then ai.builtMines += 1; return SUCCESS end
	return RUNNING
end

local function btBuildFirstBarracks(ai: any)
	-- "Barracks" is gone; the Bonfire (type "Deployer") is the AI's first military build.
	local live = countOwnedBuildings(ai.ownerStr, "Deployer")
	if live >= 1 then ai.builtBarracks = math.max(ai.builtBarracks, 1); return SUCCESS end
	if not canAfford(ai.player, Config.DEPLOYER_COST, ai.reserve) then return RUNNING end
	if tryPlaceRandom(ai.player, ai.base, "Deployer", 15, 35) then ai.builtBarracks += 1; return SUCCESS end
	return RUNNING
end

local function btUpdateVision(ai: any)
	local threats = scanThreats(ai)
	ai.enemyTurretCount = threats.enemyTurretCount
	ai.enemyUnitCount   = threats.enemyUnitCount
	ai.enemyArmyValue   = threats.enemyArmyValue
	ai.baseUnderAttack  = threats.baseUnderAttack
	ai.enemyComp        = threats.enemyComp
	ai.enemyHarvesters  = threats.enemyHarvesters

	if threats.priorityTarget then
		ai.lastKnownEnemyPos = threats.priorityTarget
		ai.lastEnemySeenTick = tick()
	elseif ai.lastKnownEnemyPos then
		if tick() - ai.lastEnemySeenTick > ai.enemyMemory then
			ai.lastKnownEnemyPos = nil
		end
	end
	ai.priorityTarget = threats.priorityTarget or ai.lastKnownEnemyPos
	return SUCCESS
end

-- The AI's army comes from FREE, capacity-limited bonfire auto-summon — the same rules
-- the player plays by. This just MANAGES the bonfires (it does NOT mass paid units like
-- the old training did, which defied the capacity cap): give each bonfire a varied summon
-- type, and empower them with surplus to scale capacity by difficulty.
local function btManageBonfires(ai: any)
	local ids = getOwnedBuildingIds(ai.ownerStr, "Deployer")
	if #ids == 0 then return FAILURE end

	-- Pace tech by peak army size now that nothing increments totalTrained directly.
	ai.totalTrained = math.max(ai.totalTrained, unitManager.getUnitCount(ai.player))

	-- Assign each bonfire a (composition-driven) summon type once → varied armies, not
	-- all-Soldier. Research-gated picks fall back to Soldier.
	ai.bonfireType = ai.bonfireType or {}
	for _, id in ids do
		if not ai.bonfireType[id] then
			local utype = (next(ai.currentWeights) ~= nil) and pickWeighted(ai.currentWeights) or "Soldier"
			local def   = Config.UNIT_TYPES[utype]
			if not def or (def.researchReq and not hasTech(ai, def.researchReq)) then utype = "Soldier" end
			if buildingManager.setBonfireSummonType and buildingManager.setBonfireSummonType(ai.player, id, utype) then
				ai.bonfireType[id] = utype
			end
		end
	end

	-- Empower with clear surplus, capped by difficulty. Gradual by design — the army
	-- still fills slowly through free auto-summon, so this never floods units.
	local cap = ai.bonfireEmpowerCap or 0
	if cap > 0 and buildingManager.upgradeBonfireForPlayer
		and resourceManager.get(ai.player) > ai.reserve * 2.5 then
		for _, id in ids do
			if buildingManager.upgradeBonfireForPlayer(ai.player, id, cap) then break end
		end
	end

	return SUCCESS
end

-- Wave archetype: turtle, then launch escalating timed all-ins on a clock.
local function waveCombat(ai: any, data: any, pts: { Vector3 })
	ai.waveTimer = (ai.waveTimer or 0) + ai.reactionInterval
	local interval = math.max(20, 55 - ai.wavesSent * 5)

	if ai.combatPhase == "gather" then
		local near = {}
		for i = 1, math.min(10, #pts) do near[i] = pts[i] end
		if #ai.mainForce > 0 then fanAcrossMap(ai, ai.mainForce, near, 4) end
		local pastPeace = (not ai.aggressionUnlockTime) or tick() >= ai.aggressionUnlockTime
		if pastPeace and ai.waveTimer >= interval and #data >= ai.minAtk and ai.priorityTarget then
			local target = pickAttackTarget(ai)
			if target then
				ai.attackTarget   = target
				ai.rallyPoint     = approachPoint(target, math.random() * math.pi * 2, 55 + math.random(0, 20))
				ai.combatPhase    = "staging"; ai.phaseTimer = 0
				ai.stageDuration  = math.random(ai.archetype.stageMin, ai.archetype.stageMax)
				ai.attackDuration = math.random(18, 35)
			end
		end
	elseif ai.combatPhase == "staging" then
		if ai.rallyPoint and #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.rallyPoint) end
		if not ai.attackTarget then
			ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.waveTimer = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			ai.combatPhase = "attack"; ai.phaseTimer = 0; ai.wavesSent += 1
		end
	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.waveTimer = 0; return SUCCESS end
		commitAttack(ai, data, target)
		if ai.phaseTimer >= ai.attackDuration then
			ai.combatPhase = "retreat"; ai.phaseTimer = 0; ai.retreatDuration = math.random(6, 12)
		end
	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.waveTimer = 0; ai.attackTarget = nil
		end
	end
	return SUCCESS
end

-- Value-based combat: maneuver until a target offers a favorable force trade,
-- commit, then retreat when the trade turns against us.
local function btCommandArmy(ai: any)
	local data     = unitManager.getPlayerUnitData(ai.player)
	local armySize = #data
	if armySize == 0 then return FAILURE end

	local myValue = 0
	for _, u in data do myValue += unitValue(u.unitType) end

	local pts            = ai.explorePoints
	local garrisonTarget = ai.baseUnderAttack and ai.base or snapGrid(ai.base + Vector3.new(0, 0, 18))

	if #ai.garrison > 0 then unitManager.sendUnitsTo(ai.player, ai.garrison, garrisonTarget) end
	updateScouts(ai, pts)
	updateHarass(ai)

	-- Snap home to defend.
	if ai.baseUnderAttack and ai.combatPhase ~= "defend" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if #ai.harass    > 0 then sendSpread(ai.player, ai.harass,    ai.base) end
		ai.combatPhase = "defend"; ai.phaseTimer = 0; ai.attackTarget = nil; ai.feintTarget = nil
		return SUCCESS
	end

	ai.phaseTimer += ai.reactionInterval

	if ai.combatPhase == "defend" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, garrisonTarget) end
		if not ai.baseUnderAttack then ai.combatPhase = "gather"; ai.phaseTimer = 0 end
		return SUCCESS
	end

	if ai.archetype.waveMode then return waveCombat(ai, data, pts) end

	local pastPeace = (not ai.aggressionUnlockTime) or tick() >= ai.aggressionUnlockTime

	if ai.combatPhase == "gather" then
		if #ai.mainForce > 0 then
			if pastPeace then
				-- Roam the full map, probing toward the enemy while looking for an opening.
				fanAcrossMap(ai, ai.mainForce, pts, 3)
				ai.exploreTimer += ai.reactionInterval
				if ai.exploreTimer >= 8 then ai.exploreTimer = 0; ai.exploreIdx = (ai.exploreIdx % #pts) + 1 end
			else
				-- Opening peace: the army stays home and patrols its OWN perimeter.
				-- Only the lone scout (and the shadowing harass squad) ranges out, so
				-- all the player sees is something lurking — never a column marching in.
				local home: { Vector3 } = {}
				for i = 1, math.min(8, #pts) do table.insert(home, pts[i]) end
				if #home > 0 then fanAcrossMap(ai, ai.mainForce, home, 4) end
			end
		end
		if pastPeace and ai.priorityTarget and armySize >= ai.minAtk then
			local target = pickAttackTarget(ai)
			if target then
				local enemyVal = enemyValueNear(ai.ownerStr, target, 70)
				if myValue >= enemyVal * ai.engageRatio then
					local approach   = math.random() * math.pi * 2
					ai.combatPhase   = "staging"; ai.phaseTimer = 0
					ai.attackTarget  = target
					ai.rallyPoint    = approachPoint(target, approach, 50 + math.random(0, 25))
					ai.stageDuration = math.random(ai.archetype.stageMin, ai.archetype.stageMax)
					ai.attackDuration = math.random(20, 45)
				end
			end
		end

	elseif ai.combatPhase == "staging" then
		if #ai.mainForce > 0 and ai.rallyPoint then sendSpread(ai.player, ai.mainForce, ai.rallyPoint) end
		if not ai.attackTarget then
			ai.combatPhase = "gather"; ai.phaseTimer = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			ai.combatPhase = "attack"; ai.phaseTimer = 0; ai.wavesSent += 1
			-- Competent bots sometimes flank a second target.
			ai.isFlankingAttack = ai.competence >= 0.7 and math.random() < 0.35 and #ai.mainForce >= 5
			if ai.isFlankingAttack then
				local c = findEnemyBuilding(ai.ownerStr, pickFrom({ "Deployer", "Turret", "Relay" }))
				ai.feintTarget = (c and c ~= ai.attackTarget) and c or nil
				if not ai.feintTarget then ai.isFlankingAttack = false end
			end
		end

	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then ai.combatPhase = "gather"; ai.phaseTimer = 0; return SUCCESS end
		commitAttack(ai, data, target)
		local enemyVal = enemyValueNear(ai.ownerStr, target, 70)
		if myValue < enemyVal * RETREAT_RATIO or ai.phaseTimer >= ai.attackDuration then
			ai.combatPhase = "retreat"; ai.phaseTimer = 0
			ai.feintTarget = nil; ai.isFlankingAttack = false
			ai.retreatDuration = math.random(8, 18)
		end

	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.attackTarget = nil; ai.rallyPoint = nil
		end
	end

	return SUCCESS
end

-- ── Phase model ───────────────────────────────────────────────────────────────

local function getPhase(ai: any): string
	local t    = tick() - ai.startTime
	local army = unitManager.getUnitCount(ai.player)
	local p
	if t < 35 then p = "opening"
	elseif t < 110 then p = "expand"
	elseif t < 260 then p = "mid"
	else p = "late" end

	if army >= 18 and p ~= "late" then p = "late"
	elseif army >= 10 and (p == "opening" or p == "expand") then p = "mid" end

	if ai.isNightmare and p ~= "late" then
		p = (p == "opening" and "expand") or (p == "expand" and "mid") or "late"
	end
	return p
end

-- ── Nightmare scaling ───────────────────────────────────────────────────────
-- Starts ~level-3 strength and grows unbound. Overwrites the mutable knobs each
-- tick using exponential time scaling, and keeps the coffers full.

local function applyNightmareScaling(ai: any)
	local elapsed = tick() - ai.startTime
	local scale   = math.exp(elapsed / 90)

	ai.maxUnits  = 999
	ai.caps      = {
		h = math.ceil(3 * scale), b = math.ceil(2 * scale),
		t = math.ceil(2 * scale), r = math.max(1, math.ceil(scale - 0.5)),
	}
	ai.strategyInterval = math.max(0.5, 6.0 / math.sqrt(scale))
	ai.reactionInterval = math.max(0.2, 1.2 / math.sqrt(scale))
	ai.minAtk       = math.max(1, math.floor(4 / scale))
	ai.garrisonRatio = math.max(0.02, 0.12 / scale)
	ai.reserveBase  = 0
	ai.techTier     = 4

	local current = resourceManager.get(ai.player)
	if current < 9999 then resourceManager.add(ai.player, 9999 - current) end
end

-- ── Swarm gamemode ──────────────────────────────────────────────────────────

local function swarmCaps(level: number): (number, number, number)
	if level <= 1 then return 1, 0, 1
	elseif level == 2 then return 1, 1, 2
	elseif level == 3 then return 2, 1, 2
	elseif level == 4 then return 3, 2, 3
	else return 4, 3, 4 end
end

local function swarmStrategyTree(ai: any)
	if ai.isNightmare then
		local current = resourceManager.get(ai.player)
		if current < 9999 then resourceManager.add(ai.player, 9999 - current) end
	end

	if btBuildCC(ai) ~= SUCCESS then return end

	if not ai.swarmTechGranted then
		ai.swarmTechGranted = true
		grantTech(ai.player, "CreepyBlob")
	end

	local maxNests, maxBlobs, maxMines = swarmCaps(ai.level)
	if ai.isNightmare then maxNests += 2; maxBlobs += 2 end

	local liveMines = countOwnedBuildings(ai.ownerStr, "Foundry")
	local foundryCost = Config.scaledBuildingCost(Config.FOUNDRY_COST, "Foundry", liveMines)
	if liveMines < maxMines and canAfford(ai.player, foundryCost, ai.reserve) then
		if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Foundry", 22, 48) then
			ai.builtMines += 1
		end
	end

	local liveNests = countOwnedBuildings(ai.ownerStr, "LampreyNest")
	if liveNests < maxNests and canAfford(ai.player, Config.LAMPREY_NEST_COST, ai.reserve) then
		tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "LampreyNest", 15, 45)
	end

	local liveBlobs = countOwnedBuildings(ai.ownerStr, "CreepyBlob")
	if liveBlobs < maxBlobs and canAfford(ai.player, Config.CREEPY_BLOB_COST, ai.reserve) then
		tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "CreepyBlob", 15, 45)
	end

	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai)
		ai.lastSquadCount = currentCount
	end
end

local function btProduceSwarm(ai: any)
	if unitManager.getUnitCount(ai.player) >= ai.maxUnits then return end

	for _, nestId in getOwnedBuildingIds(ai.ownerStr, "LampreyNest") do
		-- Once the swarm can afford one, occasionally commit to a heavy Broodmother;
		-- otherwise keep alternating the cheap Lamprey/Hagfish swarm.
		local kind: string
		if canAfford(ai.player, Config.BROODMOTHER_EGG_COST, ai.reserve) and math.random() < 0.18 then
			kind = "Broodmother"
		else
			ai.swarmEggToggle = not ai.swarmEggToggle
			kind = if ai.swarmEggToggle then "Lamprey" else "Hagfish"
		end
		local cost = if kind == "Hagfish" then Config.HAGFISH_EGG_COST
			elseif kind == "Broodmother" then Config.BROODMOTHER_EGG_COST
			else Config.LAMPREY_EGG_COST
		if canAfford(ai.player, cost, ai.reserve) then
			buildingManager.requestNestEgg(ai.player, nestId, kind)
		end
	end

	for _, blobId in getOwnedBuildingIds(ai.ownerStr, "CreepyBlob") do
		if canAfford(ai.player, Config.BLOB_SOLDIER_COST, ai.reserve) then
			buildingManager.requestBlobSoldier(ai.player, blobId)
		end
	end
end

-- ── Trainer personality ──────────────────────────────────────────────────────
--[[
	Teaching opponent. Mirrors the human's economy/army (with lag), probes in
	partial-commitment waves with long cool-offs, gives ground when the player is
	expanding, never wins, and concedes after the player kills ≥8 trainer units OR
	destroys ≥2 trainer buildings (or after 7 minutes).
--]]

local function trainerStrategyTree(ai: any)
	ai.phase   = getPhase(ai)
	ai.reserve = math.floor(ai.reserveBase * ai.archetype.reserveMult)

	local playerMines    = buildingManager.getHumanBuildingCount("Foundry")
	local playerBarracks = countHumanBuildings("Deployer")
	local playerAllBld   = countHumanBuildings("any")
	local playerArmy     = countHumanArmy()

	ai.caps.h   = math.clamp(playerMines,    1, 2)
	ai.caps.b   = math.clamp(playerBarracks, 1, 2)
	ai.caps.t   = 1
	ai.caps.r   = 0
	ai.maxUnits = math.clamp(playerArmy + math.random(1, 2), 4, 14)

	local playerBldGrew = playerAllBld > (ai.trainerLastBldCount or 0)
	ai.trainerLastBldCount = playerAllBld
	if playerBldGrew then
		ai.trainerWaveInterval = math.max(ai.trainerWaveInterval, 70)
	end

	local ownBldNow = countAllOwnedBuildings(ai.ownerStr)
	if ownBldNow < (ai.trainerLastOwnBldCount or 0) then
		ai.trainerBldLost += (ai.trainerLastOwnBldCount - ownBldNow)
	end
	ai.trainerLastOwnBldCount = ownBldNow

	if not ai.trainerConceded then
		local elapsed = tick() - ai.startTime
		if ai.trainerUnitsLost >= 8 or ai.trainerBldLost >= 2 or elapsed >= 420 then
			ai.trainerConceded = true
			ai.trainerMode     = "concede"
			print("[Trainer] Conceding — unitsLost:", ai.trainerUnitsLost,
				"bldLost:", ai.trainerBldLost, "elapsed:", math.floor(elapsed) .. "s")
		end
	end

	if ai.trainerMode == "shadow" and ai.wavesSent >= 1 then ai.trainerMode = "press" end

	if btBuildCC(ai) ~= SUCCESS then return end
	btBuildFirstMine(ai)
	btBuildFirstBarracks(ai)

	if ai.trainerConceded then
		local currentCount = unitManager.getUnitCount(ai.player)
		if currentCount ~= ai.lastSquadCount then
			rebuildSquads(ai); ai.lastSquadCount = currentCount
		end
		return
	end

	local liveMines    = countOwnedBuildings(ai.ownerStr, "Foundry")
	local liveBarracks = countOwnedBuildings(ai.ownerStr, "Deployer")
	local liveTurrets  = countOwnedBuildings(ai.ownerStr, "Turret")

	if liveBarracks < math.min(ai.caps.b, ai.builtBarracks) then
		if canAfford(ai.player, Config.DEPLOYER_COST, ai.reserve) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Deployer", 15, 35) then ai.builtBarracks += 1 end
		end
	end
	if liveMines < ai.caps.h then
		if canAfford(ai.player, Config.FOUNDRY_COST, ai.reserve) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Foundry", 22, 48) then ai.builtMines += 1 end
		end
	end
	if liveBarracks < ai.caps.b then
		if canAfford(ai.player, Config.DEPLOYER_COST, ai.reserve) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Deployer", 15, 35) then
				ai.builtBarracks = math.max(ai.builtBarracks, liveBarracks + 1)
			end
		end
	end
	if liveTurrets < 1 then
		if canAfford(ai.player, Config.TURRET_COST, ai.reserve) then
			if tryPlaceAnywhere(ai.player, ai.ownerStr, ai.base, "Turret", 20, 40) then
				ai.builtTurrets = math.max(ai.builtTurrets, 1)
			end
		end
	end

	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai); ai.lastSquadCount = currentCount
	end
	computeComposition(ai)
end

local function btCommandArmyTrainer(ai: any)
	local armySize = unitManager.getUnitCount(ai.player)
	if armySize == 0 then return FAILURE end

	local garrisonTarget = ai.baseUnderAttack and ai.base or snapGrid(ai.base + Vector3.new(0, 0, 18))
	if #ai.garrison > 0 then unitManager.sendUnitsTo(ai.player, ai.garrison, garrisonTarget) end

	if ai.trainerConceded then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if #ai.garrison  > 0 then unitManager.sendUnitsTo(ai.player, ai.garrison, ai.base) end
		ai.combatPhase = "gather"
		return SUCCESS
	end

	if ai.baseUnderAttack and ai.combatPhase ~= "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		ai.combatPhase = "retreat"; ai.phaseTimer = 0
		ai.retreatDuration  = math.random(20, 35)
		ai.trainerWaveTimer = 0
		return SUCCESS
	end

	ai.phaseTimer += ai.reactionInterval

	if ai.combatPhase == "gather" then
		ai.trainerWaveTimer += ai.reactionInterval
		local pts = ai.explorePoints
		local nearPts: { Vector3 } = {}
		for i = 1, math.min(8, #pts) do table.insert(nearPts, pts[i]) end
		if #ai.mainForce > 0 and #nearPts > 0 then
			ai.exploreTimer += ai.reactionInterval
			if ai.exploreTimer >= 10 then ai.exploreTimer = 0; ai.exploreIdx = (ai.exploreIdx % #nearPts) + 1 end
			fanAcrossMap(ai, ai.mainForce, nearPts, 3)
		end

		local pastPeace = (not ai.aggressionUnlockTime) or tick() >= ai.aggressionUnlockTime
		if pastPeace and ai.trainerWaveTimer >= ai.trainerWaveInterval and armySize >= ai.minAtk and ai.priorityTarget then
			local target = pickAttackTarget(ai)
			if target then
				ai.attackTarget   = target
				ai.rallyPoint     = approachPoint(target, math.random() * math.pi * 2, 60 + math.random(0, 20))
				ai.combatPhase    = "staging"; ai.phaseTimer = 0
				ai.stageDuration  = math.random(5, 10)
				ai.attackDuration = math.random(10, 16)
				ai.retreatDuration = math.random(20, 40)
				ai.trainerAttackStartArmy = armySize
			end
		end

	elseif ai.combatPhase == "staging" then
		if #ai.mainForce > 0 and ai.rallyPoint then sendSpread(ai.player, ai.mainForce, ai.rallyPoint) end
		if not ai.attackTarget then
			ai.combatPhase = "gather"; ai.phaseTimer = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			ai.combatPhase = "attack"; ai.phaseTimer = 0; ai.wavesSent += 1
		end

	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then ai.combatPhase = "retreat"; ai.phaseTimer = 0; return SUCCESS end

		local n           = #ai.mainForce
		local commitRatio = 0.50 + math.random() * 0.10
		local commitCount = math.max(1, math.floor(n * commitRatio))
		local commitChunk, holdChunk = {}, {}
		for i, id in ai.mainForce do
			if i <= commitCount then table.insert(commitChunk, id) else table.insert(holdChunk, id) end
		end
		sendSpread(ai.player, commitChunk, target)
		if ai.rallyPoint and #holdChunk > 0 then sendSpread(ai.player, holdChunk, ai.rallyPoint) end

		if ai.phaseTimer >= ai.attackDuration then
			ai.trainerUnitsLost += math.max(0, ai.trainerAttackStartArmy - armySize)
			ai.combatPhase = "retreat"; ai.phaseTimer = 0
		end

	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai.player, ai.mainForce, ai.base) end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.attackTarget = nil; ai.rallyPoint = nil
			local playerArmy    = countHumanArmy()
			local playerGrowing = playerArmy > (ai.trainerLastPlayerArmy or 0)
			ai.trainerWaveInterval   = playerGrowing and math.random(60, 90) or math.random(40, 65)
			ai.trainerLastPlayerArmy = playerArmy
			ai.trainerWaveTimer      = 0
		end
	end

	return SUCCESS
end

local function trainerReactionTree(ai: any)
	btUpdateVision(ai)
	if not ai.trainerConceded then btManageBonfires(ai) end
	btCommandArmyTrainer(ai)
end

-- ── Top-level trees ───────────────────────────────────────────────────────────

local function strategyTree(ai: any)
	if ai.swarm then swarmStrategyTree(ai); return end
	if ai.personality == "trainer" then trainerStrategyTree(ai); return end
	if ai.isNightmare then applyNightmareScaling(ai) end

	if btBuildCC(ai) ~= SUCCESS then return end

	ai.phase   = getPhase(ai)
	ai.reserve = math.floor(ai.reserveBase * ai.archetype.reserveMult)

	planEconomy(ai)

	local count = unitManager.getUnitCount(ai.player)
	if count ~= ai.lastSquadCount then rebuildSquads(ai); ai.lastSquadCount = count end

	computeComposition(ai)
	planTech(ai)
	planTurretUpgrades(ai)
end

local function reactionTree(ai: any)
	if ai.swarm then
		btUpdateVision(ai); btProduceSwarm(ai); btCommandArmy(ai); return
	end
	if ai.personality == "trainer" then trainerReactionTree(ai); return end
	if ai.isNightmare then applyNightmareScaling(ai) end
	btUpdateVision(ai)
	btManageBonfires(ai)
	btCommandArmy(ai)
end

-- ── Identity assignment ───────────────────────────────────────────────────────

local function applyLevel(ai: any, level: number)
	local L = LEVELS[math.clamp(level, 1, 5)]
	ai.maxUnits        = L.maxUnits
	ai.caps            = { h = L.hcap, b = L.bcap, t = L.tcap, r = L.rcap }
	ai.reserveBase     = L.reserve
	ai.reserve         = L.reserve
	ai.strategyInterval = L.strat
	ai.reactionInterval = L.react
	ai.visionRadius    = L.vision
	ai.enemyMemory     = L.mem
	ai.minAtk          = L.minAtk
	ai.techTier        = L.techTier
	ai.competence      = L.competence
	ai.firstStrike     = L.firstStrike
	-- How far the bot will Empower its bonfires (capacity scaling). Gentle: Easy never
	-- upgrades, Medium tops out at +2, up to +4 at the highest tier.
	ai.bonfireEmpowerCap = math.max(0, level - 1)
end

-- When the bot is first allowed to commit its main army, and when the harassment
-- squad may begin hunting. Re-anchored to `startTime` so resets pace fresh. The
-- opening before this is deliberately quiet: scouts lurk, the army holds home.
local function applyAggressionWindow(ai: any)
	local fs = ai.firstStrike or 140
	-- ±15% jitter so the first push never lands on a predictable clock.
	fs = fs * (0.85 + math.random() * 0.30)
	ai.aggressionUnlockTime = ai.startTime + fs
	ai.harassUnlockTime     = ai.startTime + fs * 0.55
end

local function assignArchetype(ai: any)
	local arche
	if ai.swarm then arche = ARCHETYPES.Swarm
	elseif ai.personality == "trainer" then arche = ARCHETYPES.Trainer
	elseif ai.personality == "territorial" then arche = ARCHETYPES.Defender
	elseif ai.personality == "waves" then arche = ARCHETYPES.Waves
	elseif ai.personality == "nightmare" then arche = ARCHETYPES[pickFrom(NIGHTMARE_ROLL)]
	else arche = ARCHETYPES[pickFrom(BALANCED_ROLL)] end

	ai.archetype     = arche
	ai.engageRatio   = arche.engageRatio
	ai.garrisonRatio = arche.garrison
end

-- ── Public API ────────────────────────────────────────────────────────────────

function AIManager.init(um, bm, rm)
	unitManager     = um
	buildingManager = bm
	resourceManager = rm
end

function AIManager.setResearchManager(rm: any)
	researchManager = rm
end

function AIManager.setSwarmMode(on: boolean)
	swarmMode = on and true or false
end

function AIManager.resetBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end

	-- Re-roll level + archetype so a rebuilt bot plays fresh.
	applyLevel(ai, ai.level)
	assignArchetype(ai)

	ai.hasCC             = false
	ai.swarmTechGranted  = false
	ai.swarmEggToggle    = false
	ai.builtMines        = 0
	ai.builtBarracks     = 0
	ai.builtTurrets      = 0
	ai.builtRelays       = 0
	ai.trainedSoldiers   = 0
	ai.trainedTanks      = 0
	ai.totalTrained      = 0
	ai.bonfireType       = {}
	ai.lastKnownEnemyPos = nil
	ai.lastEnemySeenTick = 0
	ai.priorityTarget    = nil
	ai.enemyTurretCount  = 0
	ai.enemyUnitCount    = 0
	ai.enemyArmyValue    = 0
	ai.baseUnderAttack   = false
	ai.enemyComp         = {}
	ai.enemyHarvesters   = {}
	ai.compDemand        = {}
	ai.mainForce         = {}
	ai.garrison          = {}
	ai.scouts            = {}
	ai.harass            = {}
	ai.currentWeights    = {}
	ai.phase             = "opening"
	ai.exploreIdx        = 1
	ai.exploreTimer      = 0
	ai.scoutIdx          = math.floor(#ai.explorePoints * 0.6) + 1
	ai.scoutTimer        = 0
	ai.scoutState        = nil
	ai.scoutDwell        = 0
	ai.scoutAngle        = 0
	ai.scoutPoint        = nil
	ai.harassTimer       = 0
	ai.harassTarget      = nil
	ai.lastSquadCount    = 0
	ai.combatPhase       = "gather"
	ai.phaseTimer        = 0
	ai.attackTarget      = nil
	ai.rallyPoint        = nil
	ai.feintTarget       = nil
	ai.isFlankingAttack  = false
	ai.stageDuration     = 12
	ai.attackDuration    = 25
	ai.retreatDuration   = 15
	ai.waveTimer         = 0
	ai.wavesSent         = 0
	ai.strategyTimer     = ai.strategyInterval
	ai.reactionTimer     = ai.reactionInterval
	ai.startTime         = tick()
	applyAggressionWindow(ai)
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
	print(string.format("[AIManager] Bot %d reset → %s", userId, ai.archetype.label))
end

function AIManager.resetAllBots()
	takenBaseIdx = {}
	for userId in botByUserId do
		AIManager.resetBot(userId)
	end
end

local function pickBestBase(): (Vector3, number)
	local existingCCPositions: { Vector3 } = {}
	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local tv = model:FindFirstChild("BuildingType")
			if tv and tv.Value == "CommandCenter" then
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then table.insert(existingCCPositions, Vector3.new(base.Position.X, 0, base.Position.Z)) end
			end
		end
	end
	for idx, taken in takenBaseIdx do
		if taken then
			local c = AI_BASES[idx]
			table.insert(existingCCPositions, Vector3.new(c.X, 0, c.Z))
		end
	end

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
		if minDist > bestScore then bestScore = minDist; bestIdx = i end
	end
	if bestIdx == -1 then
		for i in AI_BASES do if not takenBaseIdx[i] then bestIdx = i; break end end
	end
	if bestIdx == -1 then bestIdx = ((aiCounter - 1) % #AI_BASES) + 1 end

	takenBaseIdx[bestIdx] = true
	return AI_BASES[bestIdx], bestIdx
end

function AIManager.spawnAI(personality: string, level: number, baseOverride: Vector3?): boolean
	personality = tostring(personality):lower()
	level       = math.clamp(math.floor(tonumber(level) or 3), 1, 5)

	if not VALID_PERSONALITIES[personality] then
		warn("[AIManager] Unknown personality:", personality, "— use balanced / territorial / waves / nightmare / trainer")
		return false
	end

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
	team.TeamColor      = AI_COLORS[colorIdx]
	team.AutoAssignable = false
	team.Parent         = Teams

	local aiPlayer = {
		UserId    = -aiCounter,
		TeamColor = AI_COLORS[colorIdx],
		Team      = team,
		Name      = "AI_" .. aiCounter,
		Parent    = workspace,
		isSwarm   = swarmMode,   -- swarm-mode AIs get a distinct black spike command center
	}

	resourceManager.add(aiPlayer, Config.STARTING_RESOURCES)

	local ai: any = {
		player      = aiPlayer,
		ownerStr    = tostring(aiPlayer.UserId),
		base        = base,
		personality = personality,
		level       = personality == "nightmare" and 5 or personality == "trainer" and 1 or level,
		isNightmare = personality == "nightmare",

		swarm            = swarmMode,
		swarmTechGranted = false,
		swarmEggToggle   = false,

		hasCC = false,

		builtMines    = 0,
		builtBarracks = 0,
		builtTurrets  = 0,
		builtRelays   = 0,

		trainedSoldiers = 0,
		trainedTanks    = 0,
		totalTrained    = 0,

		lastKnownEnemyPos = nil,
		lastEnemySeenTick = 0,
		priorityTarget    = nil,

		enemyTurretCount = 0,
		enemyUnitCount   = 0,
		enemyArmyValue   = 0,
		baseUnderAttack  = false,
		enemyComp        = {},
		enemyHarvesters  = {},
		compDemand       = {},

		mainForce = {},
		garrison  = {},
		scouts    = {},
		harass    = {},

		currentWeights = {},
		phase          = "opening",

		explorePoints = generateExplorePoints(base),
		exploreIdx    = 1,
		exploreTimer  = 0,

		scoutIdx   = 0,
		scoutTimer = 0,
		scoutState = nil,
		scoutDwell = 0,
		scoutAngle = 0,
		scoutPoint = nil,

		harassTimer  = 0,
		harassTarget = nil,

		lastSquadCount = 0,

		combatPhase      = "gather",
		phaseTimer       = 0,
		attackTarget     = nil,
		rallyPoint       = nil,
		feintTarget      = nil,
		isFlankingAttack = false,
		stageDuration    = 12,
		attackDuration   = 25,
		retreatDuration  = 15,
		waveTimer        = 0,
		wavesSent        = 0,

		startTime = tick(),

		trainerMode            = "shadow",
		trainerWaveTimer       = 0,
		trainerWaveInterval    = 60,
		trainerUnitsLost       = 0,
		trainerBldLost         = 0,
		trainerAttackStartArmy = 0,
		trainerLastBldCount    = 0,
		trainerLastOwnBldCount = 0,
		trainerLastPlayerArmy  = 0,
		trainerConceded        = false,
	}

	applyLevel(ai, ai.level)
	assignArchetype(ai)
	applyAggressionWindow(ai)

	ai.strategyTimer = ai.strategyInterval
	ai.reactionTimer = ai.reactionInterval
	ai.scoutIdx      = math.floor(#ai.explorePoints * 0.6) + 1

	team.Name = string.format("AI [%s/%s lv%d] %d", personality, ai.archetype.label, ai.level, aiCounter)

	botByUserId[aiPlayer.UserId] = ai

	task.spawn(function()
		while true do
			local dt = task.wait(0.5)
			ai.strategyTimer += dt
			ai.reactionTimer += dt

			if ai.strategyTimer >= ai.strategyInterval then
				ai.strategyTimer = 0
				local ok, err = pcall(strategyTree, ai)
				if not ok then warn("[AIManager] strategy error:", err) end
			end
			if ai.reactionTimer >= ai.reactionInterval then
				ai.reactionTimer = 0
				local ok, err = pcall(reactionTree, ai)
				if not ok then warn("[AIManager] reaction error:", err) end
			end
		end
	end)

	print(string.format("[AIManager] Spawned %s AI (%s) lv%d #%d at %s",
		personality, ai.archetype.label, ai.level, aiCounter, tostring(base)))
	return true
end

return AIManager
