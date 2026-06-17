--!strict
--[[
	TerrainManager v4 — StarCraft 2-style tiered Roblox Terrain.

	Three elevation levels built entirely from real Terrain voxels (rock cliffs
	with a grass cap, grass ramps) — no parts on the ground:
	  • Level 0 — the flat base ground (grass floor, top at GROUND_TOP).
	  • Level 1 — a wide "natural" plateau raised one STEP, reached from L0 by
	    1–2 grass ramps cut into its front cliff.
	  • Level 2 — a smaller "main" plateau sitting on the back of L1, raised a
	    further STEP, reached from L1 by 1–2 ramps.

	Symmetry: the whole layout is generated for one half and mirrored across a
	single axis (randomly the world X or Z axis), so both players get identical
	terrain. Plateau extents, positions and ramp count/placement are randomised
	each generation.

	An (empty) TerrainObstacles folder is kept so isPositionBlocked still works
	for the lane-mode walls; the tiered plateaus are intentionally buildable.
]]

local TerrainManager = {}

local Terrain         = workspace.Terrain
local obstaclesFolder: Folder? = nil

-- Stored layout of the current tiered map, used by heightAt() so structures and
-- trees can snap to whichever level they sit on. nil = flat / lane (everything
-- on the logical ground plane).
local terrainPlan: any = nil

local HALF        = 432   -- map half-extent (studs)
local GROUND_TOP  = -4    -- top surface of the base ground fill (matches init.server)
local BODY_BOTTOM = -12   -- bottom of every terrain column
local STEP        = 12    -- height gained per elevation level
local CAP         = 4     -- thickness of the grass cap on each plateau top
local RAMP_D      = 28    -- horizontal depth (run) of each ramp

local L1_TOP = GROUND_TOP + STEP          -- natural plateau top
local L2_TOP = GROUND_TOP + STEP * 2      -- main plateau top

-- ── Base ground ───────────────────────────────────────────────────────────────
-- Mirrors the fill in init.server.luau.  Called after Terrain:Clear() to restore
-- the flat grass floor so the rest of the game is unaffected.

local function fillBaseGround()
	Terrain:FillBlock(
		CFrame.new(0, -8, 0),
		Vector3.new(960, 8, 960),
		Enum.Material.Grass
	)
end

-- ── Lane obstacle helper ────────────────────────────────────────────────────────
-- Invisible Part added to TerrainObstacles so code-level placement/movement
-- checks (isPositionBlocked) still see the lane-mode rock walls as blocked.
local function addObstacle(cx: number, cz: number, hw: number, hd: number, h: number)
	local p           = Instance.new("Part")
	p.Name            = "TerrainObstacle"
	p.Size            = Vector3.new(hw * 2, h, hd * 2)
	p.CFrame          = CFrame.new(cx, h / 2, cz)
	p.Anchored        = true
	p.CanCollide      = false
	p.CanQuery        = false
	p.Transparency    = 1
	p.CastShadow      = false
	p.Parent          = obstaclesFolder
end

-- ── Generation ────────────────────────────────────────────────────────────────

function TerrainManager.generate(seed: number?)
	if obstaclesFolder then obstaclesFolder:Destroy(); obstaclesFolder = nil end
	Terrain:Clear()
	fillBaseGround()

	obstaclesFolder        = Instance.new("Folder")
	obstaclesFolder.Name   = "TerrainObstacles"
	obstaclesFolder.Parent = workspace

	local rng = Random.new(seed or math.floor(os.clock() * 7919))
	local function r(base: number, spread: number): number
		return base + rng:NextNumber(-spread, spread)
	end

	-- Mirror across either the world X axis (reflect Z) or the world Z axis
	-- (reflect X). We author the layout in plan coords (a = cross axis,
	-- b = symmetry axis) and map them to world depending on the chosen axis.
	local mirrorZ = rng:NextInteger(1, 2) == 1

	local function worldPos(a: number, b: number, y: number): Vector3
		if mirrorZ then return Vector3.new(a, y, b) else return Vector3.new(b, y, a) end
	end
	local function planSize(sa: number, sb: number, sy: number): Vector3
		if mirrorZ then return Vector3.new(sa, sy, sb) else return Vector3.new(sb, sy, sa) end
	end
	-- Uphill world direction (toward the plateau) for the given half (+1 / -1).
	local function uphill(half: number): Vector3
		local u = mirrorZ and Vector3.new(0, 0, 1) or Vector3.new(1, 0, 0)
		return u * half
	end

	-- A raised plateau: rock column with a thin grass cap on top.
	local function fillTier(a: number, b: number, sa: number, sb: number, topY: number)
		local bodyTop = topY - CAP
		Terrain:FillBlock(
			CFrame.new(worldPos(a, b, (BODY_BOTTOM + bodyTop) / 2)),
			planSize(sa, sb, bodyTop - BODY_BOTTOM),
			Enum.Material.Rock
		)
		Terrain:FillBlock(
			CFrame.new(worldPos(a, b, topY - CAP / 2)),
			planSize(sa, sb, CAP),
			Enum.Material.Grass
		)
	end

	-- A grass ramp leaning on a plateau's front cliff, descending RAMP_D studs
	-- toward map centre from the cliff edge (faceB) to the lower level.
	local function fillRamp(a: number, faceB: number, w: number, half: number, lowTopY: number, highTopY: number)
		local bCenter = (faceB - RAMP_D / 2) * half
		local yCenter = (lowTopY + highTopY) / 2
		local pos     = worldPos(a, bCenter, yCenter)
		local vY      = Vector3.new(0, 1, 0)
		local vZ      = uphill(half)            -- wedge full-height face points uphill
		local vX      = vY:Cross(vZ)
		Terrain:FillWedge(
			CFrame.fromMatrix(pos, vX, vY, vZ),
			Vector3.new(w, highTopY - lowTopY, RAMP_D),
			Enum.Material.Grass
		)
	end

	-- Randomised ramp offsets along a plateau's width (1 or 2 ramps, centred).
	local function rampOffsets(sa: number): { number }
		if rng:NextInteger(1, 2) == 1 then
			return { r(0, sa * 0.16) }
		else
			local d = r(sa * 0.28, sa * 0.05)
			return { -d, d }
		end
	end

	-- ── Layout (authored for the +b half, mirrored to −b) ──────────────────────
	-- Level 1: wide natural plateau spanning most of the map width. Made deep
	-- enough that its back edge clears the L2 plateau so L2 sits fully on it.
	local l1b, l1sa, l1sb = r(235, 12), r(560, 25), r(330, 18)
	-- Level 2: smaller main plateau on the back of L1.
	local l2b, l2sa, l2sb = r(305, 12), r(360, 25), r(150, 15)

	local l1RampW, l2RampW = r(42, 4), r(40, 4)
	local l1Ramps = rampOffsets(l1sa)
	local l2Ramps = rampOffsets(l2sa)

	local l1Face = l1b - l1sb / 2   -- L1 front cliff (faces centre)
	local l2Face = l2b - l2sb / 2   -- L2 front cliff (sits on the L1 surface)

	-- Remember the layout so heightAt() can place things on the right level.
	terrainPlan = {
		mirrorZ = mirrorZ,
		l1b = l1b, l1sa = l1sa, l1sb = l1sb,
		l2b = l2b, l2sa = l2sa, l2sb = l2sb,
		l1Ramps = l1Ramps, l2Ramps = l2Ramps,
		l1RampW = l1RampW, l2RampW = l2RampW,
		l1Face = l1Face, l2Face = l2Face,
	}

	for _, half in { 1, -1 } do
		fillTier(0, l1b * half, l1sa, l1sb, L1_TOP)
		fillTier(0, l2b * half, l2sa, l2sb, L2_TOP)

		for _, off in l1Ramps do
			fillRamp(off, l1Face, l1RampW, half, GROUND_TOP, L1_TOP)
		end
		for _, off in l2Ramps do
			fillRamp(off, l2Face, l2RampW, half, L1_TOP, L2_TOP)
		end
	end
end

-- ── Lane mode terrain ─────────────────────────────────────────────────────────
-- Clears all platforms and fills rocky walls on both sides of a 300-stud-wide
-- corridor centred on X=0.  Players start at the south end (Z≈−290), AI at
-- the north end (Z≈+290).

function TerrainManager.generateLane()
	terrainPlan = nil
	if obstaclesFolder then obstaclesFolder:Destroy(); obstaclesFolder = nil end
	Terrain:Clear()
	fillBaseGround()

	obstaclesFolder        = Instance.new("Folder")
	obstaclesFolder.Name   = "TerrainObstacles"
	obstaclesFolder.Parent = workspace

	local LANE_HALF = 150                       -- half-width of the open lane
	local WALL_FILL = HALF - LANE_HALF          -- 282 studs wide per rock wall
	local WALL_CX   = LANE_HALF + WALL_FILL / 2 -- centre X of each wall  (291)
	local WALL_H    = 26
	local totalH    = WALL_H + 12
	local centerY   = (WALL_H - 12) / 2

	-- East rocky wall
	Terrain:FillBlock(
		CFrame.new(WALL_CX, centerY, 0),
		Vector3.new(WALL_FILL, totalH, HALF * 2 + 40),
		Enum.Material.Rock
	)
	addObstacle(WALL_CX, 0, WALL_FILL / 2, HALF + 20, WALL_H)

	-- West rocky wall
	Terrain:FillBlock(
		CFrame.new(-WALL_CX, centerY, 0),
		Vector3.new(WALL_FILL, totalH, HALF * 2 + 40),
		Enum.Material.Rock
	)
	addObstacle(-WALL_CX, 0, WALL_FILL / 2, HALF + 20, WALL_H)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function TerrainManager.clear()
	terrainPlan = nil
	if obstaclesFolder then obstaclesFolder:Destroy(); obstaclesFolder = nil end
	Terrain:Clear()
	fillBaseGround()
end

-- Surface height (world Y) at an XZ position — the actual terrain top a structure,
-- tree or unit rests on. GROUND_TOP = ground, L1_TOP = natural plateau, L2_TOP =
-- main plateau; ramps interpolate. Matches the generated voxels (and downward
-- raycasts) so analytic placement and ray-based ground-snapping stay in lockstep.
function TerrainManager.heightAt(x: number, z: number): number
	local plan = terrainPlan
	if not plan then return GROUND_TOP end

	-- Convert to plan coords (a = cross axis, b = symmetry axis); the layout is
	-- symmetric in b, so test against |b|.
	local a, b
	if plan.mirrorZ then a, b = x, z else a, b = z, x end
	local bb = math.abs(b)

	-- Main plateau (highest) — checked first since it sits inside L1.
	if math.abs(a) <= plan.l2sa / 2
		and bb >= plan.l2b - plan.l2sb / 2 and bb <= plan.l2b + plan.l2sb / 2 then
		return L2_TOP
	end
	-- L1 → L2 ramps (in front of the main plateau, on the L1 surface).
	for _, off in plan.l2Ramps do
		if math.abs(a - off) <= plan.l2RampW / 2
			and bb >= plan.l2Face - RAMP_D and bb <= plan.l2Face then
			local t = (bb - (plan.l2Face - RAMP_D)) / RAMP_D
			return L1_TOP + t * STEP
		end
	end
	-- Natural plateau.
	if math.abs(a) <= plan.l1sa / 2
		and bb >= plan.l1b - plan.l1sb / 2 and bb <= plan.l1b + plan.l1sb / 2 then
		return L1_TOP
	end
	-- L0 → L1 ramps.
	for _, off in plan.l1Ramps do
		if math.abs(a - off) <= plan.l1RampW / 2
			and bb >= plan.l1Face - RAMP_D and bb <= plan.l1Face then
			local t = (bb - (plan.l1Face - RAMP_D)) / RAMP_D
			return GROUND_TOP + t * STEP
		end
	end
	return GROUND_TOP
end

-- Returns true if a box centred at pos.X/pos.Z with the given half-extents
-- overlaps any terrain obstacle Part.  Used by BuildingManager and BuildingPlacer.
function TerrainManager.isPositionBlocked(pos: Vector3, halfW: number, halfD: number): boolean
	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return false end
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		if math.abs(pos.X - part.Position.X) < halfW + part.Size.X / 2
			and math.abs(pos.Z - part.Position.Z) < halfD + part.Size.Z / 2 then
			return true
		end
	end
	return false
end

return TerrainManager
