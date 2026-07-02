--[[
	GoreManager — server-side blood & gore VFX for biological units.

	A horror-grade death effect, layered for realism and spawned server-side so it
	replicates to every nearby client (same pattern as BuildingManager's destruction
	VFX). One death produces:

	  • Arterial spray   — a fast directional particle burst that arcs under gravity.
	  • Lingering mist   — a slower haze of fine droplets that hangs then settles.
	  • Physics gibs      — flesh chunks (and bone shards for humans) flung outward
	    with spin and blood trails; they tumble, land and rest before cleanup.
	  • Blood pool        — a slope-aligned stain raycast onto the ground that grows
	    from the impact, holds, then slowly dries/fades. Pools are globally capped.
	  • Ground splatter    — a scatter of smaller stains around the pool.

	Blood identity is per-unit: humans bleed red (with bone), the nest eels bleed a
	dark venous purple, and the creepy faction leaks sickly green ichor. `spawn` is
	the full death effect; `spurt` is a cheap particle-only burst for non-fatal hits.

	All parts live under workspace.GoreFX, are CanQuery=false (never block targeting
	or pathing raycasts) and are Debris-cleaned. `clear()` wipes everything on reset.
]]

local Debris       = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local GoreManager = {}

-- ── Blood identity ─────────────────────────────────────────────────────────────

local RED      = Color3.fromRGB(150,  10,  10)
local RED_DK   = Color3.fromRGB( 78,   6,   6)
local EEL      = Color3.fromRGB( 92,  20,  52)
local EEL_DK   = Color3.fromRGB( 46,  10,  28)
local ICHOR    = Color3.fromRGB( 70,  96,  34)
local ICHOR_DK = Color3.fromRGB( 34,  48,  18)
local BONE     = Color3.fromRGB(226, 221, 202)

type Blood = { spray: Color3, pool: Color3, bone: boolean }

local BLOOD: { [string]: Blood } = {
	Survivor      = { spray = RED,   pool = RED_DK,   bone = true  },
	Sniper        = { spray = RED,   pool = RED_DK,   bone = true  },
	Elite         = { spray = RED,   pool = RED_DK,   bone = true  },
	Medic         = { spray = RED,   pool = RED_DK,   bone = true  },
	Lamprey       = { spray = EEL,   pool = EEL_DK,   bone = false },
	Hagfish       = { spray = EEL,   pool = EEL_DK,   bone = false },
	CreepySoldier = { spray = ICHOR, pool = ICHOR_DK, bone = false },
	Broodmother   = { spray = ICHOR, pool = ICHOR_DK, bone = false },
}
local DEFAULT_BLOOD: Blood = { spray = RED, pool = RED_DK, bone = true }

-- Scales gib count, particle volume and pool radius with the unit's mass.
local SCALE: { [string]: number } = {
	Survivor = 1.0, Sniper = 1.0, Elite = 1.25, Medic = 1.0, CreepySoldier = 1.0,
	Lamprey = 1.7, Hagfish = 1.4, Broodmother = 3.2,
}

-- ── Pool registry (global cap) ──────────────────────────────────────────────────

local goreFolder: Folder? = nil
local pools: { BasePart } = {}
local MAX_POOLS = 48

local function folder(): Folder
	if goreFolder and goreFolder.Parent then return goreFolder end
	local f = workspace:FindFirstChild("GoreFX")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name   = "GoreFX"
		f.Parent = workspace
	end
	goreFolder = f :: Folder
	return goreFolder
end

local function registerPool(p: BasePart)
	table.insert(pools, p)
	while #pools > MAX_POOLS do
		local old = table.remove(pools, 1)
		if old then old:Destroy() end
	end
end

-- ── Ground probe ────────────────────────────────────────────────────────────────

-- Raycast down for a surface to lay stains on, ignoring units + existing gore so
-- pools sit on terrain/buildings and follow slopes.
local function groundBelow(pos: Vector3): (Vector3, Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { folder() }
	local u = workspace:FindFirstChild("Units")
	if u then table.insert(exclude, u) end
	params.FilterDescendantsInstances = exclude
	local res = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -250, 0), params)
	if res then return res.Position, res.Normal end
	return Vector3.new(pos.X, pos.Y - 2.5, pos.Z), Vector3.new(0, 1, 0)
end

-- Flat disc CFrame on a surface: a thin cylinder whose round face lies on the
-- ground (axis = surface normal), nudged out to avoid z-fighting.
local function discCF(pos: Vector3, normal: Vector3): CFrame
	local tangent = normal:Cross(Vector3.new(0, 0, 1))
	if tangent.Magnitude < 0.05 then tangent = normal:Cross(Vector3.new(1, 0, 0)) end
	tangent = tangent.Unit
	return CFrame.fromMatrix(pos + normal * 0.06, normal, tangent)
end

-- ── Stain spawners ──────────────────────────────────────────────────────────────

local function spawnStain(groundPos: Vector3, normal: Vector3, color: Color3,
	diameter: number, hold: number, fade: number, isPool: boolean)
	local thickness = 0.1
	local disc        = Instance.new("Part")
	disc.Shape        = Enum.PartType.Cylinder
	disc.Size         = Vector3.new(thickness, diameter * 0.25, diameter * 0.25) -- starts small, grows
	disc.CFrame       = discCF(groundPos, normal)
	disc.Anchored     = true
	disc.CanCollide   = false
	disc.CanQuery     = false
	disc.CanTouch     = false
	disc.CastShadow   = false
	disc.Material     = Enum.Material.Glass     -- faint wet sheen
	disc.Color        = color
	disc.Transparency = 0.15
	disc.Parent       = folder()
	if isPool then registerPool(disc) end

	-- Spread out from the impact, then dry + fade away.
	TweenService:Create(disc, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(thickness, diameter, diameter) }):Play()
	task.delay(hold, function()
		if not disc.Parent then return end
		local t = TweenService:Create(disc, TweenInfo.new(fade, Enum.EasingStyle.Linear),
			{ Transparency = 1 })
		t:Play()
		t.Completed:Once(function()
			local i = table.find(pools, disc)
			if i then table.remove(pools, i) end
			disc:Destroy()
		end)
	end)
end

-- ── Particle bursts ─────────────────────────────────────────────────────────────

local function burst(pos: Vector3, color: Color3, scale: number, emitMul: number?, power: number?)
	emitMul = emitMul or 1
	power   = power or 1
	local fx        = Instance.new("Part")
	fx.Size         = Vector3.one * 0.1
	fx.Position     = pos
	fx.Anchored     = true
	fx.CanCollide   = false
	fx.CanQuery     = false
	fx.CanTouch     = false
	fx.CastShadow   = false
	fx.Transparency = 1
	fx.Parent       = folder()

	-- Arterial spray — fast, radial, gravity-pulled droplets.
	local spray            = Instance.new("ParticleEmitter")
	spray.Color            = ColorSequence.new(color)
	spray.LightInfluence   = 1
	spray.Lifetime         = NumberRange.new(0.35, 0.75)
	spray.Speed            = NumberRange.new(20 * power, 46 * power)
	spray.SpreadAngle      = Vector2.new(180, 180)
	spray.Acceleration     = Vector3.new(0, -75, 0)
	spray.Rotation         = NumberRange.new(0, 360)
	spray.RotSpeed         = NumberRange.new(-220, 220)
	spray.Size             = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0.12),
	})
	spray.Transparency     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.75, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	spray.Enabled          = false
	spray.Parent           = fx

	-- Lingering mist — slow fine haze that hangs then settles.
	local mist          = Instance.new("ParticleEmitter")
	mist.Color          = ColorSequence.new(color)
	mist.LightInfluence = 1
	mist.Lifetime       = NumberRange.new(0.9, 1.8)
	mist.Speed          = NumberRange.new(2, 8)
	mist.SpreadAngle    = Vector2.new(120, 120)
	mist.Acceleration   = Vector3.new(0, -12, 0)
	mist.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.3, 1.3),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	mist.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1),
	})
	mist.Enabled        = false
	mist.Parent         = fx

	spray:Emit(math.floor(22 * scale * emitMul + 0.5))
	mist:Emit(math.floor(14 * scale * emitMul + 0.5))
	Debris:AddItem(fx, 2.5)
end

-- Vertical blood geyser — a pressurised column that shoots up and rains back down.
-- Used for the most violent deaths where the body ruptures at the torso.
local function bloodFountain(pos: Vector3, color: Color3, scale: number)
	local part        = Instance.new("Part")
	part.Size         = Vector3.one * 0.2
	part.Position     = pos
	part.Transparency = 1
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CanTouch     = false
	part.CastShadow   = false
	part.Parent       = folder()

	local fountain          = Instance.new("ParticleEmitter")
	fountain.Color          = ColorSequence.new(color)
	fountain.EmissionDirection = Enum.NormalId.Top
	fountain.LightInfluence = 1
	fountain.Lifetime       = NumberRange.new(0.7, 1.4)
	fountain.Speed          = NumberRange.new(26, 44)
	fountain.SpreadAngle    = Vector2.new(24, 24)
	fountain.Acceleration   = Vector3.new(0, -60, 0)
	fountain.Rotation       = NumberRange.new(0, 360)
	fountain.RotSpeed       = NumberRange.new(-160, 160)
	fountain.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6 * scale), NumberSequenceKeypoint.new(1, 0.1) })
	fountain.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.8, 0.3),
		NumberSequenceKeypoint.new(1, 1) })
	fountain.Enabled        = false
	fountain.Parent         = part
	fountain:Emit(math.floor(50 * scale + 0.5))
	Debris:AddItem(part, 2.5)
end

-- ── Physics gibs ────────────────────────────────────────────────────────────────

-- `gibMul` multiplies the chunk count, `level` (1–3) makes higher tiers throw
-- bigger chunks harder, and `blast` flattens the arc into a wide horizontal spray
-- (the tier-3 "blown apart" second wave) instead of a fountaining upward toss.
local function flingGibs(pos: Vector3, info: Blood, scale: number, gibMul: number?, level: number?, blast: boolean?)
	gibMul = gibMul or 1
	level  = level or 1
	local n = math.clamp(math.floor(3.5 * scale * gibMul + 0.5), 3, 42)
	local rscale  = math.sqrt(scale) * (1 + (level - 1) * 0.22)   -- bigger chunks at higher tiers
	local force   = (1 + (level - 1) * 0.55) * (if blast then 1.5 else 1)
	for _ = 1, n do
		local gib       = Instance.new("Part")
		gib.Material    = Enum.Material.SmoothPlastic
		gib.CanCollide  = true
		gib.CanQuery    = false
		gib.CanTouch    = false
		gib.CastShadow  = false

		local isBone = info.bone and math.random() < 0.3
		if isBone then
			gib.Shape = Enum.PartType.Block
			gib.Size  = Vector3.new(0.16, 0.16, (0.5 + math.random() * 0.7)) * rscale
			gib.Color = BONE
		else
			gib.Shape = Enum.PartType.Ball
			local s   = (0.35 + math.random() * 0.55) * rscale
			gib.Size  = Vector3.new(s, s * (0.6 + math.random() * 0.35), s)
			gib.Color = info.pool
		end

		gib.Position = pos + Vector3.new(
			(math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2)
		gib.Parent   = folder()

		local ang   = math.random() * math.pi * 2
		local outSp = (12 + math.random() * 24) * force
		local upSp  = (14 + math.random() * 18) * force * (if blast then 0.4 else 1)
		gib.AssemblyLinearVelocity  = Vector3.new(math.cos(ang) * outSp, upSp, math.sin(ang) * outSp)
		gib.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * 30, (math.random() - 0.5) * 30, (math.random() - 0.5) * 30)

		-- Flesh gibs streak blood as they tumble.
		if not isBone then
			local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0,  gib.Size.Y * 0.5, 0); a0.Parent = gib
			local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -gib.Size.Y * 0.5, 0); a1.Parent = gib
			local tr          = Instance.new("Trail")
			tr.Attachment0    = a0
			tr.Attachment1    = a1
			tr.Color          = ColorSequence.new(info.pool)
			tr.Transparency   = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
			tr.WidthScale     = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
			tr.Lifetime       = 0.4
			tr.LightInfluence = 1
			tr.Parent         = gib
		end

		Debris:AddItem(gib, 2.5 + math.random() * 1.5)
	end
end

-- ── Decapitation (rare soldier spectacle) ───────────────────────────────────────

local function bloodTrail(p: BasePart, color: Color3, life: number)
	local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0,  p.Size.Y * 0.5, 0); a0.Parent = p
	local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -p.Size.Y * 0.5, 0); a1.Parent = p
	local tr          = Instance.new("Trail")
	tr.Attachment0    = a0
	tr.Attachment1    = a1
	tr.Color          = ColorSequence.new(color)
	tr.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	tr.WidthScale     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	tr.Lifetime       = life
	tr.LightInfluence = 1
	tr.Parent         = p
end

--[[
	Pops a soldier's head clean off: the head launches skyward trailing blood, a
	geyser erupts from the neck stump (welded to the body so it tilts as it falls),
	the headless body ragdolls to the ground, and a wide pool spreads beneath. The
	live decorator parts are repurposed as the corpse, so it matches the soldier
	exactly (uniform colour + that soldier's skin tone).

	Call this BEFORE the body root is destroyed — it reparents the parts it keeps
	out of the body, so the subsequent destroy only removes the empty pivot.
]]
function GoreManager.decapitate(body: BasePart)
	local f      = folder()
	local baseCF = body.CFrame

	-- Gather the visible parts; separate the head from everything else.
	local head: BasePart? = nil
	local bodyParts: { BasePart } = {}
	for _, c in body:GetChildren() do
		if c:IsA("BasePart") then
			if c.Name == "_SoldierHead" then head = c else table.insert(bodyParts, c) end
		end
	end

	-- ── Head launch ──────────────────────────────────────────────────────────
	if head then
		head.Parent     = f
		head.Anchored   = false
		head.CanCollide = true
		head.CanQuery   = false
		head.AssemblyLinearVelocity  = Vector3.new(
			(math.random() - 0.5) * 16, 36 + math.random() * 16, (math.random() - 0.5) * 16)
		head.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * 28, (math.random() - 0.5) * 28, (math.random() - 0.5) * 28)
		bloodTrail(head, RED_DK, 0.5)
		Debris:AddItem(head, 5)
	end

	-- ── Ragdoll the headless body ────────────────────────────────────────────
	local corpse  = Instance.new("Model")
	corpse.Name   = "Corpse"
	corpse.Parent = f

	local root: BasePart? = nil
	for _, bp in bodyParts do
		bp.Parent     = corpse
		bp.Anchored   = false
		bp.CanCollide = true
		bp.CanQuery   = false
		if not root or bp.Position.Y < root.Position.Y then root = bp end
	end
	if root then
		corpse.PrimaryPart = root
		for _, bp in bodyParts do
			if bp ~= root then
				local w = Instance.new("WeldConstraint")
				w.Part0 = root; w.Part1 = bp; w.Parent = root
			end
		end
		-- A shove + spin so it crumples and topples instead of dropping straight down.
		local ang = math.random() * math.pi * 2
		root.AssemblyLinearVelocity  = Vector3.new(math.cos(ang) * 9, 4, math.sin(ang) * 9)
		root.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * 9, (math.random() - 0.5) * 4, (math.random() - 0.5) * 9)
	end
	Debris:AddItem(corpse, 6)

	-- ── Neck geyser (welded to the body so it follows + tilts) ───────────────
	local geyser        = Instance.new("Part")
	geyser.Size         = Vector3.one * 0.2
	geyser.Transparency = 1
	geyser.Anchored     = root == nil
	geyser.CanCollide   = false
	geyser.CanQuery     = false
	geyser.CanTouch     = false
	geyser.CastShadow   = false
	geyser.CFrame       = baseCF * CFrame.new(0, 1.05, 0)   -- neck stump
	geyser.Parent       = root and corpse or f
	if root then
		local w = Instance.new("WeldConstraint")
		w.Part0 = root; w.Part1 = geyser; w.Parent = geyser
	end

	local fountain          = Instance.new("ParticleEmitter")
	fountain.Color          = ColorSequence.new(RED)
	fountain.EmissionDirection = Enum.NormalId.Top
	fountain.LightInfluence = 1
	fountain.Lifetime       = NumberRange.new(0.8, 1.5)
	fountain.Speed          = NumberRange.new(30, 46)       -- shoots high into the sky
	fountain.SpreadAngle    = Vector2.new(11, 11)
	fountain.Acceleration   = Vector3.new(0, -62, 0)        -- arcs back down as a fountain
	fountain.Rotation       = NumberRange.new(0, 360)
	fountain.RotSpeed       = NumberRange.new(-160, 160)
	fountain.Rate           = 240
	fountain.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0.1) })
	fountain.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.8, 0.25),
		NumberSequenceKeypoint.new(1, 1) })
	fountain.Parent         = geyser
	fountain:Emit(45)                                       -- initial burst of pressure
	task.delay(1.0, function() if fountain.Parent then fountain.Enabled = false end end)
	Debris:AddItem(geyser, root and 6 or 3)

	-- A wide pool spreads from where they fell.
	local groundPos, normal = groundBelow(baseCF.Position)
	spawnStain(groundPos, normal, RED_DK, 4.5 + math.random() * 2.0, 16, 7, true)
end

-- ── Public API ──────────────────────────────────────────────────────────────────

-- Death violence tiers, picked by how far the killing blow overkilled the victim.
-- Tier 1 is the baseline spray/gibs/pool. Tier 2 (a heavy overkill) ruptures the
-- body — more gibs flung wider, a thicker double spray, a bigger pool and more
-- splatter. Tier 3 (a massive overkill) blows it apart — a vertical blood geyser
-- and a violent low horizontal gib blast on top of everything else.
type Tier = { emit: number, gibs: number, pool: number, splats: number, reach: number }
local TIER: { Tier } = {
	{ emit = 1.0, gibs = 1.0, pool = 1.0, splats = 1.0, reach = 1.0 },   -- clean kill
	{ emit = 1.8, gibs = 2.1, pool = 1.4, splats = 1.9, reach = 1.5 },   -- ruptured
	{ emit = 2.8, gibs = 3.4, pool = 1.9, splats = 3.0, reach = 2.2 },   -- blown apart
}

-- Full death gore at a biological unit's position. `level` (1–3, default 1) is the
-- gore tier — how gruesome the death is; see TIER above.
function GoreManager.spawn(unitType: string, pos: Vector3, level: number?)
	local info  = BLOOD[unitType] or DEFAULT_BLOOD
	local scale = SCALE[unitType] or 1
	local lv    = math.clamp(math.floor(level or 1), 1, 3)
	local t     = TIER[lv]

	burst(pos + Vector3.new(0, 1, 0), info.spray, scale, t.emit, 1 + (lv - 1) * 0.5)
	flingGibs(pos + Vector3.new(0, 0.5, 0), info, scale, t.gibs, lv)

	-- Tier 2+: a second rupturing spray higher up the torso.
	if lv >= 2 then
		burst(pos + Vector3.new(0, 1.5, 0), info.spray, scale, t.emit * 0.6, 1 + (lv - 1) * 0.5)
	end
	-- Tier 3: the body bursts — an upward geyser plus a wide low gib blast.
	if lv >= 3 then
		bloodFountain(pos + Vector3.new(0, 1.2, 0), info.spray, scale)
		flingGibs(pos + Vector3.new(0, 0.8, 0), info, scale, t.gibs * 0.7, lv, true)
	end

	local groundPos, normal = groundBelow(pos)
	-- Main pool.
	spawnStain(groundPos, normal, info.pool, (3.0 + math.random() * 1.5) * scale * t.pool, 14, 6, true)
	-- Scattered splatter around it — flung further at higher tiers.
	local splats = math.clamp(math.floor(3 * scale * t.splats + 0.5), 3, 22)
	for _ = 1, splats do
		local ang = math.random() * math.pi * 2
		local r   = (1.5 + math.random() * 3.0) * scale * t.reach
		local sp  = groundPos + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r)
		local gPos, gN = groundBelow(sp + Vector3.new(0, 2, 0))
		spawnStain(gPos, gN, info.pool, (0.8 + math.random() * 1.4) * scale, 10, 4, false)
	end
end

-- Cheap non-fatal hit: a small directional blood puff, no gibs or pools.
function GoreManager.spurt(unitType: string, pos: Vector3)
	local info = BLOOD[unitType] or DEFAULT_BLOOD
	burst(pos, info.spray, 0.3)
end

-- Wipe all gore (call on match reset).
function GoreManager.clear()
	pools = {}
	if goreFolder then goreFolder:Destroy(); goreFolder = nil end
	local f = workspace:FindFirstChild("GoreFX")
	if f then f:Destroy() end
end

return GoreManager
