--!strict
--[[
	InjectPlants: the growths the Hollowed Mother's "Inject" leaves in the ground.

	InjectPlants.VARIANTS                              → ordered variant names
	InjectPlants.INJECT[variant]                       → what injecting that plant gives
	InjectPlants.injectInfo(model)                     → that entry, off a grown plant
	InjectPlants.grow(parent, origin, variant, seed?)  → Model

	Three distinct plants come out of one injection, one of each variant:
		spire  : a tall segmented stalk topped with a glowing bulb
		frond  : a squat bulb that splays a fan of blades
		pods   : a low mound knotted with a cluster of glowing pods

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
export type InjectInfo = { label: string, yield: string, kind: string? }
InjectPlants.INJECT: { [string]: InjectInfo } = {
	spire = { label = "Spire",       yield = "3 LEECHES",   kind = "leeches" },
	pods  = { label = "Pod Cluster", yield = "2 NESTS",     kind = "nests"   },
	frond = { label = "Frond",       yield = "COMING SOON"                   },
}

-- The plant's entry, read off the Variant attribute grow() stamps on the model. Returns
-- nil for anything that isn't one of the Mother's plants.
function InjectPlants.injectInfo(model: Instance): InjectInfo?
	local variant = model:GetAttribute("Variant")
	if type(variant) ~= "string" then return nil end
	return InjectPlants.INJECT[variant]
end

local RISE_TIME = 1.3   -- seconds a plant takes to climb out of the ground

-- ── Palette (Hollowed flesh + bioluminescence) ────────────────────────────────
local STEM_COLS = {
	Color3.fromRGB(74, 38, 62),
	Color3.fromRGB(58, 30, 52),
	Color3.fromRGB(88, 46, 70),
}
local FLESH_COL = Color3.fromRGB(96, 42, 66)
local GLOW_COLS = {
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

local function glowBulb(parent: Instance, name: string, pos: Vector3, dia: number,
	col: Color3, light: boolean): BasePart
	local b        = part(parent, name, Vector3.new(dia, dia, dia),
		CFrame.new(pos), col, Enum.Material.Neon)
	b.Shape        = Enum.PartType.Ball
	b.Transparency = 0.12
	if light then
		local pl      = Instance.new("PointLight")
		pl.Color      = col
		pl.Brightness = 2.2
		pl.Range      = 12
		pl.Shadows    = false
		pl.Parent     = b
	end
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

	glowBulb(model, "Crown", cur + Vector3.new(0, 0.6, 0),
		r:NextNumber(2.2, 3.0), GLOW_COLS[r:NextInteger(1, #GLOW_COLS)], true)

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

-- A squat bulb that splays a fan of curved blades, tipped with light.
local function buildFrond(model: Model, r: Random, origin: Vector3): number
	local blades = r:NextInteger(6, 8)
	local height = r:NextNumber(6, 8)
	local col    = GLOW_COLS[r:NextInteger(1, #GLOW_COLS)]

	local bulb        = part(model, "Bulb", Vector3.new(3.2, 3.2, 3.2),
		CFrame.new(origin + Vector3.new(0, 1.0, 0)), FLESH_COL, Enum.Material.Glass)
	bulb.Shape        = Enum.PartType.Ball
	bulb.Transparency = 0.15

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
		glowBulb(model, "Tip" .. i, tip, r:NextNumber(0.7, 1.1), col, i <= 2)
	end

	return height + 2
end

-- A low mound knotted with glowing pods on short stems.
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
		glowBulb(model, "Pod" .. i, tip,
			r:NextNumber(1.3, 2.0), GLOW_COLS[r:NextInteger(1, #GLOW_COLS)], i <= 2)
		height = math.max(height, h)
	end

	return height + 3
end

-- ── Public API ────────────────────────────────────────────────────────────────
-- Builds `variant` at `origin` (ground level) under `parent` and drives it up out of
-- the ground. Returns the model immediately; the rise runs on its own thread.
function InjectPlants.grow(parent: Instance, origin: Vector3, variant: string, seed: number?): Model
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
	model:PivotTo(rest * CFrame.new(0, -depth, 0))
	model.Parent = parent

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
