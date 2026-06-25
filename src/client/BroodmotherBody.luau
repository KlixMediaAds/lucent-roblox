-- BroodmotherBody.luau
-- Client-only procedural body + animation for the towering Broodmother unit.
-- Architecture mirrors LampreyBody / HagfishBody: one shared RenderStepped loop, a
-- distance cull, a speed-proportional animation clock, and parts tagged with a
-- "UnitId" attribute so FogManager can hide them for enemy units in the fog.
--
-- The server spawns the Broodmother as an invisible, ground-snapped pivot block
-- (size 11×20×11, so its centre sits 10 studs above the terrain). Everything you
-- see is drawn here: a lumpy sea-anemone mass riding atop three tentacle legs,
-- fang clusters ringing the mass (each maw facing its own way), a crown of swaying
-- tendrils, and — when it attacks — a swarm of glowing orbs that spit from the
-- tendrils and orbit the creature.
--
-- Attack: when the server fires a "Broodmother" UnitHit the tendrils glow and a
-- swarm of orbs forms over ORB_CHARGE seconds, orbits for ORB_ACTIVE seconds, then
-- scatters and fades over ORB_SCATTER. Death (BroodmotherDeath remote → trigger
-- DeathNear): the mass drops, splits along an exposed ribcage, drops three egg
-- sacs and sinks into the ground.
--!strict

local RunService = game:GetService("RunService")

local BroodmotherBody = {}

-- ── Geometry (raw studs at scale 1; multiplied by `sc` each frame) ──────────────
local BASE_HEIGHT = 20.0   -- must equal Config.UNIT_TYPES.Broodmother.size.Y
local MASS_H      = 13.0   -- mass-centre height above the ground
local MASS_R      = 4.2    -- mass radius
local MASS_SIZE   = Vector3.new(MASS_R * 2, MASS_R * 1.8, MASS_R * 2)

local N_LEG    = 3
local N_LSEG   = 3         -- segments per leg (spine has N_LSEG + 1 points)
local L_THICK  = { 1.8, 1.3, 0.8 }
local FOOT_R   = 7.0       -- horizontal splay radius of the planted feet
local KNEE_OUT = 2.6       -- how far the knee bows outward from the hip→foot line
local KNEE_LIFT = 3.6
local STEP_LEN = 2.4       -- forward stride travel per step (scaled by speed)
local STEP_H   = 2.2       -- foot lift height per step (scaled by speed)
local STRIDE_FREQ = 1.05   -- gait cycles/sec at full speed

local NMAW    = 5          -- fang clusters around the mass
local NTEETH  = 5          -- fangs per cluster
local NTEN    = 8          -- crown tendrils
local N_TSEG  = 3          -- segments per tendril
local TEN_LEN = 5.2        -- tendril reach
local NORB    = 14         -- glowing orbs in the attack swarm (Config.BROODMOTHER_ORB_COUNT)
local ORB_SIZE = 1.35

-- ── Attack timeline (seconds; mirror Config.BROODMOTHER_*) ──────────────────────
local ORB_CHARGE  = 4.0
local ORB_ACTIVE  = 5.0
local ORB_SCATTER = 1.2
local ORB_TOTAL   = ORB_CHARGE + ORB_ACTIVE + ORB_SCATTER
local ORB_EMERGE  = 1.4    -- per-orb rise-out duration during the charge

-- ── Death timeline (seconds; sums to Config.BROODMOTHER_DEATH_DURATION = 10.2) ──
-- Impact (slam down + ribcage/egg burst) → hold (gored on the ground) → sink →
-- the eggs rest a final HATCH stretch before the server swaps them for Lampreys.
local DEATH_IMPACT = 1.0
local DEATH_HOLD   = 5.0
local DEATH_SINK   = 1.2
local DEATH_HATCH  = 3.0
local DEATH_DUR    = DEATH_IMPACT + DEATH_HOLD + DEATH_SINK + DEATH_HATCH

local FULL_SPEED = 8.0     -- matches Config.UNIT_MOVE_SPEED.Broodmother
local SWAY_FREQ  = 0.7

local CULL_SQ = 320 * 320

-- ── Colours ─────────────────────────────────────────────────────────────────--
local C_BODY  = Color3.fromRGB(46, 40, 60)    -- deep purple-slate flesh
local C_LEG   = Color3.fromRGB(38, 33, 50)
local C_TOOTH = Color3.fromRGB(228, 222, 232)
local C_MAW   = Color3.fromRGB(120, 24, 60)
local C_EYE   = Color3.fromRGB(150, 240, 200)
local C_RIB   = Color3.fromRGB(214, 206, 198)
local C_EGG   = Color3.fromRGB(150, 230, 90)  -- Lamprey-egg green
local C_ORB   = Color3.fromRGB(255, 224, 90)  -- glowing yellow attack orbs (+ tendril tips)

-- ── Helpers ─────────────────────────────────────────────────────────────────--
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

-- Vector3 lerp (named to avoid clashing with the scalar `lerp`)
local function lerp3(a: Vector3, b: Vector3, t: number): Vector3
	return a + (b - a) * t
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type OrbData = { ang0: number, radius: number, height: number, spin: number, stagger: number }

type Entry = {
	body:        BasePart,
	mass:        BasePart,
	lumps:       { BasePart },
	eyes:        { BasePart },
	legSegs:     { BasePart },   -- N_LEG * N_LSEG
	legKnuckles: { BasePart },   -- N_LEG * (N_LSEG - 1)
	feet:        { BasePart },   -- N_LEG foot pads
	mawSockets:  { BasePart },
	teeth:       { BasePart },   -- NMAW * NTEETH
	mawDirs:     { Vector3 },    -- local maw directions
	tenSegs:     { BasePart },   -- NTEN * N_TSEG
	tenTips:     { BasePart },
	tenDirs:     { Vector3 },    -- local tendril root directions
	orbs:        { BasePart },
	orbData:     { OrbData },
	-- death tableau (created hidden at attach)
	halves:      { BasePart },   -- 2 mass halves
	ribs:        { BasePart },   -- 6 rib arcs
	eggs:        { BasePart },   -- 3 egg sacs
	-- animation state
	walkClock:   number,
	swayClock:   number,
	lastPos:     Vector3?,
	smoothSpeed: number,
	attackActive: boolean,
	attackT:     number,
	dying:       boolean,
	deathT:      number,
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

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function BroodmotherBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local mass = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)

	local lumps: { BasePart } = {}
	for _ = 1, 4 do table.insert(lumps, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)) end

	local eyes: { BasePart } = {}
	for _ = 1, 2 do table.insert(eyes, makePart(unitId, C_EYE, Enum.Material.Neon, Enum.PartType.Ball)) end

	local legSegs:     { BasePart } = {}
	local legKnuckles: { BasePart } = {}
	local feet:        { BasePart } = {}
	for _ = 1, N_LEG do
		for _ = 1, N_LSEG do table.insert(legSegs, makePart(unitId, C_LEG, Enum.Material.SmoothPlastic)) end
		for _ = 1, N_LSEG - 1 do table.insert(legKnuckles, makePart(unitId, C_LEG, Enum.Material.SmoothPlastic, Enum.PartType.Ball)) end
		table.insert(feet, makePart(unitId, C_LEG, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end

	-- Fang clusters: precompute a spread of local maw directions
	local mawDirs: { Vector3 } = {
		Vector3.new( 1.0,  0.2,  0.3), Vector3.new(-0.8,  0.1,  0.7),
		Vector3.new( 0.2,  0.3, -1.0), Vector3.new(-0.6, -0.3, -0.5),
		Vector3.new( 0.7, -0.4,  0.5),
	}
	for i, d in mawDirs do mawDirs[i] = d.Unit end
	local mawSockets: { BasePart } = {}
	local teeth:      { BasePart } = {}
	for _ = 1, NMAW do
		table.insert(mawSockets, makePart(unitId, C_MAW, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
		for _ = 1, NTEETH do table.insert(teeth, makePart(unitId, C_TOOTH, Enum.Material.SmoothPlastic)) end
	end

	-- Crown tendrils
	local tenDirs: { Vector3 } = {}
	local tenSegs: { BasePart } = {}
	local tenTips: { BasePart } = {}
	for k = 1, NTEN do
		local a = (k / NTEN) * math.pi * 2
		table.insert(tenDirs, Vector3.new(math.cos(a) * 0.6, 0.85, math.sin(a) * 0.6).Unit)
		for _ = 1, N_TSEG do table.insert(tenSegs, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)) end
		local tip = makePart(unitId, C_ORB, Enum.Material.Neon, Enum.PartType.Ball)
		table.insert(tenTips, tip)
	end

	-- Glowing orb swarm (hidden until an attack)
	local orbs:    { BasePart } = {}
	local orbData: { OrbData }  = {}
	local GOLD = 2.399963   -- golden angle, spreads the orbs evenly
	for i = 1, NORB do
		local o = makePart(unitId, C_ORB, Enum.Material.Neon, Enum.PartType.Ball)
		o.Transparency = 1
		table.insert(orbs, o)
		table.insert(orbData, {
			ang0    = i * GOLD,
			radius  = 8 + (i % 5) * 3.2,            -- 8..21 spread
			height  = 3 + ((i * 5) % 7) * 2.1,      -- 3..15 spread
			spin    = (1.1 + (i % 3) * 0.35) * (if i % 2 == 0 then 1 else -1),
			stagger = (i - 1) / NORB * (ORB_CHARGE * 0.6),
		})
	end

	-- Death tableau (hidden until the creature dies)
	local halves: { BasePart } = {}
	for _ = 1, 2 do
		local h = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		h.Transparency = 1
		table.insert(halves, h)
	end
	local ribs: { BasePart } = {}
	for _ = 1, 6 do
		local r = makePart(unitId, C_RIB, Enum.Material.SmoothPlastic)
		r.Transparency = 1
		table.insert(ribs, r)
	end
	local eggs: { BasePart } = {}
	for _ = 1, 3 do
		local e = makePart(unitId, C_EGG, Enum.Material.Neon, Enum.PartType.Ball)
		e.Transparency = 1
		table.insert(eggs, e)
	end

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		BroodmotherBody.detach(unitId)
	end)

	active[unitId] = {
		body         = body,
		mass         = mass,
		lumps        = lumps,
		eyes         = eyes,
		legSegs      = legSegs,
		legKnuckles  = legKnuckles,
		feet         = feet,
		mawSockets   = mawSockets,
		teeth        = teeth,
		mawDirs      = mawDirs,
		tenSegs      = tenSegs,
		tenTips      = tenTips,
		tenDirs      = tenDirs,
		orbs         = orbs,
		orbData      = orbData,
		halves       = halves,
		ribs         = ribs,
		eggs         = eggs,
		walkClock    = phase,
		swayClock    = phase * 1.7,
		lastPos      = nil,
		smoothSpeed  = 0,
		attackActive = false,
		attackT      = 0,
		dying        = false,
		deathT       = 0,
		conn         = conn,
	}
end

function BroodmotherBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	local function killAll(list: { BasePart })
		for _, p in list do if p.Parent then p:Destroy() end end
	end
	killAll(e.lumps); killAll(e.eyes); killAll(e.legSegs); killAll(e.legKnuckles)
	killAll(e.feet); killAll(e.mawSockets); killAll(e.teeth)
	killAll(e.tenSegs); killAll(e.tenTips); killAll(e.orbs)
	killAll(e.halves); killAll(e.ribs); killAll(e.eggs)
	if e.mass.Parent then e.mass:Destroy() end
end

-- Match the nearest active Broodmother to an attack origin and start its orb swarm.
function BroodmotherBody.triggerAttackNear(pos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		if e.dying then continue end
		local d = (e.body.Position - pos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < 40 then
		local e = active[bestId]
		e.attackActive = true
		e.attackT      = 0
	end
end

-- Match the nearest active Broodmother to a death position and start its collapse.
function BroodmotherBody.triggerDeathNear(pos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		if e.dying then continue end
		local d = (e.body.Position - pos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < 40 then
		local e = active[bestId]
		e.dying        = true
		e.deathT       = 0
		e.attackActive = false
		-- Hide the orb swarm immediately
		for _, o in e.orbs do o.Transparency = 1 end
	end
end

-- ── Living layout ───────────────────────────────────────────────────────────--
local function layout(e: Entry, dt: number, speedF: number)
	local body    = e.body
	local cf      = body.CFrame
	local bpos    = body.Position
	local sc      = body.Size.Y / BASE_HEIGHT
	local groundY = bpos.Y - body.Size.Y * 0.5

	local lv  = cf.LookVector
	local fwd = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd          = fwd.Unit
	local right  = fwd:Cross(Vector3.yAxis).Unit
	local centre = Vector3.new(bpos.X, groundY, bpos.Z)

	-- Mass bob + a gentle anemone roll
	local bob     = math.sin(e.walkClock * 2) * 0.5 * sc * speedF + math.sin(e.swayClock) * 0.35 * sc
	local massPos = centre + Vector3.new(0, MASS_H * sc + bob, 0)
	local rollZ   = math.sin(e.swayClock * 0.8) * 0.05
	local massCF  = CFrame.lookAt(massPos, massPos + fwd) * CFrame.Angles(0, 0, rollZ)

	-- Attack glow factor (0 idle → 1 swarm fully lit)
	local glow = 0
	if e.attackActive then
		local t = e.attackT
		if t < ORB_CHARGE then glow = t / ORB_CHARGE
		elseif t < ORB_CHARGE + ORB_ACTIVE then glow = 1
		else glow = math.max(0, 1 - (t - ORB_CHARGE - ORB_ACTIVE) / ORB_SCATTER) end
	end

	-- ── Mass + lumps ───────────────────────────────────────────────────────────
	e.mass.Size   = MASS_SIZE * sc
	e.mass.CFrame = CFrame.new(massPos)
	local lumpOff = {
		Vector3.new( 2.2, 1.4,  1.6), Vector3.new(-2.4, 0.6, -1.2),
		Vector3.new( 0.6, 2.4, -2.2), Vector3.new(-1.4, -1.6, 2.0),
	}
	for i, lp in e.lumps do
		lp.Size   = Vector3.new(3.4, 3.0, 3.4) * sc
		lp.CFrame = massCF * CFrame.new(lumpOff[i] * sc)
	end

	-- ── Eyes ──────────────────────────────────────────────────────────────────
	e.eyes[1].Size   = Vector3.new(0.95, 0.95, 0.95) * sc
	e.eyes[2].Size   = e.eyes[1].Size
	e.eyes[1].CFrame = massCF * CFrame.new(-1.6 * sc, 0.8 * sc, -MASS_R * 0.85 * sc)
	e.eyes[2].CFrame = massCF * CFrame.new( 1.6 * sc, 0.8 * sc, -MASS_R * 0.85 * sc)

	-- ── Three tentacle legs (tripod gait) ─────────────────────────────────────
	for L = 1, N_LEG do
		local ang   = (L - 1) * (math.pi * 2 / 3) + math.pi / 2
		local dir   = right * math.cos(ang) + fwd * math.sin(ang)
		local phase = e.walkClock + (L - 1) * (math.pi * 2 / 3)
		local stride = math.cos(phase) * STEP_LEN * sc * speedF
		local lift   = math.max(0, math.sin(phase)) * STEP_H * sc * speedF
		local foot  = centre + dir * (FOOT_R * sc) + fwd * stride + Vector3.new(0, lift, 0)
		local hip   = massPos + dir * (MASS_R * 0.5 * sc) - Vector3.new(0, MASS_R * 0.4 * sc, 0)
		local knee  = (hip + foot) * 0.5 + dir * (KNEE_OUT * sc) + Vector3.new(0, KNEE_LIFT * sc, 0)
		local ankle = lerp3(knee, foot, 0.6) + dir * (0.6 * sc)
		local pts   = { hip, knee, ankle, foot }
		local base  = (L - 1) * N_LSEG
		for i = 1, N_LSEG do
			orientYBetween(e.legSegs[base + i], pts[i], pts[i + 1], L_THICK[i] * sc)
		end
		local kbase = (L - 1) * (N_LSEG - 1)
		for i = 1, N_LSEG - 1 do
			local d = L_THICK[i + 1] * sc
			e.legKnuckles[kbase + i].Size   = Vector3.new(d, d, d)
			e.legKnuckles[kbase + i].CFrame = CFrame.new(pts[i + 1])
		end
		e.feet[L].Size   = Vector3.new(1.7, 0.9, 2.0) * sc
		e.feet[L].CFrame = CFrame.lookAt(foot, foot + dir)
	end

	-- ── Fang clusters (each maw faces its own way) ────────────────────────────
	local ti = 0
	for m = 1, NMAW do
		local dirW = massCF:VectorToWorldSpace(e.mawDirs[m])
		local mawC = massPos + dirW * (MASS_R * 0.92 * sc)
		e.mawSockets[m].Size   = Vector3.new(1.7, 1.7, 1.1) * sc
		e.mawSockets[m].CFrame = CFrame.lookAt(mawC, mawC + dirW)
		local u = dirW:Cross(Vector3.yAxis)
		u = if u.Magnitude > 0.01 then u.Unit else Vector3.xAxis
		local v = dirW:Cross(u).Unit
		for k = 1, NTEETH do
			ti += 1
			local a    = (k / NTEETH) * math.pi * 2
			local rad  = u * math.cos(a) + v * math.sin(a)
			local base = mawC + rad * (1.0 * sc)
			local tip  = mawC + dirW * (1.2 * sc) + rad * (0.45 * sc)
			orientYBetween(e.teeth[ti], base, tip, 0.34 * sc)
		end
	end

	-- ── Crown tendrils (sway with movement; glow + lift during an attack) ─────
	for k = 1, NTEN do
		local rootDirW = massCF:VectorToWorldSpace(e.tenDirs[k])
		local root     = massPos + rootDirW * (MASS_R * 0.85 * sc)
		local swayAmp  = (0.5 + 0.7 * speedF + 0.6 * glow) * sc
		local pts: { Vector3 } = {}
		for j = 0, N_TSEG do
			local s    = j / N_TSEG
			local sway = (right * math.sin(e.swayClock * 1.6 + k + s * 3.0)
				+ fwd * math.cos(e.swayClock * 1.3 + k * 0.7 + s * 2.4)) * swayAmp * s
			-- Tendrils rear upward as the swarm charges
			local rise = Vector3.new(0, glow * 1.4 * s * sc, 0)
			pts[j + 1] = root + rootDirW * (TEN_LEN * s * sc) + sway + rise
		end
		local tbase = (k - 1) * N_TSEG
		for j = 1, N_TSEG do
			orientYBetween(e.tenSegs[tbase + j], pts[j], pts[j + 1], (0.34 - 0.07 * (j - 1)) * sc)
		end
		local tip = e.tenTips[k]
		local ts  = (0.55 + glow * 0.5) * sc
		tip.Size   = Vector3.new(ts, ts, ts)
		tip.CFrame = CFrame.new(pts[N_TSEG + 1])
	end

	-- ── Orb swarm ──────────────────────────────────────────────────────────────
	if e.attackActive then
		local t        = e.attackT
		local activeEnd = ORB_CHARGE + ORB_ACTIVE
		local crown    = massPos + Vector3.new(0, MASS_R * sc, 0)
		for i = 1, NORB do
			local od  = e.orbData[i]
			local em  = math.clamp((t - od.stagger) / ORB_EMERGE, 0, 1)
			local angle = od.ang0 + t * od.spin
			local rWob  = od.radius + math.sin(t * 1.7 + i) * 1.8
			local hWob  = od.height + math.sin(t * 1.3 + i * 0.7) * 2.4
			local scatter, fade = 0, 0
			if t > activeEnd then
				local sp = math.min((t - activeEnd) / ORB_SCATTER, 1)
				scatter  = sp * 34
				fade     = sp
			end
			local orbitPos = massPos
				+ (right * math.cos(angle) + fwd * math.sin(angle)) * ((rWob + scatter) * sc)
				+ Vector3.new(0, hWob * sc, 0)
			local pos = crown:Lerp(orbitPos, smoothstep(em))
			local sz  = ORB_SIZE * sc * smoothstep(em) * (1 - fade * 0.9)
			local orb = e.orbs[i]
			orb.Size         = Vector3.new(sz, sz, sz)
			orb.CFrame       = CFrame.new(pos)
			orb.Transparency = if em < 0.02 then 1 else fade
		end
	end
end

-- ── Death layout: collapse → split (ribcage) → drop eggs → sink ────────────────
local function layoutDeath(e: Entry, dt: number)
	e.deathT += dt
	local body    = e.body
	local sc      = body.Size.Y / BASE_HEIGHT
	local bpos    = body.Position
	local groundY = bpos.Y - body.Size.Y * 0.5
	local lv      = body.CFrame.LookVector
	local fwd     = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd          = fwd.Unit
	local right  = fwd:Cross(Vector3.yAxis).Unit
	local centre = Vector3.new(bpos.X, groundY, bpos.Z)

	-- Absolute-time phases: a fast slam + ribcage/egg burst, a long gored hold, then
	-- the corpse sinks (the eggs stay behind and rest until the server hatches them).
	local t        = e.deathT
	local holdEnd  = DEATH_IMPACT + DEATH_HOLD
	local collapse = smoothstep(math.min(t / (DEATH_IMPACT * 0.45), 1))                -- mass slams down
	local split    = smoothstep(math.clamp((t - DEATH_IMPACT * 0.30) / (DEATH_IMPACT * 0.70), 0, 1))  -- mass tears open
	local sink     = smoothstep(math.clamp((t - holdEnd) / DEATH_SINK, 0, 1))          -- corpse sinks after the hold

	local massY    = lerp(MASS_H, 2.6, collapse) * sc - sink * (7 * sc)
	local massPos  = centre + Vector3.new(0, massY, 0)
	local massCF   = CFrame.lookAt(massPos, massPos + fwd)

	-- Hide the living detail that has no place in the corpse
	local function hide(list: { BasePart }) for _, q in list do q.Transparency = 1 end end
	hide(e.eyes); hide(e.mawSockets); hide(e.teeth)
	hide(e.tenSegs); hide(e.tenTips); hide(e.orbs)

	-- Main mass shrinks as it tears in half
	local mainScale = 1 - split
	local massHidden = mainScale < 0.05
	e.mass.Transparency = if massHidden then 1 else 0
	if not massHidden then
		e.mass.Size   = MASS_SIZE * sc * math.max(0.05, mainScale)
		e.mass.CFrame = CFrame.new(massPos)
	end
	local lumpOff = {
		Vector3.new( 2.2, 1.4,  1.6), Vector3.new(-2.4, 0.6, -1.2),
		Vector3.new( 0.6, 2.4, -2.2), Vector3.new(-1.4, -1.6, 2.0),
	}
	for i, lp in e.lumps do
		lp.Transparency = if massHidden then 1 else 0
		if not massHidden then
			lp.Size   = Vector3.new(3.4, 3.0, 3.4) * sc * math.max(0.05, mainScale)
			lp.CFrame = massCF * CFrame.new(lumpOff[i] * sc * math.max(0.2, mainScale))
		end
	end

	-- Two halves spread apart and slump, then sink
	local spread = split * 3.4 * sc
	for s = 1, 2 do
		local sgn  = if s == 1 then -1 else 1
		local half = e.halves[s]
		local vis  = split > 0.04 and sink < 0.99
		half.Transparency = if vis then math.max(1 - split, sink) else 1
		if vis then
			half.Size   = Vector3.new(MASS_R * 1.5, MASS_R * 1.7, MASS_R * 1.9) * sc
			half.CFrame = massCF * CFrame.new(sgn * spread, -sink * 4 * sc, 0) * CFrame.Angles(0, 0, sgn * split * 0.6)
		end
	end

	-- Exposed ribcage: arching ribs between the halves, rising as it splits
	for i = 1, #e.ribs do
		local rib = e.ribs[i]
		local vis = split > 0.06 and sink < 0.99
		rib.Transparency = if vis then math.max(1 - split, sink) else 1
		if vis then
			local f     = (i - 0.5) / #e.ribs            -- 0 front → 1 back
			local along = (f - 0.5) * 2 * (MASS_R * 1.15) * sc
			local sideArc = (1 - math.abs(f - 0.5) * 2) * MASS_R * 0.9 * sc
			local baseY = massY - MASS_R * 0.5 * sc - sink * 5 * sc
			local ribBase = centre + fwd * along + Vector3.new(0, baseY, 0)
			local ribTop  = ribBase + Vector3.new(0, (MASS_R * 1.5) * split * sc, 0) + fwd * (along * 0.1)
			orientYBetween(rib, ribBase, ribTop, 0.3 * sc)
			-- bow the rib outward a touch by widening toward the middle
			rib.Size = Vector3.new(0.3 * sc, (ribTop - ribBase).Magnitude, 0.3 * sc + sideArc * 0.04)
		end
	end

	-- Legs go limp: hips drop to the slumping mass, feet stay splayed, fade as it sinks
	for L = 1, N_LEG do
		local ang  = (L - 1) * (math.pi * 2 / 3) + math.pi / 2
		local dir  = right * math.cos(ang) + fwd * math.sin(ang)
		local foot = centre + dir * (FOOT_R * 1.1 * sc)
		local hip  = massPos + dir * (MASS_R * 0.4 * sc) - Vector3.new(0, MASS_R * 0.3 * sc, 0)
		local mid  = lerp3(hip, foot, 0.5) + Vector3.new(0, (1 - collapse) * 1.5 * sc, 0)
		local pts  = { hip, mid, foot, foot }
		local base = (L - 1) * N_LSEG
		for i = 1, N_LSEG do
			local seg = e.legSegs[base + i]
			seg.Transparency = sink
			orientYBetween(seg, pts[i], pts[i + 1], L_THICK[i] * sc)
		end
		local kbase = (L - 1) * (N_LSEG - 1)
		for i = 1, N_LSEG - 1 do
			e.legKnuckles[kbase + i].Transparency = sink
			local d = L_THICK[i + 1] * sc
			e.legKnuckles[kbase + i].Size   = Vector3.new(d, d, d)
			e.legKnuckles[kbase + i].CFrame = CFrame.new(pts[i + 1])
		end
		e.feet[L].Transparency = sink
		e.feet[L].Size   = Vector3.new(1.7, 0.9, 2.0) * sc
		e.feet[L].CFrame = CFrame.lookAt(foot, foot + dir)
	end

	-- Three egg sacs burst from the wreckage during the impact, land around the
	-- corpse and rest there (gently breathing) right up until the server hatches
	-- them into Lampreys — they never sink with the body.
	for k = 1, 3 do
		local egg = e.eggs[k]
		local ep  = smoothstep(math.clamp((t - DEATH_IMPACT * 0.35) / (DEATH_IMPACT * 0.6), 0, 1))
		if ep <= 0.02 then
			egg.Transparency = 1
		else
			local a    = (k / 3) * math.pi * 2 + math.pi / 4
			local land = centre + Vector3.new(math.cos(a) * 5.5 * sc, 1.9 * sc, math.sin(a) * 5.5 * sc)
			local start = centre + Vector3.new(0, math.max(massY, 3 * sc), 0)
			local arc  = math.sin(ep * math.pi) * 3.5 * sc
			local pulse = if ep >= 1 then 1 + math.sin(t * 3 + k) * 0.06 else 1   -- incubation breathing once landed
			egg.Transparency = 0
			egg.Size   = Vector3.new(3, 3.6, 3) * 0.7 * sc * pulse
			egg.CFrame = CFrame.new(start:Lerp(land, ep) + Vector3.new(0, arc, 0))
		end
	end
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function BroodmotherBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_BroodmotherBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				BroodmotherBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then continue end

			if e.dying then
				layoutDeath(e, dt)
				continue
			end

			-- Speed estimate from frame-to-frame movement (parts are anchored)
			local last      = e.lastPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.lastPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.08
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Advance clocks
			e.walkClock += dt * (0.35 + speedF) * STRIDE_FREQ * math.pi * 2
			e.swayClock += dt * SWAY_FREQ * math.pi * 2

			-- Advance the attack timeline
			if e.attackActive then
				e.attackT += dt
				if e.attackT >= ORB_TOTAL then
					e.attackActive = false
					for _, o in e.orbs do o.Transparency = 1 end
				end
			end

			layout(e, dt, speedF)
		end
	end)
end

return BroodmotherBody
