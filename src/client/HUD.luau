local Players    = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local HUD         = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────

local resLabel:  TextLabel?
local incLabel:  TextLabel?
local selLabel:  TextLabel?
local buildBarRef: Frame?
local cancelBtnRef: TextButton?
local ccBtnRef:   TextButton?

local currentResources = 0
local currentIncome    = 0
local buildMenuOpen    = false
local buildToggleBtnRef: TextButton?

-- Per-building-type card data
type CardData = {
	btn:        TextButton,
	accentBar:  Frame,
	nameLbl:    TextLabel,
	subLbl:     TextLabel,
	stroke:     UIStroke,
	color:      Color3,
}
local cardMap: { [string]: CardData } = {}

-- Requirement system
local playerCounts:      { [string]: number } = {}
local currentActivePlacing: string?           = nil

-- ── Building metadata ─────────────────────────────────────────────────────────

local BUILDING_INFO: { [string]: { cost: number, requires: { [string]: number } } } = {
	Mine     = { cost = Config.MINE_COST,      requires = {} },
	Barracks = { cost = Config.BUILDING_COST,  requires = { Mine = 1 } },
	Workshop = { cost = Config.WORKSHOP_COST,  requires = { Mine = 1 } },
	Turret   = { cost = Config.TURRET_COST,    requires = { Barracks = 1 } },
}

local CARD_ENTRIES: { { btype: string, color: Color3, label: string } } = {
	{ btype = "Mine",     color = C.MINE,     label = "MINE"     },
	{ btype = "Barracks", color = C.BARRACKS, label = "BARRACKS" },
	{ btype = "Workshop", color = C.WORKSHOP, label = "WORKSHOP" },
	{ btype = "Turret",   color = C.TURRET,   label = "TURRET"   },
}

-- ── Requirement helpers ───────────────────────────────────────────────────────

local function isUnlocked(btype: string): boolean
	local info = BUILDING_INFO[btype]
	if not info then return true end
	for req, count in info.requires do
		if (playerCounts[req] or 0) < count then return false end
	end
	return true
end

-- ── Card visual state ─────────────────────────────────────────────────────────

local function applyCardState(btype: string)
	local d = cardMap[btype]
	if not d then return end

	local locked  = not isUnlocked(btype)
	local placing = currentActivePlacing == btype
	local info    = BUILDING_INFO[btype]

	if placing then
		-- Bright cyan: actively placing this building
		d.btn.BackgroundColor3       = Color3.fromRGB(0, 60, 80)
		d.btn.BackgroundTransparency = 0
		d.accentBar.BackgroundColor3 = C.ACCENT
		d.nameLbl.TextColor3         = C.ACCENT
		d.subLbl.Text                = "PLACING..."
		d.subLbl.TextColor3          = C.ACCENT
		d.stroke.Color               = C.ACCENT
		d.stroke.Thickness           = 1.8

	elseif locked then
		-- Dim: requirements not met
		local missingReq = ""
		if info then
			for req in info.requires do
				if (playerCounts[req] or 0) < (info.requires[req] or 1) then
					missingReq = req; break
				end
			end
		end
		d.btn.BackgroundColor3       = C.BG_LOCKED
		d.btn.BackgroundTransparency = 0
		d.accentBar.BackgroundColor3 = C.DIM
		d.nameLbl.TextColor3         = C.DIM
		d.subLbl.Text                = missingReq ~= "" and ("Needs " .. missingReq) or "LOCKED"
		d.subLbl.TextColor3          = Color3.fromRGB(160, 50, 50)
		d.stroke.Color               = C.BORDER_LO
		d.stroke.Thickness           = 1

	else
		-- Normal: available to build
		d.btn.BackgroundColor3       = C.BG_CARD
		d.btn.BackgroundTransparency = 0
		d.accentBar.BackgroundColor3 = d.color
		d.nameLbl.TextColor3         = C.TEXT
		d.subLbl.Text                = "◆ " .. tostring(info and info.cost or 0) .. " res"
		d.subLbl.TextColor3          = C.GOLD
		d.stroke.Color               = C.BORDER
		d.stroke.Thickness           = 1
	end
end

local function updateAllCards()
	for _, e in CARD_ENTRIES do
		applyCardState(e.btype)
	end
end

-- ── Resource display ──────────────────────────────────────────────────────────

local function refreshResDisplay()
	if resLabel then
		resLabel.Text = tostring(currentResources)
	end
	if incLabel then
		if currentIncome > 0 then
			incLabel.Text = string.format("+%.0f/min", currentIncome)
			incLabel.TextColor3 = C.GREEN
		else
			incLabel.Text = ""
		end
	end
end

-- ── Card construction ─────────────────────────────────────────────────────────

local function makeCard(parent: Instance, btype: string, label: string, color: Color3): TextButton
	local zi = 5

	-- Root: a TextButton so click and hover work directly on the card
	local btn                  = Instance.new("TextButton")
	btn.Name                   = btype .. "Card"
	btn.Size                   = UDim2.fromOffset(128, 60)
	btn.BackgroundColor3       = C.BG_CARD
	btn.BackgroundTransparency = 0
	btn.Text                   = ""
	btn.AutoButtonColor        = false
	btn.BorderSizePixel        = 0
	btn.LayoutOrder            = #CARD_ENTRIES   -- overwritten by caller
	btn.ZIndex                 = zi
	btn.Parent                 = parent
	UILib.corner(btn, 8)
	local sk = UILib.stroke(btn, C.BORDER, 1)

	-- Subtle hover feedback
	btn.MouseEnter:Connect(function()
		if currentActivePlacing ~= btype and isUnlocked(btype) then
			btn.BackgroundColor3 = Color3.fromRGB(22, 32, 58)
		end
	end)
	btn.MouseLeave:Connect(function()
		if currentActivePlacing ~= btype then
			applyCardState(btype)
		end
	end)

	-- Coloured accent bar at top
	local bar                  = Instance.new("Frame")
	bar.Name                   = "AccentBar"
	bar.Size                   = UDim2.new(1, -2, 0, 5)
	bar.Position               = UDim2.fromOffset(1, 1)
	bar.BackgroundColor3       = color
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = zi + 1
	bar.Parent                 = btn
	UILib.corner(bar, 6)

	-- Building name
	local nameLbl              = UILib.lbl(btn, label,
		UDim2.fromOffset(108, 18), UDim2.fromOffset(10, 10),
		{ bold = true, size = 13, color = C.TEXT, zIndex = zi + 1 })
	nameLbl.Name               = "NameLbl"

	-- Cost / status
	local subLbl               = UILib.lbl(btn, "",
		UDim2.fromOffset(108, 14), UDim2.fromOffset(10, 30),
		{ size = 11, color = C.GOLD, zIndex = zi + 1 })
	subLbl.Name                = "SubLbl"

	cardMap[btype] = {
		btn       = btn,
		accentBar = bar,
		nameLbl   = nameLbl,
		subLbl    = subLbl,
		stroke    = sk,
		color     = color,
	}

	return btn
end

-- ── HUD.create ────────────────────────────────────────────────────────────────

function HUD.create(): (Frame, TextButton, TextButton, TextButton, TextButton, TextButton, TextButton)
	local sg               = Instance.new("ScreenGui")
	sg.Name                = "RTSHUD"
	sg.ResetOnSpawn        = false
	sg.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
	sg.Parent              = localPlayer.PlayerGui

	-- ── Resource bar (top-left) ──────────────────────────────────────────
	local resBar                  = Instance.new("Frame")
	resBar.Name                   = "ResourceBar"
	resBar.Size                   = UDim2.fromOffset(272, 40)
	resBar.Position               = UDim2.fromOffset(12, 12)
	resBar.BackgroundColor3       = C.BG_PANEL
	resBar.BackgroundTransparency = 0.08
	resBar.BorderSizePixel        = 0
	resBar.ZIndex                 = 4
	resBar.Parent                 = sg
	UILib.corner(resBar, 8)
	UILib.stroke(resBar, C.BORDER, 1)

	-- Diamond icon
	local diamond                 = UILib.lbl(resBar, "◆",
		UDim2.fromOffset(22, 40), UDim2.fromOffset(8, 0),
		{ bold = true, size = 18, color = C.GOLD, align = Enum.TextXAlignment.Center, zIndex = 5 })
	diamond.Name = "Diamond"

	-- Resource number
	local rLbl                    = UILib.lbl(resBar, "400",
		UDim2.fromOffset(100, 40), UDim2.fromOffset(30, 0),
		{ bold = true, size = 16, color = C.GOLD, align = Enum.TextXAlignment.Left, zIndex = 5 })
	rLbl.Name = "ResLabel"
	resLabel   = rLbl

	-- Separator dot
	local dot                     = UILib.lbl(resBar, "·",
		UDim2.fromOffset(14, 40), UDim2.fromOffset(132, 0),
		{ size = 16, color = C.SUBTEXT, align = Enum.TextXAlignment.Center, zIndex = 5 })
	dot.Name = "Dot"

	-- Income
	local iLbl                    = UILib.lbl(resBar, "",
		UDim2.fromOffset(112, 40), UDim2.fromOffset(148, 0),
		{ size = 13, color = C.GREEN, align = Enum.TextXAlignment.Left, zIndex = 5 })
	iLbl.Name = "IncLabel"
	incLabel   = iLbl

	-- ── Selection label (top-center) ─────────────────────────────────────
	local sLbl                    = Instance.new("TextLabel")
	sLbl.Name                     = "SelLabel"
	sLbl.Size                     = UDim2.fromOffset(280, 38)
	sLbl.Position                 = UDim2.new(0.5, -140, 0, 12)
	sLbl.BackgroundTransparency   = 1
	sLbl.TextColor3               = C.TEXT
	sLbl.Font                     = Enum.Font.GothamBold
	sLbl.TextSize                 = 15
	sLbl.TextXAlignment           = Enum.TextXAlignment.Center
	sLbl.Text                     = ""
	sLbl.ZIndex                   = 4
	sLbl.Parent                   = sg
	selLabel = sLbl

	-- ── Drag-select rectangle ─────────────────────────────────────────────
	local dragFrame                  = Instance.new("Frame")
	dragFrame.Name                   = "DragSelect"
	dragFrame.BackgroundColor3       = C.ACCENT
	dragFrame.BackgroundTransparency = 0.76
	dragFrame.BorderSizePixel        = 1
	dragFrame.BorderColor3           = C.ACCENT
	dragFrame.Visible                = false
	dragFrame.ZIndex                 = 20
	dragFrame.Parent                 = sg

	-- ── Bottom button row (toggle + cancel sit here) ─────────────────────
	-- Layout from bottom: 10px margin → 50px button row → 8px gap → 72px tray → 8px gap → panels

	-- CC placement button (centered, CC mode only)
	local ccBtn                  = UILib.btn(sg,
		"⌂  PLACE COMMAND CENTER",
		UDim2.fromOffset(280, 50),
		UDim2.new(0.5, -140, 1, -60),
		C.TEAL, 4)
	ccBtn.Name                   = "CCButton"
	ccBtn.TextSize               = 15
	ccBtn.Visible                = false
	ccBtnRef                     = ccBtn

	-- Build toggle button (bottom-left, game mode)
	local toggleBtn              = UILib.btn(sg,
		"BUILD  ▼",
		UDim2.fromOffset(164, 50),
		UDim2.new(0, 10, 1, -60),
		C.BG_CARD, 4)
	toggleBtn.Name               = "BuildToggle"
	toggleBtn.TextSize           = 14
	toggleBtn.Visible            = false
	buildToggleBtnRef            = toggleBtn

	-- Cancel button (right of toggle, placement mode only)
	local cancelBtn              = UILib.btn(sg,
		"✕  CANCEL",
		UDim2.fromOffset(145, 50),
		UDim2.new(0, 184, 1, -60),
		C.RED, 6)
	cancelBtn.Name               = "CancelBtn"
	cancelBtn.TextSize           = 14
	cancelBtn.Visible            = false
	cancelBtnRef                 = cancelBtn

	-- ── Build card tray (above toggle row, collapsed by default) ──────────
	local buildBar                   = Instance.new("Frame")
	buildBar.Name                    = "BuildBar"
	buildBar.Size                    = UDim2.fromOffset(564, 72)
	buildBar.Position                = UDim2.new(0.5, -282, 1, -140)
	buildBar.BackgroundColor3        = C.BG_PANEL
	buildBar.BackgroundTransparency  = 0.08
	buildBar.BorderSizePixel         = 0
	buildBar.Visible                 = false   -- collapsed until toggled
	buildBar.ZIndex                  = 4
	buildBar.Parent                  = sg
	UILib.corner(buildBar, 10)
	UILib.stroke(buildBar, C.BORDER, 1)
	buildBarRef = buildBar

	local layout                     = Instance.new("UIListLayout")
	layout.FillDirection             = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment       = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment         = Enum.VerticalAlignment.Center
	layout.Padding                   = UDim.new(0, 8)
	layout.Parent                    = buildBar

	-- Build cards — order matches CARD_ENTRIES
	local btnRefs: { [string]: TextButton } = {}
	for i, e in CARD_ENTRIES do
		local b          = makeCard(buildBar, e.btype, e.label, e.color)
		b.LayoutOrder    = i
		btnRefs[e.btype] = b
	end

	-- Apply initial visual state
	updateAllCards()

	return dragFrame,
		btnRefs["Barracks"],
		btnRefs["Mine"],
		btnRefs["Turret"],
		cancelBtn,
		ccBtn,
		btnRefs["Workshop"]
end

-- ── Private helpers ──────────────────────────────────────────────────────────

local function setTrayOpen(open: boolean)
	buildMenuOpen = open
	if buildBarRef  then buildBarRef.Visible  = open end
	if buildToggleBtnRef then
		buildToggleBtnRef.Text             = open and "BUILD  ▲" or "BUILD  ▼"
		buildToggleBtnRef.BackgroundColor3 = open and C.GREEN   or C.BG_CARD
	end
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

function HUD.setCommandCenterMode(isCC: boolean)
	if ccBtnRef         then ccBtnRef.Visible         = isCC     end
	if buildToggleBtnRef then buildToggleBtnRef.Visible = not isCC end
	if cancelBtnRef     then cancelBtnRef.Visible     = false    end
	setTrayOpen(false)
end

function HUD.refreshTrayState(counts: { [string]: number })
	playerCounts = counts
	updateAllCards()
end

-- ── HUD.wire ──────────────────────────────────────────────────────────────────

function HUD.wire(
	network,       unitController, buildingPlacer,
	buildBtn:      TextButton,
	mineBtn:       TextButton,
	turretBtn:     TextButton,
	cancelBtn:     TextButton,
	workshopBtn:   TextButton
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

	-- Toggle tray open/close
	if buildToggleBtnRef then
		buildToggleBtnRef.MouseButton1Click:Connect(function()
			setTrayOpen(not buildMenuOpen)
		end)
	end

	-- Build card clicks — also close the tray
	mineBtn.MouseButton1Click:Connect(function()
		if not isUnlocked("Mine") then return end
		setTrayOpen(false)
		buildingPlacer.enterPlacementMode("Mine")
	end)

	buildBtn.MouseButton1Click:Connect(function()
		if not isUnlocked("Barracks") then return end
		setTrayOpen(false)
		buildingPlacer.enterPlacementMode("Barracks")
	end)

	workshopBtn.MouseButton1Click:Connect(function()
		if not isUnlocked("Workshop") then return end
		setTrayOpen(false)
		buildingPlacer.enterPlacementMode("Workshop")
	end)

	turretBtn.MouseButton1Click:Connect(function()
		if not isUnlocked("Turret") then return end
		setTrayOpen(false)
		buildingPlacer.enterPlacementMode("Turret")
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		buildingPlacer.exitPlacementMode()
	end)

	-- Placement mode changes
	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		currentActivePlacing = active and buildingType or nil
		updateAllCards()
		-- Close tray when placement begins; restore toggle when done
		if active then
			setTrayOpen(false)
		end
		cancelBtn.Visible = active and buildingType ~= "CommandCenter"
	end)
end

return HUD
