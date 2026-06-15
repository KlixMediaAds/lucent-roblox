--!strict
--[[
    DeployerPanel — Radial identity selector for Deployer buildings.

    Clicking a Deployer opens a radial menu identical in style to BarracksPanel.
    Selecting a unit type sends SetDeployerType to the server; the deployer will
    free-spawn that unit every DEPLOYER_SPAWN_INTERVAL seconds.

    World display (matches Signal Flare method):
      • BillboardGui on the deployer base  — slim progress bar (spawn countdown).
      • ScreenGui overlay entry per deployer — ViewportFrame unit preview icon,
        repositioned each frame via WorldToViewportPoint (same as FlareIconOverlay).
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local DeployerPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeDeployerId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?

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

-- ── Radial overlay ────────────────────────────────────────────────────────────
local RADIUS   = 155
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)

type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	stroke:   UIStroke,
	label:    TextLabel,
	key:      string,
	finalPos: UDim2,
	startPos: UDim2,
}
local childNodes: { ChildNode } = {}
local overlay:    Frame?
local rootLbl:    TextLabel?

local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNodes()
	for _, c in childNodes do
		c.wrapper.Visible             = true
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
	end
end

local function collapseNodes(then_: (() -> ())?)
	for _, c in childNodes do
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in childNodes do c.wrapper.Visible = false end
		if then_ then then_() end
	end)
end

local function refreshResearchNodes()
	for _, c in childNodes do
		if c.key == "Elite" then
			local unlocked = hasResearchFn and hasResearchFn("EliteUnits") or false
			if unlocked then
				c.btn.BackgroundColor3       = PURPLE
				c.btn.BackgroundTransparency = 0.35
				c.stroke.Color               = PURPLE
				c.stroke.Thickness           = 2
				c.label.TextColor3           = C.TEXT
			else
				c.btn.BackgroundColor3       = C.BG_LOCKED
				c.btn.BackgroundTransparency = 0.3
				c.stroke.Color               = C.BORDER_LO
				c.stroke.Thickness           = 1.5
				c.label.Text                 = "Elite\nLocked"
				c.label.TextColor3           = C.DIM
			end
		elseif c.key == "Medic" then
			local unlocked = hasResearchFn and hasResearchFn("MedicUnit") or false
			if unlocked then
				c.btn.BackgroundColor3       = MEDIC_TEAL
				c.btn.BackgroundTransparency = 0.35
				c.stroke.Color               = MEDIC_TEAL
				c.stroke.Thickness           = 2
				c.label.TextColor3           = C.TEXT
			else
				c.btn.BackgroundColor3       = C.BG_LOCKED
				c.btn.BackgroundTransparency = 0.3
				c.stroke.Color               = C.BORDER_LO
				c.stroke.Thickness           = 1.5
				c.label.Text                 = "Medic\nLocked"
				c.label.TextColor3           = C.DIM
			end
		end
	end
end

local function updateRootLabel(unitType: string)
	if not rootLbl then return end
	rootLbl.Text = "DEPLOYER\n" .. unitType
end

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
		track.Size                     = UDim2.new(1, 0, 0, 5)
		track.Position                 = UDim2.fromOffset(0, 46)
		track.BackgroundColor3         = Color3.fromRGB(20, 22, 28)
		track.BackgroundTransparency   = 0.3
		track.BorderSizePixel          = 0
		track.Parent                   = bb
		local ptc = Instance.new("UICorner"); ptc.CornerRadius = UDim.new(1, 0); ptc.Parent = track

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

-- ── Init ──────────────────────────────────────────────────────────────────────
function DeployerPanel.init(network, hasResearch)
	networkRef    = network
	hasResearchFn = hasResearch

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

	-- Build the radial overlay on RTSHUD
	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local ov                         = Instance.new("Frame")
	ov.Name                          = "DeployerOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	local rootWrapper, rBtn = UILib.radialNode(ov, "DEPLOYER", "🚀", C.DEPLOYER, ROOT_POS, 70, 11)
	rootLbl = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?

	rBtn.MouseButton1Click:Connect(function() DeployerPanel.hide() end)

	for _, def in UNIT_DEFS do
		local rad      = math.rad(def.angle)
		local dx       = math.cos(rad) * RADIUS
		local dy       = math.sin(rad) * RADIUS
		local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx,
		                           ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

		local line         = UILib.connectorLine(ov, ROOT_POS, def.angle, RADIUS, 10)
		local wrapper, btn = UILib.radialNode(ov, def.label, def.icon, def.color, ROOT_POS, 70, 11)
		wrapper.Visible    = false

		UILib.setNodeViewport(btn, ViewportPreview.forUnit(def.key, Vector2.new(70, 70)))

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel")    :: TextLabel

		local key = def.key
		btn.MouseButton1Click:Connect(function()
			if not activeDeployerId then return end
			if key == "Elite" and not (hasResearchFn and hasResearchFn("EliteUnits")) then return end
			if key == "Medic" and not (hasResearchFn and hasResearchFn("MedicUnit"))  then return end
			networkRef.setDeployerType(activeDeployerId, key)
			updateRootLabel(key)
			DeployerPanel.hide()
		end)

		table.insert(childNodes, {
			wrapper  = wrapper,
			btn      = btn,
			line     = line,
			stroke   = stroke,
			label    = label,
			key      = key,
			finalPos = finalPos,
			startPos = ROOT_POS,
		})
	end

	-- Listen for server updates → drive world display
	network.onDeployerUpdate(function(deployerId: string, unitType: string, progress: number)
		updateWorldDisplay(deployerId, unitType, progress)
		if deployerId == activeDeployerId then
			updateRootLabel(unitType)
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function DeployerPanel.show(deployerId: string)
	activeDeployerId = deployerId
	if overlay then overlay.Visible = true end
	refreshResearchNodes()
	expandNodes()
	local currentType = deployerCurrentTypes[deployerId] or "Soldier"
	updateRootLabel(currentType)
end

function DeployerPanel.hide()
	activeDeployerId = nil
	if rootLbl then rootLbl.Text = "DEPLOYER" end
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function DeployerPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refreshResearchNodes() end
end

function DeployerPanel.isVisible(): boolean
	return overlay ~= nil and (overlay :: Frame).Visible
end

return DeployerPanel
