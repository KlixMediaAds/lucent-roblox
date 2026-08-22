--!strict
--[[
	ForestFade — a clearing rides along under the camera, so the woods never bury what
	you are looking at.

	Every tree within CLEAR_R studs of the spot the camera is centred on is gone, and from
	there they thicken smoothly back to solid by FADE_R. What matters is that this is
	measured in STUDS ON THE GROUND and in nothing else. Zoom cannot touch it: the same
	trees are transparent whether the camera is right down on the deck or pulled all the
	way out, because how far away the camera happens to be never enters the sum.

	(Doing this in screen space instead is the obvious reading of "vignette", but it
	cannot hold still. A fixed circle of screen covers more and more ground as the camera
	pulls back, so the patch of forest that vanishes grows with every zoom step. Studs are
	the only unit that keeps the same trees clear at every distance.)

	Cosmetic and purely local: nothing here replicates, and trees are CanQuery=false
	scenery so no raycast ever sees the change. A tree that starts to wither away hands
	itself back at once (ForestManager drives Transparency while it withers, and the two
	must not fight over the property), which is what the Felled attribute is for.

	Because trees are invisible to raycasts, this module also owns the only workable
	answer to "is a tree in the way of that": blocksSight(). Nothing calls it since the
	occlusion outline was cut; it is kept because raycasts cannot replace it, and it
	costs nothing until called (the grid it reads is filed at tree registration).
]]

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PerfProbe = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PerfProbe"))
local CameraModule = require(script.Parent:WaitForChild("Camera"))

local ForestFade = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
local CLEAR_R    = 50    -- studs: trees this close to the camera's centre are gone outright
local FADE_R     = 120   -- studs: fully solid again from here out
local FADE_MAX   = 1     -- transparency inside the clearing
local FADE_SPEED = 10    -- how sharply a tree eases toward its target
local RETARGET   = 1/30  -- seconds between target recomputes (the apply pass is every frame)

local CLEAR_R2 = CLEAR_R * CLEAR_R
local FADE_R2  = FADE_R * FADE_R

-- Sight-line queries (see blocksSight) walk a coarse grid of the forest rather than all
-- 1,650 trees. CELL is the bucket size in studs.
local CELL      = 32
local SEE_TRANS = 0.55   -- a tree faded past this is see-through enough to not count as cover

-- ── State ───────────────────────────────────────────────────────────────────
-- `parts` holds anything on the tree that draws and has a Transparency: BaseParts, and
-- the Decals the pine's canopy is actually made of. The authored pine hangs its needles
-- off Decals sitting on parts that are themselves fully invisible, and a Decal ignores
-- its part's transparency entirely, so fading the parts alone leaves the tree solid.
type Entry = {
	model: Model,
	parts: { Instance },
	base:  { number },     -- transparency each one was authored with
	x:     number,         -- where the trunk stands, which is all the clearing test needs
	z:     number,
	-- Canopy bounds, only ever read by blocksSight: the tree as a standing cylinder.
	rad:   number,
	y0:    number,
	top:   number,
	cur:   number,         -- fade currently written to the parts
	goal:  number,
}

local entries: { Entry } = {}
local known:   { [Model]: boolean } = {}
local grid:    { [number]: { Entry } } = {}   -- cell key → the trees standing in it
local started    = false
local folderConn: RBXScriptConnection? = nil
local accum      = 0

-- ── Registration ────────────────────────────────────────────────────────────
local function cellKey(x: number, z: number): number
	-- Single number key; the offset keeps negative coordinates from colliding.
	return (math.floor(x / CELL) + 512) * 1024 + (math.floor(z / CELL) + 512)
end

local function applyFade(e: Entry, f: number)
	for i, p in e.parts do
		if p.Parent then
			local b    = e.base[i]
			local draw = p :: any
			draw.Transparency = b + (1 - b) * f
		end
	end
end

local function release(e: Entry)
	known[e.model] = nil
	if e.cur > 0 then applyFade(e, 0) end
end

local function register(model: Model)
	if known[model] then return end

	local parts: { Instance } = {}
	local base:  { number }   = {}
	for _, d in model:GetDescendants() do
		-- Anything already invisible is left out (the Root anchor, and the bare boards the
		-- canopy decals are pinned to): it has nothing to fade, and it would only cost a
		-- property write every frame.
		local draws = d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture")
		if draws and (d :: any).Transparency < 1 then
			table.insert(parts, d)
			table.insert(base, (d :: any).Transparency)
		end
	end
	if #parts == 0 then return end

	-- The pivot is the Root anchor both tree builders plant at ground level, so this is
	-- exactly where the trunk stands. The clearing test needs only the footprint; the
	-- bounding box is for blocksSight, which stands the tree up as a cylinder.
	local at      = model:GetPivot().Position
	local _, size = model:GetBoundingBox()

	known[model] = true
	local e: Entry = {
		model = model, parts = parts, base = base, x = at.X, z = at.Z,
		rad = math.max(size.X, size.Z) * 0.5, y0 = at.Y, top = at.Y + size.Y,
		cur = 0, goal = 0,
	}
	table.insert(entries, e)

	local key    = cellKey(at.X, at.Z)
	local bucket = grid[key]
	if not bucket then bucket = {}; grid[key] = bucket end
	table.insert(bucket, e)
end

-- Parts replicate after the Model itself, and both tree builders set the Root anchor
-- as PrimaryPart last, so that property is the signal the whole tree has landed.
local function watch(inst: Instance)
	if not inst:IsA("Model") or inst.Name ~= "Tree" then return end
	local model = inst :: Model
	if model.PrimaryPart then
		register(model)
		return
	end
	local conn: RBXScriptConnection
	conn = model:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
		if model.PrimaryPart then
			conn:Disconnect()
			if model.Parent then register(model) end
		end
	end)
end

local function attach(folder: Instance)
	if folderConn then folderConn:Disconnect() end
	for _, e in entries do release(e) end   -- hand back anything the last forest left faded
	entries = {}
	known   = {}
	grid    = {}
	folderConn = folder.ChildAdded:Connect(watch)
	for _, c in folder:GetChildren() do watch(c) end
end

-- ── Per-tick work ───────────────────────────────────────────────────────────
-- The camera's focus is the ground point it is looking straight at, which is the middle
-- of the screen. Everything is flat distance from there: no camera height, no depth, no
-- field of view, nothing the zoom can move. Most trees are rejected on the squared
-- distance alone and never reach a square root.
local function retarget(fx: number, fz: number)
	for i = #entries, 1, -1 do
		local e = entries[i]
		if not e.model.Parent or e.model:GetAttribute("Felled") then
			release(e)
			entries[i] = entries[#entries]
			entries[#entries] = nil
		else
			local dx = e.x - fx
			local dz = e.z - fz
			local d2 = dx * dx + dz * dz
			if d2 >= FADE_R2 then
				e.goal = 0
			elseif d2 <= CLEAR_R2 then
				e.goal = FADE_MAX
			else
				local t = 1 - (math.sqrt(d2) - CLEAR_R) / (FADE_R - CLEAR_R)
				e.goal = FADE_MAX * t * t * (3 - 2 * t)   -- smoothstep, so the rim has no seam
			end
		end
	end
end

-- Ease every tree toward its target. Cheap on a still camera: a tree already sitting
-- at its goal costs one comparison and no property write.
local function step(dt: number)
	local a = 1 - math.exp(-FADE_SPEED * dt)
	for _, e in entries do
		if e.cur ~= e.goal then
			local nxt = e.cur + (e.goal - e.cur) * a
			if math.abs(nxt - e.goal) < 0.004 then nxt = e.goal end
			e.cur = nxt
			applyFade(e, nxt)
		end
	end
end

-- ── Sight lines ─────────────────────────────────────────────────────────────
-- Is a tree standing between these two points? Trees are CanQuery=false scenery, so an
-- ordinary raycast goes straight through them and this is the only way to ask.
--
-- Only the cells around `to` are searched, not the whole line. With the camera pitched
-- down at 55 degrees a tree can only hide something within its own height / tan(55), and
-- these are 57 studs at most, so anything doing the hiding stands within ~40 studs of what
-- it hides. A tree nearer the camera than that would have to be in the cleared middle of
-- the screen, where it has already faded out and stopped counting as cover anyway.
function ForestFade.blocksSight(from: Vector3, to: Vector3): boolean
	local dx, dz = to.X - from.X, to.Z - from.Z
	local len2   = dx * dx + dz * dz
	if len2 < 1e-4 then return false end
	local dy = to.Y - from.Y

	local reach = 48
	for cx = math.floor((to.X - reach) / CELL), math.floor((to.X + reach) / CELL) do
		for cz = math.floor((to.Z - reach) / CELL), math.floor((to.Z + reach) / CELL) do
			local bucket = grid[(cx + 512) * 1024 + (cz + 512)]
			if bucket then
				for i = #bucket, 1, -1 do
					local e = bucket[i]
					if not e.model.Parent then
						-- Felled since it was filed here; drop it on the way past.
						bucket[i] = bucket[#bucket]
						bucket[#bucket] = nil
					elseif e.cur <= SEE_TRANS then
						-- Where the sight line passes the trunk, as a fraction along it.
						local t = ((e.x - from.X) * dx + (e.z - from.Z) * dz) / len2
						if t > 0.05 and t < 0.95 then
							local ox = e.x - (from.X + dx * t)
							local oz = e.z - (from.Z + dz * t)
							if ox * ox + oz * oz <= e.rad * e.rad then
								local y = from.Y + dy * t
								if y >= e.y0 and y <= e.top then return true end
							end
						end
					end
				end
			end
		end
	end
	return false
end

-- ── Public ──────────────────────────────────────────────────────────────────
function ForestFade.start()
	if started then return end
	started = true

	local existing = workspace:FindFirstChild("Forest")
	if existing then attach(existing) end
	workspace.ChildAdded:Connect(function(c)
		-- The forest is torn down and regrown per match, so re-attach every time.
		if c.Name == "Forest" and c:IsA("Folder") then attach(c) end
	end)

	PerfProbe.onRender("ForestFade", function(dt: number)
		if #entries == 0 then return end
		accum += dt
		if accum >= RETARGET then
			accum = 0
			local focus = CameraModule.getFocus()
			retarget(focus.X, focus.Z)
		end
		step(dt)
	end)
end

return ForestFade
