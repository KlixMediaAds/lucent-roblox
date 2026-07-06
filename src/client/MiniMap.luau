local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

local MiniMap     = {}
local localPlayer = Players.LocalPlayer

-- ── Constants ────────────────────────────────────────────────────────────────

local MAP_SIZE   = 144    -- minimap square pixel size (reduced 20% from 180)
local WORLD_HALF = 432    -- studs from center to edge (matches FogManager: 72×12/2)
local PADDING    = 10     -- px gap from screen edge

-- Dot sizes (diameter)
local DOT_UNIT    = 5
local DOT_BLD     = 8
local DOT_MINER   = 3
local DOT_DEPOSIT = 4   -- ore deposit square side length

local LINE_T     = 1      -- viewport rectangle line thickness (px)

-- Palette — matches existing HUD aesthetic
local C_BG          = Color3.fromRGB( 10,  15,  28)
local C_BORDER      = Color3.fromRGB( 35,  75, 140)
local C_GRID        = Color3.fromRGB( 20,  30,  55)
local C_OWN_UNIT    = Color3.fromRGB( 50, 230,  90)
local C_OWN_BLD     = Color3.fromRGB(  0, 190, 255)
local C_ENEMY_UNIT  = Color3.fromRGB(230,  50,  50)
local C_ENEMY_BLD   = Color3.fromRGB(220,  80,  40)
local C_MINER       = Color3.fromRGB( 90, 200, 110)
local C_VIEWPORT    = Color3.fromRGB(255, 255, 255)
local C_CC_OWN      = Color3.fromRGB(255, 200,  40)
local C_CC_ENEMY    = Color3.fromRGB(220, 100,  30)
local C_MONUMENT    = Color3.fromRGB(255, 215,   0)  -- gold — always shown
local C_DEPOSIT     = Color3.fromRGB(255, 248, 160)  -- light yellow — ore deposits
local C_TERRAIN     = Color3.fromRGB(78,  66,  56)   -- grey-brown — terrain obstacles

-- Attack-alert ping colors, keyed by category
local PING_COLORS: { [string]: Color3 } = {
	base = Color3.fromRGB(255,  70,  55),   -- red    — buildings under attack
	army = Color3.fromRGB(255, 195,  45),   -- amber  — units under attack
}

-- ── State ─────────────────────────────────────────────────────────────────────

local canvas:      Frame
local cameraRef:   any
local localUserId: number

-- "Return to Command Center" camera button. Always visible; dims when the view is
-- already home (near the CC / no rotation). Wired via MiniMap.onReturnClicked.
local returnBtn:     TextButton?   = nil
local returnStroke:  UIStroke?     = nil
local returnBadge:   TextLabel?    = nil
local returnClickFn: (() -> ())?   = nil
local returnDimmed   = false

local unitMarkers: { [string]: TextLabel } = {}
-- Last written pose per unit marker — GUI property writes invalidate the minimap
-- canvas, so idle units are skipped entirely (see syncUnitTriangles).
local unitLastU: { [string]: number } = {}
local unitLastV: { [string]: number } = {}
local unitLastR: { [string]: number } = {}
local buildingDots:{ [string]: Frame } = {}
local minerDots:   { [string]: Frame } = {}
local depositDots: { [string]: Frame } = {}
local terrainDots: { [string]: Frame } = {}  -- terrain obstacle rectangles
local vpLines:     { Frame }           = {}  -- 4 viewport rectangle edges

-- CC avatar icons (one per Command Center building)
local ccIcons:      { [string]: Frame }  = {}
local ccIconOwners: { [string]: number } = {}  -- building id → userId
local enemyMarks:   { Frame }            = {}  -- persistent enemy-structure crosshairs
local thumbCache:   { [number]: string } = {}  -- userId → thumbnail URL
local thumbLoading: { [number]: boolean } = {}

-- ── World ↔ minimap conversion ────────────────────────────────────────────────

local function w2m(wx: number, wz: number): (number, number)
	local u = (wx + WORLD_HALF) / (WORLD_HALF * 2) * MAP_SIZE
	local v = (wz + WORLD_HALF) / (WORLD_HALF * 2) * MAP_SIZE
	return u, v
end

local function m2w(mu: number, mv: number): Vector3
	return Vector3.new(
		mu / MAP_SIZE * (WORLD_HALF * 2) - WORLD_HALF,
		0,
		mv / MAP_SIZE * (WORLD_HALF * 2) - WORLD_HALF
	)
end

-- ── Dot helpers ───────────────────────────────────────────────────────────────

local function makeDot(size: number, color: Color3): Frame
	local f            = Instance.new("Frame")
	f.Size             = UDim2.fromOffset(size, size)
	f.AnchorPoint      = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = color
	f.BorderSizePixel  = 0
	f.ZIndex           = 3
	local c            = Instance.new("UICorner")
	c.CornerRadius     = UDim.new(1, 0)
	c.Parent           = f
	f.Parent           = canvas
	return f
end

local function placeDot(dot: Frame, wx: number, wz: number)
	local u, v    = w2m(wx, wz)
	dot.Position  = UDim2.fromOffset(u, v)
end

-- ── CC avatar icon ────────────────────────────────────────────────────────────

local function makeCCIcon(buildingId: string, userId: number, isOwn: boolean): Frame
	local borderColor = isOwn and C_CC_OWN or C_CC_ENEMY

	local ring               = Instance.new("Frame")
	ring.Name                = "CCIcon"
	ring.Size                = UDim2.fromOffset(20, 20)
	ring.AnchorPoint         = Vector2.new(0.5, 0.5)
	ring.BackgroundColor3    = borderColor
	ring.BorderSizePixel     = 0
	ring.ZIndex              = 4
	Instance.new("UICorner", ring).CornerRadius = UDim.new(1, 0)

	local img                = Instance.new("ImageLabel")
	img.Name                 = "PfpImage"
	img.Size                 = UDim2.new(1, -4, 1, -4)
	img.Position             = UDim2.fromOffset(2, 2)
	img.BackgroundColor3     = Color3.fromRGB(15, 20, 35)
	img.BorderSizePixel      = 0
	img.ZIndex               = 5
	img.ScaleType            = Enum.ScaleType.Crop
	Instance.new("UICorner", img).CornerRadius = UDim.new(1, 0)
	img.Parent               = ring

	if thumbCache[userId] then
		img.Image = thumbCache[userId]
	elseif not thumbLoading[userId] then
		thumbLoading[userId] = true
		task.spawn(function()
			local ok, url = pcall(function()
				return Players:GetUserThumbnailAsync(
					userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size48x48
				)
			end)
			if ok and url then
				thumbCache[userId] = url
				for bid, owner in ccIconOwners do
					if owner == userId then
						local ic   = ccIcons[bid]
						local imgL = ic and ic:FindFirstChild("PfpImage") :: ImageLabel?
						if imgL then imgL.Image = url end
					end
				end
			end
		end)
	end

	ring.Parent = canvas
	return ring
end

-- ── Triangle unit marker ───────────────────────────────────────────────────────

local function makeTriangleMarker(color: Color3): TextLabel
	local lbl                   = Instance.new("TextLabel")
	lbl.Size                    = UDim2.fromOffset(11, 11)
	lbl.AnchorPoint             = Vector2.new(0.5, 0.5)
	lbl.BackgroundTransparency  = 1
	lbl.Text                    = "▲"
	lbl.TextSize                = 9
	lbl.TextColor3              = color
	lbl.Font                    = Enum.Font.GothamBold
	lbl.TextXAlignment          = Enum.TextXAlignment.Center
	lbl.TextYAlignment          = Enum.TextYAlignment.Center
	lbl.BorderSizePixel         = 0
	lbl.ZIndex                  = 4
	lbl.Parent                  = canvas
	return lbl
end

local function syncUnitTriangles(folder: Instance?, myStr: string)
	local seen: { [string]: true } = {}

	if folder then
		for _, child in folder:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local ov = child:FindFirstChild("OwnerId") :: StringValue?
			if not ov then continue end
			local bp    = child :: BasePart
			local isOwn = ov.Value == myStr

			if not isOwn and bp.LocalTransparencyModifier >= 1 then continue end

			local id     = child.Name
			seen[id]     = true

			local marker = unitMarkers[id]
			if not marker then
				marker          = makeTriangleMarker(isOwn and C_OWN_UNIT or C_ENEMY_UNIT)
				unitMarkers[id] = marker
			end

			-- Position (centre of marker = unit world position); rotation 0° = up
			-- (north/-Z world), 90° = right (+X world). Only write on change — GUI
			-- writes invalidate the canvas, so idle units must cost nothing.
			local u, v = w2m(bp.Position.X, bp.Position.Z)
			if unitLastU[id] ~= u or unitLastV[id] ~= v then
				unitLastU[id], unitLastV[id] = u, v
				marker.Position = UDim2.fromOffset(u, v)
			end
			local lv  = bp.CFrame.LookVector
			local rot = math.deg(math.atan2(lv.X, -lv.Z))
			if unitLastR[id] ~= rot then
				unitLastR[id]   = rot
				marker.Rotation = rot
			end
		end
	end

	for id, marker in unitMarkers do
		if not seen[id] then
			marker:Destroy()
			unitMarkers[id] = nil
			unitLastU[id], unitLastV[id], unitLastR[id] = nil, nil, nil
		end
	end
end

-- ── Line helpers (viewport rectangle) ────────────────────────────────────────

local function makeLine(): Frame
	local f            = Instance.new("Frame")
	f.AnchorPoint      = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = C_VIEWPORT
	f.BorderSizePixel  = 0
	f.ZIndex           = 5
	f.Parent           = canvas
	return f
end

local function setLine(ln: Frame, p1: Vector2, p2: Vector2)
	local cx = (p1.X + p2.X) * 0.5
	local cy = (p1.Y + p2.Y) * 0.5
	local dx = p2.X - p1.X
	local dy = p2.Y - p1.Y
	ln.Size     = UDim2.fromOffset(math.max(math.sqrt(dx*dx + dy*dy), 1), LINE_T + 1)
	ln.Position = UDim2.fromOffset(cx, cy)
	ln.Rotation = math.deg(math.atan2(dy, dx))
end

-- ── Dot pool sync ─────────────────────────────────────────────────────────────

-- Syncs a flat folder of BaseParts (Units / Miners).
local function syncPartDots(
	folder:   Instance?,
	pool:     { [string]: Frame },
	myStr:    string,
	dotSize:  number,
	ownColor: Color3,
	foeColor: Color3
)
	local seen: { [string]: true } = {}

	if folder then
		for _, child in folder:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local ov = child:FindFirstChild("OwnerId") :: StringValue?
			if not ov then continue end
			local bp    = child :: BasePart
			local isOwn = ov.Value == myStr

			-- Hide enemy entities that are fully in unexplored fog
			if not isOwn and bp.LocalTransparencyModifier >= 1 then continue end

			local id  = child.Name
			seen[id]  = true
			local dot = pool[id]
			if not dot then
				dot      = makeDot(dotSize, isOwn and ownColor or foeColor)
				pool[id] = dot
			end
			placeDot(dot, bp.Position.X, bp.Position.Z)
		end
	end

	for id, dot in pool do
		if not seen[id] then dot:Destroy(); pool[id] = nil end
	end
end

-- Syncs building models (Children have a "Base" BasePart).
local function syncBuildingDots(folder: Instance?, pool: { [string]: Frame }, myStr: string)
	local seen: { [string]: true } = {}

	if folder then
		for _, model in folder:GetChildren() do
			local ov = model:FindFirstChild("OwnerId") :: StringValue?
			if not ov then continue end
			local base = model:FindFirstChild("Base")
			if not base or not base:IsA("BasePart") then continue end
			local bp    = base :: BasePart
			local isOwn = ov.Value == myStr

			-- Determine building type first (Monument bypasses fog check)
			local btv   = model:FindFirstChild("BuildingType") :: StringValue?
			local btype = btv and btv.Value or ""

			-- CCs use avatar icons (handled by syncCCIcons)
			if btype == "CommandCenter" then continue end

			-- Hide fully-fogged enemy buildings (Monuments are always shown)
			if not isOwn and bp.LocalTransparencyModifier >= 1 and btype ~= "Monument" then continue end

			local id  = model.Name
			seen[id]  = true

			-- Color — Monument is gold, CC gets distinct gold/orange, others normal
			local color: Color3
			if btype == "Monument" then
				color = C_MONUMENT
			elseif isOwn then
				color = btype == "CommandCenter" and C_CC_OWN or C_OWN_BLD
			else
				color = btype == "CommandCenter" and C_CC_ENEMY or C_ENEMY_BLD
			end

			local dot = pool[id]
			if not dot then
				dot      = makeDot(DOT_BLD, color)
				pool[id] = dot
			else
				-- Update color if needed (e.g. ghost → visible transition)
				dot.BackgroundColor3 = color
			end
			placeDot(dot, bp.Position.X, bp.Position.Z)
		end
	end

	for id, dot in pool do
		if not seen[id] then dot:Destroy(); pool[id] = nil end
	end
end

-- ── CC avatar icon sync ───────────────────────────────────────────────────────

local function syncCCIcons(folder: Instance?, myStr: string)
	local seen: { [string]: true } = {}

	if folder then
		for _, model in folder:GetChildren() do
			local ov  = model:FindFirstChild("OwnerId")      :: StringValue?
			local btv = model:FindFirstChild("BuildingType") :: StringValue?
			if not ov or not btv or btv.Value ~= "CommandCenter" then continue end

			local base = model:FindFirstChild("Base")
			if not base or not base:IsA("BasePart") then continue end
			local bp    = base :: BasePart
			local isOwn = ov.Value == myStr

			-- Only reveal enemy CC once it has been spotted (not fully fogged)
			if not isOwn and bp.LocalTransparencyModifier >= 1 then continue end

			local id     = model.Name
			seen[id]     = true
			local userId = tonumber(ov.Value) or 0

			if not ccIcons[id] then
				ccIcons[id]      = makeCCIcon(id, userId, isOwn)
				ccIconOwners[id] = userId
			end

			local u, v          = w2m(bp.Position.X, bp.Position.Z)
			ccIcons[id].Position = UDim2.fromOffset(u, v)
		end
	end

	for id, icon in ccIcons do
		if not seen[id] then
			icon:Destroy()
			ccIcons[id]      = nil
			ccIconOwners[id] = nil
		end
	end
end

-- ── Terrain obstacle rectangles ──────────────────────────────────────────────

local function syncTerrainDots()
	local seen: { [string]: true } = {}
	local folder = workspace:FindFirstChild("TerrainObstacles")

	if folder then
		for i, part in ipairs(folder:GetChildren()) do
			if not part:IsA("BasePart") then continue end
			local id  = "t" .. i
			seen[id]  = true

			local dot = terrainDots[id]
			if not dot then
				local pw = math.max(3, part.Size.X / (WORLD_HALF * 2) * MAP_SIZE)
				local ph = math.max(3, part.Size.Z / (WORLD_HALF * 2) * MAP_SIZE)
				dot                    = Instance.new("Frame")
				dot.Size               = UDim2.fromOffset(pw, ph)
				dot.AnchorPoint        = Vector2.new(0.5, 0.5)
				dot.BackgroundColor3   = C_TERRAIN
				dot.BackgroundTransparency = 0.2
				dot.BorderSizePixel    = 0
				dot.ZIndex             = 1   -- drawn behind everything else
				dot.Parent             = canvas
				terrainDots[id]        = dot
			end

			local u, v     = w2m(part.Position.X, part.Position.Z)
			dot.Position   = UDim2.fromOffset(u, v)
		end
	end

	for id, dot in terrainDots do
		if not seen[id] then dot:Destroy(); terrainDots[id] = nil end
	end
end

-- ── Deposit dots (squares, always visible) ────────────────────────────────────

-- Reads unclaimed deposits from the server-created workspace.Deposits folder.
-- Deposits show regardless of fog — resource nodes are global map knowledge.
local function syncDepositDots()
	local seen: { [string]: true } = {}
	local depositsF = workspace:FindFirstChild("Deposits")

	if depositsF then
		for _, model in depositsF:GetChildren() do
			if not model:IsA("Model") then continue end
			local primary = (model :: Model).PrimaryPart
			if not primary then continue end

			local id = model.Name  -- posKey string, unique per deposit
			seen[id] = true

			local dot = depositDots[id]
			if not dot then
				dot                   = Instance.new("Frame")
				dot.Size              = UDim2.fromOffset(DOT_DEPOSIT, DOT_DEPOSIT)
				dot.AnchorPoint       = Vector2.new(0.5, 0.5)
				dot.BackgroundColor3  = C_DEPOSIT
				dot.BorderSizePixel   = 0
				dot.ZIndex            = 2   -- behind units/buildings, above background
				dot.Parent            = canvas
				depositDots[id]       = dot
			end

			placeDot(dot, primary.Position.X, primary.Position.Z)
		end
	end

	for id, dot in depositDots do
		if not seen[id] then dot:Destroy(); depositDots[id] = nil end
	end
end

-- ── Viewport rectangle ────────────────────────────────────────────────────────

local function projectToGround(sx: number, sy: number): Vector3?
	local cam = workspace.CurrentCamera
	local ray = cam:ViewportPointToRay(sx, sy, 0)
	if math.abs(ray.Direction.Y) < 1e-6 then return nil end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t <= 0 then return nil end
	return ray.Origin + ray.Direction * t
end

local function updateViewport()
	local cam = workspace.CurrentCamera
	local vp  = cam.ViewportSize

	local corners = {
		projectToGround(0,    0),
		projectToGround(vp.X, 0),
		projectToGround(vp.X, vp.Y),
		projectToGround(0,    vp.Y),
	}

	-- If any corner fails to hit the ground, hide the indicator
	local pts: { Vector2 } = {}
	for _, wc in corners do
		if not wc then
			for _, ln in vpLines do ln.Visible = false end
			return
		end
		local u, v = w2m(wc.X, wc.Z)
		table.insert(pts, Vector2.new(u, v))
	end

	for _, ln in vpLines do ln.Visible = true end
	-- Edges: TL→TR, TR→BR, BR→BL, BL→TL
	setLine(vpLines[1], pts[1], pts[2])
	setLine(vpLines[2], pts[2], pts[3])
	setLine(vpLines[3], pts[3], pts[4])
	setLine(vpLines[4], pts[4], pts[1])
end

-- ── Click / drag to pan ───────────────────────────────────────────────────────

local function hookInput(clickArea: GuiButton)
	local pressing = false

	local function tryPan()
		local ml = UserInputService:GetMouseLocation()
		local ap = clickArea.AbsolutePosition
		local mu = ml.X - ap.X
		local mv = ml.Y - ap.Y
		if mu < 0 or mv < 0 or mu > MAP_SIZE or mv > MAP_SIZE then return end
		cameraRef.setFocus(m2w(mu, mv))
	end

	clickArea.MouseButton1Down:Connect(function()
		pressing = true
		tryPan()
	end)

	-- The minimap sits in the top-right corner, inside the camera's edge-pan
	-- threshold. Suppress edge panning whenever the cursor is over it so
	-- click/drag-to-pan centres on the chosen point instead of drifting.
	clickArea.MouseEnter:Connect(function()
		cameraRef.setEdgePanSuppressed(true)
	end)
	clickArea.MouseLeave:Connect(function()
		cameraRef.setEdgePanSuppressed(false)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if pressing and input.UserInputType == Enum.UserInputType.MouseMovement then
			tryPan()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pressing = false
		end
	end)
end

-- ── Build UI ──────────────────────────────────────────────────────────────────

local function buildUI()
	local sg              = Instance.new("ScreenGui")
	sg.Name               = "MiniMapGui"
	sg.ResetOnSpawn       = false
	sg.ZIndexBehavior     = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset     = true   -- AbsolutePosition matches GetMouseLocation() coords
	sg.Parent             = localPlayer.PlayerGui

	-- Border frame
	local border              = Instance.new("Frame")
	border.Name               = "Border"
	border.Size               = UDim2.fromOffset(MAP_SIZE + 4, MAP_SIZE + 4)
	border.AnchorPoint        = Vector2.new(0, 1)
	border.Position           = UDim2.new(0, PADDING, 1, -PADDING)
	border.BackgroundColor3   = C_BORDER
	border.BorderSizePixel    = 0
	border.Parent             = sg

	-- Map canvas
	local inner               = Instance.new("Frame")
	inner.Name                = "Canvas"
	inner.Size                = UDim2.fromOffset(MAP_SIZE, MAP_SIZE)
	inner.Position            = UDim2.fromOffset(2, 2)
	inner.BackgroundColor3    = C_BG
	inner.BorderSizePixel     = 0
	inner.ClipsDescendants    = true
	inner.Parent              = border

	-- Faint center crosshair lines
	local hLine               = Instance.new("Frame")
	hLine.Size                = UDim2.new(1, 0, 0, 1)
	hLine.Position            = UDim2.new(0, 0, 0.5, 0)
	hLine.BackgroundColor3    = C_GRID
	hLine.BorderSizePixel     = 0
	hLine.ZIndex              = 1
	hLine.Parent              = inner

	local vLine               = Instance.new("Frame")
	vLine.Size                = UDim2.new(0, 1, 1, 0)
	vLine.Position            = UDim2.new(0.5, 0, 0, 0)
	vLine.BackgroundColor3    = C_GRID
	vLine.BorderSizePixel     = 0
	vLine.ZIndex              = 1
	vLine.Parent              = inner

	-- Invisible click capture layer (sits above all dots)
	local clickArea           = Instance.new("TextButton")
	clickArea.Name            = "ClickArea"
	clickArea.Size            = UDim2.new(1, 0, 1, 0)
	clickArea.BackgroundTransparency = 1
	clickArea.Text            = ""
	clickArea.ZIndex          = 10
	clickArea.Parent          = inner

	-- "MAP" label pinned to bottom of the border frame
	local lbl                 = Instance.new("TextLabel")
	lbl.Size                  = UDim2.fromOffset(MAP_SIZE + 4, 14)
	lbl.Position              = UDim2.new(0, 0, 0, -15)
	lbl.BackgroundTransparency= 1
	lbl.Text                  = ""
	lbl.Font                  = Enum.Font.GothamBold
	lbl.TextSize              = 10
	lbl.TextColor3            = C_BORDER
	lbl.TextXAlignment        = Enum.TextXAlignment.Center
	lbl.Parent                = border

	-- ── Return-to-CC button (just left of the minimap) ────────────────────────
	local rBtn                = Instance.new("TextButton")
	rBtn.Name                 = "ReturnToCCBtn"
	rBtn.Size                 = UDim2.fromOffset(28, 28)
	rBtn.AnchorPoint          = Vector2.new(1, 1)
	rBtn.Position             = UDim2.new(0, MAP_SIZE + 4 + PADDING, 1, -(MAP_SIZE + 4 + PADDING) - 5)
	rBtn.BackgroundColor3     = Color3.fromRGB(7, 9, 14)
	rBtn.BackgroundTransparency = 0.06
	rBtn.AutoButtonColor      = false
	rBtn.Text                 = "⌂"
	rBtn.Font                 = Enum.Font.GothamBold
	rBtn.TextSize             = 18
	rBtn.TextColor3           = C_CC_OWN
	rBtn.BorderSizePixel      = 0
	rBtn.Visible              = true
	rBtn.ZIndex               = 6
	rBtn.Parent               = sg
	Instance.new("UICorner", rBtn).CornerRadius = UDim.new(0, 6)
	local rStroke             = Instance.new("UIStroke")
	rStroke.Color             = C_CC_OWN
	rStroke.Thickness         = 1
	rStroke.Transparency      = 0.3
	rStroke.Parent            = rBtn
	returnStroke              = rStroke

	-- Small "R" key badge in the corner
	local rBadge              = Instance.new("TextLabel")
	rBadge.Size               = UDim2.fromOffset(11, 9)
	rBadge.AnchorPoint        = Vector2.new(1, 1)
	rBadge.Position           = UDim2.new(1, -2, 1, -1)
	rBadge.BackgroundTransparency = 1
	rBadge.Text               = "R"
	rBadge.Font               = Enum.Font.GothamBold
	rBadge.TextSize           = 9
	rBadge.TextColor3         = Color3.fromRGB(150, 170, 200)
	rBadge.TextXAlignment     = Enum.TextXAlignment.Right
	rBadge.ZIndex             = 7
	rBadge.Parent             = rBtn
	returnBadge               = rBadge

	rBtn.MouseEnter:Connect(function()
		TweenService:Create(rBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(20, 26, 38) }):Play()
		TweenService:Create(rStroke, TweenInfo.new(0.12), { Transparency = 0, Thickness = 1.8 }):Play()
	end)
	rBtn.MouseLeave:Connect(function()
		TweenService:Create(rBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(7, 9, 14) }):Play()
		TweenService:Create(rStroke, TweenInfo.new(0.12), { Transparency = 0.3, Thickness = 1 }):Play()
	end)
	rBtn.MouseButton1Click:Connect(function()
		if returnClickFn then returnClickFn() end
	end)
	returnBtn = rBtn

	return inner, clickArea
end

-- ── Attack-alert pings ────────────────────────────────────────────────────────

-- Drops a transient, pulsing ping on the minimap at a world position. Used by
-- the AttackAlert handler to show where the player's base/army is under attack.
-- `category` is "base" (red) or "army" (amber).
function MiniMap.ping(worldPos: Vector3, category: string)
	if not canvas then return end
	local color = PING_COLORS[category] or PING_COLORS.base
	local u, v  = w2m(worldPos.X, worldPos.Z)

	-- Persistent center dot (fades out after the pulses finish).
	local dot              = Instance.new("Frame")
	dot.Size               = UDim2.fromOffset(7, 7)
	dot.AnchorPoint        = Vector2.new(0.5, 0.5)
	dot.Position           = UDim2.fromOffset(u, v)
	dot.BackgroundColor3   = color
	dot.BorderSizePixel    = 0
	dot.ZIndex             = 9
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
	dot.Parent             = canvas

	-- Three expanding ring pulses, staggered for a radar-sweep feel.
	for i = 0, 2 do
		task.delay(i * 0.32, function()
			if not dot.Parent then return end   -- ping was cleaned up early
			local ring             = Instance.new("Frame")
			ring.Size              = UDim2.fromOffset(8, 8)
			ring.AnchorPoint       = Vector2.new(0.5, 0.5)
			ring.Position          = UDim2.fromOffset(u, v)
			ring.BackgroundTransparency = 1
			ring.ZIndex            = 8
			Instance.new("UICorner", ring).CornerRadius = UDim.new(1, 0)
			local stroke           = Instance.new("UIStroke")
			stroke.Color           = color
			stroke.Thickness       = 2
			stroke.Transparency    = 0
			stroke.Parent          = ring
			ring.Parent            = canvas

			local ti = TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(ring, ti, { Size = UDim2.fromOffset(36, 36) }):Play()
			local fade = TweenService:Create(stroke, ti, { Transparency = 1 })
			fade:Play()
			fade.Completed:Once(function() ring:Destroy() end)
		end)
	end

	-- Fade and remove the center dot once the sweep completes.
	task.delay(1.7, function()
		if not dot.Parent then return end
		local out = TweenService:Create(dot, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
		out:Play()
		out.Completed:Once(function() dot:Destroy() end)
	end)
end

-- ── Enemy-structure crosshair ─────────────────────────────────────────────────

-- Draws a persistent squared crosshair at a world position to flag a discovered
-- enemy structure. The square "forms" with a brief scale-in + fade animation.
local C_CROSSHAIR = Color3.fromRGB(255, 60, 50)
function MiniMap.markEnemyStructure(worldPos: Vector3)
	if not canvas then return end
	local u, v = w2m(worldPos.X, worldPos.Z)

	local SQ = 20  -- final square side (px)

	local box              = Instance.new("Frame")
	box.Name               = "EnemyMark"
	box.Size               = UDim2.fromOffset(SQ, SQ)
	box.AnchorPoint        = Vector2.new(0.5, 0.5)
	box.Position           = UDim2.fromOffset(u, v)
	box.BackgroundTransparency = 1
	box.ZIndex             = 9
	box.Parent             = canvas
	local stroke           = Instance.new("UIStroke")
	stroke.Color           = C_CROSSHAIR
	stroke.Thickness       = 1.5
	stroke.Parent          = box

	-- Crosshair tick lines extending past each side of the square
	local function tick(horizontal: boolean)
		local ln              = Instance.new("Frame")
		ln.AnchorPoint        = Vector2.new(0.5, 0.5)
		ln.Position           = UDim2.fromScale(0.5, 0.5)
		ln.Size               = horizontal and UDim2.new(1, 8, 0, 1) or UDim2.new(0, 1, 1, 8)
		ln.BackgroundColor3   = C_CROSSHAIR
		ln.BorderSizePixel    = 0
		ln.ZIndex             = 9
		ln.Parent             = box
	end
	tick(true)
	tick(false)

	table.insert(enemyMarks, box)

	-- "Form" animation: start large + invisible, snap inward to final size.
	box.Size = UDim2.fromOffset(SQ * 2.4, SQ * 2.4)
	stroke.Transparency = 1
	TweenService:Create(box,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(SQ, SQ) }):Play()
	TweenService:Create(stroke, TweenInfo.new(0.25), { Transparency = 0 }):Play()

	-- Gentle ongoing pulse so the marker keeps drawing the eye.
	task.spawn(function()
		while box.Parent do
			TweenService:Create(stroke, TweenInfo.new(0.7, Enum.EasingStyle.Sine), { Thickness = 3 }):Play()
			task.wait(0.75)
			if not box.Parent then break end
			TweenService:Create(stroke, TweenInfo.new(0.7, Enum.EasingStyle.Sine), { Thickness = 1.5 }):Play()
			task.wait(0.75)
		end
	end)
end

-- Removes all enemy-structure crosshairs (called on game reset).
function MiniMap.clearEnemyStructures()
	for _, m in enemyMarks do
		if m.Parent then m:Destroy() end
	end
	enemyMarks = {}
end

-- ── Return-to-CC button API ───────────────────────────────────────────────────

-- Register the callback fired when the player clicks the return-to-CC button.
function MiniMap.onReturnClicked(fn: () -> ())
	returnClickFn = fn
end

-- Show or hide the return-to-CC button.
function MiniMap.setReturnVisible(v: boolean)
	if returnBtn then returnBtn.Visible = v end
end

-- Dim the [R] camera button when the view is already "home" (return is redundant),
-- brighten it once the player has panned / rotated away. Applies only on a state
-- change so it doesn't fight the hover tweens each frame.
function MiniMap.setReturnDimmed(dimmed: boolean)
	if dimmed == returnDimmed then return end
	returnDimmed = dimmed
	if returnBtn    then returnBtn.BackgroundTransparency = dimmed and 0.7 or 0.06 end
	if returnBtn    then (returnBtn :: TextButton).TextTransparency = dimmed and 0.55 or 0 end
	if returnStroke then returnStroke.Transparency = dimmed and 0.75 or 0.3 end
	if returnBadge  then returnBadge.TextTransparency = dimmed and 0.55 or 0 end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function MiniMap.init(cameraModule: any, userId: number)
	cameraRef   = cameraModule
	localUserId = userId

	local inner, clickArea = buildUI()
	canvas = inner

	for i = 1, 4 do vpLines[i] = makeLine() end

	hookInput(clickArea)

	local myStr = tostring(localUserId)

	-- Dot/marker sync at 10 Hz — imperceptible on a minimap, but 6× fewer folder
	-- scans, FindFirstChild calls and GUI writes than per-frame. The camera viewport
	-- rectangle stays per-frame so it tracks panning smoothly.
	local SYNC_INTERVAL = 0.1
	local syncAcc       = SYNC_INTERVAL  -- fire on the first frame

	RunService.RenderStepped:Connect(function(dt: number)
		syncAcc += dt
		if syncAcc >= SYNC_INTERVAL then
			syncAcc = 0

			local unitsF     = workspace:FindFirstChild("Units")
			local buildingsF = workspace:FindFirstChild("Buildings")
			local minersF    = workspace:FindFirstChild("Miners")

			syncTerrainDots()
			syncDepositDots()
			syncUnitTriangles(unitsF, myStr)
			syncBuildingDots(buildingsF, buildingDots, myStr)
			syncCCIcons(buildingsF, myStr)
			syncPartDots(minersF,   minerDots,   myStr, DOT_MINER, C_MINER,    C_MINER)
		end

		updateViewport()
	end)
end

return MiniMap
