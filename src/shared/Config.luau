local Config = {}

-- Economy
Config.STARTING_RESOURCES   = 400
Config.BUILDING_COST         = 50   -- Barracks cost
Config.MINE_COST             = 75   -- Mine building cost

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Soldier       = { cost = 25,  size = Vector3.new(4, 4, 4) },
	Tank          = { cost = 60,  size = Vector3.new(7, 5, 9)  },
	Elite         = { cost = 100, size = Vector3.new(5, 6, 5), researchReq = "EliteUnits" },
	Medic         = { cost = 60,  size = Vector3.new(4, 4, 4), researchReq = "MedicUnit"  },
	CreepySoldier = { cost = 0,   size = Vector3.new(4, 4, 4) },  -- spawned free by Mutant turrets
}

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = { Soldier = 26, Tank = 14, Elite = 20, Medic = 22, CreepySoldier = 24 }
Config.UNIT_ACCEL             = { Soldier = 12, Tank = 4,  Elite = 8,  Medic = 10, CreepySoldier = 14 }
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

-- Mini Miners (spawned automatically by Mine buildings)
Config.MINI_MINER_SIZE           = Vector3.new(5, 4, 5)
Config.MINI_MINER_HP             = 100   -- health points per mini miner
Config.MINI_MINER_MAX            = 6
Config.MINI_MINER_SPAWN_INTERVAL = 30   -- seconds between new spawns
Config.MINI_MINER_INCOME         = 5    -- resources per tick per miner
Config.MINI_MINER_INCOME_INTERVAL = 10  -- seconds per income tick

-- Offsets (unit direction vectors) for Mini Miner positions around Mine center.
-- Order: N, E, S, W, NE, NW  (all 6 fill MINI_MINER_MAX exactly).
-- Multiply by BUILDING_SIZE.X at runtime for real-world spacing.
Config.MINER_OFFSETS = {
	Vector3.new( 0, 0, -1),  -- N
	Vector3.new( 1, 0,  0),  -- E
	Vector3.new( 0, 0,  1),  -- S
	Vector3.new(-1, 0,  0),  -- W
	Vector3.new( 1, 0, -1),  -- NE
	Vector3.new(-1, 0, -1),  -- NW
}

-- Command Center
Config.COMMAND_CENTER_SIZE     = Vector3.new(14, 10, 14)
Config.COMMAND_CENTER_MIN_DIST = 100   -- minimum studs between any two command centers
Config.BUILD_RADIUS            = 85    -- studs; non-CC buildings must be within this distance of the player's CC

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

-- Monument (win condition — upgrade from Command Center)
Config.MONUMENT_COST         = 1500
Config.MONUMENT_WIN_DURATION = 300    -- seconds to hold monument for victory (5 minutes)
Config.MONUMENT_SIZE         = Vector3.new(5, 20, 5)

-- Mine limits & deposits
Config.MAX_MINES                = math.huge  -- no cap on mine buildings per player
Config.DEPOSIT_TOTAL_RESOURCES  = 1000  -- total resources a deposit holds before depleting
Config.MINE_EXTRACT_RANGE       = 60    -- studs; mine scans for deposits within this radius
Config.MINE_EXTRACT_INTERVAL    = 5     -- seconds between extraction ticks
Config.MINE_INCOME_PER_DEPOSIT  = 8    -- resources per deposit per extraction tick

-- Condition-based unlocks.
-- cond.type: "building" (cumulative placed), "kill" (enemies killed), "train" (units trained)
-- requires: tech name that must be done first
-- group: mutually-exclusive choice group — player picks one when any member's cond is met
Config.UNLOCKS = {
	BetterMines      = { icon = "⛏", desc = "Mines gain upgrade options.",
		condText = "Build 3 Mines",    cond = { type = "building", name = "Mine",     count = 3 } },
	EliteUnits       = { icon = "⭐", desc = "Unlocks the Elite unit at Barracks.",
		condText = "Train 5 Soldiers", cond = { type = "train",    name = "Soldier",  count = 5 } },
	MedicUnit        = { icon = "➕", desc = "Unlocks the Medic unit. Medics automatically heal nearby friendly units.",
		condText = "Build 3 Barracks", cond = { type = "building", name = "Barracks", count = 3 } },
	TurretUpgrades   = { icon = "⚙", desc = "Unlocks upgrade options for all Turrets.",
		condText = "Build 3 Turrets",  cond = { type = "building", name = "Turret",   count = 3 } },
	Relay            = { icon = "📡", desc = "Unlocks the Relay building. Extends your build zone by 65 studs.",
		condText = "Build 2 Barracks", cond = { type = "building", name = "Barracks", count = 2 } },
	EyeUpgrade       = { icon = "👁", desc = "All units gain enhanced vision, increasing fog-of-war sight radius by 20%.",
		condText = "Build 8 structures", cond = { type = "building", name = "any",    count = 8 } },
	ConcussionShells = { icon = "💥", desc = "Tank shells slow enemy units on impact.",
		condText = "Kill 5 enemies",   cond = { type = "kill", count = 5 } },
	HardenedArmor    = { icon = "🛡", desc = "Soldiers absorb a flat amount of damage per hit.",
		condText = "Kill 8 enemies",   cond = { type = "kill", count = 8 } },
	CombatStims      = { icon = "⚡", desc = "Soldiers automatically boost speed and attack rate when engaging enemies.",
		condText = "Kill 10 enemies",  cond = { type = "kill", count = 10 } },
	RocketBarrage    = { icon = "🚀", desc = "Replaces the tank's attack with 3 spiraling rockets, each dealing AoE splash damage.",
		condText = "Kill 15 enemies",  cond = { type = "kill", count = 15 },
		requires = "ConcussionShells", group = "TankSpec" },
	Trapper          = { icon = "🪝", desc = "Replaces the tank's weapon with a harpoon launcher. Slows enemies by 90% for 7 s.",
		condText = "Build 5 Turrets",  cond = { type = "building", name = "Turret", count = 5 },
		requires = "ConcussionShells", group = "TankSpec" },
	Rollers          = { icon = "🔄", desc = "Soldiers become Rollers: rolling melee charge attack, 20% faster movement.",
		condText = "Kill 20 enemies",  cond = { type = "kill", count = 20 },
		requires = "CombatStims" },
	CreepyBlob       = { icon = "🫧", desc = "Unlocks the Creepy Blob. Evolve it into CreepySoldiers, a Creepy Worm, or a Creepy Turret.",
		condText = "Build 3 Relays",   cond = { type = "building", name = "Relay", count = 3 } },
	MobileCC         = { icon = "🦾", desc = "Unlocks mobility for your Command Center. Move it anywhere — but building is disabled while mobile.",
		condText = "Build 2 Mines",    cond = { type = "building", name = "Mine",  count = 2 } },
}

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

-- Eye Upgrade
Config.EYE_VISION_MULT = 1.2   -- 20% broader unit vision radius in fog of war

-- Soldier: Rollers upgrade
Config.ROLLER_ATTACK_RANGE  = 14   -- studs; approach/engage range (wider for tracking)
Config.ROLLER_CHARGE_DIST   = 22   -- studs; fixed dash distance per attack (zips past target)
Config.ROLLER_CHARGE_SPEED  = 90   -- studs/s dash speed
Config.ROLLER_SPEED_MULT    = 1.2  -- 20% faster than base soldier
Config.ROLLER_ROLL_PER_STUD = 0.25 -- radians of X-roll (tire pitch) per stud traveled

-- Turret upgrade paths (mutually exclusive per turret, requires TurretUpgrades research)
Config.TURRET_UPGRADE_COST = { Flamethrower = 200, RocketLauncher = 225, Creepy = 275, Mutant = 350 }
Config.TURRET_CREEPY = { range = 45, damage = 12, rate = 0.5 }  -- was Evolved
Config.TURRET_FLAME  = { range = 28, damage = 35, rate = 0.6  }
Config.TURRET_ROCKET = { range = 70, damage = 80, rate = 3.5  }

-- Mutant turret → creepy soldier spawning
Config.CREEPY_SOLDIER_MAX            = 3
Config.CREEPY_SOLDIER_SPAWN_INTERVAL = 20  -- seconds between spawn checks

-- Turret
Config.TURRET_COST        = 100
Config.TURRET_RANGE       = 50    -- studs
Config.TURRET_DAMAGE      = 20
Config.TURRET_ATTACK_RATE = 1.5   -- seconds between shots

-- Build / train times (seconds)  —  CommandCenter is always instant
Config.BUILD_TIME       = { Barracks = 15, Mine = 12, Turret = 10, Monument = 20, Relay = 12, CreepyWorm = 10, CreepyBlob = 12 }
Config.UNIT_TRAIN_TIME  = { Soldier = 6,   Tank = 12, Elite = 18, Medic = 10, CreepySoldier = 0 }

-- Combat / Health
Config.UNIT_HP             = { Soldier = 80,  Tank = 250,  Elite = 180,  Medic = 70,   CreepySoldier = 55  }
Config.BUILDING_HP         = { Barracks = 500, Mine = 300, CommandCenter = 1000, Turret = 350, Monument = 3000, Relay = 250, CreepyWorm = 150, CreepyBlob = 350 }
Config.UNIT_ATTACK_DAMAGE  = { Soldier = 12,  Tank = 35,   Elite = 25,   Medic = 22,   CreepySoldier = 14  }
Config.UNIT_ATTACK_RANGE   = { Soldier = 15,  Tank = 45,   Elite = 30,   Medic = 22,   CreepySoldier = 13  }
Config.UNIT_ATTACK_RATE    = { Soldier = 0.8, Tank = 1.6,  Elite = 1.0,  Medic = 1.2,  CreepySoldier = 0.7 }

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
	BuildMonument    = "BuildMonument",
	MonumentProgress = "MonumentProgress",
	PlayerWon        = "PlayerWon",
	MineIncome              = "MineIncome",
	MineBeams               = "MineBeams",
	CCAttacked              = "CCAttacked",
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
	ShowEndScreen           = "ShowEndScreen",
	CondProgressSync        = "CondProgressSync",
	WormBurst               = "WormBurst",
	BlobProduce             = "BlobProduce",
	BlobUpdate              = "BlobUpdate",
	MobilizeCC              = "MobilizeCC",
	MoveMobileCC            = "MoveMobileCC",
	CCMobileSync            = "CCMobileSync",
}

return Config
