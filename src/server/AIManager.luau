--[[
	AIManager v6 — Honest Commander.

	Ground-up rewrite with one rule: the AI plays by EXACTLY the player ruleset,
	StarCraft-style. Difficulty changes only intelligence, never the rules.

	Same rules as a player:
	  • ECONOMY — starts with STARTING_RESOURCES, earns only CC passive income and
	    Foundry income (its base is seeded with the same 5 deposits a player gets).
	    Every purchase goes through the same cost/validation paths players use.
	    No resource grants — not even on Nightmare.
	  • BUILDINGS — placed via BuildingManager.placeForPlayer: same costs, build
	    times, build-zone limits, and prerequisites (Foundry → Bonfire → Turret /
	    Engineering Post; Relay & CreepyBlob research-gated).
	  • RESEARCH — earns condition unlocks (build/kill/summon counts) and runs the
	    same 30-second timed researches through ResearchManager.requestUpgrade,
	    honoring the per-category concurrency cap. No instant grants.
	  • ENGINEERING POST — builds one and pays for Light researches like a player,
	    collecting random stat upgrades on the same 30 s timer.
	  • ARMY — free capacity-limited Bonfire auto-summon (same as the player),
	    scaled only by paid Empowers; paid Survivor → Sniper field upgrades; paid
	    turret upgrade paths. Armies attack-move like a player's would.
	  • VISION — sees through the same fog radii the player's FogManager uses
	    (units 65, per-building VISION_RADIUS). Anything else is remembered intel
	    that goes stale. No wallhacks.

	What difficulty (1-5) actually scales: decision cadence, intel memory, micro
	quality (flanks, siege standoff, value-read accuracy), spending discipline,
	scouting diligence, macro ambition, aggression timing, and whether the bot
	will push a Monument win when dominant. Nightmare is a level-5 brain with
	relentless pacing — still on a player's economy.

	Per-game STYLES (Assault / Siege / Fortress / Waves) keep same-difficulty bots
	from playing identically. The horror pacing is preserved: an opening peace
	window (firstStrike) where the bot only economizes, and fog-edge lurker scouts.

	Chat command: /ai balanced|territorial|waves|nightmare|trainer [1-5]
--]]

local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local SpawnPoints       = require(script.Parent:WaitForChild("SpawnPoints"))

local AIManager = {}

-- ── Difficulty levels: intelligence knobs ONLY (no rule changes) ──────────────
-- strat/react: seconds between macro / micro thinking ticks
-- mem:         seconds intel about unseen enemies is trusted before it goes stale
-- micro:       0..1 decision quality — value-read accuracy, flanks, standoffs
-- spend:       0..1 chance per opportunity the bot remembers to spend surplus
-- ambition:    multiplier on the style's structure targets (a cautious beginner
--              simply builds less; a strong player builds the full base)
-- empower:     how deep it will Empower bonfires (bank pays every level)
-- techDepth:   how far down its research priority list it bothers to go
-- firstStrike: opening peace window before the first committed assault
type Level = {
	strat: number, react: number, mem: number,
	micro: number, spend: number, scouts: number, harass: boolean,
	minAtk: number, ambition: number, empower: number, techDepth: number,
	firstStrike: number, monument: boolean,
}

local LEVELS: { Level } = {
	{ strat = 10.0, react = 2.4, mem = 20,  micro = 0.35, spend = 0.35, scouts = 1, harass = false, minAtk = 4, ambition = 0.70, empower = 1,  techDepth = 2, firstStrike = 210, monument = false },
	{ strat = 8.0,  react = 2.0, mem = 40,  micro = 0.50, spend = 0.55, scouts = 1, harass = false, minAtk = 5, ambition = 0.85, empower = 3,  techDepth = 3, firstStrike = 175, monument = false },
	{ strat = 6.5,  react = 1.5, mem = 75,  micro = 0.70, spend = 0.75, scouts = 1, harass = true,  minAtk = 5, ambition = 1.00, empower = 6,  techDepth = 5, firstStrike = 145, monument = false },
	{ strat = 5.0,  react = 1.1, mem = 130, micro = 0.85, spend = 0.90, scouts = 2, harass = true,  minAtk = 6, ambition = 1.15, empower = 10, techDepth = 7, firstStrike = 115, monument = true  },
	{ strat = 4.0,  react = 0.8, mem = 240, micro = 1.00, spend = 1.00, scouts = 2, harass = true,  minAtk = 6, ambition = 1.30, empower = 20, techDepth = 9, firstStrike = 90,  monument = true  },
}

local RETREAT_RATIO = 0.45  -- pull back when myValue < enemyLocalValue * this

-- ── Play styles (rolled per game; all honest, just different plans) ───────────
-- targets:  structure counts the style works toward (scaled by phase + ambition)
-- comp:     per-phase bonfire summon weights (counters layer on top)
-- techOrder: research priority (requestUpgrade no-ops until conditions are met)
type Style = {
	label: string,
	targets: { foundries: number, bonfires: number, turrets: number, relays: number, posts: number },
	comp: { [string]: { [string]: number } },
	techOrder: { string },
	turret: string,
	engageRatio: number,
	garrison: number,
	stageMin: number, stageMax: number,
	harass: boolean,
	waveMode: boolean,
	turtle: boolean,
	reserveMult: number,
	commitRatio: number,
	atkCooldownMin: number, atkCooldownMax: number,
}

local STYLES: { [string]: Style } = {
	Assault = {
		label = "Assault",
		targets = { foundries = 2, bonfires = 3, turrets = 2, relays = 1, posts = 1 },
		comp = {
			opening = { Survivor = 4 },
			expand  = { Survivor = 4, Tank = 1 },
			mid     = { Survivor = 3, Elite = 2, Tank = 1, Foamer = 1 },
			late    = { Survivor = 2, Elite = 3, Tank = 2, Foamer = 1, Medic = 1 },
		},
		techOrder = { "EliteUnits", "ConcussionShells", "MedicUnit", "TurretUpgrades", "Relay", "RocketBarrage", "BetterMines" },
		turret = "Flamethrower",
		engageRatio = 0.95, garrison = 0.20, stageMin = 3, stageMax = 8,
		harass = true, waveMode = false, turtle = false,
		reserveMult = 0.7, commitRatio = 1.0, atkCooldownMin = 0, atkCooldownMax = 0,
	},
	Siege = {
		label = "Siege",
		targets = { foundries = 3, bonfires = 3, turrets = 3, relays = 2, posts = 1 },
		comp = {
			opening = { Survivor = 3 },
			expand  = { Survivor = 2, Tank = 2 },
			mid     = { Tank = 3, Howitzer = 2, Survivor = 1, Medic = 1 },
			late    = { Tank = 3, Howitzer = 3, Elite = 1, Medic = 1 },
		},
		techOrder = { "ConcussionShells", "EliteUnits", "TurretUpgrades", "MedicUnit", "Relay", "RocketBarrage", "BetterMines" },
		turret = "Artillery",
		engageRatio = 1.15, garrison = 0.30, stageMin = 8, stageMax = 16,
		harass = false, waveMode = false, turtle = false,
		reserveMult = 1.1, commitRatio = 1.0, atkCooldownMin = 0, atkCooldownMax = 0,
	},
	Fortress = {
		label = "Fortress",
		targets = { foundries = 3, bonfires = 3, turrets = 6, relays = 2, posts = 1 },
		comp = {
			opening = { Survivor = 3 },
			expand  = { Survivor = 3, Foamer = 1 },
			mid     = { Survivor = 2, Foamer = 2, Howitzer = 1, Tank = 1 },
			late    = { Howitzer = 2, Foamer = 2, Tank = 2, Elite = 2, Medic = 1 },
		},
		techOrder = { "TurretUpgrades", "ConcussionShells", "EliteUnits", "MedicUnit", "Relay", "Trapper", "BetterMines" },
		turret = "Artillery",
		engageRatio = 1.35, garrison = 0.45, stageMin = 10, stageMax = 18,
		harass = false, waveMode = false, turtle = true,
		reserveMult = 1.3, commitRatio = 1.0, atkCooldownMin = 0, atkCooldownMax = 0,
	},
	Waves = {
		label = "Waves",
		targets = { foundries = 3, bonfires = 3, turrets = 3, relays = 1, posts = 1 },
		comp = {
			opening = { Survivor = 4 },
			expand  = { Survivor = 3, Tank = 1 },
			mid     = { Survivor = 2, Tank = 3, Elite = 1 },
			late    = { Tank = 3, Howitzer = 2, Elite = 2, Foamer = 1 },
		},
		techOrder = { "EliteUnits", "ConcussionShells", "TurretUpgrades", "Relay", "RocketBarrage", "MedicUnit", "BetterMines" },
		turret = "RocketLauncher",
		engageRatio = 0.95, garrison = 0.30, stageMin = 4, stageMax = 10,
		harass = false, waveMode = true, turtle = false,
		reserveMult = 1.0, commitRatio = 1.0, atkCooldownMin = 0, atkCooldownMax = 0,
	},
	-- Teaching opponent: tiny base, partial-commitment pokes with long cool-offs.
	Trainer = {
		label = "Trainer",
		targets = { foundries = 2, bonfires = 1, turrets = 1, relays = 0, posts = 0 },
		comp = {
			opening = { Survivor = 3 },
			expand  = { Survivor = 3, Tank = 1 },
			mid     = { Survivor = 3, Tank = 1 },
			late    = { Survivor = 3, Tank = 1, Foamer = 1 },
		},
		techOrder = {},
		turret = "Flamethrower",
		engageRatio = 1.6, garrison = 0.35, stageMin = 6, stageMax = 10,
		harass = false, waveMode = false, turtle = true,
		reserveMult = 1.0, commitRatio = 0.55, atkCooldownMin = 45, atkCooldownMax = 90,
	},
	-- Swarm gamemode: combat knobs only (production runs through the swarm brain).
	Swarm = {
		label = "Swarm",
		targets = { foundries = 4, bonfires = 0, turrets = 0, relays = 0, posts = 0 },
		comp = { opening = { Survivor = 1 }, expand = { Survivor = 1 }, mid = { Survivor = 1 }, late = { Survivor = 1 } },
		techOrder = {},
		turret = "Flamethrower",
		engageRatio = 0.8, garrison = 0.12, stageMin = 3, stageMax = 7,
		harass = true, waveMode = false, turtle = false,
		reserveMult = 1.0, commitRatio = 1.0, atkCooldownMin = 0, atkCooldownMax = 0,
	},
}

local BALANCED_ROLL  = { "Assault", "Siege", "Fortress" }
local NIGHTMARE_ROLL = { "Assault", "Siege", "Fortress", "Waves" }

local VALID_PERSONALITIES = { balanced = true, territorial = true, waves = true, nightmare = true, trainer = true }

-- ── Bot spawn configuration ───────────────────────────────────────────────────

local AI_COLORS = {
	BrickColor.new("Magenta"),
	BrickColor.new("Teal"),
	BrickColor.new("Cyan"),
	BrickColor.new("Bright orange"),
}

-- ── Module state ──────────────────────────────────────────────────────────────

local aiCounter    = 0
local unitManager:     any
local buildingManager: any
local resourceManager: any
local researchManager: any
local mineralManager:  any

local botByUserId: { [number]: any } = {}

local swarmMode = false
local laneMode  = false

-- ── Generic helpers ───────────────────────────────────────────────────────────

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

local function pickWeighted(weights: { [string]: number }): string
	local total = 0
	for _, w in weights do total += w end
	if total <= 0 then return "Survivor" end
	local r, cum = math.random() * total, 0
	for name, w in weights do
		cum += w
		if r <= cum then return name end
	end
	for name in weights do return name end
	return "Survivor"
end

local function pickFrom(list: { string }): string
	return list[math.random(1, #list)]
end

local function unitValue(unitType: string): number
	local d = Config.UNIT_TYPES[unitType]
	if d and d.cost and d.cost > 0 then return d.cost end
	return 20
end

local function bank(ai: any): number
	return resourceManager.get(ai.player)
end

local function hasTech(ai: any, techName: string): boolean
	return researchManager ~= nil and researchManager.hasResearch(ai.player, techName)
end

-- A weak player misjudges army strength; a strong one reads it accurately.
-- Noise on VALUE ESTIMATES is how low difficulties make bad calls without
-- ever breaking the rules.
local function estimate(ai: any, value: number): number
	local wobble = (1 - ai.micro) * 0.5
	return value * (1 + (math.random() - 0.5) * 2 * wobble)
end

-- Chance-gated spending discipline: low levels simply forget to spend surplus
-- some of the time, the way a distracted human floats resources.
local function remembers(ai: any): boolean
	return math.random() < ai.spend
end

-- ── Live building scans (own buildings are always known — they're ours) ───────

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

local function getOwnedPositions(ownerStr: string, buildType: string): { Vector3 }
	local out: { Vector3 } = {}
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return out end
	for _, model in folder:GetChildren() do
		local ov = model:FindFirstChild("OwnerId")
		local tv = model:FindFirstChild("BuildingType")
		if ov and ov.Value == ownerStr and tv and tv.Value == buildType then
			local base = model:FindFirstChild("Base") :: BasePart?
			if base then table.insert(out, Vector3.new(base.Position.X, 0, base.Position.Z)) end
		end
	end
	return out
end

-- ── Perception: the same fog-of-war rules the player lives under ──────────────
-- Eyes = own units (VISION_UNIT) + own buildings (per-type VISION_RADIUS), the
-- exact radii FogManager reveals for players. Everything sensed is written into
-- an intel memory with timestamps; entries older than the bot's memory horizon
-- (or confirmed dead on revisit) are dropped. All decisions read intel only.

type Eye = { x: number, z: number, r2: number }

local function gatherEyes(ai: any): { Eye }
	local eyes: { Eye } = {}
	local myStr = ai.ownerStr
	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		local r2 = Config.VISION_UNIT * Config.VISION_UNIT
		for _, p in unitsF:GetChildren() do
			if not p:IsA("BasePart") then continue end
			local ov = p:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr then
				eyes[#eyes + 1] = { x = p.Position.X, z = p.Position.Z, r2 = r2 }
			end
		end
	end
	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value ~= myStr then continue end
			local base = model:FindFirstChild("Base") :: BasePart?
			if not base then continue end
			local tv = model:FindFirstChild("BuildingType")
			local vr = (Config.VISION_RADIUS :: any)[tv and tv.Value or ""] or Config.VISION_DEFAULT
			eyes[#eyes + 1] = { x = base.Position.X, z = base.Position.Z, r2 = vr * vr }
		end
	end
	return eyes
end

local function inSight(eyes: { Eye }, pos: Vector3): boolean
	for _, e in eyes do
		local dx = pos.X - e.x
		local dz = pos.Z - e.z
		if dx * dx + dz * dz <= e.r2 then return true end
	end
	return false
end

-- Threat weights for priority-target scoring.
local THREAT_BUILDING = {
	Monument = 500, CommandCenter = 100, LampreyNest = 70, Foundry = 60,
	Deployer = 55, EngineeringPost = 40, CreepyBlob = 35, Turret = 30, Relay = 25,
}
local THREAT_UNIT = {
	Broodmother = 46, Howitzer = 38, Sniper = 36, Elite = 35, Lamprey = 32, Tank = 30,
	Needler = 26, Roller = 24, Survivor = 20, Foamer = 18, CreepySoldier = 15,
	Hagfish = 14, Watcher = 20, Medic = 10, Leech = 8, Embryo = 12,
}

local function senseWorld(ai: any)
	local now   = tick()
	local myStr = ai.ownerStr
	local eyes  = gatherEyes(ai)
	ai.eyes = eyes

	local unitsF     = workspace:FindFirstChild("Units")
	local buildingsF = workspace:FindFirstChild("Buildings")

	-- Record everything currently visible.
	if unitsF then
		for _, p in unitsF:GetChildren() do
			if not p:IsA("BasePart") then continue end
			local ov = p:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local pos = p.Position
			if not inSight(eyes, pos) then continue end
			local ut = p:FindFirstChild("UnitType")
			ai.intelUnits[p.Name] = {
				pos   = Vector3.new(pos.X, 0, pos.Z),
				utype = ut and ut.Value or "Survivor",
				seen  = now,
			}
		end
	end
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base") :: BasePart?
			if not base then continue end
			if not inSight(eyes, base.Position) then continue end
			local tv = model:FindFirstChild("BuildingType")
			ai.intelBuildings[model.Name] = {
				pos   = Vector3.new(base.Position.X, 0, base.Position.Z),
				btype = tv and tv.Value or "Deployer",
				seen  = now,
			}
		end
	end

	-- Forget: stale intel ages out; anything we can SEE is gone gets erased.
	-- Units churn fast, so unit intel is trusted for a shorter slice of memory.
	local unitMem = math.min(ai.mem, 25)
	for name, rec in ai.intelUnits do
		if now - rec.seen > unitMem then
			ai.intelUnits[name] = nil
		elseif now - rec.seen > 0.5 and inSight(eyes, rec.pos)
			and not (unitsF and unitsF:FindFirstChild(name)) then
			ai.intelUnits[name] = nil
		end
	end
	for name, rec in ai.intelBuildings do
		if now - rec.seen > ai.mem then
			ai.intelBuildings[name] = nil
		elseif inSight(eyes, rec.pos)
			and not (buildingsF and buildingsF:FindFirstChild(name)) then
			ai.intelBuildings[name] = nil
		end
	end

	-- Aggregates the planners read.
	local comp: { [string]: number } = {}
	local armyValue    = 0
	local turretCount  = 0
	local unitCount    = 0
	local underAttack  = false
	local bestScore    = -math.huge
	local bestTarget: Vector3? = nil

	for _, rec in ai.intelUnits do
		unitCount += 1
		comp[rec.utype] = (comp[rec.utype] or 0) + 1
		armyValue += unitValue(rec.utype)
		local dToBase = (rec.pos - Vector3.new(ai.base.X, 0, ai.base.Z)).Magnitude
		if dToBase < 60 and now - rec.seen < 5 then underAttack = true end
		local fresh = math.clamp(1 - (now - rec.seen) / math.max(ai.mem, 1), 0, 1)
		local score = ((THREAT_UNIT :: any)[rec.utype] or 20) * (0.5 + fresh)
		if score > bestScore then bestScore = score; bestTarget = rec.pos end
	end
	for _, rec in ai.intelBuildings do
		if rec.btype == "Turret" then turretCount += 1 end
		local fresh = math.clamp(1 - (now - rec.seen) / math.max(ai.mem, 1), 0, 1)
		local score = ((THREAT_BUILDING :: any)[rec.btype] or 25) * (0.5 + fresh)
		if score > bestScore then bestScore = score; bestTarget = rec.pos end
	end

	ai.enemyComp        = comp
	ai.enemyArmyValue   = armyValue
	ai.enemyUnitCount   = unitCount
	ai.enemyTurretCount = turretCount
	ai.baseUnderAttack  = underAttack

	if bestTarget then
		ai.priorityTarget    = bestTarget
		ai.lastKnownEnemyPos = bestTarget
	else
		ai.priorityTarget = ai.lastKnownEnemyPos
	end
end

-- Known enemy value (units + turrets) within a radius of a point, from intel.
local function intelValueNear(ai: any, pos: Vector3, radius: number): number
	local r2, total = radius * radius, 0
	for _, rec in ai.intelUnits do
		local dx, dz = rec.pos.X - pos.X, rec.pos.Z - pos.Z
		if dx * dx + dz * dz <= r2 then total += unitValue(rec.utype) end
	end
	for _, rec in ai.intelBuildings do
		if rec.btype ~= "Turret" then continue end
		local dx, dz = rec.pos.X - pos.X, rec.pos.Z - pos.Z
		if dx * dx + dz * dz <= r2 then total += 55 end
	end
	return total
end

-- Random known enemy building of a type (from intel — never a map peek).
local function knownEnemyBuilding(ai: any, btype: string): Vector3?
	local found: { Vector3 } = {}
	for _, rec in ai.intelBuildings do
		if rec.btype == btype then table.insert(found, rec.pos) end
	end
	if #found == 0 then return nil end
	return found[math.random(1, #found)]
end

-- Weighted attack-target pick over everything the bot knows about. An enemy
-- Monument is an emergency (it wins the game if left standing) and dominates.
local function pickAttackTarget(ai: any): Vector3?
	local monument = knownEnemyBuilding(ai, "Monument")
	if monument then return monument end
	if ai.priorityTarget and math.random() < 0.4 then return ai.priorityTarget end
	local candidates: { { pos: Vector3, w: number } } = {}
	for _, rec in ai.intelBuildings do
		local w = (THREAT_BUILDING :: any)[rec.btype] or 25
		table.insert(candidates, { pos = rec.pos, w = w })
	end
	if #candidates == 0 then return ai.priorityTarget end
	local total = 0
	for _, c in candidates do total += c.w end
	local r, cum = math.random() * total, 0
	for _, c in candidates do
		cum += c.w
		if r <= cum then return c.pos end
	end
	return candidates[#candidates].pos
end

-- ── Placement: aim, then let placeForPlayer be the judge ──────────────────────
-- Candidates ring an anchor; an optional bias direction sorts them so turrets
-- face the threat and relays reach toward expansion targets. Every candidate is
-- validated (zone / cost / occupancy / prereqs) by BuildingManager itself.

local function tryPlaceRing(ai: any, anchor: Vector3, buildType: string, minR: number, maxR: number, biasDir: Vector3?): boolean
	local candidates: { { pos: Vector3, score: number } } = {}
	for _ = 1, 24 do
		local angle = math.random() * math.pi * 2
		local r     = minR + math.random() * (maxR - minR)
		local pos   = snapGrid(anchor + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		local score = math.random()
		if biasDir then
			local d = Vector3.new(math.cos(angle), 0, math.sin(angle))
			score = d:Dot(biasDir) + math.random() * 0.35
		end
		table.insert(candidates, { pos = pos, score = score })
	end
	table.sort(candidates, function(a, b) return a.score > b.score end)
	for _, c in candidates do
		if buildingManager.placeForPlayer(ai.player, c.pos, buildType) then return true end
	end
	return false
end

-- Anchors the bot can legally build around: its CC and its relays.
local function zoneAnchors(ai: any): { Vector3 }
	local anchors = { Vector3.new(ai.base.X, 0, ai.base.Z) }
	for _, p in getOwnedPositions(ai.ownerStr, "Relay") do table.insert(anchors, p) end
	return anchors
end

local function tryPlaceAnywhere(ai: any, buildType: string, minR: number, maxR: number, biasDir: Vector3?): boolean
	for i, anchor in zoneAnchors(ai) do
		local lo = i == 1 and minR or 5
		if tryPlaceRing(ai, anchor, buildType, lo, maxR, biasDir) then return true end
	end
	return false
end

-- Direction the enemy is expected from: latest intel, else the map centre.
local function threatDir(ai: any): Vector3
	local from = ai.lastKnownEnemyPos
	local dir  = from and (from - ai.base) or -ai.base
	dir = Vector3.new(dir.X, 0, dir.Z)
	return dir.Magnitude > 1 and dir.Unit or Vector3.new(0, 0, 1)
end

-- Foundries chase deposits: find the unclaimed deposit reachable from our build
-- zone with the most neighbours (deposits are world-visible to every commander,
-- same as the player's minimap), and place the Foundry beside it.
local function tryPlaceFoundry(ai: any): boolean
	if mineralManager and mineralManager.getUnclaimedPositions then
		local deposits = mineralManager.getUnclaimedPositions()
		local anchors  = zoneAnchors(ai)
		local best: Vector3? = nil
		local bestScore = -1
		for _, dep in deposits do
			local reachable = false
			for i, anchor in anchors do
				local reach = (i == 1) and Config.BUILD_RADIUS or Config.RELAY_RADIUS
				if (dep - anchor).Magnitude <= reach then reachable = true; break end
			end
			if not reachable then continue end
			local neighbours = 0
			for _, other in deposits do
				if (other - dep).Magnitude <= 45 then neighbours += 1 end
			end
			if neighbours > bestScore then bestScore = neighbours; best = dep end
		end
		if best then
			if tryPlaceRing(ai, best, "Foundry", 12, 30) then return true end
		end
	end
	return tryPlaceAnywhere(ai, "Foundry", 22, 48)
end

-- Relays reach outward: toward the richest deposit cluster we can't touch yet,
-- else toward the enemy. Placed at the edge of the current zone in that direction.
local function tryPlaceRelay(ai: any): boolean
	local dir = threatDir(ai)
	if mineralManager and mineralManager.getUnclaimedPositions then
		local anchors = zoneAnchors(ai)
		local bestDep: Vector3? = nil
		local bestDist = math.huge
		for _, dep in mineralManager.getUnclaimedPositions() do
			local reachable = false
			local nearest   = math.huge
			for i, anchor in anchors do
				local reach = (i == 1) and Config.BUILD_RADIUS or Config.RELAY_RADIUS
				local d = (dep - anchor).Magnitude
				if d <= reach then reachable = true; break end
				nearest = math.min(nearest, d)
			end
			if not reachable and nearest < bestDist then bestDist = nearest; bestDep = dep end
		end
		if bestDep then
			local d = bestDep - ai.base
			d = Vector3.new(d.X, 0, d.Z)
			if d.Magnitude > 1 then dir = d.Unit end
		end
	end
	local edge = Vector3.new(ai.base.X, 0, ai.base.Z) + dir * (Config.BUILD_RADIUS - 12)
	if tryPlaceRing(ai, edge, "Relay", 0, 18, dir) then return true end
	return tryPlaceAnywhere(ai, "Relay", 45, Config.BUILD_RADIUS - 10, dir)
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
	return p
end

-- ── Macro: structures ─────────────────────────────────────────────────────────
-- Desired counts come from style targets × phase ramp × the level's ambition.
-- The bot then buys ONE thing per macro tick with at most one structure under
-- construction — the human pacing this game's design asks for (Nightmare, a
-- flawless macro player, is exempt from the one-at-a-time throttle but still
-- pays for and constructs everything normally).

local function planStructures(ai: any)
	local style = ai.style
	local phase = ai.phase

	local phaseMult = (phase == "opening" and 0.5)
		or (phase == "expand" and 0.75)
		or (phase == "mid" and 1.0)
		or 1.25
	local amb = ai.ambition

	local function want(target: number): number
		return math.max(0, math.ceil(target * phaseMult * amb))
	end

	local liveFoundry = countOwnedBuildings(ai.ownerStr, "Foundry")
	local liveBonfire = countOwnedBuildings(ai.ownerStr, "Deployer")
	local liveTurret  = countOwnedBuildings(ai.ownerStr, "Turret")
	local liveRelay   = countOwnedBuildings(ai.ownerStr, "Relay")
	local livePost    = countOwnedBuildings(ai.ownerStr, "EngineeringPost")

	local wantFoundry = math.max(1, want(style.targets.foundries))
	local wantBonfire = (phase == "opening") and math.min(1, style.targets.bonfires)
		or want(style.targets.bonfires)
	local wantTurret  = want(style.targets.turrets)
	local wantRelay   = (phase ~= "opening") and want(style.targets.relays) or 0
	local wantPost    = (phase ~= "opening") and math.min(1, style.targets.posts) or 0

	-- Defensive floor: the base keeps a turret line that grows through the game.
	local turretFloor = (phase == "opening" and 1) or (phase == "expand" and 2)
		or (phase == "mid" and 3) or 4
	wantTurret = math.max(wantTurret, math.ceil(turretFloor * math.min(amb, 1)))
	if style.turtle and phase ~= "opening" then wantTurret = math.max(wantTurret, style.targets.turrets) end
	if ai.baseUnderAttack then wantTurret += 1 end

	-- Priority shopping list, most urgent first. Costs are what placeForPlayer
	-- will charge; the reserve keeps a reaction cushion in the bank.
	local reserve = ai.reserve
	local defDir  = threatDir(ai)
	local items: { { prio: number, cost: number, fn: () -> boolean } } = {}
	local function add(prio: number, cost: number, fn: () -> boolean)
		table.insert(items, { prio = prio, cost = cost, fn = fn })
	end

	if liveFoundry < 1 then
		add(100, Config.scaledBuildingCost(Config.FOUNDRY_COST, "Foundry", liveFoundry), function()
			return tryPlaceFoundry(ai)
		end)
	end
	if liveFoundry >= 1 and liveBonfire < 1 then
		add(95, Config.DEPLOYER_COST, function()
			return tryPlaceAnywhere(ai, "Deployer", 15, 35)
		end)
	end
	if ai.baseUnderAttack and liveBonfire >= 1 then
		add(92, Config.TURRET_COST, function()
			return tryPlaceAnywhere(ai, "Turret", 18, 42, defDir)
		end)
	end
	if liveFoundry >= 1 and liveFoundry < wantFoundry then
		add(85, Config.scaledBuildingCost(Config.FOUNDRY_COST, "Foundry", liveFoundry), function()
			return tryPlaceFoundry(ai)
		end)
	end
	if liveBonfire >= 1 and liveBonfire < wantBonfire then
		add(80, Config.DEPLOYER_COST, function()
			return tryPlaceAnywhere(ai, "Deployer", 15, 35)
		end)
	end
	if liveBonfire >= 1 and liveTurret < wantTurret then
		add(style.turtle and 84 or 72, Config.TURRET_COST, function()
			return tryPlaceAnywhere(ai, "Turret", 20, 45, defDir)
		end)
	end
	if liveBonfire >= 1 and livePost < wantPost then
		add(68, Config.ENGINEERING_POST_COST, function()
			return tryPlaceAnywhere(ai, "EngineeringPost", 18, 45)
		end)
	end
	if liveRelay < wantRelay and hasTech(ai, "Relay") then
		add(60, Config.RELAY_COST, function()
			return tryPlaceRelay(ai)
		end)
	end

	table.sort(items, function(a, b) return a.prio > b.prio end)

	if not ai.pacingExempt then
		if buildingManager.countConstructing and buildingManager.countConstructing(ai.player) > 0 then
			return
		end
		for _, it in items do
			if bank(ai) >= it.cost + reserve then
				if it.fn() then break end
			end
		end
	else
		for _, it in items do
			if bank(ai) >= it.cost + reserve then it.fn() end
		end
	end
end

-- ── Macro: research (the player path — conditions, timers, concurrency) ───────

local function planResearch(ai: any)
	if not researchManager then return end
	local depth = ai.techDepth
	if depth <= 0 then return end

	-- Composition demands (counters wanting a gated unit) jump the queue.
	if ai.compDemand then
		for tech in ai.compDemand do
			if not hasTech(ai, tech) then
				researchManager.requestUpgrade(ai.player, tech)
			end
		end
	end
	local asked = 0
	for i, tech in ipairs(ai.style.techOrder) do
		if i > depth then break end
		if not hasTech(ai, tech) then
			researchManager.requestUpgrade(ai.player, tech)
			asked += 1
			if asked >= 3 then break end
		end
	end
end

-- ── Macro: Engineering Post (paid Light researches, collected when done) ──────

local function planEngineering(ai: any)
	if not buildingManager.startEngineeringForPlayer then return end
	for _, id in getOwnedBuildingIds(ai.ownerStr, "EngineeringPost") do
		local state = buildingManager.getEngineeringState(ai.player, id)
		if state == "ready" and remembers(ai) then
			buildingManager.collectEngineeringForPlayer(ai.player, id)
		elseif state == "idle"
			and bank(ai) >= Config.ENGINEERING_RESEARCH_COST + math.floor(ai.reserve * 1.5)
			and remembers(ai) then
			buildingManager.startEngineeringForPlayer(ai.player, id)
		end
	end
end

-- ── Macro: composition & bonfires ─────────────────────────────────────────────

local function computeComposition(ai: any)
	local style = ai.style
	local base  = style.comp[ai.phase] or style.comp.mid
	local w: { [string]: number } = {}
	for k, v in base do w[k] = v end

	-- Waves style escalates its tier with each wave launched.
	if style.waveMode then
		local tier = math.min(ai.wavesSent, 4)
		w["Tank"] = (w["Tank"] or 0) + tier
		if tier >= 2 then w["Elite"]    = (w["Elite"] or 0) + 1 end
		if tier >= 3 then w["Howitzer"] = (w["Howitzer"] or 0) + 1 end
	end

	-- Counters, from OBSERVED intel only.
	local comp = ai.enemyComp or {}
	local cheapMass = (comp.Survivor or 0) + (comp.CreepySoldier or 0) + (comp.Hagfish or 0) + (comp.Embryo or 0)
	local heavy     = (comp.Tank or 0) + (comp.Howitzer or 0) + (comp.Elite or 0)
		+ (comp.Lamprey or 0) + (comp.Roller or 0) + (comp.Broodmother or 0)

	-- Turret lines: only the Howitzer (65) out-ranges a turret (50).
	if ai.enemyTurretCount >= 2 then
		w["Howitzer"] = (w["Howitzer"] or 0) + ai.enemyTurretCount
		w["Elite"]    = (w["Elite"] or 0) + 1
	end
	if cheapMass >= 4 then
		w["Tank"]   = (w["Tank"] or 0) + math.floor(cheapMass / 3)
		w["Foamer"] = (w["Foamer"] or 0) + 1
	end
	if heavy >= 3 then
		w["Elite"]    = (w["Elite"] or 0) + 2
		w["Foamer"]   = (w["Foamer"] or 0) + 1
		w["Survivor"] = (w["Survivor"] or 0) + 1
	end

	if hasTech(ai, "MedicUnit") and unitManager.getUnitCount(ai.player) >= 6 then
		w["Medic"] = math.max(w["Medic"] or 0, 1)
	end

	-- Research-gated picks: zero them out and demand the tech instead — the
	-- research planner will queue it through the normal timed path.
	ai.compDemand = {}
	local gated = { Elite = "EliteUnits", Medic = "MedicUnit" }
	for unitName, tech in gated do
		if (w[unitName] or 0) > 0 and not hasTech(ai, tech) then
			ai.compDemand[tech] = true
			w[unitName] = 0
		end
	end

	local total = 0
	for _, v in w do total += v end
	if total <= 0 then w["Survivor"] = 1 end
	ai.currentWeights = w
end

local function planBonfires(ai: any)
	local ids = getOwnedBuildingIds(ai.ownerStr, "Deployer")
	if #ids == 0 then return end

	ai.totalTrained = math.max(ai.totalTrained, unitManager.getUnitCount(ai.player))

	-- Assign each new bonfire a composition-driven summon type; each tick one
	-- existing bonfire is also re-evaluated so the mix tracks the counters
	-- (players re-pick their bonfire menus too — just not all at once).
	ai.bonfireType = ai.bonfireType or {}
	table.sort(ids)
	local rotate = ids[(ai.bonfireRotate % #ids) + 1]
	ai.bonfireRotate += 1
	for _, id in ids do
		if not ai.bonfireType[id] or id == rotate then
			local utype = pickWeighted(ai.currentWeights)
			local def   = Config.UNIT_TYPES[utype]
			if not def or (def.researchReq and not hasTech(ai, def.researchReq)) then utype = "Survivor" end
			if buildingManager.setBonfireSummonType(ai.player, id, utype) then
				ai.bonfireType[id] = utype
			end
		end
	end

	-- Empower with surplus: lowest-level bonfire first, capped by the level's
	-- ambition. Every level is bought at full price; discipline gates how
	-- reliably surplus actually gets spent.
	if ai.empowerCap > 0 and buildingManager.upgradeBonfireForPlayer then
		for _ = 1, ai.pacingExempt and 4 or 1 do
			if bank(ai) <= ai.reserve * 2.5 or not remembers(ai) then break end
			local upgraded = false
			for _, id in ids do
				if buildingManager.upgradeBonfireForPlayer(ai.player, id, ai.empowerCap) then
					upgraded = true
					break
				end
			end
			if not upgraded then break end
		end
	end
end

-- Paid Survivor → Sniper field upgrades: the counter a player buys against
-- turret lines and slow heavy comps. Skill-gated — beginners don't know it.
local function planSnipers(ai: any)
	if ai.micro < 0.65 then return end
	local heavy = (ai.enemyComp.Tank or 0) + (ai.enemyComp.Howitzer or 0) + (ai.enemyComp.Broodmother or 0)
	if ai.enemyTurretCount < 2 and heavy < 3 then return end
	local snipers, survivors = 0, {}
	for _, u in unitManager.getPlayerUnitData(ai.player) do
		if u.unitType == "Sniper" then snipers += 1
		elseif u.unitType == "Survivor" then table.insert(survivors, u.id) end
	end
	local maxSnipers = math.min(4, ai.enemyTurretCount + math.floor(heavy / 2))
	for _ = snipers + 1, maxSnipers do
		if #survivors == 0 then break end
		if bank(ai) < Config.SNIPER_UPGRADE_COST + ai.reserve then break end
		if not remembers(ai) then break end
		local id = table.remove(survivors)
		unitManager.upgradeUnit(ai.player, id :: string, "Sniper")
	end
end

local function planTurretUpgrades(ai: any)
	if not buildingManager.upgradeTurretForPlayer then return end
	if not hasTech(ai, "TurretUpgrades") then return end
	local pref = ai.style.turret
	local cost = (Config.TURRET_UPGRADE_COST :: any)[pref] or 999
	for _, tid in getOwnedBuildingIds(ai.ownerStr, "Turret") do
		if bank(ai) < cost + ai.reserve then break end
		if not remembers(ai) then break end
		buildingManager.upgradeTurretForPlayer(ai.player, tid, pref)
	end
end

-- ── Macro: Monument (the bot plays to WIN when it has earned the right) ───────
-- High-difficulty bots that are far ahead bank up and start the Monument, then
-- turtle around it — exactly the play a dominant human makes.

local function planMonument(ai: any)
	if not ai.monumentAmbition or ai.monumentBuilt then return end
	if ai.phase ~= "late" or ai.baseUnderAttack then return end
	if bank(ai) < Config.MONUMENT_COST + ai.reserve * 2 then return end

	local myValue = 0
	for _, u in unitManager.getPlayerUnitData(ai.player) do myValue += unitValue(u.unitType) end
	local known = estimate(ai, ai.enemyArmyValue)
	local quiet = (tick() - ai.startTime > 180) and ai.enemyUnitCount == 0
	if myValue > known * 1.3 or quiet then
		if buildingManager.buildMonument(ai.player) then
			ai.monumentBuilt = true
			print(string.format("[AIManager] %s bot %s is racing the Monument", ai.style.label, ai.player.Name))
		end
	end
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

-- ── Movement helpers ──────────────────────────────────────────────────────────
-- Army movements are ATTACK-MOVES (the same order a player issues); plain moves
-- are reserved for scouts and support that shouldn't pick fights.

local function orderChunk(ai: any, ids: { string }, dest: Vector3, attackMove: boolean)
	if #ids == 0 then return end
	if attackMove and unitManager.attackMoveUnitsFor then
		unitManager.attackMoveUnitsFor(ai.player, ids, dest)
	else
		unitManager.sendUnitsTo(ai.player, ids, dest)
	end
end

local function sendSpread(ai: any, units: { string }, target: Vector3, attackMove: boolean)
	local SPREAD = 10
	for i = 1, #units, 3 do
		local chunk = {}
		for j = i, math.min(i + 2, #units) do table.insert(chunk, units[j]) end
		local angle = math.random() * math.pi * 2
		local r     = math.random(0, SPREAD)
		local dest  = snapGrid(target + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		orderChunk(ai, chunk, dest, attackMove)
	end
end

local function fanAcrossMap(ai: any, units: { string }, pts: { Vector3 }, groupSize: number, attackMove: boolean)
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
		sendSpread(ai, chunk, pts[ptIdx], attackMove)
	end
end

-- Composition-aware commit: Howitzers hold at standoff range, Medics trail,
-- the line attack-moves in (with an optional 65/35 flank for skilled bots).
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

	-- Trainer-style partial commitment: hold a chunk back at the rally.
	if ai.style.commitRatio < 1 and #line >= 3 then
		local keep = math.floor(#line * ai.style.commitRatio)
		local held = {}
		for i = #line, keep + 1, -1 do
			table.insert(held, table.remove(line))
		end
		if ai.rallyPoint and #held > 0 then sendSpread(ai, held, ai.rallyPoint, false) end
	end

	local dirAngle = math.atan2(target.Z - ai.base.Z, target.X - ai.base.X)

	if ai.isFlankingAttack and ai.feintTarget and #line >= 5 then
		local mainCount = math.floor(#line * 0.65)
		local a, b = {}, {}
		for i, id in line do
			if i <= mainCount then table.insert(a, id) else table.insert(b, id) end
		end
		sendSpread(ai, a, target, true)
		sendSpread(ai, b, ai.feintTarget, true)
	elseif #line > 0 then
		sendSpread(ai, line, target, true)
	end

	if #siege > 0 then
		-- Howitzer range is 65; hold ~52 studs back on the approach side.
		sendSpread(ai, siege, approachPoint(target, dirAngle + math.pi, 52), true)
	end
	if #support > 0 then
		orderChunk(ai, support, approachPoint(target, dirAngle + math.pi, 20), false)
	end
end

-- ── Scout / stalker behavior ──────────────────────────────────────────────────
-- The scout is a lurker, not a map-recon drone. It creeps to the EDGE of the
-- player's vision and then WATCHES (dead still), WANDERS (drifts the rim), or
-- VANISHES (melts into the fog, reappears at a new angle). That flicker of a
-- unit at the fog line is the scare — and it's also how the bot gathers intel.

local LURK_MIN, LURK_MAX = 72, 96

local function lurkAnchor(ai: any): Vector3?
	return ai.priorityTarget
		or ai.lastKnownEnemyPos
		or knownEnemyBuilding(ai, "CommandCenter")
		or knownEnemyBuilding(ai, "Deployer")
end

local function updateScouts(ai: any, pts: { Vector3 })
	if #ai.scouts == 0 then ai.scoutState = nil; return end

	ai.scoutTimer = (ai.scoutTimer or 0) + ai.reactionInterval
	local anchor  = lurkAnchor(ai)

	-- Nothing found yet → patrol the far explore points to FIND the enemy.
	if not anchor then
		ai.scoutState = "search"
		if ai.scoutTimer >= 9 then
			ai.scoutTimer = 0
			ai.scoutIdx   = math.random(math.max(1, math.floor(#pts * 0.55)), #pts)
		end
		unitManager.sendUnitsTo(ai.player, ai.scouts, pts[ai.scoutIdx])
		return
	end

	if not ai.scoutState or ai.scoutState == "search" then
		ai.scoutState = "approach"
		ai.scoutTimer = 0
		ai.scoutDwell = 0
		ai.scoutAngle = math.random() * math.pi * 2
	end

	if ai.scoutTimer < (ai.scoutDwell or 0) then
		if ai.scoutState == "wander" and ai.scoutPoint then
			unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)
		end
		return
	end

	ai.scoutTimer = 0
	local prev = ai.scoutState
	local r    = math.random()

	if prev == "approach" then
		ai.scoutState = (r < 0.7) and "watch" or "wander"
	elseif prev == "watch" then
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
		ai.scoutDwell = math.random(4, 9)
		ai.scoutPoint = ai.scoutPoint or approachPoint(anchor, ai.scoutAngle, dist)
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)
	elseif ai.scoutState == "wander" then
		ai.scoutDwell = math.random(2, 4)
		ai.scoutAngle = (ai.scoutAngle or 0) + (math.random() < 0.5 and -1 or 1) * (0.5 + math.random() * 0.7)
		ai.scoutPoint = approachPoint(anchor, ai.scoutAngle, dist)
		unitManager.sendUnitsTo(ai.player, ai.scouts, ai.scoutPoint)
	else -- "vanish"
		ai.scoutDwell = math.random(4, 8)
		unitManager.sendUnitsTo(ai.player, ai.scouts, approachPoint(anchor, ai.scoutAngle or 0, dist + 70))
	end
end

-- Harassment squad hunts the enemy ECONOMY it knows about (Foundries, Relays).
-- Held back during the opening peace window: it shadows from a distance so the
-- first thing the player ever sees the bot do is lurk, not raid.
local function updateHarass(ai: any)
	if #ai.harass == 0 then return end
	if ai.harassUnlockTime and tick() < ai.harassUnlockTime then
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
		if ai.harassTarget then sendSpread(ai, ai.harass, ai.harassTarget, false) end
		return
	end
	ai.harassTimer += ai.reactionInterval
	if ai.harassTimer >= 4 or not ai.harassTarget then
		ai.harassTimer = 0
		ai.harassTarget = knownEnemyBuilding(ai, "Foundry")
			or knownEnemyBuilding(ai, "Relay")
			or knownEnemyBuilding(ai, "EngineeringPost")
			or knownEnemyBuilding(ai, "Deployer")
			or ai.explorePoints[#ai.explorePoints]
	end
	if ai.harassTarget then sendSpread(ai, ai.harass, ai.harassTarget, true) end
end

-- ── Squad partitioning ────────────────────────────────────────────────────────

local function rebuildSquads(ai: any)
	local allUnits = unitManager.getPlayerUnitData(ai.player)
	local total    = #allUnits
	ai.scouts, ai.harass, ai.mainForce, ai.garrison = {}, {}, {}, {}
	if total == 0 then return end

	-- The lurker at the fog edge is core atmosphere — peel one off as soon as
	-- there's an army to spare. Diligent (high-level) bots field two.
	local scoutN = (total >= 4 and ai.personality ~= "trainer") and math.min(ai.scoutCount, 1) or 0
	if ai.scoutCount >= 2 and total >= 10 and ai.personality ~= "trainer" then scoutN = 2 end
	local harassN = 0
	if ai.harassEnabled and ai.style.harass and total >= 8 then
		harassN = math.min(3, math.floor(total * 0.2))
	end

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

	local garrisonRatio = ai.style.garrison
	if ai.monumentBuilt then garrisonRatio = math.max(garrisonRatio, 0.5) end
	local garrisonN = math.max(rest[1] and 1 or 0, math.floor(#rest * garrisonRatio))
	local mainN     = #rest - garrisonN
	for i, id in rest do
		if i <= mainN then table.insert(ai.mainForce, id)
		else table.insert(ai.garrison, id) end
	end
end

-- ── Combat controller ─────────────────────────────────────────────────────────
-- Value-based: maneuver until a target offers a favorable trade (as the bot
-- ESTIMATES it — misjudgment is the low-level handicap), commit, retreat when
-- the trade turns. Cooldown-gated styles (Waves / Trainer) attack on a clock.

local function currentAtkCooldown(ai: any): number
	local style = ai.style
	if style.waveMode then return math.max(20, 55 - ai.wavesSent * 5) end
	if style.atkCooldownMax > 0 then
		return ai.rolledCooldown or style.atkCooldownMin
	end
	return 0
end

local function commandArmy(ai: any)
	local data     = unitManager.getPlayerUnitData(ai.player)
	local armySize = #data
	if armySize == 0 then return end

	local myValue = 0
	for _, u in data do myValue += unitValue(u.unitType) end

	local pts            = ai.explorePoints
	local garrisonTarget = ai.baseUnderAttack and ai.base or snapGrid(ai.base + Vector3.new(0, 0, 18))

	if #ai.garrison > 0 then unitManager.sendUnitsTo(ai.player, ai.garrison, garrisonTarget) end
	updateScouts(ai, pts)
	updateHarass(ai)

	-- Snap home to defend.
	if ai.baseUnderAttack and ai.combatPhase ~= "defend" then
		if #ai.mainForce > 0 then sendSpread(ai, ai.mainForce, ai.base, true) end
		if #ai.harass    > 0 then sendSpread(ai, ai.harass,    ai.base, true) end
		ai.combatPhase = "defend"; ai.phaseTimer = 0; ai.attackTarget = nil; ai.feintTarget = nil
		return
	end

	ai.phaseTimer += ai.reactionInterval
	ai.atkCooldownTimer = (ai.atkCooldownTimer or 0) + ai.reactionInterval

	if ai.combatPhase == "defend" then
		if #ai.mainForce > 0 then sendSpread(ai, ai.mainForce, garrisonTarget, true) end
		if not ai.baseUnderAttack then ai.combatPhase = "gather"; ai.phaseTimer = 0 end
		return
	end

	local pastPeace = (not ai.aggressionUnlockTime) or tick() >= ai.aggressionUnlockTime

	if ai.combatPhase == "gather" then
		if #ai.mainForce > 0 then
			if pastPeace then
				-- Roam the map probing for an opening (this is also how a bot
				-- without intel finds the enemy — it has no map hack to lean on).
				fanAcrossMap(ai, ai.mainForce, pts, 3, true)
				ai.exploreTimer += ai.reactionInterval
				if ai.exploreTimer >= 8 then ai.exploreTimer = 0; ai.exploreIdx = (ai.exploreIdx % #pts) + 1 end
			else
				-- Opening peace: the army patrols its OWN perimeter. Only the
				-- lurker scout ranges out, so all the player sees is something
				-- flickering at the fog line — never a column marching in.
				local home: { Vector3 } = {}
				for i = 1, math.min(8, #pts) do table.insert(home, pts[i]) end
				if #home > 0 then fanAcrossMap(ai, ai.mainForce, home, 4, false) end
			end
		end
		local cooldownOk = ai.atkCooldownTimer >= currentAtkCooldown(ai)
		if pastPeace and cooldownOk and ai.priorityTarget and armySize >= ai.minAtk then
			local target = pickAttackTarget(ai)
			if target then
				local enemyVal = estimate(ai, intelValueNear(ai, target, 70))
				if myValue >= enemyVal * ai.style.engageRatio then
					ai.combatPhase    = "staging"; ai.phaseTimer = 0
					ai.attackTarget   = target
					ai.rallyPoint     = approachPoint(target, math.random() * math.pi * 2, 50 + math.random(0, 25))
					ai.stageDuration  = math.random(ai.style.stageMin, ai.style.stageMax)
					ai.attackDuration = math.random(20, 45)
				end
			end
		end

	elseif ai.combatPhase == "staging" then
		if #ai.mainForce > 0 and ai.rallyPoint then sendSpread(ai, ai.mainForce, ai.rallyPoint, true) end
		if not ai.attackTarget then
			ai.combatPhase = "gather"; ai.phaseTimer = 0
		elseif ai.phaseTimer >= ai.stageDuration then
			ai.combatPhase = "attack"; ai.phaseTimer = 0; ai.wavesSent += 1
			-- Skilled bots sometimes split onto a second target.
			ai.isFlankingAttack = ai.micro >= 0.7 and math.random() < 0.35 and #ai.mainForce >= 5
			if ai.isFlankingAttack then
				local c = knownEnemyBuilding(ai, pickFrom({ "Deployer", "Turret", "Relay", "Foundry" }))
				ai.feintTarget = (c and c ~= ai.attackTarget) and c or nil
				if not ai.feintTarget then ai.isFlankingAttack = false end
			end
		end

	elseif ai.combatPhase == "attack" then
		local target = ai.attackTarget or ai.priorityTarget
		if not target then ai.combatPhase = "gather"; ai.phaseTimer = 0; return end
		commitAttack(ai, data, target)
		local enemyVal = estimate(ai, intelValueNear(ai, target, 70))
		if myValue < enemyVal * RETREAT_RATIO or ai.phaseTimer >= ai.attackDuration then
			ai.combatPhase = "retreat"; ai.phaseTimer = 0
			ai.feintTarget = nil; ai.isFlankingAttack = false
			ai.retreatDuration = math.random(8, 18)
		end

	elseif ai.combatPhase == "retreat" then
		if #ai.mainForce > 0 then sendSpread(ai, ai.mainForce, ai.base, false) end
		if ai.phaseTimer >= ai.retreatDuration then
			ai.combatPhase = "gather"; ai.phaseTimer = 0; ai.attackTarget = nil; ai.rallyPoint = nil
			ai.atkCooldownTimer = 0
			if ai.style.atkCooldownMax > 0 then
				ai.rolledCooldown = math.random(ai.style.atkCooldownMin, ai.style.atkCooldownMax)
			end
		end
	end
end

-- ── Swarm gamemode brain ──────────────────────────────────────────────────────
-- Special PvE mode: the bot fields a nest/creepy army instead of the standard
-- human tech tree. Still pays full price for every structure, egg and soldier
-- out of the same honest economy (Foundries + CC income).

local function swarmCaps(level: number): (number, number, number)
	if level <= 1 then return 1, 0, 1
	elseif level == 2 then return 1, 1, 2
	elseif level == 3 then return 2, 1, 2
	elseif level == 4 then return 3, 2, 3
	else return 4, 3, 4 end
end

local function ensureCC(ai: any): boolean
	if ai.hasCC then return true end
	local ok = buildingManager.placeForPlayer(ai.player, ai.base, "CommandCenter")
	if not ok then return false end
	ai.hasCC = true
	-- Base parity with humans: default-mode players get 5 deposits seeded at
	-- their base (deliverBaseForPlayer); lane-mode players get +600 resources
	-- instead. The bot gets exactly the same start.
	if ai.laneMode then
		resourceManager.add(ai.player, 600)
	elseif mineralManager and mineralManager.spawnDepositsForBase then
		mineralManager.spawnDepositsForBase(Vector3.new(ai.base.X, 0, ai.base.Z), 5)
	end
	return true
end

local function swarmStrategyTree(ai: any)
	if not ensureCC(ai) then return end

	if not ai.swarmTechGranted and researchManager then
		ai.swarmTechGranted = true
		researchManager.startForPlayer(ai.player, "", "CreepyBlob")
	end

	local maxNests, maxBlobs, maxMines = swarmCaps(ai.level)
	if ai.isNightmare then maxNests += 2; maxBlobs += 2 end

	local liveMines   = countOwnedBuildings(ai.ownerStr, "Foundry")
	local foundryCost = Config.scaledBuildingCost(Config.FOUNDRY_COST, "Foundry", liveMines)
	if liveMines < maxMines and bank(ai) >= foundryCost + ai.reserve then
		tryPlaceFoundry(ai)
	end

	local liveNests = countOwnedBuildings(ai.ownerStr, "LampreyNest")
	if liveNests < maxNests and bank(ai) >= Config.LAMPREY_NEST_COST + ai.reserve then
		tryPlaceAnywhere(ai, "LampreyNest", 15, 45)
	end

	local liveBlobs = countOwnedBuildings(ai.ownerStr, "CreepyBlob")
	if liveBlobs < maxBlobs and bank(ai) >= Config.CREEPY_BLOB_COST + ai.reserve then
		tryPlaceAnywhere(ai, "CreepyBlob", 15, 45)
	end

	local currentCount = unitManager.getUnitCount(ai.player)
	if currentCount ~= ai.lastSquadCount then
		rebuildSquads(ai)
		ai.lastSquadCount = currentCount
	end
end

local function produceSwarm(ai: any)
	for _, nestId in getOwnedBuildingIds(ai.ownerStr, "LampreyNest") do
		local kind: string
		if bank(ai) >= Config.BROODMOTHER_EGG_COST + ai.reserve and math.random() < 0.18 then
			kind = "Broodmother"
		else
			ai.swarmEggToggle = not ai.swarmEggToggle
			kind = if ai.swarmEggToggle then "Lamprey" else "Hagfish"
		end
		local cost = if kind == "Hagfish" then Config.HAGFISH_EGG_COST
			elseif kind == "Broodmother" then Config.BROODMOTHER_EGG_COST
			else Config.LAMPREY_EGG_COST
		if bank(ai) >= cost + ai.reserve then
			buildingManager.requestNestEgg(ai.player, nestId, kind)
		end
	end
	for _, blobId in getOwnedBuildingIds(ai.ownerStr, "CreepyBlob") do
		if bank(ai) >= Config.BLOB_SOLDIER_COST + ai.reserve then
			buildingManager.requestBlobSoldier(ai.player, blobId)
		end
	end
end

-- ── Top-level trees ───────────────────────────────────────────────────────────

local function strategyTree(ai: any)
	ai.reserve = math.floor(ai.reserveBase * ai.style.reserveMult)
	if ai.swarm then swarmStrategyTree(ai); return end

	if not ensureCC(ai) then return end

	ai.phase = getPhase(ai)

	planStructures(ai)

	local count = unitManager.getUnitCount(ai.player)
	if count ~= ai.lastSquadCount then rebuildSquads(ai); ai.lastSquadCount = count end

	computeComposition(ai)
	planResearch(ai)
	planEngineering(ai)
	planBonfires(ai)
	planSnipers(ai)
	planTurretUpgrades(ai)
	planMonument(ai)
end

local function reactionTree(ai: any)
	senseWorld(ai)
	if ai.swarm then
		produceSwarm(ai)
	end
	commandArmy(ai)
end

-- ── Identity assignment ───────────────────────────────────────────────────────

local function applyLevel(ai: any, level: number)
	local L = LEVELS[math.clamp(level, 1, 5)]
	ai.strategyInterval = L.strat
	ai.reactionInterval = L.react
	ai.mem              = L.mem
	ai.micro            = L.micro
	ai.spend            = L.spend
	ai.scoutCount       = L.scouts
	ai.harassEnabled    = L.harass
	ai.minAtk           = L.minAtk
	ai.ambition         = L.ambition
	ai.empowerCap       = L.empower
	ai.techDepth        = L.techDepth
	ai.firstStrike      = L.firstStrike
	ai.monumentAmbition = L.monument
	ai.reserveBase      = 30 + level * 10
	ai.pacingExempt     = false

	-- Nightmare: a flawless level-5 brain on a relentless clock. It thinks and
	-- spends faster and never hesitates — but its bank, prices, timers, and
	-- vision are exactly a player's.
	if ai.isNightmare then
		ai.strategyInterval = 3.0
		ai.reactionInterval = 0.6
		ai.micro            = 1.0
		ai.spend            = 1.0
		ai.ambition         = 1.5
		ai.empowerCap       = Config.DEPLOYER_UPGRADE_MAX_LEVEL
		ai.techDepth        = 9
		ai.firstStrike      = 60
		ai.monumentAmbition = true
		ai.reserveBase      = 20
		ai.pacingExempt     = true
	end
end

-- When the bot first commits its main army, and when harassment may begin.
-- The opening before this is deliberately quiet: scouts lurk, the army holds.
local function applyAggressionWindow(ai: any)
	local fs = (ai.firstStrike or 140) * (0.85 + math.random() * 0.30)
	ai.aggressionUnlockTime = ai.startTime + fs
	ai.harassUnlockTime     = ai.startTime + fs * 0.55
end

local function assignStyle(ai: any)
	if ai.swarm then ai.style = STYLES.Swarm
	elseif ai.personality == "trainer" then ai.style = STYLES.Trainer
	elseif ai.personality == "territorial" then ai.style = STYLES.Fortress
	elseif ai.personality == "waves" then ai.style = STYLES.Waves
	elseif ai.personality == "nightmare" then ai.style = STYLES[pickFrom(NIGHTMARE_ROLL)]
	else ai.style = STYLES[pickFrom(BALANCED_ROLL)] end
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

function AIManager.setMineralManager(mm: any)
	mineralManager = mm
end

function AIManager.setSwarmMode(on: boolean)
	swarmMode = on and true or false
end

-- Lane mode gives bots an explicit corridor base and extra starting resources (no
-- deposits are seeded down the lane); every other mode has them claim a perimeter
-- spot and mine like a player.
function AIManager.setLaneMode(on: boolean)
	laneMode = on and true or false
end

-- Permanently knock a bot out of the current match (its CC was destroyed). It stops
-- thinking/rebuilding and idles until the next round's resetAllBots respawns it.
function AIManager.eliminateBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end
	ai.eliminated = true
	ai.hasCC      = false
end

-- Every AI bot that took part in this match (id + a readable name), for the
-- end-screen performance graph.
function AIManager.getBotsForGraph(): { { userId: number, name: string } }
	local out = {}
	for userId, ai in botByUserId do
		local label = (ai.style and ai.style.label) or ai.personality or "Bot"
		out[#out + 1] = { userId = userId, name = "AI " .. tostring(label) }
	end
	return out
end

function AIManager.resetBot(userId: number)
	local ai = botByUserId[userId]
	if not ai then return end

	-- Re-roll level knobs + style so a rebuilt bot plays fresh.
	applyLevel(ai, ai.level)
	assignStyle(ai)

	-- Hold this bot's ground on the spawn ring. The reservation list was just
	-- cleared for the new match, so re-register it or the next commander to claim a
	-- spot could be handed the ground this bot is about to rebuild on.
	SpawnPoints.reserve(ai.base)

	ai.hasCC             = false
	ai.eliminated        = false
	ai.swarmTechGranted  = false
	ai.swarmEggToggle    = false
	ai.monumentBuilt     = false
	ai.totalTrained      = 0
	ai.bonfireType       = {}
	ai.bonfireRotate     = 0
	ai.intelUnits        = {}
	ai.intelBuildings    = {}
	ai.lastKnownEnemyPos = nil
	ai.priorityTarget    = nil
	ai.enemyTurretCount  = 0
	ai.enemyUnitCount    = 0
	ai.enemyArmyValue    = 0
	ai.baseUnderAttack   = false
	ai.enemyComp         = {}
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
	ai.atkCooldownTimer  = 0
	ai.rolledCooldown    = nil
	ai.wavesSent         = 0
	ai.strategyTimer     = ai.strategyInterval
	ai.reactionTimer     = ai.reactionInterval
	ai.startTime         = tick()
	applyAggressionWindow(ai)

	-- Fresh match, fresh slate — exactly what a rejoining player gets.
	resourceManager.reset(ai.player)
	if researchManager and researchManager.resetPlayer then
		researchManager.resetPlayer(ai.player)
	end
	print(string.format("[AIManager] Bot %d reset → %s lv%d", userId, ai.style.label, ai.level))
end

function AIManager.resetAllBots()
	for userId in botByUserId do
		AIManager.resetBot(userId)
	end
end

-- `race` ("Humans" | "Hollowed") comes from the lobby's per-AI card. Hollowed
-- bots field the nest/creature army (the swarm brain) behind the black spike
-- command center; Humans (default) play the bonfire tech tree. The Swarm
-- GAMEMODE still forces every bot Hollowed regardless of the card.
function AIManager.spawnAI(personality: string, level: number, baseOverride: Vector3?, race: string?): boolean
	personality = tostring(personality):lower()
	level       = math.clamp(math.floor(tonumber(level) or 3), 1, 5)
	local hollowed = swarmMode or race == "Hollowed"

	if not VALID_PERSONALITIES[personality] then
		warn("[AIManager] Unknown personality:", personality, "— use balanced / territorial / waves / nightmare / trainer")
		return false
	end

	aiCounter += 1
	-- Lane mode passes an explicit corridor base; otherwise the bot claims a random
	-- perimeter spot, spaced away from every other commander (SpawnPoints).
	local base     = baseOverride or SpawnPoints.claim()
	local colorIdx = ((aiCounter - 1) % #AI_COLORS) + 1

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
		isSwarm   = hollowed,   -- Hollowed AIs get the black spike command center + nest gates
	}

	-- Same wallet + research ledger a joining player gets.
	resourceManager.reset(aiPlayer)
	if researchManager and researchManager.registerBotPlayer then
		researchManager.registerBotPlayer(aiPlayer)
	end

	local ai: any = {
		player      = aiPlayer,
		ownerStr    = tostring(aiPlayer.UserId),
		base        = base,
		personality = personality,
		level       = personality == "nightmare" and 5 or personality == "trainer" and 1 or level,
		isNightmare = personality == "nightmare",
		laneMode    = laneMode,

		swarm            = hollowed,
		swarmTechGranted = false,
		swarmEggToggle   = false,

		hasCC         = false,
		eliminated    = false,
		monumentBuilt = false,
		totalTrained  = 0,

		bonfireType   = {},
		bonfireRotate = 0,

		intelUnits        = {},
		intelBuildings    = {},
		lastKnownEnemyPos = nil,
		priorityTarget    = nil,
		enemyTurretCount  = 0,
		enemyUnitCount    = 0,
		enemyArmyValue    = 0,
		baseUnderAttack   = false,
		enemyComp         = {},
		compDemand        = {},

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
		atkCooldownTimer = 0,
		rolledCooldown   = nil,
		wavesSent        = 0,

		reserve   = 0,
		startTime = tick(),
	}

	applyLevel(ai, ai.level)
	assignStyle(ai)
	applyAggressionWindow(ai)

	ai.strategyTimer = ai.strategyInterval
	ai.reactionTimer = ai.reactionInterval
	ai.scoutIdx      = math.floor(#ai.explorePoints * 0.6) + 1

	team.Name = string.format("AI [%s/%s lv%d] %d", personality, ai.style.label, ai.level, aiCounter)

	botByUserId[aiPlayer.UserId] = ai

	task.spawn(function()
		while true do
			local dt = task.wait(0.5)
			-- Eliminated bots idle (they don't rebuild a CC) until the next
			-- round's resetAllBots clears the flag and respawns them fresh.
			if ai.eliminated then continue end
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
		personality, ai.style.label, ai.level, aiCounter, tostring(base)))
	return true
end

return AIManager
