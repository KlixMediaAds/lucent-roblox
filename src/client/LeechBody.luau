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

-- ── Harvest (feeding) animation — plays on each burrowed income tick ────────────
local HARVEST_DUR  = 1.3           -- seconds the feeding animation plays
local HARVEST_DIP  = 1.5           -- how far the head burrows down as it draws blood
local PERI_AMP     = 0.55          -- peristalsis thickness pulse (fraction of body width)
local PERI_FREQ    = 8.5           -- pump cycles/sec while feeding
local PERI_K       = math.pi * 2.0 -- pump waves along the body

-- Harvest sound: a dirt shift as it latches on, then a coin-like chime 0.4 s later.
local DIRT_SND_ID  = "rbxassetid://139990035476921"
local CHIME_SND_ID = "rbxassetid://74040596787161"
local CHIME_DELAY  = 0.4

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

-- ── Types ─────────────────────────────────────────────────────────────────────
type Entry = {
	body:        BasePart,
	segs:        { BasePart },
	head:        BasePart,
	eyes:        { BasePart },
	feedHost:    BasePart,
	feed:        ParticleEmitter,
	prevPos:     Vector3?,
	animClock:   number,
	idleClock:   number,
	smoothSpeed: number,
	harvestActive: boolean,
	harvestT:      number,
	harvestEmitted: boolean,
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

	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

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
		prevPos        = nil,
		animClock      = phase,
		idleClock      = phase * 1.4,
		smoothSpeed    = 0,
		harvestActive  = false,
		harvestT       = 0,
		harvestEmitted = false,
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

	-- Harvest envelope (0→1→0 over HARVEST_DUR): drives a head-down feeding dip and a
	-- peristaltic thickness pump while a burrowed leech is drawing income.
	local hv = 0
	if e.harvestActive then
		hv = math.sin(math.clamp(e.harvestT / HARVEST_DUR, 0, 1) * math.pi)
	end

	-- ── Build spine points along the ground (head index 1 → tail index N_SEG+1) ──
	local pts: { Vector3 } = {}
	for i = 0, N_SEG do
		local s     = i / N_SEG
		local along = HEAD_FWD - s * BODY_LEN            -- +fwd at head, −fwd at tail

		-- Vertical: each segment rests on the surface by its own radius, the head lifts
		-- a little (sensing), and a travelling hump inch-worms the body when crawling.
		-- While harvesting the front burrows down (dip) as it latches on to feed.
		local restY    = THICK[i + 1] * 0.5
		local headLift = HEAD_RISE * (1 - s) * (1 - s)
		local hump     = HUMP_AMP * speedF * math.max(0, math.sin(e.animClock - s * HUMP_K))
		local dip      = hv * HARVEST_DIP * (1 - s) * (1 - s)
		local height   = restY + headLift + hump - dip

		-- Lateral slither (side to side); quicker + wider when crawling, plus a gentle
		-- idle head sway on the front.
		local lat  = math.sin(e.animClock - s * LAT_K) * LAT_AMP * (0.4 + 0.6 * speedF)
		local sway = math.sin(e.idleClock) * IDLE_SWAY * (1 - s)

		pts[i + 1] = centre
			+ fwd   * (along * sc)
			+ right * ((lat + sway) * sc)
			+ Vector3.new(0, height * sc, 0)
	end

	-- ── Tapering opaque segments (no ball joints along the spine) ─────────────
	-- A peristaltic pulse ripples down the body while feeding (pumping blood along it).
	for i = 1, N_SEG do
		local sm   = (i - 0.5) / N_SEG
		local peri = 1 + PERI_AMP * hv * math.sin(e.harvestT * PERI_FREQ - sm * PERI_K)
		local t    = (THICK[i] + THICK[i + 1]) * 0.5 * sc * peri
		orientYBetween(e.segs[i], pts[i], pts[i + 1], t)
	end

	-- ── Head at the front, facing the way the leech is heading ────────────────
	local headPos = pts[1]
	local headDir = (pts[1] - pts[2])
	headDir = if headDir.Magnitude > 0.01 then headDir.Unit else fwd
	local headCF  = CFrame.lookAt(headPos, headPos + headDir)  -- LookVector (−Z) = headDir
	e.head.Size   = HEAD_SIZE * sc
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
				-- Dirt shift now, then the income chime 0.4 s later.
				local sndPos = pts[1]
				playSoundAt(sndPos, DIRT_SND_ID, 0.7)
				task.delay(CHIME_DELAY, function()
					playSoundAt(sndPos, CHIME_SND_ID, 0.65)
				end)
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

			-- Advance clocks (slither quickens with movement)
			e.animClock += dt * (0.35 + speedF) * SLITHER_FREQ * math.pi * 2
			e.idleClock += dt * IDLE_FREQ * math.pi * 2

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
