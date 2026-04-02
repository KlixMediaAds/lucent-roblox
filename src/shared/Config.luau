local Config = {}

-- Economy
Config.STARTING_RESOURCES   = 100
Config.UNIT_COST             = 25
Config.BUILDING_COST         = 50

-- Units
Config.UNIT_SIZE             = Vector3.new(4, 4, 4)
Config.UNIT_MOVE_SPEED       = 22
Config.UNIT_FORMATION_SPACING = 7

-- Buildings
Config.BUILDING_SIZE         = Vector3.new(10, 8, 10)
Config.BUILDING_GRID         = 5     -- snap grid in studs

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
	SpawnUnit        = "SpawnUnit",
	MoveUnits        = "MoveUnits",
	PlaceBuilding    = "PlaceBuilding",
	SyncResources    = "SyncResources",
	UnitSpawned      = "UnitSpawned",
	BuildingPlaced   = "BuildingPlaced",
	UnitsOrderedMove = "UnitsOrderedMove",
}

return Config
