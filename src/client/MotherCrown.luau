-- MotherCrown.luau
-- Client-side animator for the Hollowed Mother's sea-anemone tentacle crown.
-- The crown segments ("Crown_<i>_<j>") are built server-side in a static resting
-- pose by UnitVisuals.buildMotherDecor; here every client sways them with the same
-- wiggly-column math as the Hagfish ground-tentacle strike (HagfishBody), but much
-- slower — a living anemone drift instead of a whip. CFrame writes are local-only,
-- so there is zero replication cost, and fog still works because the parts live
-- inside the building model (FogManager's building pass owns their transparency).
--!strict

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))

local MotherCrown = {}

-- Hagfish strike uses T_WFREQ = 9.0 / T_WAMP = 0.85; the crown drifts far slower.
local W_FREQ  = 1.5            -- wobble cycles/sec (slow anemone sway)
local W_AMP   = 0.55           -- sway amplitude at the tips (studs)
local W_K     = math.pi * 1.2  -- wave phase along each tentacle (same as hagfish)
local CULL_SQ = 300 * 300

-- Resting local spine points per crown tentacle — identical on every Mother, so
-- computed once at module load from the shared spec.
local SPINES: { { Vector3 } } = {}
for _, spec in UnitVisuals.MOTHER_CROWN do
	SPINES[#SPINES + 1] = UnitVisuals.motherCrownSpine(spec)
end

type Entry = {
	base:  BasePart,
	segs:  { { BasePart } },   -- segs[i][j] — tentacle i, segment j (1..3)
	phase: number,
}

local active: { [string]: Entry } = {}
local camera: Camera

-- ── Attach / detach ─────────────────────────────────────────────────────────────
local function attach(model: Model)
	local id = model.Name
	if active[id] then return end
	local base = model:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then return end

	-- Collect the crown segments by name. Absent (e.g. non-Mother SwarmCC models,
	-- old saves) → nothing to animate.
	local segs: { { BasePart } } = {}
	local found = 0
	for i = 1, #SPINES do
		segs[i] = {}
		for j = 1, 3 do
			local p = model:FindFirstChild("Crown_" .. i .. "_" .. j)
			if p and p:IsA("BasePart") then
				segs[i][j] = p
				found += 1
			end
		end
	end
	if found == 0 then return end

	active[id] = { base = base :: BasePart, segs = segs, phase = math.random() * 100 }
	base.Destroying:Once(function() active[id] = nil end)
end

-- ── Init + animation loop ───────────────────────────────────────────────────────
function MotherCrown.init(cam: Camera)
	camera = cam

	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 30) :: Folder?
		if not bf then return end
		local function tryAttach(child: Instance)
			if child:IsA("Model") and child:GetAttribute("SwarmCC") then
				-- Decor parts may land a moment after the model replicates.
				task.delay(0.2, function()
					if child.Parent then attach(child :: Model) end
				end)
			end
		end
		for _, c in bf:GetChildren() do tryAttach(c) end
		bf.ChildAdded:Connect(tryAttach)
	end)

	RunService.RenderStepped:Connect(function()
		local now    = os.clock()
		local camPos = camera.CFrame.Position

		for id, e in active do
			local base = e.base
			if not base.Parent then
				active[id] = nil
				continue
			end

			local bpos = base.Position
			local dx, dy, dz = bpos.X - camPos.X, bpos.Y - camPos.Y, bpos.Z - camPos.Z
			if dx * dx + dy * dy + dz * dz > CULL_SQ then continue end

			-- Ground frame = bottom of the (invisible) base box, tracking uproot moves.
			local groundCF = base.CFrame * CFrame.new(0, -base.Size.Y / 2, 0)
			local t        = now + e.phase

			for i, spine in SPINES do
				local spec = UnitVisuals.MOTHER_CROWN[i]
				local row  = e.segs[i]
				-- World spine with the hagfish wobble (sway grows toward the tip).
				local prev: Vector3? = nil
				for j = 0, 3 do
					local sj   = j / 3
					local wobX = math.sin(t * W_FREQ + spec.seed + sj * W_K) * W_AMP * sj
					local wobZ = math.cos(t * W_FREQ * 1.27 + spec.seed) * W_AMP * 0.7 * sj
					local wp   = (groundCF * CFrame.new(spine[j + 1] + Vector3.new(wobX, 0, wobZ))).Position
					if prev and row[j] then
						UnitVisuals.orientYBetween(row[j], prev, wp, spec.thicks[j])
					end
					prev = wp
				end
			end
		end
	end)
end

return MotherCrown
