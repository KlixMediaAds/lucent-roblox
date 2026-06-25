--[[
	BuildField — "The Construction Field"

	Unified placement feedback for build-zone placement. Replaces the thin flat
	build-zone ring + ambiguous red ghost with one coherent system.

	Governing rule:  STEADY cues show state, MOTION only fires on events.
	Anything that animates means something just happened — so movement is always
	signal, never decoration.

	Layers
	  • Field   (where)   : a translucent blueprint deck disc draped on each zone's
	                        terrain tier + a global placement dim so the lit field
	                        pops (the dim is driven by BuildingPlacer's CCE).
	  • Edge    (the wall): a vertical neon wall that follows terrain height around
	                        the merged perimeter. Reuses the same arc-segment merge
	                        as RangeRing.createBuildZone so CC + Relay zones fuse.
	  • Cursor  (here?)   : the footprint stamp — the building's true-size base rect
	                        projected on the ground + corner brackets, coloured
	                        green / gray / red.
	  • Events            : a one-shot radar sweep on power-on / relay-extend, and a
	                        force-field flare on the wall when the cursor crosses out.

	Public API
	  BuildField.show(zones, tint)         zones = { {cx,cz,radius} }
	  BuildField.hide()
	  BuildField.setStamp(cx, cz, y, sizeX, sizeZ, state)   state: "valid"|"blocked"|"illegal"
	  BuildField.hideStamp()
	  BuildField.flareAt(wx, wz)
	  BuildField.sweep()
--]]

local RunService = game:GetService("RunService")

local BuildField = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local WALL_HEIGHT     = 7        -- studs the perimeter wall rises off the terrain
local WALL_THICK      = 0.5
local DECK_Y_OFFSET   = 0.30     -- deck sits this far above the terrain (clears fog tiles)
local WALL_BASE_DROP  = 0.0      -- wall bottom relative to terrain surface
local SEG_TARGET_LEN  = 9        -- aim for ~this many studs per wall segment
local SEG_MIN, SEG_MAX = 24, 64  -- clamp segment count per zone

local FLARE_TIME      = 0.45     -- seconds a wall flare takes to decay
local FLARE_RADIUS    = 14       -- studs around the crossing point that flare
local SWEEP_TIME      = 0.7      -- seconds for one radar sweep revolution

-- State colours
local C_VALID   = Color3.fromRGB(70, 255, 130)
local C_BLOCKED = Color3.fromRGB(180, 184, 196)
local C_ILLEGAL = Color3.fromRGB(255, 72, 72)

-- ── Terrain height probe (matches BuildingPlacer's straight-down raycast) ──────
local terrainRayParams = RaycastParams.new()
terrainRayParams.FilterType = Enum.RaycastFilterType.Include
terrainRayParams.FilterDescendantsInstances = { workspace.Terrain }

local function terrainHeightAt(x: number, z: number): number?
	local result = workspace:Raycast(Vector3.new(x, 250, z), Vector3.new(0, -500, 0), terrainRayParams)
	return result and result.Position.Y or nil
end

-- ── Module state ──────────────────────────────────────────────────────────────
type Zone = { cx: number, cz: number, radius: number }
type WallSeg = { part: Part, wx: number, wz: number, baseTr: number }

local container:  Folder?          = nil   -- holds deck + wall (not the stamp)
local wallSegs:   { WallSeg }      = {}
local zonesRef:   { Zone }         = {}
local tintRef:    Color3           = Color3.fromRGB(120, 200, 255)

-- Active flares: each pulses a single wall segment then clears.
type Flare = { seg: WallSeg, t0: number }
local flares: { Flare } = {}

-- Sweep arm (one-shot)
local sweep: { part: Part, t0: number, cx: number, cz: number, y: number, radius: number }? = nil

-- Footprint stamp (created lazily, reused, never destroyed until hide)
local stampFolder: Folder? = nil
local stampFill:   Part?   = nil
local stampBars:   { Part } = {}    -- 8 thin bars = 4 corner brackets

local loopConn: RBXScriptConnection? = nil

-- ── Deck + wall construction ──────────────────────────────────────────────────
local function segCount(radius: number): number
	local n = math.round(2 * math.pi * radius / SEG_TARGET_LEN)
	return math.clamp(n, SEG_MIN, SEG_MAX)
end

-- True if a point lies inside any zone OTHER than `self`.
local function insideOtherZone(wx: number, wz: number, self: Zone): boolean
	for _, other in zonesRef do
		if other == self then continue end
		local dx, dz = wx - other.cx, wz - other.cz
		if dx * dx + dz * dz < other.radius * other.radius then
			return true
		end
	end
	return false
end

local function buildField()
	local folder = Instance.new("Folder")
	folder.Name  = "_BuildField"
	folder.Parent = workspace
	container = folder

	for _, zone in zonesRef do
		local cx, cz, radius = zone.cx, zone.cz, zone.radius
		local zoneY = terrainHeightAt(cx, cz) or 0

		-- Blueprint deck disc on this zone's tier ----------------------------------
		local deck            = Instance.new("Part")
		deck.Name             = "_Deck"
		deck.Shape            = Enum.PartType.Cylinder
		deck.Size             = Vector3.new(0.2, radius * 2, radius * 2)
		deck.CFrame           = CFrame.new(cx, zoneY + DECK_Y_OFFSET, cz)
		                        * CFrame.Angles(0, 0, math.pi / 2)
		deck.Anchored         = true
		deck.CanCollide       = false
		deck.CanQuery         = false
		deck.CastShadow       = false
		deck.Material         = Enum.Material.Neon
		deck.Color            = tintRef
		deck.Transparency     = 0.9
		deck.Parent           = folder

		-- Terrain-draped perimeter wall -------------------------------------------
		local n      = segCount(radius)
		local arcLen = 2 * math.pi * radius / n + 0.15
		for i = 0, n - 1 do
			local angle = i * 2 * math.pi / n
			local cosA, sinA = math.cos(angle), math.sin(angle)
			local wx = cx + cosA * radius
			local wz = cz + sinA * radius
			if insideOtherZone(wx, wz, zone) then continue end

			local segY = terrainHeightAt(wx, wz) or zoneY
			local seg  = Instance.new("Part")
			seg.Name         = "_Wall"
			seg.Size         = Vector3.new(arcLen, WALL_HEIGHT, WALL_THICK)
			seg.Anchored     = true
			seg.CanCollide   = false
			seg.CanQuery     = false
			seg.CastShadow   = false
			seg.Material     = Enum.Material.Neon
			seg.Color        = tintRef
			seg.Transparency = 0.55
			-- X axis = tangent, Y = up, sits with its base on the terrain surface.
			seg.CFrame = CFrame.fromMatrix(
				Vector3.new(wx, segY + WALL_BASE_DROP + WALL_HEIGHT / 2, wz),
				Vector3.new(-sinA, 0, cosA),
				Vector3.new(0, 1, 0)
			)
			seg.Parent = folder
			table.insert(wallSegs, { part = seg, wx = wx, wz = wz, baseTr = 0.55 })
		end
	end
end

-- ── Footprint stamp ────────────────────────────────────────────────────────────
local function makeBar(parent: Instance): Part
	local p        = Instance.new("Part")
	p.Name         = "_Bracket"
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CastShadow   = false
	p.Material     = Enum.Material.Neon
	p.Transparency = 0.1
	p.Parent       = parent
	return p
end

local function ensureStamp()
	if stampFolder then return end
	local folder = Instance.new("Folder")
	folder.Name  = "_BuildStamp"
	folder.Parent = workspace
	stampFolder = folder

	local fill        = Instance.new("Part")
	fill.Name         = "_StampFill"
	fill.Anchored     = true
	fill.CanCollide   = false
	fill.CanQuery     = false
	fill.CastShadow   = false
	fill.Material     = Enum.Material.Neon
	fill.Transparency = 0.62
	fill.Parent       = folder
	stampFill = fill

	for _ = 1, 8 do
		table.insert(stampBars, makeBar(folder))
	end
end

-- Bracket arm length as a fraction of the shorter footprint side.
local BRACKET_FRAC = 0.32
local BRACKET_THICK = 0.5

function BuildField.setStamp(cx: number, cz: number, y: number, sizeX: number, sizeZ: number, state: string)
	ensureStamp()
	local colour = state == "valid"   and C_VALID
		or state == "blocked" and C_BLOCKED
		or C_ILLEGAL

	local fill = stampFill :: Part
	fill.Size   = Vector3.new(sizeX, 0.15, sizeZ)
	fill.CFrame = CFrame.new(cx, y, cz)
	fill.Color  = colour

	local halfX, halfZ = sizeX / 2, sizeZ / 2
	local armX = math.min(halfX, sizeX * BRACKET_FRAC)
	local armZ = math.min(halfZ, sizeZ * BRACKET_FRAC)
	local by   = y + 0.1

	-- Four corners, each an L made of two bars (X-arm + Z-arm).
	local corners = {
		{ -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 },
	}
	for ci, c in corners do
		local sx, sz = c[1], c[2]
		local cornerX = cx + sx * halfX
		local cornerZ = cz + sz * halfZ

		-- X-direction arm (runs inward along X from the corner)
		local bx = stampBars[(ci - 1) * 2 + 1]
		bx.Size  = Vector3.new(armX, 0.2, BRACKET_THICK)
		bx.CFrame = CFrame.new(cornerX - sx * armX / 2, by, cornerZ)
		bx.Color = colour

		-- Z-direction arm (runs inward along Z from the corner)
		local bz = stampBars[(ci - 1) * 2 + 2]
		bz.Size  = Vector3.new(BRACKET_THICK, 0.2, armZ)
		bz.CFrame = CFrame.new(cornerX, by, cornerZ - sz * armZ / 2)
		bz.Color = colour
	end

	(stampFolder :: Folder).Parent = workspace  -- ensure visible after hideStamp()
end

function BuildField.hideStamp()
	if stampFolder then stampFolder.Parent = nil end
end

-- ── Events: flare + sweep ──────────────────────────────────────────────────────
function BuildField.flareAt(wx: number, wz: number)
	if #wallSegs == 0 then return end
	local now = os.clock()
	for _, seg in wallSegs do
		local dx, dz = seg.wx - wx, seg.wz - wz
		if dx * dx + dz * dz <= FLARE_RADIUS * FLARE_RADIUS then
			table.insert(flares, { seg = seg, t0 = now })
		end
	end
end

function BuildField.sweep()
	if #zonesRef == 0 then return end
	-- Sweep from the largest zone (the CC) so the arm spans the full reach.
	local big = zonesRef[1]
	for _, z in zonesRef do
		if z.radius > big.radius then big = z end
	end
	if sweep and sweep.part.Parent then sweep.part:Destroy() end

	local y    = (terrainHeightAt(big.cx, big.cz) or 0) + DECK_Y_OFFSET + 0.05
	local part = Instance.new("Part")
	part.Name         = "_Sweep"
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CastShadow   = false
	part.Material     = Enum.Material.Neon
	part.Color        = tintRef
	part.Transparency = 0.2
	part.Size         = Vector3.new(big.radius, 0.18, 1.4)
	part.Parent       = container or workspace

	sweep = { part = part, t0 = os.clock(), cx = big.cx, cz = big.cz, y = y, radius = big.radius }
end

-- ── Animation loop (events + gentle wall breathing) ───────────────────────────
local function step()
	local now = os.clock()

	-- Wall breathing (steady, very subtle — reads as "powered", not noisy)
	local breathe = math.sin(now * 1.6) * 0.06
	for _, seg in wallSegs do
		seg.part.Transparency = seg.baseTr + breathe
	end

	-- Flares: brighten + grow the segment, decaying to its base.
	for i = #flares, 1, -1 do
		local f = flares[i]
		local k = (now - f.t0) / FLARE_TIME
		if k >= 1 then
			f.seg.part.Transparency = f.seg.baseTr + breathe
			f.seg.part.Size = Vector3.new(f.seg.part.Size.X, WALL_HEIGHT, WALL_THICK)
			table.remove(flares, i)
		else
			local e = 1 - k                     -- 1 → 0
			f.seg.part.Transparency = math.max(0, f.seg.baseTr - 0.5 * e)
			f.seg.part.Size = Vector3.new(f.seg.part.Size.X, WALL_HEIGHT * (1 + 0.6 * e), WALL_THICK)
		end
	end

	-- Radar sweep: one revolution, fading out.
	if sweep then
		local k = (now - sweep.t0) / SWEEP_TIME
		if k >= 1 then
			sweep.part:Destroy()
			sweep = nil
		else
			local angle = k * 2 * math.pi
			local cosA, sinA = math.cos(angle), math.sin(angle)
			local dir = Vector3.new(cosA, 0, sinA)
			local mid = Vector3.new(sweep.cx + cosA * sweep.radius / 2, sweep.y, sweep.cz + sinA * sweep.radius / 2)
			sweep.part.CFrame = CFrame.fromMatrix(mid, dir, Vector3.new(0, 1, 0))
			sweep.part.Transparency = 0.2 + 0.6 * k
		end
	end
end

-- ── Show / hide ────────────────────────────────────────────────────────────────
function BuildField.show(zones: { Zone }, tint: Color3?)
	BuildField.hide()
	zonesRef = zones
	tintRef  = tint or tintRef
	if #zonesRef == 0 then return end

	buildField()
	loopConn = RunService.RenderStepped:Connect(step)
	BuildField.sweep()
end

function BuildField.hide()
	if loopConn then loopConn:Disconnect(); loopConn = nil end
	if sweep and sweep.part.Parent then sweep.part:Destroy() end
	sweep = nil
	flares = {}
	wallSegs = {}
	zonesRef = {}
	if container then container:Destroy(); container = nil end
	-- Destroy the stamp entirely on hide (rebuilt lazily next session).
	if stampFolder then stampFolder:Destroy(); stampFolder = nil end
	stampFill = nil
	stampBars = {}
end

function BuildField.isShown(): boolean
	return container ~= nil
end

return BuildField
