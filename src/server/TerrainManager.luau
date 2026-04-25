--!strict
--[[
    TerrainManager v2 — Starcraft-style structured map terrain.

    Symmetry: X-axis reflection.  Everything generated for the top half
    (z > 0) is mirrored to the bottom half (z → -z), giving both players
    structurally identical environments.

    Map layout (one half):

        ┌──────────────────────────────────────────┐
        │ [L-WALL] corner           corner [L-WALL] │  ← enclosed base pockets
        │                                            │
        │       [side slab]     [side slab]          │  ← extra corridor detail
        │                                            │
        │ ████████████████  gap  ████████████████   │  ← choke wall pair
        │                                            │
        │               open center                  │
        └────────────────── z=0 ────────────────────┘  (mirror line)

    Structural elements per half (mirrored to other half → 16 Parts total):
      • 2 corner L-enclosures  × 2 pieces each = 4 pieces  (one per map corner)
      • 1 choke wall pair                       = 2 pieces  (full-width minus gap)
      • 2 side pocket slabs                     = 2 pieces  (mid-corridor detail)

    All obstacles: CanCollide = false.  Building-placement and unit-movement
    enforcement is done entirely in code.
]]

local TerrainManager = {}

local obstaclesFolder: Folder? = nil
local HALF       = 432   -- map half-extent in studs  (matches WORLD_HALF everywhere)
local OBS_HEIGHT = 16    -- all terrain pieces this tall

-- ── Part factory ─────────────────────────────────────────────────────────────

local function makePart(cx: number, cz: number, hw: number, hd: number)
    local part            = Instance.new("Part")
    part.Name             = "TerrainObstacle"
    part.Size             = Vector3.new(math.max(hw * 2, 1), OBS_HEIGHT, math.max(hd * 2, 1))
    part.CFrame           = CFrame.new(cx, OBS_HEIGHT / 2, cz)
    part.Material         = Enum.Material.Rock
    part.BrickColor       = BrickColor.new("Slate grey")
    part.Anchored         = true
    part.CanCollide       = false
    part.CanQuery         = false
    part.CastShadow       = true
    part.Parent           = obstaclesFolder
end

-- ── Generation ───────────────────────────────────────────────────────────────

function TerrainManager.generate(seed: number?)
    TerrainManager.clear()

    obstaclesFolder        = Instance.new("Folder")
    obstaclesFolder.Name   = "TerrainObstacles"
    obstaclesFolder.Parent = workspace

    local rng = Random.new(seed or math.floor(os.clock() * 7919))

    -- Convenience: random value centred on `base` with ±`spread`.
    local function r(base: number, spread: number): number
        return base + rng:NextNumber(-spread, spread)
    end

    -- Pieces defined for the TOP half (z > 0); each is auto-mirrored to z < 0.
    type Piece = { cx: number, cz: number, hw: number, hd: number }
    local half: { Piece } = {}

    -- ── 1. Corner L-enclosures ────────────────────────────────────────────
    --
    -- Each corner gets two pieces forming an L open toward the map centre.
    -- The horizontal cap seals the far edge; the vertical slab runs down
    -- the side, leaving an opening that faces inward.
    --
    --   cap:  ██████████████████
    --   slab: ██
    --         ██
    --         ██                ← opening here (unit can enter from below/right)
    --
    -- Left corner L (top-left when looking down):
    local capCZ   = r(375, 12)          -- cap sits near the top edge
    local capHW   = r(115, 12)          -- how far inward the cap reaches
    local capHD   = r(18,   3)
    local capCX   = -(HALF - capHW)     -- cap's right edge at roughly -HALF, left at ~-HALF+2*capHW

    local slabCX  = r(-410,  8)         -- slab hugs the left edge
    local slabCZ  = r(295,  15)         -- slab centre; top end ≈ capCZ, bottom ~= slabCZ - slabHD
    local slabHW  = r( 16,   3)
    local slabHD  = r( 80,  10)         -- bottom edge stays safely above the choke

    -- Left corner
    table.insert(half, { cx =  capCX,  cz = capCZ,  hw = capHW,  hd = capHD  })
    table.insert(half, { cx =  slabCX, cz = slabCZ, hw = slabHW, hd = slabHD })
    -- Right corner (mirror X)
    table.insert(half, { cx = -capCX,  cz = capCZ,  hw = capHW,  hd = capHD  })
    table.insert(half, { cx = -slabCX, cz = slabCZ, hw = slabHW, hd = slabHD })

    -- ── 2. Full-width choke wall pair ─────────────────────────────────────
    --
    -- Two long horizontal walls that span the entire map width, broken only
    -- by a central gap.  Units must funnel through that gap to cross between
    -- the two halves — exactly like a Starcraft natural choke.
    --
    --   ████████████████  [gap]  ████████████████
    --
    local chokeZ    = r(130, 20)        -- how far from z=0 the choke sits
    local chokeHD   = r(16,   3)        -- wall thickness (Z direction)
    local gapHalf   = r(80,  12)        -- half-width of the central opening
    --   Each wall's half-width  = (HALF - gapHalf) / 2   (so two walls + gap = full map)
    --   Each wall's centre X    = ±(gapHalf + chokeHW)  = ±(gapHalf + (HALF-gapHalf)/2)
    --                           = ±(gapHalf/2 + HALF/2) = ±(HALF + gapHalf) / 2
    local chokeHW   = (HALF - gapHalf) / 2
    local chokeCX   = (HALF + gapHalf) / 2   -- centre of RIGHT wall (positive)

    table.insert(half, { cx = -chokeCX, cz = chokeZ, hw = chokeHW, hd = chokeHD })
    table.insert(half, { cx =  chokeCX, cz = chokeZ, hw = chokeHW, hd = chokeHD })

    -- ── 3. Side pocket slabs ──────────────────────────────────────────────
    --
    -- Thin vertical slabs placed along the edges between the corner L and the
    -- choke wall.  They pinch the side corridor slightly, creating secondary
    -- choke-like passages on the flanks and breaking up long straight runs.
    --
    local pocketX   = r(385, 15)        -- close to the side edge
    local pocketCZ  = r(225, 20)        -- between choke (z≈130) and corner slab
    local pocketHW  = r( 14,  3)        -- thin in X
    local pocketHD  = r( 55, 10)        -- moderate height in Z

    table.insert(half, { cx = -pocketX, cz = pocketCZ, hw = pocketHW, hd = pocketHD })
    table.insert(half, { cx =  pocketX, cz = pocketCZ, hw = pocketHW, hd = pocketHD })

    -- ── 4. Centre accent rocks ────────────────────────────────────────────
    --
    -- A few rocks in the open centre area (below the choke) give units
    -- something to hide behind in mid-map battles.
    local accentCount = rng:NextInteger(2, 4)
    for _ = 1, accentCount do
        local ax = rng:NextNumber(-160, 160)
        local az = r(55, 30)   -- safely below the choke: z ≈ 25–85
        table.insert(half, { cx = ax, cz = az, hw = r(16, 5), hd = r(11, 4) })
    end

    -- ── Place everything: top half + mirrored bottom half ─────────────────
    for _, p in half do
        makePart( p.cx,  p.cz, p.hw, p.hd)   -- top half  (z > 0)
        makePart( p.cx, -p.cz, p.hw, p.hd)   -- bottom half (z < 0)
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function TerrainManager.clear()
    if obstaclesFolder then
        obstaclesFolder:Destroy()
        obstaclesFolder = nil
    end
end

-- Returns true if a box centred at pos.X / pos.Z with the given half-extents
-- overlaps any terrain obstacle.  Used by BuildingManager and BuildingPlacer.
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
