--!strict
--[[
	CombatFX — every one-shot combat effect the client draws: the shots that fly, the
	things they hit, and the sounds both make.

	Nothing in here knows anything about the match. Each function is handed a position (or
	a from/to pair), drops parts and particles into the workspace, animates them off one
	PerfProbe render binding, and lets Debris clean them up. That makes it scenery, not
	game logic -- which is why it lives beside init.client rather than inside it. Pulling
	it out took the main client script from 5.5k lines to 3.7k and, more to the point, off
	the shoulder of Luau's ceiling of 200 locals per chunk.

	init.client calls these from its UnitHit / turret-fire handlers, e.g.
	  CombatFX.tankShell(fromPos, toPos)
	  CombatFX.sound3D(pos, CombatFX.SND_TANK, 0.7)
]]

local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Config    = require(Shared:WaitForChild("Config"))
local PerfProbe = require(Shared:WaitForChild("PerfProbe"))

local CombatFX = {}

-- ── Unit attack VFX ──────────────────────────────────────────────────────────
-- Traveling projectile from attacker → target, then a brief impact flash.
-- Survivors: small fast yellow bullet.  Tanks: larger slower orange shell with arc.
-- Elite: large purple lobbed orb with trail + full explosion VFX.

-- Elite explosion: single RenderStepped connection animates all pieces together.
function CombatFX.eliteExplosion(pos: Vector3)
	-- ── Core burst (instant, very short) ──────────────────────────────────
	local core        = Instance.new("Part")
	core.Name         = "_ECore"
	core.Shape        = Enum.PartType.Ball
	core.Size         = Vector3.new(3, 3, 3)
	core.BrickColor   = BrickColor.new("White")
	core.Material     = Enum.Material.Neon
	core.Anchored     = true
	core.CanCollide   = false
	core.CanQuery     = false
	core.CanTouch     = false
	core.CastShadow   = false
	core.Position     = pos
	core.Parent       = workspace

	-- ── Outer flash (expands + fades) ─────────────────────────────────────
	local flash        = Instance.new("Part")
	flash.Name         = "_EFlash"
	flash.Shape        = Enum.PartType.Ball
	flash.Size         = Vector3.new(2, 2, 2)
	flash.BrickColor   = BrickColor.new("Bright violet")
	flash.Material     = Enum.Material.Neon
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CanTouch     = false
	flash.CastShadow   = false
	flash.Position     = pos
	flash.Parent       = workspace

	-- ── Shockwave ring (horizontal disc expanding outward) ─────────────────
	-- Cylinder in Roblox: round face along X axis, Size.X = length, Size.Y = Size.Z = diameter.
	-- Rotate 90° around Z so the disc lies flat (Y axis = up).
	local ring         = Instance.new("Part")
	ring.Name          = "_ERing"
	ring.Shape         = Enum.PartType.Cylinder
	ring.Size          = Vector3.new(0.35, 1, 1)
	ring.BrickColor    = BrickColor.new("Bright violet")
	ring.Material      = Enum.Material.Neon
	ring.Anchored      = true
	ring.CanCollide    = false
	ring.CanQuery      = false
	ring.CanTouch      = false
	ring.CastShadow    = false
	ring.CFrame        = CFrame.new(pos + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent        = workspace

	-- ── Debris chunks (5 pieces, fly outward with gravity) ────────────────
	type DebrisData = { part: Part, vx: number, vy: number, vz: number }
	local debris: { DebrisData } = {}
	for i = 1, 5 do
		local angle = (i - 1) / 5 * math.pi * 2 + math.random() * 0.6
		local spd   = 10 + math.random() * 7
		local d: Part = Instance.new("Part")
		d.Name        = "_EDeb"
		d.Size        = Vector3.new(0.9, 0.9, 0.9)
		d.BrickColor  = i % 2 == 0 and BrickColor.new("Dark indigo") or BrickColor.new("Bright violet")
		d.Material    = Enum.Material.Neon
		d.Anchored    = true
		d.CanCollide  = false
		d.CanQuery    = false
		d.CanTouch    = false
		d.CastShadow  = false
		d.Position    = pos
		d.Parent      = workspace
		table.insert(debris, {
			part = d,
			vx   = math.cos(angle) * spd,
			vy   = 8 + math.random() * 5,
			vz   = math.sin(angle) * spd,
		})
	end

	-- ── Single connection animates all pieces ──────────────────────────────
	local FLASH_DUR  = 0.30
	local RING_DUR   = 0.22
	local CORE_DUR   = 0.10
	local DEBRIS_DUR = 0.55

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt

		-- Core: quick white burst
		if core then
			if elapsed < CORE_DUR then
				core.Transparency = elapsed / CORE_DUR
			else
				core:Destroy()
				core = nil :: any
			end
		end

		-- Flash: expands 2→9 studs, fades out
		if flash then
			if elapsed < FLASH_DUR then
				local t = elapsed / FLASH_DUR
				local s = 2 + t * 7
				flash.Size         = Vector3.new(s, s, s)
				flash.Transparency = t * 0.85
			else
				flash:Destroy()
				flash = nil :: any
			end
		end

		-- Ring: diameter expands 1→12 studs, fades out
		if ring then
			if elapsed < RING_DUR then
				local t = elapsed / RING_DUR
				local d = 1 + t * 11
				ring.Size         = Vector3.new(0.35, d, d)
				ring.Transparency = 0.2 + t * 0.8
			else
				ring:Destroy()
				ring = nil :: any
			end
		end

		-- Debris: fly outward under gravity, fade
		for _, db in debris do
			if db.part then
				if elapsed < DEBRIS_DUR then
					local t = elapsed / DEBRIS_DUR
					db.vy -= 30 * dt
					db.part.Position = db.part.Position
						+ Vector3.new(db.vx * dt, db.vy * dt, db.vz * dt)
					db.part.Transparency = t
				else
					db.part:Destroy()
					db.part = nil :: any
				end
			end
		end

		if elapsed >= DEBRIS_DUR then
			conn:Disconnect()
		end
	end)
end

-- Tank shell explosion: orange fireball, shockwave ring, debris chunks.
function CombatFX.tankExplosion(pos: Vector3)
	-- Core: instant white burst
	local core       = Instance.new("Part")
	core.Name        = "_TCore"
	core.Shape       = Enum.PartType.Ball
	core.Size        = Vector3.new(4, 4, 4)
	core.BrickColor  = BrickColor.new("White")
	core.Material    = Enum.Material.Neon
	core.Anchored    = true
	core.CanCollide  = false
	core.CanQuery    = false
	core.CanTouch    = false
	core.CastShadow  = false
	core.Position    = pos
	core.Parent      = workspace

	-- Fireball: expands 3 → 18 studs, orange → dark orange fade
	local fire       = Instance.new("Part")
	fire.Name        = "_TFire"
	fire.Shape       = Enum.PartType.Ball
	fire.Size        = Vector3.new(3, 3, 3)
	fire.BrickColor  = BrickColor.new("Bright orange")
	fire.Material    = Enum.Material.Neon
	fire.Anchored    = true
	fire.CanCollide  = false
	fire.CanQuery    = false
	fire.CanTouch    = false
	fire.CastShadow  = false
	fire.Position    = pos
	fire.Parent      = workspace

	-- Inner ember: smaller, persists slightly longer for depth
	local ember      = Instance.new("Part")
	ember.Name       = "_TEmber"
	ember.Shape      = Enum.PartType.Ball
	ember.Size       = Vector3.new(2, 2, 2)
	ember.BrickColor = BrickColor.new("Bright yellow")
	ember.Material   = Enum.Material.Neon
	ember.Anchored   = true
	ember.CanCollide = false
	ember.CanQuery   = false
	ember.CanTouch   = false
	ember.CastShadow = false
	ember.Position   = pos
	ember.Parent     = workspace

	-- Shockwave ring: horizontal disc expanding outward
	local ring       = Instance.new("Part")
	ring.Name        = "_TRing"
	ring.Shape       = Enum.PartType.Cylinder
	ring.Size        = Vector3.new(0.4, 1, 1)
	ring.BrickColor  = BrickColor.new("Bright orange")
	ring.Material    = Enum.Material.Neon
	ring.Anchored    = true
	ring.CanCollide  = false
	ring.CanQuery    = false
	ring.CanTouch    = false
	ring.CastShadow  = false
	ring.CFrame      = CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent      = workspace

	-- Debris: 7 chunks fly outward under gravity
	type DebrisData = { part: Part, vx: number, vy: number, vz: number }
	local debris: { DebrisData } = {}
	for i = 1, 7 do
		local angle = (i - 1) / 7 * math.pi * 2 + math.random() * 0.5
		local spd   = 12 + math.random() * 9
		local d: Part = Instance.new("Part")
		d.Name        = "_TDeb"
		d.Size        = Vector3.new(0.7 + math.random() * 0.6, 0.7 + math.random() * 0.6, 0.7 + math.random() * 0.6)
		d.BrickColor  = (i % 3 == 0) and BrickColor.new("Bright yellow")
			or (i % 3 == 1) and BrickColor.new("Bright orange")
			or BrickColor.new("Reddish brown")
		d.Material    = Enum.Material.Neon
		d.Anchored    = true
		d.CanCollide  = false
		d.CanQuery    = false
		d.CanTouch    = false
		d.CastShadow  = false
		d.Position    = pos
		d.Parent      = workspace
		table.insert(debris, {
			part = d,
			vx   = math.cos(angle) * spd,
			vy   = 9 + math.random() * 6,
			vz   = math.sin(angle) * spd,
		})
	end

	local CORE_DUR   = 0.08
	local FIRE_DUR   = 0.40
	local EMBER_DUR  = 0.25
	local RING_DUR   = 0.28
	local DEBRIS_DUR = 0.65

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt

		if core then
			if elapsed < CORE_DUR then
				core.Transparency = elapsed / CORE_DUR
			else
				core:Destroy(); core = nil :: any
			end
		end

		if fire then
			if elapsed < FIRE_DUR then
				local t = elapsed / FIRE_DUR
				local s = 3 + t * 15
				fire.Size         = Vector3.new(s, s, s)
				fire.Transparency = 0.1 + t * 0.9
			else
				fire:Destroy(); fire = nil :: any
			end
		end

		if ember then
			if elapsed < EMBER_DUR then
				local t = elapsed / EMBER_DUR
				local s = 2 + t * 4
				ember.Size         = Vector3.new(s, s, s)
				ember.Transparency = t
			else
				ember:Destroy(); ember = nil :: any
			end
		end

		if ring then
			if elapsed < RING_DUR then
				local t = elapsed / RING_DUR
				local d = 1 + t * 20
				ring.Size         = Vector3.new(0.4, d, d)
				ring.Transparency = 0.15 + t * 0.85
			else
				ring:Destroy(); ring = nil :: any
			end
		end

		for _, db in debris do
			if db.part then
				if elapsed < DEBRIS_DUR then
					local t = elapsed / DEBRIS_DUR
					db.vy -= 35 * dt
					db.part.Position = db.part.Position
						+ Vector3.new(db.vx * dt, db.vy * dt, db.vz * dt)
					db.part.Transparency = math.max(0, t - 0.2) / 0.8
				else
					db.part:Destroy(); db.part = nil :: any
				end
			end
		end

		if elapsed >= DEBRIS_DUR then conn:Disconnect() end
	end)
end

-- Rocket Barrage: 3 small rockets that spiral toward the target before impact.
-- Each rocket has a random landing offset and converging helix animation.
function CombatFX.rocketBarrage(fromPos: Vector3, toPos: Vector3)
	local TRAVEL  = 0.55   -- seconds per rocket
	local ARC     = 3.5    -- height of the ballistic arc
	local HELIX_R = 2.8    -- helix radius at launch; shrinks to 0 at impact
	local TWISTS  = 2      -- full rotations during flight

	for i = 1, 3 do
		local launchDelay = (i - 1) * 0.13
		local phase       = (i - 1) * (math.pi * 2 / 3)  -- 120° apart

		-- Small random landing spread per rocket (server mirrors this for damage)
		local lx = (math.random() - 0.5) * 6
		local lz = (math.random() - 0.5) * 6

		task.delay(launchDelay, function()
			local origin = fromPos + Vector3.new(0, 2.2, 0)
			local dest   = toPos   + Vector3.new(lx, 0.4, lz)

			local rocket        = Instance.new("Part")
			rocket.Name         = "_BarrageRocket"
			rocket.Shape        = Enum.PartType.Block
			rocket.Size         = Vector3.new(0.5, 0.5, 1.4)
			rocket.Color        = Color3.fromRGB(220, 60, 30)
			rocket.Material     = Enum.Material.Neon
			rocket.Anchored     = true
			rocket.CanCollide   = false
			rocket.CanQuery     = false
			rocket.CanTouch     = false
			rocket.CastShadow   = false
			rocket.Position     = origin
			rocket.Parent       = workspace

			local a0            = Instance.new("Attachment", rocket)
			a0.Position         = Vector3.new(0, 0, 0.6)
			local a1            = Instance.new("Attachment", rocket)
			a1.Position         = Vector3.new(0, 0, -0.6)

			local trail             = Instance.new("Trail", rocket)
			trail.Attachment0       = a0
			trail.Attachment1       = a1
			trail.Lifetime          = 0.20
			trail.MinLength         = 0
			trail.FaceCamera        = true
			trail.Color             = ColorSequence.new({
				ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 120,  30)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200,  50,  10)),
				ColorSequenceKeypoint.new(1,   Color3.fromRGB( 60,  10,   0)),
			})
			trail.Transparency  = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.0),
				NumberSequenceKeypoint.new(1, 1.0),
			})
			trail.WidthScale    = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.9),
				NumberSequenceKeypoint.new(1, 0.0),
			})

			local elapsed = 0
			local conn: RBXScriptConnection
			conn = PerfProbe.onRender("ClientFX", function(dt)
				elapsed += dt
				local t = math.min(elapsed / TRAVEL, 1)

				-- Ballistic arc lerp
				local basePath = origin:Lerp(dest, t)
					+ Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

				-- Helix: radius collapses to 0 as rocket converges on target
				local helixRadius = HELIX_R * (1 - t)
				local angle       = phase + t * TWISTS * math.pi * 2
				local helixOffset = Vector3.new(
					math.cos(angle) * helixRadius,
					0,
					math.sin(angle) * helixRadius
				)
				local newPos = basePath + helixOffset

				-- Orient nose toward next position
				if t < 0.97 then
					local tN    = math.min(t + 0.04, 0.97)
					local baseN = origin:Lerp(dest, tN)
						+ Vector3.new(0, math.sin(tN * math.pi) * ARC, 0)
					local helN  = Vector3.new(
						math.cos(phase + tN * TWISTS * math.pi * 2) * HELIX_R * (1 - tN),
						0,
						math.sin(phase + tN * TWISTS * math.pi * 2) * HELIX_R * (1 - tN)
					)
					local dir = (baseN + helN) - newPos
					if dir.Magnitude > 0.05 then
						rocket.CFrame = CFrame.lookAt(newPos, newPos + dir)
					else
						rocket.Position = newPos
					end
				else
					rocket.Position = newPos
				end

				if t >= 1 then
					conn:Disconnect()
					rocket:Destroy()
					CombatFX.tankExplosion(dest - Vector3.new(0, 0.2, 0))
				end
			end)
		end)
	end
end

-- Tank shell: heavy arcing projectile with an orange-to-red trail.
function CombatFX.tankShell(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.48
	local ARC    = 6.0

	local origin = fromPos + Vector3.new(0, 2.0, 0)
	local dest   = toPos   + Vector3.new(0, 0.5, 0)

	local shell        = Instance.new("Part")
	shell.Name         = "_TankShell"
	shell.Shape        = Enum.PartType.Ball
	shell.Size         = Vector3.new(1.1, 1.1, 1.1)
	shell.BrickColor   = BrickColor.new("Bright orange")
	shell.Material     = Enum.Material.Neon
	shell.Anchored     = true
	shell.CanCollide   = false
	shell.CanQuery     = false
	shell.CanTouch     = false
	shell.CastShadow   = false
	shell.Position     = origin
	shell.Parent       = workspace

	local a0           = Instance.new("Attachment", shell)
	a0.Position        = Vector3.new(0,  0.35, 0)
	local a1           = Instance.new("Attachment", shell)
	a1.Position        = Vector3.new(0, -0.35, 0)

	local trail              = Instance.new("Trail", shell)
	trail.Attachment0        = a0
	trail.Attachment1        = a1
	trail.Lifetime           = 0.30
	trail.MinLength          = 0
	trail.FaceCamera         = true
	trail.Color              = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 200,  60)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(230, 100,  20)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB( 80,  20,   0)),
	})
	trail.Transparency       = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	trail.WidthScale         = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(1, 0.0),
	})

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		shell.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

		if t >= 1 then
			conn:Disconnect()
			shell:Destroy()
			CombatFX.tankExplosion(dest)
		end
	end)
end

-- Elite lobbed orb: large arc, purple, with a color trail.
function CombatFX.eliteProjectile(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.55
	local ARC    = 7.0

	local origin = fromPos + Vector3.new(0, 2.5, 0)
	local dest   = toPos   + Vector3.new(0, 1.0, 0)

	local proj        = Instance.new("Part")
	proj.Name         = "_EliteOrb"
	proj.Shape        = Enum.PartType.Ball
	proj.Size         = Vector3.new(1.2, 1.2, 1.2)
	proj.BrickColor   = BrickColor.new("Bright violet")
	proj.Material     = Enum.Material.Neon
	proj.Anchored     = true
	proj.CanCollide   = false
	proj.CanQuery     = false
	proj.CanTouch     = false
	proj.CastShadow   = false
	proj.Position     = origin
	proj.Parent       = workspace

	-- Trail (needs two attachments as anchor points)
	local a0          = Instance.new("Attachment", proj)
	a0.Position       = Vector3.new(0,  0.4, 0)
	local a1          = Instance.new("Attachment", proj)
	a1.Position       = Vector3.new(0, -0.4, 0)

	local trail              = Instance.new("Trail", proj)
	trail.Attachment0        = a0
	trail.Attachment1        = a1
	trail.Lifetime           = 0.45
	trail.MinLength          = 0
	trail.FaceCamera         = true
	trail.Color              = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 120, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160,  40, 220)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB( 60,   0, 120)),
	})
	trail.Transparency       = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	trail.WidthScale         = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(1, 0.0),
	})

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		proj.Position = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			CombatFX.eliteExplosion(dest)
		end
	end)
end

-- ── Medic heal beam VFX ──────────────────────────────────────────────────────
-- Trapper zip-wire: a black shiny cable that bolts onto the target and stays taut for
-- TRAPPER_SLOW_DURATION seconds while units are slowed, then snaps back to the trapper.
-- The wire follows both units as they move.
function CombatFX.trapperHarpoon(fromPos: Vector3, toPos: Vector3)
	if (toPos - fromPos).Magnitude < 0.5 then return end

	local SLOW_DUR  = Config.TRAPPER_SLOW_DURATION  -- 7 s taut
	local RETRACT_T = 0.4                           -- retraction animation duration

	-- Spatial lookup: find the actual BasePart closest to a world position
	local function findNearestUnit(searchPos: Vector3): BasePart?
		local unitsF = workspace:FindFirstChild("Units") :: Folder?
		if not unitsF then return nil end
		local best: BasePart? = nil
		local bestDist = 12
		for _, child in unitsF:GetChildren() do
			if not child:IsA("BasePart") then continue end
			local d = (child.Position - searchPos).Magnitude
			if d < bestDist then bestDist = d; best = child :: BasePart end
		end
		return best
	end

	-- fromPos is the trapper's centre; toPos is target top-centre (part.Position + sizeY/2).
	-- Tank sizeY = 5, so target part centre is ~2.5 below toPos.
	local trapperPart = findNearestUnit(fromPos)
	local targetPart  = findNearestUnit(toPos - Vector3.new(0, 2.5, 0))

	-- Wire: thin black SmoothPlastic cable
	local wire         = Instance.new("Part")
	wire.Name          = "_HarpoonWire"
	wire.Color         = Color3.fromRGB(12, 12, 16)
	wire.Material      = Enum.Material.SmoothPlastic
	wire.CastShadow    = false
	wire.Anchored      = true
	wire.CanCollide    = false
	wire.CanQuery      = false
	wire.CanTouch      = false
	wire.Parent        = workspace

	-- Bolt: small dark metal cylinder clamped onto the target's side
	local bolt         = Instance.new("Part")
	bolt.Name          = "_HarpoonBolt"
	bolt.Shape         = Enum.PartType.Cylinder
	bolt.Size          = Vector3.new(0.5, 0.6, 0.6)
	bolt.Color         = Color3.fromRGB(25, 25, 30)
	bolt.Material      = Enum.Material.Metal
	bolt.CastShadow    = false
	bolt.Anchored      = true
	bolt.CanCollide    = false
	bolt.CanQuery      = false
	bolt.CanTouch      = false
	bolt.Parent        = workspace

	local elapsed    = 0
	local retracting = false
	local retractT   = 0
	local anchorTip  = toPos  -- last known bolt position when retraction begins

	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt

		-- Resolve live positions — follow moving parts
		local basePos = (trapperPart and trapperPart.Parent)
			and (trapperPart.Position + Vector3.new(0, trapperPart.Size.Y * 0.25, 0))
			or  fromPos

		local tipPos = (targetPart and targetPart.Parent)
			and (targetPart.Position + Vector3.new(0, targetPart.Size.Y * 0.35, 0))
			or  anchorTip

		-- Target was destroyed early — start retraction from its last position
		if not retracting and targetPart and not targetPart.Parent then
			retracting = true
			anchorTip  = tipPos
		end

		-- Trapper was destroyed — remove wire immediately
		if trapperPart and not trapperPart.Parent then
			conn:Disconnect()
			wire:Destroy()
			bolt:Destroy()
			return
		end

		if not retracting then
			-- Stay taut: update wire and bolt each frame
			local d = (tipPos - basePos).Magnitude
			if d > 0.2 then
				wire.Size  = Vector3.new(0.18, 0.18, d)
				wire.CFrame = CFrame.lookAt(basePos, tipPos) * CFrame.new(0, 0, -d / 2)
			end
			-- Bolt cylinder axis points along the wire toward the trapper
			bolt.Position = tipPos
			bolt.CFrame   = CFrame.lookAt(tipPos, basePos) * CFrame.Angles(0, 0, math.pi / 2)

			if elapsed >= SLOW_DUR then
				retracting = true
				anchorTip  = tipPos
			end
		else
			-- Retraction: bolt slides from anchorTip back toward basePos
			retractT += dt
			local t    = math.clamp(retractT / RETRACT_T, 0, 1)
			local ease = t * (2 - t)  -- ease-out

			local boltNow = anchorTip:Lerp(basePos, ease)
			bolt.Position = boltNow
			bolt.CFrame   = CFrame.lookAt(boltNow, basePos) * CFrame.Angles(0, 0, math.pi / 2)

			local d = (boltNow - basePos).Magnitude
			if d > 0.25 then
				wire.Size  = Vector3.new(0.18, 0.18, d)
				wire.CFrame = CFrame.lookAt(basePos, boltNow) * CFrame.new(0, 0, -d / 2)
			else
				wire.Size = Vector3.new(0.18, 0.18, 0.25)
			end

			if t >= 1 then
				conn:Disconnect()
				wire:Destroy()
				bolt:Destroy()
			end
		end
	end)
end

-- A semi-transparent green neon beam that fades out over ~0.45 s.
function CombatFX.healBeam(fromPos: Vector3, toPos: Vector3)
	local dist = (toPos - fromPos).Magnitude
	if dist < 0.5 then return end

	local beam              = Instance.new("Part")
	beam.Name               = "_HealBeam"
	beam.Size               = Vector3.new(0.22, 0.22, dist)
	-- CFrame.lookAt positions at fromPos facing toPos (-Z forward);
	-- shift dist/2 along -Z to centre the beam between the two points.
	beam.CFrame             = CFrame.lookAt(fromPos, toPos) * CFrame.new(0, 0, -dist / 2)
	beam.Color              = Color3.fromRGB(80, 220, 120)
	beam.Material           = Enum.Material.Neon
	beam.Transparency       = 0.25
	beam.Anchored           = true
	beam.CanCollide         = false
	beam.CastShadow         = false
	beam.CanQuery           = false
	beam.CanTouch           = false
	beam.Parent             = workspace

	-- Small glow sphere at the target end
	local glow              = Instance.new("Part")
	glow.Name               = "_HealGlow"
	glow.Shape              = Enum.PartType.Ball
	glow.Size               = Vector3.new(0.8, 0.8, 0.8)
	glow.Color              = Color3.fromRGB(140, 255, 170)
	glow.Material           = Enum.Material.Neon
	glow.Transparency       = 0.3
	glow.Anchored           = true
	glow.CanCollide         = false
	glow.CastShadow         = false
	glow.CanQuery           = false
	glow.CanTouch           = false
	glow.Position           = toPos
	glow.Parent             = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.clamp(elapsed / 0.45, 0, 1)
		local alpha = t * t   -- ease-in fade
		beam.Transparency = 0.25 + alpha * 0.75
		glow.Transparency = 0.30 + alpha * 0.70
		if t >= 1 then
			conn:Disconnect()
			beam:Destroy()
			glow:Destroy()
		end
	end)
end

-- ── Howitzer VFX ──────────────────────────────────────────────────────────────

-- Impact: dirt geysers fly out of the ground and a dark crater fades over time.
function CombatFX.howitzerImpact(pos: Vector3)
	local groundPos = Vector3.new(pos.X, 0.15, pos.Z)

	-- ── Core burst ────────────────────────────────────────────────────────────
	local core        = Instance.new("Part")
	core.Name         = "_HwCore"
	core.Shape        = Enum.PartType.Ball
	core.Size         = Vector3.new(4, 4, 4)
	core.Color        = Color3.fromRGB(255, 240, 195)
	core.Material     = Enum.Material.Neon
	core.Anchored     = true; core.CanCollide = false; core.CanQuery = false; core.CastShadow = false
	core.Position     = pos
	core.Parent       = workspace

	-- ── Shockwave ring ────────────────────────────────────────────────────────
	-- Cylinder: axis along local X.  Rotate 90° on Z so it lies flat.
	local ring        = Instance.new("Part")
	ring.Name         = "_HwRing"
	ring.Shape        = Enum.PartType.Cylinder
	ring.Size         = Vector3.new(0.40, 1, 1)
	ring.Color        = Color3.fromRGB(210, 145, 40)
	ring.Material     = Enum.Material.Neon
	ring.Anchored     = true; ring.CanCollide = false; ring.CanQuery = false; ring.CastShadow = false
	ring.CFrame       = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent       = workspace

	-- ── Dust puffs ────────────────────────────────────────────────────────────
	type DustData = { part: Part, vx: number, vy: number, vz: number, dur: number }
	local dustPuffs: { DustData } = {}
	for i = 1, 5 do
		local a   = (i / 5) * math.pi * 2 + math.random() * 0.7
		local spd = 3 + math.random() * 4
		local d: Part = Instance.new("Part")
		d.Name        = "_HwDust"
		d.Shape       = Enum.PartType.Ball
		d.Size        = Vector3.new(2.5, 2.5, 2.5)
		d.Color       = Color3.fromRGB(126, 108, 80)
		d.Material    = Enum.Material.SmoothPlastic
		d.Transparency = 0.22
		d.Anchored    = true; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
		d.Position    = groundPos + Vector3.new(math.cos(a) * 1.5, 0.4, math.sin(a) * 1.5)
		d.Parent      = workspace
		table.insert(dustPuffs, {
			part = d,
			vx   = math.cos(a) * spd,
			vy   = 3 + math.random() * 3,
			vz   = math.sin(a) * spd,
			dur  = 0.36 + math.random() * 0.22,
		})
	end

	-- ── Dirt chunks ───────────────────────────────────────────────────────────
	type DirtChunk = { part: Part, vx: number, vy: number, vz: number }
	local DIRT_COLS = {
		Color3.fromRGB(68, 48, 30),
		Color3.fromRGB(84, 62, 40),
		Color3.fromRGB(98, 74, 50),
		Color3.fromRGB(54, 40, 26),
	}
	local chunks: { DirtChunk } = {}
	for i = 1, 14 do
		local a   = (i / 14) * math.pi * 2 + (math.random() - 0.5) * 0.45
		local spd = 9 + math.random() * 14
		local sz  = 0.5 + math.random() * 1.4
		local d: Part = Instance.new("Part")
		d.Name        = "_HwDirt"
		d.Size        = Vector3.new(sz, sz, sz)
		d.Color       = DIRT_COLS[math.random(1, #DIRT_COLS)]
		d.Material    = Enum.Material.SmoothPlastic
		d.Anchored    = true; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
		d.Position    = groundPos + Vector3.new(
			(math.random() - 0.5) * 2.5, 0.3, (math.random() - 0.5) * 2.5)
		d.Parent      = workspace
		table.insert(chunks, {
			part = d,
			vx   = math.cos(a) * spd,
			vy   = 18 + math.random() * 22,   -- strong upward launch
			vz   = math.sin(a) * spd,
		})
	end

	-- ── Crater (outer + inner ring, fades over ~9 seconds) ────────────────────
	local crater      = Instance.new("Part")
	crater.Name       = "_HwCrater"
	crater.Shape      = Enum.PartType.Cylinder
	crater.Size       = Vector3.new(0.28, 8.5, 8.5)
	crater.Color      = Color3.fromRGB(36, 24, 14)
	crater.Material   = Enum.Material.SmoothPlastic
	crater.Anchored   = true; crater.CanCollide = false; crater.CanQuery = false; crater.CastShadow = false
	crater.CFrame     = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.pi / 2)
	crater.Parent     = workspace

	local craterInner      = Instance.new("Part")
	craterInner.Name       = "_HwCraterIn"
	craterInner.Shape      = Enum.PartType.Cylinder
	craterInner.Size       = Vector3.new(0.30, 4.0, 4.0)
	craterInner.Color      = Color3.fromRGB(16, 10, 6)
	craterInner.Material   = Enum.Material.SmoothPlastic
	craterInner.Anchored   = true; craterInner.CanCollide = false; craterInner.CanQuery = false; craterInner.CastShadow = false
	craterInner.CFrame     = CFrame.new(groundPos + Vector3.new(0, 0.02, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	craterInner.Parent     = workspace

	-- ── Animate all short-lived effects in one connection ─────────────────────
	local CORE_DUR = 0.13
	local RING_DUR = 0.30
	local DIRT_DUR = 0.92
	local GRAVITY  = 34

	local elapsed = 0
	local hwConn: RBXScriptConnection
	hwConn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt

		if core then
			if elapsed < CORE_DUR then
				local p = elapsed / CORE_DUR
				local s = 4 + p * 7
				core.Size         = Vector3.new(s, s, s)
				core.Transparency = p
			else
				core:Destroy(); core = nil :: any
			end
		end

		if ring then
			if elapsed < RING_DUR then
				local p = elapsed / RING_DUR
				local d = 1 + p * 17
				ring.Size         = Vector3.new(0.40, d, d)
				ring.Transparency = 0.10 + p * 0.90
			else
				ring:Destroy(); ring = nil :: any
			end
		end

		for _, dc in dustPuffs do
			if dc.part then
				if elapsed < dc.dur then
					local p = elapsed / dc.dur
					dc.vy -= 14 * dt
					dc.part.Position = dc.part.Position
						+ Vector3.new(dc.vx * dt, dc.vy * dt, dc.vz * dt)
					local s = 2.5 + p * 3.0
					dc.part.Size         = Vector3.new(s, s, s)
					dc.part.Transparency = 0.22 + p * 0.78
				else
					dc.part:Destroy(); dc.part = nil :: any
				end
			end
		end

		for _, c in chunks do
			if c.part then
				if elapsed < DIRT_DUR then
					c.vy -= GRAVITY * dt
					c.part.Position = c.part.Position
						+ Vector3.new(c.vx * dt, c.vy * dt, c.vz * dt)
					c.part.Transparency = elapsed / DIRT_DUR
				else
					c.part:Destroy(); c.part = nil :: any
				end
			end
		end

		if elapsed >= DIRT_DUR then hwConn:Disconnect() end
	end)

	-- Crater fades independently over a long duration
	task.spawn(function()
		local CRATER_LIFE = 9
		local ct = 0
		while crater.Parent do
			ct += task.wait(0.15)
			local p = math.clamp(ct / CRATER_LIFE, 0, 1)
			if crater.Parent       then crater.Transparency       = p end
			if craterInner.Parent  then craterInner.Transparency  = p end
			if p >= 1 then
				if crater.Parent       then crater:Destroy()      end
				if craterInner.Parent  then craterInner:Destroy() end
				break
			end
		end
	end)

	-- ── Fire zone: 5 s burn then 3 s fade ────────────────────────────────────
	-- Outer base + inner core, each carrying a Fire and Smoke instance.
	local fireCfgs = {
		{ sz = 8,  heat = 10, fsz = 10, c1 = Color3.fromRGB(255, 90, 10),  c2 = Color3.fromRGB(255, 200, 0) },
		{ sz = 4,  heat = 18, fsz = 6,  c1 = Color3.fromRGB(255, 35, 0),   c2 = Color3.fromRGB(255, 140, 0) },
	}
	local fireParts: { Part } = {}
	local fireObjs:  { Fire } = {}
	local smokeObj: Smoke? = nil

	for i, cfg in fireCfgs do
		local fp         = Instance.new("Part")
		fp.Size          = Vector3.new(cfg.sz, 0.5, cfg.sz)
		fp.Anchored      = true
		fp.CanCollide    = false
		fp.CanQuery      = false
		fp.CanTouch      = false
		fp.CastShadow    = false
		fp.Transparency  = 1
		fp.Position      = Vector3.new(groundPos.X, 0.25, groundPos.Z)
		fp.Parent        = workspace

		local f              = Instance.new("Fire")
		f.Heat               = cfg.heat
		f.Size               = cfg.fsz
		f.Color              = cfg.c1
		f.SecondaryColor     = cfg.c2
		f.Parent             = fp

		fireParts[i] = fp
		fireObjs[i]  = f

		if i == 1 then
			local sm             = Instance.new("Smoke")
			sm.Color             = Color3.fromRGB(50, 42, 36)
			sm.Opacity           = 0.30
			sm.RiseVelocity      = 7
			sm.Size              = 2
			sm.Parent            = fp
			smokeObj             = sm
		end
	end

	-- Store initial values for lerping during the fade
	local initSizes: { number } = {}
	local initHeats: { number } = {}
	for i, f in fireObjs do
		initSizes[i] = f.Size
		initHeats[i] = f.Heat
	end
	local initSmokeOpacity = smokeObj and smokeObj.Opacity or 0

	task.spawn(function()
		local FIRE_FULL = 5
		local FIRE_FADE = 3
		-- Wait out the full-burn phase
		task.wait(FIRE_FULL)
		-- Fade phase
		local e = 0
		while e < FIRE_FADE do
			local idt = task.wait(0.05)
			e = math.min(e + idt, FIRE_FADE)
			local t = e / FIRE_FADE
			for i, f in fireObjs do
				if f.Parent then
					f.Size = math.max(0.05, initSizes[i] * (1 - t))
					f.Heat = initHeats[i] * (1 - t)
				end
			end
			if smokeObj and smokeObj.Parent then
				smokeObj.Opacity = math.max(0, initSmokeOpacity * (1 - t))
			end
		end
		for _, fp in fireParts do
			if fp.Parent then fp:Destroy() end
		end
	end)
end

-- Howitzer shell: large oriented tracer streak lobbed on a high arc.
-- The shell rotates along the arc (oriented toward its velocity direction at every
-- frame) giving a satisfying "arcing artillery round" appearance.
function CombatFX.howitzerShell(fromPos: Vector3, toPos: Vector3)
	local TRAVEL     = 0.72   -- seconds — slow enough to appreciate the arc
	local ARC        = 20.0   -- studs — dramatic high parabola
	local STREAK_LEN = 4.0    -- stud length of the shell body

	local origin = fromPos + Vector3.new(0, 2, 0)
	local dest   = toPos   + Vector3.new(0, 0.5, 0)

	local rawDir = dest - origin
	local dist   = rawDir.Magnitude
	local tUnit  = if dist > 0.01 then rawDir / dist else Vector3.new(0, 0, -1)

	-- ── Steam muzzle blast (large core + expanding steam ring) ───────────────
	local muzzle          = Instance.new("Part")
	muzzle.Name           = "_HwMuzzle"
	muzzle.Size           = Vector3.new(2.2, 2.2, 2.2)
	muzzle.Shape          = Enum.PartType.Ball
	muzzle.Color          = Color3.fromRGB(240, 230, 210)
	muzzle.Material       = Enum.Material.Neon
	muzzle.Anchored       = true; muzzle.CanCollide = false; muzzle.CanQuery = false; muzzle.CastShadow = false
	muzzle.Position       = origin
	muzzle.Parent         = workspace

	-- Steam ring expanding from barrel
	local steamRing        = Instance.new("Part")
	steamRing.Name         = "_HwSteamRing"
	steamRing.Shape        = Enum.PartType.Cylinder
	steamRing.Size         = Vector3.new(0.35, 1, 1)
	steamRing.Color        = Color3.fromRGB(210, 210, 210)
	steamRing.Material     = Enum.Material.Neon
	steamRing.Transparency = 0.3
	steamRing.Anchored     = true; steamRing.CanCollide = false; steamRing.CanQuery = false; steamRing.CastShadow = false
	steamRing.CFrame       = CFrame.new(origin) * CFrame.Angles(0, 0, math.pi / 2)
	steamRing.Parent       = workspace

	-- Animate muzzle flash and steam ring
	local muzzElapsed = 0
	local MUZZLE_DUR  = 0.18
	local muzzConn: RBXScriptConnection
	muzzConn = PerfProbe.onRender("ClientFX", function(dt)
		muzzElapsed += dt
		local p = math.min(muzzElapsed / MUZZLE_DUR, 1)
		if muzzle.Parent then
			muzzle.Size         = Vector3.new(2.2 + p * 3, 2.2 + p * 3, 2.2 + p * 3)
			muzzle.Transparency = p
		end
		if steamRing.Parent then
			local d = 1 + p * 10
			steamRing.Size         = Vector3.new(0.35, d, d)
			steamRing.Transparency = 0.2 + p * 0.8
		end
		if p >= 1 then
			muzzConn:Disconnect()
			if muzzle.Parent    then muzzle:Destroy()    end
			if steamRing.Parent then steamRing:Destroy() end
		end
	end)

	-- ── Shell body — oriented along arc tangent (velocity direction) ──────────
	-- At t=0 the shell points steeply upward; at peak it's horizontal;
	-- on descent it dips nose-down toward the target — exactly like a real shell.
	local initVY  = math.cos(0) * math.pi * ARC            -- π * 20 ≈ 62.8 upward
	local initVel = rawDir + Vector3.new(0, initVY, 0)
	local initDir = if initVel.Magnitude > 0.01 then initVel.Unit else tUnit
	local initCF  = CFrame.lookAt(origin - initDir * (STREAK_LEN * 0.5), origin + initDir)

	-- Inner core: thin bright near-white rod
	local proj        = Instance.new("Part")
	proj.Name         = "_HwShell"
	proj.Size         = Vector3.new(0.18, 0.18, STREAK_LEN)
	proj.Color        = Color3.fromRGB(255, 235, 165)
	proj.Material     = Enum.Material.Neon
	proj.Anchored     = true; proj.CanCollide = false; proj.CanQuery = false; proj.CastShadow = false
	proj.CFrame       = initCF
	proj.Parent       = workspace

	-- Outer glow: wider amber-orange shell
	local glow        = Instance.new("Part")
	glow.Name         = "_HwShellGlow"
	glow.Size         = Vector3.new(0.44, 0.44, STREAK_LEN + 0.8)
	glow.Color        = Color3.fromRGB(255, 128, 28)
	glow.Material     = Enum.Material.Neon
	glow.Transparency = 0.42
	glow.Anchored     = true; glow.CanCollide = false; glow.CanQuery = false; glow.CastShadow = false
	glow.CFrame       = initCF
	glow.Parent       = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)

		-- Arc position: lerp + sine arc
		local currentPos = origin + tUnit * (t * dist)
			+ Vector3.new(0, math.sin(t * math.pi) * ARC, 0)

		-- Velocity tangent: derivative of arc with respect to t
		-- d/dt[lerp] = rawDir;  d/dt[sin(π*t)*ARC] = cos(π*t)*π*ARC
		local vY  = math.cos(t * math.pi) * math.pi * ARC
		local vel = rawDir + Vector3.new(0, vY, 0)
		local dir = if vel.Magnitude > 0.01 then vel.Unit else Vector3.new(0, -1, 0)

		-- Place center half a streak behind the leading edge so tip == currentPos
		local center = currentPos - dir * (STREAK_LEN * 0.5)
		local cf     = CFrame.lookAt(center, center + dir)
		proj.CFrame  = cf
		glow.CFrame  = cf

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			glow:Destroy()
			CombatFX.howitzerImpact(dest)
		end
	end)
end

-- Plays a short 3D-positional sound at `pos` and auto-destroys when finished.
CombatFX.SND_SOLDIER          = "rbxassetid://138651783706047"
CombatFX.SND_SNIPER           = "rbxassetid://1231327271"
CombatFX.SND_TANK             = "rbxassetid://122500594085328"
CombatFX.SND_LAMPREY_ATTACK   = "rbxassetid://106129163863465"
CombatFX.SND_LAMPREY_IMPACT   = "rbxassetid://99851197639856"
CombatFX.SND_LAMPREY_EGG_LAND = "rbxassetid://133222321566847"
CombatFX.SND_LAMPREY_HATCH    = "rbxassetid://106129163863465"

function CombatFX.sound3D(pos: Vector3, soundId: string, volume: number)
	local p            = Instance.new("Part")
	p.Anchored         = true
	p.CanCollide       = false
	p.CanTouch         = false
	p.CanQuery         = false
	p.CastShadow       = false
	p.Transparency     = 1
	p.Size             = Vector3.new(1, 1, 1)
	p.Position         = pos
	p.Parent           = workspace
	local snd                  = Instance.new("Sound")
	snd.SoundId                = soundId
	snd.Volume                 = volume
	snd.RollOffMaxDistance     = 120
	snd.RollOffMinDistance     = 10
	snd.RollOffMode            = Enum.RollOffMode.Linear
	snd.Parent                 = p
	snd:Play()
	snd.Ended:Once(function() p:Destroy() end)
end

-- Lamprey bile: a glowing acid bolt hurled from the reared head. A bright neon
-- core wrapped in a translucent slime aura streaks along a ribbon trail, spinning
-- and wobbling; on impact it flashes, throws a ground shockwave ring and a spray
-- of physics-driven globs, and leaves a bubbling corrosive pool that fizzles away.
function CombatFX.lampreyBile(fromPos: Vector3, toPos: Vector3)
	local Debris = game:GetService("Debris")
	-- Tighter and meaner than the original lob: a smaller bolt that lands sooner
	-- on a flatter trajectory, so the spit reads as a spat dart, not a heaved blob.
	local BOLT   = 0.7          -- size scale of the flying bolt
	local TRAVEL = 0.32         -- seconds in flight
	local ARC    = 7.0          -- lob height in studs
	local CORE_D = 1.6 * BOLT   -- glowing core diameter
	local AURA_D = 2.5 * BOLT   -- slime aura diameter

	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	local dir  = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
	-- Origin ≈ the lamprey's reared head/maw (forward + a little up from the pivot)
	local origin = fromPos + dir * 4.5 + Vector3.new(0, 1.4, 0)
	local dest   = toPos + Vector3.new(0, 0.5, 0)

	CombatFX.sound3D(origin, CombatFX.SND_LAMPREY_ATTACK, 0.85)

	local C_HOT  = Color3.fromRGB(190, 255, 100)   -- bright core / sparks
	local C_BILE = Color3.fromRGB(132, 214, 46)    -- mid acid
	local C_DK   = Color3.fromRGB(70, 130, 24)     -- dark drip

	-- ── Glowing core ──────────────────────────────────────────────────────────
	local glob          = Instance.new("Part")
	glob.Name           = "_LampreyBile"
	glob.Shape          = Enum.PartType.Ball
	glob.Size           = Vector3.new(CORE_D, CORE_D, CORE_D)
	glob.Color          = C_HOT
	glob.Material       = Enum.Material.Neon
	glob.Transparency   = 0
	glob.Anchored       = true; glob.CanCollide = false; glob.CanQuery = false; glob.CastShadow = false
	glob.Position       = origin
	glob.Parent         = workspace

	local light         = Instance.new("PointLight")
	light.Color         = C_BILE
	light.Brightness    = 4
	light.Range         = 14
	light.Parent        = glob

	-- ── Translucent slime aura that lags + breathes around the core ────────────
	local shell         = Instance.new("Part")
	shell.Name          = "_LampreyBileShell"
	shell.Shape         = Enum.PartType.Ball
	shell.Size          = Vector3.new(AURA_D, AURA_D, AURA_D)
	shell.Color         = C_BILE
	shell.Material      = Enum.Material.Neon
	shell.Transparency  = 0.55
	shell.Anchored      = true; shell.CanCollide = false; shell.CanQuery = false; shell.CastShadow = false
	shell.Position      = origin
	shell.Parent        = workspace

	-- ── Ribbon trail streaking behind the bolt ─────────────────────────────────
	local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0,  0.6 * BOLT, 0); a0.Parent = glob
	local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -0.6 * BOLT, 0); a1.Parent = glob
	local trail            = Instance.new("Trail")
	trail.Attachment0      = a0
	trail.Attachment1      = a1
	trail.Color            = ColorSequence.new(C_HOT, C_DK)
	trail.Transparency     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale       = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Lifetime         = 0.32
	trail.LightEmission    = 0.7
	trail.Parent           = glob

	-- ── Dribbling acid droplets shed in flight ─────────────────────────────────
	local drip                = Instance.new("ParticleEmitter")
	drip.Texture              = "rbxasset://textures/particles/sparkles_main.dds"
	drip.Color                = ColorSequence.new(C_HOT, C_DK)
	drip.LightEmission        = 0.8
	drip.Size                 = NumberSequence.new(0.7 * BOLT, 0.05)
	drip.Transparency         = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	drip.Lifetime             = NumberRange.new(0.3, 0.55)
	drip.Speed                = NumberRange.new(1, 3)
	drip.Acceleration         = Vector3.new(0, -36, 0)
	drip.SpreadAngle          = Vector2.new(40, 40)
	drip.Rate                 = 90
	drip.Parent               = glob

	local spin = 0
	local origElapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(bdt)
		origElapsed += bdt
		spin += bdt * 16
		local t    = math.min(origElapsed / TRAVEL, 1)
		local arcH = math.sin(t * math.pi) * ARC
		local pos  = origin:Lerp(dest, t) + Vector3.new(0, arcH, 0)
		local wob  = CORE_D + math.sin(origElapsed * 30) * 0.16 * BOLT
		glob.Size   = Vector3.new(wob, wob, wob)
		glob.CFrame = CFrame.new(pos) * CFrame.Angles(spin, spin * 0.7, 0)
		-- Aura lags slightly behind and pulses out of phase for a gooey feel
		local swob = AURA_D + math.sin(origElapsed * 22 + 1) * 0.24 * BOLT
		shell.Size     = Vector3.new(swob, swob, swob)
		shell.Position = shell.Position:Lerp(pos, 0.5)
		if t >= 1 then
			conn:Disconnect()
			drip.Enabled  = false
			trail.Enabled = false
			glob.Transparency  = 1
			shell.Transparency = 1
			Debris:AddItem(glob, 0.5)
			Debris:AddItem(shell, 0.1)

			CombatFX.sound3D(dest, CombatFX.SND_LAMPREY_IMPACT, 0.9)

			-- ── Impact flash ──
			local flash          = Instance.new("Part")
			flash.Shape          = Enum.PartType.Ball
			flash.Size           = Vector3.new(2, 2, 2)
			flash.Position       = dest
			flash.Color          = C_HOT
			flash.Material       = Enum.Material.Neon
			flash.Transparency   = 0.05
			flash.Anchored       = true; flash.CanCollide = false; flash.CanQuery = false; flash.CastShadow = false
			flash.Parent         = workspace
			local fLight         = Instance.new("PointLight")
			fLight.Color = C_BILE; fLight.Brightness = 6; fLight.Range = 18; fLight.Parent = flash
			local fe = 0
			local fc: RBXScriptConnection
			fc = PerfProbe.onRender("ClientFX", function(fdt)
				fe += fdt
				local fp = math.min(fe / 0.3, 1)
				local s  = 2 + fp * 7
				flash.Size         = Vector3.new(s, s, s)
				flash.Transparency = 0.05 + fp * 0.95
				fLight.Brightness  = 6 * (1 - fp)
				if fp >= 1 then fc:Disconnect(); flash:Destroy() end
			end)

			-- ── Ground shockwave ring ──
			local ring          = Instance.new("Part")
			ring.Shape          = Enum.PartType.Cylinder
			ring.Size           = Vector3.new(0.4, 3, 3)
			ring.CFrame         = CFrame.new(dest - Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			ring.Color          = C_HOT
			ring.Material       = Enum.Material.Neon
			ring.Transparency   = 0.2
			ring.Anchored       = true; ring.CanCollide = false; ring.CanQuery = false; ring.CastShadow = false
			ring.Parent         = workspace
			local re = 0
			local rc: RBXScriptConnection
			rc = PerfProbe.onRender("ClientFX", function(rdt)
				re += rdt
				local rp = math.min(re / 0.4, 1)
				local s  = 3 + rp * 16
				ring.Size         = Vector3.new(0.4, s, s)
				ring.Transparency = 0.2 + rp * 0.8
				if rp >= 1 then rc:Disconnect(); ring:Destroy() end
			end)

			-- ── Viscous globs flung outward with real physics ──
			for _ = 1, 8 do
				local g            = Instance.new("Part")
				g.Shape            = Enum.PartType.Ball
				local sz           = 0.4 + math.random() * 0.7
				g.Size             = Vector3.new(sz, sz, sz)
				g.Color            = C_BILE
				g.Material         = Enum.Material.Neon
				g.Anchored         = false; g.CanCollide = false; g.CanTouch = false; g.CastShadow = false
				g.Position         = dest + Vector3.new(0, 0.4, 0)
				g.AssemblyLinearVelocity = Vector3.new(
					(math.random() - 0.5) * 26,
					math.random() * 16 + 8,
					(math.random() - 0.5) * 26)
				g.Parent           = workspace
				Debris:AddItem(g, 0.8)
			end

			-- ── Lingering corrosive pool: bubbling + glowing, fizzles away ──
			local pool          = Instance.new("Part")
			pool.Shape          = Enum.PartType.Cylinder
			pool.Size           = Vector3.new(0.2, 5.5, 5.5)
			pool.CFrame         = CFrame.new(dest - Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			pool.Color          = C_BILE
			pool.Material       = Enum.Material.Neon
			pool.Transparency   = 0.25
			pool.Anchored       = true; pool.CanCollide = false; pool.CanQuery = false; pool.CastShadow = false
			pool.Parent         = workspace
			local pLight        = Instance.new("PointLight")
			pLight.Color = C_BILE; pLight.Brightness = 3; pLight.Range = 12; pLight.Parent = pool

			local bubbles                = Instance.new("ParticleEmitter")
			bubbles.Texture              = "rbxasset://textures/particles/smoke_main.dds"
			bubbles.Color                = ColorSequence.new(C_HOT, C_DK)
			bubbles.LightEmission        = 0.5
			bubbles.Size                 = NumberSequence.new(0.4, 0.9)
			bubbles.Transparency         = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(1, 1),
			})
			bubbles.Lifetime             = NumberRange.new(0.4, 0.8)
			bubbles.Speed                = NumberRange.new(2, 4)
			bubbles.Acceleration         = Vector3.new(0, 6, 0)
			bubbles.SpreadAngle          = Vector2.new(180, 180)
			bubbles.Rate                 = 40
			bubbles.Parent               = pool

			local pe = 0
			local pc: RBXScriptConnection
			pc = PerfProbe.onRender("ClientFX", function(pdt)
				pe += pdt
				local pp = math.min(pe / 1.5, 1)
				pool.Transparency = 0.25 + pp * 0.75
				pLight.Brightness = 3 * (1 - pp)
				if pp >= 0.5 then bubbles.Rate = 40 * (1 - (pp - 0.5) / 0.5) end
				if pp >= 1 then pc:Disconnect(); pool:Destroy() end
			end)
		end
	end)
end

-- ── Turret projectile VFX ─────────────────────────────────────────────────────

-- Base turret: small red ball + flash (unchanged)
function CombatFX.baseTurretShot(fromPos: Vector3, toPos: Vector3)
	local proj              = Instance.new("Part")
	proj.Name               = "_TurretProjectile"
	proj.Size               = Vector3.new(0.45, 0.45, 0.45)
	proj.Shape              = Enum.PartType.Ball
	proj.BrickColor         = BrickColor.new("Bright red")
	proj.Material           = Enum.Material.Neon
	proj.Anchored           = true
	proj.CanCollide         = false
	proj.CanQuery           = false
	proj.CanTouch           = false
	proj.CastShadow         = false
	proj.Position           = fromPos
	proj.Parent             = workspace

	local TRAVEL = 0.22
	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)
		proj.Position = fromPos:Lerp(toPos, t) + Vector3.new(0, math.sin(t * math.pi) * 2, 0)
		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			local flash             = Instance.new("Part")
			flash.Name              = "_TurretImpact"
			flash.Size              = Vector3.new(1.8, 1.8, 1.8)
			flash.Shape             = Enum.PartType.Ball
			flash.BrickColor        = BrickColor.new("Bright red")
			flash.Material          = Enum.Material.Neon
			flash.Anchored          = true
			flash.CanCollide        = false
			flash.CanQuery          = false
			flash.CanTouch          = false
			flash.CastShadow        = false
			flash.Position          = toPos
			flash.Parent            = workspace
			task.delay(0.1, function() flash:Destroy() end)
		end
	end)
end

-- Flamethrower: fast oriented bolt → orange burst + flat ring on hit
-- Part budget: 1 projectile + 2 impact parts = 3 max per shot
-- Flamethrower: instant beam + 4 fire blobs → burst + ring on hit
-- Part budget: 1 beam + 4 blobs + 2 impact = 7, all gone within 0.22s
function CombatFX.flamethrowerShot(fromPos: Vector3, toPos: Vector3)
	local dest = toPos + Vector3.new(0, 0.5, 0)
	local dir  = dest - fromPos
	local len  = dir.Magnitude
	if len < 0.5 then return end

	local FADE = 0.22

	-- Thin neon beam spanning full path
	local mid          = (fromPos + dest) * 0.5
	local beam         = Instance.new("Part")
	beam.Name          = "_FlameBeam"
	beam.Size          = Vector3.new(0.35, 0.35, len)
	beam.Color         = Color3.fromRGB(255, 160, 30)
	beam.Material      = Enum.Material.Neon
	beam.Anchored      = true
	beam.CanCollide    = false
	beam.CanQuery      = false
	beam.CanTouch      = false
	beam.CastShadow    = false
	beam.CFrame        = CFrame.new(mid, dest)
	beam.Parent        = workspace

	-- 4 fire blobs: small near barrel, large near target, yellow→deep orange
	local BLOB_DEFS = {
		{ t = 0.12, sz = 0.70, r = 255, g = 230, b = 40,  offY =  0.10 },
		{ t = 0.35, sz = 0.95, r = 255, g = 160, b = 20,  offY = -0.15 },
		{ t = 0.60, sz = 1.25, r = 255, g = 100, b = 10,  offY =  0.20 },
		{ t = 0.83, sz = 1.55, r = 230, g = 60,  b =  5,  offY = -0.10 },
	}
	local blobs: { Part } = {}
	local rng = Random.new()
	for _, def in BLOB_DEFS do
		local pos    = fromPos:Lerp(dest, def.t)
		local randOff = Vector3.new(
			(rng:NextNumber() - 0.5) * 0.8,
			def.offY,
			(rng:NextNumber() - 0.5) * 0.8
		)
		local b        = Instance.new("Part")
		b.Name         = "_FlameBlob"
		b.Shape        = Enum.PartType.Ball
		b.Size         = Vector3.new(def.sz, def.sz, def.sz)
		b.Color        = Color3.fromRGB(def.r, def.g, def.b)
		b.Material     = Enum.Material.Neon
		b.Anchored     = true
		b.CanCollide   = false
		b.CanQuery     = false
		b.CanTouch     = false
		b.CastShadow   = false
		b.Position     = pos + randOff
		b.Parent       = workspace
		table.insert(blobs, b)
	end

	-- Impact: burst sphere + flat ring
	local burst        = Instance.new("Part")
	burst.Name         = "_FlameBurst"
	burst.Shape        = Enum.PartType.Ball
	burst.Size         = Vector3.new(1.2, 1.2, 1.2)
	burst.Color        = Color3.fromRGB(255, 120, 15)
	burst.Material     = Enum.Material.Neon
	burst.Position     = dest
	burst.Anchored     = true
	burst.CanCollide   = false
	burst.CanQuery     = false
	burst.CanTouch     = false
	burst.CastShadow   = false
	burst.Parent       = workspace

	local ring         = Instance.new("Part")
	ring.Name          = "_FlameRing"
	ring.Shape         = Enum.PartType.Cylinder
	ring.Size          = Vector3.new(0.22, 0.8, 0.8)
	ring.Color         = Color3.fromRGB(200, 55, 5)
	ring.Material      = Enum.Material.Neon
	ring.Anchored      = true
	ring.CanCollide    = false
	ring.CanQuery      = false
	ring.CanTouch      = false
	ring.CastShadow    = false
	ring.CFrame        = CFrame.new(dest) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent        = workspace

	local RING_DUR = 0.19
	local elapsed  = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local ft = math.min(elapsed / FADE, 1)

		-- fade beam
		if beam.Parent then
			beam.Transparency = ft
			if ft >= 1 then beam:Destroy() end
		end
		-- fade blobs
		for _, b in blobs do
			if b.Parent then
				b.Transparency = ft
				if ft >= 1 then b:Destroy() end
			end
		end
		-- burst expands + fades
		if burst.Parent then
			local s = 1.2 + ft * 3.8
			burst.Size         = Vector3.new(s, s, s)
			burst.Transparency = ft * 0.9
			if ft >= 1 then burst:Destroy() end
		end
		-- ring expands + fades
		if ring.Parent then
			local rt = math.min(elapsed / RING_DUR, 1)
			local d  = 0.8 + rt * 5.0
			ring.Size         = Vector3.new(0.22, d, d)
			ring.Transparency = 0.1 + rt * 0.9
			if rt >= 1 then ring:Destroy() end
		end

		if elapsed >= FADE then conn:Disconnect() end
	end)
end

-- Rocket Launcher: oriented rocket body + exhaust glow → white core + expanding
-- ring + smoke cloud.
-- Part budget: 2 projectile + 3 impact = 5 max per shot (rockets fire rarely)
function CombatFX.rocketShot(fromPos: Vector3, toPos: Vector3)
	local TRAVEL = 0.32
	local ARC    = 1.2
	local origin = fromPos
	local dest   = toPos + Vector3.new(0, 0.8, 0)
	local dir    = dest - origin

	-- Rocket body: elongated dark part oriented toward target
	local body        = Instance.new("Part")
	body.Name         = "_RocketBody"
	body.Size         = Vector3.new(1.3, 1.3, 4.5)
	body.BrickColor   = BrickColor.new("Dark stone grey")
	body.Material     = Enum.Material.Metal
	body.Anchored     = true
	body.CanCollide   = false
	body.CanQuery     = false
	body.CanTouch     = false
	body.CastShadow   = false
	body.CFrame       = dir.Magnitude > 0.1
		and CFrame.new(origin, origin + dir.Unit)
		or  CFrame.new(origin)
	body.Parent       = workspace

	-- Exhaust glow: small neon orange orb at rear of body
	local exhaust        = Instance.new("Part")
	exhaust.Name         = "_RocketExhaust"
	exhaust.Shape        = Enum.PartType.Ball
	exhaust.Size         = Vector3.new(1.1, 1.1, 1.1)
	exhaust.BrickColor   = BrickColor.new("Bright orange")
	exhaust.Material     = Enum.Material.Neon
	exhaust.Anchored     = true
	exhaust.CanCollide   = false
	exhaust.CanQuery     = false
	exhaust.CanTouch     = false
	exhaust.CastShadow   = false
	exhaust.Position     = origin
	exhaust.Parent       = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t   = math.min(elapsed / TRAVEL, 1)
		local cur = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)
		local lookDir = dest - cur

		body.CFrame = lookDir.Magnitude > 0.1
			and CFrame.new(cur, dest)
			or  CFrame.new(cur)
		-- Keep exhaust at the back of the body (-Z tail)
		local back = lookDir.Magnitude > 0.1
			and (lookDir.Unit * -2.25)
			or  Vector3.new(0, 0, 2.25)
		exhaust.Position = cur + back

		if t >= 1 then
			conn:Disconnect()
			body:Destroy()
			exhaust:Destroy()

			-- White core flash: instant bright burst
			local core        = Instance.new("Part")
			core.Name         = "_RocketCore"
			core.Shape        = Enum.PartType.Ball
			core.Size         = Vector3.new(2.8, 2.8, 2.8)
			core.BrickColor   = BrickColor.new("White")
			core.Material     = Enum.Material.Neon
			core.Position     = dest
			core.Anchored     = true
			core.CanCollide   = false
			core.CanQuery     = false
			core.CanTouch     = false
			core.CastShadow   = false
			core.Parent       = workspace

			-- Expanding shockwave ring: yellow-orange
			local ring        = Instance.new("Part")
			ring.Name         = "_RocketRing"
			ring.Shape        = Enum.PartType.Cylinder
			ring.Size         = Vector3.new(0.35, 1, 1)
			ring.BrickColor   = BrickColor.new("Bright yellow")
			ring.Material     = Enum.Material.Neon
			ring.Anchored     = true
			ring.CanCollide   = false
			ring.CanQuery     = false
			ring.CanTouch     = false
			ring.CastShadow   = false
			ring.CFrame       = CFrame.new(dest + Vector3.new(0, 0.4, 0))
				* CFrame.Angles(0, 0, math.pi / 2)
			ring.Parent       = workspace

			-- Smoke/dust cloud: grey sphere that expands and fades slowly
			local smoke       = Instance.new("Part")
			smoke.Name        = "_RocketSmoke"
			smoke.Shape       = Enum.PartType.Ball
			smoke.Size        = Vector3.new(2, 2, 2)
			smoke.Color       = Color3.fromRGB(90, 80, 70)
			smoke.Material    = Enum.Material.SmoothPlastic
			smoke.Anchored    = true
			smoke.CanCollide  = false
			smoke.CanQuery    = false
			smoke.CanTouch    = false
			smoke.CastShadow  = false
			smoke.Position    = dest
			smoke.Parent      = workspace

			local CORE_DUR  = 0.09
			local RING_DUR  = 0.30
			local SMOKE_DUR = 0.42
			local e2        = 0
			local ic: RBXScriptConnection
			ic = PerfProbe.onRender("ClientFX", function(idt)
				e2 += idt
				if core.Parent then
					if e2 < CORE_DUR then
						core.Transparency = e2 / CORE_DUR
					else
						core:Destroy()
					end
				end
				if ring.Parent then
					if e2 < RING_DUR then
						local rt = e2 / RING_DUR
						local d  = 1 + rt * 13
						ring.Size         = Vector3.new(0.35, d, d)
						ring.Transparency = 0.1 + rt * 0.9
					else
						ring:Destroy()
					end
				end
				if smoke.Parent then
					if e2 < SMOKE_DUR then
						local st = e2 / SMOKE_DUR
						local s  = 2 + st * 7
						smoke.Size         = Vector3.new(s, s, s)
						smoke.Transparency = 0.15 + st * 0.80
					else
						smoke:Destroy()
					end
				end
				if e2 >= SMOKE_DUR then ic:Disconnect() end
			end)
		end
	end)
end

-- Artillery: a 3-shell volley lobbed on a high arc with a heavy ground explosion.
function CombatFX.artilleryImpact(dest: Vector3)
	-- White core flash
	local core        = Instance.new("Part")
	core.Name         = "_ArtCore"
	core.Shape        = Enum.PartType.Ball
	core.Size         = Vector3.new(4.5, 4.5, 4.5)
	core.BrickColor   = BrickColor.new("White")
	core.Material     = Enum.Material.Neon
	core.Anchored     = true; core.CanCollide = false; core.CanQuery = false; core.CastShadow = false
	core.Position     = dest
	core.Parent       = workspace

	-- Expanding shockwave ring
	local ring        = Instance.new("Part")
	ring.Name         = "_ArtRing"
	ring.Shape        = Enum.PartType.Cylinder
	ring.Size         = Vector3.new(0.4, 1, 1)
	ring.BrickColor   = BrickColor.new("Bright orange")
	ring.Material     = Enum.Material.Neon
	ring.Anchored     = true; ring.CanCollide = false; ring.CanQuery = false; ring.CastShadow = false
	ring.CFrame       = CFrame.new(dest + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent       = workspace

	-- Smoke cloud
	local smoke       = Instance.new("Part")
	smoke.Name        = "_ArtSmoke"
	smoke.Shape       = Enum.PartType.Ball
	smoke.Size        = Vector3.new(3, 3, 3)
	smoke.Color       = Color3.fromRGB(80, 72, 64)
	smoke.Material    = Enum.Material.SmoothPlastic
	smoke.Anchored    = true; smoke.CanCollide = false; smoke.CanQuery = false; smoke.CastShadow = false
	smoke.Position    = dest
	smoke.Parent      = workspace

	-- Debris chunks flung outward on ballistic arcs
	type Chunk = { part: Part, vx: number, vy: number, vz: number }
	local chunks: { Chunk } = {}
	for i = 1, 8 do
		local a   = (i / 8) * math.pi * 2 + (math.random() - 0.5) * 0.5
		local spd = 11 + math.random() * 14
		local sz  = 0.6 + math.random() * 1.3
		local d   = Instance.new("Part")
		d.Name        = "_ArtDebris"
		d.Size        = Vector3.new(sz, sz, sz)
		d.Color       = Color3.fromRGB(70, 56, 40)
		d.Material    = Enum.Material.SmoothPlastic
		d.Anchored    = true; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
		d.Position    = dest + Vector3.new(0, 0.5, 0)
		d.Parent      = workspace
		chunks[i] = { part = d, vx = math.cos(a) * spd, vy = 16 + math.random() * 18, vz = math.sin(a) * spd }
	end

	local CORE_DUR, RING_DUR, SMOKE_DUR, DEBRIS_DUR = 0.11, 0.38, 0.55, 0.85
	local GRAV = 34
	local e = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		e += dt
		if core.Parent then
			if e < CORE_DUR then
				local p = e / CORE_DUR
				local s = 4.5 + p * 6
				core.Size = Vector3.new(s, s, s); core.Transparency = p
			else core:Destroy() end
		end
		if ring.Parent then
			if e < RING_DUR then
				local p = e / RING_DUR
				local dd = 1 + p * 22
				ring.Size = Vector3.new(0.4, dd, dd); ring.Transparency = 0.1 + p * 0.9
			else ring:Destroy() end
		end
		if smoke.Parent then
			if e < SMOKE_DUR then
				local p = e / SMOKE_DUR
				local s = 3 + p * 9
				smoke.Size = Vector3.new(s, s, s); smoke.Transparency = 0.1 + p * 0.85
			else smoke:Destroy() end
		end
		for _, c in chunks do
			if c.part.Parent then
				if e < DEBRIS_DUR then
					c.vy -= GRAV * dt
					c.part.Position += Vector3.new(c.vx * dt, c.vy * dt, c.vz * dt)
					c.part.Transparency = e / DEBRIS_DUR
				else c.part:Destroy() end
			end
		end
		if e >= DEBRIS_DUR then conn:Disconnect() end
	end)
end

function CombatFX.artilleryShell(fromPos: Vector3, toPos: Vector3, bigImpact: boolean)
	local TRAVEL = 0.55
	local ARC    = 11
	local origin = fromPos
	local dest   = toPos + Vector3.new(0, 0.8, 0)
	local dir    = dest - origin

	local body        = Instance.new("Part")
	body.Name         = "_ArtShell"
	body.Size         = Vector3.new(1.6, 1.6, 5.5)
	body.BrickColor   = BrickColor.new("Really black")
	body.Material     = Enum.Material.Metal
	body.Anchored     = true; body.CanCollide = false; body.CanQuery = false; body.CastShadow = false
	body.CFrame       = dir.Magnitude > 0.1 and CFrame.new(origin, origin + dir.Unit) or CFrame.new(origin)
	body.Parent       = workspace

	local tail        = Instance.new("Part")
	tail.Name         = "_ArtTail"
	tail.Shape        = Enum.PartType.Ball
	tail.Size         = Vector3.new(1.6, 1.6, 1.6)
	tail.BrickColor   = BrickColor.new("Bright orange")
	tail.Material     = Enum.Material.Neon
	tail.Anchored     = true; tail.CanCollide = false; tail.CanQuery = false; tail.CastShadow = false
	tail.Position     = origin
	tail.Parent       = workspace

	-- Muzzle flash at the nozzle
	local flash       = Instance.new("Part")
	flash.Name        = "_ArtMuzzle"
	flash.Shape       = Enum.PartType.Ball
	flash.Size        = Vector3.new(3, 3, 3)
	flash.BrickColor  = BrickColor.new("Bright yellow")
	flash.Material    = Enum.Material.Neon
	flash.Anchored    = true; flash.CanCollide = false; flash.CanQuery = false; flash.CastShadow = false
	flash.Position    = origin
	flash.Parent      = workspace
	task.delay(0.07, function() if flash.Parent then flash:Destroy() end end)

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t   = math.min(elapsed / TRAVEL, 1)
		local cur = origin:Lerp(dest, t) + Vector3.new(0, math.sin(t * math.pi) * ARC, 0)
		local lookDir = dest - cur
		body.CFrame = lookDir.Magnitude > 0.1 and CFrame.new(cur, dest) or CFrame.new(cur)
		local back = lookDir.Magnitude > 0.1 and (lookDir.Unit * -2.8) or Vector3.new(0, 0, 2.8)
		tail.Position = cur + back
		if t >= 1 then
			conn:Disconnect()
			body:Destroy(); tail:Destroy()
			if bigImpact then CombatFX.artilleryImpact(dest) end
		end
	end)
end

function CombatFX.artilleryShot(fromPos: Vector3, toPos: Vector3)
	-- Spread the three shells laterally so they read as a 3-nozzle volley.
	local flat = (toPos - fromPos) * Vector3.new(1, 0, 1)
	local right = flat.Magnitude > 0.1 and flat.Unit:Cross(Vector3.new(0, 1, 0)) or Vector3.new(1, 0, 0)
	local offs = { -2.1, 0, 2.1 }
	for i, off in offs do
		local from = fromPos + right * off
		-- only the centre shell triggers the heavy impact (single damage event)
		task.delay((i - 1) * 0.06, function()
			CombatFX.artilleryShell(from, toPos, off == 0)
		end)
	end
end

return CombatFX
