--!strict
--[[
    HUD — Resource bar, selection label, drag-select rect, CC button,
    and the radial build menu (Mine / Barracks / Turret).

    Build menu: circular root node at bottom-left; three child nodes fan
    upward via TweenService when the root is clicked.

    Public API unchanged except HUD.create() now returns (dragFrame, ccBtn).
    HUD.wire() now takes a hidePanelsFn callback instead of individual button refs.
]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local SoundService     = game:GetService("SoundService")
local RunService       = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local Network           = require(script.Parent:WaitForChild("Network"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

-- ── UI scaling ────────────────────────────────────────────────────────────────
-- The whole bottom HUD cluster (this ScreenGui plus the minimap, command grid,
-- resource bar, command-bar band and scout icons — each a separate ScreenGui) scales
-- off one shared factor in UILib so it stays a cohesive size on every display. See
-- UILib.applyHudScale.

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

-- ── Command-card build/lane page state ──────────────────────────────────────────
-- The new StarCraft-style grid (CommandCard) shows build options when the player's
-- CC is selected or [Space] is pressed (selection-driven, wired from init.client).
local hasCC            = false
local buildExtraSlots: { any }? = nil   -- e.g. CC mobility slot appended by init.client
local laneSpawnFn:      ((string) -> ())? = nil
local buildingPlacerRef: any   = nil
local upgradeMapBtn:    TextButton? = nil

-- Forward-declared renderers (assigned in the public-API section, near the bottom),
-- so early helpers like updateAllNodes / refreshLaneButtons can trigger a re-render.
local renderBuildPage: ((extra: { any }?) -> ())? = nil
local renderLanePage:  (() -> ())?                = nil

-- Build-menu hint: if the player hasn't opened the build menu within 10 s of the
-- tray appearing, a bouncing arrow points at the BUILD node.
local buildMenuEverOpened = false
local buildHintScheduled  = false
local buildHint:      TextLabel? = nil
local buildHintTween: Tween?     = nil
local currentActivePlacing: string? = nil
local isLaneModeActive = false
local lanePanel:     Frame?
local laneUnitBtns:  { [string]: TextButton } = {}

local playerCounts: { [string]: number } = {}
-- In-flight placements the player has sent but that haven't landed yet. Counted in
-- the displayed COST (so the price scales immediately) but NOT in requirement gating.
local pendingCounts: { [string]: number } = {}
local hasResearchFn: ((string) -> boolean)?

-- ── Building metadata ─────────────────────────────────────────────────────────
type BuildingInfo = { cost: number, requires: { [string]: number }, researchReq: string? }
local BUILDING_INFO: { [string]: BuildingInfo } = {
	Foundry    = { cost = Config.FOUNDRY_COST,      requires = {},               researchReq = nil        },
	Deployer   = { cost = Config.DEPLOYER_COST,     requires = { Foundry = 1 },  researchReq = nil        },
	Turret     = { cost = Config.TURRET_COST,       requires = { Deployer = 1 }, researchReq = nil        },
	Relay      = { cost = Config.RELAY_COST,        requires = {},             researchReq = "Relay"      },
	CreepyBlob = { cost = Config.CREEPY_BLOB_COST,  requires = {},             researchReq = "CreepyBlob" },
	LampreyNest = { cost = Config.LAMPREY_NEST_COST, requires = { Deployer = 1 }, researchReq = nil       },
	EngineeringPost = { cost = Config.ENGINEERING_POST_COST, requires = { Deployer = 1 }, researchReq = nil },
	TEST       = { cost = Config.TEST_COST,         requires = {},               researchReq = nil        },
}

-- Buildings limited to a fixed number per player; their build node hides once the
-- player owns (or has in-flight) that many. TEST is a one-at-a-time structure.
local BUILDING_MAX_COUNT: { [string]: number } = {
	TEST = 1,
}

-- Display labels that differ from the internal building-type id.
local DISPLAY_NAME: { [string]: string } = {
	Deployer        = "Bonfire",
	LampreyNest     = "Nest",
	EngineeringPost = "Eng Post",
	TEST            = "TEST",
}

local function dispName(btype: string): string
	return (DISPLAY_NAME[btype] or btype):upper()
end

-- Current cost of the next `btype`, applying exponential scaling from how many the
-- player already owns (mirrors the server's BuildingManager.costFor).
local function costOf(btype: string): number
	local info = BUILDING_INFO[btype]
	local base = info and info.cost or 0
	-- Include in-flight placements so the price climbs the instant one is purchased,
	-- before its drop pod lands (mirrors the server's costFor with pending).
	local count = (playerCounts[btype] or 0) + (pendingCounts[btype] or 0)
	return Config.scaledBuildingCost(base, btype, count)
end

-- Horizontal layout: each child slides right from the root along the bottom bar.
-- Spacing = node diameter (80) + gap (15) = 95 px between centres.
local CHILD_DEFS: { { btype: string, icon: string, color: Color3, desc: string } } = {
	{ btype = "Foundry",    icon = "🏭", color = C.MINE,                        desc = "Passive income; +15% per nearby mineral deposit (deposits drain)" },
	{ btype = "Deployer",   icon = "🔥", color = Color3.fromRGB(160, 80, 230),  desc = "Mystical bonfire; auto-summons units for free. Empower it for more capacity & faster summons" },
	{ btype = "Turret",     icon = "⚙", color = C.TURRET,                      desc = "Auto-attacks nearby enemies"                   },
	{ btype = "Relay",      icon = "📡", color = C.ACCENT,                      desc = "Extends your build zone"                       },
	{ btype = "CreepyBlob", icon = "🫧", color = Color3.fromRGB(100, 40, 180),  desc = "Evolve into soldiers, a worm burst, or a creepy turret" },
	{ btype = "LampreyNest", icon = "🥚", color = Color3.fromRGB(120, 190, 60), desc = "Births Lampreys from pulsing eggs"             },
	{ btype = "EngineeringPost", icon = "🔬", color = Color3.fromRGB(90, 200, 255), desc = "Researches random combat upgrades for your units" },
	{ btype = "TEST", icon = "🧪", color = Color3.fromRGB(160, 80, 230), desc = "Sandbox bonfire (limit 1): summons units, builds structures & has separate supply / spawn-rate upgrades" },
}
local CHILD_SPACING = 114   -- px between child centres

-- Lane mode unit spawn panel definitions
local LANE_UNIT_DEFS: { { utype: string, icon: string, color: Color3 } } = {
	{ utype = "Survivor", icon = "⚔",  color = C.BARRACKS                       },
	{ utype = "Tank",    icon = "🛡",  color = Color3.fromRGB(60,  140,  60)    },
	{ utype = "Elite",   icon = "⭐",  color = Color3.fromRGB(200, 160,  40)    },
	{ utype = "Medic",   icon = "➕",  color = Color3.fromRGB(40,  160, 140)    },
}

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
local sellBtnRef:         TextButton?
local UPGRADES_COLOR = Color3.fromRGB(232, 196, 120)  -- gold, cohesive with the new UI
local SELL_COLOR     = Color3.fromRGB(214, 78, 78)    -- red, demolish/sell

-- Of the given selected building ids, the ones that may actually be sold (own,
-- non-CC, non-Monument). Reads the BuildingType tag on each model in workspace.
local function sellableSelectedIds(ids: { string }): { string }
	local out: { string } = {}
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return out end
	for _, id in ids do
		local m  = bf:FindFirstChild(id)
		local bt = m and m:FindFirstChild("BuildingType") :: StringValue?
		if bt and bt.Value ~= "CommandCenter" and bt.Value ~= "Monument" then
			table.insert(out, id)
		end
	end
	return out
end

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

-- Faction gating: the Hollowed team builds NOTHING from the bottom tray — everything
-- flows from selecting the Mother (their spike Command Center) and its option grid. So
-- their tray is empty. Humans place everything except the legacy creature buildings
-- (kept in code for the Swarm AI). Faction comes from the replicated player attribute
-- set in the lobby (defaults to Humans).
local HOLLOWED_BUILDINGS: { [string]: boolean } = { CreepyBlob = true, LampreyNest = true }
local function currentFaction(): string
	return localPlayer:GetAttribute("Faction") or "Humans"
end
local function factionAllows(btype: string): boolean
	if currentFaction() == "Hollowed" then return false end
	return HOLLOWED_BUILDINGS[btype] ~= true
end

-- Returns false if this building's researchReq hasn't been completed yet.
-- Such nodes are fully hidden from the tray until research is done.
local function isResearchVisible(btype: string): boolean
	if currentFaction() == "Hollowed" then return true end  -- Hollowed skip the Human tech tree
	local info = BUILDING_INFO[btype]
	if not info or not info.researchReq then return true end
	return hasResearchFn ~= nil and hasResearchFn(info.researchReq)
end

local function isUnlocked(btype: string): boolean
	if currentFaction() == "Hollowed" then return true end  -- Hollowed's Blob/Nest have no prereqs
	local info = BUILDING_INFO[btype]
	if not info then return true end
	for req, count in info.requires do
		if (playerCounts[req] or 0) < count then return false end
	end
	return true
end

-- A build node is shown only once it is fully available — both its research gate
-- (if any) and its building prerequisites are met. Locked structures are hidden
-- entirely rather than shown greyed-out.
local function isAtMaxCount(btype: string): boolean
	local max = BUILDING_MAX_COUNT[btype]
	if not max then return false end
	return (playerCounts[btype] or 0) + (pendingCounts[btype] or 0) >= max
end

local function isNodeVisible(btype: string): boolean
	return factionAllows(btype) and isResearchVisible(btype) and isUnlocked(btype) and not isAtMaxCount(btype)
end

-- Re-packs the visible build nodes into consecutive slots along the bottom bar so
-- there are no gaps where hidden (locked) nodes would have been. Updates each
-- visible node's finalPos in place; callers handle the actual show/animate.
local function relayoutNodes()
	local slot = 0
	for _, n in childNodes do
		if isNodeVisible(n.btype) then
			slot += 1
			n.finalPos = UDim2.new(
				n.startPos.X.Scale, n.startPos.X.Offset + slot * CHILD_SPACING,
				n.startPos.Y.Scale, n.startPos.Y.Offset
			)
		end
	end
end

-- ── Resource display ──────────────────────────────────────────────────────────
local function refreshResDisplay()
	if resLabel then resLabel.Text = tostring(currentResources) end
	if incLabel then
		incLabel.Text = currentIncome > 0
			and string.format("+%.0f / min", currentIncome)
			or  ""
	end
end

-- ── Lane panel affordability ──────────────────────────────────────────────────
local function refreshLaneButtons()
	if not isLaneModeActive then return end
	-- Lane unit spawning now lives in the command-card grid; re-render it for
	-- affordability colours when resources change.
	if CommandCard.isOwner("lane") and renderLanePage then renderLanePage() end
end

-- ── Expand / collapse animations ──────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- ── Build node visual state (colour + label only; visibility handled by
-- updateAllNodes). Only ever called for currently-visible nodes. ───────────────
local function applyNodeState(node: ChildNode)
	local placing = currentActivePlacing == node.btype
	local cost    = costOf(node.btype)

	-- The node body stays dark glass; the building's colour lives in the stroke +
	-- icon + label so the tray reads as a cohesive set of framed tiles.
	if placing then
		node.btn.BackgroundColor3 = Color3.fromRGB(14, 26, 34)
		node.stroke.Color         = C.ACCENT
		node.stroke.Thickness     = 3
		node.btn.TextColor3       = C.ACCENT
		node.label.Text           = dispName(node.btype) .. "\nPLACING…"
		node.label.TextColor3     = C.ACCENT
	else
		local accent = ({ Foundry = C.MINE, Turret = C.TURRET })[node.btype]
			or node.color
		node.btn.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
		node.stroke.Color         = accent
		node.stroke.Thickness     = 2
		node.btn.TextColor3       = accent
		node.label.Text       = dispName(node.btype) .. "\n◆ " .. cost
		node.label.TextColor3     = C.TEXT
	end
end

-- Re-packs the tray and shows/hides each node by availability. While the menu is
-- open, visible nodes slide to their packed slot so prerequisites unlocking
-- mid-game (e.g. placing a Foundry reveals Barracks) animate in with no gaps.
-- Re-render the live command-card build page (if it is currently the shown page),
-- so prerequisites/research unlocking mid-game, affordability, and placing-state
-- highlights all update in place. The legacy radial nodes are dormant (never shown).
local function updateAllNodes()
	-- Only re-render if the build page actually still owns the grid (another panel
	-- may have taken it over via selection).
	if CommandCard.isOwner("build") and renderBuildPage then renderBuildPage(buildExtraSlots) end
end

-- ── Build-menu hint arrow ───────────────────────────────────────────────────
local function hideBuildHint()
	if buildHintTween then buildHintTween:Cancel(); buildHintTween = nil end
	if buildHint then buildHint.Visible = false end
end

local function showBuildHint()
	if not buildHint or buildMenuEverOpened or buildMenuOpen then return end
	buildHint.Visible  = true
	buildHint.Position = UDim2.new(0, 88, 1, -186)
	buildHintTween = TweenService:Create(buildHint,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0, 88, 1, -170) })
	buildHintTween:Play()
end

local function expandMenu()
	buildMenuOpen = true
	buildMenuEverOpened = true
	hideBuildHint()
	if rootBtn    then rootBtn.Text = "X" end
	if rootStroke then TweenService:Create(rootStroke, TweenInfo.new(0.12), { Thickness = 4 }):Play() end
	updateAllNodes()
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

-- ── System / pause menu (top-right) ───────────────────────────────────────────
-- A Wuthering-Waves-styled popup with RESUME / SECRETS / LEAVE MATCH. Lives in its
-- own ScreenGui (no UIScale) so the dim overlay always covers the full screen.
local PM_GOLD = Color3.fromRGB(232, 196, 120)
local PM_CYAN = Color3.fromRGB(120, 224, 255)
local PM_INK  = Color3.fromRGB(7, 9, 14)

local function diamond(parent: Instance, sizePx: number, color: Color3, pos: UDim2, zIndex: number): Frame
	local d                  = Instance.new("Frame")
	d.Size                   = UDim2.fromOffset(sizePx, sizePx)
	d.Position               = pos
	d.AnchorPoint            = Vector2.new(0.5, 0.5)
	d.Rotation               = 45
	d.BackgroundColor3       = color
	d.BorderSizePixel        = 0
	d.ZIndex                 = zIndex
	d.Parent                 = parent
	return d
end

-- L-shaped corner brackets on all four corners of `parent` (WuWa framing).
local function cornerBrackets(parent: Instance, color: Color3, len: number, thick: number, zIndex: number)
	for _, a in { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) } do
		local h            = Instance.new("Frame")
		h.Size             = UDim2.fromOffset(len, thick)
		h.AnchorPoint      = a
		h.Position         = UDim2.new(a.X, 0, a.Y, 0)
		h.BackgroundColor3 = color
		h.BorderSizePixel  = 0
		h.ZIndex           = zIndex
		h.Parent           = parent
		local v            = Instance.new("Frame")
		v.Size             = UDim2.fromOffset(thick, len)
		v.AnchorPoint      = a
		v.Position         = UDim2.new(a.X, 0, a.Y, 0)
		v.BackgroundColor3 = color
		v.BorderSizePixel  = 0
		v.ZIndex           = zIndex
		v.Parent           = parent
	end
end

-- Angular "tile" node for the build / research menu — dark glass with a coloured
-- stroke, gold corner brackets and a caption below. Returns (wrapper, btn) with the
-- contract the radial menu logic expects: a UIStroke child + a "NodeLabel" child;
-- viewport icons swap in over the text via UILib.setNodeViewport.
local function buildNode(
	parent: Instance, labelText: string, icon: string, color: Color3,
	position: UDim2, diameter: number, zIndex: number
): (Frame, TextButton)
	local d  = diameter
	local zi = zIndex

	local wrapper                  = Instance.new("Frame")
	wrapper.Name                   = "RadialNode"
	wrapper.Size                   = UDim2.fromOffset(d, d + 38)
	wrapper.Position               = position
	wrapper.AnchorPoint            = Vector2.new(0.5, 0.5)
	wrapper.BackgroundTransparency = 1
	wrapper.ZIndex                 = zi
	wrapper.Parent                 = parent

	local btn                      = Instance.new("TextButton")
	btn.Name                       = "NodeBtn"
	btn.Size                       = UDim2.fromOffset(d, d)
	btn.BackgroundColor3           = Color3.fromRGB(16, 20, 30)
	btn.BackgroundTransparency     = 0.12
	btn.Text                       = icon
	btn.TextSize                   = math.max(20, math.floor(d * 0.40))
	btn.TextColor3                 = color
	btn.TextStrokeTransparency     = 0.6
	btn.TextStrokeColor3           = Color3.new(0, 0, 0)
	btn.Font                       = Enum.Font.GothamBold
	btn.AutoButtonColor            = false
	btn.BorderSizePixel            = 0
	btn.ZIndex                     = zi + 1
	btn.Parent                     = wrapper
	UILib.corner(btn, 12)

	-- Light sheen only. A UIGradient also multiplies the button's TEXT colour, so a
	-- dark gradient here would crush the ⚒ / ⚗ icons to black — keep it near-white.
	local g                        = Instance.new("UIGradient")
	g.Rotation                     = 90
	g.Color                        = ColorSequence.new(
		Color3.fromRGB(255, 255, 255), Color3.fromRGB(208, 208, 208))
	g.Parent                       = btn

	UILib.stroke(btn, color, 2)
	cornerBrackets(btn, PM_GOLD, math.floor(d * 0.20), 2, zi + 4)

	local lbl                      = Instance.new("TextLabel")
	lbl.Name                       = "NodeLabel"
	lbl.Size                       = UDim2.fromOffset(d + 50, 32)
	lbl.Position                   = UDim2.fromOffset(-25, d + 4)
	lbl.BackgroundTransparency     = 1
	lbl.Text                       = labelText
	lbl.Font                       = Enum.Font.GothamBold
	lbl.TextSize                   = 13
	lbl.TextColor3                 = C.TEXT
	lbl.TextStrokeTransparency     = 0.55
	lbl.TextStrokeColor3           = Color3.new(0, 0, 0)
	lbl.TextXAlignment             = Enum.TextXAlignment.Center
	lbl.TextWrapped                = true
	lbl.ZIndex                     = zi + 1
	lbl.Parent                     = wrapper

	return wrapper, btn
end

local function createSystemMenu()
	local sg                = Instance.new("ScreenGui")
	sg.Name                 = "RTSSystemMenu"
	sg.ResetOnSpawn         = false
	sg.IgnoreGuiInset       = true
	sg.DisplayOrder         = 200
	sg.ZIndexBehavior       = Enum.ZIndexBehavior.Sibling
	sg.Parent               = localPlayer.PlayerGui

	-- ── Top-right trigger button ──────────────────────────────────────────────
	local menuBtn                   = Instance.new("TextButton")
	menuBtn.Name                    = "SystemMenuBtn"
	menuBtn.Size                    = UDim2.fromOffset(46, 46)
	menuBtn.AnchorPoint             = Vector2.new(1, 0)
	menuBtn.Position                = UDim2.new(1, -14, 0, 12)
	menuBtn.BackgroundColor3        = PM_INK
	menuBtn.BackgroundTransparency  = 0.08
	menuBtn.AutoButtonColor         = false
	menuBtn.Text                    = "☰"
	menuBtn.Font                    = Enum.Font.GothamBold
	menuBtn.TextSize                = 22
	menuBtn.TextColor3              = PM_GOLD
	menuBtn.BorderSizePixel         = 0
	menuBtn.ZIndex                  = 5
	menuBtn.Parent                  = sg
	UILib.corner(menuBtn, 9)
	local menuBtnStroke             = UILib.stroke(menuBtn, PM_GOLD, 1)
	menuBtnStroke.Transparency      = 0.35

	-- ── Dim overlay (click outside the card to close) ─────────────────────────
	local overlay                   = Instance.new("TextButton")
	overlay.Name                    = "Overlay"
	overlay.Size                    = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3        = Color3.fromRGB(2, 3, 6)
	overlay.BackgroundTransparency  = 0.45
	overlay.AutoButtonColor         = false
	overlay.Text                    = ""
	overlay.Visible                 = false
	overlay.ZIndex                  = 10
	overlay.Parent                  = sg

	-- ── Card (its own TextButton so inside-clicks don't reach the overlay) ────
	local card                      = Instance.new("TextButton")
	card.Name                       = "Card"
	card.Size                       = UDim2.fromOffset(380, 322)
	card.AnchorPoint                = Vector2.new(0.5, 0.5)
	card.Position                   = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3           = Color3.fromRGB(12, 15, 22)
	card.BackgroundTransparency     = 0.02
	card.AutoButtonColor            = false
	card.Text                       = ""
	card.BorderSizePixel            = 0
	card.ZIndex                     = 11
	card.Parent                     = overlay
	UILib.corner(card, 6)
	local cardStroke                = UILib.stroke(card, PM_GOLD, 1.5)
	cardStroke.Transparency         = 0.2

	local cardGrad                  = Instance.new("UIGradient")
	cardGrad.Rotation               = 90
	cardGrad.Color                  = ColorSequence.new(
		Color3.fromRGB(20, 25, 36), Color3.fromRGB(10, 12, 18))
	cardGrad.Parent                 = card

	local cardScale                 = Instance.new("UIScale")
	cardScale.Scale                 = 1
	cardScale.Parent                = card

	-- Gold accent bar + diamond along the card's top
	local accentBar                 = Instance.new("Frame")
	accentBar.Size                  = UDim2.fromOffset(54, 3)
	accentBar.Position              = UDim2.fromOffset(26, 24)
	accentBar.BackgroundColor3      = PM_GOLD
	accentBar.BorderSizePixel       = 0
	accentBar.ZIndex                = 12
	accentBar.Parent                = card
	diamond(card, 8, PM_GOLD, UDim2.fromOffset(90, 25), 12)

	local title                     = Instance.new("TextLabel")
	title.Size                      = UDim2.new(1, -52, 0, 30)
	title.Position                  = UDim2.fromOffset(26, 36)
	title.BackgroundTransparency    = 1
	title.Text                      = "PAUSED"
	title.Font                      = Enum.Font.GothamBold
	title.TextSize                  = 24
	title.TextColor3                = Color3.fromRGB(238, 240, 245)
	title.TextXAlignment            = Enum.TextXAlignment.Left
	title.ZIndex                    = 12
	title.Parent                    = card

	local subtitle                  = Instance.new("TextLabel")
	subtitle.Size                   = UDim2.new(1, -52, 0, 16)
	subtitle.Position               = UDim2.fromOffset(27, 66)
	subtitle.BackgroundTransparency = 1
	subtitle.Text                   = "SYSTEM MENU"
	subtitle.Font                   = Enum.Font.Gotham
	subtitle.TextSize               = 11
	subtitle.TextColor3             = Color3.fromRGB(120, 134, 158)
	subtitle.TextXAlignment         = Enum.TextXAlignment.Left
	subtitle.ZIndex                 = 12
	subtitle.Parent                 = card

	-- ── State + open/close ─────────────────────────────────────────────────────
	local isOpen     = false
	local leaveArmed = false
	local leaveBtn: TextButton? = nil

	local statusLine                = Instance.new("TextLabel")
	statusLine.Size                 = UDim2.new(1, -52, 0, 16)
	statusLine.Position             = UDim2.new(0, 26, 1, -26)
	statusLine.BackgroundTransparency = 1
	statusLine.Text                 = ""
	statusLine.Font                 = Enum.Font.GothamMedium
	statusLine.TextSize             = 12
	statusLine.TextColor3           = PM_CYAN
	statusLine.TextXAlignment       = Enum.TextXAlignment.Left
	statusLine.ZIndex               = 12
	statusLine.Parent               = card

	local function setOpen(open: boolean)
		isOpen = open
		if open then
			leaveArmed       = false
			statusLine.Text  = ""
			if leaveBtn then leaveBtn.Text = "LEAVE MATCH" end
			overlay.Visible  = true
			overlay.BackgroundTransparency = 1
			cardScale.Scale  = 0.86
			TweenService:Create(overlay, TweenInfo.new(0.14), { BackgroundTransparency = 0.45 }):Play()
			TweenService:Create(cardScale,
				TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }):Play()
		else
			TweenService:Create(overlay, TweenInfo.new(0.12), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(cardScale, TweenInfo.new(0.12), { Scale = 0.9 }):Play()
			task.delay(0.12, function()
				if not isOpen then overlay.Visible = false end
			end)
		end
	end

	-- ── Menu item factory ──────────────────────────────────────────────────────
	local function menuItem(text: string, y: number, accent: Color3, onClick: () -> ()): TextButton
		local b                     = Instance.new("TextButton")
		b.Size                      = UDim2.new(1, -52, 0, 48)
		b.Position                  = UDim2.fromOffset(26, y)
		b.BackgroundColor3          = Color3.fromRGB(18, 22, 32)
		b.AutoButtonColor           = false
		b.Text                      = text
		b.Font                      = Enum.Font.GothamBold
		b.TextSize                  = 15
		b.TextColor3                = Color3.fromRGB(206, 214, 228)
		b.TextXAlignment            = Enum.TextXAlignment.Left
		b.BorderSizePixel           = 0
		b.ZIndex                    = 12
		b.Parent                    = card
		UILib.corner(b, 5)
		local pad                   = Instance.new("UIPadding")
		pad.PaddingLeft             = UDim.new(0, 44)
		pad.Parent                  = b
		local st                    = UILib.stroke(b, Color3.fromRGB(38, 46, 62), 1)

		-- Left accent stripe
		local bar                   = Instance.new("Frame")
		bar.Size                    = UDim2.fromOffset(4, 24)
		bar.Position                = UDim2.new(0, 16, 0.5, -12)
		bar.BackgroundColor3        = accent
		bar.BorderSizePixel         = 0
		bar.ZIndex                  = 13
		bar.Parent                  = b
		UILib.corner(bar, 2)

		b.MouseEnter:Connect(function()
			TweenService:Create(b,  TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(26, 32, 46) }):Play()
			TweenService:Create(st, TweenInfo.new(0.12), { Color = accent, Thickness = 1.5 }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(b,  TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(18, 22, 32) }):Play()
			TweenService:Create(st, TweenInfo.new(0.12), { Color = Color3.fromRGB(38, 46, 62), Thickness = 1 }):Play()
		end)
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	menuItem("RESUME", 92, PM_CYAN, function()
		setOpen(false)
	end)

	menuItem("SECRETS", 146, PM_GOLD, function()
		leaveArmed       = false
		statusLine.Text  = "✦  Secrets — coming soon"
		statusLine.TextColor3 = PM_GOLD
	end)

	leaveBtn = menuItem("LEAVE MATCH", 200, Color3.fromRGB(210, 70, 70), function()
		if not leaveArmed then
			leaveArmed            = true
			if leaveBtn then leaveBtn.Text = "CONFIRM — LEAVE MATCH?" end
			statusLine.Text       = "You will forfeit the match."
			statusLine.TextColor3 = Color3.fromRGB(220, 110, 110)
			return
		end
		Network.forfeitMatch()
		setOpen(false)
	end)

	-- ── Wiring ─────────────────────────────────────────────────────────────────
	menuBtn.MouseButton1Click:Connect(function() setOpen(not isOpen) end)
	menuBtn.MouseEnter:Connect(function()
		TweenService:Create(menuBtnStroke, TweenInfo.new(0.12), { Transparency = 0, Thickness = 1.5 }):Play()
	end)
	menuBtn.MouseLeave:Connect(function()
		TweenService:Create(menuBtnStroke, TweenInfo.new(0.12), { Transparency = 0.35, Thickness = 1 }):Play()
	end)
	overlay.MouseButton1Click:Connect(function() setOpen(false) end)
end

-- ── HUD.create ────────────────────────────────────────────────────────────────
function HUD.create(): (Frame, TextButton)
	local sg                    = Instance.new("ScreenGui")
	sg.Name                     = "RTSHUD"
	sg.ResetOnSpawn             = false
	sg.ZIndexBehavior           = Enum.ZIndexBehavior.Sibling
	sg.Parent                   = localPlayer.PlayerGui
	UILib.applyHudScale(sg)

	-- Bottom-left map cluster (resource counter + upgrades button) lives in its own
	-- inset-ignoring ScreenGui so it shares the minimap's coordinate space. It carries
	-- the SAME shared HUD scale as the minimap (below) so the two scale in lockstep and
	-- the resource bar always sits cleanly above the map at every resolution.
	local mapSg                 = Instance.new("ScreenGui")
	mapSg.Name                  = "RTSMapHUD"
	mapSg.ResetOnSpawn          = false
	mapSg.IgnoreGuiInset        = true
	mapSg.DisplayOrder          = 3
	mapSg.ZIndexBehavior        = Enum.ZIndexBehavior.Sibling
	mapSg.Parent                = localPlayer.PlayerGui
	UILib.applyHudScale(mapSg)

	-- ── Resource count — designed crystal icon + the number (no frame) ────────
	local MAP_W = 148   -- minimap border width (MAP_SIZE 144 + 4)
	local ROW_Y = -(MAP_W + 10 + 6)   -- bottom edge of the resource row (above the map)

	-- Designed resource crystal: a faceted purple gem with a smaller cluster shard,
	-- a lavender rim, a gradient body and a bright inner facet + highlight glint.
	do
		local CX, CY = 22, ROW_Y - 15   -- gem centre (row is 30px tall, anchored bottom)

		-- Soft outer glow
		local glow                      = Instance.new("Frame")
		glow.Name                       = "ResGlow"
		glow.Size                       = UDim2.fromOffset(30, 30)
		glow.AnchorPoint                = Vector2.new(0.5, 0.5)
		glow.Position                   = UDim2.new(0, CX, 1, CY)
		glow.Rotation                   = 45
		glow.BackgroundColor3           = Color3.fromRGB(150, 70, 230)
		glow.BackgroundTransparency     = 0.72
		glow.BorderSizePixel            = 0
		glow.ZIndex                     = 4
		glow.Parent                     = mapSg
		UILib.corner(glow, 8)

		-- Small cluster shard (behind, upper-left)
		local shard                     = Instance.new("Frame")
		shard.Name                      = "ResShard"
		shard.Size                      = UDim2.fromOffset(9, 9)
		shard.AnchorPoint               = Vector2.new(0.5, 0.5)
		shard.Position                  = UDim2.new(0, CX - 7, 1, CY - 5)
		shard.Rotation                  = 45
		shard.BackgroundColor3          = Color3.fromRGB(170, 96, 235)
		shard.BorderSizePixel           = 0
		shard.ZIndex                    = 5
		shard.Parent                    = mapSg
		UILib.corner(shard, 2)
		UILib.stroke(shard, Color3.fromRGB(220, 165, 255), 1)

		-- Main gem body
		local gem                       = Instance.new("Frame")
		gem.Name                        = "ResGem"
		gem.Size                        = UDim2.fromOffset(20, 20)
		gem.AnchorPoint                 = Vector2.new(0.5, 0.5)
		gem.Position                    = UDim2.new(0, CX, 1, CY)
		gem.Rotation                    = 45
		gem.BackgroundColor3            = Color3.fromRGB(190, 95, 245)
		gem.BorderSizePixel             = 0
		gem.ZIndex                      = 6
		gem.Parent                      = mapSg
		UILib.corner(gem, 4)
		local gemStroke                 = UILib.stroke(gem, Color3.fromRGB(232, 180, 255), 1.25)
		gemStroke.Transparency          = 0.1
		local gemGrad                   = Instance.new("UIGradient")
		gemGrad.Rotation                = 55
		gemGrad.Color                   = ColorSequence.new({
			ColorSequenceKeypoint.new(0,    Color3.fromRGB(236, 170, 255)),
			ColorSequenceKeypoint.new(0.5,  Color3.fromRGB(176, 78, 236)),
			ColorSequenceKeypoint.new(1,    Color3.fromRGB(120, 44, 190)),
		})
		gemGrad.Parent                  = gem

		-- Inner facet (bright core)
		local facet                     = Instance.new("Frame")
		facet.Size                      = UDim2.fromOffset(8, 8)
		facet.AnchorPoint               = Vector2.new(0.5, 0.5)
		facet.Position                  = UDim2.fromScale(0.5, 0.5)
		facet.BackgroundColor3          = Color3.fromRGB(248, 222, 255)
		facet.BackgroundTransparency    = 0.15
		facet.BorderSizePixel           = 0
		facet.ZIndex                    = 7
		facet.Parent                    = gem
		UILib.corner(facet, 2)

		-- Highlight glint (top-left)
		local glint                     = Instance.new("Frame")
		glint.Size                      = UDim2.fromOffset(3, 3)
		glint.AnchorPoint               = Vector2.new(0.5, 0.5)
		glint.Position                  = UDim2.fromScale(0.3, 0.3)
		glint.BackgroundColor3          = Color3.new(1, 1, 1)
		glint.BorderSizePixel           = 0
		glint.ZIndex                    = 8
		glint.Parent                    = gem
		UILib.corner(glint, 1)
	end

	local rLbl                      = Instance.new("TextLabel")
	rLbl.Name                       = "ResLabel"
	rLbl.Size                       = UDim2.fromOffset(86, 30)
	rLbl.AnchorPoint                = Vector2.new(0, 1)
	rLbl.Position                   = UDim2.new(0, 40, 1, ROW_Y)
	rLbl.BackgroundTransparency     = 1
	rLbl.Text                       = "0"
	rLbl.Font                       = Enum.Font.GothamBlack
	rLbl.TextSize                   = 24
	rLbl.TextColor3                 = Color3.fromRGB(238, 242, 250)
	rLbl.TextStrokeTransparency     = 0.4
	rLbl.TextStrokeColor3           = Color3.new(0, 0, 0)
	rLbl.TextXAlignment             = Enum.TextXAlignment.Left
	rLbl.TextYAlignment             = Enum.TextYAlignment.Center
	rLbl.ZIndex                     = 5
	rLbl.Parent                     = mapSg
	resLabel = rLbl

	-- ── Upgrades — small icon button at the top-right of the minimap ──────────
	-- Opens the Workshop research panel. Hidden until the player earns/places the
	-- prerequisites (driven by HUD.setUpgradesVisible).
	do
		local upg                       = Instance.new("TextButton")
		upg.Name                        = "UpgradesBtn"
		upg.Size                        = UDim2.fromOffset(30, 30)
		upg.AnchorPoint                 = Vector2.new(1, 1)
		upg.Position                    = UDim2.new(0, 10 + MAP_W, 1, -(MAP_W + 10 + 5))
		upg.BackgroundColor3            = Color3.fromRGB(16, 20, 30)
		upg.BackgroundTransparency      = 0.06
		upg.AutoButtonColor             = false
		upg.Font                        = Enum.Font.GothamBold
		upg.TextSize                    = 17
		upg.TextColor3                  = UPGRADES_COLOR
		upg.Text                        = "⚗"
		upg.BorderSizePixel             = 0
		upg.ZIndex                      = 5
		upg.Visible                     = false
		upg.Parent                      = mapSg
		UILib.corner(upg, 6)
		local upgStroke                 = UILib.stroke(upg, UPGRADES_COLOR, 1.25)
		upg.MouseEnter:Connect(function()
			TweenService:Create(upg,       TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(26, 32, 46) }):Play()
			TweenService:Create(upgStroke, TweenInfo.new(0.12), { Thickness = 2 }):Play()
		end)
		upg.MouseLeave:Connect(function()
			TweenService:Create(upg,       TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(16, 20, 30) }):Play()
			TweenService:Create(upgStroke, TweenInfo.new(0.12), { Thickness = 1.25 }):Play()
		end)
		upgradeMapBtn = upg
	end

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

	-- Build-menu hint arrow — points at the BUILD node after 10 s of inactivity
	do
		local hint                  = Instance.new("TextLabel")
		hint.Name                   = "BuildHint"
		hint.AnchorPoint            = Vector2.new(0.5, 1)
		hint.Size                   = UDim2.fromOffset(150, 44)
		hint.Position               = UDim2.new(0, 88, 1, -186)
		hint.BackgroundTransparency = 1
		hint.Text                   = "BUILD HERE\n⬇"
		hint.Font                   = Enum.Font.GothamBold
		hint.TextSize               = 18
		hint.TextColor3             = PM_GOLD
		hint.TextStrokeColor3       = Color3.new(0, 0, 0)
		hint.TextStrokeTransparency = 0.4
		hint.LineHeight             = 1.1
		hint.Visible                = false
		hint.ZIndex                 = 7
		hint.Parent                 = ov
		buildHint = hint
	end

	-- Root "BUILD" node — bottom-left, always visible when overlay is visible
	local rootPos                       = UDim2.new(0, 88, 1, -120)
	local rootWrapper, rBtn             = buildNode(ov, "BUILD", "⚒", C.ACCENT, rootPos, 96, 4)
	rootBtn                             = rBtn
	rootStroke                          = rBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local _rw = rootWrapper  -- suppress unused

	-- Hover helper shared by the stacked side nodes (SELL / UPGRADES)
	local function wireNodeHover(btn: TextButton, stroke: UIStroke)
		btn.MouseEnter:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 3 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn,    TweenInfo.new(0.12), { BackgroundTransparency = 0.12 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.12), { Thickness = 2 }):Play()
		end)
	end

	-- "UPGRADES" / research node — matches the BUILD tile, gold-accented
	do
		local upgPos = UDim2.new(0, 88, 1, -234)
		local _w, btn = buildNode(ov, "UPGRADES", "⚗", UPGRADES_COLOR, upgPos, 96, 4)
		;(_w:FindFirstChild("NodeLabel") :: TextLabel).TextSize = 15

		local stroke     = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		stroke.Color     = UPGRADES_COLOR
		stroke.Thickness = 2
		wireNodeHover(btn, stroke)

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
		tip.Position                     = UDim2.new(0, 22, 1, -366)
		tip.BackgroundTransparency       = 1
		tip.BorderSizePixel              = 0
		tip.Visible                      = false
		tip.ZIndex                       = 5
		tip.Parent                       = ov
		tooltipFrame = tip

		-- Gold left accent bar + diamond to tie the tooltip into the new UI
		local tipBar                     = Instance.new("Frame")
		tipBar.Size                      = UDim2.fromOffset(3, 42)
		tipBar.Position                  = UDim2.fromOffset(0, 8)
		tipBar.BackgroundColor3          = PM_GOLD
		tipBar.BorderSizePixel           = 0
		tipBar.ZIndex                    = 6
		tipBar.Parent                    = tip
		diamond(tip, 8, PM_GOLD, UDim2.fromOffset(2, 4), 6)

		local tipTitle                   = Instance.new("TextLabel")
		tipTitle.Size                    = UDim2.new(1, -16, 0, 54)
		tipTitle.Position                = UDim2.new(0, 16, 0, 0)
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
		tipDesc.Size                     = UDim2.new(1, -16, 0, 30)
		tipDesc.Position                 = UDim2.new(0, 18, 0, 58)
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

		local wrapper, btn = buildNode(ov, def.btype, def.icon, def.color, rootPos, 76, 4)
		wrapper.Visible = false

		UILib.setNodeViewport(btn, ViewportPreview.forBuilding(def.btype, Vector2.new(76, 76)))

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
		local bname  = dispName(def.btype)
		local bcolor = def.color
		local bdesc  = def.desc
		btn.MouseEnter:Connect(function()
			if not buildMenuOpen then return end
			startTypewriter(bname, bdesc, bcolor)
		end)
		btn.MouseLeave:Connect(hideTooltip)
	end

	updateAllNodes()

	-- ── Contextual SELL button (bottom-centre) ─────────────────────────────────
	-- Only shown while a sellable structure is selected (wired in HUD.wire). Sits
	-- below the build-node row and clear of the centre building panels.
	do
		local sellBtn                   = Instance.new("TextButton")
		sellBtn.Name                    = "SellStructureBtn"
		sellBtn.Size                    = UDim2.fromOffset(196, 46)
		sellBtn.AnchorPoint             = Vector2.new(0.5, 1)
		sellBtn.Position                = UDim2.new(0.5, 0, 1, -16)
		sellBtn.BackgroundColor3        = Color3.fromRGB(16, 20, 30)
		sellBtn.BackgroundTransparency  = 0.06
		sellBtn.AutoButtonColor         = false
		sellBtn.Font                    = Enum.Font.GothamBold
		sellBtn.TextSize                = 16
		sellBtn.TextColor3              = SELL_COLOR
		sellBtn.Text                    = "$   SELL STRUCTURE"
		sellBtn.BorderSizePixel         = 0
		sellBtn.ZIndex                  = 6
		sellBtn.Visible                 = false
		sellBtn.Parent                  = sg
		UILib.corner(sellBtn, 6)
		local sellStroke                = UILib.stroke(sellBtn, SELL_COLOR, 1.5)
		cornerBrackets(sellBtn, PM_GOLD, 12, 2, 8)

		sellBtn.MouseEnter:Connect(function()
			TweenService:Create(sellBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(26, 32, 46) }):Play()
			TweenService:Create(sellStroke, TweenInfo.new(0.12), { Thickness = 2.5 }):Play()
		end)
		sellBtn.MouseLeave:Connect(function()
			TweenService:Create(sellBtn,    TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(16, 20, 30) }):Play()
			TweenService:Create(sellStroke, TweenInfo.new(0.12), { Thickness = 1.5 }):Play()
		end)
		sellBtnRef = sellBtn
	end

	-- ── Lane mode spawn panel ──────────────────────────────────────────────────
	do
		local BTN_W  = 84
		local BTN_H  = 88
		local GAP    = 6
		local PAD    = 10
		local HEADER = 22
		local nUnits = #LANE_UNIT_DEFS
		local panelW = PAD * 2 + nUnits * BTN_W + (nUnits - 1) * GAP
		local panelH = PAD + HEADER + GAP + BTN_H + PAD

		local panel                     = Instance.new("Frame")
		panel.Name                      = "LanePanel"
		panel.Size                      = UDim2.fromOffset(panelW, panelH)
		panel.Position                  = UDim2.new(0, 12, 1, -(panelH + 12))
		panel.BackgroundColor3          = C.BG_PANEL
		panel.BackgroundTransparency    = 0.06
		panel.BorderSizePixel           = 0
		panel.ZIndex                    = 3
		panel.Visible                   = false
		panel.Parent                    = sg
		UILib.corner(panel, 12)
		UILib.stroke(panel, C.ACCENT, 1.5)

		local panelGrad                 = Instance.new("UIGradient")
		panelGrad.Color                 = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(8,  22, 42)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(4,  11, 22)),
		})
		panelGrad.Rotation              = 90
		panelGrad.Parent                = panel

		local headerLbl                 = Instance.new("TextLabel")
		headerLbl.Size                  = UDim2.new(1, -PAD * 2, 0, HEADER)
		headerLbl.Position              = UDim2.fromOffset(PAD, PAD - 2)
		headerLbl.BackgroundTransparency = 1
		headerLbl.Text                  = "SPAWN UNIT"
		headerLbl.Font                  = Enum.Font.GothamBold
		headerLbl.TextSize              = 13
		headerLbl.TextColor3            = C.ACCENT
		headerLbl.TextXAlignment        = Enum.TextXAlignment.Left
		headerLbl.ZIndex                = 4
		headerLbl.Parent                = panel

		for i, def in LANE_UNIT_DEFS do
			local bx    = PAD + (i - 1) * (BTN_W + GAP)
			local by    = PAD + HEADER + GAP
			local uType = def.utype
			local col   = def.color

			local btn                       = Instance.new("TextButton")
			btn.Name                        = uType .. "Btn"
			btn.Size                        = UDim2.fromOffset(BTN_W, BTN_H)
			btn.Position                    = UDim2.fromOffset(bx, by)
			btn.BackgroundColor3            = col
			btn.BackgroundTransparency      = 0.35
			btn.BorderSizePixel             = 0
			btn.AutoButtonColor             = false
			btn.Text                        = ""
			btn.ZIndex                      = 4
			btn.Parent                      = panel
			UILib.corner(btn, 10)

			local btnStroke                 = Instance.new("UIStroke")
			btnStroke.Color                 = col
			btnStroke.Thickness             = 2
			btnStroke.Parent                = btn

			local iconVpf                   = ViewportPreview.forUnit(uType, Vector2.new(BTN_W - 8, 40))
			iconVpf.Position                = UDim2.fromOffset(4, 4)
			iconVpf.ZIndex                  = 5
			iconVpf.Parent                  = btn

			local nameLbl                   = Instance.new("TextLabel")
			nameLbl.Size                    = UDim2.new(1, -4, 0, 18)
			nameLbl.Position                = UDim2.fromOffset(2, 43)
			nameLbl.BackgroundTransparency  = 1
			nameLbl.Text                    = uType:upper()
			nameLbl.Font                    = Enum.Font.GothamBold
			nameLbl.TextSize                = 10
			nameLbl.TextColor3              = C.TEXT
			nameLbl.TextXAlignment          = Enum.TextXAlignment.Center
			nameLbl.ZIndex                  = 5
			nameLbl.Parent                  = btn

			local typeDef                   = (Config.UNIT_TYPES :: any)[uType]
			local cost                      = typeDef and typeDef.cost or 0
			local costLbl                   = Instance.new("TextLabel")
			costLbl.Name                    = "CostLabel"
			costLbl.Size                    = UDim2.new(1, -4, 0, 18)
			costLbl.Position                = UDim2.fromOffset(2, 62)
			costLbl.BackgroundTransparency  = 1
			costLbl.Text                    = "◆ " .. cost
			costLbl.Font                    = Enum.Font.GothamBold
			costLbl.TextSize                = 11
			costLbl.TextColor3              = C.GOLD
			costLbl.TextXAlignment          = Enum.TextXAlignment.Center
			costLbl.ZIndex                  = 5
			costLbl.Parent                  = btn

			btn.MouseEnter:Connect(function()
				TweenService:Create(btn,       TweenInfo.new(0.12), { BackgroundTransparency = 0.15 }):Play()
				TweenService:Create(btnStroke, TweenInfo.new(0.12), { Thickness = 3.5 }):Play()
			end)
			btn.MouseLeave:Connect(function()
				TweenService:Create(btn,       TweenInfo.new(0.12), { BackgroundTransparency = 0.35 }):Play()
				TweenService:Create(btnStroke, TweenInfo.new(0.12), { Thickness = 2 }):Play()
			end)

			laneUnitBtns[uType] = btn
		end

		lanePanel = panel
	end

	-- Top-right system / pause menu (own ScreenGui)
	createSystemMenu()

	return dragFrame, ccBtn
end

-- ── Error sound ──────────────────────────────────────────────────────────────
local function playErrorSound()
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://9113923981"
	s.Volume  = 1
	s.Parent  = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
end

-- Exposed so other systems (e.g. BuildingPlacer's can't-afford path) play the same
-- insufficient-funds / unable-to-purchase cue.
function HUD.playErrorSound()
	playErrorSound()
end

-- ── Success sound ─────────────────────────────────────────────────────────────
-- Played when a purchase actually commits (unit spawned, building placed, upgrade
-- bought). Exposed so every purchase path shares one confirmation cue. The cue layers
-- a couple of clips together for a richer confirmation.
local SUCCESS_SOUND_IDS = {
	"rbxassetid://70793938100698",
	"rbxassetid://124702008706576",   -- "mythical" flourish
}
function HUD.playSuccessSound()
	for _, id in SUCCESS_SOUND_IDS do
		local s = Instance.new("Sound")
		s.SoundId = id
		s.Volume  = 1
		s.Parent  = SoundService
		s:Play()
		s.Ended:Once(function() s:Destroy() end)
	end
end

-- ── Notification sound ─────────────────────────────────────────────────────────
-- One shared blip played whenever a notification toast appears. A single reused Sound
-- (rather than a fresh instance each time) so a burst of toasts doesn't pile up voices.
local notifSound       = Instance.new("Sound")
notifSound.SoundId     = "rbxassetid://71092634771595"
notifSound.Volume      = 0.6
notifSound.Parent      = SoundService
function HUD.playNotificationSound()
	notifSound:Play()
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
	HUD.playNotificationSound()

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
	refreshLaneButtons()
	-- Live-refresh the build page so building affordability (and its tooltip) update
	-- the moment resources change, not just on the next interaction.
	updateAllNodes()
end

function HUD.setIncome(perMin: number)
	currentIncome = perMin
	refreshResDisplay()
end

local ccPulseActive = false

function HUD.setCommandCenterMode(isCC: boolean)
	-- isCC = "no Command Center yet". The build options are now selection-driven
	-- (shown on the command-card grid when the CC is selected or [Space] is pressed),
	-- so all we do here is track whether a CC exists and tear the grid down on reset.
	hasCC = not isCC
	if ccBtnInternal then ccBtnInternal.Visible = false end
	if buildOverlay  then buildOverlay.Visible  = false end   -- legacy radial stays dormant
	if lanePanel     then lanePanel.Visible     = false end
	ccPulseActive = false

	if isCC then
		-- No CC (round reset): clear any shown grid page.
		CommandCard.hide("build")
		CommandCard.hide("lane")
		buildExtraSlots = nil
	elseif isLaneModeActive and renderLanePage then
		-- Lane gamemode: unit spawning lives persistently in the command-card grid.
		renderLanePage()
	end
end

function HUD.refreshTrayState(counts: { [string]: number })
	playerCounts = counts
	updateAllNodes()
end

-- In-flight placement counts (per building type) — affects displayed cost only.
function HUD.setPendingCounts(counts: { [string]: number })
	pendingCounts = counts
	updateAllNodes()
end

-- Current scaled cost to place the next `btype` (built + in-flight, first-free aware).
-- Used by BuildingPlacer so its affordability checks match what's displayed/charged.
function HUD.getBuildCost(btype: string): number
	return costOf(btype)
end

function HUD.setHasResearch(fn: (string) -> boolean)
	hasResearchFn = fn
	updateAllNodes()
end

function HUD.setUpgradesVisible(_visible: boolean)
	-- Upgrades button is hidden for now (its spot is used by the camera [R] button).
	if upgradeMapBtn then upgradeMapBtn.Visible = false end
end

function HUD.setLaneMode(enabled: boolean)
	isLaneModeActive = enabled
	if lanePanel then lanePanel.Visible = false end
end

function HUD.wireLane(onSpawnFn: (string) -> ())
	laneSpawnFn = onSpawnFn
	if CommandCard.isOwner("lane") and renderLanePage then renderLanePage() end
end

-- ── Command-card build page ────────────────────────────────────────────────────
-- Accent colours for the three "starter" buildings (mirrors the old node styling).
local BUILD_ACCENT: { [string]: Color3 } = {
	Foundry = C.MINE, Deployer = Color3.fromRGB(160, 80, 230), Turret = C.TURRET,
}

local function visibleBuildDefs(): { { btype: string, icon: string, color: Color3, desc: string } }
	local out = {}
	for _, def in CHILD_DEFS do
		if isNodeVisible(def.btype) then table.insert(out, def) end
	end
	return out
end

local function buildBuildSlots(): { CommandCard.Slot }
	local slots: { CommandCard.Slot } = {}
	for i, def in visibleBuildDefs() do
		local btype   = def.btype
		local cost    = costOf(btype)
		local placing = currentActivePlacing == btype
		local accent  = placing and C.ACCENT or (BUILD_ACCENT[btype] or def.color)
		table.insert(slots, {
			index           = i,
			name            = dispName(btype),
			cost            = cost,
			color           = accent,
			enabled         = currentResources >= cost,
			icon            = def.icon,
			viewportKey     = "bld:" .. btype,
			viewportFactory = function() return ViewportPreview.forBuilding(btype, Vector2.new(64, 64)) end,
			badge           = placing and "▸" or nil,
			desc            = def.desc,
			hotkey          = i <= 5 and tostring(i) or nil,
			onClick         = function()
				if not isUnlocked(btype) then return end
				local c = costOf(btype)
				if currentResources < c then
					playErrorSound()
					HUD.showNotification("⚠ Not enough resources  ◆ " .. currentResources .. " / " .. c, C.RED)
					return
				end
				if buildingPlacerRef then buildingPlacerRef.enterPlacementMode(btype) end
			end,
		})
	end
	return slots
end

function HUD.showBuildPage(extra: { any }?)
	if not hasCC then return end
	buildExtraSlots = extra
	local slots = buildBuildSlots()
	if extra then
		local n = #slots
		for j, s in extra do
			s.index = n + j
			table.insert(slots, s)
		end
	end
	CommandCard.show("build", { header = "COMMAND CENTER", slots = slots })
end
renderBuildPage = HUD.showBuildPage

function HUD.hideBuildPage()
	if not CommandCard.isOwner("build") then return end
	buildExtraSlots = nil
	CommandCard.hide("build")
end

function HUD.isBuildPageShown(): boolean
	return CommandCard.isOwner("build")
end

-- ── Command-card lane spawn page (Lane gamemode) ───────────────────────────────
local function buildLaneSlots(): { CommandCard.Slot }
	local slots: { CommandCard.Slot } = {}
	for i, def in LANE_UNIT_DEFS do
		local ut      = def.utype
		local typeDef = (Config.UNIT_TYPES :: any)[ut]
		local cost    = typeDef and typeDef.cost or 0
		table.insert(slots, {
			index           = i,
			name            = ut:upper(),
			cost            = cost,
			color           = def.color,
			enabled         = currentResources >= cost,
			viewportKey     = "unit:" .. ut,
			viewportFactory = function() return ViewportPreview.forUnit(ut, Vector2.new(64, 64)) end,
			desc            = "Spawn a " .. ut .. " down your lane",
			hotkey          = i <= 5 and tostring(i) or nil,
			onClick         = function()
				if currentResources < cost then
					playErrorSound()
					HUD.showNotification("⚠ Not enough resources  ◆ " .. currentResources .. " / " .. cost, C.RED)
					return
				end
				if laneSpawnFn then laneSpawnFn(ut) end
			end,
		})
	end
	return slots
end

function HUD.showLanePage()
	CommandCard.show("lane", { header = "SPAWN UNIT", slots = buildLaneSlots() })
end
renderLanePage = HUD.showLanePage

-- ── HUD.wire ──────────────────────────────────────────────────────────────────
function HUD.wire(
	network,
	unitController,
	buildingPlacer,
	hidePanelsFn: () -> (),
	upgradesFn:  (() -> ())?
)
	buildingPlacerRef = buildingPlacer

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
			local cost = costOf(n.btype)
			if currentResources < cost then
				playErrorSound()
				HUD.showNotification("⚠ Not enough resources  ◆ " .. currentResources .. " / " .. cost, C.RED)
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

	-- Upgrades button (on top of the map) — upgradesFn owns its own show/hide logic;
	-- don't call hidePanelsFn first or it resets the toggle flag before upgradesFn checks it.
	if upgradeMapBtn and upgradesFn then
		upgradeMapBtn.MouseButton1Click:Connect(upgradesFn)
	end

	-- Sell button — only present while a sellable structure is selected.
	if sellBtnRef then
		sellBtnRef.MouseButton1Click:Connect(function()
			local ids = sellableSelectedIds(unitController.getSelectedBuildingIds())
			if #ids == 0 then return end
			network.sellBuildings(ids)
			hidePanelsFn()
			HUD.showNotification("Structure sold  ◆ refund", C.GOLD)
		end)

		-- Toggle visibility from the live selection (cheap: a tiny table scan / frame).
		local sellShown = false
		RunService.Heartbeat:Connect(function()
			local btn = sellBtnRef
			if not btn then return end
			local show = #sellableSelectedIds(unitController.getSelectedBuildingIds()) > 0
			if show ~= sellShown then
				sellShown   = show
				btn.Visible = show
			end
		end)
	end

	-- Placement mode changes
	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		currentActivePlacing = active and buildingType or nil
		updateAllNodes()
		if cancelBtnRef then
			cancelBtnRef.Visible = active and buildingType ~= "CommandCenter"
		end
	end)

	-- Number keybinds 1–5: enter placement mode for the corresponding building
	local KEY_CODES = {
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
	}
	-- Hotkeys map to the visible build slots — only while the build page is shown
	-- (selection-driven: select the CC or press [Space] first).
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if not CommandCard.isOwner("build") then return end
		for i, kc in KEY_CODES do
			if input.KeyCode == kc then
				local defs = visibleBuildDefs()
				local def  = defs[i]
				if not def then return end
				local cost = costOf(def.btype)
				if currentResources < cost then
					playErrorSound()
					HUD.showNotification("⚠ Not enough resources  ◆ " .. currentResources .. " / " .. cost, C.RED)
					return
				end
				buildingPlacer.enterPlacementMode(def.btype)
				return
			end
		end
	end)
end

return HUD
