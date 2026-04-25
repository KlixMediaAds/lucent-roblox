--!strict
--[[
    MechLegs — Procedural mech-leg animation for the mobile Command Center.

    API:
      MechLegs.init(camera)          — call once on startup
      MechLegs.attach(ccId, base)    — sprout 4 legs from the CC, start walk cycle
      MechLegs.detach(ccId)          — retract legs, then destroy them
]]

local RunService = game:GetService("RunService")

local MechLegs = {}

-- ── Leg geometry constants ─────────────────────────────────────────────────────
-- CC base is 14×10×14.  Hips sit at (±5, +2, ±5) relative to base centre
-- (upper portion of the CC body).  Feet land at (±12, -5, ±12) relative to
-- base centre — roughly ground level when CC is placed on flat terrain.
local HIP_X  =  5    -- |X| offset of hip from base centre (local space)
local HIP_Y  =  2    -- Y offset of hip from base centre
local HIP_Z  =  5    -- |Z| offset
local FOOT_X = 12    -- |X| of foot in local base space
local FOOT_Y = -5    -- Y of foot (≈ ground level)
local FOOT_Z = 12    -- |Z|

local LEG_LIFT  = 3.0  -- studs a foot rises during the lift phase
local WALK_HZ   = 1.4  -- full cycles per second
local LEG_SIZE  = 2.2  -- cross-section of the leg part (X and Z)

-- Four corners: (xSign, zSign, gaitPhase)
-- Pair A (FL + BR): phase 0      — lift together
-- Pair B (FR + BL): phase π      — opposite phase
local CORNERS = {
	{ xs =  1, zs =  1, phase = 0        },  -- BR  (pair A)
	{ xs = -1, zs = -1, phase = 0        },  -- FL  (pair A)
	{ xs =  1, zs = -1, phase = math.pi  },  -- FR  (pair B)
	{ xs = -1, zs =  1, phase = math.pi  },  -- BL  (pair B)
}

-- ── Types ─────────────────────────────────────────────────────────────────────
type LegEntry = {
	part:  Part,
	xs:    number,   -- X sign (-1 or 1)
	zs:    number,   -- Z sign
	phase: number,   -- gait cycle offset (radians)
	t:     number,   -- 0 = fully collapsed, 1 = fully extended
}

type LegSet = {
	base:     BasePart,
	legs:     { LegEntry },
	walkTime: number,
	sprouting: boolean,
	retracting: boolean,
	elapsed:  number,
	conn:     RBXScriptConnection?,
}

local sets: { [string]: LegSet } = {}

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function makePart(): Part
	local p              = Instance.new("Part")
	p.Anchored           = true
	p.CanCollide         = false
	p.CanQuery           = false
	p.CastShadow         = false
	p.Color              = Color3.fromRGB(50, 55, 70)
	p.Material           = Enum.Material.Metal
	p.Size               = Vector3.new(LEG_SIZE, 0.1, LEG_SIZE)
	p.Transparency       = 1
	p.Parent             = workspace
	return p
end

-- Compute hip and animated foot in world space, then position the leg part.
local function updateLeg(leg: LegEntry, base: BasePart, walkTime: number)
	local bCF  = base.CFrame
	local bSz  = base.Size

	-- Hip: upper portion of the CC corner in base-local space
	local hipLocal = Vector3.new(leg.xs * HIP_X, HIP_Y, leg.zs * HIP_Z)
	local hipWorld = bCF:PointToWorldSpace(hipLocal)

	-- Foot base (fully-extended, no lift)
	local footLocal = Vector3.new(leg.xs * FOOT_X, FOOT_Y, leg.zs * FOOT_Z)
	local footWorld = bCF:PointToWorldSpace(footLocal)

	-- Walk lift: only applies when fully extended
	if leg.t > 0.8 then
		local s    = math.sin(WALK_HZ * 2 * math.pi * walkTime + leg.phase)
		local lift = math.max(0, s) * LEG_LIFT
		footWorld  = footWorld + Vector3.new(0, lift, 0)
	end

	-- Lerp foot from hip toward extended as t goes 0→1
	footWorld = hipWorld:Lerp(footWorld, leg.t)

	-- Build CFrame: centre between hip and foot, Y-axis pointing from foot to hip
	local diff = hipWorld - footWorld
	local len  = diff.Magnitude
	if len < 0.05 then
		leg.part.Transparency = 1
		return
	end

	local mid = (hipWorld + footWorld) * 0.5
	-- CFrame.lookAt points the -Z axis toward the second arg.
	-- We want the Y axis of the part along the leg, so rotate +90° around X.
	local cf = CFrame.lookAt(mid, footWorld) * CFrame.Angles(math.pi * 0.5, 0, 0)

	leg.part.Size         = Vector3.new(LEG_SIZE, len, LEG_SIZE)
	leg.part.CFrame       = cf
	leg.part.Transparency = 0
end

-- ── Public API ────────────────────────────────────────────────────────────────

function MechLegs.attach(ccId: string, base: BasePart)
	if sets[ccId] then return end

	local legs: { LegEntry } = {}
	for _, c in CORNERS do
		table.insert(legs, {
			part  = makePart(),
			xs    = c.xs,
			zs    = c.zs,
			phase = c.phase,
			t     = 0,
		})
	end

	local set: LegSet = {
		base       = base,
		legs       = legs,
		walkTime   = 0,
		sprouting  = true,
		retracting = false,
		elapsed    = 0,
		conn       = nil,
	}
	sets[ccId] = set

	set.conn = RunService.Heartbeat:Connect(function(dt: number)
		-- If CC is gone and we haven't started retracting yet, start now
		if not base.Parent and not set.retracting then
			sets[ccId] = nil
			set.sprouting  = false
			set.retracting = true
			set.elapsed    = 0
		end

		set.walkTime += dt
		set.elapsed  += dt

		-- Sprout phase: 0 → 1 over 0.55 s with smoothstep
		if set.sprouting then
			local prog = math.min(set.elapsed / 0.55, 1)
			local t    = prog * prog * (3 - 2 * prog)
			for _, leg in set.legs do leg.t = t end
			if prog >= 1 then
				set.sprouting = false
				set.elapsed   = 0
			end

		-- Retract phase: 1 → 0 over 0.40 s with ease-in
		elseif set.retracting then
			local prog = math.min(set.elapsed / 0.40, 1)
			local t    = 1 - prog * prog
			for _, leg in set.legs do leg.t = t end
			if prog >= 1 then
				if set.conn then set.conn:Disconnect(); set.conn = nil end
				for _, leg in set.legs do
					if leg.part.Parent then leg.part:Destroy() end
				end
				return
			end
		end

		if base.Parent then
			for _, leg in set.legs do
				updateLeg(leg, base, set.walkTime)
			end
		end
	end)
end

function MechLegs.detach(ccId: string)
	local set = sets[ccId]
	if not set then return end
	sets[ccId]       = nil
	set.sprouting    = false
	set.retracting   = true
	set.elapsed      = 0
end

function MechLegs.init(_camera: Camera)
	-- kept for API consistency with SpiderLegs / CreepyLegs
end

return MechLegs
