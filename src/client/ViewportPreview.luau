--[[
	ViewportPreview — Centralized 3D thumbnail renderer for the UI.

	Creates a ViewportFrame containing a static 3D model of any unit or building.
	Uses UnitVisuals to build models so previews always match in-game appearance.

	Usage:
	  local vpf = ViewportPreview.forUnit("Survivor", Vector2.new(52, 52))
	  local vpf = ViewportPreview.forBuilding("Turret", Vector2.new(52, 52))
	  vpf.Parent = someButton

	No RunService updates — models are purely static.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local ViewportPreview = {}

-- ── Camera framing ────────────────────────────────────────────────────────────

local FOV = 28  -- narrow = quasi-orthographic, minimal perspective distortion

local function frameCameraOnParts(cam: Camera, parts: { BasePart })
	local minX, minY, minZ =  math.huge,  math.huge,  math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

	for _, p in parts do
		if p.Transparency >= 0.99 then continue end  -- skip invisible logic parts
		local pos = p.Position
		local hs  = p.Size / 2
		if minX > pos.X - hs.X then minX = pos.X - hs.X end
		if minY > pos.Y - hs.Y then minY = pos.Y - hs.Y end
		if minZ > pos.Z - hs.Z then minZ = pos.Z - hs.Z end
		if maxX < pos.X + hs.X then maxX = pos.X + hs.X end
		if maxY < pos.Y + hs.Y then maxY = pos.Y + hs.Y end
		if maxZ < pos.Z + hs.Z then maxZ = pos.Z + hs.Z end
	end

	local center = Vector3.new(
		(minX + maxX) / 2,
		(minY + maxY) / 2,
		(minZ + maxZ) / 2
	)
	local maxExtent = math.max(maxX - minX, maxY - minY, maxZ - minZ)

	-- Fit the bounding sphere within the FOV with a small margin
	local halfFovRad = math.rad(FOV / 2)
	local distance   = (maxExtent / 2) / math.tan(halfFovRad) * 1.15

	-- 3/4 view: 40° yaw, 22° pitch — readable for both tall and wide models
	local yaw   = math.rad(40)
	local pitch = math.rad(22)
	local dir   = Vector3.new(
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw)
	)

	cam.FieldOfView = FOV
	cam.CFrame      = CFrame.lookAt(center + dir * distance, center)
end

-- ── Internal builder ──────────────────────────────────────────────────────────

local function build(pixelSize: Vector2, populate: (Instance) -> ()): ViewportFrame
	local vpf                    = Instance.new("ViewportFrame")
	vpf.Size                     = UDim2.fromOffset(pixelSize.X, pixelSize.Y)
	vpf.BackgroundTransparency   = 1
	vpf.BorderSizePixel          = 0
	vpf.Ambient                  = Color3.fromRGB(180, 180, 180)
	vpf.LightColor               = Color3.fromRGB(255, 255, 255)
	vpf.LightDirection           = Vector3.new(-1, -2, -1)

	-- Populate model parts directly inside the ViewportFrame
	populate(vpf)

	-- Collect all BaseParts for camera framing
	local parts: { BasePart } = {}
	for _, d in vpf:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d :: BasePart)
		end
	end

	if #parts > 0 then
		local cam        = Instance.new("Camera")
		cam.Parent       = vpf
		vpf.CurrentCamera = cam
		frameCameraOnParts(cam, parts)
	end

	return vpf
end

-- ── Orbit builder ─────────────────────────────────────────────────────────────

export type Orbit = {
	vpf:    ViewportFrame,
	setYaw: (yaw: number) -> (),  -- radians; orbits the camera around the model
}

-- Like build(), but returns a controller so the caller can spin the camera around
-- the framed model. The camera distance is fit to the model's bounding sphere, so
-- any unit/building stays fully visible regardless of size.
local function buildOrbit(pixelSize: Vector2, populate: (Instance) -> ()): Orbit
	local vpf                  = Instance.new("ViewportFrame")
	vpf.Size                   = UDim2.fromOffset(pixelSize.X, pixelSize.Y)
	vpf.BackgroundTransparency = 1
	vpf.BorderSizePixel        = 0
	vpf.Ambient                = Color3.fromRGB(180, 180, 180)
	vpf.LightColor             = Color3.fromRGB(255, 255, 255)
	vpf.LightDirection         = Vector3.new(-1, -2, -1)

	populate(vpf)

	local minX, minY, minZ =  math.huge,  math.huge,  math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in vpf:GetDescendants() do
		if p:IsA("BasePart") and p.Transparency < 0.99 then
			local pos = p.Position
			local hs  = p.Size / 2
			if minX > pos.X - hs.X then minX = pos.X - hs.X end
			if minY > pos.Y - hs.Y then minY = pos.Y - hs.Y end
			if minZ > pos.Z - hs.Z then minZ = pos.Z - hs.Z end
			if maxX < pos.X + hs.X then maxX = pos.X + hs.X end
			if maxY < pos.Y + hs.Y then maxY = pos.Y + hs.Y end
			if maxZ < pos.Z + hs.Z then maxZ = pos.Z + hs.Z end
		end
	end

	local center   = Vector3.new(0, 0, 0)
	local distance  = 20
	if minX <= maxX then
		center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
		local maxExtent = math.max(maxX - minX, maxY - minY, maxZ - minZ)
		distance = (maxExtent / 2) / math.tan(math.rad(FOV / 2)) * 1.25
	end

	local cam         = Instance.new("Camera")
	cam.FieldOfView   = FOV
	cam.Parent        = vpf
	vpf.CurrentCamera = cam

	local pitch = math.rad(20)
	local function setYaw(yaw: number)
		local dir = Vector3.new(
			math.cos(pitch) * math.sin(yaw),
			math.sin(pitch),
			math.cos(pitch) * math.cos(yaw)
		)
		cam.CFrame = CFrame.lookAt(center + dir * distance, center)
	end
	setYaw(math.rad(35))

	return { vpf = vpf, setYaw = setYaw }
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Rotatable preview of a unit. Returns an Orbit; caller drives setYaw each frame.
function ViewportPreview.forUnitOrbit(unitType: string, pixelSize: Vector2, teamColor: BrickColor?): Orbit
	return buildOrbit(pixelSize, function(vpf)
		UnitVisuals.buildUnitPreview(vpf, unitType, teamColor)
	end)
end

-- Rotatable preview of a building. Returns an Orbit; caller drives setYaw each frame.
function ViewportPreview.forBuildingOrbit(buildingType: string, pixelSize: Vector2, teamColor: BrickColor?): Orbit
	return buildOrbit(pixelSize, function(vpf)
		UnitVisuals.buildBuildingPreview(vpf, buildingType, teamColor)
	end)
end

--[[
	Returns a new ViewportFrame displaying the given unit type.
	pixelSize: pixel dimensions (e.g. Vector2.new(52, 52)).
	teamColor: optional BrickColor for the unit body.
]]
function ViewportPreview.forUnit(unitType: string, pixelSize: Vector2, teamColor: BrickColor?): ViewportFrame
	return build(pixelSize, function(vpf)
		UnitVisuals.buildUnitPreview(vpf, unitType, teamColor)
	end)
end

--[[
	Returns a new ViewportFrame displaying the given building type.
	pixelSize: pixel dimensions.
	teamColor: optional BrickColor for team-tinted surfaces.
	upgradeType: optional turret upgrade to visualise (e.g. "Flamethrower").
]]
function ViewportPreview.forBuilding(
	buildingType: string,
	pixelSize:    Vector2,
	teamColor:    BrickColor?,
	upgradeType:  string?
): ViewportFrame
	return build(pixelSize, function(vpf)
		UnitVisuals.buildBuildingPreview(vpf, buildingType, teamColor, upgradeType)
	end)
end

-- Preview of a Leech in a chosen pose: arched = false → mobile crawling worm;
-- arched = true → burrowed feeding pose (rainbow arch). Used by the Mother build grid
-- (mobile) and the Leech command card (arched = burrow, mobile = unburrow).
function ViewportPreview.forLeech(arched: boolean, pixelSize: Vector2, teamColor: BrickColor?): ViewportFrame
	return build(pixelSize, function(vpf)
		UnitVisuals.buildLeechPreview(vpf, arched, teamColor)
	end)
end

-- Preview of the Mother's Egg Sacs nest — the same fleshy egg-clutch nest planted in
-- the world, with a bright incubating egg settled in its bowl so the tile reads as
-- "a nest with an egg in it". Used by the Mother command card's Egg Sacs tile.
function ViewportPreview.forEggSacNest(pixelSize: Vector2, teamColor: BrickColor?): ViewportFrame
	return build(pixelSize, function(vpf)
		UnitVisuals.buildMotherNestDecor(vpf, CFrame.new(), teamColor or BrickColor.new("Bright violet"), false)
		-- A prominent glowing egg sitting in the clutch (matches the live hatch egg).
		local egg      = Instance.new("Part")
		egg.Shape      = Enum.PartType.Ball
		egg.Size       = Vector3.new(2.4, 3.0, 2.4)
		egg.CFrame     = CFrame.new(0, 2.4, 0)
		egg.Color      = Color3.fromRGB(255, 120, 60)
		egg.Material   = Enum.Material.Neon
		egg.Anchored   = true
		egg.CanCollide = false
		egg.CastShadow = false
		egg.Parent     = vpf
	end)
end

-- A bespoke icon for the Bonfire's "Empower" upgrade: a violet flame crowned by a
-- glowing gold up-chevron (capacity/speed rising). Built here so it renders with the
-- same framing/lighting as the other 3D slot icons.
function ViewportPreview.forBonfireUpgrade(pixelSize: Vector2): ViewportFrame
	return build(pixelSize, function(vpf)
		local function part(size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?): Part
			local p      = Instance.new("Part")
			if shape then (p :: any).Shape = shape end
			p.Size       = size
			p.CFrame     = cf
			p.Color      = color
			p.Material   = Enum.Material.Neon
			p.Anchored   = true
			p.CanCollide = false
			p.CastShadow = false
			p.Parent     = vpf
			return p
		end
		-- Violet flame (rising, fading tip)
		part(Vector3.new(2.0, 2.6, 2.0), CFrame.new(0, 0.0, 0), Color3.fromRGB(150,  70, 235), Enum.PartType.Ball)
		part(Vector3.new(1.4, 1.9, 1.4), CFrame.new(0, 1.1, 0), Color3.fromRGB(190, 110, 255), Enum.PartType.Ball)
		part(Vector3.new(0.8, 1.1, 0.8), CFrame.new(0, 2.0, 0), Color3.fromRGB(225, 180, 255), Enum.PartType.Ball)
		-- Gold up-chevron (the two bars meet at the top centre → "^")
		local gold = Color3.fromRGB(245, 205, 110)
		part(Vector3.new(0.5, 2.0, 0.5), CFrame.new(-0.75, 3.3, 0) * CFrame.Angles(0, 0, math.rad(-40)), gold)
		part(Vector3.new(0.5, 2.0, 0.5), CFrame.new( 0.75, 3.3, 0) * CFrame.Angles(0, 0, math.rad( 40)), gold)
	end)
end

return ViewportPreview
