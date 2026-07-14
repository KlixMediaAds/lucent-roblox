-- WatcherBody.luau
-- Client-only procedural body for the Watcher — a slow, drifting cluster of eyes
-- evolved from a Leech. The whole creature is a lumpy fleshy knot studded with
-- eyeballs that stare outward in every direction, blinking and darting independently.
-- The eyes take their look from the Hagfish: narrow, angular, amber, faintly glowing
-- (same C_EYE palette as HagfishBody / RollerBody). It has no legs — it hovers a little
-- off the ground and bobs as it creeps along.
--
-- Architecture mirrors LeechBody / RollerBody: one shared RenderStepped loop, a distance
-- cull, a speed-proportional animation clock, and every part tagged with a "UnitId"
-- attribute so FogManager can hide the bodies of enemy Watchers sitting in the fog.
--
-- The server spawns the Watcher as an invisible, ground-snapped pivot block (size
-- 6×6×6). Everything you see is drawn here. Its attack is a ranged "gaze": when the
-- server fires a Watcher hit, triggerGazeNear locks the nearest Watcher's eyes onto the
-- target and fires a brief converging glare beam.
--!strict

local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")

local WatcherBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
-- The cluster is an UPRIGHT PILL (capsule): a straight cylindrical mid-section capped
-- by a hemisphere at top and bottom. The eyes are studded evenly over that surface.
local N_EYES    = 16          -- eyeballs studded over the pill
local PILL_R    = 1.8         -- horizontal radius of the pill (cylinder + cap radius)
local PILL_H    = 1.7         -- half-height of the pill's straight (cylindrical) mid-section
local N_LOBES   = 3           -- extra offset flesh lobes → an irregular, lumpy body
local HOVER     = 1.0         -- studs the cluster floats above the pivot's resting centre

-- The pivot centre sits size.Y/2 = 3 above the ground. The Watcher doesn't grow, so
-- scale ≈ 1, but we keep the same derivation as the other body animators.
local BASE_HEIGHT = 6.0       -- = Config.UNIT_TYPES.Watcher.size.Y

-- ── Motion ────────────────────────────────────────────────────────────────────
local FULL_SPEED  = 7.0       -- matches Config.UNIT_MOVE_SPEED.Watcher (slow)
local SPIN_RATE   = 0.35      -- rad/sec the whole cluster idly turns
local BOB_FREQ    = 0.7       -- vertical bob cycles/sec
local BOB_AMP     = 0.45      -- bob height (studs), grows a touch with movement
local BREATHE_FREQ = 0.9      -- core pulsate cycles/sec
local BREATHE_AMP  = 0.08     -- fraction the core swells/shrinks as it "breathes"

-- ── Eyes ──────────────────────────────────────────────────────────────────────
local EYE_SCLERA_D = 1.05     -- sclera ball diameter
local EYE_PUPIL_D  = 0.44     -- pupil ball diameter
local PUPIL_ORBIT  = 0.32     -- how far the pupil rides off the sclera centre (as a fraction of radius the eye is offset)
local LOOK_MIN     = 1.1      -- min seconds before an idle eye picks a new look direction
local LOOK_MAX     = 3.4      -- max seconds before an idle eye picks a new look direction
local LOOK_EASE    = 3.2      -- how fast a pupil slews toward its look direction (unhurried)
-- Blinks are slow and frog-like: a lazy lid sweep that eases shut and eases back open,
-- fired rarely and staggered per eye so the cluster never blinks in unison.
local BLINK_MIN    = 4.5      -- min seconds between an eye's blinks
local BLINK_MAX    = 12.0     -- max seconds between an eye's blinks
local BLINK_DUR    = 0.9      -- seconds one slow blink takes (ease shut → ease open)

-- ── Gaze attack ───────────────────────────────────────────────────────────────
local GAZE_TIME    = 0.5      -- seconds the eyes lock on + the iris flares after a hit
local GAZE_RANGE   = 60       -- max studs from a hit origin to claim the nearest Watcher
local GAZE_SND_ID  = "rbxassetid://9125703168"

local CULL_SQ = 300 * 300

-- ── Colours (Hagfish-eye palette) ──────────────────────────────────────────────
local C_FLESH  = Color3.fromRGB(52, 32, 40)    -- dark blood-maroon knot
local C_LOBE   = Color3.fromRGB(44, 27, 34)    -- slightly darker lumps
local C_SOCKET = Color3.fromRGB(24, 14, 18)    -- dark recessed socket behind each eye
local C_SCLERA = Color3.fromRGB(235, 150, 78)  -- amber, faintly glowing (hagfish eye)
local C_PUPIL  = Color3.fromRGB(18, 9, 12)      -- near-black pupil

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- Even points on a unit sphere (Fibonacci lattice) — the eye normals.
local function fibSphere(n: number): { Vector3 }
	local pts: { Vector3 } = {}
	local ga = math.pi * (3 - math.sqrt(5))   -- golden angle
	for i = 0, n - 1 do
		local y = 1 - (i / (n - 1)) * 2         -- 1 → -1
		local r = math.sqrt(math.max(0, 1 - y * y))
		local a = ga * i
		pts[i + 1] = Vector3.new(math.cos(a) * r, y, math.sin(a) * r)
	end
	return pts
end

-- Orient a part so its front (-Z / LookVector) points along `normal`.
local function faceOut(part: BasePart, pos: Vector3, normal: Vector3, size: Vector3)
	part.CFrame = CFrame.lookAt(pos, pos + normal)
	part.Size   = size
end

-- Evenly-spaced points + outward normals over an UPRIGHT capsule (pill) surface:
-- a cylinder of half-height `h` and radius `r` capped by a hemisphere at each end.
-- Points march along the vertical profile at even arc-length with a golden-angle
-- azimuth spin (the capsule analogue of a Fibonacci sphere), so coverage stays even
-- from the bottom pole, up the straight wall, to the top pole.
type SurfPt = { pos: Vector3, normal: Vector3 }
local function capsulePoints(n: number, r: number, h: number): { SurfPt }
	local pts: { SurfPt } = {}
	local ga     = math.pi * (3 - math.sqrt(5))   -- golden angle
	local capLen = (math.pi / 2) * r              -- arc length of one cap (pole → seam)
	local cylLen = 2 * h
	local total  = 2 * capLen + cylLen
	for i = 0, n - 1 do
		local s      = ((i + 0.5) / n) * total     -- arc distance from the bottom pole
		local phi    = ga * i
		local hx, hz = math.cos(phi), math.sin(phi)
		local rho, y, nUp
		if s < capLen then
			-- bottom hemisphere (centred at 0,-h,0); a = polar angle from the down pole
			local a = s / r
			rho, y, nUp = r * math.sin(a), -h - r * math.cos(a), -math.cos(a)
		elseif s < capLen + cylLen then
			-- straight cylinder wall (horizontal normal)
			rho, y, nUp = r, -h + (s - capLen), 0
		else
			-- top hemisphere (centred at 0,+h,0)
			local a = (s - capLen - cylLen) / r
			rho, y, nUp = r * math.cos(a), h + r * math.sin(a), math.sin(a)
		end
		local nRho = math.sqrt(math.max(0, 1 - nUp * nUp))
		pts[i + 1] = {
			pos    = Vector3.new(hx * rho, y, hz * rho),
			normal = Vector3.new(hx * nRho, nUp, hz * nRho),
		}
	end
	return pts
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Eye = {
	socket:     BasePart,
	sclera:     BasePart,
	pupil:      BasePart,
	basePos:    Vector3,    -- surface position on the pill (cluster-local, unscaled)
	normal:     Vector3,    -- outward unit normal at that point (cluster-local)
	tanA:       Vector3,    -- two tangents spanning this eye's look plane
	tanB:       Vector3,
	look:       Vector2,    -- current pupil offset in the (tanA, tanB) plane, each −1..1
	lookGoal:   Vector2,    -- where the pupil is slewing toward
	lookTimer:  number,     -- countdown to the next idle look target
	blinkTimer: number,     -- countdown to the next blink
	blinkT:     number,     -- 0 = open; >0 = mid-blink (lid sweeping)
}
type Lobe = { part: BasePart, off: Vector3, d: number }
type Entry = {
	body:        BasePart,
	coreCyl:     BasePart,   -- pill mid-section (upright cylinder)
	coreTop:     BasePart,   -- top hemispherical cap (ball)
	coreBot:     BasePart,   -- bottom hemispherical cap (ball)
	lobes:       { Lobe },
	eyes:        { Eye },
	prevPos:     Vector3?,
	smoothSpeed: number,
	spin:        number,
	bobClock:    number,
	breatheClock: number,
	gazeT:       number,
	gazeTarget:  Vector3?,
	conn:        RBXScriptConnection,
}

local active: { [string]: Entry } = {}
local folder: Folder
local camera: Camera

-- ── Part factory ────────────────────────────────────────────────────────────--
local function makePart(unitId: string, col: Color3, mat: Enum.Material, shape: Enum.PartType?): BasePart
	local p          = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Color          = col
	p.Material       = mat
	p.Anchored       = true
	p.CanCollide     = false
	p.CanQuery       = false
	p.CastShadow     = false
	p.Size           = Vector3.new(0.2, 0.2, 0.2)
	p:SetAttribute("UnitId", unitId)
	p.Parent         = folder
	return p
end

-- A brief amber glare beam from the cluster to the gaze target, fading as it fires.
local function drawGaze(unitId: string, fromPos: Vector3, toPos: Vector3)
	local delta = toPos - fromPos
	local len   = delta.Magnitude
	if len < 0.1 then return end
	local beam         = Instance.new("Part")
	beam.Anchored      = true
	beam.CanCollide    = false
	beam.CanQuery      = false
	beam.CastShadow    = false
	beam.Material      = Enum.Material.Neon
	beam.Color         = C_SCLERA
	beam.Size          = Vector3.new(0.34, 0.34, len)
	beam.CFrame        = CFrame.lookAt(fromPos + delta * 0.5, toPos)
	beam.Transparency  = 0.25
	beam:SetAttribute("UnitId", unitId)   -- so FogManager can hide enemy gazes in fog
	beam.Parent        = folder
	TweenService:Create(beam, TweenInfo.new(GAZE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1, Size = Vector3.new(0.05, 0.05, len) }):Play()
	Debris:AddItem(beam, GAZE_TIME + 0.05)
end

-- Fire a one-shot spatial sound at a world position (self-cleaning).
local function playSoundAt(pos: Vector3, id: string, volume: number)
	local p       = Instance.new("Part")
	p.Anchored    = true
	p.CanCollide  = false
	p.CanQuery    = false
	p.Transparency = 1
	p.Size        = Vector3.new(1, 1, 1)
	p.Position    = pos
	p.Parent      = workspace
	local s              = Instance.new("Sound")
	s.SoundId           = id
	s.Volume            = volume
	s.RollOffMaxDistance = 90
	s.RollOffMinDistance = 8
	s.RollOffMode       = Enum.RollOffMode.Linear
	s.Parent            = p
	s:Play()
	s.Ended:Once(function() p:Destroy() end)
	Debris:AddItem(p, 5)
end

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function WatcherBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	-- Core = an upright pill: a cylinder mid-section with a ball cap at each end.
	local coreCyl = makePart(unitId, C_FLESH, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	local coreTop = makePart(unitId, C_FLESH, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local coreBot = makePart(unitId, C_FLESH, Enum.Material.SmoothPlastic, Enum.PartType.Ball)

	-- A few offset lobes make the flesh body lumpy rather than a clean pill.
	local lobes: { Lobe } = {}
	local lobeDirs = fibSphere(N_LOBES)
	for i = 1, N_LOBES do
		local ld = lobeDirs[i]
		table.insert(lobes, {
			part = makePart(unitId, C_LOBE, Enum.Material.SmoothPlastic, Enum.PartType.Ball),
			-- Squeezed in horizontally, spread out vertically → lumps riding the pill's length.
			off  = Vector3.new(ld.X * PILL_R * 0.45, ld.Y * (PILL_H + PILL_R * 0.4), ld.Z * PILL_R * 0.45),
			d    = PILL_R * (1.0 + 0.3 * ((i * 0.37) % 1)),
		})
	end

	-- Eyes studded evenly over the pill surface.
	local eyes: { Eye } = {}
	local surf = capsulePoints(N_EYES, PILL_R, PILL_H)
	for i = 1, N_EYES do
		local sp     = surf[i]
		local normal = sp.normal
		-- Two tangents spanning the plane the pupil darts within.
		local tanA = normal:Cross(Vector3.yAxis)
		if tanA.Magnitude < 0.05 then tanA = normal:Cross(Vector3.xAxis) end
		tanA = tanA.Unit
		local tanB = normal:Cross(tanA).Unit
		table.insert(eyes, {
			socket     = makePart(unitId, C_SOCKET, Enum.Material.SmoothPlastic),
			sclera     = makePart(unitId, C_SCLERA, Enum.Material.Neon, Enum.PartType.Ball),
			pupil      = makePart(unitId, C_PUPIL,  Enum.Material.SmoothPlastic, Enum.PartType.Ball),
			basePos    = sp.pos,
			normal     = normal,
			tanA       = tanA,
			tanB       = tanB,
			look       = Vector2.new((math.random() - 0.5) * 1.4, (math.random() - 0.5) * 1.4),
			lookGoal   = Vector2.new((math.random() - 0.5) * 1.4, (math.random() - 0.5) * 1.4),
			lookTimer  = LOOK_MIN + math.random() * (LOOK_MAX - LOOK_MIN),
			blinkTimer = BLINK_MIN + math.random() * (BLINK_MAX - BLINK_MIN),
			blinkT     = 0,
		})
	end

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		WatcherBody.detach(unitId)
	end)

	active[unitId] = {
		body         = body,
		coreCyl      = coreCyl,
		coreTop      = coreTop,
		coreBot      = coreBot,
		lobes        = lobes,
		eyes         = eyes,
		prevPos      = nil,
		smoothSpeed  = 0,
		spin         = phase * 6.28,
		bobClock     = phase * 4.0,
		breatheClock = phase * 3.0,
		gazeT        = 0,
		gazeTarget   = nil,
		conn         = conn,
	}
end

function WatcherBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, p in { e.coreCyl, e.coreTop, e.coreBot } do
		if p.Parent then p:Destroy() end
	end
	for _, l in e.lobes do if l.part.Parent then l.part:Destroy() end end
	for _, eye in e.eyes do
		if eye.socket.Parent then eye.socket:Destroy() end
		if eye.sclera.Parent then eye.sclera:Destroy() end
		if eye.pupil.Parent  then eye.pupil:Destroy()  end
	end
end

-- Lock the nearest Watcher's gaze onto a target and fire its glare beam.
function WatcherBody.triggerGazeNear(fromPos: Vector3, toPos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		local d = (e.body.Position - fromPos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < GAZE_RANGE then
		local e = active[bestId]
		e.gazeT      = GAZE_TIME
		e.gazeTarget = toPos
		-- Only draw/sound the glare when the body is visible (not hidden behind fog).
		if e.coreCyl.LocalTransparencyModifier < 0.5 then
			drawGaze(bestId, e.body.Position + Vector3.new(0, HOVER, 0), toPos)
			playSoundAt(e.body.Position, GAZE_SND_ID, 0.6)
		end
	end
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
local function layout(e: Entry, sc: number, speedF: number, dt: number)
	local body    = e.body
	local bpos    = body.Position
	-- Cluster centre: pivot centre, lifted a little as it hovers + bobs.
	local bob     = math.sin(e.bobClock) * BOB_AMP * (0.6 + 0.6 * speedF)
	local centre  = bpos + Vector3.new(0, (HOVER + bob) * sc, 0)

	-- Slowly turning cluster basis (idle spin about Y).
	local cs, sn  = math.cos(e.spin), math.sin(e.spin)
	local function turn(v: Vector3): Vector3
		return Vector3.new(v.X * cs + v.Z * sn, v.Y, -v.X * sn + v.Z * cs)
	end

	-- Core pill (upright capsule), gently breathing. A Cylinder part's length runs along
	-- its local X, so we tip it up 90° about Z to stand it vertically; the two ball caps
	-- sit at ±half-height. The core rides just inside the eye shell so gaps don't gape.
	local breathe = 1 + math.sin(e.breatheClock) * BREATHE_AMP
	local rr      = PILL_R * 0.94 * sc * breathe
	local hh      = PILL_H * sc
	e.coreCyl.Size   = Vector3.new(2 * hh, 2 * rr, 2 * rr)
	e.coreCyl.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.pi / 2)
	local capD = 2 * rr
	e.coreTop.Size   = Vector3.new(capD, capD, capD)
	e.coreTop.CFrame = CFrame.new(centre + Vector3.new(0, hh, 0))
	e.coreBot.Size   = Vector3.new(capD, capD, capD)
	e.coreBot.CFrame = CFrame.new(centre + Vector3.new(0, -hh, 0))

	for _, l in e.lobes do
		l.part.Size   = Vector3.new(l.d * sc * breathe, l.d * sc * breathe, l.d * sc * breathe)
		l.part.CFrame = CFrame.new(centre + turn(l.off) * sc)
	end

	-- Gaze aim: while attacking, eyes turn toward the target; the iris flares.
	local gazeF = if e.gazeT > 0 then math.clamp(e.gazeT / GAZE_TIME, 0, 1) else 0
	local aimDir: Vector3? = nil
	if gazeF > 0 and e.gazeTarget then
		aimDir = ((e.gazeTarget :: Vector3) - centre)
		if aimDir.Magnitude > 0.05 then aimDir = aimDir.Unit else aimDir = nil end
	end

	for _, eye in e.eyes do
		local normal = turn(eye.normal)
		local tanA   = turn(eye.tanA)
		local tanB   = turn(eye.tanB)

		-- ── Look direction ──────────────────────────────────────────────────
		if aimDir then
			-- Only the eyes facing the target can lock on (dot > 0); the rest keep idling.
			local dp = aimDir:Dot(normal)
			if dp > 0.15 then
				-- Project the aim onto this eye's tangent plane → a pupil offset.
				local pa = aimDir:Dot(tanA)
				local pb = aimDir:Dot(tanB)
				local m  = math.sqrt(pa * pa + pb * pb)
				if m > 1e-3 then
					eye.lookGoal = Vector2.new(pa / m, pb / m)   -- fully deflected toward the target
				end
			end
		else
			-- Idle wander: pick a fresh look target now and then.
			eye.lookTimer -= dt
			if eye.lookTimer <= 0 then
				eye.lookTimer = LOOK_MIN + math.random() * (LOOK_MAX - LOOK_MIN)
				eye.lookGoal  = Vector2.new((math.random() - 0.5) * 1.5, (math.random() - 0.5) * 1.5)
			end
		end
		eye.look = eye.look + (eye.lookGoal - eye.look) * math.min(1, dt * LOOK_EASE)

		-- ── Blink: a slow, frog-like lid sweep that eases shut and eases open ─
		eye.blinkTimer -= dt
		if eye.blinkTimer <= 0 and eye.blinkT <= 0 then
			eye.blinkT    = BLINK_DUR
			eye.blinkTimer = BLINK_MIN + math.random() * (BLINK_MAX - BLINK_MIN)
		end
		local open = 1.0
		if eye.blinkT > 0 then
			eye.blinkT = math.max(0, eye.blinkT - dt)
			-- Raised-cosine over the blink: eases from open → nearly shut → open with no
			-- snap, so it reads as an unhurried, deliberate frog blink.
			local p      = 1 - eye.blinkT / BLINK_DUR       -- 0 → 1 across the blink
			local closed = 0.5 - 0.5 * math.cos(p * math.pi * 2)   -- 0 → 1 → 0 (shut at the midpoint)
			open = 1 - 0.9 * closed
		end

		-- ── Place socket, sclera, pupil ─────────────────────────────────────
		local surf   = centre + turn(eye.basePos) * sc
		faceOut(eye.socket, surf, normal, Vector3.new(1.5 * sc * open, 1.5 * sc * open, 0.3 * sc))

		local proud  = 0.35 * sc * open      -- how far the eyeball stands off the surface (retracts on a wink)
		local scPos  = surf + normal * proud
		local scD    = EYE_SCLERA_D * sc * open
		-- Iris flare on a gaze: the amber eye swells + brightens briefly.
		if gazeF > 0 then scD *= (1 + 0.25 * gazeF) end
		eye.sclera.Size   = Vector3.new(scD, scD, scD)
		eye.sclera.CFrame = CFrame.new(scPos)

		-- Pupil rides on the sclera's front, offset toward the look direction.
		local off    = (tanA * eye.look.X + tanB * eye.look.Y)
		local pupilN = (normal + off * PUPIL_ORBIT)
		pupilN = if pupilN.Magnitude > 1e-3 then pupilN.Unit else normal
		local pupD   = EYE_PUPIL_D * sc * open
		eye.pupil.Size   = Vector3.new(pupD, pupD, pupD)
		eye.pupil.CFrame = CFrame.new(scPos + pupilN * (scD * 0.42))
	end
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function WatcherBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_WatcherBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				WatcherBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx * dx + dy * dy + dz * dz > CULL_SQ then continue end

			-- Speed estimate from frame-to-frame movement (parts are anchored).
			local last      = e.prevPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.prevPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			-- Riding a Roller: the body is dragged along, but it holds its idle drift
			-- (facing still follows the server-set CFrame = Roller's front).
			if body:GetAttribute("Carried") then spd = 0 end
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.1
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Advance clocks.
			e.spin         += dt * SPIN_RATE
			e.bobClock     += dt * BOB_FREQ * math.pi * 2
			e.breatheClock += dt * BREATHE_FREQ * math.pi * 2
			if e.gazeT > 0 then e.gazeT = math.max(0, e.gazeT - dt) end

			local sc = body.Size.Y / BASE_HEIGHT
			layout(e, sc, speedF, dt)
		end
	end)
end

return WatcherBody
