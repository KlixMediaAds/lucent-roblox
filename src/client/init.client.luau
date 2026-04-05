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
local MinePanel      = require(script:WaitForChild("MinePanel"))
local WorkshopPanel  = require(script:WaitForChild("WorkshopPanel"))
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

-- Current resource amount (tracked for MinePanel affordability checks)
local currentResources = 0

-- Research state (replicated from server)
local researchedTechs:   { [string]: boolean } = {}
local researchProgress:  { [string]: number?  } = {}

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

local dragFrame, buildBtn, mineBtn, turretBtn, cancelBtn, ccBtn, workshopBtn = HUD.create()

UnitController.init(Network, CameraModule, dragFrame, isBlocked)
BarracksPanel.init(Network)
MinePanel.init(Network,
	function() return currentResources end,
	function(mineId) return mineMiners[mineId] or 0 end,
	function(techName) return researchedTechs[techName] == true end)
WorkshopPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end,
	function(techName) return researchProgress[techName] end)
FogManager.init(localUserId)

HUD.wire(Network, UnitController, BuildingPlacer, buildBtn, mineBtn, turretBtn, cancelBtn, workshopBtn)

-- ── Command Center mode ───────────────────────────────────────────────────────

local function enterCCMode()
	BuildingPlacer.exitPlacementMode()
	clearMinerData()
	ownedBuildingCounts = {}
	researchedTechs    = {}
	researchProgress   = {}
	refreshRequirements()
	HUD.setCommandCenterMode(true)
	BarracksPanel.hide()
	MinePanel.hide()
	WorkshopPanel.hide()
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
		MinePanel.hide()
		WorkshopPanel.hide()
		BarracksPanel.show(barrackId)
	else
		BarracksPanel.hide()
	end
end)

-- ── Mine panel ────────────────────────────────────────────────────────────────
UnitController.onMineSelected(function(mineId: string?)
	if mineId then
		BarracksPanel.hide()
		WorkshopPanel.hide()
		MinePanel.show(mineId)
	else
		MinePanel.hide()
	end
end)

-- ── Workshop panel ─────────────────────────────────────────────────────────────
UnitController.onWorkshopSelected(function(workshopId: string?)
	if workshopId then
		BarracksPanel.hide()
		MinePanel.hide()
		WorkshopPanel.show(workshopId)
	else
		WorkshopPanel.hide()
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
	MinePanel.refreshIfVisible()
end)

Network.onResourceSync(function(amount: number)
	currentResources = amount
	MinePanel.refreshIfVisible()
end)

-- ── Research events ───────────────────────────────────────────────────────────

Network.onResearchUpdate(function(techName: string, progress: number)
	researchProgress[techName] = progress
	WorkshopPanel.refreshIfVisible()
end)

Network.onResearchCompleted(function(techName: string)
	researchedTechs[techName]  = true
	researchProgress[techName] = nil
	WorkshopPanel.refreshIfVisible()
	MinePanel.refreshIfVisible()
end)

-- ── Unit attack VFX ──────────────────────────────────────────────────────────
-- Traveling projectile from attacker → target, then a brief impact flash.
-- Soldiers: small fast yellow bullet.  Tanks: larger slower orange shell with arc.

Network.onUnitHit(function(fromPos: Vector3, toPos: Vector3, unitType: string)
	local isTank   = unitType == "Tank"
	local projSize = isTank and Vector3.new(0.9, 0.9, 0.9) or Vector3.new(0.45, 0.45, 0.45)
	local color    = isTank and BrickColor.new("Bright orange") or BrickColor.new("Bright yellow")
	local travel   = isTank and 0.26 or 0.14   -- seconds to reach target
	local arc      = isTank and 3.5 or 0.8     -- peak height of trajectory

	-- Offset origin to unit's approximate gun height
	local origin = fromPos + Vector3.new(0, 1.5, 0)
	local dest   = toPos   + Vector3.new(0, 1.0, 0)

	local proj          = Instance.new("Part")
	proj.Name           = "_UnitProj"
	proj.Size           = projSize
	proj.Shape          = Enum.PartType.Ball
	proj.BrickColor     = color
	proj.Material       = Enum.Material.Neon
	proj.Position       = origin
	proj.Anchored       = true
	proj.CanCollide     = false
	proj.CanQuery       = false
	proj.CastShadow     = false
	proj.Parent         = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.min(elapsed / travel, 1)
		proj.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * arc, 0)

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()

			-- Impact flash
			local flash         = Instance.new("Part")
			flash.Name          = "_UnitImpact"
			flash.Size          = isTank
				and Vector3.new(2.8, 2.8, 2.8)
				or  Vector3.new(1.5, 1.5, 1.5)
			flash.Shape         = Enum.PartType.Ball
			flash.BrickColor    = color
			flash.Material      = Enum.Material.Neon
			flash.Position      = dest
			flash.Anchored      = true
			flash.CanCollide    = false
			flash.CanQuery      = false
			flash.CastShadow    = false
			flash.Parent        = workspace
			task.delay(0.09, function() flash:Destroy() end)
		end
	end)
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
