local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local BuildingManager    = {}
local buildingsFolder: Folder
local counter            = 0

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

local function createBuilding(player: Player, position: Vector3)
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

	-- Small neon flag on top
	local flag      = Instance.new("Part")
	flag.Name       = "Flag"
	flag.Size       = Vector3.new(0.6, 5, 0.6)
	flag.Position   = position + Vector3.new(0, Config.BUILDING_SIZE.Y + 2.5, 0)
	flag.BrickColor = player.TeamColor
	flag.Material   = Enum.Material.Neon
	flag.Anchored   = true
	flag.Parent     = model

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = model

	model.PrimaryPart = base
	model.Parent      = buildingsFolder

	RemoteHandler.get(Config.REMOTES.BuildingPlaced):FireAllClients(id, player.UserId, position)
end

function BuildingManager.init(resourceManager)
	buildingsFolder        = Instance.new("Folder")
	buildingsFolder.Name   = "Buildings"
	buildingsFolder.Parent = workspace

	RemoteHandler.get(Config.REMOTES.PlaceBuilding).OnServerEvent:Connect(function(player, pos)
		if typeof(pos) ~= "Vector3" then return end
		local snapped = snapGrid(pos)
		if not resourceManager.spend(player, Config.BUILDING_COST) then return end
		createBuilding(player, snapped)
	end)
end

return BuildingManager
