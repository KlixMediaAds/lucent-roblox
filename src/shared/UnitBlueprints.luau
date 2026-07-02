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
local GHILLIE  = Color3.fromRGB( 58,  70,  44)   -- Sniper's dark camo ghillie wrap / hood
local GUNMETAL = Color3.fromRGB( 38,  40,  46)   -- Sniper's long rifle body

local SMOOTH = Enum.Material.SmoothPlastic
local METAL  = Enum.Material.Metal
local NEON   = Enum.Material.Neon

local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

-- ── Skin tones ────────────────────────────────────────────────────────────────
-- A believable human range (pale → deep). A part flagged `skin = true` is tinted
-- with ONE tone picked per unit (so a soldier's head + hands match each other),
-- plus a touch of HSV jitter so even two same-tone soldiers differ slightly —
-- crowds read as individuals, just like real life.
local SKIN_TONES = {
	Color3.fromRGB(255, 224, 196),
	Color3.fromRGB(241, 194, 159),
	Color3.fromRGB(224, 172, 138),
	Color3.fromRGB(198, 134, 102),
	Color3.fromRGB(161, 102,  72),
	Color3.fromRGB(122,  78,  54),
	Color3.fromRGB( 94,  58,  40),
}
local DEFAULT_SKIN = SKIN_TONES[3]

-- One randomized skin tone, used for every `skin` part on a single unit. Callers
-- compute this once per unit/preview and pass it to `instantiate`.
function UnitBlueprints.randomSkinTone(): Color3
	local base   = SKIN_TONES[math.random(1, #SKIN_TONES)]
	local h, s, v = base:ToHSV()
	h = (h + (math.random() - 0.5) * 0.02) % 1
	s = math.clamp(s + (math.random() - 0.5) * 0.07, 0, 1)
	v = math.clamp(v + (math.random() - 0.5) * 0.07, 0, 1)
	return Color3.fromHSV(h, s, v)
end

export type PartSpec = {
	size:     Vector3,
	cf:       CFrame,            -- local offset from body centre
	color:    Color3?,           -- nil → use team colour
	material: Enum.Material,
	shape:    Enum.PartType?,    -- nil → Block
	name:     string?,           -- optional instance name (e.g. smokestacks)
	skin:     boolean?,          -- true → tint with the unit's per-unit skin tone
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

-- ── Survivor: little trooper — team-coloured body, skin-toned head + arms ──────
-- Body root is an invisible anchor. Stack (bottom→top): legs ball, torso pill,
-- shoulders ball (all team colour = uniform), then a small skin sphere head and
-- two little skin arms reaching forward to grip the rifle held across the chest.
local SOLDIER: Blueprint = {
	rootTransparent = true,
	parts = {
		-- ── Body / uniform (team colour) ─────────────────────────────────────
		{ size = Vector3.new(1.5, 2.0, 2.0), cf = CFrame.Angles(0, 0, math.pi / 2), color = nil, material = SMOOTH, shape = CYL  }, -- torso pill
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0, -0.75, 0),          color = nil, material = SMOOTH, shape = BALL }, -- lower body / legs
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0,  0.75, 0),          color = nil, material = SMOOTH, shape = BALL }, -- chest / shoulders
		-- ── Head (skin) ──────────────────────────────────────────────────────
		-- Named so the gore system can pop it off on a decapitation death.
		{ size = Vector3.new(1.2, 1.2, 1.2), cf = CFrame.new(0, 1.7, 0),            skin = true, material = SMOOTH, shape = BALL, name = "_SoldierHead" }, -- little round head
		-- ── Arms gripping the rifle (skin) ───────────────────────────────────
		{ size = Vector3.new(0.34, 0.34, 1.15), cf = CFrame.new( 0.65, 0.25, -0.45) * CFrame.Angles(0, math.rad(-10), 0), skin = true, material = SMOOTH }, -- right arm
		{ size = Vector3.new(0.34, 0.34, 1.15), cf = CFrame.new(-0.10, 0.25, -0.55) * CFrame.Angles(0, math.rad( 22), 0), skin = true, material = SMOOTH }, -- left arm (reaches across)
		{ size = Vector3.new(0.42, 0.42, 0.42), cf = CFrame.new( 0.50, 0.30, -0.05), skin = true, material = SMOOTH, shape = BALL }, -- rear hand (trigger)
		{ size = Vector3.new(0.42, 0.42, 0.42), cf = CFrame.new( 0.05, 0.30, -1.15), skin = true, material = SMOOTH, shape = BALL }, -- front hand (foregrip)
		-- ── Rifle (held across the front) ────────────────────────────────────
		{ size = Vector3.new(0.30, 0.26, 1.7),  cf = CFrame.new( 0.30, 0.40, -0.70), color = GREY, material = SMOOTH },
	},
}

-- ── Sniper: a marksman kitted differently from the trooper ─────────────────────
-- Same team-coloured trooper base, but draped in a dark ghillie wrap + hood (the
-- "different wear"), and shouldering a long scoped rifle that reads as a sniper at
-- a glance. Body stays team-tinted so allegiance is still readable; the gear + gun
-- are fixed dark colours. −Z is forward; the rifle runs out ahead of the chest.
local SNIPER: Blueprint = {
	rootTransparent = true,
	parts = {
		-- ── Body / uniform (team colour) ─────────────────────────────────────
		{ size = Vector3.new(1.5, 2.0, 2.0), cf = CFrame.Angles(0, 0, math.pi / 2), color = nil, material = SMOOTH, shape = CYL  }, -- torso pill
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0, -0.75, 0),          color = nil, material = SMOOTH, shape = BALL }, -- lower body / legs
		{ size = Vector3.new(2.0, 2.0, 2.0), cf = CFrame.new(0,  0.75, 0),          color = nil, material = SMOOTH, shape = BALL }, -- chest / shoulders
		-- ── Ghillie wrap + hood (fixed dark camo — the distinguishing kit) ────
		{ size = Vector3.new(1.75, 1.55, 1.35), cf = CFrame.new(0, 0.55, 0.45),     color = GHILLIE, material = SMOOTH },              -- cloak hanging off the back
		{ size = Vector3.new(2.15, 0.55, 2.15), cf = CFrame.new(0, 1.05, 0),        color = GHILLIE, material = SMOOTH, shape = BALL }, -- shoulder shroud
		{ size = Vector3.new(1.35, 0.75, 1.35), cf = CFrame.new(0, 2.05, 0.05),     color = GHILLIE, material = SMOOTH, shape = BALL }, -- hood over the crown
		-- ── Head (skin) ──────────────────────────────────────────────────────
		{ size = Vector3.new(1.1, 1.1, 1.1), cf = CFrame.new(0, 1.7, 0),            skin = true, material = SMOOTH, shape = BALL, name = "_SniperHead" }, -- little round head
		-- ── Arms bracing the long rifle (skin) ───────────────────────────────
		{ size = Vector3.new(0.34, 0.34, 1.25), cf = CFrame.new( 0.65, 0.25, -0.55) * CFrame.Angles(0, math.rad(-8),  0), skin = true, material = SMOOTH }, -- right arm
		{ size = Vector3.new(0.34, 0.34, 1.55), cf = CFrame.new(-0.05, 0.20, -0.95) * CFrame.Angles(0, math.rad( 14), 0), skin = true, material = SMOOTH }, -- left arm reaches far down the barrel
		{ size = Vector3.new(0.42, 0.42, 0.42), cf = CFrame.new( 0.50, 0.30, -0.05), skin = true, material = SMOOTH, shape = BALL }, -- rear hand (trigger)
		{ size = Vector3.new(0.42, 0.42, 0.42), cf = CFrame.new( 0.05, 0.24, -1.65), skin = true, material = SMOOTH, shape = BALL }, -- front hand (far foregrip)
		-- ── Long sniper rifle (across the front, reaching well past the chest) ─
		{ size = Vector3.new(0.30, 0.32, 0.75), cf = CFrame.new( 0.30, 0.36,  0.35), color = GUNMETAL, material = METAL },              -- shoulder stock (rear)
		{ size = Vector3.new(0.30, 0.30, 2.9),  cf = CFrame.new( 0.30, 0.42, -0.95), color = GUNMETAL, material = METAL },              -- receiver + long barrel
		{ size = Vector3.new(0.16, 0.16, 0.9),  cf = CFrame.new( 0.30, 0.42, -2.55), color = BLACK,    material = METAL },              -- slim muzzle / suppressor
		-- ── Telescopic sight (block scope + glowing team-colour lens) ─────────
		{ size = Vector3.new(0.22, 0.22, 1.05), cf = CFrame.new( 0.30, 0.66, -0.80), color = BLACK, material = METAL },                 -- scope tube
		{ size = Vector3.new(0.10, 0.24, 0.10), cf = CFrame.new( 0.30, 0.54, -0.55), color = BLACK, material = METAL },                 -- rear scope mount
		{ size = Vector3.new(0.10, 0.24, 0.10), cf = CFrame.new( 0.30, 0.54, -1.05), color = BLACK, material = METAL },                 -- front scope mount
		{ size = Vector3.new(0.24, 0.24, 0.24), cf = CFrame.new( 0.30, 0.66, -1.35), color = nil,   material = NEON, shape = BALL },     -- objective lens (team-colour glint)
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

-- ── Public API ────────────────────────────────────────────────────────────────

--[[
	Returns the blueprint for `unitType` (or nil if the unit has no static
	blueprint and is built by a bespoke routine).  `bodySize` is required for
	the size-dependent blueprints (Tank treads, Medic cross).
]]
function UnitBlueprints.get(unitType: string, bodySize: Vector3): Blueprint?
	if unitType == "Howitzer" then return HOWITZER end
	if unitType == "Survivor"  then return SOLDIER  end
	if unitType == "Sniper"    then return SNIPER   end
	if unitType == "Tank"     then return tankBlueprint(bodySize)  end
	if unitType == "Medic"    then return medicBlueprint(bodySize) end
	if unitType == "Foamer"   then return FOAMER   end
	return nil
end

--[[
	Instantiates a single spec as an Anchored, non-colliding Part.  The caller
	is responsible for parenting and (on the server) decorator tracking.
	`bodyCF` is the body's world CFrame (identity for previews at the origin);
	`teamColor` is used wherever `spec.color` is nil.  `skinColor` (one tone per
	unit) tints any spec flagged `skin = true`; omit it and skin parts fall back to
	a neutral default tone.
]]
function UnitBlueprints.instantiate(spec: PartSpec, bodyCF: CFrame, teamColor: Color3, skinColor: Color3?): Part
	local p      = Instance.new("Part")
	if spec.shape then (p :: any).Shape = spec.shape end
	if spec.name  then p.Name = spec.name end
	p.Size       = spec.size
	if spec.skin then
		p.Color = skinColor or DEFAULT_SKIN
	else
		p.Color = spec.color or teamColor
	end
	p.Material   = spec.material
	p.Anchored   = true
	p.CanCollide = false
	p.CastShadow = false
	p.CanQuery   = false
	p.CFrame     = bodyCF * spec.cf
	return p
end

return UnitBlueprints
