--!strict
--[[
    WorkshopPanel — Tech Gallery + Monument button.

    Cards laid out with UIGridLayout so positions are never derived from
    AbsoluteSize (which is 0 before the first render frame).
]]

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel = {}
local C             = UILib.C

-- ── Palette overrides for the gallery ─────────────────────────────────────────
local COL_UNLOCKED_BG   = Color3.fromRGB( 6,  24, 12)
local COL_UNLOCKED_BDR  = Color3.fromRGB(45, 200, 80)
local COL_LOCKED_BG     = Color3.fromRGB(11,  13, 23)
local COL_LOCKED_BDR    = Color3.fromRGB(30,  38, 65)
local COL_COND_LOCKED   = Color3.fromRGB(195, 148, 38)   -- amber "do this to unlock"
local COL_COND_UNLOCKED = Color3.fromRGB(45,  200, 80)
local COL_PANEL_BG      = Color3.fromRGB( 7,   9, 18)

-- ── Sizing ────────────────────────────────────────────────────────────────────
local CARD_W   = 304
local CARD_H   = 112
local CARD_PAD = 10
local COLS     = 2
local PANEL_W  = COLS * CARD_W + (COLS - 1) * CARD_PAD + 40
local PANEL_H  = 580

-- ── State ─────────────────────────────────────────────────────────────────────
local overlay:     Frame?
local scrollFrame: ScrollingFrame?
local gridLayout:  UIGridLayout?
local searchBox:   TextBox?
local monBtn:      TextButton?
local monLabel:    TextLabel?

local hasResearchFn: ((string) -> boolean)?
local resourcesFn:   (() -> number)?
local networkRef:    any

local localMonumentTime: number?
local searchText = ""

-- ── Monument button ───────────────────────────────────────────────────────────

local function refreshMonumentBtn()
	if not monBtn or not monLabel then return end
	local t   = localMonumentTime
	local res = resourcesFn and resourcesFn() or 0

	if t == nil then
		local canAfford = res >= Config.MONUMENT_COST
		monBtn.BackgroundColor3 = canAfford
			and Color3.fromRGB(60, 44, 0)
			or  Color3.fromRGB(22, 22, 22)
		monLabel.Text       = "★  BUILD MONUMENT  —  ◆ " .. Config.MONUMENT_COST
		monLabel.TextColor3 = canAfford and C.GOLD or C.DIM
	elseif t == -1 then
		monBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 10)
		monLabel.Text           = "★  MONUMENT  —  Rising…"
		monLabel.TextColor3     = C.GOLD
	else
		local mins = math.floor(t / 60)
		local secs = t % 60
		monBtn.BackgroundColor3 = Color3.fromRGB(8, 36, 8)
		monLabel.Text           = string.format("★  MONUMENT  —  %d:%02d remaining", mins, secs)
		monLabel.TextColor3     = C.GREEN
	end
end

-- ── Card builder ──────────────────────────────────────────────────────────────

local ICON_COL = 48   -- width of the emoji column

local function buildCard(parent: Instance, techName: string, unlocked: boolean): Frame
	local unlock = (Config.UNLOCKS :: any)[techName]
	if not unlock then
		local f = Instance.new("Frame"); f.Size = UDim2.fromOffset(CARD_W, CARD_H); f.Parent = parent; return f
	end

	local icon   = (unlock.icon     :: string?) or "◆"
	local desc   = (unlock.desc     :: string)
	local cond   = (unlock.condText :: string)
	local req    = (unlock.requires :: string?)
	local reqStr = req and ("Requires: " .. req) or nil

	local card                      = Instance.new("Frame")
	card.Name                       = "Card_" .. techName
	card.Size                       = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3           = unlocked and COL_UNLOCKED_BG or COL_LOCKED_BG
	card.BackgroundTransparency     = 0
	card.BorderSizePixel            = 0
	card.ZIndex                     = 52
	card.Parent                     = parent
	UILib.corner(card, 8)
	UILib.stroke(card, unlocked and COL_UNLOCKED_BDR or COL_LOCKED_BDR, unlocked and 1.5 or 1)

	-- Left accent bar
	local bar                       = Instance.new("Frame")
	bar.Size                        = UDim2.fromOffset(3, CARD_H - 16)
	bar.Position                    = UDim2.fromOffset(0, 8)
	bar.BackgroundColor3            = unlocked and COL_UNLOCKED_BDR or COL_LOCKED_BDR
	bar.BackgroundTransparency      = unlocked and 0 or 0.55
	bar.BorderSizePixel             = 0
	bar.ZIndex                      = 53
	bar.Parent                      = card
	UILib.corner(bar, 2)

	-- Emoji icon
	local iconLbl                   = Instance.new("TextLabel")
	iconLbl.Size                    = UDim2.fromOffset(ICON_COL, CARD_H)
	iconLbl.Position                = UDim2.fromOffset(10, 0)
	iconLbl.BackgroundTransparency  = 1
	iconLbl.Font                    = Enum.Font.GothamBold
	iconLbl.TextSize                = 26
	iconLbl.TextColor3              = unlocked and COL_UNLOCKED_BDR or C.SUBTEXT
	iconLbl.TextXAlignment          = Enum.TextXAlignment.Center
	iconLbl.TextYAlignment          = Enum.TextYAlignment.Center
	iconLbl.Text                    = icon
	iconLbl.ZIndex                  = 53
	iconLbl.Parent                  = card

	-- Content area starts after icon column
	local cx = ICON_COL + 14

	-- Tech name
	local nameW = CARD_W - cx - 10
	local nameLbl                   = Instance.new("TextLabel")
	nameLbl.Size                    = UDim2.fromOffset(nameW, 22)
	nameLbl.Position                = UDim2.fromOffset(cx, 8)
	nameLbl.BackgroundTransparency  = 1
	nameLbl.Font                    = Enum.Font.GothamBold
	nameLbl.TextSize                = 14
	nameLbl.TextColor3              = unlocked and COL_UNLOCKED_BDR or C.TEXT
	nameLbl.TextXAlignment          = Enum.TextXAlignment.Left
	nameLbl.TextTruncate            = Enum.TextTruncate.AtEnd
	nameLbl.Text                    = techName
	nameLbl.ZIndex                  = 53
	nameLbl.Parent                  = card

	-- Description
	local descH = reqStr and 28 or 38
	local descLbl                   = Instance.new("TextLabel")
	descLbl.Size                    = UDim2.fromOffset(nameW, descH)
	descLbl.Position                = UDim2.fromOffset(cx, 32)
	descLbl.BackgroundTransparency  = 1
	descLbl.Font                    = Enum.Font.Gotham
	descLbl.TextSize                = 11
	descLbl.TextColor3              = unlocked and C.SUBTEXT or Color3.fromRGB(85, 95, 118)
	descLbl.TextXAlignment          = Enum.TextXAlignment.Left
	descLbl.TextWrapped             = true
	descLbl.Text                    = desc
	descLbl.ZIndex                  = 53
	descLbl.Parent                  = card

	-- Requires line (if any)
	if reqStr then
		local reqLbl                = Instance.new("TextLabel")
		reqLbl.Size                 = UDim2.fromOffset(nameW, 16)
		reqLbl.Position             = UDim2.fromOffset(cx, 62)
		reqLbl.BackgroundTransparency = 1
		reqLbl.Font                 = Enum.Font.GothamBold
		reqLbl.TextSize             = 10
		reqLbl.TextColor3           = Color3.fromRGB(120, 100, 50)
		reqLbl.TextXAlignment       = Enum.TextXAlignment.Left
		reqLbl.Text                 = "⚠ " .. reqStr
		reqLbl.ZIndex               = 53
		reqLbl.Parent               = card
	end

	-- Condition row at the bottom of the card
	local condY = CARD_H - 22
	local condLbl                   = Instance.new("TextLabel")
	condLbl.Size                    = UDim2.fromOffset(nameW, 18)
	condLbl.Position                = UDim2.fromOffset(cx, condY)
	condLbl.BackgroundTransparency  = 1
	condLbl.Font                    = Enum.Font.GothamBold
	condLbl.TextSize                = 11
	condLbl.TextColor3              = unlocked and COL_COND_UNLOCKED or COL_COND_LOCKED
	condLbl.TextXAlignment          = Enum.TextXAlignment.Left
	condLbl.Text                    = (unlocked and "✓  " or "◎  ") .. cond
	condLbl.ZIndex                  = 53
	condLbl.Parent                  = card

	return card
end

-- ── Layout ────────────────────────────────────────────────────────────────────

local function rebuildCards()
	local sf   = scrollFrame
	local grid = gridLayout
	if not sf or not grid then return end
	local hr   = hasResearchFn

	-- Remove old cards (leave grid layout alone)
	for _, child in sf:GetChildren() do
		if child:IsA("Frame") and child.Name:sub(1, 5) == "Card_" then
			child:Destroy()
		end
	end

	-- Gather matching entries
	local filter = searchText:lower()
	local entries: { string } = {}
	for techName, unlock in (Config.UNLOCKS :: any) do
		if filter == "" then
			table.insert(entries, techName)
		else
			local hit = techName:lower():find(filter, 1, true)
				or (unlock.desc     :: string):lower():find(filter, 1, true)
				or (unlock.condText :: string):lower():find(filter, 1, true)
			if hit then table.insert(entries, techName) end
		end
	end

	-- Unlocked first, then alpha within each group
	table.sort(entries, function(a, b)
		local ua = hr and hr(a) or false
		local ub = hr and hr(b) or false
		if ua ~= ub then return ua end
		return a < b
	end)

	for _, techName in entries do
		local unlocked = hr and hr(techName) or false
		buildCard(sf, techName, unlocked)
	end

	-- Let UIGridLayout measure, then sync CanvasSize on next frame
	task.defer(function()
		if sf.Parent then
			sf.CanvasSize = UDim2.fromOffset(0, grid.AbsoluteContentSize.Y + CARD_PAD)
		end
	end)
end

-- ── Show / hide ───────────────────────────────────────────────────────────────

function WorkshopPanel.show(_ccId: string?)
	local ov = overlay
	if not ov then return end
	rebuildCards()
	refreshMonumentBtn()
	ov.Visible = true
	ov.BackgroundTransparency = 0.45
end

function WorkshopPanel.hide()
	local ov = overlay
	if not ov then return end
	ov.Visible = false
end

function WorkshopPanel.refreshIfVisible()
	if overlay and overlay.Visible then
		rebuildCards()
		refreshMonumentBtn()
	end
end

function WorkshopPanel.resetMonument()
	localMonumentTime = nil
	refreshMonumentBtn()
end

function WorkshopPanel.onMonumentProgress(timeRemaining: number?)
	localMonumentTime = timeRemaining
	if overlay and overlay.Visible then refreshMonumentBtn() end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function WorkshopPanel.init(
	network:      any,
	hasResearch:  (string) -> boolean,
	resourcesGet: () -> number
)
	networkRef    = network
	hasResearchFn = hasResearch
	resourcesFn   = resourcesGet

	local sg = Players.LocalPlayer.PlayerGui
		:WaitForChild("RTSHUD") :: ScreenGui

	-- ── Dim overlay (click outside to close) ─────────────────────────────────
	local ov                        = Instance.new("Frame")
	ov.Name                         = "TechGallery"
	ov.Size                         = UDim2.new(1, 0, 1, 0)
	ov.BackgroundColor3             = Color3.fromRGB(0, 0, 0)
	ov.BackgroundTransparency       = 0.45
	ov.BorderSizePixel              = 0
	ov.ZIndex                       = 48
	ov.Visible                      = false
	ov.Parent                       = sg
	overlay = ov

	local dimBlocker                = Instance.new("TextButton")
	dimBlocker.Size                 = UDim2.new(1, 0, 1, 0)
	dimBlocker.BackgroundTransparency = 1
	dimBlocker.Text                 = ""
	dimBlocker.ZIndex               = 49
	dimBlocker.Parent               = ov
	dimBlocker.MouseButton1Click:Connect(WorkshopPanel.hide)

	-- ── Panel ─────────────────────────────────────────────────────────────────
	local panel                     = Instance.new("Frame")
	panel.Name                      = "Panel"
	panel.Size                      = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.AnchorPoint               = Vector2.new(0.5, 0.5)
	panel.Position                  = UDim2.new(0.5, 0, 0.5, 0)
	panel.BackgroundColor3          = COL_PANEL_BG
	panel.BackgroundTransparency    = 0
	panel.BorderSizePixel           = 0
	panel.ZIndex                    = 50
	panel.Parent                    = ov
	UILib.corner(panel, 14)
	UILib.stroke(panel, Color3.fromRGB(38, 48, 90), 1.5)

	-- Title bar
	local titleBar                  = Instance.new("Frame")
	titleBar.Size                   = UDim2.new(1, 0, 0, 44)
	titleBar.BackgroundColor3       = Color3.fromRGB(10, 12, 24)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel        = 0
	titleBar.ZIndex                 = 51
	titleBar.Parent                 = panel
	UILib.corner(titleBar, 14)
	-- square off bottom corners
	local sq                        = Instance.new("Frame")
	sq.Size                         = UDim2.new(1, 0, 0, 14)
	sq.Position                     = UDim2.new(0, 0, 1, -14)
	sq.BackgroundColor3             = Color3.fromRGB(10, 12, 24)
	sq.BorderSizePixel              = 0
	sq.ZIndex                       = 51
	sq.Parent                       = titleBar

	UILib.lbl(titleBar, "⚗  TECH GALLERY",
		UDim2.new(1, -50, 1, 0), UDim2.fromOffset(14, 0),
		{ bold = true, size = 16, color = C.TEXT, zIndex = 52 })

	local closeBtn                  = Instance.new("TextButton")
	closeBtn.Size                   = UDim2.fromOffset(28, 28)
	closeBtn.Position               = UDim2.new(1, -36, 0.5, -14)
	closeBtn.BackgroundColor3       = Color3.fromRGB(130, 30, 30)
	closeBtn.BackgroundTransparency = 0.1
	closeBtn.BorderSizePixel        = 0
	closeBtn.Font                   = Enum.Font.GothamBold
	closeBtn.TextSize               = 13
	closeBtn.TextColor3             = C.TEXT
	closeBtn.Text                   = "✕"
	closeBtn.ZIndex                 = 53
	closeBtn.Parent                 = titleBar
	UILib.corner(closeBtn, 6)
	closeBtn.MouseButton1Click:Connect(WorkshopPanel.hide)

	local Y = 44   -- running Y cursor inside panel

	-- ── Search bar ────────────────────────────────────────────────────────────
	local searchFrame               = Instance.new("Frame")
	searchFrame.Size                = UDim2.fromOffset(PANEL_W - 20, 32)
	searchFrame.Position            = UDim2.fromOffset(10, Y + 8)
	searchFrame.BackgroundColor3    = Color3.fromRGB(15, 18, 34)
	searchFrame.BackgroundTransparency = 0
	searchFrame.BorderSizePixel     = 0
	searchFrame.ZIndex              = 51
	searchFrame.Parent              = panel
	UILib.corner(searchFrame, 6)
	UILib.stroke(searchFrame, Color3.fromRGB(38, 48, 90), 1)

	UILib.lbl(searchFrame, "🔍",
		UDim2.fromOffset(28, 32), UDim2.fromOffset(4, 0),
		{ size = 13, color = C.SUBTEXT, align = Enum.TextXAlignment.Center, zIndex = 52 })

	local tb                        = Instance.new("TextBox")
	tb.Size                         = UDim2.new(1, -36, 1, 0)
	tb.Position                     = UDim2.fromOffset(30, 0)
	tb.BackgroundTransparency       = 1
	tb.Font                         = Enum.Font.Gotham
	tb.TextSize                     = 13
	tb.TextColor3                   = C.TEXT
	tb.PlaceholderText              = "Search upgrades…"
	tb.PlaceholderColor3            = C.DIM
	tb.TextXAlignment               = Enum.TextXAlignment.Left
	tb.ClearTextOnFocus             = true
	tb.ZIndex                       = 52
	tb.Parent                       = searchFrame
	searchBox = tb

	tb:GetPropertyChangedSignal("Text"):Connect(function()
		searchText = tb.Text
		rebuildCards()
	end)

	Y += 48

	-- ── Monument button ───────────────────────────────────────────────────────
	local mb                        = Instance.new("TextButton")
	mb.Size                         = UDim2.fromOffset(PANEL_W - 20, 34)
	mb.Position                     = UDim2.fromOffset(10, Y + 4)
	mb.BackgroundColor3             = Color3.fromRGB(60, 44, 0)
	mb.BackgroundTransparency       = 0
	mb.BorderSizePixel              = 0
	mb.Text                         = ""
	mb.AutoButtonColor              = false
	mb.ZIndex                       = 51
	mb.Parent                       = panel
	UILib.corner(mb, 6)
	UILib.stroke(mb, C.GOLD, 1)
	monBtn = mb

	local mLbl                      = Instance.new("TextLabel")
	mLbl.Size                       = UDim2.new(1, 0, 1, 0)
	mLbl.BackgroundTransparency     = 1
	mLbl.Font                       = Enum.Font.GothamBold
	mLbl.TextSize                   = 13
	mLbl.TextColor3                 = C.GOLD
	mLbl.TextXAlignment             = Enum.TextXAlignment.Center
	mLbl.Text                       = "★  BUILD MONUMENT  —  ◆ " .. Config.MONUMENT_COST
	mLbl.ZIndex                     = 52
	mLbl.Parent                     = mb
	monLabel = mLbl

	mb.MouseEnter:Connect(function()
		if localMonumentTime ~= nil then return end
		TweenService:Create(mb, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(80, 60, 0) }):Play()
	end)
	mb.MouseLeave:Connect(function()
		if localMonumentTime ~= nil then return end
		TweenService:Create(mb, TweenInfo.new(0.1), { BackgroundColor3 = Color3.fromRGB(60, 44, 0) }):Play()
	end)
	mb.MouseButton1Click:Connect(function()
		if localMonumentTime ~= nil then return end
		if (resourcesFn and resourcesFn() or 0) < Config.MONUMENT_COST then return end
		networkRef.buildMonument()
	end)

	Y += 44

	-- ── Scroll frame for cards ────────────────────────────────────────────────
	local sf                        = Instance.new("ScrollingFrame")
	sf.Name                         = "CardScroll"
	sf.Size                         = UDim2.fromOffset(PANEL_W - 20, PANEL_H - Y - 10)
	sf.Position                     = UDim2.fromOffset(10, Y + 4)
	sf.BackgroundTransparency       = 1
	sf.BorderSizePixel              = 0
	sf.ScrollBarThickness           = 5
	sf.ScrollBarImageColor3         = Color3.fromRGB(50, 60, 100)
	sf.CanvasSize                   = UDim2.fromOffset(0, 0)
	sf.ZIndex                       = 51
	sf.Parent                       = panel
	scrollFrame = sf

	-- UIGridLayout — eliminates all AbsoluteSize dependencies
	local grid                      = Instance.new("UIGridLayout")
	grid.CellSize                   = UDim2.fromOffset(CARD_W, CARD_H)
	grid.CellPadding                = UDim2.fromOffset(CARD_PAD, CARD_PAD)
	grid.HorizontalAlignment        = Enum.HorizontalAlignment.Center
	grid.SortOrder                  = Enum.SortOrder.Name
	grid.Parent                     = sf
	gridLayout = grid

	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		sf.CanvasSize = UDim2.fromOffset(0, grid.AbsoluteContentSize.Y + CARD_PAD)
	end)

	-- Manually drive scrolling from UIS so it works even when camera also
	-- listens to MouseWheel on the same InputChanged signal.
	local UserInputService = game:GetService("UserInputService")
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		if not ov.Visible then return end
		local mousePos = UserInputService:GetMouseLocation()
		local sfAbs    = sf.AbsolutePosition
		local sfSize   = sf.AbsoluteSize
		local inBounds = mousePos.X >= sfAbs.X and mousePos.X <= sfAbs.X + sfSize.X
			and mousePos.Y >= sfAbs.Y and mousePos.Y <= sfAbs.Y + sfSize.Y
		if not inBounds then return end
		local SCROLL_SPEED = 60
		sf.CanvasPosition = Vector2.new(
			0,
			math.clamp(sf.CanvasPosition.Y - input.Position.Z * SCROLL_SPEED, 0,
				math.max(0, grid.AbsoluteContentSize.Y - sf.AbsoluteSize.Y + CARD_PAD))
		)
	end)

	refreshMonumentBtn()
end

return WorkshopPanel
