--!strict
--[[
    WorkshopPanel — Radial bubble node-graph (Fusion 0.3.0).

    Root nodes: Units | Monument | Structures (always visible at screen centre).
    Monument is a standalone root-level node (no children).
    Click Units / Structures → children fan outward.
    Click a child            → starts research.
    Hover any node           → tooltip near the cursor.

    Node colours are state-driven (not per-tech):
      AVAILABLE   – ready to research (mid-blue)
      CANT_AFFORD – not enough resources, Monument only (dimmed)
      IN_PROGRESS – currently researching / building (bright cyan)
      DONE        – research / build complete (green)

    Branches are always collapsed when the menu opens or closes.
]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config"))
local UILib            = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C

-- ── Layout constants ──────────────────────────────────────────────────────────
local NODE_D  = UILib.NODE_D   -- 80 px diameter
local RADIUS  = 230            -- distance from root node to child node

-- Root node X-offsets from screen centre.
-- Three nodes in a row: Units (-200) | Monument (0) | Structures (+200)
local UNITS_X     = -200
local MONUMENT_X  =    0
local STRUCTS_X   =  200

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:      string?
local networkRef:      any
local getResearchedFn: ((string) -> boolean)?
local getProgressFn:   ((string) -> number?)?
local getResourcesFn:  (() -> number)?
local localMonumentTime: number?
local screenGui:       ScreenGui?
local overlay:         Frame?

-- ── Tech definitions ──────────────────────────────────────────────────────────
local TECHS = {
	{
		key  = "BetterMines",
		name = "Better Mines",
		icon = "⛏",
		time = 5,
		tip  = "Unlocks upgrade buttons on your mines.\n\nEfficiency — ×2 income per miner\nCapacity — +4 extra miner slots\n\nBoth upgrades are mutually exclusive per mine.",
	},
	{
		key  = "EliteUnits",
		name = "Elite Units",
		icon = "⚔",
		time = 15,
		tip  = "Trains Elite units at your Barracks.\n\nLong range, high damage, spider-leg movement.\nIdeal counter to turret-heavy bases.\n\nCost per unit: 100 res",
	},
	{
		key  = "ConcussionShells",
		name = "Concussion Shells",
		icon = "◈",
		time = 10,
		tip  = "Tank shells slow all hit enemies to 40% speed for 1.5 s.\n\nApplies to both the primary target and AoE splash victims.\nStacks with repeated hits — ideal against blob attacks.",
	},
	{
		key  = "MedicUnit",
		name = "Medic Unit",
		icon = "✚",
		time = 15,
		tip  = "Trains Medic units at your Barracks.\n\nMedics automatically heal the most-injured friendly unit nearby.\n\nCost per unit: 60 res",
	},
	{
		key  = "CombatStims",
		name = "Combat Stims",
		icon = "⚡",
		time = 12,
		tip  = "Soldiers inject combat stimulants when engaging an enemy.\n\n+50% move speed and faster attack rate for 8 s.\nCooldown: 20 s between activations.",
	},
	{
		key  = "HardenedArmor",
		name = "Hardened Armor",
		icon = "🛡",
		time = 10,
		tip  = "Soldiers wear reinforced plating that absorbs a flat 6 damage per incoming hit.\n\nStacks with Combat Stims.",
	},
	{
		key  = "TurretUpgrades",
		name = "Turret Upgrades",
		icon = "⚙",
		time = 20,
		tip  = "Unlocks two upgrade paths for each turret.\n\nFlamethrower — short range (28), rapid fire\nRocket Launcher — long range (70), high damage\n\nMutually exclusive per turret.",
	},
}

local techByKey: { [string]: typeof(TECHS[1]) } = {}
for _, t in TECHS do techByKey[t.key] = t end

-- RocketBarrage is a second-level node (child of ConcussionShells), not part of
-- the main TECHS loop.  Its data lives here for tooltip / label use.
local RB_TECH = {
	key  = "RocketBarrage",
	name = "Rocket Barrage",
	icon = "🚀",
	time = 18,
	tip  = "Replaces the tank's attack with 3 spiraling rockets.\n\nEach rocket deals 65% base damage with AoE splash.\nRockets swirl before converging on the target.\n\nRequires: Concussion Shells",
}

-- ── Child node definitions ─────────────────────────────────────────────────────
type ChildDef = {
	key:   string,
	icon:  string,
	angle: number,   -- degrees; 0° = right, 90° = down
	tip:   string,
}

-- Units children fan to the LEFT.
-- 5 nodes spread over a 148° arc (37° steps) centred on 180°.
-- 37° steps at RADIUS=230 give ~148 px chord — enough gap for labels.
local UNITS_CHILDREN: { ChildDef } = {
	{ key = "EliteUnits",       icon = "⚔", angle = 106, tip = (techByKey["EliteUnits"]      or {tip=""}).tip },
	{ key = "CombatStims",      icon = "⚡", angle = 143, tip = (techByKey["CombatStims"]     or {tip=""}).tip },
	{ key = "MedicUnit",        icon = "✚", angle = 180, tip = (techByKey["MedicUnit"]        or {tip=""}).tip },
	{ key = "HardenedArmor",    icon = "🛡", angle = 217, tip = (techByKey["HardenedArmor"]   or {tip=""}).tip },
	{ key = "ConcussionShells", icon = "◈", angle = 254, tip = (techByKey["ConcussionShells"] or {tip=""}).tip },
}

-- Structures children fan to the RIGHT.
-- 2 nodes at ±62° give ~230 px vertical separation — no overlap possible.
local STRUCTURES_CHILDREN: { ChildDef } = {
	{ key = "BetterMines",    icon = "⛏", angle = -62, tip = (techByKey["BetterMines"]    or {tip=""}).tip },
	{ key = "TurretUpgrades", icon = "⚙", angle =  62, tip = (techByKey["TurretUpgrades"] or {tip=""}).tip },
}

-- ── Semantic state colours ────────────────────────────────────────────────────
local STATE_BG = {
	AVAILABLE   = Color3.fromRGB(40,  90, 175),  -- blue-ish, ready to research
	CANT_AFFORD = Color3.fromRGB(28,  34,  54),  -- dark dim, can't afford
	IN_PROGRESS = C.ACCENT,                       -- bright cyan
	DONE        = C.GREEN,
}
local STATE_STROKE = {
	AVAILABLE   = Color3.fromRGB(80, 140, 230),
	CANT_AFFORD = C.DIM,
	IN_PROGRESS = C.ACCENT,
	DONE        = C.GREEN,
}
local STATE_TEXT = {
	AVAILABLE   = C.TEXT,
	CANT_AFFORD = C.DIM,
	IN_PROGRESS = C.ACCENT,
	DONE        = C.GREEN,
}
local STATE_TRANSP = {
	AVAILABLE   = 0.30,
	CANT_AFFORD = 0.55,
	IN_PROGRESS = 0.10,
	DONE        = 0.20,
}

-- ── Per-node live refs ────────────────────────────────────────────────────────
type NodeRef = {
	btn:       TextButton,
	stroke:    UIStroke,
	label:     TextLabel,
	progTrack: Frame,
	progFill:  Frame,
}
local nodeRefs: { [string]: NodeRef } = {}

-- ── Second-level node: RocketBarrage branching from ConcussionShells ──────────
local isHoveringCS = false   -- true while cursor is over ConcussionShells
local rbWrapper:   Frame?
local rbBtn:       TextButton?
local rbLine:      Frame?

-- ── Tooltip ───────────────────────────────────────────────────────────────────
local ttFrame: Frame?
local ttTitle: TextLabel?
local ttCost:  TextLabel?
local ttBody:  TextLabel?

local function buildTooltip(sg: ScreenGui)
	local f                      = Instance.new("Frame")
	f.Name                       = "WorkshopTooltip"
	f.Size                       = UDim2.fromOffset(272, 200)
	f.Position                   = UDim2.fromOffset(0, 0)  -- repositioned dynamically
	f.BackgroundColor3           = Color3.fromRGB(8, 11, 22)
	f.BackgroundTransparency     = 0.06
	f.BorderSizePixel            = 0
	f.ZIndex                     = 30
	f.Visible                    = false
	f.Parent                     = sg
	UILib.corner(f, 10)
	UILib.stroke(f, C.BORDER, 1.5)

	-- Top accent bar
	local accent                 = Instance.new("Frame")
	accent.Size                  = UDim2.new(1, -2, 0, 3)
	accent.Position              = UDim2.fromOffset(1, 1)
	accent.BackgroundColor3      = C.ACCENT
	accent.BorderSizePixel       = 0
	accent.ZIndex                = 31
	accent.Parent                = f
	UILib.corner(accent, 8)

	-- Tech / node name
	local title                  = Instance.new("TextLabel")
	title.Name                   = "TipTitle"
	title.Size                   = UDim2.new(1, -16, 0, 22)
	title.Position               = UDim2.fromOffset(10, 10)
	title.BackgroundTransparency = 1
	title.Font                   = Enum.Font.GothamBold
	title.TextSize               = 14
	title.TextColor3             = C.TEXT
	title.TextXAlignment         = Enum.TextXAlignment.Left
	title.Text                   = ""
	title.ZIndex                 = 31
	title.Parent                 = f

	-- Cost / time line
	local cost                   = Instance.new("TextLabel")
	cost.Name                    = "TipCost"
	cost.Size                    = UDim2.new(1, -16, 0, 18)
	cost.Position                = UDim2.fromOffset(10, 33)
	cost.BackgroundTransparency  = 1
	cost.Font                    = Enum.Font.GothamBold
	cost.TextSize                = 12
	cost.TextColor3              = C.GOLD
	cost.TextXAlignment          = Enum.TextXAlignment.Left
	cost.Text                    = ""
	cost.ZIndex                  = 31
	cost.Parent                  = f

	-- Separator
	local sep                    = Instance.new("Frame")
	sep.Size                     = UDim2.new(1, -20, 0, 1)
	sep.Position                 = UDim2.fromOffset(10, 55)
	sep.BackgroundColor3         = C.SEP
	sep.BorderSizePixel          = 0
	sep.ZIndex                   = 31
	sep.Parent                   = f

	-- Description body
	local body                   = Instance.new("TextLabel")
	body.Name                    = "TipBody"
	body.Size                    = UDim2.new(1, -20, 1, -68)
	body.Position                = UDim2.fromOffset(10, 62)
	body.BackgroundTransparency  = 1
	body.Font                    = Enum.Font.Gotham
	body.TextSize                = 12
	body.TextColor3              = C.SUBTEXT
	body.TextXAlignment          = Enum.TextXAlignment.Left
	body.TextYAlignment          = Enum.TextYAlignment.Top
	body.TextWrapped             = true
	body.Text                    = ""
	body.ZIndex                  = 31
	body.Parent                  = f

	ttFrame = f
	ttTitle = title
	ttCost  = cost
	ttBody  = body
end

local function positionTooltipAtMouse()
	local f = ttFrame
	local sg = screenGui
	if not f or not sg then return end
	local mouse  = UserInputService:GetMouseLocation()
	local inset  = GuiService:GetGuiInset()
	-- Convert screen coordinates to ScreenGui space
	local mx = mouse.X - inset.X + 16
	local my = mouse.Y - inset.Y + 12
	-- Clamp so the tooltip stays on-screen
	local sw = sg.AbsoluteSize.X
	local sh = sg.AbsoluteSize.Y
	local tw = f.AbsoluteSize.X
	local th = f.AbsoluteSize.Y
	if mx + tw > sw then mx = mouse.X - inset.X - tw - 8 end
	if my + th > sh then my = mouse.Y - inset.Y - th - 8 end
	f.Position = UDim2.fromOffset(mx, my)
end

local function showTooltip(name: string, costLine: string, body: string)
	if not ttFrame or not ttTitle or not ttCost or not ttBody then return end
	ttTitle.Text    = name
	ttCost.Text     = costLine
	ttBody.Text     = body
	positionTooltipAtMouse()
	ttFrame.Visible = true
end

local function hideTooltip()
	if ttFrame then ttFrame.Visible = false end
end

-- ── Progress bar helper ───────────────────────────────────────────────────────
local function makeProgressBar(parent: Instance, zi: number): (Frame, Frame)
	local barTrack                      = Instance.new("Frame")
	barTrack.Name                       = "ProgressTrack"
	barTrack.Size                       = UDim2.new(1, -14, 0, 7)
	barTrack.Position                   = UDim2.new(0, 7, 1, -14)
	barTrack.BackgroundColor3           = Color3.fromRGB(5, 8, 18)
	barTrack.BackgroundTransparency     = 0.1
	barTrack.BorderSizePixel            = 0
	barTrack.ZIndex                     = zi
	barTrack.Visible                    = false
	barTrack.ClipsDescendants           = true
	barTrack.Parent                     = parent
	UILib.corner(barTrack, 3)

	local barFill                       = Instance.new("Frame")
	barFill.Name                        = "Fill"
	barFill.Size                        = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3            = C.ACCENT
	barFill.BorderSizePixel             = 0
	barFill.ZIndex                      = zi + 1
	barFill.Parent                      = barTrack
	UILib.corner(barFill, 3)

	return barTrack, barFill
end

-- ── Node state refresh ────────────────────────────────────────────────────────
local function applyState(ref: NodeRef, state: string)
	ref.btn.BackgroundColor3       = STATE_BG[state]
	ref.btn.BackgroundTransparency = STATE_TRANSP[state]
	ref.stroke.Color               = STATE_STROKE[state]
	ref.label.TextColor3           = STATE_TEXT[state]
end

local function refreshMonumentNode()
	local ref = nodeRefs["Monument"]
	if not ref then return end
	local t = localMonumentTime

	ref.progTrack.Visible = false

	if t == nil then
		local canAfford = (getResourcesFn and getResourcesFn() or 0) >= Config.MONUMENT_COST
		applyState(ref, canAfford and "AVAILABLE" or "CANT_AFFORD")
		ref.stroke.Thickness = 2
		ref.label.Text       = "Monument\n◆ 1 500"
		ref.btn.Active       = canAfford
	elseif t == -1 then
		applyState(ref, "IN_PROGRESS")
		ref.stroke.Thickness = 4
		ref.label.Text       = "Monument\nRising…"
		ref.btn.Active       = false
	else
		applyState(ref, "DONE")
		ref.stroke.Thickness = 2
		local mins = math.floor(t / 60)
		local secs = math.floor(t % 60)
		ref.label.Text = string.format("Monument\n%d:%02d", mins, secs)
		ref.btn.Active = false
	end
end

local function refreshTechNode(key: string)
	local ref  = nodeRefs[key]
	local tech = techByKey[key]
	if not ref or not tech then return end

	local done     = getResearchedFn and getResearchedFn(key) or false
	local progress = getProgressFn   and getProgressFn(key)   or nil
	local inProg   = progress ~= nil and not done

	if done then
		applyState(ref, "DONE")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n✓ Done"
		ref.btn.Active        = false
		ref.progTrack.Visible = false
	elseif inProg then
		local pct = math.floor((progress :: number) * 100)
		applyState(ref, "IN_PROGRESS")
		ref.stroke.Thickness  = 4
		ref.label.Text        = tech.name .. "\n" .. pct .. "%"
		ref.btn.Active        = false
		ref.progTrack.Visible = true
		ref.progFill.Size     = UDim2.new(progress :: number, 0, 1, 0)
		ref.progFill.BackgroundColor3 = C.ACCENT
	else
		applyState(ref, "AVAILABLE")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n⏱ " .. tech.time .. "s"
		ref.btn.Active        = true
		ref.progTrack.Visible = false
	end
end

-- Handles the RocketBarrage second-level node visibility and appearance.
-- Three states:
--   1. ConcussionShells done  → real RocketBarrage node (AVAILABLE/IN_PROGRESS/DONE)
--   2. Hovering CS, CS not done → ghost "???" preview (locked indicator)
--   3. Otherwise              → hidden
local function refreshRocketBarrageNode()
	if not rbWrapper or not rbLine then return end
	local ref = nodeRefs["RocketBarrage"]
	if not ref then return end

	local csDone = getResearchedFn and getResearchedFn("ConcussionShells") or false

	if csDone then
		-- ── Real node ───────────────────────────────────────────────────────
		rbWrapper.Visible             = true
		rbLine.BackgroundTransparency = 0.60

		local done     = getResearchedFn and getResearchedFn("RocketBarrage") or false
		local progress = getProgressFn   and getProgressFn("RocketBarrage")   or nil
		local inProg   = progress ~= nil and not done

		if done then
			applyState(ref, "DONE")
			ref.stroke.Thickness  = 2
			ref.label.Text        = RB_TECH.name .. "\n✓ Done"
			ref.btn.Active        = false
			ref.progTrack.Visible = false
		elseif inProg then
			local pct = math.floor((progress :: number) * 100)
			applyState(ref, "IN_PROGRESS")
			ref.stroke.Thickness  = 4
			ref.label.Text        = RB_TECH.name .. "\n" .. pct .. "%"
			ref.btn.Active        = false
			ref.progTrack.Visible = true
			ref.progFill.Size     = UDim2.new(progress :: number, 0, 1, 0)
			ref.progFill.BackgroundColor3 = C.ACCENT
		else
			applyState(ref, "AVAILABLE")
			ref.stroke.Thickness  = 2
			ref.label.Text        = RB_TECH.name .. "\n⏱ " .. RB_TECH.time .. "s"
			ref.btn.Active        = true
			ref.progTrack.Visible = false
		end

	elseif isHoveringCS then
		-- ── Ghost "???" preview ─────────────────────────────────────────────
		rbWrapper.Visible                = true
		rbLine.BackgroundTransparency    = 0.80
		ref.btn.BackgroundColor3         = Color3.fromRGB(28, 32, 50)
		ref.btn.BackgroundTransparency   = 0.50
		ref.stroke.Color                 = C.DIM
		ref.stroke.Thickness             = 1.5
		ref.label.Text                   = "???"
		ref.label.TextColor3             = Color3.fromRGB(65, 75, 100)
		ref.btn.Active                   = false
		ref.progTrack.Visible            = false

	else
		-- ── Hidden ─────────────────────────────────────────────────────────
		rbWrapper.Visible             = false
		rbLine.BackgroundTransparency = 1
	end
end

local function refresh()
	if not activeCCId then return end
	for _, tech in TECHS do refreshTechNode(tech.key) end
	refreshMonumentNode()
	refreshRocketBarrageNode()
end

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	key:      string,
	finalPos: UDim2,
	startPos: UDim2,
}

local function expandChildren(children: { ChildNode }, stroke: UIStroke)
	TweenService:Create(stroke, TweenInfo.new(0.15), { Thickness = 4 }):Play()
	for _, c in children do
		c.wrapper.Visible             = true
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = STATE_TRANSP["AVAILABLE"] }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
	end
end

local function collapseChildren(children: { ChildNode }, stroke: UIStroke)
	TweenService:Create(stroke, TweenInfo.new(0.15), { Thickness = 2 }):Play()
	hideTooltip()
	for _, c in children do
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in children do c.wrapper.Visible = false end
	end)
end

-- ── Open / closed tracking ────────────────────────────────────────────────────
local unitsIsOpen      = false
local structuresIsOpen = false
local unitsChildrenRef:  { ChildNode } = {}
local structChildrenRef: { ChildNode } = {}
local unitsStrokeRef:    UIStroke?
local structStrokeRef:   UIStroke?

-- Instantly reset all children — no animation. Used on show/hide.
local function resetAllChildren()
	for _, c in unitsChildrenRef do
		c.wrapper.Visible             = false
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
	end
	for _, c in structChildrenRef do
		c.wrapper.Visible             = false
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
	end
	unitsIsOpen      = false
	structuresIsOpen = false
	if unitsStrokeRef  then unitsStrokeRef.Thickness  = 2 end
	if structStrokeRef then structStrokeRef.Thickness  = 2 end
	-- Reset second-level node
	isHoveringCS = false
	if rbWrapper then rbWrapper.Visible = false end
	if rbLine    then rbLine.BackgroundTransparency = 1 end
end

-- ── Build child node group ────────────────────────────────────────────────────
local function buildChildNodes(
	parent:  Frame,
	defs:    { ChildDef },
	rootPos: UDim2
): { ChildNode }
	local nodes: { ChildNode } = {}
	for _, def in defs do
		local rad = math.rad(def.angle)
		local dx  = math.cos(rad) * RADIUS
		local dy  = math.sin(rad) * RADIUS

		local finalPos = UDim2.new(
			rootPos.X.Scale,  rootPos.X.Offset + dx,
			rootPos.Y.Scale,  rootPos.Y.Offset + dy
		)

		local line             = UILib.connectorLineBetween(parent, rootPos, finalPos, 11)
		local wrapper, btn     = UILib.radialNode(parent, def.key, def.icon, STATE_BG["AVAILABLE"], rootPos, nil, 13)
		wrapper.Visible        = false

		-- Widen the label slightly to handle longer names (with wrapping)
		local label = wrapper:FindFirstChild("NodeLabel") :: TextLabel
		label.Size  = UDim2.fromOffset(NODE_D + 40, 52)

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		stroke.Color = STATE_STROKE["AVAILABLE"]

		local barTrack, barFill = makeProgressBar(btn, 16)

		nodeRefs[def.key] = {
			btn       = btn,
			stroke    = stroke,
			label     = label,
			progTrack = barTrack,
			progFill  = barFill,
		}

		-- Tooltip wiring
		local tech    = techByKey[def.key]
		local tipName = tech and tech.name or def.key
		local tipCost = tech and ("⏱ " .. tech.time .. " seconds") or ""
		local tipBody = def.tip

		btn.MouseEnter:Connect(function()
			showTooltip(tipName, tipCost, tipBody)
		end)
		btn.MouseMoved:Connect(positionTooltipAtMouse)
		btn.MouseLeave:Connect(hideTooltip)

		-- Click
		local key = def.key
		btn.MouseButton1Click:Connect(function()
			if not activeCCId or not btn.Active then return end
			networkRef.startResearch(activeCCId, key)
		end)

		table.insert(nodes, {
			wrapper  = wrapper,
			btn      = btn,
			line     = line,
			key      = key,
			finalPos = finalPos,
			startPos = rootPos,
		})
	end
	return nodes
end

-- ── Init ─────────────────────────────────────────────────────────────────────
function WorkshopPanel.init(
	network,
	getResearched: (string) -> boolean,
	getProgress:   (string) -> number?,
	getResources:  (() -> number)?
)
	networkRef      = network
	getResearchedFn = getResearched
	getProgressFn   = getProgress
	getResourcesFn  = getResources

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui
	screenGui = sg

	-- Full-screen overlay (intercepts no clicks — transparent, just a container)
	local ov                         = Instance.new("Frame")
	ov.Name                          = "WorkshopOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	-- ── Root node positions ─────────────────────────────────────────────────
	local unitsPos   = UDim2.new(0.5, UNITS_X,    0.5, 0)
	local monPos     = UDim2.new(0.5, MONUMENT_X, 0.5, 0)
	local structsPos = UDim2.new(0.5, STRUCTS_X,  0.5, 0)

	-- ── Root nodes ──────────────────────────────────────────────────────────
	local _uw, unitsBtn  = UILib.radialNode(ov, "Units",      "⚔", C.ACCENT, unitsPos,   nil, 12)
	local _sw, structBtn = UILib.radialNode(ov, "Structures", "⚒", C.ACCENT, structsPos, nil, 12)
	local _mw, monBtn    = UILib.radialNode(ov, "Monument",   "★", C.GOLD,   monPos,     nil, 12)

	local unitsStroke  = unitsBtn:FindFirstChildWhichIsA("UIStroke")  :: UIStroke
	local structStroke = structBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local monStroke    = monBtn:FindFirstChildWhichIsA("UIStroke")    :: UIStroke
	local monLabel     = _mw:FindFirstChild("NodeLabel")              :: TextLabel
	monLabel.Size      = UDim2.fromOffset(NODE_D + 40, 52)

	-- Monument progress bar (hosted in monBtn)
	local monBarTrack, monBarFill = makeProgressBar(monBtn, 16)
	monBarFill.BackgroundColor3   = C.GOLD

	nodeRefs["Monument"] = {
		btn       = monBtn,
		stroke    = monStroke,
		label     = monLabel,
		progTrack = monBarTrack,
		progFill  = monBarFill,
	}

	-- Monument tooltip + click
	monBtn.MouseEnter:Connect(function()
		showTooltip(
			"Monument",
			"💰 1 500 resources",
			"Rises from your Command Center.\nDefend it for 5 minutes to win.\n\nVisible to all players — 3 000 HP."
		)
	end)
	monBtn.MouseMoved:Connect(positionTooltipAtMouse)
	monBtn.MouseLeave:Connect(hideTooltip)
	monBtn.MouseButton1Click:Connect(function()
		if not activeCCId or not monBtn.Active then return end
		networkRef.buildMonument()
	end)

	-- ── Child node groups ───────────────────────────────────────────────────
	unitsStrokeRef  = unitsStroke
	structStrokeRef = structStroke

	unitsChildrenRef  = buildChildNodes(ov, UNITS_CHILDREN,      unitsPos)
	structChildrenRef = buildChildNodes(ov, STRUCTURES_CHILDREN, structsPos)

	-- ── Second-level node: RocketBarrage branches from ConcussionShells ─────
	-- Angle 200° from ConcussionShells at SUB_RADIUS keeps it on-screen and
	-- visually distinct from the Units fan.
	do
		local SUB_RADIUS = 128
		local SUB_ANGLE  = 200   -- degrees

		local csFinalPos: UDim2?    = nil
		local csBtnRef:   TextButton? = nil
		for _, c in unitsChildrenRef do
			if c.key == "ConcussionShells" then
				csFinalPos = c.finalPos
				csBtnRef   = c.btn
				break
			end
		end

		if csFinalPos then
			local rad   = math.rad(SUB_ANGLE)
			local rbPos = UDim2.new(
				csFinalPos.X.Scale, csFinalPos.X.Offset + math.cos(rad) * SUB_RADIUS,
				csFinalPos.Y.Scale, csFinalPos.Y.Offset + math.sin(rad) * SUB_RADIUS
			)

			-- Connector line (initially hidden; shown by refreshRocketBarrageNode)
			rbLine = UILib.connectorLineBetween(ov, csFinalPos, rbPos, 11)
			rbLine.BackgroundTransparency = 1

			-- The node itself (one wrapper serves both ghost and real states)
			local rbW, rbB = UILib.radialNode(ov, RB_TECH.key, RB_TECH.icon,
				STATE_BG["AVAILABLE"], rbPos, nil, 14)
			rbWrapper         = rbW
			rbBtn             = rbB
			rbWrapper.Visible = false

			local rbLabel = rbW:FindFirstChild("NodeLabel") :: TextLabel
			rbLabel.Size  = UDim2.fromOffset(NODE_D + 40, 52)

			local rbStroke           = rbB:FindFirstChildWhichIsA("UIStroke") :: UIStroke
			local rbTrack, rbFill    = makeProgressBar(rbB, 17)

			nodeRefs["RocketBarrage"] = {
				btn       = rbB,
				stroke    = rbStroke,
				label     = rbLabel,
				progTrack = rbTrack,
				progFill  = rbFill,
			}

			-- Tooltip — content depends on whether CS is done
			rbB.MouseEnter:Connect(function()
				local csDone = getResearchedFn and getResearchedFn("ConcussionShells") or false
				if csDone then
					showTooltip(RB_TECH.name, "⏱ " .. RB_TECH.time .. " seconds", RB_TECH.tip)
				else
					-- Hovering ghost: keep ghost visible + show locked tooltip
					isHoveringCS = true
					refreshRocketBarrageNode()
					showTooltip("🔒 Locked Upgrade",
						"Requires: Concussion Shells",
						"Research Concussion Shells to unlock this upgrade path.")
				end
			end)
			rbB.MouseMoved:Connect(positionTooltipAtMouse)
			rbB.MouseLeave:Connect(function()
				local csDone = getResearchedFn and getResearchedFn("ConcussionShells") or false
				if not csDone then
					isHoveringCS = false
					refreshRocketBarrageNode()
				end
				hideTooltip()
			end)

			-- Click: only active when CS is done and RB is not yet researched
			rbB.MouseButton1Click:Connect(function()
				if not activeCCId or not rbB.Active then return end
				networkRef.startResearch(activeCCId, "RocketBarrage")
			end)

			-- Wire CS hover → ghost appears/disappears
			if csBtnRef then
				csBtnRef.MouseEnter:Connect(function()
					isHoveringCS = true
					refreshRocketBarrageNode()
				end)
				csBtnRef.MouseLeave:Connect(function()
					-- Small delay so the cursor can travel to the ghost node
					-- without it disappearing mid-transit.
					task.delay(0.14, function()
						if not isHoveringCS then
							refreshRocketBarrageNode()
						end
					end)
				end)
			end
		end
	end

	-- ── Root button clicks ──────────────────────────────────────────────────
	unitsBtn.MouseButton1Click:Connect(function()
		if unitsIsOpen then
			unitsIsOpen = false
			collapseChildren(unitsChildrenRef, unitsStroke)
		else
			unitsIsOpen = true
			expandChildren(unitsChildrenRef, unitsStroke)
		end
	end)

	structBtn.MouseButton1Click:Connect(function()
		if structuresIsOpen then
			structuresIsOpen = false
			collapseChildren(structChildrenRef, structStroke)
		else
			structuresIsOpen = true
			expandChildren(structChildrenRef, structStroke)
		end
	end)

	buildTooltip(sg)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	resetAllChildren()   -- always start fully collapsed
	if overlay then overlay.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if overlay then overlay.Visible = false end
	hideTooltip()
	resetAllChildren()   -- reset so next open is always clean
end

function WorkshopPanel.refreshIfVisible()
	if overlay and overlay.Visible then refresh() end
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
	localMonumentTime = timeRemaining
	if overlay and overlay.Visible then refreshMonumentNode() end
end

function WorkshopPanel.resetMonument()
	localMonumentTime = nil
	refreshMonumentNode()
end

return WorkshopPanel
