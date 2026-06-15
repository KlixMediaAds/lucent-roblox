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
	for _, spec in bp.parts do
		local p  = UnitBlueprints.instantiate(spec, body.CFrame, teamColor)
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

-- ── Building helpers ──────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Monument"      then return Config.MONUMENT_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	if buildingType == "CreepyWorm"    then return Vector3.new(8, 5, 8) end
	if buildingType == "CreepyBlob"    then return Vector3.new(9, 6, 9) end
	if buildingType == "LampreyNest"   then return Config.LAMPREY_NEST_SIZE end
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

	elseif buildingType == "Mine" then
		base.Size     = Vector3.new(10, 2, 10)
		base.Position = position + Vector3.new(0, 1, 0)
		base.Material = Enum.Material.Metal
		base.BrickColor = BrickColor.new("Dark stone grey")

		local shaft       = makePart(parent)
		shaft.Name        = "Shaft"
		shaft.Size        = Vector3.new(2, 9, 2)
		shaft.Position    = position + Vector3.new(0, 6.5, 0)
		shaft.BrickColor  = BrickColor.new("Dark stone grey")
		shaft.Material    = Enum.Material.Metal

		local ring        = makePart(parent)
		ring.Name         = "EmitterRing"
		ring.Shape        = Enum.PartType.Cylinder
		ring.Size         = Vector3.new(0.4, 7, 7)
		ring.CFrame       = CFrame.new(position + Vector3.new(0, 11.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		ring.BrickColor   = color
		ring.Material     = Enum.Material.Neon

		local emitter     = makePart(parent)
		emitter.Name      = "Emitter"
		emitter.Shape     = Enum.PartType.Ball
		emitter.Size      = Vector3.new(2, 2, 2)
		emitter.Position  = position + Vector3.new(0, 12.2, 0)
		emitter.BrickColor = color
		emitter.Material  = Enum.Material.Neon

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
		-- Lamprey Nest: organic mound + birth tubes around a green orifice (preview).
		local FLESH = Color3.fromRGB(40, 44, 52)
		local GREEN = Color3.fromRGB(120, 190, 60)

		base.Color    = FLESH
		base.Material = Enum.Material.SmoothPlastic

		for i = 1, 6 do
			local angle = (i / 6) * math.pi * 2
			local r     = 3.4
			local lump  = makePart(parent)
			lump.Name   = "Lump_" .. i
			lump.Shape  = Enum.PartType.Ball
			lump.Size   = Vector3.new(rng:NextNumber(2.6, 3.8), rng:NextNumber(2.2, 3.2), rng:NextNumber(2.6, 3.8))
			lump.Position = Vector3.new(math.cos(angle) * r, size.Y - 1.4, math.sin(angle) * r)
			lump.Color  = FLESH; lump.Material = Enum.Material.SmoothPlastic
		end

		local core    = makePart(parent)
		core.Name     = "Core"
		core.Shape    = Enum.PartType.Ball
		core.Size     = Vector3.new(3.4, 3.4, 3.4)
		core.Position = Vector3.new(0, size.Y + 0.3, 0)
		core.Color    = GREEN; core.Material = Enum.Material.Neon
		core.Transparency = 0.15

		local tubeCount = 5
		for i = 1, tubeCount do
			local angle  = (i / tubeCount) * math.pi * 2 + 0.3
			local r      = 3.1
			local lean   = 0.30
			local cf     = CFrame.new(Vector3.new(math.cos(angle) * r, size.Y + 1.4, math.sin(angle) * r))
				* CFrame.Angles(math.sin(angle) * lean, 0, -math.cos(angle) * lean)
			local tube   = makePart(parent)
			tube.Name    = "Tube_" .. i
			tube.Size    = Vector3.new(1.3, 4.4, 1.3)
			tube.CFrame  = cf
			tube.Color   = FLESH; tube.Material = Enum.Material.SmoothPlastic
			local tip    = makePart(parent)
			tip.Name     = "TubeTip_" .. i
			tip.Shape    = Enum.PartType.Ball
			tip.Size     = Vector3.new(1.0, 1.0, 1.0)
			tip.CFrame   = cf * CFrame.new(0, 2.4, 0)
			tip.Color    = GREEN; tip.Material = Enum.Material.Neon
			tip.Transparency = 0.2
		end

		local band   = makePart(parent)
		band.Name    = "TeamBand"
		band.Shape   = Enum.PartType.Cylinder
		band.Size    = Vector3.new(0.5, 11.6, 11.6)
		band.CFrame  = CFrame.new(Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		band.BrickColor = color; band.Material = Enum.Material.Neon

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
	local typeDef = (Config.UNIT_TYPES :: any)[unitType]
	if typeDef then
		return typeDef.size.Y / 2
	end
	return 2.0
end

return UnitVisuals
