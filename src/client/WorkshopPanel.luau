local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel   = {}
local localPlayer     = Players.LocalPlayer
local C               = UILib.C

-- ── Palette additions ─────────────────────────────────────────────────────────
local PURPLE   = Color3.fromRGB(160, 80, 230)
local DARK_BG  = Color3.fromRGB(8, 11, 22)
local CARD_BG  = Color3.fromRGB(12, 17, 32)
local SEC_LBL  = Color3.fromRGB(80, 110, 160)

-- ── Module state ──────────────────────────────────────────────────────────────
local panel:           Frame?
local activeCCId:      string?  = nil
local networkRef:      any
local getResearchedFn: ((string) -> boolean)?
local getProgressFn:   ((string) -> number?)?
local getResourcesFn:  (() -> number)?

-- nil = no monument; -1 = constructing; >0 = seconds remaining
local localMonumentTime: number? = nil

type CardRefs = {
	root:      TextButton,
	stroke:    UIStroke,
	nameLbl:   TextLabel,
	statusLbl: TextLabel,
	progFill:  Frame,
	progTrack: Frame,
}
local cardRefs: { [string]: CardRefs } = {}

-- Monument refs
local monRoot:   TextButton?
local monRight:  Frame?       -- right info panel
local monBigLbl: TextLabel?   -- large number / timer
local monSmLbl:  TextLabel?   -- "resources" / "remaining" sub-label
local monFill:   Frame?
local monTrack:  Frame?

-- Tooltip refs (single floating tooltip, content swapped on hover)
local ttFrame:  Frame?
local ttTitle:  TextLabel?
local ttBody:   TextLabel?

-- ── Tech definitions ──────────────────────────────────────────────────────────
local TECHS: {
	{
		key:   string,
		name:  string,
		icon:  string,
		color: Color3,
		short: string,
		tip:   string,
	}
} = {
	{
		key   = "BetterMines",
		name  = "Better Mines",
		icon  = "⛏",
		color = C.TEAL,
		short = "Enables upgrades on mine buildings.",
		tip   = "Unlocks the Upgrade button on each mine.\n\nEfficiency  ×2 income per miner\nCapacity  +4 extra miner slots\n\nBoth upgrades are mutually exclusive per mine.\n\n⏱  5 sec",
	},
	{
		key   = "EliteUnits",
		name  = "Elite Units",
		icon  = "⚔",
		color = PURPLE,
		short = "Unlocks Elite unit at Barracks.",
		tip   = "Trains Elite units at your Barracks.\n\nLong attack range, high damage, and unique spider-leg movement. Ideal counter to turret-heavy defenses.\n\nCost per unit: 100 res\n\n⏱  15 sec",
	},
}

-- ── Tooltip ───────────────────────────────────────────────────────────────────

local function buildTooltip(sg: ScreenGui)
	local f                  = Instance.new("Frame")
	f.Name                   = "WorkshopTooltip"
	-- Sits to the LEFT of the panel (panel is at 0.5 - 210; tooltip right edge at 0.5 - 220)
	f.Size                   = UDim2.fromOffset(196, 170)
	f.Position               = UDim2.new(0.5, -428, 1, -468)
	f.BackgroundColor3       = DARK_BG
	f.BackgroundTransparency = 0.06
	f.BorderSizePixel        = 0
	f.ZIndex                 = 30
	f.Visible                = false
	f.Parent                 = sg
	UILib.corner(f, 10)
	UILib.stroke(f, C.BORDER, 1.5)

	-- Accent bar at top
	local accent             = Instance.new("Frame")
	accent.Size              = UDim2.new(1, -2, 0, 3)
	accent.Position          = UDim2.fromOffset(1, 1)
	accent.BackgroundColor3  = C.ACCENT
	accent.BorderSizePixel   = 0
	accent.ZIndex            = 31
	accent.Parent            = f
	UILib.corner(accent, 8)

	local title              = Instance.new("TextLabel")
	title.Name               = "Title"
	title.Size               = UDim2.new(1, -16, 0, 20)
	title.Position           = UDim2.fromOffset(8, 12)
	title.BackgroundTransparency = 1
	title.Font               = Enum.Font.GothamBold
	title.TextSize           = 13
	title.TextColor3         = C.TEXT
	title.TextXAlignment     = Enum.TextXAlignment.Left
	title.Text               = ""
	title.ZIndex             = 31
	title.Parent             = f

	-- Separator under title
	local sep                = Instance.new("Frame")
	sep.Size                 = UDim2.new(1, -16, 0, 1)
	sep.Position             = UDim2.fromOffset(8, 34)
	sep.BackgroundColor3     = C.SEP
	sep.BorderSizePixel      = 0
	sep.ZIndex               = 31
	sep.Parent               = f

	local body               = Instance.new("TextLabel")
	body.Name                = "Body"
	body.Size                = UDim2.new(1, -16, 1, -44)
	body.Position            = UDim2.fromOffset(8, 40)
	body.BackgroundTransparency = 1
	body.Font                = Enum.Font.Gotham
	body.TextSize            = 11
	body.TextColor3          = C.SUBTEXT
	body.TextXAlignment      = Enum.TextXAlignment.Left
	body.TextYAlignment      = Enum.TextYAlignment.Top
	body.TextWrapped         = true
	body.Text                = ""
	body.ZIndex              = 31
	body.Parent              = f

	ttFrame = f; ttTitle = title; ttBody = body
end

local function showTooltip(title: string, body: string)
	if not ttFrame or not ttTitle or not ttBody then return end
	ttTitle.Text  = title
	ttBody.Text   = body
	ttFrame.Visible = true
end

local function hideTooltip()
	if ttFrame then ttFrame.Visible = false end
end

-- ── Research card builder ─────────────────────────────────────────────────────

local CARD_W = 194
local CARD_H = 108

local function makeResearchCard(
	parent: Instance,
	tech:   typeof(TECHS[1]),
	xPos:   number
): CardRefs
	local zi = 11

	-- Root button
	local root                  = Instance.new("TextButton")
	root.Name                   = tech.key .. "Card"
	root.Size                   = UDim2.fromOffset(CARD_W, CARD_H)
	root.Position               = UDim2.fromOffset(xPos, 74)
	root.BackgroundColor3       = CARD_BG
	root.BackgroundTransparency = 0
	root.Text                   = ""
	root.AutoButtonColor        = false
	root.BorderSizePixel        = 0
	root.ZIndex                 = zi
	root.Parent                 = parent
	UILib.corner(root, 8)
	local stroke = UILib.stroke(root, tech.color, 1.5)

	-- Top accent stripe
	local stripe                = Instance.new("Frame")
	stripe.Size                 = UDim2.new(1, 0, 0, 4)
	stripe.BackgroundColor3     = tech.color
	stripe.BorderSizePixel      = 0
	stripe.ZIndex               = zi + 1
	stripe.Parent               = root
	UILib.corner(stripe, 8)

	-- Icon circle (left side)
	local circle                = Instance.new("Frame")
	circle.Size                 = UDim2.fromOffset(30, 30)
	circle.Position             = UDim2.fromOffset(8, 11)
	circle.BackgroundColor3     = tech.color
	circle.BackgroundTransparency = 0.55
	circle.BorderSizePixel      = 0
	circle.ZIndex               = zi + 1
	circle.Parent               = root
	UILib.corner(circle, 15)

	local iconLbl               = Instance.new("TextLabel")
	iconLbl.Size                = UDim2.new(1, 0, 1, 0)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Font                = Enum.Font.GothamBold
	iconLbl.TextSize            = 15
	iconLbl.TextColor3          = C.TEXT
	iconLbl.Text                = tech.icon
	iconLbl.TextXAlignment      = Enum.TextXAlignment.Center
	iconLbl.ZIndex              = zi + 2
	iconLbl.Parent              = circle

	-- Tech name
	local nameLbl               = Instance.new("TextLabel")
	nameLbl.Name                = "NameLbl"
	nameLbl.Size                = UDim2.fromOffset(144, 18)
	nameLbl.Position            = UDim2.fromOffset(46, 8)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font                = Enum.Font.GothamBold
	nameLbl.TextSize            = 12
	nameLbl.TextColor3          = C.TEXT
	nameLbl.TextXAlignment      = Enum.TextXAlignment.Left
	nameLbl.Text                = tech.name:upper()
	nameLbl.ZIndex              = zi + 1
	nameLbl.Parent              = root

	-- Short description
	local descLbl               = Instance.new("TextLabel")
	descLbl.Name                = "DescLbl"
	descLbl.Size                = UDim2.fromOffset(144, 30)
	descLbl.Position            = UDim2.fromOffset(46, 28)
	descLbl.BackgroundTransparency = 1
	descLbl.Font                = Enum.Font.Gotham
	descLbl.TextSize            = 10
	descLbl.TextColor3          = C.SUBTEXT
	descLbl.TextXAlignment      = Enum.TextXAlignment.Left
	descLbl.TextYAlignment      = Enum.TextYAlignment.Top
	descLbl.TextWrapped         = true
	descLbl.Text                = tech.short
	descLbl.ZIndex              = zi + 1
	descLbl.Parent              = root

	-- Status label — only visible when there is actual state to show (progress %, done ✓)
	local statusLbl             = Instance.new("TextLabel")
	statusLbl.Name              = "StatusLbl"
	statusLbl.Size              = UDim2.fromOffset(178, 16)
	statusLbl.Position          = UDim2.fromOffset(8, 62)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font              = Enum.Font.GothamBold
	statusLbl.TextSize          = 10
	statusLbl.TextColor3        = C.GOLD
	statusLbl.TextXAlignment    = Enum.TextXAlignment.Left
	statusLbl.Text              = ""
	statusLbl.Visible           = false
	statusLbl.ZIndex            = zi + 1
	statusLbl.Parent            = root

	-- Progress bar (bottom of card)
	local pb = UILib.progressBar(root,
		UDim2.new(1, 0, 0, 5),
		UDim2.fromOffset(0, 82),
		tech.color, zi + 1)
	pb.track.Visible = false

	-- Hover tooltip wiring
	root.MouseEnter:Connect(function()
		showTooltip(tech.name, tech.tip)
	end)
	root.MouseLeave:Connect(function()
		hideTooltip()
	end)

	-- Click to research
	root.MouseButton1Click:Connect(function()
		if not activeCCId or not root.Active then return end
		networkRef.startResearch(activeCCId, tech.key)
	end)

	return {
		root      = root,
		stroke    = stroke,
		nameLbl   = nameLbl,
		statusLbl = statusLbl,
		progFill  = pb.fill,
		progTrack = pb.track,
	}
end

-- ── Research card refresh ─────────────────────────────────────────────────────

local function refreshCard(tech: typeof(TECHS[1]))
	local refs = cardRefs[tech.key]
	if not refs then return end

	local done     = getResearchedFn and getResearchedFn(tech.key) or false
	local progress = getProgressFn   and getProgressFn(tech.key)   or nil
	local inProg   = progress ~= nil and not done

	local root = refs.root

	if done then
		root.Active               = false
		root.BackgroundColor3     = Color3.fromRGB(10, 26, 18)
		refs.stroke.Color         = C.GREEN
		refs.nameLbl.TextColor3   = C.TEXT
		refs.statusLbl.Visible    = true
		refs.statusLbl.TextColor3 = C.GREEN
		refs.statusLbl.Text       = "✓"
		refs.progTrack.Visible    = true
		refs.progFill.Size        = UDim2.new(1, 0, 1, 0)
		refs.progFill.BackgroundColor3 = C.GREEN

	elseif inProg then
		root.Active               = false
		root.BackgroundColor3     = CARD_BG
		refs.stroke.Color         = tech.color
		refs.stroke.Thickness     = 1
		refs.nameLbl.TextColor3   = C.ACCENT
		refs.statusLbl.Visible    = true
		refs.statusLbl.TextColor3 = C.ACCENT
		local pct = math.floor((progress :: number) * 100)
		refs.statusLbl.Text       = string.format("%d%%", pct)
		refs.progTrack.Visible    = true
		refs.progFill.Size        = UDim2.new(math.clamp(progress :: number, 0, 1), 0, 1, 0)

	else
		root.Active               = true
		root.BackgroundColor3     = CARD_BG
		refs.stroke.Color         = tech.color
		refs.stroke.Thickness     = 1.5
		refs.nameLbl.TextColor3   = C.TEXT
		refs.statusLbl.Visible    = false
		refs.progTrack.Visible    = false
	end
end

-- ── Monument section builders ─────────────────────────────────────────────────

local function buildMonumentSection(parent: Frame, yStart: number)
	local zi = 11

	-- Full-width card
	local root                  = Instance.new("TextButton")
	root.Name                   = "MonumentCard"
	root.Size                   = UDim2.fromOffset(400, 82)
	root.Position               = UDim2.fromOffset(10, yStart)
	root.BackgroundColor3       = Color3.fromRGB(24, 18, 6)
	root.BackgroundTransparency = 0
	root.Text                   = ""
	root.AutoButtonColor        = false
	root.BorderSizePixel        = 0
	root.ZIndex                 = zi
	root.Parent                 = parent
	UILib.corner(root, 8)
	UILib.stroke(root, C.GOLD, 1.5)

	-- Gold left edge bar
	local leftBar               = Instance.new("Frame")
	leftBar.Size                = UDim2.fromOffset(4, 82)
	leftBar.BackgroundColor3    = C.GOLD
	leftBar.BorderSizePixel     = 0
	leftBar.ZIndex              = zi + 1
	leftBar.Parent              = root
	UILib.corner(leftBar, 4)

	-- Icon circle
	local circle                = Instance.new("Frame")
	circle.Size                 = UDim2.fromOffset(32, 32)
	circle.Position             = UDim2.fromOffset(14, 10)
	circle.BackgroundColor3     = C.GOLD
	circle.BackgroundTransparency = 0.55
	circle.BorderSizePixel      = 0
	circle.ZIndex               = zi + 1
	circle.Parent               = root
	UILib.corner(circle, 16)

	local iconLbl               = Instance.new("TextLabel")
	iconLbl.Size                = UDim2.new(1, 0, 1, 0)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Font                = Enum.Font.GothamBold
	iconLbl.TextSize            = 17
	iconLbl.TextColor3          = C.GOLD
	iconLbl.Text                = "★"
	iconLbl.TextXAlignment      = Enum.TextXAlignment.Center
	iconLbl.ZIndex              = zi + 2
	iconLbl.Parent              = circle

	-- Title
	local titleLbl              = Instance.new("TextLabel")
	titleLbl.Size               = UDim2.fromOffset(196, 20)
	titleLbl.Position           = UDim2.fromOffset(54, 6)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font               = Enum.Font.GothamBold
	titleLbl.TextSize           = 13
	titleLbl.TextColor3         = C.GOLD
	titleLbl.TextXAlignment     = Enum.TextXAlignment.Left
	titleLbl.Text               = "BUILD MONUMENT"
	titleLbl.ZIndex             = zi + 1
	titleLbl.Parent             = root

	-- Description
	local descLbl               = Instance.new("TextLabel")
	descLbl.Size                = UDim2.fromOffset(198, 30)
	descLbl.Position            = UDim2.fromOffset(54, 28)
	descLbl.BackgroundTransparency = 1
	descLbl.Font                = Enum.Font.Gotham
	descLbl.TextSize            = 10
	descLbl.TextColor3          = C.SUBTEXT
	descLbl.TextXAlignment      = Enum.TextXAlignment.Left
	descLbl.TextYAlignment      = Enum.TextYAlignment.Top
	descLbl.TextWrapped         = true
	descLbl.Text                = "Rises from your Command Center. Defend it for 5 minutes to win."
	descLbl.ZIndex              = zi + 1
	descLbl.Parent              = root

	-- Status text (bottom-left of card)
	local statusLbl             = Instance.new("TextLabel")
	statusLbl.Name              = "MonStatus"
	statusLbl.Size              = UDim2.fromOffset(198, 14)
	statusLbl.Position          = UDim2.fromOffset(54, 62)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font              = Enum.Font.GothamBold
	statusLbl.TextSize          = 10
	statusLbl.TextColor3        = C.GOLD
	statusLbl.TextXAlignment    = Enum.TextXAlignment.Left
	statusLbl.Text              = ""
	statusLbl.Visible           = false
	statusLbl.ZIndex            = zi + 1
	statusLbl.Parent            = root

	-- ── Right info panel ───────────────────────────────────────────────────
	local rightPanel            = Instance.new("Frame")
	rightPanel.Name             = "RightPanel"
	rightPanel.Size             = UDim2.fromOffset(110, 82)
	rightPanel.Position         = UDim2.fromOffset(290, 0)
	rightPanel.BackgroundColor3 = Color3.fromRGB(18, 13, 4)
	rightPanel.BackgroundTransparency = 0
	rightPanel.BorderSizePixel  = 0
	rightPanel.ZIndex           = zi + 1
	rightPanel.Parent           = root
	-- rounded right corners only (hack: corner the whole panel but square the left via overlap)
	UILib.corner(rightPanel, 8)

	-- Big number / timer
	local bigLbl                = Instance.new("TextLabel")
	bigLbl.Name                 = "BigLbl"
	bigLbl.Size                 = UDim2.new(1, -8, 0, 38)
	bigLbl.Position             = UDim2.fromOffset(4, 12)
	bigLbl.BackgroundTransparency = 1
	bigLbl.Font                 = Enum.Font.GothamBold
	bigLbl.TextSize             = 26
	bigLbl.TextColor3           = C.GOLD
	bigLbl.TextXAlignment       = Enum.TextXAlignment.Center
	bigLbl.Text                 = "1500"
	bigLbl.ZIndex               = zi + 2
	bigLbl.Parent               = rightPanel

	-- Sub-label ("resources" / "remaining")
	local smLbl                 = Instance.new("TextLabel")
	smLbl.Name                  = "SmLbl"
	smLbl.Size                  = UDim2.new(1, -8, 0, 14)
	smLbl.Position              = UDim2.fromOffset(4, 52)
	smLbl.BackgroundTransparency = 1
	smLbl.Font                  = Enum.Font.Gotham
	smLbl.TextSize              = 10
	smLbl.TextColor3            = C.SUBTEXT
	smLbl.TextXAlignment        = Enum.TextXAlignment.Center
	smLbl.Text                  = ""
	smLbl.ZIndex                = zi + 2
	smLbl.Parent                = rightPanel

	-- ── Progress bar (below the card) ─────────────────────────────────────
	local pb = UILib.progressBar(parent,
		UDim2.fromOffset(400, 6),
		UDim2.fromOffset(10, yStart + 84),
		C.GOLD, zi)
	pb.track.Visible = false

	-- ── Tooltip ────────────────────────────────────────────────────────────
	root.MouseEnter:Connect(function()
		showTooltip("Build Monument",
			"Constructs an obelisk at your Command Center. If it stands undamaged for 5 minutes, you win the game.\n\nEnemies can see and attack it at any time — it has 3000 HP so defend it well.\n\n💰  Costs 1500 resources")
	end)
	root.MouseLeave:Connect(function()
		hideTooltip()
	end)

	-- ── Click ──────────────────────────────────────────────────────────────
	root.MouseButton1Click:Connect(function()
		if not activeCCId or not root.Active then return end
		networkRef.buildMonument()
	end)

	monRoot  = root
	monRight = rightPanel
	monBigLbl = bigLbl
	monSmLbl  = smLbl
	monFill   = pb.fill
	monTrack  = pb.track
end

-- ── Monument card refresh ─────────────────────────────────────────────────────

local function refreshMonument()
	local root   = monRoot
	local bigLbl = monBigLbl
	local smLbl  = monSmLbl
	local right  = monRight
	if not root or not bigLbl or not smLbl or not right then return end

	local status = root:FindFirstChild("MonStatus") :: TextLabel?
	local t      = localMonumentTime

	if t == nil then
		-- Not built
		local canAfford = (getResourcesFn and getResourcesFn() or 0) >= Config.MONUMENT_COST
		root.Active               = true
		root.BackgroundColor3     = Color3.fromRGB(24, 18, 6)
		right.BackgroundColor3    = Color3.fromRGB(18, 13, 4)
		bigLbl.TextColor3         = canAfford and C.GOLD or C.DIM
		bigLbl.TextSize           = 26
		bigLbl.Text               = "1500"
		smLbl.TextColor3          = canAfford and C.SUBTEXT or C.DIM
		smLbl.Text                = ""
		if status then
			status.Visible = false
		end
		if monTrack then monTrack.Visible = false end

	elseif t == -1 then
		-- Under construction
		root.Active               = false
		root.BackgroundColor3     = CARD_BG
		right.BackgroundColor3    = Color3.fromRGB(8, 11, 22)
		bigLbl.TextColor3         = C.ACCENT
		bigLbl.TextSize           = 18
		bigLbl.Text               = "RISING"
		smLbl.TextColor3          = C.SUBTEXT
		smLbl.Text                = ""
		if status then
			status.Visible = false
		end
		if monTrack then monTrack.Visible = false end

	else
		-- Countdown active
		root.Active               = false
		root.BackgroundColor3     = Color3.fromRGB(24, 18, 6)
		right.BackgroundColor3    = Color3.fromRGB(18, 13, 4)
		local mins = math.floor(t / 60)
		local secs = math.floor(t % 60)
		bigLbl.TextColor3  = C.GOLD
		bigLbl.TextSize    = 26
		bigLbl.Text        = string.format("%d:%02d", mins, secs)
		smLbl.TextColor3   = C.SUBTEXT
		smLbl.Text         = ""
		if status then
			status.Visible = false
		end
		local pct = 1 - (t / Config.MONUMENT_WIN_DURATION)
		if monFill  then monFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0) end
		if monTrack then monTrack.Visible = true end
	end
end

-- ── Master refresh ────────────────────────────────────────────────────────────

local function refresh()
	if not activeCCId then return end
	for _, tech in TECHS do
		refreshCard(tech)
	end
	refreshMonument()
end

-- ── Init ──────────────────────────────────────────────────────────────────────

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

	-- ── Main panel ─────────────────────────────────────────────────────────
	-- Size: 420 × 320; bottom aligned, centred.
	-- Bottom edge keeps same screen position as the old panel.
	local p                  = Instance.new("Frame")
	p.Name                   = "WorkshopPanel"
	p.Size                   = UDim2.fromOffset(420, 320)
	p.Position               = UDim2.new(0.5, -210, 1, -468)
	p.BackgroundColor3       = DARK_BG
	p.BackgroundTransparency = 0.05
	p.BorderSizePixel        = 0
	p.ZIndex                 = 10
	p.Visible                = false
	p.Parent                 = sg
	UILib.corner(p, 12)
	UILib.stroke(p, C.BORDER, 1.5)
	panel = p

	-- ── Title bar ──────────────────────────────────────────────────────────
	UILib.titleBar(p, "COMMAND CENTER", function() WorkshopPanel.hide() end, C.TEAL)

	-- Subtitle
	UILib.lbl(p, "Research  ·  Upgrades  ·  Win Conditions",
		UDim2.fromOffset(390, 14), UDim2.fromOffset(10, 36),
		{ size = 10, color = SEC_LBL, zIndex = 11 })

	-- Thin separator
	UILib.divider(p, 52, 10, 11)

	-- ── Research section header ────────────────────────────────────────────
	UILib.lbl(p, "RESEARCH",
		UDim2.fromOffset(390, 14), UDim2.fromOffset(10, 57),
		{ bold = true, size = 10, color = SEC_LBL, zIndex = 11 })

	-- ── Research cards (side-by-side) ──────────────────────────────────────
	-- Card 1 at x=10, Card 2 at x=216  (gap = 12px, margin = 10px each side)
	cardRefs["BetterMines"] = makeResearchCard(p, TECHS[1], 10)
	cardRefs["EliteUnits"]  = makeResearchCard(p, TECHS[2], 216)

	-- ── Divider before win section ─────────────────────────────────────────
	UILib.divider(p, 188, 10, 11)

	-- ── Win condition section header ───────────────────────────────────────
	UILib.lbl(p, "WIN CONDITION",
		UDim2.fromOffset(390, 14), UDim2.fromOffset(10, 193),
		{ bold = true, size = 10, color = C.GOLD, zIndex = 11 })

	-- ── Monument card (y=209) ──────────────────────────────────────────────
	buildMonumentSection(p, 209)

	-- ── Tooltip (parented to ScreenGui so it floats freely) ───────────────
	buildTooltip(sg)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	if panel then panel.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if panel then panel.Visible = false end
	hideTooltip()
end

function WorkshopPanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refresh() end
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
	localMonumentTime = timeRemaining
	if panel and (panel :: Frame).Visible then refreshMonument() end
end

function WorkshopPanel.resetMonument()
	localMonumentTime = nil
	refreshMonument()
end

return WorkshopPanel
