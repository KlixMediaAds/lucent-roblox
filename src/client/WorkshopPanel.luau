--!strict
--[[
    WorkshopPanel — Left-to-right drip-feed tech tree with dynamic layout.

    Layout is calculated at runtime from ROOT_DEFS and TIER2_CHILDREN.
    Adding a new node only requires updating those two tables — Y positions
    are automatically recalculated so nothing ever overlaps.

    Columns (X offset from screen centre):
      Col 0  x = -490  root category buttons
      Col 1  x = -260  tier-1 techs
      Col 2  x =    0  tier-2 techs

    Node state colours:
      AVAILABLE   – blue,  ready to research
      CANT_AFFORD – dim,   Monument only (not enough resources)
      IN_PROGRESS – cyan,  currently researching
      DONE        – green, research complete
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local GuiService        = game:GetService("GuiService")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C

-- ── Column X positions ────────────────────────────────────────────────────────
local NODE_D  = UILib.NODE_D
local COL0_X  = -490
local COL1_X  = -260
local COL2_X  =    0

-- ── Spacing ───────────────────────────────────────────────────────────────────
-- NODE_SPACING: pixels between adjacent leaf-node centres (vertically)
-- GROUP_GAP:    extra pixels added between separate root groups
local NODE_SPACING = 90
local GROUP_GAP    = 65

-- ── Tree structure (edit these to add/remove nodes) ───────────────────────────
type RootDef = { key: string, icon: string, color: Color3, tier1Keys: { string } }

local ROOT_DEFS: { RootDef } = {
	{ key = "Units",      icon = "⚔", color = C.ACCENT,
	  tier1Keys = { "CombatStims", "ConcussionShells", "MedicUnit", "EyeUpgrade" } },
	{ key = "Structures", icon = "⚒", color = C.ACCENT,
	  tier1Keys = { "BetterMines", "TurretUpgrades", "Relay" } },
}

-- Ordered tier-2 children per tier-1 node.
-- Add a new tier-2 here and it will appear automatically in the tree.
local TIER2_CHILDREN: { [string]: { string } } = {
	CombatStims      = { "HardenedArmor", "Rollers" },
	ConcussionShells = { "RocketBarrage", "Trapper" },
	MedicUnit        = { "EliteUnits" },
}

-- ── Derived lookup tables (auto-built from ROOT_DEFS / TIER2_CHILDREN) ────────
local TIER2_PARENT: { [string]: string } = {}
for t1key, children in TIER2_CHILDREN do
	for _, t2key in children do
		TIER2_PARENT[t2key] = t1key
	end
end

local TIER1_ROOT: { [string]: string } = {}
for _, rootDef in ROOT_DEFS do
	for _, t1key in rootDef.tier1Keys do
		TIER1_ROOT[t1key] = rootDef.key
	end
end

-- ── Dynamic layout calculation ────────────────────────────────────────────────
-- Returns a map of nodeKey → { x, y } screen-centre offsets.
-- Called once at init; positions are stable for the session.
type Pt = { x: number, y: number }

local function calculateLayout(): { [string]: Pt }
	local positions: { [string]: Pt } = {}

	-- 1. Build a flat ordered list of leaf slots, with group boundaries noted.
	type LeafSlot = { t1key: string, t2key: string?, groupIdx: number }
	local leaves: { LeafSlot } = {}

	for gi, rootDef in ROOT_DEFS do
		for _, t1key in rootDef.tier1Keys do
			local children = TIER2_CHILDREN[t1key]
			if children and #children > 0 then
				for _, t2key in children do
					table.insert(leaves, { t1key = t1key, t2key = t2key, groupIdx = gi })
				end
			else
				table.insert(leaves, { t1key = t1key, t2key = nil, groupIdx = gi })
			end
		end
	end

	-- 2. Assign Y to each leaf. Extra gap whenever the group index changes.
	local leafYs: { number } = {}
	local y = 0
	for i, leaf in leaves do
		if i > 1 then
			y += NODE_SPACING
			if leaf.groupIdx ~= leaves[i - 1].groupIdx then
				y += GROUP_GAP
			end
		end
		leafYs[i] = y
	end

	-- Centre the entire tree vertically.
	local totalH = leafYs[#leafYs] or 0
	local yOff   = -totalH / 2
	for i in leafYs do leafYs[i] += yOff end

	-- 3. Assign tier-2 positions and accumulate centroid data for tier-1 nodes.
	local t1Sum: { [string]: number } = {}
	local t1Cnt: { [string]: number } = {}

	for i, leaf in leaves do
		local ly = leafYs[i]
		if leaf.t2key then
			positions[leaf.t2key] = { x = COL2_X, y = ly }
		end
		-- Always accumulate for the tier-1 centroid (whether it has tier-2 or not)
		t1Sum[leaf.t1key] = (t1Sum[leaf.t1key] or 0) + ly
		t1Cnt[leaf.t1key] = (t1Cnt[leaf.t1key] or 0) + 1
	end

	-- 4. Tier-1 positions = centroid of their leaf contributions.
	for t1key, s in t1Sum do
		positions[t1key] = { x = COL1_X, y = s / t1Cnt[t1key] }
	end

	-- 5. Root positions = centroid of their tier-1 nodes.
	for _, rootDef in ROOT_DEFS do
		local s, n = 0, 0
		for _, t1key in rootDef.tier1Keys do
			local p = positions[t1key]
			if p then s += p.y; n += 1 end
		end
		positions[rootDef.key] = { x = COL0_X, y = if n > 0 then s / n else 0 }
	end

	-- 6. Monument sits below the last root group with a full group gap.
	local lastY = leafYs[#leafYs] or 0
	positions["Monument"] = { x = COL0_X, y = lastY + NODE_SPACING + GROUP_GAP }

	return positions
end

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId        : string?
local networkRef        : any
local getResearchedFn   : ((string) -> boolean)?
local getProgressFn     : ((string) -> number?)?
local getResourcesFn    : (() -> number)?
local showNotificationFn: ((string, Color3?) -> ())?
local localMonumentTime : number?
local screenGui         : ScreenGui?
local overlay           : Frame?
local workshopBlur      : BlurEffect?

-- ── Tech data ─────────────────────────────────────────────────────────────────
local TECH_DATA: { [string]: { name: string, icon: string, time: number, tip: string } } = {
	CombatStims = {
		name = "Combat Stims", icon = "⚡", time = 12,
		tip  = "Speed + attacks boost on engage",
	},
	HardenedArmor = {
		name = "Hardened Armor", icon = "🛡", time = 10,
		tip  = "Absorb 6 flat damage/hit",
	},
	Rollers = {
		name = "Rollers", icon = "⚙", time = 20,
		tip  = "Melee charge attack, 20% faster",
	},
	ConcussionShells = {
		name = "Concussion Shells", icon = "◈", time = 10,
		tip  = "Tank shells slow enemies 40%",
	},
	RocketBarrage = {
		name = "Rocket Barrage", icon = "🚀", time = 18,
		tip  = "3 AoE spiraling rockets/attack",
	},
	Trapper = {
		name = "Trapper", icon = "⚓", time = 20,
		tip  = "Harpoons slow enemies 90%",
	},
	MedicUnit = {
		name = "Medic Unit", icon = "✚", time = 15,
		tip  = "Heals nearest injured ally",
	},
	EliteUnits = {
		name = "Elite Units", icon = "⚔", time = 15,
		tip  = "Long range, high damage",
	},
	BetterMines = {
		name = "Better Mines", icon = "⛏", time = 5,
		tip  = "Efficiency + capacity upgrades",
	},
	TurretUpgrades = {
		name = "Turret Upgrades", icon = "⚙", time = 20,
		tip  = "Flamethrower + rocket paths",
	},
	Relay = {
		name = "Relay", icon = "📡", time = 20,
		tip  = "Extends build zone by 65 studs",
	},
	EyeUpgrade = {
		name = "Eye Upgrade", icon = "👁", time = 25,
		tip  = "+20% unit fog-of-war vision radius",
	},
}

-- Mutually exclusive pairs
local MUTEX_SIBLING: { [string]: string } = {
	RocketBarrage = "Trapper",
	Trapper       = "RocketBarrage",
}

-- ── Semantic state colours ────────────────────────────────────────────────────
local STATE_BG = {
	AVAILABLE   = Color3.fromRGB(40,  90, 175),
	CANT_AFFORD = Color3.fromRGB(28,  34,  54),
	IN_PROGRESS = C.ACCENT,
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

-- ── Node refs ─────────────────────────────────────────────────────────────────
type NodeRef = {
	btn      : TextButton,
	stroke   : UIStroke,
	label    : TextLabel,
	progTrack: Frame,
	progFill : Frame,
	wrapper  : Frame,
}
local nodeRefs: { [string]: NodeRef } = {}

type TechNode = {
	pos      : UDim2,
	startPos : UDim2,
	connector: Frame,
}
local techNodes: { [string]: TechNode } = {}

type RootInfo = {
	btn      : TextButton,
	stroke   : UIStroke,
	isOpen   : boolean,
	tier1Keys: { string },
}
local roots: { [string]: RootInfo } = {}

-- ── Tween constants ───────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local REVEAL_TI   = TweenInfo.new(0.30, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)

-- ── Tooltip ───────────────────────────────────────────────────────────────────
local ttFrame: Frame?
local ttTitle: TextLabel?
local ttCost : TextLabel?
local ttBody : TextLabel?

local function buildTooltip(sg: ScreenGui)
	local f                      = Instance.new("Frame")
	f.Name                       = "WorkshopTooltip"
	f.Size                       = UDim2.fromOffset(310, 112)
	f.BackgroundColor3           = Color3.fromRGB(10, 15, 30)
	f.BackgroundTransparency     = 0.04
	f.BorderSizePixel            = 0
	f.ZIndex                     = 30
	f.Visible                    = false
	f.Parent                     = sg
	UILib.corner(f, 8)
	UILib.stroke(f, C.ACCENT, 1.5)

	local stripe                 = Instance.new("Frame")
	stripe.Size                  = UDim2.new(0, 4, 1, -20)
	stripe.Position              = UDim2.fromOffset(9, 10)
	stripe.BackgroundColor3      = C.ACCENT
	stripe.BorderSizePixel       = 0
	stripe.ZIndex                = 31
	stripe.Parent                = f
	UILib.corner(stripe, 3)

	local title                  = Instance.new("TextLabel")
	title.Name                   = "TipTitle"
	title.Size                   = UDim2.new(1, -30, 0, 26)
	title.Position               = UDim2.fromOffset(22, 10)
	title.BackgroundTransparency = 1
	title.Font                   = Enum.Font.GothamBold
	title.TextSize               = 17
	title.TextColor3             = C.TEXT
	title.TextXAlignment         = Enum.TextXAlignment.Left
	title.Text                   = ""
	title.ZIndex                 = 31
	title.Parent                 = f

	local cost                   = Instance.new("TextLabel")
	cost.Name                    = "TipCost"
	cost.Size                    = UDim2.new(1, -30, 0, 20)
	cost.Position                = UDim2.fromOffset(22, 37)
	cost.BackgroundTransparency  = 1
	cost.Font                    = Enum.Font.GothamBold
	cost.TextSize                = 14
	cost.TextColor3              = C.GOLD
	cost.TextXAlignment          = Enum.TextXAlignment.Left
	cost.Text                    = ""
	cost.ZIndex                  = 31
	cost.Parent                  = f

	local sep                    = Instance.new("Frame")
	sep.Size                     = UDim2.new(1, -30, 0, 1)
	sep.Position                 = UDim2.fromOffset(22, 61)
	sep.BackgroundColor3         = C.SEP
	sep.BorderSizePixel          = 0
	sep.ZIndex                   = 31
	sep.Parent                   = f

	local body                   = Instance.new("TextLabel")
	body.Name                    = "TipBody"
	body.Size                    = UDim2.new(1, -30, 0, 40)
	body.Position                = UDim2.fromOffset(22, 67)
	body.BackgroundTransparency  = 1
	body.Font                    = Enum.Font.Gotham
	body.TextSize                = 14
	body.TextColor3              = C.SUBTEXT
	body.TextXAlignment          = Enum.TextXAlignment.Left
	body.TextYAlignment          = Enum.TextYAlignment.Top
	body.TextWrapped             = true
	body.Text                    = ""
	body.ZIndex                  = 31
	body.Parent                  = f

	ttFrame = f ; ttTitle = title ; ttCost = cost ; ttBody = body
end

local TT_W = 310
local TT_H = 112

local function positionTooltipAtMouse()
	local f = ttFrame ; local sg = screenGui
	if not f or not sg then return end
	local mouse = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	local sh    = sg.AbsoluteSize.Y
	local mx    = mouse.X - inset.X - TT_W - 12
	local my    = mouse.Y - inset.Y + 4
	if mx < 4 then mx = mouse.X - inset.X + 16 end
	if my + TT_H > sh - 4 then my = sh - TT_H - 4 end
	f.Position = UDim2.fromOffset(mx, my)
end

local function showTooltip(name: string, costLine: string, body: string)
	if not ttFrame or not ttTitle or not ttCost or not ttBody then return end
	ttTitle.Text = name ; ttCost.Text = costLine ; ttBody.Text = body
	positionTooltipAtMouse()
	ttFrame.Visible = true
end

local function hideTooltip()
	if ttFrame then ttFrame.Visible = false end
end

-- ── Progress bar ──────────────────────────────────────────────────────────────
local function makeProgressBar(parent: Instance, zi: number): (Frame, Frame)
	local track                  = Instance.new("Frame")
	track.Name                   = "ProgressTrack"
	track.Size                   = UDim2.new(1, -14, 0, 7)
	track.Position               = UDim2.new(0, 7, 1, -14)
	track.BackgroundColor3       = Color3.fromRGB(5, 8, 18)
	track.BackgroundTransparency = 0.1
	track.BorderSizePixel        = 0
	track.ZIndex                 = zi
	track.Visible                = false
	track.ClipsDescendants       = true
	track.Parent                 = parent
	UILib.corner(track, 3)

	local fill                   = Instance.new("Frame")
	fill.Name                    = "Fill"
	fill.Size                    = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3        = C.ACCENT
	fill.BorderSizePixel         = 0
	fill.ZIndex                  = zi + 1
	fill.Parent                  = track
	UILib.corner(fill, 3)

	return track, fill
end

-- ── State application ─────────────────────────────────────────────────────────
local function applyState(ref: NodeRef, state: string)
	ref.btn.BackgroundColor3       = STATE_BG[state]
	ref.btn.BackgroundTransparency = STATE_TRANSP[state]
	ref.stroke.Color               = STATE_STROKE[state]
	ref.label.TextColor3           = STATE_TEXT[state]
end

-- ── Node refresh ──────────────────────────────────────────────────────────────
local function refreshTechNode(key: string)
	local ref  = nodeRefs[key]
	local tech = TECH_DATA[key]
	if not ref or not tech then return end

	local done     = getResearchedFn and getResearchedFn(key) or false
	local progress = getProgressFn   and getProgressFn(key)   or nil
	local inProg   = progress ~= nil and not done

	local siblingKey   = MUTEX_SIBLING[key]
	local siblingTaken = siblingKey ~= nil
		and ((getResearchedFn and getResearchedFn(siblingKey))
		     or (getProgressFn and getProgressFn(siblingKey) ~= nil))

	if done then
		applyState(ref, "DONE")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n✓ Done"
		ref.btn.Active        = false
		ref.progTrack.Visible = false
	elseif inProg then
		local pct = math.floor((progress :: number) * 100)
		applyState(ref, "IN_PROGRESS")
		ref.stroke.Thickness          = 4
		ref.label.Text                = tech.name .. "\n" .. pct .. "%"
		ref.btn.Active                = false
		ref.progTrack.Visible         = true
		ref.progFill.Size             = UDim2.new(progress :: number, 0, 1, 0)
		ref.progFill.BackgroundColor3 = C.ACCENT
	elseif siblingTaken then
		applyState(ref, "CANT_AFFORD")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n⊘ Locked"
		ref.btn.Active        = false
		ref.progTrack.Visible = false
	else
		applyState(ref, "AVAILABLE")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n⏱ " .. tech.time .. "s"
		ref.btn.Active        = true
		ref.progTrack.Visible = false
	end
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

-- ── Tier-2 drip-feed reveal / hide ───────────────────────────────────────────
local function revealTier2(key: string)
	local tn  = techNodes[key]
	local ref = nodeRefs[key]
	if not tn or not ref or ref.wrapper.Visible then return end

	ref.wrapper.Visible                 = true
	ref.wrapper.Position                = tn.startPos
	ref.btn.BackgroundTransparency      = 1
	tn.connector.BackgroundTransparency = 1

	TweenService:Create(ref.wrapper,  REVEAL_TI, { Position = tn.pos }):Play()
	TweenService:Create(ref.btn,      REVEAL_TI, { BackgroundTransparency = STATE_TRANSP["AVAILABLE"] }):Play()
	TweenService:Create(tn.connector, REVEAL_TI, { BackgroundTransparency = 0.65 }):Play()
end

local function hideTier2Instant(key: string)
	local tn  = techNodes[key]
	local ref = nodeRefs[key]
	if not tn or not ref then return end
	ref.wrapper.Visible                 = false
	ref.wrapper.Position                = tn.startPos
	ref.btn.BackgroundTransparency      = 1
	tn.connector.BackgroundTransparency = 1
end

-- ── Global refresh ────────────────────────────────────────────────────────────
local function refresh()
	if not activeCCId then return end
	for key in TECH_DATA do refreshTechNode(key) end
	refreshMonumentNode()
	for t2key, t1key in TIER2_PARENT do
		local rootKey = TIER1_ROOT[t1key]
		local root    = roots[rootKey]
		if root and root.isOpen then
			local parentDone = getResearchedFn and getResearchedFn(t1key) or false
			if parentDone then
				local ref = nodeRefs[t2key]
				if ref and not ref.wrapper.Visible then revealTier2(t2key) end
			end
		end
	end
end

-- ── Expand / collapse roots ───────────────────────────────────────────────────
local function expandRoot(rootKey: string)
	local root = roots[rootKey]
	if not root or root.isOpen then return end
	root.isOpen = true
	TweenService:Create(root.stroke, TweenInfo.new(0.15), { Thickness = 4 }):Play()

	for _, t1key in root.tier1Keys do
		local tn  = techNodes[t1key]
		local ref = nodeRefs[t1key]
		if not tn or not ref then continue end

		ref.wrapper.Visible                 = true
		ref.wrapper.Position                = tn.startPos
		ref.btn.BackgroundTransparency      = 1
		tn.connector.BackgroundTransparency = 1

		TweenService:Create(ref.wrapper,  EXPAND_TI, { Position = tn.pos }):Play()
		TweenService:Create(ref.btn,      EXPAND_TI, { BackgroundTransparency = STATE_TRANSP["AVAILABLE"] }):Play()
		TweenService:Create(tn.connector, EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()

		local parentDone = getResearchedFn and getResearchedFn(t1key) or false
		if parentDone then
			for t2key, parentKey in TIER2_PARENT do
				if parentKey == t1key then
					task.delay(EXPAND_TI.Time * 0.6, function() revealTier2(t2key) end)
				end
			end
		end
	end
end

local function collapseRoot(rootKey: string)
	local root = roots[rootKey]
	if not root or not root.isOpen then return end
	root.isOpen = false
	hideTooltip()
	TweenService:Create(root.stroke, TweenInfo.new(0.15), { Thickness = 2 }):Play()

	for t2key, t1key in TIER2_PARENT do
		if TIER1_ROOT[t1key] == rootKey then hideTier2Instant(t2key) end
	end

	for _, t1key in root.tier1Keys do
		local tn  = techNodes[t1key]
		local ref = nodeRefs[t1key]
		if not tn or not ref then continue end
		TweenService:Create(ref.wrapper,  COLLAPSE_TI, { Position = tn.startPos }):Play()
		TweenService:Create(ref.btn,      COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(tn.connector, COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		if root.isOpen then return end
		for _, t1key in root.tier1Keys do
			local ref = nodeRefs[t1key]
			if ref then ref.wrapper.Visible = false end
		end
	end)
end

local function resetAllRoots()
	hideTooltip()
	for rootKey, root in roots do
		root.isOpen           = false
		root.stroke.Thickness = 2
		for _, t1key in root.tier1Keys do
			local tn  = techNodes[t1key]
			local ref = nodeRefs[t1key]
			if tn and ref then
				ref.wrapper.Visible                 = false
				ref.wrapper.Position                = tn.startPos
				ref.btn.BackgroundTransparency      = 1
				tn.connector.BackgroundTransparency = 1
			end
		end
		for t2key, t1key in TIER2_PARENT do
			if TIER1_ROOT[t1key] == rootKey then hideTier2Instant(t2key) end
		end
	end
end

-- ── Build a researchable tech node ────────────────────────────────────────────
local function buildTechNode(
	parent  : Frame,
	key     : string,
	pos     : UDim2,
	startPos: UDim2,
	zi      : number
)
	local tech = TECH_DATA[key]
	if not tech then return end

	local connector = UILib.connectorLineBetween(parent, startPos, pos, zi - 1)
	connector.BackgroundTransparency = 1

	local wrapper, btn = UILib.radialNode(parent, key, tech.icon, STATE_BG["AVAILABLE"], pos, nil, zi)
	wrapper.Visible = false

	local label = wrapper:FindFirstChild("NodeLabel") :: TextLabel
	label.Size     = UDim2.fromOffset(NODE_D + 52, 60)
	label.TextSize = 18

	local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	stroke.Color = STATE_STROKE["AVAILABLE"]

	local barTrack, barFill = makeProgressBar(btn, zi + 2)

	nodeRefs[key] = {
		btn       = btn,
		stroke    = stroke,
		label     = label,
		progTrack = barTrack,
		progFill  = barFill,
		wrapper   = wrapper,
	}
	techNodes[key] = { pos = pos, startPos = startPos, connector = connector }

	local tipCost = "⏱ " .. tech.time .. " seconds"
	btn.MouseEnter:Connect(function() showTooltip(tech.name, tipCost, tech.tip) end)
	btn.MouseMoved:Connect(positionTooltipAtMouse)
	btn.MouseLeave:Connect(hideTooltip)

	btn.MouseButton1Click:Connect(function()
		if not activeCCId or not btn.Active then return end
		for k in TECH_DATA do
			if getProgressFn and getProgressFn(k) ~= nil then
				if showNotificationFn then
					showNotificationFn("⚗ Only one research at a time.", C.ACCENT)
				end
				return
			end
		end
		networkRef.startResearch(activeCCId, key)
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function WorkshopPanel.init(
	network         : any,
	getResearched   : (string) -> boolean,
	getProgress     : (string) -> number?,
	getResources    : (() -> number)?,
	showNotification: ((string, Color3?) -> ())?
)
	networkRef         = network
	getResearchedFn    = getResearched
	getProgressFn      = getProgress
	getResourcesFn     = getResources
	showNotificationFn = showNotification

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui
	screenGui = sg

	local ov                  = Instance.new("Frame")
	ov.Name                   = "WorkshopOverlay"
	ov.Size                   = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency = 1
	ov.BorderSizePixel        = 0
	ov.ZIndex                 = 10
	ov.Visible                = false
	ov.Parent                 = sg
	overlay = ov

	-- Calculate all node positions
	local layout = calculateLayout()

	local function cp(key: string): UDim2
		local p = layout[key]
		return UDim2.new(0.5, p.x, 0.5, p.y)
	end

	-- ── Root category nodes (data-driven) ───────────────────────────────────
	for _, rootDef in ROOT_DEFS do
		local _w, btn = UILib.radialNode(ov, rootDef.key, rootDef.icon,
			rootDef.color, cp(rootDef.key), nil, 12)
		;(_w:FindFirstChild("NodeLabel") :: TextLabel).TextSize = 18

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke

		roots[rootDef.key] = {
			btn       = btn,
			stroke    = stroke,
			isOpen    = false,
			tier1Keys = rootDef.tier1Keys,
		}

		local key = rootDef.key
		btn.MouseButton1Click:Connect(function()
			if roots[key].isOpen then collapseRoot(key) else expandRoot(key) end
		end)
	end

	-- ── Monument node ────────────────────────────────────────────────────────
	local _mw, monBtn = UILib.radialNode(ov, "Monument", "★", C.GOLD, cp("Monument"), nil, 12)
	local monStroke   = monBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local monLabel    = _mw:FindFirstChild("NodeLabel")           :: TextLabel
	monLabel.Size     = UDim2.fromOffset(NODE_D + 52, 60)
	monLabel.TextSize = 18

	local monBarTrack, monBarFill = makeProgressBar(monBtn, 14)
	monBarFill.BackgroundColor3   = C.GOLD

	nodeRefs["Monument"] = {
		btn       = monBtn,
		stroke    = monStroke,
		label     = monLabel,
		progTrack = monBarTrack,
		progFill  = monBarFill,
		wrapper   = _mw,
	}

	monBtn.MouseEnter:Connect(function()
		showTooltip("Monument", "💰 1 500 resources", "Defend 5 min to win")
	end)
	monBtn.MouseMoved:Connect(positionTooltipAtMouse)
	monBtn.MouseLeave:Connect(hideTooltip)
	monBtn.MouseButton1Click:Connect(function()
		if not activeCCId or not monBtn.Active then return end
		networkRef.buildMonument()
	end)

	-- ── Tier-1 nodes (data-driven) ───────────────────────────────────────────
	for _, rootDef in ROOT_DEFS do
		for _, t1key in rootDef.tier1Keys do
			buildTechNode(ov, t1key, cp(t1key), cp(rootDef.key), 13)
		end
	end

	-- ── Tier-2 nodes (data-driven) ───────────────────────────────────────────
	for t2key, t1key in TIER2_PARENT do
		buildTechNode(ov, t2key, cp(t2key), cp(t1key), 14)
	end

	buildTooltip(sg)

	local blur     = Instance.new("BlurEffect")
	blur.Name      = "WorkshopBlur"
	blur.Size      = 0
	blur.Enabled   = false
	blur.Parent    = Lighting
	workshopBlur   = blur
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	resetAllRoots()
	if overlay then overlay.Visible = true end
	if workshopBlur then
		workshopBlur.Enabled = true
		workshopBlur.Size    = 0
		TweenService:Create(workshopBlur,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = 22 }):Play()
	end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if overlay then overlay.Visible = false end
	resetAllRoots()
	if workshopBlur then
		local b = workshopBlur
		TweenService:Create(b,
			TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Size = 0 }):Play()
		task.delay(0.22, function()
			if b.Parent then b.Enabled = false end
		end)
	end
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
