local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RangeRing         = require(script.Parent:WaitForChild("RangeRing"))
local BuildField        = require(script.Parent:WaitForChild("BuildField"))

local BuildingPlacer = {}
local localPlayer    = Players.LocalPlayer

local isPlacing           = false
local currentType         = "Foundry"
local currentSnapTarget: Vector3? = nil   -- Mine mode: deposit we're snapping to
local ccTooClose          = false          -- CommandCenter mode: ghost is red
local outOfBuildZone      = false          -- non-CC mode: ghost is outside build zone
local onTerrain           = false          -- ghost is overlapping a terrain obstacle, out of bounds, or on sloped/uneven ground
local depositPositions: {Vector3} = {}
local ccPositions: {Vector3}      = {}     -- all known CC positions
local ownCcPosition: Vector3?     = nil    -- local player's own CC position
local ownRelayPositions: {Vector3} = {}    -- local player's own Relay positions
local ghost:          Part?
local rangeRing:      Model?               -- mine extract-range ring (follows ghost)
local prevOutOfZone   = false              -- for edge-crossing flare detection
local modeCb: ((boolean, string?) -> ())?
local networkRef: any
local cameraRef:  any

local ccIsMobileRef  = false   -- true while CC is mobile; suppresses the stale build-zone ring

local lineShiftHeld  = false
local isLineDragging = false
local lineDragStart:  Vector3?  = nil
local lineGhosts:     { Part }  = {}
local getResources:   (() -> number)? = nil
local notEnoughCb:    (() -> ())? = nil   -- shows the "not enough resources" toast
local placeSentFn:    ((string) -> ())? = nil   -- fired when a (non-CC) placement is sent
local costGetterFn:   ((string) -> number)? = nil   -- live scaled cost for a building type
local flashUntil      = 0                 -- os.clock() until which the ghost flashes red

local GRID = Config.BUILDING_GRID

-- Straight-down terrain raycast so ghosts, deposit rings and the flatness check
-- all sit on whichever tier they're over (the map has raised plateaus now).
local terrainRayParams = RaycastParams.new()
terrainRayParams.FilterType = Enum.RaycastFilterType.Include
terrainRayParams.FilterDescendantsInstances = { workspace.Terrain }

local function terrainHeightAt(x: number, z: number): number?
	local result = workspace:Raycast(Vector3.new(x, 250, z), Vector3.new(0, -500, 0), terrainRayParams)
	return result and result.Position.Y or nil
end

local placeSound        = Instance.new("Sound")
placeSound.SoundId      = "rbxassetid://138637105380663"
placeSound.Volume       = 1
placeSound.Parent       = SoundService

local function playPlaceSound()
	placeSound:Play()
end

-- Placement-mode dim: a dedicated ColorCorrectionEffect that desaturates and
-- darkens the world slightly so the neon Construction Field (deck/wall/stamp)
-- reads as the brightest thing on screen — an "inverse spotlight" on the build
-- zone. Separate instance so it stacks cleanly on top of ShaderManager's CCE.
local dimCC: ColorCorrectionEffect? = nil
local function setPlacementDim(on: boolean)
	if on then
		if not dimCC then
			dimCC        = Instance.new("ColorCorrectionEffect")
			dimCC.Name   = "_BuildFieldDim"
			dimCC.Parent = Lighting
		end
		TweenService:Create(dimCC, TweenInfo.new(0.25), {
			Brightness = -0.06, Saturation = -0.35, Contrast = 0.06,
		}):Play()
	elseif dimCC then
		local cc = dimCC
		dimCC = nil
		local t = TweenService:Create(cc, TweenInfo.new(0.2), {
			Brightness = 0, Saturation = 0, Contrast = 0,
		})
		t.Completed:Connect(function() cc:Destroy() end)
		t:Play()
	end
end

-- Returns true if pos is within any owned build zone (CC or Relay).
local function isInBuildZone(pos: Vector3): boolean
	if ownCcPosition then
		local d = Vector3.new(pos.X, 0, pos.Z) - Vector3.new(ownCcPosition.X, 0, ownCcPosition.Z)
		if d.Magnitude <= Config.BUILD_RADIUS then return true end
	end
	for _, rp in ownRelayPositions do
		local d = Vector3.new(pos.X, 0, pos.Z) - Vector3.new(rp.X, 0, rp.Z)
		if d.Magnitude <= Config.RELAY_RADIUS then return true end
	end
	return false
end

-- Rebuilds the Construction Field (deck + wall) from all current CC + Relay
-- positions. BuildField.show fires a one-shot radar sweep, so calling this when a
-- Relay is placed automatically announces the extended reach.
local function rebuildBuildZoneRing()
	if currentType == "CommandCenter" then BuildField.hide(); return end
	if ccIsMobileRef then BuildField.hide(); return end   -- CC is walking; its old position would be misleading
	local zones: { { cx: number, cz: number, radius: number } } = {}
	if ownCcPosition then
		table.insert(zones, { cx = ownCcPosition.X, cz = ownCcPosition.Z, radius = Config.BUILD_RADIUS })
	end
	for _, rp in ownRelayPositions do
		table.insert(zones, { cx = rp.X, cz = rp.Z, radius = Config.RELAY_RADIUS })
	end
	if #zones > 0 then
		BuildField.show(zones, localPlayer.TeamColor.Color)
	else
		BuildField.hide()
	end
end

-- ── Deposit markers (Foundry placement mode only) ─────────────────────────────
-- When the player enters Foundry placement mode every unclaimed deposit gets:
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
        -- Ground ring — sit it on whichever terrain tier the deposit is on
        -- (the synced deposit position carries no reliable Y).
        local ringY             = (terrainHeightAt(pos.X, pos.Z) or 0) + 0.25
        local ring              = Instance.new("Part")
        ring.Name               = "_DepositRing"
        ring.Shape              = Enum.PartType.Cylinder
        ring.CFrame             = CFrame.new(pos.X, ringY, pos.Z)
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
        bl.Text                 = "◆  Deposit"
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

-- Called every RenderStepped while in Foundry placement mode.
local function updateDepositMarkers()
    local cam = workspace.CurrentCamera
    local vp  = cam.ViewportSize
    if vp.X == 0 or vp.Y == 0 then return end

    local cx, cy = vp.X * 0.5, vp.Y * 0.5
    local t      = os.clock()

    for _, m in depositMarkers do
        -- All deposit rings breathe gently
        m.ring.Transparency = 0.3 + math.sin(t * 1.8) * 0.12
        m.ring.Size = RING_BASE_SIZE

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

-- Snaps to the grid and lifts the ghost so its centre is halfH above the terrain
-- surface AT the snapped cell. The server raycasts straight down at the same
-- snapped XZ, so the preview lands exactly where the building will — even near a
-- plateau edge where the cursor cell and the snapped cell differ in height.
local function snapToSurface(cursor: Vector3, halfH: number): Vector3
	local s  = snap(cursor)
	local sy = terrainHeightAt(s.X, s.Z)
	if sy then return Vector3.new(s.X, sy + halfH, s.Z) end
	return Vector3.new(s.X, cursor.Y, s.Z)
end

-- The position to send to the server when placing. The server trusts this Y as
-- the base-bottom (ground) height — the client's terrain raycast is the source
-- of truth (it's the same one the ghost preview uses), since recomputing the
-- height server-side was burying structures. Grid-snapped XZ, surface Y.
local function placePos(cursor: Vector3): Vector3
	local s  = snap(cursor)
	local sy = terrainHeightAt(s.X, s.Z)
	return Vector3.new(s.X, sy or s.Y, s.Z)
end

local function ghostSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	if buildingType == "LampreyNest"   then return Config.LAMPREY_NEST_SIZE end
	if buildingType == "Foundry"       then return Config.FOUNDRY_SIZE end
	if buildingType == "Deployer"      then return Config.BONFIRE_SIZE end
	if buildingType == "TEST"          then return Config.TEST_SIZE end
	return Config.BUILDING_SIZE
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

local function checkTerrainOverlap(pos: Vector3, buildType: string): boolean
	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return false end
	local size = ghostSize(buildType)
	local nhw  = size.X / 2
	local nhd  = size.Z / 2
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		if math.abs(pos.X - part.Position.X) < nhw + part.Size.X / 2
			and math.abs(pos.Z - part.Position.Z) < nhd + part.Size.Z / 2 then
			return true
		end
	end
	return false
end

-- True if the footprint at `pos` overlaps an existing building's Base. Without
-- this the ghost stayed valid (blue) when hovering over another structure.
local function checkBuildingOverlap(pos: Vector3, buildType: string): boolean
	local folder = workspace:FindFirstChild("Buildings")
	if not folder then return false end
	local size = ghostSize(buildType)
	local nhw  = size.X / 2
	local nhd  = size.Z / 2
	for _, model in folder:GetChildren() do
		local base = model:FindFirstChild("Base")
		if not base or not base:IsA("BasePart") then continue end
		if math.abs(pos.X - base.Position.X) < nhw + base.Size.X / 2
			and math.abs(pos.Z - base.Position.Z) < nhd + base.Size.Z / 2 then
			return true
		end
	end
	return false
end

local function isOutOfMapBounds(pos: Vector3, buildType: string): boolean
	local size = ghostSize(buildType)
	return math.abs(pos.X) + size.X / 2 > 432 or math.abs(pos.Z) + size.Z / 2 > 432
end

-- ── Footprint flatness (ramp/tier-boundary) check ─────────────────────────────
-- Mirrors the server's TerrainManager.isFootprintFlat using real terrain
-- raycasts, so the ghost previews red over ramps/boundaries before the player
-- clicks instead of silently failing to place.
local FOOTPRINT_FLAT_EPS = 0.5
local function isFootprintFlat(pos: Vector3, buildType: string): boolean
	local size  = ghostSize(buildType)
	local halfX, halfZ = size.X / 2, size.Z / 2
	local h0 = terrainHeightAt(pos.X, pos.Z)
	if not h0 then return true end  -- raycast miss: don't block on incomplete data
	for _, corner in {
		Vector3.new(pos.X - halfX, 0, pos.Z - halfZ),
		Vector3.new(pos.X + halfX, 0, pos.Z - halfZ),
		Vector3.new(pos.X - halfX, 0, pos.Z + halfZ),
		Vector3.new(pos.X + halfX, 0, pos.Z + halfZ),
	} do
		local h = terrainHeightAt(corner.X, corner.Z)
		if not h or math.abs(h - h0) > FOOTPRINT_FLAT_EPS then return false end
	end
	return true
end

local function buildingCost(btype: string): number
	-- Prefer the HUD's live cost (scaled by built + in-flight count, first-free
	-- aware) so affordability checks match the displayed/charged price exactly.
	if costGetterFn then return costGetterFn(btype) end
	if btype == "Foundry"    then return Config.FOUNDRY_COST end
	if btype == "Turret"     then return Config.TURRET_COST end
	if btype == "Relay"      then return Config.RELAY_COST end
	if btype == "CreepyBlob" then return Config.CREEPY_BLOB_COST end
	if btype == "LampreyNest" then return Config.LAMPREY_NEST_COST end
	return Config.BUILDING_COST
end

local function lineSpacing(btype: string): number
	local sz = ghostSize(btype)
	return math.max(sz.X, sz.Z) + 5
end

local function getLinePositions(startPos: Vector3, endPos: Vector3, spacing: number): { Vector3 }
	local dx  = endPos.X - startPos.X
	local dz  = endPos.Z - startPos.Z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.1 then return { snap(startPos) } end
	local ndx = dx / len
	local ndz = dz / len
	local count = math.max(1, math.floor(len / spacing) + 1)
	local result: { Vector3 } = {}
	for i = 0, count - 1 do
		table.insert(result, snap(Vector3.new(
			startPos.X + ndx * i * spacing,
			startPos.Y,
			startPos.Z + ndz * i * spacing
		)))
	end
	return result
end

local function clearLineGhosts()
	for _, g in lineGhosts do
		if g.Parent then g:Destroy() end
	end
	lineGhosts = {}
end

local function confirmLineDrag()
	if not lineDragStart or not cameraRef then
		clearLineGhosts(); isLineDragging = false; lineDragStart = nil; return
	end
	local curPos = cameraRef.getPositionAtHeight(ghostSize(currentType).Y / 2)
	local endPos = curPos and snap(curPos) or lineDragStart
	local positions = getLinePositions(lineDragStart, endPos, lineSpacing(currentType))
	local resources = getResources and getResources() or 0
	local placed    = 0
	for _, lpos in positions do
		-- Recompute each step: placing one bumps the in-flight count, so the next
		-- in the line costs more (and the first may be free).
		local cost = buildingCost(currentType)
		if resources < cost then break end
		local valid = isInBuildZone(lpos)
			and not checkTerrainOverlap(lpos, currentType)
			and not isOutOfMapBounds(lpos, currentType)
			and not checkBuildingOverlap(lpos, currentType)
		if valid then
			networkRef.placeBuilding(placePos(lpos), currentType)
			if placeSentFn and currentType then placeSentFn(currentType) end
			resources -= cost
			placed    += 1
		end
	end
	clearLineGhosts()
	isLineDragging = false
	lineDragStart  = nil
	if placed > 0 then
		playPlaceSound()
		task.defer(BuildingPlacer.exitPlacementMode)
	end
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

	-- Track CC/Relay positions for min-distance validation and build-zone rings
	network.onBuildingPlaced(function(_id: string, ownerId: number, pos: Vector3, buildingType: string)
		if buildingType == "CommandCenter" then
			table.insert(ccPositions, pos)
			if ownerId == localPlayer.UserId then
				ownCcPosition = pos
				if isPlacing then rebuildBuildZoneRing() end
			end
		elseif buildingType == "Relay" and ownerId == localPlayer.UserId then
			table.insert(ownRelayPositions, pos)
			if isPlacing then rebuildBuildZoneRing() end
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			lineShiftHeld = true
		end
		if not isPlacing then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and not gpe then
			if currentType == "CommandCenter" then
				if not ccTooClose and not onTerrain then
					local halfH = Config.COMMAND_CENTER_SIZE.Y / 2
					local pos   = cameraModule.getPositionAtHeight(halfH)
					if pos then
						network.placeBuilding(placePos(pos), "CommandCenter")
						playPlaceSound()
						task.defer(BuildingPlacer.exitPlacementMode)
					end
				end
				-- Red = blocked → do nothing (keeps mode open)

			else
				if outOfBuildZone or onTerrain then return end
				local pos = cameraModule.getPositionAtHeight(ghostSize(currentType).Y / 2)
				if not pos then return end
				if lineShiftHeld then
					isLineDragging = true
					lineDragStart  = snap(pos)
					return
				end
				-- Insufficient funds: flash red + toast, keep placement mode open.
				if getResources and getResources() < buildingCost(currentType) then
					flashUntil = os.clock() + 0.4
					if notEnoughCb then notEnoughCb() end
					return
				end
				network.placeBuilding(placePos(pos), currentType)
				if placeSentFn and currentType then placeSentFn(currentType) end
				playPlaceSound()
				task.defer(BuildingPlacer.exitPlacementMode)
			end

		elseif input.UserInputType == Enum.UserInputType.MouseButton2
			or input.KeyCode == Enum.KeyCode.Escape then
			task.defer(BuildingPlacer.exitPlacementMode)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			lineShiftHeld = false
			if isLineDragging then confirmLineDrag() end
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if isLineDragging then confirmLineDrag() end
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not isPlacing then return end

		-- Line drag mode: pool of ghosts along the drag line
		if isLineDragging and lineDragStart then
			BuildField.hideStamp()   -- single-cell stamp is irrelevant while dragging a line
			if ghost then ghost.Transparency = 1 end
			local pos = cameraModule.getPositionAtHeight(ghostSize(currentType).Y / 2)
			if pos then
				local endPos    = snap(pos)
				local spacing   = lineSpacing(currentType)
				local positions = getLinePositions(lineDragStart, endPos, spacing)
				local resources = getResources and getResources() or math.huge
				local cost      = buildingCost(currentType)
				local canAffordN = math.max(0, math.floor(resources / cost))

				-- Resize ghost pool
				while #lineGhosts > #positions do
					lineGhosts[#lineGhosts]:Destroy()
					table.remove(lineGhosts)
				end
				while #lineGhosts < #positions do
					local g          = Instance.new("Part")
					g.Name           = "__LineGhost"
					g.Size           = ghostSize(currentType)
					g.Anchored       = true
					g.CanCollide     = false
					g.CanQuery       = false
					g.Material       = Enum.Material.SmoothPlastic
					g.Parent         = workspace
					table.insert(lineGhosts, g)
				end

				-- Update each ghost
				for i, lpos in positions do
					local g     = lineGhosts[i]
					local valid = isInBuildZone(lpos)
						and not checkTerrainOverlap(lpos, currentType)
						and not isOutOfMapBounds(lpos, currentType)
						and not checkBuildingOverlap(lpos, currentType)
						and isFootprintFlat(lpos, currentType)
					local affordable = i <= canAffordN
					g.BrickColor   = not valid       and BrickColor.new("Bright red")
						or not affordable and BrickColor.new("Bright orange")
						or localPlayer.TeamColor
					g.Transparency = (not valid or not affordable) and 0.65 or 0.5
					g.Position     = lpos
				end
			end
			return  -- skip normal ghost update
		end

		if not ghost then return end

		if currentType == "CommandCenter" then
			local halfH = Config.COMMAND_CENTER_SIZE.Y / 2
			local pos   = cameraModule.getPositionAtHeight(halfH)
			if pos then
				local snapped  = snapToSurface(pos, halfH)
				ccTooClose     = isCCTooClose(snapped)
				onTerrain      = checkTerrainOverlap(snapped, "CommandCenter") or isOutOfMapBounds(snapped, "CommandCenter")
					or checkBuildingOverlap(snapped, "CommandCenter")
					or not isFootprintFlat(snapped, "CommandCenter")
				ghost.Position = snapped
				local blocked  = ccTooClose or onTerrain
				ghost.BrickColor   = blocked and BrickColor.new("Bright red") or localPlayer.TeamColor
				ghost.Transparency = blocked and 0.65 or 0.5
			end

		else
			local pos = cameraModule.getPositionAtHeight(ghostSize(currentType).Y / 2)
			if pos then
				local snapped = snapToSurface(pos, ghostSize(currentType).Y / 2)
				ghost.Position = snapped

				onTerrain      = checkTerrainOverlap(snapped, currentType) or isOutOfMapBounds(snapped, currentType)
					or checkBuildingOverlap(snapped, currentType)
					or not isFootprintFlat(snapped, currentType)
				outOfBuildZone = not onTerrain and not isInBuildZone(snapped)

				local flashing = os.clock() < flashUntil
				local blocked  = onTerrain or outOfBuildZone or flashing
				ghost.BrickColor   = blocked and BrickColor.new("Bright red") or localPlayer.TeamColor
				ghost.Transparency = blocked and 0.65 or 0.5

				-- Footprint stamp: green = placeable, gray = in-zone but unaffordable,
				-- red = outside the zone or on illegal terrain.
				local size   = ghostSize(currentType)
				local groundY = (terrainHeightAt(snapped.X, snapped.Z) or 0) + 0.32
				local state: string
				if onTerrain or outOfBuildZone then
					state = "illegal"
				elseif (getResources and getResources() or math.huge) < buildingCost(currentType) then
					state = "blocked"
				else
					state = "valid"
				end
				BuildField.setStamp(snapped.X, snapped.Z, groundY, size.X, size.Z, state)

				-- Force-field flare: fire once at the moment the cursor crosses out of
				-- the zone (rising edge), so the wall reacts where you hit it.
				if outOfBuildZone and not prevOutOfZone then
					BuildField.flareAt(snapped.X, snapped.Z)
				end
				prevOutOfZone = outOfBuildZone

				-- Keep range ring (turret attack range / Foundry boost radius) centred
				-- under the ghost on its tier.
				if rangeRing then
					RangeRing.moveTo(rangeRing, snapped.X, snapped.Z, terrainHeightAt(snapped.X, snapped.Z) or 0)
				end
			end
			-- Foundry mode shows deposit markers so the player can place near ore.
			if currentType == "Foundry" then updateDepositMarkers() end
		end
	end)
end

function BuildingPlacer.enterPlacementMode(buildingType: string?)
	if isPlacing then return end
	currentType      = buildingType or "Foundry"
	currentSnapTarget = nil
	ccTooClose       = false
	outOfBuildZone   = false
	prevOutOfZone    = false
	isPlacing        = true
	makeGhost()
	setPlacementDim(true)

	-- Construction Field (deck + wall + power-on sweep): shown for all non-CC placements
	rebuildBuildZoneRing()

	if currentType == "Foundry" then
		-- Foundry boost-radius ring follows the ghost cursor; deposit markers show
		-- where ore is so the player can place inside its pull radius.
		rangeRing = RangeRing.create(Config.FOUNDRY_BOOST_RADIUS, 0, 0)
		createDepositMarkers()
	elseif currentType == "Turret" then
		-- Turret attack-range ring follows the ghost cursor
		rangeRing = RangeRing.create(Config.TURRET_RANGE, 0, 0)
	end

	if modeCb then modeCb(true, currentType) end
end

function BuildingPlacer.exitPlacementMode()
	if not isPlacing then return end
	isLineDragging = false
	lineDragStart  = nil
	clearLineGhosts()
	isPlacing         = false
	currentSnapTarget = nil
	ccTooClose        = false
	outOfBuildZone    = false
	onTerrain         = false
	if ghost        then ghost:Destroy();              ghost        = nil end
	if rangeRing    then RangeRing.destroy(rangeRing); rangeRing    = nil end
	BuildField.hide()
	setPlacementDim(false)
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

function BuildingPlacer.clearRelayPositions()
	ownRelayPositions = {}
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

function BuildingPlacer.setResourceGetter(fn: () -> number)
	getResources = fn
end

-- Called when the player tries to place a building they can't afford.
function BuildingPlacer.setNotEnoughResourcesFn(fn: () -> ())
	notEnoughCb = fn
end

-- Called (with the building type) each time a non-CC placement is sent to the
-- server, so the HUD can count in-flight placements for live cost scaling.
function BuildingPlacer.onPlaceSent(fn: (string) -> ())
	placeSentFn = fn
end

-- Supplies the live (scaled, in-flight & first-free aware) cost for a building type.
function BuildingPlacer.setCostGetter(fn: (string) -> number)
	costGetterFn = fn
end

-- Called when the local player's CC enters or leaves mobile (walking) state.
-- While mobile the CC is moving so its cached position is stale — hide the ring.
function BuildingPlacer.setCCMobile(isMobile: boolean)
	ccIsMobileRef = isMobile
	if isMobile then
		BuildField.hide()
	elseif isPlacing then
		rebuildBuildZoneRing()
	end
end

return BuildingPlacer
