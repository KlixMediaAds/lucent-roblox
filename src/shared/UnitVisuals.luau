--[[
	UnitVisuals — Shared procedural visual builders for units and buildings.

	Used by ViewportPreview (client) to produce static 3D thumbnails.
	Visual logic here must stay in sync with UnitManager and BuildingManager
	whenever those files update a unit or building's appearance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UnitBlueprints    = require(Shared:WaitForChild("UnitBlueprints"))

local UnitVisuals = {}

local DEFAULT_TEAM = BrickColor.new("Medium blue")

-- ── Fabricator Core (Command Center) shared constants ─────────────────────────
-- Used by buildCommandCenterDecor (server + preview) and the client
-- FabricatorArms animator. All Y values are studs above ground level.
UnitVisuals.FAB = {
	ARM_ANGLES  = { 0, math.pi * 2 / 3, math.pi * 4 / 3 },  -- yaw of each arm mount
	MOUNT_R     = 6.9,    -- radial distance of arm pylon centres
	SHOULDER_Y  = 14.35,  -- height of the arm shoulder pivot
	UPPER_LEN   = 4.9,    -- upper-arm segment length
	FORE_MIN    = 3.4,    -- forearm telescoping range
	FORE_MAX    = 6.4,
	STAND_ELBOW = Vector2.new(4.6, 18.7),  -- standby elbow (radial dist, Y)
	STAND_TIP   = Vector2.new(2.2, 16.3),  -- standby tool tip (radial dist, Y)
	HOVER_Y     = 19,     -- dropship hover height above ground while fabricating
}

-- Orients a part so its local Y axis runs from world point a to world point b,
-- sizing Y to the span and X/Z to `thickness`.
function UnitVisuals.orientYBetween(part: BasePart, a: Vector3, b: Vector3, thickness: number)
	local delta = b - a
	local len   = math.max(delta.Magnitude, 0.05)
	local dir   = delta / len
	local right = dir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then
		right = dir:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local back = right:Cross(dir)
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(thickness, len, thickness)
end

-- ── Unit helpers ──────────────────────────────────────────────────────────────

local function makePart(parent: Instance): Part
	local p          = Instance.new("Part")
	p.Anchored       = true
	p.CanCollide     = false
	p.CastShadow     = false
	p.CanQuery       = false
	p.Parent         = parent
	return p
end

-- Applies a shared unit blueprint to a static preview body at the origin.
-- Mirrors UnitManager.buildFromBlueprint but without decorator tracking.
local function applyBlueprint(parent: Instance, body: BasePart, bp: UnitBlueprints.Blueprint)
	if bp.rootTransparent then body.Transparency = 1 end
	local teamColor = body.Color
	local skinColor = UnitBlueprints.randomSkinTone()  -- one tone per preview (head + arms match)
	for _, spec in bp.parts do
		local p  = UnitBlueprints.instantiate(spec, body.CFrame, teamColor, skinColor)
		p.Parent = parent
	end
end

-- Preview-only static legs for the Howitzer walker. The live unit uses the
-- animated WalkerLegs client module instead, so the legs are not part of the
-- shared blueprint.
local function addWalkerLegsPreview(parent: Instance, body: BasePart)
	local grey = BrickColor.new("Dark stone grey").Color
	local function ap(sz: Vector3, pos: Vector3)
		local p      = makePart(parent)
		p.Size       = sz
		p.Position   = pos
		p.Color      = grey
		p.Material   = Enum.Material.Metal
	end
	for _, side in { -1, 1 } do
		ap(Vector3.new(2.4, 4, 2.4),   Vector3.new(side * 4.4, -2.5, 0))    -- upper leg
		ap(Vector3.new(2.0, 3.5, 2.0), Vector3.new(side * 4.8, -6.3, 0.2))  -- lower leg
		ap(Vector3.new(3.5, 0.9, 4.5), Vector3.new(side * 4.8, -7.5, 0.3))  -- foot plate
	end
end

-- Preview-only static lamprey: a massive eel reared up out of a dirt mound, mouth
-- agape. The live unit's whole body is drawn (and animated diving in/out of the
-- ground) by the client LampreyBody module, so none of this lives in the blueprint.
-- Built around a transparent body pivot at the origin; teamColor tints the
-- bioluminescent belly stripe.
local function addLampreyPreview(parent: Instance, body: BasePart)
	local teamColor = body.Color
	local C_BODY  = Color3.fromRGB(40, 44, 52)
	local C_TOOTH = Color3.fromRGB(228, 226, 210)
	local C_MAW   = Color3.fromRGB(150, 24, 28)
	local C_EYE   = Color3.fromRGB(255, 230, 40)
	local C_DIRT  = Color3.fromRGB(74, 56, 38)

	local function ap(sz: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p      = makePart(parent)
		if shape then (p :: any).Shape = shape end
		p.Size       = sz
		p.CFrame     = cf
		p.Color      = color
		p.Material   = material
		return p
	end

	-- Arched spine from a buried tail (back, +Z, low) up to a reared head (−Z, high)
	local pts = {
		Vector3.new(0, -2.6, 4.6),
		Vector3.new(0, -0.4, 3.2),
		Vector3.new(0,  1.8, 1.6),
		Vector3.new(0,  3.8, 0.1),
		Vector3.new(0,  5.4, -1.5),
		Vector3.new(0,  6.3, -3.0),  -- head centre
	}
	local thick = { 1.6, 2.8, 3.2, 3.3, 3.2, 3.0 }

	-- Body segments (tapered tubes) + a bioluminescent team stripe down the belly
	for i = 1, #pts - 1 do
		local t = (thick[i] + thick[i + 1]) * 0.5
		local seg = ap(Vector3.new(1, 1, 1), CFrame.new(), C_BODY, Enum.Material.SmoothPlastic)
		UnitVisuals.orientYBetween(seg, pts[i], pts[i + 1], t)
		-- knuckle ball to smooth the joints
		ap(Vector3.new(thick[i + 1], thick[i + 1], thick[i + 1]), CFrame.new(pts[i + 1]), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		-- glowing team-colour vent on the belly side (−Z front face of each segment)
		local mid  = (pts[i] + pts[i + 1]) * 0.5
		ap(Vector3.new(0.35, 0.35, 0.35), CFrame.new(mid + Vector3.new(0, 0, -t * 0.5)), teamColor, Enum.Material.Neon, Enum.PartType.Ball)
	end

	-- Dirt mound the tail erupts from
	ap(Vector3.new(7, 2.2, 7), CFrame.new(0, -0.4, 4.4), C_DIRT, Enum.Material.Ground, Enum.PartType.Ball)

	-- Head bulb
	local headPos = pts[#pts]
	ap(Vector3.new(3.8, 3.6, 4.0), CFrame.new(headPos), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)

	-- Mouth: a round red maw ringed with converging fangs, facing the head's forward
	local fwd = (pts[#pts] - pts[#pts - 1])
	fwd = if fwd.Magnitude > 0.01 then fwd.Unit else Vector3.new(0, 0, -1)
	local right = fwd:Cross(Vector3.yAxis)
	right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis
	local up = right:Cross(fwd).Unit
	local mawCentre = headPos + fwd * 1.7

	ap(Vector3.new(2.6, 2.6, 1.2), CFrame.lookAt(mawCentre, mawCentre + fwd), C_MAW, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	for k = 0, 9 do
		local ang = (k / 10) * math.pi * 2
		local radial = right * math.cos(ang) + up * math.sin(ang)
		local base = mawCentre + radial * 1.5
		local tip  = mawCentre + fwd * 1.3 + radial * 0.5
		local tooth = ap(Vector3.new(1, 1, 1), CFrame.new(), C_TOOTH, Enum.Material.SmoothPlastic)
		UnitVisuals.orientYBetween(tooth, base, tip, 0.42)
	end

	-- Two sunken glowing eyes on top of the head
	for _, s in { -1, 1 } do
		ap(Vector3.new(0.9, 0.9, 0.9), CFrame.new(headPos + right * (s * 1.1) + up * 1.0 + fwd * 0.4), C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
	end
end

-- Preview-only static hagfish: a slithering hagfish with its front third reared up
-- like a cobra, six dark reddish-purple teeth ringing the sides of its mouth (three
-- per side, like the six face of a die) and two tentacle-like antennae on its crown.
-- The live unit's whole body is drawn + animated by the client HagfishBody module,
-- so none of this lives in the blueprint. teamColor tints the belly stripe.
local function addHagfishPreview(parent: Instance, body: BasePart)
	local teamColor = body.Color
	local C_BODY  = Color3.fromRGB(48, 40, 56)   -- dark purplish slate
	local C_TOOTH = Color3.fromRGB(96, 32, 66)   -- dark reddish-purple fangs
	local C_ANT   = Color3.fromRGB(70, 50, 78)   -- antennae
	local C_EYE   = Color3.fromRGB(255, 120, 60)

	local function ap(sz: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p      = makePart(parent)
		if shape then (p :: any).Shape = shape end
		p.Size       = sz
		p.CFrame     = cf
		p.Color      = color
		p.Material   = material
		return p
	end

	-- S-curved spine: tail slithered out on the ground (+Z, low), rising through a
	-- reared neck to a forward-leaning head (−Z, high) — a cobra ready to strike.
	local pts = {
		Vector3.new( 1.4, 0.4, 4.8),  -- tail tip (slithered to one side)
		Vector3.new(-1.0, 0.4, 3.6),
		Vector3.new( 0.8, 0.4, 2.4),
		Vector3.new( 0.0, 0.6, 1.2),  -- neck base (where the rear leaves the ground)
		Vector3.new( 0.0, 2.4, 0.5),  -- lower neck
		Vector3.new( 0.0, 4.3, -0.3), -- upper neck
		Vector3.new( 0.0, 5.7, -1.4), -- head centre (reared, leaning forward)
	}
	local thick = { 0.8, 1.8, 2.2, 2.4, 2.3, 2.1, 1.9 }

	-- Body segments + knuckle balls + a glowing team-colour belly stripe
	for i = 1, #pts - 1 do
		local t   = (thick[i] + thick[i + 1]) * 0.5
		local seg = ap(Vector3.new(1, 1, 1), CFrame.new(), C_BODY, Enum.Material.SmoothPlastic)
		UnitVisuals.orientYBetween(seg, pts[i], pts[i + 1], t)
		ap(Vector3.new(thick[i + 1], thick[i + 1], thick[i + 1]), CFrame.new(pts[i + 1]), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		local mid = (pts[i] + pts[i + 1]) * 0.5
		ap(Vector3.new(0.3, 0.3, 0.3), CFrame.new(mid + Vector3.new(0, 0, -t * 0.5)), teamColor, Enum.Material.Neon, Enum.PartType.Ball)
	end

	-- Head bulb
	local headPos = pts[#pts]
	ap(Vector3.new(3.0, 2.8, 3.4), CFrame.new(headPos), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)

	-- Head basis: forward = up-and-over toward the strike direction (−Z), with a
	-- right axis and a head-up axis to lay the side teeth out across.
	local fwd = (pts[#pts] - pts[#pts - 1])
	fwd = if fwd.Magnitude > 0.01 then fwd.Unit else Vector3.new(0, 0, -1)
	local right = fwd:Cross(Vector3.yAxis)
	right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis
	local up = right:Cross(fwd).Unit

	-- Mouth on the underside-front of the reared head
	local mouth = headPos + fwd * 1.2 - up * 0.4

	-- Six side teeth: three rows on each side of the mouth (the six face of a die),
	-- splaying outward and slightly forward.
	for _, s in { -1, 1 } do
		for _, r in { -1, 0, 1 } do
			local base = mouth + right * (s * 1.2) + up * (r * 0.85)
			local tip  = base + right * (s * 0.7) + fwd * 0.6 - up * 0.1
			local tooth = ap(Vector3.new(1, 1, 1), CFrame.new(), C_TOOTH, Enum.Material.SmoothPlastic)
			UnitVisuals.orientYBetween(tooth, base, tip, 0.42)
		end
	end

	-- Two tentacle-like antennae curving up and back off the crown
	for _, s in { -1, 1 } do
		local base = headPos + up * 1.3 + right * (s * 0.6) - fwd * 0.2
		local tip  = base + up * 1.7 - fwd * 1.0 + right * (s * 0.3)
		local ant  = ap(Vector3.new(1, 1, 1), CFrame.new(), C_ANT, Enum.Material.SmoothPlastic)
		UnitVisuals.orientYBetween(ant, base, tip, 0.32)
		ap(Vector3.new(0.5, 0.5, 0.5), CFrame.new(tip), C_ANT, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end

	-- Two glowing eyes high on the head
	for _, s in { -1, 1 } do
		ap(Vector3.new(0.7, 0.7, 0.7), CFrame.new(headPos + right * (s * 1.0) + up * 0.7 + fwd * 0.5), C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
	end
end

-- Preview-only static Broodmother: a towering tripod standing on three tentacle
-- legs, crowned with a lumpy sea-anemone mass ringed in lamprey-like fang clusters
-- (each facing its own way) and topped with a fan of swaying tendrils. The live
-- unit's whole body is drawn + animated by the client BroodmotherBody module, so
-- none of this lives in the blueprint. Built in pivot-local space (ground at
-- y = -10, matching the 20-tall pivot). The tendril tips glow yellow (matching the
-- live unit's attack orbs); eyes are a fixed mint glow.
local function addBroodmotherPreview(parent: Instance, body: BasePart)
	local C_BODY  = Color3.fromRGB(46, 40, 60)    -- deep purple-slate flesh
	local C_LEG   = Color3.fromRGB(38, 33, 50)
	local C_TOOTH = Color3.fromRGB(228, 222, 232)
	local C_MAW   = Color3.fromRGB(120, 24, 60)
	local C_EYE   = Color3.fromRGB(150, 240, 200)
	local C_ORB   = Color3.fromRGB(255, 224, 90)  -- glowing yellow tendril tips

	local function ap(sz: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = makePart(parent)
		if shape then (p :: any).Shape = shape end
		p.Size     = sz
		p.CFrame   = cf
		p.Color    = color
		p.Material = material
		return p
	end

	local GROUND  = -10.0
	local MASS_Y  = 3.0
	local MASS_R  = 4.2
	local massPos = Vector3.new(0, MASS_Y, 0)

	-- ── Three tentacle legs, splayed 120° apart ──────────────────────────────────
	for L = 0, 2 do
		local ang  = (L / 3) * math.pi * 2 + math.pi / 6
		local dir  = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local hip  = massPos + dir * (MASS_R * 0.5) + Vector3.new(0, -1.5, 0)
		local knee = massPos + dir * (MASS_R + 2.5) + Vector3.new(0, (GROUND + MASS_Y) * 0.45, 0)
		local foot = Vector3.new(dir.X * (MASS_R + 3.0), GROUND, dir.Z * (MASS_R + 3.0))
		local pts  = { hip, knee, foot }
		local thk  = { 1.7, 1.2, 0.7 }
		for i = 1, #pts - 1 do
			local seg = ap(Vector3.new(1, 1, 1), CFrame.new(), C_LEG, Enum.Material.SmoothPlastic)
			UnitVisuals.orientYBetween(seg, pts[i], pts[i + 1], thk[i])
			ap(Vector3.new(thk[i], thk[i], thk[i]), CFrame.new(pts[i + 1]), C_LEG, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		end
		-- Splayed foot pad
		ap(Vector3.new(1.6, 0.7, 1.6), CFrame.new(foot + Vector3.new(0, 0.3, 0)), C_LEG, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end

	-- ── Anemone mass: a lumpy cluster of overlapping balls ───────────────────────
	ap(Vector3.new(MASS_R * 2, MASS_R * 1.8, MASS_R * 2), CFrame.new(massPos), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	for _, lump in {
		Vector3.new( 2.2, 1.4,  1.6), Vector3.new(-2.4, 0.6, -1.2),
		Vector3.new( 0.6, 2.4, -2.2), Vector3.new(-1.4, -1.6, 2.0),
	} do
		ap(Vector3.new(3.4, 3.0, 3.4), CFrame.new(massPos + lump), C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end

	-- ── Fang clusters facing several directions (lamprey-like sucker maws) ───────
	local mawDirs = {
		Vector3.new( 1, 0.15,  0.3), Vector3.new(-0.8, 0.1,  0.7),
		Vector3.new( 0.2, 0.2, -1),  Vector3.new(-0.5, -0.4, -0.6),
		Vector3.new( 0.7, -0.3, 0.6),
	}
	for _, d in mawDirs do
		local dir = d.Unit
		local mawC = massPos + dir * (MASS_R * 0.92)
		-- Maw socket
		ap(Vector3.new(1.6, 1.6, 1.0), CFrame.lookAt(mawC, mawC + dir), C_MAW, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		-- Basis perpendicular to the maw direction for the fang ring
		local u = dir:Cross(Vector3.yAxis)
		u = if u.Magnitude > 0.01 then u.Unit else Vector3.xAxis
		local v = dir:Cross(u).Unit
		for k = 0, 5 do
			local a    = (k / 6) * math.pi * 2
			local rad  = u * math.cos(a) + v * math.sin(a)
			local base = mawC + rad * 0.95
			local tip  = mawC + dir * 1.1 + rad * 0.4
			local tooth = ap(Vector3.new(1, 1, 1), CFrame.new(), C_TOOTH, Enum.Material.SmoothPlastic)
			UnitVisuals.orientYBetween(tooth, base, tip, 0.3)
		end
	end

	-- ── Crown of swaying tendrils (static curl in the preview) ───────────────────
	for k = 0, 7 do
		local ang  = (k / 8) * math.pi * 2
		local out  = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local base = massPos + Vector3.new(0, MASS_R * 0.8, 0) + out * 1.2
		local mid  = base + out * 1.4 + Vector3.new(0, 2.2, 0)
		local tip  = mid + out * 1.8 + Vector3.new(0, 1.6, 0)
		local seg1 = ap(Vector3.new(1, 1, 1), CFrame.new(), C_BODY, Enum.Material.SmoothPlastic)
		local seg2 = ap(Vector3.new(1, 1, 1), CFrame.new(), C_BODY, Enum.Material.SmoothPlastic)
		UnitVisuals.orientYBetween(seg1, base, mid, 0.34)
		UnitVisuals.orientYBetween(seg2, mid,  tip, 0.24)
		-- Glowing yellow bulb on the tip
		ap(Vector3.new(0.7, 0.7, 0.7), CFrame.new(tip), C_ORB, Enum.Material.Neon, Enum.PartType.Ball)
	end

	-- ── Two glowing eyes on the front of the mass ────────────────────────────────
	for _, s in { -1, 1 } do
		ap(Vector3.new(0.9, 0.9, 0.9), CFrame.new(massPos + Vector3.new(s * 1.6, 0.8, -MASS_R * 0.85)), C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
	end
end

-- ── Building helpers ──────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Monument"      then return Config.MONUMENT_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	if buildingType == "CreepyWorm"    then return Vector3.new(8, 5, 8) end
	if buildingType == "CreepyBlob"    then return Vector3.new(9, 6, 9) end
	if buildingType == "LampreyNest"   then return Config.LAMPREY_NEST_SIZE end
	if buildingType == "Foundry"       then return Config.FOUNDRY_SIZE end
	if buildingType == "EngineeringPost" then return Config.ENGINEERING_POST_SIZE end
	return Config.BUILDING_SIZE
end

-- ── Fabricator Core decor ─────────────────────────────────────────────────────

--[[
	Builds the full Industrial Fabricator Core decoration set under `parent`:
	layered platform rings, reactor pit, pipes, vents, warning lights, operator
	pulpit and three fabrication arms in standby pose.

	Shared by BuildingManager (live building), buildBuildingPreview (thumbnails)
	and the client CC move ghost — keep all three in sync through this function.

	groundCF:  CFrame at the ground-level centre of the CC footprint (Y = 0).
	teamColor: accent colour for identity bands / pulpit screen.
	withFX:    true to add lights + particle emitters (live building only).

	All parts are Anchored, CanCollide false, CanQuery false. Arm segments are
	named "Fab<Seg><i>" so FabricatorArms (client) can animate them.
]]
function UnitVisuals.buildCommandCenterDecor(parent: Instance, groundCF: CFrame, teamColor: BrickColor, withFX: boolean?)
	local FAB = UnitVisuals.FAB

	local cDarkSteel = Color3.fromRGB(52, 54, 58)
	local cGunmetal  = Color3.fromRGB(35, 37, 41)
	local cPlate     = Color3.fromRGB(70, 73, 78)
	local cCorrode   = Color3.fromRGB(92, 76, 60)
	local cEmber     = Color3.fromRGB(255, 96, 24)
	local cWarn      = Color3.fromRGB(255, 40, 30)
	local cCable     = Color3.fromRGB(24, 24, 28)

	local function dp(name: string, size: Vector3, localCF: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		if shape then (p :: any).Shape = shape end
		p.Size       = size
		p.CFrame     = groundCF * localCF
		p.Color      = color
		p.Material   = material
		p.Anchored   = true
		p.CanCollide = false
		p.CastShadow = false
		p.CanQuery   = false
		p.Parent     = parent
		return p
	end

	-- Vertical cylinder (cylinder axis is X; roll 90° to stand it up)
	local function vcyl(name: string, height: number, diameter: number, x: number, y: number, z: number, color: Color3, material: Enum.Material): Part
		return dp(name, Vector3.new(height, diameter, diameter),
			CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.pi / 2),
			color, material, Enum.PartType.Cylinder)
	end

	-- ── Layered platform rings ────────────────────────────────────────────────
	vcyl("SkirtRing", 2.4, 16.8, 0, 1.2, 0, cPlate,    Enum.Material.DiamondPlate)
	vcyl("MidRing",   5.0, 15.2, 0, 5.4, 0, cGunmetal, Enum.Material.Metal)
	vcyl("DeckRing",  1.2, 16.0, 0, 9.4, 0, cPlate,    Enum.Material.DiamondPlate)

	-- Team identity bands
	local band1 = vcyl("TeamBand",  0.5,  17.0, 0, 2.55, 0, teamColor.Color, Enum.Material.Neon)
	local band2 = vcyl("TeamBand2", 0.35, 16.2, 0, 8.6,  0, teamColor.Color, Enum.Material.Neon)
	local _ = band1; _ = band2

	-- ── Reactor pit ───────────────────────────────────────────────────────────
	vcyl("PitWall", 1.8, 9.0, 0, 10.1, 0, cGunmetal,  Enum.Material.Metal)
	vcyl("PitRim",  0.3, 9.6, 0, 11.1, 0, cDarkSteel, Enum.Material.Metal)
	local core = vcyl("ReactorCore", 0.6, 7.0, 0, 10.5, 0, cEmber, Enum.Material.Neon)

	if withFX then
		local glow      = Instance.new("PointLight")
		glow.Color      = Color3.fromRGB(255, 120, 30)
		glow.Brightness = 6
		glow.Range      = 30
		glow.Parent     = core

		local embers              = Instance.new("ParticleEmitter")
		embers.Texture            = "rbxasset://textures/particles/fire_main.dds"
		embers.Color              = ColorSequence.new(Color3.fromRGB(255, 140, 40), Color3.fromRGB(180, 40, 10))
		embers.LightEmission      = 1
		embers.Size               = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7),
			NumberSequenceKeypoint.new(1, 0.15),
		})
		embers.Transparency       = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.25),
			NumberSequenceKeypoint.new(0.7, 0.55),
			NumberSequenceKeypoint.new(1,   1),
		})
		embers.Rate               = 7
		embers.Lifetime           = NumberRange.new(1.0, 1.9)
		embers.Speed              = NumberRange.new(2, 4.5)
		embers.SpreadAngle        = Vector2.new(14, 14)
		embers.EmissionDirection  = Enum.NormalId.Right  -- cylinder local X = world up
		embers.Parent             = core
	end

	-- ── Pipes (4 verticals with elbow caps) ───────────────────────────────────
	for _, deg in { 45, 135, 225, 315 } do
		local a = math.rad(deg)
		local x = math.cos(a) * 6.6
		local z = math.sin(a) * 6.6
		vcyl("Pipe" .. deg, 7.0, 0.7, x, 5.9, z, cCorrode, Enum.Material.CorrodedMetal)
		dp("PipeElbow" .. deg, Vector3.new(0.95, 0.95, 0.95), CFrame.new(x, 9.55, z), cDarkSteel, Enum.Material.Metal)
	end

	-- ── Vents + conduit boxes on the mid ring ─────────────────────────────────
	for _, deg in { 60, 300 } do
		local a   = math.rad(deg)
		local pos = Vector3.new(math.cos(a) * 7.5, 6.5, math.sin(a) * 7.5)
		dp("Vent" .. deg, Vector3.new(2.6, 1.8, 1.0),
			CFrame.lookAt(pos, Vector3.new(pos.X * 2, pos.Y, pos.Z * 2)),
			cDarkSteel, Enum.Material.Metal)
	end
	for _, deg in { 100, 260 } do
		local a   = math.rad(deg)
		local pos = Vector3.new(math.cos(a) * 7.7, 4.6, math.sin(a) * 7.7)
		dp("Conduit" .. deg, Vector3.new(1.8, 1.2, 0.8),
			CFrame.lookAt(pos, Vector3.new(pos.X * 2, pos.Y, pos.Z * 2)),
			cGunmetal, Enum.Material.Metal)
	end

	-- ── Warning lights on deck-edge posts (client blinks "WarnLight" parts) ──
	for _, deg in { 60, 210, 300 } do
		local a = math.rad(deg)
		local x = math.cos(a) * 7.5
		local z = math.sin(a) * 7.5
		dp("WarnPost" .. deg, Vector3.new(0.25, 1.4, 0.25), CFrame.new(x, 10.7, z), cDarkSteel, Enum.Material.Metal)
		dp("WarnLight", Vector3.new(0.5, 0.5, 0.5), CFrame.new(x, 11.55, z), cWarn, Enum.Material.Neon, Enum.PartType.Ball)
	end

	-- ── Heat exhaust stacks ───────────────────────────────────────────────────
	for _, deg in { 90, 270 } do
		local a = math.rad(deg)
		local x = math.cos(a) * 5.4
		local z = math.sin(a) * 5.4
		vcyl("Stack" .. deg,    2.8,  1.7, x, 11.4,  z, cGunmetal,  Enum.Material.Metal)
		vcyl("StackTop" .. deg, 0.25, 1.9, x, 12.85, z, cDarkSteel, Enum.Material.Metal)
		local vent = vcyl("StackGlow" .. deg, 0.1, 1.1, x, 12.78, z, cEmber, Enum.Material.Neon)
		if withFX then
			local smoke             = Instance.new("ParticleEmitter")
			smoke.Texture           = "rbxasset://textures/particles/smoke_main.dds"
			smoke.Color             = ColorSequence.new(Color3.fromRGB(70, 68, 66), Color3.fromRGB(30, 30, 32))
			smoke.Size              = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.8),
				NumberSequenceKeypoint.new(1, 2.4),
			})
			smoke.Transparency      = NumberSequence.new({
				NumberSequenceKeypoint.new(0,   0.55),
				NumberSequenceKeypoint.new(1,   1),
			})
			smoke.Rate              = 1.6
			smoke.Lifetime          = NumberRange.new(2.2, 3.4)
			smoke.Speed             = NumberRange.new(1.4, 2.6)
			smoke.SpreadAngle       = Vector2.new(8, 8)
			smoke.EmissionDirection = Enum.NormalId.Right
			smoke.Parent            = vent
		end
	end

	-- ── Operator pulpit (avatar seat perch, at 180° between arms 2 and 3) ────
	dp("PulpitDeck",    Vector3.new(3.4, 0.6, 3.4),  CFrame.new(-5.6, 10.3, 0),  cGunmetal,  Enum.Material.Metal)
	dp("PulpitConsole", Vector3.new(0.5, 1.1, 2.0),  CFrame.new(-7.0, 11.15, 0), cDarkSteel, Enum.Material.Metal)
	dp("PulpitScreen",  Vector3.new(0.15, 0.7, 1.5), CFrame.new(-7.3, 11.2, 0),  teamColor.Color, Enum.Material.Neon)

	-- ── Fabrication arms ──────────────────────────────────────────────────────
	for i, theta in FAB.ARM_ANGLES do
		local dir   = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local mount = dir * FAB.MOUNT_R
		local yawCF = CFrame.Angles(0, -theta, 0)

		-- Support strut from the skirt up under the pylon
		local strut = dp("FabStrut" .. i, Vector3.new(1, 1, 1), CFrame.new(), cCorrode, Enum.Material.CorrodedMetal)
		UnitVisuals.orientYBetween(strut,
			groundCF:PointToWorldSpace(dir * 8.2 + Vector3.new(0, 2.5, 0)),
			groundCF:PointToWorldSpace(dir * FAB.MOUNT_R + Vector3.new(0, 9.6, 0)), 0.8)

		dp("FabPylonFoot" .. i, Vector3.new(2.6, 0.4, 2.6), CFrame.new(mount + Vector3.new(0, 10.2, 0)) * yawCF, cPlate, Enum.Material.DiamondPlate)
		dp("FabPylon" .. i,     Vector3.new(1.9, 3.2, 1.9), CFrame.new(mount + Vector3.new(0, 11.6, 0)) * yawCF, cGunmetal, Enum.Material.Metal)
		vcyl("FabTurn" .. i, 0.8, 2.4, mount.X, 13.6, mount.Z, cDarkSteel, Enum.Material.Metal)

		-- Standby joint positions (local space)
		local P0 = mount + Vector3.new(0, FAB.SHOULDER_Y, 0)
		local P1 = dir * FAB.STAND_ELBOW.X + Vector3.new(0, FAB.STAND_ELBOW.Y, 0)
		local P2 = dir * FAB.STAND_TIP.X + Vector3.new(0, FAB.STAND_TIP.Y, 0)
		local w0 = groundCF:PointToWorldSpace(P0)
		local w1 = groundCF:PointToWorldSpace(P1)
		local w2 = groundCF:PointToWorldSpace(P2)

		local shoulder = dp("FabShoulder" .. i, Vector3.new(1.7, 1.7, 1.7), CFrame.new(P0) * yawCF, cGunmetal, Enum.Material.Metal)

		local upper = dp("FabUpper" .. i, Vector3.new(1, 1, 1), CFrame.new(), cDarkSteel, Enum.Material.Metal)
		UnitVisuals.orientYBetween(upper, w0, w1, 1.1)

		dp("FabElbow" .. i, Vector3.new(1.4, 1.4, 1.4), CFrame.new(P1), cGunmetal, Enum.Material.Metal, Enum.PartType.Ball)

		local fore = dp("FabFore" .. i, Vector3.new(1, 1, 1), CFrame.new(), cDarkSteel, Enum.Material.Metal)
		UnitVisuals.orientYBetween(fore, w1, w2, 0.85)

		local foreDirW = (w2 - w1).Unit
		local tool = dp("FabTool" .. i, Vector3.new(1.3, 1.3, 1.9), CFrame.lookAt(w2, w2 + foreDirW), cGunmetal, Enum.Material.Metal)
		-- Tool CFrame is world-space already; undo the groundCF transform applied by dp
		tool.CFrame = CFrame.lookAt(w2, w2 + foreDirW)

		local tip = dp("FabTip" .. i, Vector3.new(0.45, 0.45, 0.45), CFrame.new(), cEmber, Enum.Material.Neon, Enum.PartType.Ball)
		tip.CFrame = CFrame.new(w2 + foreDirW * 1.25)

		-- Hydraulic piston: pylon top rear → upper-arm midpoint
		local piston = dp("FabPiston" .. i, Vector3.new(1, 1, 1), CFrame.new(), cDarkSteel, Enum.Material.Metal)
		UnitVisuals.orientYBetween(piston,
			groundCF:PointToWorldSpace(dir * 6.0 + Vector3.new(0, 13.2, 0)),
			(w0 + w1) * 0.5, 0.38)

		-- Drooping power cable: shoulder → tool head (follows parts when animated)
		local a0    = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.9, 0)
		a0.Axis     = Vector3.new(0, -1, 0)
		a0.Parent   = shoulder
		local a1    = Instance.new("Attachment")
		a1.Position = Vector3.new(0, 0.4, 0.8)
		a1.Axis     = Vector3.new(0, -1, 0)
		a1.Parent   = tool
		local cable        = Instance.new("Beam")
		cable.Attachment0  = a0
		cable.Attachment1  = a1
		cable.Color        = ColorSequence.new(cCable)
		cable.Width0       = 0.22
		cable.Width1       = 0.22
		cable.CurveSize0   = 2
		cable.CurveSize1   = 1.5
		cable.Transparency = NumberSequence.new(0.25)
		cable.FaceCamera   = true
		cable.Parent       = shoulder
	end
end

--[[
	Builds the Lamprey Nest decoration under `parent`: a cluster of seven egg-tipped
	tentacles (inspired by the Hagfish's ground tentacles, ~50% larger and longer)
	erupting from one spot, each branching out on its own heading at its own height
	and arching over under the weight of a glowing green egg at its tip. The central
	green "Core" orifice is the egg-emergence point; the seven egg tips are "TubeTip_"
	parts that bulge during egg production (see produceLampreyEgg). Shared by
	BuildingManager (live, withFX) and buildBuildingPreview (thumbnail) so the two
	stay in sync.

	groundCF:  CFrame at the ground-level centre of the footprint (Y = 0 = ground).
	teamColor: accent colour for the ownership band.
	withFX:    true to add a glow light (live building only).
]]
-- Local-space (relative to the ground-centre CFrame) home poses of the Foundry's two
-- rotating arms, at rotation angle 0. Each arm is a long strut whose inner foot sits low
-- by the central hub and whose outer head rises up-and-out at ~45°. Shared by
-- buildFoundryDecor (to build them) and the client FoundryRotor (to spin them around the
-- centrepiece) so the live geometry and the animation never drift apart.
function UnitVisuals.foundryArms(): { { cf: CFrame, size: Vector3 } }
	local arms: { { cf: CFrame, size: Vector3 } } = {}
	for _, theta in { 0, math.pi } do
		local dir  = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local low  = dir * 2  + Vector3.new(0, 5,  0)   -- inner foot: near & low at the hub
		local high = dir * 13 + Vector3.new(0, 16, 0)   -- outer head: up & out (~45°)
		local mid  = (low + high) / 2
		local len  = (high - low).Magnitude
		table.insert(arms, {
			cf   = CFrame.lookAt(mid, high),
			size = Vector3.new(1.6, 1.6, len),
		})
	end
	return arms
end

--[[
	Builds the Foundry decoration set under `parent`: a wide armored deck, a central
	molten crucible, a glowing hub, and TWO angled struts that the client FoundryRotor
	slowly spins around the centrepiece. Shared by BuildingManager (live, withFX) and
	buildBuildingPreview (thumbnail) so the two stay in sync.

	groundCF:  CFrame at the ground-level centre of the 28×28 footprint (Y = 0 = ground).
	teamColor: accent colour for the identity bands.
	withFX:    true to add the molten glow light + looped ambient/harvest sounds (live only).
]]
function UnitVisuals.buildFoundryDecor(parent: Instance, groundCF: CFrame, teamColor: BrickColor, withFX: boolean?)
	local cGunmetal = Color3.fromRGB(35, 37, 41)
	local cDarkSteel = Color3.fromRGB(52, 54, 58)
	local cPlate    = Color3.fromRGB(70, 73, 78)
	local cMolten   = Color3.fromRGB(255, 110, 30)

	local function dp(name: string, size: Vector3, localCF: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		if shape then (p :: any).Shape = shape end
		p.Size       = size
		p.CFrame     = groundCF * localCF
		p.Color      = color
		p.Material   = material
		p.Anchored   = true
		p.CanCollide = false
		p.CastShadow = false
		p.CanQuery   = false
		p.Parent     = parent
		return p
	end

	-- Vertical cylinder (cylinder axis is X; roll 90° to stand it up)
	local function vcyl(name: string, height: number, diameter: number, x: number, y: number, z: number, color: Color3, material: Enum.Material): Part
		return dp(name, Vector3.new(height, diameter, diameter),
			CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.pi / 2),
			color, material, Enum.PartType.Cylinder)
	end

	-- ── Deck ──────────────────────────────────────────────────────────────────
	dp("Slab",     Vector3.new(28, 1.5, 28), CFrame.new(0, 0.75, 0), cGunmetal, Enum.Material.DiamondPlate)
	dp("TeamTrim", Vector3.new(26, 0.4, 26), CFrame.new(0, 1.55, 0), teamColor.Color, Enum.Material.Neon)
	dp("Deck",     Vector3.new(24, 1.2, 24), CFrame.new(0, 2.1, 0),  cPlate,    Enum.Material.DiamondPlate)

	-- ── Central crucible (molten metal vat) ───────────────────────────────────
	vcyl("Crucible",    10, 12.0, 0, 7.7,  0, cGunmetal,       Enum.Material.Metal)
	vcyl("TeamBand",    0.5, 12.4, 0, 5.0, 0, teamColor.Color, Enum.Material.Neon)
	vcyl("CrucibleRim", 0.6, 13.0, 0, 12.6, 0, cDarkSteel,     Enum.Material.Metal)
	local molten = vcyl("Molten", 0.7, 11.0, 0, 12.9, 0, cMolten, Enum.Material.Neon)

	-- ── Rotating hub + two angled struts ──────────────────────────────────────
	-- The struts pivot around this hub (FoundryRotor drives "FoundryArm*" CFrames).
	dp("FoundryHub", Vector3.new(3.2, 3.2, 3.2), CFrame.new(0, 13.2, 0), teamColor.Color, Enum.Material.Neon, Enum.PartType.Ball)
	for i, a in UnitVisuals.foundryArms() do
		dp("FoundryArm" .. i, a.size, a.cf, cDarkSteel, Enum.Material.Metal)
	end

	if withFX then
		local glow      = Instance.new("PointLight")
		glow.Color      = Color3.fromRGB(255, 130, 40)
		glow.Brightness = 5
		glow.Range      = 26
		glow.Parent     = molten

		-- Looped 3D ambient refinery hum. Loud "spin-up" on the first pass, then
		-- drops 60% (to 40% volume) for every loop after — settles into a quiet bed.
		local AMB_VOLUME       = 0.55
		local amb              = Instance.new("Sound")
		amb.Name               = "_FoundryAmbient"
		amb.SoundId            = "rbxassetid://9112839813"
		amb.Looped             = true
		amb.Volume             = AMB_VOLUME
		amb.RollOffMode        = Enum.RollOffMode.Linear
		amb.RollOffMinDistance = 12
		amb.RollOffMaxDistance = 150
		amb.Playing            = true
		amb.Parent             = molten
		amb.DidLoop:Once(function()
			amb.Volume = AMB_VOLUME * 0.4
		end)

		-- One-shot harvest sound, :Play()ed by the server each boosted income tick.
		local harv              = Instance.new("Sound")
		harv.Name               = "_FoundryHarvest"
		harv.SoundId            = "rbxassetid://138571475125488"
		harv.Volume             = 0.6
		harv.RollOffMode        = Enum.RollOffMode.Linear
		harv.RollOffMinDistance = 10
		harv.RollOffMaxDistance = 120
		harv.Parent             = molten
	end
end

--[[
	Builds the Engineering Post decoration set: an armored lab housing with a glowing
	holographic data screen, a roof sensor dish on a mast, and team-coloured trim.
	Shared by BuildingManager (live, withFX) and buildBuildingPreview (thumbnail).

	groundCF:  CFrame at the ground-level centre of the footprint (Y = 0 = ground).
	teamColor: accent colour for trim / screen.
	withFX:    true to add a soft work light (live building only).
]]
function UnitVisuals.buildEngineeringPostDecor(parent: Instance, groundCF: CFrame, teamColor: BrickColor, withFX: boolean?)
	local cGunmetal = Color3.fromRGB(38, 41, 47)
	local cPlate    = Color3.fromRGB(70, 73, 78)
	local cGlass    = teamColor.Color
	local tc        = teamColor.Color

	local function dp(name: string, size: Vector3, localCF: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		if shape then (p :: any).Shape = shape end
		p.Size       = size
		p.CFrame     = groundCF * localCF
		p.Color      = color
		p.Material   = material
		p.Anchored   = true
		p.CanCollide = false
		p.CastShadow = false
		p.CanQuery   = false
		p.Parent     = parent
		return p
	end

	-- Foundation + main housing
	dp("Slab",    Vector3.new(12, 0.8, 12), CFrame.new(0, 0.4, 0),  cGunmetal, Enum.Material.DiamondPlate)
	dp("Housing", Vector3.new(9, 5.5, 9),   CFrame.new(0, 3.25, 0), cPlate,    Enum.Material.Metal)
	-- Sloped roof cap
	dp("Roof",    Vector3.new(9.6, 0.6, 9.6), CFrame.new(0, 6.1, 0), cGunmetal, Enum.Material.Metal)
	-- Team identity band around the housing
	dp("Band",    Vector3.new(9.2, 0.4, 9.2), CFrame.new(0, 5.6, 0), tc, Enum.Material.Neon)

	-- Glowing holographic data screen on the front face
	dp("Screen",  Vector3.new(5.5, 3.2, 0.3), CFrame.new(0, 3.4, 4.6), cGlass, Enum.Material.Neon)
	dp("ScreenFrame", Vector3.new(6.1, 3.8, 0.2), CFrame.new(0, 3.4, 4.5), cGunmetal, Enum.Material.Metal)

	-- Corner support struts (dark)
	for _, s in { {1, 1}, {1, -1}, {-1, 1}, {-1, -1} } do
		dp("Strut", Vector3.new(0.7, 5.5, 0.7), CFrame.new(s[1] * 4.4, 3.25, s[2] * 4.4), cGunmetal, Enum.Material.Metal)
	end

	-- Roof sensor mast + dish (slightly tilted)
	dp("Mast", Vector3.new(0.5, 3.0, 0.5), CFrame.new(0, 7.7, 0), cPlate, Enum.Material.Metal)
	local dish = dp("Dish", Vector3.new(3.4, 0.5, 3.4),
		CFrame.new(0, 9.1, 0) * CFrame.Angles(math.rad(28), 0, 0),
		cPlate, Enum.Material.Metal, Enum.PartType.Cylinder)
	dp("DishCore", Vector3.new(0.8, 0.8, 0.8), CFrame.new(0, 9.1, 0), tc, Enum.Material.Neon, Enum.PartType.Ball)
	local _ = dish

	if withFX then
		local glow      = Instance.new("PointLight")
		glow.Color      = tc
		glow.Brightness = 1.6
		glow.Range      = 16
		local screen    = parent:FindFirstChild("Screen") :: BasePart?
		glow.Parent     = screen or parent:FindFirstChild("Housing")
	end
end

function UnitVisuals.buildLampreyNestDecor(parent: Instance, groundCF: CFrame, teamColor: BrickColor, withFX: boolean?)
	local GREEN  = Color3.fromRGB(120, 190, 60)
	local EGGC   = Color3.fromRGB(120, 230, 90)
	local DIRT   = Color3.fromRGB(74, 56, 38)
	local V      = Vector3.new

	local function dp(name: string, size: Vector3, localCF: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p      = Instance.new("Part")
		p.Name       = name
		if shape then (p :: any).Shape = shape end
		p.Size       = size
		p.CFrame     = groundCF * localCF
		p.Color      = color
		p.Material   = material
		p.Anchored   = true
		p.CanCollide = false
		p.CastShadow = false
		p.CanQuery   = false
		p.Parent     = parent
		return p
	end
	local function wpt(v: Vector3): Vector3
		return groundCF:PointToWorldSpace(v)
	end
	local function seg(name: string, a: Vector3, b: Vector3, thick: number, color: Color3, material: Enum.Material)
		local p = dp(name, V(1, 1, 1), CFrame.new(), color, material)
		UnitVisuals.orientYBetween(p, wpt(a), wpt(b), thick)
	end

	-- ── Seven egg-tipped tentacles erupting from one spot ──
	-- Inspired by the Hagfish's ground tentacles but ~50% larger and longer: each
	-- stalk rises from the central orifice, branches out on its own heading, and
	-- arches over under the weight of a glowing green egg fused to its tip — a gentle
	-- droop, heavier than a reed but far short of a candy cane. The egg tips are the
	-- "TubeTip_" parts pulsed during birth; the central green "Core" is where new
	-- eggs actually emerge.
	local TENT    = Color3.fromRGB(96, 32, 66)    -- hagfish reddish-purple
	local TENT_DK = Color3.fromRGB(66, 22, 46)

	-- Central muscular base + green emergence orifice (Core)
	dp("BaseBulb", V(4.2, 2.4, 4.2), CFrame.new(0, 1.0, 0), TENT_DK, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local core = dp("Core", V(2.5, 2.5, 2.5), CFrame.new(0, 1.8, 0), GREEN, Enum.Material.Neon, Enum.PartType.Ball)
	core.Transparency = 0.15

	-- A few tentacles tower over the rest; the tall ones bend less so they stand up
	-- high rather than arching way out.
	local heights = { 13.5, 8.0, 12.0, 7.5, 14.5, 8.8, 11.0 }
	local bends   = { 1.45, 1.90, 1.55, 1.95, 1.35, 1.80, 1.60 }   -- radians (~77°–112°)
	local M       = 6                                              -- spine points per stalk
	local BT, TT  = 1.45, 0.5                                      -- base / tip thickness (~1.5× hagfish)

	for i = 1, 7 do
		local az      = (i - 1) / 7 * math.pi * 2 + 0.25
		local outward = V(math.cos(az), 0, math.sin(az))
		local sideAx  = V(-outward.Z, 0, outward.X)
		local H       = heights[i]
		local maxBend = bends[i]
		local segLen  = H / M

		-- Integrate the curve: near-vertical for most of the rise, arching over near
		-- the top so the weighted tip droops outward.
		local pts = { V(math.cos(az) * 0.6, 0.6, math.sin(az) * 0.6) }
		local pos = pts[1]
		for j = 1, M do
			local s     = j / M
			local bend  = (s ^ 2.6) * maxBend
			local waver = math.sin(s * 5 + i * 1.3) * 0.14
			local dir   = (Vector3.yAxis * math.cos(bend) + outward * math.sin(bend) + sideAx * waver).Unit
			pos         = pos + dir * segLen
			pts[j + 1]  = pos
		end

		-- Tapered segments + joint knots
		for j = 1, M do
			local th = BT + (TT - BT) * ((j - 1) / M)
			seg("Stalk_" .. i .. "_" .. j, pts[j], pts[j + 1], th, TENT, Enum.Material.SmoothPlastic)
			if j < M then
				dp("Knot_" .. i .. "_" .. j, V(th, th, th), CFrame.new(pts[j + 1]), TENT, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
			end
		end

		-- Drooping green egg fused to the tip (TubeTip_ → bulges during birth)
		local tip    = pts[M + 1]
		local tipDir = (pts[M + 1] - pts[M]).Unit
		local egg    = dp("TubeTip_" .. i, V(1.8, 2.0, 1.8), CFrame.new(tip + tipDir * 0.7), EGGC, Enum.Material.Neon, Enum.PartType.Ball)
		egg.Transparency = 0.2
	end

	-- ── Disturbed earth the tentacles erupt from ──
	dp("Mound", V(1.0, 9.2, 9.2), CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2), DIRT, Enum.Material.Ground, Enum.PartType.Cylinder)
	for i = 1, 6 do
		local ang = (i / 6) * math.pi * 2 + 0.5
		local r   = 3.9
		dp("Clod" .. i, V(1.7, 1.1, 1.7), CFrame.new(math.cos(ang) * r, 0.6, math.sin(ang) * r), DIRT, Enum.Material.Ground, Enum.PartType.Ball)
	end

	if withFX then
		local light      = Instance.new("PointLight")
		light.Color      = GREEN
		light.Brightness = 2.2
		light.Range      = 14
		light.Parent     = core
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--[[
	Builds a static unit model under `parent` for ViewportFrame display.
	All parts are anchored. Returns the root BasePart.
	teamColor: BrickColor for the unit body (defaults to medium blue).
]]
function UnitVisuals.buildUnitPreview(parent: Instance, unitType: string, teamColor: BrickColor?): BasePart?
	local typeDef = (Config.UNIT_TYPES :: any)[unitType]
	if not typeDef then return nil end

	local color: BrickColor = teamColor or DEFAULT_TEAM
	if unitType == "CreepySoldier" then
		color = BrickColor.new("Black")
	end

	-- Base block body. For units whose blueprint marks the root transparent
	-- (Soldier, Howitzer) this becomes an invisible anchor; the visible shape is
	-- entirely decorator parts. Named after the unit type so callers can pick it
	-- as the model's PrimaryPart.
	local body          = Instance.new("Part")
	body.Name           = unitType
	body.Size           = typeDef.size
	body.CFrame         = CFrame.new(0, 0, 0)
	body.BrickColor     = color
	body.Material       = Enum.Material.SmoothPlastic
	body.Anchored       = true
	body.CanCollide     = false
	body.CastShadow     = false
	body.CanQuery       = false
	body.Parent         = parent

	-- Shared geometry from the single-source-of-truth blueprint.
	local blueprint = UnitBlueprints.get(unitType, body.Size)
	if blueprint then
		applyBlueprint(parent, body, blueprint)
	end

	-- Preview-only addons (diverge from the live unit, so not in the blueprint):
	if unitType == "Howitzer" then
		addWalkerLegsPreview(parent, body)   -- live unit uses animated WalkerLegs
	end
	if unitType == "Lamprey" then
		body.Transparency = 1   -- live unit + preview draw the eel, not the pivot block
		addLampreyPreview(parent, body)
	end
	if unitType == "Hagfish" then
		body.Transparency = 1   -- live unit + preview draw the hagfish, not the pivot block
		addHagfishPreview(parent, body)
	end
	if unitType == "Broodmother" then
		body.Transparency = 1   -- live unit + preview draw the creature, not the pivot block
		addBroodmotherPreview(parent, body)
	end

	return body
end

--[[
	Builds a static building model under `parent` for ViewportFrame display.
	All parts are anchored. Returns the root BasePart ("Base").
	teamColor: BrickColor for team-tinted parts (defaults to medium blue).
	upgradeType: optional turret upgrade to visually apply (e.g. "Flamethrower").
]]
function UnitVisuals.buildBuildingPreview(
	parent:      Instance,
	buildingType: string,
	teamColor:   BrickColor?,
	upgradeType: string?
): BasePart?
	local size  = buildingSize(buildingType)
	local color: BrickColor = teamColor or DEFAULT_TEAM
	-- position parameter mirrors createBuilding's `position` argument — kept at zero
	local position = Vector3.zero
	local rng = Random.new(12345)  -- fixed seed for deterministic bump layout

	local base          = makePart(parent)
	base.Name           = "Base"
	base.Size           = size
	base.Position       = Vector3.new(0, size.Y / 2, 0)
	base.BrickColor     = color
	base.Material       = Enum.Material.SmoothPlastic

	-- ── Type-specific accessories ─────────────────────────────────────────────

	if buildingType == "CommandCenter" then
		-- Industrial Fabricator Core — base block is the team-coloured housing
		-- visible between the platform rings; everything else is shared decor.
		base.Material = Enum.Material.Metal
		UnitVisuals.buildCommandCenterDecor(parent, CFrame.new(position), color, false)

	elseif buildingType == "Foundry" then
		-- Foundry: team-coloured base stays as the invisible logic box; all decoration
		-- comes from the shared builder so the thumbnail matches the live building.
		base.Transparency = 1
		UnitVisuals.buildFoundryDecor(parent, CFrame.new(position), color, false)

	elseif buildingType == "EngineeringPost" then
		base.Transparency = 1
		UnitVisuals.buildEngineeringPostDecor(parent, CFrame.new(position), color, false)

	elseif buildingType == "Turret" then
		-- Military tripod machine gun — matches BuildingManager's in-world geometry
		local grey = BrickColor.new("Dark stone grey")

		-- Repurpose base as the central mounting hub/platform
		base.BrickColor = grey
		base.Material   = Enum.Material.Metal
		base.Size       = Vector3.new(9, 2.5, 7)
		base.Position   = position + Vector3.new(0, 5.75, 0)

		-- Three tripod legs (two front, one rear)
		local legDefs = {
			{ top = Vector3.new(-2.5, 5.5,  1.5), foot = Vector3.new(-7, 0.4,  8) },
			{ top = Vector3.new( 2.5, 5.5,  1.5), foot = Vector3.new( 7, 0.4,  8) },
			{ top = Vector3.new( 0,   5.5, -1.5), foot = Vector3.new( 0, 0.4, -8) },
		}
		for _, l in legDefs do
			local topW  = position + l.top
			local footW = position + l.foot
			local mid   = (topW + footW) * 0.5
			local len   = (topW - footW).Magnitude
			local leg   = makePart(parent)
			leg.Name    = "Leg"
			leg.Size    = Vector3.new(1.6, len, 1.6)
			leg.BrickColor = grey; leg.Material = Enum.Material.Metal
			leg.CFrame  = CFrame.lookAt(mid, footW) * CFrame.Angles(math.pi / 2, 0, 0)
			local pad   = makePart(parent)
			pad.Name    = "FootPad"
			pad.Size    = Vector3.new(3, 0.5, 3)
			pad.Position = position + Vector3.new(l.foot.X, 0.25, l.foot.Z)
			pad.BrickColor = grey; pad.Material = Enum.Material.Metal
		end

		-- Vertical post connecting hub to gun mount
		local post     = makePart(parent)
		post.Name      = "Post"
		post.Size      = Vector3.new(1.4, 2.5, 1.4)
		post.Position  = position + Vector3.new(0, 8.25, 0)
		post.BrickColor = grey; post.Material = Enum.Material.Metal

		-- Machine gun receiver — MUST remain "Head" (attack system rotates this)
		local head     = makePart(parent)
		head.Name      = "Head"
		head.Size      = Vector3.new(3.2, 2, 4)
		head.Position  = position + Vector3.new(0, 9.75, 0)
		head.BrickColor = grey; head.Material = Enum.Material.Metal

		-- Barrel — MUST remain "Barrel"
		local barrel   = makePart(parent)
		barrel.Name    = "Barrel"
		barrel.Size    = Vector3.new(0.7, 0.7, 7)
		barrel.Position = position + Vector3.new(0, 9.75, 3.5)
		barrel.BrickColor = grey; barrel.Material = Enum.Material.Metal

		-- Rear sight stub
		local sight    = makePart(parent)
		sight.Name     = "Sight"
		sight.Size     = Vector3.new(0.4, 0.7, 0.4)
		sight.Position = position + Vector3.new(0, 10.85, -1.2)
		sight.BrickColor = grey; sight.Material = Enum.Material.Metal

		-- Muzzle device
		local muzzle   = makePart(parent)
		muzzle.Name    = "Muzzle"
		muzzle.Size    = Vector3.new(1.1, 1.1, 0.6)
		muzzle.Position = position + Vector3.new(0, 9.75, 7.25)
		muzzle.BrickColor = grey; muzzle.Material = Enum.Material.Metal

		-- Neon accent ring at post/gun junction — MUST remain "Ring"
		local ring     = makePart(parent)
		ring.Name      = "Ring"
		ring.Size      = Vector3.new(3.2, 0.4, 3.2)
		ring.Position  = position + Vector3.new(0, 8.75, 0)
		ring.BrickColor = BrickColor.new("Bright red")
		ring.Material  = Enum.Material.Neon

		-- suppress unused-var warnings
		local _ = sight; _ = muzzle

		-- Apply upgrade visuals if requested
		if upgradeType == "Flamethrower" then
			head.BrickColor   = BrickColor.new("Bright orange")
			head.Material     = Enum.Material.Neon
			barrel.BrickColor = BrickColor.new("Bright orange")
			barrel.Material   = Enum.Material.Neon
			barrel.Size       = Vector3.new(2.4, 2.4, 5)
			ring.BrickColor   = BrickColor.new("Deep orange")
			ring.Size         = ring.Size + Vector3.new(0, 0.4, 0)
		elseif upgradeType == "RocketLauncher" then
			head.BrickColor   = BrickColor.new("Dark indigo")
			head.Material     = Enum.Material.SmoothPlastic
			head.Size         = head.Size + Vector3.new(1, 0.5, 1)
			barrel.BrickColor = BrickColor.new("Medium blue")
			barrel.Material   = Enum.Material.Metal
			barrel.Size       = Vector3.new(2.4, 2.4, 11)
			ring.BrickColor   = BrickColor.new("Medium blue")
			ring.Material     = Enum.Material.Neon
		elseif upgradeType == "Creepy" then
			head.BrickColor   = BrickColor.new("Black")
			head.Material     = Enum.Material.SmoothPlastic
			head.Size         = Vector3.new(6, 4, 6)
			barrel.Transparency = 1
			ring.BrickColor   = BrickColor.new("Black")
			ring.Material     = Enum.Material.SmoothPlastic
			ring.Size         = ring.Size + Vector3.new(3, 0, 3)
		elseif upgradeType == "Artillery" then
			-- Massive siege piece: huge mantlet + three long nozzles on a pedestal
			local steel = BrickColor.new("Dark stone grey")
			local black = BrickColor.new("Really black")
			local glow  = BrickColor.new("Deep orange")
			head.BrickColor   = steel
			head.Material     = Enum.Material.Metal
			head.Size         = Vector3.new(8, 6, 9)
			barrel.Transparency = 1
			ring.BrickColor   = black
			ring.Material     = Enum.Material.Metal
			ring.Size         = Vector3.new(7.5, 1.4, 7.5)

			local hp = head.Position
			local function ap(sz: Vector3, cf: CFrame, bc: BrickColor, mat: Enum.Material, shape: Enum.PartType?): Part
				local p      = makePart(parent)
				if shape then (p :: any).Shape = shape end
				p.Size       = sz
				p.CFrame     = cf
				p.BrickColor = bc
				p.Material   = mat
				return p
			end
			ap(Vector3.new(7, 3.5, 7), CFrame.new(hp + Vector3.new(0, -3, 0)), black, Enum.Material.Metal)
			ap(Vector3.new(0.7, 7.6, 7.6),
				CFrame.new(hp + Vector3.new(0, -3, 0)) * CFrame.Angles(0, 0, math.pi / 2),
				glow, Enum.Material.Neon, Enum.PartType.Cylinder)
			for _, off in { -2.1, 0, 2.1 } do
				local center = hp + Vector3.new(off, 0, 6)
				ap(Vector3.new(1.5, 1.5, 14), CFrame.new(center, center + Vector3.new(0, 0, 1)), steel, Enum.Material.Metal)
			end
		end

	elseif buildingType == "Monument" then
		base.BrickColor = BrickColor.new("Light stone grey")
		base.Material   = Enum.Material.SmoothPlastic

		local tip        = makePart(parent)
		tip.Name         = "Tip"
		tip.Shape        = Enum.PartType.Ball
		tip.Size         = Vector3.new(3.5, 3.5, 3.5)
		tip.Position     = position + Vector3.new(0, size.Y + 1.75, 0)
		tip.BrickColor   = BrickColor.new("Bright yellow")
		tip.Material     = Enum.Material.Neon

		for i = 1, 2 do
			local ring       = makePart(parent)
			ring.Name        = "Ring" .. i
			ring.Shape       = Enum.PartType.Cylinder
			ring.Size        = Vector3.new(0.35, 8, 8)
			ring.CFrame      = CFrame.new(position + Vector3.new(0, size.Y * (i / 3 + 0.05), 0))
				* CFrame.Angles(0, 0, math.pi / 2)
			ring.BrickColor  = BrickColor.new("Bright yellow")
			ring.Material    = Enum.Material.Neon
		end

	elseif buildingType == "Relay" then
		local pole       = makePart(parent)
		pole.Name        = "Pole"
		pole.Size        = Vector3.new(1, size.Y + 6, 1)
		pole.Position    = position + Vector3.new(0, (size.Y + 6) / 2, 0)
		pole.BrickColor  = BrickColor.new("Dark stone grey")
		pole.Material    = Enum.Material.Metal

		local orb        = makePart(parent)
		orb.Name         = "Orb"
		orb.Shape        = Enum.PartType.Ball
		orb.Size         = Vector3.new(2.5, 2.5, 2.5)
		orb.Position     = position + Vector3.new(0, size.Y + 7.25, 0)
		orb.BrickColor   = color
		orb.Material     = Enum.Material.Neon

		local ring        = makePart(parent)
		ring.Name         = "Ring"
		ring.Shape        = Enum.PartType.Cylinder
		ring.Size         = Vector3.new(0.3, 4, 4)
		ring.CFrame       = CFrame.new(position + Vector3.new(0, size.Y + 6, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		ring.BrickColor   = color
		ring.Material     = Enum.Material.Neon

	elseif buildingType == "CreepyBlob" then
		base.BrickColor = BrickColor.new("Black")
		base.Material   = Enum.Material.SmoothPlastic

		for i = 1, 5 do
			local angle   = (i / 5) * math.pi * 2
			local r       = 2.8
			local bump         = makePart(parent)
			bump.Name          = "Bump_" .. i
			bump.Shape         = Enum.PartType.Ball
			bump.Size          = Vector3.new(
				rng:NextNumber(2.2, 3.2),
				rng:NextNumber(2.0, 3.0),
				rng:NextNumber(2.2, 3.2)
			)
			bump.Position      = position + Vector3.new(math.cos(angle) * r, size.Y - 0.5, math.sin(angle) * r)
			bump.BrickColor    = BrickColor.new("Black")
			bump.Material      = Enum.Material.SmoothPlastic
		end

		local eye          = makePart(parent)
		eye.Name           = "Eye"
		eye.Shape          = Enum.PartType.Ball
		eye.Size           = Vector3.new(1.8, 1.8, 1.8)
		eye.Position       = position + Vector3.new(0, size.Y + 0.8, 0)
		eye.BrickColor     = BrickColor.new("Dark indigo")
		eye.Material       = Enum.Material.Neon

	elseif buildingType == "CreepyWorm" then
		base.BrickColor = BrickColor.new("Black")
		base.Material   = Enum.Material.SmoothPlastic

		local spineCount = 6
		for i = 1, spineCount do
			local angle  = (i / spineCount) * math.pi * 2
			local r      = 3.0
			local spine         = makePart(parent)
			spine.Name          = "Spine_" .. i
			spine.Size          = Vector3.new(0.8, 3.5, 0.8)
			spine.BrickColor    = BrickColor.new("Black")
			spine.Material      = Enum.Material.SmoothPlastic
			spine.CFrame        = CFrame.new(position + Vector3.new(math.cos(angle) * r, size.Y + 0.75, math.sin(angle) * r))
				* CFrame.Angles(math.sin(angle) * 0.28, 0, -math.cos(angle) * 0.28)
		end

	elseif buildingType == "Deployer" then
		-- Deployer: armored auto-spawn bay (preview).
		base.Size      = Vector3.new(10, 0.5, 10)
		base.Position  = Vector3.new(0, 0.25, 0)
		base.BrickColor = BrickColor.new("Dark stone grey")
		base.Material   = Enum.Material.Metal

		local grey = BrickColor.new("Dark stone grey")

		local bw2 = makePart(parent); bw2.Size = Vector3.new(9.3, 4.5, 0.7); bw2.Position = Vector3.new(0, 2.75, -5.35);   bw2.BrickColor = color; bw2.Material = Enum.Material.SmoothPlastic
		local lw2 = makePart(parent); lw2.Size = Vector3.new(0.7, 4.5, 10.7); lw2.Position = Vector3.new(-5.35, 2.75, 0); lw2.BrickColor = color; lw2.Material = Enum.Material.SmoothPlastic
		local rw2 = makePart(parent); rw2.Size = Vector3.new(0.7, 4.5, 10.7); rw2.Position = Vector3.new( 5.35, 2.75, 0); rw2.BrickColor = color; rw2.Material = Enum.Material.SmoothPlastic
		local rf2 = makePart(parent); rf2.Size = Vector3.new(9.3, 0.4, 5.3);  rf2.Position = Vector3.new(0, 5.2, -2.65);   rf2.BrickColor = grey;  rf2.Material = Enum.Material.DiamondPlate
		local ob2 = makePart(parent); ob2.Size = Vector3.new(10.7, 0.5, 0.7); ob2.Position = Vector3.new(0, 5.2, 2.35);    ob2.BrickColor = color; ob2.Material = Enum.Material.SmoothPlastic
		local rl  = makePart(parent); rl.Size  = Vector3.new(0.4, 1.2, 4);    rl.Position  = Vector3.new(-4.8, 1.1, 2.5);  rl.BrickColor  = grey;  rl.Material  = Enum.Material.Metal
		local rr  = makePart(parent); rr.Size  = Vector3.new(0.4, 1.2, 4);    rr.Position  = Vector3.new( 4.8, 1.1, 2.5);  rr.BrickColor  = grey;  rr.Material  = Enum.Material.Metal
		local dp  = makePart(parent); dp.Name  = "DeployPad"; dp.Size = Vector3.new(6, 0.2, 6); dp.Position = Vector3.new(0, 0.7, 0); dp.BrickColor = color; dp.Material = Enum.Material.Neon
		local ns2 = makePart(parent); ns2.Size = Vector3.new(9.3, 0.3, 0.3);  ns2.Position = Vector3.new(0, 5.2, -5.35);   ns2.BrickColor = color; ns2.Material = Enum.Material.Neon
		local sl  = makePart(parent); sl.Shape = Enum.PartType.Ball; sl.Size = Vector3.new(0.8, 0.8, 0.8); sl.Position = Vector3.new(-5.35, 5.45, -5.35); sl.BrickColor = color; sl.Material = Enum.Material.Neon
		local sr  = makePart(parent); sr.Shape = Enum.PartType.Ball; sr.Size = Vector3.new(0.8, 0.8, 0.8); sr.Position = Vector3.new( 5.35, 5.45, -5.35); sr.BrickColor = color; sr.Material = Enum.Material.Neon
		local ap  = makePart(parent); ap.Size  = Vector3.new(0.3, 2.5, 0.3);  ap.Position  = Vector3.new(0, 6.5, -4.5);    ap.BrickColor  = grey;  ap.Material  = Enum.Material.Metal
		local an  = makePart(parent); an.Size  = Vector3.new(0.15, 1.2, 1.8); an.Position  = Vector3.new(1.1, 7.35, -4.5); an.BrickColor  = color; an.Material  = Enum.Material.Neon
		local _ = bw2; _ = lw2; _ = rw2; _ = rf2; _ = ob2; _ = rl; _ = rr; _ = dp; _ = ns2; _ = sl; _ = sr; _ = ap; _ = an

	elseif buildingType == "LampreyNest" then
		-- Lamprey Nest (preview): invisible base; the egg-tipped tentacle cluster comes
		-- from the shared builder so the thumbnail matches the live building exactly.
		base.Transparency = 1
		UnitVisuals.buildLampreyNestDecor(parent, CFrame.new(position), color, false)

	else
		-- Barracks: open-top training facility (preview).
		-- Repurpose base as the foundation floor so the camera frames it correctly.
		base.Size      = Vector3.new(10, 0.7, 10)
		base.Position  = Vector3.new(0, 0.35, 0)
		base.BrickColor = BrickColor.new("Dark stone grey")
		base.Material   = Enum.Material.Metal

		local grey = BrickColor.new("Dark stone grey")

		-- Side walls
		local lw = makePart(parent); lw.Size = Vector3.new(0.7, 6.3, 10.7); lw.Position = Vector3.new(-5.35, 3.85, 0); lw.BrickColor = color; lw.Material = Enum.Material.SmoothPlastic
		local rw = makePart(parent); rw.Size = Vector3.new(0.7, 6.3, 10.7); rw.Position = Vector3.new( 5.35, 3.85, 0); rw.BrickColor = color; rw.Material = Enum.Material.SmoothPlastic
		-- Back wall
		local bw = makePart(parent); bw.Size = Vector3.new(9.3, 6.3, 0.7);  bw.Position = Vector3.new(0, 3.85, -5.35); bw.BrickColor = color; bw.Material = Enum.Material.SmoothPlastic
		-- Front pillars
		local pl = makePart(parent); pl.Size = Vector3.new(0.7, 6.3, 0.7);  pl.Position = Vector3.new(-4.65, 3.85, 5.35); pl.BrickColor = color; pl.Material = Enum.Material.SmoothPlastic
		local pr = makePart(parent); pr.Size = Vector3.new(0.7, 6.3, 0.7);  pr.Position = Vector3.new( 4.65, 3.85, 5.35); pr.BrickColor = color; pr.Material = Enum.Material.SmoothPlastic
		-- Top beam
		local tb = makePart(parent); tb.Size = Vector3.new(10.7, 0.6, 0.7); tb.Position = Vector3.new(0, 7.3, 5.35); tb.BrickColor = color; tb.Material = Enum.Material.SmoothPlastic
		-- Training pad
		local pad = makePart(parent); pad.Name = "TrainingPad"; pad.Size = Vector3.new(4, 0.2, 4); pad.Position = Vector3.new(0, 0.8, 0); pad.BrickColor = color; pad.Material = Enum.Material.Neon
		-- Neon accents
		local ns = makePart(parent); ns.Size = Vector3.new(9.3, 0.3, 0.3); ns.Position = Vector3.new(0, 7.3, -5.35); ns.BrickColor = color; ns.Material = Enum.Material.Neon
		local cl = makePart(parent); cl.Shape = Enum.PartType.Ball; cl.Size = Vector3.new(0.7, 0.7, 0.7); cl.Position = Vector3.new(-5.35, 7.3, -5.35); cl.BrickColor = color; cl.Material = Enum.Material.Neon
		local cr = makePart(parent); cr.Shape = Enum.PartType.Ball; cr.Size = Vector3.new(0.7, 0.7, 0.7); cr.Position = Vector3.new( 5.35, 7.3, -5.35); cr.BrickColor = color; cr.Material = Enum.Material.Neon
		-- Flag
		local fp = makePart(parent); fp.Size = Vector3.new(0.35, 3, 0.35);  fp.Position = Vector3.new(0, 8.5, -4.5);    fp.BrickColor = grey;  fp.Material = Enum.Material.Metal
		local fl = makePart(parent); fl.Size = Vector3.new(0.15, 1.4, 2.4); fl.Position = Vector3.new(1.25, 9.5, -4.5); fl.BrickColor = color; fl.Material = Enum.Material.Neon
		-- suppress unused warnings
		local _ = lw; _ = rw; _ = bw; _ = pl; _ = pr; _ = tb; _ = ns; _ = cl; _ = cr; _ = fp; _ = fl
	end

	return base
end

--[[
	Returns the distance from the unit's pivot (body centre) down to its visual bottom.
	Used to sit the training preview correctly on the barracks training pad.
]]
function UnitVisuals.getUnitPreviewBottomOffset(unitType: string): number
	if unitType == "Soldier" then
		return 1.75  -- pill half-height (total height 3.5)
	end
	if unitType == "Lamprey" then
		return 3.7   -- distance from origin pivot down to the dirt mound's base
	end
	if unitType == "Broodmother" then
		return 10.0  -- pivot centre sits 10 studs above the feet (ground at y = -10)
	end
	local typeDef = (Config.UNIT_TYPES :: any)[unitType]
	if typeDef then
		return typeDef.size.Y / 2
	end
	return 2.0
end

return UnitVisuals
