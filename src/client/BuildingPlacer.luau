local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config"))

local BuildingPlacer = {}
local localPlayer    = Players.LocalPlayer

local isPlacing = false
local ghost: Part?
local modeCb: ((boolean) -> ())?
local networkRef: any
local cameraRef:  any

local GRID = Config.BUILDING_GRID

local function snap(v: Vector3): Vector3
	return Vector3.new(math.round(v.X / GRID) * GRID, v.Y, math.round(v.Z / GRID) * GRID)
end

local function makeGhost()
	if ghost then ghost:Destroy() end
	ghost              = Instance.new("Part")
	ghost.Name         = "__Ghost"
	ghost.Size         = Config.BUILDING_SIZE
	ghost.Anchored     = true
	ghost.CanCollide   = false
	ghost.CanQuery     = false   -- invisible to raycasts
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
			-- Use center height so click position matches what the ghost showed
			local pos = cameraModule.getPositionAtHeight(Config.BUILDING_SIZE.Y / 2)
			if pos then
				network.placeBuilding(snap(pos))
			end
			-- Defer so isPlacing stays true for this frame's other InputBegan handlers
			task.defer(BuildingPlacer.exitPlacementMode)

		elseif input.UserInputType == Enum.UserInputType.MouseButton2
			or input.KeyCode == Enum.KeyCode.Escape then
			task.defer(BuildingPlacer.exitPlacementMode)
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not isPlacing or not ghost then return end
		-- Intersect at ghost center height so the ghost visually tracks the cursor
		local pos = cameraModule.getPositionAtHeight(Config.BUILDING_SIZE.Y / 2)
		if pos then
			ghost.Position = snap(pos)
		end
	end)
end

function BuildingPlacer.enterPlacementMode()
	if isPlacing then return end
	isPlacing = true
	makeGhost()
	if modeCb then modeCb(true) end
end

function BuildingPlacer.exitPlacementMode()
	if not isPlacing then return end
	isPlacing = false
	if ghost then ghost:Destroy(); ghost = nil end
	if modeCb then modeCb(false) end
end

function BuildingPlacer.isActive(): boolean
	return isPlacing
end

function BuildingPlacer.onModeChanged(fn: (boolean) -> ())
	modeCb = fn
end

return BuildingPlacer
