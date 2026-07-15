-- NeedlerBody.luau
-- Client-only procedural body for the Needler — a slow stalker evolved from an Embryo,
-- and its merged "spider" forms.
--
-- A lone Needler is a single spherical body with an amber eye on each side and one long,
-- two-jointed arm rising from its top that reads like a solitary giant insect leg. It
-- does not walk on legs: it REACHES the arm forward, plants the tip in the ground ahead,
-- then hauls its whole body up to the anchor — a surging, non-linear inch-along gait.
--
-- MERGE FORMS (server sets a "NeedlerCount" attribute, 1–5, on the pivot part):
--   • 1–2 bodies  → the DRAG gait: 1 or 2 long arms reach forward and haul the body along,
--                   just like a lone Needler (two arms alternate hand-over-hand).
--   • 3–5 bodies  → the body closes into a fat radial mass and the arms splay out evenly
--                   around it as legs. It stands up and WALKS like a spider: each leg
--                   plants a foot on the ground out at its radial slot, and steps forward
--                   when the body drifts too far from that foot (a capped alternating gait).
-- The core swells and the legs spread wider with each extra body, so the silhouette grows
-- radially as Needlers are folded in.
--
-- Its attack is a stationary mantis-shrimp strike: the body braces while one arm — the one
-- best aimed at the target — cocks up and snaps down. The other arms keep walking.
--
-- Architecture mirrors WatcherBody / RollerBody: one shared RenderStepped loop, a
-- distance cull, a movement-derived speed clock, and every part tagged with a "UnitId"
-- attribute so FogManager can hide the bodies of enemy Needlers sitting in the fog.
--
-- The server spawns the Needler as an invisible, ground-snapped pivot block (base size
-- 4×6×4; the XZ footprint grows with the merge count). Everything you see is drawn here.
--!strict

local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")

local NeedlerBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
local BASE_HEIGHT = 6.0        -- = Config.UNIT_TYPES.Needler.size.Y (pivot centre = size.Y/2 above ground)
local BODY_R      = 1.5        -- spherical body radius (lone Needler)
local BODY_H      = 1.9        -- resting height of the body centre above the ground (drag gait)
local BODY_DIP    = 0.55       -- how much the body sinks at the bottom of a pull (crouch/brace)
local SHOULDER_UP  = BODY_R * 0.78   -- arm root offset above the body centre
local SHOULDER_FWD = BODY_R * 0.15   -- arm root offset toward the front

local UPPER_LEN  = 5.15        -- upper arm segment length (shoulder → elbow)
local FORE_LEN   = 5.62        -- fore arm segment length (elbow → tip)
local UPPER_TH   = 0.71        -- upper arm thickness
local FORE_TH    = 0.51        -- fore arm thickness (tapers toward the point)

-- ── Drag gait (anchored pull; counts 1–2) ─────────────────────────────────────
local FULL_SPEED   = 10.0      -- matches Config.UNIT_MOVE_SPEED.Needler (slow)
local STRIDE_LEN   = 7.5       -- studs of ground covered per full reach→pull cycle (bigger steps)
local REACH_END    = 0.45      -- phase [0,REACH_END) = reach; [REACH_END,1) = plant + pull
local ANCHOR_AHEAD = 7.5       -- studs ahead of the body the tip plants
local DRAG_SPREAD  = 1.35      -- lateral offset of each arm in a two-arm drag body
local SURGE_AMP    = 0.95      -- how far the body lags/leads its pivot through the surge
local REACH_LIFT   = 1.8       -- how high the tip arcs as it is thrown forward
local BREATHE_FREQ = 0.75      -- idle body pulsate cycles/sec
local BREATHE_AMP  = 0.06      -- fraction the body swells as it "breathes"

-- ── Spider gait (radial legs; counts 3–5) ─────────────────────────────────────
local SPIDER_BODY_H  = 3.3     -- body-centre height above ground while standing on legs
local FOOT_RADIUS_0  = 5.3     -- base foot planting radius (grows with count)
local FOOT_RADIUS_K  = 0.72    -- extra foot radius per body beyond the first
local SHOULDER_UP_SP = 0.55    -- leg root height above the body centre
local STEP_DIST      = 2.5     -- foot drift from its neutral slot before it takes a step
local STEP_DUR       = 0.26    -- seconds a single leg step takes
local STEP_LIFT      = 1.7     -- how high a foot arcs mid-step
local STEP_LEAD      = 3.2     -- studs ahead (along travel) a step aims when moving
local BODY_BOB_AMP   = 0.28    -- vertical body bob amplitude while walking

-- ── Eyes ──────────────────────────────────────────────────────────────────────
local SCLERA_D   = 0.98        -- amber eyeball diameter
local PUPIL_D    = 0.42        -- pupil diameter
local EYE_FWD    = BODY_R * 0.34   -- eye offset toward the front
local EYE_UP     = BODY_R * 0.12   -- eye offset above the body's equator
local EYE_SIDE   = BODY_R * 0.92   -- eye offset out to each side
local LOOK_MIN   = 1.2         -- min seconds before an idle eye re-aims
local LOOK_MAX   = 3.6         -- max seconds before an idle eye re-aims
local LOOK_EASE  = 3.0         -- how fast the pupil slews to a new look target
local BLINK_MIN  = 4.0         -- min seconds between an eye's blinks
local BLINK_MAX  = 11.0        -- max seconds between an eye's blinks
local BLINK_DUR  = 0.7         -- seconds one blink takes

-- ── Strike (mantis-shrimp) ──────────────────────────────────────────────────────
local STRIKE_DUR   = 0.5       -- total seconds of one strike (cock → snap → recover)
local STRIKE_RANGE = 65        -- max studs from a hit origin to claim the nearest Needler
local COCK_END     = 0.42      -- phase the arm finishes rearing up
local SNAP_END     = 0.56      -- phase the arm finishes snapping down (impact lands here)
local COCK_H       = 2.9       -- studs the tip rears above the shoulder while cocking
local STRIKE_REACH = 4.4       -- studs ahead the tip drives on the snap
local STRIKE_GY    = 0.5       -- height above ground the strike point sits
local STRIKE_SND   = "rbxassetid://9125703168"

local CULL_SQ = 300 * 300

-- ── Colours (Hagfish-eye palette) ───────────────────────────────────────────────
local C_FLESH    = Color3.fromRGB(58, 34, 42)    -- dark blood-maroon body
local C_BELLY    = Color3.fromRGB(44, 25, 32)    -- darker underside lobe
local C_CHITIN   = Color3.fromRGB(80, 47, 41)    -- rusty chitin arm segments
local C_JOINT    = Color3.fromRGB(52, 30, 28)    -- darker knuckle/shoulder joints
local C_CLAW     = Color3.fromRGB(158, 100, 62)  -- pale amber chitin point
local C_SOCKET   = Color3.fromRGB(30, 18, 22)    -- recessed socket behind each eye
local C_SCLERA   = Color3.fromRGB(235, 150, 78)  -- amber, faintly glowing (hagfish eye)
local C_PUPIL    = Color3.fromRGB(18, 9, 12)     -- near-black pupil

-- ── Easing ──────────────────────────────────────────────────────────────────────
local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end
local function easeOutCubic(t: number): number
	t = math.clamp(t, 0, 1)
	local u = 1 - t
	return 1 - u * u * u
end
local function easeInQuint(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t * t * t
end

-- ── Types ─────────────────────────────────────────────────────────────────────
type Eye = {
	socket:     BasePart,
	sclera:     BasePart,
	pupil:      BasePart,
	side:       number,      -- +1 = right, -1 = left
	look:       Vector2,     -- current pupil offset (each −1..1)
	lookGoal:   Vector2,
	lookTimer:  number,
	blinkTimer: number,
	blinkT:     number,
}
type Arm = {
	shoulder:  BasePart,   -- arm-root joint ball
	upper:     BasePart,   -- upper arm segment
	elbow:     BasePart,   -- elbow joint ball
	fore:      BasePart,   -- fore arm segment
	claw:      BasePart,   -- pointed tip
	restAngle: number,     -- radial slot angle around the body (spider gait; 0 = forward)
	lateral:   number,     -- lateral offset sign (drag gait)
	armPhase:  number,     -- stride phase offset [0,1) (drag gait)
	-- drag-gait anchor
	plantPos:  Vector3,
	pullSet:   boolean,
	-- spider-gait foot
	footPos:   Vector3,
	stepT:     number,     -- >0 while this leg is mid-step
	stepFrom:  Vector3,
	stepTo:    Vector3,
	renderTip: Vector3?,   -- the tip actually drawn last frame (strike hand-offs)
	cockFrom:  Vector3?,   -- where this arm's tip was when its current strike began
}
type Entry = {
	body:        BasePart,
	core:        BasePart,    -- spherical body
	belly:       BasePart,    -- darker underside lobe
	arms:        { Arm },
	count:       number,      -- merge stack size (1–5)
	eyes:        { Eye },
	prevPos:     Vector3?,
	smoothSpeed: number,
	facing:      Vector3,     -- horizontal unit heading the creature is pointed
	gaitPhase:   number,      -- accumulates with distance travelled (drag gait)
	breatheClock: number,
	bobClock:    number,      -- spider-gait body bob accumulator
	strikeT:     number,      -- >0 while a strike plays
	strikeTarget: Vector3?,
	strikeArm:   number,      -- index of the arm currently striking
	struck:      boolean,     -- has this swing already spat its impact FX
	cockFrom:    Vector3?,    -- where the tip was when the current strike began
	countConn:   RBXScriptConnection,
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

-- Stretch a block part between two world points (used for the arm segments).
local function placeLimb(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 1e-3 then
		part.Size  = Vector3.new(thick, thick, thick)
		part.CFrame = CFrame.new(a)
		return
	end
	part.Size  = Vector3.new(thick, thick, len)
	part.CFrame = CFrame.lookAt((a + b) * 0.5, b)
end

-- Fire a one-shot spatial sound at a world position (self-cleaning).
local function playSoundAt(pos: Vector3, id: string, volume: number)
	local p        = Instance.new("Part")
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.Transparency = 1
	p.Size         = Vector3.new(1, 1, 1)
	p.Position     = pos
	p.Parent       = workspace
	local s               = Instance.new("Sound")
	s.SoundId            = id
	s.Volume             = volume
	s.PlaybackSpeed      = 1.2 + math.random() * 0.25
	s.RollOffMaxDistance = 90
	s.RollOffMinDistance = 8
	s.RollOffMode        = Enum.RollOffMode.Linear
	s.Parent             = p
	s:Play()
	s.Ended:Once(function() p:Destroy() end)
	Debris:AddItem(p, 4)
end

-- A sharp burst where the strike lands: a bright amber flash + a few flung chitin shards.
local function spawnStrikeImpact(unitId: string, pos: Vector3, dir: Vector3)
	local flash        = Instance.new("Part")
	flash.Shape        = Enum.PartType.Ball
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CastShadow   = false
	flash.Material     = Enum.Material.Neon
	flash.Color        = C_CLAW
	flash.Size         = Vector3.new(0.6, 0.6, 0.6)
	flash.CFrame       = CFrame.new(pos)
	flash.Transparency = 0.1
	flash:SetAttribute("UnitId", unitId)
	flash.Parent       = folder
	TweenService:Create(flash, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(3.4, 3.4, 3.4), Transparency = 1 }):Play()
	Debris:AddItem(flash, 0.3)

	local right = dir:Cross(Vector3.yAxis)
	for i = 1, 5 do
		local shard        = Instance.new("Part")
		shard.Anchored     = true
		shard.CanCollide   = false
		shard.CanQuery     = false
		shard.CastShadow   = false
		shard.Material     = Enum.Material.Neon
		shard.Color        = C_SCLERA
		shard.Size         = Vector3.new(0.12, 0.12, 0.5 + math.random() * 0.4)
		shard:SetAttribute("UnitId", unitId)
		local spread = dir * (0.6 + math.random())
			+ right * (math.random() - 0.5) * 1.6
			+ Vector3.new(0, 0.4 + math.random() * 1.1, 0)
		local endPos = pos + spread * 3
		shard.CFrame       = CFrame.lookAt(pos, endPos)
		shard.Transparency = 0.15
		shard.Parent       = folder
		TweenService:Create(shard, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.lookAt(endPos, endPos + spread), Transparency = 1 }):Play()
		Debris:AddItem(shard, 0.36)
	end
end

-- ── Arm construction / removal ──────────────────────────────────────────────--
local function makeArm(unitId: string, atPos: Vector3): Arm
	return {
		shoulder  = makePart(unitId, C_JOINT,  Enum.Material.SmoothPlastic, Enum.PartType.Ball),
		upper     = makePart(unitId, C_CHITIN, Enum.Material.SmoothPlastic),
		elbow     = makePart(unitId, C_JOINT,  Enum.Material.SmoothPlastic, Enum.PartType.Ball),
		fore      = makePart(unitId, C_CHITIN, Enum.Material.SmoothPlastic),
		claw      = makePart(unitId, C_CLAW,   Enum.Material.SmoothPlastic),
		restAngle = 0,
		lateral   = 0,
		armPhase  = 0,
		plantPos  = atPos,
		pullSet   = false,
		footPos   = atPos,
		stepT     = 0,
		stepFrom  = atPos,
		stepTo    = atPos,
		renderTip = nil,
		cockFrom  = nil,
	}
end

local function destroyArm(arm: Arm)
	for _, p in { arm.shoulder, arm.upper, arm.elbow, arm.fore, arm.claw } do
		if p.Parent then p:Destroy() end
	end
end

-- Assign each arm its radial slot / drag offsets for the current body count. Spider
-- forms (3+) spread the arms evenly around the body, offset a half-slot so none points
-- straight ahead; drag forms (1–2) line the arms up across the front and give the pair
-- a half-stride phase offset so they haul hand-over-hand.
local function recomputeSlots(e: Entry)
	local n = e.count
	local spider = n >= 3
	for i, arm in e.arms do
		if spider then
			arm.restAngle = ((i - 1) + 0.5) / n * (2 * math.pi)
			arm.lateral   = 0
			arm.armPhase  = 0
		else
			arm.restAngle = 0
			arm.lateral   = (n == 1) and 0 or (i - (n + 1) * 0.5)   -- n=2 → −0.5, +0.5
			arm.armPhase  = (i - 1) / n
		end
	end
end

local function setCount(e: Entry, n: number)
	n = math.clamp(math.floor(n + 0.5), 1, 5)
	if n == e.count and #e.arms == n then return end
	local unitId = e.core:GetAttribute("UnitId") :: string
	local atPos  = e.body.Position
	while #e.arms < n do
		e.arms[#e.arms + 1] = makeArm(unitId, atPos + e.facing * ANCHOR_AHEAD)
	end
	while #e.arms > n do
		destroyArm(e.arms[#e.arms])
		e.arms[#e.arms] = nil
	end
	e.count = n
	if e.strikeArm > n then e.strikeArm = 1 end
	recomputeSlots(e)
end

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function NeedlerBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local core     = makePart(unitId, C_FLESH,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local belly    = makePart(unitId, C_BELLY,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)

	local eyes: { Eye } = {}
	for _, side in { -1, 1 } do
		table.insert(eyes, {
			socket     = makePart(unitId, C_SOCKET, Enum.Material.SmoothPlastic),
			sclera     = makePart(unitId, C_SCLERA, Enum.Material.Neon,         Enum.PartType.Ball),
			pupil      = makePart(unitId, C_PUPIL,  Enum.Material.SmoothPlastic, Enum.PartType.Ball),
			side       = side,
			look       = Vector2.new((math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2),
			lookGoal   = Vector2.new((math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2),
			lookTimer  = LOOK_MIN + math.random() * (LOOK_MAX - LOOK_MIN),
			blinkTimer = BLINK_MIN + math.random() * (BLINK_MAX - BLINK_MIN),
			blinkT     = 0,
		})
	end

	local n      = tonumber(unitId:match("%d+")) or 0
	local phase  = n * 0.6180339887
	local facing = body.CFrame.LookVector
	facing       = Vector3.new(facing.X, 0, facing.Z)
	facing       = if facing.Magnitude > 1e-3 then facing.Unit else Vector3.new(0, 0, -1)

	local conn = body.Destroying:Connect(function()
		NeedlerBody.detach(unitId)
	end)

	local e: Entry = {
		body         = body,
		core         = core,
		belly        = belly,
		arms         = {},
		count        = 0,
		eyes         = eyes,
		prevPos      = nil,
		smoothSpeed  = 0,
		facing       = facing,
		gaitPhase    = phase,
		breatheClock = phase * 4.0,
		bobClock     = phase * 3.0,
		strikeT      = 0,
		strikeTarget = nil,
		strikeArm    = 1,
		struck       = false,
		cockFrom     = nil,
		countConn    = nil :: any,
		conn         = conn,
	}
	active[unitId] = e

	-- Build the initial arms for the current merge count, and rebuild them if it changes.
	setCount(e, (body:GetAttribute("NeedlerCount") :: number?) or 1)
	e.countConn = body:GetAttributeChangedSignal("NeedlerCount"):Connect(function()
		setCount(e, (body:GetAttribute("NeedlerCount") :: number?) or 1)
	end)
end

function NeedlerBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	if e.countConn then e.countConn:Disconnect() end
	for _, p in { e.core, e.belly } do
		if p.Parent then p:Destroy() end
	end
	for _, arm in e.arms do destroyArm(arm) end
	for _, eye in e.eyes do
		if eye.socket.Parent then eye.socket:Destroy() end
		if eye.sclera.Parent then eye.sclera:Destroy() end
		if eye.pupil.Parent  then eye.pupil:Destroy()  end
	end
end

-- Lock the nearest Needler onto a target and play its best-aimed arm's strike.
function NeedlerBody.triggerAttackNear(fromPos: Vector3, toPos: Vector3)
	local bestId: string? = nil
	local bestD           = math.huge
	for unitId, e in active do
		local d = (e.body.Position - fromPos).Magnitude
		if d < bestD then bestD = d; bestId = unitId end
	end
	if bestId and bestD < STRIKE_RANGE then
		local e = active[bestId]
		e.strikeT      = STRIKE_DUR
		e.strikeTarget = toPos
		e.struck       = false
		-- Snap the heading toward the target so the strike drives straight at it.
		local flat = Vector3.new(toPos.X - e.body.Position.X, 0, toPos.Z - e.body.Position.Z)
		if flat.Magnitude > 1e-3 then e.facing = flat.Unit end
		-- Pick the arm whose radial slot is best aimed at the target.
		local f      = e.facing
		local right  = Vector3.new(f.Z, 0, -f.X)
		local dir    = if flat.Magnitude > 1e-3 then flat.Unit else f
		local bestArm, bestDot = 1, -math.huge
		for i, arm in e.arms do
			local armDir: Vector3
			if e.count >= 3 then
				armDir = (f * math.cos(arm.restAngle) + right * math.sin(arm.restAngle))
			else
				armDir = (f + right * (arm.lateral * 0.5))
				armDir = if armDir.Magnitude > 1e-3 then armDir.Unit else f
			end
			local d = armDir:Dot(dir)
			if d > bestDot then bestDot = d; bestArm = i end
		end
		e.strikeArm = bestArm
		e.arms[bestArm].cockFrom = e.arms[bestArm].renderTip
	end
end

-- ── Two-bone IK: place elbow between shoulder S and tip T ────────────────────────
-- The elbow always bends WITHIN the vertical plane that contains the arm (the plane
-- whose normal is planeNormal), on the "up" side so the knee stays raised.
local function solveElbow(S: Vector3, T: Vector3, l1: number, l2: number, planeNormal: Vector3): Vector3
	local delta = T - S
	local d     = delta.Magnitude
	if d < 1e-4 then return S + Vector3.new(0, l1, 0) end
	d = math.clamp(d, math.abs(l1 - l2) + 0.05, l1 + l2 - 0.05)
	local axis = delta.Unit
	local a    = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
	local h    = math.sqrt(math.max(0, l1 * l1 - a * a))
	local bendDir = planeNormal:Cross(axis)
	if bendDir.Magnitude < 1e-4 then
		bendDir = Vector3.yAxis - axis * Vector3.yAxis:Dot(axis)
	end
	bendDir = if bendDir.Magnitude > 1e-4 then bendDir.Unit else Vector3.yAxis
	if bendDir.Y < 0 then bendDir = -bendDir end   -- keep the knee raised
	return S + axis * a + bendDir * h
end

-- Draw a single arm's two-bone linkage from a shoulder to a tip, clamping the tip so it
-- never exceeds the arm's real reach. Returns the (possibly clamped) tip actually drawn.
local function poseArm(arm: Arm, shoulderPos: Vector3, tip: Vector3, planeNormal: Vector3, sc: number, f: Vector3): Vector3
	local armReach = (UPPER_LEN + FORE_LEN) * sc * 0.985
	local toTip    = tip - shoulderPos
	if toTip.Magnitude > armReach then
		tip = shoulderPos + toTip.Unit * armReach
	end
	arm.renderTip = tip

	local elbowPos = solveElbow(shoulderPos, tip, UPPER_LEN * sc, FORE_LEN * sc, planeNormal)

	local jointD = UPPER_TH * 1.35 * sc
	arm.shoulder.Size   = Vector3.new(jointD, jointD, jointD)
	arm.shoulder.CFrame = CFrame.new(shoulderPos)
	placeLimb(arm.upper, shoulderPos, elbowPos, UPPER_TH * sc)
	local elbD = UPPER_TH * 1.2 * sc
	arm.elbow.Size   = Vector3.new(elbD, elbD, elbD)
	arm.elbow.CFrame = CFrame.new(elbowPos)
	placeLimb(arm.fore, elbowPos, tip, FORE_TH * sc)
	-- A pale pointed claw finishing the fore-arm, aimed along its last segment.
	local clawLen = 0.9 * sc
	local clawDir = (tip - elbowPos)
	clawDir = if clawDir.Magnitude > 1e-3 then clawDir.Unit else f
	arm.claw.Size   = Vector3.new(FORE_TH * 1.1 * sc, FORE_TH * 1.1 * sc, clawLen)
	arm.claw.CFrame = CFrame.lookAt(tip - clawDir * (clawLen * 0.4), tip + clawDir)
	return tip
end

-- Compute the tip of a striking arm for the current strike phase.
local function strikeTip(e: Entry, arm: Arm, shoulderPos: Vector3, aheadTip: Vector3,
	groundY: number, f: Vector3, sc: number): (Vector3, boolean)
	local sp       = 1 - e.strikeT / STRIKE_DUR
	local bpos     = e.body.Position
	local cockFrom = arm.cockFrom or aheadTip
	local cockTip  = shoulderPos + Vector3.yAxis * (COCK_H * sc) - f * (0.7 * sc)
	local snapTip  = e.strikeTarget or (Vector3.new(bpos.X, groundY, bpos.Z) + f * (STRIKE_REACH * sc))
	snapTip = Vector3.new(snapTip.X, groundY + STRIKE_GY * sc, snapTip.Z)
	local tip: Vector3
	local doImpact = false
	if sp < COCK_END then
		tip = cockFrom:Lerp(cockTip, smooth(sp / COCK_END))
	elseif sp < SNAP_END then
		tip = cockTip:Lerp(snapTip, easeInQuint((sp - COCK_END) / (SNAP_END - COCK_END)))
		if not e.struck and sp >= (SNAP_END - 0.02) and e.core.LocalTransparencyModifier < 0.5 then
			e.struck = true
			doImpact = true
		end
	else
		tip = snapTip:Lerp(aheadTip, smooth((sp - SNAP_END) / (1 - SNAP_END)))
	end
	return tip, doImpact
end

-- ── Body core + eyes (shared by both gaits) ─────────────────────────────────────
local function drawBody(e: Entry, bodyCentre: Vector3, coreR: number, breathe: number, sc: number)
	local coreD = coreR * 2 * sc * breathe
	e.core.Size   = Vector3.new(coreD, coreD, coreD)
	e.core.CFrame = CFrame.new(bodyCentre)
	local bellyD  = coreR * 1.5 * sc * breathe
	e.belly.Size   = Vector3.new(bellyD, bellyD * 0.8, bellyD)
	e.belly.CFrame = CFrame.new(bodyCentre - Vector3.yAxis * (coreR * 0.5 * sc))
end

local function drawEyes(e: Entry, bodyCentre: Vector3, f: Vector3, right: Vector3, up: Vector3,
	sc: number, dt: number, eyeSide: number)
	local striking = e.strikeT > 0
	local aimDir: Vector3? = nil
	if striking and e.strikeTarget then
		local a = (e.strikeTarget :: Vector3) - bodyCentre
		aimDir = if a.Magnitude > 0.05 then a.Unit else nil
	end
	for _, eye in e.eyes do
		local sideDir = right * eye.side
		local basePos = bodyCentre + sideDir * (eyeSide * sc) + f * (EYE_FWD * sc) + up * (EYE_UP * sc)
		local normal  = (sideDir * 0.72 + f * 0.55 + up * 0.15).Unit
		local tanA    = right
		local tanB    = up

		if aimDir then
			eye.lookGoal = Vector2.new(math.clamp(aimDir:Dot(tanA), -1, 1), math.clamp(aimDir:Dot(tanB), -1, 1))
		else
			eye.lookTimer -= dt
			if eye.lookTimer <= 0 then
				eye.lookTimer = LOOK_MIN + math.random() * (LOOK_MAX - LOOK_MIN)
				eye.lookGoal  = Vector2.new((math.random() - 0.5) * 1.3, (math.random() - 0.5) * 1.3)
			end
		end
		eye.look = eye.look + (eye.lookGoal - eye.look) * math.min(1, dt * LOOK_EASE)

		eye.blinkTimer -= dt
		if eye.blinkTimer <= 0 and eye.blinkT <= 0 then
			eye.blinkT     = BLINK_DUR
			eye.blinkTimer = BLINK_MIN + math.random() * (BLINK_MAX - BLINK_MIN)
		end
		local open = 1.0
		if eye.blinkT > 0 then
			eye.blinkT = math.max(0, eye.blinkT - dt)
			local p      = 1 - eye.blinkT / BLINK_DUR
			local closed = 0.5 - 0.5 * math.cos(p * math.pi * 2)
			open = 1 - 0.85 * closed
		end

		local socketD = SCLERA_D * 1.35 * sc
		eye.socket.Size   = Vector3.new(socketD, socketD * open, socketD * 0.55)
		eye.socket.CFrame = CFrame.lookAt(basePos, basePos + normal)

		local scD = SCLERA_D * sc * open
		if striking then scD *= 1.12 end
		eye.sclera.Size   = Vector3.new(scD, scD, scD)
		eye.sclera.CFrame = CFrame.new(basePos + normal * (0.28 * sc * open))

		local pupilN = (normal + (tanA * eye.look.X + tanB * eye.look.Y) * 0.3)
		pupilN = if pupilN.Magnitude > 1e-3 then pupilN.Unit else normal
		local pupD   = PUPIL_D * sc * open
		eye.pupil.Size   = Vector3.new(pupD, pupD, pupD)
		eye.pupil.CFrame = CFrame.new(basePos + normal * (0.28 * sc * open) + pupilN * (scD * 0.4))
	end
end

-- ── Drag gait layout (counts 1–2) ───────────────────────────────────────────────
local function layoutDrag(e: Entry, sc: number, speedF: number, dt: number)
	local bpos    = e.body.Position
	local groundY = bpos.Y - (BASE_HEIGHT * 0.5) * sc
	local f       = e.facing
	local right   = Vector3.new(f.Z, 0, -f.X)
	local up      = Vector3.yAxis
	local striking = e.strikeT > 0

	-- Body surge + brace (whole body hauls forward through the pull; braces on a strike).
	local longOff, dip
	if striking then
		longOff = -0.2
		dip     = BODY_DIP * 0.8
	else
		local u0 = e.gaitPhase - math.floor(e.gaitPhase)
		local surge
		if u0 < REACH_END then
			surge = SURGE_AMP * (1 - 2 * smooth(u0 / REACH_END))
		else
			surge = SURGE_AMP * (2 * easeOutCubic((u0 - REACH_END) / (1 - REACH_END)) - 1)
		end
		longOff = surge * speedF
		local pullF = if u0 >= REACH_END then math.sin(((u0 - REACH_END) / (1 - REACH_END)) * math.pi) else 0
		dip = BODY_DIP * pullF * speedF
	end

	local breathe    = 1 + math.sin(e.breatheClock) * BREATHE_AMP
	local coreR      = BODY_R * (e.count == 2 and 1.22 or 1.0)
	local bodyCentre = Vector3.new(bpos.X, groundY, bpos.Z)
		+ f * (longOff * sc)
		+ up * ((BODY_H - dip) * sc)
	drawBody(e, bodyCentre, coreR, breathe, sc)

	for i, arm in e.arms do
		local latOff      = arm.lateral * DRAG_SPREAD
		local shoulderPos = bodyCentre + up * (SHOULDER_UP * sc) + f * (SHOULDER_FWD * sc) + right * (latOff * sc)
		local aheadTip    = Vector3.new(bpos.X, groundY, bpos.Z) + f * (ANCHOR_AHEAD * sc) + right * (latOff * sc)

		local tip: Vector3
		local doImpact = false
		if striking and i == e.strikeArm then
			tip, doImpact = strikeTip(e, arm, shoulderPos, aheadTip, groundY, f, sc)
			arm.plantPos = tip
			arm.pullSet  = false
		else
			local u = (e.gaitPhase + arm.armPhase)
			u = u - math.floor(u)
			if u < REACH_END then
				arm.pullSet = false
				local t = u / REACH_END
				tip = arm.plantPos:Lerp(aheadTip, smooth(t)) + up * (math.sin(t * math.pi) * REACH_LIFT * sc * (0.4 + 0.6 * speedF))
			else
				if not arm.pullSet then
					arm.plantPos = aheadTip
					arm.pullSet  = true
				end
				tip = arm.plantPos
			end
		end

		local drawn = poseArm(arm, shoulderPos, tip, right, sc, f)
		if doImpact then
			spawnStrikeImpact(e.core:GetAttribute("UnitId") :: string or "", drawn, f)
			playSoundAt(drawn, STRIKE_SND, 0.55)
		end
	end

	drawEyes(e, bodyCentre, f, right, up, sc, dt, EYE_SIDE)
end

-- ── Spider gait layout (counts 3–5) ─────────────────────────────────────────────
local function layoutSpider(e: Entry, sc: number, speedF: number, dt: number)
	local bpos      = e.body.Position
	local groundY   = bpos.Y - (BASE_HEIGHT * 0.5) * sc
	local f         = e.facing
	local right     = Vector3.new(f.Z, 0, -f.X)
	local up        = Vector3.yAxis
	local striking  = e.strikeT > 0
	local n         = e.count
	local footRad   = (FOOT_RADIUS_0 + FOOT_RADIUS_K * (n - 1)) * sc
	local coreR     = BODY_R * (0.78 + 0.22 * n)     -- body swells radially with each body
	local shoulderR = coreR * 0.86 * sc

	-- Gentle body bob keyed to walking speed.
	e.bobClock += dt * (2 + 6 * speedF)
	local bob        = math.sin(e.bobClock) * BODY_BOB_AMP * speedF
	local breathe    = 1 + math.sin(e.breatheClock) * BREATHE_AMP
	local bodyCentre = Vector3.new(bpos.X, groundY + (SPIDER_BODY_H + bob) * sc, bpos.Z)
	drawBody(e, bodyCentre, coreR, breathe, sc)

	-- Neutral foot slot for each leg (moves with the body); a leg steps when its planted
	-- foot drifts too far. Steps are capped so roughly half the legs stay grounded.
	local groundPos = Vector3.new(bpos.X, groundY, bpos.Z)
	local lead      = f * (STEP_LEAD * speedF * sc)
	local stepping  = 0
	for _, arm in e.arms do
		if arm.stepT > 0 then stepping += 1 end
	end
	local maxConcurrent = math.max(1, math.floor(n / 2))

	-- Rank grounded legs that want to step by drift, and start the neediest ones.
	local wanters: { { arm: Arm, drift: number, neutral: Vector3 } } = {}
	for i, arm in e.arms do
		local restDir = (f * math.cos(arm.restAngle) + right * math.sin(arm.restAngle))
		local neutral = groundPos + restDir * footRad + lead
		if arm.stepT <= 0 and not (striking and i == e.strikeArm) then
			local drift = (arm.footPos - neutral).Magnitude
			if drift > STEP_DIST * sc then
				table.insert(wanters, { arm = arm, drift = drift, neutral = neutral })
			end
		end
	end
	table.sort(wanters, function(a, b) return a.drift > b.drift end)
	for _, w in wanters do
		if stepping >= maxConcurrent then break end
		w.arm.stepT    = STEP_DUR
		w.arm.stepFrom = w.arm.footPos
		w.arm.stepTo   = w.neutral
		stepping += 1
	end

	for i, arm in e.arms do
		local restDir     = (f * math.cos(arm.restAngle) + right * math.sin(arm.restAngle))
		local shoulderPos = bodyCentre + restDir * shoulderR + up * (SHOULDER_UP_SP * sc)

		-- Advance a step, or hold the planted foot.
		if arm.stepT > 0 then
			arm.stepT = math.max(0, arm.stepT - dt)
			local p = 1 - arm.stepT / STEP_DUR
			arm.footPos = arm.stepFrom:Lerp(arm.stepTo, smooth(p)) + up * (math.sin(p * math.pi) * STEP_LIFT * sc)
			if arm.stepT <= 0 then arm.footPos = arm.stepTo end
		end

		local tip: Vector3
		local doImpact = false
		if striking and i == e.strikeArm then
			local aheadTip = groundPos + restDir * footRad
			tip, doImpact = strikeTip(e, arm, shoulderPos, aheadTip, groundY, f, sc)
			arm.footPos = Vector3.new(tip.X, groundY, tip.Z)   -- resume the walk from here
		else
			tip = arm.footPos
		end

		-- Legs bend within the vertical plane that holds their radial direction.
		local planeN = restDir:Cross(up)
		if planeN.Magnitude < 1e-4 then planeN = right end
		local drawn = poseArm(arm, shoulderPos, tip, planeN, sc, restDir)
		if doImpact then
			spawnStrikeImpact(e.core:GetAttribute("UnitId") :: string or "", drawn, f)
			playSoundAt(drawn, STRIKE_SND, 0.55)
		end
	end

	drawEyes(e, bodyCentre, f, right, up, sc, dt, coreR * 0.62)
end

-- ── Init + animation loop ─────────────────────────────────────────────────────
function NeedlerBody.init(cam: Camera)
	camera        = cam
	folder        = Instance.new("Folder")
	folder.Name   = "_NeedlerBody"
	folder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				NeedlerBody.detach(unitId)
				continue
			end

			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx * dx + dy * dy + dz * dz > CULL_SQ then continue end

			-- Speed + heading from frame-to-frame movement (parts are anchored).
			local last      = e.prevPos or bpos
			local moveVec   = bpos - last
			local frameMove = moveVec.Magnitude
			e.prevPos       = bpos
			local carried   = body:GetAttribute("Carried") == true
			local spd       = if carried then 0 else frameMove / math.max(dt, 0.001)
			local alpha     = if spd > e.smoothSpeed then 0.3 else 0.12
			e.smoothSpeed  += (spd - e.smoothSpeed) * alpha
			local speedF    = math.clamp(e.smoothSpeed / FULL_SPEED, 0, 1)

			-- Heading eases toward travel direction (held steady when idle / striking).
			if e.strikeT <= 0 and not carried then
				local flat = Vector3.new(moveVec.X, 0, moveVec.Z)
				if flat.Magnitude > 0.02 then
					local goal = flat.Unit
					e.facing = (e.facing + (goal - e.facing) * math.min(1, dt * 6)).Unit
				end
			end

			if not carried then e.gaitPhase += frameMove / STRIDE_LEN end
			e.breatheClock += dt * BREATHE_FREQ * math.pi * 2
			if e.strikeT > 0 then e.strikeT = math.max(0, e.strikeT - dt) end

			local sc = body.Size.Y / BASE_HEIGHT
			if e.count >= 3 then
				layoutSpider(e, sc, speedF, dt)
			else
				layoutDrag(e, sc, speedF, dt)
			end
		end
	end)
end

return NeedlerBody
