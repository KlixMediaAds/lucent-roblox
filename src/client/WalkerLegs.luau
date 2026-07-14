-- WalkerLegs.luau
-- Client-only procedural bipedal walking animation for Howitzer steam walker units.
-- Architecture mirrors SpiderLegs: single shared RenderStepped loop, distance cull,
-- speed-proportional animation clock.
--
-- Root body: 8×14×8; center sits at Y≈7 above flat ground.
-- Hip pivots: local (±4, 0, 0) → world Y ≈ 7.
-- Foot rest:  local (±4.8, -7, 0.3) → world Y ≈ 0 (ground contact).

local RunService = game:GetService("RunService")

local WalkerLegs = {}

-- ── Geometry constants ────────────────────────────────────────────────────────
local UPPER_THICK  = 2.4    -- upper leg segment cross-section (studs)
local LOWER_THICK  = 2.0    -- lower leg segment cross-section
local PISTON_THICK = 0.7    -- brass piston accent rod cross-section
local KNEE_DIAM    = 2.6    -- knee ball diameter

-- Hip attachment points in root local space
local HIP = {
	Vector3.new(-4.0, 0.0,  0.0),   -- left
	Vector3.new( 4.0, 0.0,  0.0),   -- right
}

-- Foot rest positions in root local space (ground level = root.center.Y - 7)
local FOOT_REST = {
	Vector3.new(-4.8, -7.0, 0.3),   -- left
	Vector3.new( 4.8, -7.0, 0.3),   -- right
}

-- ── Walk parameters ───────────────────────────────────────────────────────────
local WALK_FREQ      = 1.1    -- gait cycles per second at full speed (slow, deliberate)
local STEP_LIFT      = 3.0    -- max foot lift in studs
local STEP_SWING     = 2.2    -- forward/back swing amplitude in studs (along LookVector)
local KNEE_LATERAL   = 2.0    -- outward knee bow at rest (studs from hip-foot midpoint)
local KNEE_UP_BASE   = 1.5    -- knee height above hip-foot midpoint at rest
local KNEE_UP_STEP   = 3.0    -- extra knee rise at peak step lift

-- Idle piston movement (very subtle, always running)
local IDLE_AMP   = 0.25   -- max foot oscillation in studs when standing still
local IDLE_FREQ  = 0.45   -- cycles per second for idle bob

-- Left leg = phase 0, right leg = π (perfectly opposite)
local LEG_PHASE  = { 0, math.pi }
-- Knee bow direction: left leg bows left (−RightVector), right bows right (+RightVector)
local KNEE_SIGN  = { -1, 1 }

-- Animation runs at WALK_FREQ when unit speed ≥ FULL_SPEED
local FULL_SPEED = 9.0   -- matches Config.UNIT_MOVE_SPEED.Howitzer

-- Distance-squared cull (280 stud radius from camera)
local CULL_SQ = 280 * 280

-- ── Colors ────────────────────────────────────────────────────────────────────
local COL_IRON  = Color3.fromRGB(52, 52, 57)
local COL_BRASS = Color3.fromRGB(168, 126, 45)

-- ── Helper: orient a box so its Y axis runs from world point A to world point B ─
local function orientBetween(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.04 then return end
	local dir   = delta / len
	-- Build a stable right vector; fall back to X-axis if dir is nearly vertical
	local right = dir:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 0.01 then
		right = dir:Cross(Vector3.new(1, 0, 0))
	end
	right = right.Unit
	local back = right:Cross(dir)
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(thick, len, thick)
end

-- ── State type ────────────────────────────────────────────────────────────────
type LegParts = {
	upper:  BasePart,   -- hip-to-knee structural member
	lower:  BasePart,   -- knee-to-foot structural member
	piston: BasePart,   -- brass piston accent running alongside lower leg
	knee:   BasePart,   -- spherical knee cap
	foot:   BasePart,   -- flat rectangular foot plate
}

type Entry = {
	body:        BasePart,
	legs:        { LegParts },
	lastPos:     Vector3,
	animClock:   number,    -- drives the walk cycle
	idleClock:   number,    -- drives the idle piston bob
	smoothSpeed: number,    -- exponentially-smoothed speed estimate
	phase:       number,    -- per-unit phase offset (golden-ratio spread)
	conn:        RBXScriptConnection,
}

local active: { [string]: Entry } = {}
local legsFolder: Folder
local camera: Camera

-- ── Part factories ────────────────────────────────────────────────────────────

local function makePart(col: Color3, mat: Enum.Material, shape: Enum.PartType?): BasePart
	local p          = Instance.new("Part")
	if shape then (p :: any).Shape = shape end
	p.Color          = col
	p.Material       = mat
	p.Anchored       = true
	p.CanCollide     = false
	p.CastShadow     = false
	p.CanQuery       = false
	p.Parent         = legsFolder
	return p
end

local function buildLeg(): LegParts
	return {
		upper  = makePart(COL_IRON,  Enum.Material.Metal),
		lower  = makePart(COL_IRON,  Enum.Material.Metal),
		piston = makePart(COL_BRASS, Enum.Material.SmoothPlastic),
		knee   = makePart(COL_IRON,  Enum.Material.Metal, Enum.PartType.Ball),
		foot   = makePart(COL_IRON,  Enum.Material.Metal),
	}
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WalkerLegs.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	-- Match the team color from the existing decorator parts
	local teamCol = body.BrickColor

	local legs: { LegParts } = { buildLeg(), buildLeg() }

	-- Tint the upper leg slightly with team color for visual identity
	for _, leg in legs do
		leg.upper.BrickColor = teamCol
		-- Initial sizes so they're not zero-sized before first frame
		leg.upper.Size  = Vector3.new(UPPER_THICK,  0.1, UPPER_THICK)
		leg.lower.Size  = Vector3.new(LOWER_THICK,  0.1, LOWER_THICK)
		leg.piston.Size = Vector3.new(PISTON_THICK, 0.1, PISTON_THICK)
		leg.knee.Size   = Vector3.new(KNEE_DIAM, KNEE_DIAM, KNEE_DIAM)
		leg.foot.Size   = Vector3.new(3.5, 0.9, 4.5)
	end

	-- Golden-ratio phase spread so multiple walkers don't sync perfectly
	local n     = tonumber(unitId:match("%d+")) or 0
	local phase = n * 0.6180339887

	local conn = body.Destroying:Connect(function()
		WalkerLegs.detach(unitId)
	end)

	active[unitId] = {
		body        = body,
		legs        = legs,
		lastPos     = body.Position,
		animClock   = 0,
		idleClock   = phase,
		smoothSpeed = 0,
		phase       = phase,
		conn        = conn,
	}
end

function WalkerLegs.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, leg in e.legs do
		leg.upper:Destroy()
		leg.lower:Destroy()
		leg.piston:Destroy()
		leg.knee:Destroy()
		leg.foot:Destroy()
	end
end

-- ── Initialization + animation loop ──────────────────────────────────────────

function WalkerLegs.init(cam: Camera)
	camera = cam

	legsFolder        = Instance.new("Folder")
	legsFolder.Name   = "_WalkerLegs"
	legsFolder.Parent = workspace

	RunService.RenderStepped:Connect(function(dt)
		local camPos = camera.CFrame.Position

		for unitId, e in active do
			local body = e.body
			if not body.Parent then
				WalkerLegs.detach(unitId)
				continue
			end

			-- ── Distance cull ──────────────────────────────────────────────────
			local bpos = body.Position
			local dx   = bpos.X - camPos.X
			local dy   = bpos.Y - camPos.Y
			local dz   = bpos.Z - camPos.Z
			if dx*dx + dy*dy + dz*dz > CULL_SQ then
				e.lastPos = bpos
				continue
			end

			-- ── Speed smoothing ────────────────────────────────────────────────
			local moved     = (bpos - e.lastPos).Magnitude
			e.lastPos       = bpos
			local rawSpeed  = moved / math.max(dt, 0.001)
				-- Riding a Roller: the body is dragged along, but the walker holds its idle
				-- stance (facing still follows the server-set CFrame = Roller's front).
				if body:GetAttribute("Carried") then rawSpeed = 0 end
			local alpha     = if rawSpeed > e.smoothSpeed then 0.25 else 0.07
			e.smoothSpeed   = e.smoothSpeed + (rawSpeed - e.smoothSpeed) * alpha

			local speedF    = math.min(e.smoothSpeed / FULL_SPEED, 1.0)
			e.animClock    += dt * speedF  * WALK_FREQ * math.pi * 2
			e.idleClock    += dt * IDLE_FREQ * math.pi * 2

			-- ── Per-frame body frame ───────────────────────────────────────────
			local cf  = body.CFrame
			local rv  = cf.RightVector
			local lv  = cf.LookVector

			-- Flat forward direction for foot plate orientation
			local flatLV = Vector3.new(lv.X, 0, lv.Z)
			if flatLV.Magnitude < 0.01 then flatLV = Vector3.new(0, 0, -1) end
			flatLV = flatLV.Unit

			for i = 1, 2 do
				local theta  = e.animClock + e.phase + LEG_PHASE[i]
				local sinT   = math.sin(theta)
				local cosT   = math.cos(theta)

				-- Walk lift and forward swing (scale to zero when idle)
				local lift   = math.max(0, sinT) * STEP_LIFT  * speedF
				local swing  = cosT              * STEP_SWING * speedF

				-- Idle piston oscillation (active when standing still)
				local idleT  = math.sin(e.idleClock + i * math.pi)
				local idleLift = idleT * IDLE_AMP * (1 - speedF)
				lift = lift + idleLift

				-- World-space hip and foot rest positions
				local hipW      = cf:PointToWorldSpace(HIP[i])
				local footRestW = cf:PointToWorldSpace(FOOT_REST[i])

				-- Foot position: swing along LookVector, lift vertically
				local footW = Vector3.new(
					footRestW.X + flatLV.X * swing,
					footRestW.Y + lift,
					footRestW.Z + flatLV.Z * swing
				)

				-- Knee: midpoint + lateral bow + upward rise
				-- Knee rises more dramatically at peak step (stepPeak = lift / STEP_LIFT)
				local stepPeak  = if STEP_LIFT > 0 then math.max(0, sinT) * speedF else 0
				local kneeExtra = stepPeak * KNEE_UP_STEP
				local kneeW = (hipW + footW) * 0.5
					+ rv * (KNEE_SIGN[i] * KNEE_LATERAL)
					+ Vector3.new(0, KNEE_UP_BASE + kneeExtra, 0)

				local leg = e.legs[i]

				-- Orient structural segments
				orientBetween(leg.upper, hipW,  kneeW, UPPER_THICK)
				orientBetween(leg.lower, kneeW, footW, LOWER_THICK)

				-- Piston: runs alongside lower leg, offset slightly toward body center
				local pistonOff = rv * (-KNEE_SIGN[i] * 0.7)
				orientBetween(leg.piston,
					kneeW + pistonOff + Vector3.new(0, -0.2, 0),
					footW + pistonOff + Vector3.new(0,  0.3, 0),
					PISTON_THICK
				)

				-- Knee cap at knee pivot
				leg.knee.CFrame = CFrame.new(kneeW)

				-- Foot plate: flat, facing same direction as body, at foot contact point
				local footRight = flatLV:Cross(Vector3.new(0, 1, 0))
				if footRight.Magnitude > 0.01 then
					footRight = footRight.Unit
					leg.foot.CFrame = CFrame.fromMatrix(footW, footRight, Vector3.new(0, 1, 0), -flatLV)
				else
					leg.foot.CFrame = CFrame.new(footW)
				end
			end
		end
	end)
end

return WalkerLegs
