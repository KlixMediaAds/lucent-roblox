-- FungiCluster v4 — forest-scale bioluminescent colony with resource-state visualization.
--   FungiCluster.create(origin, seed?, fullness?)  → Model
--   FungiCluster.rebuild(model, fullness)           → regenerates colony in place

local FungiCluster = {}

-- ── Palette ───────────────────────────────────────────────────────────────────

local BULB_COLORS = {
	Color3.fromRGB(210,  85, 255),
	Color3.fromRGB(255,  85, 210),
	Color3.fromRGB(175,  75, 240),
	Color3.fromRGB(235,  95, 255),
	Color3.fromRGB(195, 145, 255),
	Color3.fromRGB(255, 115, 225),
}
local MOSS_COLORS = {
	Color3.fromRGB(32, 76, 28),
	Color3.fromRGB(44, 88, 36),
	Color3.fromRGB(28, 65, 24),
}
local BARK_COLORS = {
	Color3.fromRGB(40, 26, 16),
	Color3.fromRGB(34, 21, 11),
	Color3.fromRGB(52, 34, 18),
	Color3.fromRGB(30, 20, 10),
}
local ROOT_COLOR = Color3.fromRGB(52, 38, 20)
local ROCK_COLOR = Color3.fromRGB(70, 64, 56)

-- ── Colony variants ───────────────────────────────────────────────────────────
--
-- radius         : colony half-extent at full resources (before elongation)
-- xzScale        : elongation factor; creeping has the highest (very stretched)
-- heroCount      : centrepiece tall stalks; scales with fSq (fast dropoff when depleted)
-- heroHeight     : stud range for hero stalk total height
-- maxClumpH      : ceiling for normal clump stalk height at full resources
-- lightCount     : total PointLight budget at full resources

local VARIANTS = {
	bloom = {
		hotspotCount   = 4,
		radius         = {18, 24},
		xzScale        = {0.90, 1.20},
		hotspotSpread  = 0.38,
		heroCount      = {9, 16},
		heroHeight     = {3.8, 5.5},
		clumpsPerHs    = {4, 6},
		stalksPerClump = {6, 11},
		maxClumpH      = 3.5,
		lonerCount     = {16, 26},
		baseChunks     = {6, 10},
		mossCount      = {22, 35},
		lightCount     = 18,
	},
	compact = {
		hotspotCount   = 3,
		radius         = {13, 19},
		xzScale        = {0.85, 1.20},
		hotspotSpread  = 0.30,
		heroCount      = {6, 12},
		heroHeight     = {3.2, 4.8},
		clumpsPerHs    = {3, 5},
		stalksPerClump = {5, 9},
		maxClumpH      = 3.0,
		lonerCount     = {10, 18},
		baseChunks     = {4, 8},
		mossCount      = {16, 26},
		lightCount     = 15,
	},
	creeping = {
		hotspotCount   = 4,
		radius         = {10, 15},
		xzScale        = {2.20, 3.50},
		hotspotSpread  = 0.55,
		heroCount      = {5, 10},
		heroHeight     = {3.0, 4.5},
		clumpsPerHs    = {3, 5},
		stalksPerClump = {4, 7},
		maxClumpH      = 2.8,
		lonerCount     = {14, 22},
		baseChunks     = {5, 9},
		mossCount      = {18, 28},
		lightCount     = 14,
	},
	split = {
		hotspotCount   = 3,
		radius         = {12, 18},
		xzScale        = {1.10, 1.70},
		hotspotSpread  = 0.55,
		heroCount      = {5, 11},
		heroHeight     = {3.0, 4.5},
		clumpsPerHs    = {3, 5},
		stalksPerClump = {4, 8},
		maxClumpH      = 2.8,
		lonerCount     = {10, 18},
		baseChunks     = {4, 7},
		mossCount      = {14, 22},
		lightCount     = 14,
	},
	sparse = {
		hotspotCount   = 2,
		radius         = {14, 20},
		xzScale        = {1.00, 1.60},
		hotspotSpread  = 0.40,
		heroCount      = {4, 8},
		heroHeight     = {2.5, 3.8},
		clumpsPerHs    = {2, 4},
		stalksPerClump = {3, 6},
		maxClumpH      = 2.5,
		lonerCount     = {16, 26},
		baseChunks     = {3, 5},
		mossCount      = {10, 18},
		lightCount     = 12,
	},
}

local VARIANT_POOL = {
	"bloom",   "bloom",   "bloom",
	"compact", "compact", "compact",
	"creeping", "creeping",
	"split",   "split",
	"sparse",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Right-handed CFrame so cylinder length (local X) aligns with dir.
local function cylinderCFrame(center: Vector3, dir: Vector3): CFrame
	dir = dir.Unit
	local ref = math.abs(dir.Y) < 0.9 and Vector3.new(0, 1, 0) or Vector3.new(1, 0, 0)
	local vZ  = (dir:Cross(ref)).Unit
	local vY  = (vZ:Cross(dir)).Unit
	return CFrame.fromMatrix(center, dir, vY, vZ)
end

local function decoPart(parent, name)
	local p      = Instance.new("Part")
	p.Name       = name
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.CastShadow = false
	p.Parent     = parent
	return p
end

local function solidPart(parent, name, size, cf, color, material)
	local p      = Instance.new("Part")
	p.Name       = name
	p.Size       = size
	p.CFrame     = cf
	p.Color      = color
	p.Material   = material
	p.Anchored   = true
	p.CanCollide = true
	p.CanQuery   = false
	p.CastShadow = true
	p.Parent     = parent
	return p
end

-- ── Stalk builder ─────────────────────────────────────────────────────────────

local function makeStalk(r, stalksF, bulbsF, basePos, height, dia, withLight, withParticle)
	local segCount = height < 1.2 and 1 or (height > 2.8 and 3 or 2)
	local segLen   = height / segCount
	local stemCol  = Color3.fromRGB(
		r:NextInteger(148, 198),
		r:NextInteger(130, 172),
		r:NextInteger(192, 228))
	local lx  = r:NextNumber(-0.18, 0.18)
	local lz  = r:NextNumber(-0.18, 0.18)
	local cur = basePos

	for _ = 1, segCount do
		lx = lx + r:NextNumber(-0.05, 0.05)
		lz = lz + r:NextNumber(-0.05, 0.05)
		local dir = Vector3.new(lx, 1, lz).Unit
		local tip = cur + dir * segLen
		local mid = (cur + tip) * 0.5

		local stem        = decoPart(stalksF, "Stem")
		stem.Shape        = Enum.PartType.Cylinder
		stem.Size         = Vector3.new(segLen, dia, dia)
		stem.CFrame       = cylinderCFrame(mid, dir)
		stem.Color        = stemCol
		stem.Material     = Enum.Material.Glass
		stem.Transparency = r:NextNumber(0.28, 0.50)
		cur = tip
	end

	local bSz = height < 1.0 and r:NextNumber(0.12, 0.22)
	         or height > 3.5  and r:NextNumber(0.38, 0.60)
	         or height > 2.0  and r:NextNumber(0.24, 0.40)
	         or                   r:NextNumber(0.16, 0.28)
	local bCol = BULB_COLORS[r:NextInteger(1, #BULB_COLORS)]

	local bulb        = decoPart(bulbsF, "Bulb")
	bulb.Shape        = Enum.PartType.Ball
	bulb.Size         = Vector3.new(bSz, bSz, bSz)
	bulb.CFrame       = CFrame.new(cur + Vector3.new(0, bSz * 0.45, 0))
	bulb.Color        = bCol
	bulb.Material     = Enum.Material.Neon
	bulb.Transparency = r:NextNumber(0.05, 0.22)

	if withLight then
		local pl      = Instance.new("PointLight")
		pl.Color      = Color3.fromHSV(r:NextNumber(0.74, 0.92), r:NextNumber(0.75, 1.0), 1.0)
		pl.Brightness = r:NextNumber(1.0, 3.0)
		pl.Range      = r:NextNumber(6, 14)
		pl.Shadows    = false
		pl.Parent     = bulb
	end

	if withParticle then
		local pe = Instance.new("ParticleEmitter")
		pe.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, bCol),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 205, 255)),
		})
		pe.LightEmission  = 0.85
		pe.LightInfluence = 0.15
		pe.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.09),
			NumberSequenceKeypoint.new(0.6, 0.05),
			NumberSequenceKeypoint.new(1,   0),
		})
		pe.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.20),
			NumberSequenceKeypoint.new(1, 1),
		})
		pe.Speed       = NumberRange.new(0.3, 1.0)
		pe.SpreadAngle = Vector2.new(30, 30)
		pe.Lifetime    = NumberRange.new(2.0, 4.5)
		pe.Rate        = 4
		pe.RotSpeed    = NumberRange.new(-60, 60)
		pe.Rotation    = NumberRange.new(0, 360)
		pe.Parent      = bulb
	end
end

-- ── Core generator ────────────────────────────────────────────────────────────
-- Called by both create() and rebuild().  Destroys all Folder children so it
-- can be called multiple times on the same model without leaking old parts.
-- The Anchor Part (model.PrimaryPart) is NOT in a folder and is left intact.

local function populate(model: Model, origin: Vector3, seed: number, fullness: number)
	-- Clear folders from any previous populate call
	for _, child in model:GetChildren() do
		if child:IsA("Folder") then child:Destroy() end
	end
	-- Clear stale PointLight on the anchor (re-added below with new brightness)
	local anchor = model.PrimaryPart
	if anchor then
		for _, child in anchor:GetChildren() do child:Destroy() end
	end

	local fLin  = math.clamp(fullness, 0, 1)
	local fSq   = fLin * fLin          -- fast dropoff — hero stalks, particles
	local fSqrt = math.sqrt(fLin)      -- slow dropoff — radius, moss, ambient glow

	local r   = Random.new(seed)
	local cfg = VARIANTS[VARIANT_POOL[r:NextInteger(1, #VARIANT_POOL)]]

	-- Colony footprint: radius shrinks toward fSqrt so the colony visibly thins
	local radius    = lerp(cfg.radius[1] * 0.45, cfg.radius[2], fSqrt)
	local xScale    = r:NextNumber(cfg.xzScale[1], cfg.xzScale[2])
	local mainAngle = r:NextNumber(0, math.pi * 2)
	local cosA      = math.cos(mainAngle)
	local sinA      = math.sin(mainAngle)

	-- Colony-space → world XZ.  xScale stretches along mainAngle.
	local function toWorld(lx: number, lz: number): Vector3
		return Vector3.new(
			origin.X + xScale * lx * cosA - lz * sinA,
			origin.Y,
			origin.Z + xScale * lx * sinA + lz * cosA)
	end

	local function folder(name: string): Folder
		local f = Instance.new("Folder"); f.Name = name; f.Parent = model; return f
	end
	local baseF    = folder("Base")
	local mossF    = folder("Moss")
	local stalksF  = folder("Stalks")
	local bulbsF   = folder("Bulbs")
	local effectsF = folder("Effects")

	-- ── Hotspots ──────────────────────────────────────────────────────────────
	-- Count scales linearly so fewer density peaks remain at low fullness.
	local hotspotCount = math.max(1, math.round(cfg.hotspotCount * (0.25 + 0.75 * fLin)))
	local hotspots: { Vector3 } = {}
	for i = 1, hotspotCount do
		local a    = (i - 1) / hotspotCount * math.pi * 2 + r:NextNumber(-0.25, 0.25)
		local dist = r:NextNumber(0, cfg.hotspotSpread) * radius
		table.insert(hotspots, Vector3.new(math.cos(a) * dist, 0, math.sin(a) * dist))
	end

	-- ── Base: bark chunks, rocks, roots ──────────────────────────────────────
	-- Base detail scales fSqrt — it's the last thing to disappear.
	local chunkCount = math.max(1, math.round(lerp(1, cfg.baseChunks[2], fSqrt)))
	for i = 1, chunkCount do
		local hs   = hotspots[r:NextInteger(1, #hotspots)]
		local a    = r:NextNumber(0, math.pi * 2)
		local d    = r:NextNumber(0, radius * 0.65)
		local wpos = toWorld(hs.X + math.cos(a) * d, hs.Z + math.sin(a) * d)
		local big  = (i <= 2)
		local sX   = big and r:NextNumber(3.0, 6.0) or r:NextNumber(1.0, 2.5)
		local sY   = big and r:NextNumber(0.7, 1.2) or r:NextNumber(0.35, 0.70)
		local sZ   = big and r:NextNumber(2.0, 4.0) or r:NextNumber(0.7, 1.8)
		solidPart(baseF, "Bark_" .. i,
			Vector3.new(sX, sY, sZ),
			CFrame.new(wpos + Vector3.new(0, sY * 0.5 - 0.05, 0))
				* CFrame.Angles(r:NextNumber(-0.12, 0.12), r:NextNumber(0, math.pi * 2), r:NextNumber(-0.08, 0.08)),
			BARK_COLORS[r:NextInteger(1, #BARK_COLORS)], Enum.Material.Wood)
	end

	for i = 1, r:NextInteger(1, 3) do
		local a    = r:NextNumber(0, math.pi * 2)
		local wpos = toWorld(
			math.cos(a) * r:NextNumber(radius * 0.3, radius * 0.85),
			math.sin(a) * r:NextNumber(radius * 0.3, radius * 0.85))
		local sY   = r:NextNumber(0.6, 1.4)
		solidPart(baseF, "Rock_" .. i,
			Vector3.new(r:NextNumber(1.0, 2.5), sY, r:NextNumber(0.8, 2.0)),
			CFrame.new(wpos + Vector3.new(0, sY * 0.5 - 0.08, 0))
				* CFrame.Angles(r:NextNumber(-0.2, 0.2), r:NextNumber(0, math.pi * 2), r:NextNumber(-0.15, 0.15)),
			ROCK_COLOR, Enum.Material.SmoothPlastic)
	end

	for i = 1, r:NextInteger(5, 12) do
		local a    = r:NextNumber(0, math.pi * 2)
		local wpos = toWorld(
			math.cos(a) * r:NextNumber(0, radius * 1.05),
			math.sin(a) * r:NextNumber(0, radius * 1.05))
		local p    = decoPart(baseF, "Root_" .. i)
		p.Size     = Vector3.new(r:NextNumber(0.06, 0.16), 0.05, r:NextNumber(0.6, 2.2))
		p.CFrame   = CFrame.new(wpos + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, r:NextNumber(0, math.pi * 2), 0)
		p.Color    = ROOT_COLOR
		p.Material = Enum.Material.Wood
	end

	-- ── Moss ──────────────────────────────────────────────────────────────────
	local mossCount = math.max(2, math.round(lerp(cfg.mossCount[1] * 0.30, cfg.mossCount[2], fSqrt)))
	for i = 1, mossCount do
		local a    = r:NextNumber(0, math.pi * 2)
		local dist = r:NextNumber(0, 1) * radius * 1.10
		local wpos = toWorld(math.cos(a) * dist, math.sin(a) * dist)
		local p    = decoPart(mossF, "Moss_" .. i)
		p.Size     = Vector3.new(r:NextNumber(0.4, 1.4), 0.06, r:NextNumber(0.35, 1.1))
		p.CFrame   = CFrame.new(wpos + Vector3.new(0, 0.20, 0))
		             * CFrame.Angles(r:NextNumber(-0.10, 0.10), r:NextNumber(0, math.pi * 2), r:NextNumber(-0.10, 0.10))
		p.Color    = MOSS_COLORS[r:NextInteger(1, #MOSS_COLORS)]
		p.Material = Enum.Material.Grass
	end

	-- ── Shared budgets ────────────────────────────────────────────────────────
	local lightBudget  = math.max(2, math.round(lerp(2, cfg.lightCount, fSqrt)))
	local particleProb = lerp(0.01, 0.10, fSq)   -- nearly no spores at low fullness
	local maxClumpH    = lerp(0.9, cfg.maxClumpH, fLin)

	-- ── Hero stalks — centrepiece silhouette elements ─────────────────────────
	-- Count uses fSq so the tallest stalks disappear quickly as resources deplete.
	local heroCount = math.round(lerp(0, cfg.heroCount[2], fSq))
	for hi = 1, heroCount do
		local hs   = hotspots[((hi - 1) % #hotspots) + 1]
		local a    = r:NextNumber(0, math.pi * 2)
		local d    = r:NextNumber(0, radius * 0.18)
		local wpos = toWorld(hs.X + math.cos(a) * d, hs.Z + math.sin(a) * d)
		local sPos = Vector3.new(wpos.X, origin.Y + 0.40, wpos.Z)
		local h    = r:NextNumber(cfg.heroHeight[1], cfg.heroHeight[2])
		local lit  = lightBudget > 0
		if lit then lightBudget -= 1 end
		makeStalk(r, stalksF, bulbsF, sPos, h,
			r:NextNumber(0.085, 0.135), lit, r:NextNumber() < particleProb * 1.5)
	end

	-- ── Micro-clumps around each hotspot ──────────────────────────────────────
	for _, hs in ipairs(hotspots) do
		local clumpCount = math.max(0, math.round(lerp(
			cfg.clumpsPerHs[1] * 0.20, cfg.clumpsPerHs[2], fLin)))
		for _ = 1, clumpCount do
			local ca  = r:NextNumber(0, math.pi * 2)
			local cd  = r:NextNumber(0, radius * 0.48)
			local clx = hs.X + math.cos(ca) * cd
			local clz = hs.Z + math.sin(ca) * cd
			local cW  = toWorld(clx, clz)

			local dHs  = math.sqrt((clx - hs.X)^2 + (clz - hs.Z)^2)
			local infl = 1 - math.min(dHs / (radius * 0.50), 1)

			local stalkCount = math.max(1, math.round(lerp(
				cfg.stalksPerClump[1] * 0.20, cfg.stalksPerClump[2], fLin)))
			for _ = 1, stalkCount do
				local sa   = r:NextNumber(0, math.pi * 2)
				local sd   = r:NextNumber(0, 0.80 + (1 - infl) * 0.90)
				local sPos = Vector3.new(
					cW.X + math.cos(sa) * sd,
					origin.Y + 0.40 + r:NextNumber(-0.08, 0.18),
					cW.Z + math.sin(sa) * sd)

				local hroll  = r:NextNumber()
				local bonus  = infl * fLin
				local height = hroll < 0.10 and r:NextNumber(0.30, 0.80)
				            or hroll < 0.28 and r:NextNumber(0.80, 1.50) + bonus * 0.4
				            or hroll < 0.80 and r:NextNumber(1.50, maxClumpH) + bonus * 0.8
				            or                  r:NextNumber(maxClumpH, maxClumpH * 1.25) + bonus * 0.5

				local lit = lightBudget > 0 and r:NextNumber() < (infl * 0.28 + 0.04)
				if lit then lightBudget -= 1 end
				makeStalk(r, stalksF, bulbsF, sPos, height,
					r:NextNumber(0.055, 0.105), lit, r:NextNumber() < particleProb)
			end
		end
	end

	-- ── Loner stalks — sparse filler between clumps / at perimeter ───────────
	local lonerMax = math.max(2, math.round(lerp(cfg.lonerCount[1] * 0.20, cfg.lonerCount[2], fSqrt)))
	local lonerH   = lerp(0.22, 1.60, fLin)
	for _ = 1, lonerMax do
		local a    = r:NextNumber(0, math.pi * 2)
		local dist = math.sqrt(r:NextNumber(0, 1)) * radius * r:NextNumber(0.50, 1.08)
		local wpos = toWorld(math.cos(a) * dist, math.sin(a) * dist)
		local sPos = Vector3.new(
			wpos.X + r:NextNumber(-0.25, 0.25),
			origin.Y + 0.40 + r:NextNumber(-0.08, 0.18),
			wpos.Z + r:NextNumber(-0.25, 0.25))
		makeStalk(r, stalksF, bulbsF, sPos,
			r:NextNumber(0.22, lonerH), r:NextNumber(0.040, 0.078),
			false, r:NextNumber() < particleProb * 0.5)
	end

	-- ── Ambient effects ───────────────────────────────────────────────────────
	-- Wide soft glow from anchor — brightness scales fSqrt
	if anchor then
		local pl      = Instance.new("PointLight")
		pl.Color      = Color3.fromHSV(0.80, 0.55, 1.0)
		pl.Brightness = lerp(0.04, 0.40, fSqrt)
		pl.Range      = math.max(radius * xScale, 14)
		pl.Shadows    = false
		pl.Parent     = anchor
	end

	-- Mist emitters at up to 2 hotspot positions; rate and emission scale fSq
	for hi, hs in ipairs(hotspots) do
		if hi > 2 then break end
		local wpos        = toWorld(hs.X, hs.Z)
		local anch        = decoPart(effectsF, "MistAnchor_" .. hi)
		anch.Size         = Vector3.new(0.1, 0.1, 0.1)
		anch.CFrame       = CFrame.new(wpos + Vector3.new(0, 0.40, 0))
		anch.Transparency = 1

		local mist = Instance.new("ParticleEmitter")
		mist.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 90, 215)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 55, 175)),
		})
		mist.LightEmission  = lerp(0.10, 0.50, fSqrt)
		mist.LightInfluence = 0.60
		mist.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0),
			NumberSequenceKeypoint.new(0.25, lerp(0.20, 0.65, fSqrt)),
			NumberSequenceKeypoint.new(1,    0),
		})
		mist.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.82),
			NumberSequenceKeypoint.new(0.5, 0.90),
			NumberSequenceKeypoint.new(1,   1),
		})
		mist.Speed       = NumberRange.new(0.05, 0.35)
		mist.SpreadAngle = Vector2.new(70, 70)
		mist.Lifetime    = NumberRange.new(4, 8)
		mist.Rate        = math.max(0.5, lerp(0.5, 9, fSq))
		mist.RotSpeed    = NumberRange.new(-30, 30)
		mist.Rotation    = NumberRange.new(0, 360)
		mist.Parent      = anch
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function FungiCluster.create(origin: Vector3, seed: number?, fullness: number?): Model
	local s = seed or (math.abs(math.round(origin.X) * 1000 + math.round(origin.Z) * 7919) % 999983 + 1)
	local f = fullness or 1.0

	local model   = Instance.new("Model")
	model.Name    = "BioluminescentFungiColony"

	-- Anchor stays as a direct child of model (never in a folder) so it survives
	-- repeated populate() calls via rebuild().
	local anchor        = Instance.new("Part")
	anchor.Name         = "Anchor"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CastShadow   = false
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame       = CFrame.new(origin)
	anchor.Transparency = 1
	anchor.Parent       = model
	model.PrimaryPart   = anchor

	-- Persist seed + origin so rebuild() can regenerate deterministically
	model:SetAttribute("ColonySeed",    s)
	model:SetAttribute("ColonyOriginX", origin.X)
	model:SetAttribute("ColonyOriginY", origin.Y)
	model:SetAttribute("ColonyOriginZ", origin.Z)

	populate(model, origin, s, f)
	return model
end

-- Regenerates the colony in place at a new fullness level.
-- All geometry is destroyed and rebuilt; the model identity and attributes survive.
function FungiCluster.rebuild(model: Model, fullness: number)
	local s  = model:GetAttribute("ColonySeed")    :: number?
	local ox = model:GetAttribute("ColonyOriginX") :: number?
	local oy = model:GetAttribute("ColonyOriginY") :: number?
	local oz = model:GetAttribute("ColonyOriginZ") :: number?
	if not (s and ox and oy and oz) then return end
	populate(model, Vector3.new(ox, oy, oz), s, fullness)
end

return FungiCluster
