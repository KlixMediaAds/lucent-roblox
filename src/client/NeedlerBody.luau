-- NeedlerBody.luau
-- Client-only procedural body for the Needler — a slow stalker evolved from an Embryo.
-- The creature is a single spherical body with an amber eye on each side and one long,
-- two-jointed arm rising from its top that reads like a solitary giant insect leg. It
-- does not walk on legs: it REACHES the arm forward, plants the tip in the ground ahead,
-- then hauls its whole body up to the anchor — a surging, non-linear inch-along gait.
-- Its attack is a stationary mantis-shrimp strike: the body stays braced to the ground
-- while the arm cocks up and snaps down at the target with sudden force.
--
-- Architecture mirrors WatcherBody / RollerBody: one shared RenderStepped loop, a
-- distance cull, a movement-derived speed clock, and every part tagged with a "UnitId"
-- attribute so FogManager can hide the bodies of enemy Needlers sitting in the fog.
--
-- The server spawns the Needler as an invisible, ground-snapped pivot block (size
-- 4×6×4). Everything you see is drawn here. When the server fires a Needler melee hit,
-- triggerAttackNear picks the nearest Needler and plays its arm strike at the target.
--!strict

local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")

local NeedlerBody = {}

-- ── Geometry ──────────────────────────────────────────────────────────────────
local BASE_HEIGHT = 6.0        -- = Config.UNIT_TYPES.Needler.size.Y (pivot centre = size.Y/2 above ground)
local BODY_R      = 1.5        -- spherical body radius
local BODY_H      = 1.9        -- resting height of the body centre above the ground
local BODY_DIP    = 0.55       -- how much the body sinks at the bottom of a pull (crouch/brace)
local SHOULDER_UP  = BODY_R * 0.78   -- arm root offset above the body centre
local SHOULDER_FWD = BODY_R * 0.15   -- arm root offset toward the front

local UPPER_LEN  = 5.15        -- upper arm segment length (shoulder → elbow)
local FORE_LEN   = 5.62        -- fore arm segment length (elbow → tip)
local UPPER_TH   = 0.71        -- upper arm thickness
local FORE_TH    = 0.51        -- fore arm thickness (tapers toward the point)

-- ── Gait (anchored pull) ────────────────────────────────────────────────────────
local FULL_SPEED   = 10.0      -- matches Config.UNIT_MOVE_SPEED.Needler (slow)
local STRIDE_LEN   = 7.5       -- studs of ground covered per full reach→pull cycle (bigger steps)
local REACH_END    = 0.45      -- phase [0,REACH_END) = reach; [REACH_END,1) = plant + pull
local ANCHOR_AHEAD = 7.5       -- studs ahead of the body the tip plants (the long arm reaches far out each drag, then hauls the body most of the way to it)
local SURGE_AMP    = 0.95      -- how far the body lags/leads its pivot through the surge
local REACH_LIFT   = 1.8       -- how high the tip arcs as it is thrown forward
local BREATHE_FREQ = 0.75      -- idle body pulsate cycles/sec
local BREATHE_AMP  = 0.06      -- fraction the body swells as it "breathes"

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
local STRIKE_RANGE = 55        -- max studs from a hit origin to claim the nearest Needler
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
type Entry = {
	body:        BasePart,
	core:        BasePart,    -- spherical body
	belly:       BasePart,    -- darker underside lobe
	shoulder:    BasePart,    -- arm-root joint ball
	upper:       BasePart,    -- upper arm segment
	elbow:       BasePart,    -- elbow joint ball
	fore:        BasePart,    -- fore arm segment
	claw:        BasePart,    -- pointed tip
	eyes:        { Eye },
	prevPos:     Vector3?,
	smoothSpeed: number,
	facing:      Vector3,     -- horizontal unit heading the creature is pointed
	gaitPhase:   number,      -- accumulates with distance travelled (1.0 = one full stride)
	plantPos:    Vector3,     -- world position the tip is currently anchored at
	pullSet:     boolean,     -- has this cycle's plant point been committed yet
	breatheClock: number,
	strikeT:     number,      -- >0 while a strike plays
	strikeTarget: Vector3?,
	struck:      boolean,     -- has this swing already spat its impact FX
	renderTip:   Vector3?,    -- the arm tip actually drawn last frame (for smooth hand-offs)
	cockFrom:    Vector3?,    -- where the tip was when the current strike began
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

-- ── Public API: attach / detach ─────────────────────────────────────────────--
function NeedlerBody.attach(unitId: string, body: BasePart)
	if active[unitId] then return end

	local core     = makePart(unitId, C_FLESH,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local belly    = makePart(unitId, C_BELLY,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local shoulder = makePart(unitId, C_JOINT,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local upper    = makePart(unitId, C_CHITIN, Enum.Material.SmoothPlastic)
	local elbow    = makePart(unitId, C_JOINT,  Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local fore     = makePart(unitId, C_CHITIN, Enum.Material.SmoothPlastic)
	local claw     = makePart(unitId, C_CLAW,   Enum.Material.SmoothPlastic)

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

	active[unitId] = {
		body         = body,
		core         = core,
		belly        = belly,
		shoulder     = shoulder,
		upper        = upper,
		elbow        = elbow,
		fore         = fore,
		claw         = claw,
		eyes         = eyes,
		prevPos      = nil,
		smoothSpeed  = 0,
		facing       = facing,
		gaitPhase    = phase,
		plantPos     = body.Position + facing * ANCHOR_AHEAD,
		pullSet      = false,
		breatheClock = phase * 4.0,
		strikeT      = 0,
		strikeTarget = nil,
		struck       = false,
		renderTip    = nil,
		cockFrom     = nil,
		conn         = conn,
	}
end

function NeedlerBody.detach(unitId: string)
	local e = active[unitId]
	if not e then return end
	active[unitId] = nil
	e.conn:Disconnect()
	for _, p in { e.core, e.belly, e.shoulder, e.upper, e.elbow, e.fore, e.claw } do
		if p.Parent then p:Destroy() end
	end
	for _, eye in e.eyes do
		if eye.socket.Parent then eye.socket:Destroy() end
		if eye.sclera.Parent then eye.sclera:Destroy() end
		if eye.pupil.Parent  then eye.pupil:Destroy()  end
	end
end

-- Lock the nearest Needler onto a target and play its arm strike.
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
		-- Begin the cock from wherever the arm actually is right now, so the wind-up
		-- eases out of the current pose instead of jumping to a fixed start point.
		e.cockFrom     = e.renderTip
		-- Snap the heading toward the target so the strike drives straight at it.
		local flat = Vector3.new(toPos.X - e.body.Position.X, 0, toPos.Z - e.body.Position.Z)
		if flat.Magnitude > 1e-3 then e.facing = flat.Unit end
	end
end

-- ── Two-bone IK: place elbow between shoulder S and tip T ────────────────────────
-- The elbow always bends WITHIN the vertical plane that contains the arm (the plane
-- whose normal is the creature's side vector), on the "up" side so the knee stays
-- raised. Because the bend direction is derived from that fixed plane rather than a
-- thresholded hint, it varies continuously as the tip sweeps from far-ahead to folded
-- to overhead — no flips, no degeneracy, so the fold reads as a smooth organic curl.
local function solveElbow(S: Vector3, T: Vector3, l1: number, l2: number, planeNormal: Vector3): Vector3
	local delta = T - S
	local d     = delta.Magnitude
	if d < 1e-4 then return S + Vector3.new(0, l1, 0) end
	d = math.clamp(d, math.abs(l1 - l2) + 0.05, l1 + l2 - 0.05)
	local axis = delta.Unit
	local a    = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
	local h    = math.sqrt(math.max(0, l1 * l1 - a * a))
	-- In-plane perpendicular to the arm axis (planeNormal ⟂ the vertical arm plane).
	local bendDir = planeNormal:Cross(axis)
	if bendDir.Magnitude < 1e-4 then
		bendDir = Vector3.yAxis - axis * Vector3.yAxis:Dot(axis)
	end
	bendDir = if bendDir.Magnitude > 1e-4 then bendDir.Unit else Vector3.yAxis
	if bendDir.Y < 0 then bendDir = -bendDir end   -- keep the knee raised
	return S + axis * a + bendDir * h
end

-- ── Layout: positions every part for one frame ─────────────────────────────────
local function layout(e: Entry, sc: number, speedF: number, dt: number)
	local bpos     = e.body.Position
	local groundY  = bpos.Y - (BASE_HEIGHT * 0.5) * sc
	local f        = e.facing
	local right    = Vector3.new(f.Z, 0, -f.X)   -- f rotated −90° about Y
	local up       = Vector3.yAxis

	local u        = e.gaitPhase - math.floor(e.gaitPhase)   -- fractional stride phase
	local striking = e.strikeT > 0

	-- ── Body surge + brace ─────────────────────────────────────────────────────
	-- Longitudinal offset relative to the pivot: the body hangs back through the
	-- reach (anchored/paused), then hauls forward through the pull. Scaled by speed
	-- so an idle Needler sits still. A strike freezes the surge and braces low.
	local longOff, dip
	if striking then
		longOff = -0.2   -- slight backward brace as it plants to strike
		dip     = BODY_DIP * 0.8
	else
		local surge
		if u < REACH_END then
			surge = SURGE_AMP * (1 - 2 * smooth(u / REACH_END))          -- +A → −A (drift back)
		else
			surge = SURGE_AMP * (2 * easeOutCubic((u - REACH_END) / (1 - REACH_END)) - 1)  -- −A → +A (haul forward)
		end
		longOff = surge * speedF
		-- Crouch through the hardest part of the pull, rise while reaching.
		local pullF = if u >= REACH_END then math.sin(((u - REACH_END) / (1 - REACH_END)) * math.pi) else 0
		dip = BODY_DIP * pullF * speedF
	end

	local breathe    = 1 + math.sin(e.breatheClock) * BREATHE_AMP
	local bodyCentre = Vector3.new(bpos.X, groundY, bpos.Z)
		+ f * (longOff * sc)
		+ up * ((BODY_H - dip) * sc)

	local coreD = BODY_R * 2 * sc * breathe
	e.core.Size   = Vector3.new(coreD, coreD, coreD)
	e.core.CFrame = CFrame.new(bodyCentre)
	local bellyD  = BODY_R * 1.5 * sc * breathe
	e.belly.Size   = Vector3.new(bellyD, bellyD * 0.8, bellyD)
	e.belly.CFrame = CFrame.new(bodyCentre - up * (BODY_R * 0.5 * sc))

	-- ── Arm tip target ─────────────────────────────────────────────────────────
	local shoulderPos = bodyCentre + up * (SHOULDER_UP * sc) + f * (SHOULDER_FWD * sc)
	local aheadTip    = Vector3.new(bpos.X, groundY, bpos.Z) + f * (ANCHOR_AHEAD * sc)

	local tip: Vector3
	local doImpact = false
	if striking then
		-- Cock up and back, then snap down at the target with force, then recover.
		local sp       = 1 - e.strikeT / STRIKE_DUR
		local cockFrom = e.cockFrom or aheadTip   -- ease the wind-up out of the current pose
		local cockTip  = shoulderPos + up * (COCK_H * sc) - f * (0.7 * sc)
		local snapTip  = e.strikeTarget or (Vector3.new(bpos.X, groundY, bpos.Z) + f * (STRIKE_REACH * sc))
		snapTip = Vector3.new(snapTip.X, groundY + STRIKE_GY * sc, snapTip.Z)
		if sp < COCK_END then
			tip = cockFrom:Lerp(cockTip, smooth(sp / COCK_END))
		elseif sp < SNAP_END then
			tip = cockTip:Lerp(snapTip, easeInQuint((sp - COCK_END) / (SNAP_END - COCK_END)))
			if not e.struck and sp >= (SNAP_END - 0.02) and e.core.LocalTransparencyModifier < 0.5 then
				e.struck  = true
				doImpact  = true
			end
		else
			tip = snapTip:Lerp(aheadTip, smooth((sp - SNAP_END) / (1 - SNAP_END)))
		end
	else
		-- Anchored-pull gait: reach a fresh plant ahead, then hold it as the body hauls in.
		if u < REACH_END then
			e.pullSet = false
			local t = u / REACH_END
			tip = e.plantPos:Lerp(aheadTip, smooth(t)) + up * (math.sin(t * math.pi) * REACH_LIFT * sc * (0.4 + 0.6 * speedF))
		else
			if not e.pullSet then
				e.plantPos = aheadTip
				e.pullSet  = true
			end
			tip = e.plantPos
		end
	end

	-- Never let the rendered tip exceed the arm's reach. A distant ground anchor (after
	-- the body has moved) or a strike target beyond arm range would otherwise stretch the
	-- segments far past their real length — pull the tip in to just under full extension
	-- along the same direction so the arm stays a rigid two-bone linkage.
	local armReach = (UPPER_LEN + FORE_LEN) * sc * 0.985
	local toTip    = tip - shoulderPos
	if toTip.Magnitude > armReach then
		tip = shoulderPos + toTip.Unit * armReach
	end
	e.renderTip = tip
	-- While striking, keep the gait's anchor pinned to where the arm actually is, so it
	-- resumes the walk cycle from the current pose without a snap when the strike ends.
	if striking then
		e.plantPos = tip
		e.pullSet  = false
	end
	if doImpact then
		spawnStrikeImpact(e.core:GetAttribute("UnitId") :: string or "", tip, f)
		playSoundAt(tip, STRIKE_SND, 0.55)
	end

	-- ── Two-bone arm ───────────────────────────────────────────────────────────
	-- The arm lives in the vertical plane spanned by facing (f) and up; its side
	-- vector (right) is that plane's normal, so the elbow bends smoothly in-plane.
	local elbowPos = solveElbow(shoulderPos, tip, UPPER_LEN * sc, FORE_LEN * sc, right)

	local jointD = UPPER_TH * 1.35 * sc
	e.shoulder.Size   = Vector3.new(jointD, jointD, jointD)
	e.shoulder.CFrame = CFrame.new(shoulderPos)
	placeLimb(e.upper, shoulderPos, elbowPos, UPPER_TH * sc)
	local elbD = UPPER_TH * 1.2 * sc
	e.elbow.Size   = Vector3.new(elbD, elbD, elbD)
	e.elbow.CFrame = CFrame.new(elbowPos)
	placeLimb(e.fore, elbowPos, tip, FORE_TH * sc)
	-- A pale pointed claw finishing the fore-arm, aimed along its last segment.
	local clawLen = 0.9 * sc
	local clawDir = (tip - elbowPos)
	clawDir = if clawDir.Magnitude > 1e-3 then clawDir.Unit else f
	e.claw.Size   = Vector3.new(FORE_TH * 1.1 * sc, FORE_TH * 1.1 * sc, clawLen)
	e.claw.CFrame = CFrame.lookAt(tip - clawDir * (clawLen * 0.4), tip + clawDir)

	-- ── Eyes ───────────────────────────────────────────────────────────────────
	local aimDir: Vector3? = nil
	if striking and e.strikeTarget then
		local a = (e.strikeTarget :: Vector3) - bodyCentre
		aimDir = if a.Magnitude > 0.05 then a.Unit else nil
	end
	for _, eye in e.eyes do
		local sideDir = right * eye.side
		-- Base position on the body's flank, canted a touch forward.
		local basePos = bodyCentre + sideDir * (EYE_SIDE * sc) + f * (EYE_FWD * sc) + up * (EYE_UP * sc)
		local normal  = (sideDir * 0.72 + f * 0.55 + up * 0.15).Unit   -- eyes look out & forward
		local tanA    = right
		local tanB    = up

		-- Look direction: lock forward on a strike, otherwise idle wander.
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

		-- Blink: a quick lid squash on the eyeball.
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
		if striking then scD *= 1.12 end   -- eyes swell as it strikes
		eye.sclera.Size   = Vector3.new(scD, scD, scD)
		eye.sclera.CFrame = CFrame.new(basePos + normal * (0.28 * sc * open))

		local pupilN = (normal + (tanA * eye.look.X + tanB * eye.look.Y) * 0.3)
		pupilN = if pupilN.Magnitude > 1e-3 then pupilN.Unit else normal
		local pupD   = PUPIL_D * sc * open
		eye.pupil.Size   = Vector3.new(pupD, pupD, pupD)
		eye.pupil.CFrame = CFrame.new(basePos + normal * (0.28 * sc * open) + pupilN * (scD * 0.4))
	end
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

			-- Advance the gait by ground covered so plants lock to distance travelled.
			if not carried then e.gaitPhase += frameMove / STRIDE_LEN end
			e.breatheClock += dt * BREATHE_FREQ * math.pi * 2
			if e.strikeT > 0 then e.strikeT = math.max(0, e.strikeT - dt) end

			local sc = body.Size.Y / BASE_HEIGHT
			layout(e, sc, speedF, dt)
		end
	end)
end

return NeedlerBody
