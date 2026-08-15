--[[
	MotherLegs — procedural walk cycle for the uprooted Hollowed Mother.

	Her four splayed legs are static decor parts baked into the model by
	UnitVisuals.buildMotherDecor. Those parts belong to the server, and it re-sends
	their CFrames every frame she walks (Model:PivotTo), so animating them directly
	would just get overwritten. Instead this CLONES them into a client-only folder,
	hides the originals, and animates the clones — the same trick MechLegs uses for
	the Human core. Cloning rather than rebuilding means the walking legs keep the
	exact colour, material and taper the model was built with.

	The gait:
	  • Diagonal pairs swing together (front-left with rear-right), the salamander
	    stance the model is built in.
	  • The cycle advances with DISTANCE TRAVELLED, not wall-clock time, so the feet
	    never skate — stop moving and the legs settle mid-stride.
	  • A swinging foot lifts and reaches ahead; a planted foot is drawn backward
	    relative to the body, which reads as pushing off the ground.
	  • The knee trails the foot so the limb folds rather than stretching rigidly.

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
local S              = UnitVisuals.MOTHER_SCALE
local CYCLE_PER_STUD = 0.055      -- gait cycles advanced per stud walked
local STRIDE         = 2.6 * S    -- studs a foot reaches fore/aft through a stride
local LEG_LIFT       = 1.5 * S    -- studs a swinging foot rises
local KNEE_FOLLOW    = 0.35       -- how much of the foot's swing the knee inherits
local KNEE_RISE      = 0.45       -- how much of the foot's lift the knee inherits
local UPPER_THICK    = 1.35 * S   -- matches buildMotherDecor's LegUpper
local FORE_THICK     = 1.0 * S    -- matches buildMotherDecor's LegFore
local CULL_DIST2     = 700 * 700

type Leg = {
	upper: BasePart, fore: BasePart, pad: BasePart,   -- animated clones
	hidden: { BasePart },                             -- the model's own parts, hidden
	spec: UnitVisuals.MotherLeg,
}
type Entry = {
	base:     BasePart,
	legs:     { Leg },
	walkTime: number,
	lastPos:  Vector3,
}

local entries: { [string]: Entry } = {}
local pending: { [string]: boolean } = {}   -- attach waiting on parts to replicate
local legsFolder: Folder
local camera:     Camera
local conn:       RBXScriptConnection?

-- Pose one leg for the current point in the gait. `look` is the body's forward
-- direction on the ground plane; `swing` is this leg's -1..1 position in the cycle.
local function poseLeg(leg: Leg, baseCF: CFrame, look: Vector3, swing: number)
	-- MOTHER_LEGS holds authored coordinates, so scale them the same way the decor
	-- builder does before turning them into world points.
	local spec = leg.spec
	local hip  = baseCF:PointToWorldSpace(spec.hip * S)

	-- Reach ahead through the swing, trail behind through the stance; lift only
	-- while swinging forward.
	local reach = look * (swing * STRIDE)
	local rise  = Vector3.new(0, math.max(0, swing) * LEG_LIFT, 0)

	local foot = baseCF:PointToWorldSpace(spec.foot * S) + reach + rise
	local knee = baseCF:PointToWorldSpace(spec.knee * S) + reach * KNEE_FOLLOW + rise * KNEE_RISE

	UnitVisuals.orientYBetween(leg.upper, hip,  knee, UPPER_THICK)
	UnitVisuals.orientYBetween(leg.fore,  knee, foot, FORE_THICK)
	leg.pad.CFrame = CFrame.new(baseCF:PointToWorldSpace(spec.pad * S) + reach + rise)
end

local function step(_dt: number)
	local camPos = camera and camera.CFrame.Position or Vector3.zero
	for id, e in entries do
		if not e.base.Parent then
			MotherLegs.detach(id)
			continue
		end

		local pos   = e.base.Position
		local moved = (pos - e.lastPos).Magnitude
		e.lastPos   = pos

		-- Far off screen: skip the pose work but keep tracking movement, so the
		-- stride is already correct when she comes back into view.
		local d = pos - camPos
		if d:Dot(d) > CULL_DIST2 then continue end

		-- Distance-driven, so the stride only advances as she covers ground.
		e.walkTime += moved * CYCLE_PER_STUD

		local baseCF = e.base.CFrame
		-- The creature is built facing +Z relative to its base (buildMotherDecor
		-- applies a 180° flip), so "forward" is the base's +Z axis — its ZVector —
		-- and NOT its LookVector, which points out of her back.
		local look = baseCF.ZVector
		look = Vector3.new(look.X, 0, look.Z)
		look = look.Magnitude > 1e-3 and look.Unit or Vector3.zAxis

		for _, leg in e.legs do
			poseLeg(leg, baseCF, look, math.sin(e.walkTime * math.pi * 2 + leg.spec.phase))
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local function attachNow(ccId: string, model: Model)
	if entries[ccId] then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local function borrow(name: string): BasePart?
		return model:FindFirstChild(name) :: BasePart?
	end

	local legs: { Leg } = {}
	for i, spec in UnitVisuals.MOTHER_LEGS do
		local upper = borrow("LegUpper" .. i)
		local fore  = borrow("LegFore" .. i)
		local pad   = borrow("Foot" .. i)
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

		legs[#legs + 1] = {
			upper = aUpper, fore = aFore, pad = aPad,
			hidden = { upper, fore, pad },
			spec = spec,
		}
	end
	if #legs == 0 then return end

	entries[ccId] = { base = base, legs = legs, walkTime = 0, lastPos = base.Position }
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
