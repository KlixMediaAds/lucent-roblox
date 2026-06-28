--!strict
--[[
    DeployerPanel — command-card menu for the Bonfire (internal building type "Deployer").

    Selecting a Bonfire opens a grid: pick which unit type it summons (sends
    SetDeployerType), plus an EMPOWER upgrade slot that raises capacity and shortens the
    summon interval for a scaling price (sends UpgradeDeployer). The bonfire free-summons
    its chosen unit up to its (upgradeable) capacity.

    World display (matches Signal Flare method):
      • BillboardGui on the bonfire base  — slim progress bar (summon countdown).
      • ScreenGui overlay entry per bonfire — ViewportFrame unit preview icon,
        repositioned each frame via WorldToViewportPoint (same as FlareIconOverlay).
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local DeployerPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C
local OWNER         = "deployer"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeDeployerId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?
local resourcesFn:      (() -> number)?
local getMultiIdsFn:    (() -> { string })?

-- Per-bonfire Empower state, fed by DeployerUpdate (level, capacity, next upgrade cost).
local deployerLevels:    { [string]: number } = {}
local deployerCaps:      { [string]: number } = {}
local deployerNextCosts: { [string]: number } = {}
local UPGRADE_COLOR = Color3.fromRGB(232, 196, 120)  -- gold (matches other upgrade buttons)

-- ── Unit definitions ──────────────────────────────────────────────────────────
local PURPLE       = Color3.fromRGB(160,  80, 230)
local MEDIC_TEAL   = Color3.fromRGB( 50, 200, 160)
local HOWITZER_OLV = Color3.fromRGB(138, 168,  52)
local FOAM_BLUE    = Color3.fromRGB(160, 220, 255)

type UnitDef = { key: string, label: string, icon: string, color: Color3, angle: number }

local UNIT_DEFS: { UnitDef } = {
	{ key = "Soldier",  label = "Soldier",  icon = "⚔",  color = C.GREEN,      angle = -135 },
	{ key = "Tank",     label = "Tank",      icon = "⬡",  color = C.BARRACKS,   angle = -90  },
	{ key = "Howitzer", label = "Howitzer",  icon = "💣", color = HOWITZER_OLV, angle = -45  },
	{ key = "Elite",    label = "Elite",     icon = "★",  color = PURPLE,       angle = 0    },
	{ key = "Medic",    label = "Medic",     icon = "✚",  color = MEDIC_TEAL,   angle = 45   },
	{ key = "Foamer",   label = "Foamer",    icon = "🫧", color = FOAM_BLUE,    angle = 90   },
}

local UNIT_COLOR: { [string]: Color3 } = {
	Soldier  = C.GREEN,
	Tank     = C.BARRACKS,
	Howitzer = HOWITZER_OLV,
	Elite    = PURPLE,
	Medic    = MEDIC_TEAL,
	Foamer   = FOAM_BLUE,
}

-- ── Research gate per unit key ──────────────────────────────────────────────────
local RESEARCH_GATE: { [string]: string } = { Elite = "EliteUnits", Medic = "MedicUnit" }

-- ── World display (Signal Flare method) ───────────────────────────────────────
-- Each deployer gets:
--   • A BillboardGui on its base: slim progress bar (spawn timer 0→1).
--   • A ScreenGui overlay entry: ViewportFrame unit preview, repositioned each
--     frame to sit directly above the progress bar.

local overlaySg: ScreenGui

type DeployerEntry = { anchor: BasePart, frame: Frame }
local deployerEntries:      { [string]: DeployerEntry } = {}
local deployerBillboards:   { [string]: BillboardGui  } = {}
local deployerCurrentTypes: { [string]: string        } = {}

local function getDeployerBase(deployerId: string): BasePart?
	local bf    = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(deployerId)
	return model and model:FindFirstChild("Base") :: BasePart?
end

-- All currently-selected buildings that are actually bonfires (so the Empower button
-- and its cost/level readout reflect the whole multi-selection, not just the active one).
local function selectedBonfireIds(): { string }
	local sel  = (getMultiIdsFn and getMultiIdsFn()) or {}
	local bf   = workspace:FindFirstChild("Buildings") :: Folder?
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, id in sel do
		if seen[id] then continue end
		local m  = bf and bf:FindFirstChild(id)
		local bt = m and m:FindFirstChild("BuildingType") :: StringValue?
		if bt and bt.Value == "Deployer" then
			seen[id] = true
			table.insert(out, id)
		end
	end
	if #out == 0 and activeDeployerId then table.insert(out, activeDeployerId) end
	return out
end

-- ── Empower animation ─────────────────────────────────────────────────────────
-- A short violet flare when a bonfire is Empowered: a ground shock-ring expands out,
-- a column of fire flashes up, and a few embers spit skyward. World parts (parented to
-- workspace, self-destructing) so model rescale / destruction can't strand them.
local FX_PURPLE = Color3.fromRGB(185, 105, 255)

local function playUpgradeFX(deployerId: string)
	local base = getDeployerBase(deployerId)
	if not base then return end
	local origin   = base.Position
	local groundY  = origin.Y - base.Size.Y / 2 + 0.3

	local function neon(size: Vector3, cf: CFrame, shape: Enum.PartType?): Part
		local p      = Instance.new("Part")
		if shape then (p :: any).Shape = shape end
		p.Size       = size
		p.CFrame     = cf
		p.Color      = FX_PURPLE
		p.Material   = Enum.Material.Neon
		p.Anchored   = true
		p.CanCollide = false
		p.CanQuery   = false
		p.CastShadow = false
		p.Parent     = workspace
		return p
	end
	local function tweenOut(p: Part, info: TweenInfo, goal: { [string]: any })
		local tw = TweenService:Create(p, info, goal)
		tw:Play()
		tw.Completed:Once(function() p:Destroy() end)
	end

	-- Ground shock-ring (flat disc rolled flat) expanding outward
	local ring = neon(Vector3.new(0.4, 3, 3),
		CFrame.new(origin.X, groundY, origin.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.PartType.Cylinder)
	ring.Transparency = 0.1
	tweenOut(ring, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, 18, 18), Transparency = 1 })

	-- Vertical fire flash column
	local col = neon(Vector3.new(4, 2.4, 2.4),
		CFrame.new(origin.X, groundY + 2, origin.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.PartType.Cylinder)
	col.Transparency = 0.15
	tweenOut(col, TweenInfo.new(0.55, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Size = Vector3.new(15, 0.5, 0.5), Transparency = 1,
		  CFrame = CFrame.new(origin.X, groundY + 8, origin.Z) * CFrame.Angles(0, 0, math.pi / 2) })

	-- A halo glow that blooms and dies
	local glow      = Instance.new("PointLight")
	glow.Color      = FX_PURPLE
	glow.Brightness  = 7
	glow.Range      = 26
	glow.Parent     = col

	-- Skyward embers
	for i = 1, 6 do
		local a   = (i / 6) * math.pi * 2
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local e   = neon(Vector3.new(0.5, 0.5, 0.5),
			CFrame.new(origin.X, groundY + 1.5, origin.Z), Enum.PartType.Ball)
		e.Transparency = 0.2
		tweenOut(e, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.new(origin + out * 4 + Vector3.new(0, 7 + i, 0)),
			  Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1 })
	end
end

local function destroyDeployerDisplay(deployerId: string)
	local bb = deployerBillboards[deployerId]
	if bb and bb.Parent then bb:Destroy() end
	deployerBillboards[deployerId] = nil

	local entry = deployerEntries[deployerId]
	if entry then
		if entry.frame and entry.frame.Parent then entry.frame:Destroy() end
		deployerEntries[deployerId] = nil
	end
	deployerCurrentTypes[deployerId] = nil
	deployerLevels[deployerId]       = nil
	deployerCaps[deployerId]         = nil
	deployerNextCosts[deployerId]    = nil
end

local function ensureDisplay(deployerId: string, unitType: string)
	local base = getDeployerBase(deployerId)
	if not base then destroyDeployerDisplay(deployerId); return end

	-- BillboardGui: matches signal-flare layout (44 wide × 52 tall, unit icon slot + progress bar)
	local bb = deployerBillboards[deployerId]
	if not bb or not bb.Parent then
		bb              = Instance.new("BillboardGui")
		bb.Name         = "DeployerDisplay"
		bb.Size         = UDim2.fromOffset(44, 52)
		bb.StudsOffset  = Vector3.new(0, base.Size.Y / 2 + 5, 0)
		bb.AlwaysOnTop  = false
		bb.MaxDistance  = 350
		bb.LightInfluence = 0
		bb.Parent       = base
		deployerBillboards[deployerId] = bb

		-- Slim progress bar at the bottom (y = 46, matching signal flare position)
		local track                    = Instance.new("Frame")
		track.Name                     = "ProgTrack"
		track.Size                     = UDim2.new(1, 0, 0, 3)
		track.Position                 = UDim2.fromOffset(0, 46)
		track.BackgroundColor3         = Color3.fromRGB(20, 22, 28)
		track.BackgroundTransparency   = 0.3
		track.BorderSizePixel          = 0
		track.Parent                   = bb
		local ptc = Instance.new("UICorner"); ptc.CornerRadius = UDim.new(1, 0); ptc.Parent = track
		local pts = Instance.new("UIStroke"); pts.Color = Color3.fromRGB(0, 0, 0); pts.Thickness = 1; pts.Transparency = 0.35; pts.Parent = track

		local fill                 = Instance.new("Frame")
		fill.Name                  = "Fill"
		fill.Size                  = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3      = C.DEPLOYER
		fill.BorderSizePixel       = 0
		fill.Parent                = track
		local pfc = Instance.new("UICorner"); pfc.CornerRadius = UDim.new(1, 0); pfc.Parent = fill

		base.Destroying:Connect(function() destroyDeployerDisplay(deployerId) end)
	end

	-- ScreenGui overlay entry: rebuild when unit type changes
	if deployerCurrentTypes[deployerId] ~= unitType then
		local old = deployerEntries[deployerId]
		if old then
			if old.frame and old.frame.Parent then old.frame:Destroy() end
			deployerEntries[deployerId] = nil
		end
		deployerCurrentTypes[deployerId] = unitType

		local frame                  = Instance.new("Frame")
		frame.Size                   = UDim2.fromOffset(44, 44)
		frame.AnchorPoint            = Vector2.new(0.5, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel        = 0
		frame.ZIndex                 = 15
		frame.Visible                = false
		frame.Parent                 = overlaySg

		local vp = ViewportPreview.forUnit(unitType, Vector2.new(38, 38))
		vp.Position = UDim2.fromOffset(3, 3)
		vp.Parent   = frame

		deployerEntries[deployerId] = { anchor = base, frame = frame }
	end
end

local function updateWorldDisplay(deployerId: string, unitType: string, progress: number)
	ensureDisplay(deployerId, unitType)

	local bb = deployerBillboards[deployerId]
	if bb then
		local track = bb:FindFirstChild("ProgTrack") :: Frame?
		if track then
			local fill = track:FindFirstChild("Fill") :: Frame?
			if fill then
				fill.Size             = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
				fill.BackgroundColor3 = UNIT_COLOR[unitType] or C.DEPLOYER
			end
		end
	end
end

-- ── Command-card page ───────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local current = activeDeployerId and deployerCurrentTypes[activeDeployerId] or "Soldier"
	local slots: { CommandCard.Slot } = {}
	for i, def in UNIT_DEFS do
		local key    = def.key
		local gate   = RESEARCH_GATE[key]
		local locked = gate ~= nil and not (hasResearchFn and hasResearchFn(gate))
		table.insert(slots, {
			index           = i,
			name            = key:upper(),
			color           = def.color,
			locked          = locked,
			icon            = def.icon,
			viewportKey     = "unit:" .. key,
			viewportFactory = function() return ViewportPreview.forUnit(key, Vector2.new(64, 64)) end,
			badge           = (key == current) and "✓" or nil,
			desc            = locked and "Locked — research required" or ("Summon " .. key),
			onClick         = function()
				if locked then return end
				-- Apply to the whole bonfire multi-selection.
				for _, id in selectedBonfireIds() do
					networkRef.setDeployerType(id, key)
				end
				if CommandCard.isOwner(OWNER) then CommandCard.update(OWNER, buildPage()) end
			end,
		})
	end

	-- ── Empower upgrade slot (+capacity, faster summon; scaling price) ──────────
	-- Reflects the whole bonfire multi-selection: targets the LOWEST level present, so a
	-- press evens the group out (stragglers catch up to the rest before any go higher).
	local ids = selectedBonfireIds()
	local minLevel = math.huge
	for _, id in ids do
		local lvl = deployerLevels[id] or 0
		if lvl < minLevel then minLevel = lvl end
	end
	if minLevel == math.huge then minLevel = 0 end
	local atMin = 0
	for _, id in ids do
		if (deployerLevels[id] or 0) == minLevel then atMin += 1 end
	end

	local maxed   = minLevel >= Config.DEPLOYER_UPGRADE_MAX_LEVEL
	local perCost = Config.bonfireUpgradeCost(minLevel)
	local cap     = Config.bonfireCapacity(minLevel)
	local res     = resourcesFn and resourcesFn() or 0
	local multi   = atMin > 1
	local desc
	if maxed then
		desc = "Max power — capacity " .. cap
	elseif multi then
		desc = "Empower " .. atMin .. " bonfires (Lv " .. minLevel .. ") · " .. perCost .. " each"
	else
		desc = "Capacity " .. cap .. " → " .. (cap + Config.DEPLOYER_UPGRADE_CAP_STEP) .. ", faster summons"
	end
	table.insert(slots, {
		index           = #UNIT_DEFS + 1,
		name            = "EMPOWER",
		color           = UPGRADE_COLOR,
		cost            = (not maxed) and perCost or nil,
		enabled         = (not maxed) and res >= perCost,
		locked          = maxed,
		icon            = "✦",
		viewportKey     = "bonfire:empower",
		viewportFactory = function() return ViewportPreview.forBonfireUpgrade(Vector2.new(64, 64)) end,
		badge           = multi and ("×" .. atMin) or nil,
		desc            = desc,
		onClick         = function()
			if maxed then return end
			local sel = selectedBonfireIds()
			if #sel > 0 then networkRef.upgradeDeployer(sel) end
		end,
	})

	return { header = "BONFIRE", slots = slots }
end

local function renderIfActive()
	if activeDeployerId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function DeployerPanel.init(network, hasResearch, getResources, getMultiIds)
	networkRef    = network
	hasResearchFn = hasResearch
	resourcesFn   = getResources
	getMultiIdsFn = getMultiIds

	-- ScreenGui overlay for per-deployer unit viewport icons
	overlaySg                  = Instance.new("ScreenGui")
	overlaySg.Name             = "DeployerIconOverlay"
	overlaySg.IgnoreGuiInset   = true
	overlaySg.ResetOnSpawn     = false
	overlaySg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	overlaySg.Parent           = localPlayer.PlayerGui

	-- Reposition icons every frame (same technique as FlareIconOverlay in init.client)
	RunService:BindToRenderStep("DeployerIconPositions", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = workspace.CurrentCamera
		for _, entry in deployerEntries do
			if not entry.anchor.Parent then
				entry.frame.Visible = false
				continue
			end
			-- Billboard StudsOffset is (0, base.SizeY/2 + 5, 0); project that world point
			local worldPt = entry.anchor.Position
				+ Vector3.new(0, entry.anchor.Size.Y / 2 + 5, 0)
			local sv, onScreen = cam:WorldToViewportPoint(worldPt)
			if onScreen and sv.Z > 0 then
				entry.frame.Visible  = true
				-- AnchorPoint (0.5, 1): bottom-center of the 44px icon sits at +8px below billboard center,
				-- matching the FlareIconOverlay positioning.
				entry.frame.Position = UDim2.fromOffset(math.floor(sv.X), math.floor(sv.Y + 8))
			else
				entry.frame.Visible = false
			end
		end
	end)

	-- Listen for server updates → drive world display + Empower state
	network.onDeployerUpdate(function(deployerId: string, unitType: string, progress: number, level: number?, capacity: number?, nextCost: number?, justUpgraded: boolean?)
		if level    ~= nil then deployerLevels[deployerId]    = level    end
		if capacity ~= nil then deployerCaps[deployerId]      = capacity end
		if nextCost ~= nil then deployerNextCosts[deployerId] = nextCost end
		if justUpgraded then playUpgradeFX(deployerId) end
		updateWorldDisplay(deployerId, unitType, progress)
		if deployerId == activeDeployerId or (getMultiIdsFn and table.find(getMultiIdsFn(), deployerId)) then
			renderIfActive()
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function DeployerPanel.show(deployerId: string)
	activeDeployerId = deployerId
	CommandCard.show(OWNER, buildPage())
end

function DeployerPanel.hide()
	activeDeployerId = nil
	CommandCard.hide(OWNER)
end

function DeployerPanel.refreshIfVisible()
	renderIfActive()
end

function DeployerPanel.isVisible(): boolean
	return activeDeployerId ~= nil and CommandCard.isOwner(OWNER)
end

return DeployerPanel
