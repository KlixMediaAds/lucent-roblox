--!strict
--[[
    MotherInject: ground-targeting mode for the Hollowed Mother's INJECT action.

    Pressing INJECT on the Mother's command card (or [R]) calls begin(): a purple
    hologram sight follows the cursor across the terrain, naming what sits under it,
    until the player left-clicks, which sends the point to the server
    (Network.injectGround). Right-click or [Esc] calls it off.

    The sight reads what is under it. Bare ground is one target; so is any plant of her
    own she has already grown, which snaps the sight onto it and names what injecting it
    would give up (InjectPlants.INJECT). So is any egg nest of her own: a spike into one
    of those takes the nest up a size, and the sight names the size it would leave the nest
    at ("Medium Nest", then "Large Nest") until it is fully grown.
    Plants with nothing to give yet read "coming soon" and refuse the click, as does a
    nest that has nowhere left to grow and any target she cannot pay for.

    Whatever it is over, the payout gets its own lime plate that snaps open each time it
    changes -- purple-on-purple over dark ground was the one thing here you could not read.

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
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe = require(Shared:WaitForChild("PerfProbe"))
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
-- the Mother's own plants or egg nests, snapped to and named. Refreshed on a timer while
-- aiming.
local hoverTarget: Model? = nil
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
type Ghost = { model: Model, tag: TextLabel, label: string, target: Model? }
local ghosts: { Ghost } = {}

-- Plants and nests already spoken for by a queued mark. Injecting a plant twice would
-- walk her over to a wound that is no longer there, and stacking swellings on one nest
-- reads as a mistake far more often than it reads as a plan, so the sight refuses both.
local queuedTargets: { [Model]: boolean } = {}

-- What the sight says about a nest it is over, shaped like an InjectPlants entry so the
-- readout, the block rule and the tile's 3D face all treat it exactly as they treat a
-- plant: no `kind` means the click is refused. Injecting a nest takes it up a size
-- (BuildingManager.swellEggNest), until it is fully grown.
--
-- A nest is named by SIZE, and the name the sight shows is the size the spike would leave
-- it at -- point at a fresh Small nest and it reads "Medium Nest", because that is what you
-- are about to make. A nest that has gone as far as it goes is named for what it already
-- is. The yield line says what the tier actually buys: a second egg on the way to Medium,
-- and the prime egg (with the heavy creatures behind it) on the way to Large.
local NEST_TIERS  = { "Small Nest", "Medium Nest", "Large Nest" }
local NEST_YIELDS = { "+1 EGG", "PRIME EGG" }   -- indexed by the tier being left behind

local function nestInfo(tier: number): InjectPlants.InjectInfo
	local top = Config.MOTHER_INJECT_NEST_TIERS
	if tier >= top then
		return { label = NEST_TIERS[math.min(tier, #NEST_TIERS)] or "Egg Nest",
			yield = "FULLY GROWN", kind = nil, preview = "nest" }
	end
	return { label = NEST_TIERS[math.min(tier + 1, #NEST_TIERS)] or "Egg Nest",
		yield = NEST_YIELDS[tier] or "+1 EGG", kind = "swell", preview = "nest" }
end

local MARK_COL  = Color3.fromRGB(196, 90, 255)
local TEXT_COL  = Color3.fromRGB(236, 214, 255)
local BLOCK_COL = Color3.fromRGB(200, 62, 72)   -- target she cannot take: refuses the click
local WAIT_COL  = Color3.fromRGB(150, 196, 255)  -- inject still recharging: allowed, but it waits
-- What she GETS out of the target. Deliberately not the purple everything else on this
-- sight is drawn in: the yield is the one line the player is actually reading, and purple
-- text on a purple hologram over dark ground was the hardest thing here to make out.
local YIELD_COL = Color3.fromRGB(150, 255, 60)   -- lime: the payout line, and only that

-- What the sight says it is about to inject. Only the ground is injectable for now, so
-- this is fixed; once she can inject other things it becomes a lookup on whatever the
-- cursor is over.
local TARGET_NAME = "Ground"

-- ── Marker ────────────────────────────────────────────────────────────────────
-- The floating readout above the sight: a name plate for what is being injected, and a
-- lime plate under it for what injecting it pays out (or why it will not be taken).
-- Returns both labels.
local function buildReadout(parent: BasePart): (TextLabel, TextLabel)
	local bb          = Instance.new("BillboardGui")
	bb.Name           = "InjectReadout"
	-- Wide enough for the longest line either plate can hold (the frond's
	-- "+15 MAX ENERGY, +0.3 REGEN"), since neither wraps and a clipped payout is worse
	-- than a slightly roomy plate.
	bb.Size           = UDim2.fromOffset(238, 48)
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

	-- The yield line gets a plate of its own rather than floating bare over the terrain.
	-- It is the line that says what she is about to be paid, and bare text lost against
	-- lit ground, fog and her own hologram. Dark plate, hard stroke, and it grows from the
	-- middle each time it changes (see revealSub) so a new number announces itself.
	local subCard                  = Instance.new("Frame")
	subCard.Name                   = "YieldPlate"
	subCard.AnchorPoint            = Vector2.new(0.5, 0)
	subCard.Position               = UDim2.new(0.5, 0, 0, 25)
	subCard.Size                   = UDim2.new(1, 0, 0, 19)
	subCard.BackgroundColor3       = Color3.fromRGB(6, 10, 4)
	subCard.BackgroundTransparency = 0.25
	subCard.BorderSizePixel        = 0
	subCard.Parent                 = bb
	Instance.new("UICorner", subCard).CornerRadius = UDim.new(0, 4)

	local subStroke        = Instance.new("UIStroke")
	subStroke.Name         = "Edge"
	subStroke.Color        = YIELD_COL
	subStroke.Thickness    = 1
	subStroke.Transparency = 0.2
	subStroke.Parent       = subCard

	local sub                   = Instance.new("TextLabel")
	sub.Name                    = "Yield"
	sub.Size                    = UDim2.new(1, 0, 1, 0)
	sub.BackgroundTransparency  = 1
	sub.Font                    = Enum.Font.GothamBold
	sub.TextSize                = 13
	sub.TextColor3              = YIELD_COL
	sub.TextStrokeTransparency  = 0
	sub.TextStrokeColor3        = Color3.new(0, 0, 0)
	sub.Text                    = ""
	sub.Parent                  = subCard

	return name, sub
end

-- ── The reveal ────────────────────────────────────────────────────────────────
-- Played whenever the yield line changes to something new: the plate snaps open from the
-- middle while the text fades up through it. Short on purpose -- the sight is dragged
-- across a lot of ground and a slow flourish would be in the way within seconds.
local REVEAL_TIME = 0.16
local revealTween: Tween? = nil

local function revealSub()
	local sub = markerSub
	if not sub then return end
	local plate  = sub.Parent :: Frame
	local stroke = plate:FindFirstChild("Edge") :: UIStroke?
	if revealTween then revealTween:Cancel() end

	plate.Size                   = UDim2.new(0.55, 0, 0, 19)
	plate.BackgroundTransparency = 1
	sub.TextTransparency         = 1
	sub.TextStrokeTransparency   = 1
	if stroke then stroke.Transparency = 1 end

	local info = TweenInfo.new(REVEAL_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	revealTween = TweenService:Create(plate, info, {
		Size = UDim2.new(1, 0, 0, 19), BackgroundTransparency = 0.25,
	})
	revealTween:Play()
	TweenService:Create(sub, TweenInfo.new(REVEAL_TIME * 0.7), {
		TextTransparency = 0, TextStrokeTransparency = 0,
	}):Play()
	if stroke then
		TweenService:Create(stroke, TweenInfo.new(REVEAL_TIME), { Transparency = 0.2 }):Play()
	end
end

-- Seconds until she can inject again, off the timestamp the server stamps on her
-- base. Injecting is free, so this is the pacing the player actually feels: the sight
-- reports it, but does not refuse the click -- a spot laid onto a run already under way is
-- accepted, and the server is the one that decides.
local function cooldownLeft(): number
	local base = ccBaseFn and ccBaseFn()
	local v    = base and base:GetAttribute("InjectReadyAt")
	if type(v) ~= "number" then return 0 end
	return math.max(0, v - workspace:GetServerTimeNow())
end

-- Her energy pool, as the server last published it. Before the first tick lands the
-- opening pool is the honest answer.
local function energy(): number
	local base = ccBaseFn and ccBaseFn()
	local v    = base and base:GetAttribute("MotherEnergy")
	return type(v) == "number" and v or Config.MOTHER_ENERGY_START
end

-- Can she pay for one more wound? The server charges per injection, queued ones included,
-- so a target she cannot afford is refused here rather than silently dropped there. The
-- price is her energy; the resource cost is kept in the test because it is configurable
-- and has been non-zero before.
local function canAfford(): boolean
	if energy() < Config.MOTHER_INJECT_ENERGY then return false end
	local cost = Config.MOTHER_INJECT_COST
	if cost <= 0 then return true end
	return (resourcesFn and resourcesFn() or 0) >= cost
end

-- A target the sight will not take: a plant with nothing to give yet, a nest that is
-- already fully grown, one already queued, or a target she cannot pay for. The sight turns
-- on it rather than letting the click go nowhere.
local function blockedTarget(): boolean
	if hoverInfo and not hoverInfo.kind then return true end
	if hoverTarget and queuedTargets[hoverTarget] then return true end
	if groundCrowded then return true end
	return not canAfford()
end

-- Name plate + yield line, both driven by whatever the sight is currently over. The yield
-- line only replays its reveal when it actually says something NEW: the cooldown counts
-- itself down through here once a second, and re-popping the plate on every tick would
-- turn a flourish into a flicker.
local function refreshReadout()
	local nameLbl, sub = markerName, markerSub
	if not (nameLbl and sub) then return end

	nameLbl.Text = hoverInfo and hoverInfo.label or TARGET_NAME

	local was = sub.Text
	if energy() < Config.MOTHER_INJECT_ENERGY then
		sub.Text       = "NEED " .. Config.MOTHER_INJECT_ENERGY .. " ENERGY"
		sub.TextColor3 = BLOCK_COL
	elseif not canAfford() then
		sub.Text       = "NEED " .. Config.MOTHER_INJECT_COST .. " RESOURCES"
		sub.TextColor3 = BLOCK_COL
	elseif hoverTarget and queuedTargets[hoverTarget] then
		sub.Text       = "ALREADY QUEUED"
		sub.TextColor3  = BLOCK_COL
	elseif groundCrowded then
		sub.Text       = "GROUND TOO CROWDED"
		sub.TextColor3 = BLOCK_COL
	elseif hoverInfo then
		-- The payout. Lime, and the only thing on this sight wearing it.
		sub.Text       = hoverInfo.yield
		sub.TextColor3 = hoverInfo.kind and YIELD_COL or BLOCK_COL
	else
		local cd = cooldownLeft()
		if cd > 0 then
			-- She is between wounds: the spot can still be laid down, it just waits its turn.
			sub.Text       = "INJECT READY IN " .. math.ceil(cd) .. "s"
			sub.TextColor3 = WAIT_COL
		else
			local n        = #ghosts
			sub.Text       = n > 0 and ("+" .. n .. " QUEUED") or "[SHIFT] TO QUEUE"
			sub.TextColor3 = MARK_COL
		end
	end

	-- The plate wears the line's own colour, so a refusal reads red and a payout lime
	-- without the player having to read the words to know which it is.
	local plate  = sub.Parent :: Frame
	local stroke = plate:FindFirstChild("Edge") :: UIStroke?
	if stroke then stroke.Color = sub.TextColor3 end
	if sub.Text ~= was then revealSub() end
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
	disc.CanTouch     = false
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
	core.CanTouch     = false
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
-- What tier a nest stands at, off the attribute the server stamps on every injection.
local function nestTierOf(clump: Model): number
	return (clump:GetAttribute("NestTier") :: number?) or 1
end

-- Two readings of the same target say the same thing? Nest entries are built per scan
-- rather than being shared constants, so this compares what they SAY, not which table
-- they are.
local function sameInfo(a: InjectPlants.InjectInfo?, b: InjectPlants.InjectInfo?): boolean
	if a == b then return true end
	if not a or not b then return false end
	return a.label == b.label and a.yield == b.yield and a.kind == b.kind
end

-- Her plants are scenery (CanQuery is off), so the cursor cannot hit them directly:
-- the nearest of her own plants to the point under the cursor wins instead, which also
-- gives the sight its snap onto the plant. Her own egg nests are hunted the same way and
-- compete on the same distance, so whichever the cursor is nearer to is what she takes.
local function scanHover(groundPos: Vector3)
	local folder     = workspace:FindFirstChild("InjectPlants")
	local bestTarget: Model? = nil
	local bestIn:     InjectPlants.InjectInfo? = nil
	local bestPos:    Vector3? = nil
	local bestD      = HOVER_RADIUS * HOVER_RADIUS
	local userId     = Players.LocalPlayer.UserId

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

			-- Still buried under its parasite. It claims the ground (the crowding check
			-- above already counted it), but there is nothing standing there to aim at
			-- yet, and its pivot is metres underground.
			local riseAt = child:GetAttribute("RiseAt")
			if type(riseAt) == "number" and workspace:GetServerTimeNow() < riseAt then continue end

			-- Hers, or wild: a plant with no owner grew on its own (WildPlants seeds the
			-- map with them) and is anyone's to take. Someone else's is off limits.
			local owner = child:GetAttribute("OwnerUserId")
			if owner ~= nil and owner ~= userId then continue end
			local info = InjectPlants.injectInfo(child)
			if not info then continue end
			if d < bestD then
				bestD, bestTarget, bestIn, bestPos = d, child, info, p
			end
		end
	end

	-- Her own egg nests, from the clutch folder of the very Mother being aimed with: a
	-- spike into one of those divides it rather than opening ground. Rival nests (and her
	-- other Mothers', if it ever comes to that) are not in this folder at all, so there is
	-- nothing further to check. Unlike plants, a nest does NOT crowd the ground out: it is
	-- a structure standing on soil, not something grown in it.
	local nests  = workspace:FindFirstChild("EggNests")
	local clutch = nests and aimingCCId and nests:FindFirstChild(aimingCCId)
	if clutch then
		for _, clump in clutch:GetChildren() do
			if not clump:IsA("Model") then continue end
			if clump:GetAttribute("NestId") == nil then continue end
			if clump:GetAttribute("EggOwnerId") ~= userId then continue end
			local bowl = clump:FindFirstChild("Bowl") :: BasePart?
			local hit  = clump:FindFirstChild("Hitbox") :: BasePart?
			if not bowl then continue end
			if not hit or not hit.CanQuery then continue end   -- still growing in on its tentacle
			-- The bowl straddles the socket, so its underside IS the ground the nest
			-- stands on, at any size the injections have swollen it to.
			local p  = bowl.Position - Vector3.new(0, bowl.Size.Y * 0.5, 0)
			local dx = p.X - groundPos.X
			local dz = p.Z - groundPos.Z
			local d  = dx * dx + dz * dz
			if d < bestD then
				bestD, bestTarget, bestPos = d, clump, p
				bestIn = nestInfo(nestTierOf(clump))
			end
		end
	end

	-- Only bare ground can be crowded out; aiming at a plant or a nest is a deliberate
	-- target.
	local nowCrowded = crowded and bestTarget == nil
	local changed    = nowCrowded ~= groundCrowded
	groundCrowded    = nowCrowded

	-- Same thing under the sight AND the same thing to say about it. The second half
	-- matters for nests: injecting one takes it up a tier while the cursor never moves,
	-- and the readout has to name the new size rather than the one it just left.
	if bestTarget == hoverTarget and sameInfo(bestIn, hoverInfo) then
		if changed then refreshReadout() end
		return
	end
	hoverTarget, hoverInfo, hoverPos = bestTarget, bestIn, bestPos
	refreshReadout()
	if onHoverChanged then onHoverChanged(bestIn and bestIn.preview or nil) end
end

-- ── Queued ghosts ─────────────────────────────────────────────────────────────
-- A quieter copy of the sight, left standing on a spot the player shift-queued. It
-- carries its place in the run, so the order she walks them in reads at a glance.
local function spawnGhost(pos: Vector3, label: string, target: Model?)
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
	disc.CanTouch     = false
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
	core.CanTouch     = false
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
	table.insert(ghosts, { model = g, tag = tag, label = label, target = target })
	if target then queuedTargets[target] = true end
end

local function renumberGhosts()
	for i, gh in ghosts do
		gh.tag.Text = i .. ". " .. gh.label
	end
end

local function clearGhosts()
	for _, gh in ghosts do gh.model:Destroy() end
	table.clear(ghosts)
	table.clear(queuedTargets)
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
	if lead.target then queuedTargets[lead.target] = nil end
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
	hoverTarget, hoverInfo, hoverPos = nil, nil, nil
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

	PerfProbe.onHeartbeat("MotherInject", function()
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

		-- Nothing here she can take (a "coming soon" plant, a fully grown nest, a target
		-- already queued, or a wound she cannot pay for): the click is spent on nothing
		-- and the sight stays up.
		if blockedTarget() then return end

		local ccId   = aimingCCId :: string
		local target = hoverTarget
		local pos    = hoverPos or cameraRef.getGroundPosition()
		local label  = hoverInfo and hoverInfo.label or TARGET_NAME
		local shift  = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		-- Shift keeps the sight up, so the next spot goes straight onto the queue.
		if shift then
			if pos then
				networkRef.injectGround(ccId, pos, true, target)
				spawnGhost(pos, label, target)
				refreshReadout()
			end
			return
		end

		-- A plain pick is the whole plan now, exactly as the server reads it: the
		-- queued run is off, so its marks come down with it.
		stopAiming()
		if pos then
			clearGhosts()
			networkRef.injectGround(ccId, pos, false, target)
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
	renderConn = PerfProbe.onRender("MotherInject", function()
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
