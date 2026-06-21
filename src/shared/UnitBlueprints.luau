--[[
	UnitBlueprints — single source of truth for unit decorator geometry.

	A *blueprint* is a flat list of part specs (size / local-CFrame / colour /
	material / shape) plus a little metadata.  Both consumers build from the
	exact same data, so a unit only ever has to be described once:

	  • Server  (UnitManager)  — instantiates each spec as an Anchored decorator
	    part welded-by-code to the live body, tracked in `unitDecorators` so the
	    Heartbeat can re-apply `bodyCF * spec.cf` every frame as the unit moves.

	  • Preview (UnitVisuals)  — instantiates the same specs around a static body
	    at the origin for the ViewportFrame thumbnail.

	Coordinate convention (matches the rest of the project):
	  • Local space is relative to the body's centre.
	  • −Z is the unit's forward direction.
	  • `spec.color == nil` means "tint with the team colour"; otherwise the
	    fixed Color3 is used verbatim.

	NOT covered here (deliberately bespoke — they diverge between runtime and
	preview, or depend on runtime state):
]]

local UnitBlueprints = {}

-- Named palette (computed once; byte-identical to the old BrickColor literals).
local GREY  = BrickColor.new("Dark stone grey").Color
local BLACK = BrickColor.new("Black").Color
local BRASS = BrickColor.new("Warm Yellow").Color
local WHITE = BrickColor.new("White").Color

local SMOOTH = Enum.Material.SmoothPlastic
local METAL  = Enum.Material.Metal
local NEON   = Enum.Material.Neon

local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

export type PartSpec = {
	size:     Vector3,
	cf:       CFrame,            -- local offset from body centre
	color:    Color3?,           -- nil → use team colour
	material: Enum.Material,
	shape:    Enum.PartType?,    -- nil → Block
	name:     string?,           -- optional instance name (e.g. smokestacks)
}

export type Blueprint = {
	rootTransparent: boolean?,   -- hide the body part (it's a pure pivot)
	healthBarY:      number?,    -- override HealthBar StudsOffset.Y
	parts:           { PartSpec },
}

-- ── Howitzer: steampunk bipedal steam walker ──────────────────────────────────
-- Body root (8×14×8) is an invisible hip pivot; everything visible lives here.
local HOWITZER: Blueprint = {
	rootTransparent = true,
	healthBarY      = 17,
	parts = {
		-- Hip / pelvis plate (connects the mechanical legs)
		{ size = Vector3.new(8.5, 2, 8.5),   cf = CFrame.new(0, 0, 0),      color = GREY,  material = METAL  },
		-- Engine housing (lower torso, below boiler) + front flange
		{ size = Vector3.new(7.5, 4.5, 8),   cf = CFrame.new(0, 3.5, 0),    color = GREY,  material = SMOOTH },
		{ size = Vector3.new(5, 3.5, 1.5),   cf = CFrame.new(0, 3.5, -5),   color = GREY,  material = METAL  },
		-- Main boiler box (the locomotive drum) + brass banding rings
		{ size = Vector3.new(7, 5.5, 8.5),   cf = CFrame.new(0, 8, 0),      color = GREY,  material = SMOOTH },
		{ size = Vector3.new(7.5, 0.7, 0.5), cf = CFrame.new(0, 9.5, 0),    color = BRASS, material = SMOOTH },
		{ size = Vector3.new(7.5, 0.7, 0.5), cf = CFrame.new(0, 6.5, 0),    color = BRASS, material = SMOOTH },
		-- Cockpit armoured box + team-colour observation slit
		{ size = Vector3.new(4.5, 3.5, 2),   cf = CFrame.new(0, 8, -5.3),   color = GREY,  material = METAL  },
		{ size = Vector3.new(4.5, 0.5, 0.2), cf = CFrame.new(0, 8.3, -6.35), color = nil,  material = NEON   },
		-- Smokestacks (rear; upright round chimneys, one taller than the other).
		-- Cylinder length runs along local X, so rotate Z by 90° to stand upright.
		{ size = Vector3.new(7, 1.6, 1.6),   cf = CFrame.new(-2, 13, 3)   * CFrame.Angles(0, 0, math.pi / 2), color = BLACK, material = SMOOTH, shape = CYL, name = "_HwStack1" },
		{ size = Vector3.new(5.5, 1.3, 1.3), cf = CFrame.new(-0.3, 12.3, 2) * CFrame.Angles(0, 0, math.pi / 2), color = BLACK, material = SMOOTH, shape = CYL, name = "_HwStack2" },
		-- Cannon mount + dual steam barrels (forward, −Z)
		{ size = Vector3.new(3, 2.5, 3),     cf = CFrame.new(0, 2, -4.5),   color = GREY,  material = METAL  },
		{ size = Vector3.new(0.9, 0.9, 5.5), cf = CFrame.new(-0.85, 2, -7.3), color = GREY, material = METAL  },
		{ size = Vector3.new(0.9, 0.9, 5.5), cf = CFrame.new(0.85, 2, -7.3), color = GREY,  material = METAL  },
		-- Steam feed pipe + horizontal pressure manifold
		{ size = Vector3.new(0.5, 3.5, 0.5), cf = CFrame.new(0, 5, -4),     color = BRASS, material = SMOOTH },
		{ size = Vector3.new(6, 0.5, 0.5),   cf = CFrame.new(0, 7.2, -5.5), color = BRASS, material = SMOOTH },
		-- Vertical side structural braces
		{ size = Vector3.new(0.8, 9, 0.8),   cf = CFrame.new(-4.2, 4.5, 0), color = GREY,  material = METAL  },
		{ size = Vector3.new(0.8, 9, 0.8),   cf = CFrame.new(4.2, 4.5, 0),  color = GREY,  material = METAL  },
		-- Rear exhaust vent
		{ size = Vector3.new(3, 0.6, 0.5),   cf = CFrame.new(0, 5.5, 4.5),  color = GREY,  material = METAL  },
	},
}

-- ── Soldier: upright pill + gun (body is an invisible anchor) ─────────────────
local SOLDIER: Blueprint = {
	rootTransparent = true,
	parts = {
		{ size = Vector3.new(1.5, 2.0, 2.0), cf = CFrame.Angles(0, 0, math.pi / 2), color = nil,  material = SMOOTH, shape = CYL  },
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0,  0.75, 0),          color = nil,  material = SMOOTH, shape = BALL },
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0, -0.75, 0),          color = nil,  material = SMOOTH, shape = BALL },
		{ size = Vector3.new(0.3, 0.25, 1.6), cf = CFrame.new(1.15, 0.15, -0.3),    color = GREY, material = SMOOTH },
	},
}

-- ── Size-dependent blueprints (treads / cross scale with the body) ────────────

local function tankBlueprint(bodySize: Vector3): Blueprint
	local halfX   = bodySize.X / 2 + 0.75
	local offsetY = -(bodySize.Y / 2) + 1.1
	local treadSz = Vector3.new(1.5, 2.2, bodySize.Z + 1.5)
	return {
		parts = {
			{ size = treadSz, cf = CFrame.new(-halfX, offsetY, 0), color = GREY, material = SMOOTH, name = "Tread" },
			{ size = treadSz, cf = CFrame.new( halfX, offsetY, 0), color = GREY, material = SMOOTH, name = "Tread" },
		},
	}
end

local function medicBlueprint(bodySize: Vector3): Blueprint
	local topY = bodySize.Y / 2 + 0.18
	return {
		parts = {
			{ size = Vector3.new(bodySize.X * 0.55, 0.3, 0.7),            cf = CFrame.new(0, topY, 0), color = WHITE, material = SMOOTH },
			{ size = Vector3.new(0.7, 0.3, bodySize.Z * 0.55),            cf = CFrame.new(0, topY, 0), color = WHITE, material = SMOOTH },
		},
	}
end

-- ── Foamer: chunky armored foam-cannon crawler ────────────────────────────────
-- Body root (6×5×7) is an invisible pivot.  The FoamBarrel part is named so that
-- UnitManager can animate its localCF.Y between retracted (0.3) and extended (3.5)
-- during deploy/undeploy.  All other parts are static.
local FOAMER: Blueprint = {
	rootTransparent = true,
	healthBarY      = 6,
	parts = {
		-- Main armored hull (team colour)
		{ size = Vector3.new(6, 2.8, 7),     cf = CFrame.new(0, -0.6, 0),     color = nil,  material = SMOOTH },
		-- Treads (grey)
		{ size = Vector3.new(1.3, 1.8, 7.5), cf = CFrame.new(-3.65, -1.5, 0), color = GREY, material = SMOOTH },
		{ size = Vector3.new(1.3, 1.8, 7.5), cf = CFrame.new( 3.65, -1.5, 0), color = GREY, material = SMOOTH },
		-- Front slope armour plate
		{ size = Vector3.new(5.5, 2.5, 0.5), cf = CFrame.new(0, -0.3, -3.7),  color = GREY, material = METAL  },
		-- Top deck
		{ size = Vector3.new(4, 0.35, 5.5),  cf = CFrame.new(0, 0.85, 0),     color = GREY, material = METAL  },
		-- Central barrel housing (dome the cannon rises from)
		{ size = Vector3.new(3, 1.5, 3),     cf = CFrame.new(0, 1.55, 0),     color = GREY, material = METAL  },
		-- Dome ring (team colour neon — glows when deployed)
		{ size = Vector3.new(3.5, 0.4, 3.5), cf = CFrame.new(0, 2.35, 0),     color = nil,  material = NEON   },
		-- Side neon accent strips (team colour)
		{ size = Vector3.new(0.2, 1.5, 5.5), cf = CFrame.new(-2.9, 0.2, 0),   color = nil,  material = NEON   },
		{ size = Vector3.new(0.2, 1.5, 5.5), cf = CFrame.new( 2.9, 0.2, 0),   color = nil,  material = NEON   },
		-- Foam cannon barrel — retracted (Y centre = 0.3, flush inside housing).
		-- UnitManager animates localCF.Y between 0.3 (retracted) and 3.5 (deployed).
		{ size = Vector3.new(1.0, 2.5, 1.0), cf = CFrame.new(0, 0.3, 0),      color = GREY, material = METAL, name = "FoamBarrel" },
	},
}

-- ── Core: compact deploy rover ─────────────────────────────────────────────────
-- The mobile "seed" that drops in and later transforms into the Command Center.
-- Body root (5×3×6) is the visible chassis; a glowing reactor orb rides on top so
-- it reads as a miniature Fabricator Core. −Z is forward.
local CORE: Blueprint = {
	healthBarY = 4,
	parts = {
		-- Lower hull skirt (dark metal) wrapping the team-coloured chassis
		{ size = Vector3.new(5.4, 1.1, 6.2), cf = CFrame.new(0, -0.9, 0),     color = GREY,  material = METAL  },
		-- Angled front prow
		{ size = Vector3.new(4.2, 1.2, 1.6), cf = CFrame.new(0, -0.3, -3),    color = GREY,  material = METAL  },
		-- Reactor housing disc (team colour) + neon core orb on top
		{ size = Vector3.new(1.0, 2.6, 2.6), cf = CFrame.new(0, 1.7, 0.2) * CFrame.Angles(0, 0, math.pi / 2), color = nil, material = METAL, shape = CYL },
		{ size = Vector3.new(1.7, 1.7, 1.7), cf = CFrame.new(0, 2.6, 0.2),    color = nil,   material = NEON,   shape = BALL },
		-- Forward sensor antenna + tip light
		{ size = Vector3.new(0.25, 2.2, 0.25), cf = CFrame.new(1.4, 2.4, -2), color = GREY,  material = METAL  },
		{ size = Vector3.new(0.55, 0.55, 0.55), cf = CFrame.new(1.4, 3.4, -2), color = nil,  material = NEON,   shape = BALL },
		-- Four stubby wheels — an unrotated Cylinder's axle already runs along local
		-- X (left/right), so they read as wheels rolling in the −Z forward direction.
		{ size = Vector3.new(1.0, 1.8, 1.8), cf = CFrame.new(-2.5, -1.1, -1.9), color = BLACK, material = SMOOTH, shape = CYL },
		{ size = Vector3.new(1.0, 1.8, 1.8), cf = CFrame.new( 2.5, -1.1, -1.9), color = BLACK, material = SMOOTH, shape = CYL },
		{ size = Vector3.new(1.0, 1.8, 1.8), cf = CFrame.new(-2.5, -1.1,  1.9), color = BLACK, material = SMOOTH, shape = CYL },
		{ size = Vector3.new(1.0, 1.8, 1.8), cf = CFrame.new( 2.5, -1.1,  1.9), color = BLACK, material = SMOOTH, shape = CYL },
	},
}

-- ── Public API ────────────────────────────────────────────────────────────────

--[[
	Returns the blueprint for `unitType` (or nil if the unit has no static
	blueprint and is built by a bespoke routine).  `bodySize` is required for
	the size-dependent blueprints (Tank treads, Medic cross).
]]
function UnitBlueprints.get(unitType: string, bodySize: Vector3): Blueprint?
	if unitType == "Howitzer" then return HOWITZER end
	if unitType == "Soldier"  then return SOLDIER  end
	if unitType == "Tank"     then return tankBlueprint(bodySize)  end
	if unitType == "Medic"    then return medicBlueprint(bodySize) end
	if unitType == "Foamer"   then return FOAMER   end
	if unitType == "Core"     then return CORE     end
	return nil
end

--[[
	Instantiates a single spec as an Anchored, non-colliding Part.  The caller
	is responsible for parenting and (on the server) decorator tracking.
	`bodyCF` is the body's world CFrame (identity for previews at the origin);
	`teamColor` is used wherever `spec.color` is nil.
]]
function UnitBlueprints.instantiate(spec: PartSpec, bodyCF: CFrame, teamColor: Color3): Part
	local p      = Instance.new("Part")
	if spec.shape then (p :: any).Shape = spec.shape end
	if spec.name  then p.Name = spec.name end
	p.Size       = spec.size
	p.Color      = spec.color or teamColor
	p.Material   = spec.material
	p.Anchored   = true
	p.CanCollide = false
	p.CastShadow = false
	p.CanQuery   = false
	p.CFrame     = bodyCF * spec.cf
	return p
end

return UnitBlueprints
