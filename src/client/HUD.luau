local Players = game:GetService("Players")

local HUD         = {}
local localPlayer = Players.LocalPlayer

local resLabel: TextLabel?
local selLabel: TextLabel?
local currentResources = 0
local currentIncome    = 0

-- Build menu state
local buildMenuBtnRef: TextButton?
local buildMenuTray:   Frame?
local buildMenuOpen    = false
local cancelBtnRef:    TextButton?
local ccBtnRef:        TextButton?

-- Individual build buttons (inside tray, returned for wiring)
local buildBtnRef:  TextButton?
local mineBtnRef:   TextButton?
local turretBtnRef: TextButton?

-- Tooltip refs
local tooltipFrame: Frame?
local tooltipTitle: TextLabel?
local tooltipDesc:  TextLabel?
local tooltipReqs:  TextLabel?

-- Requirement system state
local playerCounts: { [string]: number } = {}
local currentActivePlacing: string?      = nil

-- Building metadata: description + what each type requires
local BUILDING_INFO: { [string]: { desc: string, requires: { [string]: number } } } = {
	Mine     = { desc = "Extracts resources from mineral deposits. Max 3.",    requires = {} },
	Barracks = { desc = "Trains soldiers and tanks for your army.",             requires = { Mine = 1 } },
	Turret   = { desc = "Defensive cannon that attacks nearby enemies.",        requires = { Barracks = 1 } },
}

-- Colours
local BLUE     = Color3.fromRGB(40,  90, 150)
local GOLD     = Color3.fromRGB(160, 120,  10)
local ORANGE   = Color3.fromRGB(170,  80,  20)
local RED      = Color3.fromRGB(160,  50,  50)
local TEAL     = Color3.fromRGB(20,  130, 120)
local GREEN2   = Color3.fromRGB(35,  110,  40)
local GRAY     = Color3.fromRGB(50,   50,  55)
local DARK     = Color3.fromRGB(20,   20,  20)
local WHITE    = Color3.new(1, 1, 1)
local SUBTEXT  = Color3.fromRGB(160, 180, 210)
local DIM_TEXT = Color3.fromRGB(90,   90, 100)

-- ── Requirement helpers ───────────────────────────────────────────────────────

local function isUnlocked(buildingType: string): boolean
	local info = BUILDING_INFO[buildingType]
	if not info then return true end
	for reqType, reqCount in info.requires do
		if (playerCounts[reqType] or 0) < reqCount then return false end
	end
	return true
end

-- Recolour each tray button to reflect locked / active / normal state.
local function updateTrayButtonVisuals(activePlacing: string?)
	local entries = {
		{ btype = "Mine",     btn = mineBtnRef,   normal = GOLD   },
		{ btype = "Barracks", btn = buildBtnRef,  normal = BLUE   },
		{ btype = "Turret",   btn = turretBtnRef, normal = ORANGE },
	}
	for _, e in entries do
		local btn = e.btn
		if not btn then continue end
		if not isUnlocked(e.btype) then
			btn.BackgroundColor3 = GRAY
			btn.TextColor3       = DIM_TEXT
		elseif activePlacing == e.btype then
			btn.BackgroundColor3 = RED
			btn.TextColor3       = WHITE
		else
			btn.BackgroundColor3 = e.normal
			btn.TextColor3       = WHITE
		end
	end
end

-- ── Label / button factories ──────────────────────────────────────────────────

local function refreshResLabel()
	if not resLabel then return end
	local text = "Resources: " .. currentResources
	if currentIncome > 0 then text ..= "  (+" .. currentIncome .. "/min)" end
	resLabel.Text = text
end

local function makeLabel(parent: Instance, text: string, pos: UDim2, size: UDim2): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Text                   = text
	l.Position               = pos
	l.Size                   = size
	l.BackgroundColor3       = DARK
	l.BackgroundTransparency = 0.4
	l.TextColor3             = WHITE
	l.TextScaled             = true
	l.Font                   = Enum.Font.GothamBold
	l.Parent                 = parent
	return l
end

local function makeButton(parent: Instance, text: string, pos: UDim2, size: UDim2, color: Color3?): TextButton
	local b                  = Instance.new("TextButton")
	b.Text                   = text
	b.Position               = pos
	b.Size                   = size
	b.BackgroundColor3       = color or BLUE
	b.TextColor3             = WHITE
	b.TextScaled             = true
	b.Font                   = Enum.Font.GothamBold
	b.Parent                 = parent
	local c                  = Instance.new("UICorner")
	c.CornerRadius           = UDim.new(0, 6)
	c.Parent                 = b
	return b
end

-- ── Tooltip ───────────────────────────────────────────────────────────────────

local function hideTooltip()
	if tooltipFrame then tooltipFrame.Visible = false end
end

local function showTooltip(buildingType: string, button: TextButton)
	if not tooltipFrame then return end
	local info = BUILDING_INFO[buildingType]
	if not info then hideTooltip(); return end

	if tooltipTitle then tooltipTitle.Text = buildingType:upper() end
	if tooltipDesc  then tooltipDesc.Text  = info.desc end

	if tooltipReqs then
		if next(info.requires) == nil then
			tooltipReqs.Text       = "No requirements"
			tooltipReqs.TextColor3 = SUBTEXT
		else
			local parts = {}
			for reqType, reqCount in info.requires do
				local have = (playerCounts[reqType] or 0) >= reqCount
				local mark = have and "✓" or "✗"
				table.insert(parts, mark .. " Requires " .. reqType .. " ×" .. reqCount)
			end
			tooltipReqs.Text       = table.concat(parts, "\n")
			tooltipReqs.TextColor3 = isUnlocked(buildingType)
				and Color3.fromRGB(80, 200, 90)
				or  Color3.fromRGB(220, 55, 55)
		end
	end

	-- Position tooltip to the right of the tray (tray left=10, width=152, gap=8 → x=170)
	local absY = button.AbsolutePosition.Y
	tooltipFrame.Position = UDim2.fromOffset(170, absY)
	tooltipFrame.Visible  = true
end

-- ── Tray open / close ─────────────────────────────────────────────────────────

local function setTrayOpen(open: boolean)
	buildMenuOpen = open
	if not open then hideTooltip() end
	if buildMenuTray   then buildMenuTray.Visible = open end
	if buildMenuBtnRef then
		buildMenuBtnRef.Text             = open and "Build  ▲" or "Build  ▼"
		buildMenuBtnRef.BackgroundColor3 = open and GREEN2 or BLUE
	end
end

-- ── create ────────────────────────────────────────────────────────────────────

function HUD.create(): (Frame, TextButton, TextButton, TextButton, TextButton, TextButton)
	local sg               = Instance.new("ScreenGui")
	sg.Name                = "RTSHUD"
	sg.ResetOnSpawn        = false
	sg.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
	sg.Parent              = localPlayer.PlayerGui

	resLabel = makeLabel(sg, "Resources: 400",
		UDim2.fromOffset(10, 10), UDim2.fromOffset(260, 42))

	selLabel = makeLabel(sg, "",
		UDim2.new(0.5, -120, 0, 10), UDim2.fromOffset(240, 42))
	selLabel.BackgroundTransparency = 1

	local dragFrame                  = Instance.new("Frame")
	dragFrame.Name                   = "DragSelect"
	dragFrame.BackgroundColor3       = Color3.fromRGB(100, 200, 255)
	dragFrame.BackgroundTransparency = 0.7
	dragFrame.BorderSizePixel        = 1
	dragFrame.BorderColor3           = Color3.fromRGB(160, 220, 255)
	dragFrame.Visible                = false
	dragFrame.ZIndex                 = 20
	dragFrame.Parent                 = sg

	-- CC placement button (centred at bottom)
	local ccBtn = makeButton(sg, "Place Command Center",
		UDim2.new(0.5, -130, 1, -60), UDim2.fromOffset(260, 50), TEAL)
	ccBtnRef    = ccBtn

	-- ── Build tray ────────────────────────────────────────────────────────
	local tray                       = Instance.new("Frame")
	tray.Name                        = "BuildTray"
	tray.Size                        = UDim2.fromOffset(152, 154)
	tray.Position                    = UDim2.new(0, 10, 1, -222)
	tray.BackgroundColor3            = Color3.fromRGB(18, 18, 18)
	tray.BackgroundTransparency      = 0.18
	tray.Visible                     = false
	tray.ZIndex                      = 8
	tray.Parent                      = sg

	local trayCorner                 = Instance.new("UICorner")
	trayCorner.CornerRadius          = UDim.new(0, 8)
	trayCorner.Parent                = tray

	local trayStroke                 = Instance.new("UIStroke")
	trayStroke.Color                 = Color3.fromRGB(60, 60, 70)
	trayStroke.Thickness             = 1
	trayStroke.Parent                = tray

	local trayLayout                 = Instance.new("UIListLayout")
	trayLayout.FillDirection         = Enum.FillDirection.Vertical
	trayLayout.SortOrder             = Enum.SortOrder.LayoutOrder
	trayLayout.Padding               = UDim.new(0, 5)
	trayLayout.Parent                = tray

	local trayPad                    = Instance.new("UIPadding")
	trayPad.PaddingTop               = UDim.new(0, 6)
	trayPad.PaddingBottom            = UDim.new(0, 6)
	trayPad.PaddingLeft              = UDim.new(0, 6)
	trayPad.PaddingRight             = UDim.new(0, 6)
	trayPad.Parent                   = tray

	-- Buttons in order: Mine (no reqs) → Barracks (needs Mine) → Turret (needs Barracks)
	local mineBtn   = makeButton(tray, "Mine  (75)",     UDim2.new(), UDim2.new(1, 0, 0, 42), GOLD)
	local buildBtn  = makeButton(tray, "Barracks  (50)", UDim2.new(), UDim2.new(1, 0, 0, 42))
	local turretBtn = makeButton(tray, "Turret  (100)",  UDim2.new(), UDim2.new(1, 0, 0, 42), ORANGE)

	buildMenuTray = tray
	buildBtnRef   = buildBtn
	mineBtnRef    = mineBtn
	turretBtnRef  = turretBtn

	-- ── Tooltip frame ─────────────────────────────────────────────────────
	local tt                         = Instance.new("Frame")
	tt.Name                          = "BuildTooltip"
	tt.Size                          = UDim2.fromOffset(210, 108)
	tt.BackgroundColor3              = Color3.fromRGB(12, 18, 34)
	tt.BackgroundTransparency        = 0.06
	tt.BorderSizePixel               = 0
	tt.Visible                       = false
	tt.ZIndex                        = 20
	tt.Parent                        = sg

	local ttCorner                   = Instance.new("UICorner")
	ttCorner.CornerRadius            = UDim.new(0, 8)
	ttCorner.Parent                  = tt

	local ttStroke                   = Instance.new("UIStroke")
	ttStroke.Color                   = Color3.fromRGB(55, 90, 150)
	ttStroke.Thickness               = 1.2
	ttStroke.Parent                  = tt

	local ttPad                      = Instance.new("UIPadding")
	ttPad.PaddingTop                 = UDim.new(0, 8)
	ttPad.PaddingLeft                = UDim.new(0, 10)
	ttPad.PaddingRight               = UDim.new(0, 10)
	ttPad.PaddingBottom              = UDim.new(0, 8)
	ttPad.Parent                     = tt

	local ttLayout                   = Instance.new("UIListLayout")
	ttLayout.FillDirection           = Enum.FillDirection.Vertical
	ttLayout.SortOrder               = Enum.SortOrder.LayoutOrder
	ttLayout.Padding                 = UDim.new(0, 5)
	ttLayout.Parent                  = tt

	local ttTitle                    = Instance.new("TextLabel")
	ttTitle.Name                     = "Title"
	ttTitle.LayoutOrder              = 1
	ttTitle.Size                     = UDim2.new(1, 0, 0, 18)
	ttTitle.BackgroundTransparency   = 1
	ttTitle.TextColor3               = WHITE
	ttTitle.Font                     = Enum.Font.GothamBold
	ttTitle.TextSize                 = 14
	ttTitle.TextXAlignment           = Enum.TextXAlignment.Left
	ttTitle.Parent                   = tt

	local ttDesc                     = Instance.new("TextLabel")
	ttDesc.Name                      = "Desc"
	ttDesc.LayoutOrder               = 2
	ttDesc.Size                      = UDim2.new(1, 0, 0, 40)
	ttDesc.BackgroundTransparency    = 1
	ttDesc.TextColor3                = SUBTEXT
	ttDesc.Font                      = Enum.Font.Gotham
	ttDesc.TextSize                  = 12
	ttDesc.TextXAlignment            = Enum.TextXAlignment.Left
	ttDesc.TextWrapped               = true
	ttDesc.Parent                    = tt

	local ttReqs                     = Instance.new("TextLabel")
	ttReqs.Name                      = "Reqs"
	ttReqs.LayoutOrder               = 3
	ttReqs.Size                      = UDim2.new(1, 0, 0, 28)
	ttReqs.BackgroundTransparency    = 1
	ttReqs.TextColor3                = SUBTEXT
	ttReqs.Font                      = Enum.Font.Gotham
	ttReqs.TextSize                  = 12
	ttReqs.TextXAlignment            = Enum.TextXAlignment.Left
	ttReqs.TextWrapped               = true
	ttReqs.Parent                    = tt

	tooltipFrame = tt
	tooltipTitle = ttTitle
	tooltipDesc  = ttDesc
	tooltipReqs  = ttReqs

	-- ── Bottom action bar ─────────────────────────────────────────────────
	local buildMenuBtn = makeButton(sg, "Build  ▼",
		UDim2.new(0, 10, 1, -60), UDim2.fromOffset(152, 50))
	buildMenuBtnRef    = buildMenuBtn

	local cancelBtn = makeButton(sg, "Cancel [Esc]",
		UDim2.new(0, 170, 1, -60), UDim2.fromOffset(145, 50), RED)
	cancelBtn.Visible  = false
	cancelBtnRef       = cancelBtn

	buildMenuBtn.Visible = false   -- hidden until CC is placed

	return dragFrame, buildBtn, mineBtn, turretBtn, cancelBtn, ccBtn
end

-- ── Public API ────────────────────────────────────────────────────────────────

function HUD.setResources(n: number)
	currentResources = n
	refreshResLabel()
end

function HUD.setIncome(perMin: number)
	currentIncome = perMin
	refreshResLabel()
end

function HUD.setCommandCenterMode(isCC: boolean)
	if ccBtnRef        then ccBtnRef.Visible        = isCC     end
	if buildMenuBtnRef then buildMenuBtnRef.Visible = not isCC end
	if cancelBtnRef    then cancelBtnRef.Visible    = false    end
	setTrayOpen(false)
end

-- Called from init.client whenever owned building counts change.
function HUD.refreshTrayState(counts: { [string]: number })
	playerCounts = counts
	updateTrayButtonVisuals(currentActivePlacing)
	hideTooltip()
end

function HUD.wire(network, unitController, buildingPlacer,
	buildBtn: TextButton, mineBtn: TextButton, turretBtn: TextButton, cancelBtn: TextButton)

	network.onResourceSync(function(n: number)
		HUD.setResources(n)
	end)

	unitController.onSelectionChanged(function(n: number)
		if selLabel then
			selLabel.Text = n > 0 and (n .. " unit" .. (n == 1 and "" or "s") .. " selected") or ""
		end
	end)

	-- Build toggle
	if buildMenuBtnRef then
		buildMenuBtnRef.MouseButton1Click:Connect(function()
			setTrayOpen(not buildMenuOpen)
		end)
	end

	-- Tray buttons — lock-aware clicks
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

	turretBtn.MouseButton1Click:Connect(function()
		if not isUnlocked("Turret") then return end
		setTrayOpen(false)
		buildingPlacer.enterPlacementMode("Turret")
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		buildingPlacer.exitPlacementMode()
	end)

	-- Hover tooltips
	mineBtn.MouseEnter:Connect(function()   showTooltip("Mine",     mineBtn)   end)
	mineBtn.MouseLeave:Connect(function()   hideTooltip()                       end)
	buildBtn.MouseEnter:Connect(function()  showTooltip("Barracks", buildBtn)  end)
	buildBtn.MouseLeave:Connect(function()  hideTooltip()                       end)
	turretBtn.MouseEnter:Connect(function() showTooltip("Turret",   turretBtn) end)
	turretBtn.MouseLeave:Connect(function() hideTooltip()                       end)

	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		currentActivePlacing = active and buildingType or nil

		if buildMenuBtnRef then
			if active and buildingType ~= "CommandCenter" then
				buildMenuBtnRef.BackgroundColor3 = RED
			elseif buildMenuOpen then
				buildMenuBtnRef.BackgroundColor3 = GREEN2
			else
				buildMenuBtnRef.BackgroundColor3 = BLUE
				buildMenuBtnRef.Text             = "Build  ▼"
			end
		end

		updateTrayButtonVisuals(currentActivePlacing)
		cancelBtn.Visible = active and (buildingType ~= "CommandCenter")
		if active then setTrayOpen(false) end
	end)
end

return HUD
