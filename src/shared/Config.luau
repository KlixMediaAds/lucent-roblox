local Config = {}

-- Gamemodes
Config.GAMEMODES = { Default = "Default", Lane = "Lane", Swarm = "Swarm" }

-- Economy
Config.STARTING_RESOURCES   = 400
Config.BUILDING_COST         = 50   -- Barracks cost
Config.FOUNDRY_COST          = 150  -- Foundry building cost (passive-income structure; scales — see below)

-- Buildings whose cost grows exponentially with how many the player already owns.
-- The Nth (0-indexed by current active count) costs baseCost * growth^count, so the
-- price climbs as you stack them and drops right back down if one is lost/sold.
Config.EXPONENTIAL_BUILDING_COST = {
	Foundry = 1.6,
}

-- Buildings whose FIRST one (current count 0) is free; later ones cost as normal.
Config.FIRST_FREE_BUILDING = {
	Foundry = true,
}

-- Scaled cost for `buildingType` given how many the player currently owns.
function Config.scaledBuildingCost(baseCost: number, buildingType: string, currentCount: number): number
	if Config.FIRST_FREE_BUILDING[buildingType] and currentCount <= 0 then return 0 end
	local growth = Config.EXPONENTIAL_BUILDING_COST[buildingType]
	if not growth then return baseCost end
	return math.floor(baseCost * growth ^ math.max(0, currentCount) + 0.5)
end
-- Bonfire (internal building type "Deployer") — a mystical purple bonfire that
-- auto-summons units for FREE up to a capacity, with a repeatable "Empower" upgrade
-- that raises capacity AND shortens the summon interval. Each purchase also stacks a
-- LOG onto the fire, building a tiki tower that flares outward as it climbs (see
-- UnitVisuals.addBonfireLog). Capacity/interval are tracked per-building from level.
-- The upgrade is open-ended by design; MAX_LEVEL just caps it "for now".
Config.DEPLOYER_COST              = 100  -- Bonfire build cost (flat)
Config.DEPLOYER_BASE_CAPACITY     = 3    -- max simultaneous summoned units at level 0
Config.DEPLOYER_BASE_INTERVAL     = 15   -- seconds between summons at level 0
Config.DEPLOYER_MIN_INTERVAL      = 3.5  -- floor so deep upgrades don't go absurd
Config.DEPLOYER_UPGRADE_COST      = 75   -- base cost of the first Empower upgrade
Config.DEPLOYER_UPGRADE_GROWTH    = 1.22 -- upgrade cost multiplier per level already bought
Config.DEPLOYER_UPGRADE_CAP_STEP  = 1    -- +capacity per Empower level
Config.DEPLOYER_UPGRADE_INTERVAL_MULT = 0.9   -- summon interval ×this per Empower level (until the floor)
Config.DEPLOYER_UPGRADE_MAX_LEVEL = 20   -- max Empower purchases per bonfire (≈ tiki logs)

-- Cost to Empower a bonfire that has already bought `level` upgrades.
function Config.bonfireUpgradeCost(level: number): number
	return math.floor(Config.DEPLOYER_UPGRADE_COST * Config.DEPLOYER_UPGRADE_GROWTH ^ math.max(0, level) + 0.5)
end
function Config.bonfireCapacity(level: number): number
	return Config.DEPLOYER_BASE_CAPACITY + level * Config.DEPLOYER_UPGRADE_CAP_STEP
end
function Config.bonfireInterval(level: number): number
	-- Early levels speed up summons; later levels are floored so the reward shifts to
	-- pure capacity (and the growing tiki).
	return math.max(Config.DEPLOYER_MIN_INTERVAL,
		Config.DEPLOYER_BASE_INTERVAL * Config.DEPLOYER_UPGRADE_INTERVAL_MULT ^ math.max(0, level))
end

-- TEST building — a 4×4-tile "super bonfire" sandbox structure (limit 1 per player).
-- When selected it opens a 3-way menu: UPGRADES, UNITS, STRUCTURES.
--   • UNITS     — same unit grid as the Bonfire; picks which unit it auto-summons.
--   • STRUCTURES— the Command Center build options.
--   • UPGRADES  — two SEPARATE repeatable upgrades: Supply (+capacity) and
--                 Spawn Rate (shorter summon interval). Unlike the Bonfire's combined
--                 "Empower", these are tracked and purchased independently.
Config.TEST_COST              = 100  -- build cost (flat)
Config.TEST_SIZE              = Vector3.new(20, 8, 20)  -- 4×4 tiles (grid = 5)
Config.TEST_BASE_CAPACITY     = 3    -- max simultaneous summoned units at supply level 0
Config.TEST_BASE_INTERVAL     = 15   -- seconds between summons at rate level 0
Config.TEST_MIN_INTERVAL      = 3.5  -- floor so deep rate upgrades don't go absurd
Config.TEST_SUPPLY_COST       = 75   -- base cost of the first Supply upgrade
Config.TEST_SUPPLY_GROWTH     = 1.22 -- Supply cost multiplier per level already bought
Config.TEST_SUPPLY_CAP_STEP   = 1    -- +capacity per Supply level
Config.TEST_SUPPLY_MAX_LEVEL  = 20   -- max Supply upgrades
Config.TEST_RATE_COST         = 75   -- base cost of the first Spawn Rate upgrade
Config.TEST_RATE_GROWTH       = 1.22 -- Spawn Rate cost multiplier per level already bought
Config.TEST_RATE_INTERVAL_MULT = 0.9 -- summon interval ×this per Spawn Rate level (until the floor)
Config.TEST_RATE_MAX_LEVEL    = 20   -- max Spawn Rate upgrades

function Config.testSupplyCost(level: number): number
	return math.floor(Config.TEST_SUPPLY_COST * Config.TEST_SUPPLY_GROWTH ^ math.max(0, level) + 0.5)
end
function Config.testRateCost(level: number): number
	return math.floor(Config.TEST_RATE_COST * Config.TEST_RATE_GROWTH ^ math.max(0, level) + 0.5)
end
function Config.testCapacity(supplyLevel: number): number
	return Config.TEST_BASE_CAPACITY + supplyLevel * Config.TEST_SUPPLY_CAP_STEP
end
function Config.testInterval(rateLevel: number): number
	return math.max(Config.TEST_MIN_INTERVAL,
		Config.TEST_BASE_INTERVAL * Config.TEST_RATE_INTERVAL_MULT ^ math.max(0, rateLevel))
end

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Survivor      = { cost = 25,  size = Vector3.new(4, 4, 4) },
	Sniper        = { cost = 75,  size = Vector3.new(4, 4, 4) },  -- long-range marksman: slow fire, high damage (trained by upgrading a Survivor, not summoned directly)
	Tank          = { cost = 60,  size = Vector3.new(7, 5, 9)  },
	Howitzer      = { cost = 90,  size = Vector3.new(8, 14, 8) },
	Elite         = { cost = 100, size = Vector3.new(5, 6, 5), researchReq = "EliteUnits" },
	Medic         = { cost = 60,  size = Vector3.new(4, 4, 4), researchReq = "MedicUnit"  },
	Foamer        = { cost = 80,  size = Vector3.new(6, 5, 7)  },
	Lamprey       = { cost = 110, size = Vector3.new(7, 12, 7) },  -- massive burrowing lamprey (visuals drawn client-side)
	Hagfish       = { cost = 120, size = Vector3.new(6, 10, 6) },  -- slithering cobra-posed hagfish (visuals drawn client-side)
	Broodmother   = { cost = 200, size = Vector3.new(13.2, 24, 13.2) }, -- towering anemone-bodied tripod (visuals drawn client-side; 1.2× the base 11×20×11)
	CreepySoldier = { cost = 0,   size = Vector3.new(4, 4, 4) },  -- spawned free by Mutant turrets
}

-- Field upgrade: a selected Survivor can be re-kitted into a Sniper (command-card
-- action on the unit, not a Bonfire summon option). Charged per Survivor upgraded.
Config.SNIPER_UPGRADE_COST = 60

Config.CC_PASSIVE_INCOME      = 10    -- resources granted per tick to every standing Command Center
Config.CC_PASSIVE_INTERVAL    = 6     -- seconds between Command Center passive-income ticks

-- Foundry: a large industrial structure (4× the Command Center footprint) that
-- passively produces income. Every active mineral deposit within FOUNDRY_BOOST_RADIUS
-- boosts its output by FOUNDRY_BOOST_PER_DEPOSIT (uncapped) and is drained a little each
-- income tick, so a deposit-rich site pays out more but exhausts the field faster.
Config.FOUNDRY_BASE_INCOME       = 12    -- resources per tick with no nearby deposits
Config.FOUNDRY_INCOME_INTERVAL   = 6     -- seconds between Foundry income ticks
Config.FOUNDRY_BOOST_RADIUS      = 60    -- studs; active deposits within this of a Foundry boost it
Config.FOUNDRY_BOOST_PER_DEPOSIT = 0.15  -- +15% income per active nearby deposit (no cap)
Config.FOUNDRY_DRAIN_PER_DEPOSIT = 12    -- resources drained from each boosting deposit per income tick

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = { Survivor = 26, Sniper = 22, Tank = 14, Howitzer = 9,  Elite = 20, Medic = 22, Foamer = 11, Lamprey = 13, Hagfish = 15, Broodmother = 8, CreepySoldier = 24 }
Config.UNIT_ACCEL             = { Survivor = 12, Sniper = 10, Tank = 4,  Howitzer = 3,  Elite = 8,  Medic = 10, Foamer = 3,  Lamprey = 3,  Hagfish = 4,  Broodmother = 3, CreepySoldier = 14 }
Config.UNIT_FORMATION_SPACING = 7
Config.UNIT_AGGRO_RADIUS      = 40   -- studs; idle/A-move units spot enemies here
Config.UNIT_LEASH_RANGE       = 55   -- studs from aggro-start before retreating
Config.TANK_SPLASH_RANGE      = 12   -- studs AoE radius on tank hit
Config.TANK_SPLASH_DAMAGE_MULT = 0.5  -- splash deals this fraction of primary damage
Config.TANK_SLOW_DURATION     = 1.5  -- seconds units are slowed after a tank shell hit
Config.TANK_SLOW_MULT         = 0.4  -- speed multiplier while slowed (requires ConcussionShells)

-- Buildings
Config.BUILDING_SIZE         = Vector3.new(10, 8, 10)
Config.BUILDING_GRID         = 5     -- snap grid in studs
Config.FOUNDRY_SIZE          = Vector3.new(15, 10, 15)  -- 3×3 tiles (grid = 5)
Config.BONFIRE_SIZE          = Vector3.new(8, 7, 8)     -- summoning bonfire footprint (internal type "Deployer")
Config.ENGINEERING_POST_SIZE = Vector3.new(12, 10, 12)

-- Engineering Post — researches random combat upgrades. Light research rolls one
-- random stat (+5–15%) on a random unit type, applied to all that player's units of
-- that type (current + future). Heavy research is a placeholder ("coming soon").
Config.ENGINEERING_POST_COST   = 150   -- cost to build the post (needs a Barracks first)
Config.ENGINEERING_RESEARCH_COST = 75  -- resource cost to start one Light research
Config.ENGINEERING_LIGHT_TIME  = 30    -- seconds for a Light research
Config.ENGINEERING_HEAVY_TIME  = 90    -- seconds for a Heavy research (not yet implemented)
Config.ENGINEERING_UPGRADE_MIN_PCT = 5   -- min % a Light research improves a stat by
Config.ENGINEERING_UPGRADE_MAX_PCT = 15  -- max %

-- Mineral Deposits — cluster spawning
Config.DEPOSIT_SIZE          = Vector3.new(5, 10, 5)
Config.DEPOSIT_SPREAD        = 380   -- half-extent of placement area (2× map)

-- Ore clusters (initial generation)
Config.CLUSTER_COUNT         = 6     -- number of initial ore clusters (must be even for mirror symmetry)
Config.CLUSTER_SIZE_MIN      = 3     -- minimum deposits per cluster
Config.CLUSTER_SIZE_MAX      = 5     -- maximum deposits per cluster
Config.CLUSTER_RADIUS        = 55    -- max scatter radius within a cluster (studs)
Config.CLUSTER_MIN_DIST      = 130   -- min distance between cluster centers (studs)

-- Ore wave (comet respawn system)
Config.ORE_WAVE_MAX_DEPOSITS    = 20   -- cap; no wave fires while unclaimed count >= this
Config.ORE_WAVE_MIN_INTERVAL    = 25   -- seconds between depletion and wave when ores are scarce
Config.ORE_WAVE_MAX_INTERVAL    = 180  -- seconds when plenty of ores remain
Config.ORE_COMET_CLUSTER_SIZE_MIN = 2  -- deposits spawned per wave (min)
Config.ORE_COMET_CLUSTER_SIZE_MAX = 4  -- deposits spawned per wave (max)
Config.ORE_COMET_HEIGHT         = 220  -- studs above ground comets spawn
Config.ORE_COMET_SPEED          = 85   -- studs per second fall speed

-- Command Center
Config.COMMAND_CENTER_SIZE     = Vector3.new(14, 10, 14)
Config.COMMAND_CENTER_MIN_DIST = 100   -- minimum studs between any two command centers
Config.BUILD_RADIUS            = 85    -- studs; non-CC buildings must be within this distance of the player's CC
Config.FOREST_CC_CLEARING      = 60    -- studs; trees are felled within this radius around a Command Center

-- Relay (build-zone extender, unlocked via Relay research)
Config.RELAY_COST            = 175
Config.MOBILE_CC_COST        = 200   -- one-time cost to enable CC mobility
Config.MOBILE_CC_SPEED       = 14    -- studs per second when walking
Config.CREEPY_BLOB_COST      = 225   -- cost to place the blob building
Config.BLOB_SOLDIER_COST     = 40    -- per CreepySoldier spawn
Config.BLOB_SOLDIER_COOLDOWN = 6     -- seconds between soldier spawns
Config.BLOB_WORM_COST        = 300   -- triggers worm burst, consumes blob
Config.BLOB_TURRET_COST      = 275   -- transforms blob into a Creepy Turret
Config.RELAY_HP         = 250
Config.RELAY_BUILD_TIME = 12
Config.RELAY_RADIUS     = 65    -- studs; extends the build zone around this structure
Config.RELAY_SIZE       = Vector3.new(6, 12, 6)

-- Lamprey Nest — organic structure that births Lampreys from pulsing eggs.
-- Replaces the Barracks as the sole source of Lampreys. Each purchase makes the
-- nest pulse its tubes, then ejects a green egg to a random spot nearby; each
-- egg incubates on its own timer and hatches into a Lamprey. Eggs ARE the queue.
Config.LAMPREY_NEST_COST       = 150  -- cost to place the nest building
Config.LAMPREY_EGG_COST        = 110  -- cost per egg / Lamprey (matches the Lamprey unit cost)
Config.LAMPREY_NEST_MAX_EGGS   = 8    -- max concurrent eggs (in-flight + incubating) per nest
Config.LAMPREY_NEST_SIZE       = Vector3.new(11, 7, 11)
Config.LAMPREY_NEST_EJECT_TIME = 1.5  -- seconds the tubes pulse + the egg arcs out of the nest
Config.LAMPREY_EGG_INCUBATION  = 9.0  -- seconds from egg settling to hatch (~10s total per egg)

-- Lamprey Nest rally upgrade — a one-time node purchase that changes how the nest
-- births eggs: instead of settling them around its own footprint, the nest LAUNCHES
-- each egg to a player-set rally point (right-click the ground while the nest is
-- selected). Eggs scatter within a spread radius and refuse to overlap each other.
Config.LAMPREY_NEST_RALLY_COST  = 160   -- one-time cost to unlock the rally launcher
Config.LAMPREY_NEST_RALLY_RANGE = 90    -- max studs the rally point may sit from the nest
Config.LAMPREY_NEST_EGG_SPREAD  = 7     -- radius around the rally point eggs scatter within
Config.LAMPREY_NEST_EGG_GAP     = 4.2   -- min centre-to-centre spacing so eggs never overlap

-- Hagfish — the nest's second unit. A light, fragile slithering hagfish that rears
-- its front third like a cobra, then slaps its head into the earth to erupt six
-- teeth-like tentacles from the ground around nearby enemies. Hatches from the
-- same Lamprey Nest egg pipeline (its own egg cost, shared concurrent egg cap).
Config.HAGFISH_EGG_COST        = 120  -- cost per Hagfish egg (matches the Hagfish unit cost)
Config.HAGFISH_TENTACLES       = 6    -- tentacles erupting per attack (strikes split across foes)
Config.HAGFISH_STRIKE_WINDOW   = 2.5  -- seconds across which the six tentacles strike, deviated
Config.HAGFISH_ROOT_TIME       = 3.3  -- seconds the hagfish is head-down + rooted while attacking (slap + window + rear-up)

-- Broodmother — the nest's heavy third unit. A towering creature that walks on
-- three tentacle-legs with a swaying sea-anemone mass for a head, ringed in
-- lamprey-like fangs. Instead of a normal attack it spits a swarm of glowing
-- orbs that orbit it and deal weak-but-constant stacking aura damage to any enemy
-- within range. On death it collapses, splits open along its ribcage and births
-- three Lampreys from the wreckage. Hatches from the shared Lamprey Nest egg
-- pipeline (its own egg cost, shared concurrent egg cap).
Config.BROODMOTHER_EGG_COST       = 200  -- cost per egg / Broodmother (matches the unit cost)
Config.BROODMOTHER_CHARGE_TIME    = 4.0  -- seconds the orb swarm takes to form (animation in)
Config.BROODMOTHER_ACTIVE_TIME    = 5.0  -- seconds the swarm orbits + deals aura damage
Config.BROODMOTHER_RECHARGE_TIME  = 3.0  -- seconds before the swarm can be summoned again
Config.BROODMOTHER_AURA_TICK      = 0.5  -- seconds between aura damage ticks (uses attack damage per tick)
Config.BROODMOTHER_ORB_COUNT      = 14   -- glowing orbs in the swarm (client visual)
Config.BROODMOTHER_DEATH_DURATION = 10.2 -- total death sequence before final removal + brood hatch:
                                         -- ~1s impact + ribcage/egg burst, 5s gored on the ground, ~1.2s sink, then 3s to hatch
Config.BROODMOTHER_DEATH_EGGS     = 3    -- Lampreys born from the wreckage on death
Config.BROODMOTHER_SHAKE_RADIUS   = 90   -- studs; nearby player cameras shake on a Broodmother's death

-- Lamprey growth: each tree a Lamprey fells makes it 15% larger and tougher
-- (size + max HP scale together), compounding up to a hard cap so a forest-fed
-- Lamprey becomes a genuine threat without growing without bound.
Config.LAMPREY_GROWTH_PER_TREE  = 0.05  -- size & HP multiplier gained per tree felled
Config.LAMPREY_GROWTH_MAX_SCALE = 2.5   -- cap on cumulative size/HP scale (vs. base)

-- Monument (win condition — upgrade from Command Center)
Config.MONUMENT_COST         = 1500
Config.MONUMENT_WIN_DURATION = 300    -- seconds to hold monument for victory (5 minutes)
Config.MONUMENT_SIZE         = Vector3.new(5, 20, 5)

-- Mineral deposits
Config.DEPOSIT_TOTAL_RESOURCES  = 1000  -- total resources a deposit holds before depleting

-- Condition-based unlocks.
-- cond.type: "building" (cumulative placed), "kill" (enemies killed), "train" (units trained)
-- requires: tech name that must be done first
-- group: mutually-exclusive choice group — player picks one when any member's cond is met
-- Each unlock belongs to a category ("Infra" = economy/structures, "Army" = units/combat
-- upgrades) and maps to a unit/building so the upgrade UI can render a 3D preview.
-- `vp` = { kind = "unit"|"building", name = <type> }.
Config.UNLOCKS = {
	BetterMines      = { icon = "🏭", title = "Better Foundries", category = "Infra",
		vp = { kind = "building", name = "Foundry" },
		desc = "Foundries you build run hotter, refining a touch more each tick.",
		condText = "Build 3 Foundries", cond = { type = "building", name = "Foundry", count = 3 } },
	EliteUnits       = { icon = "⭐", title = "Elite Units", category = "Army",
		vp = { kind = "unit", name = "Elite" },
		desc = "Unlocks the Elite unit at the Bonfire.",
		condText = "Summon 5 Survivors", cond = { type = "train",    name = "Survivor",  count = 5 } },
	MedicUnit        = { icon = "➕", title = "Medic Unit", category = "Army",
		vp = { kind = "unit", name = "Medic" },
		desc = "Unlocks the Medic, which automatically heals nearby friendly units.",
		condText = "Build 2 Bonfires", cond = { type = "building", name = "Deployer", count = 2 } },
	TurretUpgrades   = { icon = "⚙", title = "Turret Upgrades", category = "Infra",
		vp = { kind = "building", name = "Turret" },
		desc = "Unlocks upgrade options for all Turrets.",
		condText = "Build 3 Turrets",  cond = { type = "building", name = "Turret",   count = 3 } },
	Relay            = { icon = "📡", title = "Relay", category = "Infra",
		vp = { kind = "building", name = "Relay" },
		desc = "Unlocks the Relay, extending your build zone by 65 studs.",
		condText = "Build 2 Bonfires", cond = { type = "building", name = "Deployer", count = 2 } },
	ConcussionShells = { icon = "💥", title = "Concussion Shells", category = "Army",
		vp = { kind = "unit", name = "Tank" },
		desc = "Tank shells slow enemy units on impact.",
		condText = "Kill 5 enemies",   cond = { type = "kill", count = 5 } },
	-- Survivor upgrades disabled for now (HardenedArmor / CombatStims / Rollers).
	-- Removing them from UNLOCKS hides them from the upgrade UI, blocks player +
	-- AI research, and makes hasResearch() always false so the runtime behaviors
	-- never activate. Re-enable by uncommenting these blocks.
	--[[
	HardenedArmor    = { icon = "🛡", title = "Hardened Armor", category = "Army",
		vp = { kind = "unit", name = "Survivor" },
		desc = "Survivors absorb a flat amount of damage per hit.",
		condText = "Kill 8 enemies",   cond = { type = "kill", count = 8 } },
	CombatStims      = { icon = "⚡", title = "Combat Stims", category = "Army",
		vp = { kind = "unit", name = "Survivor" },
		desc = "Survivors auto-boost speed and attack rate when engaging enemies.",
		condText = "Kill 10 enemies",  cond = { type = "kill", count = 10 } },
	--]]
	RocketBarrage    = { icon = "🚀", title = "Rocket Barrage", category = "Army",
		vp = { kind = "unit", name = "Tank" },
		desc = "Tanks fire 3 spiraling rockets, each dealing AoE splash damage.",
		condText = "Kill 15 enemies",  cond = { type = "kill", count = 15 },
		requires = "ConcussionShells", group = "TankSpec" },
	Trapper          = { icon = "🪝", title = "Trapper", category = "Army",
		vp = { kind = "unit", name = "Tank" },
		desc = "Tanks launch harpoons that slow enemies by 90% for 7 s.",
		condText = "Build 5 Turrets",  cond = { type = "building", name = "Turret", count = 5 },
		requires = "ConcussionShells", group = "TankSpec" },
	-- Survivor upgrade disabled for now (see HardenedArmor/CombatStims note above).
	--[[
	Rollers          = { icon = "🔄", title = "Rollers", category = "Army",
		vp = { kind = "unit", name = "Survivor" },
		desc = "Survivors become Rollers: rolling melee charge, 20% faster movement.",
		condText = "Kill 20 enemies",  cond = { type = "kill", count = 20 },
		requires = "CombatStims" },
	--]]
	CreepyBlob       = { icon = "🫧", title = "Creepy Blob", category = "Infra",
		vp = { kind = "building", name = "CreepyBlob" },
		desc = "Unlocks the Creepy Blob, which evolves into soldiers, a worm, or a turret.",
		condText = "Build 3 Relays",   cond = { type = "building", name = "Relay", count = 3 } },
	MobileCC         = { icon = "🦾", title = "Mobile CC", category = "Infra",
		vp = { kind = "building", name = "CommandCenter" },
		desc = "Unlocks Command Center mobility (building disabled while mobile).",
		condText = "Build 2 Foundries", cond = { type = "building", name = "Foundry", count = 2 } },
}

-- Tech upgrade pacing (manual research from the upgrade panel)
Config.UPGRADE_TIME            = 30  -- seconds each research takes once started
Config.MAX_CONCURRENT_RESEARCH = 2   -- max simultaneous in-progress researches per category

-- Foamer unit: deploy/undeploy animation + foam debuff
Config.FOAMER_DEPLOY_TIME     = 1.4   -- seconds to fully deploy (sink + barrel rise)
Config.FOAMER_UNDEPLOY_TIME   = 1.0   -- seconds to fully undeploy
Config.FOAMER_SINK_DEPTH      = 0.8   -- studs the body sinks during deploy
Config.FOAMER_FOAM_SLOW_MULT  = 0.30  -- speed multiplier while foamed (70% slow)
Config.FOAMER_FOAM_DURATION   = 3     -- seconds a foam hit lasts
Config.FOAMER_FOAM_DOT        = 8     -- damage per second while foamed

-- Howitzer: fire zone left at impact site (damages ALL units, both teams)
Config.HOWITZER_FIRE_RADIUS        = 10   -- studs radius of fire damage
Config.HOWITZER_FIRE_DMG_PER_SEC   = 15   -- damage per second at full intensity
Config.HOWITZER_FIRE_FULL_DURATION = 5    -- seconds of full-damage fire
Config.HOWITZER_FIRE_FADE_DURATION = 3    -- seconds of tapering fire after that

-- Tank: Rocket Barrage (requires ConcussionShells)
Config.ROCKET_BARRAGE_COUNT    = 3     -- rockets fired per attack cycle
Config.ROCKET_BARRAGE_DMG_MULT = 0.65  -- each rocket deals this fraction of base attack damage
Config.ROCKET_BARRAGE_SPREAD   = 5.0   -- max random landing offset per rocket in studs

-- Tank: Trapper (requires ConcussionShells, mutually exclusive with RocketBarrage)
Config.TRAPPER_HARPOON_MAX   = 5    -- maximum harpoons carried at once
Config.TRAPPER_SLOW_MULT     = 0.1  -- speed multiplier while harpooned (90% slow)
Config.TRAPPER_SLOW_DURATION = 7    -- seconds the harpoon slow lasts
Config.TRAPPER_RESTOCK_TIME  = 10   -- seconds to restock one harpoon

-- Survivor: Combat Stims
Config.SOLDIER_STIM_DURATION  = 8    -- seconds stims stay active
Config.SOLDIER_STIM_COOLDOWN  = 20   -- seconds before stims can reactivate
Config.SOLDIER_STIM_SPEED     = 1.5  -- move speed multiplier while stimmed
Config.SOLDIER_STIM_RATE      = 0.55 -- attack-rate period multiplier while stimmed (lower = faster)

-- Survivor: Hardened Armor
Config.SOLDIER_ARMOR          = 6    -- flat damage absorbed per incoming hit

-- ── Wounded soldiers: immobilization, rescue-dragging & field healing ──────────
-- At/below IMMOBILIZE_THRESHOLD HP, a soldier may collapse (prone, can still shoot
-- but can't move). The chance is rolled every CHECK_INTERVAL seconds and scales
-- from MIN_CHANCE (at the threshold) up to MAX_CHANCE (near death). Downed soldiers
-- are dragged back to the Command Center by available comrades and slowly healed.
Config.SOLDIER_IMMOBILIZE_THRESHOLD    = 0.25  -- HP ratio at/below which collapse can happen
Config.SOLDIER_IMMOBILIZE_CHECK_EVERY  = 0.75  -- seconds between collapse rolls
Config.SOLDIER_IMMOBILIZE_MIN_CHANCE   = 0.10  -- per-roll chance right at the threshold
Config.SOLDIER_IMMOBILIZE_MAX_CHANCE   = 0.85  -- per-roll chance as HP nears zero
Config.SOLDIER_PRONE_PITCH             = math.rad(72)  -- recline angle of a downed soldier (head up)
Config.SOLDIER_DRAG_SPEED              = 7     -- studs/s per dragging soldier (2 draggers = 2×)
Config.SOLDIER_DRAG_SLOTS              = 2     -- max comrades that can haul one casualty
Config.SOLDIER_HEAL_RADIUS             = 30    -- studs from the CC counted as "back at base"
Config.SOLDIER_HEAL_RATE               = 4     -- HP/s regained while healing at the CC
Config.SOLDIER_RECOVER_RATIO           = 0.6   -- HP ratio at which a soldier gets back up

-- Survivor: Rollers upgrade
Config.ROLLER_ATTACK_RANGE  = 14   -- studs; approach/engage range (wider for tracking)
Config.ROLLER_CHARGE_DIST   = 22   -- studs; fixed dash distance per attack (zips past target)
Config.ROLLER_CHARGE_SPEED  = 90   -- studs/s dash speed
Config.ROLLER_SPEED_MULT    = 1.2  -- 20% faster than base soldier
Config.ROLLER_ROLL_PER_STUD = 0.25 -- radians of X-roll (tire pitch) per stud traveled

-- Turret upgrade paths (mutually exclusive per turret, requires TurretUpgrades research)
Config.TURRET_UPGRADE_COST = { Flamethrower = 200, RocketLauncher = 225, Artillery = 400, Creepy = 275, Mutant = 350 }
Config.TURRET_CREEPY = { range = 45,  damage = 12,  rate = 0.5 }  -- was Evolved
Config.TURRET_FLAME  = { range = 28,  damage = 35,  rate = 0.6 }
Config.TURRET_ROCKET = { range = 70,  damage = 80,  rate = 3.5 }
-- Artillery: 4× base range, devastating, slow. Only fires at targets that are
-- spotted (within vision of a friendly unit/building) — never blind into fog.
Config.TURRET_ARTILLERY = { range = 200, damage = 130, rate = 5.0 }

-- Server-side vision (studs) — used by the Artillery spotter check. Mirrors the
-- fog-of-war reveal radii in FogManager so "can the artillery see it" matches
-- "is it out of the fog" for the owner.
Config.VISION_UNIT    = 65
Config.VISION_DEFAULT = 40
Config.VISION_RADIUS  = {
	CommandCenter = 75, Foundry = 55, Turret = 40, EngineeringPost = 50,
	Deployer = 50, Relay = 45, Monument = 60, CreepyWorm = 40, CreepyBlob = 45,
	LampreyNest = 50, TEST = 55,
}

-- Mutant turret → creepy soldier spawning
Config.CREEPY_SOLDIER_MAX            = 3
Config.CREEPY_SOLDIER_SPAWN_INTERVAL = 20  -- seconds between spawn checks

-- Turret
Config.TURRET_COST        = 100
Config.TURRET_RANGE       = 50    -- studs
Config.TURRET_DAMAGE      = 20
Config.TURRET_ATTACK_RATE = 1.5   -- seconds between shots

-- Build / train times (seconds)  —  CommandCenter is always instant
Config.BUILD_TIME       = { Deployer = 15, Turret = 10, Monument = 20, Relay = 12, CreepyWorm = 10, CreepyBlob = 12, LampreyNest = 18, Foundry = 20, EngineeringPost = 15, TEST = 12 }
Config.UNIT_TRAIN_TIME  = { Survivor = 6,   Sniper = 12, Tank = 12, Howitzer = 20, Elite = 18, Medic = 10, Foamer = 14, Lamprey = 18, Hagfish = 18, Broodmother = 22, CreepySoldier = 0 }

-- Combat / Health
Config.UNIT_HP             = { Survivor = 80,  Sniper = 60,  Tank = 250,  Howitzer = 220,  Elite = 180,  Medic = 70,   Foamer = 140, Lamprey = 240, Hagfish = 150, Broodmother = 420, CreepySoldier = 55 }
Config.BUILDING_HP         = { Deployer = 450, CommandCenter = 1000, Turret = 350, Monument = 3000, Relay = 250, CreepyWorm = 150, CreepyBlob = 350, LampreyNest = 600, Foundry = 800, EngineeringPost = 550, TEST = 600 }
Config.UNIT_ATTACK_DAMAGE  = { Survivor = 12,  Sniper = 85,  Tank = 35,   Howitzer = 70,   Elite = 25,   Medic = 22,   Foamer = 8,  Lamprey = 45,  Hagfish = 22,  Broodmother = 5,  CreepySoldier = 14 }
Config.UNIT_ATTACK_RANGE   = { Survivor = 15,  Sniper = 95,  Tank = 45,   Howitzer = 65,   Elite = 30,   Medic = 22,   Foamer = 22, Lamprey = 42,  Hagfish = 36,  Broodmother = 30, CreepySoldier = 13 }
Config.UNIT_ATTACK_RATE    = { Survivor = 0.8, Sniper = 3.5, Tank = 1.6,  Howitzer = 4.0,  Elite = 1.0,  Medic = 1.2,  Foamer = 1.8, Lamprey = 3.0, Hagfish = 6.0, Broodmother = 4.0, CreepySoldier = 0.7 }

-- Terrain obstacles (generated in lobby when terrain is toggled on)
Config.TERRAIN_AVOIDANCE_RADIUS = 9   -- studs; units steer away from obstacle edges within this distance

-- Camera
Config.CAMERA_PITCH          = 55    -- degrees down from horizon
Config.CAMERA_MOVE_SPEED     = 60
Config.CAMERA_ZOOM_MIN       = 20
Config.CAMERA_ZOOM_MAX       = 280
Config.CAMERA_ZOOM_STEP      = 12
Config.CAMERA_ROTATE_SPEED   = 80   -- degrees/sec for Q/E
Config.CAMERA_EDGE_THRESHOLD = 30   -- pixels from screen edge

-- Remote event names
Config.REMOTES = {
	TrainUnit        = "TrainUnit",
	MoveUnits        = "MoveUnits",
	FormationMove    = "FormationMove",
	PlaceBuilding    = "PlaceBuilding",
	SyncResources    = "SyncResources",
	UnitSpawned      = "UnitSpawned",
	BuildingPlaced   = "BuildingPlaced",
	UnitsOrderedMove = "UnitsOrderedMove",
	SyncDeposits      = "SyncDeposits",
	NeedCommandCenter = "NeedCommandCenter",
	TrainingUpdate    = "TrainingUpdate",
	TurretShot        = "TurretShot",
	AttackMoveUnits   = "AttackMoveUnits",
	FocusAttack       = "FocusAttack",
	UnitDied          = "UnitDied",
	UnitHit           = "UnitHit",
	UpgradeTurret     = "UpgradeTurret",
	UpgradeUnit       = "UpgradeUnit",
	UnlockGranted     = "UnlockGranted",
	UnlockChoice      = "UnlockChoice",
	UnlockChoose      = "UnlockChoose",
	RequestUpgrade    = "RequestUpgrade",
	UpgradeStarted    = "UpgradeStarted",
	BuildMonument    = "BuildMonument",
	MonumentProgress = "MonumentProgress",
	PlayerWon        = "PlayerWon",
	FoundryIncome           = "FoundryIncome",
	EngineeringStart        = "EngineeringStart",
	EngineeringCollect      = "EngineeringCollect",
	EngineeringRequest      = "EngineeringRequest",
	EngineeringSync         = "EngineeringSync",
	CCAttacked              = "CCAttacked",
	AttackAlert             = "AttackAlert",
	HealBeam                = "HealBeam",
	CometWave               = "CometWave",
	TentacleTargets         = "TentacleTargets",
	LobbySync               = "LobbySync",
	LobbyReady              = "LobbyReady",
	LobbyReroll             = "LobbyReroll",
	LobbyStart              = "LobbyStart",
	LobbySetColor           = "LobbySetColor",
	LobbySetFaction         = "LobbySetFaction",
	LobbyTerrainToggle      = "LobbyTerrainToggle",
	LobbyAddAI              = "LobbyAddAI",
	LobbyRemoveAI           = "LobbyRemoveAI",
	LobbyRemoveAIFull       = "LobbyRemoveAIFull",
	LobbySetAICount         = "LobbySetAICount",
	LobbySetAIDifficulty    = "LobbySetAIDifficulty",
	ShowEndScreen           = "ShowEndScreen",
	CondProgressSync        = "CondProgressSync",
	WormBurst               = "WormBurst",
	BlobProduce             = "BlobProduce",
	BlobUpdate              = "BlobUpdate",
	MobilizeCC              = "MobilizeCC",
	MoveMobileCC            = "MoveMobileCC",
	CCMobileSync            = "CCMobileSync",
	LobbySetGamemode        = "LobbySetGamemode",
	SpawnLaneUnit           = "SpawnLaneUnit",
	SetDeployerType         = "SetDeployerType",
	DeployerUpdate          = "DeployerUpdate",
	UpgradeDeployer         = "UpgradeDeployer",
	SetTestType             = "SetTestType",
	TestUpdate              = "TestUpdate",
	UpgradeTest             = "UpgradeTest",
	LampreyEgg              = "LampreyEgg",
	HagfishStrike           = "HagfishStrike",
	BroodmotherDeath        = "BroodmotherDeath",
	UpgradeNest             = "UpgradeNest",
	SetNestRally            = "SetNestRally",
	ForfeitMatch            = "ForfeitMatch",
	SellBuilding            = "SellBuilding",
	ShowDefeatScreen        = "ShowDefeatScreen",
	PlayAgain               = "PlayAgain",
}

return Config
