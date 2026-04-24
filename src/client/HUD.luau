--!strict
--[[
    HUD — Resource bar, selection label, drag-select rect, CC button,
    and the radial build menu (Mine / Barracks / Turret).

    Build menu: circular root node at bottom-left; three child nodes fan
    upward via TweenService when the root is clicked.

    Public API unchanged except HUD.create() now returns (dragFrame, ccBtn).
    HUD.wire() now takes a hidePanelsFn callback instead of individual button refs.
]]

local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

-- ── UI scaling ────────────────────────────────────────────────────────────────
-- All pixel offsets are authored at 1920×1080.  UIScale adjusts them uniformly
-- for any resolution so the layout stays proportional.
local BASE_W = 1920
local BASE_H = 1080

local function setupScaling(sg: ScreenGui)
	local uiScale        = Instance.new("UIScale")
	uiScale.Scale        = 1
	uiScale.Parent       = sg

	local function applyScale()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp  = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		uiScale.Scale = math.max(
			math.min(vp.X / BASE_W, vp.Y / BASE_H),
			0.35  -- floor: never shrink below 35 % (very small / mobile windows)
		)
	end

	applyScale()

	-- Re-apply whenever the camera or its viewport size changes
	local function hookCamera(cam: Camera)
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
		applyScale()
	end

	if workspace.CurrentCamera then
		hookCamera(workspace.CurrentCamera)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then hookCamera(workspace.CurrentCamera) end
	end)
end

local HUD         = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local resLabel:  TextLabel?
local incLabel:  TextLabel?
local selLabel:  TextLabel?

local currentResources = 0
local currentIncome    = 0
local buildMenuOpen    = false
local currentActivePlacing: string? = nil

local playerCounts: { [string]: number } = {}
local hasResearchFn: ((string) -> boolean)?

-- ── Building metadata ─────────────────────────────────────────────────────────
type BuildingInfo = { cost: number, requires: { [string]: number }, researchReq: string? }
local BUILDING_INFO: { [string]: BuildingInfo } = {
	Mine       = { cost = Config.MINE_COST,         requires = {},             researchReq = nil          },
	Barracks   = { cost = Config.BUILDING_COST,     requires = { Mine = 1 },   researchReq = nil          },
	Turret     = { cost = Config.TURRET_COST,       requires = { Barracks = 1 }, researchReq = nil        },
	Relay      = { cost = Config.RELAY_COST,        requires = {},             researchReq = "Relay"      },
	CreepyBlob = { cost = Config.CREEPY_BLOB_COST,  requires = {},             researchReq = "CreepyBlob" },
}

-- Horizontal layout: each child slides right from the root along the bottom bar.
-- Spacing = node diameter (80) + gap (15) = 95 px between centres.
local CHILD_DEFS: { { btype: string, icon: string, color: Color3, desc: string } } = {
	{ btype = "Mine",       icon = "⛏", color = C.MINE,                        desc = "Harvests nearby mineral deposits"              },
	{ btype = "Barracks",   icon = "⚔", color = C.BARRACKS,                    desc = "Trains and deploys combat units"               },
	{ btype = "Turret",     icon = "⚙", color = C.TURRET,                      desc = "Auto-attacks nearby enemies"                   },
	{ btype = "Relay",      icon = "📡", color = C.ACCENT,                      desc = "Extends your build zone"                       },
	{ btype = "CreepyBlob", icon = "🫧", color = Color3.fromRGB(100, 40, 180),  desc = "Evolve into soldiers, a worm burst, or a creepy turret" },
}
local CHILD_SPACING = 95   -- px between child centres

-- ── Horizontal node refs ──────────────────────────────────────────────────────
type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	stroke:   UIStroke,
	label:    TextLabel,
	btype:    string,
	color:    Color3,
	desc:     string,
	finalPos: UDim2,
	startPos: UDim2,
}
local childNodes:    { ChildNode } = {}
local rootBtn:       TextButton?
local rootStroke:    UIStroke?
local buildOverlay:  Frame?
local cancelBtnRef:  TextButton?
local ccBtnInternal: TextButton?
local ccGlowRef:     UIStroke?
local ccScaleRef:    UIScale?
local upgradesBtnRef:     TextButton?
local upgradesStroke:     UIStroke?
local upgradesBtnWrapper: Frame?
local UPGRADES_COLOR = Color3.fromRGB(190, 140, 255)

-- ── Build-menu hover tooltip ──────────────────────────────────────────────────
local tooltipFrame: Frame?
local tooltipTitle: TextLabel?
local tooltipDesc:  TextLabel?
local typewriterToken = 0  -- incremented to cancel an in-flight typewriter

local function startTypewriter(nameStr: string, descStr: string, color: Color3)
	typewriterToken += 1
	local myToken = typewriterToken
	if not (tooltipFrame and tooltipTitle and tooltipDesc) then return end

	tooltipTitle.TextColor3 = color
	tooltipTitle.Text       = ""
	tooltipDesc.Text        = ""
	tooltipFrame.Visible    = true

	task.spawn(function()
		for i = 1, #nameStr do
			if typewriterToken ~= myToken then return end
			tooltipTitle.Text = string.sub(nameStr, 1, i)
			task.wait(0.04)
		end
		if typewriterToken ~= myToken then return end
		task.wait(0.07)
		for i = 1, #descStr do
			if typewriterToken ~= myToken then return end
			tooltipDesc.Text = string.sub(descStr, 1, i)
			task.wait(0.024)
		end
	end)
end

local function hideTooltip()
	typewriterToken += 1
	if tooltipFrame then tooltipFrame.Visible = false end
end

-- ── Requirement helpers ───────────────────────────────────────────────────────

-- Returns false if this building's researchReq hasn't been completed yet.
-- Such nodes are fully hidden from the tray until research is done.
local function isResearchVisible(btype: string): boolean
	local info = BUILDING_INFO[btype]
	if not info or not info.researchReq then return true end
	return hasResearchFn ~= nil and hasResearchFn(info.researchReq)
end

local function isUnlocked(btype: string): boolean
	local info = BUILDING_INFO[btype]
	if not info then return true end
	for req, count in info.requires do
		if (playerCounts[req] or 0) < count then return false end
	end
	return true
end

-- ── Resource display ──────────────────────────────────────────────────────────
local function refreshResDisplay()
	if resLabel then resLabel.Text = tostring(currentResources) end
	if incLabel then
		if currentIncome > 0 then
			incLabel.Text       = string.format("+%.0f/min", currentIncome)
			incLabel.TextColor3 = C.GREEN
		else
			incLabel.Text = ""
		end
	end
end

-- ── Build node visual state ───────────────────────────────────────────────────
local function applyNodeState(node: ChildNode)
	-- Hide completely if gated behind unfinished research
	if not isResearchVisible(node.btype) then
		node.wrapper.Visible = false
		return
	end

	-- If the menu is open and this node just became research-visible, show it
	if buildMenuOpen and not node.wrapper.Visible then
		node.wrapper.Visible = true
		node.wrapper.Position = node.finalPos
	end

	local locked  = not isUnlocked(node.btype)
	local placing = currentActivePlacing == node.btype
	local info    = BUILDING_INFO[node.btype]
	local cost    = info and info.cost or 0

	if placing then
		node.btn.BackgroundColor3     = C.ACCENT
		node.btn.BackgroundTransparency = 0.1
		node.stroke.Color             = C.ACCENT
		node.stroke.Thickness         = 3
		node.label.Text               = node.btype:upper() .. "\nPLACING…"
		node.label.TextColor3         = C.ACCENT
	elseif locked then
		local lockReason = "LOCKED"
		if info then
			for req in info.requires do
				if (playerCounts[req] or 0) < (info.requires[req] or 1) then
					lockReason = "Needs " .. req; break
				end
			end
		end
		node.btn.BackgroundColor3     = C.BG_LOCKED
		node.btn.BackgroundTransparency = 0.4
		node.stroke.Color             = C.BORDER_LO
		node.stroke.Thickness         = 1.5
		node.label.Text               = node.btype:upper() .. "\n" .. lockReason
		node.label.TextColor3         = C.DIM
	else
		node.btn.BackgroundColor3     =
			({ Mine = C.MINE, Barracks = C.BARRACKS, Turret = C.TURRET })[node.btype]
			or node.color
		node.btn.BackgroundTransparency = 0.35
		node.stroke.Color             = node.btn.BackgroundColor3
		node.stroke.Thickness         = 2
		node.label.Text               = node.btype:upper() .. "\n◆ " .. cost
		node.label.TextColor3         = C.TEXT
	end
end

local function updateAllNodes()
	for _, n in childNodes do applyNodeState(n) end
end

-- ── Expand / collapse animations ──────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandMenu()
	buildMenuOpen = true
	if rootBtn    then rootBtn.Text = "X" end
	if rootStroke then TweenService:Create(rootStroke, TweenInfo.new(0.12), { Thickness = 4 }):Play() end

	for _, n in childNodes do
		if not isResearchVisible(n.btype) then continue end
		n.wrapper.Visible              = true
		n.wrapper.Position             = n.startPos
		n.btn.BackgroundTransparency   = 1
		TweenService:Create(n.wrapper, EXPAND_TI, { Position = n.finalPos }):Play()
		TweenService:Create(n.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
	end
end

local function collapseMenu()
	buildMenuOpen = false
	hideTooltip()
	if rootBtn    then rootBtn.Text = "⚒" end
	if rootStroke then TweenService:Create(rootStroke, TweenInfo.new(0.12), { Thickness = 2 }):Play() end

	for _, n in childNodes do
		TweenService:Create(n.wrapper, COLLAPSE_TI, { Position = n.startPos }):Play()
		TweenService:Create(n.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, n in childNodes do n.wrapper.Visible = false end
	end)
end

-- ── HUD.create ────────────────────────────────────────────────────────────────
function HUD.create(): (Frame, TextButton)
	local sg                    = Instance.new("ScreenGui")
	sg.Name                     = "RTSHUD"
	sg.ResetOnSpawn             = false
	sg.ZIndexBehavior           = Enum.ZIndexBehavior.Sibling
	sg.Parent                   = localPlayer.PlayerGui
	setupScaling(sg)

	-- ── Resource bar (top-left) ───────────────────────────────────────────────
	local resBar                    = Instance.new("Frame")
	resBar.Name                     = "ResourceBar"
	resBar.Size                     = UDim2.fromOffset(272, 40)
	resBar.Position                 = UDim2.fromOffset(12, 12)
	resBar.BackgroundColor3         = C.BG_PANEL
	resBar.BackgroundTransparency   = 0.08
	resBar.BorderSizePixel          = 0
	resBar.ZIndex                   = 4
	resBar.Parent                   = sg
	UILib.corner(resBar, 8)
	UILib.stroke(resBar, C.BORDER, 1)

	UILib.lbl(resBar, "◆",
		UDim2.fromOffset(22, 40), UDim2.fromOffset(8, 0),
		{ bold = true, size = 18, color = C.GOLD, align = Enum.TextXAlignment.Center, zIndex = 5 })

	local rLbl = UILib.lbl(resBar, "400",
		UDim2.fromOffset(100, 40), UDim2.fromOffset(30, 0),
		{ bold = true, size = 16, color = C.GOLD, align = Enum.TextXAlignment.Left, zIndex = 5 })
	rLbl.Name = "ResLabel"
	resLabel   = rLbl

	UILib.lbl(resBar, "·",
		UDim2.fromOffset(14, 40), UDim2.fromOffset(132, 0),
		{ size = 16, color = C.SUBTEXT, align = Enum.TextXAlignment.Center, zIndex = 5 })

	local iLbl = UILib.lbl(resBar, "",
		UDim2.fromOffset(112, 40), UDim2.fromOffset(148, 0),
		{ size = 13, color = C.GREEN, align = Enum.TextXAlignment.Left, zIndex = 5 })
	iLbl.Name = "IncLabel"
	incLabel   = iLbl

	-- ── Selection label (top-centre) ──────────────────────────────────────────
	local sLbl                      = Instance.new("TextLabel")
	sLbl.Name                       = "SelLabel"
	sLbl.Size                       = UDim2.fromOffset(280, 38)
	sLbl.Position                   = UDim2.new(0.5, -140, 0, 12)
	sLbl.BackgroundTransparency     = 1
	sLbl.TextColor3                 = C.TEXT
	sLbl.Font                       = Enum.Font.GothamBold
	sLbl.TextSize                   = 15
	sLbl.TextXAlignment             = Enum.TextXAlignment.Center
	sLbl.Text                       = ""
	sLbl.ZIndex                     = 4
	sLbl.Parent                     = sg
	selLabel = sLbl

	-- ── Drag-select rectangle ─────────────────────────────────────────────────
	local dragFrame                     = Instance.new("Frame")
	dragFrame.Name                      = "DragSelect"
	dragFrame.BackgroundColor3          = C.ACCENT
	dragFrame.BackgroundTransparency    = 0.76
	dragFrame.BorderSizePixel           = 1
	dragFrame.BorderColor3              = C.ACCENT
	dragFrame.Visible                   = false
	dragFrame.ZIndex                    = 20
	dragFrame.Parent                    = sg

	-- ── CC placement button (shown in CC mode only) ───────────────────────────
	local ccBtn                         = Instance.new("TextButton")
	ccBtn.Name                          = "CCButton"
	ccBtn.Size                          = UDim2.fromOffset(520, 86)
	ccBtn.AnchorPoint                   = Vector2.new(0.5, 1)
	ccBtn.Position                      = UDim2.new(0.5, 0, 1, -24)
	ccBtn.BackgroundColor3              = Color3.fromRGB(4, 20, 28)
	ccBtn.BackgroundTransparency        = 0
	ccBtn.BorderSizePixel               = 0
	ccBtn.Text                          = ""
	ccBtn.AutoButtonColor               = false
	ccBtn.ZIndex                        = 4
	ccBtn.Visible                       = false
	ccBtn.Parent                        = sg
	UILib.corner(ccBtn, 14)
	ccBtnInternal = ccBtn

	-- Background gradient (dark teal wash)
	local ccGrad                        = Instance.new("UIGradient")
	ccGrad.Color                        = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(  0,  38,  52)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(  2,  18,  30)),
	})
	ccGrad.Rotation                     = 90
	ccGrad.Parent                       = ccBtn

	-- Glowing border
	local ccGlowStroke                  = Instance.new("UIStroke")
	ccGlowStroke.Color                  = Color3.fromRGB(0, 210, 220)
	ccGlowStroke.Thickness              = 2
	ccGlowStroke.Transparency           = 0
	ccGlowStroke.ApplyStrokeMode        = Enum.ApplyStrokeMode.Border
	ccGlowStroke.Parent                 = ccBtn
	ccGlowRef                           = ccGlowStroke

	-- Left icon circle
	local iconCircle                    = Instance.new("Frame")
	iconCircle.Size                     = UDim2.fromOffset(58, 58)
	iconCircle.Position                 = UDim2.fromOffset(14, 14)
	iconCircle.BackgroundColor3         = Color3.fromRGB(0, 160, 180)
	iconCircle.BackgroundTransparency   = 0.25
	iconCircle.BorderSizePixel          = 0
	iconCircle.ZIndex                   = 5
	iconCircle.Parent                   = ccBtn
	UILib.corner(iconCircle, 29)

	local iconLbl                       = Instance.new("TextLabel")
	iconLbl.Size                        = UDim2.new(1, 0, 1, 0)
	iconLbl.BackgroundTransparency      = 1
	iconLbl.Font                        = Enum.Font.GothamBold
	iconLbl.TextSize                    = 30
	iconLbl.TextColor3                  = Color3.fromRGB(180, 255, 255)
	iconLbl.TextXAlignment              = Enum.TextXAlignment.Center
	iconLbl.TextYAlignment              = Enum.TextYAlignment.Center
	iconLbl.Text                        = "⌂"
	iconLbl.ZIndex                      = 6
	iconLbl.Parent                      = iconCircle

	-- Title text
	local ccTitle                       = Instance.new("TextLabel")
	ccTitle.Size                        = UDim2.fromOffset(420, 38)
	ccTitle.Position                    = UDim2.fromOffset(84, 10)
	ccTitle.BackgroundTransparency      = 1
	ccTitle.Font                        = Enum.Font.GothamBold
	ccTitle.TextSize                    = 26
	ccTitle.TextColor3                  = Color3.fromRGB(180, 255, 255)
	ccTitle.TextXAlignment              = Enum.TextXAlignment.Left
	ccTitle.TextYAlignment              = Enum.TextYAlignment.Center
	ccTitle.Text                        = "PLACE COMMAND CENTER"
	ccTitle.TextStrokeTransparency      = 0.5
	ccTitle.TextStrokeColor3            = Color3.new(0, 0, 0)
	ccTitle.ZIndex                      = 5
	ccTitle.Parent                      = ccBtn

	-- Subtitle text
	local ccSub                         = Instance.new("TextLabel")
	ccSub.Size                          = UDim2.fromOffset(420, 26)
	ccSub.Position                      = UDim2.fromOffset(84, 50)
	ccSub.BackgroundTransparency        = 1
	ccSub.Font                          = Enum.Font.Gotham
	ccSub.TextSize                      = 15
	ccSub.TextColor3                    = Color3.fromRGB(100, 190, 200)
	ccSub.TextXAlignment                = Enum.TextXAlignment.Left
	ccSub.TextYAlignment                = Enum.TextYAlignment.Center
	ccSub.Text                          = "Click anywhere on the map to deploy"
	ccSub.ZIndex                        = 5
	ccSub.Parent                        = ccBtn

	-- Scale spring for pop-in animation
	local ccScaleInst                   = Instance.new("UIScale")
	ccScaleInst.Scale                   = 1
	ccScaleInst.Parent                  = ccBtn
	ccScaleRef                          = ccScaleInst

	-- Hover brighten
	ccBtn.MouseEnter:Connect(function()
		TweenService:Create(ccBtn, TweenInfo.new(0.12), {
			BackgroundColor3 = Color3.fromRGB(0, 35, 48)
		}):Play()
		TweenService:Create(ccGlowStroke, TweenInfo.new(0.12), { Thickness = 3.5 }):Play()
	end)
	ccBtn.MouseLeave:Connect(function()
		TweenService:Create(ccBtn, TweenInfo.new(0.12), {
			BackgroundColor3 = Color3.fromRGB(4, 20, 28)
		}):Play()
		TweenService:Create(ccGlowStroke, TweenInfo.new(0.12), { Thickness = 2 }):Play()
	end)

	-- ── Cancel button (shown during placement, bottom-right) ──────────────────
	local cancelBtn                     = UILib.btn(sg,
		"X  CANCEL",
		UDim2.fromOffset(145, 50),
		UDim2.new(1, -160, 1, -60),
		C.RED, 6)
	cancelBtn.Name                      = "CancelBtn"
	cancelBtn.TextSize                  = 14
	cancelBtn.Visible                   = false
	cancelBtnRef                        = cancelBtn

	-- ── Radial build overlay (full-screen transparent) ────────────────────────
	local ov                            = Instance.new("Frame")
	ov.Name                             = "BuildOverlay"
	ov.Size                             = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency           = 1
	ov.BorderSizePixel                  = 0
	ov.ZIndex                           = 3
	ov.Visible                          = false    -- hidden in CC mode
	ov.Parent                           = sg
	buildOverlay = ov

	-- Root "BUILD" node — bottom-left, always visible when overlay is visible
	local rootPos                       = UDim2.new(0, 80, 1, -110)
	local rootWrapper, rBtn             = UILib.radialNode(ov, "BUILD", "⚒", C.ACCENT, rootPos, 80, 4)
	rootBtn                             = rBtn
	rootStroke                          = rBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local _rw = rootWrapper  -- suppress unused

	-- "UPGRADES" node — circular, matching BUILD style
	do
		local upgPos = UDim2.new(0, 80, 1, -212)
		local _w, btn = UILib.radialNode(ov, "UPGRADES", "⚗", UPGRADES_COLOR, upgPos, 80, 4)
		;(_w:FindFirstChild("NodeLabel") :: TextLabel).TextSize = 15

		local stroke     = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		stroke.Color     = UPGRADES_COLOR
		stroke.Thickness = 1.5

		btn.MouseEnter:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0.15 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 2.5 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0.35 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 1.5 }):Play()
		end)

		upgradesBtnRef     = btn
		upgradesStroke     = stroke
		upgradesBtnWrapper = _w :: Frame
		_w.Visible         = false   -- hidden until the player earns their first upgrade
	end

	-- Hover tooltip — fixed position above the build menu, always in the same spot
	do
		local tip                        = Instance.new("Frame")
		tip.Name                         = "BuildTooltip"
		tip.Size                         = UDim2.fromOffset(420, 92)
		-- Anchored bottom-left, sitting well above the UPGRADES button
		tip.Position                     = UDim2.new(0, 22, 1, -340)
		tip.BackgroundTransparency       = 1
		tip.BorderSizePixel              = 0
		tip.Visible                      = false
		tip.ZIndex                       = 5
		tip.Parent                       = ov
		tooltipFrame = tip

		local tipTitle                   = Instance.new("TextLabel")
		tipTitle.Size                    = UDim2.new(1, 0, 0, 54)
		tipTitle.Position                = UDim2.new(0, 0, 0, 0)
		tipTitle.BackgroundTransparency  = 1
		tipTitle.Text                    = ""
		tipTitle.Font                    = Enum.Font.GothamBold
		tipTitle.TextSize                = 44
		tipTitle.TextColor3              = C.ACCENT
		tipTitle.TextXAlignment          = Enum.TextXAlignment.Left
		tipTitle.TextStrokeTransparency  = 0.25
		tipTitle.TextStrokeColor3        = Color3.new(0, 0, 0)
		tipTitle.ZIndex                  = 6
		tipTitle.Parent                  = tip
		tooltipTitle = tipTitle

		local tipDesc                    = Instance.new("TextLabel")
		tipDesc.Size                     = UDim2.new(1, 0, 0, 30)
		tipDesc.Position                 = UDim2.new(0, 2, 0, 58)
		tipDesc.BackgroundTransparency   = 1
		tipDesc.Text                     = ""
		tipDesc.Font                     = Enum.Font.GothamBold
		tipDesc.TextSize                 = 19
		tipDesc.TextColor3               = C.TEXT
		tipDesc.TextXAlignment           = Enum.TextXAlignment.Left
		tipDesc.TextStrokeTransparency   = 0.35
		tipDesc.TextStrokeColor3         = Color3.new(0, 0, 0)
		tipDesc.ZIndex                   = 6
		tipDesc.Parent                   = tip
		tooltipDesc = tipDesc
	end

	-- Child nodes spread right along the bottom from the root position
	for i, def in CHILD_DEFS do
		local finalPos = UDim2.new(
			rootPos.X.Scale,
			rootPos.X.Offset + i * CHILD_SPACING,
			rootPos.Y.Scale,
			rootPos.Y.Offset
		)

		local wrapper, btn = UILib.radialNode(ov, def.btype, def.icon, def.color, rootPos, 60, 4)
		wrapper.Visible = false

		local stroke  = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label   = wrapper:FindFirstChild("NodeLabel") :: TextLabel

		table.insert(childNodes, {
			wrapper  = wrapper,
			btn      = btn,
			stroke   = stroke,
			label    = label,
			btype    = def.btype,
			color    = def.color,
			desc     = def.desc,
			finalPos = finalPos,
			startPos = rootPos,
		})

		-- Hover: start typewriter (tooltip position is fixed, set once at create time)
		local bname  = def.btype:upper()
		local bcolor = def.color
		local bdesc  = def.desc
		btn.MouseEnter:Connect(function()
			if not buildMenuOpen then return end
			startTypewriter(bname, bdesc, bcolor)
		end)
		btn.MouseLeave:Connect(hideTooltip)
	end

	updateAllNodes()
	return dragFrame, ccBtn
end

-- ── Notification toast ────────────────────────────────────────────────────────
-- Shows a small pill at the top-right that auto-dismisses after 4 s.
-- Multiple calls stack vertically (each new toast appears below the previous).

local toastQueue: { Frame } = {}
local TOAST_BASE_Y = 64   -- px from top for the first toast

local function shiftToasts()
	for i, t in toastQueue do
		TweenService:Create(t, TweenInfo.new(0.18), {
			Position = UDim2.new(1, -12, 0, TOAST_BASE_Y + (i - 1) * 52)
		}):Play()
	end
end

function HUD.showNotification(msg: string, color: Color3?)
	local sg = localPlayer.PlayerGui:FindFirstChild("RTSHUD") :: ScreenGui?
	if not sg then return end

	local col = color or C.TEXT

	local toast                         = Instance.new("Frame")
	toast.Size                          = UDim2.fromOffset(290, 42)
	toast.Position                      = UDim2.new(1, 290, 0, TOAST_BASE_Y)  -- starts off-screen right
	toast.AnchorPoint                   = Vector2.new(1, 0)
	toast.BackgroundColor3              = Color3.fromRGB(8, 12, 24)
	toast.BackgroundTransparency        = 0.06
	toast.BorderSizePixel               = 0
	toast.ZIndex                        = 60
	toast.Parent                        = sg
	UILib.corner(toast, 8)
	UILib.stroke(toast, col, 1.5)

	-- Colour accent on the left edge
	local bar                           = Instance.new("Frame")
	bar.Size                            = UDim2.new(0, 4, 1, -12)
	bar.Position                        = UDim2.fromOffset(6, 6)
	bar.BackgroundColor3                = col
	bar.BorderSizePixel                 = 0
	bar.ZIndex                          = 61
	bar.Parent                          = toast
	UILib.corner(bar, 2)

	local lbl                           = Instance.new("TextLabel")
	lbl.Size                            = UDim2.new(1, -20, 1, 0)
	lbl.Position                        = UDim2.fromOffset(16, 0)
	lbl.BackgroundTransparency          = 1
	lbl.Text                            = msg
	lbl.TextSize                        = 13
	lbl.TextColor3                      = col
	lbl.Font                            = Enum.Font.GothamBold
	lbl.TextXAlignment                  = Enum.TextXAlignment.Left
	lbl.TextWrapped                     = true
	lbl.ZIndex                          = 61
	lbl.Parent                          = toast

	table.insert(toastQueue, toast)
	local targetY = TOAST_BASE_Y + (#toastQueue - 1) * 52

	-- Slide all existing toasts into their new positions, then slide this one in
	shiftToasts()
	TweenService:Create(toast, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.new(1, -12, 0, targetY)
	}):Play()

	-- Auto-dismiss after 4 s
	task.delay(4, function()
		local t2 = TweenService:Create(toast, TweenInfo.new(0.18), { Position = UDim2.new(1, 290, 0, targetY) })
		t2.Completed:Once(function()
			for i, t in toastQueue do
				if t == toast then table.remove(toastQueue, i); break end
			end
			toast:Destroy()
			shiftToasts()
		end)
		t2:Play()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function HUD.setResources(n: number)
	currentResources = n
	refreshResDisplay()
end

function HUD.setIncome(perMin: number)
	currentIncome = perMin
	refreshResDisplay()
end

local ccPulseActive = false

function HUD.setCommandCenterMode(isCC: boolean)
	if buildOverlay  then buildOverlay.Visible  = not isCC end
	if ccBtnInternal then ccBtnInternal.Visible = isCC     end
	if isCC and buildMenuOpen then collapseMenu() end

	if isCC then
		-- Pop-in spring
		if ccScaleRef then
			ccScaleRef.Scale = 0.78
			TweenService:Create(ccScaleRef,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
		end

		-- Continuous border pulse while CC mode is active
		if not ccPulseActive then
			ccPulseActive = true
			task.spawn(function()
				while ccPulseActive and ccGlowRef do
					TweenService:Create(ccGlowRef,
						TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
						{ Thickness = 5, Transparency = 0.1 }
					):Play()
					task.wait(0.9)
					if not ccPulseActive then break end
					TweenService:Create(ccGlowRef,
						TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
						{ Thickness = 2, Transparency = 0 }
					):Play()
					task.wait(0.9)
				end
			end)
		end
	else
		ccPulseActive = false
		if ccGlowRef then
			TweenService:Create(ccGlowRef,
				TweenInfo.new(0.15), { Thickness = 2, Transparency = 0 }
			):Play()
		end
	end
end

function HUD.refreshTrayState(counts: { [string]: number })
	playerCounts = counts
	updateAllNodes()
end

function HUD.setHasResearch(fn: (string) -> boolean)
	hasResearchFn = fn
	updateAllNodes()
end

function HUD.setUpgradesVisible(visible: boolean)
	local w = upgradesBtnWrapper
	if not w then return end
	w.Visible = visible
end

-- ── HUD.wire ──────────────────────────────────────────────────────────────────
function HUD.wire(
	network,
	unitController,
	buildingPlacer,
	hidePanelsFn: () -> (),
	upgradesFn:  (() -> ())?
)
	-- Resource sync
	network.onResourceSync(function(n: number)
		HUD.setResources(n)
	end)

	-- Selection display
	unitController.onSelectionChanged(function(n: number)
		if selLabel then
			selLabel.Text = n > 0
				and (n .. " unit" .. (n == 1 and "" or "s") .. " selected")
				or  ""
		end
	end)

	-- Root node click: toggle build menu
	if rootBtn then
		rootBtn.MouseButton1Click:Connect(function()
			if buildMenuOpen then
				collapseMenu()
			else
				hidePanelsFn()
				expandMenu()
			end
		end)
	end

	-- Child node clicks: enter placement mode
	for _, node in childNodes do
		local n = node  -- capture
		n.btn.MouseButton1Click:Connect(function()
			if not isUnlocked(n.btype) then return end
			local info = BUILDING_INFO[n.btype]
			if info and currentResources < info.cost then
				HUD.showNotification("⚠ Not enough resources  (need ◆ " .. info.cost .. ")", C.GOLD)
				return
			end
			hidePanelsFn()
			buildingPlacer.enterPlacementMode(n.btype)
		end)
	end

	-- Cancel button
	if cancelBtnRef then
		cancelBtnRef.MouseButton1Click:Connect(function()
			buildingPlacer.exitPlacementMode()
		end)
	end

	-- Upgrades button — upgradesFn owns its own show/hide logic; don't call
	-- hidePanelsFn first or it resets the toggle flag before upgradesFn checks it.
	if upgradesBtnRef and upgradesFn then
		upgradesBtnRef.MouseButton1Click:Connect(upgradesFn)
	end

	-- Placement mode changes
	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		currentActivePlacing = active and buildingType or nil
		updateAllNodes()
		if cancelBtnRef then
			cancelBtnRef.Visible = active and buildingType ~= "CommandCenter"
		end
	end)
end

return HUD
