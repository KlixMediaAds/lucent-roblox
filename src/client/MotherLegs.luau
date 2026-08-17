--[[
	MotherLegs — procedural walk for the uprooted Hollowed Mother.

	Her four splayed legs are static decor parts baked into the model by
	UnitVisuals.buildMotherDecor. Those parts belong to the server, and it re-sends
	their CFrames every frame she walks (Model:PivotTo), so animating them directly
	would just get overwritten. Instead this CLONES them into a client-only folder,
	hides the originals, and animates the clones — the same trick MechLegs uses for
	the Human core. Cloning rather than rebuilding means the walking legs keep the
	exact colour, material and taper the model was built with.

	The gait is FOOT-PLANTED, not swept. A foot holds a fixed point in the WORLD and
	does not move at all while the body walks over it; only when the body has carried
	its hip too far from that point does the leg pick up, arc through the air and set
	down ahead. That is the whole difference between a creature walking and a model
	sliding with its legs waving:

	  • A foot's world position is state, not a function of the body's. It is
	    recomputed only during a step.
	  • Steps are gated into diagonal pairs — front-left with rear-right — so she is
	    never off more than two feet at once and the stance stays a stable tripod.
	  • A step lands AHEAD of where the foot is currently wanted, by an amount that
	    scales with how fast she is going, so at speed she reaches rather than shuffles.
	  • The knee is a real two-bone IK solve off the authored bone lengths, with the
	    pole vector kicked outward, so the limb folds out sideways like a salamander's
	    instead of stretching straight at the ground.
	  • Stop moving and the feet simply stay where they are. Nothing skates, ever.

	Injecting is a separate pose blended on top: she widens her stance and digs in,
	the front pair braced forward, and shivers while the spike is in the ground. The
	server flags this with an `Injecting` attribute on her Base so every client sees it,
	not just the one who gave the order.

	API:
	  MotherLegs.init(camera)
	  MotherLegs.attach(ccId, model)   — start walking; safe to call twice
	  MotherLegs.detach(ccId)          — restore the model's own planted legs
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local MotherLegs = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
-- Everything measured in studs is authored at the Mother's full size and shrunk by
-- MOTHER_SCALE, so resizing her rescales her stride with her.
local S            = UnitVisuals.MOTHER_SCALE
local STEP_TRIGGER = 2.4 * S    -- studs a foot may fall behind its home before it steps
local STEP_LEAD    = 0.55       -- seconds of travel a step aims ahead of home
local STEP_LEAD_MAX= 3.2 * S    -- cap on that reach, so a sprint does not do the splits
local STEP_TIME    = 0.34       -- seconds a foot spends in the air at a walk
local STEP_TIME_MIN= 0.16       -- ...and at full speed
local STEP_LIFT    = 1.7 * S    -- studs a stepping foot arcs up
local UPPER_THICK  = 1.35 * S   -- matches buildMotherDecor's LegUpper
local FORE_THICK   = 1.0 * S    -- matches buildMotherDecor's LegFore
local POLE_OUT     = 1.0        -- how hard the knee is pushed out to the side
local POLE_UP      = 0.45       -- ...and up, so it folds over rather than under
local SPEED_SMOOTH = 8          -- how fast the measured speed follows reality
local CULL_DIST2   = 700 * 700

-- Injection brace.
local BRACE_IN     = 6          -- blend rate into and out of the braced stance
local BRACE_OUT    = 1.9 * S    -- studs the feet splay outward while bracing
local BRACE_FWD    = 1.3 * S    -- studs the front pair digs in ahead
local BRACE_DOWN   = 0.5 * S    -- studs the feet press down into the ground
local SHIVER       = 0.16 * S   -- amplitude of the tremor while the spike is in
local SHIVER_RATE  = 26         -- tremor cycles per second

type Leg = {
	upper: BasePart, fore: BasePart, pad: BasePart,   -- animated clones
	hidden: { BasePart },                             -- the model's own parts, hidden
	spec:   UnitVisuals.MotherLeg,
	side:   number,      -- -1 left, +1 right
	front:  boolean,
	group:  number,      -- diagonal pair: 1 or 2
	upLen:  number,      -- hip→knee bone length, in world studs
	loLen:  number,      -- knee→foot bone length
	padRot: CFrame,      -- the foot pad's rotation relative to the body
	plant:  Vector3,     -- where this foot is standing, in the world
	from:   Vector3,     -- step start
	to:     Vector3,     -- step end
	stepT:  number,      -- 0..1 through a step; >= 1 means planted
}
type Entry = {
	base:    BasePart,
	legs:    { Leg },
	lastPos: Vector3,
	speed:   number,
	brace:   number,     -- 0..1 blend into the injection stance
	phase:   number,     -- free-running clock for the tremor
}

local entries: { [string]: Entry } = {}
local pending: { [string]: boolean } = {}   -- attach waiting on parts to replicate
local legsFolder: Folder
local camera:     Camera
local conn:       RBXScriptConnection?

-- ── Posing ────────────────────────────────────────────────────────────────────
-- Where this foot wants to stand right now, given where the body is. Authored
-- coordinates, so scale them the way the decor builder does. The brace blend pushes
-- the stance wide and low; the front pair also digs in ahead of her.
local function homeFor(leg: Leg, baseCF: CFrame, brace: number): Vector3
	local spec = leg.spec
	local at   = spec.foot * S
	if brace > 0.001 then
		local fwd = if leg.front then BRACE_FWD else -BRACE_FWD * 0.4
		at += Vector3.new(leg.side * BRACE_OUT, -BRACE_DOWN, fwd) * brace
	end
	return baseCF:PointToWorldSpace(at)
end

-- Two-bone IK. Given the hip and where the foot has actually planted, find the knee:
-- the classic law-of-cosines circle intersection, with the elbow pushed along a pole
-- vector so it always breaks outward and upward rather than picking a side at random.
local function solveKnee(leg: Leg, hip: Vector3, foot: Vector3, baseCF: CFrame): Vector3
	local delta = foot - hip
	local dist  = delta.Magnitude
	local reach = leg.upLen + leg.loLen
	if dist < 1e-3 then return hip + Vector3.new(0, -leg.upLen, 0) end
	-- Never let the solve go imaginary: a foot further away than the leg is long just
	-- straightens the limb instead of snapping it.
	dist = math.min(dist, reach * 0.999)
	local dir = delta / delta.Magnitude

	local a = (leg.upLen * leg.upLen - leg.loLen * leg.loLen + dist * dist) / (2 * dist)
	local h = math.sqrt(math.max(0, leg.upLen * leg.upLen - a * a))

	local pole = baseCF.RightVector * (leg.side * POLE_OUT) + Vector3.new(0, POLE_UP, 0)
	local perp = pole - dir * pole:Dot(dir)          -- the part of the pole across the bone
	if perp.Magnitude < 1e-3 then
		perp = dir:Cross(Vector3.yAxis)
		if perp.Magnitude < 1e-3 then perp = dir:Cross(Vector3.xAxis) end
	end
	return hip + dir * a + perp.Unit * h
end

local function drawLeg(leg: Leg, baseCF: CFrame, foot: Vector3)
	local hip  = baseCF:PointToWorldSpace(leg.spec.hip * S)
	local knee = solveKnee(leg, hip, foot, baseCF)
	UnitVisuals.orientYBetween(leg.upper, hip,  knee, UPPER_THICK)
	UnitVisuals.orientYBetween(leg.fore,  knee, foot, FORE_THICK)
	leg.pad.CFrame = CFrame.new(foot) * (baseCF.Rotation * leg.padRot)
end

-- ── Per-frame ─────────────────────────────────────────────────────────────────
local function stepEntry(e: Entry, dt: number, baseCF: CFrame)
	-- Body speed, smoothed: it drives how far a step reaches and how fast it lands.
	local pos    = baseCF.Position
	local moved  = (pos - e.lastPos).Magnitude
	e.lastPos    = pos
	local inst   = if dt > 1e-4 then moved / dt else 0
	e.speed     += (inst - e.speed) * math.min(1, dt * SPEED_SMOOTH)
	e.phase     += dt

	local injecting = e.base:GetAttribute("Injecting") == true
	local target    = if injecting then 1 else 0
	e.brace += (target - e.brace) * math.min(1, dt * BRACE_IN)

	local look = baseCF.ZVector   -- buildMotherDecor flips her, so +Z is forward, not LookVector
	look = Vector3.new(look.X, 0, look.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis

	-- Only one diagonal pair may be off the ground at a time. Find out whether either
	-- is already committed before letting anybody else pick a foot up.
	local busy = 0
	for _, leg in e.legs do
		if leg.stepT < 1 then busy = leg.group end
	end

	local stepTime = math.max(STEP_TIME_MIN, STEP_TIME - e.speed * 0.006)
	local lead     = math.min(e.speed * STEP_LEAD, STEP_LEAD_MAX)

	for _, leg in e.legs do
		local home = homeFor(leg, baseCF, e.brace)

		if leg.stepT < 1 then
			-- Mid-step: arc from where it left the ground to where it is setting down.
			leg.stepT = math.min(1, leg.stepT + dt / stepTime)
			local t   = leg.stepT
			local ease = t * t * (3 - 2 * t)
			local arc  = math.sin(t * math.pi) * STEP_LIFT
			leg.plant  = leg.from:Lerp(leg.to, ease) + Vector3.new(0, arc, 0)
			if leg.stepT >= 1 then leg.plant = leg.to end
		else
			-- Planted. Has the body carried the hip too far from this foot to keep it?
			local dx = home.X - leg.plant.X
			local dz = home.Z - leg.plant.Z
			local dy = home.Y - leg.plant.Y
			local off2 = dx * dx + dz * dz + dy * dy
			-- While bracing she is stationary and must not lift a foot; the stance just
			-- creeps to the braced position, which reads as digging in.
			if e.brace > 0.05 then
				leg.plant = leg.plant:Lerp(home, math.min(1, dt * BRACE_IN))
			elseif off2 > STEP_TRIGGER * STEP_TRIGGER and (busy == 0 or busy == leg.group) then
				leg.from  = leg.plant
				leg.to    = home + look * lead
				leg.stepT = 0
				busy      = leg.group
			end
		end

		local foot = leg.plant
		if e.brace > 0.05 then
			-- A fine tremor through the whole stance while the spike is in the ground.
			local w = math.sin((e.phase + leg.side * 0.7) * SHIVER_RATE) * SHIVER * e.brace
			foot += Vector3.new(w, math.abs(w) * 0.5, w * 0.6)
		end
		drawLeg(leg, baseCF, foot)
	end
end

local function step(dt: number)
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	for id, e in entries do
		if not e.base.Parent then
			MotherLegs.detach(id)
			continue
		end

		local baseCF = e.base.CFrame
		local d      = baseCF.Position - camPos
		if d:Dot(d) > CULL_DIST2 then
			-- Far off screen: skip the pose work, but keep the feet under her so she is
			-- not owed four enormous catch-up steps the moment she comes back into view.
			e.lastPos = baseCF.Position
			for _, leg in e.legs do
				leg.plant = homeFor(leg, baseCF, 0)
				leg.stepT = 1
			end
			continue
		end

		stepEntry(e, math.min(dt, 0.1), baseCF)
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local function attachNow(ccId: string, model: Model)
	if entries[ccId] then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end
	local baseCF = base.CFrame

	local legs: { Leg } = {}
	for i, spec in UnitVisuals.MOTHER_LEGS do
		local upper = model:FindFirstChild("LegUpper" .. i) :: BasePart?
		local fore  = model:FindFirstChild("LegFore" .. i) :: BasePart?
		local pad   = model:FindFirstChild("Foot" .. i) :: BasePart?
		if not (upper and fore and pad) then continue end

		-- Clone for animating, then hide the server's copies. Transparency is never
		-- touched by the server after build, so hiding them locally sticks.
		local function clone(src: BasePart): BasePart
			local p      = src:Clone()
			p.Anchored   = true
			p.CanCollide = false
			p.CanQuery   = false
			p.CastShadow = false
			p.Parent     = legsFolder
			return p
		end
		local aUpper, aFore, aPad = clone(upper), clone(fore), clone(pad)
		upper.Transparency, fore.Transparency, pad.Transparency = 1, 1, 1

		-- Bone lengths come from the authored rig, so the IK can never stretch the limb
		-- past what the model was built with.
		local foot0 = baseCF:PointToWorldSpace(spec.foot * S)
		legs[#legs + 1] = {
			upper = aUpper, fore = aFore, pad = aPad,
			hidden = { upper, fore, pad },
			spec  = spec,
			side  = if spec.hip.X >= 0 then 1 else -1,
			front = spec.foot.Z < spec.hip.Z,   -- the front pair reaches forward of its hip
			group = if spec.phase < 1 then 1 else 2,
			upLen = (spec.knee - spec.hip).Magnitude * S,
			loLen = (spec.foot - spec.knee).Magnitude * S,
			padRot = baseCF.Rotation:Inverse() * pad.CFrame.Rotation,
			plant = foot0, from = foot0, to = foot0, stepT = 1,
		}
	end
	if #legs == 0 then return end

	entries[ccId] = {
		base = base, legs = legs, lastPos = base.Position,
		speed = 0, brace = 0, phase = 0,
	}
	if not conn then conn = RunService.RenderStepped:Connect(step) end
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
			-- Hand the planted legs back to the model, exactly as it built them.
			for _, p in leg.hidden do
				if p.Parent then p.Transparency = 0 end
			end
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
