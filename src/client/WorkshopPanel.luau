--!strict
--[[
    WorkshopPanel — Left-to-right drip-feed tech tree.

    Columns (X offset from screen centre):
      Col 0  x = -420  root category buttons  (Units, Structures, Monument)
      Col 1  x = -210  tier-1 researchable techs   — revealed on root click
      Col 2  x =    0  tier-2 techs                — revealed when tier-1 parent DONE

    Units root → 3 tier-1 branches:
      CombatStims      → HardenedArmor
      ConcussionShells → RocketBarrage
      MedicUnit        → EliteUnits

    Structures root → 2 tier-1 branches:
      BetterMines   (no tier-2)
      TurretUpgrades (no tier-2)

    Monument — standalone root node (no children, builds a win-condition structure).

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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C

-- ── Layout constants ──────────────────────────────────────────────────────────
local NODE_D  = UILib.NODE_D   -- 80 px diameter

local COL0_X = -420   -- root category column
local COL1_X = -210   -- tier-1 tech column
local COL2_X =    0   -- tier-2 tech column

-- Root node Y offsets from screen centre
local UNITS_ROOT_Y   = -150
local STRUCTS_ROOT_Y =  165
local MONUMENT_Y     =  335

-- Tier-1 Y positions (Units branch)
local Y_COMBAT  = -260   -- CombatStims
local Y_CONC    = -150   -- ConcussionShells
local Y_MEDIC   =  -40   -- MedicUnit

-- Tier-1 Y positions (Structures branch)
local Y_MINES   =  110   -- BetterMines
local Y_TURRET  =  220   -- TurretUpgrades

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


-- ── Tech data ─────────────────────────────────────────────────────────────────
local TECH_DATA: { [string]: { name: string, icon: string, time: number, tip: string } } = {
	CombatStims = {
		name = "Combat Stims", icon = "⚡", time = 12,
		tip  = "Soldiers gain +50% speed and faster attacks for 8 s after engaging an enemy.",
	},
	HardenedArmor = {
		name = "Hardened Armor", icon = "🛡", time = 10,
		tip  = "Soldiers absorb a flat 6 damage per incoming hit.",
	},
	ConcussionShells = {
		name = "Concussion Shells", icon = "◈", time = 10,
		tip  = "Tank shells slow all hit enemies to 40% speed for 1.5 s.",
	},
	RocketBarrage = {
		name = "Rocket Barrage", icon = "🚀", time = 18,
		tip  = "Replaces tank attacks with 3 spiraling AoE rockets, each dealing 65% base damage.",
	},
	MedicUnit = {
		name = "Medic Unit", icon = "✚", time = 15,
		tip  = "Unlocks Medic units that automatically heal the most-injured nearby ally (60 res each).",
	},
	EliteUnits = {
		name = "Elite Units", icon = "⚔", time = 15,
		tip  = "Unlocks Elite units with long range and high damage (100 res each).",
	},
	BetterMines = {
		name = "Better Mines", icon = "⛏", time = 5,
		tip  = "Unlocks Efficiency (×2 income) and Capacity (+4 slots) upgrade paths on your mines.",
	},
	TurretUpgrades = {
		name = "Turret Upgrades", icon = "⚙", time = 20,
		tip  = "Unlocks Flamethrower and Rocket Launcher upgrade paths for each turret.",
	},
}

-- Tier-2 key → its tier-1 parent key (drip-feed gating)
local TIER2_PARENT: { [string]: string } = {
	HardenedArmor = "CombatStims",
	RocketBarrage  = "ConcussionShells",
	EliteUnits     = "MedicUnit",
}

-- Tier-1 key → root category key
local TIER1_ROOT: { [string]: string } = {
	CombatStims      = "Units",
	ConcussionShells = "Units",
	MedicUnit        = "Units",
	BetterMines      = "Structures",
	TurretUpgrades   = "Structures",
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

-- Per-tech layout data (set during init)
type TechNode = {
	pos      : UDim2,   -- final resting position
	startPos : UDim2,   -- slide-in origin (parent position)
	connector: Frame,   -- line from parent to this node
}
local techNodes: { [string]: TechNode } = {}

-- Root category tracking
type RootInfo = {
	btn      : TextButton,
	stroke   : UIStroke,
	isOpen   : boolean,
	tier1Keys: { string },
}
local roots: { [string]: RootInfo } = {}

-- ── Tween constants ───────────────────────────────────────────────────────────
local EXPAND_TI  = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local REVEAL_TI  = TweenInfo.new(0.30, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)

-- ── Tooltip ───────────────────────────────────────────────────────────────────
local ttFrame: Frame?
local ttTitle: TextLabel?
local ttCost : TextLabel?
local ttBody : TextLabel?

local function buildTooltip(sg: ScreenGui)
	local f                      = Instance.new("Frame")
	f.Name                       = "WorkshopTooltip"
	f.Size                       = UDim2.fromOffset(272, 200)
	f.Position                   = UDim2.fromOffset(0, 0)
	f.BackgroundColor3           = Color3.fromRGB(8, 11, 22)
	f.BackgroundTransparency     = 0.06
	f.BorderSizePixel            = 0
	f.ZIndex                     = 30
	f.Visible                    = false
	f.Parent                     = sg
	UILib.corner(f, 10)
	UILib.stroke(f, C.BORDER, 1.5)

	local accent                 = Instance.new("Frame")
	accent.Size                  = UDim2.new(1, -2, 0, 3)
	accent.Position              = UDim2.fromOffset(1, 1)
	accent.BackgroundColor3      = C.ACCENT
	accent.BorderSizePixel       = 0
	accent.ZIndex                = 31
	accent.Parent                = f
	UILib.corner(accent, 8)

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

	local sep                    = Instance.new("Frame")
	sep.Size                     = UDim2.new(1, -20, 0, 1)
	sep.Position                 = UDim2.fromOffset(10, 55)
	sep.BackgroundColor3         = C.SEP
	sep.BorderSizePixel          = 0
	sep.ZIndex                   = 31
	sep.Parent                   = f

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

	ttFrame = f ; ttTitle = title ; ttCost = cost ; ttBody = body
end

local TT_W = 272   -- matches buildTooltip UDim2.fromOffset(272, 200)
local TT_H = 200

local function positionTooltipAtMouse()
	local f = ttFrame ; local sg = screenGui
	if not f or not sg then return end
	local mouse = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	local sh = sg.AbsoluteSize.Y

	-- Left of cursor (Minecraft-style); use fixed size to avoid AbsoluteSize = 0 on first frame
	local mx = mouse.X - inset.X - TT_W - 12
	local my = mouse.Y - inset.Y + 4
	if mx < 4 then mx = mouse.X - inset.X + 16 end               -- flip right if off left edge
	if my + TT_H > sh - 4 then my = sh - TT_H - 4 end            -- clamp bottom

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
	local track                      = Instance.new("Frame")
	track.Name                       = "ProgressTrack"
	track.Size                       = UDim2.new(1, -14, 0, 7)
	track.Position                   = UDim2.new(0, 7, 1, -14)
	track.BackgroundColor3           = Color3.fromRGB(5, 8, 18)
	track.BackgroundTransparency     = 0.1
	track.BorderSizePixel            = 0
	track.ZIndex                     = zi
	track.Visible                    = false
	track.ClipsDescendants           = true
	track.Parent                     = parent
	UILib.corner(track, 3)

	local fill                       = Instance.new("Frame")
	fill.Name                        = "Fill"
	fill.Size                        = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3            = C.ACCENT
	fill.BorderSizePixel             = 0
	fill.ZIndex                      = zi + 1
	fill.Parent                      = track
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

	if done then
		applyState(ref, "DONE")
		ref.stroke.Thickness  = 2
		ref.label.Text        = tech.name .. "\n✓ Done"
		ref.btn.Active        = false
		ref.progTrack.Visible = false
	elseif inProg then
		local pct = math.floor((progress :: number) * 100)
		applyState(ref, "IN_PROGRESS")
		ref.stroke.Thickness        = 4
		ref.label.Text              = tech.name .. "\n" .. pct .. "%"
		ref.btn.Active              = false
		ref.progTrack.Visible       = true
		ref.progFill.Size           = UDim2.new(progress :: number, 0, 1, 0)
		ref.progFill.BackgroundColor3 = C.ACCENT
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

	ref.wrapper.Visible                = true
	ref.wrapper.Position               = tn.startPos
	ref.btn.BackgroundTransparency     = 1
	tn.connector.BackgroundTransparency = 1

	TweenService:Create(ref.wrapper,  REVEAL_TI, { Position = tn.pos }):Play()
	TweenService:Create(ref.btn,      REVEAL_TI, { BackgroundTransparency = STATE_TRANSP["AVAILABLE"] }):Play()
	TweenService:Create(tn.connector, REVEAL_TI, { BackgroundTransparency = 0.65 }):Play()
end

local function hideTier2Instant(key: string)
	local tn  = techNodes[key]
	local ref = nodeRefs[key]
	if not tn or not ref then return end
	ref.wrapper.Visible                = false
	ref.wrapper.Position               = tn.startPos
	ref.btn.BackgroundTransparency     = 1
	tn.connector.BackgroundTransparency = 1
end

-- ── Global refresh ────────────────────────────────────────────────────────────
local function refresh()
	if not activeCCId then return end

	for key in TECH_DATA do
		refreshTechNode(key)
	end
	refreshMonumentNode()

	-- Drip-feed: reveal tier-2 nodes whose tier-1 parent is DONE (and root is open)
	for t2key, t1key in TIER2_PARENT do
		local rootKey = TIER1_ROOT[t1key]
		local root    = roots[rootKey]
		if root and root.isOpen then
			local parentDone = getResearchedFn and getResearchedFn(t1key) or false
			if parentDone then
				local ref = nodeRefs[t2key]
				if ref and not ref.wrapper.Visible then
					revealTier2(t2key)
				end
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

		ref.wrapper.Visible                = true
		ref.wrapper.Position               = tn.startPos
		ref.btn.BackgroundTransparency     = 1
		tn.connector.BackgroundTransparency = 1

		TweenService:Create(ref.wrapper,  EXPAND_TI, { Position = tn.pos }):Play()
		TweenService:Create(ref.btn,      EXPAND_TI, { BackgroundTransparency = STATE_TRANSP["AVAILABLE"] }):Play()
		TweenService:Create(tn.connector, EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()

		-- If this tier-1 is already done, reveal its tier-2 child after a short lag
		local parentDone = getResearchedFn and getResearchedFn(t1key) or false
		if parentDone then
			for t2key, parentKey in TIER2_PARENT do
				if parentKey == t1key then
					task.delay(EXPAND_TI.Time * 0.6, function()
						revealTier2(t2key)
					end)
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

	-- Instantly hide tier-2 nodes before tier-1 animates out
	for t2key, t1key in TIER2_PARENT do
		if TIER1_ROOT[t1key] == rootKey then
			hideTier2Instant(t2key)
		end
	end

	-- Animate tier-1 back to root position
	for _, t1key in root.tier1Keys do
		local tn  = techNodes[t1key]
		local ref = nodeRefs[t1key]
		if not tn or not ref then continue end

		TweenService:Create(ref.wrapper,  COLLAPSE_TI, { Position = tn.startPos }):Play()
		TweenService:Create(ref.btn,      COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(tn.connector, COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		if root.isOpen then return end  -- re-opened during the tween
		for _, t1key in root.tier1Keys do
			local ref = nodeRefs[t1key]
			if ref then ref.wrapper.Visible = false end
		end
	end)
end

local function resetAllRoots()
	hideTooltip()
	for rootKey, root in roots do
		root.isOpen       = false
		root.stroke.Thickness = 2

		for _, t1key in root.tier1Keys do
			local tn  = techNodes[t1key]
			local ref = nodeRefs[t1key]
			if tn and ref then
				ref.wrapper.Visible                = false
				ref.wrapper.Position               = tn.startPos
				ref.btn.BackgroundTransparency     = 1
				tn.connector.BackgroundTransparency = 1
			end
		end

		for t2key, t1key in TIER2_PARENT do
			if TIER1_ROOT[t1key] == rootKey then
				hideTier2Instant(t2key)
			end
		end
	end
end

-- ── Build a researchable tech node ────────────────────────────────────────────
local function buildTechNode(
	parent  : Frame,
	key     : string,
	pos     : UDim2,   -- final position
	startPos: UDim2,   -- slide animation origin (= parent node position)
	zi      : number
)
	local tech = TECH_DATA[key]
	if not tech then return end

	-- Connector line from parent to this node (starts invisible)
	local connector = UILib.connectorLineBetween(parent, startPos, pos, zi - 1)
	connector.BackgroundTransparency = 1

	-- Circular node
	local wrapper, btn = UILib.radialNode(parent, key, tech.icon, STATE_BG["AVAILABLE"], pos, nil, zi)
	wrapper.Visible = false

	local label = wrapper:FindFirstChild("NodeLabel") :: TextLabel
	label.Size  = UDim2.fromOffset(NODE_D + 40, 52)

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
	techNodes[key] = {
		pos       = pos,
		startPos  = startPos,
		connector = connector,
	}

	-- Tooltip
	local tipCost = "⏱ " .. tech.time .. " seconds"
	btn.MouseEnter:Connect(function() showTooltip(tech.name, tipCost, tech.tip) end)
	btn.MouseMoved:Connect(positionTooltipAtMouse)
	btn.MouseLeave:Connect(hideTooltip)

	-- Research click — enforce one research at a time
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

	local ov                      = Instance.new("Frame")
	ov.Name                       = "WorkshopOverlay"
	ov.Size                       = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency     = 1
	ov.BorderSizePixel            = 0
	ov.ZIndex                     = 10
	ov.Visible                    = false
	ov.Parent                     = sg
	overlay = ov

	-- Shorthand: UDim2 offset from screen centre
	local function cp(x: number, y: number): UDim2
		return UDim2.new(0.5, x, 0.5, y)
	end

	-- ── Root category positions ─────────────────────────────────────────────
	local unitsPos   = cp(COL0_X, UNITS_ROOT_Y)
	local structsPos = cp(COL0_X, STRUCTS_ROOT_Y)
	local monPos     = cp(COL0_X, MONUMENT_Y)

	-- ── Root category nodes (expand/collapse only, not researchable) ────────
	local _uw, unitsBtn  = UILib.radialNode(ov, "Units",      "⚔", C.ACCENT, unitsPos,   nil, 12)
	local _sw, structBtn = UILib.radialNode(ov, "Structures", "⚒", C.ACCENT, structsPos, nil, 12)
	local _mw, monBtn    = UILib.radialNode(ov, "Monument",   "★", C.GOLD,   monPos,     nil, 12)

	local unitsStroke  = unitsBtn:FindFirstChildWhichIsA("UIStroke")  :: UIStroke
	local structStroke = structBtn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local monStroke    = monBtn:FindFirstChildWhichIsA("UIStroke")    :: UIStroke
	local monLabel     = _mw:FindFirstChild("NodeLabel")              :: TextLabel
	monLabel.Size      = UDim2.fromOffset(NODE_D + 40, 52)

	-- Monument progress bar
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
		showTooltip("Monument", "💰 1 500 resources",
			"Rises from your Command Center.\nDefend it for 5 minutes to win.\n\nVisible to all players — 3 000 HP.")
	end)
	monBtn.MouseMoved:Connect(positionTooltipAtMouse)
	monBtn.MouseLeave:Connect(hideTooltip)
	monBtn.MouseButton1Click:Connect(function()
		if not activeCCId or not monBtn.Active then return end
		networkRef.buildMonument()
	end)

	-- ── Units tier-1 nodes ──────────────────────────────────────────────────
	-- All slide out from the Units root position
	buildTechNode(ov, "CombatStims",      cp(COL1_X, Y_COMBAT), unitsPos, 13)
	buildTechNode(ov, "ConcussionShells", cp(COL1_X, Y_CONC),   unitsPos, 13)
	buildTechNode(ov, "MedicUnit",        cp(COL1_X, Y_MEDIC),  unitsPos, 13)

	-- ── Units tier-2 nodes ──────────────────────────────────────────────────
	-- Hidden until their tier-1 parent is DONE; slide out from tier-1 position
	buildTechNode(ov, "HardenedArmor", cp(COL2_X, Y_COMBAT), cp(COL1_X, Y_COMBAT), 14)
	buildTechNode(ov, "RocketBarrage", cp(COL2_X, Y_CONC),   cp(COL1_X, Y_CONC),   14)
	buildTechNode(ov, "EliteUnits",    cp(COL2_X, Y_MEDIC),  cp(COL1_X, Y_MEDIC),  14)

	-- ── Structures tier-1 nodes ─────────────────────────────────────────────
	buildTechNode(ov, "BetterMines",    cp(COL1_X, Y_MINES),  structsPos, 13)
	buildTechNode(ov, "TurretUpgrades", cp(COL1_X, Y_TURRET), structsPos, 13)

	-- ── Register roots ──────────────────────────────────────────────────────
	roots["Units"] = {
		btn       = unitsBtn,
		stroke    = unitsStroke,
		isOpen    = false,
		tier1Keys = { "CombatStims", "ConcussionShells", "MedicUnit" },
	}
	roots["Structures"] = {
		btn       = structBtn,
		stroke    = structStroke,
		isOpen    = false,
		tier1Keys = { "BetterMines", "TurretUpgrades" },
	}

	-- ── Root click handlers ─────────────────────────────────────────────────
	unitsBtn.MouseButton1Click:Connect(function()
		if roots["Units"].isOpen then collapseRoot("Units")
		else expandRoot("Units") end
	end)
	structBtn.MouseButton1Click:Connect(function()
		if roots["Structures"].isOpen then collapseRoot("Structures")
		else expandRoot("Structures") end
	end)

	buildTooltip(sg)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	resetAllRoots()
	if overlay then overlay.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if overlay then overlay.Visible = false end
	resetAllRoots()
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
