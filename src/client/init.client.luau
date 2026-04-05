local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local Network        = require(script:WaitForChild("Network"))
local CameraModule   = require(script:WaitForChild("Camera"))
local BuildingPlacer = require(script:WaitForChild("BuildingPlacer"))
local UnitController = require(script:WaitForChild("UnitController"))
local BarracksPanel  = require(script:WaitForChild("BarracksPanel"))
local HUD            = require(script:WaitForChild("HUD"))
local FogManager     = require(script:WaitForChild("FogManager"))

-- Disable default character controls so WASD only moves the RTS camera.
task.spawn(function()
	local ok, PlayerModule = pcall(require,
		Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	if ok then PlayerModule:GetControls():Disable() end
end)

local localUserId = Players.LocalPlayer.UserId

-- Resources per minute each miner generates
local INCOME_PER_MINER = Config.MINI_MINER_INCOME * (60 / Config.MINI_MINER_INCOME_INTERVAL)

-- mineId → current miner count (only this player's mines)
local mineMiners: { [string]: number } = {}

-- buildingType → count of owned (non-CC) buildings for requirement system
local ownedBuildingCounts: { [string]: number } = {}

local function totalIncome(): number
	local total = 0
	for _, count in mineMiners do total += count end
	return total * INCOME_PER_MINER
end

local function clearMinerData()
	mineMiners = {}
	HUD.setIncome(0)
end

local function refreshRequirements()
	HUD.refreshTrayState(ownedBuildingCounts)
end

local function isBlocked(): boolean
	return BuildingPlacer.isActive()
end

CameraModule.init()
BuildingPlacer.init(Network, CameraModule)

local dragFrame, buildBtn, mineBtn, turretBtn, cancelBtn, ccBtn = HUD.create()

UnitController.init(Network, CameraModule, dragFrame, isBlocked)
BarracksPanel.init(Network)
FogManager.init(localUserId)

HUD.wire(Network, UnitController, BuildingPlacer, buildBtn, mineBtn, turretBtn, cancelBtn)

-- ── Command Center mode ───────────────────────────────────────────────────────

local function enterCCMode()
	BuildingPlacer.exitPlacementMode()
	clearMinerData()
	ownedBuildingCounts = {}
	refreshRequirements()
	HUD.setCommandCenterMode(true)
end

Network.onNeedCommandCenter(function()
	enterCCMode()
end)

ccBtn.MouseButton1Click:Connect(function()
	BuildingPlacer.enterPlacementMode("CommandCenter")
end)

Network.onBuildingPlaced(function(id: string, ownerId: number, _pos: Vector3, buildingType: string)
	if buildingType == "CommandCenter" and ownerId == localUserId then
		HUD.setCommandCenterMode(false)
	end

	-- Track this player's non-CC buildings for the requirement system
	if ownerId == localUserId and buildingType ~= "CommandCenter" then
		ownedBuildingCounts[buildingType] = (ownedBuildingCounts[buildingType] or 0) + 1
		refreshRequirements()

		-- Decrement when the building is destroyed
		task.spawn(function()
			local buildingsFolder = workspace:FindFirstChild("Buildings")
				or workspace:WaitForChild("Buildings", 10) :: Folder?
			if not buildingsFolder then return end
			local model = buildingsFolder:WaitForChild(id, 15)
			if not model then return end
			local base = model:WaitForChild("Base", 5) :: BasePart?
			if not base then return end
			local conn: RBXScriptConnection
			conn = base.Destroying:Connect(function()
				conn:Disconnect()
				ownedBuildingCounts[buildingType] =
					math.max(0, (ownedBuildingCounts[buildingType] or 1) - 1)
				refreshRequirements()
			end)
		end)
	end
end)

-- ── Barracks panel ────────────────────────────────────────────────────────────
UnitController.onBarracksSelected(function(barrackId: string?)
	if barrackId then
		BarracksPanel.show(barrackId)
	else
		BarracksPanel.hide()
	end
end)

-- ── Mineral / income wiring ───────────────────────────────────────────────────

Network.onSyncDeposits(function(positions: {Vector3})
	BuildingPlacer.setDepositPositions(positions)
end)

Network.onDepositClaimed(function(pos: Vector3)
	BuildingPlacer.removeDeposit(pos)
end)

Network.onMinerSpawned(function(mineId: string, ownerUserId: number, minerCount: number)
	if ownerUserId ~= localUserId then return end
	mineMiners[mineId] = minerCount
	HUD.setIncome(totalIncome())
end)

-- ── Turret projectile VFX ─────────────────────────────────────────────────────

Network.onTurretShot(function(fromPos: Vector3, toPos: Vector3)
	local proj              = Instance.new("Part")
	proj.Name               = "_TurretProjectile"
	proj.Size               = Vector3.new(0.45, 0.45, 0.45)
	proj.Shape              = Enum.PartType.Ball
	proj.BrickColor         = BrickColor.new("Bright red")
	proj.Material           = Enum.Material.Neon
	proj.Anchored           = true
	proj.CanCollide         = false
	proj.CanQuery           = false
	proj.CastShadow         = false
	proj.Position           = fromPos
	proj.Parent             = workspace

	local TRAVEL  = 0.22   -- seconds to reach target
	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		-- Lerp with a slight upward arc
		local p = fromPos:Lerp(toPos, t)
		proj.Position = p + Vector3.new(0, math.sin(t * math.pi) * 2, 0)

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()

			-- Small impact flash
			local flash             = Instance.new("Part")
			flash.Name              = "_TurretImpact"
			flash.Size              = Vector3.new(1.8, 1.8, 1.8)
			flash.Shape             = Enum.PartType.Ball
			flash.BrickColor        = BrickColor.new("Bright red")
			flash.Material          = Enum.Material.Neon
			flash.Anchored          = true
			flash.CanCollide        = false
			flash.CanQuery          = false
			flash.CastShadow        = false
			flash.Position          = toPos
			flash.Parent            = workspace
			task.delay(0.1, function() flash:Destroy() end)
		end
	end)
end)
