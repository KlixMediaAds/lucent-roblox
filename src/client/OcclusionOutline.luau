--!strict
--[[
	OcclusionOutline — your own units and buildings keep a bright edge when something
	gets in front of them.

	Whenever a thing you own goes behind cover (a structure, a rise in the terrain, or a
	tree the clearing has not thinned out) it gets a Highlight drawn on top of everything,
	so you can still see where it is and what shape it is. The moment it comes back into
	the clear the edge goes away again, so nothing you can already see is decorated.

	Two different tests decide "is it covered", because two different kinds of thing can
	cover it:

	  • A raycast from the camera, stopped a few studs short of the target so the ground
	    behind it is never mistaken for cover. Units are excluded from it wholesale, since
	    one of your own soldiers standing in front of another is not worth an outline.
	  • ForestFade.blocksSight, because trees are CanQuery=false scenery that raycasts
	    pass straight through. It also ignores any tree already faded out, so a canopy in
	    the middle of the screen does not raise an outline for something you can see fine.

	Highlights are RATIONED. Roblox stops rendering them past about thirty on screen and
	they are one of the most expensive things a client can draw, so an army of sixty units
	standing in a wood would otherwise spend its frame budget outlining itself. Only the
	nearest MAX_ON covered things get an edge, handed out from a fixed pool of Highlight
	instances that are re-pointed rather than created per unit.

	Purely local and purely cosmetic: nothing here replicates or is queryable.
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local ForestFade = require(script.Parent:WaitForChild("ForestFade"))

local OcclusionOutline = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
local EDGE_COL   = Color3.fromRGB(140, 255, 195)  -- friendly green, distinct from selection cyan
local FILL_TRANS = 0.78   -- the body is a faint wash; the edge does the work
local TICK       = 1/10   -- seconds between occlusion checks
local AIM_UP     = 2      -- studs above the root the sight line aims at
local STOP_SHORT = 3      -- studs the ray stops short, so the target's own ground is not cover
-- How many covered things may wear an edge at once. Roblox renders at most ~31 Highlights
-- and charges dearly for each, so this is a hard budget, spent on the ones nearest the
-- camera: those are the ones the player is actually looking for.
local MAX_ON     = 14

-- ── State ───────────────────────────────────────────────────────────────────
type Entry = {
	root:    BasePart,    -- what the sight line aims at
	adornee: Instance,    -- what the Highlight wraps (the model for a building, the part for a unit)
}

local entries: { [Instance]: Entry } = {}
local conns:   { RBXScriptConnection } = {}
local myId     = ""
local started  = false
local accum    = 0

local rp = RaycastParams.new()
rp.FilterType  = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true

-- ── The Highlight pool ──────────────────────────────────────────────────────
-- At most MAX_ON of these ever exist. They are handed to whatever is covered and nearest
-- this tick and taken back when it stops being either, so in the steady state a Highlight
-- is never created, destroyed or reparented, only re-adorned.
local pool:     { Highlight }             = {}
local assigned: { [Instance]: Highlight } = {}   -- adornee -> the Highlight wearing it

local function newHighlight(): Highlight
	local hl                = Instance.new("Highlight")
	hl.Name                 = "OccludedEdge"
	hl.DepthMode            = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor            = EDGE_COL
	hl.FillTransparency     = FILL_TRANS
	hl.OutlineColor         = EDGE_COL
	hl.OutlineTransparency  = 0
	hl.Enabled              = false
	hl.Parent               = workspace
	table.insert(pool, hl)
	return hl
end

local function release(adornee: Instance)
	local hl = assigned[adornee]
	if not hl then return end
	assigned[adornee] = nil
	hl.Enabled = false
	hl.Adornee = nil
end

-- Give `adornee` an edge, taking a spare from the pool (or growing it, up to MAX_ON).
-- Returns false when the budget is already spent.
local function acquire(adornee: Instance): boolean
	if assigned[adornee] then return true end
	local free: Highlight? = nil
	for _, hl in pool do
		if hl.Adornee == nil then free = hl; break end
	end
	if not free then
		if #pool >= MAX_ON then return false end
		free = newHighlight()
	end
	local hl = free :: Highlight
	hl.Adornee = adornee
	hl.Enabled = true
	assigned[adornee] = hl
	return true
end

local function drop(key: Instance)
	local e = entries[key]
	if not e then return end
	release(e.adornee)
	entries[key] = nil
end

-- Ownership arrives as an OwnerId StringValue that replicates a beat after the instance
-- itself, so this waits for it rather than reading it inline and missing every unit.
local function claim(inst: Instance, isUnit: boolean)
	if entries[inst] then return end
	task.spawn(function()
		local ov = inst:WaitForChild("OwnerId", 15)
		if not ov or not ov:IsA("StringValue") or ov.Value ~= myId then return end
		if not inst.Parent or entries[inst] then return end

		if isUnit then
			if inst:IsA("BasePart") then
				entries[inst] = { root = inst, adornee = inst }
			end
			return
		end

		local base = inst:WaitForChild("Base", 15)
		if base and base:IsA("BasePart") and inst.Parent and not entries[inst] then
			entries[inst] = { root = base, adornee = inst }
		end
	end)
end

local function attach(folder: Instance, isUnit: boolean)
	table.insert(conns, folder.ChildAdded:Connect(function(c) claim(c, isUnit) end))
	table.insert(conns, folder.ChildRemoved:Connect(drop))
	for _, c in folder:GetChildren() do claim(c, isUnit) end
end

-- Every match tears its folders down and builds new ones, so the whole set is rebuilt
-- from scratch each time rather than trying to reconcile the old one.
local function rewire()
	for _, c in conns do c:Disconnect() end
	conns = {}
	for key in entries do drop(key) end
	-- Nothing keeps an edge across a match boundary; hand the whole pool back.
	for _, hl in pool do
		hl.Enabled = false
		hl.Adornee = nil
	end
	table.clear(assigned)

	local units = workspace:FindFirstChild("Units")
	if units then attach(units, true) end
	local buildings = workspace:FindFirstChild("Buildings")
	if buildings then attach(buildings, false) end
end

-- ── Per-tick work ───────────────────────────────────────────────────────────
local ignore: { Instance } = {}
-- What is covered right now, gathered before any edge is handed out: the budget can
-- only be spent on the nearest few once the whole set is known.
type Covered = { adornee: Instance, dist: number }
local covered: { Covered } = {}

local function refresh()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local eye = cam.CFrame.Position
	local fwd = cam.CFrame.LookVector

	-- Your own units never count as cover for each other, so the whole folder sits out of
	-- the raycast. Rebuilt each tick because the folders are replaced between matches.
	table.clear(ignore)
	local units = workspace:FindFirstChild("Units")
	if units then table.insert(ignore, units) end
	local miners = workspace:FindFirstChild("Miners")
	if miners then table.insert(ignore, miners) end
	rp.FilterDescendantsInstances = ignore

	table.clear(covered)

	for key, e in entries do
		if not e.root.Parent or not key.Parent then
			drop(key)
			continue
		end

		local target = e.root.Position + Vector3.new(0, AIM_UP, 0)
		local to     = target - eye
		local dist   = to.Magnitude
		if fwd:Dot(to) <= 0 or dist < STOP_SHORT + 1 then
			-- Behind the camera, or the camera is sitting on top of it. Nothing to draw.
			release(e.adornee)
			continue
		end

		-- Stopping short matters: run the ray the whole way and it lands on the terrain
		-- the target is standing on, and everything you own reads as permanently covered.
		local hit = workspace:Raycast(eye, to.Unit * (dist - STOP_SHORT), rp)
		local blocked = hit ~= nil and not hit.Instance:IsDescendantOf(key)
		if not blocked then
			blocked = ForestFade.blocksSight(eye, target)
		end
		if blocked then
			table.insert(covered, { adornee = e.adornee, dist = dist })
		else
			release(e.adornee)
		end
	end

	-- Spend the budget nearest-first. The sort only matters once more is covered than
	-- there is budget, which is exactly the case this pool exists for.
	if #covered > MAX_ON then
		table.sort(covered, function(a, b) return a.dist < b.dist end)
		-- Everything past the budget gives its edge back BEFORE the winners ask for one;
		-- otherwise the pool is still full when they ask and the nearest units flicker.
		for i = MAX_ON + 1, #covered do
			release(covered[i].adornee)
		end
	end
	for i = 1, math.min(#covered, MAX_ON) do
		acquire(covered[i].adornee)
	end
end

-- ── Public ──────────────────────────────────────────────────────────────────
function OcclusionOutline.start()
	if started then return end
	started = true
	myId    = tostring(Players.LocalPlayer.UserId)

	rewire()
	workspace.ChildAdded:Connect(function(c)
		if c.Name == "Units" or c.Name == "Buildings" then rewire() end
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		if accum < TICK then return end
		accum = 0
		refresh()
	end)
end

return OcclusionOutline
