-- HagfishBody.luau
-- Client-only procedural body + slither/attack animation for the Hagfish unit.
-- Architecture mirrors LampreyBody: one shared RenderStepped loop, a distance
-- cull, a speed-proportional animation clock, and parts tagged with a "UnitId"
-- attribute so FogManager can hide them for enemy units in the fog.
--
-- The server spawns the Hagfish as an invisible, ground-snapped pivot block
-- (size 6×10×6). Everything you see is drawn here: a long eel-like body whose
-- back two-thirds slither across the ground in an S-wave while its front third
-- rears up like a cobra, six dark reddish-purple teeth ringing the SIDES of its
-- mouth (three a side, like the six face of a die), and two wobbly antennae on
-- its crown.
--
-- Attack: when the server fires a HagfishStrike, the head slaps down into the
-- earth (teeth sink in) and stays buried while six teeth-like tentacles erupt
-- from the ground around the enemies (drawn by spawnTentacles at the strike
-- positions). After the strike window the head rears back to its cobra stance.
--!strict

local RunService = game:GetService("RunService")

local HagfishBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
local N_SEG      = 8          -- body segments (spine has N_SEG + 1 points)
local TOTAL_LEN  = 15.0       -- nominal head-to-tail length in studs
local FRONT_FRAC = 0.4        -- front fraction of the body that rears up (cobra)
local THICK      = { 2.4, 2.4, 2.3, 2.1, 1.9, 1.6, 1.3, 1.0, 0.6 }  -- head → tail taper

-- Reared (cobra) profile
local HEAD_RISE  = 6.5        -- head height above ground when fully reared
local NECK_FWD   = 2.6        -- how far the reared head leans forward of the neck base
-- Slap profile (head driven down onto the earth ahead)
local SLAP_FWD   = 6.0        -- how far forward the head reaches when it slaps down
local SLAP_Y     = 0.3        -- head height when slammed into the ground
local REAR_LEN   = 11.0       -- ground length the trailing body covers

local HEAD_SIZE  = Vector3.new(3.0, 2.8, 3.4)
local EYE_SIZE   = Vector3.new(0.7, 0.7, 0.7)

-- Must equal Config.UNIT_TYPES.Hagfish.size.Y (the hagfish does not grow, so the
-- render scale stays ~1, but we keep the same derivation as LampreyBody).
local BASE_HEIGHT = 10.0

-- ── Slither ─────────────────────────────────────────────────────────────────--
local FULL_SPEED = 15.0       -- matches Config.UNIT_MOVE_SPEED.Hagfish
local SLITHER_FREQ = 1.5      -- lateral wave cycles/sec baseline
local LAT_AMP    = 2.2        -- side-to-side slither amplitude (studs)
local LAT_K      = math.pi * 2 * 0.9   -- waves along the body length
local IDLE_SWAY_FREQ = 0.6

-- ── Attack timeline (seconds) ──────────────────────────────────────────────────
local SLAP_T   = 0.28                 -- head slams down
local HOLD_T   = 2.5                  -- teeth buried (matches Config.HAGFISH_STRIKE_WINDOW)
local RAISE_T  = 0.55                 -- head rears back up
local ATTACK_T = SLAP_T + HOLD_T + RAISE_T

local CULL_SQ  = 300 * 300

-- ── Colours ───────────────────────────────────────────────────────────────────
local C_BODY  = Color3.fromRGB(48, 40, 56)   -- dark purplish slate
local C_TOOTH = Color3.fromRGB(96, 32, 66)   -- dark reddish-purple (teeth + tentacles)
local C_ANT   = Color3.fromRGB(70, 50, 78)
local C_EYE   = Color3.fromRGB(255, 120, 60)

local ERUPT_SND_ID = "rbxassetid://117742365588721"

-- ── Helpers ───────────────────────────────────────────────────────────────────
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

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Entry = {
	body:        BasePart,
	segs:        { BasePart },
	knuckles:    { BasePart },
	teeth:       { BasePart },   -- 6 side teeth
	antennae:    { BasePart },   -- 2 stalks
	antTips:     { BasePart },   -- 2 stalk-tip balls
	eyes:        { BasePart },
	head:        BasePart,
	prevPos:     Vector3?,
	animClock:   number,
	idleClock:   number,
	smoothSpeed: number,
	rear:        number,         -- 0 = head slapped down, 1 = fully reared cobra
	attackActive: boolean,
	attackT:     number,
	conn:        RBXScriptConnection,
}

local active: { [string]: Entry } = {}
local folder: Folder
local camera: Camera

-- ── Part factory ────────────────────────────────────────────────────────────--
local function makePart(unitId: string?, col: Color3, mat: Enum.Material, shape: Enum.PartType?): BasePart
	local p          = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Color          = col
	p.Material       = mat
	p.Anchored       = true
	p.CanCollide     = false
	p.CanQuery       = false
	p.CastShadow     = false
	p.Size           = Vector3.new(0.2, 0.2, 0.2)
	if unitId then p:SetAttribute("UnitId", unitId) end
	p.Parent         = folder
	return p
end

local function makeDirtEmitter(host: BasePart)
	local pe             = Instance.new("ParticleEmitter")
	pe.Texture           = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color             = ColorSequence.new(Color3.fromRGB(86, 60, 70), Color3.fromRGB(52, 36, 44))
	pe.LightEmission     = 0
	pe.LightInfluence    = 1
	pe.Size              = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.6),
		NumberSequenceKeypoint.new(0.4, 1.5),
		NumberSequenceKeypoint.new(1,   2.2),
	})
	pe.Transparency      = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	pe.Lifetime          = NumberRange.new(0.4, 0.85)
	pe.Speed             = NumberRange.new(8, 16)
	pe.SpreadAngle       = Vector2.new(55, 55)
	pe.Acceleration      = Vector3.new(0, -58, 0)
	pe.Rotation          = NumberRange.new(0, 360)
	pe.RotSpeed          = NumberRange.new(-90, 90)
	pe.Rate              = 0
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Parent            = host
	return pe
end

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function HagfishBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local segs:     { BasePart } = {}
	local knuckles: { BasePart } = {}
	for _ = 1, N_SEG do table.insert(segs, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)) end
	for _ = 1, N_SEG - 1 do
		table.insert(knuckles, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end

	local head = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	head.Size  = HEAD_SIZE

	local teeth: { BasePart } = {}
	for _ = 1, 6 do table.insert(teeth, makePart(unitId, C_TOOTH, Enum.Material.SmoothPlastic)) end

	local antennae: { BasePart } = {}
	local antTips:  { BasePart } = {}
	for _ = 1, 2 do
		table.insert(antennae, makePart(unitId, C_ANT, Enum.Material.SmoothPlastic))
		local tip = makePart(unitId, C_ANT, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		tip.Size  = Vector3.new(0.5, 0.5, 0.5)
		table.insert(antTips, tip)
	end

	local eyes: { BasePart } = {}
	for _ = 1, 2 do
		local e = makePart(unitId, C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
		e.Size  = EYE_SIZE
		table.insert(eyes, e)
	end

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		HagfishBody.detach(unitId)
	end)

	active[unitId] = {
		body         = body,
		segs         = segs,
		knuckles     = knuckles,
		teeth        = teeth,
		antennae     = antennae,
		antTips      = antTips,
		eyes         = eyes,
		head         = head,
		prevPos      = nil,
		animClock    = phase,
		idleClock    = phase * 1.4,
		smoothSpeed  = 0,
		rear         = 1,
		attackActive = false,
		attackT      = 0,
		conn         = conn,
	}
end

function HagfishBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	local function killAll(list: { BasePart })
		for _, p in list do if p.Parent then p:Destroy() end end
	end
	killAll(e.segs); killAll(e.knuckles); killAll(e.teeth)
	killAll(e.antennae); killAll(e.antTips); killAll(e.eyes)
	if e.head.Parent then e.head:Destroy() end
end

-- Match the nearest active hagfish to a strike origin and start its head-slap.
function HagfishBody.triggerAttackNear(pos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		local d = (e.body.Position - pos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < 40 then
		local e = active[bestId]
		e.attackActive = true
		e.attackT      = 0
	end
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
local function layout(e: Entry, speedF: number, dt: number)
	local body    = e.body
	local cf      = body.CFrame
	local bpos    = body.Position
	local sc      = body.Size.Y / BASE_HEIGHT
	local groundY = bpos.Y - body.Size.Y * 0.5

	local lv  = cf.LookVector
	local fwd = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd         = fwd.Unit
	local right = fwd:Cross(Vector3.yAxis).Unit
	local centre = Vector3.new(bpos.X, groundY, bpos.Z)

	local rear = e.rear
	-- A faint tremor runs through the buried head while the teeth are sunk in.
	local tremor = (1 - rear) * math.sin(e.idleClock * 30) * 0.12 * sc

	-- ── Build spine points (head index 1 → tail index N_SEG+1) ─────────────────
	local pts: { Vector3 } = {}
	for i = 0, N_SEG do
		local s = i / N_SEG
		local along, height

		if s < FRONT_FRAC then
			local u       = s / FRONT_FRAC               -- 0 head → 1 neck base
			local heightA = HEAD_RISE * math.cos(u * math.pi * 0.5)
			local alongA  = NECK_FWD * (1 - u)
			local heightB = SLAP_Y * (1 - u)
			local alongB  = SLAP_FWD * (1 - u)
			height = lerp(heightB, heightA, rear)
			along  = lerp(alongB, alongA, rear)
		else
			local v = (s - FRONT_FRAC) / (1 - FRONT_FRAC)  -- 0 neck base → 1 tail
			along  = -(v * REAR_LEN)
			height = 0.0
		end

		-- Lateral slither: muted on the reared neck, full on the trailing ground body
		local groundness = math.clamp((s - FRONT_FRAC) / (1 - FRONT_FRAC), 0, 1)
		local latScale   = (0.2 + 0.8 * groundness) * (0.55 + 0.45 * speedF)
		local lat        = math.sin(e.animClock - s * LAT_K) * LAT_AMP * sc * latScale

		-- Reared head sways gently when idle
		local sway = math.sin(e.idleClock) * 0.5 * sc * rear * (1 - groundness)

		pts[i + 1] = centre
			+ fwd * (along * sc)
			+ right * (lat + sway + tremor * (1 - groundness))
			+ Vector3.new(0, height * sc, 0)
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

	-- ── Head frame from the spine ─────────────────────────────────────────────
	local headPos = pts[1]
	local headDir = (pts[1] - pts[2])
	headDir = if headDir.Magnitude > 0.01 then headDir.Unit else fwd
	local headCF  = CFrame.lookAt(headPos, headPos + headDir)  -- LookVector (−Z) = headDir
	e.head.Size   = HEAD_SIZE * sc
	e.head.CFrame = headCF

	-- ── Six side teeth: three rows on each side (the six face of a die) ───────
	-- Splay outward + forward from the mouth on the head's underside-front.
	local SIDE_BASE = 1.0 * sc
	local SIDE_TIP  = 1.75 * sc
	local ti = 0
	for _, sgn in { -1, 1 } do
		for _, row in { -1, 0, 1 } do
			ti += 1
			local y    = (row * 0.7 - 0.35) * sc
			local base = (headCF * CFrame.new(sgn * SIDE_BASE, y, -1.1 * sc)).Position
			local tip  = (headCF * CFrame.new(sgn * SIDE_TIP,  y, -1.6 * sc)).Position
			orientYBetween(e.teeth[ti], base, tip, 0.42 * sc)
		end
	end

	-- ── Two wobbly antennae on the crown ──────────────────────────────────────
	for k = 1, 2 do
		local sgn = if k == 1 then -1 else 1
		local wob = math.sin(e.idleClock * 2.2 + sgn * 1.3) * 0.4 * sc
		local base = (headCF * CFrame.new(sgn * 0.6 * sc, 1.1 * sc, -0.1 * sc)).Position
		local tip  = (headCF * CFrame.new(sgn * 0.8 * sc + wob, 2.6 * sc, 0.7 * sc)).Position
		orientYBetween(e.antennae[k], base, tip, 0.3 * sc)
		e.antTips[k].Size   = Vector3.new(0.5, 0.5, 0.5) * sc
		e.antTips[k].CFrame = CFrame.new(tip)
	end

	-- ── Eyes ──────────────────────────────────────────────────────────────────
	e.eyes[1].Size   = EYE_SIZE * sc
	e.eyes[2].Size   = EYE_SIZE * sc
	e.eyes[1].CFrame = headCF * CFrame.new(-1.0 * sc, 0.55 * sc, -0.75 * sc)
	e.eyes[2].CFrame = headCF * CFrame.new( 1.0 * sc, 0.55 * sc, -0.75 * sc)
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function HagfishBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_HagfishBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				HagfishBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then continue end

			-- Speed estimate from frame-to-frame movement (parts are anchored)
			local last      = e.prevPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.prevPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			-- Riding a Roller: the body is dragged along, but it holds its idle wave
			-- (facing still follows the server-set CFrame = Roller's front).
			if body:GetAttribute("Carried") then spd = 0 end
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.08
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Advance clocks (slither speeds up with movement)
			e.animClock += dt * (0.4 + speedF) * SLITHER_FREQ * math.pi * 2
			e.idleClock += dt * IDLE_SWAY_FREQ * math.pi * 2

			-- ── Attack timeline drives the rear amount (head slap → bury → rise) ──
			if e.attackActive then
				e.attackT += dt
				local t = e.attackT
				if t >= ATTACK_T then
					e.attackActive = false
					e.rear = 1
				elseif t < SLAP_T then
					e.rear = 1 - smoothstep(t / SLAP_T)
				elseif t < SLAP_T + HOLD_T then
					e.rear = 0
				else
					e.rear = smoothstep((t - SLAP_T - HOLD_T) / RAISE_T)
				end
			else
				-- Ease back to the reared stance if something interrupted an attack
				e.rear = e.rear + (1 - e.rear) * math.min(1, dt * 6)
			end

			layout(e, speedF, dt)
		end
	end)
end

-- ── Ground tentacle cluster VFX ────────────────────────────────────────────────
-- Six teeth-like tentacles erupt from the earth at the given world positions,
-- striking on their own deviated timing within HOLD_T, then retreating. Spawned
-- by init.client when a HagfishStrike arrives. Self-contained + self-cleaning.

local T_H        = 6.0        -- full tentacle height
local T_NSEG     = 5          -- segments per tentacle (T_NSEG + 1 spine points)
local T_THICK    = { 0.95, 0.82, 0.66, 0.5, 0.32 }
local T_EMERGE   = 0.18       -- rise-out duration
local T_RETREAT  = 0.38       -- sink-back duration
local T_STRIKE   = 0.24       -- whip duration
local T_WAMP     = 0.85       -- wobble amplitude (grows toward the tip)
local T_WFREQ    = 9.0
local T_WK       = math.pi * 1.2
local T_RETREAT_AT = HOLD_T   -- all tentacles start retreating at the strike-window end
local T_LIFE     = HOLD_T + T_RETREAT + 0.15

type Tentacle = {
	segs:       { BasePart },
	tip:        BasePart,
	base:       Vector3,
	emergeDelay: number,
	seed:       number,
	strikeDir:  Vector3,
	dirtHost:   BasePart,
	dirt:       ParticleEmitter,
	erupted:    boolean,
}

function HagfishBody.spawnTentacles(positions: { Vector3 })
	if not folder or #positions == 0 then return end

	local tents: { Tentacle } = {}
	local n = #positions
	local cx, cz = 0, 0

	for k, basePos in positions do
		cx += basePos.X; cz += basePos.Z
		local segs: { BasePart } = {}
		for _ = 1, T_NSEG do
			local sg = makePart(nil, C_TOOTH, Enum.Material.SmoothPlastic)
			sg.Transparency = 1   -- stay hidden until the loop erupts it (avoids an origin flash)
			table.insert(segs, sg)
		end
		local tip = makePart(nil, C_TOOTH, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		tip.Transparency = 1

		local host          = makePart(nil, C_BODY, Enum.Material.SmoothPlastic)
		host.Transparency   = 1
		host.CFrame         = CFrame.new(basePos)
		local ang           = math.random() * math.pi * 2

		table.insert(tents, {
			segs        = segs,
			tip         = tip,
			base        = basePos,
			-- Stagger the six eruptions across the first ~60% of the strike window
			emergeDelay = (k - 1) / n * (HOLD_T * 0.55) + math.random() * 0.12,
			seed        = math.random() * 100,
			strikeDir   = Vector3.new(math.cos(ang), 0, math.sin(ang)),
			dirtHost    = host,
			dirt        = makeDirtEmitter(host),
			erupted     = false,
		})
	end

	-- A single low rumble at the cluster centroid
	do
		local p          = Instance.new("Part")
		p.Anchored       = true; p.CanCollide = false; p.Transparency = 1
		p.Size           = Vector3.new(1, 1, 1)
		p.Position       = Vector3.new(cx / n, positions[1].Y, cz / n)
		p.Parent         = workspace
		local s          = Instance.new("Sound")
		s.SoundId        = ERUPT_SND_ID
		s.PlaybackSpeed  = 0.5 + math.random() * 0.15
		s.Volume         = 0.8
		s.RollOffMaxDistance = 110
		s.RollOffMinDistance = 10
		s.RollOffMode    = Enum.RollOffMode.Linear
		s.Parent         = p
		s:Play()
		s.Ended:Once(function() p:Destroy() end)
	end

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= T_LIFE then
			conn:Disconnect()
			for _, tn in tents do
				for _, sg in tn.segs do if sg.Parent then sg:Destroy() end end
				if tn.tip.Parent then tn.tip:Destroy() end
				if tn.dirtHost.Parent then tn.dirtHost:Destroy() end
			end
			return
		end

		for _, tn in tents do
			local localT = elapsed - tn.emergeDelay

			-- Emergence fraction: 0 → 1 on rise, hold, then 1 → 0 on retreat
			local emerge: number
			if localT < 0 then
				emerge = 0
			elseif localT < T_EMERGE then
				emerge = smoothstep(localT / T_EMERGE)
			elseif elapsed < T_RETREAT_AT then
				emerge = 1
			else
				emerge = 1 - smoothstep((elapsed - T_RETREAT_AT) / T_RETREAT)
			end

			-- Dirt burst + visibility toggle the moment it breaks the surface
			if emerge > 0 and not tn.erupted then
				tn.erupted = true
				tn.dirt:Emit(math.random(7, 12))
			end
			local hidden = emerge <= 0.001
			for _, sg in tn.segs do sg.Transparency = if hidden then 1 else 0 end
			tn.tip.Transparency = if hidden then 1 else 0
			if hidden then continue end

			-- A quick whipping strike just after the tentacle clears the ground
			local strikeAmt = 0
			if localT >= T_EMERGE and localT < T_EMERGE + T_STRIKE then
				strikeAmt = math.sin((localT - T_EMERGE) / T_STRIKE * math.pi)
			end

			-- Build the wiggly column of spine points from base → tip
			local cpts: { Vector3 } = {}
			for j = 0, T_NSEG do
				local sj    = j / T_NSEG
				local h     = emerge * T_H * sj
				local wob   = math.sin(elapsed * T_WFREQ + tn.seed + sj * T_WK) * T_WAMP * sj * emerge
				local wob2  = math.cos(elapsed * T_WFREQ * 1.27 + tn.seed) * T_WAMP * 0.7 * sj * emerge
				local lean  = strikeAmt * 1.7 * sj
				cpts[j + 1] = tn.base
					+ Vector3.new(wob, h, wob2)
					+ tn.strikeDir * lean
			end
			for j = 1, T_NSEG do
				orientYBetween(tn.segs[j], cpts[j], cpts[j + 1], T_THICK[j])
			end
			-- Pointed tip
			local d = T_THICK[T_NSEG] * 0.9
			tn.tip.Size   = Vector3.new(d, d * 1.6, d)
			tn.tip.CFrame = CFrame.new(cpts[T_NSEG + 1])
		end
	end)
end

return HagfishBody
