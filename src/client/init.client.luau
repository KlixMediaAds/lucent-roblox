local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")

local Network        = require(script:WaitForChild("Network"))
local CameraModule   = require(script:WaitForChild("Camera"))
local BuildingPlacer = require(script:WaitForChild("BuildingPlacer"))
local UnitController = require(script:WaitForChild("UnitController"))
local HUD            = require(script:WaitForChild("HUD"))

local BLUE   = Color3.fromRGB(40,  90, 150)
local ORANGE = Color3.fromRGB(150, 80,  20)

local isSpawning = false

local function isBlocked(): boolean
	return isSpawning or BuildingPlacer.isActive()
end

-- Disable default character controls so WASD only moves the RTS camera.
-- BindToRenderStep in Camera already overrides Roblox's camera script.
task.spawn(function()
	local ok, PlayerModule = pcall(require,
		Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	if ok then
		PlayerModule:GetControls():Disable()
	end
end)

-- Initialise in dependency order (earlier init = earlier InputBegan priority)
CameraModule.init()
BuildingPlacer.init(Network, CameraModule)

local dragFrame, spawnBtn, buildBtn, cancelBtn = HUD.create()

-- UnitController connects InputBegan AFTER BuildingPlacer, so BuildingPlacer
-- always handles its clicks first and isBlocked() reflects the updated state.
UnitController.init(Network, CameraModule, dragFrame, isBlocked)

HUD.wire(Network, UnitController, BuildingPlacer, buildBtn, cancelBtn)

-- Spawn mode: connected last so UnitController's InputBegan fires before ours,
-- sees isBlocked()=true, and skips drag-start for this click.
spawnBtn.MouseButton1Click:Connect(function()
	if isBlocked() then return end
	isSpawning            = true
	spawnBtn.Text         = "Click ground..."
	spawnBtn.BackgroundColor3 = ORANGE

	local conn
	conn = UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		local done = false

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local pos = CameraModule.getGroundPosition()
			if pos then Network.spawnUnit(pos) end
			done = true
		elseif input.KeyCode == Enum.KeyCode.Escape
			or input.UserInputType == Enum.UserInputType.MouseButton2 then
			done = true
		end

		if done then
			conn:Disconnect()
			isSpawning                = false
			spawnBtn.Text             = "Spawn Unit (25)"
			spawnBtn.BackgroundColor3 = BLUE
		end
	end)
end)
