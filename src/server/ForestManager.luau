--[[
	ForestManager — dense destructible forest scattered across the map.

	• generate()           scatters trees on a jittered grid, skipping resources,
	                       elevated terrain, the map edge and existing buildings.
	• clearAround(pos, r)  fells every tree within `r` of `pos` (trees topple away
	                       from the point, then fade). Used for:
	                         – building placement (the structure's footprint),
	                         – medium+ units knocking trees over as they advance,
	                         – new ore deposits landing in the woods.

	Trees are non-colliding, non-query scenery (CanQuery=false) so they never
	block raycasts, unit pathing or building placement — they only *look* solid
	and get knocked down. A spatial hash keeps clearAround cheap on a dense map.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local ForestManager = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
local HALF          = 432    -- map half-extent (studs)
local EDGE_MARGIN   = 16     -- keep trees off the boundary walls
local SPACING       = 30     -- base grid spacing between candidate spots
local JITTER        = 12     -- random offset applied within each cell
local DEPOSIT_CLEAR = 16     -- no tree within this radius of a resource deposit
local BUILDING_PAD  = 12     -- min clearance from a non-CC building at gen time
local TRUNK_R       = 1.5    -- trunk radius (added to a unit's reach)
local CELL          = 24     -- spatial-hash cell size (studs)
local MAX_TREES     = 820    -- hard safety cap on tree count

-- Forest is placed with Perlin noise so trees gather into organic groves separated by
-- open clearings, rather than an even sprinkle. Density at a spot = the noise value; a
-- candidate is planted only where density clears the threshold, and denser cores plant
-- more reliably (the probability tracks the density).
local NOISE_SCALE   = 0.012  -- lower → larger groves + clearings
local NOISE_THRESH  = 0.50   -- density (0..1) a spot must clear to grow a tree

-- ── State ───────────────────────────────────────────────────────────────────
type Tree = { id: number, pos: Vector3, model: Model }

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

local function buildTreeModel(pos: Vector3, seed: number): Model
	local r     = Random.new(seed * 7919 + 13)
	local h     = r:NextNumber(12, 19)
	local model = Instance.new("Model")
	model.Name  = "Tree"

	-- Invisible ground anchor — PrimaryPart so GetPivot() is an upright frame at
	-- the trunk base, which makes the topple rotation a clean hinge.
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
	trunk.Size        = Vector3.new(h, 1.6, 1.6)
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
	local canopyBase = h - 1.5
	local blobs      = r:NextInteger(2, 3)
	for i = 1, blobs do
		local d           = r:NextNumber(4.5, 7.5)
		local ball        = Instance.new("Part")
		ball.Shape        = Enum.PartType.Ball
		ball.Size         = Vector3.new(d, d * r:NextNumber(0.85, 1.05), d)
		ball.CFrame       = CFrame.new(pos + Vector3.new(
			r:NextNumber(-1.6, 1.6),
			canopyBase + (i - 1) * r:NextNumber(1.6, 2.6),
			r:NextNumber(-1.6, 1.6)))
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

-- ── Felling ─────────────────────────────────────────────────────────────────
local function topple(t: Tree, fromPos: Vector3)
	unregister(t)
	local model = t.model
	if not model.Parent then return end

	-- Fall away from the source point (a unit / building / deposit centre).
	local dir = Vector3.new(t.pos.X - fromPos.X, 0, t.pos.Z - fromPos.Z)
	if dir.Magnitude < 0.1 then
		local a = rng:NextNumber(0, math.pi * 2)
		dir = Vector3.new(math.cos(a), 0, math.sin(a))
	end
	dir = dir.Unit

	local axis  = Vector3.new(dir.Z, 0, -dir.X)   -- horizontal hinge perpendicular to fall dir
	local hinge = Vector3.new(t.pos.X, 0, t.pos.Z)
	local rest  = model:GetPivot()

	task.spawn(function()
		local FALL = 0.7
		local el   = 0
		while el < FALL do
			local dt = RunService.Heartbeat:Wait()
			el += dt
			local tt  = math.min(el / FALL, 1)
			local ang = (1 - (1 - tt) ^ 2) * math.rad(84)  -- ease-out to ~flat
			model:PivotTo(CFrame.new(hinge) * CFrame.fromAxisAngle(axis, ang) * CFrame.new(hinge):Inverse() * rest)
		end

		task.wait(2.5)

		local parts: { BasePart } = {}
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then table.insert(parts, p) end
		end
		local fe = 0
		while fe < 0.6 do
			local dt = RunService.Heartbeat:Wait()
			fe += dt
			local a = math.min(fe / 0.6, 1)
			for _, p in parts do if p.Parent then p.Transparency = a end end
		end
		model:Destroy()
	end)
end

-- Fell every standing tree within `radius` of `pos`. Cheap: only scans the few
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
	for _, t in hits do topple(t, pos) end
	return #hits
end

-- A medium+ unit shoulders through nearby trees as it moves.
-- Returns the number of trees actually felled this call.
function ForestManager.knockNear(unitPos: Vector3, unitRadius: number): number
	return ForestManager.clearAround(unitPos, unitRadius + TRUNK_R)
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

	-- Fresh noise offset per generation so each match's groves differ.
	local nox = rng:NextNumber(-500, 500)
	local noz = rng:NextNumber(-500, 500)

	local x = -lim
	while x <= lim do
		local z = -lim
		while z <= lim do
			if counter < MAX_TREES then
				local px = math.clamp(x + rng:NextNumber(-JITTER, JITTER), -lim, lim)
				local pz = math.clamp(z + rng:NextNumber(-JITTER, JITTER), -lim, lim)
				-- Perlin density in 0..1; grow only in the groves (noise above the
				-- threshold), and let denser cores plant more reliably.
				local dens = math.noise(px * NOISE_SCALE + nox, pz * NOISE_SCALE + noz, 0.5) + 0.5
				if dens > NOISE_THRESH and rng:NextNumber(0, 1) < dens then
					local py  = terrainManagerRef and terrainManagerRef.surfaceHeightAt(px, pz) or 0
					local pos = Vector3.new(px, py, pz)
					-- (pos.Y is the real surface so the tree isn't buried under a tier)
					if not depositTooClose(pos, deposits)
						and not onTerrainObstacle(pos)
						and not nearBuilding(pos) then
						counter += 1
						local id    = counter
						local model = buildTreeModel(pos, id)
						model.Parent = forestFolder
						local t: Tree = { id = id, pos = pos, model = model }
						trees[id] = t
						addToGrid(t)
						-- Spread the part creation over a few frames to avoid a hitch.
						if counter % 100 == 0 then task.wait() end
					end
				end
			end
			z += SPACING
		end
		x += SPACING
	end

	print("[ForestManager] Grew", counter, "trees")
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function ForestManager.init(mineralManager: any)
	mineralManagerRef = mineralManager
end

function ForestManager.setTerrainManager(tm: any)
	terrainManagerRef = tm
end

return ForestManager
