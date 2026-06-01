--[[
	UnitVisuals — Shared procedural visual builders for units and buildings.

	Used by ViewportPreview (client) to produce static 3D thumbnails.
	Visual logic here must stay in sync with UnitManager and BuildingManager
	whenever those files update a unit or building's appearance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local UnitVisuals = {}

local DEFAULT_TEAM = BrickColor.new("Medium blue")

-- ── Unit helpers ──────────────────────────────────────────────────────────────

local function addTankTreads(body: BasePart)
	local halfX   = body.Size.X / 2 + 0.75
	local offsetY = -(body.Size.Y / 2) + 1.1
	for _, side in { -1, 1 } do
		local tread          = Instance.new("Part")
		tread.Name           = "Tread"
		tread.Size           = Vector3.new(1.5, 2.2, body.Size.Z + 1.5)
		tread.BrickColor     = BrickColor.new("Dark stone grey")
		tread.Material       = Enum.Material.SmoothPlastic
		tread.Anchored       = true
		tread.CanCollide     = false
		tread.CastShadow     = false
		tread.CanQuery       = false
		tread.CFrame         = body.CFrame * CFrame.new(side * halfX, offsetY, 0)
		tread.Parent         = body.Parent
	end
end

local function makeEye(parent: Instance, cf: CFrame, name: string, eyeSize: number)
	local sclera        = Instance.new("Part")
	sclera.Name         = name
	sclera.Shape        = Enum.PartType.Ball
	sclera.Size         = Vector3.new(eyeSize, eyeSize, eyeSize)
	sclera.Color        = Color3.fromRGB(255, 255, 255)
	sclera.Material     = Enum.Material.SmoothPlastic
	sclera.Anchored     = true
	sclera.CanCollide   = false
	sclera.CastShadow   = false
	sclera.CanQuery     = false
	sclera.CFrame       = cf
	sclera.Parent       = parent

	local iris          = Instance.new("Part")
	iris.Name           = "_Iris"
	iris.Shape          = Enum.PartType.Ball
	iris.Size           = Vector3.new(eyeSize * 0.42, eyeSize * 0.42, eyeSize * 0.42)
	iris.Color          = Color3.fromRGB(255, 30, 0)
	iris.Material       = Enum.Material.Neon
	iris.Anchored       = true
	iris.CanCollide     = false
	iris.CastShadow     = false
	iris.CanQuery       = false
	iris.CFrame         = cf * CFrame.new(0, 0, -eyeSize * 0.3)
	iris.Parent         = parent

	local pupil         = Instance.new("Part")
	pupil.Name          = "_Pupil"
	pupil.Shape         = Enum.PartType.Ball
	pupil.Size          = Vector3.new(eyeSize * 0.2, eyeSize * 0.2, eyeSize * 0.2)
	pupil.Color         = Color3.fromRGB(0, 0, 0)
	pupil.Material      = Enum.Material.SmoothPlastic
	pupil.Anchored      = true
	pupil.CanCollide    = false
	pupil.CastShadow    = false
	pupil.CanQuery      = false
	pupil.CFrame        = cf * CFrame.new(0, 0, -eyeSize * 0.44)
	pupil.Parent        = parent
end

local function addCreepyEyes(parent: Instance, body: BasePart, unitType: string)
	if unitType == "Soldier" then
		local halfX   = body.Size.X / 2
		local eyeSize = 2.4
		makeEye(parent, body.CFrame * CFrame.new(-halfX + eyeSize * 0.1, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), "_EyeL", eyeSize)
		makeEye(parent, body.CFrame * CFrame.new(halfX - eyeSize * 0.1, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), "_EyeR", eyeSize)
	else
		local topY    = body.Size.Y / 2
		local halfX   = body.Size.X * 0.22
		local fwdZ    = -(body.Size.Z / 2) + 0.15
		local eyeSize = 1.5
		makeEye(parent, body.CFrame * CFrame.new(-halfX, topY * 0.28, fwdZ), "_EyeL", eyeSize)
		makeEye(parent, body.CFrame * CFrame.new( halfX, topY * 0.28, fwdZ), "_EyeR", eyeSize)
	end
end

local function addMedicCross(parent: Instance, body: BasePart)
	local topY = body.Size.Y / 2 + 0.18
	local function makeBar(sx: number, sz: number)
		local bar         = Instance.new("Part")
		bar.Size          = Vector3.new(sx, 0.3, sz)
		bar.BrickColor    = BrickColor.new("White")
		bar.Material      = Enum.Material.SmoothPlastic
		bar.Anchored      = true
		bar.CanCollide    = false
		bar.CastShadow    = false
		bar.CanQuery      = false
		bar.CFrame        = body.CFrame * CFrame.new(0, topY, 0)
		bar.Parent        = parent
	end
	makeBar(body.Size.X * 0.55, 0.7)
	makeBar(0.7, body.Size.Z * 0.55)
end

-- ── Building helpers ──────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Monument"      then return Config.MONUMENT_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	if buildingType == "CreepyWorm"    then return Vector3.new(8, 5, 8) end
	if buildingType == "CreepyBlob"    then return Vector3.new(9, 6, 9) end
	return Config.BUILDING_SIZE
end

local function makePart(parent: Instance): Part
	local p          = Instance.new("Part")
	p.Anchored       = true
	p.CanCollide     = false
	p.CastShadow     = false
	p.CanQuery       = false
	p.Parent         = parent
	return p
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

	-- ── Soldier: upright pill + gun ───────────────────────────────────────────
	if unitType == "Soldier" then
		local function ap(shape: Enum.PartType?, sz: Vector3, cf: CFrame, col: BrickColor): BasePart
			local p          = Instance.new("Part")
			if shape then (p :: any).Shape = shape end
			p.Size           = sz
			p.CFrame         = cf
			p.BrickColor     = col
			p.Material       = Enum.Material.SmoothPlastic
			p.Anchored       = true
			p.CanCollide     = false
			p.CastShadow     = false
			p.CanQuery       = false
			p.Parent         = parent
			return p
		end

		-- Cylinder torso standing upright (long axis rotated to Y)
		local cyl = ap(Enum.PartType.Cylinder,
			Vector3.new(1.5, 2.0, 2.0),
			CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.pi / 2),
			color)
		cyl.Name = "Soldier"

		-- Rounded caps
		ap(Enum.PartType.Ball, Vector3.new(2.0, 2.0, 2.0), CFrame.new(0,  0.75, 0), color)
		ap(Enum.PartType.Ball, Vector3.new(2.0, 2.0, 2.0), CFrame.new(0, -0.75, 0), color)

		-- Gun: dark rectangle, barrel pointing forward (-Z)
		ap(nil, Vector3.new(0.3, 0.25, 1.6), CFrame.new(1.15, 0.15, -0.3),
			BrickColor.new("Dark stone grey"))

		return cyl
	end

	-- ── Other units: base block body ──────────────────────────────────────────
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

	if unitType == "Tank" then
		addTankTreads(body)
	end
	if unitType == "Medic" then
		addMedicCross(parent, body)
	end
	if unitType == "CreepySoldier" then
		addCreepyEyes(parent, body, "Soldier")
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
		-- Neon collar rings on top and bottom edges
		local hw = size.X / 2
		local hd = size.Z / 2
		local collars = {
			position.Y + size.Y - 0.45,
			position.Y          + 0.45,
		}
		for _, cY in collars do
			local strips = {
				{ sz = Vector3.new(size.X + 0.4, 0.9, 0.3), pos = Vector3.new(0,       cY,  hd + 0.15) },
				{ sz = Vector3.new(size.X + 0.4, 0.9, 0.3), pos = Vector3.new(0,       cY, -hd - 0.15) },
				{ sz = Vector3.new(0.3, 0.9, size.Z + 0.4), pos = Vector3.new( hw+0.15, cY,  0        ) },
				{ sz = Vector3.new(0.3, 0.9, size.Z + 0.4), pos = Vector3.new(-hw-0.15, cY,  0        ) },
			}
			for _, s in strips do
				local strip       = makePart(parent)
				strip.Name        = "Collar"
				strip.Size        = s.sz
				strip.Position    = s.pos
				strip.BrickColor  = color
				strip.Material    = Enum.Material.Neon
			end
		end

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
		local head         = makePart(parent)
		head.Name          = "Head"
		head.Size          = Vector3.new(5, 3, 5)
		head.Position      = position + Vector3.new(0, size.Y + 1.5, 0)
		head.BrickColor    = BrickColor.new("Dark stone grey")
		head.Material      = Enum.Material.Metal

		local barrel       = makePart(parent)
		barrel.Name        = "Barrel"
		barrel.Size        = Vector3.new(1.2, 1.2, 7)
		barrel.Position    = position + Vector3.new(0, size.Y + 1.5, 3.5)
		barrel.BrickColor  = BrickColor.new("Dark stone grey")
		barrel.Material    = Enum.Material.Metal

		local ring         = makePart(parent)
		ring.Name          = "Ring"
		ring.Size          = Vector3.new(7, 0.4, 7)
		ring.Position      = position + Vector3.new(0, size.Y + 0.2, 0)
		ring.BrickColor    = BrickColor.new("Bright red")
		ring.Material      = Enum.Material.Neon

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
	local typeDef = (Config.UNIT_TYPES :: any)[unitType]
	if typeDef then
		return typeDef.size.Y / 2
	end
	return 2.0
end

return UnitVisuals
