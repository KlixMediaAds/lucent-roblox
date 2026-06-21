local Config = {}

-- Gamemodes
Config.GAMEMODES = { Default = "Default", Lane = "Lane", Swarm = "Swarm" }

-- Economy
Config.STARTING_RESOURCES   = 400
Config.BUILDING_COST         = 50   -- Barracks cost
Config.MINE_COST             = 75   -- Mine building cost
Config.DEPLOYER_COST         = 100  -- Deployer building cost
Config.DEPLOYER_MAX_UNITS    = 4    -- max simultaneous auto-deployed soldiers per Deployer
Config.DEPLOYER_SPAWN_INTERVAL = 15 -- seconds between auto-spawn checks

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Soldier       = { cost = 25,  size = Vector3.new(4, 4, 4) },
	Tank          = { cost = 60,  size = Vector3.new(7, 5, 9)  },
	Howitzer      = { cost = 90,  size = Vector3.new(8, 14, 8) },
	Elite         = { cost = 100, size = Vector3.new(5, 6, 5), researchReq = "EliteUnits" },
	Medic         = { cost = 60,  size = Vector3.new(4, 4, 4), researchReq = "MedicUnit"  },
	Foamer        = { cost = 80,  size = Vector3.new(6, 5, 7)  },
	Lamprey       = { cost = 110, size = Vector3.new(7, 12, 7) },  -- massive burrowing lamprey (visuals drawn client-side)
	Hagfish       = { cost = 120, size = Vector3.new(6, 10, 6) },  -- slithering cobra-posed hagfish (visuals drawn client-side)
	CreepySoldier = { cost = 0,   size = Vector3.new(4, 4, 4) },  -- spawned free by Mutant turrets
	Core          = { cost = 0,   size = Vector3.new(5, 3, 6) },  -- mobile deploy seed: drops in, then transforms into the Command Center
	Harvester     = { cost = 75,  size = Vector3.new(5, 4, 5) },  -- mobile miner: deployed via "Mine" order, walks to a deposit, drains it, returns to the CC and stashes
}

-- Command Center deploy: the Core (above) lands from a drop pod, the player drives
-- it to a chosen spot, then presses DEPLOY to transform it into the CC.
Config.CORE_DEPLOY_TIME       = 3     -- seconds the Core takes to transform into the Command Center
Config.CC_PASSIVE_INCOME      = 10    -- resources granted per tick to every standing Command Center
Config.CC_PASSIVE_INTERVAL    = 6     -- seconds between Command Center passive-income ticks

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = { Soldier = 26, Tank = 14, Howitzer = 9,  Elite = 20, Medic = 22, Foamer = 11, Lamprey = 13, Hagfish = 15, CreepySoldier = 24, Core = 42, Harvester = 18 }
Config.UNIT_ACCEL             = { Soldier = 12, Tank = 4,  Howitzer = 3,  Elite = 8,  Medic = 10, Foamer = 3,  Lamprey = 3,  Hagfish = 4,  CreepySoldier = 14, Core = 20, Harvester = 8 }
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

-- Lamprey growth: each tree a Lamprey fells makes it 15% larger and tougher
-- (size + max HP scale together), compounding up to a hard cap so a forest-fed
-- Lamprey becomes a genuine threat without growing without bound.
Config.LAMPREY_GROWTH_PER_TREE  = 0.15  -- size & HP multiplier gained per tree felled
Config.LAMPREY_GROWTH_MAX_SCALE = 2.5   -- cap on cumulative size/HP scale (vs. base)

-- Monument (win condition — upgrade from Command Center)
Config.MONUMENT_COST         = 1500
Config.MONUMENT_WIN_DURATION = 300    -- seconds to hold monument for victory (5 minutes)
Config.MONUMENT_SIZE         = Vector3.new(5, 20, 5)

-- Harvester limits & deposits
Config.MAX_MINES                = math.huge  -- no cap on active harvesters deployed per player
Config.DEPOSIT_TOTAL_RESOURCES  = 1000  -- total resources a deposit holds before depleting
Config.MINE_EXTRACT_RANGE       = 60    -- studs; a parked harvester drains deposits within this radius of its deploy point
Config.MINE_EXTRACT_INTERVAL    = 5     -- seconds between harvester drain ticks
Config.MINE_INCOME_PER_DEPOSIT  = 8    -- resources drained per deposit per drain tick

-- Condition-based unlocks.
-- cond.type: "building" (cumulative placed), "kill" (enemies killed), "train" (units trained)
-- requires: tech name that must be done first
-- group: mutually-exclusive choice group — player picks one when any member's cond is met
-- Each unlock belongs to a category ("Infra" = economy/structures, "Army" = units/combat
-- upgrades) and maps to a unit/building so the upgrade UI can render a 3D preview.
-- `vp` = { kind = "unit"|"building", name = <type> }.
Config.UNLOCKS = {
	BetterMines      = { icon = "⛏", title = "Better Mines", category = "Infra",
		vp = { kind = "building", name = "Mine" },
		desc = "Mines gain upgrade options.",
		condText = "Build 3 Mines",    cond = { type = "building", name = "Mine",     count = 3 } },
	EliteUnits       = { icon = "⭐", title = "Elite Units", category = "Army",
		vp = { kind = "unit", name = "Elite" },
		desc = "Unlocks the Elite unit at Barracks.",
		condText = "Train 5 Soldiers", cond = { type = "train",    name = "Soldier",  count = 5 } },
	MedicUnit        = { icon = "➕", title = "Medic Unit", category = "Army",
		vp = { kind = "unit", name = "Medic" },
		desc = "Unlocks the Medic, which automatically heals nearby friendly units.",
		condText = "Build 3 Barracks", cond = { type = "building", name = "Barracks", count = 3 } },
	TurretUpgrades   = { icon = "⚙", title = "Turret Upgrades", category = "Infra",
		vp = { kind = "building", name = "Turret" },
		desc = "Unlocks upgrade options for all Turrets.",
		condText = "Build 3 Turrets",  cond = { type = "building", name = "Turret",   count = 3 } },
	Relay            = { icon = "📡", title = "Relay", category = "Infra",
		vp = { kind = "building", name = "Relay" },
		desc = "Unlocks the Relay, extending your build zone by 65 studs.",
		condText = "Build 2 Barracks", cond = { type = "building", name = "Barracks", count = 2 } },
	ConcussionShells = { icon = "💥", title = "Concussion Shells", category = "Army",
		vp = { kind = "unit", name = "Tank" },
		desc = "Tank shells slow enemy units on impact.",
		condText = "Kill 5 enemies",   cond = { type = "kill", count = 5 } },
	HardenedArmor    = { icon = "🛡", title = "Hardened Armor", category = "Army",
		vp = { kind = "unit", name = "Soldier" },
		desc = "Soldiers absorb a flat amount of damage per hit.",
		condText = "Kill 8 enemies",   cond = { type = "kill", count = 8 } },
	CombatStims      = { icon = "⚡", title = "Combat Stims", category = "Army",
		vp = { kind = "unit", name = "Soldier" },
		desc = "Soldiers auto-boost speed and attack rate when engaging enemies.",
		condText = "Kill 10 enemies",  cond = { type = "kill", count = 10 } },
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
	Rollers          = { icon = "🔄", title = "Rollers", category = "Army",
		vp = { kind = "unit", name = "Soldier" },
		desc = "Soldiers become Rollers: rolling melee charge, 20% faster movement.",
		condText = "Kill 20 enemies",  cond = { type = "kill", count = 20 },
		requires = "CombatStims" },
	CreepyBlob       = { icon = "🫧", title = "Creepy Blob", category = "Infra",
		vp = { kind = "building", name = "CreepyBlob" },
		desc = "Unlocks the Creepy Blob, which evolves into soldiers, a worm, or a turret.",
		condText = "Build 3 Relays",   cond = { type = "building", name = "Relay", count = 3 } },
	MobileCC         = { icon = "🦾", title = "Mobile CC", category = "Infra",
		vp = { kind = "building", name = "CommandCenter" },
		desc = "Unlocks Command Center mobility (building disabled while mobile).",
		condText = "Build 2 Mines",    cond = { type = "building", name = "Mine",  count = 2 } },
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

-- Soldier: Combat Stims
Config.SOLDIER_STIM_DURATION  = 8    -- seconds stims stay active
Config.SOLDIER_STIM_COOLDOWN  = 20   -- seconds before stims can reactivate
Config.SOLDIER_STIM_SPEED     = 1.5  -- move speed multiplier while stimmed
Config.SOLDIER_STIM_RATE      = 0.55 -- attack-rate period multiplier while stimmed (lower = faster)

-- Soldier: Hardened Armor
Config.SOLDIER_ARMOR          = 6    -- flat damage absorbed per incoming hit

-- Soldier: Rollers upgrade
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
	CommandCenter = 75, Barracks = 50, Mine = 45, Turret = 40,
	Deployer = 50, Relay = 45, Monument = 60, CreepyWorm = 40, CreepyBlob = 45,
	LampreyNest = 50,
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
Config.BUILD_TIME       = { Barracks = 15, Deployer = 15, Turret = 10, Monument = 20, Relay = 12, CreepyWorm = 10, CreepyBlob = 12, LampreyNest = 18 }
Config.UNIT_TRAIN_TIME  = { Soldier = 6,   Tank = 12, Howitzer = 20, Elite = 18, Medic = 10, Foamer = 14, Lamprey = 18, Hagfish = 18, CreepySoldier = 0, Core = 0 }

-- Combat / Health
Config.UNIT_HP             = { Soldier = 80,  Tank = 250,  Howitzer = 220,  Elite = 180,  Medic = 70,   Foamer = 140, Lamprey = 240, Hagfish = 150, CreepySoldier = 55,  Core = 250, Harvester = 300 }
Config.BUILDING_HP         = { Barracks = 500, Deployer = 450, CommandCenter = 1000, Turret = 350, Monument = 3000, Relay = 250, CreepyWorm = 150, CreepyBlob = 350, LampreyNest = 600 }
Config.UNIT_ATTACK_DAMAGE  = { Soldier = 12,  Tank = 35,   Howitzer = 70,   Elite = 25,   Medic = 22,   Foamer = 8,  Lamprey = 45,  Hagfish = 22,  CreepySoldier = 14,  Core = 0,  Harvester = 0 }
Config.UNIT_ATTACK_RANGE   = { Soldier = 15,  Tank = 45,   Howitzer = 65,   Elite = 30,   Medic = 22,   Foamer = 22, Lamprey = 42,  Hagfish = 36,  CreepySoldier = 13,  Core = 0,  Harvester = 0 }
Config.UNIT_ATTACK_RATE    = { Soldier = 0.8, Tank = 1.6,  Howitzer = 4.0,  Elite = 1.0,  Medic = 1.2,  Foamer = 1.8, Lamprey = 3.0, Hagfish = 6.0, CreepySoldier = 0.7, Core = 1.0, Harvester = 1.0 }

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
	DepositClaimed    = "DepositClaimed",
	MinerSpawned      = "MinerSpawned",
	NeedCommandCenter = "NeedCommandCenter",
	TrainingUpdate    = "TrainingUpdate",
	TurretShot        = "TurretShot",
	AttackMoveUnits   = "AttackMoveUnits",
	FocusAttack       = "FocusAttack",
	UnitDied          = "UnitDied",
	UnitHit           = "UnitHit",
	UpgradeMine       = "UpgradeMine",
	UpgradeTurret     = "UpgradeTurret",
	UnlockGranted     = "UnlockGranted",
	UnlockChoice      = "UnlockChoice",
	UnlockChoose      = "UnlockChoose",
	RequestUpgrade    = "RequestUpgrade",
	UpgradeStarted    = "UpgradeStarted",
	BuildMonument    = "BuildMonument",
	MonumentProgress = "MonumentProgress",
	PlayerWon        = "PlayerWon",
	MineIncome              = "MineIncome",
	MineBeams               = "MineBeams",
	HarvesterStash          = "HarvesterStash",
	CCAttacked              = "CCAttacked",
	AttackAlert             = "AttackAlert",
	MineDepletionWarning    = "MineDepletionWarning",
	HealBeam                = "HealBeam",
	CometWave               = "CometWave",
	TentacleTargets         = "TentacleTargets",
	LobbySync               = "LobbySync",
	LobbyReady              = "LobbyReady",
	LobbyReroll             = "LobbyReroll",
	LobbyStart              = "LobbyStart",
	LobbySetColor           = "LobbySetColor",
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
	LampreyEgg              = "LampreyEgg",
	HagfishStrike           = "HagfishStrike",
	UpgradeNest             = "UpgradeNest",
	SetNestRally            = "SetNestRally",
	ForfeitMatch            = "ForfeitMatch",
	SellBuilding            = "SellBuilding",
	CorePodLaunched         = "CorePodLaunched",
	DeployCore              = "DeployCore",
}

return Config
