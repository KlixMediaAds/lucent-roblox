local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local BuildingPlacer = {}
local localPlayer    = Players.LocalPlayer

local isPlacing           = false
local currentType         = "Barracks"
local currentSnapTarget: Vector3? = nil   -- Mine mode: deposit we're snapping to
local ccTooClose          = false          -- CommandCenter mode: ghost is red
local depositPositions: {Vector3} = {}
local ccPositions: {Vector3}      = {}     -- all known CC positions
local ghost: Part?
local modeCb: ((boolean, string?) -> ())?
local networkRef: any
local cameraRef:  any

local GRID = Config.BUILDING_GRID

local function snap(v: Vector3): Vector3
	return Vector3.new(math.round(v.X / GRID) * GRID, v.Y, math.round(v.Z / GRID) * GRID)
end

local function ghostSize(buildingType: string): Vector3
	return buildingType == "CommandCenter" and Config.COMMAND_CENTER_SIZE or Config.BUILDING_SIZE
end

local function nearestDeposit(cursor: Vector3): Vector3?
	if #depositPositions == 0 then return nil end
	local best, bestDist = depositPositions[1], math.huge
	for _, pos in depositPositions do
		local d = (Vector3.new(cursor.X, 0, cursor.Z) - pos).Magnitude
		if d < bestDist then bestDist = d; best = pos end
	end
	return best
end

local function isCCTooClose(pos: Vector3): boolean
	for _, ccPos in ccPositions do
		local d = Vector3.new(pos.X, 0, pos.Z) - Vector3.new(ccPos.X, 0, ccPos.Z)
		if d.Magnitude < Config.COMMAND_CENTER_MIN_DIST then return true end
	end
	return false
end

local function makeGhost()
	if ghost then ghost:Destroy() end
	ghost              = Instance.new("Part")
	ghost.Name         = "__Ghost"
	ghost.Size         = ghostSize(currentType)
	ghost.Anchored     = true
	ghost.CanCollide   = false
	ghost.CanQuery     = false
	ghost.Transparency = 0.5
	ghost.BrickColor   = localPlayer.TeamColor
	ghost.Material     = Enum.Material.SmoothPlastic
	ghost.Parent       = workspace
end

function BuildingPlacer.init(network, cameraModule)
	networkRef = network
	cameraRef  = cameraModule

	-- Track all CC positions for min-distance validation
	network.onBuildingPlaced(function(_id: string, _ownerId: number, pos: Vector3, buildingType: string)
		if buildingType == "CommandCenter" then
			table.insert(ccPositions, pos)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if not isPlacing then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and not gpe then
			if currentType == "Mine" then
				if currentSnapTarget then
					network.placeBuilding(currentSnapTarget, "Mine")
					task.defer(BuildingPlacer.exitPlacementMode)
				end

			elseif currentType == "CommandCenter" then
				if not ccTooClose then
					local halfH = Config.COMMAND_CENTER_SIZE.Y / 2
					local pos   = cameraModule.getPositionAtHeight(halfH)
					if pos then
						network.placeBuilding(snap(pos), "CommandCenter")
						task.defer(BuildingPlacer.exitPlacementMode)
					end
				end
				-- Red = too close → do nothing (keeps mode open)

			else
				local pos = cameraModule.getPositionAtHeight(Config.BUILDING_SIZE.Y / 2)
				if pos then
					network.placeBuilding(snap(pos), currentType)
				end
				task.defer(BuildingPlacer.exitPlacementMode)
			end

		elseif input.UserInputType == Enum.UserInputType.MouseButton2
			or input.KeyCode == Enum.KeyCode.Escape then
			task.defer(BuildingPlacer.exitPlacementMode)
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not isPlacing or not ghost then return end

		if currentType == "Mine" then
			local cursor = cameraModule.getPositionAtHeight(0)
			if cursor then
				local dep = nearestDeposit(cursor)
				if dep then
					currentSnapTarget  = dep
					ghost.Position     = dep + Vector3.new(0, Config.BUILDING_SIZE.Y / 2, 0)
					ghost.BrickColor   = localPlayer.TeamColor
					ghost.Transparency = 0.5
				else
					currentSnapTarget  = nil
					ghost.Position     = Vector3.new(cursor.X, Config.BUILDING_SIZE.Y / 2, cursor.Z)
					ghost.BrickColor   = BrickColor.new("Bright red")
					ghost.Transparency = 0.65
				end
			end

		elseif currentType == "CommandCenter" then
			local halfH = Config.COMMAND_CENTER_SIZE.Y / 2
			local pos   = cameraModule.getPositionAtHeight(halfH)
			if pos then
				local snapped = snap(pos)
				ccTooClose    = isCCTooClose(snapped)
				ghost.Position  = snapped
				ghost.BrickColor = ccTooClose and BrickColor.new("Bright red") or localPlayer.TeamColor
				ghost.Transparency = ccTooClose and 0.65 or 0.5
			end

		else
			local pos = cameraModule.getPositionAtHeight(Config.BUILDING_SIZE.Y / 2)
			if pos then
				ghost.Position   = snap(pos)
				ghost.BrickColor = localPlayer.TeamColor
			end
		end
	end)
end

function BuildingPlacer.enterPlacementMode(buildingType: string?)
	if isPlacing then return end
	currentType       = buildingType or "Barracks"
	currentSnapTarget = nil
	ccTooClose        = false
	isPlacing         = true
	makeGhost()
	if modeCb then modeCb(true, currentType) end
end

function BuildingPlacer.exitPlacementMode()
	if not isPlacing then return end
	isPlacing         = false
	currentSnapTarget = nil
	ccTooClose        = false
	if ghost then ghost:Destroy(); ghost = nil end
	if modeCb then modeCb(false, nil) end
end

function BuildingPlacer.isActive(): boolean
	return isPlacing
end

function BuildingPlacer.onModeChanged(fn: (boolean, string?) -> ())
	modeCb = fn
end

function BuildingPlacer.setDepositPositions(positions: {Vector3})
	depositPositions = positions
end

function BuildingPlacer.removeDeposit(pos: Vector3)
	for i, p in depositPositions do
		if math.abs(p.X - pos.X) < 1 and math.abs(p.Z - pos.Z) < 1 then
			table.remove(depositPositions, i)
			return
		end
	end
end

return BuildingPlacer
