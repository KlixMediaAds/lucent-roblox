-- LeechBody.luau
-- Client-only procedural body for the Leech: a worm-like body that lies SIDEWAYS along
-- the ground (head at the front, tapering tail behind), inching + slithering as it
-- crawls, with a distinct rounded head. Same clean opaque tapering-segment style as the
-- Lamprey/Hagfish bodies — no ball joints along the spine. Architecture mirrors
-- LampreyBody: one shared RenderStepped loop, a distance cull, a speed-proportional
-- animation clock, and parts tagged with a "UnitId" attribute so FogManager can hide
-- them for enemy leeches in the fog.
--
-- The server spawns the Leech as an invisible, ground-snapped pivot block (size
-- 4×3×5). The visible body is drawn here; burrowing is handled server-side (the pivot
-- sinks), so the body simply follows it down.
--!strict

local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

local LeechBody = {}

-- Fire a one-shot spatial sound at a world position (self-cleaning).
local function playSoundAt(pos: Vector3, id: string, volume: number)
	local p      = Instance.new("Part")
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.Transparency = 1
	p.Size       = Vector3.new(1, 1, 1)
	p.Position   = pos
	p.Parent     = workspace
	local s               = Instance.new("Sound")
	s.SoundId             = id
	s.Volume              = volume
	s.RollOffMaxDistance  = 90
	s.RollOffMinDistance  = 8
	s.RollOffMode         = Enum.RollOffMode.Linear
	s.Parent              = p
	s:Play()
	s.Ended:Once(function() p:Destroy() end)
	Debris:AddItem(p, 6)   -- safety net if the asset fails to load / Ended never fires
end

-- ── Geometry ──────────────────────────────────────────────────────────────────
local N_SEG    = 7                 -- body segments (spine has N_SEG + 1 points)
local BODY_LEN = 7.5               -- ground length of the leech (head → tail)
local HEAD_FWD = 3.4               -- head's forward offset from the pivot centre
-- Tube thickness at each of the N_SEG+1 spine points (head → tail taper)
local THICK    = { 1.4, 1.5, 1.4, 1.2, 0.95, 0.7, 0.48, 0.28 }
local HEAD_SIZE = Vector3.new(1.7, 1.5, 2.1)  -- rounded head, slightly elongated front-to-back
local EYE_SIZE  = Vector3.new(0.3, 0.3, 0.3)

-- Must equal Config.UNIT_TYPES.Leech.size.Y. The leech doesn't grow, so scale ≈ 1,
-- but we keep the same derivation as the other body animators.
local BASE_HEIGHT = 3.0

-- ── Motion ────────────────────────────────────────────────────────────────────
local FULL_SPEED  = 18.0           -- matches Config.UNIT_MOVE_SPEED.Leech
local SLITHER_FREQ = 1.8           -- lateral slither cycles/sec baseline
local LAT_K       = math.pi * 1.5  -- slither waves along the body length
local LAT_AMP     = 1.7            -- side-to-side slither amplitude
local HUMP_AMP    = 1.0            -- inch-worm vertical hump height (only while crawling)
local HUMP_K      = math.pi * 2.0  -- humps along the body length
local HEAD_RISE   = 1.3            -- how far the head lifts off the ground (sensing)
local IDLE_FREQ   = 0.85           -- head sway cycles/sec
local IDLE_SWAY   = 0.45           -- idle head side-to-side sway

-- ── Burrowed posture — a leech latched on to feed: both suckers pressed into the
-- ground with the body arched up between them like a rainbow (not a flat sink). ──────
local BURROW_EASE       = 4.5      -- how quickly the body eases into / out of the burrow pose
local ARCH_HEIGHT       = 5.0      -- peak height of the arched midsection
local ARCH_SPAN         = 6.8      -- ground distance from the planted tail to the head anchor
local ARCH_END_LATCH    = 0.35     -- how far the mouth / tail suckers press into the ground
local ARCH_BREATHE_AMP  = 0.4      -- subtle idle swell of the arch while latched
local ARCH_BREATHE_FREQ = 0.9      -- breaths/sec of the arch

-- ── Anchoring — before it plants its head to feed, the leech rears up onto its tail
-- and holds its head in the air, questing, for a short random moment before committing. ─
local STAND_HEIGHT     = 6.2       -- head height while reared up and questing (pre-anchor)
local STAND_REACH      = 1.2       -- slight forward lean of the reared body
local SEARCH_SWAY      = 1.4       -- side-to-side head sway while it decides where to anchor
local ANCHOR_EASE      = 4.0       -- how smoothly the head lowers to plant once it commits
local ANCHOR_DELAY_MIN = 0.5       -- min seconds head-up before anchoring
local ANCHOR_DELAY_MAX = 3.0       -- max seconds head-up before anchoring

-- ── Harvest (feeding) — plays on each burrowed income tick. A bolus of drawn blood
-- swells at the mouth and pumps along the arched body to the tail, inflating each
-- section as it passes (a peristaltic, bodily inflation). Amplitude rides a smooth
-- 0→1→0 envelope so it fades in and out with no snap. ────────────────────────────────
local HARVEST_DUR  = 2.0           -- seconds one pump takes to travel mouth → tail
local BOLUS_AMP    = 1.15          -- extra body thickness at the crest of the travelling bulge
local BOLUS_WIDTH  = 0.22          -- half-width of the bulge along the body (in s units)
local BOLUS_MARGIN = 0.28          -- how far the bulge starts/ends off the body ends (smooth entry/exit)
local SUCK_DIP     = 0.4           -- how far the mouth pulls the head-end down while drawing

-- Sounds. The feeding pump plays a single wet suck; the dirt shift is now the burrow
-- cue, played when the leech digs in / pulls out (see the RenderStepped loop).
local HARVEST_SND_ID = "rbxassetid://9125703168"
local BURROW_SND_ID  = "rbxassetid://139990035476921"
-- Played the moment the reared-up leech lowers its head and plants it into the ground
-- at the end of the burrow/anchor animation (the "heads touch the ground" cue).
local ANCHOR_SND_ID  = "rbxassetid://9125892982"

local CULL_SQ = 300 * 300

-- ── Colours ───────────────────────────────────────────────────────────────────
local C_BODY = Color3.fromRGB(66, 34, 38)   -- dark blood-maroon (opaque)
local C_EYE  = Color3.fromRGB(190, 80, 64)  -- faint eye specks

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

-- A random horizontal unit direction — the way the leech reaches out to plant its head
-- (the far anchor of the arch) when it digs in.
local function randomHorizDir(): Vector3
	local a = math.random() * math.pi * 2
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Entry = {
	body:        BasePart,
	segs:        { BasePart },
	head:        BasePart,
	eyes:        { BasePart },
	feedHost:    BasePart,
	feed:        ParticleEmitter,
	rise:        ParticleEmitter,
	prevPos:     Vector3?,
	animClock:   number,
	idleClock:   number,
	smoothSpeed: number,
	harvestActive: boolean,
	harvestT:      number,
	harvestEmitted: boolean,
	burrowBlend:   number,
	anchorBlend:   number,
	anchorDelay:   number,
	anchorPlanted: boolean,   -- head-plant sound already played for the current burrow
	burrowTime:    number,
	archClock:     number,
	wasBurrowed:   boolean,
	archDir:       Vector3,
	conn:        RBXScriptConnection,
}

local active: { [string]: Entry } = {}
local folder: Folder
local camera: Camera

-- ── Part factory ────────────────────────────────────────────────────────────--
local function makePart(unitId: string, col: Color3, mat: Enum.Material, shape: Enum.PartType?): BasePart
	local p      = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Color      = col
	p.Material   = mat
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.CastShadow = false
	p.Size       = Vector3.new(0.2, 0.2, 0.2)
	p:SetAttribute("UnitId", unitId)
	p.Parent     = folder
	return p
end

-- A short reddish "feeding" mist that puffs up around the head as it draws blood.
local function makeFeedEmitter(host: BasePart): ParticleEmitter
	local pe          = Instance.new("ParticleEmitter")
	pe.Texture        = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color          = ColorSequence.new(Color3.fromRGB(120, 30, 36), Color3.fromRGB(60, 20, 24))
	pe.LightEmission   = 0
	pe.LightInfluence = 1
	pe.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.4),
		NumberSequenceKeypoint.new(0.5, 1.0),
		NumberSequenceKeypoint.new(1,   1.5),
	})
	pe.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	pe.Lifetime       = NumberRange.new(0.4, 0.8)
	pe.Speed          = NumberRange.new(2, 5)
	pe.SpreadAngle    = Vector2.new(40, 40)
	pe.Acceleration   = Vector3.new(0, -6, 0)
	pe.Rotation       = NumberRange.new(0, 360)
	pe.RotSpeed       = NumberRange.new(-60, 60)
	pe.Rate           = 0                         -- burst-only via :Emit
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Parent         = host
	return pe
end

-- Thin, radiant gold→white streaks that shoot up quickly on each harvest — the
-- "soul" of the drawn blood ascending. Tight spread + high speed + a taper to a
-- point makes each mote read as a slender rising streak; LightEmission makes them
-- glow additively so it looks angelic and rich rather than dusty.
local function makeRiseEmitter(host: BasePart): ParticleEmitter
	local pe          = Instance.new("ParticleEmitter")
	pe.Texture        = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color          = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 245, 205)),  -- warm candlelit gold
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 226, 150)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(255, 255, 255)),  -- to pure white at the crest
	})
	pe.LightEmission  = 1        -- fully additive → radiant, not smoky
	pe.LightInfluence = 0        -- ignore world lighting; always bright
	pe.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0,    0.45),
		NumberSequenceKeypoint.new(0.15, 0.26),
		NumberSequenceKeypoint.new(1,    0),      -- taper to a slim point (the "streak" tail)
	})
	pe.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0,    1.0),    -- flick in
		NumberSequenceKeypoint.new(0.12, 0.1),
		NumberSequenceKeypoint.new(0.75, 0.35),
		NumberSequenceKeypoint.new(1,    1.0),    -- dissolve at the top
	})
	pe.Lifetime       = NumberRange.new(0.45, 0.75)
	pe.Speed          = NumberRange.new(15, 22)   -- quick ascent
	pe.Drag           = 3.5                        -- ease off as they climb → streak then settle
	pe.SpreadAngle    = Vector2.new(7, 7)          -- tight column so they stay slender & vertical
	pe.Acceleration   = Vector3.new(0, 5, 0)       -- keep drifting upward as they fade
	pe.Rotation       = NumberRange.new(0, 0)
	pe.RotSpeed       = NumberRange.new(0, 0)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Rate           = 0                          -- burst-only via :Emit
	pe.Parent         = host
	return pe
end

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function LeechBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local segs: { BasePart } = {}
	for _ = 1, N_SEG do table.insert(segs, makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)) end

	local head = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	head.Size  = HEAD_SIZE

	local eyes: { BasePart } = {}
	for _ = 1, 2 do
		local e = makePart(unitId, C_EYE, Enum.Material.Neon, Enum.PartType.Ball)
		e.Size  = EYE_SIZE
		table.insert(eyes, e)
	end

	local feedHost = makePart(unitId, C_BODY, Enum.Material.SmoothPlastic)
	feedHost.Transparency = 1
	local feed = makeFeedEmitter(feedHost)
	local rise = makeRiseEmitter(feedHost)

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	-- The Burrowed flag only exists after the first toggle; seed the posture from it so a
	-- leech that is already burrowed when it comes into view doesn't re-play the dig cue.
	local bv0 = body:FindFirstChild("Burrowed") :: BoolValue?
	local b0  = bv0 ~= nil and bv0.Value == true

	local conn = body.Destroying:Connect(function()
		LeechBody.detach(unitId)
	end)

	active[unitId] = {
		body           = body,
		segs           = segs,
		head           = head,
		eyes           = eyes,
		feedHost       = feedHost,
		feed           = feed,
		rise           = rise,
		prevPos        = nil,
		animClock      = phase,
		idleClock      = phase * 1.4,
		smoothSpeed    = 0,
		harvestActive  = false,
		harvestT       = 0,
		harvestEmitted = false,
		burrowBlend    = b0 and 1 or 0,
		anchorBlend    = b0 and 1 or 0,    -- already-burrowed leeches start planted
		anchorDelay    = ANCHOR_DELAY_MIN + math.random() * (ANCHOR_DELAY_MAX - ANCHOR_DELAY_MIN),
		anchorPlanted  = b0,   -- already-planted leeches shouldn't re-fire the cue
		burrowTime     = b0 and 999 or 0,
		archClock      = phase,
		wasBurrowed    = b0,
		archDir        = randomHorizDir(),
		conn           = conn,
	}
end

-- Kick off the feeding/harvest animation on a leech (fired by the server each time a
-- burrowed leech pays out income).
function LeechBody.triggerHarvest(unitId: string)
	local e = active[unitId]
	if not e then return end
	e.harvestActive  = true
	e.harvestT       = 0
	e.harvestEmitted = false
end

function LeechBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, p in e.segs do if p.Parent then p:Destroy() end end
	for _, p in e.eyes do if p.Parent then p:Destroy() end end
	if e.head.Parent then e.head:Destroy() end
	if e.feedHost.Parent then e.feedHost:Destroy() end
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
local function layout(e: Entry, speedF: number)
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

	-- Harvest envelope (0→1→0 over HARVEST_DUR): drives the mouth suck-dip and the feed
	-- puff. The raw progress (bolusC) drives the blood bolus travelling head→tail.
	local hv = 0
	if e.harvestActive then
		hv = math.sin(math.clamp(e.harvestT / HARVEST_DUR, 0, 1) * math.pi)
	end
	local bl = e.burrowBlend                                             -- 0 crawl → 1 burrow pose
	local an = e.anchorBlend                                             -- 0 head-up questing → 1 planted

	-- Blood-bolus centre travels from just off the mouth to just past the tail; its
	-- amplitude rides a smooth 0→1→0 envelope so the pump fades in and out with no snap.
	local bolusC, bolusEnv = -1, 0
	if e.harvestActive then
		local p  = math.clamp(e.harvestT / HARVEST_DUR, 0, 1)
		bolusC   = -BOLUS_MARGIN + p * (1 + 2 * BOLUS_MARGIN)
		bolusEnv = math.sin(p * math.pi)
	end

	-- archDir is where it reaches out to plant its head; aRight is the sway axis.
	local aDir   = e.archDir
	local aRight = Vector3.new(-aDir.Z, 0, aDir.X)

	-- ── Build spine points along the ground (head index 1 → tail index N_SEG+1) ──
	local pts: { Vector3 } = {}
	for i = 0, N_SEG do
		local s     = i / N_SEG
		local along = HEAD_FWD - s * BODY_LEN            -- +fwd at head, −fwd at tail
		local restY = THICK[i + 1] * 0.5

		-- Crawling profile: the head lifts to sense and a travelling hump inch-worms the body.
		local headLift = HEAD_RISE * (1 - s) * (1 - s)
		local hump     = HUMP_AMP * speedF * math.max(0, math.sin(e.animClock - s * HUMP_K))
		local crawlY   = restY + headLift + hump
		local lat      = math.sin(e.animClock - s * LAT_K) * LAT_AMP * (0.4 + 0.6 * speedF)
		local sway     = math.sin(e.idleClock) * IDLE_SWAY * (1 - s)
		local crawlHoriz = fwd * (along * sc) + right * ((lat + sway) * sc)

		-- Questing profile: reared up on the planted tail, head high and swaying while it
		-- decides where to anchor (barely any horizontal reach yet).
		local searchY     = restY + STAND_HEIGHT * (1 - s)
		local searchHoriz = aDir   * (STAND_REACH * (1 - s) * sc)
			+ aRight * (SEARCH_SWAY * (1 - s) * math.sin(e.archClock * 1.6) * sc)

		-- Anchored profile: a rainbow arch — head planted ARCH_SPAN away along aDir, both
		-- suckers pressed to the ground, midsection raised, with a breathing swell and, while
		-- feeding, a mouth suck-dip.
		local archUp      = math.sin(math.pi * s)                        -- 0 at both ends, 1 mid
		local breathe     = ARCH_BREATHE_AMP * archUp * math.sin(e.archClock)
		local suck        = hv * SUCK_DIP * (1 - s) * (1 - s)
		local anchoredY   = restY + ARCH_HEIGHT * archUp - ARCH_END_LATCH * (1 - archUp) + breathe - suck
		local anchoredHoriz = aDir * (ARCH_SPAN * (1 - s) * sc)          -- head out, tail at pivot

		-- Burrow pose = quest → anchored (anchorBlend); final = crawl → burrow (burrowBlend).
		local burrowY     = searchY + (anchoredY - searchY) * an
		local burrowHoriz = searchHoriz + (anchoredHoriz - searchHoriz) * an
		local height      = crawlY + (burrowY - crawlY) * bl
		local horiz       = crawlHoriz + (burrowHoriz - crawlHoriz) * bl

		pts[i + 1] = centre + horiz + Vector3.new(0, height * sc, 0)
	end

	-- ── Tapering opaque segments (no ball joints along the spine) ─────────────
	-- While feeding, a bolus of blood pumps head→tail, swelling the body it passes through.
	for i = 1, N_SEG do
		local sm    = (i - 0.5) / N_SEG
		local bulge = 0
		if bolusEnv > 0 then
			local d = (sm - bolusC) / BOLUS_WIDTH
			bulge   = BOLUS_AMP * bolusEnv * math.exp(-d * d)
		end
		local t = ((THICK[i] + THICK[i + 1]) * 0.5 + bulge) * sc
		orientYBetween(e.segs[i], pts[i], pts[i + 1], t)
	end

	-- ── Head at the front, facing the way the leech is heading ────────────────
	local headPos = pts[1]
	local headDir = (pts[1] - pts[2])
	headDir = if headDir.Magnitude > 0.01 then headDir.Unit else fwd
	local headCF  = CFrame.lookAt(headPos, headPos + headDir)  -- LookVector (−Z) = headDir
	-- The head swells as the bolus first forms at the mouth (bolusC near 0).
	local headSwell = (bolusEnv > 0) and (BOLUS_AMP * 0.5 * bolusEnv * math.exp(-(bolusC / BOLUS_WIDTH) ^ 2)) or 0
	e.head.Size   = (HEAD_SIZE + Vector3.new(headSwell, headSwell, headSwell)) * sc
	e.head.CFrame = headCF

	-- Two small eye specks on top of the head, near the front.
	e.eyes[1].Size   = EYE_SIZE * sc
	e.eyes[2].Size   = EYE_SIZE * sc
	e.eyes[1].CFrame = headCF * CFrame.new(-0.5 * sc, 0.5 * sc, -0.55 * sc)
	e.eyes[2].CFrame = headCF * CFrame.new( 0.5 * sc, 0.5 * sc, -0.55 * sc)

	-- ── Feeding puff at the head when a harvest starts ────────────────────────
	if e.harvestActive then
		e.feedHost.CFrame = CFrame.new(pts[1].X, groundY + 0.2 * sc, pts[1].Z)
		if not e.harvestEmitted and hv > 0.05 then
			e.harvestEmitted = true
			-- Don't leak the puff/sound through fog: only play when the body is visible
			-- (FogManager sets LocalTransparencyModifier on _LeechBody parts).
			if e.head.LocalTransparencyModifier < 0.5 then
				e.feed:Emit(math.random(6, 10))
				e.rise:Emit(math.random(10, 14))   -- angelic gold→white streaks ascending
				playSoundAt(pts[1], HARVEST_SND_ID, 0.85)
			end
		end
	end
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function LeechBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_LeechBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				LeechBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx * dx + dy * dy + dz * dz > CULL_SQ then continue end

			-- Speed estimate from frame-to-frame movement (parts are anchored)
			local last      = e.prevPos or bpos
			local frameMove = (bpos - last).Magnitude
			e.prevPos       = bpos
			local spd       = frameMove / math.max(dt, 0.001)
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.08
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Burrow state (the server tags a Burrowed BoolValue on the pivot). Ease the
			-- body into / out of the reared burrow pose, and play the dig cue on the flip.
			local bv       = body:FindFirstChild("Burrowed") :: BoolValue?
			local burrowed = bv ~= nil and (bv :: BoolValue).Value == true
			if burrowed ~= e.wasBurrowed then
				e.wasBurrowed = burrowed
				if burrowed then
					-- Fresh dig-in: throw the arch a new direction, rear up head-high, and
					-- quest for the server's AnchorDelay before planting the head — so the
					-- head-plant lines up with when this leech's first income tick is due
					-- (each leech in a batch gets its own delay). Fall back to a local roll.
					e.archDir      = randomHorizDir()
					e.burrowTime   = 0
					e.anchorPlanted = false   -- re-arm the head-plant cue for this dig-in
					e.anchorDelay  = (body:GetAttribute("AnchorDelay") :: number?)
						or (ANCHOR_DELAY_MIN + math.random() * (ANCHOR_DELAY_MAX - ANCHOR_DELAY_MIN))
				end
				if e.head.LocalTransparencyModifier < 0.5 then
					playSoundAt(bpos, BURROW_SND_ID, 0.85)
				end
			end
			e.burrowBlend += ((burrowed and 1 or 0) - e.burrowBlend) * math.min(dt * BURROW_EASE, 1)

			-- Head stays up and questing for anchorDelay seconds, then lowers to plant.
			if burrowed then e.burrowTime += dt end
			local anchorTarget = (burrowed and e.burrowTime >= e.anchorDelay) and 1 or 0
			e.anchorBlend += (anchorTarget - e.anchorBlend) * math.min(dt * ANCHOR_EASE, 1)

			-- The head finishes lowering into the ground → play the plant/impact cue once
			-- per dig-in (only while the body is visible, i.e. not hidden behind fog).
			if not e.anchorPlanted and anchorTarget == 1 and e.anchorBlend >= 0.9 then
				e.anchorPlanted = true
				if e.head.LocalTransparencyModifier < 0.5 then
					playSoundAt(e.head.Position, ANCHOR_SND_ID, 0.9)
				end
			end

			-- Advance clocks (slither quickens with movement)
			e.animClock += dt * (0.35 + speedF) * SLITHER_FREQ * math.pi * 2
			e.idleClock += dt * IDLE_FREQ * math.pi * 2
			e.archClock += dt * ARCH_BREATHE_FREQ * math.pi * 2

			-- Advance the feeding/harvest animation timer.
			if e.harvestActive then
				e.harvestT += dt
				if e.harvestT >= HARVEST_DUR then e.harvestActive = false end
			end

			layout(e, speedF)
		end
	end)
end

return LeechBody
