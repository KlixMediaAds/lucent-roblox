local Config = {}

-- Economy
Config.STARTING_RESOURCES   = 400
Config.BUILDING_COST         = 50   -- Barracks cost
Config.MINE_COST             = 75   -- Mine building cost

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Soldier = { cost = 25, size = Vector3.new(4, 4, 4) },
	Tank    = { cost = 60, size = Vector3.new(7, 5, 9)  },
}

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = { Soldier = 26, Tank = 14 }  -- per-type max speed
Config.UNIT_ACCEL             = { Soldier = 12, Tank = 4  }  -- velocity lerp factor
Config.UNIT_FORMATION_SPACING = 7
Config.UNIT_AGGRO_RADIUS      = 40   -- studs; idle/A-move units spot enemies here
Config.UNIT_LEASH_RANGE       = 55   -- studs from aggro-start before retreating
Config.TANK_SPLASH_RANGE      = 10   -- studs AoE around building target on tank hit

-- Buildings
Config.BUILDING_SIZE         = Vector3.new(10, 8, 10)
Config.BUILDING_GRID         = 5     -- snap grid in studs

-- Mineral Deposits
Config.DEPOSIT_COUNT         = 8
Config.DEPOSIT_SIZE          = Vector3.new(5, 10, 5)
Config.DEPOSIT_SPREAD        = 150   -- half-extent of random placement area

-- Mini Miners (spawned automatically by Mine buildings)
Config.MINI_MINER_SIZE           = Vector3.new(5, 4, 5)
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

-- Mine limits & depletion
Config.MAX_MINES                = 3     -- max mine buildings per player
Config.DEPOSIT_TOTAL_RESOURCES  = 1000  -- total resources a deposit holds before depleting
Config.MINE_DECAY_RATE          = 5     -- HP/second drained from a depleted mine

-- Mine upgrades (one per mine, mutually exclusive)
Config.MINE_UPGRADE_COST = { Efficiency = 150, Capacity = 125 }
Config.MINE_UPGRADE_EFFICIENCY_MULT  = 2.0   -- income per miner × this
Config.MINE_UPGRADE_CAPACITY_EXTRA   = 4     -- extra miner slots added

-- Workshop
Config.WORKSHOP_COST      = 100

-- Research techs (time in seconds; no resource cost)
Config.RESEARCH = {
	BetterMines = { time = 5, desc = "Unlocks the ability to upgrade mine buildings." },
}

-- Turret
Config.TURRET_COST        = 100
Config.TURRET_RANGE       = 50    -- studs
Config.TURRET_DAMAGE      = 20
Config.TURRET_ATTACK_RATE = 1.5   -- seconds between shots

-- Build / train times (seconds)  —  CommandCenter is always instant
Config.BUILD_TIME       = { Barracks = 15, Mine = 12, Turret = 10, Workshop = 10 }
Config.UNIT_TRAIN_TIME  = { Soldier = 6,   Tank = 12 }

-- Combat / Health
Config.UNIT_HP             = { Soldier = 80,  Tank = 250  }
Config.BUILDING_HP         = { Barracks = 500, Mine = 300, CommandCenter = 1000, Turret = 350, Workshop = 400 }
Config.UNIT_ATTACK_DAMAGE  = { Soldier = 12,  Tank = 35   }
Config.UNIT_ATTACK_RANGE   = 15    -- studs
Config.UNIT_ATTACK_RATE    = { Soldier = 0.8, Tank = 1.6 }  -- seconds between attacks

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
	UnitHit           = "UnitHit",
	UpgradeMine       = "UpgradeMine",
	StartResearch     = "StartResearch",
	ResearchUpdate    = "ResearchUpdate",
	ResearchCompleted = "ResearchCompleted",
}

return Config
