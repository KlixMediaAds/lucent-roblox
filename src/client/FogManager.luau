--[[
	FogManager — Starcraft 2-style fog of war

	Three cell states per grid tile:
	  UNEXPLORED  (0) — never visited → pitch-black opaque tile
	  EXPLORED    (1) — visited before, no current vision → dark shroud overlay;
	                    enemy buildings shown as a transparent "last known" ghost,
	                    enemy units hidden (they move)
	  VISIBLE     (2) — currently inside a vision radius → no fog, everything shown

	Visibility sources and radii:
	  Own units     →  65 studs
	  Own buildings →  55 studs
	  Own miners    →  30 studs
--]]

local Players = game:GetService("Players")

local FogManager  = {}
local localPlayer = Players.LocalPlayer

-- ── Config ────────────────────────────────────────────────────────────────────
local CELL_SIZE    = 20    -- studs per fog tile  (map coverage: ±220 studs)
local GRID_CELLS   = 22    -- tiles per axis
local HALF         = GRID_CELLS / 2   -- 11
local FOG_Y        = 0.15  -- world Y of tile centres

local SHROUD_TRANS = 0.45  -- shroud tile transparency when "explored" (0=opaque)
local GHOST_MOD    = 0.55  -- LocalTransparencyModifier for "last known" buildings

local TICK = 0.3           -- seconds between fog updates

local VIS_UNIT     = 65
local VIS_BUILDING = 55
local VIS_MINER    = 30

local STATE_UNEXPLORED = 0
local STATE_EXPLORED   = 1
local STATE_VISIBLE    = 2

-- ── State ─────────────────────────────────────────────────────────────────────
local localUserId: number
local fogFolder:   Folder

local blackLayer:  { { Part } } = {}   -- pitch-black tiles
local shroudLayer: { { Part } } = {}   -- dark-overlay tiles
local tileState:   { { number } } = {} -- current state per cell (avoids redundant writes)
local exploredMap: { [number]: { [number]: true } } = {}   -- permanent memory

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

-- ── Tile factories ────────────────────────────────────────────────────────────

local function makeTilePart(y: number, trans: number): Part
	local p         = Instance.new("Part")
	p.Name          = "Tile"
	p.Size          = Vector3.new(CELL_SIZE, 0.1, CELL_SIZE)
	p.Color         = Color3.new(0, 0, 0)
	p.Material      = Enum.Material.SmoothPlastic
	p.Transparency  = trans
	p.Anchored      = true
	p.CanCollide    = false
	p.CastShadow    = false
	p.CanQuery      = false   -- invisible to raycasts: placement / selection unaffected
	p.Position      = Vector3.new(0, y, 0)
	return p
end

local function applyTileState(row: number, col: number, state: number)
	if state == STATE_UNEXPLORED then
		blackLayer[row][col].Transparency  = 0   -- opaque black
		shroudLayer[row][col].Transparency = 1   -- shroud hidden (black handles it)
	elseif state == STATE_EXPLORED then
		blackLayer[row][col].Transparency  = 1   -- black gone permanently
		shroudLayer[row][col].Transparency = SHROUD_TRANS   -- dark overlay
	else -- STATE_VISIBLE
		blackLayer[row][col].Transparency  = 1
		shroudLayer[row][col].Transparency = 1
	end
end

local function buildFogGrid()
	fogFolder        = Instance.new("Folder")
	fogFolder.Name   = "FogOfWar"
	fogFolder.Parent = workspace

	local blackF        = Instance.new("Folder")
	blackF.Name         = "Black"
	blackF.Parent       = fogFolder

	local shroudF       = Instance.new("Folder")
	shroudF.Name        = "Shroud"
	shroudF.Parent      = fogFolder

	for row = 1, GRID_CELLS do
		blackLayer[row]  = {}
		shroudLayer[row] = {}
		tileState[row]   = {}
		for col = 1, GRID_CELLS do
			local wx, wz = cellCentre(row, col)

			local black = makeTilePart(FOG_Y, 0)         -- starts opaque
			black.Position = Vector3.new(wx, FOG_Y, wz)
			black.Parent   = blackF

			local shroud = makeTilePart(FOG_Y + 0.05, 1) -- starts invisible
			shroud.Position = Vector3.new(wx, FOG_Y + 0.05, wz)
			shroud.Parent   = shroudF

			blackLayer[row][col]  = black
			shroudLayer[row][col] = shroud
			tileState[row][col]   = STATE_UNEXPLORED
		end
	end
end

-- ── Vision sources ────────────────────────────────────────────────────────────

type Source = { x: number, z: number, r2: number }

local function collectSources(): { Source }
	local out: { Source } = {}
	local myStr = tostring(localUserId)

	local function add(p: BasePart, r: number)
		local pos = p.Position
		table.insert(out, { x = pos.X, z = pos.Z, r2 = r * r })
	end

	local unitsF = workspace:FindFirstChild("Units")
	if unitsF then
		for _, c in unitsF:GetChildren() do
			local ov = c:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr and c:IsA("BasePart") then
				add(c :: BasePart, VIS_UNIT)
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
					add(base :: BasePart, VIS_BUILDING)
				end
			end
		end
	end

	local minersF = workspace:FindFirstChild("Miners")
	if minersF then
		for _, c in minersF:GetChildren() do
			local ov = c:FindFirstChild("OwnerId")
			if ov and ov.Value == myStr and c:IsA("BasePart") then
				add(c :: BasePart, VIS_MINER)
			end
		end
	end

	return out
end

-- ── Visibility grid ───────────────────────────────────────────────────────────

local function computeVisibleGrid(sources: { Source }): { [number]: { [number]: true } }
	local visGrid: { [number]: { [number]: true } } = {}

	for _, src in sources do
		local radius  = math.sqrt(src.r2)
		local radiusC = math.ceil(radius / CELL_SIZE) + 1
		local cRow, cCol = worldToCell(src.x, src.z)

		for dr = -radiusC, radiusC do
			local row = cRow + dr
			if row < 1 or row > GRID_CELLS then continue end
			if not visGrid[row] then visGrid[row] = {} end
			for dc = -radiusC, radiusC do
				local col = cCol + dc
				if col < 1 or col > GRID_CELLS then continue end
				local cwx, cwz = cellCentre(row, col)
				local dx = cwx - src.x
				local dz = cwz - src.z
				if dx * dx + dz * dz <= src.r2 then
					visGrid[row][col] = true
				end
			end
		end
	end

	return visGrid
end

-- ── Per-position helpers ──────────────────────────────────────────────────────

local function posIsVisible(pos: Vector3, visGrid: { [number]: { [number]: true } }): boolean
	local row, col = worldToCell(pos.X, pos.Z)
	if not inBounds(row, col) then return false end
	return visGrid[row] ~= nil and visGrid[row][col] == true
end

local function posIsExplored(pos: Vector3): boolean
	local row, col = worldToCell(pos.X, pos.Z)
	if not inBounds(row, col) then return false end
	return exploredMap[row] ~= nil and exploredMap[row][col] == true
end

-- ── Main update ───────────────────────────────────────────────────────────────

local function updateFog()
	local sources = collectSources()
	local visGrid = computeVisibleGrid(sources)

	-- Permanently mark all currently-visible cells as explored
	for row, cols in visGrid do
		if not exploredMap[row] then exploredMap[row] = {} end
		for col in cols do
			exploredMap[row][col] = true
		end
	end

	-- ── Fog grid tiles ────────────────────────────────────────────────────
	for row = 1, GRID_CELLS do
		local visRow = visGrid[row]
		local expRow = exploredMap[row]
		for col = 1, GRID_CELLS do
			local vis = visRow ~= nil and visRow[col] == true
			local exp = expRow ~= nil and expRow[col] == true

			local newState: number
			if vis then
				newState = STATE_VISIBLE
			elseif exp then
				newState = STATE_EXPLORED
			else
				newState = STATE_UNEXPLORED
			end

			-- Only write to parts when state actually changes
			if newState ~= tileState[row][col] then
				tileState[row][col] = newState
				applyTileState(row, col, newState)
			end
		end
	end

	-- ── Enemy units: visible → show, otherwise → hide ─────────────────────
	local myStr   = tostring(localUserId)
	local unitsF  = workspace:FindFirstChild("Units")
	if unitsF then
		for _, child in unitsF:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local ov = child:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local bp  = child :: BasePart
			local vis = posIsVisible(bp.Position, visGrid)
			bp.LocalTransparencyModifier = if vis then 0 else 1
			for _, gc in bp:GetChildren() do
				if gc:IsA("BillboardGui") then
					local bb = gc :: BillboardGui
					bb.Enabled = vis
				end
			end
		end
	end

	-- ── Enemy buildings:
	--    visible   → normal
	--    explored  → ghosted (last-known position, semi-transparent)
	--    unexplored → fully hidden
	local buildingsF = workspace:FindFirstChild("Buildings")
	if buildingsF then
		for _, model in buildingsF:GetChildren() do
			local ov = model:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local base = model:FindFirstChild("Base")
			if not base or not base:IsA("BasePart") then continue end
			local bpos = (base :: BasePart).Position
			local vis  = posIsVisible(bpos, visGrid)
			local exp  = posIsExplored(bpos)

			local modifier: number
			local bbEnabled: boolean
			if vis then
				modifier  = 0
				bbEnabled = true
			elseif exp then
				modifier  = GHOST_MOD   -- semi-transparent "last known" ghost
				bbEnabled = false
			else
				modifier  = 1           -- fully invisible
				bbEnabled = false
			end

			for _, desc in model:GetDescendants() do
				if desc:IsA("BasePart") then
					local dp = desc :: BasePart
					dp.LocalTransparencyModifier = modifier
				elseif desc:IsA("BillboardGui") then
					local bb = desc :: BillboardGui
					bb.Enabled = bbEnabled
				end
			end
		end
	end

	-- ── Enemy miners: visible → show, otherwise → hide ────────────────────
	local minersF = workspace:FindFirstChild("Miners")
	if minersF then
		for _, child in minersF:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local ov = child:FindFirstChild("OwnerId")
			if not ov or ov.Value == myStr then continue end
			local bp = child :: BasePart
			bp.LocalTransparencyModifier = if posIsVisible(bp.Position, visGrid) then 0 else 1
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function FogManager.init(userId: number)
	localUserId = userId
	buildFogGrid()

	task.spawn(function()
		task.wait(1)   -- let world geometry settle
		while true do
			updateFog()
			task.wait(TICK)
		end
	end)
end

return FogManager
