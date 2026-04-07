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
local SpiderLegs     = require(script:WaitForChild("SpiderLegs"))
local MiniMap        = require(script:WaitForChild("MiniMap"))

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

-- Win/lose overlay (forward-declared so enterCCMode can hide it on reset)
local winOverlay: Frame?

-- Monument tracking
local monumentBuildingId: { [number]: string }       = {}  -- ownerUserId → buildingId
local monumentBillboards: { [number]: BillboardGui } = {}  -- ownerUserId → floating timer

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
SpiderLegs.init(workspace.CurrentCamera)
BuildingPlacer.init(Network, CameraModule)

local dragFrame, buildBtn, mineBtn, turretBtn, cancelBtn, ccBtn = HUD.create()

UnitController.init(Network, CameraModule, dragFrame, isBlocked)
BarracksPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end)
MinePanel.init(Network,
	function() return currentResources end,
	function(mineId) return mineMiners[mineId] or 0 end,
	function(techName) return researchedTechs[techName] == true end)
WorkshopPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end,
	function(techName) return researchProgress[techName] end,
	function() return currentResources end)
FogManager.init(localUserId)
MiniMap.init(CameraModule, localUserId)

HUD.wire(Network, UnitController, BuildingPlacer, buildBtn, mineBtn, turretBtn, cancelBtn)

-- ── Hide building panels when entering placement mode ─────────────────────────
-- If a panel (BarracksPanel, MinePanel, WorkshopPanel) is visible when the
-- player enters placement mode, it sits on top of the map and intercepts the
-- placement click (gpe = true), silently swallowing the click and leaving
-- isPlacing = true forever (until Escape/right-click).  Hiding panels on every
-- build-card click prevents this.
local function hideBuildingPanels()
	BarracksPanel.hide()
	MinePanel.hide()
	WorkshopPanel.hide()
end
buildBtn.MouseButton1Click:Connect(hideBuildingPanels)
mineBtn.MouseButton1Click:Connect(hideBuildingPanels)
turretBtn.MouseButton1Click:Connect(hideBuildingPanels)
ccBtn.MouseButton1Click:Connect(hideBuildingPanels)

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
	WorkshopPanel.resetMonument()
	if winOverlay then winOverlay.Visible = false end
	monumentBuildingId = {}
	monumentBillboards = {}
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

	if buildingType == "Monument" then
		monumentBuildingId[ownerId] = id
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

-- ── Command Center research panel ─────────────────────────────────────────────
UnitController.onCCSelected(function(ccId: string?)
	if ccId then
		BarracksPanel.hide()
		MinePanel.hide()
		WorkshopPanel.show(ccId)
	else
		WorkshopPanel.hide()
	end
end)

-- ── Mineral / income wiring ───────────────────────────────────────────────────

-- UnitsOrderedMove is fired by the server whenever any player issues a move
-- command (including AI bots).  Connect a no-op to prevent the event queue
-- from filling up with dropped messages.
Network.onUnitsOrderedMove(function(_ids: {string}, _targetPos: Vector3) end)

Network.onSyncDeposits(function(positions: {Vector3})
	BuildingPlacer.setDepositPositions(positions)
end)

Network.onDepositClaimed(function(pos: Vector3)
	BuildingPlacer.removeDeposit(pos)
end)

-- ── Spider legs for Elite units ───────────────────────────────────────────────

Network.onUnitSpawned(function(unitId: string, _ownerId: number, _pos: Vector3)
	task.spawn(function()
		local unitsFolder = workspace:WaitForChild("Units", 10) :: Folder?
		if not unitsFolder then return end
		local part = unitsFolder:WaitForChild(unitId, 10) :: BasePart?
		if not part then return end
		local tv = part:FindFirstChild("UnitType") :: StringValue?
		if tv and tv.Value == "Elite" then
			SpiderLegs.attach(unitId, part)
		end
	end)
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
	BarracksPanel.refreshIfVisible()
end)

-- ── Monument & win condition ──────────────────────────────────────────────────

-- ── Toast notification helper ─────────────────────────────────────────────────
local function showNotification(text: string, color: Color3?)
	local sg      = Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui
	local lbl     = Instance.new("TextLabel")
	lbl.Size      = UDim2.fromOffset(460, 44)
	lbl.Position  = UDim2.new(0.5, -230, 0, 72)
	lbl.BackgroundColor3 = Color3.fromRGB(8, 12, 26)
	lbl.BackgroundTransparency = 0.08
	lbl.BorderSizePixel = 0
	lbl.Font      = Enum.Font.GothamBold
	lbl.TextSize  = 16
	lbl.TextColor3 = color or Color3.fromRGB(255, 215, 0)
	lbl.Text      = text
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.ZIndex    = 50
	lbl.Parent    = sg
	local stroke  = Instance.new("UIStroke"); stroke.Color = color or Color3.fromRGB(255, 215, 0)
	stroke.Thickness = 1; stroke.Parent = lbl
	local corner  = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = lbl
	task.delay(4.5, function()
		for i = 1, 15 do
			task.wait(0.05)
			lbl.BackgroundTransparency = 0.08 + i / 15 * 0.92
			lbl.TextTransparency       = i / 15
		end
		lbl:Destroy()
	end)
end

-- ── Monument timer billboard ──────────────────────────────────────────────────
local function getOrCreateMonumentBillboard(ownerUserId: number): BillboardGui?
	if monumentBillboards[ownerUserId] and monumentBillboards[ownerUserId].Parent then
		return monumentBillboards[ownerUserId]
	end
	local bid = monumentBuildingId[ownerUserId]
	if not bid then return nil end
	local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
	if not buildingsF then return nil end
	local model = buildingsF:FindFirstChild(bid)
	if not model then return nil end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return nil end

	local bb             = Instance.new("BillboardGui")
	bb.Name              = "MonumentTimer"
	bb.Size              = UDim2.fromOffset(160, 26)
	bb.StudsOffset       = Vector3.new(0, 16, 0)
	bb.MaxDistance       = 600
	bb.AlwaysOnTop       = false
	bb.Parent            = base

	local bg             = Instance.new("Frame")
	bg.Size              = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3  = Color3.fromRGB(8, 12, 26)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel   = 0
	bg.Parent            = bb
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = bg

	local lbl            = Instance.new("TextLabel")
	lbl.Name             = "TimerLabel"
	lbl.Size             = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font             = Enum.Font.GothamBold
	lbl.TextSize         = 13
	lbl.TextColor3       = Color3.fromRGB(255, 215, 0)
	lbl.Text             = "Monument Rising..."
	lbl.Parent           = bb

	monumentBillboards[ownerUserId] = bb
	return bb
end

local function updateMonumentBillboard(ownerUserId: number, timeRemaining: number?)
	local bb  = getOrCreateMonumentBillboard(ownerUserId)
	if not bb then return end
	local lbl = bb:FindFirstChild("TimerLabel") :: TextLabel?
	if not lbl then return end

	if timeRemaining == nil or timeRemaining == -1 then
		lbl.Text = "Monument Rising..."
	else
		local mins = math.floor(timeRemaining / 60)
		local secs = math.floor(timeRemaining % 60)
		local player = Players:GetPlayerByUserId(ownerUserId)
		local name   = player and player.DisplayName or "???"
		lbl.Text     = string.format("%s  —  Win in %d:%02d", name, mins, secs)
	end
end

Network.onMonumentProgress(function(ownerUserId: number, timeRemaining: number?)
	-- Update local player's workshop panel
	if ownerUserId == localUserId then
		WorkshopPanel.onMonumentProgress(timeRemaining)
	end

	-- Update floating timer billboard
	if timeRemaining == nil then
		-- Monument destroyed — clear stale refs (the model/billboard is already gone)
		monumentBillboards[ownerUserId] = nil
		monumentBuildingId[ownerUserId] = nil

		if ownerUserId ~= localUserId then
			local p    = Players:GetPlayerByUserId(ownerUserId)
			local name = p and p.Name or "Enemy"
			showNotification(name .. "'s Monument was destroyed!", Color3.fromRGB(50, 200, 80))
		end
	elseif timeRemaining == -1 then
		-- Construction just started
		updateMonumentBillboard(ownerUserId, -1)

		local p    = Players:GetPlayerByUserId(ownerUserId)
		local name = p and p.Name or "Someone"
		if ownerUserId == localUserId then
			showNotification("Your Monument is rising! Defend it for 5 minutes to win!")
		else
			showNotification(name .. " is building a Monument! Destroy it to stop them!", Color3.fromRGB(255, 80, 60))
		end
	else
		-- Countdown tick
		updateMonumentBillboard(ownerUserId, timeRemaining)
	end
end)

-- Win / lose overlay
do
	local sg             = Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui
	local overlay        = Instance.new("Frame")
	overlay.Name         = "WinOverlay"
	overlay.Size         = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.45
	overlay.ZIndex       = 100
	overlay.Visible      = false
	overlay.Parent       = sg
	winOverlay           = overlay

	local heading        = Instance.new("TextLabel")
	heading.Name         = "Heading"
	heading.Size         = UDim2.new(1, 0, 0, 110)
	heading.Position     = UDim2.new(0, 0, 0.5, -90)
	heading.BackgroundTransparency = 1
	heading.Font         = Enum.Font.GothamBold
	heading.TextSize     = 80
	heading.Text         = "VICTORY!"
	heading.ZIndex       = 101
	heading.Parent       = overlay

	local sub            = Instance.new("TextLabel")
	sub.Name             = "Sub"
	sub.Size             = UDim2.new(1, 0, 0, 36)
	sub.Position         = UDim2.new(0, 0, 0.5, 32)
	sub.BackgroundTransparency = 1
	sub.Font             = Enum.Font.Gotham
	sub.TextSize         = 22
	sub.TextColor3       = Color3.fromRGB(200, 220, 255)
	sub.Text             = ""
	sub.ZIndex           = 101
	sub.Parent           = overlay
end

Network.onPlayerWon(function(winnerUserId: number)
	winOverlay.Visible = true
	local heading = winOverlay:FindFirstChild("Heading") :: TextLabel?
	local sub     = winOverlay:FindFirstChild("Sub")     :: TextLabel?
	if winnerUserId == localUserId then
		if heading then heading.Text = "VICTORY!";           heading.TextColor3 = Color3.fromRGB(255, 215, 0)  end
		if sub     then sub.Text     = "Your monument stood for 5 minutes." end
	else
		if heading then heading.Text = "DEFEAT";             heading.TextColor3 = Color3.fromRGB(210, 50, 50)  end
		if sub     then sub.Text     = "The enemy's monument has been completed." end
	end
end)

-- ── Unit attack VFX ──────────────────────────────────────────────────────────
-- Traveling projectile from attacker → target, then a brief impact flash.
-- Soldiers: small fast yellow bullet.  Tanks: larger slower orange shell with arc.
-- Elite: large purple lobbed orb with trail + full explosion VFX.

-- Elite explosion: single RenderStepped connection animates all pieces together.
local function spawnEliteExplosion(pos: Vector3)
	-- ── Core burst (instant, very short) ──────────────────────────────────
	local core        = Instance.new("Part")
	core.Name         = "_ECore"
	core.Shape        = Enum.PartType.Ball
	core.Size         = Vector3.new(3, 3, 3)
	core.BrickColor   = BrickColor.new("White")
	core.Material     = Enum.Material.Neon
	core.Anchored     = true
	core.CanCollide   = false
	core.CanQuery     = false
	core.CastShadow   = false
	core.Position     = pos
	core.Parent       = workspace

	-- ── Outer flash (expands + fades) ─────────────────────────────────────
	local flash        = Instance.new("Part")
	flash.Name         = "_EFlash"
	flash.Shape        = Enum.PartType.Ball
	flash.Size         = Vector3.new(2, 2, 2)
	flash.BrickColor   = BrickColor.new("Bright violet")
	flash.Material     = Enum.Material.Neon
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CastShadow   = false
	flash.Position     = pos
	flash.Parent       = workspace

	-- ── Shockwave ring (horizontal disc expanding outward) ─────────────────
	-- Cylinder in Roblox: round face along X axis, Size.X = length, Size.Y = Size.Z = diameter.
	-- Rotate 90° around Z so the disc lies flat (Y axis = up).
	local ring         = Instance.new("Part")
	ring.Name          = "_ERing"
	ring.Shape         = Enum.PartType.Cylinder
	ring.Size          = Vector3.new(0.35, 1, 1)
	ring.BrickColor    = BrickColor.new("Bright violet")
	ring.Material      = Enum.Material.Neon
	ring.Anchored      = true
	ring.CanCollide    = false
	ring.CanQuery      = false
	ring.CastShadow    = false
	ring.CFrame        = CFrame.new(pos + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent        = workspace

	-- ── Debris chunks (5 pieces, fly outward with gravity) ────────────────
	type DebrisData = { part: Part, vx: number, vy: number, vz: number }
	local debris: { DebrisData } = {}
	for i = 1, 5 do
		local angle = (i - 1) / 5 * math.pi * 2 + math.random() * 0.6
		local spd   = 10 + math.random() * 7
		local d: Part = Instance.new("Part")
		d.Name        = "_EDeb"
		d.Size        = Vector3.new(0.9, 0.9, 0.9)
		d.BrickColor  = i % 2 == 0 and BrickColor.new("Dark indigo") or BrickColor.new("Bright violet")
		d.Material    = Enum.Material.Neon
		d.Anchored    = true
		d.CanCollide  = false
		d.CanQuery    = false
		d.CastShadow  = false
		d.Position    = pos
		d.Parent      = workspace
		table.insert(debris, {
			part = d,
			vx   = math.cos(angle) * spd,
			vy   = 8 + math.random() * 5,
			vz   = math.sin(angle) * spd,
		})
	end

	-- ── Single connection animates all pieces ──────────────────────────────
	local FLASH_DUR  = 0.30
	local RING_DUR   = 0.22
	local CORE_DUR   = 0.10
	local DEBRIS_DUR = 0.55

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt

		-- Core: quick white burst
		if core then
			if elapsed < CORE_DUR then
				core.Transparency = elapsed / CORE_DUR
			else
				core:Destroy()
				core = nil :: any
			end
		end

		-- Flash: expands 2→9 studs, fades out
		if flash then
			if elapsed < FLASH_DUR then
				local t = elapsed / FLASH_DUR
				local s = 2 + t * 7
				flash.Size         = Vector3.new(s, s, s)
				flash.Transparency = t * 0.85
			else
				flash:Destroy()
				flash = nil :: any
			end
		end

		-- Ring: diameter expands 1→12 studs, fades out
		if ring then
			if elapsed < RING_DUR then
				local t = elapsed / RING_DUR
				local d = 1 + t * 11
				ring.Size         = Vector3.new(0.35, d, d)
				ring.Transparency = 0.2 + t * 0.8
			else
				ring:Destroy()
				ring = nil :: any
			end
		end

		-- Debris: fly outward under gravity, fade
		for _, db in debris do
			if db.part then
				if elapsed < DEBRIS_DUR then
					local t = elapsed / DEBRIS_DUR
					db.vy -= 30 * dt
					db.part.Position = db.part.Position
						+ Vector3.new(db.vx * dt, db.vy * dt, db.vz * dt)
					db.part.Transparency = t
				else
					db.part:Destroy()
					db.part = nil :: any
				end
			end
		end

		if elapsed >= DEBRIS_DUR then
			conn:Disconnect()
		end
	end)
end

-- Elite lobbed orb: large arc, purple, with a color trail.
local function spawnEliteProjectile(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.55
	local ARC    = 7.0

	local origin = fromPos + Vector3.new(0, 2.5, 0)
	local dest   = toPos   + Vector3.new(0, 1.0, 0)

	local proj        = Instance.new("Part")
	proj.Name         = "_EliteOrb"
	proj.Shape        = Enum.PartType.Ball
	proj.Size         = Vector3.new(1.2, 1.2, 1.2)
	proj.BrickColor   = BrickColor.new("Bright violet")
	proj.Material     = Enum.Material.Neon
	proj.Anchored     = true
	proj.CanCollide   = false
	proj.CanQuery     = false
	proj.CastShadow   = false
	proj.Position     = origin
	proj.Parent       = workspace

	-- Trail (needs two attachments as anchor points)
	local a0          = Instance.new("Attachment", proj)
	a0.Position       = Vector3.new(0,  0.4, 0)
	local a1          = Instance.new("Attachment", proj)
	a1.Position       = Vector3.new(0, -0.4, 0)

	local trail              = Instance.new("Trail", proj)
	trail.Attachment0        = a0
	trail.Attachment1        = a1
	trail.Lifetime           = 0.45
	trail.MinLength          = 0
	trail.FaceCamera         = true
	trail.Color              = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 120, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160,  40, 220)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB( 60,   0, 120)),
	})
	trail.Transparency       = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	trail.WidthScale         = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(1, 0.0),
	})

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		proj.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			spawnEliteExplosion(dest)
		end
	end)
end

Network.onUnitHit(function(fromPos: Vector3, toPos: Vector3, unitType: string)
	-- Elite gets its own lobbed projectile with trail + explosion.
	if unitType == "Elite" then
		spawnEliteProjectile(fromPos, toPos)
		return
	end

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
