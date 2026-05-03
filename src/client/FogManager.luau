--[[
	FogManager v4 — Starcraft 2-style fog of war

	Improvements over v3:
	  1. Feathered vision edges — boundary cells get fractional transparency
	                              using quadratic falloff (no sqrt in hot loop).
	  2. Smaller cell size      — CELL_SIZE 12 → 8 for rounder circles.
	  3. Animated fog drift     — two large sinusoidally-drifting planes give
	                              a subtle living-fog effect over unexplored tiles.
	  5. Soft reveal            — tiles tween to transparent when first revealed
	                              instead of snapping (0.22 s Quad-out).
	  6. Depth layers           — the two drift planes at different Y heights
	                              create an inexpensive parallax depth effect.
--]]

local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")

local FogManager  = {}
local localPlayer = Players.LocalPlayer

-- ── Config ────────────────────────────────────────────────────────────────────
local CELL_SIZE    = 8      -- studs per fog tile
local GRID_CELLS   = 108    -- tiles per axis  →  ±432 stud coverage (108 × 8 = 864)
local HALF         = GRID_CELLS / 2  -- 54
local FEATHER_FRAC = 0.22   -- outer feather band as fraction of each vision radius

local FOG_Y        = 0.15
local SHROUD_TRANS = 0.45  -- explored-but-not-visible overlay opacity (0 = fully opaque)
local GHOST_MOD    = 0.55  -- LocalTransparencyModifier for last-known-position buildings
local UNIT_FADE    = 0.15  -- seconds for enemy-unit fade in/out

local TICK = 0.3  -- fog update interval

-- Per-building-type vision radii (studs)
local VIS_CC       = 75
local VIS_BARRACKS = 50
local VIS_MINE     = 45
local VIS_TURRET   = 40
local VIS_MINER    = 30
local VIS_UNIT     = 65

local STATE_UNEXPLORED = 0
local STATE_EXPLORED   = 1
local STATE_VISIBLE    = 2

local FADE_INFO        = TweenInfo.new(UNIT_FADE, Enum.EasingStyle.Linear)
local TILE_REVEAL_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Effective unit vision (may be boosted by EyeUpgrade)
local effVIS_UNIT = VIS_UNIT

-- Precomputed squared radii + cell-radii + inner squared radii (feather start)
local UNIT_R2   = VIS_UNIT  * VIS_UNIT
local UNIT_RC   = math.ceil(VIS_UNIT  / CELL_SIZE) + 1
local UNIT_RI2  = (VIS_UNIT  * (1 - FEATHER_FRAC)) ^ 2
local MINER_R2  = VIS_MINER * VIS_MINER
local MINER_RC  = math.ceil(VIS_MINER / CELL_SIZE) + 1
local MINER_RI2 = (VIS_MINER * (1 - FEATHER_FRAC)) ^ 2

-- ── Module state ──────────────────────────────────────────────────────────────
local localUserId: number
local fogFolder:   Folder
local xrayEnabled  = false

-- Fog tile layers
local blackLayer:  { { Part } } = {}
local shroudLayer: { { Part } } = {}
local tileState:   { { number } } = {}

-- Permanent exploration memory (never shrinks until reset)
local exploredMap: { [number]: { [number]: true } } = {}

-- ── Source cache ──────────────────────────────────────────────────────────────
type Source = { x: number, z: number, r2: number, rc: number, ri2: number }

-- Cached lists of own parts — rebuilt only when a folder child changes
local ownUnitParts:    { BasePart } = {}
local ownBuildingData: { { part: BasePart, r2: number, rc: number, ri2: number } } = {}
local ownMinerParts:   { BasePart } = {}
local sourcesDirty = true

-- Drift plane handles (created in init)
local driftPlane1: Part?
local driftPlane2: Part?

-- ── Ghost building tracking ───────────────────────────────────────────────────
-- Keyed by model.Name (building ID). Entry exists only while building is alive
-- AND we've had line-of-sight on it at least once.
local seenEnemyBuildings: { [string]: true } = {}

-- ── Unit fade tracking ────────────────────────────────────────────────────────
local unitLastVis:  { [string]: boolean } = {}  -- part.Name → last vis state
local activeTweens: { [string]: Tween }  = {}  -- part.Name → in-progress tween

-- ── Grid helpers ──────────────────────────────────────────────────────────────

local function cellCentre(row: number, col: number): (number, number)
	return (col - HALF - 0.5) * CELL_SIZE,
	       (row - HALF - 0.5) * CELL_SIZE
end

local function worldToCell(wx: number, wz: number): (number, number)
	local col = math.floor(wx / CELL_SIZE + HALF) + 1
	local row = math.floor(wz / CELL_SIZE + HALF) + 1
	return row, col
end

local function inBounds(row: number, col: number): boolean
	return row >= 1 and row <= GRID_CELLS and col >= 1 and col <= GRID_CELLS
end

-- ── Tile layer ────────────────────────────────────────────────────────────────

local function makeTile(trans: number): Part
	local p         = Instance.new("Part")
	p.Name          = "Tile"
	p.Size          = Vector3.new(CELL_SIZE, 0.1, CELL_SIZE)
	p.Color         = Color3.new(0, 0, 0)
	p.Material      = Enum.Material.Neon
	p.Transparency  = trans
	p.Anchored      = true
	p.CanCollide    = false
	p.CastShadow    = false
	p.CanQuery      = false  -- raycasts ignore fog tiles
	return p
end

local function applyTileState(row: number, col: number, state: number)
	if state == STATE_UNEXPLORED then
		blackLayer[row][col].Transparency  = 0
		shroudLayer[row][col].Transparency = 1
	elseif state == STATE_EXPLORED then
		blackLayer[row][col].Transparency  = 1
		shroudLayer[row][col].Transparency = SHROUD_TRANS
	else  -- STATE_VISIBLE
		blackLayer[row][col].Transparency  = 1
		shroudLayer[row][col].Transparency = 1
	end
end

local function buildFogGrid()
	fogFolder        = Instance.new("Folder")
	fogFolder.Name   = "FogOfWar"
	fogFolder.Parent = workspace

	local blackF   = Instance.new("Folder"); blackF.Name  = "Black";  blackF.Parent  = fogFolder
	local shroudF  = Instance.new("Folder"); shroudF.Name = "Shroud"; shroudF.Parent = fogFolder

	for row = 1, GRID_CELLS do
		blackLayer[row]  = {}
		shroudLayer[row] = {}
		tileState[row]   = {}
		for col = 1, GRID_CELLS do
			local wx, wz = cellCentre(row, col)

			local black        = makeTile(0)  -- opaque
			black.Position     = Vector3.new(wx, FOG_Y, wz)
			black.Parent       = blackF
			blackLayer[row][col] = black

			local shroud       = makeTile(1)  -- invisible initially
			shroud.Position    = Vector3.new(wx, FOG_Y + 0.05, wz)
			shroud.Parent      = shroudF
			shroudLayer[row][col] = shroud

			tileState[row][col] = STATE_UNEXPLORED
		end
	end
end

-- ── Source cache helpers ──────────────────────────────────────────────────────

local function buildingTypeRadius(btype: string): (number, number, number)
	local r: number
	if      btype == "CommandCenter" then r = VIS_CC
	elseif  btype == "Monument"      then r = VIS_CC
	elseif  btype == "Barracks"      then r = VIS_BARRACKS
	elseif  btype == "Mine"          then r = VIS_MINE
	elseif  btype == "Turret"        then r = VIS_TURRET
	else                                  r = VIS_BARRACKS
	end
	local r2  = r * r
	local rc  = math.ceil(r / CELL_SIZE) + 1
	local ri2 = (r * (1 - FEATHER_FRAC)) ^ 2
	return r2, rc, ri2
end

local function rebuildSourceList()
	local myStr     = tostring(localUserId)
	ownUnitParts    = {}
	ownBuildingData = {}
	ownMinerParts   = {}

	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		for _, c in unitsF:GetChildren() do
			local ov = c:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr and c:IsA("BasePart") then
				table.insert(ownUnitParts, c :: BasePart)
			end
		end
	end

	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr then
				local base = model:FindFirstChild("Base")
				if base and base:IsA("BasePart") then
					local btv   = model:FindFirstChild("BuildingType")
					local btype = btv and btv.Value or "Barracks"
					local r2, rc, ri2 = buildingTypeRadius(btype)
					table.insert(ownBuildingData, { part = base :: BasePart, r2 = r2, rc = rc, ri2 = ri2 })
				end
			end
		end
	end

	local minersF = workspace:FindFirstChild("Miners")
	if minersF then
		for _, c in minersF:GetChildren() do
			local ov = c:FindFirstChild("OwnerId")
			if not ov or ov.Value ~= myStr then continue end
			local root: BasePart?
			if c:IsA("BasePart") then
				root = c :: BasePart
			elseif c:IsA("Model") then
				root = (c :: Model).PrimaryPart or c:FindFirstChildWhichIsA("BasePart") :: BasePart?
			end
			if root then table.insert(ownMinerParts, root) end
		end
	end

	sourcesDirty = false
end

-- Reads fresh positions every tick (units move); rebuilds part list only when dirty.
local function collectSources(): { Source }
	if sourcesDirty then rebuildSourceList() end

	local out: { Source } = {}
	for _, p in ownUnitParts do
		local pos = p.Position
		table.insert(out, { x = pos.X, z = pos.Z, r2 = UNIT_R2, rc = UNIT_RC, ri2 = UNIT_RI2 })
	end
	for _, bd in ownBuildingData do
		local pos = bd.part.Position
		table.insert(out, { x = pos.X, z = pos.Z, r2 = bd.r2, rc = bd.rc, ri2 = bd.ri2 })
	end
	for _, p in ownMinerParts do
		local pos = p.Position
		table.insert(out, { x = pos.X, z = pos.Z, r2 = MINER_R2, rc = MINER_RC, ri2 = MINER_RI2 })
	end
	return out
end

-- ── Visibility grid ───────────────────────────────────────────────────────────
-- Returns 0–1 per cell: 1.0 = fully visible, 0 = not visible.
-- Cells in the feather band (ri2 < d2 <= r2) get a quadratic falloff value.

local function computeVisibleGrid(sources: { Source }): { [number]: { [number]: number } }
	local visGrid: { [number]: { [number]: number } } = {}
	for _, src in sources do
		local cRow, cCol = worldToCell(src.x, src.z)
		for dr = -src.rc, src.rc do
			local row = cRow + dr
			if row < 1 or row > GRID_CELLS then continue end
			if not visGrid[row] then visGrid[row] = {} end
			for dc = -src.rc, src.rc do
				local col = cCol + dc
				if col < 1 or col > GRID_CELLS then continue end
				local cwx, cwz = cellCentre(row, col)
				local dx = cwx - src.x
				local dz = cwz - src.z
				local d2 = dx * dx + dz * dz
				if d2 <= src.r2 then
					local level: number
					if d2 <= src.ri2 then
						level = 1.0
					else
						-- Quadratic falloff in feather band — avoids sqrt
						level = 1.0 - (d2 - src.ri2) / (src.r2 - src.ri2)
					end
					local prev = visGrid[row][col]
					if not prev or level > prev then
						visGrid[row][col] = level
					end
				end
			end
		end
	end
	return visGrid
end

local function posIsVisible(pos: Vector3, visGrid: { [number]: { [number]: number } }): boolean
	local row, col = worldToCell(pos.X, pos.Z)
	if not inBounds(row, col) then return false end
	return visGrid[row] ~= nil and (visGrid[row][col] or 0) > 0
end

local function posIsExplored(pos: Vector3): boolean
	local row, col = worldToCell(pos.X, pos.Z)
	if not inBounds(row, col) then return false end
	return exploredMap[row] ~= nil and exploredMap[row][col] == true
end

-- ── Xray fast-path (reveal entire map for local player) ──────────────────────

local function applyXray()
	local myStr = tostring(localUserId)

	for row = 1, GRID_CELLS do
		for col = 1, GRID_CELLS do
			if tileState[row][col] ~= STATE_VISIBLE then
				tileState[row][col] = STATE_VISIBLE
				applyTileState(row, col, STATE_VISIBLE)
			end
		end
	end

	local function showAll(folder: Folder?)
		if not folder then return end
		for _, child in folder:GetChildren() do
			local ov = child:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if child:IsA("BasePart") then
				(child :: BasePart).LocalTransparencyModifier = 0
				for _, desc in child:GetDescendants() do
					if desc:IsA("BasePart") then (desc :: BasePart).LocalTransparencyModifier = 0 end
					if desc:IsA("BillboardGui") then (desc :: BillboardGui).Enabled = true end
				end
				for _, gc in child:GetChildren() do
					if gc:IsA("BillboardGui") then (gc :: BillboardGui).Enabled = true end
				end
			elseif child:IsA("Model") then
				for _, desc in child:GetDescendants() do
					if desc:IsA("BasePart") then (desc :: BasePart).LocalTransparencyModifier = 0 end
					if desc:IsA("BillboardGui") then (desc :: BillboardGui).Enabled = true end
				end
			end
		end
	end

	showAll(workspace:FindFirstChild("Units") :: Folder?)
	showAll(workspace:FindFirstChild("Buildings") :: Folder?)
	showAll(workspace:FindFirstChild("Miners") :: Folder?)

	for _, folderName in { "_EliteLegs", "_CreepyLegs" } do
		local lf = workspace:FindFirstChild(folderName)
		if lf then
			for _, legPart in lf:GetChildren() do
				if legPart:IsA("BasePart") then
					(legPart :: BasePart).LocalTransparencyModifier = 0
				end
			end
		end
	end
end

-- ── Main update ───────────────────────────────────────────────────────────────

local function updateFog()
	if xrayEnabled then applyXray() return end

	local sources = collectSources()
	local visGrid = computeVisibleGrid(sources)

	-- Permanently mark visible cells as explored
	for row, cols in visGrid do
		if not exploredMap[row] then exploredMap[row] = {} end
		for col in cols do exploredMap[row][col] = true end
	end

	-- ── 1. Fog grid tiles ─────────────────────────────────────────────────
	for row = 1, GRID_CELLS do
		local visRow = visGrid[row]
		local expRow = exploredMap[row]
		for col = 1, GRID_CELLS do
			local visLevel = if visRow then (visRow[col] or 0) else 0
			local exp      = expRow ~= nil and expRow[col] == true
			local oldState = tileState[row][col]
			local newState: number
			if visLevel > 0 then  newState = STATE_VISIBLE
			elseif exp then       newState = STATE_EXPLORED
			else                  newState = STATE_UNEXPLORED
			end
			local stateChanged = newState ~= oldState
			if stateChanged then tileState[row][col] = newState end

			-- Target transparencies
			local blackT: number
			local shroudT: number
			if visLevel >= 1.0 then
				blackT = 1; shroudT = 1
			elseif visLevel > 0 then
				blackT = visLevel; shroudT = 1  -- feathered edge
			elseif exp then
				blackT = 1; shroudT = SHROUD_TRANS
			else
				blackT = 0; shroudT = 1
			end

			if stateChanged then
				-- Soft reveal: tween black tile out when a cell first becomes fully visible
				if newState == STATE_VISIBLE and visLevel >= 1.0 then
					TweenService:Create(blackLayer[row][col], TILE_REVEAL_INFO, { Transparency = 1 }):Play()
				else
					blackLayer[row][col].Transparency = blackT
				end
				shroudLayer[row][col].Transparency = shroudT
			elseif visLevel > 0 then
				-- Keep visible tiles in sync every tick — fixes stale feather values
				-- when a cell moves from the feather band back to full visibility.
				blackLayer[row][col].Transparency  = blackT
				shroudLayer[row][col].Transparency = shroudT
			end
		end
	end

	local myStr = tostring(localUserId)

	-- ── 2. Enemy units — smooth fade in/out ───────────────────────────────
	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		for _, child in unitsF:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local ov = child:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local bp  = child :: BasePart
			local uid = bp.Name
			local vis = posIsVisible(bp.Position, visGrid)

			if unitLastVis[uid] ~= vis then
				unitLastVis[uid] = vis
				local prev = activeTweens[uid]
				if prev then prev:Cancel() end
				local modifier = if vis then 0 else 1
				local tw = TweenService:Create(bp, FADE_INFO, {
					LocalTransparencyModifier = modifier
				})
				activeTweens[uid] = tw
				tw:Play()
				tw.Completed:Connect(function(ps)
					if ps == Enum.PlaybackState.Completed then activeTweens[uid] = nil end
				end)
				-- Also fade any visual sub-parts (e.g. tank treads)
				for _, desc in bp:GetDescendants() do
					if desc:IsA("BasePart") then
						TweenService:Create(desc :: BasePart, FADE_INFO, {
							LocalTransparencyModifier = modifier
						}):Play()
					end
				end
			end

			-- BillboardGuis hard-cut (no benefit tweening UI opacity)
			for _, gc in bp:GetChildren() do
				if gc:IsA("BillboardGui") then
					(gc :: BillboardGui).Enabled = vis
				end
			end
		end
	end

	-- ── 3. Enemy buildings — normal / ghost / hidden ──────────────────────
	--    visible   → show fully
	--    explored  → ghost ONLY if we've had LoS on it before AND it still exists
	--    unexplored → fully hidden
	--    Monument  → ALWAYS fully visible (win-condition structure)
	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base")
			if not base or not base:IsA("BasePart") then continue end

			-- Monuments are always visible regardless of fog
			local btv   = model:FindFirstChild("BuildingType") :: StringValue?
			local btype = btv and btv.Value or ""
			if btype == "Monument" then
				for _, desc in model:GetDescendants() do
					if desc:IsA("BasePart") then
						(desc :: BasePart).LocalTransparencyModifier = 0
					elseif desc:IsA("BillboardGui") then
						(desc :: BillboardGui).Enabled = true
					end
				end
				continue
			end

			local bpos = (base :: BasePart).Position
			local vis  = posIsVisible(bpos, visGrid)
			local exp  = posIsExplored(bpos)
			local bid  = model.Name

			-- First time we see this building: record it and watch for death
			if vis and not seenEnemyBuildings[bid] then
				seenEnemyBuildings[bid] = true
				(base :: BasePart).Destroying:Connect(function()
					seenEnemyBuildings[bid] = nil
				end)
			end

			local modifier: number
			local bbEnabled: boolean
			if vis then
				modifier = 0; bbEnabled = true
			elseif exp and seenEnemyBuildings[bid] then
				modifier = GHOST_MOD; bbEnabled = false
			else
				modifier = 1; bbEnabled = false
			end

			for _, desc in model:GetDescendants() do
				if desc:IsA("BasePart") then
					(desc :: BasePart).LocalTransparencyModifier = modifier
				elseif desc:IsA("BillboardGui") then
					(desc :: BillboardGui).Enabled = bbEnabled
				end
			end
		end
	end

	-- ── 4. Enemy miners — instant ─────────────────────────────────────────
	local minersF = workspace:FindFirstChild("Miners")
	if minersF then
		for _, child in minersF:GetChildren() do
			local ov = child:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			if child:IsA("BasePart") then
				local bp = child :: BasePart
				local modifier = if posIsVisible(bp.Position, visGrid) then 0 else 1
				bp.LocalTransparencyModifier = modifier
			elseif child:IsA("Model") then
				local model = child :: Model
				local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart") :: BasePart?
				local vis = root and posIsVisible(root.Position, visGrid) or false
				local modifier = if vis then 0 else 1
				for _, desc in model:GetDescendants() do
					if desc:IsA("BasePart") then
						(desc :: BasePart).LocalTransparencyModifier = modifier
					elseif desc:IsA("BillboardGui") then
						(desc :: BillboardGui).Enabled = vis
					end
				end
			end
		end
	end

	-- ── 5 & 6. Procedural leg folders — Elite (_EliteLegs) & Creepy (_CreepyLegs) ──
	-- Own units: always visible. Enemy units: follow fog tween state.
	local function syncLegFolder(folderName: string)
		local lf = workspace:FindFirstChild(folderName)
		if not lf then return end
		for _, legPart in lf:GetChildren() do
			if not legPart:IsA("BasePart") then continue end
			local uid = legPart:GetAttribute("UnitId") :: string?
			if not uid then continue end
			local isOwn = false
			if unitsF then
				local unitPart = unitsF:FindFirstChild(uid)
				local ov = unitPart and unitPart:FindFirstChild("OwnerId") :: StringValue?
				isOwn = ov ~= nil and ov.Value == myStr
			end
			local vis: boolean = isOwn or (unitLastVis[uid] == true)
			;(legPart :: BasePart).LocalTransparencyModifier = if vis then 0 else 1
		end
	end

	syncLegFolder("_EliteLegs")
	syncLegFolder("_CreepyLegs")

end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Toggle full-map reveal for the local player (debug/cheat command).
function FogManager.setXray(enabled: boolean)
	xrayEnabled = enabled
	if not enabled then
		-- Force a fresh fog update on the next tick so tiles/units snap back correctly
		sourcesDirty = true
	end
end

-- Called client-side when EyeUpgrade research completes.
-- Recomputes UNIT_R2/RC/RI2 so the next fog tick uses the wider vision radius.
function FogManager.setEyeUpgrade(active: boolean)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
	local mult   = if active then Config.EYE_VISION_MULT else 1.0
	effVIS_UNIT  = VIS_UNIT * mult
	UNIT_R2      = effVIS_UNIT * effVIS_UNIT
	UNIT_RC      = math.ceil(effVIS_UNIT / CELL_SIZE) + 1
	UNIT_RI2     = (effVIS_UNIT * (1 - FEATHER_FRAC)) ^ 2
end

-- Call when the local player is eliminated (CC destroyed). Wipes exploration
-- memory so the map returns to black — the player must re-scout after rebuilding.
function FogManager.reset()
	exploredMap        = {}
	seenEnemyBuildings = {}
	unitLastVis        = {}

	for _, tw in activeTweens do tw:Cancel() end
	activeTweens = {}

	for row = 1, GRID_CELLS do
		for col = 1, GRID_CELLS do
			if tileState[row][col] ~= STATE_UNEXPLORED then
				tileState[row][col] = STATE_UNEXPLORED
				applyTileState(row, col, STATE_UNEXPLORED)
			end
		end
	end

	sourcesDirty = true
end

function FogManager.init(userId: number)
	localUserId = userId
	buildFogGrid()

	-- ── Animated drift planes (options 3 & 6) ─────────────────────────────
	-- Two large translucent neon planes oscillate in XZ via sine waves.
	-- They sit just above the fog tiles and cover unexplored areas, giving a
	-- subtle drifting depth effect with near-zero tile overhead.
	local function makeDriftPlane(y: number, color: Color3, trans: number): Part
		local p = Instance.new("Part")
		p.Name         = "DriftLayer"
		p.Size         = Vector3.new(920, 0.1, 920)
		p.Position     = Vector3.new(0, y, 0)
		p.Color        = color
		p.Material     = Enum.Material.Neon
		p.Transparency = trans
		p.Anchored     = true
		p.CanCollide   = false
		p.CastShadow   = false
		p.CanQuery     = false
		p.Parent       = fogFolder
		return p
	end

	driftPlane1 = makeDriftPlane(FOG_Y + 0.20, Color3.fromRGB(3, 6, 18),  0.92)
	driftPlane2 = makeDriftPlane(FOG_Y + 0.38, Color3.fromRGB(0, 3, 12),  0.95)

	task.spawn(function()
		local t = 0
		while driftPlane1 and driftPlane1.Parent do
			t += 0.1
			driftPlane1.Position = Vector3.new(
				math.sin(t * math.pi * 2 / 30) * 18,
				FOG_Y + 0.20,
				math.cos(t * math.pi * 2 / 38) * 12)
			driftPlane2.Position = Vector3.new(
				math.cos(t * math.pi * 2 / 24) * 14,
				FOG_Y + 0.38,
				math.sin(t * math.pi * 2 / 28) * 16)
			task.wait(0.1)
		end
	end)

	task.spawn(function()
		-- Wire dirty flags to folder changes so source/deposit lists
		-- are rebuilt only when membership actually changes.
		local function watch(name: string, fn: () -> ())
			local f = workspace:WaitForChild(name, 15)
			if not f then return end
			f.ChildAdded:Connect(fn)
			f.ChildRemoved:Connect(fn)
		end

		local function dirtySource() sourcesDirty = true end

		watch("Units",     dirtySource)
		watch("Buildings", dirtySource)
		watch("Miners",    dirtySource)

		while true do
			updateFog()
			task.wait(TICK)
		end
	end)
end

-- Immediately clears fog around current sources without waiting for the next tick.
-- Call this when the player's own buildings are placed so fog lifts instantly.
function FogManager.forceRefresh()
	sourcesDirty = true
	updateFog()
end

return FogManager
