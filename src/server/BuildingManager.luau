local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local BuildingManager    = {}
local buildingsFolder: Folder
local counter            = 0
local mineralManager: any

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

-- Returns the new building id.
local function createBuilding(player: Player, position: Vector3, buildingType: string): string
	counter += 1
	local id = "b" .. counter

	local model     = Instance.new("Model")
	model.Name      = id

	local base      = Instance.new("Part")
	base.Name       = "Base"
	base.Size       = Config.BUILDING_SIZE
	base.Position   = position + Vector3.new(0, Config.BUILDING_SIZE.Y / 2, 0)
	base.BrickColor = player.TeamColor
	base.Material   = Enum.Material.SmoothPlastic
	base.Anchored   = true
	base.Parent     = model

	if buildingType == "Mine" then
		-- Glowing crystal finial — distinct from the Barracks flag
		local crystal      = Instance.new("Part")
		crystal.Name       = "Crystal"
		crystal.Size       = Vector3.new(2, 4, 2)
		crystal.Position   = position + Vector3.new(0, Config.BUILDING_SIZE.Y + 2, 0)
		crystal.BrickColor = BrickColor.new("Bright yellow")
		crystal.Material   = Enum.Material.Neon
		crystal.Anchored   = true
		crystal.Parent     = model
	else
		-- Thin neon flag (Barracks)
		local flag      = Instance.new("Part")
		flag.Name       = "Flag"
		flag.Size       = Vector3.new(0.6, 5, 0.6)
		flag.Position   = position + Vector3.new(0, Config.BUILDING_SIZE.Y + 2.5, 0)
		flag.BrickColor = player.TeamColor
		flag.Material   = Enum.Material.Neon
		flag.Anchored   = true
		flag.Parent     = model
	end

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = model

	local tv        = Instance.new("StringValue")
	tv.Name         = "BuildingType"
	tv.Value        = buildingType
	tv.Parent       = model

	model.PrimaryPart = base
	model.Parent      = buildingsFolder

	-- Include buildingType so clients can tell Barracks from Mine
	RemoteHandler.get(Config.REMOTES.BuildingPlaced):FireAllClients(
		id, player.UserId, position, buildingType
	)

	return id
end

function BuildingManager.init(resourceManager, mineralManager_)
	mineralManager        = mineralManager_
	buildingsFolder        = Instance.new("Folder")
	buildingsFolder.Name   = "Buildings"
	buildingsFolder.Parent = workspace

	RemoteHandler.get(Config.REMOTES.PlaceBuilding).OnServerEvent:Connect(function(player, pos, buildingType)
		if typeof(pos) ~= "Vector3" then return end
		if type(buildingType) ~= "string" then buildingType = "Barracks" end

		local snapped = snapGrid(pos)
		local cost    = buildingType == "Mine" and Config.MINE_COST or Config.BUILDING_COST

		-- Mine requires a valid unclaimed deposit at that position
		if buildingType == "Mine" then
			if not mineralManager or not mineralManager.tryClaimDeposit(snapped) then return end
		end

		if not resourceManager.spend(player, cost) then return end

		local id = createBuilding(player, snapped, buildingType)

		if buildingType == "Mine" then
			mineralManager.registerMine(id, snapped, player)
		end
	end)
end

return BuildingManager
