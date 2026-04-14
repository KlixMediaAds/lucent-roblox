local Config = {}

-- Economy
Config.STARTING_RESOURCES   = 400
Config.BUILDING_COST         = 50   -- Barracks cost
Config.MINE_COST             = 75   -- Mine building cost

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Soldier = { cost = 25, size = Vector3.new(4, 4, 4) },
	Tank    = { cost = 60, size = Vector3.new(7, 5, 9)  },
	Elite   = { cost = 100, size = Vector3.new(5, 6, 5), researchReq = "EliteUnits" },
	Medic   = { cost = 60,  size = Vector3.new(4, 4, 4), researchReq = "MedicUnit"  },
}

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = { Soldier = 26, Tank = 14, Elite = 20, Medic = 22 }  -- per-type max speed
Config.UNIT_ACCEL             = { Soldier = 12, Tank = 4,  Elite = 8,  Medic = 10 }  -- velocity lerp factor
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

-- Monument (win condition — upgrade from Command Center)
Config.MONUMENT_COST         = 1500
Config.MONUMENT_WIN_DURATION = 300    -- seconds to hold monument for victory (5 minutes)
Config.MONUMENT_SIZE         = Vector3.new(5, 20, 5)

-- Mine limits & depletion
Config.MAX_MINES                = 3     -- max mine buildings per player
Config.DEPOSIT_TOTAL_RESOURCES  = 1000  -- total resources a deposit holds before depleting
Config.MINE_DECAY_RATE          = 5     -- HP/second drained from a depleted mine

-- Mine upgrades (one per mine, mutually exclusive)
Config.MINE_UPGRADE_COST = { Efficiency = 150, Capacity = 125 }
Config.MINE_UPGRADE_EFFICIENCY_MULT  = 2.0   -- income per miner × this
Config.MINE_UPGRADE_CAPACITY_EXTRA   = 4     -- extra miner slots added

-- Research techs (time in seconds; no resource cost)
-- `requires`: if set, that tech must be done before this one can start.
Config.RESEARCH = {
	BetterMines       = { time = 5,  desc = "Unlocks the ability to upgrade mine buildings." },
	EliteUnits        = { time = 15, desc = "Unlocks the Elite unit at Barracks." },
	MedicUnit         = { time = 15, desc = "Unlocks the Medic unit at Barracks. Medics automatically heal damaged friendly units nearby." },
	TurretUpgrades    = { time = 20, desc = "Unlocks Flamethrower and Rocket Launcher upgrades for turrets." },
	ConcussionShells  = { time = 10, desc = "Tank shells slow enemy units on impact." },
	RocketBarrage     = { time = 18, requires = "ConcussionShells", desc = "Replaces the tank's attack with 3 spiraling rockets, each dealing AoE splash damage." },
	Trapper           = { time = 20, requires = "ConcussionShells", desc = "Replaces the tank's weapon with a harpoon launcher. Each harpoon slows an enemy by 90% for 7 s. Carries 5 harpoons, restocking one every 10 s." },
	CombatStims       = { time = 12, desc = "Soldiers automatically boost speed and attack rate when engaging enemies." },
	HardenedArmor     = { time = 10, desc = "Soldiers absorb a flat amount of damage per hit." },
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

-- Turret upgrade paths (mutually exclusive per turret, requires TurretUpgrades research)
Config.TURRET_UPGRADE_COST = { Flamethrower = 200, RocketLauncher = 225 }
Config.TURRET_FLAME  = { range = 28, damage = 35, rate = 0.6  }   -- short range, rapid fire
Config.TURRET_ROCKET = { range = 70, damage = 80, rate = 3.5  }   -- long range, high damage

-- Turret
Config.TURRET_COST        = 100
Config.TURRET_RANGE       = 50    -- studs
Config.TURRET_DAMAGE      = 20
Config.TURRET_ATTACK_RATE = 1.5   -- seconds between shots

-- Build / train times (seconds)  —  CommandCenter is always instant
Config.BUILD_TIME       = { Barracks = 15, Mine = 12, Turret = 10, Monument = 20 }
Config.UNIT_TRAIN_TIME  = { Soldier = 6,   Tank = 12, Elite = 18, Medic = 10 }

-- Combat / Health
Config.UNIT_HP             = { Soldier = 80,  Tank = 250,  Elite = 180,  Medic = 70   }
Config.BUILDING_HP         = { Barracks = 500, Mine = 300, CommandCenter = 1000, Turret = 350, Monument = 3000 }
Config.UNIT_ATTACK_DAMAGE  = { Soldier = 12,  Tank = 35,   Elite = 25,   Medic = 22   }  -- Medic value = heal per tick
Config.UNIT_ATTACK_RANGE   = { Soldier = 15, Tank = 45, Elite = 30, Medic = 22 }  -- studs per type
Config.UNIT_ATTACK_RATE    = { Soldier = 0.8, Tank = 1.6,  Elite = 1.0,  Medic = 1.2  }  -- seconds between attacks

-- Camera
Config.CAMERA_PITCH          = 55    -- degrees down from horizon
Config.CAMERA_MOVE_SPEED     = 60
Config.CAMERA_ZOOM_MIN       = 20
Config.CAMERA_ZOOM_MAX       = 150
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
	StartResearch     = "StartResearch",
	ResearchUpdate    = "ResearchUpdate",
	ResearchCompleted = "ResearchCompleted",
	BuildMonument    = "BuildMonument",
	MonumentProgress = "MonumentProgress",
	PlayerWon        = "PlayerWon",
	MineIncome              = "MineIncome",
	CCAttacked              = "CCAttacked",
	MineDepletionWarning    = "MineDepletionWarning",
	HealBeam                = "HealBeam",
	CometWave               = "CometWave",
	LobbySync               = "LobbySync",
	LobbyReady              = "LobbyReady",
	LobbyReroll             = "LobbyReroll",
	LobbyStart              = "LobbyStart",
}

return Config
