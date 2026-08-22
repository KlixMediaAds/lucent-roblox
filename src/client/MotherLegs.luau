--[[
	MotherLegs: the walking, breathing Hollowed Mother.

	Her whole body is static decor parts baked into the model by
	UnitVisuals.buildMotherDecor. Those parts belong to the server, and it re-sends their
	CFrames every frame she walks (Model:PivotTo), so animating them in place would just
	get overwritten. Instead this CLONES them into a client-only folder, hides the
	originals, and animates the clones. Cloning rather than rebuilding means the animated
	creature keeps the exact colour, material and taper the model was built with.

	It runs for the LOCAL player's own Mother only (see init.client), so no enemy ever
	gains an animated body that the fog cannot hide.

	── Finding her rig ──────────────────────────────────────────────────────────
	Everything below is done in HER OWN space, the space her decor was authored in:
	origin at the ground point she stands on, head toward -Z. That is NOT her Base's
	space -- the Base is a 14x10x14 box sitting half its height above the ground with no
	flip on it -- so every frame starts by converting one into the other through
	UnitVisuals.motherBodyCF. Skipping that conversion is what used to pose her legs five
	studs up in the air and mirrored end for end, which is why the helper lives next to
	the rig it describes rather than here.

	── The gait ────────────────────────────────────────────────────────────────
	FOOT-PLANTED, not swept. A foot holds a fixed point in the WORLD and does not move at
	all while the body walks over it; only when the body has carried its hip too far from
	that point does the leg pick up, arc through the air and set down ahead.

	  • A foot's world position is state, not a function of the body's. It is recomputed
	    only during a step.
	  • Steps are gated into diagonal pairs -- front-left with rear-right -- so she is
	    never off more than two feet at once and the stance stays a stable tripod.
	  • Nothing may ever stretch. The bones are fixed lengths and the segments are drawn
	    BETWEEN points, so a foot further away than the leg is long does not strain, it
	    tears the shin into a long thin spike. Two rules prevent it: a foot beyond
	    REACH_FORCE of full extension steps immediately, pair gating or not, and the
	    point the limb is actually drawn to is clamped to REACH_SAFE regardless.
	  • A step lands slightly ahead of where the foot is wanted, scaled by speed, so at
	    pace she reaches rather than shuffles.
	  • The knee is a real two-bone IK solve off the authored bone lengths, with the pole
	    vector kicked outward, so the limb folds out sideways like a salamander's.

	── The body ────────────────────────────────────────────────────────────────
	A creature that only moves its feet reads as a prop on a trolley, so the body is
	animated too, in three rigid groups hung off the same frame:

	  • CORE -- everything -- dips and twists as a pair of legs swings through, and
	    breathes on its own slow clock so she is alive standing still.
	  • HEAD -- skull, horns, snout, eyes -- holds against that twist, leads into her
	    turns (the head commits before the mass does, which is most of what sells a
	    turn), sweeps slowly while she stands, and blinks.
	  • GASTER -- the egg-swollen abdomen -- swings wider and drags AGAINST a turn
	    instead of leading it, heaves with her breathing, and its brood nodules pulse.

	The body takes its rhythm from the LEGS -- how far through the air the stepping pair
	is, and which pair it is -- rather than from a clock of its own. There is no stride
	length to keep in sync with the step trigger, the bob cannot drift out of step with
	the feet, and it stops dead when she does.

	Injecting is a pose blended on top: she widens her stance and digs in, sinks and
	pitches down over the wound, and shivers while the spike is in the ground. The server
	flags it with an `Injecting` attribute on her Base so every client sees it.

	API:
	  MotherLegs.init(camera)
	  MotherLegs.attach(ccId, model)   -- start animating; safe to call twice
	  MotherLegs.detach(ccId)          -- hand the static model back, exactly as built
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe         = require(Shared:WaitForChild("PerfProbe"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local MotherLegs = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
-- Everything measured in studs is authored at the Mother's full size and shrunk by
-- MOTHER_SCALE, so resizing her rescales her stride with her.
local S            = UnitVisuals.MOTHER_SCALE

-- Gait. The stride these add up to (trigger + lead) is what her legs can actually give:
-- most of a limb's extension is spent reaching SIDEWAYS to her splayed stance, so there is
-- far more room fore-and-aft than the stance width suggests -- about 3.8 authored studs of
-- travel before a foot hits REACH_FORCE. These sit inside that, with the clamp behind them.
local STEP_TRIGGER = 1.80 * S   -- studs a foot may fall behind its home before it steps
local STEP_LEAD    = 0.14       -- seconds of travel a step aims ahead of home
local STEP_LEAD_MAX= 2.00 * S   -- cap on that reach, so a sprint does not do the splits
local STEP_TIME    = 0.28       -- seconds a foot spends in the air at a stroll
local STEP_TIME_MIN= 0.11       -- ...and at a full 21-stud-per-second march
local STEP_LIFT    = 1.30 * S   -- studs a stepping foot arcs up
local REACH_FORCE  = 0.90       -- extension past which a foot steps whatever else is up
local REACH_SAFE   = 0.97       -- extension the drawn limb is clamped to, always
local UPPER_THICK  = 1.35 * S   -- matches buildMotherDecor's LegUpper
local FORE_THICK   = 1.0  * S   -- matches buildMotherDecor's LegFore
local POLE_OUT     = 1.0        -- how hard the knee is pushed out to the side
local POLE_UP      = 0.45       -- ...and up, so it folds over rather than under
local SPEED_SMOOTH = 8          -- how fast the measured speed follows reality
local SPEED_REF    = 16         -- studs/s counted as "full speed" for the animation (she tops out at 21)
local CULL_DIST2   = 700 * 700

-- Body. Angles in radians, distances in authored studs scaled like everything else.
local BOB          = 0.42 * S           -- vertical dip as a diagonal pair swings through
local ROLL         = math.rad(2.8)      -- twist about her length, toward the swinging pair
local PITCH        = math.rad(1.5)      -- nose dips as she pushes off
local BREATH       = 0.13 * S           -- idle rise and fall, never stops
local BREATH_HZ    = 0.23
local HEAD_YAW     = math.rad(3.2)      -- held against the body's twist
local HEAD_IDLE    = math.rad(6.5)      -- slow sweep while she is standing still
local HEAD_PITCH   = math.rad(2.8)
local HEAD_LEAD    = 0.42               -- radians of anticipation per rad/s of turn
local HEAD_LEAD_MAX= math.rad(15)
local GASTER_YAW   = math.rad(4.5)      -- the abdomen swings wider, and later
local GASTER_PITCH = math.rad(2.4)
local GASTER_LAG   = 0.55               -- ...and drags AGAINST the turn
local GASTER_LAG_MAX = math.rad(11)
local SWELL        = 0.030              -- breathing swell of the gaster segments
local GLOW_PULSE   = 0.18               -- brood nodules throbbing under the skin
local GLOW_HZ      = 0.7
local BLINK_MIN    = 3.0                -- seconds between blinks
local BLINK_MAX    = 8.0
local BLINK_TIME   = 0.11
local BLINK_SHUT   = 0.22               -- how far the eye shrinks while shut
local TURN_SMOOTH  = 7

-- Injection brace.
local BRACE_IN     = 6          -- blend rate into and out of the braced stance
local BRACE_OUT    = 1.9 * S    -- studs the feet splay outward while bracing
local BRACE_FWD    = 1.3 * S    -- studs the front pair digs in ahead
local BRACE_DOWN   = 0.5 * S    -- studs the feet press down into the ground
local BRACE_SINK   = 0.7 * S    -- studs the whole body drops over the wound
local BRACE_PITCH  = math.rad(7)   -- nose-down over the spike
local BRACE_HEAD   = math.rad(13)  -- ...and the head bows further still
local BRACE_GASTER = math.rad(8)   -- gaster cocks up as the front end digs in
local SHIVER       = 0.16 * S   -- amplitude of the tremor while the spike is in
local SHIVER_RATE  = 26         -- tremor cycles per second

-- ── Body groups ───────────────────────────────────────────────────────────────
-- Which rigid group each decor part belongs to, by the name the builder gave it.
-- Anything not listed (the trunk balls, the shoulder sockets) rides the core alone.
local HEAD_NAMES: { [string]: boolean } = {
	Neck = true, Skull = true, Snout = true, HornWing = true, Eye = true,
}
local GASTER_NAMES: { [string]: boolean } = {
	Petiole = true, GasterA = true, GasterB = true, GasterTip = true,
	Band1 = true, Band2 = true, BroodGlow = true, EggVent = true,
}
-- Never touched: the Base is the server's collision/HP box and the hitbox is what the
-- player's clicks land on. Both must keep the server's own CFrame.
local SKIP_NAMES: { [string]: boolean } = { Base = true, ClickHitbox = true }

-- Where each group turns about, in authored coordinates: the neck joint and the waist.
local HEAD_PIVOT   = Vector3.new(0, 2.6, -4.6)
local GASTER_PIVOT = Vector3.new(0, 3.6,  2.6)

local function isLegPart(name: string): boolean
	return name:match("^LegUpper%d+$") ~= nil
		or name:match("^LegFore%d+$") ~= nil
		or name:match("^Foot%d+$") ~= nil
end

type Leg = {
	upper: BasePart, fore: BasePart, pad: BasePart,   -- animated clones
	spec:   UnitVisuals.MotherLeg,
	side:   number,      -- -1 left, +1 right
	front:  boolean,
	group:  number,      -- diagonal pair: 1 or 2
	upLen:  number,      -- hip->knee bone length, in world studs
	loLen:  number,      -- knee->foot bone length
	reach:  number,      -- upLen + loLen, cached
	padRot: CFrame,      -- the foot pad's rotation relative to the body
	plant:  Vector3,     -- where this foot is standing, in the world
	from:   Vector3,     -- step start
	to:     Vector3,     -- step end
	stepT:  number,      -- 0..1 through a step; >= 1 means planted
}
-- One cloned body part: where it sits in her own space, and how it is allowed to breathe.
type Bit = {
	part:  BasePart,
	rest:  CFrame,       -- local transform, in her authored space
	size:  Vector3,      -- authored size, before any swell
	group: number,       -- 0 core, 1 head, 2 gaster
	kind:  number,       -- 0 plain, 1 swells with breath, 2 brood glow, 3 eye
}
type Entry = {
	base:    BasePart,
	legs:    { Leg },
	body:    { Bit },
	hidden:  { { part: BasePart, transparency: number } },
	lastPos: Vector3,
	lastFwd: Vector3,
	speed:   number,
	turn:    number,     -- smoothed yaw rate, radians/second
	brace:   number,     -- 0..1 blend into the injection stance
	phase:   number,     -- free-running clock for breathing and tremor
	blinkAt: number,     -- phase at which the next blink starts
}

local entries: { [string]: Entry } = {}
local pending: { [string]: boolean } = {}   -- attach waiting on parts to replicate
local legsFolder: Folder
local camera:     Camera
local conn:       RBXScriptConnection?

-- ── Posing ────────────────────────────────────────────────────────────────────
-- Where this foot wants to stand right now, given where the body is. Authored
-- coordinates, so scale them the way the decor builder does. The brace blend pushes the
-- stance wide and low; the front pair also digs in ahead of her.
local function homeFor(leg: Leg, bodyCF: CFrame, brace: number): Vector3
	local spec = leg.spec
	local at   = spec.foot * S
	if brace > 0.001 then
		local fwd = if leg.front then -BRACE_FWD else BRACE_FWD * 0.4
		at += Vector3.new(leg.side * BRACE_OUT, -BRACE_DOWN, fwd) * brace
	end
	return bodyCF:PointToWorldSpace(at)
end

-- Two-bone IK. Given the hip and where the foot has actually planted, find the knee:
-- the classic law-of-cosines circle intersection, with the elbow pushed along a pole
-- vector so it always breaks outward and upward rather than picking a side at random.
local function solveKnee(leg: Leg, hip: Vector3, foot: Vector3, bodyCF: CFrame): Vector3
	local delta = foot - hip
	local dist  = delta.Magnitude
	if dist < 1e-3 then return hip + Vector3.new(0, -leg.upLen, 0) end
	local dir = delta / dist

	local a = (leg.upLen * leg.upLen - leg.loLen * leg.loLen + dist * dist) / (2 * dist)
	local h = math.sqrt(math.max(0, leg.upLen * leg.upLen - a * a))

	local pole = bodyCF.RightVector * (leg.side * POLE_OUT) + Vector3.new(0, POLE_UP, 0)
	local perp = pole - dir * pole:Dot(dir)          -- the part of the pole across the bone
	if perp.Magnitude < 1e-3 then
		perp = dir:Cross(Vector3.yAxis)
		if perp.Magnitude < 1e-3 then perp = dir:Cross(Vector3.xAxis) end
	end
	return hip + dir * a + perp.Unit * h
end

-- Draw one limb from the hip to wherever its foot is standing. `animCF` is the body
-- INCLUDING its bob and roll, so the limb stays welded to a body that is moving under
-- its own animation, not just to the flat frame the server sends.
local function drawLeg(leg: Leg, animCF: CFrame, foot: Vector3)
	local hip = animCF:PointToWorldSpace(leg.spec.hip * S)

	-- The one hard rule: never draw past what the bones can span. Everything else tries
	-- to keep the foot inside reach; this makes it impossible to fail.
	local delta = foot - hip
	local dist  = delta.Magnitude
	local limit = leg.reach * REACH_SAFE
	if dist > limit and dist > 1e-3 then
		foot = hip + delta * (limit / dist)
	end

	local knee = solveKnee(leg, hip, foot, animCF)
	UnitVisuals.orientYBetween(leg.upper, hip,  knee, UPPER_THICK)
	UnitVisuals.orientYBetween(leg.fore,  knee, foot, FORE_THICK)
	leg.pad.CFrame = CFrame.new(foot) * (animCF.Rotation * leg.padRot)
end

-- ── Per-frame ─────────────────────────────────────────────────────────────────
-- The body's own animation, as an offset applied inside her frame: the core transform
-- everything rides, plus the head's and the gaster's rotations about their joints.
local function poseBody(e: Entry, animCF: CFrame, headRot: CFrame, gasterRot: CFrame,
	swell: number, glow: number, blink: number)
	local headCF   = CFrame.new(HEAD_PIVOT * S)   * headRot   * CFrame.new(-HEAD_PIVOT * S)
	local gasterCF = CFrame.new(GASTER_PIVOT * S) * gasterRot * CFrame.new(-GASTER_PIVOT * S)

	for _, b in e.body do
		local g = if b.group == 1 then headCF elseif b.group == 2 then gasterCF else nil
		b.part.CFrame = if g then animCF * g * b.rest else animCF * b.rest

		if b.kind == 1 then
			b.part.Size = b.size * swell
		elseif b.kind == 2 then
			b.part.Size = b.size * glow
		elseif b.kind == 3 then
			b.part.Size = b.size * blink
		end
	end
end

local function stepEntry(e: Entry, dt: number, bodyCF: CFrame)
	-- Body speed, smoothed: it drives how far a step reaches and how fast it lands.
	local pos    = bodyCF.Position
	local moved  = (pos - e.lastPos).Magnitude
	e.lastPos    = pos
	local inst   = if dt > 1e-4 then moved / dt else 0
	e.speed     += (inst - e.speed) * math.min(1, dt * SPEED_SMOOTH)
	e.phase     += dt

	local speedN = math.clamp(e.speed / SPEED_REF, 0, 1)

	local injecting = e.base:GetAttribute("Injecting") == true
	local target    = if injecting then 1 else 0
	e.brace += (target - e.brace) * math.min(1, dt * BRACE_IN)

	-- Forward is -Z in her own space (the head end), and how fast that swings is what
	-- the head leads into and the gaster drags against.
	local look = bodyCF.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local turned = e.lastFwd:Cross(look).Y / math.max(dt, 1e-3)
	e.lastFwd = look
	e.turn += (turned - e.turn) * math.min(1, dt * TURN_SMOOTH)

	-- ── The gait ──────────────────────────────────────────────────────────────
	-- Only one diagonal pair may be off the ground at a time. Find out whether either is
	-- already committed before letting anybody else pick a foot up.
	local busy = 0
	for _, leg in e.legs do
		if leg.stepT < 1 then busy = leg.group end
	end

	-- A pair has to be back down before the other pair runs out of leg, so the time she
	-- takes to cover one stride IS the time a step is allowed to last. Deriving it keeps
	-- the gait honest at any speed instead of leaving a hand-tuned duration to fall behind
	-- her the moment she is quick -- which is what leaves feet skating or over-reached.
	local lead     = math.min(e.speed * STEP_LEAD, STEP_LEAD_MAX)
	local stride   = STEP_TRIGGER + lead
	local stepTime = STEP_TIME
	if e.speed > 0.1 then
		stepTime = math.clamp(stride / e.speed, STEP_TIME_MIN, STEP_TIME)
	end

	for _, leg in e.legs do
		local home = homeFor(leg, bodyCF, e.brace)

		if leg.stepT < 1 then
			-- Mid-step: arc from where it left the ground to where it is setting down.
			leg.stepT = math.min(1, leg.stepT + dt / stepTime)
			local t    = leg.stepT
			local ease = t * t * (3 - 2 * t)
			local arc  = math.sin(t * math.pi) * STEP_LIFT
			leg.plant  = leg.from:Lerp(leg.to, ease) + Vector3.new(0, arc, 0)
			if leg.stepT >= 1 then leg.plant = leg.to end
		else
			local hip  = bodyCF:PointToWorldSpace(leg.spec.hip * S)
			local ext  = (leg.plant - hip).Magnitude / leg.reach
			local off  = (home - leg.plant).Magnitude

			if e.brace > 0.05 then
				-- Bracing she is stationary and must not lift a foot; the stance just
				-- creeps to the braced position, which reads as digging in.
				leg.plant = leg.plant:Lerp(home, math.min(1, dt * BRACE_IN))
			elseif ext > REACH_FORCE then
				-- About to run out of leg. This one goes now, pair or no pair: a limb
				-- that cannot reach its own foot is worse than a broken gait.
				leg.from, leg.to, leg.stepT = leg.plant, home + look * lead, 0
				busy = leg.group
			elseif off > STEP_TRIGGER and (busy == 0 or busy == leg.group) then
				leg.from, leg.to, leg.stepT = leg.plant, home + look * lead, 0
				busy = leg.group
			end
		end
	end

	-- ── The body ──────────────────────────────────────────────────────────────
	-- The body's motion is read straight off the legs rather than off a clock of its
	-- own: `swing` is how far through the air the stepping pair is, and `twist` is which
	-- pair it is. Everything below hangs on those two, so the bob can never drift out of
	-- step with the feet the way a free-running gait phase does, and it stops dead the
	-- moment she does -- no stride length to keep in sync with the trigger distance.
	local breath = math.sin(e.phase * math.pi * 2 * BREATH_HZ)
	local swing      = 0
	local swingGroup = 0
	for _, leg in e.legs do
		if leg.stepT < 1 then
			local s = math.sin(leg.stepT * math.pi)
			if s > swing then swing, swingGroup = s, leg.group end
		end
	end
	-- A diagonal-pair gait does not roll a body, it twists it: the shoulders turn one
	-- way as the hips turn the other, and which way depends on the pair in the air.
	local twist = if swingGroup == 1 then swing else -swing

	local bob   = -swing * BOB * speedN + breath * BREATH
	local roll  =  twist * ROLL * speedN
	local pitch = -swing * PITCH * speedN

	bob   -= BRACE_SINK * e.brace
	pitch -= BRACE_PITCH * e.brace   -- negative pitches her nose down over the wound

	local shiverX, shiverY = 0, 0
	if e.brace > 0.05 then
		local w = math.sin(e.phase * SHIVER_RATE) * SHIVER * e.brace
		shiverX = w
		shiverY = math.abs(w) * 0.5
	end

	local core = CFrame.new(shiverX, bob + shiverY, 0) * CFrame.Angles(pitch, 0, roll)
	local animCF = bodyCF * core

	-- The head commits to a turn before her mass does, which is most of what sells a
	-- turn, and holds itself against the twist of the body under it. Standing still it
	-- sweeps slowly on its own: a creature that watches the field, not a statue.
	local lead2   = math.clamp(e.turn * HEAD_LEAD, -HEAD_LEAD_MAX, HEAD_LEAD_MAX)
	local idle    = math.sin(e.phase * 0.37) * HEAD_IDLE * (1 - speedN)
	local headRot = CFrame.Angles(
		swing * HEAD_PITCH * speedN - BRACE_HEAD * e.brace,
		-twist * HEAD_YAW * speedN + lead2 + idle,
		0)

	-- The abdomen is the heaviest thing on her and behaves like it: it swings wider than
	-- the body, the other way, and drags AGAINST a turn rather than leading it.
	local drag      = math.clamp(-e.turn * GASTER_LAG, -GASTER_LAG_MAX, GASTER_LAG_MAX)
	local gasterRot = CFrame.Angles(
		swing * GASTER_PITCH * speedN + BRACE_GASTER * e.brace,
		twist * GASTER_YAW * speedN + drag,
		0)

	local swell = 1 + breath * SWELL
	local glow  = 1 + math.sin(e.phase * math.pi * 2 * GLOW_HZ) * GLOW_PULSE

	-- Blink: a quick shrink of the eye nodules, on an irregular clock.
	local blink = 1
	if e.phase >= e.blinkAt then
		local into = e.phase - e.blinkAt
		if into < BLINK_TIME then
			blink = 1 - (1 - BLINK_SHUT) * math.sin(into / BLINK_TIME * math.pi)
		else
			e.blinkAt = e.phase + BLINK_MIN + math.random() * (BLINK_MAX - BLINK_MIN)
		end
	end

	poseBody(e, animCF, headRot, gasterRot, swell, glow, blink)

	-- Feet last, so they are drawn against the body pose they have to hold up.
	for _, leg in e.legs do
		local foot = leg.plant
		if e.brace > 0.05 then
			-- A fine tremor through the whole stance while the spike is in the ground.
			local w = math.sin((e.phase + leg.side * 0.7) * SHIVER_RATE) * SHIVER * e.brace
			foot += Vector3.new(w, math.abs(w) * 0.5, w * 0.6)
		end
		drawLeg(leg, animCF, foot)
	end
end

local function step(dt: number)
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	for id, e in entries do
		if not e.base.Parent then
			MotherLegs.detach(id)
			continue
		end

		local bodyCF = UnitVisuals.motherBodyCF(e.base)
		local d      = bodyCF.Position - camPos
		if d:Dot(d) > CULL_DIST2 then
			-- Far off: skip the gait and the body's animation, but still draw her in a
			-- flat standing pose. Leaving the clones where they were would strand a set
			-- of legs on the ground behind her.
			e.lastPos = bodyCF.Position
			for _, leg in e.legs do
				leg.plant = homeFor(leg, bodyCF, 0)
				leg.stepT = 1
				drawLeg(leg, bodyCF, leg.plant)
			end
			poseBody(e, bodyCF, CFrame.identity, CFrame.identity, 1, 1, 1)
			continue
		end

		stepEntry(e, math.min(dt, 0.1), bodyCF)
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local function attachNow(ccId: string, model: Model)
	if entries[ccId] then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end
	local bodyCF = UnitVisuals.motherBodyCF(base)

	local hidden: { { part: BasePart, transparency: number } } = {}
	-- Clone for animating, then hide the server's copy. Transparency is never touched by
	-- the server after build, so hiding it locally sticks; the original value is kept so
	-- detach can hand the model back exactly as it was built.
	local function clone(src: BasePart, shadows: boolean): BasePart
		local p      = src:Clone()
		p.Anchored   = true
		p.CanCollide = false
		p.CanQuery   = false
		p.CanTouch   = false
		p.CastShadow = shadows and src.CastShadow
		p.Parent     = legsFolder
		hidden[#hidden + 1] = { part = src, transparency = src.Transparency }
		src.Transparency = 1
		return p
	end

	local legs: { Leg } = {}
	for i, spec in UnitVisuals.MOTHER_LEGS do
		local upper = model:FindFirstChild("LegUpper" .. i) :: BasePart?
		local fore  = model:FindFirstChild("LegFore" .. i) :: BasePart?
		local pad   = model:FindFirstChild("Foot" .. i) :: BasePart?
		if not (upper and fore and pad) then continue end

		local aUpper, aFore, aPad = clone(upper, false), clone(fore, false), clone(pad, false)

		-- Bone lengths come from the authored rig, so the IK can never stretch the limb
		-- past what the model was built with.
		local upLen = (spec.knee - spec.hip).Magnitude * S
		local loLen = (spec.foot - spec.knee).Magnitude * S
		local foot0 = bodyCF:PointToWorldSpace(spec.foot * S)
		legs[#legs + 1] = {
			upper = aUpper, fore = aFore, pad = aPad,
			spec  = spec,
			side  = if spec.hip.X >= 0 then 1 else -1,
			front = spec.foot.Z < spec.hip.Z,   -- the front pair reaches forward of its hip
			group = if spec.phase < 1 then 1 else 2,
			upLen = upLen,
			loLen = loLen,
			reach = upLen + loLen,
			padRot = bodyCF.Rotation:Inverse() * pad.CFrame.Rotation,
			plant = foot0, from = foot0, to = foot0, stepT = 1,
		}
	end
	if #legs == 0 then return end

	-- Everything else she is built from, filed into the group that moves it. Read off the
	-- model rather than rebuilt, so a change to her decor needs no change here: a new
	-- part simply rides the core until it is named in one of the group lists.
	local body: { Bit } = {}
	local inverse = bodyCF:Inverse()
	for _, part in model:GetChildren() do
		if not part:IsA("BasePart") then continue end
		if SKIP_NAMES[part.Name] or isLegPart(part.Name) then continue end

		local group = 0
		if HEAD_NAMES[part.Name] then group = 1
		elseif GASTER_NAMES[part.Name] then group = 2 end

		local kind = 0
		if part.Name == "BroodGlow" then kind = 2
		elseif part.Name == "Eye" then kind = 3
		elseif group == 2 then kind = 1 end   -- the abdomen is what visibly breathes

		body[#body + 1] = {
			part  = clone(part, true),
			rest  = inverse * part.CFrame,
			size  = part.Size,
			group = group,
			kind  = kind,
		}
	end

	local look = bodyCF.LookVector
	entries[ccId] = {
		base = base, legs = legs, body = body, hidden = hidden,
		lastPos = bodyCF.Position,
		lastFwd = Vector3.new(look.X, 0, look.Z).Unit,
		speed = 0, turn = 0, brace = 0, phase = 0,
		blinkAt = BLINK_MIN,
	}
	if not conn then conn = PerfProbe.onRender("MotherLegs", step) end
end

-- The Mother's model can replicate a beat before her decor parts do (she now spawns
-- already uprooted, so this fires the instant she appears), so wait for the legs to
-- arrive rather than silently ending up with a Mother who skates.
function MotherLegs.attach(ccId: string, model: Model)
	if entries[ccId] or pending[ccId] then return end
	pending[ccId] = true
	task.spawn(function()
		local ready = model:WaitForChild("LegUpper1", 10)
		-- detach() clears our flag to cancel us if she rooted again while we waited.
		local stillWanted = pending[ccId] == true
		pending[ccId] = nil
		if stillWanted and ready and model.Parent and not entries[ccId] then
			attachNow(ccId, model)
		end
	end)
end

function MotherLegs.detach(ccId: string)
	local e = entries[ccId]
	entries[ccId] = nil
	pending[ccId] = nil   -- cancels an attach still waiting on replication
	if e then
		for _, leg in e.legs do
			leg.upper:Destroy()
			leg.fore:Destroy()
			leg.pad:Destroy()
		end
		for _, b in e.body do
			b.part:Destroy()
		end
		-- Hand the static creature back, exactly as the builder left it.
		for _, h in e.hidden do
			if h.part.Parent then h.part.Transparency = h.transparency end
		end
	end
	if next(entries) == nil and conn then
		conn:Disconnect()
		conn = nil
	end
end

function MotherLegs.init(cam: Camera)
	camera = cam
	local existing = workspace:FindFirstChild("MotherLegs")
	if existing and existing:IsA("Folder") then
		legsFolder = existing
	else
		legsFolder      = Instance.new("Folder")
		legsFolder.Name = "MotherLegs"
		legsFolder.Parent = workspace
	end
end

return MotherLegs
