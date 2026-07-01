--[[
	SwarmGrass — Client-side "corruption tendrils" spreading from swarm-mode AI
	command centers.

	The server tags each swarm CC model with the attribute `SwarmCC = true` (see
	BuildingManager). This module watches the Buildings folder and, for every
	tagged CC, grows a web of dark vein/root tendrils that crawl outward from the
	spike along the ground, branching fractally, with sparse purple glow nodes at
	the branch points. Reads as a creeping infestation, not a lawn.

	(Module name kept as SwarmGrass so the client bootstrap require is unchanged.)

	Look — everything is shaped once at build time (zero per-frame cost):
	  • Radial branching veins — a handful of primary tendrils leave the spike and
	    wander outward, spawning child branches recursively; width tapers to the
	    tip so they read as roots.
	  • Purple glow nodes — small neon blobs at branch points / tips for the eye
	    catch (kept sparse and lightless, so nearly free).
	  • Grow-in — when a CC spawns the whole web scales up/outward from the spike
	    over ~1.2s (one-time Model:ScaleTo tween), so the veins appear to crawl out.

	Optimization:
	  • Fully client-side — nothing replicates; the server never simulates this.
	  • Every segment is a render-only thin flat Part hugging the ground. No cones,
	    no meshes — just batched blocks.
	  • CanCollide / CanQuery / CanTouch / CastShadow all off, Massless on — nothing
	    here touches physics or raycasts.
	  • Each CC's web is one Model; a throttled Heartbeat distance-culls far webs by
	    un-parenting the whole Model at once.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local SwarmGrass = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local R_INNER       = 5              -- start just outside the spike footprint
local R_OUTER       = 34             -- how far tendrils reach
local PRIMARY       = 16             -- main tendrils leaving the spike
local SEG_LEN       = 2.4            -- length of each vein segment
local START_W       = 1.5            -- base width at the spike
local WIDTH_DECAY   = 0.9            -- per-segment taper
local MIN_W         = 0.18           -- stop a tendril once this thin
local WANDER        = 0.4            -- max turn (rad) per segment
local BRANCH_CHANCE = 0.16           -- chance a segment spawns a branch
local MAX_DEPTH     = 3              -- branch recursion limit
local THICKNESS     = 0.16           -- vein height off the ground

local COLOR         = Color3.fromRGB(10, 9, 13)
local GLOW_COLOR    = Color3.fromRGB(150, 55, 225)  -- swarm purple
local GLOW_AT_NODE  = 0.55           -- chance of a glow blob at a branch node
local GLOW_AT_TIP   = 0.5            -- chance of a glow blob at a tendril tip

local CULL_SQ       = 360 * 360      -- un-parent webs past this range
local CULL_EVERY    = 0.4            -- seconds between cull checks
local GROW_TIME     = 1.2            -- spawn grow-in duration
local HALF_H        = Config.COMMAND_CENTER_SIZE.Y / 2

local rng = Random.new()

type Entry = { field: Model, base: BasePart, visible: boolean }
local entries: { [Model]: Entry } = {}
local processed: { [Model]: boolean } = {}
local camera: Camera?

-- ── Geometry helpers ────────────────────────────────────────────────────────────
local function rotY(v: Vector3, ang: number): Vector3
	local c, s = math.cos(ang), math.sin(ang)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function addSegment(field: Model, groundY: number, p0: Vector3, p1: Vector3, width: number)
	local dir = p1 - p0
	local len = dir.Magnitude
	if len < 1e-3 then return end

	-- Slight per-segment lift so overlapping veins don't z-fight, and read as raised.
	local y   = groundY + THICKNESS * 0.5 + rng:NextNumber(0.02, 0.09)
	local a   = Vector3.new(p0.X, y, p0.Z)
	local b   = Vector3.new(p1.X, y, p1.Z)
	local mid = (a + b) * 0.5

	local seg      = Instance.new("Part")
	seg.Size       = Vector3.new(width, THICKNESS, len + 0.15)  -- overlap to hide seams
	seg.Color      = COLOR
	seg.Material   = Enum.Material.Slate
	seg.Anchored   = true
	seg.CanCollide = false
	seg.CanQuery   = false
	seg.CanTouch   = false
	seg.CastShadow = false
	seg.Massless   = true
	seg.CFrame     = CFrame.lookAt(mid, b)   -- box Z aligns with the segment
	seg.Parent     = field
end

local function addGlow(field: Model, groundY: number, pos: Vector3, size: number)
	local glow      = Instance.new("Part")
	glow.Shape      = Enum.PartType.Ball
	glow.Size       = Vector3.new(size, size, size)
	glow.Color      = GLOW_COLOR
	glow.Material   = Enum.Material.Neon
	glow.Anchored   = true
	glow.CanCollide = false
	glow.CanQuery   = false
	glow.CanTouch   = false
	glow.CastShadow = false
	glow.Massless   = true
	glow.CFrame     = CFrame.new(pos.X, groundY + size * 0.4, pos.Z)
	glow.Parent     = field
end

-- ── Tendril growth (recursive) ──────────────────────────────────────────────────
local function grow(field: Model, groundY: number, pos: Vector3, dir: Vector3, width: number, remaining: number, depth: number)
	while remaining > 0 and width >= MIN_W do
		dir = rotY(dir, rng:NextNumber(-WANDER, WANDER))
		local step    = math.min(SEG_LEN, remaining)
		local nextPos = pos + dir * step
		addSegment(field, groundY, pos, nextPos, width)

		remaining -= step
		width     *= WIDTH_DECAY

		if depth < MAX_DEPTH and remaining > SEG_LEN * 2 and rng:NextNumber() < BRANCH_CHANCE then
			local side  = rng:NextNumber() < 0.5 and 1 or -1
			local bDir  = rotY(dir, side * rng:NextNumber(0.4, 0.95))
			if rng:NextNumber() < GLOW_AT_NODE then
				addGlow(field, groundY, nextPos, rng:NextNumber(0.35, 0.6))
			end
			grow(field, groundY, nextPos, bDir, width * 0.8, remaining * rng:NextNumber(0.4, 0.7), depth + 1)
		end

		pos = nextPos
	end

	if rng:NextNumber() < GLOW_AT_TIP then
		addGlow(field, groundY, pos, rng:NextNumber(0.25, 0.4))
	end
end

-- ── Field builder ─────────────────────────────────────────────────────────────
local function buildField(cx: number, cz: number, groundY: number): Model
	local field = Instance.new("Model")
	field.Name  = "SwarmGrass"

	local center = Vector3.new(cx, groundY, cz)
	local baseAng = rng:NextNumber(0, math.pi * 2)
	for i = 1, PRIMARY do
		local ang   = baseAng + (i / PRIMARY) * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local dir   = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local start = center + dir * R_INNER
		local reach = rng:NextNumber((R_OUTER - R_INNER) * 0.6, R_OUTER - R_INNER)
		grow(field, groundY, start, dir, START_W * rng:NextNumber(0.85, 1.1), reach, 0)
	end

	field.WorldPivot = CFrame.new(center)
	return field
end

-- ── Attach / detach ───────────────────────────────────────────────────────────
local function attach(model: Model)
	if processed[model] then return end
	processed[model] = true

	task.spawn(function()
		local base = model:WaitForChild("Base", 10) :: BasePart?
		if not base or not model.Parent then
			processed[model] = nil
			return
		end

		local groundY = base.Position.Y - HALF_H
		local field   = buildField(base.Position.X, base.Position.Z, groundY)

		if not model.Parent then
			field:Destroy()
			processed[model] = nil
			return
		end
		field.Parent = model
		entries[model] = { field = field, base = base, visible = true }

		-- Grow-in: veins crawl outward from the spike once (transient, no ongoing cost).
		task.spawn(function()
			local t0 = os.clock()
			field:ScaleTo(0.05)
			while field.Parent or entries[model] do
				local a = (os.clock() - t0) / GROW_TIME
				if a >= 1 then break end
				local e = 1 - (1 - a) * (1 - a)   -- ease-out quad
				field:ScaleTo(0.05 + 0.95 * e)
				RunService.Heartbeat:Wait()
			end
			if entries[model] then field:ScaleTo(1) end
		end)
	end)
end

-- ── Distance-cull loop ──────────────────────────────────────────────────────────
local cullAccum = 0
local function update(dt: number)
	cullAccum += dt
	if cullAccum < CULL_EVERY then return end
	cullAccum = 0

	local camPos = camera and camera.CFrame.Position or Vector3.zero
	for model, e in entries do
		if not model.Parent then
			e.field:Destroy()
			entries[model]   = nil
			processed[model] = nil
			continue
		end
		local dd   = e.base.Position - camPos
		local near = dd:Dot(dd) <= CULL_SQ
		if near ~= e.visible then
			e.visible      = near
			e.field.Parent = near and model or nil
		end
	end
end

-- ── Public API ──────────────────────────────────────────────────────────────────
function SwarmGrass.init(cam: Camera)
	camera = cam

	task.spawn(function()
		local folder = workspace:WaitForChild("Buildings", 30)
		if not folder then return end

		local function consider(m: Instance)
			if not m:IsA("Model") then return end
			if m:GetAttribute("SwarmCC") then
				attach(m)
			else
				-- Attribute may replicate a beat after the model; wait for it once.
				local conn
				conn = m:GetAttributeChangedSignal("SwarmCC"):Connect(function()
					if m:GetAttribute("SwarmCC") then
						conn:Disconnect()
						attach(m)
					end
				end)
			end
		end

		for _, m in folder:GetChildren() do consider(m) end
		folder.ChildAdded:Connect(consider)
	end)

	RunService.Heartbeat:Connect(update)
end

return SwarmGrass
