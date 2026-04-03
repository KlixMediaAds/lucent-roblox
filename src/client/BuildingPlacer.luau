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
local currentSnapTarget: Vector3? = nil   -- Mine mode: deposit we're currently snapping to
local depositPositions: {Vector3} = {}    -- known unclaimed deposit positions
local ghost: Part?
local modeCb: ((boolean, string?) -> ())?
local networkRef: any
local cameraRef:  any

local GRID = Config.BUILDING_GRID

local function snap(v: Vector3): Vector3
	return Vector3.new(math.round(v.X / GRID) * GRID, v.Y, math.round(v.Z / GRID) * GRID)
end

-- Returns the nearest deposit to `cursor` (ignores Y), or nil if none exist.
local function nearestDeposit(cursor: Vector3): Vector3?
	if #depositPositions == 0 then return nil end
	local best, bestDist = depositPositions[1], math.huge
	for _, pos in depositPositions do
		local d = (Vector3.new(cursor.X, 0, cursor.Z) - pos).Magnitude
		if d < bestDist then bestDist = d; best = pos end
	end
	return best
end

local function makeGhost()
	if ghost then ghost:Destroy() end
	ghost              = Instance.new("Part")
	ghost.Name         = "__Ghost"
	ghost.Size         = Config.BUILDING_SIZE
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

	UserInputService.InputBegan:Connect(function(input, gpe)
		if not isPlacing then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and not gpe then
			if currentType == "Mine" then
				-- Only place if we have a valid deposit snapped
				if currentSnapTarget then
					network.placeBuilding(currentSnapTarget, "Mine")
					task.defer(BuildingPlacer.exitPlacementMode)
				end
				-- No valid deposit → do nothing (keeps mode open so player sees red ghost)
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
			-- Snap ghost to nearest deposit; turn red if none available
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
		else
			local pos = cameraModule.getPositionAtHeight(Config.BUILDING_SIZE.Y / 2)
			if pos then
				ghost.Position   = snap(pos)
				ghost.BrickColor = localPlayer.TeamColor
			end
		end
	end)
end

-- buildingType: "Barracks" (default) or "Mine"
function BuildingPlacer.enterPlacementMode(buildingType: string?)
	if isPlacing then return end
	currentType       = buildingType or "Barracks"
	currentSnapTarget = nil
	isPlacing         = true
	makeGhost()
	if modeCb then modeCb(true, currentType) end
end

function BuildingPlacer.exitPlacementMode()
	if not isPlacing then return end
	isPlacing         = false
	currentSnapTarget = nil
	if ghost then ghost:Destroy(); ghost = nil end
	if modeCb then modeCb(false, nil) end
end

function BuildingPlacer.isActive(): boolean
	return isPlacing
end

-- fn(active, buildingType?) — buildingType is nil when mode exits
function BuildingPlacer.onModeChanged(fn: (boolean, string?) -> ())
	modeCb = fn
end

-- Called once on join when the server sends the deposit list
function BuildingPlacer.setDepositPositions(positions: {Vector3})
	depositPositions = positions
end

-- Called when a deposit is claimed (remove it from the snap candidates)
function BuildingPlacer.removeDeposit(pos: Vector3)
	for i, p in depositPositions do
		if math.abs(p.X - pos.X) < 1 and math.abs(p.Z - pos.Z) < 1 then
			table.remove(depositPositions, i)
			return
		end
	end
end

return BuildingPlacer
