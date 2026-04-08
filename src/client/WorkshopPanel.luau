local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel   = {}
local localPlayer     = Players.LocalPlayer
local C               = UILib.C

-- ── Palette ───────────────────────────────────────────────────────────────────
local PURPLE  = Color3.fromRGB(160, 80, 230)
local DARK_BG = Color3.fromRGB(8, 11, 22)
local CARD_BG = Color3.fromRGB(12, 17, 32)

-- ── State ─────────────────────────────────────────────────────────────────────
local panel:           Frame?
local activeCCId:      string?
local networkRef:      any
local getResearchedFn: ((string) -> boolean)?
local getProgressFn:   ((string) -> number?)?
local getResourcesFn:  (() -> number)?

-- nil = not built; -1 = constructing; >0 = seconds remaining
local localMonumentTime: number?

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
local monBigLbl: TextLabel?
local monFill:   Frame?
local monTrack:  Frame?

-- Tooltip (single instance, content swapped on hover)
local ttFrame: Frame?
local ttTitle: TextLabel?
local ttBody:  TextLabel?

-- ── Tech definitions ──────────────────────────────────────────────────────────
local TECHS: {
	{
		key:   string,
		name:  string,
		icon:  string,
		color: Color3,
		tip:   string,
	}
} = {
	{
		key   = "BetterMines",
		name  = "Better Mines",
		icon  = "⛏",
		color = C.TEAL,
		tip   = "Unlocks upgrade buttons on your mines.\n\nEfficiency — ×2 income per miner\nCapacity — +4 extra miner slots\n\nBoth upgrades are mutually exclusive per mine.\n\n⏱ 5 sec",
	},
	{
		key   = "EliteUnits",
		name  = "Elite Units",
		icon  = "⚔",
		color = PURPLE,
		tip   = "Trains Elite units at your Barracks.\n\nLong range, high damage, spider-leg movement.\nIdeal counter to turret-heavy bases.\n\nCost per unit: 100 res   ⏱ 15 sec",
	},
	{
		key   = "TurretUpgrades",
		name  = "Turret Upgrades",
		icon  = "⚙",
		color = C.TURRET,
		tip   = "Unlocks two upgrade paths for each turret.\n\nFlamethrower — short range (28), rapid fire\nRocket Launcher — long range (70), high damage\n\nMutually exclusive per turret.\n\n⏱ 20 sec",
	},
}

-- ── Tooltip ───────────────────────────────────────────────────────────────────

local function buildTooltip(sg: ScreenGui)
	local f                  = Instance.new("Frame")
	f.Name                   = "WorkshopTooltip"
	f.Size                   = UDim2.fromOffset(190, 148)
	f.Position               = UDim2.new(0.5, -412, 1, -443)
	f.BackgroundColor3       = DARK_BG
	f.BackgroundTransparency = 0.06
	f.BorderSizePixel        = 0
	f.ZIndex                 = 30
	f.Visible                = false
	f.Parent                 = sg
	UILib.corner(f, 10)
	UILib.stroke(f, C.BORDER, 1.5)

	local accent             = Instance.new("Frame")
	accent.Size              = UDim2.new(1, -2, 0, 3)
	accent.Position          = UDim2.fromOffset(1, 1)
	accent.BackgroundColor3  = C.ACCENT
	accent.BorderSizePixel   = 0
	accent.ZIndex            = 31
	accent.Parent            = f
	UILib.corner(accent, 8)

	local title              = Instance.new("TextLabel")
	title.Size               = UDim2.new(1, -16, 0, 20)
	title.Position           = UDim2.fromOffset(8, 10)
	title.BackgroundTransparency = 1
	title.Font               = Enum.Font.GothamBold
	title.TextSize           = 13
	title.TextColor3         = C.TEXT
	title.TextXAlignment     = Enum.TextXAlignment.Left
	title.Text               = ""
	title.ZIndex             = 31
	title.Parent             = f

	local sep                = Instance.new("Frame")
	sep.Size                 = UDim2.new(1, -16, 0, 1)
	sep.Position             = UDim2.fromOffset(8, 32)
	sep.BackgroundColor3     = C.SEP
	sep.BorderSizePixel      = 0
	sep.ZIndex               = 31
	sep.Parent               = f

	local body               = Instance.new("TextLabel")
	body.Size                = UDim2.new(1, -16, 1, -42)
	body.Position            = UDim2.fromOffset(8, 38)
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

	ttFrame = f
	ttTitle = title
	ttBody  = body
end

local function showTooltip(title: string, body: string)
	if not ttFrame or not ttTitle or not ttBody then return end
	ttTitle.Text    = title
	ttBody.Text     = body
	ttFrame.Visible = true
end

local function hideTooltip()
	if ttFrame then ttFrame.Visible = false end
end

-- ── Research card ─────────────────────────────────────────────────────────────

local CARD_W = 194
local CARD_H = 64

local function makeResearchCard(parent: Instance, tech: typeof(TECHS[1]), xPos: number, yPos: number?): CardRefs
	local zi = 11

	local root               = Instance.new("TextButton")
	root.Name                = tech.key .. "Card"
	root.Size                = UDim2.fromOffset(CARD_W, CARD_H)
	root.Position            = UDim2.fromOffset(xPos, yPos or 50)
	root.BackgroundColor3    = CARD_BG
	root.Text                = ""
	root.AutoButtonColor     = false
	root.BorderSizePixel     = 0
	root.ZIndex              = zi
	root.Parent              = parent
	UILib.corner(root, 8)
	local stroke = UILib.stroke(root, tech.color, 1.5)

	-- Top accent stripe
	local stripe             = Instance.new("Frame")
	stripe.Size              = UDim2.new(1, 0, 0, 3)
	stripe.BackgroundColor3  = tech.color
	stripe.BorderSizePixel   = 0
	stripe.ZIndex            = zi + 1
	stripe.Parent            = root
	UILib.corner(stripe, 8)

	-- Icon circle
	local circle             = Instance.new("Frame")
	circle.Size              = UDim2.fromOffset(30, 30)
	circle.Position          = UDim2.fromOffset(10, 14)
	circle.BackgroundColor3  = tech.color
	circle.BackgroundTransparency = 0.6
	circle.BorderSizePixel   = 0
	circle.ZIndex            = zi + 1
	circle.Parent            = root
	UILib.corner(circle, 15)

	local iconLbl            = Instance.new("TextLabel")
	iconLbl.Size             = UDim2.new(1, 0, 1, 0)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Font             = Enum.Font.GothamBold
	iconLbl.TextSize         = 16
	iconLbl.TextColor3       = C.TEXT
	iconLbl.Text             = tech.icon
	iconLbl.TextXAlignment   = Enum.TextXAlignment.Center
	iconLbl.ZIndex           = zi + 2
	iconLbl.Parent           = circle

	-- Name
	local nameLbl            = Instance.new("TextLabel")
	nameLbl.Name             = "NameLbl"
	nameLbl.Size             = UDim2.fromOffset(134, 22)
	nameLbl.Position         = UDim2.fromOffset(48, 18)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font             = Enum.Font.GothamBold
	nameLbl.TextSize         = 12
	nameLbl.TextColor3       = C.TEXT
	nameLbl.TextXAlignment   = Enum.TextXAlignment.Left
	nameLbl.Text             = tech.name:upper()
	nameLbl.ZIndex           = zi + 1
	nameLbl.Parent           = root

	-- Status indicator (% or ✓ — hidden when idle)
	local statusLbl          = Instance.new("TextLabel")
	statusLbl.Name           = "StatusLbl"
	statusLbl.Size           = UDim2.fromOffset(44, 22)
	statusLbl.Position       = UDim2.fromOffset(142, 18)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font           = Enum.Font.GothamBold
	statusLbl.TextSize       = 11
	statusLbl.TextColor3     = C.GOLD
	statusLbl.TextXAlignment = Enum.TextXAlignment.Right
	statusLbl.Text           = ""
	statusLbl.Visible        = false
	statusLbl.ZIndex         = zi + 1
	statusLbl.Parent         = root

	-- Progress bar (bottom edge)
	local pb = UILib.progressBar(root,
		UDim2.new(1, 0, 0, 4),
		UDim2.fromOffset(0, 60),
		tech.color, zi + 1)
	pb.track.Visible = false

	root.MouseEnter:Connect(function() showTooltip(tech.name, tech.tip) end)
	root.MouseLeave:Connect(function() hideTooltip() end)

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

	if done then
		refs.root.Active               = false
		refs.root.BackgroundColor3     = Color3.fromRGB(10, 26, 18)
		refs.stroke.Color              = C.GREEN
		refs.nameLbl.TextColor3        = C.TEXT
		refs.statusLbl.Visible         = true
		refs.statusLbl.TextColor3      = C.GREEN
		refs.statusLbl.Text            = "✓"
		refs.progTrack.Visible         = true
		refs.progFill.Size             = UDim2.new(1, 0, 1, 0)
		refs.progFill.BackgroundColor3 = C.GREEN

	elseif inProg then
		refs.root.Active               = false
		refs.root.BackgroundColor3     = CARD_BG
		refs.stroke.Color              = tech.color
		refs.stroke.Thickness          = 1
		refs.nameLbl.TextColor3        = C.ACCENT
		refs.statusLbl.Visible         = true
		refs.statusLbl.TextColor3      = C.ACCENT
		refs.statusLbl.Text            = string.format("%d%%", math.floor((progress :: number) * 100))
		refs.progTrack.Visible         = true
		refs.progFill.Size             = UDim2.new(math.clamp(progress :: number, 0, 1), 0, 1, 0)

	else
		refs.root.Active               = true
		refs.root.BackgroundColor3     = CARD_BG
		refs.stroke.Color              = tech.color
		refs.stroke.Thickness          = 1.5
		refs.nameLbl.TextColor3        = C.TEXT
		refs.statusLbl.Visible         = false
		refs.progTrack.Visible         = false
	end
end

-- ── Monument card ─────────────────────────────────────────────────────────────

local function buildMonumentSection(parent: Frame, yStart: number)
	local zi = 11

	local root               = Instance.new("TextButton")
	root.Name                = "MonumentCard"
	root.Size                = UDim2.fromOffset(400, 58)
	root.Position            = UDim2.fromOffset(10, yStart)
	root.BackgroundColor3    = Color3.fromRGB(24, 18, 6)
	root.Text                = ""
	root.AutoButtonColor     = false
	root.BorderSizePixel     = 0
	root.ZIndex              = zi
	root.Parent              = parent
	UILib.corner(root, 8)
	UILib.stroke(root, C.GOLD, 1.5)

	-- Gold left accent bar
	local leftBar            = Instance.new("Frame")
	leftBar.Size             = UDim2.fromOffset(4, 58)
	leftBar.BackgroundColor3 = C.GOLD
	leftBar.BorderSizePixel  = 0
	leftBar.ZIndex           = zi + 1
	leftBar.Parent           = root
	UILib.corner(leftBar, 4)

	-- Icon circle
	local circle             = Instance.new("Frame")
	circle.Size              = UDim2.fromOffset(30, 30)
	circle.Position          = UDim2.fromOffset(14, 14)
	circle.BackgroundColor3  = C.GOLD
	circle.BackgroundTransparency = 0.6
	circle.BorderSizePixel   = 0
	circle.ZIndex            = zi + 1
	circle.Parent            = root
	UILib.corner(circle, 15)

	local iconLbl            = Instance.new("TextLabel")
	iconLbl.Size             = UDim2.new(1, 0, 1, 0)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Font             = Enum.Font.GothamBold
	iconLbl.TextSize         = 16
	iconLbl.TextColor3       = C.GOLD
	iconLbl.Text             = "★"
	iconLbl.TextXAlignment   = Enum.TextXAlignment.Center
	iconLbl.ZIndex           = zi + 2
	iconLbl.Parent           = circle

	-- Name
	local nameLbl            = Instance.new("TextLabel")
	nameLbl.Size             = UDim2.fromOffset(200, 24)
	nameLbl.Position         = UDim2.fromOffset(52, 16)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font             = Enum.Font.GothamBold
	nameLbl.TextSize         = 13
	nameLbl.TextColor3       = C.GOLD
	nameLbl.TextXAlignment   = Enum.TextXAlignment.Left
	nameLbl.Text             = "MONUMENT"
	nameLbl.ZIndex           = zi + 1
	nameLbl.Parent           = root

	-- Cost / timer number (right side)
	local bigLbl             = Instance.new("TextLabel")
	bigLbl.Name              = "BigLbl"
	bigLbl.Size              = UDim2.fromOffset(120, 58)
	bigLbl.Position          = UDim2.fromOffset(280, 0)
	bigLbl.BackgroundTransparency = 1
	bigLbl.Font              = Enum.Font.GothamBold
	bigLbl.TextSize          = 22
	bigLbl.TextColor3        = C.GOLD
	bigLbl.TextXAlignment    = Enum.TextXAlignment.Center
	bigLbl.TextYAlignment    = Enum.TextYAlignment.Center
	bigLbl.Text              = "1500"
	bigLbl.ZIndex            = zi + 1
	bigLbl.Parent            = root

	-- Progress bar
	local pb = UILib.progressBar(parent,
		UDim2.fromOffset(400, 6),
		UDim2.fromOffset(10, yStart + 61),
		C.GOLD, zi)
	pb.track.Visible = false

	root.MouseEnter:Connect(function()
		showTooltip("Monument",
			"Rises from your Command Center.\nDefend it for 5 minutes to win the game.\n\nVisible to all players at all times.\n3000 HP — protect it well.\n\n💰 Costs 1500 resources")
	end)
	root.MouseLeave:Connect(function() hideTooltip() end)

	root.MouseButton1Click:Connect(function()
		if not activeCCId or not root.Active then return end
		networkRef.buildMonument()
	end)

	monRoot   = root
	monBigLbl = bigLbl
	monFill   = pb.fill
	monTrack  = pb.track
end

-- ── Monument refresh ──────────────────────────────────────────────────────────

local function refreshMonument()
	local root   = monRoot
	local bigLbl = monBigLbl
	if not root or not bigLbl then return end

	local t = localMonumentTime

	if t == nil then
		local canAfford       = (getResourcesFn and getResourcesFn() or 0) >= Config.MONUMENT_COST
		root.Active           = true
		root.BackgroundColor3 = Color3.fromRGB(24, 18, 6)
		bigLbl.TextColor3     = canAfford and C.GOLD or C.DIM
		bigLbl.TextSize       = 22
		bigLbl.Text           = "1500"
		if monTrack then monTrack.Visible = false end

	elseif t == -1 then
		root.Active           = false
		root.BackgroundColor3 = CARD_BG
		bigLbl.TextColor3     = C.ACCENT
		bigLbl.TextSize       = 14
		bigLbl.Text           = "RISING..."
		if monTrack then monTrack.Visible = false end

	else
		root.Active           = false
		root.BackgroundColor3 = Color3.fromRGB(24, 18, 6)
		local mins = math.floor(t / 60)
		local secs = math.floor(t % 60)
		bigLbl.TextColor3     = C.GOLD
		bigLbl.TextSize       = 22
		bigLbl.Text           = string.format("%d:%02d", mins, secs)
		local pct = 1 - (t / Config.MONUMENT_WIN_DURATION)
		if monFill  then monFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0) end
		if monTrack then monTrack.Visible = true end
	end
end

-- ── Master refresh ────────────────────────────────────────────────────────────

local function refresh()
	if not activeCCId then return end
	for _, tech in TECHS do refreshCard(tech) end
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

	local p                  = Instance.new("Frame")
	p.Name                   = "WorkshopPanel"
	p.Size                   = UDim2.fromOffset(420, 290)
	p.Position               = UDim2.new(0.5, -210, 1, -438)
	p.BackgroundColor3       = DARK_BG
	p.BackgroundTransparency = 0.05
	p.BorderSizePixel        = 0
	p.ZIndex                 = 10
	p.Visible                = false
	p.Parent                 = sg
	UILib.corner(p, 12)
	UILib.stroke(p, C.BORDER, 1.5)
	panel = p

	UILib.titleBar(p, "COMMAND CENTER", function() WorkshopPanel.hide() end, C.TEAL)

	-- Research cards — row 1 (y=50)
	cardRefs["BetterMines"]    = makeResearchCard(p, TECHS[1], 10,  50)
	cardRefs["EliteUnits"]     = makeResearchCard(p, TECHS[2], 216, 50)
	-- Research cards — row 2 (y=122), centred
	cardRefs["TurretUpgrades"] = makeResearchCard(p, TECHS[3], 113, 122)

	-- Separator
	UILib.divider(p, 196, 10, 11)

	-- Monument card (y=208)
	buildMonumentSection(p, 208)

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
