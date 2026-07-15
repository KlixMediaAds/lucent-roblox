--[[
	LobbyUI, full-screen pre-game lobby (reworked).

	Resolution independence:
	  All UI is designed at DESIGN_W×DESIGN_H. A UIScale on `container` scales
	  everything uniformly to fit the actual viewport, letterboxing if needed.
	  `bg` (full-screen backdrop) lives outside the container so it always fills
	  the screen regardless of scale.

	Layout:
	  ┌──────────┐  ┌──────────────────────────┐
	  │ MATCH    │  │                          │
	  │ SETUP    │  │       TACTICAL MAP       │  ← map on the right of the settings
	  │ • Gamemode  │       (large square)     │
	  │ • AI Diff   │                          │
	  │ • AI Count  │  └──────────────────────────┘
	  │ • Teams  │  ┌───────────────┐ ┌──────────┐
	  └──────────┘  │  COMBATANTS    │ │  READY   │  ← roster beneath the map,
	                │ [P][P][AI]…    │ │   UP     │     large READY button bottom-right
	                └───────────────┘ └──────────┘

	Sizes are ~40% larger than the previous lobby for readability.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local LobbyUI     = {}
local localPlayer = Players.LocalPlayer

-- ── Design constants ──────────────────────────────────────────────────────────
local DESIGN_W   = 960    -- reference design width
local DESIGN_H   = 900    -- reference design height

-- Player banners: up to 4 tall vertical cards (name · profile · chosen race).
local MAX_BANNERS = 4
local BANNER_W    = 140
local BANNER_H    = 300
local BANNER_GAP  = 12
local PANEL_PAD   = 16             -- inner padding of the players panel
local PANEL_HEAD  = 34             -- players-panel header height

-- Layout (design pixels)
local PANEL_W     = BANNER_W * MAX_BANNERS + BANNER_GAP * (MAX_BANNERS - 1) + PANEL_PAD * 2  -- 628
local SETTINGS_W  = 300
local GAP         = 24             -- gap between settings column and players panel
local ROSTER_GAP  = 20             -- vertical gap between panel and the ready button
local PANEL_H     = BANNER_H + PANEL_HEAD + PANEL_PAD * 2   -- 366
local READY_W     = 300
local READY_H     = 92
local HEADER_H    = 190            -- top margin: status line + clearance for the tab shell

-- Derived layout values (design space). CONTENT_H is floored at 600 so the expanded
-- settings drop-menu (taller than the players panel) never clips its faction cards.
local CONTENT_W  = SETTINGS_W + GAP + PANEL_W
local CONTENT_H  = math.max(PANEL_H + ROSTER_GAP + READY_H, 600)
local CONTENT_X  = math.floor((DESIGN_W - CONTENT_W) / 2)
local CONTENT_Y  = HEADER_H + 14

-- Collapsible settings: the players panel + ready button live in `rightGroup`, which
-- slides between a centered "settings collapsed" position and a shifted-right
-- "settings expanded" position. The settings panel itself drops open downward.
local SETTINGS_HEADER_H = 54
local SETTINGS_COLLAPSED_W = 150                                      -- compact pill when collapsed
local PANEL_X_OPEN     = CONTENT_X + SETTINGS_W + GAP
local PANEL_X_CLOSED   = math.floor((DESIGN_W - PANEL_W) / 2)          -- centered (clears the collapsed pill)

-- Game-start sounds
local SND_COUNTDOWN = "rbxassetid://131999546232546"
local SND_START     = "rbxassetid://75131546063270"

-- Faction → the unit whose 3D preview stands in for the race on a player banner.
local FACTION_UNIT  = { Humans = "Survivor", Hollowed = "Lamprey" }
local FACTION_LABEL = { Humans = "HUMANS",   Hollowed = "HOLLOWED" }

-- ── Palette ───────────────────────────────────────────────────────────────────
-- Wuthering-Waves-inspired: near-black slate, ivory text, signature gold + cyan.
local C_BG          = Color3.fromRGB(  6,   8,  13)
local C_BG2         = Color3.fromRGB( 11,  14,  21)
local C_GOLD        = Color3.fromRGB(232, 196, 120)
local C_PANEL       = Color3.fromRGB( 14,  17,  25)
local C_PANEL_HI    = Color3.fromRGB( 23,  28,  39)
local C_BORDER      = Color3.fromRGB( 64,  76,  98)
local C_GRID        = Color3.fromRGB( 22,  28,  40)
local C_TITLE       = Color3.fromRGB(238, 240, 245)
local C_TEXT        = Color3.fromRGB(206, 214, 228)
local C_SUBTEXT     = Color3.fromRGB(120, 134, 158)
local C_ACCENT      = Color3.fromRGB(120, 224, 255)
local C_DEPOSIT     = Color3.fromRGB(255, 236, 150)
local C_READY_ON    = Color3.fromRGB(232, 196, 120)
local C_READY_OFF   = Color3.fromRGB( 24,  30,  42)
local C_READY_DOT   = Color3.fromRGB(110, 224, 175)
local C_WAITING_DOT = Color3.fromRGB(206,  92,  92)
local C_SLOT        = Color3.fromRGB( 20,  25,  36)   -- inactive value button
local C_SLOT_DIS    = Color3.fromRGB( 16,  19,  27)   -- disabled (coming soon)
local C_FACTION_SEL = Color3.fromRGB( 46,  38,  22)   -- selected faction card (gold-tinted fill)
local C_TERRAIN_DOT = Color3.fromRGB( 80,  68,  58)

-- AI difficulty accent colors
local DIFF_COLORS = {
	Easy      = Color3.fromRGB(110, 210, 130),
	Medium    = Color3.fromRGB(232, 196, 120),
	Hard      = Color3.fromRGB(230, 150,  70),
	Nightmare = Color3.fromRGB(225,  90,  90),
}

-- ── Module refs ───────────────────────────────────────────────────────────────
local sg:            ScreenGui
local bg:            Frame
local glow:          Frame   -- the blue backdrop glow (turns purple as the game starts)
local silhouetteLayer: Frame -- black silhouette horde during the ready transition
local container:     Frame
local uiScaleObj:    UIScale
local rightGroup:    Frame   -- players panel + ready (slides aside when settings open)
local settingsPanel: Frame
local settingsChevron: TextLabel
local settingsTitleLbl: TextLabel
local playersPanel:  Frame
local bannersContent: Frame
local readyBtn:      TextButton
local readyGrad:     UIGradient
local readyStroke:   UIStroke
local statusLbl:     TextLabel

local sndCountdown:  Sound
local sndStart:      Sound

local aiCountBtn:    TextButton
local aiDiffBtn:     TextButton
local gamemodeBtn:   TextButton
local terrainBtn:    TextButton

local lastRosterSig       = ""      -- roster signature; banners rebuild only when it changes
-- The game-start callback fired when the lobby's countdown completes. Stored in a module
-- var so LobbyUI.reopen() can swap it: the FIRST lobby runs the full startGame, a
-- re-opened lobby (after returning from a match) runs a lightweight resume instead.
local onGameStartRef: ((string) -> ())? = nil
-- Fired the instant the game-start countdown/transition begins (before the dramatic
-- full-screen sequence). Lets an owner (e.g. the MainMenu tab shell) tear down any
-- chrome it's floating on top of the lobby so the transition reads clean.
local onStartTransitionRef: (() -> ())? = nil
local remotesWired        = false   -- one-time guard for the persistent remote connections
local isReady             = false
local settingsExpanded    = false
-- Chosen team/faction: "Humans" (Survivor-led) or "Hollowed" (Lamprey creatures).
local selectedFaction     = "Humans"
local factionCards: { [string]: { card: TextButton, stroke: UIStroke, name: TextLabel, vpf: ViewportFrame, badge: TextLabel } } = {}
local lobbyTerrainMode    = "Off"   -- Layered | Walled | Off (server owns the authoritative value)
local lobbyGamemode       = "Default"
local lastSettings        = { aiCount = 1, aiDifficulty = "Medium" }

-- Bright "ready up" palette, pronounced yellow→white gradient
local C_READY_TOP   = Color3.fromRGB(255, 248, 196)  -- near-white top
local C_READY_BOT   = Color3.fromRGB(255, 204,  56)  -- saturated yellow bottom
local C_READY_GLOW  = Color3.fromRGB(255, 226, 120)

-- ── UIScale update ────────────────────────────────────────────────────────────
local function updateScale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	uiScaleObj.Scale = math.min(vp.X / DESIGN_W, vp.Y / DESIGN_H)
end

-- ── UI helpers ────────────────────────────────────────────────────────────────
local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color; s.Thickness = thickness; s.Parent = parent
	return s
end

local function gradient(parent: Instance, c1: Color3, c2: Color3, rotation: number?): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c1, c2)
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

local function diamond(parent: Instance, sizePx: number, color: Color3, pos: UDim2, zIndex: number?)
	local d = Instance.new("Frame")
	d.Size = UDim2.fromOffset(sizePx, sizePx)
	d.Position = pos
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Rotation = 45
	d.BackgroundColor3 = color
	d.BorderSizePixel = 0
	d.ZIndex = zIndex or 5
	d.Parent = parent
end

local function cornerBrackets(parent: Instance, color: Color3, len: number, thick: number, zIndex: number?)
	local zi = zIndex or 6
	local corners = {
		{ a = Vector2.new(0, 0) }, { a = Vector2.new(1, 0) },
		{ a = Vector2.new(0, 1) }, { a = Vector2.new(1, 1) },
	}
	for _, c in corners do
		local h = Instance.new("Frame")
		h.Size = UDim2.fromOffset(len, thick)
		h.AnchorPoint = c.a; h.Position = UDim2.new(c.a.X, 0, c.a.Y, 0)
		h.BackgroundColor3 = color; h.BorderSizePixel = 0; h.ZIndex = zi; h.Parent = parent
		local v = Instance.new("Frame")
		v.Size = UDim2.fromOffset(thick, len)
		v.AnchorPoint = c.a; v.Position = UDim2.new(c.a.X, 0, c.a.Y, 0)
		v.BackgroundColor3 = color; v.BorderSizePixel = 0; v.ZIndex = zi; v.Parent = parent
	end
end

local function label(
	parent: Instance, text: string, size: number, color: Color3, font: Enum.Font,
	uiSize: UDim2, pos: UDim2, align: Enum.TextXAlignment?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Text = text; l.TextSize = size; l.TextColor3 = color; l.Font = font
	l.Size = uiSize; l.Position = pos
	l.BackgroundTransparency = 1; l.TextScaled = false
	l.TextXAlignment = align or Enum.TextXAlignment.Center
	l.Parent = parent
	return l
end

local function makeBtn(
	parent: Instance, text: string, size: UDim2, pos: UDim2,
	bgColor: Color3, textColor: Color3, fontSize: number
): TextButton
	local b = Instance.new("TextButton")
	b.Size = size; b.Position = pos
	b.BackgroundColor3 = bgColor; b.BorderSizePixel = 0; b.AutoButtonColor = false
	b.Font = Enum.Font.GothamBold; b.TextSize = fontSize; b.TextColor3 = textColor
	b.Text = text; b.Parent = parent
	corner(b, 5)
	gradient(b, Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 214, 214), 90)
	local st = stroke(b, C_BORDER, 1); st.Transparency = 0.25
	b.MouseEnter:Connect(function()
		TweenService:Create(st, TweenInfo.new(0.12), { Transparency = 0, Thickness = 1.5, Color = C_ACCENT }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(st, TweenInfo.new(0.12), { Transparency = 0.25, Thickness = 1, Color = C_BORDER }):Play()
	end)
	return b
end

-- ── Terrain (settings button only; the map preview was removed) ────────────────
local TERRAIN_COLORS = {
	Layered = Color3.fromRGB(120, 200, 130),
	Walled  = Color3.fromRGB(196, 150, 110),
	Off     = C_SUBTEXT,
}
local function syncTerrain(mode: string)
	lobbyTerrainMode = mode or "Off"
	if terrainBtn then
		local c = TERRAIN_COLORS[lobbyTerrainMode] or C_TITLE
		terrainBtn.Text       = lobbyTerrainMode:upper()
		terrainBtn.TextColor3  = c
		local st = terrainBtn:FindFirstChildOfClass("UIStroke")
		if st then st.Color = c; st.Transparency = 0.35 end
	end
end

-- ── Player banners ─────────────────────────────────────────────────────────────
-- Up to MAX_BANNERS tall vertical cards, one per combatant. Each shows, top to
-- bottom: the player name, their profile avatar, and a 3D preview of the race
-- (faction) they picked. AI opponents and unfilled slots get their own variants.
local BANNER_PAD  = 10
local BANNER_IN_W = BANNER_W - BANNER_PAD * 2   -- 120

-- Build a single banner. `kind` is "player" | "ai" | "empty".
local function buildBanner(opts: {
	kind: string, name: string?, userId: number?, faction: string?,
	ready: boolean?, isLocal: boolean?, diff: string?, diffColor: Color3?,
}): Frame
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(BANNER_W, BANNER_H)
	card.BackgroundColor3 = opts.kind == "empty" and C_SLOT_DIS or Color3.fromRGB(17, 21, 31)
	card.BackgroundTransparency = opts.kind == "empty" and 0.35 or 0
	card.BorderSizePixel = 0
	corner(card, 8)
	local cst = stroke(card, C_BORDER, 1)
	cst.Transparency = opts.kind == "empty" and 0.7 or 0.4

	if opts.kind == "empty" then
		label(card, "OPEN\nSLOT", 15, C_SUBTEXT, Enum.Font.GothamBold,
			UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0)).TextYAlignment = Enum.TextYAlignment.Center
		return card
	end

	local accent = opts.kind == "ai" and (opts.diffColor or C_GOLD) or C_TEXT

	-- Name (top)
	local nameLbl = label(card, opts.name or "", 14, accent, Enum.Font.GothamBold,
		UDim2.new(1, -12, 0, 22), UDim2.fromOffset(BANNER_PAD, 8))
	nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

	-- Profile (avatar headshot for players, glyph block for AI)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(BANNER_IN_W, BANNER_IN_W)
	holder.Position = UDim2.fromOffset(BANNER_PAD, 34)
	holder.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = true
	holder.Parent = card
	corner(holder, 6)
	local hst = stroke(holder, C_BORDER, 1); hst.Transparency = 0.5

	if opts.kind == "ai" then
		local g = label(holder, "🤖", 54, accent, Enum.Font.GothamBlack,
			UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0))
		g.TextYAlignment = Enum.TextYAlignment.Center
	elseif opts.userId and opts.userId > 0 then
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.new(1, 0, 1, 0)
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Crop
		img.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", opts.userId)
		img.Parent = holder
	else
		-- No valid avatar (e.g. a Studio test session): fall back to a name initial.
		local g = label(holder, string.sub(opts.name or "?", 1, 1):upper(), 54, C_GOLD,
			Enum.Font.GothamBlack, UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0))
		g.TextYAlignment = Enum.TextYAlignment.Center
	end

	-- Race caption + preview
	local raceY = 34 + BANNER_IN_W + 6   -- 160
	label(card, opts.kind == "ai" and "DIFFICULTY" or "RACE", 10, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -12, 0, 12), UDim2.fromOffset(BANNER_PAD, raceY), Enum.TextXAlignment.Left)

	local raceBox = Instance.new("Frame")
	raceBox.Size = UDim2.fromOffset(BANNER_IN_W, BANNER_H - (raceY + 14) - 32)
	raceBox.Position = UDim2.fromOffset(BANNER_PAD, raceY + 14)
	raceBox.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
	raceBox.BackgroundTransparency = 0.35
	raceBox.BorderSizePixel = 0
	raceBox.ClipsDescendants = true
	raceBox.Parent = card
	corner(raceBox, 6)

	if opts.kind == "ai" then
		-- AI has no chosen race; show the difficulty prominently instead.
		local dl = label(raceBox, (opts.diff or "MEDIUM"):upper(), 18, accent, Enum.Font.GothamBlack,
			UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0))
		dl.TextYAlignment = Enum.TextYAlignment.Center
	else
		local unit = FACTION_UNIT[opts.faction or "Humans"] or "Survivor"
		local vpf  = ViewportPreview.forUnit(unit, Vector2.new(BANNER_IN_W - 8, raceBox.Size.Y.Offset - 22))
		vpf.Position = UDim2.fromOffset(4, 2)
		vpf.Parent = raceBox
		label(raceBox, FACTION_LABEL[opts.faction or "Humans"] or "HUMANS", 11, C_GOLD, Enum.Font.GothamBold,
			UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 1, -18))
	end

	-- Ready / waiting status pill (bottom)
	local statusLblC = label(card, opts.kind == "ai" and "AI" or (opts.ready and "READY" or "waiting"),
		11, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -12, 0, 20), UDim2.new(0, BANNER_PAD, 1, -28))
	if opts.kind == "ai" then
		statusLblC.TextColor3 = accent
	else
		statusLblC.TextColor3 = opts.ready and C_READY_DOT or C_SUBTEXT
	end

	-- Highlight the local player's own banner.
	if opts.isLocal then
		cst.Color = C_GOLD; cst.Thickness = 2; cst.Transparency = 0
	end

	return card
end

local function syncRoster(readyList: { { name: string, userId: number, ready: boolean, faction: string? } }, settings)
	local n    = (settings and settings.aiCount) or 0
	local diff = (settings and settings.aiDifficulty) or "Medium"

	-- Rebuild only when something visible changed (avoids re-rendering 3D previews on
	-- every sync). Signature captures names, factions, ready flags and the AI config.
	local parts = { tostring(n), diff }
	for _, e in readyList do
		table.insert(parts, string.format("%s|%s|%s", e.name, e.faction or "Humans", tostring(e.ready)))
	end
	local sig = table.concat(parts, ";")
	if sig == lastRosterSig then return end
	lastRosterSig = sig

	for _, child in bannersContent:GetChildren() do
		if child:IsA("Frame") then child:Destroy() end
	end

	local diffColor = DIFF_COLORS[diff] or C_GOLD
	local slots = 0

	-- Human players first.
	for _, entry in readyList do
		if slots >= MAX_BANNERS then break end
		slots += 1
		buildBanner({
			kind    = "player",
			name    = entry.name,
			userId  = entry.userId,
			faction = entry.faction or "Humans",
			ready   = entry.ready,
			isLocal = entry.name == localPlayer.Name,
		}).Parent = bannersContent
	end

	-- Then AI opponents.
	for _ = 1, n do
		if slots >= MAX_BANNERS then break end
		slots += 1
		buildBanner({
			kind = "ai", name = "AI OPPONENT", diff = diff, diffColor = diffColor,
		}).Parent = bannersContent
	end

	-- Fill the rest with empty "open slot" placeholders.
	while slots < MAX_BANNERS do
		slots += 1
		buildBanner({ kind = "empty" }).Parent = bannersContent
	end
end

-- ── Settings value display ─────────────────────────────────────────────────────
local function applySettings(settings)
	lastSettings = settings or lastSettings
	local n    = lastSettings.aiCount or 0
	local diff = lastSettings.aiDifficulty or "Medium"

	if aiCountBtn then
		aiCountBtn.Text = n == 0 and "NONE" or tostring(n)
		aiCountBtn.TextColor3 = n == 0 and C_SUBTEXT or C_TITLE
	end
	if aiDiffBtn then
		local c = DIFF_COLORS[diff] or C_GOLD
		aiDiffBtn.Text = diff:upper()
		aiDiffBtn.TextColor3 = c
		local st = aiDiffBtn:FindFirstChildOfClass("UIStroke")
		if st then st.Color = c; st.Transparency = 0.35 end
	end
end

-- ── Gamemode display ───────────────────────────────────────────────────────────
local GAMEMODE_LABELS = { Default = "DEFAULT", Swarm = "SWARM" }
local function applyGamemode(gm: string?)
	if gm then lobbyGamemode = gm end
	if gamemodeBtn then
		gamemodeBtn.Text = GAMEMODE_LABELS[lobbyGamemode] or string.upper(lobbyGamemode)
	end
end

-- ── Ready button display ───────────────────────────────────────────────────────
local function applyReadyState(ready: boolean)
	isReady = ready
	if ready then
		-- Locked in: shift the bright button to a confident green→white.
		readyGrad.Color = ColorSequence.new(Color3.fromRGB(216, 255, 208), Color3.fromRGB(96, 214, 130))
		readyStroke.Color = Color3.fromRGB(128, 240, 158)
		readyBtn.TextColor3 = Color3.fromRGB(14, 42, 22)
		readyBtn.Text = "✓\nLOCKED IN"
	else
		readyGrad.Color = ColorSequence.new(C_READY_TOP, C_READY_BOT)
		readyStroke.Color = C_READY_GLOW
		readyBtn.TextColor3 = Color3.fromRGB(54, 38, 6)
		readyBtn.Text = "READY\nUP"
	end
end

-- ── Player ready sync ──────────────────────────────────────────────────────────
local function syncPlayers(readyList)
	for _, entry in readyList do
		if entry.name == localPlayer.Name then
			applyReadyState(entry.ready)
			break
		end
	end
end

-- ── Game-start transition ──────────────────────────────────────────────────────
local function fadeFrame(frame: Instance, info: TweenInfo)
	if frame:IsA("GuiObject") then
		pcall(function() TweenService:Create(frame, info, { BackgroundTransparency = 1 }):Play() end)
	end
	for _, d in frame:GetDescendants() do
		if d:IsA("GuiObject") then
			pcall(function() TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play() end)
		end
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			pcall(function() TweenService:Create(d, info, { TextTransparency = 1 }):Play() end)
		end
		if d:IsA("ImageLabel") then
			pcall(function() TweenService:Create(d, info, { ImageTransparency = 1 }):Play() end)
		end
	end
end

-- A rising horde of black silhouettes that surges up from the bottom edge as the
-- match begins, the dramatic foreground of the ready transition.
local function spawnSilhouettes()
	silhouetteLayer = Instance.new("Frame")
	silhouetteLayer.Name = "Silhouettes"
	silhouetteLayer.Size = UDim2.new(1, 0, 1, 0)
	silhouetteLayer.BackgroundTransparency = 1
	silhouetteLayer.ClipsDescendants = true
	silhouetteLayer.ZIndex = 3
	silhouetteLayer.Parent = bg

	local COUNT = 16
	for i = 1, COUNT do
		local depth = math.random()                       -- 0 far · 1 near
		local h     = 90 + depth * 170
		local w     = h * (0.62 + math.random() * 0.30)
		local xScl  = (i - 0.5) / COUNT + (math.random() - 0.5) * 0.05
		local zi    = 3 + math.floor(depth * 6)
		local tr    = 0.04 + (1 - depth) * 0.34

		-- Creature body (rounded hump)
		local fig = Instance.new("Frame")
		fig.AnchorPoint = Vector2.new(0.5, 1)
		fig.Size = UDim2.fromOffset(w, h)
		fig.Position = UDim2.new(xScl, 0, 1.45, 0)        -- start below the screen
		fig.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		fig.BackgroundTransparency = tr
		fig.BorderSizePixel = 0
		fig.ZIndex = zi
		fig.Parent = silhouetteLayer
		corner(fig, math.floor(w * 0.45))

		-- Head
		local head = Instance.new("Frame")
		head.AnchorPoint = Vector2.new(0.5, 0.5)
		head.Size = UDim2.fromOffset(w * 0.5, w * 0.5)
		head.Position = UDim2.new(0.5, 0, 0, 0)
		head.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		head.BackgroundTransparency = tr
		head.BorderSizePixel = 0
		head.ZIndex = zi
		head.Parent = fig
		corner(head, math.floor(w * 0.25))

		-- Spikes / legs to break the silhouette
		for s = -1, 1, 2 do
			local spike = Instance.new("Frame")
			spike.AnchorPoint = Vector2.new(0.5, 1)
			spike.Size = UDim2.fromOffset(w * 0.16, h * 0.45)
			spike.Position = UDim2.new(0.5, s * w * 0.28, 1, 0)
			spike.Rotation = s * 12
			spike.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			spike.BackgroundTransparency = tr
			spike.BorderSizePixel = 0
			spike.ZIndex = zi
			spike.Parent = fig
		end

		local targetY = 1.05 + (1 - depth) * 0.05
		local rise = TweenInfo.new(0.85 + math.random() * 0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		task.delay(math.random() * 0.55, function()
			if not fig.Parent then return end
			TweenService:Create(fig, rise, { Position = UDim2.new(xScl, 0, targetY, 0) }):Play()
			-- Idle bob once landed
			task.delay(0.85, function()
				if not fig.Parent then return end
				TweenService:Create(fig,
					TweenInfo.new(1.3 + math.random() * 0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Position = UDim2.new(xScl, 0, targetY - 0.018, 0) }
				):Play()
			end)
		end)
	end
end

local function playGameStartTransition(onComplete: (string) -> ())
	readyBtn.Active = false

	-- Let any owning shell drop its chrome before the full-screen sequence plays.
	if onStartTransitionRef then
		pcall(onStartTransitionRef)
	end

	-- Recolor the blue backdrop glow to a foreboding purple as the match begins,
	-- and surge the black silhouette horde up from the bottom.
	if glow then
		TweenService:Create(glow,
			TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundColor3 = Color3.fromRGB(128, 44, 172), BackgroundTransparency = 0.32 }
		):Play()
	end
	spawnSilhouettes()

	task.spawn(function()
		for _, txt in { "3", "2", "1" } do
			statusLbl.Text = "Game starting in  " .. txt
			statusLbl.TextColor3 = C_TEXT; statusLbl.TextSize = 18
			if sndCountdown then sndCountdown:Play() end
			TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 24 }):Play()
			task.delay(0.12, function()
				TweenService:Create(statusLbl, TweenInfo.new(0.22), { TextSize = 17 }):Play()
			end)
			task.wait(0.65)
		end
		statusLbl.Text = "GO!"; statusLbl.TextColor3 = C_READY_DOT; statusLbl.TextSize = 18
		if sndCountdown then sndCountdown:Play() end  -- final tick; the big start sound plays with the reveal
		TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 30 }):Play()
		task.delay(0.14, function()
			TweenService:Create(statusLbl, TweenInfo.new(0.30), { TextSize = 18 }):Play()
		end)
	end)

	-- Fade out the lobby UI (bg stays opaque to hide the camera snap).
	task.delay(1.80, function()
		local fade = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(statusLbl, fade, { TextTransparency = 1 }):Play()
		fadeFrame(settingsPanel, fade)
		fadeFrame(playersPanel,  fade)
		fadeFrame(readyBtn,      fade)
		task.delay(0.42, function()
			settingsPanel.Visible = false
			playersPanel.Visible  = false
			readyBtn.Visible      = false
		end)
	end)

	-- Hand off to gameplay behind the still-opaque backdrop (this stretch doubles as
	-- the loading screen), then sweep the silhouette horde up to uncover the world.
	task.delay(2.60, function()
		onComplete(lobbyGamemode)

		task.delay(1.0, function()
			-- The big game-start sound fires here, in lockstep with the horde rising.
			if sndStart then sndStart:Play() end

			local reveal = TweenInfo.new(2.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
			TweenService:Create(bg, reveal, { BackgroundTransparency = 1 }):Play()
			if glow then
				TweenService:Create(glow, reveal,
					{ BackgroundTransparency = 1, BackgroundColor3 = Color3.fromRGB(170, 100, 212) }
				):Play()
			end
			if silhouetteLayer then
				-- Bigger/nearer figures lead the rise for a parallax wipe.
				for _, fig in silhouetteLayer:GetChildren() do
					if fig:IsA("Frame") then
						local xs = fig.Position.X.Scale
						local lead = math.clamp(fig.AbsoluteSize.Y / 260, 0, 1)
						task.delay((1 - lead) * 0.5, function()
							if not fig.Parent then return end
							TweenService:Create(fig,
								TweenInfo.new(2.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
								{ Position = UDim2.new(xs, 0, -0.8, 0) }   -- rise off the top
							):Play()
						end)
					end
				end
				fadeFrame(silhouetteLayer, TweenInfo.new(2.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out))
			end
			task.delay(3.1, function() sg:Destroy() end)
		end)
	end)
end

-- ── Build: backdrop ─────────────────────────────────────────────────────────────
local function buildBackdrop()
	bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0); bg.BackgroundColor3 = C_BG
	bg.BorderSizePixel = 0; bg.Active = true   -- absorb clicks so nothing behind the lobby is hit
	bg.Parent = sg
	gradient(bg, C_BG, C_BG2, 90)

	local deco = Instance.new("Frame")
	deco.Name = "Deco"; deco.Size = UDim2.new(1, 0, 1, 0)
	deco.BackgroundTransparency = 1; deco.Parent = bg
	for _, cfg in {
		{ x = 0.13, w = 1, rot =  17, col = C_BORDER, tr = 0.86 },
		{ x = 0.84, w = 2, rot = -15, col = C_GOLD,   tr = 0.9  },
		{ x = 0.9,  w = 1, rot = -15, col = C_ACCENT, tr = 0.93 },
	} do
		local ln = Instance.new("Frame")
		ln.Size = UDim2.new(0, cfg.w, 1.7, 0); ln.AnchorPoint = Vector2.new(0.5, 0.5)
		ln.Position = UDim2.new(cfg.x, 0, 0.5, 0); ln.Rotation = cfg.rot
		ln.BackgroundColor3 = cfg.col; ln.BackgroundTransparency = cfg.tr
		ln.BorderSizePixel = 0; ln.Parent = deco
	end
	local bigDia = Instance.new("Frame")
	bigDia.Size = UDim2.fromOffset(520, 520); bigDia.AnchorPoint = Vector2.new(0.5, 0.5)
	bigDia.Position = UDim2.new(0.5, 0, 0.5, 0); bigDia.Rotation = 45
	bigDia.BackgroundTransparency = 1; bigDia.Parent = deco
	local bd = stroke(bigDia, C_BORDER, 1); bd.Transparency = 0.9

	glow = Instance.new("Frame")
	glow.Name = "Glow"; glow.Size = UDim2.new(1, 0, 1, 0)
	glow.BackgroundColor3 = Color3.fromRGB(42, 122, 152); glow.BackgroundTransparency = 0.5
	glow.BorderSizePixel = 0; glow.ZIndex = 0; glow.Parent = bg
	local glowGrad = Instance.new("UIGradient")
	glowGrad.Rotation = 90
	glowGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.93),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	glowGrad.Parent = glow
	TweenService:Create(glow,
		TweenInfo.new(3.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ BackgroundTransparency = 0.82 }
	):Play()

	local particles = Instance.new("Frame")
	particles.Name = "Particles"; particles.Size = UDim2.new(1, 0, 1, 0)
	particles.BackgroundTransparency = 1; particles.ClipsDescendants = true
	particles.ZIndex = 1; particles.Parent = bg

	local PARTICLE_COLS = { C_GOLD, C_ACCENT, Color3.fromRGB(206, 222, 246) }
	local function spawnParticle()
		local sz = math.random(2, 5)
		local p  = Instance.new("Frame")
		p.Size = UDim2.fromOffset(sz, sz); p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Position = UDim2.new(math.random(), 0, 1.04, math.random(0, 30)); p.Rotation = 45
		p.BackgroundColor3 = PARTICLE_COLS[math.random(1, #PARTICLE_COLS)]
		p.BackgroundTransparency = 0.25 + math.random() * 0.35
		p.BorderSizePixel = 0; p.ZIndex = 1; p.Parent = particles
		local rise  = 5.5 + math.random() * 4.5
		local drift = (math.random() - 0.5) * 0.08
		local tw = TweenService:Create(p, TweenInfo.new(rise, Enum.EasingStyle.Linear),
			{ Position = UDim2.new(p.Position.X.Scale + drift, 0, -0.05, 0), BackgroundTransparency = 1 })
		tw:Play(); tw.Completed:Connect(function() p:Destroy() end)
	end
	task.spawn(function()
		while sg and sg.Parent do
			spawnParticle(); task.wait(0.18 + math.random() * 0.24)
		end
	end)
end

-- ── Build: status line ──────────────────────────────────────────────────────────
-- The lobby carries no title of its own, the MainMenu tab shell provides branding
-- on top. All that lives up here is the ready/countdown status line.
local function buildTitle()
	statusLbl = label(container, "Waiting for players to ready up...", 15, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, HEADER_H - 34))
end

-- ── Build: settings column ──────────────────────────────────────────────────────
-- A labeled value control. `interactive` styles + returns the value button; when
-- false the control is rendered as a static/disabled chip.
local function settingRow(parent: Instance, y: number, caption: string,
	valueText: string, valueColor: Color3, interactive: boolean): TextButton
	label(parent, caption, 12, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -32, 0, 16), UDim2.fromOffset(16, y), Enum.TextXAlignment.Left)
	local btn = makeBtn(parent, valueText,
		UDim2.new(1, -32, 0, 50), UDim2.fromOffset(16, y + 20),
		interactive and C_SLOT or C_SLOT_DIS, valueColor, 18)
	if not interactive then
		btn.AutoButtonColor = false
		btn.Active = false
		local st = btn:FindFirstChildOfClass("UIStroke")
		if st then st.Transparency = 0.7 end
	end
	return btn
end

-- Expand/collapse the settings drop-menu. Collapsing shrinks the panel to just
-- its header (rows clip away) and slides the map group back to center, so the
-- lobby reads clean by default; expanding drops the rows open and shifts the
-- map aside to make room.
local function setSettingsExpanded(expanded: boolean, instant: boolean?)
	settingsExpanded = expanded
	local targetW    = expanded and SETTINGS_W or SETTINGS_COLLAPSED_W
	local targetH    = expanded and CONTENT_H or SETTINGS_HEADER_H
	local targetMapX = expanded and PANEL_X_OPEN or PANEL_X_CLOSED

	local panelInfo = instant and TweenInfo.new(0)
		or TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local slideInfo = instant and TweenInfo.new(0)
		or TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	TweenService:Create(settingsPanel, panelInfo, { Size = UDim2.fromOffset(targetW, targetH) }):Play()
	TweenService:Create(rightGroup,    slideInfo, { Position = UDim2.fromOffset(targetMapX, CONTENT_Y) }):Play()
	if settingsChevron then
		TweenService:Create(settingsChevron, TweenInfo.new(0.3), { Rotation = expanded and 180 or 0 }):Play()
	end
	if settingsTitleLbl then
		settingsTitleLbl.Text = expanded and "⚙  GAME SETTINGS" or "⚙  SETTINGS"
	end
end

-- Highlight whichever faction card is currently chosen. The selected card gets a
-- gold-tinted fill, a thick full-opacity gold border, a lifted "✓ SELECTED" badge and
-- crisp text; the other card is clearly dimmed so the choice is unmistakable.
local function applyFactionVisual()
	for f, refs in factionCards do
		local sel = f == selectedFaction
		refs.card.BackgroundColor3      = sel and C_FACTION_SEL or C_SLOT
		refs.card.BackgroundTransparency = sel and 0 or 0.35
		refs.stroke.Color               = sel and C_GOLD or C_BORDER
		refs.stroke.Thickness           = sel and 3 or 1
		refs.stroke.Transparency        = sel and 0 or 0.6
		refs.name.TextColor3            = sel and C_GOLD or C_SUBTEXT
		refs.name.Font                  = sel and Enum.Font.GothamBlack or Enum.Font.GothamBold
		refs.vpf.ImageTransparency      = sel and 0 or 0.55
		refs.badge.Visible              = sel
	end
end

-- Pick a team and tell the server (stored per-player, like team colour).
local function setFaction(faction: string)
	if selectedFaction == faction then return end
	selectedFaction = faction
	applyFactionVisual()
	RemoteHandler.get(Config.REMOTES.LobbySetFaction):FireServer(faction)
end

-- Two picture buttons side by side: Humans (a Survivor) and Hollowed (a Lamprey),
-- each a 3D unit thumbnail above a label. The chosen one reads as selected.
local function buildFactionSection(parent: Instance, y: number)
	label(parent, "TEAM", 12, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -32, 0, 16), UDim2.fromOffset(16, y), Enum.TextXAlignment.Left)

	local FB_GAP = 12
	local innerW = SETTINGS_W - 32
	local fbW    = math.floor((innerW - FB_GAP) / 2)
	local fbH    = 120
	local fbY    = y + 22

	local defs = {
		{ faction = "Humans",   unit = "Survivor", label = "HUMANS"   },
		{ faction = "Hollowed", unit = "Lamprey",  label = "HOLLOWED" },
	}
	for i, d in defs do
		local bx   = 16 + (i - 1) * (fbW + FB_GAP)
		local card = Instance.new("TextButton")
		card.Name             = "Faction_" .. d.faction
		card.Size             = UDim2.fromOffset(fbW, fbH)
		card.Position         = UDim2.fromOffset(bx, fbY)
		card.BackgroundColor3  = C_SLOT
		card.AutoButtonColor  = false
		card.BorderSizePixel  = 0
		card.Text             = ""
		card.Parent           = parent
		corner(card, 6)
		local st = stroke(card, C_BORDER, 1); st.Transparency = 0.35

		local vpf    = ViewportPreview.forUnit(d.unit, Vector2.new(fbW - 16, fbH - 36))
		vpf.Position = UDim2.fromOffset(8, 6)
		vpf.Parent   = card

		local nameLbl = label(card, d.label, 13, C_TEXT, Enum.Font.GothamBold,
			UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 1, -24), Enum.TextXAlignment.Center)

		-- "✓ SELECTED" pill pinned to the top-left corner; shown only on the chosen card.
		local badge = Instance.new("TextLabel")
		badge.Name             = "SelBadge"
		badge.Text             = "✓ SELECTED"
		badge.Font             = Enum.Font.GothamBlack
		badge.TextSize         = 10
		badge.TextColor3       = C_BG
		badge.BackgroundColor3 = C_GOLD
		badge.Size             = UDim2.fromOffset(74, 16)
		badge.Position         = UDim2.fromOffset(6, 6)
		badge.ZIndex           = 5
		badge.Visible          = false
		badge.Parent           = card
		corner(badge, 4)

		local faction = d.faction
		card.MouseButton1Click:Connect(function() setFaction(faction) end)
		factionCards[faction] = { card = card, stroke = st, name = nameLbl, vpf = vpf, badge = badge }
	end

	applyFactionVisual()  -- default (Humans) reads as selected without a network call
end

local function buildSettingsColumn()
	settingsPanel = Instance.new("Frame")
	settingsPanel.Name = "Settings"
	settingsPanel.Size = UDim2.fromOffset(SETTINGS_COLLAPSED_W, SETTINGS_HEADER_H)  -- collapsed by default
	settingsPanel.Position = UDim2.fromOffset(CONTENT_X, CONTENT_Y)
	settingsPanel.BackgroundColor3 = C_PANEL
	settingsPanel.BackgroundTransparency = 0.04
	settingsPanel.BorderSizePixel = 0
	settingsPanel.ClipsDescendants = true  -- rows below the header clip away when collapsed
	settingsPanel.Parent = container
	corner(settingsPanel, 8)
	local ps = stroke(settingsPanel, C_BORDER, 1); ps.Transparency = 0.15
	gradient(settingsPanel, C_PANEL_HI, C_PANEL, 90)
	cornerBrackets(settingsPanel, C_GOLD, 14, 2, 9)

	-- Header doubles as the toggle button (the whole bar is clickable).
	local header = Instance.new("TextButton")
	header.Name = "SettingsToggle"
	header.Size = UDim2.new(1, 0, 0, SETTINGS_HEADER_H)
	header.Position = UDim2.fromOffset(0, 0)
	header.BackgroundTransparency = 1
	header.AutoButtonColor = false
	header.Text = ""
	header.ZIndex = 4
	header.Parent = settingsPanel

	settingsTitleLbl = label(header, "⚙  SETTINGS", 14, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -44, 1, 0), UDim2.fromOffset(14, 0), Enum.TextXAlignment.Left)
	settingsTitleLbl.ZIndex = 4

	settingsChevron = label(header, "▼", 16, C_GOLD, Enum.Font.GothamBold,
		UDim2.fromOffset(24, 24), UDim2.new(1, -38, 0.5, -12))
	settingsChevron.ZIndex = 4

	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, -32, 0, 1); div.Position = UDim2.fromOffset(16, SETTINGS_HEADER_H - 2)
	div.BackgroundColor3 = C_BORDER; div.BackgroundTransparency = 0.5
	div.BorderSizePixel = 0; div.Parent = settingsPanel

	local rowY = SETTINGS_HEADER_H + 14
	local ROW_STEP = 92

	-- Gamemode (cycles Default ↔ Swarm)
	gamemodeBtn = settingRow(settingsPanel, rowY, "GAMEMODE", "DEFAULT", Color3.fromRGB(20, 24, 32), true)
	gamemodeBtn.BackgroundColor3 = C_READY_ON  -- reads as the active selection
	rowY += ROW_STEP

	-- Terrain (cycles Layered → Walled → Off)
	terrainBtn = settingRow(settingsPanel, rowY, "TERRAIN", "LAYERED", TERRAIN_COLORS.Layered, true)
	rowY += ROW_STEP

	-- AI Difficulty (cycles Easy/Medium/Hard/Nightmare)
	aiDiffBtn = settingRow(settingsPanel, rowY, "AI DIFFICULTY", "MEDIUM", C_GOLD, true)
	rowY += ROW_STEP

	-- AI Count (cycles 0..3)
	aiCountBtn = settingRow(settingsPanel, rowY, "AI COUNT", "1", C_TITLE, true)
	rowY += ROW_STEP

	-- Team / faction: two picture buttons, Humans (a Survivor) vs Hollowed (a Lamprey).
	buildFactionSection(settingsPanel, rowY)

	header.MouseButton1Click:Connect(function()
		setSettingsExpanded(not settingsExpanded)
	end)
end

-- ── Build: players panel ────────────────────────────────────────────────────────
-- The players panel (up to 4 vertical banners) and the ready button live inside
-- `rightGroup` (relative coordinates) so the whole block can slide aside as a unit
-- when the settings drop-menu opens.
local function buildPlayersPanel()
	playersPanel = Instance.new("Frame")
	playersPanel.Name = "Players"
	playersPanel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	playersPanel.Position = UDim2.fromOffset(0, 0)
	playersPanel.BackgroundColor3 = C_PANEL
	playersPanel.BackgroundTransparency = 0.04
	playersPanel.BorderSizePixel = 0
	playersPanel.Parent = rightGroup
	corner(playersPanel, 8)
	local rs = stroke(playersPanel, C_BORDER, 1); rs.Transparency = 0.15
	gradient(playersPanel, C_PANEL_HI, C_PANEL, 90)
	cornerBrackets(playersPanel, C_GOLD, 14, 2, 9)

	label(playersPanel, "◆  COMBATANTS", 13, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -28, 0, 18), UDim2.fromOffset(16, 10), Enum.TextXAlignment.Left)
	label(playersPanel, "FREE-FOR-ALL", 10, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -28, 0, 16), UDim2.fromOffset(16, 11), Enum.TextXAlignment.Right)

	bannersContent = Instance.new("Frame")
	bannersContent.Name = "Banners"
	bannersContent.Size = UDim2.new(1, -PANEL_PAD * 2, 0, BANNER_H)
	bannersContent.Position = UDim2.fromOffset(PANEL_PAD, PANEL_HEAD + PANEL_PAD)
	bannersContent.BackgroundTransparency = 1
	bannersContent.Parent = playersPanel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, BANNER_GAP)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = bannersContent
end

-- ── Build: ready button ─────────────────────────────────────────────────────────
local function buildReadyButton()
	-- Large READY button centered beneath the players panel. Pronounced bright
	-- yellow→white gradient with a pulsing glow so it pops as the call-to-action.
	local rowY = PANEL_H + ROSTER_GAP
	local rx   = math.floor((PANEL_W - READY_W) / 2)

	readyBtn = Instance.new("TextButton")
	readyBtn.Name = "ReadyButton"
	readyBtn.Size = UDim2.fromOffset(READY_W, READY_H)
	readyBtn.Position = UDim2.fromOffset(rx, rowY)
	readyBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	readyBtn.BorderSizePixel = 0
	readyBtn.AutoButtonColor = false
	readyBtn.Font = Enum.Font.GothamBlack
	readyBtn.TextSize = 28
	readyBtn.TextColor3 = Color3.fromRGB(54, 38, 6)
	readyBtn.Text = "READY\nUP"
	readyBtn.TextYAlignment = Enum.TextYAlignment.Center
	readyBtn.Parent = rightGroup
	corner(readyBtn, 6)
	readyGrad = gradient(readyBtn, C_READY_TOP, C_READY_BOT, 90)
	readyStroke = stroke(readyBtn, C_READY_GLOW, 2)
	readyStroke.Transparency = 0.45
	cornerBrackets(readyBtn, Color3.fromRGB(255, 255, 255), 16, 2, 9)

	-- Steady attention pulse on the glow.
	TweenService:Create(readyStroke,
		TweenInfo.new(1.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.05, Thickness = 3 }
	):Play()

	readyBtn.MouseEnter:Connect(function()
		TweenService:Create(readyBtn, TweenInfo.new(0.12), { TextSize = 30 }):Play()
	end)
	readyBtn.MouseLeave:Connect(function()
		TweenService:Create(readyBtn, TweenInfo.new(0.12), { TextSize = 28 }):Play()
	end)
end

-- ── Control wiring ──────────────────────────────────────────────────────────────
-- Per-instance button clicks. Called from buildUI so a freshly (re)built lobby always
-- has working buttons, even after the previous lobby's ScreenGui was destroyed on
-- game start. The remote handlers (LobbySync/LobbyStart) are connected once in init and
-- reference the module-level UI vars, which buildUI reassigns to the fresh instances.
local function wireControls()
	readyBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyReady):FireServer()
	end)
	aiDiffBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbySetAIDifficulty):FireServer()
	end)
	aiCountBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbySetAICount):FireServer()
	end)
	gamemodeBtn.MouseButton1Click:Connect(function()
		local next = lobbyGamemode == "Swarm" and "Default" or "Swarm"
		RemoteHandler.get(Config.REMOTES.LobbySetGamemode):FireServer(next)
	end)
	terrainBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle):FireServer()
	end)
end

-- ── Build UI ────────────────────────────────────────────────────────────────────
local function buildUI()
	-- Clear any leftover lobby from a previous build (reopen after a match) and drop the
	-- stale roster signature so the banners rebuild fresh against the new instances.
	local old = localPlayer.PlayerGui:FindFirstChild("LobbyUI")
	if old then old:Destroy() end
	lastRosterSig = ""

	sg = Instance.new("ScreenGui")
	sg.Name = "LobbyUI"; sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = true; sg.DisplayOrder = 100
	sg.Parent = localPlayer.PlayerGui

	buildBackdrop()

	container = Instance.new("Frame")
	container.Name = "Container"; container.Size = UDim2.fromOffset(DESIGN_W, DESIGN_H)
	container.AnchorPoint = Vector2.new(0.5, 0.5); container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundTransparency = 1; container.ClipsDescendants = false
	container.Parent = sg

	uiScaleObj = Instance.new("UIScale"); uiScaleObj.Scale = 1; uiScaleObj.Parent = container

	-- Players panel + ready group. Starts at the centered (settings-collapsed) spot.
	rightGroup = Instance.new("Frame")
	rightGroup.Name = "RightGroup"
	rightGroup.Size = UDim2.fromOffset(PANEL_W, CONTENT_H)
	rightGroup.Position = UDim2.fromOffset(PANEL_X_CLOSED, CONTENT_Y)
	rightGroup.BackgroundTransparency = 1
	rightGroup.ClipsDescendants = false
	rightGroup.Parent = container

	-- Game-start sounds
	sndCountdown = Instance.new("Sound")
	sndCountdown.SoundId = SND_COUNTDOWN; sndCountdown.Volume = 0.6; sndCountdown.Parent = sg
	sndStart = Instance.new("Sound")
	sndStart.SoundId = SND_START; sndStart.Volume = 0.8; sndStart.Parent = sg

	buildTitle()
	buildSettingsColumn()
	buildPlayersPanel()
	buildReadyButton()
	wireControls()
end

-- Point the overhead camera at the map (used by init and reopen).
local function overheadCamera()
	task.spawn(function()
		task.wait(0.1)
		local cam = workspace.CurrentCamera
		if not cam then return end
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 700, 1), Vector3.new(0, 0, 0))
	end)
end

-- Connect the persistent lobby remote handlers exactly once. They reference the
-- module-level UI vars, which buildUI reassigns on every (re)build, so they keep
-- driving whichever lobby instance is currently up.
local function wireRemotesOnce()
	if remotesWired then return end
	remotesWired = true

	RemoteHandler.get(Config.REMOTES.LobbySync).OnClientEvent:Connect(
		function(
			readyList: { { name: string, userId: number, ready: boolean, faction: string? } },
			_positions:  { Vector3 },
			terrainMode: string,
			settings:    { aiCount: number, aiDifficulty: string }?,
			gamemode:    string?
		)
			-- Ignore syncs that arrive while no lobby is on screen (mid-match).
			if not sg or not sg.Parent then return end
			syncPlayers(readyList)
			applySettings(settings)
			syncRoster(readyList, settings or lastSettings)
			applyGamemode(gamemode)
			syncTerrain(terrainMode)
		end
	)

	RemoteHandler.get(Config.REMOTES.LobbyStart).OnClientEvent:Connect(function()
		if onGameStartRef then playGameStartTransition(onGameStartRef) end
	end)
end

-- ── Public init ───────────────────────────────────────────────────────────────
function LobbyUI.init(onGameStart: (string) -> ())
	onGameStartRef = onGameStart
	buildUI()

	updateScale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	overheadCamera()
	wireRemotesOnce()
end

-- Re-open the ready-up menu after a match. Rebuilds the (previously destroyed) lobby UI
-- and swaps the game-start callback for a lightweight `resume`, the match systems from
-- the first startGame are still running, so readying up should NOT re-run startGame; it
-- just plays the transition and lets the server-delivered base drive the rest.
function LobbyUI.reopen(resume: (string) -> ())
	onGameStartRef   = resume
	isReady          = false
	settingsExpanded = false
	buildUI()
	updateScale()
	overheadCamera()
	wireRemotesOnce()
end

-- The locally-chosen team/faction ("Humans" or "Hollowed").
function LobbyUI.getFaction(): string
	return selectedFaction
end

-- Show/hide the (already-built) lobby without destroying it, used by the MainMenu tab
-- shell so the "READY UP" tab can flip the lobby on and off beneath the persistent tab
-- bar. Showing re-asserts the overhead camera (a sibling tab may have moved it).
function LobbyUI.setVisible(visible: boolean)
	if not sg then return end
	sg.Enabled = visible
	if visible then overheadCamera() end
end

-- Register a callback fired the instant the game-start transition begins.
function LobbyUI.setOnStartTransition(cb: (() -> ())?)
	onStartTransitionRef = cb
end

return LobbyUI
