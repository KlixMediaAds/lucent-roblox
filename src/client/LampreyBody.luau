-- LampreyBody.luau
-- Client-only procedural body + burrowing animation for the massive Lamprey unit.
-- Architecture mirrors WalkerLegs / CreepyLegs: one shared RenderStepped loop, a
-- distance cull, a speed-proportional animation clock, and parts tagged with a
-- "UnitId" attribute so FogManager can hide them for enemy units in the fog.
--
-- The server spawns the Lamprey as an invisible, ground-snapped pivot block
-- (size 7×12×7, so its centre sits BODY_HALF_Y = 6 studs above the terrain).
-- Everything you see — the segmented eel, the toothy maw, the kicked-up dirt — is
-- drawn here. When idle the head rears out of the ground and the body stays
-- buried; when moving a travelling wave porpoises the whole creature in and out of
-- the surface, throwing dirt each time a segment breaches.
--!strict

local RunService = game:GetService("RunService")

local LampreyBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
local N_SEG      = 8       -- body segments (spine has N_SEG + 1 points)
local HEAD_FWD   = 5.5     -- head's forward offset from the pivot, along LookVector
local TOTAL_LEN  = 16.0    -- head-to-tail spine length in studs
-- Tube thickness at each of the 9 spine points (head → tail taper)
local THICK = { 3.4, 3.2, 3.0, 2.6, 2.2, 1.8, 1.4, 1.0, 0.6 }

-- Base sizes for the parts whose dimensions are fixed at attach but rescaled
-- each frame by the growth factor (see BASE_HEIGHT below).
local HEAD_SIZE  = Vector3.new(3.8, 3.6, 4.0)
local MAW_SIZE   = Vector3.new(2.4, 2.4, 1.4)
local EYE_SIZE   = Vector3.new(0.9, 0.9, 0.9)

-- Growth: the server grows a tree-felling Lamprey by scaling its (invisible)
-- pivot part. We derive a render scale from the part's current height versus the
-- spawn height so the whole creature swells to match. Must equal the Y of
-- Config.UNIT_TYPES.Lamprey.size.
local BASE_HEIGHT = 12.0

-- ── Burrow / undulation ───────────────────────────────────────────────────────
local FULL_SPEED      = 13.0   -- matches Config.UNIT_MOVE_SPEED.Lamprey
local WAVE_FREQ       = 1.4    -- porpoise cycles/sec at full speed
local WAVE_AMP        = 4.2    -- vertical breach/dive amplitude (studs)
local WAVE_K          = math.pi * 2 * 1.25   -- humps along the body length
local IDLE_HEAD_RISE  = 4.2    -- how far the head pokes out of the ground when idle
local IDLE_SINK_RATE  = 24.0   -- how fast the body buries behind the head when idle
local IDLE_BOB_FREQ   = 0.5
local LAT_AMP         = 1.7    -- side-to-side slither amplitude
local LAT_K           = math.pi * 2 * 0.7
local LAT_FREQ        = 1.1

local CULL_SQ    = 300 * 300
local HOP_SND_ID = "rbxassetid://117742365588721"
local HOP_COOLDOWN = 0.18   -- min seconds between hop sounds per unit

-- ── Colours ───────────────────────────────────────────────────────────────────
local C_BODY  = Color3.fromRGB(40, 44, 52)
local C_TOOTH = Color3.fromRGB(228, 226, 210)
local C_MAW   = Color3.fromRGB(150, 24, 28)
local C_EYE   = Color3.fromRGB(255, 230, 40)

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Orient a box so its local Y axis runs from world point a to world point b.
local function orientYBetween(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.04 then return end
	local dir   = delta / len
	local right = dir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then right = dir:Cross(Vector3.xAxis) end
	right = right.Unit
	local back = right:Cross(dir)
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(thick, len, thick)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Entry = {
	body:        BasePart,
	segs:        { BasePart },  -- N_SEG tubes
	knuckles:    { BasePart },  -- interior joint balls
	fins:        { BasePart },  -- dorsal spikes on the front segments
	teeth:       { BasePart },
	eyes:        { BasePart },
	head:        BasePart,
	maw:         BasePart,
	dirt:        { ParticleEmitter },  -- pool of dirt emitters, reused per breach
	dirtHost:    { BasePart },
	dirtIdx:     number,
	prevY:       { number },     -- last frame's world Y per spine point (breach detect)
	lastPos:     Vector3?,       -- body position last frame (for speed estimate)
	animClock:   number,
	latClock:    number,
	idleClock:   number,
	smoothSpeed: number,
	lastHopSound: number,
	-- ── Idle / attack animation state ──
	nextIdleAt:   number,    -- tick() when the next idle animation may start
	idleKind:     string?,   -- "yawn" | "shake" while playing, else nil
	idleT:        number,    -- elapsed seconds into the current idle animation
	idleDur:      number,    -- total duration of the current idle animation
	attackActive: boolean,   -- true while an attack (mouth-open lunge) plays
	attackT:      number,    -- elapsed seconds into the current attack
	conn:        RBXScriptConnection,
}

-- Animation durations (seconds)
local YAWN_DUR   = 2.2
local SHAKE_DUR  = 1.4
local ATTACK_DUR = 0.5

local active: { [string]: Entry } = {}
local folder: Folder
local camera: Camera

-- ── Part factories ────────────────────────────────────────────────────────────

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

local function makeDirtEmitter(host: BasePart)
	local pe                = Instance.new("ParticleEmitter")
	pe.Texture              = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color                = ColorSequence.new(Color3.fromRGB(104, 80, 52), Color3.fromRGB(64, 48, 30))
	pe.LightEmission        = 0
	pe.LightInfluence       = 1
	pe.Size                 = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.6),
		NumberSequenceKeypoint.new(0.4, 1.4),
		NumberSequenceKeypoint.new(1,   2.0),
	})
	pe.Transparency         = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.25),
		NumberSequenceKeypoint.new(1,   1.0),
	})
	pe.Lifetime             = NumberRange.new(0.4, 0.8)
	pe.Speed                = NumberRange.new(7, 14)
	pe.SpreadAngle          = Vector2.new(48, 48)
	pe.Acceleration         = Vector3.new(0, -55, 0)  -- gravity: clods arc up then fall
	pe.Rotation             = NumberRange.new(0, 360)
	pe.RotSpeed             = NumberRange.new(-90, 90)
	pe.Rate                 = 0                        -- burst-only via :Emit
	pe.EmissionDirection    = Enum.NormalId.Top
	pe.Parent               = host
	return pe
end

-- ── Public API ────────────────────────────────────────────────────────────────

function LampreyBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local segs:     { BasePart } = {}
	local knuckles: { BasePart } = {}
	for _ = 1, N_SEG do table.insert(segs, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)) end
	for _ = 1, N_SEG - 1 do
		local b = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		table.insert(knuckles, b)
	end

	local fins: { BasePart } = {}
	for _ = 1, 3 do table.insert(fins, makePart(unitId, Color3.fromRGB(26, 28, 34), Enum.Material.SmoothPlastic)) end

	local head = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	head.Size  = HEAD_SIZE

	local maw  = makePart(unitId, C_MAW, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	maw.Size   = MAW_SIZE

	local teeth: { BasePart } = {}
	for _ = 1, 8 do table.insert(teeth, makePart(unitId, C_TOOTH, Enum.Material.SmoothPlastic)) end

	local eyes: { BasePart } = {}
	for _ = 1, 2 do
		local e = makePart(unitId, C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
		e.Size  = EYE_SIZE
		table.insert(eyes, e)
	end

	-- Dirt emitter pool, repositioned to the breach point as the body surfaces
	local dirt:     { ParticleEmitter } = {}
	local dirtHost: { BasePart }        = {}
	for _ = 1, 3 do
		local host       = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)
		host.Transparency = 1
		host.Size        = Vector3.new(0.2, 0.2, 0.2)
		table.insert(dirtHost, host)
		table.insert(dirt, makeDirtEmitter(host))
	end

	local prevY: { number } = {}
	for i = 1, N_SEG + 1 do prevY[i] = body.Position.Y end

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		LampreyBody.detach(unitId)
	end)

	active[unitId] = {
		body         = body,
		segs         = segs,
		knuckles     = knuckles,
		fins         = fins,
		teeth        = teeth,
		eyes         = eyes,
		head         = head,
		maw          = maw,
		dirt         = dirt,
		dirtHost     = dirtHost,
		dirtIdx      = 1,
		prevY        = prevY,
		animClock    = phase,
		latClock     = phase * 1.7,
		idleClock    = phase,
		smoothSpeed  = 0,
		lastHopSound = 0,
		-- Stagger first idle so a cluster of lampreys doesn't yawn in unison
		nextIdleAt   = tick() + 3 + (n % 7),
		idleKind     = nil,
		idleT        = 0,
		idleDur      = 0,
		attackActive = false,
		attackT      = 0,
		conn         = conn,
	}
end

-- Triggered when a Lamprey spits bile: snap the mouth open and lunge the head.
-- The attack VFX (init.client) only knows the firing position, so match the
-- nearest active Lamprey to it.
function LampreyBody.triggerAttackNear(pos: Vector3)
	local bestId: string?  = nil
	local bestD            = math.huge
	for unitId, e in active do
		local d = (e.body.Position - pos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < 30 then
		local e = active[bestId]
		e.attackActive = true
		e.attackT      = 0
		e.idleKind     = nil   -- cancel any idle in progress
	end
end

-- ── Animation driver: advances idle/attack state, returns the head pose ────────
-- Returns (mouthOpen 0..1, yaw, pitch, lunge) applied to the head each frame.
local function updatePose(e: Entry, dt: number, speedF: number): (number, number, number, number)
	local mouthOpen, yaw, pitch, lunge = 0.0, 0.0, 0.0, 0.0
	local now    = tick()
	local moving = speedF > 0.18

	-- ── Attack: fast snap-open + forward lunge, takes priority over idles ──
	if e.attackActive then
		e.attackT += dt
		local p = e.attackT / ATTACK_DUR
		if p >= 1 then
			e.attackActive = false
		else
			local o
			if p < 0.22 then o = p / 0.22            -- snap open
			elseif p < 0.5 then o = 1                 -- hold (the spit)
			else o = 1 - (p - 0.5) / 0.5 end          -- close
			mouthOpen = o
			lunge     = math.sin(math.min(p / 0.5, 1) * math.pi) * 1.6  -- thrust then recoil
		end
	end

	-- ── Idle animations: only while essentially stationary ──
	if not e.attackActive then
		if e.idleKind == nil and not moving and now >= e.nextIdleAt then
			e.idleKind = if math.random() < 0.5 then "yawn" else "shake"
			e.idleT    = 0
			e.idleDur  = if e.idleKind == "yawn" then YAWN_DUR else SHAKE_DUR
		end

		if e.idleKind ~= nil then
			if moving then
				-- Interrupted by movement: abandon and reschedule
				e.idleKind   = nil
				e.nextIdleAt = now + 4 + math.random() * 5
			else
				e.idleT += dt
				local p = e.idleT / e.idleDur
				if p >= 1 then
					e.idleKind   = nil
					e.nextIdleAt = now + 5 + math.random() * 6
				elseif e.idleKind == "yawn" then
					-- Slow, languid wide stretch with the head rearing upward
					local o
					if p < 0.30 then o = p / 0.30
					elseif p < 0.62 then o = 1
					else o = 1 - (p - 0.62) / 0.38 end
					o         = o * o * (3 - 2 * o)        -- smoothstep
					mouthOpen = o
					pitch     = o * 0.45                   -- nose up
				else
					-- "shake": three quick agitated chomps + a rapid head shake
					local env   = math.sin(p * math.pi)            -- fade in/out
					local chomp = math.abs(math.sin(p * math.pi * 3))
					mouthOpen   = chomp * env * 0.85
					yaw         = math.sin(p * math.pi * 8) * 0.25 * env
				end
			end
		end
	end

	return mouthOpen, yaw, pitch, lunge
end

function LampreyBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	local function killAll(list: { BasePart })
		for _, p in list do if p.Parent then p:Destroy() end end
	end
	killAll(e.segs); killAll(e.knuckles); killAll(e.fins)
	killAll(e.teeth); killAll(e.eyes); killAll(e.dirtHost)
	if e.head.Parent then e.head:Destroy() end
	if e.maw.Parent  then e.maw:Destroy()  end
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
-- mouthOpen/yaw/pitch/lunge come from updatePose (idle yawn/shake + attack snap).
local function layout(e: Entry, speedF: number, mouthOpen: number, yaw: number, pitch: number, lunge: number)
	local body   = e.body
	local cf     = body.CFrame
	local bpos   = body.Position
	-- Growth scale derived from the (server-grown) pivot height. 1.0 at spawn.
	local sc      = body.Size.Y / BASE_HEIGHT
	local groundY = bpos.Y - body.Size.Y * 0.5

	-- Flat forward / right basis from the body's facing
	local lv     = cf.LookVector
	local fwd    = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd          = fwd.Unit
	local right  = fwd:Cross(Vector3.yAxis).Unit
	local centre = Vector3.new(bpos.X, groundY, bpos.Z)

	local headBob = math.sin(e.idleClock) * 0.4

	-- ── Build spine points in world space (all offsets scale with growth) ──────
	local pts: { Vector3 } = {}
	for i = 0, N_SEG do
		local s     = i / N_SEG
		local along = (HEAD_FWD - s * TOTAL_LEN) * sc

		-- Vertical: blend idle (head out, body buried) with moving (porpoise wave)
		local idleOff = ((IDLE_HEAD_RISE - s * IDLE_SINK_RATE) + headBob * (1 - s)) * sc
		local moveOff = WAVE_AMP * sc * math.sin(e.animClock - s * WAVE_K)
		local off     = lerp(idleOff, moveOff, speedF)

		-- Lateral slither: subtle when idle, fuller when moving
		local lat = math.sin(e.latClock - s * LAT_K) * LAT_AMP * sc * (0.35 + 0.65 * speedF)

		pts[i + 1] = centre + fwd * along + right * lat + Vector3.new(0, off, 0)
	end

	-- ── Segments + knuckle joints ─────────────────────────────────────────────
	for i = 1, N_SEG do
		local t = (THICK[i] + THICK[i + 1]) * 0.5 * sc
		orientYBetween(e.segs[i], pts[i], pts[i + 1], t)
	end
	for i = 1, N_SEG - 1 do
		local d = THICK[i + 1] * sc
		e.knuckles[i].Size   = Vector3.new(d, d, d)
		e.knuckles[i].CFrame = CFrame.new(pts[i + 1])
	end

	-- ── Dorsal fins on the front three joints (rake backward) ─────────────────
	for f = 1, 3 do
		local base = pts[f + 1]
		local tip  = base + Vector3.new(0, (THICK[f + 1] * 0.5 + 1.6) * sc, 0) - fwd * (0.8 * sc)
		orientYBetween(e.fins[f], base, tip, 0.4 * sc)
	end

	-- ── Head + maw + teeth + eyes ─────────────────────────────────────────────
	local headPos = pts[1]
	local headDir = (pts[1] - pts[2])
	headDir = if headDir.Magnitude > 0.01 then headDir.Unit else fwd
	-- Base head frame from the spine, then layer the animation pose on top:
	-- pitch (rear up), yaw (look-around / shake), lunge (thrust forward, -Z).
	local headCF  = CFrame.lookAt(headPos, headPos + headDir)  -- LookVector = -Z = headDir
		* CFrame.Angles(pitch, yaw, 0)
		* CFrame.new(0, 0, -lunge * sc)
	e.head.Size   = HEAD_SIZE * sc
	e.head.CFrame = headCF

	-- Maw (throat) bulges forward and grows as the mouth opens, revealing the gullet
	e.maw.Size    = MAW_SIZE * sc * (1 + mouthOpen * 0.6)
	e.maw.CFrame  = headCF * CFrame.new(0, -0.2 * sc, -(1.3 + mouthOpen * 0.9) * sc)

	-- Fang ring: each tooth hinges from a FIXED base ring on the mouth rim — only
	-- the tip swings. Closed, tips converge inward to a point; open, tips splay
	-- outward + forward like a lamprey's sucker-mouth flaring its teeth. (Growing
	-- the base radius with mouthOpen made the whole tooth float off the head.)
	local BASE_R    = 1.45 * sc                  -- anchored mouth-rim radius (fixed)
	local MOUTH_FWD = 1.6 * sc
	local tipOut    = 0.35 + mouthOpen * 1.45    -- tip radius factor (splays open)
	local tipFwd    = (1.3 + mouthOpen * 0.9) * sc
	for k = 1, 8 do
		local ang   = (k / 8) * math.pi * 2
		local c, sn = math.cos(ang), math.sin(ang)
		local base  = (headCF * CFrame.new(c * BASE_R, sn * BASE_R - 0.2 * sc, -MOUTH_FWD)).Position
		local tip   = (headCF * CFrame.new(c * BASE_R * tipOut, sn * BASE_R * tipOut - 0.2 * sc, -MOUTH_FWD - tipFwd)).Position
		orientYBetween(e.teeth[k], base, tip, 0.42 * sc)
	end

	e.eyes[1].Size   = EYE_SIZE * sc
	e.eyes[2].Size   = EYE_SIZE * sc
	e.eyes[1].CFrame = headCF * CFrame.new(-1.15 * sc, 0.95 * sc, -0.7 * sc)
	e.eyes[2].CFrame = headCF * CFrame.new( 1.15 * sc, 0.95 * sc, -0.7 * sc)

	-- ── Dirt: burst whenever a spine point breaches the surface while moving ──
	if speedF > 0.18 then
		local now = tick()
		for i = 1, N_SEG + 1 do
			local y      = pts[i].Y
			local was    = e.prevY[i]
			if was <= groundY and y > groundY then
				local host = e.dirtHost[e.dirtIdx]
				host.CFrame = CFrame.new(pts[i].X, groundY + 0.2, pts[i].Z)
				e.dirt[e.dirtIdx]:Emit(math.random(6, 11))
				e.dirtIdx = (e.dirtIdx % #e.dirt) + 1
				if now - e.lastHopSound >= HOP_COOLDOWN then
					e.lastHopSound = now
					local p            = Instance.new("Part")
					p.Anchored         = true; p.CanCollide = false; p.Transparency = 1
					p.Size             = Vector3.new(1, 1, 1)
					p.Position         = host.CFrame.Position
					p.Parent           = workspace
					local s            = Instance.new("Sound")
					s.SoundId          = HOP_SND_ID
					s.PlaybackSpeed    = 0.82 + math.random() * 0.36
					s.Volume           = 0.65
					s.RollOffMaxDistance = 80
					s.RollOffMinDistance = 8
					s.RollOffMode      = Enum.RollOffMode.Linear
					s.Parent           = p
					s:Play()
					s.Ended:Once(function() p:Destroy() end)
				end
			end
			e.prevY[i] = y
		end
	else
		for i = 1, N_SEG + 1 do e.prevY[i] = pts[i].Y end
	end
end

-- ── Init + animation loop ─────────────────────────────────────────────────────

function LampreyBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_LampreyBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				LampreyBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx   = bpos.X - camPos.X
			local dy   = bpos.Y - camPos.Y
			local dz   = bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then
				continue
			end

			-- Speed estimate from frame-to-frame body movement (parts are anchored,
			-- so AssemblyLinearVelocity is always zero — derive it ourselves).
			local last      = e.lastPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.lastPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.08
			e.smoothSpeed += (spd - e.smoothSpeed) * alpha
			local speedF = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Advance clocks
			e.animClock += dt * (0.15 + speedF) * WAVE_FREQ * math.pi * 2
			e.latClock  += dt * LAT_FREQ * math.pi * 2
			e.idleClock += dt * IDLE_BOB_FREQ * math.pi * 2

			local mouthOpen, yaw, pitch, lunge = updatePose(e, dt, speedF)
			layout(e, speedF, mouthOpen, yaw, pitch, lunge)
		end
	end)
end

return LampreyBody
