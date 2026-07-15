--[[
	MainMenu, the first screen the player sees.

	A tabbed shell with a persistent tab bar along the top. Selecting a tab swaps
	the content beneath it while the bar stays put:

	  • LUCENT        → the landing panel: wordmark, tagline, and a big JOIN button
	                    (JOIN just selects the READY UP tab).
	  • READY UP      → reveals the Map/AI ready-up lobby *beneath* the tab bar by
	                    hiding this menu's backdrop. The lobby (LobbyUI) is a separate
	                    ScreenGui at a lower DisplayOrder; we flip it visible/hidden as
	                    the tab is entered/left, so the bar never disappears. The lobby
	                    still owns the game-start flow, when its countdown begins it
	                    calls MainMenu.close() to drop this chrome for the transition.
	  • TUTORIAL      → an in-menu "How to Play" panel.
	  • CUSTOMIZATION → not built yet; the panel just reads "Coming soon".

	Everything is client-side. A UIScale on the content container keeps the layout
	proportional across resolutions; the full-screen backdrop lives behind it.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UnitVisuals = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UnitVisuals"))

local MainMenu    = {}
local localPlayer = Players.LocalPlayer

-- Reference resolution for the content UIScale.
local DESIGN_W, DESIGN_H = 1280, 720

-- Module-level teardown so the lobby's game-start transition can drop this chrome
-- via MainMenu.close() from outside the init closure.
local activeClose: (() -> ())? = nil

-- ── Palette ───────────────────────────────────────────────────────────────────
local C_GOLD    = Color3.fromRGB(232, 196, 120)
local C_ACCENT  = Color3.fromRGB(120, 224, 255)
local C_PANEL   = Color3.fromRGB( 12,  15,  22)
local C_PANEL_HI= Color3.fromRGB( 20,  25,  35)
local C_BORDER  = Color3.fromRGB( 64,  76,  98)
local C_TITLE   = Color3.fromRGB(238, 240, 245)
local C_TEXT    = Color3.fromRGB(206, 214, 228)
local C_SUBTEXT = Color3.fromRGB(120, 134, 158)
local C_TAB_OFF = Color3.fromRGB( 16,  20,  28)

-- ── Small helpers ───────────────────────────────────────────────────────────
local function corner(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: GuiObject, color: Color3, thick: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick
	s.Parent = inst
	return s
end

local function gradient(inst: GuiObject, c1: Color3, c2: Color3, rot: number): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c1, c2)
	g.Rotation = rot
	g.Parent = inst
	return g
end

local function label(
	parent: Instance, text: string, size: number, color: Color3, font: Enum.Font,
	uiSize: UDim2, pos: UDim2, align: Enum.TextXAlignment?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Text = text; l.TextSize = size; l.TextColor3 = color; l.Font = font
	l.Size = uiSize; l.Position = pos
	l.BackgroundTransparency = 1
	l.TextXAlignment = align or Enum.TextXAlignment.Center
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Parent = parent
	return l
end

-- Tear down whatever menu is currently up (idempotent). Called on the lobby's
-- game-start transition so the tab bar doesn't float over the dramatic sequence.
function MainMenu.close()
	if activeClose then
		local fn = activeClose
		activeClose = nil
		fn()
	end
end

-- ── Public init ───────────────────────────────────────────────────────────────
-- `opts.buildLobby`      builds + shows the ready-up lobby for the first time.
-- `opts.setLobbyVisible` shows/hides the (already-built) lobby without rebuilding.
function MainMenu.init(opts: { buildLobby: () -> (), setLobbyVisible: (boolean) -> () })
	local buildLobby      = opts.buildLobby
	local setLobbyVisible = opts.setLobbyVisible

	local sg = Instance.new("ScreenGui")
	sg.Name = "MainMenu"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 120   -- above the lobby (100) so the bar/panels sit in front
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = localPlayer:WaitForChild("PlayerGui")

	-- ── Backdrop (full-screen). Hidden when READY UP reveals the lobby beneath. ─
	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BorderSizePixel = 0
	bg.ZIndex = 1
	bg.Parent = sg

	-- Mild colour glow rising from the bottom edge; its colour cycles slowly and the
	-- gradient fades it out toward the top so it reads as a soft ground haze.
	local glow = Instance.new("Frame")
	glow.Name = "BottomGlow"
	glow.AnchorPoint = Vector2.new(0.5, 1)
	glow.Position = UDim2.new(0.5, 0, 1, 0)
	glow.Size = UDim2.new(1, 0, 0.62, 0)
	glow.BackgroundColor3 = Color3.fromHSV(0.58, 0.5, 0.5)
	glow.BorderSizePixel = 0
	glow.ZIndex = 2
	glow.Parent = bg
	local glowGrad = Instance.new("UIGradient")
	glowGrad.Rotation = 90   -- runs top → bottom
	glowGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),    -- fully faded at the top
		NumberSequenceKeypoint.new(0.7, 0.78),
		NumberSequenceKeypoint.new(1, 0.42),   -- mild at the very bottom
	})
	glowGrad.Parent = glow

	-- ── Scaled content container. Sibling of bg (NOT a child) so hiding bg keeps
	--    the tab bar visible over the lobby. ────────────────────────────────────
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.fromOffset(DESIGN_W, DESIGN_H)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundTransparency = 1
	container.ZIndex = 5
	container.Parent = sg

	local uiScale = Instance.new("UIScale")
	uiScale.Parent = container
	local function rescale()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		uiScale.Scale = math.min(vp.X / DESIGN_W, vp.Y / DESIGN_H)
	end
	rescale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

	-- Small wordmark up top-left so the tab bar has an anchor.
	local brand = label(container, "LUCENT", 28, C_TITLE, Enum.Font.GothamBlack,
		UDim2.fromOffset(320, 38), UDim2.fromOffset(70, 22), Enum.TextXAlignment.Left)
	gradient(brand, Color3.fromRGB(248, 250, 255), C_GOLD, 90)
	local brandStroke = stroke(brand, C_GOLD, 1); brandStroke.Transparency = 0.6

	-- ── Tab bar ───────────────────────────────────────────────────────────────
	-- Kept compact and high so the ready-up lobby, shown beneath it, has room below.
	local TAB_Y   = 22
	local TAB_H   = 38
	local TAB_GAP = 10

	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.AnchorPoint = Vector2.new(1, 0)
	tabBar.Size = UDim2.fromOffset(720, TAB_H)
	tabBar.Position = UDim2.fromOffset(DESIGN_W - 70, TAB_Y)
	tabBar.BackgroundTransparency = 1
	tabBar.ZIndex = 6
	tabBar.Parent = container
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Padding = UDim.new(0, TAB_GAP)
	tabLayout.Parent = tabBar

	-- Divider under the header/tab strip.
	local headerRule = Instance.new("Frame")
	headerRule.Name = "HeaderRule"
	headerRule.Size = UDim2.new(1, -140, 0, 1)
	headerRule.Position = UDim2.fromOffset(70, TAB_Y + TAB_H + 14)
	headerRule.BackgroundColor3 = C_BORDER
	headerRule.BackgroundTransparency = 0.4
	headerRule.BorderSizePixel = 0
	headerRule.ZIndex = 5
	headerRule.Parent = container

	-- ── Content region (holds the Lucent/Tutorial/Customization panels) ─────────
	local CONTENT_Y = TAB_Y + TAB_H + 30
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -140, 1, -(CONTENT_Y + 50))
	content.Position = UDim2.fromOffset(70, CONTENT_Y)
	content.BackgroundTransparency = 1
	content.ZIndex = 4
	content.Parent = container

	-- Registry of tab buttons and their content panels.
	local tabDefs   = { "Lucent", "ReadyUp", "Tutorial", "Customization" }
	local tabLabels = { Lucent = "LUCENT", ReadyUp = "READY UP", Tutorial = "TUTORIAL", Customization = "CUSTOMIZATION" }
	local tabButtons: { [string]: TextButton } = {}
	local tabUnderlines: { [string]: Frame } = {}
	local panels: { [string]: Frame } = {}
	local dismissed = false
	local activeTab = "Lucent"
	local lobbyBuilt = false

	local function makeTab(name: string, order: number)
		local btn = Instance.new("TextButton")
		btn.Name = name .. "Tab"
		btn.Size = UDim2.fromOffset(name == "Customization" and 168 or 130, TAB_H)
		btn.BackgroundColor3 = C_TAB_OFF
		btn.BackgroundTransparency = 0.2
		btn.AutoButtonColor = false
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 16
		btn.TextColor3 = C_SUBTEXT
		btn.Text = tabLabels[name]
		btn.LayoutOrder = order
		btn.ZIndex = 6
		btn.Parent = tabBar
		corner(btn, 6)
		local st = stroke(btn, C_BORDER, 1); st.Transparency = 0.5

		-- Gold underline that appears on the active tab.
		local underline = Instance.new("Frame")
		underline.Name = "Underline"
		underline.AnchorPoint = Vector2.new(0.5, 1)
		underline.Position = UDim2.new(0.5, 0, 1, -4)
		underline.Size = UDim2.fromOffset(0, 2)
		underline.BackgroundColor3 = C_GOLD
		underline.BorderSizePixel = 0
		underline.ZIndex = 7
		underline.Parent = btn

		btn.MouseEnter:Connect(function()
			if activeTab == name then return end
			TweenService:Create(btn, TweenInfo.new(0.12), { TextColor3 = C_TEXT, BackgroundTransparency = 0 }):Play()
			TweenService:Create(st, TweenInfo.new(0.12), { Transparency = 0.2, Color = C_ACCENT }):Play()
		end)
		btn.MouseLeave:Connect(function()
			if activeTab == name then return end
			TweenService:Create(btn, TweenInfo.new(0.12), { TextColor3 = C_SUBTEXT, BackgroundTransparency = 0.2 }):Play()
			TweenService:Create(st, TweenInfo.new(0.12), { Transparency = 0.5, Color = C_BORDER }):Play()
		end)

		tabButtons[name]    = btn
		tabUnderlines[name] = underline
	end

	for i, name in tabDefs do makeTab(name, i) end

	-- ── Panels ────────────────────────────────────────────────────────────────
	local function newPanel(name: string): Frame
		local p = Instance.new("Frame")
		p.Name = name .. "Panel"
		p.Size = UDim2.new(1, 0, 1, 0)
		p.BackgroundTransparency = 1
		p.Visible = false
		p.ZIndex = 4
		p.Parent = content
		panels[name] = p
		return p
	end

	-- Forward declaration so the JOIN button can drive tab selection.
	local setTab

	-- LUCENT: big wordmark, tagline, and a large JOIN button.
	do
		local p = newPanel("Lucent")

		local hero = label(p, "LUCENT", 108, C_TITLE, Enum.Font.GothamBlack,
			UDim2.new(1, 0, 0, 120), UDim2.new(0, 0, 0, 40))
		gradient(hero, Color3.fromRGB(248, 250, 255), C_GOLD, 90)
		local heroStroke = stroke(hero, C_GOLD, 1.6); heroStroke.Transparency = 0.5

		label(p, "R E A L - T I M E   S T R A T E G Y", 18, C_SUBTEXT, Enum.Font.GothamMedium,
			UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 0, 168))

		local join = Instance.new("TextButton")
		join.Name = "JoinButton"
		join.AnchorPoint = Vector2.new(0.5, 0)
		join.Size = UDim2.fromOffset(300, 76)
		join.Position = UDim2.new(0.5, 0, 0, 240)
		join.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		join.BorderSizePixel = 0
		join.AutoButtonColor = false
		join.Font = Enum.Font.GothamBlack
		join.TextSize = 30
		join.TextColor3 = Color3.fromRGB(54, 38, 6)
		join.Text = "JOIN GAME"
		join.ZIndex = 5
		join.Parent = p
		corner(join, 8)
		gradient(join, Color3.fromRGB(255, 248, 196), Color3.fromRGB(255, 204, 56), 90)
		local joinStroke = stroke(join, Color3.fromRGB(255, 226, 120), 2); joinStroke.Transparency = 0.4
		TweenService:Create(joinStroke,
			TweenInfo.new(1.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 0.05, Thickness = 3 }
		):Play()
		join.MouseEnter:Connect(function()
			TweenService:Create(join, TweenInfo.new(0.12), { Size = UDim2.fromOffset(316, 80), TextSize = 32 }):Play()
		end)
		join.MouseLeave:Connect(function()
			TweenService:Create(join, TweenInfo.new(0.12), { Size = UDim2.fromOffset(300, 76), TextSize = 30 }):Play()
		end)
		join.MouseButton1Click:Connect(function() setTab("ReadyUp") end)

		label(p, "Select a map, add AI, and ready up to begin.", 15, C_SUBTEXT, Enum.Font.Gotham,
			UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 328))
	end

	-- TUTORIAL: an in-menu "How to Play" card.
	do
		local p = newPanel("Tutorial")

		local card = Instance.new("Frame")
		card.AnchorPoint = Vector2.new(0.5, 0)
		card.Size = UDim2.fromOffset(720, 360)
		card.Position = UDim2.new(0.5, 0, 0, 30)
		card.BackgroundColor3 = C_PANEL
		card.BackgroundTransparency = 0.05
		card.BorderSizePixel = 0
		card.ZIndex = 5
		card.Parent = p
		corner(card, 10)
		local cs = stroke(card, C_BORDER, 1); cs.Transparency = 0.2
		gradient(card, C_PANEL_HI, C_PANEL, 90)

		label(card, "◆  HOW TO PLAY", 18, C_GOLD, Enum.Font.GothamBold,
			UDim2.new(1, -48, 0, 24), UDim2.fromOffset(28, 22), Enum.TextXAlignment.Left)

		local lines = {
			"Your Command Core is placed automatically at your base, protect it.",
			"Build Foundries near glowing deposits to bring in resources over time.",
			"Raise Bonfires to summon your army; upgrade them to grow your forces.",
			"Select units by dragging a box, then right-click to move or attack.",
			"Wipe out the enemy Core before they destroy yours to win the match.",
		}
		local ly = 66
		for _, text in lines do
			-- Bullet diamond
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(8, 8)
			dot.Position = UDim2.fromOffset(32, ly + 5)
			dot.Rotation = 45
			dot.BackgroundColor3 = C_ACCENT
			dot.BorderSizePixel = 0
			dot.ZIndex = 6
			dot.Parent = card
			local ln = label(card, text, 16, C_TEXT, Enum.Font.Gotham,
				UDim2.new(1, -80, 0, 44), UDim2.fromOffset(52, ly), Enum.TextXAlignment.Left)
			ln.TextWrapped = true
			ln.ZIndex = 6
			ly += 52
		end
	end

	-- CUSTOMIZATION: a live 3D preview of three Hollowed creatures with two colour
	-- options, Body (the dark overall flesh) and Signature (the glowing eyes/vents).
	-- Preview-only for now: the picks recolour the viewport but aren't saved anywhere.
	do
		local p = newPanel("Customization")

		-- Colour palettes. The first swatch of each is the canonical Hollowed look.
		local BODY_COLORS = {
			{ name = "Void Black",  c = Color3.fromRGB( 44,  42,  56) },  -- original dark flesh
			{ name = "Ash Grey",    c = Color3.fromRGB( 78,  82,  92) },
			{ name = "Bone Pale",   c = Color3.fromRGB(126, 116, 100) },
			{ name = "Blood Hide",  c = Color3.fromRGB( 74,  26,  32) },
		}
		local SIG_COLORS = {
			{ name = "Ember Orange", c = Color3.fromRGB(255, 120,  60) },  -- original glow
			{ name = "Toxic Green",  c = Color3.fromRGB(120, 255, 140) },
			{ name = "Void Violet",  c = Color3.fromRGB(190, 110, 255) },
			{ name = "Ice Cyan",     c = Color3.fromRGB(110, 224, 255) },
		}
		local curBody = BODY_COLORS[1].c
		local curSig  = SIG_COLORS[1].c

		local card = Instance.new("Frame")
		card.AnchorPoint = Vector2.new(0.5, 0)
		card.Size = UDim2.fromOffset(900, 440)
		card.Position = UDim2.new(0.5, 0, 0, 16)
		card.BackgroundColor3 = C_PANEL
		card.BackgroundTransparency = 0.05
		card.BorderSizePixel = 0
		card.ZIndex = 5
		card.Parent = p
		corner(card, 10)
		local cs = stroke(card, C_BORDER, 1); cs.Transparency = 0.2
		gradient(card, C_PANEL_HI, C_PANEL, 90)

		label(card, "◆  CUSTOMIZE YOUR HOLLOWED", 18, C_GOLD, Enum.Font.GothamBold,
			UDim2.new(1, -48, 0, 24), UDim2.fromOffset(28, 20), Enum.TextXAlignment.Left)

		-- "COMING SOON" pill in the top-right corner: this screen is a preview only.
		local soon = Instance.new("TextLabel")
		soon.AnchorPoint = Vector2.new(1, 0)
		soon.Size = UDim2.fromOffset(150, 26)
		soon.Position = UDim2.fromOffset(900 - 24, 20)
		soon.BackgroundColor3 = C_GOLD
		soon.BackgroundTransparency = 0.12
		soon.BorderSizePixel = 0
		soon.Font = Enum.Font.GothamBlack
		soon.TextSize = 13
		soon.TextColor3 = Color3.fromRGB(30, 24, 10)
		soon.Text = "COMING SOON"
		soon.ZIndex = 7
		soon.Parent = card
		corner(soon, 6)

		-- ── Live viewport (left) ────────────────────────────────────────────────
		local vpHolder = Instance.new("Frame")
		vpHolder.Size = UDim2.fromOffset(520, 356)
		vpHolder.Position = UDim2.fromOffset(24, 62)
		vpHolder.BackgroundColor3 = Color3.fromRGB(8, 11, 18)
		vpHolder.BorderSizePixel = 0
		vpHolder.ClipsDescendants = true
		vpHolder.ZIndex = 6
		vpHolder.Parent = card
		corner(vpHolder, 8)
		local vhs = stroke(vpHolder, C_BORDER, 1); vhs.Transparency = 0.35
		gradient(vpHolder, Color3.fromRGB(14, 18, 28), Color3.fromRGB(7, 9, 15), 90)

		local vpf = Instance.new("ViewportFrame")
		vpf.Size = UDim2.new(1, 0, 1, 0)
		vpf.BackgroundTransparency = 1
		vpf.Ambient = Color3.fromRGB(150, 150, 158)
		vpf.LightColor = Color3.fromRGB(255, 244, 224)
		vpf.LightDirection = Vector3.new(-0.6, -1, -0.4)
		vpf.ZIndex = 6
		vpf.Parent = vpHolder

		label(vpHolder, "LIVE", 11, C_SUBTEXT, Enum.Font.GothamBold,
			UDim2.fromOffset(60, 14), UDim2.fromOffset(12, 10), Enum.TextXAlignment.Left).ZIndex = 7

		-- Build three Hollowed creatures, each in its own Model so it can idle. The
		-- Broodmother (tallest) sits in the centre, flanked by two reared eels.
		local UNIT_DEFS = {
			{ t = "Lamprey",     x = -13 },
			{ t = "Broodmother", x =   0 },
			{ t = "Hagfish",     x =  15 },
		}
		local models:    { Model }   = {}
		local bases:     { CFrame }  = {}
		local bodyParts: { BasePart } = {}
		local sigParts:  { BasePart } = {}

		for _, def in UNIT_DEFS do
			local m = Instance.new("Model")
			m.Name = def.t
			UnitVisuals.buildUnitPreview(m, def.t, BrickColor.new("Really black"))

			-- Classify parts by role: Neon → glowing signature; dark SmoothPlastic →
			-- body flesh. Teeth/maw/dirt (bright or non-plastic) are left untouched.
			for _, part in m:GetDescendants() do
				if part:IsA("BasePart") then
					if part.Material == Enum.Material.Neon then
						table.insert(sigParts, part)
					elseif part.Material == Enum.Material.SmoothPlastic
						and math.max(part.Color.R, part.Color.G, part.Color.B) < 0.36 then
						table.insert(bodyParts, part)
					end
				end
			end

			-- Sit its feet on a common ground line at the requested column.
			local _, size = m:GetBoundingBox()
			local base = CFrame.new(def.x, size.Y / 2, 0)
			m:PivotTo(base)
			m.Parent = vpf
			table.insert(models, m)
			table.insert(bases, base)
		end

		-- Frame a camera on the whole line-up (front-quarter view, slightly above).
		local minX, minY, minZ =  math.huge,  math.huge,  math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, m in models do
			for _, part in m:GetDescendants() do
				if part:IsA("BasePart") and part.Transparency < 0.99 then
					local pp, hs = part.Position, part.Size / 2
					minX = math.min(minX, pp.X - hs.X); maxX = math.max(maxX, pp.X + hs.X)
					minY = math.min(minY, pp.Y - hs.Y); maxY = math.max(maxY, pp.Y + hs.Y)
					minZ = math.min(minZ, pp.Z - hs.Z); maxZ = math.max(maxZ, pp.Z + hs.Z)
				end
			end
		end
		local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
		local extent = math.max(maxX - minX, maxY - minY) + 4
		local FOV = 26
		local dist = (extent / 2) / math.tan(math.rad(FOV / 2)) * 1.08
		local dir  = Vector3.new(0.34, 0.24, -1).Unit
		local cam  = Instance.new("Camera")
		cam.FieldOfView = FOV
		cam.CFrame = CFrame.lookAt(center + dir * dist, center)
		cam.Parent = vpf
		vpf.CurrentCamera = cam

		-- Apply the currently-selected colours to every classified part.
		local function applyColors()
			for _, part in bodyParts do part.Color = curBody end
			for _, part in sigParts  do part.Color = curSig  end
		end
		applyColors()

		-- ── Colour options (right) ──────────────────────────────────────────────
		local OPT_X   = 568
		local SW_SIZE = 46
		local SW_GAP  = 14

		local function makeOptionRow(titleText: string, caption: string, y: number,
			colors: { { name: string, c: Color3 } }, initial: number, onPick: (Color3) -> ()
		)
			label(card, titleText, 14, C_GOLD, Enum.Font.GothamBold,
				UDim2.new(0, 300, 0, 18), UDim2.fromOffset(OPT_X, y), Enum.TextXAlignment.Left)
			label(card, caption, 12, C_SUBTEXT, Enum.Font.Gotham,
				UDim2.new(0, 300, 0, 16), UDim2.fromOffset(OPT_X, y + 20), Enum.TextXAlignment.Left)

			local nameLbl = label(card, colors[initial].name, 12, C_TEXT, Enum.Font.GothamMedium,
				UDim2.new(0, 300, 0, 16), UDim2.fromOffset(OPT_X, y + 44 + SW_SIZE + 8), Enum.TextXAlignment.Left)

			local strokes: { UIStroke } = {}
			local function select(i: number)
				for j, st in strokes do
					local on = j == i
					st.Color = on and C_GOLD or C_BORDER
					st.Thickness = on and 3 or 1
					st.Transparency = on and 0 or 0.5
				end
				nameLbl.Text = colors[i].name
				onPick(colors[i].c)
			end

			for i, def in colors do
				local sw = Instance.new("TextButton")
				sw.Size = UDim2.fromOffset(SW_SIZE, SW_SIZE)
				sw.Position = UDim2.fromOffset(OPT_X + (i - 1) * (SW_SIZE + SW_GAP), y + 44)
				sw.BackgroundColor3 = def.c
				sw.AutoButtonColor = false
				sw.BorderSizePixel = 0
				sw.Text = ""
				sw.ZIndex = 6
				sw.Parent = card
				corner(sw, 6)
				local st = stroke(sw, C_BORDER, 1); st.Transparency = 0.5
				strokes[i] = st
				sw.MouseButton1Click:Connect(function() select(i) end)
			end
			select(initial)
		end

		makeOptionRow("BODY", "The creature's overall flesh colour.", 70,
			BODY_COLORS, 1, function(c) curBody = c; applyColors() end)
		makeOptionRow("SIGNATURE", "The glow of its eyes, vents and orbs.", 236,
			SIG_COLORS, 1, function(c) curSig = c; applyColors() end)

		label(card, "Preview only, your picks aren't saved into a match yet.", 12, C_SUBTEXT,
			Enum.Font.Gotham, UDim2.new(0, 320, 0, 16), UDim2.fromOffset(OPT_X, 400), Enum.TextXAlignment.Left)

		-- ── Idle animation ──────────────────────────────────────────────────────
		-- Each creature breathes (vertical bob) and sways gently. Runs only while the
		-- Customization tab is showing; self-disconnects when the menu is torn down.
		local phase = { 0.0, 1.3, 2.4 }
		local idleConn: RBXScriptConnection
		idleConn = RunService.RenderStepped:Connect(function()
			if not sg.Parent then idleConn:Disconnect(); return end
			if activeTab ~= "Customization" then return end
			local now = os.clock()
			for i, m in models do
				local ph   = phase[i] or 0
				local bob  = math.sin(now * 1.5 + ph) * 0.35
				local sway = math.rad(math.sin(now * 0.8 + ph) * 5)
				m:PivotTo(bases[i] * CFrame.new(0, bob, 0) * CFrame.Angles(0, sway, 0))
			end
		end)
	end

	-- ── Cameras ───────────────────────────────────────────────────────────────
	-- The menu's own scriptable view (used by every tab except READY UP, which
	-- hands the camera to the lobby's overhead shot).
	local function menuCamera()
		local cam = workspace.CurrentCamera
		if not cam then return end
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 60, 40), Vector3.new(0, 0, 0))
	end

	-- ── Tab switching ─────────────────────────────────────────────────────────
	local function styleTab(name: string, active: boolean)
		local btn = tabButtons[name]
		local underline = tabUnderlines[name]
		local st = btn:FindFirstChildOfClass("UIStroke")
		if active then
			btn.TextColor3 = C_GOLD
			btn.BackgroundTransparency = 0
			if st then st.Color = C_GOLD; st.Transparency = 0.1 end
			TweenService:Create(underline, TweenInfo.new(0.18), { Size = UDim2.fromOffset(btn.Size.X.Offset - 24, 2) }):Play()
		else
			btn.TextColor3 = C_SUBTEXT
			btn.BackgroundTransparency = 0.2
			if st then st.Color = C_BORDER; st.Transparency = 0.5 end
			underline.Size = UDim2.fromOffset(0, 2)
		end
	end

	-- Reveal the ready-up lobby beneath the tab bar: hide the backdrop, and build
	-- (first time) or re-show the lobby ScreenGui.
	local function enterLobbyTab()
		bg.Visible = false
		if not lobbyBuilt then
			buildLobby()
			lobbyBuilt = true
		else
			setLobbyVisible(true)
		end
	end

	-- Leaving READY UP: hide the lobby, restore the backdrop + menu camera.
	local function leaveLobbyTab()
		if lobbyBuilt then setLobbyVisible(false) end
		bg.Visible = true
		menuCamera()
	end

	function setTab(name: string)
		if dismissed then return end
		local leavingLobby = (activeTab == "ReadyUp") and (name ~= "ReadyUp")
		activeTab = name
		for _, tName in tabDefs do
			styleTab(tName, tName == name)
			if panels[tName] then panels[tName].Visible = (tName == name) end
		end
		if name == "ReadyUp" then
			enterLobbyTab()
		elseif leavingLobby then
			leaveLobbyTab()
		end
	end

	for _, name in tabDefs do
		local capture = name
		tabButtons[name].MouseButton1Click:Connect(function() setTab(capture) end)
	end

	setTab("Lucent")

	-- Slow hue cycle on the bottom glow.
	local hue = 0.58
	local cycleConn: RBXScriptConnection
	cycleConn = RunService.RenderStepped:Connect(function(dt)
		hue = (hue + dt * 0.02) % 1   -- ~50s per full loop
		glow.BackgroundColor3 = Color3.fromHSV(hue, 0.5, 0.5)
	end)

	-- Present the menu behind a fresh scriptable camera so nothing from the
	-- default view bleeds through before the player picks a tab.
	task.spawn(menuCamera)

	-- ── Teardown ──────────────────────────────────────────────────────────────
	-- Register the close hook so MainMenu.close() (fired by the lobby's game-start
	-- transition) can drop the whole menu, bar and all, for the full-screen
	-- sequence. The lobby ScreenGui is separate and continues its own transition.
	activeClose = function()
		if dismissed then return end
		dismissed = true
		if cycleConn then cycleConn:Disconnect() end
		sg:Destroy()
	end
end

return MainMenu
