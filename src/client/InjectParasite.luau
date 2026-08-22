-- InjectParasite.luau
-- Client-only procedural creature: the thing an injection actually spits out.
--
-- A bare-ground injection used to be a purple flash and three plants sliding up out of
-- the soil. It now throws a small parasite clear of the wound for every plant it is
-- about to grow. Each one lands, scurries to the patch of ground its plant belongs on,
-- and then takes root -- and the rooting pose IS the plant it is about to become, so the
-- creature does not simply die and get replaced: it unfolds into the growth. The spire's
-- parasite rears onto its tail and stiffens into a stalk; the frond's opens its limbs
-- into the blade fan; the pod cluster's flattens into the mound and lets the lumps it was
-- carrying settle out around it.
--
-- The blend is a timing trick more than a modelling one. The server holds each plant
-- buried for exactly the leap + scurry (Config.injectParasiteLead), stamps the moment it
-- will rise on the model as RiseAt, and starts the rise while the parasite is still
-- unfolding. The plant therefore climbs THROUGH the creature, which is fading out into
-- the same silhouette, in the same three colours (InjectPlants publishes its palette).
--
-- Everything here is local. The server sends one model carrying three attributes; every
-- client builds and animates its own parasite off that, at frame rate, and throws it away
-- when the run is over.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe         = require(Shared:WaitForChild("PerfProbe"))
local Config       = require(Shared:WaitForChild("Config"))
local InjectPlants = require(Shared:WaitForChild("InjectPlants"))

local InjectParasite = {}

-- ── Timing ────────────────────────────────────────────────────────────────────
-- LEAP + SCURRY is the lead the server buries the plant for; ROOT overlaps the rise.
local LEAP  = Config.INJECT_PARASITE_LEAP
local SCUR  = Config.INJECT_PARASITE_SCURRY
local ROOT  = Config.INJECT_PARASITE_ROOT
local LEAD  = LEAP + SCUR
local TOTAL = LEAD + ROOT

local CULL_SQ = 320 * 320   -- past this the run is skipped outright; it is a 3 s detail

-- ── Motion ────────────────────────────────────────────────────────────────────
local SLITHER_FREQ = 3.4    -- body undulation cycles/sec while it scurries
local LAT_WAVE     = 1.15   -- undulation waves along the body
local LAT_AMP      = 0.62   -- side-to-side amplitude at the tail
local STEP_FREQ    = 7.0    -- limb scrabble cycles/sec
local RIDE         = 0.55   -- how high the body carries itself off the ground
local OVERSHOOT    = 2.4    -- studs past the spot the leap lands
local SIDESTEP     = 3.2    -- studs to the side of the spot the leap lands

-- ── Shape ─────────────────────────────────────────────────────────────────────
-- Each variant's parasite is already built out of what its plant is made of: the spire's
-- is long and thin with few limbs, the frond's is squat with long ones, the pod cluster's
-- carries its pods on its back before it ever reaches the ground.
type Shape = {
	segs:   number,      -- body segments (the spine has segs + 1 points)
	len:    number,      -- head-to-tail ground length
	thick:  { number },  -- body thickness at each spine point (head → tail)
	legs:   number,
	legLen: number,
	lumps:  number,      -- pods carried on its back
	head:   number,      -- head diameter
}

local SHAPES: { [string]: Shape } = {
	spire = { segs = 6, len = 4.8, legs = 4, legLen = 1.5, lumps = 0, head = 1.15,
		thick = { 0.85, 0.95, 0.86, 0.74, 0.60, 0.44, 0.28 } },
	frond = { segs = 4, len = 3.4, legs = 6, legLen = 2.1, lumps = 0, head = 1.40,
		thick = { 1.15, 1.30, 1.10, 0.85, 0.55 } },
	pods  = { segs = 5, len = 3.9, legs = 5, legLen = 1.6, lumps = 4, head = 1.20,
		thick = { 1.00, 1.18, 1.18, 0.96, 0.70, 0.44 } },
}

-- ── Types ─────────────────────────────────────────────────────────────────────
type Leg = {
	part: BasePart,
	hip:  number,    -- spine point it hangs off
	side: number,    -- -1 / +1, which flank
	ang:  number,    -- radial bearing it splays to when it roots
	off:  number,    -- gait phase offset
}

type Entry = {
	model:       Model,      -- the plant this parasite becomes (gone = run is off)
	rig:         Model,
	variant:     string,
	shape:       Shape,
	from:        Vector3,    -- the wound
	target:      Vector3,    -- where the plant comes up
	landAt:      Vector3,    -- where the leap puts it down
	pathRight:   Vector3,
	arc:         number,
	spin:        number,     -- bearing its rooted pose is built around
	riseAt:      number,     -- server clock: the plant climbs, and it starts rooting
	head:        BasePart,
	eyes:        { BasePart },
	segs:        { BasePart },
	legs:        { Leg },
	lumps:       { BasePart },
	frozen:      { Vector3 }?,   -- spine captured the frame it committed to rooting
	frozenFeet:  { Vector3 }?,
	frozenLumps: { Vector3 }?,
	landed:      boolean,
	rooted:      boolean,
	bulbCol:     Color3,
	stemCol:     Color3,
}

local live: { Entry } = {}
local watched: { [Instance]: boolean } = {}
local fxFolder: Folder
local camera: Camera

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function makePart(name: string, col: Color3, mat: Enum.Material, ball: boolean?): BasePart
	local p      = Instance.new("Part")
	if ball then p.Shape = Enum.PartType.Ball end
	p.Name       = name
	p.Color      = col
	p.Material   = mat
	p.Size       = Vector3.new(0.2, 0.2, 0.2)
	p.Anchored   = true
	p.CanCollide = false
	p.CanQuery   = false
	p.CanTouch   = false
	p.CastShadow = false
	return p
end

-- Stretch a part between two points, thickness `thick`, long axis Y. The same trick the
-- unit body animators use to draw a spine out of plain blocks.
local function span(part: BasePart, a: Vector3, b: Vector3, thick: number)
	local delta = b - a
	local len   = delta.Magnitude
	if len < 0.03 then return end
	local dir   = delta / len
	local right = dir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then right = dir:Cross(Vector3.xAxis) end
	right = right.Unit
	local back  = right:Cross(dir)
	part.CFrame = CFrame.fromMatrix((a + b) * 0.5, right, dir, -back)
	part.Size   = Vector3.new(thick, len, thick)
end

local function flatUnit(v: Vector3, fallback: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 0.01 and f.Unit or fallback
end

-- A flat bloom on the ground: the scuff where it lands, the flash where it roots.
local function puff(pos: Vector3, spread: number, col: Color3, life: number)
	local p        = makePart("_Puff", col, Enum.Material.Neon, true)
	p.Size         = Vector3.new(1.4, 0.6, 1.4)
	p.Position     = pos + Vector3.new(0, 0.25, 0)
	p.Transparency = 0.35
	p.Parent       = fxFolder
	TweenService:Create(p, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(spread, 0.4, spread),
		Transparency = 1,
	}):Play()
	Debris:AddItem(p, life + 0.1)
end

-- ── Building one parasite ─────────────────────────────────────────────────────
local function build(e: Entry)
	local sh  = e.shape
	local rig = Instance.new("Model")
	rig.Name  = "_Parasite_" .. e.variant

	for i = 1, sh.segs do
		local p  = makePart("Seg" .. i, e.stemCol, Enum.Material.Slate)
		p.Parent = rig
		e.segs[i] = p
	end

	e.head        = makePart("Head", InjectPlants.FLESH_COL, Enum.Material.Slate, true)
	e.head.Size   = Vector3.new(sh.head, sh.head, sh.head)
	e.head.Parent = rig

	for i = 1, 2 do
		local eye  = makePart("Eye" .. i, e.bulbCol, Enum.Material.Neon, true)
		eye.Size   = Vector3.new(0.22, 0.22, 0.22)
		eye.Parent = rig
		e.eyes[i]  = eye
	end

	for i = 1, sh.legs do
		local p  = makePart("Limb" .. i, e.stemCol, Enum.Material.Slate)
		p.Parent = rig
		e.legs[i] = {
			part = p,
			-- Limbs hang off the front of the body, alternating flanks.
			hip  = 1 + math.floor((i - 1) / 2) % math.max(1, sh.segs - 1),
			side = (i % 2 == 0) and 1 or -1,
			ang  = e.spin + ((i - 1) / sh.legs) * math.pi * 2,
			off  = (i % 2 == 0) and math.pi or 0,
		}
	end

	for i = 1, sh.lumps do
		local p  = makePart("Lump" .. i, e.bulbCol, Enum.Material.SmoothPlastic, true)
		p.Size   = Vector3.new(0.85, 0.85, 0.85)
		p.Parent = rig
		e.lumps[i] = p
	end

	rig.Parent = fxFolder
	e.rig      = rig
end

-- ── Poses ─────────────────────────────────────────────────────────────────────
-- Thrown clear of the wound: it tumbles head over tail through a short arc, body curled.
local function poseLeap(e: Entry, k: number): ({ Vector3 }, Vector3)
	local sh   = e.shape
	local n    = sh.segs
	local seg  = sh.len / n
	local fwd  = flatUnit(e.landAt - e.from, Vector3.zAxis)
	local pos  = e.from:Lerp(e.landAt, k) + Vector3.new(0, math.sin(k * math.pi) * e.arc, 0)
	-- Tumble about its own right axis, slowing as it comes down to land.
	local spin = -0.7 - (k - 0.35 * k * k) * math.pi * 2.6
	local cf   = CFrame.lookAt(pos, pos + fwd) * CFrame.Angles(spin, 0, 0)

	local pts: { Vector3 } = table.create(n + 1)
	for i = 0, n do
		-- Curled tight around itself in the air, hooking open as it nears the ground.
		local s    = i * seg * (0.72 + 0.28 * k)
		local hook = math.sin((i / n) * math.pi) * 0.55
		pts[i + 1] = cf * Vector3.new(0, hook, s)
	end
	return pts, cf.RightVector
end

-- Where the scurry has it at `k`: a hard dash past the spot that curves back into it.
local function scurryAt(e: Entry, k: number): Vector3
	local u = 1 - (1 - math.clamp(k, 0, 1)) ^ 2.2
	local p = e.landAt:Lerp(e.target, u)
	local s = math.sin(k * math.pi * 2.4) * 1.7 * (1 - u)
	return Vector3.new(p.X + e.pathRight.X * s, e.target.Y, p.Z + e.pathRight.Z * s)
end

-- On the ground and working: the body undulates behind the head, limbs scrabbling.
local function poseScurry(e: Entry, k: number, t: number): ({ Vector3 }, Vector3)
	local sh    = e.shape
	local n     = sh.segs
	local seg   = sh.len / n
	local head  = scurryAt(e, k)
	local ahead = scurryAt(e, math.min(k + 0.03, 1))
	local hd    = flatUnit(ahead - head, flatUnit(e.target - e.landAt, Vector3.zAxis))
	local right = hd:Cross(Vector3.yAxis).Unit
	local ph    = t * SLITHER_FREQ * math.pi * 2

	-- It slows and lowers over the last of the run, nosing at the ground it has picked.
	local settle = math.clamp((k - 0.72) / 0.28, 0, 1)
	local amp    = LAT_AMP * (1 - settle * 0.55)

	local pts: { Vector3 } = table.create(n + 1)
	for i = 0, n do
		local f    = i / n
		local lat  = math.sin(ph - f * LAT_WAVE * math.pi * 2) * amp * (0.3 + 0.7 * f)
		local hump = math.abs(math.sin(ph * 0.5 - f * 2.2)) * 0.28 * (1 - settle)
		local y    = RIDE + hump - f * 0.12 - settle * 0.18
		pts[i + 1] = head - hd * (i * seg) + right * lat + Vector3.new(0, y, 0)
	end
	return pts, right
end

-- The pose it dies into, which is the plant standing there a second later. Spire: reared
-- onto its tail, head highest, a stalk. Frond: collapsed into the bulb the blades splay
-- from. Pods: flattened into the mound, curled round on itself.
local function rootPose(e: Entry): { Vector3 }
	local sh  = e.shape
	local n   = sh.segs
	local seg = sh.len / n
	local pts: { Vector3 } = table.create(n + 1)

	if e.variant == "spire" then
		local lean = math.sin(math.rad(7))
		for i = 0, n do
			local h = (n - i) * seg * 0.92
			pts[i + 1] = e.target + Vector3.new(
				math.cos(e.spin) * h * lean, h * 0.9, math.sin(e.spin) * h * lean)
		end
	elseif e.variant == "frond" then
		for i = 0, n do
			local f = i / n
			local a = e.spin + f * math.pi * 1.5
			pts[i + 1] = e.target + Vector3.new(
				math.cos(a) * 0.55 * f, 1.15 - f * 0.45, math.sin(a) * 0.55 * f)
		end
	else
		for i = 0, n do
			local f = i / n
			local a = e.spin + f * math.pi * 1.9
			pts[i + 1] = e.target + Vector3.new(
				math.cos(a) * 1.45 * (0.45 + f), 0.42, math.sin(a) * 1.45 * (0.45 + f))
		end
	end
	return pts
end

-- Where a limb ends once it has stopped being a limb: the spire's basal thorns, the
-- frond's blade fan, the low stubs the pod mound settles on.
local function rootFoot(e: Entry, leg: Leg): Vector3
	local out = Vector3.new(math.cos(leg.ang), 0, math.sin(leg.ang))
	if e.variant == "spire" then
		return e.target + out * 1.7 + Vector3.new(0, 0.25, 0)
	elseif e.variant == "frond" then
		return e.target + out * e.shape.legLen * 1.75 + Vector3.new(0, 2.5, 0)
	end
	return e.target + out * 1.25 + Vector3.new(0, 0.2, 0)
end

-- ── Drawing one frame ─────────────────────────────────────────────────────────
local function draw(e: Entry, pts: { Vector3 }, right: Vector3, t: number,
	rootU: number, alpha: number)
	local sh = e.shape

	for i = 1, sh.segs do
		local seg   = e.segs[i]
		local thick = (sh.thick[i] + sh.thick[i + 1]) * 0.5
		span(seg, pts[i], pts[i + 1], thick * (1 - rootU * 0.25))
		seg.Transparency = alpha
	end

	-- Head: it swells and lights up as it turns into the plant's crown.
	local hd    = flatUnit(pts[1] - pts[2], right)
	local grow  = 1 + rootU * 0.55
	e.head.Size         = Vector3.new(sh.head, sh.head, sh.head) * grow
	e.head.CFrame       = CFrame.lookAt(pts[1], pts[1] + hd)
	e.head.Color        = InjectPlants.FLESH_COL:Lerp(e.bulbCol, rootU)
	e.head.Transparency = alpha
	if rootU > 0.35 then e.head.Material = Enum.Material.Neon end

	-- The eyes go out well before the body does: it stops being a creature first.
	local eyeA = math.max(alpha, math.min(rootU * 2.0, 1))
	local side = e.head.CFrame.RightVector
	local up   = e.head.CFrame.UpVector
	for i, eye in e.eyes do
		local s = (i == 1) and -1 or 1
		eye.CFrame = CFrame.new(pts[1] + hd * sh.head * 0.36
			+ side * s * sh.head * 0.26 + up * sh.head * 0.2)
		eye.Transparency = eyeA
	end

	local ph   = t * STEP_FREQ * math.pi * 2
	local feet = e.frozenFeet
	for i, leg in e.legs do
		local hip  = pts[math.min(leg.hip, #pts - 1)]
		local step = math.sin(ph + leg.off)
		local foot = hip + right * leg.side * sh.legLen * 0.8
			+ hd * step * 0.55 - Vector3.new(0, RIDE + 0.1, 0)
		if feet then foot = feet[i]:Lerp(rootFoot(e, leg), rootU) end
		span(leg.part, hip, foot, 0.3 * (1 - rootU * 0.15))
		leg.part.Transparency = alpha
	end

	local lumpsFrom = e.frozenLumps
	for i, lump in e.lumps do
		local idx = math.min(1 + i, #pts)
		local pos = pts[idx] + Vector3.new(0, sh.thick[idx] * 0.55, 0)
		if lumpsFrom then
			-- The pods it was carrying settle out around the mound and swell.
			local a  = e.spin + ((i - 1) / #e.lumps) * math.pi * 2
			local to = e.target + Vector3.new(math.cos(a) * 1.7, 1.15, math.sin(a) * 1.7)
			pos = lumpsFrom[i]:Lerp(to, rootU)
		end
		lump.Position     = pos
		lump.Size         = Vector3.new(0.85, 0.85, 0.85) * (1 + rootU * 0.9)
		lump.Transparency = alpha
	end
end

-- ── Per-frame ─────────────────────────────────────────────────────────────────
local function step()
	if #live == 0 then return end
	local now    = workspace:GetServerTimeNow()
	local camPos = camera and camera.CFrame.Position or Vector3.zero

	for i = #live, 1, -1 do
		local e = live[i]
		local t = now - (e.riseAt - LEAD)

		-- The plant it belongs to went away (razed, or the round ended): so does it.
		if not e.model.Parent or t >= TOTAL then
			e.rig:Destroy()
			table.remove(live, i)
			continue
		end
		if t < 0 then continue end

		local d = e.target - camPos
		if d:Dot(d) > CULL_SQ then continue end

		local pts: { Vector3 }
		local right: Vector3
		local rootU = 0

		if t < LEAP then
			pts, right = poseLeap(e, t / LEAP)
		elseif t < LEAD then
			if not e.landed then
				e.landed = true
				puff(e.landAt, 5.5, InjectPlants.FLESH_COL, 0.35)
			end
			pts, right = poseScurry(e, (t - LEAP) / SCUR, t)
		else
			-- Rooting. The pose it arrived in is captured once, then bent into the plant.
			if not e.rooted then
				e.rooted   = true
				local p, r = poseScurry(e, 1, t)
				e.frozen   = p
				local feet: { Vector3 } = table.create(#e.legs)
				for j, leg in e.legs do
					local hip = p[math.min(leg.hip, #p - 1)]
					feet[j]   = hip + r * leg.side * e.shape.legLen * 0.8
						- Vector3.new(0, RIDE + 0.1, 0)
				end
				e.frozenFeet = feet
				local carried: { Vector3 } = table.create(#e.lumps)
				for j, lump in e.lumps do carried[j] = lump.Position end
				e.frozenLumps = carried
				puff(e.target, 7.0, e.bulbCol, 0.5)
			end

			local k    = (t - LEAD) / ROOT
			rootU      = 1 - (1 - k) ^ 2        -- snaps open, then settles
			right      = e.pathRight
			local from = e.frozen :: { Vector3 }
			local to   = rootPose(e)
			-- A shiver that dies out with the transformation, so it convulses rather than
			-- simply sliding from one pose into the other.
			local shake = (1 - k) * 0.22
			pts = table.create(#from)
			for j = 1, #from do
				local jitter = math.sin(t * 34 + j * 1.7) * shake
				pts[j] = from[j]:Lerp(to[j], rootU) + Vector3.new(jitter, 0, jitter * 0.6)
			end
		end

		-- It only starts to go once the plant is well clear of the ground, so the two
		-- overlap in one silhouette instead of handing over on an empty frame.
		local alpha = math.clamp((rootU - 0.55) / 0.45, 0, 1)
		draw(e, pts, right, t, rootU, alpha)
	end
end

-- ── Spawning ──────────────────────────────────────────────────────────────────
local function onPlant(plant: Instance)
	if not plant:IsA("Model") then return end
	local from   = plant:GetAttribute("ParasiteFrom")
	local origin = plant:GetAttribute("PlantOrigin")
	local riseAt = plant:GetAttribute("RiseAt")
	if typeof(from) ~= "Vector3" or typeof(origin) ~= "Vector3" or typeof(riseAt) ~= "number" then
		return   -- a wild plant, or one seeded before anyone could watch it grow
	end

	-- Joined (or streamed in) after the run would have finished: the plant is already on
	-- its way up, so there is nothing left to carry it.
	if workspace:GetServerTimeNow() > riseAt then return end
	if camera then
		local d = origin - camera.CFrame.Position
		if d:Dot(d) > CULL_SQ then return end
	end

	local raw     = plant:GetAttribute("Variant")
	local variant = (typeof(raw) == "string" and SHAPES[raw]) and raw or "spire"

	local rng  = Random.new()
	local out  = flatUnit(origin - from, Vector3.zAxis)
	local perp = out:Cross(Vector3.yAxis).Unit * (rng:NextNumber() < 0.5 and -1 or 1)
	local land = origin + out * OVERSHOOT + perp * SIDESTEP * rng:NextNumber(0.7, 1.2)

	local e: Entry = {
		model       = plant,
		rig         = nil :: any,
		variant     = variant,
		shape       = SHAPES[variant],
		from        = from + Vector3.new(0, 1.2, 0),
		target      = origin,
		landAt      = Vector3.new(land.X, origin.Y, land.Z),
		pathRight   = perp,
		arc         = rng:NextNumber(5.5, 7.5),
		spin        = rng:NextNumber(0, math.pi * 2),
		riseAt      = riseAt,
		head        = nil :: any,
		eyes        = {},
		segs        = {},
		legs        = {},
		lumps       = {},
		frozen      = nil,
		frozenFeet  = nil,
		frozenLumps = nil,
		landed      = false,
		rooted      = false,
		bulbCol     = InjectPlants.BULB_COLS[rng:NextInteger(1, #InjectPlants.BULB_COLS)],
		stemCol     = InjectPlants.STEM_COLS[rng:NextInteger(1, #InjectPlants.STEM_COLS)],
	}
	-- The scurry sways across its own line of travel, which is landing spot → plant.
	e.pathRight = flatUnit(e.target - e.landAt, Vector3.zAxis):Cross(Vector3.yAxis).Unit

	build(e)
	-- The wound spitting it out. One per parasite, and all three land on the same frame
	-- at the same spot, so the injection point blooms once as they come out of it.
	puff(from, 4.0, e.bulbCol, 0.3)
	table.insert(live, e)
end

local function watch(folder: Instance)
	if watched[folder] then return end
	watched[folder] = true
	folder.ChildAdded:Connect(onPlant)
end

function InjectParasite.init(cam: Camera)
	camera          = cam
	fxFolder        = Instance.new("Folder")
	fxFolder.Name   = "_InjectParasites"
	fxFolder.Parent = workspace

	local existing = workspace:FindFirstChild("InjectPlants")
	if existing then watch(existing) end
	-- The folder is made server-side on the first injection, which can be long after the
	-- match starts, so the arrival of the folder itself has to be waited on too.
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "InjectPlants" and child:IsA("Folder") then watch(child) end
	end)

	PerfProbe.onRender("InjectParasite", step)
end

return InjectParasite
