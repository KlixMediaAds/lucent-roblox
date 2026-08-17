--!strict
--[[
	InjectPlants: the growths the Hollowed Mother's "Inject" leaves in the ground.

	InjectPlants.VARIANTS                              → ordered variant names
	InjectPlants.INJECT[variant]                       → what injecting that plant gives
	InjectPlants.injectInfo(model)                     → that entry, off a grown plant
	InjectPlants.grow(parent, origin, variant, seed?)  → Model
	InjectPlants.findSpot(folder, x, z, variant, rng?) → a spot with room, or nil

	Three distinct plants come out of one injection, one of each variant:
		spire  : a tall segmented stalk topped with a heavy bulb
		frond  : a squat bulb that splays a fan of blades
		pods   : a low mound knotted with a cluster of pods

	Each plant is built at its final resting place, then sunk under the surface and
	pushed back up, so it reads as tearing its way out of the soil. Everything is
	anchored, non-colliding and non-queryable: this is scenery, not a unit.
]]

local InjectPlants = {}

InjectPlants.VARIANTS = { "spire", "frond", "pods" }

-- What a grown plant gives up when the Mother drives her spike into IT rather than into
-- bare ground. Both sides read this one table: the targeting sight labels itself from
-- `label` / `yield`, and the server acts on `kind`. A plant with no `kind` cannot be
-- injected at all, so its yield line is what the sight shows instead.
-- `preview` names the 3D thumbnail the INJECT tile swaps to while the sight is over this
-- plant, so the player sees what it would become before spending on it. MotherPanel owns
-- the name → ViewportPreview mapping; a plant with no `kind` has nothing to show yet.
export type InjectInfo = { label: string, yield: string, kind: string?, preview: string? }
local INJECT: { [string]: InjectInfo } = {
	spire = { label = "Spire",       yield = "3 LEECHES",   kind = "leeches", preview = "leech" },
	pods  = { label = "Pod Cluster", yield = "2 EGG NESTS", kind = "nests",   preview = "nest"  },
	frond = { label = "Frond",       yield = "SPIKE GLAND",  kind = "glands",  preview = "gland" },
}
InjectPlants.INJECT = INJECT

-- The plant's entry, read off the Variant attribute grow() stamps on the model. Returns
-- nil for anything that isn't one of the Mother's plants.
function InjectPlants.injectInfo(model: Instance): InjectInfo?
	local variant = model:GetAttribute("Variant")
	if type(variant) ~= "string" then return nil end
	return InjectPlants.INJECT[variant]
end

-- ── Spacing ───────────────────────────────────────────────────────────────────
-- Roughly how far each variant's geometry sprawls from its centre at ground level: the
-- frond's blades throw the furthest, the spire is a narrow stalk with a ring of thorns.
-- Two plants closer than the sum of their radii grow THROUGH each other, and three
-- interpenetrating growths read as one tangle rather than as three things worth injecting.
local RADIUS: { [string]: number } = { spire = 3.4, frond = 6.2, pods = 4.0 }
InjectPlants.RADIUS = RADIUS

local function radiusOf(variant: string?): number
	return (type(variant) == "string" and RADIUS[variant]) or 4.5
end

-- Is (x, z) clear of every plant already standing in `folder`? Only X/Z matter: a plant
-- mid-rise is pivoted below the surface, but it comes up in the same place.
function InjectPlants.hasRoom(folder: Instance?, x: number, z: number, variant: string): boolean
	if not folder then return true end
	local r = radiusOf(variant)
	for _, child in folder:GetChildren() do
		if not child:IsA("Model") then continue end
		local need = r + radiusOf(child:GetAttribute("Variant") :: string?)
		local p    = child:GetPivot().Position
		local dx   = p.X - x
		local dz   = p.Z - z
		if dx * dx + dz * dz < need * need then return false end
	end
	return true
end

-- Somewhere near (x, z) with room for a `variant` plant: the wanted spot if it is clear,
-- otherwise spiralling outward from it in widening rings. Returns nil when there is no
-- room to be had nearby, and the caller is expected to grow NOTHING rather than stack one
-- plant inside another.
local SEARCH_RINGS = 6      -- how far out the search will push
local SEARCH_STEP  = 3.5    -- studs gained per ring
local SEARCH_ARC   = 8      -- candidate angles tried on each ring
function InjectPlants.findSpot(folder: Instance?, x: number, z: number, variant: string,
	rng: Random?): (number?, number?)
	if InjectPlants.hasRoom(folder, x, z, variant) then return x, z end
	-- Start each search at a random bearing, so plants shoved off their mark do not all
	-- drift the same way and turn a ring into a crescent.
	local spin = (rng or Random.new()):NextNumber(0, math.pi * 2)
	for ring = 1, SEARCH_RINGS do
		local d = ring * SEARCH_STEP
		for k = 0, SEARCH_ARC - 1 do
			local a  = spin + (k / SEARCH_ARC) * math.pi * 2
			local cx = x + math.cos(a) * d
			local cz = z + math.sin(a) * d
			if InjectPlants.hasRoom(folder, cx, cz, variant) then return cx, cz end
		end
	end
	return nil, nil
end

local RISE_TIME = 1.3   -- seconds a plant takes to climb out of the ground

-- ── Palette (Hollowed flesh) ──────────────────────────────────────────────────
local STEM_COLS = {
	Color3.fromRGB(74, 38, 62),
	Color3.fromRGB(58, 30, 52),
	Color3.fromRGB(88, 46, 70),
}
local FLESH_COL = Color3.fromRGB(96, 42, 66)
local BULB_COLS = {
	Color3.fromRGB(210, 85, 255),
	Color3.fromRGB(255, 95, 200),
	Color3.fromRGB(175, 75, 240),
}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function part(parent: Instance, name: string, size: Vector3, cf: CFrame,
	color: Color3, material: Enum.Material): BasePart
	local p      = Instance.new("Part")
	p.Name       = name
	p.Size       = size
	p.CFrame     = cf
	p.Color      = color
	p.Material   = material
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.CastShadow = false
	p.Parent     = parent
	return p
end

local function bulb(parent: Instance, name: string, pos: Vector3, dia: number,
	col: Color3): BasePart
	local b = part(parent, name, Vector3.new(dia, dia, dia),
		CFrame.new(pos), col, Enum.Material.SmoothPlastic)
	b.Shape = Enum.PartType.Ball
	return b
end

-- ── Variant builders ──────────────────────────────────────────────────────────
-- Each returns the plant's total height, which sets how deep it starts buried.

-- A tall leaning stalk of tapering segments with a bulb crown and a ring of thorns.
local function buildSpire(model: Model, r: Random, origin: Vector3): number
	local segs   = 4
	local height = r:NextNumber(9, 13)
	local segLen = height / segs
	local stem   = STEM_COLS[r:NextInteger(1, #STEM_COLS)]
	local lean   = r:NextNumber(0, math.pi * 2)
	local cur    = origin
	local dia    = r:NextNumber(1.5, 2.1)

	-- Each segment leans a little further off vertical than the one under it, so the
	-- stalk curves as it climbs.
	for i = 1, segs do
		local tilt = math.rad(5 * (i - 1))
		local root = CFrame.new(cur) * CFrame.Angles(0, -lean, 0) * CFrame.Angles(0, 0, tilt)
		part(model, "Seg" .. i, Vector3.new(dia, segLen * 1.06, dia),
			root * CFrame.new(0, segLen * 0.5, 0), stem, Enum.Material.Slate)
		cur = (root * CFrame.new(0, segLen, 0)).Position
		dia *= 0.78
	end

	bulb(model, "Crown", cur + Vector3.new(0, 0.6, 0),
		r:NextNumber(2.2, 3.0), BULB_COLS[r:NextInteger(1, #BULB_COLS)])

	-- Thorns kicked out around the base where the ground split.
	for i = 1, 5 do
		local a = (i / 5) * math.pi * 2 + r:NextNumber(-0.3, 0.3)
		local d = r:NextNumber(1.2, 2.0)
		local h = r:NextNumber(1.6, 2.8)
		local root = CFrame.new(origin + Vector3.new(math.cos(a) * d, 0.2, math.sin(a) * d))
			* CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, -math.rad(r:NextNumber(28, 50)))
		part(model, "Thorn" .. i, Vector3.new(0.45, h, 0.45),
			root * CFrame.new(0, h * 0.5, 0), stem, Enum.Material.Slate)
	end

	return height + 3
end

-- A squat bulb that splays a fan of curved blades, tipped with beads of flesh.
local function buildFrond(model: Model, r: Random, origin: Vector3): number
	local blades = r:NextInteger(6, 8)
	local height = r:NextNumber(6, 8)
	local col    = BULB_COLS[r:NextInteger(1, #BULB_COLS)]

	local core   = part(model, "Bulb", Vector3.new(3.2, 3.2, 3.2),
		CFrame.new(origin + Vector3.new(0, 1.0, 0)), FLESH_COL, Enum.Material.Slate)
	core.Shape   = Enum.PartType.Ball

	for i = 1, blades do
		local a    = (i / blades) * math.pi * 2 + r:NextNumber(-0.15, 0.15)
		local len  = height * r:NextNumber(0.72, 1.0)
		local tilt = math.rad(r:NextNumber(26, 48))
		-- Negative roll so the blade leans away from the middle (a fan, not a cup).
		local root = CFrame.new(origin + Vector3.new(0, 1.4, 0)) * CFrame.Angles(0, -a, 0)
			* CFrame.Angles(0, 0, -tilt)
		part(model, "Blade" .. i, Vector3.new(0.35, len, 1.5),
			root * CFrame.new(0, len * 0.5, 0),
			STEM_COLS[r:NextInteger(1, #STEM_COLS)], Enum.Material.Slate)
		local tip = (root * CFrame.new(0, len, 0)).Position
		bulb(model, "Tip" .. i, tip, r:NextNumber(0.7, 1.1), col)
	end

	return height + 2
end

-- A low mound knotted with pods on short stems.
local function buildPods(model: Model, r: Random, origin: Vector3): number
	-- Half-buried mound the pods grow out of.
	local mound        = part(model, "Mound", Vector3.new(4.6, 4.6, 4.6),
		CFrame.new(origin + Vector3.new(0, 0.4, 0)), FLESH_COL, Enum.Material.Slate)
	mound.Shape        = Enum.PartType.Ball

	local count  = r:NextInteger(5, 7)
	local height = 0
	for i = 1, count do
		local a    = (i / count) * math.pi * 2 + r:NextNumber(-0.25, 0.25)
		local d    = r:NextNumber(0.8, 2.2)
		local h    = r:NextNumber(2.4, 4.6)
		local foot = origin + Vector3.new(math.cos(a) * d, 0.6, math.sin(a) * d)
		-- Stems splay outward, away from the mound.
		local root = CFrame.new(foot) * CFrame.Angles(0, -a, 0)
			* CFrame.Angles(0, 0, -math.rad(r:NextNumber(8, 26)))
		part(model, "Stem" .. i, Vector3.new(0.55, h, 0.55),
			root * CFrame.new(0, h * 0.5, 0),
			STEM_COLS[r:NextInteger(1, #STEM_COLS)], Enum.Material.Slate)
		local tip = (root * CFrame.new(0, h + 0.5, 0)).Position
		bulb(model, "Pod" .. i, tip,
			r:NextNumber(1.3, 2.0), BULB_COLS[r:NextInteger(1, #BULB_COLS)])
		height = math.max(height, h)
	end

	return height + 3
end

-- ── Public API ────────────────────────────────────────────────────────────────
-- Builds `variant` at `origin` (ground level) under `parent` and drives it up out of
-- the ground. Returns the model immediately; the rise runs on its own thread.
--
-- `instant` skips the rise and stands the plant up where it belongs straight away. That
-- is for plants that were always there (WildPlants seeds the map with hundreds before
-- anyone can see it) rather than ones a spike just forced out of the soil.
function InjectPlants.grow(parent: Instance, origin: Vector3, variant: string, seed: number?,
	instant: boolean?): Model
	local r     = Random.new(seed or (os.clock() * 1e6) % 1e9)
	local model = Instance.new("Model")
	model.Name  = "InjectPlant_" .. variant
	model:SetAttribute("Variant", variant)

	local anchor        = Instance.new("Part")
	anchor.Name         = "Anchor"
	anchor.Size         = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame       = CFrame.new(origin)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CastShadow   = false
	anchor.Parent       = model
	model.PrimaryPart   = anchor

	local depth: number
	if variant == "frond" then
		depth = buildFrond(model, r, origin)
	elseif variant == "pods" then
		depth = buildPods(model, r, origin)
	else
		depth = buildSpire(model, r, origin)
	end

	-- Start fully buried, then climb. Terrain hides whatever is still underground, so
	-- the plant appears to shoulder its way out of the soil.
	local rest = model:GetPivot()
	model.Parent = parent
	if instant then return model end

	model:PivotTo(rest * CFrame.new(0, -depth, 0))

	task.spawn(function()
		local t0 = os.clock()
		while model.Parent do
			local k = math.min((os.clock() - t0) / RISE_TIME, 1)
			-- Ease out, with a small overshoot so it lurches up and settles back.
			local e = 1 - (1 - k) ^ 3
			local y = -depth * (1 - e) + math.sin(k * math.pi) * 0.5
			model:PivotTo(rest * CFrame.new(0, y, 0))
			if k >= 1 then break end
			task.wait()
		end
		if model.Parent then model:PivotTo(rest) end
	end)

	return model
end

return InjectPlants
