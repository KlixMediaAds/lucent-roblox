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

-- Materials: grass floor + cap, rock cliff bodies. (No biomes — fixed look.)
local GROUND_MAT = Enum.Material.Grass
local CLIFF_MAT  = Enum.Material.Rock
local CAP_MAT    = Enum.Material.Grass

-- ── Base ground ───────────────────────────────────────────────────────────────
-- Mirrors the fill in init.server.luau.  Called after Terrain:Clear() to restore
-- the flat grass floor so the rest of the game is unaffected.

local function fillBaseGround(mat: Enum.Material?)
	Terrain:FillBlock(
		CFrame.new(0, -8, 0),
		Vector3.new(960, 8, 960),
		mat or Enum.Material.Grass
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

	-- Axis: lay the tiers across either the world X or Z axis. We author the layout
	-- in plan coords (a = cross axis, b = symmetry/depth axis) and map them to world.
	local mirrorZ = rng:NextInteger(1, 2) == 1
	-- Symmetry: "mirror" reflects the +b half straight across to −b (both mains on
	-- the same side); "rotate" is 180° point-symmetry (a flips too → the two mains
	-- sit on opposite flanks, a diagonal map). Both are perfectly fair.
	local symMode = rng:NextInteger(1, 2) == 1 and "mirror" or "rotate"
	local function aSign(half: number): number
		return symMode == "rotate" and half or 1
	end

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

	-- A raised plateau: rock cliff column with a thin grass cap on top.
	local function fillTier(a: number, b: number, sa: number, sb: number, topY: number)
		local bodyTop = topY - CAP
		Terrain:FillBlock(
			CFrame.new(worldPos(a, b, (BODY_BOTTOM + bodyTop) / 2)),
			planSize(sa, sb, bodyTop - BODY_BOTTOM),
			CLIFF_MAT
		)
		Terrain:FillBlock(
			CFrame.new(worldPos(a, b, topY - CAP / 2)),
			planSize(sa, sb, CAP),
			CAP_MAT
		)
	end

	-- A grass ramp leaning on a plateau's front cliff, descending RAMP_D studs toward
	-- map centre from the cliff edge (faceB) to the lower level. `a` is already world-
	-- signed by the caller.
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
			CAP_MAT
		)
	end

	-- Randomised ramp offsets along a plateau's width, centred on `center`:
	-- sometimes a single ramp, sometimes a flanking pair, sometimes a wide trio.
	local function rampOffsets(center: number, sa: number): { number }
		local roll = rng:NextInteger(1, 5)
		if roll <= 2 then
			return { center + r(0, sa * 0.18) }
		elseif roll <= 4 then
			local d = r(sa * 0.30, sa * 0.06)
			return { center - d, center + d }
		else
			local d = r(sa * 0.34, sa * 0.05)
			return { center - d, center + r(0, sa * 0.08), center + d }
		end
	end

	-- ── Layout (authored for the +b half) ──────────────────────────────────────
	-- Level 1: wide natural plateau, centred. Deep enough that its back edge clears
	-- the L2 plateau so L2 sits fully on it. Wider size jitter than before.
	local l1b, l1sa, l1sb = r(235, 16), r(560, 55), r(330, 30)
	-- Level 2: smaller main plateau on the back of L1, now allowed to slide left or
	-- right (l2a) instead of always sitting dead centre.
	local l2sa, l2sb = r(360, 55), r(150, 22)
	local l2b        = r(305, 16)
	-- Keep the offset main inside L1's width with a margin for its ramps.
	local l2aMax     = math.max(0, (l1sa - l2sa) / 2 - 30)
	local l2a        = rng:NextNumber(-l2aMax, l2aMax)

	local l1RampW, l2RampW = r(42, 6), r(40, 6)
	local l1Ramps = rampOffsets(0,   l1sa)   -- L1 is centred
	local l2Ramps = rampOffsets(l2a, l2sa)   -- L2 ramps track its offset

	local l1Face = l1b - l1sb / 2   -- L1 front cliff (faces centre)
	local l2Face = l2b - l2sb / 2   -- L2 front cliff (sits on the L1 surface)

	-- Remember the layout so heightAt() can place things on the right level.
	terrainPlan = {
		mirrorZ = mirrorZ, symMode = symMode,
		l1b = l1b, l1sa = l1sa, l1sb = l1sb,
		l2b = l2b, l2sa = l2sa, l2sb = l2sb, l2a = l2a,
		l1Ramps = l1Ramps, l2Ramps = l2Ramps,
		l1RampW = l1RampW, l2RampW = l2RampW,
		l1Face = l1Face, l2Face = l2Face,
	}

	for _, half in { 1, -1 } do
		local sA = aSign(half)
		fillTier(0,          l1b * half, l1sa, l1sb, L1_TOP)
		fillTier(l2a * sA,   l2b * half, l2sa, l2sb, L2_TOP)

		for _, off in l1Ramps do
			fillRamp(off * sA, l1Face, l1RampW, half, GROUND_TOP, L1_TOP)
		end
		for _, off in l2Ramps do
			fillRamp(off * sA, l2Face, l2RampW, half, L1_TOP, L2_TOP)
		end
	end

	print(string.format("[TerrainManager] grass map — %s symmetry, main offset %d",
		symMode, math.floor(l2a)))
end

-- ── Walled terrain ─────────────────────────────────────────────────────────────
-- A maze-like alternative to the tiered map: instead of ramped plateaus you can walk
-- up, the map is carved by tall winding rock walls (one STEP higher than the ground)
-- topped here and there by lone rock spikes ("specs"). The walls have NO ramps, so
-- units and structures can never mount them — they're pure barriers. Every wall segment
-- is registered as a TerrainObstacle so building placement, the forest, the minimap and
-- (via NavGrid) unit pathing all treat it as solid and route around it. The logical
-- ground stays flat (terrainPlan = nil): everything off the walls sits at GROUND_TOP.

local WALL_TOP    = GROUND_TOP + STEP   -- wall crest — one elevation level up
local WALL_THICK  = 18                  -- wall width (studs); ≥ NavGrid CELL so it blocks cells
local SPEC_CHANCE = 0.10                -- chance a wall vertex sprouts a spike above the crest

-- Keep walls clear of the four corner base spots (mirrors PLAYER_BASES in init.server)
-- so an auto-placed Command Center never lands boxed in by rock.
local BASE_SPOTS = {
	Vector2.new(-120, -280), Vector2.new(120, 280),
	Vector2.new(120, -280), Vector2.new(-120, 280),
}
local BASE_CLEAR = 110

function TerrainManager.generateWalled(seed: number?)
	terrainPlan = nil
	if obstaclesFolder then obstaclesFolder:Destroy(); obstaclesFolder = nil end
	Terrain:Clear()
	fillBaseGround()

	obstaclesFolder        = Instance.new("Folder")
	obstaclesFolder.Name   = "TerrainObstacles"
	obstaclesFolder.Parent = workspace

	local rng = Random.new(seed or math.floor(os.clock() * 7919))
	local mirrorZ = rng:NextInteger(1, 2) == 1   -- reflect the layout across z=0 or x=0
	local LIM = HALF - 24

	local function nearBase(x: number, z: number): boolean
		for _, b in BASE_SPOTS do
			local dx, dz = x - b.X, z - b.Y
			if dx * dx + dz * dz < BASE_CLEAR * BASE_CLEAR then return true end
		end
		return false
	end

	-- Mirror a point across the symmetry axis so both halves of the map match.
	local function mirror(x: number, z: number): (number, number)
		if mirrorZ then return x, -z else return -x, z end
	end

	-- Fill one rock wall segment (rotated to follow the run) + drop a square obstacle
	-- so the analytic blockers see it. Optionally sprout a thin spike at the vertex.
	local function segment(ax: number, az: number, bx: number, bz: number)
		local dx, dz = bx - ax, bz - az
		local segLen = math.sqrt(dx * dx + dz * dz)
		if segLen < 0.5 then return end
		local mx, mz = (ax + bx) / 2, (az + bz) / 2
		local yMid   = (BODY_BOTTOM + WALL_TOP) / 2
		local look   = Vector3.new(mx + dx, yMid, mz + dz)
		Terrain:FillBlock(
			CFrame.lookAt(Vector3.new(mx, yMid, mz), look),
			Vector3.new(WALL_THICK, WALL_TOP - BODY_BOTTOM, segLen + WALL_THICK),
			CLIFF_MAT
		)
		addObstacle(ax, az, WALL_THICK / 2, WALL_THICK / 2, WALL_TOP - GROUND_TOP)
	end

	local function spike(x: number, z: number)
		local specTop = WALL_TOP + rng:NextNumber(STEP * 0.6, STEP * 1.7)
		local w       = rng:NextNumber(4, 7)
		Terrain:FillBlock(
			CFrame.new(x, (BODY_BOTTOM + specTop) / 2, z),
			Vector3.new(w, specTop - BODY_BOTTOM, w),
			CLIFF_MAT
		)
	end

	-- Build one windy wall run from A→B: march along it while wobbling perpendicular
	-- with a sine so it snakes. Each vertex becomes a segment (+ obstacle) and, rarely,
	-- a spike. Skips any stretch that would crowd a base corner. Mirrored for symmetry.
	local function windyRun(ax: number, az: number, bx: number, bz: number)
		local dx, dz = bx - ax, bz - az
		local len    = math.sqrt(dx * dx + dz * dz)
		if len < 1 then return end
		local dirx, dirz   = dx / len, dz / len
		local perpx, perpz = -dirz, dirx
		local steps  = math.max(2, math.floor(len / 12))
		local phase  = rng:NextNumber(0, math.pi * 2)
		local freq   = rng:NextNumber(1.5, 3.2) * math.pi / len
		local amp    = rng:NextNumber(22, 46)

		local pts: { Vector2 } = {}
		for s = 0, steps do
			local t   = s / steps
			local off = math.sin(phase + freq * len * t) * amp
			local px  = math.clamp(ax + dirx * len * t + perpx * off, -LIM, LIM)
			local pz  = math.clamp(az + dirz * len * t + perpz * off, -LIM, LIM)
			table.insert(pts, Vector2.new(px, pz))
		end

		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			if nearBase(a.X, a.Y) or nearBase(b.X, b.Y) then continue end
			-- Original run.
			segment(a.X, a.Y, b.X, b.Y)
			if rng:NextNumber(0, 1) < SPEC_CHANCE then spike(a.X, a.Y) end
			-- Mirrored twin.
			local max, maz = mirror(a.X, a.Y)
			local mbx, mbz = mirror(b.X, b.Y)
			segment(max, maz, mbx, mbz)
			if rng:NextNumber(0, 1) < SPEC_CHANCE then spike(max, maz) end
		end
	end

	-- A handful of runs snaking across the central band (endpoints kept off the corners
	-- and edges). Mirroring doubles them into a fair, symmetric barrier layout.
	local runs = rng:NextInteger(4, 6)
	for _ = 1, runs do
		local ax = rng:NextNumber(-260, 260)
		local az = rng:NextNumber(-210, 210)
		local bx = rng:NextNumber(-260, 260)
		local bz = rng:NextNumber(-210, 210)
		-- Bias toward longer runs so walls actually divide space.
		if (Vector2.new(ax, az) - Vector2.new(bx, bz)).Magnitude < 160 then
			bx = math.clamp(ax + (bx - ax) * 2.4, -260, 260)
			bz = math.clamp(az + (bz - az) * 2.4, -210, 210)
		end
		windyRun(ax, az, bx, bz)
	end

	print(string.format("[TerrainManager] walled map — %d runs, %s symmetry",
		runs, mirrorZ and "z" or "x"))
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

	-- Convert to plan coords (a = cross axis, b = symmetry/depth axis). The two
	-- halves are related by either a straight reflection in b (mirror) or a 180°
	-- point reflection (rotate, which flips a too). Fold the query into the authored
	-- +b half: bb = |b|, and aQ flips sign with b only in rotate mode.
	local a, b
	if plan.mirrorZ then a, b = x, z else a, b = z, x end
	local s  = (b >= 0) and 1 or -1
	local aQ = (plan.symMode == "rotate") and (a * s) or a
	local bb = b * s   -- = |b|

	-- Main plateau (highest) — checked first since it sits inside L1. Offset by l2a.
	if math.abs(aQ - plan.l2a) <= plan.l2sa / 2
		and bb >= plan.l2b - plan.l2sb / 2 and bb <= plan.l2b + plan.l2sb / 2 then
		return L2_TOP
	end
	-- L1 → L2 ramps (in front of the main plateau, on the L1 surface).
	for _, off in plan.l2Ramps do
		if math.abs(aQ - off) <= plan.l2RampW / 2
			and bb >= plan.l2Face - RAMP_D and bb <= plan.l2Face then
			local t = (bb - (plan.l2Face - RAMP_D)) / RAMP_D
			return L1_TOP + t * STEP
		end
	end
	-- Natural plateau (centred).
	if math.abs(aQ) <= plan.l1sa / 2
		and bb >= plan.l1b - plan.l1sb / 2 and bb <= plan.l1b + plan.l1sb / 2 then
		return L1_TOP
	end
	-- L0 → L1 ramps.
	for _, off in plan.l1Ramps do
		if math.abs(aQ - off) <= plan.l1RampW / 2
			and bb >= plan.l1Face - RAMP_D and bb <= plan.l1Face then
			local t = (bb - (plan.l1Face - RAMP_D)) / RAMP_D
			return GROUND_TOP + t * STEP
		end
	end
	return GROUND_TOP
end

-- Actual rendered terrain surface height via a downward raycast — the same
-- surface the client's holograms snap to. heightAt() is an analytic *logical*
-- level (used by NavGrid and the flatness test); its tier boundaries don't line
-- up perfectly with the smoothed voxels, so structures/deposits placed by
-- heightAt could end up buried under a raised tier. Use this for anything that
-- must visually rest on the ground. Falls back to heightAt if the ray misses.
local surfaceRayParams = RaycastParams.new()
surfaceRayParams.FilterType = Enum.RaycastFilterType.Include
surfaceRayParams.FilterDescendantsInstances = { Terrain }

function TerrainManager.surfaceHeightAt(x: number, z: number): number
	local result = workspace:Raycast(Vector3.new(x, 256, z), Vector3.new(0, -512, 0), surfaceRayParams)
	if result then
		return result.Position.Y
	end
	return TerrainManager.heightAt(x, z)
end

-- Returns true if a building footprint centred at (x, z) with the given
-- half-extents sits entirely on one terrain tier — i.e. every corner (plus the
-- centre) resolves to the same analytic level. False means the footprint spans
-- a ramp or a tier boundary. Uses heightAt (not a raycast): the analytic level
-- is perfectly flat across a tier, whereas Roblox's voxel surface is bumpy at
-- the stud level and would make a flat plateau read as "not flat".
local FLAT_EPS = 0.5
function TerrainManager.isFootprintFlat(x: number, z: number, halfX: number, halfZ: number): boolean
	local h0 = TerrainManager.heightAt(x, z)
	local corners = {
		TerrainManager.heightAt(x - halfX, z - halfZ),
		TerrainManager.heightAt(x + halfX, z - halfZ),
		TerrainManager.heightAt(x - halfX, z + halfZ),
		TerrainManager.heightAt(x + halfX, z + halfZ),
	}
	for _, h in corners do
		if math.abs(h - h0) > FLAT_EPS then return false end
	end
	return true
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
