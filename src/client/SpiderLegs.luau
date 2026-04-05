-- SpiderLegs.luau
-- Client-only procedural leg animation for Elite units.
--
-- Key design choices:
--   • animClock accumulates ONLY when the unit is moving, so legs freeze
--     when idle and animate at a rate proportional to actual movement speed.
--   • Single shared Heartbeat connection drives all active units.
--   • Distance-square cull avoids work for off-screen units.
--   • 8 parts per unit (4 legs × upper + lower segment), all Anchored.

local RunService = game:GetService("RunService")

local SpiderLegs = {}

-- ── Geometry (3× reach relative to the original design) ──────────────────────
-- Body is 5 × 6 × 5; center sits at Y ≈ 3.1 above flat ground.
-- Foot Y = -3.0 local → world Y ≈ 0.1 (ground contact).

local LEG_WIDTH    = 1.0    -- part cross-section thickness (studs)

-- Local-space hip attachment points, one per leg.
-- Order: front-left, front-right, back-left, back-right.
local HIP = {
	Vector3.new(-2.3,  0.5,  2.2),
	Vector3.new( 2.3,  0.5,  2.2),
	Vector3.new(-2.3,  0.5, -2.2),
	Vector3.new( 2.3,  0.5, -2.2),
}

-- Local-space foot REST positions (3× outward reach vs. original).
-- Y stays at -3.0 so feet always touch the ground regardless of reach.
local FOOT_REST = {
	Vector3.new(-9.2, -3.0,  6.8),
	Vector3.new( 9.2, -3.0,  6.8),
	Vector3.new(-9.2, -3.0, -6.8),
	Vector3.new( 9.2, -3.0, -6.8),
}

-- Walk cycle
local WALK_FREQ    = 2.6    -- full cycles per second at max speed
local STEP_LIFT    = 4.5    -- max foot lift (studs)
local STEP_SWING   = 1.95   -- forward/back foot swing amplitude (studs)

-- Knee bow: pushes the knee outward / upward from the hip-foot midpoint.
local KNEE_LATERAL = 4.0
local KNEE_UP      = 0.8

-- Spider trot gait: diagonal pairs step together.
--   FL + BR lift at phase 0, FR + BL lift at phase π.
local LEG_PHASE = { 0, math.pi, math.pi, 0 }   -- FL, FR, BL, BR

-- Speed at which the walk animation runs at full frequency (Elite move speed).
local FULL_SPEED = 18   -- studs / second

-- Distance-squared cull threshold.
local CULL_SQ = 320 * 320

-- ── Helper: orient a block so its Y axis runs from A to B ─────────────────────

local function orientBetween(part: BasePart, a: Vector3, b: Vector3)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.05 then return end

	local dir   = delta * (1 / len)

	local right = dir:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 0.01 then
		right = dir:Cross(Vector3.new(1, 0, 0))
	end
	right = right.Unit
	local back = right:Cross(dir)

	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(LEG_WIDTH, len, LEG_WIDTH)
end

-- ── State ─────────────────────────────────────────────────────────────────────

type Entry = {
	body:        BasePart,
	parts:       { BasePart },
	phase:       number,
	lastPos:     Vector3,    -- previous frame position for speed estimation
	animClock:   number,     -- accumulated animation time, driven by movement speed
	smoothSpeed: number,     -- exponentially-smoothed speed (avoids snap jitter)
	conn:        RBXScriptConnection,
}

local active: { [string]: Entry } = {}
local legsFolder: Folder
local camera: Camera

-- ── Attach / Detach ───────────────────────────────────────────────────────────

function SpiderLegs.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local color = body.BrickColor
	local parts: { BasePart } = {}

	for i = 1, 4 do
		for _, seg in { "U", "L" } do
			local p         = Instance.new("Part")
			p.Name          = string.format("Leg%d_%s", i, seg)
			p.Size          = Vector3.new(LEG_WIDTH, 2, LEG_WIDTH)
			p.BrickColor    = color
			p.Material      = Enum.Material.SmoothPlastic
			p.Anchored      = true
			p.CanCollide    = false
			p.CastShadow    = false
			p.CanQuery      = false
			p.Parent        = legsFolder
			table.insert(parts, p)
		end
	end

	-- Golden-ratio spread so no two units share the same gait phase.
	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		SpiderLegs.detach(unitId)
	end)

	active[unitId] = {
		body        = body,
		parts       = parts,
		phase       = phase,
		lastPos     = body.Position,
		animClock   = 0,
		smoothSpeed = 0,
		conn        = conn,
	}
end

function SpiderLegs.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, p in e.parts do
		p:Destroy()
	end
end

-- ── Animation loop ────────────────────────────────────────────────────────────

function SpiderLegs.init(cam: Camera)
	camera = cam

	legsFolder        = Instance.new("Folder")
	legsFolder.Name   = "_EliteLegs"
	legsFolder.Parent = workspace

	-- RenderStepped fires immediately before the frame is rendered, so
	-- part positions are always fresh with zero visual lag.
	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body

			if not body.Parent then
				SpiderLegs.detach(unitId)
				continue
			end

			-- ── Distance cull ──────────────────────────────────────────────
			local bpos = body.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then
				e.lastPos = bpos   -- keep lastPos fresh so speed is correct on uncull
				continue
			end

			-- ── Movement speed → animation clock ──────────────────────────
			-- Raw speed from position delta, then exponentially smoothed to
			-- prevent the jitter caused by server replication step variance.
			local moved    = (bpos - e.lastPos).Magnitude
			e.lastPos      = bpos
			local rawSpeed = moved / math.max(dt, 0.001)

			-- Smooth with a fast-rise / slow-fall filter so legs ease in/out
			-- naturally rather than snapping when the server update ticks.
			local alpha = if rawSpeed > e.smoothSpeed then 0.25 else 0.08
			e.smoothSpeed  = e.smoothSpeed + (rawSpeed - e.smoothSpeed) * alpha

			local speedFactor = math.min(e.smoothSpeed / FULL_SPEED, 1.0)
			e.animClock      += dt * speedFactor * WALK_FREQ * math.pi * 2

			-- ── Per-unit frame cache ───────────────────────────────────────
			local cf     = body.CFrame
			local rv     = cf.RightVector
			local lv     = cf.LookVector
			local phase  = e.phase
			local clock  = e.animClock
			local parts  = e.parts

			for i = 1, 4 do
				local theta = clock + phase + LEG_PHASE[i]
				local sinT  = math.sin(theta)
				local cosT  = math.cos(theta)

				-- Scale lift and swing by speed so legs stay still when unit is idle.
				local lift  = math.max(0, sinT) * STEP_LIFT  * speedFactor
				local swing = cosT               * STEP_SWING * speedFactor

				-- World-space points
				local hipW      = cf:PointToWorldSpace(HIP[i])
				local footRestW = cf:PointToWorldSpace(FOOT_REST[i])

				local footW = Vector3.new(
					footRestW.X + lv.X * swing,
					footRestW.Y + lift,
					footRestW.Z + lv.Z * swing)

				-- Knee: midpoint + outward bow + upward bow
				local lateralSign = if i == 2 or i == 4 then 1 else -1
				local kneeW = (hipW + footW) * 0.5
					+ rv * (lateralSign * KNEE_LATERAL)
					+ Vector3.new(0, KNEE_UP, 0)

				local pIdx = (i - 1) * 2 + 1
				orientBetween(parts[pIdx],     hipW,  kneeW)
				orientBetween(parts[pIdx + 1], kneeW, footW)
			end
		end
	end)
end

return SpiderLegs
