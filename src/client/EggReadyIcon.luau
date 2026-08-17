--!strict
--[[
	EggReadyIcon — the mark floating over a Mother's Egg-Sac egg, showing what that egg is
	doing right now. An egg is in exactly one of three states, and wears a mark for two:

	  ripening   — nothing here; its growth bar says it
	  RIPE       — a pulsing pip, so the eggs you can order from read across a colony
	  CARRYING   — a 3D preview of the creature it was ordered to produce, until it is out

	Both marks earn their place. Ripeness is what double-click selects on, so it has to be
	legible at a glance; and once an order is placed the egg carries a specific creature
	for EGG_HATCH_TIME, which is exactly the window where "what is in there" is a real
	question with a real answer.

	The server stamps "EggReady" as the egg ripens and "SpawnType" while it carries an
	order, clearing each when it ends; everything visible is built here.

	World display — the same method the Bonfire uses for its unit icons (DeployerPanel):
	  • ONE ScreenGui overlay for every egg on the map, holding a small frame per egg.
	  • Each frame is repositioned every RenderStep by projecting the egg's world point
	    through Camera:WorldToViewportPoint, and hidden when that point falls off-screen
	    or behind the camera.

	A BillboardGui would scale the marks with distance until they were unreadable across a
	spread-out colony, which is exactly the case this is meant to serve; a projected
	screen frame holds a constant pixel size however far out the camera sits. That matters
	most for the creature preview, which is a 3D model and degrades worst when shrunk.

	The egg's growth progress bar stays a server-built BillboardGui on the egg itself, so
	"still growing" is read off the bar and "ready" off this mark.

	start() is idempotent and safe to call before workspace.EggNests exists — the folder
	is only created when a Mother first plants a nest.
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))
local UILib           = require(script.Parent:WaitForChild("UILib"))

local EggReadyIcon = {}
local localPlayer  = Players.LocalPlayer

-- ── Look ──────────────────────────────────────────────────────────────────────
local PIP_PX   = 26     -- the ripe pip
local UNIT_PX  = 44     -- the creature preview, matching the Bonfire's icon
local VIEW_PX  = 38
local VIEW_PAD = 3
local LIFT     = 2.4    -- studs above the top of the shell the mark is pinned to
local DROP_PX  = 4      -- pixels below the projected point
local MAX_DIST = 240    -- a Mother can hold a whole colony; do not draw the far ones
local C_RIPE   = Color3.fromRGB(255, 150, 70)   -- the egg's own warm orange
local C_CORE   = Color3.fromRGB(255, 226, 190)

local ATTR_READY = "EggReady"
local ATTR_UNIT  = "SpawnType"

-- ── State ─────────────────────────────────────────────────────────────────────
local overlaySg: ScreenGui

-- `kind` is what the mark currently IS ("ready", or "unit:<type>"), so a state change
-- rebuilds and an unchanged state costs nothing. `halo` is only set on the ripe pip.
type Entry = { anchor: BasePart, frame: Frame, kind: string, pip: UILib.ReadyPip? }
local entries: { [BasePart]: Entry } = {}
local started = false

-- One built preview per creature, cloned per egg. A Roller is some sixty parts and a
-- Mother can be carrying several at once.
local templates: { [string]: ViewportFrame } = {}

local function previewFor(unitType: string): ViewportFrame
	local tpl = templates[unitType]
	if not tpl then
		tpl = ViewportPreview.forUnit(unitType, Vector2.new(VIEW_PX, VIEW_PX))
		templates[unitType] = tpl
	end
	local vp = (tpl :: ViewportFrame):Clone()
	-- The clone's CurrentCamera still points at the ORIGINAL's camera, which is parented
	-- outside this copy; re-point it or the viewport renders from nothing.
	vp.CurrentCamera = vp:FindFirstChildOfClass("Camera")
	return vp
end

-- ── Mark ──────────────────────────────────────────────────────────────────────
local function destroyMark(egg: BasePart)
	local entry = entries[egg]
	if not entry then return end
	-- The frame lives in the overlay, NOT under the egg, so nothing tears it down for us
	-- when the shell is spent or the nest comes apart. This is the only thing that does.
	if entry.frame.Parent then entry.frame:Destroy() end
	entries[egg] = nil
end

-- A bare frame in the overlay, sized for the kind of mark going in it.
local function newMarkFrame(px: number): Frame
	local frame                  = Instance.new("Frame")
	frame.Name                   = "EggMark"
	frame.Size                   = UDim2.fromOffset(px, px)
	frame.AnchorPoint            = Vector2.new(0.5, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel        = 0
	frame.ZIndex                 = 15
	frame.Visible                = false   -- the render step reveals it once it is placed
	frame.Parent                 = overlaySg
	return frame
end

-- RIPE: a pulsing pip in the egg's own warm orange. No label -- this has to be readable
-- across a whole colony at once, which is what double-click acts on. The pip itself is
-- UILib.readyPip, shared with the player badge in the menu so the two cannot drift.
local function showReadyMark(egg: BasePart)
	local frame = newMarkFrame(PIP_PX)
	local pip   = UILib.readyPip(frame, 15, C_RIPE, C_CORE)
	entries[egg] = { anchor = egg, frame = frame, kind = "ready", pip = pip }
end

-- CARRYING: the creature that was ordered, rendered from the same geometry it will be
-- drawn with when it climbs out.
local function showUnitMark(egg: BasePart, unitType: string)
	local frame = newMarkFrame(UNIT_PX)
	local vp    = previewFor(unitType)
	vp.Position = UDim2.fromOffset(VIEW_PAD, VIEW_PAD)
	vp.Parent   = frame
	entries[egg] = { anchor = egg, frame = frame, kind = "unit:" .. unitType, pip = nil }
end

-- What this egg should be wearing right now. An order in flight wins: the egg is not ripe
-- while it is carrying, so the two can never both be true, but reading the creature first
-- keeps that independent of attribute-change ordering.
local function wantedKind(egg: BasePart): string?
	local unitType = egg:GetAttribute(ATTR_UNIT)
	if type(unitType) == "string" and unitType ~= "" then return "unit:" .. unitType end
	if egg:GetAttribute(ATTR_READY) == true then return "ready" end
	return nil
end

local function refresh(egg: BasePart)
	local want    = wantedKind(egg)
	local current = entries[egg]
	if current and current.kind == want then return end
	destroyMark(egg)
	if want == "ready" then
		showReadyMark(egg)
	elseif want ~= nil then
		showUnitMark(egg, (want :: string):sub(6))
	end
end

-- ── Tracking ──────────────────────────────────────────────────────────────────
local function track(inst: Instance)
	if not inst:IsA("BasePart") or inst.Name ~= "Egg" then return end
	local egg = inst :: BasePart
	egg:GetAttributeChangedSignal(ATTR_READY):Connect(function() refresh(egg) end)
	egg:GetAttributeChangedSignal(ATTR_UNIT):Connect(function() refresh(egg) end)
	egg.Destroying:Connect(function() destroyMark(egg) end)
	refresh(egg)
end

local function watchRoot(root: Instance)
	for _, d in root:GetDescendants() do track(d) end
	root.DescendantAdded:Connect(track)
end

-- ── Public ────────────────────────────────────────────────────────────────────
function EggReadyIcon.start()
	if started then return end
	started = true

	overlaySg                = Instance.new("ScreenGui")
	overlaySg.Name           = "EggReadyOverlay"
	overlaySg.IgnoreGuiInset = true
	overlaySg.ResetOnSpawn   = false
	overlaySg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlaySg.Parent         = localPlayer.PlayerGui

	-- Reposition every mark each frame, at the same render priority the Bonfire's use.
	RunService:BindToRenderStep("EggReadyPositions", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local camPos = cam.CFrame.Position
		-- One pulse value drives every mark, so a colony breathes together rather than
		-- flickering out of step with itself.
		local pulse  = 0.5 + 0.5 * math.sin(os.clock() * 3.4)

		for _, entry in entries do
			if not entry.anchor.Parent then
				entry.frame.Visible = false
				continue
			end
			-- Size is read live: the shell settles as it ripens, and the mark should ride
			-- the top of it rather than sink in.
			local worldPt = entry.anchor.Position
				+ Vector3.new(0, entry.anchor.Size.Y / 2 + LIFT, 0)

			if (worldPt - camPos).Magnitude > MAX_DIST then
				entry.frame.Visible = false
				continue
			end

			local sv, onScreen = cam:WorldToViewportPoint(worldPt)
			if onScreen and sv.Z > 0 then
				entry.frame.Visible  = true
				entry.frame.Position = UDim2.fromOffset(math.floor(sv.X), math.floor(sv.Y + DROP_PX))
				local pip = entry.pip
				if pip then UILib.pulseReadyPip(pip, pulse) end
			else
				entry.frame.Visible = false
			end
		end
	end)

	local existing = workspace:FindFirstChild("EggNests")
	if existing then watchRoot(existing) end

	-- The folder appears the first time any Mother plants a nest, which can be well into
	-- a match, and it is rebuilt between matches.
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "EggNests" then watchRoot(child) end
	end)
end

return EggReadyIcon
