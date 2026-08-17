--!strict
--[[
    MotherInject: ground-targeting mode for the Hollowed Mother's INJECT action.

    Pressing INJECT on the Mother's command card (or [R]) calls begin(): a purple
    hologram sight follows the cursor across the terrain, naming what sits under it,
    until the player left-clicks, which sends the point to the server
    (Network.injectGround). Right-click or [Esc] calls it off.

    The sight reads what is under it. Bare ground is one target; so is any plant of her
    own she has already grown, which snaps the sight onto it and names what injecting it
    would give up (InjectPlants.INJECT). Plants with nothing to give yet read "coming
    soon" and refuse the click, as does a target she cannot pay for.

    Holding [Shift] on the click QUEUES that spot instead of committing to a single one:
    the sight stays up, a dim ghost is left behind for each queued wound, and the Mother
    works through them in order. A plain click commits and closes targeting.

    The ghosts outlive targeting: closing the sight (right-click, [Esc], INJECT again)
    leaves the queued run standing so the player can watch her walk it. A ghost clears
    when she reaches it, and the whole run clears when it is called off for real, which
    is a plain un-shifted injection or a hand-issued move order (clearQueue). Both are
    the same events that wipe the queue server-side.

    While aiming, init.client's isBlocked() reports true, so the click that picks the
    spot doesn't also clear the selection or start a drag-select box.
]]

local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local InjectPlants      = require(Shared:WaitForChild("InjectPlants"))
local Players           = game:GetService("Players")

local MotherInject = {}

-- ── State ─────────────────────────────────────────────────────────────────────
local networkRef:   any
local cameraRef:    any
local onAimChanged: ((boolean) -> ())? = nil
-- Told the InjectPlants `preview` name of whatever the sight is over (nil for bare ground
-- or a plant with nothing to give). MotherPanel uses it to turn the INJECT tile into a
-- picture of what the plant under the cursor would become.
local onHoverChanged: ((string?) -> ())? = nil
local ccBaseFn:     (() -> BasePart?)? = nil
local resourcesFn:  (() -> number)?    = nil

-- The click that ends targeting (either the commit or the cancel) must not ALSO reach
-- the drag-select box or the Mother's right-click move order. Handler order between
-- scripts isn't guaranteed, so isAiming() keeps reporting true for a beat after
-- targeting ends and everything that asks stays blocked for that click.
local CLICK_GRACE = 0.1
local endedAt     = 0

local aimingCCId: string?    = nil
local marker:     Model?     = nil
local markerDisc: BasePart?  = nil
local markerCore: BasePart?  = nil
local markerName: TextLabel? = nil
local markerSub:  TextLabel? = nil
local markerLight: PointLight? = nil
local renderConn: RBXScriptConnection? = nil

-- What the sight is currently sitting on: bare ground when this is nil, otherwise one of
-- the Mother's own plants, snapped to and named. Refreshed on a timer while aiming.
local hoverPlant: Model? = nil
local hoverInfo:  InjectPlants.InjectInfo? = nil
local hoverPos:   Vector3? = nil
local lastHoverScan = 0
-- How near the cursor a plant is snapped onto. This MUST stay below
-- Config.MOTHER_INJECT_CLEAR: a plant inside this radius becomes the TARGET, so if it
-- reached as far as the clear radius there would be no band of ground left that is both
-- aimed-at-bare-ground and too crowded to take a spike, and the crowding rule below could
-- never fire at all. At 5 vs a clear radius of 8 the band is 5-8 studs, which refuses
-- about seven of every ten attempts to re-inject a spot already worked over.
-- 5 studs still sits inside the body of every plant (the widest, the frond, is ~6), so
-- pointing at one to burst it is unchanged in practice.
local HOVER_RADIUS  = 5
local CLEAR_D       = Config.MOTHER_INJECT_CLEAR * 2   -- hologram disc diameter

-- Set while the sight is over BARE GROUND that has a plant standing too close to take a
-- spike. Refreshed by every hover scan, since the Mother can be walking a queued run and
-- growing plants under her own sight while the player is still aiming.
local groundCrowded = false
local HOVER_PERIOD  = 0.08   -- seconds between scans of her plants

-- One dim ghost per spot on the queue, so the run can be read off the ground. Each keeps
-- its tag label, since the marks renumber as she works through them.
type Ghost = { model: Model, tag: TextLabel, label: string, plant: Model? }
local ghosts: { Ghost } = {}

-- Plants already spoken for by a queued mark. Injecting one twice would walk her over to
-- a wound that is no longer there and burn the cost for nothing, so the sight refuses it.
local queuedPlants: { [Model]: boolean } = {}

local MARK_COL  = Color3.fromRGB(196, 90, 255)
local TEXT_COL  = Color3.fromRGB(236, 214, 255)
local BLOCK_COL = Color3.fromRGB(200, 62, 72)   -- target she cannot take: refuses the click
local WAIT_COL  = Color3.fromRGB(150, 196, 255)  -- spike still recharging: allowed, but it waits

-- What the sight says it is about to inject. Only the ground is injectable for now, so
-- this is fixed; once she can inject other things it becomes a lookup on whatever the
-- cursor is over.
local TARGET_NAME = "Ground"

-- ── Marker ────────────────────────────────────────────────────────────────────
-- The floating readout above the sight: a name plate for what is being injected, and a
-- second line counting the spots already queued behind it. Returns that second line.
local function buildReadout(parent: BasePart): (TextLabel, TextLabel)
	local bb          = Instance.new("BillboardGui")
	bb.Name           = "InjectReadout"
	bb.Size           = UDim2.fromOffset(124, 42)
	bb.StudsOffset    = Vector3.new(0, 9.5, 0)
	bb.AlwaysOnTop    = true
	bb.LightInfluence = 0
	bb.MaxDistance    = 600
	bb.Parent         = parent

	local card                  = Instance.new("Frame")
	card.Size                   = UDim2.new(1, 0, 0, 22)
	card.BackgroundColor3       = Color3.fromRGB(12, 5, 20)
	card.BackgroundTransparency = 0.35
	card.BorderSizePixel        = 0
	card.Parent                 = bb
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)

	local stroke        = Instance.new("UIStroke")
	stroke.Color        = MARK_COL
	stroke.Thickness    = 1
	stroke.Transparency = 0.25
	stroke.Parent       = card

	local name                  = Instance.new("TextLabel")
	name.Size                   = UDim2.new(1, 0, 1, 0)
	name.BackgroundTransparency = 1
	name.Font                   = Enum.Font.GothamBold
	name.TextSize               = 13
	name.TextColor3             = TEXT_COL
	name.Text                   = TARGET_NAME
	name.Parent                 = card

	local sub                   = Instance.new("TextLabel")
	sub.Name                    = "Queued"
	sub.Size                    = UDim2.new(1, 0, 0, 14)
	sub.Position                = UDim2.new(0, 0, 0, 23)
	sub.BackgroundTransparency  = 1
	sub.Font                    = Enum.Font.GothamBold
	sub.TextSize                = 10
	sub.TextColor3              = MARK_COL
	sub.TextStrokeTransparency  = 0.6
	sub.TextStrokeColor3        = Color3.new(0, 0, 0)
	sub.Text                    = ""
	sub.Parent                  = bb

	return name, sub
end

-- Seconds until her spike can go in again, off the timestamp the server stamps on her
-- base. Injecting is free, so this is the pacing the player actually feels: the sight
-- reports it, but does not refuse the click -- a spot laid onto a run already under way is
-- accepted, and the server is the one that decides.
local function cooldownLeft(): number
	local base = ccBaseFn and ccBaseFn()
	local v    = base and base:GetAttribute("InjectReadyAt")
	if type(v) ~= "number" then return 0 end
	return math.max(0, v - workspace:GetServerTimeNow())
end

-- Can she pay for one more wound? The server charges per injection, queued ones included,
-- so a target she cannot afford is refused here rather than silently dropped there.
local function canAfford(): boolean
	local cost = Config.MOTHER_INJECT_COST
	if cost <= 0 then return true end
	return (resourcesFn and resourcesFn() or 0) >= cost
end

-- A target the sight will not take: a plant with nothing to give yet, or one she cannot
-- pay for. The sight turns on it rather than letting the click go nowhere.
local function blockedTarget(): boolean
	if hoverInfo and not hoverInfo.kind then return true end
	if hoverPlant and queuedPlants[hoverPlant] then return true end
	if groundCrowded then return true end
	return not canAfford()
end

-- Name plate + second line, both driven by whatever the sight is currently over.
local function refreshReadout()
	local nameLbl, sub = markerName, markerSub
	if not (nameLbl and sub) then return end

	nameLbl.Text = hoverInfo and hoverInfo.label or TARGET_NAME

	if not canAfford() then
		sub.Text       = "NEED " .. Config.MOTHER_INJECT_COST .. " RESOURCES"
		sub.TextColor3 = BLOCK_COL
	elseif hoverPlant and queuedPlants[hoverPlant] then
		sub.Text       = "ALREADY QUEUED"
		sub.TextColor3  = BLOCK_COL
	elseif groundCrowded then
		sub.Text       = "GROUND TOO CROWDED"
		sub.TextColor3 = BLOCK_COL
	elseif hoverInfo then
		sub.Text       = hoverInfo.yield
		sub.TextColor3 = hoverInfo.kind and MARK_COL or BLOCK_COL
	else
		local cd = cooldownLeft()
		if cd > 0 then
			-- She is between wounds: the spot can still be laid down, it just waits its turn.
			sub.Text       = "SPIKE READY IN " .. math.ceil(cd) .. "s"
			sub.TextColor3 = WAIT_COL
		else
			local n        = #ghosts
			sub.Text       = n > 0 and ("+" .. n .. " QUEUED") or "[SHIFT] TO QUEUE"
			sub.TextColor3 = MARK_COL
		end
	end
end

local function buildMarker(): Model
	local m  = Instance.new("Model")
	m.Name   = "MotherInjectMarker"

	-- Flat ring of light on the ground.
	local disc        = Instance.new("Part")
	disc.Name         = "Disc"
	disc.Shape        = Enum.PartType.Cylinder
	-- Sized straight off MOTHER_INJECT_CLEAR: the ring the player sees IS the ground that
	-- has to be clear of plants, so the refusal below never comes as a surprise.
	disc.Size         = Vector3.new(0.4, CLEAR_D, CLEAR_D)
	disc.CFrame       = CFrame.new(0, -500, 0) * CFrame.Angles(0, 0, math.pi / 2)
	disc.Color        = MARK_COL
	disc.Material     = Enum.Material.Neon
	disc.Transparency = 0.55
	disc.Anchored     = true
	disc.CanCollide   = false
	disc.CanQuery     = false
	disc.CastShadow   = false
	disc.Parent       = m

	-- The spike's line of entry.
	local core        = Instance.new("Part")
	core.Name         = "Core"
	core.Size         = Vector3.new(1.2, 14, 1.2)
	core.CFrame       = CFrame.new(0, -500, 0)
	core.Color        = MARK_COL
	core.Material     = Enum.Material.Neon
	core.Transparency = 0.4
	core.Anchored     = true
	core.CanCollide   = false
	core.CanQuery     = false
	core.CastShadow   = false
	core.Parent       = m

	local light      = Instance.new("PointLight")
	light.Color      = MARK_COL
	light.Brightness = 3
	light.Range      = 20
	light.Shadows    = false
	light.Parent     = core

	m.PrimaryPart = core
	m.Parent      = workspace
	markerDisc    = disc
	markerCore    = core
	markerLight   = light
	markerName, markerSub = buildReadout(core)
	refreshReadout()
	return m
end

local function destroyMarker()
	if marker then marker:Destroy() end
	marker      = nil
	markerDisc  = nil
	markerCore  = nil
	markerLight = nil
	markerName  = nil
	markerSub   = nil
end

-- ── What the sight is over ────────────────────────────────────────────────────
-- Her plants are scenery (CanQuery is off), so the cursor cannot hit them directly:
-- the nearest of her own plants to the point under the cursor wins instead, which also
-- gives the sight its snap onto the plant.
local function scanHover(groundPos: Vector3)
	local folder   = workspace:FindFirstChild("InjectPlants")
	local bestPl:  Model? = nil
	local bestIn:  InjectPlants.InjectInfo? = nil
	local bestPos: Vector3? = nil
	local bestD    = HOVER_RADIUS * HOVER_RADIUS
	local userId   = Players.LocalPlayer.UserId

	-- Anything standing inside the hologram, whoever grew it. Kept separate from the snap
	-- search: the snap only takes plants she is allowed to inject, but a rival's plant (or
	-- one she cannot target) still occupies the ground and still blocks a spike.
	local clearR2 = Config.MOTHER_INJECT_CLEAR * Config.MOTHER_INJECT_CLEAR
	local crowded = false

	if folder then
		for _, child in folder:GetChildren() do
			if not child:IsA("Model") then continue end
			local p  = child:GetPivot().Position
			local dx = p.X - groundPos.X
			local dz = p.Z - groundPos.Z
			local d  = dx * dx + dz * dz
			if d < clearR2 then crowded = true end

			-- Hers, or wild: a plant with no owner grew on its own (WildPlants seeds the
			-- map with them) and is anyone's to take. Someone else's is off limits.
			local owner = child:GetAttribute("OwnerUserId")
			if owner ~= nil and owner ~= userId then continue end
			local info = InjectPlants.injectInfo(child)
			if not info then continue end
			if d < bestD then
				bestD, bestPl, bestIn, bestPos = d, child, info, p
			end
		end
	end

	-- Only bare ground can be crowded out; aiming at a plant is a deliberate target.
	local nowCrowded = crowded and bestPl == nil
	local changed    = nowCrowded ~= groundCrowded
	groundCrowded    = nowCrowded

	if bestPl == hoverPlant then
		if changed then refreshReadout() end
		return
	end
	hoverPlant, hoverInfo, hoverPos = bestPl, bestIn, bestPos
	refreshReadout()
	if onHoverChanged then onHoverChanged(bestIn and bestIn.preview or nil) end
end

-- ── Queued ghosts ─────────────────────────────────────────────────────────────
-- A quieter copy of the sight, left standing on a spot the player shift-queued. It
-- carries its place in the run, so the order she walks them in reads at a glance.
local function spawnGhost(pos: Vector3, label: string, plant: Model?)
	local g  = Instance.new("Model")
	g.Name   = "MotherInjectQueued"

	local disc        = Instance.new("Part")
	disc.Name         = "Disc"
	disc.Shape        = Enum.PartType.Cylinder
	disc.Size         = Vector3.new(0.3, CLEAR_D * 0.82, CLEAR_D * 0.82)
	disc.CFrame       = CFrame.new(pos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	disc.Color        = MARK_COL
	disc.Material     = Enum.Material.Neon
	disc.Transparency = 0.75
	disc.Anchored     = true
	disc.CanCollide   = false
	disc.CanQuery     = false
	disc.CastShadow   = false
	disc.Parent       = g

	local core        = Instance.new("Part")
	core.Name         = "Core"
	core.Size         = Vector3.new(0.7, 8, 0.7)
	core.CFrame       = CFrame.new(pos + Vector3.new(0, 4, 0))
	core.Color        = MARK_COL
	core.Material     = Enum.Material.Neon
	core.Transparency = 0.7
	core.Anchored     = true
	core.CanCollide   = false
	core.CanQuery     = false
	core.CastShadow   = false
	core.Parent       = g

	local bb          = Instance.new("BillboardGui")
	bb.Size           = UDim2.fromOffset(80, 14)
	bb.StudsOffset    = Vector3.new(0, 5.5, 0)
	bb.AlwaysOnTop    = true
	bb.LightInfluence = 0
	bb.MaxDistance    = 600
	bb.Parent         = core

	local tag                  = Instance.new("TextLabel")
	tag.Size                   = UDim2.new(1, 0, 1, 0)
	tag.BackgroundTransparency = 1
	tag.Font                   = Enum.Font.GothamBold
	tag.TextSize               = 10
	tag.TextColor3             = TEXT_COL
	tag.TextTransparency       = 0.25
	tag.TextStrokeTransparency = 0.5
	tag.TextStrokeColor3       = Color3.new(0, 0, 0)
	tag.Text                   = (#ghosts + 1) .. ". " .. label
	tag.Parent                 = bb

	g.PrimaryPart = core
	g.Parent      = workspace
	table.insert(ghosts, { model = g, tag = tag, label = label, plant = plant })
	if plant then queuedPlants[plant] = true end
end

local function renumberGhosts()
	for i, gh in ghosts do
		gh.tag.Text = i .. ". " .. gh.label
	end
end

local function clearGhosts()
	for _, gh in ghosts do gh.model:Destroy() end
	table.clear(ghosts)
	table.clear(queuedPlants)
end

-- She works the run in the order it was laid down, so only the leading mark can be the
-- one she is walking to. Same arrival radius the server uses to decide she is standing
-- over the spot, so the mark goes out as the spike goes in.
local function consumeArrived()
	local lead = ghosts[1]
	if not lead then return end
	local base = ccBaseFn and ccBaseFn()
	if not base or not base.Parent then return end
	local mark = lead.model.PrimaryPart
	if not mark then return end
	local flat = Vector3.new(mark.Position.X - base.Position.X, 0, mark.Position.Z - base.Position.Z)
	if flat.Magnitude > Config.MOTHER_INJECT_ARRIVE then return end
	lead.model:Destroy()
	if lead.plant then queuedPlants[lead.plant] = nil end
	table.remove(ghosts, 1)
	renumberGhosts()
	refreshReadout()
end

-- ── Aiming ────────────────────────────────────────────────────────────────────
-- Closes the sight only. The queued run stays standing: it is hers now, not the
-- targeting session's, and it takes a new order to call it off.
local function stopAiming()
	if not aimingCCId then return end
	aimingCCId = nil
	endedAt    = os.clock()
	if renderConn then renderConn:Disconnect(); renderConn = nil end
	destroyMarker()
	hoverPlant, hoverInfo, hoverPos = nil, nil, nil
	groundCrowded = false
	if onHoverChanged then onHoverChanged(nil) end
	if onAimChanged then onAimChanged(false) end
end

function MotherInject.init(network: any, cameraModule: any, aimChanged: ((boolean) -> ())?,
	getCCBase: (() -> BasePart?)?, getResources: (() -> number)?,
	hoverChanged: ((string?) -> ())?)
	networkRef     = network
	cameraRef      = cameraModule
	onAimChanged   = aimChanged
	ccBaseFn       = getCCBase
	resourcesFn    = getResources
	onHoverChanged = hoverChanged

	RunService.Heartbeat:Connect(function()
		if #ghosts == 0 then return end
		consumeArrived()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not aimingCCId then return end

		if input.KeyCode == Enum.KeyCode.Escape
			or input.UserInputType == Enum.UserInputType.MouseButton2 then
			stopAiming()
			return
		end

		-- `processed` covers clicks the command card itself swallowed (including the
		-- press on INJECT that started this).
		if processed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

		-- Nothing here she can take (a "coming soon" plant, one already queued, or a
		-- wound she cannot pay for): the click is spent on nothing and the sight stays up.
		if blockedTarget() then return end

		local ccId  = aimingCCId :: string
		local plant = hoverPlant
		local pos   = hoverPos or cameraRef.getGroundPosition()
		local label = hoverInfo and hoverInfo.label or TARGET_NAME
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		-- Shift keeps the sight up, so the next spot goes straight onto the queue.
		if shift then
			if pos then
				networkRef.injectGround(ccId, pos, true, plant)
				spawnGhost(pos, label, plant)
				refreshReadout()
			end
			return
		end

		-- A plain pick is the whole plan now, exactly as the server reads it: the
		-- queued run is off, so its marks come down with it.
		stopAiming()
		if pos then
			clearGhosts()
			networkRef.injectGround(ccId, pos, false, plant)
		end
	end)
end

-- Enter targeting for `ccId`. Pressing INJECT again while aiming calls it off.
function MotherInject.begin(ccId: string)
	if aimingCCId == ccId then stopAiming(); return end
	stopAiming()

	aimingCCId = ccId
	marker     = buildMarker()
	if onAimChanged then onAimChanged(true) end

	local wasBlocked = blockedTarget()
	local wasCdShown = -1
	renderConn = RunService.RenderStepped:Connect(function()
		local disc, core = markerDisc, markerCore
		if not (disc and core) then return end
		local ground = cameraRef.getGroundPosition()
		if not ground then return end

		local now = os.clock()
		if now - lastHoverScan >= HOVER_PERIOD then
			lastHoverScan = now
			scanHover(ground)
		end

		-- Over one of her plants the sight leaves the cursor and sits on the plant, so
		-- what the click will take is never in doubt.
		local pos = hoverPos or ground

		-- Income can drop out from under a target that was fine a moment ago.
		local blocked = blockedTarget()
		if blocked ~= wasBlocked then
			wasBlocked = blocked
			refreshReadout()
		end

		-- The readout only rebuilds on a change, so tick it whenever the second it is
		-- printing rolls over.
		local cdShown = math.ceil(cooldownLeft())
		if cdShown ~= wasCdShown then
			wasCdShown = cdShown
			refreshReadout()
		end
		local col = blocked and BLOCK_COL or MARK_COL

		local pulse = 0.5 + 0.5 * math.sin(now * 6)
		disc.CFrame        = CFrame.new(pos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		disc.Transparency  = 0.45 + 0.25 * pulse
		disc.Color         = col
		core.CFrame        = CFrame.new(pos + Vector3.new(0, 7, 0))
		core.Transparency  = 0.35 + 0.35 * pulse
		core.Color         = col
		if markerLight then markerLight.Color = col end
	end)
end

-- Drop the whole queued run and its marks. init.client calls this on the orders that
-- wipe the queue server-side (a hand-issued move) and when the Mother herself is gone.
function MotherInject.clearQueue()
	clearGhosts()
	refreshReadout()
end

function MotherInject.cancel()
	stopAiming()
	clearGhosts()
end

function MotherInject.isAiming(): boolean
	return aimingCCId ~= nil or (os.clock() - endedAt) < CLICK_GRACE
end

return MotherInject
