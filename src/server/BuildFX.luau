--!strict
--[[
	BuildFX — the one-shot world effects the building systems throw off.

	Every function here does the same kind of thing: drop some parts, sounds and particles
	into the workspace at a point, animate them, and let Debris clean them up. None of it
	touches building state, so it has no business living inside the state machine that owns
	that state -- and pulling it out is what keeps BuildingManager under Luau's ceiling of
	200 locals per chunk, which it has hit once already.

	Server-side by design: the effects are spawned once, on the server, and replicate to
	every client that can see them (the same pattern GoreManager uses).
]]

local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GoreManager = require(script.Parent:WaitForChild("GoreManager"))

local rng = Random.new()

local BuildFX = {}

-- ── The Mother's spike ─────────────────────────────────────────────────
-- Two separate moments, and they are not the same event: the spike GOING IN happens on
-- every injection, while the second only plays when what she went into gives something
-- up (a plant bursting into Leeches, nests or a gland). Injecting bare ground is the
-- first sound alone.
BuildFX.SND_INJECT = "rbxassetid://117742365588721"
BuildFX.SND_EVOLVE = "rbxassetid://77665012026179"

-- One-shot world sound at a point. Both come from the WOUND rather than from her body,
-- so a shift-queued run reads as a line of separate strikes across the ground instead of
-- a stack of noises following her around.
function BuildFX.injectSound(pos: Vector3, soundId: string, volume: number)
	local anchor        = Instance.new("Part")
	anchor.Name         = "_InjectSFX"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CanTouch     = false
	anchor.CastShadow   = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.one * 0.1
	anchor.Position     = pos
	anchor.Parent       = workspace

	local snd              = Instance.new("Sound")
	snd.SoundId            = soundId
	snd.Volume             = volume
	snd.RollOffMode        = Enum.RollOffMode.Linear
	snd.RollOffMinDistance = 12
	snd.RollOffMaxDistance = 190
	snd.Parent             = anchor
	snd:Play()
	Debris:AddItem(anchor, 8)
end

-- The wound itself: a purple bloom at the point where the spike goes in.
function BuildFX.injectBurst(pos: Vector3)
	local flash        = Instance.new("Part")
	flash.Shape        = Enum.PartType.Ball
	flash.Size         = Vector3.new(3, 3, 3)
	flash.Position     = pos + Vector3.new(0, 0.5, 0)
	flash.Color        = Color3.fromRGB(196, 90, 255)
	flash.Material     = Enum.Material.Neon
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CanTouch     = false
	flash.CastShadow   = false
	flash.Transparency = 0.15
	flash.Parent       = workspace
	TweenService:Create(flash, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(20, 6, 20),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.8)
end

-- ── Destruction VFX (server-side) ────────────────────────────────────────────

function BuildFX.destruction(pos: Vector3)
	-- 3D destruction sound
	local soundPart            = Instance.new("Part")
	soundPart.Anchored         = true
	soundPart.CanCollide       = false
	soundPart.CanTouch         = false
	soundPart.Transparency     = 1
	soundPart.Size             = Vector3.new(1, 1, 1)
	soundPart.CastShadow       = false
	soundPart.Position         = pos
	soundPart.Parent           = workspace
	local snd                  = Instance.new("Sound")
	snd.SoundId                = "rbxassetid://117211977307268"
	snd.Volume                 = 1.1
	snd.RollOffMaxDistance     = 200
	snd.RollOffMinDistance     = 12
	snd.Parent                 = soundPart
	snd:Play()
	Debris:AddItem(soundPart, 6)

	-- Primary explosion
	local exp              = Instance.new("Explosion")
	exp.BlastRadius        = 0
	exp.BlastPressure      = 0
	exp.Position           = pos
	exp.ExplosionType      = Enum.ExplosionType.NoCraters
	exp.Parent             = workspace

	-- Secondary offset explosion
	task.delay(0.08, function()
		local exp2          = Instance.new("Explosion")
		exp2.BlastRadius    = 0
		exp2.BlastPressure  = 0
		exp2.Position       = pos + Vector3.new(rng:NextNumber(-2.5, 2.5), 1.5, rng:NextNumber(-2.5, 2.5))
		exp2.ExplosionType  = Enum.ExplosionType.NoCraters
		exp2.Parent         = workspace
	end)

	-- Tertiary small explosion
	task.delay(0.18, function()
		local exp3          = Instance.new("Explosion")
		exp3.BlastRadius    = 0
		exp3.BlastPressure  = 0
		exp3.Position       = pos + Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(0, 2), rng:NextNumber(-3, 3))
		exp3.ExplosionType  = Enum.ExplosionType.NoCraters
		exp3.Parent         = workspace
	end)

	-- Flash light burst
	local flashPart            = Instance.new("Part")
	flashPart.Anchored         = true
	flashPart.CanCollide       = false
	flashPart.CanTouch         = false
	flashPart.CastShadow       = false
	flashPart.Transparency     = 1
	flashPart.Size             = Vector3.new(1, 1, 1)
	flashPart.Position         = pos + Vector3.new(0, 3, 0)
	flashPart.Parent           = workspace
	local light                = Instance.new("PointLight")
	light.Brightness           = 10
	light.Range                = 50
	light.Color                = Color3.fromRGB(255, 150, 50)
	light.Parent               = flashPart
	Debris:AddItem(flashPart, 0.45)

	-- Debris chunks
	local debrisColors = {
		Color3.fromRGB(120, 110, 100),
		Color3.fromRGB(80,  75,  70),
		Color3.fromRGB(60,  55,  50),
	}
	for _ = 1, 10 do
		local d            = Instance.new("Part")
		d.Anchored         = false
		d.CanCollide       = false
		d.CanTouch         = false
		d.CastShadow       = false
		d.Size             = Vector3.new(
			rng:NextNumber(0.25, 0.9),
			rng:NextNumber(0.25, 0.9),
			rng:NextNumber(0.25, 0.9)
		)
		d.Color            = debrisColors[rng:NextInteger(1, #debrisColors)]
		d.Material         = Enum.Material.SmoothPlastic
		d.Position         = pos + Vector3.new(
			rng:NextNumber(-2, 2),
			rng:NextNumber(0.5, 2.5),
			rng:NextNumber(-2, 2)
		)
		d.Parent           = workspace
		d.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-14, 14),
			rng:NextNumber(9, 22),
			rng:NextNumber(-14, 14)
		)
		d.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6)
		)
		Debris:AddItem(d, rng:NextNumber(1.5, 3.0))
	end
end

-- ── Worm burst VFX (server-side) ─────────────────────────────────────────────

function BuildFX.wormBurst(pos: Vector3)
	-- Burst sound (reuses the building-destruction sound)
	local soundPart            = Instance.new("Part")
	soundPart.Anchored         = true
	soundPart.CanCollide       = false
	soundPart.CanTouch         = false
	soundPart.Transparency     = 1
	soundPart.Size             = Vector3.new(1, 1, 1)
	soundPart.CastShadow       = false
	soundPart.Position         = pos
	soundPart.Parent           = workspace
	local snd                  = Instance.new("Sound")
	snd.SoundId                = "rbxassetid://117211977307268"
	snd.Volume                 = 1.3
	snd.RollOffMaxDistance     = 220
	snd.RollOffMinDistance     = 14
	snd.Parent                 = soundPart
	snd:Play()
	Debris:AddItem(soundPart, 6)

	-- Earthen dirt chunks hurled outward
	local dirtColors = {
		Color3.fromRGB(90,  60, 30),
		Color3.fromRGB(70,  45, 20),
		Color3.fromRGB(110, 80, 40),
		Color3.fromRGB(55,  85, 20),
	}
	for _ = 1, 18 do
		local d            = Instance.new("Part")
		d.Anchored         = false
		d.CanCollide       = false
		d.CanTouch         = false
		d.CastShadow       = false
		d.Size             = Vector3.new(
			rng:NextNumber(0.3, 1.2),
			rng:NextNumber(0.3, 1.2),
			rng:NextNumber(0.3, 1.2)
		)
		d.Color            = dirtColors[rng:NextInteger(1, #dirtColors)]
		d.Material         = Enum.Material.SmoothPlastic
		d.Position         = pos + Vector3.new(
			rng:NextNumber(-3, 3),
			rng:NextNumber(0.5, 3.0),
			rng:NextNumber(-3, 3)
		)
		d.Parent           = workspace
		d.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-20, 20),
			rng:NextNumber(14, 30),
			rng:NextNumber(-20, 20)
		)
		d.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-9, 9),
			rng:NextNumber(-9, 9),
			rng:NextNumber(-9, 9)
		)
		Debris:AddItem(d, rng:NextNumber(1.5, 3.5))
	end
end

-- ── Lamprey egg hatch VFX (server-side) ──────────────────────────────────────
function BuildFX.eggHatch(pos: Vector3)
	-- Expanding green flash that fades out
	local flash            = Instance.new("Part")
	flash.Shape            = Enum.PartType.Ball
	flash.Size             = Vector3.new(2, 2, 2)
	flash.Position         = pos
	flash.Color            = Color3.fromRGB(150, 230, 90)
	flash.Material         = Enum.Material.Neon
	flash.Anchored         = true
	flash.CanCollide       = false
	flash.CanQuery         = false
	flash.CanTouch         = false
	flash.CastShadow       = false
	flash.Transparency     = 0.1
	flash.Parent           = workspace
	TweenService:Create(flash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(9, 9, 9),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.6)

	-- Eggshell shards + slime flung outward
	local shardColors = {
		Color3.fromRGB(150, 210, 90),
		Color3.fromRGB(110, 170, 60),
		Color3.fromRGB(90, 120, 50),
	}
	for _ = 1, 12 do
		local s            = Instance.new("Part")
		s.Anchored         = false
		s.CanCollide       = false
		s.CanTouch         = false
		s.CastShadow       = false
		s.Size             = Vector3.new(
			rng:NextNumber(0.3, 0.9),
			rng:NextNumber(0.3, 0.9),
			rng:NextNumber(0.3, 0.9)
		)
		s.Color            = shardColors[rng:NextInteger(1, #shardColors)]
		s.Material         = Enum.Material.SmoothPlastic
		s.Position         = pos + Vector3.new(
			rng:NextNumber(-1.5, 1.5),
			rng:NextNumber(0.5, 2.5),
			rng:NextNumber(-1.5, 1.5)
		)
		s.Parent           = workspace
		s.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-16, 16),
			rng:NextNumber(10, 22),
			rng:NextNumber(-16, 16)
		)
		s.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8)
		)
		Debris:AddItem(s, rng:NextNumber(1.2, 2.5))
	end
end

-- ── Egg-nest birth burst ────────────────────────────────────────────────────
-- Plays when a fresh egg nest pops into view: a wet "pop" sound plus a splash of
-- translucent water-blue globs flung outward like a burst water balloon.
function BuildFX.eggNestBurst(pos: Vector3)
	-- Positional pop sound on a throwaway part.
	local soundPart          = Instance.new("Part")
	soundPart.Anchored       = true
	soundPart.CanCollide     = false
	soundPart.CanQuery       = false
	soundPart.CanTouch       = false
	soundPart.Transparency   = 1
	soundPart.Size           = Vector3.new(1, 1, 1)
	soundPart.CastShadow     = false
	soundPart.Position       = pos
	soundPart.Parent         = workspace
	local snd                = Instance.new("Sound")
	snd.SoundId              = "rbxassetid://9120495961"
	snd.Volume               = 1.0
	snd.RollOffMaxDistance   = 180
	snd.RollOffMinDistance   = 10
	snd.Parent               = soundPart
	snd:Play()
	Debris:AddItem(soundPart, 5)

	-- Expanding translucent splash ring that fades out (the balloon's water skin).
	local splash           = Instance.new("Part")
	splash.Shape           = Enum.PartType.Ball
	splash.Size            = Vector3.new(1.5, 1.5, 1.5)
	splash.Position        = pos
	splash.Color           = Color3.fromRGB(120, 205, 255)
	splash.Material        = Enum.Material.Glass
	splash.Anchored        = true
	splash.CanCollide      = false
	splash.CanQuery        = false
	splash.CanTouch        = false
	splash.CastShadow      = false
	splash.Transparency    = 0.35
	splash.Parent          = workspace
	TweenService:Create(splash, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(10, 6, 10),
		Transparency = 1,
	}):Play()
	Debris:AddItem(splash, 0.6)

	-- Water globs flung outward + up, dragged down by gravity so they splatter.
	local waterColors = {
		Color3.fromRGB(120, 205, 255),
		Color3.fromRGB( 90, 175, 240),
		Color3.fromRGB(160, 225, 255),
	}
	for _ = 1, 18 do
		local g            = Instance.new("Part")
		g.Shape            = Enum.PartType.Ball
		g.Anchored         = false
		g.CanCollide       = false
		g.CanTouch         = false
		g.CastShadow       = false
		local r            = rng:NextNumber(0.35, 0.85)
		g.Size             = Vector3.new(r, r, r)
		g.Color            = waterColors[rng:NextInteger(1, #waterColors)]
		g.Material         = Enum.Material.Glass
		g.Transparency     = 0.3
		g.Position         = pos + Vector3.new(
			rng:NextNumber(-1.2, 1.2),
			rng:NextNumber(0.4, 1.8),
			rng:NextNumber(-1.2, 1.2)
		)
		g.Parent           = workspace
		g.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-20, 20),
			rng:NextNumber(12, 26),
			rng:NextNumber(-20, 20)
		)
		Debris:AddItem(g, rng:NextNumber(0.9, 1.8))
	end

	-- Fine spray mist for the wet burst feel.
	local sprayPart        = Instance.new("Part")
	sprayPart.Anchored     = true
	sprayPart.CanCollide   = false
	sprayPart.CanQuery     = false
	sprayPart.CanTouch     = false
	sprayPart.Transparency = 1
	sprayPart.Size         = Vector3.new(1, 1, 1)
	sprayPart.CastShadow   = false
	sprayPart.Position     = pos + Vector3.new(0, 0.6, 0)
	sprayPart.Parent       = workspace
	local spray            = Instance.new("ParticleEmitter")
	spray.Color            = ColorSequence.new(Color3.fromRGB(150, 220, 255))
	spray.Size             = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	spray.Transparency     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	spray.Lifetime         = NumberRange.new(0.35, 0.7)
	spray.Speed            = NumberRange.new(14, 26)
	spray.SpreadAngle      = Vector2.new(180, 180)
	spray.Acceleration     = Vector3.new(0, -40, 0)
	spray.Rotation         = NumberRange.new(0, 360)
	spray.LightEmission    = 0.3
	spray.Enabled          = false
	spray.Parent           = sprayPart
	spray:Emit(28)
	Debris:AddItem(sprayPart, 1.2)
end

-- ── Relay catch ──────────────────────────────────────────────────────
-- A relay flashing white as an incoming pod is caught and thrown on to the next one.
function BuildFX.relayFlash(model: Model)
	for _, p in model:GetDescendants() do
		if not p:IsA("BasePart") or p.Material ~= Enum.Material.Neon then continue end
		task.spawn(function()
			local orig = p.Color
			p.Color = Color3.new(1, 1, 1)
			task.wait(0.1)
			if p.Parent then p.Color = orig end
		end)
	end
	local cr = model:FindFirstChild("CatchRing")
	if cr then
		local flash      = Instance.new("PointLight")
		flash.Color      = Color3.fromRGB(180, 230, 255)
		flash.Brightness = 16
		flash.Range      = 50
		flash.Parent     = cr
		Debris:AddItem(flash, 0.8)
	end
end

-- ── A commander's last Command Center ──────────────────────────────────────
-- Paced by BuildingManager (see its runFinalBlow), which sends every camera to the spot
-- first and holds the victory/defeat card until these have played out.
BuildFX.MOTHER_SOUND = "rbxassetid://136038559178753"   -- the wettest of the gore clips

-- A Core does not pop like an outbuilding. It goes up in a chain, each blast thrown
-- further out than the last, so the wreck keeps coming for the whole hold.
function BuildFX.coreDeath(pos: Vector3)
	BuildFX.destruction(pos)
	for i = 1, 4 do
		task.delay(0.3 * i, function()
			BuildFX.destruction(pos + Vector3.new(
				rng:NextNumber(-8, 8), rng:NextNumber(0, 6), rng:NextNumber(-8, 8)))
		end)
	end
end

-- A Mother is meat. She ruptures in stages rather than all at once -- the body first,
-- then out along it -- and every rupture is a full tier-3 death: geyser, gibs, pools.
function BuildFX.motherDeath(pos: Vector3)
	local anchor        = Instance.new("Part")
	anchor.Name         = "_MotherDeathSFX"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CanTouch     = false
	anchor.CastShadow   = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.one * 0.1
	anchor.Position     = pos
	anchor.Parent       = workspace
	local snd                = Instance.new("Sound")
	snd.SoundId              = BuildFX.MOTHER_SOUND
	snd.Volume               = 1.4
	snd.PlaybackSpeed        = 0.55           -- pitched right down: this is a big body
	snd.RollOffMode          = Enum.RollOffMode.Linear
	snd.RollOffMinDistance   = 20
	snd.RollOffMaxDistance   = 400
	snd.Parent               = anchor
	snd:Play()
	Debris:AddItem(anchor, 8)

	-- HP is passed straight to the gore scaler, which caps out well below a Mother's own
	-- pool -- her death is meant to sit at that ceiling.
	local maxHp = (Config.BUILDING_HP :: any).CommandCenter
	for i = 0, 3 do
		task.delay(0.32 * i, function()
			-- The first rupture is the body itself; the rest tear open around it.
			local off = Vector3.new(0, 2, 0)
			if i > 0 then
				off = Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(0, 4), rng:NextNumber(-6, 6))
			end
			GoreManager.spawn("Mother", pos + off, 3, maxHp)
		end)
	end
end

return BuildFX
