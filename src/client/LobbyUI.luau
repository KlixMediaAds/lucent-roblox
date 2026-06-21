--[[
	LobbyUI — full-screen pre-game lobby (reworked).

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

local LobbyUI     = {}
local localPlayer = Players.LocalPlayer

-- ── Design constants ──────────────────────────────────────────────────────────
local DESIGN_W   = 960    -- reference design width
local DESIGN_H   = 900    -- reference design height
local WORLD_HALF = 432

-- Layout (design pixels)
local PREVIEW_PX  = 520            -- map preview side length (~40% bigger than before)
local MAP_BORDER  = PREVIEW_PX + 4 -- 524
local SETTINGS_W  = 300
local GAP         = 24             -- gap between settings column and map
local ROSTER_GAP  = 18             -- vertical gap between map and the bottom row
local ROW2_H      = 150            -- bottom row height (roster + ready)
local READY_W     = 210
local READY_GAP   = 18
local HEADER_H    = 158            -- title block height at the top

-- Derived layout values (design space)
local CONTENT_W  = SETTINGS_W + GAP + MAP_BORDER         -- 848
local CONTENT_H  = MAP_BORDER + ROSTER_GAP + ROW2_H      -- 692
local CONTENT_X  = math.floor((DESIGN_W - CONTENT_W) / 2)
local CONTENT_Y  = HEADER_H + 14

-- Minimap constants — must match MiniMap.luau (used by the game-start slide)
local MINIMAP_SIZE = 180
local MINIMAP_PAD  = 10

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
local container:     Frame
local uiScaleObj:    UIScale
local mapBorder:     Frame
local mapCanvas:     Frame
local settingsPanel: Frame
local rosterPanel:   Frame
local rosterContent: Frame
local readyBtn:      TextButton
local statusLbl:     TextLabel
local titleLbl:      TextLabel
local titleDeco:     Frame
local mapLabelRef:   TextLabel

local aiCountBtn:    TextButton
local aiDiffBtn:     TextButton
local gamemodeBtn:   TextButton

local depositDots: { Frame } = {}
local terrainDots: { Frame } = {}
local isReady             = false
local lobbyTerrainEnabled = false
local lobbyGamemode       = "Default"
local lastSettings        = { aiCount = 1, aiDifficulty = "Medium" }

-- ── UIScale update ────────────────────────────────────────────────────────────
local function updateScale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	uiScaleObj.Scale = math.min(vp.X / DESIGN_W, vp.Y / DESIGN_H)
end

-- ── World → preview pixel ─────────────────────────────────────────────────────
local function w2p(wx: number, wz: number): (number, number)
	local u = (wx + WORLD_HALF) / (WORLD_HALF * 2) * PREVIEW_PX
	local v = (wz + WORLD_HALF) / (WORLD_HALF * 2) * PREVIEW_PX
	return u, v
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

-- ── Deposit dots ──────────────────────────────────────────────────────────────
local function syncDeposits(positions: { Vector3 })
	while #depositDots > #positions do
		depositDots[#depositDots]:Destroy(); table.remove(depositDots)
	end
	while #depositDots < #positions do
		local f = Instance.new("Frame")
		f.Size = UDim2.fromOffset(7, 7); f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = C_DEPOSIT; f.BorderSizePixel = 0; f.ZIndex = 5; f.Parent = mapCanvas
		table.insert(depositDots, f)
	end
	for i, pos in positions do
		local u, v = w2p(pos.X, pos.Z)
		depositDots[i].Position = UDim2.fromOffset(u, v)
	end
end

-- ── Terrain preview ───────────────────────────────────────────────────────────
local function syncTerrain(enabled: boolean)
	lobbyTerrainEnabled = enabled
	for _, dot in terrainDots do dot:Destroy() end
	terrainDots = {}
	if not enabled or not mapCanvas then return end
	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return end
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		local pu, pv = w2p(part.Position.X, part.Position.Z)
		local pw = math.max(4, part.Size.X / (WORLD_HALF * 2) * PREVIEW_PX)
		local ph = math.max(4, part.Size.Z / (WORLD_HALF * 2) * PREVIEW_PX)
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(pw, ph); dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(pu, pv); dot.BackgroundColor3 = C_TERRAIN_DOT
		dot.BackgroundTransparency = 0.25; dot.BorderSizePixel = 0; dot.ZIndex = 3
		dot.Parent = mapCanvas
		local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 2); c2.Parent = dot
		table.insert(terrainDots, dot)
	end
end

-- ── Combatant roster (beneath the map) ─────────────────────────────────────────
-- FFA for now: a single horizontal list of every human player and every AI bot.
local function makeRosterCard(): (Frame, ImageLabel, Frame, TextLabel, TextLabel)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(0, 80, 1, 0)   -- fill the roster row height
	card.BackgroundColor3 = Color3.fromRGB(17, 21, 31)
	card.BorderSizePixel = 0
	corner(card, 6)
	local cst = stroke(card, C_BORDER, 1); cst.Transparency = 0.45

	-- portrait holder (image for players, color block + glyph for AI)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(56, 56)
	holder.Position = UDim2.new(0.5, 0, 0, 8)
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = true
	holder.Parent = card
	corner(holder, 6)

	local img = Instance.new("ImageLabel")
	img.Size = UDim2.new(1, 0, 1, 0)
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Crop
	img.Parent = holder

	local glyph = label(holder, "", 22, C_GOLD, Enum.Font.GothamBlack,
		UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0))
	glyph.TextYAlignment = Enum.TextYAlignment.Center

	local nameLbl = label(card, "", 12, C_TEXT, Enum.Font.GothamMedium,
		UDim2.new(1, -8, 0, 16), UDim2.new(0, 4, 0, 68))
	nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

	local statusLblC = label(card, "", 11, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -8, 0, 14), UDim2.new(0, 4, 0, 86))

	return card, img, glyph, nameLbl, statusLblC
end

local function syncRoster(readyList: { { name: string, userId: number, ready: boolean } }, settings)
	for _, child in rosterContent:GetChildren() do
		if child:IsA("Frame") then child:Destroy() end
	end

	-- Human players
	for _, entry in readyList do
		local card, img, glyph, nameLbl, statusLblC = makeRosterCard()
		card.Parent = rosterContent
		if entry.userId and entry.userId > 0 then
			img.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", entry.userId)
			glyph.Text = ""
		else
			glyph.Text = string.sub(entry.name, 1, 1):upper()
		end
		nameLbl.Text   = entry.name
		statusLblC.Text = entry.ready and "READY" or "waiting"
		statusLblC.TextColor3 = entry.ready and C_READY_DOT or C_SUBTEXT
		if entry.name == localPlayer.Name then
			local cst = card:FindFirstChildOfClass("UIStroke")
			if cst then cst.Color = C_GOLD; cst.Thickness = 1.6; cst.Transparency = 0.1 end
		end
	end

	-- AI bots (one card per configured AI, all at the chosen difficulty)
	local n    = (settings and settings.aiCount) or 0
	local diff = (settings and settings.aiDifficulty) or "Medium"
	local diffColor = DIFF_COLORS[diff] or C_GOLD
	for _ = 1, n do
		local card, img, glyph, nameLbl, statusLblC = makeRosterCard()
		card.Parent = rosterContent
		img.Image = ""
		glyph.Text = "🤖"; glyph.TextColor3 = diffColor; glyph.TextSize = 26
		nameLbl.Text = "AI Bot"; nameLbl.TextColor3 = diffColor
		statusLblC.Text = diff:upper(); statusLblC.TextColor3 = diffColor
	end

	-- Empty-state hint when there are no AI and you're the only player
	if #readyList == 0 and n == 0 then
		label(rosterContent, "No combatants", 13, C_SUBTEXT, Enum.Font.Gotham,
			UDim2.fromOffset(160, 30), UDim2.fromOffset(0, ROW2_H / 2 - 30))
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
	readyBtn.BackgroundColor3 = ready and C_READY_ON or C_READY_OFF
	readyBtn.TextColor3 = ready and Color3.fromRGB(20, 24, 32) or Color3.fromRGB(238, 240, 245)
	readyBtn.Text = ready and "✓\nCANCEL" or "READY\nUP"
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

local function playGameStartTransition(onComplete: (string) -> ())
	readyBtn.Active = false

	task.spawn(function()
		for _, txt in { "3", "2", "1" } do
			statusLbl.Text = "Game starting in  " .. txt
			statusLbl.TextColor3 = C_TEXT; statusLbl.TextSize = 18
			TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 24 }):Play()
			task.delay(0.12, function()
				TweenService:Create(statusLbl, TweenInfo.new(0.22), { TextSize = 17 }):Play()
			end)
			task.wait(0.65)
		end
		statusLbl.Text = "GO!"; statusLbl.TextColor3 = C_READY_DOT; statusLbl.TextSize = 18
		TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 30 }):Play()
		task.delay(0.14, function()
			TweenService:Create(statusLbl, TweenInfo.new(0.30), { TextSize = 18 }):Play()
		end)
	end)

	-- Fade out UI (bg stays opaque to hide the camera snap)
	task.delay(1.80, function()
		local fade = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(titleLbl,    fade, { TextTransparency = 1 }):Play()
		TweenService:Create(statusLbl,   fade, { TextTransparency = 1 }):Play()
		TweenService:Create(mapLabelRef, fade, { TextTransparency = 1 }):Play()
		if titleDeco then fadeFrame(titleDeco, fade) end
		fadeFrame(settingsPanel, fade)
		fadeFrame(rosterPanel,   fade)
		fadeFrame(readyBtn,      fade)
		task.delay(0.42, function()
			settingsPanel.Visible = false
			rosterPanel.Visible   = false
			readyBtn.Visible      = false
		end)
	end)

	-- Map card slide to the minimap corner
	task.delay(2.00, function()
		mapBorder.ClipsDescendants = true
		local absPos  = mapBorder.AbsolutePosition
		local absSize = mapBorder.AbsoluteSize
		local canvasAbsPos = mapCanvas.AbsolutePosition

		mapBorder.Size     = UDim2.fromOffset(absSize.X, absSize.Y)
		mapBorder.Position = UDim2.fromOffset(absPos.X, absPos.Y)
		mapBorder.ZIndex   = 12
		mapBorder.Parent   = sg

		mapCanvas.Position = UDim2.fromOffset(canvasAbsPos.X - absPos.X, canvasAbsPos.Y - absPos.Y)
		mapCanvas.Size     = UDim2.fromOffset(mapCanvas.AbsoluteSize.X, mapCanvas.AbsoluteSize.Y)

		TweenService:Create(mapBorder, TweenInfo.new(0.08), { BackgroundColor3 = C_ACCENT }):Play()
		task.delay(0.12, function()
			TweenService:Create(mapBorder, TweenInfo.new(0.22), { BackgroundColor3 = C_BORDER }):Play()
		end)

		local mmBorder  = MINIMAP_SIZE + 4
		local slideInfo = TweenInfo.new(0.70, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)

		TweenService:Create(mapBorder, slideInfo, {
			Position = UDim2.new(1, -(mmBorder + MINIMAP_PAD), 1, -(mmBorder + MINIMAP_PAD)),
			Size     = UDim2.fromOffset(mmBorder, mmBorder),
		}):Play()

		local canvasFinal = math.floor((mmBorder - mapCanvas.AbsoluteSize.X) / 2)
		TweenService:Create(mapCanvas, slideInfo, {
			Position = UDim2.fromOffset(canvasFinal, canvasFinal),
		}):Play()

		task.delay(0.72, function()
			TweenService:Create(mapBorder, TweenInfo.new(0.08), { BackgroundColor3 = Color3.fromRGB(255, 255, 255) }):Play()
			task.delay(0.10, function()
				TweenService:Create(mapBorder, TweenInfo.new(0.30), { BackgroundColor3 = C_BORDER }):Play()
			end)
			task.delay(0.40, function()
				local finalFade = TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				TweenService:Create(mapBorder, finalFade, { BackgroundTransparency = 1 }):Play()
				TweenService:Create(mapCanvas, finalFade, { BackgroundTransparency = 1 }):Play()
				for _, child in mapCanvas:GetDescendants() do
					if child:IsA("GuiObject") then
						pcall(function() TweenService:Create(child, finalFade, { BackgroundTransparency = 1 }):Play() end)
					end
				end
				task.delay(0.28, function()
					onComplete(lobbyGamemode)
					TweenService:Create(bg,
						TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 1 }
					):Play()
					task.delay(0.27, function() sg:Destroy() end)
				end)
			end)
		end)
	end)
end

-- ── Build: backdrop ─────────────────────────────────────────────────────────────
local function buildBackdrop()
	bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0); bg.BackgroundColor3 = C_BG
	bg.BorderSizePixel = 0; bg.Parent = sg
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

	local glow = Instance.new("Frame")
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

-- ── Build: title lockup ─────────────────────────────────────────────────────────
local function buildTitle()
	titleDeco = Instance.new("Frame")
	titleDeco.Name = "TitleDeco"; titleDeco.Size = UDim2.new(1, 0, 0, 130)
	titleDeco.Position = UDim2.fromOffset(0, 14); titleDeco.BackgroundTransparency = 1
	titleDeco.ZIndex = 1; titleDeco.Parent = container

	local TITLE_Y = 8
	local echo = label(titleDeco, "LUCENT", 64, Color3.fromRGB(18, 60, 80), Enum.Font.GothamBlack,
		UDim2.new(1, 0, 0, 74), UDim2.fromOffset(3, TITLE_Y + 4))
	echo.TextTransparency = 0.5; echo.ZIndex = 1

	for _, s in { -1, 1 } do
		local ln = Instance.new("Frame")
		ln.Size = UDim2.fromOffset(92, 2); ln.AnchorPoint = Vector2.new(0.5, 0.5)
		ln.Position = UDim2.new(0.5, s * 240, 0, TITLE_Y + 38); ln.Rotation = s * -7
		ln.BackgroundColor3 = C_GOLD; ln.BorderSizePixel = 0; ln.ZIndex = 2; ln.Parent = titleDeco
		gradient(ln, C_GOLD, C_BG2, s == -1 and 0 or 180)
		diamond(titleDeco, 10, C_GOLD, UDim2.new(0.5, s * 188, 0, TITLE_Y + 38), 2)
		diamond(titleDeco, 5, C_ACCENT, UDim2.new(0.5, s * 292, 0, TITLE_Y + 38), 2)
	end

	local badge = Instance.new("Frame")
	badge.Size = UDim2.fromOffset(58, 28); badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(0.5, 150, 0, TITLE_Y + 16)
	badge.BackgroundColor3 = C_GOLD; badge.BorderSizePixel = 0; badge.ZIndex = 2; badge.Parent = titleDeco
	corner(badge, 4)
	local badgeLbl = label(badge, "RTS", 17, Color3.fromRGB(16, 20, 28), Enum.Font.GothamBold,
		UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0))
	badgeLbl.TextYAlignment = Enum.TextYAlignment.Center; badgeLbl.ZIndex = 3

	local ruleY = TITLE_Y + 74
	local rule = Instance.new("Frame")
	rule.Size = UDim2.fromOffset(176, 2); rule.AnchorPoint = Vector2.new(0.5, 0.5)
	rule.Position = UDim2.new(0.5, 0, 0, ruleY); rule.BackgroundColor3 = C_GOLD
	rule.BorderSizePixel = 0; rule.ZIndex = 2; rule.Parent = titleDeco
	diamond(titleDeco, 7, C_GOLD, UDim2.new(0.5, -100, 0, ruleY), 2)
	diamond(titleDeco, 7, C_GOLD, UDim2.new(0.5,  100, 0, ruleY), 2)

	local tagline = label(titleDeco, "R E A L - T I M E   S T R A T E G Y", 13, C_SUBTEXT,
		Enum.Font.GothamMedium, UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, ruleY + 12))
	tagline.ZIndex = 2

	titleLbl = label(container, "LUCENT", 64, C_TITLE, Enum.Font.GothamBlack,
		UDim2.new(1, 0, 0, 74), UDim2.fromOffset(0, 14 + TITLE_Y))
	titleLbl.ZIndex = 3
	gradient(titleLbl, Color3.fromRGB(248, 250, 255), C_GOLD, 90)
	local titleGlow = stroke(titleLbl, C_GOLD, 1.4); titleGlow.Transparency = 0.5

	statusLbl = label(container, "Waiting for players to ready up...", 15, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, HEADER_H - 30))
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

local function buildSettingsColumn()
	settingsPanel = Instance.new("Frame")
	settingsPanel.Name = "Settings"
	settingsPanel.Size = UDim2.fromOffset(SETTINGS_W, MAP_BORDER)
	settingsPanel.Position = UDim2.fromOffset(CONTENT_X, CONTENT_Y)
	settingsPanel.BackgroundColor3 = C_PANEL
	settingsPanel.BackgroundTransparency = 0.04
	settingsPanel.BorderSizePixel = 0
	settingsPanel.Parent = container
	corner(settingsPanel, 8)
	local ps = stroke(settingsPanel, C_BORDER, 1); ps.Transparency = 0.15
	gradient(settingsPanel, C_PANEL_HI, C_PANEL, 90)
	cornerBrackets(settingsPanel, C_GOLD, 14, 2, 9)

	label(settingsPanel, "◆  MATCH SETUP", 14, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -32, 0, 22), UDim2.fromOffset(16, 16), Enum.TextXAlignment.Left)

	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, -32, 0, 1); div.Position = UDim2.fromOffset(16, 46)
	div.BackgroundColor3 = C_BORDER; div.BackgroundTransparency = 0.5
	div.BorderSizePixel = 0; div.Parent = settingsPanel

	local rowY = 62
	local ROW_STEP = 92

	-- Gamemode (cycles Default ↔ Swarm)
	gamemodeBtn = settingRow(settingsPanel, rowY, "GAMEMODE", "DEFAULT", Color3.fromRGB(20, 24, 32), true)
	gamemodeBtn.BackgroundColor3 = C_READY_ON  -- reads as the active selection
	rowY += ROW_STEP

	-- AI Difficulty (cycles Easy/Medium/Hard/Nightmare)
	aiDiffBtn = settingRow(settingsPanel, rowY, "AI DIFFICULTY", "MEDIUM", C_GOLD, true)
	rowY += ROW_STEP

	-- AI Count (cycles 0..3)
	aiCountBtn = settingRow(settingsPanel, rowY, "AI COUNT", "1", C_TITLE, true)
	rowY += ROW_STEP

	-- Teams (coming soon — FFA for now)
	local teamsBtn = settingRow(settingsPanel, rowY, "TEAMS", "FFA · COMING SOON", C_SUBTEXT, false)
	teamsBtn.TextSize = 13
end

-- ── Build: map preview ──────────────────────────────────────────────────────────
local function buildMap()
	local mapX = CONTENT_X + SETTINGS_W + GAP

	mapLabelRef = label(container, "◆  TACTICAL MAP", 13, C_GOLD, Enum.Font.GothamBold,
		UDim2.fromOffset(MAP_BORDER, 22), UDim2.fromOffset(mapX, CONTENT_Y - 26), Enum.TextXAlignment.Left)

	mapBorder = Instance.new("Frame")
	mapBorder.Size = UDim2.fromOffset(MAP_BORDER, MAP_BORDER)
	mapBorder.Position = UDim2.fromOffset(mapX, CONTENT_Y)
	mapBorder.BackgroundColor3 = C_BORDER; mapBorder.BorderSizePixel = 0
	mapBorder.Parent = container
	corner(mapBorder, 4)

	mapCanvas = Instance.new("Frame")
	mapCanvas.Size = UDim2.fromOffset(PREVIEW_PX, PREVIEW_PX)
	mapCanvas.Position = UDim2.fromOffset(2, 2)
	mapCanvas.BackgroundColor3 = Color3.fromRGB(8, 11, 18)
	mapCanvas.BorderSizePixel = 0; mapCanvas.ClipsDescendants = true
	mapCanvas.Parent = mapBorder
	gradient(mapCanvas, Color3.fromRGB(12, 16, 24), Color3.fromRGB(7, 9, 15), 90)

	for _, frac in { 0.25, 0.5, 0.75 } do
		local h = Instance.new("Frame")
		h.Size = UDim2.new(1,0,0,1); h.Position = UDim2.new(0,0,frac,0)
		h.BackgroundColor3 = C_GRID; h.BorderSizePixel = 0; h.ZIndex = 2; h.Parent = mapCanvas
		local v = Instance.new("Frame")
		v.Size = UDim2.new(0,1,1,0); v.Position = UDim2.new(frac,0,0,0)
		v.BackgroundColor3 = C_GRID; v.BorderSizePixel = 0; v.ZIndex = 2; v.Parent = mapCanvas
	end
	for _, cfg in {
		{ size = UDim2.new(1,0,0,1), pos = UDim2.new(0,0,0.5,0) },
		{ size = UDim2.new(0,1,1,0), pos = UDim2.new(0.5,0,0,0) },
	} do
		local c2 = Instance.new("Frame")
		c2.Size = cfg.size; c2.Position = cfg.pos
		c2.BackgroundColor3 = C_BORDER; c2.BackgroundTransparency = 0.4; c2.BorderSizePixel = 0
		c2.ZIndex = 2; c2.Parent = mapCanvas
	end
	cornerBrackets(mapCanvas, C_GOLD, 18, 2, 6)
end

-- ── Build: roster + ready ───────────────────────────────────────────────────────
local function buildRosterAndReady()
	local rowY     = CONTENT_Y + MAP_BORDER + ROSTER_GAP
	-- The bottom row spans the full content width: roster on the left (extending
	-- under the settings column too) and the large READY button at the far right,
	-- aligned with the map's right edge.
	local rosterW  = CONTENT_W - READY_W - READY_GAP

	rosterPanel = Instance.new("Frame")
	rosterPanel.Name = "Roster"
	rosterPanel.Size = UDim2.fromOffset(rosterW, ROW2_H)
	rosterPanel.Position = UDim2.fromOffset(CONTENT_X, rowY)
	rosterPanel.BackgroundColor3 = C_PANEL
	rosterPanel.BackgroundTransparency = 0.04
	rosterPanel.BorderSizePixel = 0
	rosterPanel.Parent = container
	corner(rosterPanel, 8)
	local rs = stroke(rosterPanel, C_BORDER, 1); rs.Transparency = 0.15
	gradient(rosterPanel, C_PANEL_HI, C_PANEL, 90)
	cornerBrackets(rosterPanel, C_GOLD, 12, 2, 9)

	label(rosterPanel, "◆  COMBATANTS", 12, C_GOLD, Enum.Font.GothamBold,
		UDim2.new(1, -24, 0, 16), UDim2.fromOffset(12, 8), Enum.TextXAlignment.Left)
	label(rosterPanel, "FREE-FOR-ALL", 10, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -24, 0, 14), UDim2.fromOffset(12, 8), Enum.TextXAlignment.Right)

	rosterContent = Instance.new("Frame")
	rosterContent.Name = "RosterContent"
	rosterContent.Size = UDim2.new(1, -24, 1, -38)
	rosterContent.Position = UDim2.fromOffset(12, 30)
	rosterContent.BackgroundTransparency = 1
	rosterContent.ClipsDescendants = true
	rosterContent.Parent = rosterPanel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = rosterContent

	-- Large READY button, bottom-right (aligned with the map's right edge)
	readyBtn = makeBtn(container, "READY\nUP",
		UDim2.fromOffset(READY_W, ROW2_H),
		UDim2.fromOffset(CONTENT_X + rosterW + READY_GAP, rowY),
		C_READY_OFF, Color3.fromRGB(238, 240, 245), 26)
	readyBtn.TextYAlignment = Enum.TextYAlignment.Center
	cornerBrackets(readyBtn, C_GOLD, 14, 2, 9)
end

-- ── Build UI ────────────────────────────────────────────────────────────────────
local function buildUI()
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

	buildTitle()
	buildSettingsColumn()
	buildMap()
	buildRosterAndReady()
end

-- ── Public init ───────────────────────────────────────────────────────────────
function LobbyUI.init(onGameStart: (string) -> ())
	buildUI()

	updateScale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)

	-- Overhead camera
	task.spawn(function()
		task.wait(0.1)
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 700, 1), Vector3.new(0, 0, 0))
	end)

	RemoteHandler.get(Config.REMOTES.LobbySync).OnClientEvent:Connect(
		function(
			readyList: { { name: string, userId: number, ready: boolean } },
			positions: { Vector3 },
			terrainOn: boolean,
			settings:  { aiCount: number, aiDifficulty: string }?,
			gamemode:  string?
		)
			syncPlayers(readyList)
			applySettings(settings)
			syncRoster(readyList, settings or lastSettings)
			applyGamemode(gamemode)
			syncDeposits(positions)
			syncTerrain(terrainOn)
		end
	)

	readyBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyReady):FireServer()
	end)

	aiDiffBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbySetAIDifficulty):FireServer()
	end)

	aiCountBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbySetAICount):FireServer()
	end)

	-- Gamemode cycles Default ↔ Swarm.
	gamemodeBtn.MouseButton1Click:Connect(function()
		local next = lobbyGamemode == "Swarm" and "Default" or "Swarm"
		RemoteHandler.get(Config.REMOTES.LobbySetGamemode):FireServer(next)
	end)

	RemoteHandler.get(Config.REMOTES.LobbyStart).OnClientEvent:Connect(function()
		playGameStartTransition(onGameStart)
	end)
end

return LobbyUI
