local Config = {}

-- Economy
Config.STARTING_RESOURCES   = 100
Config.BUILDING_COST         = 50   -- Barracks cost
Config.MINE_COST             = 75   -- Mine building cost

-- Unit types (trained from Barracks)
Config.UNIT_TYPES = {
	Soldier = { cost = 25, size = Vector3.new(4, 4, 4) },
	Tank    = { cost = 60, size = Vector3.new(7, 5, 9)  },
}

-- Units (shared movement config)
Config.UNIT_MOVE_SPEED        = 22
Config.UNIT_FORMATION_SPACING = 7

-- Buildings
Config.BUILDING_SIZE         = Vector3.new(10, 8, 10)
Config.BUILDING_GRID         = 5     -- snap grid in studs

-- Mineral Deposits
Config.DEPOSIT_COUNT         = 8
Config.DEPOSIT_SIZE          = Vector3.new(8, 1.5, 8)
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
	SyncDeposits     = "SyncDeposits",
	DepositClaimed   = "DepositClaimed",
	MinerSpawned     = "MinerSpawned",
}

return Config
