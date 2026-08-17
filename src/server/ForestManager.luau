--[[
	ForestManager — the map's woods: a handful of dense groves with open ground
	between them, plus a thin scatter of lone trees.

	• generate()           seeds grove centres, fills each with a core-dense /
	                       edge-thin spread of trees, then drops a few loners out in
	                       the open. Skips resources, elevated terrain, the map edge
	                       and existing buildings.
	• clearAround(pos, r)  removes every tree within `r` of `pos`. Used for:
	                         – building placement (the structure's footprint),
	                         – new ore deposits landing in the woods.

	NO UNIT touches the forest. Trees are permanent scenery that everything walks
	straight through, and they never TOPPLE: the only thing that removes one is
	something being built on top of it, and it sinks into the ground and fades where it
	stands rather than falling over.

	Trees are non-colliding, non-query scenery (CanQuery=false) so they never
	block raycasts, unit pathing or building placement: they only *look* solid.
	A spatial hash keeps clearAround cheap.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local ForestManager = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
local HALF          = 432    -- map half-extent (studs)
local EDGE_MARGIN   = 16     -- keep trees off the boundary walls
local DEPOSIT_CLEAR = 16     -- no tree within this radius of a resource deposit
local BUILDING_PAD  = 12     -- min clearance from a non-CC building at gen time
local CELL          = 24     -- spatial-hash cell size (studs)
-- Hard safety cap only. The knobs below are what decide the forest; this sits well above
-- what they produce (~210) so it never silently truncates a run. If it ever starts biting,
-- the knobs are wrong, not the cap.
local MAX_TREES     = 400

-- The woods are grown as distinct GROVES with wide open ground between them, plus a few
-- lone trees standing well clear of any of them. Every figure below is per diagonal half
-- of the map; the mirror across z = x doubles it. At these settings the groves cover
-- roughly 8% of the map, so the ground between them reads as genuinely open.
local GROVES        = 6      -- grove centres seeded per half (→ 12 stands map-wide)
local GROVE_R_MIN   = 26     -- grove radius range (studs)
local GROVE_R_MAX   = 52
-- Comfortably more than GROVE_R_MAX * 2, so two stands can never grow into each other:
-- there is always bare ground between any pair.
local GROVE_GAP     = 140    -- min distance between two grove centres
local GROVE_SPACING = 12     -- candidate grid step inside a grove (lower → denser core)
local GROVE_JITTER  = 5      -- random offset on each candidate, to break up the grid
local EDGE_FALLOFF  = 1.7    -- >1 → packed cores thinning to a ragged rim
local LONERS        = 14     -- lone trees scattered over the open ground per half
local LONER_CLEAR   = 40     -- how far outside every grove a loner has to stand

-- ── State ───────────────────────────────────────────────────────────────────
type Tree  = { id: number, pos: Vector3, model: Model }
-- One stand of woods: a centre and the radius its trees thin out over.
type Grove = { x: number, z: number, r: number }

local trees:   { [number]: Tree }      = {}
local grid:    { [string]: { number } } = {}  -- cellKey → list of tree ids
local counter  = 0
local forestFolder: Folder? = nil
local mineralManagerRef: any = nil
local terrainManagerRef: any = nil
local rng = Random.new()

-- ── Spatial hash ────────────────────────────────────────────────────────────
local function cellKey(x: number, z: number): string
	return math.floor(x / CELL) .. "_" .. math.floor(z / CELL)
end

local function addToGrid(t: Tree)
	local k = cellKey(t.pos.X, t.pos.Z)
	local b = grid[k]
	if not b then b = {}; grid[k] = b end
	table.insert(b, t.id)
end

local function unregister(t: Tree)
	trees[t.id] = nil
	local k = cellKey(t.pos.X, t.pos.Z)
	local b = grid[k]
	if b then
		for i = #b, 1, -1 do
			if b[i] == t.id then table.remove(b, i); break end
		end
		if #b == 0 then grid[k] = nil end
	end
end

-- ── Tree model ──────────────────────────────────────────────────────────────
local TRUNK_COL = Color3.fromRGB(86, 60, 38)
local LEAF_COLS = {
	Color3.fromRGB(46, 92, 38),
	Color3.fromRGB(58, 110, 44),
	Color3.fromRGB(40, 80, 34),
	Color3.fromRGB(66, 104, 36),
}

-- ── Pine model ──────────────────────────────────────────────────────────────
-- The forest is stamped from the authored Pinetree in ReplicatedStorage.Assets
-- (synced by Rojo from assets/Pinetree.rbxmx). It's loaded once and cloned per
-- tree. If it's ever missing we fall back to the primitive tree below, so a
-- missing asset degrades the scenery instead of taking the map down.
local TREE_H_MIN, TREE_H_MAX = 36, 57   -- planted height range, in studs (3x the old 12-19)

local template:   Model? = nil
local templateH   = 0                   -- authored height, so clones can be normalised
local templateTried = false

local function getTemplate(): Model?
	if templateTried then return template end
	templateTried = true
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local m      = assets and assets:FindFirstChild("Pinetree")
	if m and m:IsA("Model") then
		local _, size = m:GetBoundingBox()
		if size.Y > 0.1 then
			template  = m
			templateH = size.Y
		end
	end
	if not template then
		warn("[ForestManager] ReplicatedStorage.Assets.Pinetree missing — using primitive trees")
	end
	return template
end

-- One pine, stamped from the model: scaled into the forest's height range, spun to
-- its own heading, and stood on the ground at `pos`.
local function buildPineTree(pos: Vector3, seed: number, src: Model): Model
	local r     = Random.new(seed * 7919 + 13)
	local model = src:Clone()
	model.Name  = "Tree"
	model.Parent = forestFolder      -- parent before scaling so the transform sticks

	-- Normalise the authored height into the range the forest was tuned for, then
	-- vary it per tree so a grove isn't one silhouette repeated.
	model:ScaleTo(r:NextNumber(TREE_H_MIN, TREE_H_MAX) / templateH)
	-- Spin each stamp; 1,600 identical headings would read as wallpaper.
	model:PivotTo(model:GetPivot() * CFrame.Angles(0, r:NextNumber(0, math.pi * 2), 0))

	-- Stand it up: drop the bounding box's bottom-centre onto the planting spot.
	local bbCF, bbSize = model:GetBoundingBox()
	local bottom = Vector3.new(bbCF.Position.X, bbCF.Position.Y - bbSize.Y * 0.5, bbCF.Position.Z)
	model:PivotTo(model:GetPivot() + (pos - bottom))

	-- Scenery rules, forced regardless of how the model was authored: trees never
	-- collide and never absorb a raycast, so they can't block unit pathing, building
	-- placement or clicks — they only look solid, and get knocked down.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored   = true
			p.CanCollide = false
			p.CanQuery   = false
			p.CanTouch   = false
			p.CastShadow = false
		end
	end

	-- Invisible ground anchor — PrimaryPart so GetPivot() is an upright frame at the
	-- trunk base, which keeps the sink-away in wither() perfectly vertical. Added last
	-- so it stays out of the bounding-box maths above.
	local anchor        = Instance.new("Part")
	anchor.Name         = "Root"
	anchor.Size         = Vector3.one * 0.2
	anchor.CFrame       = CFrame.new(pos)
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.Transparency = 1
	anchor.CastShadow   = false
	anchor.Parent       = model
	model.PrimaryPart   = anchor

	return model
end

-- Fallback scenery: the original primitive tree (trunk cylinder + leafy blobs),
-- used only when the pine model can't be found.
local function buildProceduralTree(pos: Vector3, seed: number): Model
	local r     = Random.new(seed * 7919 + 13)
	local h     = r:NextNumber(TREE_H_MIN, TREE_H_MAX)
	-- Thickness and canopy are authored against a ~15.5-stud tree, so everything below
	-- is measured off this factor and the fallback keeps its proportions at any height.
	local sc    = h / 15.5
	local model = Instance.new("Model")
	model.Name  = "Tree"

	-- Invisible ground anchor — PrimaryPart so GetPivot() is an upright frame at
	-- the trunk base, which keeps the sink-away in wither() perfectly vertical.
	local anchor        = Instance.new("Part")
	anchor.Name         = "Root"
	anchor.Size         = Vector3.one * 0.2
	anchor.CFrame       = CFrame.new(pos)
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.Transparency = 1
	anchor.CastShadow   = false
	anchor.Parent       = model
	model.PrimaryPart   = anchor

	-- Trunk (cylinder length runs along local X → rotate Z by 90° to stand up)
	local trunk       = Instance.new("Part")
	trunk.Name        = "Trunk"
	trunk.Shape       = Enum.PartType.Cylinder
	trunk.Size        = Vector3.new(h, 1.6 * sc, 1.6 * sc)
	trunk.CFrame      = CFrame.new(pos + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	trunk.Color       = TRUNK_COL
	trunk.Material    = Enum.Material.Wood
	trunk.Anchored    = true
	trunk.CanCollide  = false
	trunk.CanQuery    = false
	trunk.CastShadow  = false
	trunk.Parent      = model

	-- Canopy: 2–3 overlapping leafy blobs near the top
	local leaf       = LEAF_COLS[r:NextInteger(1, #LEAF_COLS)]
	local canopyBase = h - 1.5 * sc
	local blobs      = r:NextInteger(2, 3)
	for i = 1, blobs do
		local d           = r:NextNumber(4.5, 7.5) * sc
		local ball        = Instance.new("Part")
		ball.Shape        = Enum.PartType.Ball
		ball.Size         = Vector3.new(d, d * r:NextNumber(0.85, 1.05), d)
		ball.CFrame       = CFrame.new(pos + Vector3.new(
			r:NextNumber(-1.6, 1.6) * sc,
			canopyBase + (i - 1) * r:NextNumber(1.6, 2.6) * sc,
			r:NextNumber(-1.6, 1.6) * sc))
		ball.Color        = leaf
		ball.Material     = Enum.Material.Grass
		ball.Anchored     = true
		ball.CanCollide   = false
		ball.CanQuery     = false
		ball.CastShadow   = false
		ball.Parent       = model
	end

	return model
end

-- Plant one tree: the authored pine when it's available, the primitive otherwise.
local function buildTreeModel(pos: Vector3, seed: number): Model
	local src = getTemplate()
	if src then return buildPineTree(pos, seed, src) end
	return buildProceduralTree(pos, seed)
end

-- ── Removal ─────────────────────────────────────────────────────────────────
-- A tree that has to go sinks into the ground and fades where it stands. It never
-- topples: nothing is left lying flat, and the trunk is gone from the map instead of
-- becoming a piece of debris.
local function wither(t: Tree)
	unregister(t)
	-- ForestFade (client) writes Transparency on standing trees. The fade below drives
	-- the same property, so hand the tree over before a single frame of it.
	t.model:SetAttribute("Felled", true)
	local model = t.model
	if not model.Parent then return end

	local _, bbSize = model:GetBoundingBox()
	local rest      = model:GetPivot()
	local sink      = bbSize.Y * 0.55

	task.spawn(function()
		-- Decals as well as parts: the authored pine's needles are decals, and a decal
		-- keeps drawing at its own transparency however invisible its part goes.
		local draws: { Instance } = {}
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") or p:IsA("Decal") or p:IsA("Texture") then
				table.insert(draws, p)
			end
		end

		local SINK_TIME = 0.9
		local el = 0
		while el < SINK_TIME do
			local dt = RunService.Heartbeat:Wait()
			el += dt
			if not model.Parent then return end
			local a = math.min(el / SINK_TIME, 1)
			-- Ease in: it hesitates, then drops away.
			model:PivotTo(rest * CFrame.new(0, -sink * a * a, 0))
			for _, p in draws do
				if p.Parent then (p :: any).Transparency = a end
			end
		end
		model:Destroy()
	end)
end

-- Take out every standing tree within `radius` of `pos`. Cheap: only scans the few
-- spatial-hash cells the radius overlaps.
function ForestManager.clearAround(pos: Vector3, radius: number): number
	if not forestFolder then return 0 end
	local cminX = math.floor((pos.X - radius) / CELL)
	local cmaxX = math.floor((pos.X + radius) / CELL)
	local cminZ = math.floor((pos.Z - radius) / CELL)
	local cmaxZ = math.floor((pos.Z + radius) / CELL)
	local r2    = radius * radius

	local hits: { Tree } = {}
	for cx = cminX, cmaxX do
		for cz = cminZ, cmaxZ do
			local b = grid[cx .. "_" .. cz]
			if b then
				for _, id in b do
					local t = trees[id]
					if t then
						local dx = t.pos.X - pos.X
						local dz = t.pos.Z - pos.Z
						if dx * dx + dz * dz <= r2 then table.insert(hits, t) end
					end
				end
			end
		end
	end
	for _, t in hits do wither(t) end
	return #hits
end

-- Is any standing tree within `radius` of this spot? Same cheap spatial-hash walk as
-- clearAround, without removing anything. WildPlants uses it to keep its blooms out in the
-- open where they can be seen.
function ForestManager.treeNear(x: number, z: number, radius: number): boolean
	local r2 = radius * radius
	for cx = math.floor((x - radius) / CELL), math.floor((x + radius) / CELL) do
		for cz = math.floor((z - radius) / CELL), math.floor((z + radius) / CELL) do
			local b = grid[cx .. "_" .. cz]
			if b then
				for _, id in b do
					local t = trees[id]
					if t then
						local dx = t.pos.X - x
						local dz = t.pos.Z - z
						if dx * dx + dz * dz <= r2 then return true end
					end
				end
			end
		end
	end
	return false
end

-- ── Generation ──────────────────────────────────────────────────────────────
local function depositTooClose(pos: Vector3, deposits: { Vector3 }): boolean
	local c2 = DEPOSIT_CLEAR * DEPOSIT_CLEAR
	for _, d in deposits do
		local dx = d.X - pos.X
		local dz = d.Z - pos.Z
		if dx * dx + dz * dz < c2 then return true end
	end
	return false
end

local function onTerrainObstacle(pos: Vector3): boolean
	local f = workspace:FindFirstChild("TerrainObstacles")
	if not f then return false end
	for _, part in f:GetChildren() do
		if part:IsA("BasePart") then
			if math.abs(pos.X - part.Position.X) < part.Size.X / 2 + 2
				and math.abs(pos.Z - part.Position.Z) < part.Size.Z / 2 + 2 then
				return true
			end
		end
	end
	return false
end

-- Avoid buildings that already exist when the forest is generated (starting CCs
-- and mines). CCs get a wide clearing; other structures a small pad.
local function nearBuilding(pos: Vector3): boolean
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return false end
	for _, model in bf:GetChildren() do
		local base = model:FindFirstChild("Base") :: BasePart?
		if base then
			local bt   = model:FindFirstChild("BuildingType") :: StringValue?
			local pad  = (bt and bt.Value == "CommandCenter") and Config.FOREST_CC_CLEARING or BUILDING_PAD
			local dx   = base.Position.X - pos.X
			local dz   = base.Position.Z - pos.Z
			if dx * dx + dz * dz < pad * pad then return true end
		end
	end
	return false
end

function ForestManager.clear()
	if forestFolder then forestFolder:Destroy() end
	forestFolder = nil
	trees   = {}
	grid    = {}
	counter = 0
end

function ForestManager.generate()
	ForestManager.clear()

	forestFolder        = Instance.new("Folder")
	forestFolder.Name   = "Forest"
	forestFolder.Parent = workspace

	local deposits = mineralManagerRef and mineralManagerRef.getUnclaimedPositions() or {}
	local lim      = HALF - EDGE_MARGIN

	-- Plant one tree at (px, pz). Used for both a candidate and its diagonal twin.
	local function plant(px: number, pz: number)
		if counter >= MAX_TREES then return end
		counter += 1
		local id    = counter
		-- (Y is the real surface so the tree isn't buried under a tier.)
		local py    = terrainManagerRef and terrainManagerRef.surfaceHeightAt(px, pz) or 0
		local pos   = Vector3.new(px, py, pz)
		local model = buildTreeModel(pos, id)
		model.Parent = forestFolder
		local t: Tree = { id = id, pos = pos, model = model }
		trees[id] = t
		addToGrid(t)
		-- Spread the part creation over a few frames to avoid a hitch.
		if counter % 50 == 0 then task.wait() end
	end

	-- One candidate spot, run through every planting rule and then mirrored.
	--
	-- Diagonal symmetry (mirror across z = x): only spots in the SE half (pz <= px) are
	-- decided, and each planted tree is twinned to (pz, px) in the NW half, so both
	-- diagonal halves are identical. Checks run on the primary spot; because deposits and
	-- starting bases are ALSO diagonally symmetric, a spot clear on this side has a clear
	-- twin on the other.
	local function tryPlant(px: number, pz: number)
		if counter >= MAX_TREES then return end
		-- Dropped rather than clamped: a grove that overruns the boundary should thin out
		-- at the wall, not stack its overflow into a line along it.
		if px < -lim or px > lim or pz < -lim or pz > lim then return end
		if pz > px then return end
		local pos = Vector3.new(px, 0, pz)
		if depositTooClose(pos, deposits) then return end
		if onTerrainObstacle(pos) then return end
		if nearBuilding(pos) then return end
		plant(px, pz)
		-- Mirror twin (skip if it sits on the diagonal → same spot).
		if math.abs(px - pz) > 0.5 then plant(pz, px) end
	end

	-- ── Grove centres ───────────────────────────────────────────────────────────
	-- Seeded in the SE half and kept GROVE_GAP apart, so the woods read as a set of
	-- separate stands with open ground between them rather than one continuous canopy.
	local groves: { Grove } = {}
	local tries = 0
	while #groves < GROVES and tries < GROVES * 60 do
		tries += 1
		local cx = rng:NextNumber(-lim, lim)
		local cz = rng:NextNumber(-lim, lim)
		if cz > cx then cx, cz = cz, cx end   -- fold the pick into the SE half
		local ok = true
		for _, g in groves do
			local dx, dz = g.x - cx, g.z - cz
			if dx * dx + dz * dz < GROVE_GAP * GROVE_GAP then ok = false; break end
		end
		if ok then
			table.insert(groves, { x = cx, z = cz, r = rng:NextNumber(GROVE_R_MIN, GROVE_R_MAX) })
		end
	end

	-- ── Loners ──────────────────────────────────────────────────────────────────
	-- A few trees standing on their own well outside every grove, so the open ground
	-- isn't perfectly bare between stands.
	--
	-- Planted BEFORE the groves on purpose: they are a handful of trees against the
	-- groves' couple of hundred, so if the safety cap ever does bite, it has to eat into
	-- the woods rather than quietly deleting every lone tree on the map.
	for _ = 1, LONERS do
		local px = rng:NextNumber(-lim, lim)
		local pz = rng:NextNumber(-lim, lim)
		if pz > px then px, pz = pz, px end
		local clear = true
		for _, g in groves do
			local dx, dz = g.x - px, g.z - pz
			local reach  = g.r + LONER_CLEAR
			if dx * dx + dz * dz < reach * reach then clear = false; break end
		end
		if clear then tryPlant(px, pz) end
	end
	local lonerCount = counter

	-- ── Fill each grove ─────────────────────────────────────────────────────────
	for _, g in groves do
		local gx = -g.r
		while gx <= g.r do
			local gz = -g.r
			while gz <= g.r do
				local ox = gx + rng:NextNumber(-GROVE_JITTER, GROVE_JITTER)
				local oz = gz + rng:NextNumber(-GROVE_JITTER, GROVE_JITTER)
				local d  = math.sqrt(ox * ox + oz * oz)
				if d <= g.r then
					-- Packed at the core, thinning towards the rim, so a grove has a soft
					-- ragged edge instead of a shaved circle.
					if rng:NextNumber(0, 1) < 1 - (d / g.r) ^ EDGE_FALLOFF then
						tryPlant(g.x + ox, g.z + oz)
					end
				end
				gz += GROVE_SPACING
			end
			gx += GROVE_SPACING
		end
	end

	-- Printed so the density can be checked without counting them on screen. If `counter`
	-- ever comes back equal to MAX_TREES, the cap truncated the run and the knobs at the
	-- top of this file need lowering.
	print(string.format("[ForestManager] Grew %d trees: %d in %d groves + %d loners (diagonally mirrored, cap %d)",
		counter, counter - lonerCount, #groves * 2, lonerCount, MAX_TREES))
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function ForestManager.init(mineralManager: any)
	mineralManagerRef = mineralManager
end

function ForestManager.setTerrainManager(tm: any)
	terrainManagerRef = tm
end

return ForestManager
