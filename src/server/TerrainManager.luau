--!strict
--[[
	TerrainManager v3 — Roblox Terrain grass platforms with smooth ramps.

	Symmetry: Z reflection.  Platforms defined for z > 0 are mirrored to z < 0.

	Layout (one half, z > 0):
	  • West + East flank platforms — 1 ramp each, elevated corridor blockers
	  • Center-left + Center-right choke plateaux — 2 ramps each, with a
	    ~160-stud ground-level gap between them for units to pass through

	Invisible BaseParts in TerrainObstacles preserve the isPositionBlocked API
	used by BuildingManager / BuildingPlacer.
]]

local TerrainManager = {}

local Terrain         = workspace.Terrain
local obstaclesFolder: Folder? = nil

local HALF   = 432  -- map half-extent (studs)
local PLAT_H = 10   -- platform height above Y=0
local RAMP_D = 20   -- horizontal depth of each ramp

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

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Invisible Part added to TerrainObstacles so code-level placement/movement
-- checks (isPositionBlocked) still see elevated terrain as blocked.
local function addObstacle(cx: number, cz: number, hw: number, hd: number)
	local p           = Instance.new("Part")
	p.Name            = "TerrainObstacle"
	p.Size            = Vector3.new(hw * 2, PLAT_H, hd * 2)
	p.CFrame          = CFrame.new(cx, PLAT_H / 2, cz)
	p.Anchored        = true
	p.CanCollide      = false
	p.CanQuery        = false
	p.Transparency    = 1
	p.CastShadow      = false
	p.Parent          = obstaclesFolder
end

-- Raised grass column that fills from terrain base (Y=-12) up to Y=PLAT_H.
local function fillPlatform(cx: number, cz: number, pw: number, pd: number)
	local totalH  = PLAT_H + 12
	local centerY = (PLAT_H - 12) / 2   -- centres the fill so top = PLAT_H, bottom = -12
	Terrain:FillBlock(
		CFrame.new(cx, centerY, cz),
		Vector3.new(pw, totalH, pd),
		Enum.Material.Grass
	)
end

-- Wedge ramp from ground (Y=0) up to the platform face at highFaceZ.
--   southward = true  → ramp is on the south face of a z>0 platform:
--     high end at highFaceZ (+Z), low end at highFaceZ − RAMP_D (−Z).
--     FillWedge default orientation has full height at local +Z → no rotation needed.
--   southward = false → ramp is on the north face of a mirrored z<0 platform:
--     high end at highFaceZ (−Z), low end at highFaceZ + RAMP_D (+Z).
--     Rotate 180° around Y so the full-height end faces −Z.
local function fillRamp(cx: number, highFaceZ: number, rampW: number, southward: boolean)
	local size = Vector3.new(rampW, PLAT_H, RAMP_D)
	local cf: CFrame
	if southward then
		cf = CFrame.new(cx, PLAT_H / 2, highFaceZ - RAMP_D / 2)
	else
		cf = CFrame.new(cx, PLAT_H / 2, highFaceZ + RAMP_D / 2)
		     * CFrame.Angles(0, math.pi, 0)
	end
	Terrain:FillWedge(cf, size, Enum.Material.Grass)
end

-- ── Generation ────────────────────────────────────────────────────────────────

function TerrainManager.generate(seed: number?)
	-- Clear existing platforms and obstacle markers
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

	type RampSpec = { xOff: number, w: number }
	type PlatSpec = { cx: number, cz: number, pw: number, pd: number, ramps: { RampSpec } }

	-- All platforms defined for the z > 0 half; each is mirrored to z < 0 below.
	local platforms: { PlatSpec } = {

		-- ── West flank ─────────────────────────────────────────────────────
		-- Elevated ledge that narrows the west side corridor without fully sealing it.
		{
			cx    = r(-340, 12),
			cz    = r(220, 15),
			pw    = r(75, 8),
			pd    = r(100, 10),
			ramps = { { xOff = 0, w = r(44, 5) } },
		},

		-- ── East flank (X-mirror of west) ───────────────────────────────────
		{
			cx    = r(340, 12),
			cz    = r(220, 15),
			pw    = r(75, 8),
			pd    = r(100, 10),
			ramps = { { xOff = 0, w = r(44, 5) } },
		},

		-- ── Center-left choke plateau ───────────────────────────────────────
		-- Spans most of the left half; leaves a ~160-stud gap to the right plateau.
		{
			cx    = r(-195, 12),
			cz    = r(135, 12),
			pw    = r(210, 15),
			pd    = r(60, 6),
			ramps = {
				{ xOff = r(-55, 12), w = r(40, 5) },
				{ xOff = r( 55, 12), w = r(40, 5) },
			},
		},

		-- ── Center-right choke plateau (X-mirror) ──────────────────────────
		{
			cx    = r(195, 12),
			cz    = r(135, 12),
			pw    = r(210, 15),
			pd    = r(60, 6),
			ramps = {
				{ xOff = r(-55, 12), w = r(40, 5) },
				{ xOff = r( 55, 12), w = r(40, 5) },
			},
		},
	}

	for _, pl in platforms do
		local southFaceZ = pl.cz - pl.pd / 2  -- z > 0 platform's face toward map centre
		local northFaceZ = -(pl.cz - pl.pd / 2)  -- mirrored platform's face toward map centre

		-- z > 0 half
		fillPlatform(pl.cx,  pl.cz, pl.pw, pl.pd)
		addObstacle(pl.cx,   pl.cz, pl.pw / 2, pl.pd / 2)

		-- z < 0 half
		fillPlatform(pl.cx, -pl.cz, pl.pw, pl.pd)
		addObstacle(pl.cx,  -pl.cz, pl.pw / 2, pl.pd / 2)

		for _, rp in pl.ramps do
			local rx = pl.cx + rp.xOff
			-- Ramps intentionally have NO obstacle Part — units must be free to walk
			-- up them without being repelled by the avoidance system.
			fillRamp(rx,  southFaceZ, rp.w, true)
			fillRamp(rx, -southFaceZ, rp.w, false)
		end
	end
end

-- ── Lane mode terrain ─────────────────────────────────────────────────────────
-- Clears all platforms and fills rocky walls on both sides of a 300-stud-wide
-- corridor centred on X=0.  Players start at the south end (Z≈−290), AI at
-- the north end (Z≈+290).

function TerrainManager.generateLane()
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
	addObstacle(WALL_CX, 0, WALL_FILL / 2, HALF + 20)

	-- West rocky wall
	Terrain:FillBlock(
		CFrame.new(-WALL_CX, centerY, 0),
		Vector3.new(WALL_FILL, totalH, HALF * 2 + 40),
		Enum.Material.Rock
	)
	addObstacle(-WALL_CX, 0, WALL_FILL / 2, HALF + 20)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function TerrainManager.clear()
	if obstaclesFolder then obstaclesFolder:Destroy(); obstaclesFolder = nil end
	Terrain:Clear()
	fillBaseGround()
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
