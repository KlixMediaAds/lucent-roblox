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

-- ── Deposit markers (Mine placement mode only) ────────────────────────────────
-- When the player enters Mine placement mode every unclaimed deposit gets:
--   • A gold neon ring on the ground  +  a "⛏ Mine here" billboard label
--   • A screen-edge arrow that appears when the deposit is off-screen
-- All markers are cleaned up when placement mode exits.

local DEPOSIT_COLOR   = Color3.fromRGB(255, 205, 40)
local RING_BASE_SIZE  = Vector3.new(0.22, 9, 9)   -- flat cylinder (length = diameter)
local ARROW_MARGIN    = 50   -- px from screen edge for arrow anchor

type DepositMarker = {
    pos:   Vector3,
    ring:  Part,
    arrow: TextLabel,
}
local depositMarkers: { DepositMarker } = {}
local markerSg:       ScreenGui?        = nil

local function createDepositMarkers()
    if markerSg then return end
    if #depositPositions == 0 then return end

    -- Dedicated ScreenGui with IgnoreGuiInset so WorldToViewportPoint coords
    -- map directly onto the GUI without any top-bar offset.
    local sg                = Instance.new("ScreenGui")
    sg.Name                 = "DepositArrows"
    sg.IgnoreGuiInset       = true
    sg.ResetOnSpawn         = false
    sg.ZIndexBehavior       = Enum.ZIndexBehavior.Sibling
    sg.Parent               = localPlayer.PlayerGui
    markerSg = sg

    for _, pos in depositPositions do
        -- Ground ring
        local ring              = Instance.new("Part")
        ring.Name               = "_DepositRing"
        ring.Shape              = Enum.PartType.Cylinder
        ring.CFrame             = CFrame.new(pos + Vector3.new(0, 0.25, 0))
                                  * CFrame.Angles(0, 0, math.pi / 2)
        ring.Size               = RING_BASE_SIZE
        ring.Color              = DEPOSIT_COLOR
        ring.Material           = Enum.Material.Neon
        ring.Anchored           = true
        ring.CanCollide         = false
        ring.CanQuery           = false
        ring.CastShadow         = false
        ring.Transparency       = 0.3
        ring.Parent             = workspace

        -- "⛏ Mine here" billboard floating above the deposit
        local bb                = Instance.new("BillboardGui")
        bb.Name                 = "_DepositBB"
        bb.Size                 = UDim2.fromOffset(110, 30)
        bb.StudsOffset          = Vector3.new(0, 8, 0)
        bb.AlwaysOnTop          = false
        bb.MaxDistance          = 350
        bb.Parent               = ring

        local bl                = Instance.new("TextLabel")
        bl.Size                 = UDim2.new(1, 0, 1, 0)
        bl.BackgroundTransparency = 1
        bl.Font                 = Enum.Font.GothamBold
        bl.TextSize             = 15
        bl.TextColor3           = DEPOSIT_COLOR
        bl.TextStrokeTransparency = 0.25
        bl.TextStrokeColor3     = Color3.new(0, 0, 0)
        bl.Text                 = "⛏  Mine here"
        bl.Parent               = bb

        -- Screen-edge arrow (invisible until the deposit goes off-screen)
        local ar                = Instance.new("TextLabel")
        ar.Name                 = "_DepositArrow"
        ar.Size                 = UDim2.fromOffset(44, 44)
        ar.AnchorPoint          = Vector2.new(0.5, 0.5)
        ar.BackgroundColor3     = Color3.fromRGB(10, 8, 0)
        ar.BackgroundTransparency = 0.35
        ar.Text                 = "▶"
        ar.Font                 = Enum.Font.GothamBold
        ar.TextSize             = 24
        ar.TextColor3           = DEPOSIT_COLOR
        ar.TextStrokeTransparency = 0.2
        ar.TextStrokeColor3     = Color3.new(0, 0, 0)
        ar.Visible              = false
        ar.ZIndex               = 60
        ar.BorderSizePixel      = 0
        ar.Parent               = sg
        local _c = Instance.new("UICorner"); _c.CornerRadius = UDim.new(0, 6); _c.Parent = ar
        local _s = Instance.new("UIStroke"); _s.Color = DEPOSIT_COLOR; _s.Thickness = 1.5; _s.Parent = ar

        table.insert(depositMarkers, { pos = pos, ring = ring, arrow = ar })
    end
end

local function destroyDepositMarkers()
    for _, m in depositMarkers do
        if m.ring.Parent  then m.ring:Destroy()  end
        if m.arrow.Parent then m.arrow:Destroy() end
    end
    depositMarkers = {}
    if markerSg then markerSg:Destroy(); markerSg = nil end
end

-- Called every RenderStepped while in Mine placement mode.
local function updateDepositMarkers()
    local cam = workspace.CurrentCamera
    local vp  = cam.ViewportSize
    if vp.X == 0 or vp.Y == 0 then return end

    local cx, cy = vp.X * 0.5, vp.Y * 0.5
    local t      = os.clock()

    for _, m in depositMarkers do
        -- Determine if this is the currently snapped (nearest) deposit
        local isSnapped = currentSnapTarget ~= nil
            and math.abs(currentSnapTarget.X - m.pos.X) < 1
            and math.abs(currentSnapTarget.Z - m.pos.Z) < 1

        -- Animate ring: snapped deposit pulses fast + grows; others breathe slowly
        if isSnapped then
            local p = 0.5 + math.sin(t * 6) * 0.3
            m.ring.Transparency = p
            local d = 9 + math.abs(math.sin(t * 6)) * 2
            m.ring.Size = Vector3.new(0.22, d, d)
        else
            m.ring.Transparency = 0.3 + math.sin(t * 1.8) * 0.12
            m.ring.Size = RING_BASE_SIZE
        end

        -- Screen-edge arrow: visible only when deposit is off-screen
        local sv, onScreen = cam:WorldToViewportPoint(m.pos + Vector3.new(0, 2, 0))
        local inFront      = sv.Z > 0

        -- If the deposit is fully visible on screen, hide the arrow
        if inFront and onScreen then
            m.arrow.Visible = false
            continue
        end

        -- Off-screen (or behind camera): show arrow at screen edge
        m.arrow.Visible = true

        -- Direction from screen centre toward the deposit's projection.
        -- When behind the camera, mirror the projected coords across the centre.
        local sx = inFront and sv.X or (vp.X - sv.X)
        local sy = inFront and sv.Y or (vp.Y - sv.Y)
        local dx  = sx - cx
        local dy  = sy - cy
        if not inFront then dx = -dx; dy = -dy end

        -- Clamp to screen rect keeping ARROW_MARGIN px away from each edge
        local halfW = cx - ARROW_MARGIN
        local halfH = cy - ARROW_MARGIN
        local len   = math.sqrt(dx * dx + dy * dy)
        if len < 0.001 then continue end
        local ndx, ndy = dx / len, dy / len

        local tx = math.abs(ndx) > 0.001 and halfW / math.abs(ndx) or math.huge
        local ty = math.abs(ndy) > 0.001 and halfH / math.abs(ndy) or math.huge
        local tEdge = math.min(tx, ty)

        local ex = math.clamp(cx + ndx * tEdge, ARROW_MARGIN, vp.X - ARROW_MARGIN)
        local ey = math.clamp(cy + ndy * tEdge, ARROW_MARGIN, vp.Y - ARROW_MARGIN)

        m.arrow.Position = UDim2.fromOffset(ex, ey)
        m.arrow.Rotation = math.deg(math.atan2(ndy, ndx))
    end
end

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
			updateDepositMarkers()

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
	if currentType == "Mine" then createDepositMarkers() end
	if modeCb then modeCb(true, currentType) end
end

function BuildingPlacer.exitPlacementMode()
	if not isPlacing then return end
	isPlacing         = false
	currentSnapTarget = nil
	ccTooClose        = false
	if ghost then ghost:Destroy(); ghost = nil end
	destroyDepositMarkers()
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
			-- Remove the matching deposit marker if it exists
			for j, m in depositMarkers do
				if math.abs(m.pos.X - pos.X) < 1 and math.abs(m.pos.Z - pos.Z) < 1 then
					if m.ring.Parent  then m.ring:Destroy()  end
					if m.arrow.Parent then m.arrow:Destroy() end
					table.remove(depositMarkers, j)
					break
				end
			end
			return
		end
	end
end

return BuildingPlacer
