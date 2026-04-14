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
local TurretPanel    = require(script:WaitForChild("TurretPanel"))
local MiniMap        = require(script:WaitForChild("MiniMap"))
local Tutorial       = require(script:WaitForChild("Tutorial"))
local CometManager   = require(script:WaitForChild("CometManager"))
local LobbyUI        = require(script:WaitForChild("LobbyUI"))

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

local function startGame()

CameraModule.init()
SpiderLegs.init(workspace.CurrentCamera)
BuildingPlacer.init(Network, CameraModule)

local dragFrame, ccBtn = HUD.create()
Tutorial.init(Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui)

UnitController.init(Network, CameraModule, dragFrame, isBlocked)
UnitController.onMoveIssued(function() Tutorial.notify("move_issued") end)
BarracksPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end)
MinePanel.init(Network,
	function() return currentResources end,
	function(mineId) return mineMiners[mineId] or 0 end,
	function(techName) return researchedTechs[techName] == true end)
WorkshopPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end,
	function(techName) return researchProgress[techName] end,
	function() return currentResources end,
	HUD.showNotification)
TurretPanel.init(Network,
	function() return currentResources end,
	function(techName) return researchedTechs[techName] == true end)
FogManager.init(localUserId)
MiniMap.init(CameraModule, localUserId)

-- ── Hide building panels when entering placement mode ─────────────────────────
-- Called by HUD when a build node is clicked, and also wired to the CC button.
-- Prevents open panels from intercepting placement clicks (they consume the click
-- through GPE = true, leaving isPlacing stuck until Escape / right-click).
local function hideBuildingPanels()
	BarracksPanel.hide()
	MinePanel.hide()
	WorkshopPanel.hide()
	TurretPanel.hide()
end

HUD.wire(Network, UnitController, BuildingPlacer, hideBuildingPanels)
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
	TurretPanel.hide()
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
		Tutorial.notify("cc_placed")
	end

	if buildingType == "Monument" then
		monumentBuildingId[ownerId] = id
	end

	-- Track this player's non-CC buildings for the requirement system
	if ownerId == localUserId and buildingType ~= "CommandCenter" then
		ownedBuildingCounts[buildingType] = (ownedBuildingCounts[buildingType] or 0) + 1
		refreshRequirements()
		if buildingType == "Mine"     then Tutorial.notify("mine_placed")     end
		if buildingType == "Barracks" then Tutorial.notify("barracks_placed") end

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
		TurretPanel.hide()
		WorkshopPanel.show(ccId)
		Tutorial.notify("cc_selected")
	else
		WorkshopPanel.hide()
	end
end)

-- ── Turret upgrade panel ──────────────────────────────────────────────────────
UnitController.onTurretSelected(function(turretId: string?)
	if turretId then
		BarracksPanel.hide()
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.show(turretId)
	else
		TurretPanel.hide()
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

-- ── Tank Concussion Shells visual upgrade ────────────────────────────────────
-- Adds a glowing orange neon orb + two top-surface stripes to a tank body part.
-- Parts are unanchored + WeldConstrained so they follow the moving tank.
local function applyTankConcussionVisual(body: BasePart)
	-- Guard: don't add twice
	if body:FindFirstChild("_ConcussionOrb") then return end

	local halfY = body.Size.Y / 2

	local function weld(p: BasePart)
		local w   = Instance.new("WeldConstraint")
		w.Part0   = body
		w.Part1   = p
		w.Parent  = body
	end

	-- Glowing orb floating just above the top centre
	local orb        = Instance.new("Part")
	orb.Name         = "_ConcussionOrb"
	orb.Shape        = Enum.PartType.Ball
	orb.Size         = Vector3.new(1.6, 1.6, 1.6)
	orb.BrickColor   = BrickColor.new("Bright orange")
	orb.Material     = Enum.Material.Metal
	orb.Anchored     = false
	orb.CanCollide   = false
	orb.CanQuery     = false
	orb.CastShadow   = false
	orb.CFrame       = body.CFrame * CFrame.new(0, halfY + 1.1, 0)
	orb.Parent       = body
	weld(orb)

	-- Two lengthwise neon stripes along the top edges
	for _, sideX in { -(body.Size.X / 2 - 0.6), (body.Size.X / 2 - 0.6) } do
		local stripe       = Instance.new("Part")
		stripe.Name        = "_ConcussionStripe"
		stripe.Size        = Vector3.new(0.55, 0.3, body.Size.Z + 0.5)
		stripe.BrickColor  = BrickColor.new("Bright orange")
		stripe.Material    = Enum.Material.Metal
		stripe.Anchored    = false
		stripe.CanCollide  = false
		stripe.CanQuery    = false
		stripe.CastShadow  = false
		stripe.CFrame      = body.CFrame * CFrame.new(sideX, halfY + 0.15, 0)
		stripe.Parent      = body
		weld(stripe)
	end
end

-- ── Trapper visual upgrade ────────────────────────────────────────────────────
-- Adds a harpoon rack on top of the tank and a BillboardGui with 5 white squares
-- showing the current harpoon count. The squares go dark as harpoons are consumed.
local function applyTrapperVisual(body: BasePart)
	if body:FindFirstChild("_HarpoonRack") then return end

	local halfY = body.Size.Y / 2

	local function weld(p: BasePart)
		local w   = Instance.new("WeldConstraint")
		w.Part0   = body
		w.Part1   = p
		w.Parent  = body
	end

	-- Rack base plate centered on top of the tank
	local rack         = Instance.new("Part")
	rack.Name          = "_HarpoonRack"
	rack.Size          = Vector3.new(4.8, 0.35, 1.8)
	rack.Color         = Color3.fromRGB(50, 52, 58)
	rack.Material      = Enum.Material.Metal
	rack.Anchored      = false
	rack.CanCollide    = false
	rack.CanQuery      = false
	rack.CastShadow    = false
	rack.CFrame        = body.CFrame * CFrame.new(0, halfY + 0.18, 0)
	rack.Parent        = body
	weld(rack)

	-- Two side rails of the rack
	for _, sideZ in { -0.7, 0.7 } do
		local rail        = Instance.new("Part")
		rail.Name         = "_HarpoonRail"
		rail.Size         = Vector3.new(4.8, 0.3, 0.2)
		rail.Color        = Color3.fromRGB(80, 82, 90)
		rail.Material     = Enum.Material.Metal
		rail.Anchored     = false
		rail.CanCollide   = false
		rail.CanQuery     = false
		rail.CastShadow   = false
		rail.CFrame       = body.CFrame * CFrame.new(0, halfY + 0.55, sideZ)
		rail.Parent       = body
		weld(rail)
	end

	-- 5 harpoon bolts resting in the rack (thin silver rods pointing forward)
	for i = 1, 5 do
		local xOff       = -1.8 + (i - 1) * 0.9
		local bolt       = Instance.new("Part")
		bolt.Name        = "_HarpoonBolt"
		bolt.Size        = Vector3.new(0.25, 0.25, 2.0)
		bolt.Color       = Color3.fromRGB(185, 188, 195)
		bolt.Material    = Enum.Material.Metal
		bolt.Anchored    = false
		bolt.CanCollide  = false
		bolt.CanQuery    = false
		bolt.CastShadow  = false
		bolt.CFrame      = body.CFrame * CFrame.new(xOff, halfY + 0.52, 0)
		bolt.Parent      = body
		weld(bolt)
	end

	-- BillboardGui: 5 small squares showing harpoon count (compact, 30% of original)
	local bb               = Instance.new("BillboardGui")
	bb.Name                = "_HarpoonCountBB"
	bb.Size                = UDim2.fromOffset(30, 6)
	bb.StudsOffset         = Vector3.new(0, body.Size.Y / 2 + 1.8, 0)
	bb.AlwaysOnTop         = false
	bb.MaxDistance         = 80
	bb.LightInfluence      = 0
	bb.Parent              = body

	local squares: { Frame } = {}
	for i = 1, 5 do
		local sq                   = Instance.new("Frame")
		sq.Name                    = "HarpoonSq" .. i
		sq.Size                    = UDim2.fromOffset(4, 4)
		sq.Position                = UDim2.fromOffset((i - 1) * 6, 1)
		sq.BackgroundColor3        = Color3.fromRGB(255, 255, 255)
		sq.BackgroundTransparency  = 0.08
		sq.BorderSizePixel         = 0
		sq.Parent                  = bb
		local corner               = Instance.new("UICorner")
		corner.CornerRadius        = UDim.new(0, 1)
		corner.Parent              = sq
		squares[i] = sq
	end

	local function updateSquares(count: number)
		for i = 1, 5 do
			if i <= count then
				squares[i].BackgroundColor3       = Color3.fromRGB(255, 255, 255)
				squares[i].BackgroundTransparency = 0.08
			else
				squares[i].BackgroundColor3       = Color3.fromRGB(55, 55, 60)
				squares[i].BackgroundTransparency = 0.35
			end
		end
	end

	local hv = body:FindFirstChild("HarpoonCount") :: NumberValue?
	if hv then
		updateSquares(hv.Value)
		hv.Changed:Connect(updateSquares)
	end
end

-- ── Soldier upgrade visuals ───────────────────────────────────────────────────
-- CombatStims: two small green cylinders on the back (stim injectors)
local function applySoldierStimVisual(body: BasePart)
	if body:FindFirstChild("_StimInjector") then return end
	local halfY = body.Size.Y / 2
	local halfZ = body.Size.Z / 2

	local function weld(p: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = body
		w.Part1 = p
		w.Parent = body
	end

	for _, sideX in { -0.8, 0.8 } do
		local inj           = Instance.new("Part")
		inj.Name            = "_StimInjector"
		inj.Shape           = Enum.PartType.Cylinder
		inj.Size            = Vector3.new(1.4, 0.45, 0.45)
		inj.BrickColor      = BrickColor.new("Bright green")
		inj.Material        = Enum.Material.Metal
		inj.Anchored        = false
		inj.CanCollide      = false
		inj.CanQuery        = false
		inj.CastShadow      = false
		-- Position on the back-upper area, rotated so the cylinder stands upright
		inj.CFrame          = body.CFrame
			* CFrame.new(sideX, halfY - 0.5, halfZ - 0.25)
			* CFrame.Angles(0, 0, math.rad(90))
		inj.Parent          = body
		weld(inj)

		-- Green tip cap
		local cap           = Instance.new("Part")
		cap.Name            = "_StimCap"
		cap.Shape           = Enum.PartType.Ball
		cap.Size            = Vector3.new(0.5, 0.5, 0.5)
		cap.BrickColor      = BrickColor.new("Lime green")
		cap.Material        = Enum.Material.Neon
		cap.Anchored        = false
		cap.CanCollide      = false
		cap.CanQuery        = false
		cap.CastShadow      = false
		cap.CFrame          = body.CFrame * CFrame.new(sideX, halfY + 0.25, halfZ - 0.25)
		cap.Parent          = body
		weld(cap)
	end
end

-- HardenedArmor: flat grey plate on the front face of the soldier
local function applySoldierArmorVisual(body: BasePart)
	if body:FindFirstChild("_ArmorPlate") then return end
	local halfY = body.Size.Y / 2
	local halfZ = body.Size.Z / 2

	local function weld(p: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = body
		w.Part1 = p
		w.Parent = body
	end

	-- Main chest plate
	local plate           = Instance.new("Part")
	plate.Name            = "_ArmorPlate"
	plate.Size            = Vector3.new(body.Size.X - 0.6, body.Size.Y * 0.55, 0.3)
	plate.BrickColor      = BrickColor.new("Medium stone grey")
	plate.Material        = Enum.Material.Metal
	plate.Anchored        = false
	plate.CanCollide      = false
	plate.CanQuery        = false
	plate.CastShadow      = false
	plate.CFrame          = body.CFrame * CFrame.new(0, halfY * 0.1, -(halfZ + 0.15))
	plate.Parent          = body
	weld(plate)

	-- Rivet-strip accent across the top of the plate
	local strip           = Instance.new("Part")
	strip.Name            = "_ArmorStrip"
	strip.Size            = Vector3.new(body.Size.X - 0.6, 0.25, 0.32)
	strip.BrickColor      = BrickColor.new("Dark stone grey")
	strip.Material        = Enum.Material.Metal
	strip.Anchored        = false
	strip.CanCollide      = false
	strip.CanQuery        = false
	strip.CastShadow      = false
	strip.CFrame          = body.CFrame * CFrame.new(0, halfY * 0.1 + plate.Size.Y / 2 - 0.12, -(halfZ + 0.16))
	strip.Parent          = body
	weld(strip)
end

-- ── Spider legs for Elite units ───────────────────────────────────────────────

Network.onUnitSpawned(function(unitId: string, _ownerId: number, _pos: Vector3)
	if _ownerId == localUserId then Tutorial.notify("unit_trained") end
	task.spawn(function()
		local unitsFolder = workspace:WaitForChild("Units", 10) :: Folder?
		if not unitsFolder then return end
		local part = unitsFolder:WaitForChild(unitId, 10) :: BasePart?
		if not part then return end
		local tv = part:FindFirstChild("UnitType") :: StringValue?
		if tv and tv.Value == "Elite" then
			SpiderLegs.attach(unitId, part)
		end
		-- Apply upgrade visuals if already researched
		if _ownerId == localUserId then
			local p = part :: BasePart
			if tv and tv.Value == "Tank" and researchedTechs["ConcussionShells"] then
				applyTankConcussionVisual(p)
			end
			if tv and tv.Value == "Tank" and researchedTechs["Trapper"] then
				applyTrapperVisual(p)
			end
			if tv and tv.Value == "Soldier" then
				if researchedTechs["CombatStims"]   then applySoldierStimVisual(p)  end
				if researchedTechs["HardenedArmor"] then applySoldierArmorVisual(p) end
			end
		end
	end)
end)

Network.onMinerSpawned(function(mineId: string, ownerUserId: number, minerCount: number)
	if ownerUserId ~= localUserId then return end
	mineMiners[mineId] = minerCount
	HUD.setIncome(totalIncome())
	MinePanel.refreshIfVisible()
end)

Network.onMineIncome(function(mineId: string, income: number)
	local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
	if not buildingsF then return end
	local model = buildingsF:FindFirstChild(mineId)
	if not model then return end
	local crystal = model:FindFirstChild("Crystal") :: BasePart?
	if not crystal then return end

	-- Floating "+X res" label
	local bb           = Instance.new("BillboardGui")
	bb.Name            = "_MineIncomeBB"
	bb.Size            = UDim2.fromOffset(80, 22)
	bb.StudsOffset     = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop     = false
	bb.MaxDistance     = 120
	bb.Parent          = crystal

	local lbl                    = Instance.new("TextLabel")
	lbl.Size                     = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency   = 1
	lbl.Font                     = Enum.Font.GothamBold
	lbl.TextSize                 = 15
	lbl.TextColor3               = Color3.fromRGB(255, 215, 0)
	lbl.TextStrokeTransparency   = 0.35
	lbl.Text                     = "+" .. income .. " res"
	lbl.Parent                   = bb

	-- Crystal pulse: briefly enlarge then restore
	local originalSize = crystal.Size
	local PULSE_IN     = 0.12   -- seconds to grow
	local PULSE_OUT    = 0.32   -- seconds to shrink back
	local RISE_DUR     = 1.4    -- total float duration
	local PULSE_ADD    = Vector3.new(0.8, 1.6, 0.8)

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt

		-- Float label upward and fade
		if bb.Parent then
			local t        = math.min(elapsed / RISE_DUR, 1)
			bb.StudsOffset = Vector3.new(0, 4 + t * 3.5, 0)
			lbl.TextTransparency = math.clamp((t - 0.4) / 0.6, 0, 1)
		end

		-- Crystal size pulse
		if crystal.Parent then
			if elapsed < PULSE_IN then
				local t      = elapsed / PULSE_IN
				crystal.Size = originalSize + PULSE_ADD * t
			elseif elapsed < PULSE_IN + PULSE_OUT then
				local t      = (elapsed - PULSE_IN) / PULSE_OUT
				crystal.Size = (originalSize + PULSE_ADD) - PULSE_ADD * t
			else
				crystal.Size = originalSize
			end
		end

		if elapsed >= RISE_DUR then
			conn:Disconnect()
			if bb.Parent then bb:Destroy() end
			if crystal.Parent then crystal.Size = originalSize end
		end
	end)
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
	TurretPanel.refreshIfVisible()

	-- Apply visuals to all existing own units when relevant research completes
	if techName == "ConcussionShells" or techName == "CombatStims" or techName == "HardenedArmor" or techName == "Trapper" then
		local unitsFolder = workspace:FindFirstChild("Units") :: Folder?
		if unitsFolder then
			for _, child in unitsFolder:GetChildren() do
				if not child:IsA("BasePart") then continue end
				local ov = child:FindFirstChild("OwnerId") :: StringValue?
				if not ov or ov.Value ~= tostring(localUserId) then continue end
				local tv = child:FindFirstChild("UnitType") :: StringValue?
				if not tv then continue end
				if tv.Value == "Tank" and techName == "ConcussionShells" then
					applyTankConcussionVisual(child :: BasePart)
				elseif tv.Value == "Tank" and techName == "Trapper" then
					applyTrapperVisual(child :: BasePart)
				elseif tv.Value == "Soldier" then
					if techName == "CombatStims"   then applySoldierStimVisual(child :: BasePart)  end
					if techName == "HardenedArmor" then applySoldierArmorVisual(child :: BasePart) end
				end
			end
		end
	end
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

Network.onCCAttacked(function()
	HUD.showNotification("⚠ Command Center is under attack!", Color3.fromRGB(230, 60, 60))
end)

Network.onMineDepletionWarning(function(_mineId: string)
	HUD.showNotification("⛏ A Mine has been depleted.", Color3.fromRGB(220, 150, 30))
end)

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

-- Tank shell explosion: orange fireball, shockwave ring, debris chunks.
local function spawnTankExplosion(pos: Vector3)
	-- Core: instant white burst
	local core       = Instance.new("Part")
	core.Name        = "_TCore"
	core.Shape       = Enum.PartType.Ball
	core.Size        = Vector3.new(4, 4, 4)
	core.BrickColor  = BrickColor.new("White")
	core.Material    = Enum.Material.Neon
	core.Anchored    = true
	core.CanCollide  = false
	core.CanQuery    = false
	core.CastShadow  = false
	core.Position    = pos
	core.Parent      = workspace

	-- Fireball: expands 3 → 18 studs, orange → dark orange fade
	local fire       = Instance.new("Part")
	fire.Name        = "_TFire"
	fire.Shape       = Enum.PartType.Ball
	fire.Size        = Vector3.new(3, 3, 3)
	fire.BrickColor  = BrickColor.new("Bright orange")
	fire.Material    = Enum.Material.Neon
	fire.Anchored    = true
	fire.CanCollide  = false
	fire.CanQuery    = false
	fire.CastShadow  = false
	fire.Position    = pos
	fire.Parent      = workspace

	-- Inner ember: smaller, persists slightly longer for depth
	local ember      = Instance.new("Part")
	ember.Name       = "_TEmber"
	ember.Shape      = Enum.PartType.Ball
	ember.Size       = Vector3.new(2, 2, 2)
	ember.BrickColor = BrickColor.new("Bright yellow")
	ember.Material   = Enum.Material.Neon
	ember.Anchored   = true
	ember.CanCollide = false
	ember.CanQuery   = false
	ember.CastShadow = false
	ember.Position   = pos
	ember.Parent     = workspace

	-- Shockwave ring: horizontal disc expanding outward
	local ring       = Instance.new("Part")
	ring.Name        = "_TRing"
	ring.Shape       = Enum.PartType.Cylinder
	ring.Size        = Vector3.new(0.4, 1, 1)
	ring.BrickColor  = BrickColor.new("Bright orange")
	ring.Material    = Enum.Material.Neon
	ring.Anchored    = true
	ring.CanCollide  = false
	ring.CanQuery    = false
	ring.CastShadow  = false
	ring.CFrame      = CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent      = workspace

	-- Debris: 7 chunks fly outward under gravity
	type DebrisData = { part: Part, vx: number, vy: number, vz: number }
	local debris: { DebrisData } = {}
	for i = 1, 7 do
		local angle = (i - 1) / 7 * math.pi * 2 + math.random() * 0.5
		local spd   = 12 + math.random() * 9
		local d: Part = Instance.new("Part")
		d.Name        = "_TDeb"
		d.Size        = Vector3.new(0.7 + math.random() * 0.6, 0.7 + math.random() * 0.6, 0.7 + math.random() * 0.6)
		d.BrickColor  = (i % 3 == 0) and BrickColor.new("Bright yellow")
			or (i % 3 == 1) and BrickColor.new("Bright orange")
			or BrickColor.new("Reddish brown")
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
			vy   = 9 + math.random() * 6,
			vz   = math.sin(angle) * spd,
		})
	end

	local CORE_DUR   = 0.08
	local FIRE_DUR   = 0.40
	local EMBER_DUR  = 0.25
	local RING_DUR   = 0.28
	local DEBRIS_DUR = 0.65

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt

		if core then
			if elapsed < CORE_DUR then
				core.Transparency = elapsed / CORE_DUR
			else
				core:Destroy(); core = nil :: any
			end
		end

		if fire then
			if elapsed < FIRE_DUR then
				local t = elapsed / FIRE_DUR
				local s = 3 + t * 15
				fire.Size         = Vector3.new(s, s, s)
				fire.Transparency = 0.1 + t * 0.9
			else
				fire:Destroy(); fire = nil :: any
			end
		end

		if ember then
			if elapsed < EMBER_DUR then
				local t = elapsed / EMBER_DUR
				local s = 2 + t * 4
				ember.Size         = Vector3.new(s, s, s)
				ember.Transparency = t
			else
				ember:Destroy(); ember = nil :: any
			end
		end

		if ring then
			if elapsed < RING_DUR then
				local t = elapsed / RING_DUR
				local d = 1 + t * 20
				ring.Size         = Vector3.new(0.4, d, d)
				ring.Transparency = 0.15 + t * 0.85
			else
				ring:Destroy(); ring = nil :: any
			end
		end

		for _, db in debris do
			if db.part then
				if elapsed < DEBRIS_DUR then
					local t = elapsed / DEBRIS_DUR
					db.vy -= 35 * dt
					db.part.Position = db.part.Position
						+ Vector3.new(db.vx * dt, db.vy * dt, db.vz * dt)
					db.part.Transparency = math.max(0, t - 0.2) / 0.8
				else
					db.part:Destroy(); db.part = nil :: any
				end
			end
		end

		if elapsed >= DEBRIS_DUR then conn:Disconnect() end
	end)
end

-- Rocket Barrage: 3 small rockets that spiral toward the target before impact.
-- Each rocket has a random landing offset and converging helix animation.
local function spawnRocketBarrage(fromPos: Vector3, toPos: Vector3)
	local TRAVEL  = 0.55   -- seconds per rocket
	local ARC     = 3.5    -- height of the ballistic arc
	local HELIX_R = 2.8    -- helix radius at launch; shrinks to 0 at impact
	local TWISTS  = 2      -- full rotations during flight

	for i = 1, 3 do
		local launchDelay = (i - 1) * 0.13
		local phase       = (i - 1) * (math.pi * 2 / 3)  -- 120° apart

		-- Small random landing spread per rocket (server mirrors this for damage)
		local lx = (math.random() - 0.5) * 6
		local lz = (math.random() - 0.5) * 6

		task.delay(launchDelay, function()
			local origin = fromPos + Vector3.new(0, 2.2, 0)
			local dest   = toPos   + Vector3.new(lx, 0.4, lz)

			local rocket        = Instance.new("Part")
			rocket.Name         = "_BarrageRocket"
			rocket.Shape        = Enum.PartType.Block
			rocket.Size         = Vector3.new(0.5, 0.5, 1.4)
			rocket.Color        = Color3.fromRGB(220, 60, 30)
			rocket.Material     = Enum.Material.Neon
			rocket.Anchored     = true
			rocket.CanCollide   = false
			rocket.CanQuery     = false
			rocket.CastShadow   = false
			rocket.Position     = origin
			rocket.Parent       = workspace

			local a0            = Instance.new("Attachment", rocket)
			a0.Position         = Vector3.new(0, 0, 0.6)
			local a1            = Instance.new("Attachment", rocket)
			a1.Position         = Vector3.new(0, 0, -0.6)

			local trail             = Instance.new("Trail", rocket)
			trail.Attachment0       = a0
			trail.Attachment1       = a1
			trail.Lifetime          = 0.20
			trail.MinLength         = 0
			trail.FaceCamera        = true
			trail.Color             = ColorSequence.new({
				ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 120,  30)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200,  50,  10)),
				ColorSequenceKeypoint.new(1,   Color3.fromRGB( 60,  10,   0)),
			})
			trail.Transparency  = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.0),
				NumberSequenceKeypoint.new(1, 1.0),
			})
			trail.WidthScale    = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.9),
				NumberSequenceKeypoint.new(1, 0.0),
			})

			local elapsed = 0
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function(dt)
				elapsed += dt
				local t = math.min(elapsed / TRAVEL, 1)

				-- Ballistic arc lerp
				local basePath = origin:Lerp(dest, t)
					+ Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

				-- Helix: radius collapses to 0 as rocket converges on target
				local helixRadius = HELIX_R * (1 - t)
				local angle       = phase + t * TWISTS * math.pi * 2
				local helixOffset = Vector3.new(
					math.cos(angle) * helixRadius,
					0,
					math.sin(angle) * helixRadius
				)
				local newPos = basePath + helixOffset

				-- Orient nose toward next position
				if t < 0.97 then
					local tN    = math.min(t + 0.04, 0.97)
					local baseN = origin:Lerp(dest, tN)
						+ Vector3.new(0, math.sin(tN * math.pi) * ARC, 0)
					local helN  = Vector3.new(
						math.cos(phase + tN * TWISTS * math.pi * 2) * HELIX_R * (1 - tN),
						0,
						math.sin(phase + tN * TWISTS * math.pi * 2) * HELIX_R * (1 - tN)
					)
					local dir = (baseN + helN) - newPos
					if dir.Magnitude > 0.05 then
						rocket.CFrame = CFrame.lookAt(newPos, newPos + dir)
					else
						rocket.Position = newPos
					end
				else
					rocket.Position = newPos
				end

				if t >= 1 then
					conn:Disconnect()
					rocket:Destroy()
					spawnTankExplosion(dest - Vector3.new(0, 0.2, 0))
				end
			end)
		end)
	end
end

-- Tank shell: heavy arcing projectile with an orange-to-red trail.
local function spawnTankShell(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.48
	local ARC    = 6.0

	local origin = fromPos + Vector3.new(0, 2.0, 0)
	local dest   = toPos   + Vector3.new(0, 0.5, 0)

	local shell        = Instance.new("Part")
	shell.Name         = "_TankShell"
	shell.Shape        = Enum.PartType.Ball
	shell.Size         = Vector3.new(1.1, 1.1, 1.1)
	shell.BrickColor   = BrickColor.new("Bright orange")
	shell.Material     = Enum.Material.Neon
	shell.Anchored     = true
	shell.CanCollide   = false
	shell.CanQuery     = false
	shell.CastShadow   = false
	shell.Position     = origin
	shell.Parent       = workspace

	local a0           = Instance.new("Attachment", shell)
	a0.Position        = Vector3.new(0,  0.35, 0)
	local a1           = Instance.new("Attachment", shell)
	a1.Position        = Vector3.new(0, -0.35, 0)

	local trail              = Instance.new("Trail", shell)
	trail.Attachment0        = a0
	trail.Attachment1        = a1
	trail.Lifetime           = 0.30
	trail.MinLength          = 0
	trail.FaceCamera         = true
	trail.Color              = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 200,  60)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(230, 100,  20)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB( 80,  20,   0)),
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
		shell.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

		if t >= 1 then
			conn:Disconnect()
			shell:Destroy()
			spawnTankExplosion(dest)
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

-- ── Medic heal beam VFX ──────────────────────────────────────────────────────
-- Trapper zip-wire: a black shiny cable that bolts onto the target and stays taut for
-- TRAPPER_SLOW_DURATION seconds while units are slowed, then snaps back to the trapper.
-- The wire follows both units as they move.
local function spawnTrapperHarpoon(fromPos: Vector3, toPos: Vector3)
	if (toPos - fromPos).Magnitude < 0.5 then return end

	local SLOW_DUR  = Config.TRAPPER_SLOW_DURATION  -- 7 s taut
	local RETRACT_T = 0.4                           -- retraction animation duration

	-- Spatial lookup: find the actual BasePart closest to a world position
	local function findNearestUnit(searchPos: Vector3): BasePart?
		local unitsF = workspace:FindFirstChild("Units") :: Folder?
		if not unitsF then return nil end
		local best: BasePart? = nil
		local bestDist = 12
		for _, child in unitsF:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local d = (child.Position - searchPos).Magnitude
			if d < bestDist then bestDist = d; best = child :: BasePart end
		end
		return best
	end

	-- fromPos is the trapper's centre; toPos is target top-centre (part.Position + sizeY/2).
	-- Tank sizeY = 5, so target part centre is ~2.5 below toPos.
	local trapperPart = findNearestUnit(fromPos)
	local targetPart  = findNearestUnit(toPos - Vector3.new(0, 2.5, 0))

	-- Wire: thin black SmoothPlastic cable
	local wire         = Instance.new("Part")
	wire.Name          = "_HarpoonWire"
	wire.Color         = Color3.fromRGB(12, 12, 16)
	wire.Material      = Enum.Material.SmoothPlastic
	wire.CastShadow    = false
	wire.Anchored      = true
	wire.CanCollide    = false
	wire.CanQuery      = false
	wire.Parent        = workspace

	-- Bolt: small dark metal cylinder clamped onto the target's side
	local bolt         = Instance.new("Part")
	bolt.Name          = "_HarpoonBolt"
	bolt.Shape         = Enum.PartType.Cylinder
	bolt.Size          = Vector3.new(0.5, 0.6, 0.6)
	bolt.Color         = Color3.fromRGB(25, 25, 30)
	bolt.Material      = Enum.Material.Metal
	bolt.CastShadow    = false
	bolt.Anchored      = true
	bolt.CanCollide    = false
	bolt.CanQuery      = false
	bolt.Parent        = workspace

	local elapsed    = 0
	local retracting = false
	local retractT   = 0
	local anchorTip  = toPos  -- last known bolt position when retraction begins

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt

		-- Resolve live positions — follow moving parts
		local basePos = (trapperPart and trapperPart.Parent)
			and (trapperPart.Position + Vector3.new(0, trapperPart.Size.Y * 0.25, 0))
			or  fromPos

		local tipPos = (targetPart and targetPart.Parent)
			and (targetPart.Position + Vector3.new(0, targetPart.Size.Y * 0.35, 0))
			or  anchorTip

		-- Target was destroyed early — start retraction from its last position
		if not retracting and targetPart and not targetPart.Parent then
			retracting = true
			anchorTip  = tipPos
		end

		-- Trapper was destroyed — remove wire immediately
		if trapperPart and not trapperPart.Parent then
			conn:Disconnect()
			wire:Destroy()
			bolt:Destroy()
			return
		end

		if not retracting then
			-- Stay taut: update wire and bolt each frame
			local d = (tipPos - basePos).Magnitude
			if d > 0.2 then
				wire.Size  = Vector3.new(0.18, 0.18, d)
				wire.CFrame = CFrame.lookAt(basePos, tipPos) * CFrame.new(0, 0, -d / 2)
			end
			-- Bolt cylinder axis points along the wire toward the trapper
			bolt.Position = tipPos
			bolt.CFrame   = CFrame.lookAt(tipPos, basePos) * CFrame.Angles(0, 0, math.pi / 2)

			if elapsed >= SLOW_DUR then
				retracting = true
				anchorTip  = tipPos
			end
		else
			-- Retraction: bolt slides from anchorTip back toward basePos
			retractT += dt
			local t    = math.clamp(retractT / RETRACT_T, 0, 1)
			local ease = t * (2 - t)  -- ease-out

			local boltNow = anchorTip:Lerp(basePos, ease)
			bolt.Position = boltNow
			bolt.CFrame   = CFrame.lookAt(boltNow, basePos) * CFrame.Angles(0, 0, math.pi / 2)

			local d = (boltNow - basePos).Magnitude
			if d > 0.25 then
				wire.Size  = Vector3.new(0.18, 0.18, d)
				wire.CFrame = CFrame.lookAt(basePos, boltNow) * CFrame.new(0, 0, -d / 2)
			else
				wire.Size = Vector3.new(0.18, 0.18, 0.25)
			end

			if t >= 1 then
				conn:Disconnect()
				wire:Destroy()
				bolt:Destroy()
			end
		end
	end)
end

-- A semi-transparent green neon beam that fades out over ~0.45 s.
local function spawnHealBeam(fromPos: Vector3, toPos: Vector3)
	local dist = (toPos - fromPos).Magnitude
	if dist < 0.5 then return end

	local beam              = Instance.new("Part")
	beam.Name               = "_HealBeam"
	beam.Size               = Vector3.new(0.22, 0.22, dist)
	-- CFrame.lookAt positions at fromPos facing toPos (-Z forward);
	-- shift dist/2 along -Z to centre the beam between the two points.
	beam.CFrame             = CFrame.lookAt(fromPos, toPos) * CFrame.new(0, 0, -dist / 2)
	beam.Color              = Color3.fromRGB(80, 220, 120)
	beam.Material           = Enum.Material.Neon
	beam.Transparency       = 0.25
	beam.Anchored           = true
	beam.CanCollide         = false
	beam.CastShadow         = false
	beam.CanQuery           = false
	beam.Parent             = workspace

	-- Small glow sphere at the target end
	local glow              = Instance.new("Part")
	glow.Name               = "_HealGlow"
	glow.Shape              = Enum.PartType.Ball
	glow.Size               = Vector3.new(0.8, 0.8, 0.8)
	glow.Color              = Color3.fromRGB(140, 255, 170)
	glow.Material           = Enum.Material.Neon
	glow.Transparency       = 0.3
	glow.Anchored           = true
	glow.CanCollide         = false
	glow.CastShadow         = false
	glow.CanQuery           = false
	glow.Position           = toPos
	glow.Parent             = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.clamp(elapsed / 0.45, 0, 1)
		local alpha = t * t   -- ease-in fade
		beam.Transparency = 0.25 + alpha * 0.75
		glow.Transparency = 0.30 + alpha * 0.70
		if t >= 1 then
			conn:Disconnect()
			beam:Destroy()
			glow:Destroy()
		end
	end)
end

Network.onHealBeam(function(fromPos: Vector3, toPos: Vector3)
	spawnHealBeam(fromPos, toPos)
end)

Network.onUnitHit(function(fromPos: Vector3, toPos: Vector3, unitType: string)
	if unitType == "Elite" then
		spawnEliteProjectile(fromPos, toPos)
		return
	end

	if unitType == "TankBarrage" then
		spawnRocketBarrage(fromPos, toPos)
		return
	end

	if unitType == "TankHarpoon" then
		spawnTrapperHarpoon(fromPos, toPos)
		return
	end

	if unitType == "Tank" then
		spawnTankShell(fromPos, toPos)
		return
	end

	-- Soldier: small fast yellow bullet with simple impact flash
	local origin = fromPos + Vector3.new(0, 1.5, 0)
	local dest   = toPos   + Vector3.new(0, 1.0, 0)

	local proj          = Instance.new("Part")
	proj.Name           = "_UnitProj"
	proj.Size           = Vector3.new(0.45, 0.45, 0.45)
	proj.Shape          = Enum.PartType.Ball
	proj.BrickColor     = BrickColor.new("Bright yellow")
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
		local t = math.min(elapsed / 0.14, 1)
		proj.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * 0.8, 0)

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			local flash         = Instance.new("Part")
			flash.Name          = "_UnitImpact"
			flash.Size          = Vector3.new(1.5, 1.5, 1.5)
			flash.Shape         = Enum.PartType.Ball
			flash.BrickColor    = BrickColor.new("Bright yellow")
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

-- Base turret: small red ball + flash (unchanged)
local function spawnBaseTurretShot(fromPos: Vector3, toPos: Vector3)
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

	local TRAVEL = 0.22
	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		proj.Position = fromPos:Lerp(toPos, t) + Vector3.new(0, math.sin(t * math.pi) * 2, 0)
		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
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
end

-- Flamethrower: fast oriented bolt → orange burst + flat ring on hit
-- Part budget: 1 projectile + 2 impact parts = 3 max per shot
-- Flamethrower: instant beam + 4 fire blobs → burst + ring on hit
-- Part budget: 1 beam + 4 blobs + 2 impact = 7, all gone within 0.22s
local function spawnFlamethrowerShot(fromPos: Vector3, toPos: Vector3)
	local dest = toPos + Vector3.new(0, 0.5, 0)
	local dir  = dest - fromPos
	local len  = dir.Magnitude
	if len < 0.5 then return end

	local FADE = 0.22

	-- Thin neon beam spanning full path
	local mid          = (fromPos + dest) * 0.5
	local beam         = Instance.new("Part")
	beam.Name          = "_FlameBeam"
	beam.Size          = Vector3.new(0.35, 0.35, len)
	beam.Color         = Color3.fromRGB(255, 160, 30)
	beam.Material      = Enum.Material.Neon
	beam.Anchored      = true
	beam.CanCollide    = false
	beam.CanQuery      = false
	beam.CastShadow    = false
	beam.CFrame        = CFrame.new(mid, dest)
	beam.Parent        = workspace

	-- 4 fire blobs: small near barrel, large near target, yellow→deep orange
	local BLOB_DEFS = {
		{ t = 0.12, sz = 0.70, r = 255, g = 230, b = 40,  offY =  0.10 },
		{ t = 0.35, sz = 0.95, r = 255, g = 160, b = 20,  offY = -0.15 },
		{ t = 0.60, sz = 1.25, r = 255, g = 100, b = 10,  offY =  0.20 },
		{ t = 0.83, sz = 1.55, r = 230, g = 60,  b =  5,  offY = -0.10 },
	}
	local blobs: { Part } = {}
	local rng = Random.new()
	for _, def in BLOB_DEFS do
		local pos    = fromPos:Lerp(dest, def.t)
		local randOff = Vector3.new(
			(rng:NextNumber() - 0.5) * 0.8,
			def.offY,
			(rng:NextNumber() - 0.5) * 0.8
		)
		local b        = Instance.new("Part")
		b.Name         = "_FlameBlob"
		b.Shape        = Enum.PartType.Ball
		b.Size         = Vector3.new(def.sz, def.sz, def.sz)
		b.Color        = Color3.fromRGB(def.r, def.g, def.b)
		b.Material     = Enum.Material.Neon
		b.Anchored     = true
		b.CanCollide   = false
		b.CanQuery     = false
		b.CastShadow   = false
		b.Position     = pos + randOff
		b.Parent       = workspace
		table.insert(blobs, b)
	end

	-- Impact: burst sphere + flat ring
	local burst        = Instance.new("Part")
	burst.Name         = "_FlameBurst"
	burst.Shape        = Enum.PartType.Ball
	burst.Size         = Vector3.new(1.2, 1.2, 1.2)
	burst.Color        = Color3.fromRGB(255, 120, 15)
	burst.Material     = Enum.Material.Neon
	burst.Position     = dest
	burst.Anchored     = true
	burst.CanCollide   = false
	burst.CanQuery     = false
	burst.CastShadow   = false
	burst.Parent       = workspace

	local ring         = Instance.new("Part")
	ring.Name          = "_FlameRing"
	ring.Shape         = Enum.PartType.Cylinder
	ring.Size          = Vector3.new(0.22, 0.8, 0.8)
	ring.Color         = Color3.fromRGB(200, 55, 5)
	ring.Material      = Enum.Material.Neon
	ring.Anchored      = true
	ring.CanCollide    = false
	ring.CanQuery      = false
	ring.CastShadow    = false
	ring.CFrame        = CFrame.new(dest) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent        = workspace

	local RING_DUR = 0.19
	local elapsed  = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local ft = math.min(elapsed / FADE, 1)

		-- fade beam
		if beam.Parent then
			beam.Transparency = ft
			if ft >= 1 then beam:Destroy() end
		end
		-- fade blobs
		for _, b in blobs do
			if b.Parent then
				b.Transparency = ft
				if ft >= 1 then b:Destroy() end
			end
		end
		-- burst expands + fades
		if burst.Parent then
			local s = 1.2 + ft * 3.8
			burst.Size         = Vector3.new(s, s, s)
			burst.Transparency = ft * 0.9
			if ft >= 1 then burst:Destroy() end
		end
		-- ring expands + fades
		if ring.Parent then
			local rt = math.min(elapsed / RING_DUR, 1)
			local d  = 0.8 + rt * 5.0
			ring.Size         = Vector3.new(0.22, d, d)
			ring.Transparency = 0.1 + rt * 0.9
			if rt >= 1 then ring:Destroy() end
		end

		if elapsed >= FADE then conn:Disconnect() end
	end)
end

-- Rocket Launcher: oriented rocket body + exhaust glow → white core + expanding
-- ring + smoke cloud.
-- Part budget: 2 projectile + 3 impact = 5 max per shot (rockets fire rarely)
local function spawnRocketShot(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.32
	local ARC    = 1.2
	local origin = fromPos
	local dest   = toPos + Vector3.new(0, 0.8, 0)
	local dir    = dest - origin

	-- Rocket body: elongated dark part oriented toward target
	local body        = Instance.new("Part")
	body.Name         = "_RocketBody"
	body.Size         = Vector3.new(1.3, 1.3, 4.5)
	body.BrickColor   = BrickColor.new("Dark stone grey")
	body.Material     = Enum.Material.Metal
	body.Anchored     = true
	body.CanCollide   = false
	body.CanQuery     = false
	body.CastShadow   = false
	body.CFrame       = dir.Magnitude > 0.1
		and CFrame.new(origin, origin + dir.Unit)
		or  CFrame.new(origin)
	body.Parent       = workspace

	-- Exhaust glow: small neon orange orb at rear of body
	local exhaust        = Instance.new("Part")
	exhaust.Name         = "_RocketExhaust"
	exhaust.Shape        = Enum.PartType.Ball
	exhaust.Size         = Vector3.new(1.1, 1.1, 1.1)
	exhaust.BrickColor   = BrickColor.new("Bright orange")
	exhaust.Material     = Enum.Material.Neon
	exhaust.Anchored     = true
	exhaust.CanCollide   = false
	exhaust.CanQuery     = false
	exhaust.CastShadow   = false
	exhaust.Position     = origin
	exhaust.Parent       = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t   = math.min(elapsed / TRAVEL, 1)
		local cur = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)
		local lookDir = dest - cur

		body.CFrame = lookDir.Magnitude > 0.1
			and CFrame.new(cur, dest)
			or  CFrame.new(cur)
		-- Keep exhaust at the back of the body (-Z tail)
		local back = lookDir.Magnitude > 0.1
			and (lookDir.Unit * -2.25)
			or  Vector3.new(0, 0, 2.25)
		exhaust.Position = cur + back

		if t >= 1 then
			conn:Disconnect()
			body:Destroy()
			exhaust:Destroy()

			-- White core flash: instant bright burst
			local core        = Instance.new("Part")
			core.Name         = "_RocketCore"
			core.Shape        = Enum.PartType.Ball
			core.Size         = Vector3.new(2.8, 2.8, 2.8)
			core.BrickColor   = BrickColor.new("White")
			core.Material     = Enum.Material.Neon
			core.Position     = dest
			core.Anchored     = true
			core.CanCollide   = false
			core.CanQuery     = false
			core.CastShadow   = false
			core.Parent       = workspace

			-- Expanding shockwave ring: yellow-orange
			local ring        = Instance.new("Part")
			ring.Name         = "_RocketRing"
			ring.Shape        = Enum.PartType.Cylinder
			ring.Size         = Vector3.new(0.35, 1, 1)
			ring.BrickColor   = BrickColor.new("Bright yellow")
			ring.Material     = Enum.Material.Neon
			ring.Anchored     = true
			ring.CanCollide   = false
			ring.CanQuery     = false
			ring.CastShadow   = false
			ring.CFrame       = CFrame.new(dest + Vector3.new(0, 0.4, 0))
				* CFrame.Angles(0, 0, math.pi / 2)
			ring.Parent       = workspace

			-- Smoke/dust cloud: grey sphere that expands and fades slowly
			local smoke       = Instance.new("Part")
			smoke.Name        = "_RocketSmoke"
			smoke.Shape       = Enum.PartType.Ball
			smoke.Size        = Vector3.new(2, 2, 2)
			smoke.Color       = Color3.fromRGB(90, 80, 70)
			smoke.Material    = Enum.Material.SmoothPlastic
			smoke.Anchored    = true
			smoke.CanCollide  = false
			smoke.CanQuery    = false
			smoke.CastShadow  = false
			smoke.Position    = dest
			smoke.Parent      = workspace

			local CORE_DUR  = 0.09
			local RING_DUR  = 0.30
			local SMOKE_DUR = 0.42
			local e2        = 0
			local ic: RBXScriptConnection
			ic = RunService.RenderStepped:Connect(function(idt)
				e2 += idt
				if core.Parent then
					if e2 < CORE_DUR then
						core.Transparency = e2 / CORE_DUR
					else
						core:Destroy()
					end
				end
				if ring.Parent then
					if e2 < RING_DUR then
						local rt = e2 / RING_DUR
						local d  = 1 + rt * 13
						ring.Size         = Vector3.new(0.35, d, d)
						ring.Transparency = 0.1 + rt * 0.9
					else
						ring:Destroy()
					end
				end
				if smoke.Parent then
					if e2 < SMOKE_DUR then
						local st = e2 / SMOKE_DUR
						local s  = 2 + st * 7
						smoke.Size         = Vector3.new(s, s, s)
						smoke.Transparency = 0.15 + st * 0.80
					else
						smoke:Destroy()
					end
				end
				if e2 >= SMOKE_DUR then ic:Disconnect() end
			end)
		end
	end)
end

Network.onTurretShot(function(fromPos: Vector3, toPos: Vector3, upgradeType: string?)
	if upgradeType == "Flamethrower" then
		spawnFlamethrowerShot(fromPos, toPos)
	elseif upgradeType == "RocketLauncher" then
		spawnRocketShot(fromPos, toPos)
	else
		spawnBaseTurretShot(fromPos, toPos)
	end
end)

end -- startGame

CometManager.init()
LobbyUI.init(startGame)
