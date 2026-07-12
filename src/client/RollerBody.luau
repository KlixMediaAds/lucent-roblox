-- RollerBody.luau
-- Client-only procedural body + roll/grind animation for the Roller unit — a
-- Hollowed creature evolved from an Embryo, shaped like a living armored ball
-- (inspired by Whirlipede). Architecture mirrors HagfishBody / LampreyBody: one
-- shared RenderStepped loop, a distance cull, a speed-proportional animation clock,
-- and every part tagged with a "UnitId" attribute so FogManager can hide the bodies
-- of enemy units sitting in the fog.
--
-- The server spawns the Roller as an invisible, ground-snapped pivot block
-- (size 6×10×10). Everything you see is drawn here: a fat spherical armored shell
-- whose axle runs LEFT-TO-RIGHT (perpendicular to travel), so it rolls forward in the
-- direction it moves like a real wheel. Interlocking armor-plate segments and short
-- blunt spikes are wrapped over the whole sphere in latitude bands (not a flat tyre
-- tread) and whirl around the axle in proportion to how far the Roller has travelled.
-- One narrow, stoic eye sits fixed on EACH side pole (they never spin), with a minimal
-- mouth on the leading front; a few small legs are tucked under the shell.
--
-- Attack: the Roller has no projectile. It rolls up to a unit/structure and keeps
-- grinding — constant low DPS. When the server fires a Roller "hit", the client
-- calls triggerAttackNear on the nearest Roller, which revs the shell faster and
-- throws a burst of sparks from its leading edge for the grind window.
--!strict

local RunService = game:GetService("RunService")

local RollerBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
local R          = 5.0        -- overall radius (studs) → ~10-stud ball, slightly larger than a Tank
local RS         = R * 0.92   -- armored sphere radius (spikes/plates ride just outside)
local N_LEGS     = 4          -- small legs tucked under the shell

-- Armor plates + spikes wrapped over the sphere in latitude bands (phi = 0 is the
-- equator; ± tilts toward the two side poles where the eyes sit). Counts shrink
-- toward the poles as the circumference does. These give a round, all-over armored
-- shell rather than a flat wheel tread.
local PLATE_LATS = { { phi = 0.0, n = 11 }, { phi = math.rad(34), n = 9 }, { phi = -math.rad(34), n = 9 } }
local SPIKE_LATS = { { phi = 0.0, n = 10 }, { phi = math.rad(30), n = 6 }, { phi = -math.rad(30), n = 6 } }

-- A single flowing tentacle sprouts beside each eye. As the Roller moves it streams
-- BACKWARD (opposite to travel), a traveling sine rippling out to its glowing tip for
-- a mesmerizing flow. Two total (one per side pole).
local N_TENT_SEG = 6          -- segments per tentacle
local TENT_LEN   = 6.5        -- studs, base → tip
local TENT_AMP   = 1.7        -- wave amplitude (grows toward the tip)
local TENT_FREQ  = 3.0        -- base flow speed (rad/s; scales up with movement)
local TENT_K     = 3.2        -- wave count along the length (traveling ripple)

-- The pivot centre sits size.Y/2 = R above the ground (the shell rests on the terrain).
local BASE_HEIGHT = 10.0      -- = Config.UNIT_TYPES.Roller.size.Y (Roller doesn't grow → sc ≈ 1)

-- ── Roll / grind ────────────────────────────────────────────────────────────--
local FULL_SPEED = 20.0       -- matches Config.UNIT_MOVE_SPEED.Roller
local ROLL_GAIN  = 1.1        -- slight over-roll beyond the physical rate (sells the "living wheel")
local GRIND_TIME = 0.55       -- seconds the shell revs + sparks after a grind hit
local GRIND_SPIN = 24.0       -- radians/sec the shell whirls while grinding a target

-- Rolling sound: a 1-s clip looped while moving, its volume + pitch tracking speed
-- with a randomised pitch wobble so it never sounds mechanically constant. The clip
-- is quiet, so it's boosted well above the default volume.
local ROLL_SOUND_ID  = "rbxassetid://17812230504"
local ROLL_VOL_MAX   = 3.0    -- peak volume at full speed (clip is quiet → boosted ~3×)
local ROLL_PITCH_MIN = 0.82   -- randomised pitch-wobble range …
local ROLL_PITCH_MAX = 1.28   -- … multiplied on top of the speed-based pitch

local CULL_SQ    = 300 * 300

-- ── Colours (closest to the Hagfish palette) ──────────────────────────────────
local C_BODY  = Color3.fromRGB(48, 40, 56)   -- dark purplish slate (hagfish body)
local C_PLATE = Color3.fromRGB(66, 57, 78)   -- lighter armour plate
local C_PLATE2= Color3.fromRGB(40, 34, 48)   -- darker plate (sockets)
local C_SPIKE = Color3.fromRGB(96, 32, 66)   -- dark reddish-purple (hagfish teeth) — spikes
local C_EYE   = Color3.fromRGB(255, 120, 60) -- narrow angular eyes (hagfish eyes)
local C_LEG   = Color3.fromRGB(70, 50, 78)   -- stubby legs

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- Orient a box: vX / vY are orthonormal part axes (local X / Y); local Z is derived.
local function orient(part: BasePart, pos: Vector3, vX: Vector3, vY: Vector3, size: Vector3)
	part.CFrame = CFrame.fromMatrix(pos, vX, vY)
	part.Size   = size
end

-- Stretch a box between two points (local Y = the length axis), for tentacle segments.
local function connect(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.02 then
		part.Size = Vector3.new(thick, thick, thick); part.CFrame = CFrame.new(a); return
	end
	local dir  = delta / len
	local perp = dir:Cross(Vector3.yAxis)
	if perp.Magnitude < 0.02 then perp = dir:Cross(Vector3.xAxis) end
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, perp.Unit, dir)
	part.Size   = Vector3.new(thick, len, thick)
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Segment = { part: BasePart, phi: number, theta0: number, n: number }
type Tentacle = { segs: { BasePart }, tip: BasePart, sgn: number }
type Entry = {
	body:        BasePart,
	core:        BasePart,
	plates:      { Segment },
	spikes:      { Segment },
	legs:        { BasePart },
	eyes:        { BasePart },   -- 2: one on each side pole
	sockets:     { BasePart },   -- 2: dark recess behind each eye
	brows:       { BasePart },   -- 2: angular ridge over each eye
	tentacles:   { Tentacle },   -- 2: one flowing beside each eye
	mouth:       BasePart,
	sparkHost:   BasePart,
	sparks:      ParticleEmitter,
	rollSound:   Sound,
	sndVol:      number,
	pitchCur:    number,
	pitchTarget: number,
	pitchTimer:  number,
	prevPos:     Vector3?,
	roll:        number,
	smoothSpeed: number,
	tentClock:   number,
	grindT:      number,
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

local function makeSparks(host: BasePart): ParticleEmitter
	local pe          = Instance.new("ParticleEmitter")
	pe.Texture        = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color          = ColorSequence.new(Color3.fromRGB(255, 150, 70), Color3.fromRGB(120, 40, 60))
	pe.LightEmission  = 0.6
	pe.LightInfluence = 0
	pe.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.5),
		NumberSequenceKeypoint.new(0.5, 0.9),
		NumberSequenceKeypoint.new(1,   0.1),
	})
	pe.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	pe.Lifetime       = NumberRange.new(0.18, 0.4)
	pe.Speed          = NumberRange.new(10, 22)
	pe.SpreadAngle    = Vector2.new(35, 35)
	pe.Acceleration   = Vector3.new(0, -40, 0)
	pe.Rotation       = NumberRange.new(0, 360)
	pe.RotSpeed       = NumberRange.new(-200, 200)
	pe.Rate           = 0
	pe.EmissionDirection = Enum.NormalId.Front
	pe.Parent         = host
	return pe
end

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function RollerBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	-- Core: a full round ball (the armored plates + spikes ride on its surface).
	local core = makePart(unitId, C_BODY, Enum.Material.Metal, Enum.PartType.Ball)

	local plates: { Segment } = {}
	local spikes: { Segment } = {}
	for _, band in PLATE_LATS do
		for i = 1, band.n do
			table.insert(plates, {
				part = makePart(unitId, C_PLATE, Enum.Material.Metal),
				phi = band.phi, theta0 = (i - 1) / band.n * math.pi * 2, n = band.n,
			})
		end
	end
	for _, band in SPIKE_LATS do
		for i = 1, band.n do
			table.insert(spikes, {
				part = makePart(unitId, C_SPIKE, Enum.Material.Metal),
				phi = band.phi, theta0 = (i - 0.5) / band.n * math.pi * 2, n = band.n,
			})
		end
	end

	local legs: { BasePart } = {}
	for _ = 1, N_LEGS do table.insert(legs, makePart(unitId, C_LEG, Enum.Material.SmoothPlastic)) end

	-- One fixed eye (+ socket + brow) on each side pole; a minimal mouth up front.
	local eyes:    { BasePart } = {}
	local sockets: { BasePart } = {}
	local brows:   { BasePart } = {}
	for _ = 1, 2 do
		table.insert(sockets, makePart(unitId, C_PLATE2, Enum.Material.Metal))
		table.insert(eyes,    makePart(unitId, C_EYE,    Enum.Material.Neon))
		table.insert(brows,   makePart(unitId, C_BODY,   Enum.Material.Metal))
	end
	local mouth = makePart(unitId, C_SPIKE, Enum.Material.SmoothPlastic)

	-- One flowing tentacle beside each eye (glowing tip).
	local tentacles: { Tentacle } = {}
	for k = 1, 2 do
		local segs: { BasePart } = {}
		for _ = 1, N_TENT_SEG do table.insert(segs, makePart(unitId, C_SPIKE, Enum.Material.SmoothPlastic)) end
		local tip  = makePart(unitId, C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
		table.insert(tentacles, { segs = segs, tip = tip, sgn = if k == 1 then -1 else 1 })
	end

	local sparkHost = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)
	sparkHost.Transparency = 1
	local sparks    = makeSparks(sparkHost)

	-- Looping rolling sound, emitted from the moving pivot (3D-positional).
	local rollSound              = Instance.new("Sound")
	rollSound.SoundId            = ROLL_SOUND_ID
	rollSound.Looped             = true
	rollSound.Volume             = 0
	rollSound.RollOffMinDistance = 10
	rollSound.RollOffMaxDistance = 150
	rollSound.RollOffMode        = Enum.RollOffMode.Linear
	rollSound.Parent             = body
	rollSound:Play()

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		RollerBody.detach(unitId)
	end)

	active[unitId] = {
		body        = body,
		core        = core,
		plates      = plates,
		spikes      = spikes,
		legs        = legs,
		eyes        = eyes,
		sockets     = sockets,
		brows       = brows,
		tentacles   = tentacles,
		mouth       = mouth,
		sparkHost   = sparkHost,
		sparks      = sparks,
		rollSound   = rollSound,
		sndVol      = 0,
		pitchCur    = 1,
		pitchTarget = 1,
		pitchTimer  = 0,
		prevPos     = nil,
		roll        = phase * 6.28,
		smoothSpeed = 0,
		tentClock   = phase * 5.0,
		grindT      = 0,
		conn        = conn,
	}
end

function RollerBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, s in e.plates do if s.part.Parent then s.part:Destroy() end end
	for _, s in e.spikes do if s.part.Parent then s.part:Destroy() end end
	for _, list in { e.legs, e.eyes, e.sockets, e.brows } do
		for _, p in list do if p.Parent then p:Destroy() end end
	end
	for _, t in e.tentacles do
		for _, p in t.segs do if p.Parent then p:Destroy() end end
		if t.tip.Parent then t.tip:Destroy() end
	end
	for _, p in { e.core, e.mouth, e.sparkHost } do
		if p.Parent then p:Destroy() end
	end
	if e.rollSound.Parent then e.rollSound:Destroy() end
end

-- Rev + spark the nearest Roller to a grind origin.
function RollerBody.triggerAttackNear(pos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		local d = (e.body.Position - pos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < 40 then
		local e = active[bestId]
		e.grindT = GRIND_TIME
		e.sparks:Emit(math.random(5, 9))
	end
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
local function layout(e: Entry, sc: number, speedF: number)
	local body   = e.body
	local cf     = body.CFrame
	local center = body.Position

	-- Travel/heading basis. The axle is `right` (left↔right), so the shell rolls in
	-- the fwd-up plane → forward, the way it moves.
	local lv  = cf.LookVector
	local fwd = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd         = fwd.Unit
	local right = fwd:Cross(Vector3.yAxis).Unit    -- the axle
	local up    = Vector3.yAxis
	local Rs    = RS * sc
	local roll  = e.roll

	-- A point on the sphere at longitude θ (θ = 0 → top; advances with roll) and
	-- latitude φ (0 = equator, ± toward the side poles = the axle). Returns the
	-- surface position and the local tangent frame (outward normal + two tangents).
	local function frame(theta: number, phi: number): (Vector3, Vector3, Vector3, Vector3)
		local cth, sth = math.cos(theta), math.sin(theta)
		local radial   = up * cth + fwd * sth          -- in the rolling plane
		local cph, sph = math.cos(phi), math.sin(phi)
		local normal   = right * sph + radial * cph     -- outward from centre (unit)
		local tTheta   = up * -sth + fwd * cth          -- tangent along longitude (rolling)
		local tPhi     = right * cph - radial * sph      -- tangent along latitude (toward +pole)
		return center + normal * Rs, normal, tTheta, tPhi
	end

	-- Core ball.
	local d = Rs * 1.98
	e.core.CFrame = CFrame.new(center)
	e.core.Size   = Vector3.new(d, d, d)

	-- Interlocking armor plates, wrapped over the whole sphere and whirling with roll.
	for _, s in e.plates do
		local pos, normal, tTheta, tPhi = frame(s.theta0 + roll, s.phi)
		local arc = (math.pi * 2 * Rs * math.cos(s.phi)) / s.n * 0.86   -- tile this band's plates
		orient(s.part, pos + normal * (0.25 * sc), tTheta, tPhi,
			Vector3.new(arc, 2.0 * sc, 0.55 * sc))
	end

	-- Blunt spikes standing out from the sphere all over (hazardous shell) — half size.
	local spikeLen = 0.95 * sc
	for _, s in e.spikes do
		local pos, normal, tTheta = frame(s.theta0 + roll, s.phi)
		orient(s.part, pos + normal * (spikeLen * 0.5 - 0.15 * sc), tTheta, normal,
			Vector3.new(0.7 * sc, spikeLen, 0.7 * sc))
	end

	-- ── Fixed eyes: one on each side pole (do NOT spin with the roll) ──────────
	-- On the axle, so rolling leaves them put; each looks outward, upright, with a
	-- slight forward-up slant for a focused, stoic stare.
	local pole  = Rs + 0.1 * sc
	local slant = (fwd * 0.42 + up * 0.86).Unit        -- long axis of the narrow eye
	for k = 1, 2 do
		local sgn    = if k == 1 then -1 else 1
		local normal = right * sgn                      -- outward from this side pole
		local base   = center + normal * pole + fwd * (0.4 * sc)
		orient(e.sockets[k], base - normal * (0.3 * sc), slant, normal,
			Vector3.new(2.4 * sc, 0.5 * sc, 1.8 * sc))
		orient(e.eyes[k], base + normal * (0.1 * sc), slant, normal,
			Vector3.new(1.8 * sc, 0.55 * sc, 0.5 * sc))
		local browPos = base + slant * (1.15 * sc)
		orient(e.brows[k], browPos, (fwd * 0.9 - up * 0.2).Unit, normal,
			Vector3.new(2.3 * sc, 0.55 * sc, 0.7 * sc))
	end

	-- ── Flowing tentacles beside each eye ─────────────────────────────────────
	-- They stream BACKWARD (−fwd, opposite to travel) — more so the faster it rolls —
	-- while a traveling sine ripples out to the glowing tip in a mesmerizing wave.
	for _, t in e.tentacles do
		local normal   = right * t.sgn
		local tentBase = center + normal * (pole * 0.96) + up * (1.7 * sc) + fwd * (0.2 * sc)
		local pts: { Vector3 } = {}
		for j = 0, N_TENT_SEG do
			local a    = j / N_TENT_SEG
			local back = a * TENT_LEN * sc * (0.3 + 0.85 * speedF)   -- trails with speed
			local out  = (1 - a) * 1.0 * sc                          -- sprouts out near the base
			local droop= a * a * 1.1 * sc                            -- gentle downward hang
			local ph   = e.tentClock - a * TENT_K                    -- ripple travels base → tip
			local amp  = a * TENT_AMP * sc
			local wave = up * math.sin(ph) * amp + normal * math.cos(ph * 1.3) * amp * 0.5
			pts[j + 1] = tentBase - fwd * back + normal * out - up * droop + wave
		end
		for j = 1, N_TENT_SEG do
			local thick = (0.55 - 0.4 * (j - 1) / N_TENT_SEG) * sc
			connect(t.segs[j], pts[j], pts[j + 1], thick)
		end
		local tipD = (0.55 + 0.12 * math.sin(e.tentClock * 2.0)) * sc
		t.tip.Size   = Vector3.new(tipD, tipD, tipD)
		t.tip.CFrame = CFrame.new(pts[N_TENT_SEG + 1])
	end

	-- Minimal mouth: a short dark slit low on the leading front of the shell.
	local mouthPos = center + fwd * (Rs * 0.88 * sc) - up * (Rs * 0.34 * sc)
	orient(e.mouth, mouthPos, right, up, Vector3.new(2.0 * sc, 0.32 * sc, 0.4 * sc))

	-- ── A few small legs tucked under the shell (mostly hidden — it rolls) ─────
	local botY = -Rs + 0.4 * sc
	for i = 1, N_LEGS do
		local u       = (i - (N_LEGS + 1) / 2) / N_LEGS       -- spread along the axle
		local legBase = center + right * (u * Rs * 1.1 * sc) + up * (botY + 1.0 * sc)
		local foot    = legBase + up * (-1.2 * sc)
		local delta   = foot - legBase
		local len     = math.max(delta.Magnitude, 0.2)
		orient(e.legs[i], (legBase + foot) * 0.5, right, delta / len, Vector3.new(0.4 * sc, len, 0.4 * sc))
	end

	-- Park the spark emitter at the leading edge (front of the shell).
	e.sparkHost.CFrame = CFrame.lookAt(center + fwd * (Rs * 0.9), center + fwd * (Rs * 2))
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function RollerBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_RollerBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				RollerBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then continue end

			-- Speed estimate from frame-to-frame movement (parts are anchored).
			local last      = e.prevPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.prevPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.1
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Roll forward proportionally to distance travelled (frameMove / R), plus a
			-- rev while grinding a target. A stationary Roller does not roll.
			if e.grindT > 0 then
				e.grindT = math.max(0, e.grindT - dt)
				e.roll  += dt * GRIND_SPIN
			end
			e.roll += (frameMove / R) * ROLL_GAIN
			-- Tentacle ripple flows faster the quicker it moves.
			e.tentClock += dt * TENT_FREQ * (1 + 0.6 * speedF)

			-- Rolling sound: fade in with speed; pitch rises with speed and wobbles
			-- randomly so it never sounds like one flat looped tone.
			e.pitchTimer -= dt
			if e.pitchTimer <= 0 then
				e.pitchTimer  = 0.22 + math.random() * 0.35
				e.pitchTarget = ROLL_PITCH_MIN + math.random() * (ROLL_PITCH_MAX - ROLL_PITCH_MIN)
			end
			e.pitchCur += (e.pitchTarget - e.pitchCur) * math.min(1, dt * 6)
			local targetVol = if speedF > 0.05 then math.clamp(0.35 + speedF, 0, 1) * ROLL_VOL_MAX else 0
			e.sndVol += (targetVol - e.sndVol) * math.min(1, dt * 8)
			e.rollSound.Volume        = e.sndVol
			e.rollSound.PlaybackSpeed = e.pitchCur * (0.8 + speedF * 0.6)

			local sc = body.Size.Y / BASE_HEIGHT
			layout(e, sc, speedF)
		end
	end)
end

return RollerBody
