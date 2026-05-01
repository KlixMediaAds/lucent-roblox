--[[
	LobbyUI — full-screen pre-game lobby.

	Resolution independence:
	  All UI is designed at DESIGN_W×DESIGN_H (1280×800). A UIScale on `container`
	  scales everything uniformly to fit the actual viewport, letterboxing if needed.
	  `bg` (full-screen backdrop) lives outside the container so it always fills the
	  screen regardless of scale.

	Layout (right panel):
	  • PLAYERS section — ready-state list
	  • AI section       — queued AI bots (hidden when queue is empty)
	  • READY UP button
	  • OPTIONS button   — toggles a dropdown card below the panel:
	      Re-Roll Map | Terrain toggle | Add AI (Easy / Medium / Hard)
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
local DESIGN_W   = 1280   -- reference design width
local DESIGN_H   = 800    -- reference design height (taller than 720p to fit dropdown)
local WORLD_HALF = 432
local PREVIEW_PX = 370    -- map preview side length in design pixels
local PANEL_W    = 300
local PANEL_H    = 370
local OPT_H      = 192    -- options dropdown card height

-- Minimap constants — must match MiniMap.luau
local MINIMAP_SIZE = 180
local MINIMAP_PAD  = 10

-- Derived layout values (in design space)
local CONTENT_W  = PREVIEW_PX + 4 + 16 + PANEL_W   -- 690
local CONTENT_X  = math.floor((DESIGN_W - CONTENT_W) / 2)  -- left edge of content in container
local CONTENT_Y  = math.floor((DESIGN_H - PANEL_H)  / 2 + 18)  -- top edge of content in container

-- ── Palette ───────────────────────────────────────────────────────────────────
local C_BG          = Color3.fromRGB(  8,  12,  26)
local C_PANEL       = Color3.fromRGB( 14,  20,  40)
local C_BORDER      = Color3.fromRGB( 35,  75, 140)
local C_GRID        = Color3.fromRGB( 20,  30,  55)
local C_TITLE       = Color3.fromRGB(180, 210, 255)
local C_TEXT        = Color3.fromRGB(200, 220, 255)
local C_SUBTEXT     = Color3.fromRGB(100, 130, 180)
local C_ACCENT      = Color3.fromRGB(  0, 190, 255)
local C_DEPOSIT     = Color3.fromRGB(255, 248, 160)
local C_READY_ON    = Color3.fromRGB( 45, 190,  75)
local C_READY_OFF   = Color3.fromRGB( 30,  60, 120)
local C_READY_DOT   = Color3.fromRGB( 45, 190,  75)
local C_WAITING_DOT = Color3.fromRGB(180,  60,  60)
local C_REROLL      = Color3.fromRGB( 18,  34,  72)
local C_COOLDOWN    = Color3.fromRGB( 40,  40,  70)
local C_TERRAIN_OFF = Color3.fromRGB( 18,  34,  72)
local C_TERRAIN_ON  = Color3.fromRGB( 55,  38,  18)
local C_OPTIONS_BTN = Color3.fromRGB( 22,  42,  90)
local C_OPTIONS_ON  = Color3.fromRGB( 40,  55, 110)
local C_OPTIONS_BG  = Color3.fromRGB( 12,  18,  38)
local C_AI_BALANCED = Color3.fromRGB( 22,  68,  42)
local C_AI_TERR     = Color3.fromRGB( 70,  38,  12)
local C_AI_WAVES    = Color3.fromRGB( 14,  42,  90)
local C_AI_ROW      = Color3.fromRGB( 16,  25,  52)
local C_AI_HEADER   = Color3.fromRGB( 55,  85, 160)
local C_SECTION_DIV = Color3.fromRGB( 25,  45,  90)

-- ── Module refs ───────────────────────────────────────────────────────────────
local sg:          ScreenGui
local bg:          Frame        -- full-screen color backdrop (NOT inside container)
local container:   Frame        -- DESIGN_W×DESIGN_H, has UIScale, all real UI inside here
local uiScaleObj:  UIScale
local mapBorder:   Frame
local mapCanvas:   Frame
local panel:       Frame
local optionsCard: Frame
local playerList:  Frame
local aiListFrame: Frame
local aiSectionHeader: Frame
local readyBtn:    TextButton
local optionsBtn:  TextButton
local rerollBtn:   TextButton
local statusLbl:   TextLabel
local titleLbl:    TextLabel
local mapLabelRef: TextLabel
local terrainToggleBtn: TextButton

local depositDots:    { Frame } = {}
local terrainDots:    { Frame } = {}
local isReady           = false
local rerollOnCooldown  = false
local pendingRerollAnim = false
local optionsOpen       = false
local lobbyTerrainEnabled = false

type AIEntry = { personality: string, level: number }
local localAIQueue: { AIEntry } = {}

-- personality button refs so we can update their level display
local personalityBtns: { [string]: TextButton } = {}

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

local function stroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color; s.Thickness = thickness; s.Parent = parent
end

local function label(
	parent: Instance,
	text: string,
	size: number,
	color: Color3,
	font: Enum.Font,
	uiSize: UDim2,
	pos: UDim2,
	align: Enum.TextXAlignment?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Text               = text
	l.TextSize           = size
	l.TextColor3         = color
	l.Font               = font
	l.Size               = uiSize
	l.Position           = pos
	l.BackgroundTransparency = 1
	l.TextScaled         = false
	l.TextXAlignment     = align or Enum.TextXAlignment.Center
	l.Parent             = parent
	return l
end

local function makeBtn(
	parent: Instance, text: string,
	size: UDim2, pos: UDim2,
	bgColor: Color3, textColor: Color3, fontSize: number
): TextButton
	local b = Instance.new("TextButton")
	b.Size             = size
	b.Position         = pos
	b.BackgroundColor3 = bgColor
	b.BorderSizePixel  = 0
	b.Font             = Enum.Font.GothamBold
	b.TextSize         = fontSize
	b.TextColor3       = textColor
	b.Text             = text
	b.Parent           = parent
	corner(b, 6)
	return b
end

-- ── Deposit dots ──────────────────────────────────────────────────────────────
local function syncDeposits(positions: { Vector3 }, animate: boolean?)
	if animate then
		for _, dot in depositDots do
			TweenService:Create(dot, TweenInfo.new(0.14), { BackgroundTransparency = 1 }):Play()
		end
		task.delay(0.17, function()
			while #depositDots > #positions do
				depositDots[#depositDots]:Destroy(); table.remove(depositDots)
			end
			for _ = #depositDots + 1, #positions do
				local f = Instance.new("Frame")
				f.Size = UDim2.fromOffset(2, 2); f.AnchorPoint = Vector2.new(0.5, 0.5)
				f.BackgroundColor3 = C_DEPOSIT; f.BorderSizePixel = 0
				f.ZIndex = 5; f.BackgroundTransparency = 1; f.Parent = mapCanvas
				table.insert(depositDots, f)
			end
			for i, pos in positions do
				local u, v = w2p(pos.X, pos.Z)
				depositDots[i].Position = UDim2.fromOffset(u, v)
				TweenService:Create(depositDots[i],
					TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 0, Size = UDim2.fromOffset(6, 6) }
				):Play()
			end
		end)
	else
		while #depositDots > #positions do
			depositDots[#depositDots]:Destroy(); table.remove(depositDots)
		end
		while #depositDots < #positions do
			local f = Instance.new("Frame")
			f.Size = UDim2.fromOffset(6, 6); f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.BackgroundColor3 = C_DEPOSIT; f.BorderSizePixel = 0; f.ZIndex = 5; f.Parent = mapCanvas
			table.insert(depositDots, f)
		end
		for i, pos in positions do
			local u, v = w2p(pos.X, pos.Z)
			depositDots[i].Position = UDim2.fromOffset(u, v)
		end
	end
end

-- ── Terrain preview ───────────────────────────────────────────────────────────
local C_TERRAIN_DOT = Color3.fromRGB(80, 68, 58)

local function syncTerrain(enabled: boolean)
	lobbyTerrainEnabled = enabled
	if terrainToggleBtn then
		terrainToggleBtn.Text             = enabled and "TERRAIN: ON" or "TERRAIN: OFF"
		terrainToggleBtn.BackgroundColor3 = enabled and C_TERRAIN_ON or C_TERRAIN_OFF
	end
	for _, dot in terrainDots do dot:Destroy() end
	terrainDots = {}
	if not enabled or not mapCanvas then return end
	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return end
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		local cx, cz = part.Position.X, part.Position.Z
		local hw, hd = part.Size.X / 2, part.Size.Z / 2
		local pu, pv = w2p(cx, cz)
		local pw = math.max(4, hw * 2 / (WORLD_HALF * 2) * PREVIEW_PX)
		local ph = math.max(4, hd * 2 / (WORLD_HALF * 2) * PREVIEW_PX)
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(pw, ph); dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(pu, pv); dot.BackgroundColor3 = C_TERRAIN_DOT
		dot.BackgroundTransparency = 0.25; dot.BorderSizePixel = 0; dot.ZIndex = 3
		dot.Parent = mapCanvas
		local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 2); c2.Parent = dot
		table.insert(terrainDots, dot)
	end
end

-- ── Player list ───────────────────────────────────────────────────────────────
local function syncPlayers(list: { { name: string, ready: boolean } })
	for _, child in playerList:GetChildren() do
		if child:IsA("Frame") then child:Destroy() end
	end
	for i, entry in list do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 30); row.Position = UDim2.fromOffset(0, (i-1) * 36)
		row.BackgroundColor3 = Color3.fromRGB(18, 28, 55); row.BorderSizePixel = 0
		row.Parent = playerList; corner(row, 5)

		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(9, 9); dot.Position = UDim2.fromOffset(9, 10)
		dot.BackgroundColor3 = entry.ready and C_READY_DOT or C_WAITING_DOT
		dot.BorderSizePixel = 0; dot.Parent = row; corner(dot, 5)

		label(row, entry.name, 13, C_TEXT, Enum.Font.Gotham,
			UDim2.new(0.55, -24, 1, 0), UDim2.fromOffset(25, 0), Enum.TextXAlignment.Left)
		label(row, entry.ready and "READY" or "waiting...", 11,
			entry.ready and C_READY_DOT or C_SUBTEXT, Enum.Font.GothamBold,
			UDim2.new(0.45, -8, 1, 0), UDim2.new(0.55, 0, 0, 0), Enum.TextXAlignment.Right)
	end
	for _, entry in list do
		if entry.name == localPlayer.Name then
			isReady = entry.ready
			readyBtn.BackgroundColor3 = isReady and C_READY_ON or C_READY_OFF
			readyBtn.Text = isReady and "✓  CANCEL READY" or "READY UP"
			break
		end
	end
end

-- ── AI list ───────────────────────────────────────────────────────────────────
local PERSONALITY_COLORS = {
	balanced    = Color3.fromRGB( 45, 190,  75),
	territorial = Color3.fromRGB(210, 140,  30),
	waves       = Color3.fromRGB( 80, 160, 255),
}
local PERSONALITY_LABELS = {
	balanced    = "Balanced",
	territorial = "Territorial",
	waves       = "Waves",
}

local function levelDots(level: number): string
	local s = ""
	for i = 1, 5 do s = s .. (i <= level and "●" or "○") end
	return s
end

local function getQueueEntry(personality: string): AIEntry?
	for _, e in localAIQueue do
		if e.personality == personality then return e end
	end
	return nil
end

local function updatePersonalityButtons()
	for personality, btn in personalityBtns do
		local entry = getQueueEntry(personality)
		local lbl   = PERSONALITY_LABELS[personality] or personality
		btn.Text = entry and (lbl .. "  " .. levelDots(entry.level)) or lbl
	end
end

local function rebuildAIList()
	local hasAIs = #localAIQueue > 0
	aiSectionHeader.Visible = hasAIs
	aiListFrame.Visible     = hasAIs
	for _, child in aiListFrame:GetChildren() do
		if child:IsA("Frame") then child:Destroy() end
	end
	for i, entry in localAIQueue do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28); row.Position = UDim2.fromOffset(0, (i-1)*32)
		row.BackgroundColor3 = C_AI_ROW; row.BorderSizePixel = 0
		row.Parent = aiListFrame; corner(row, 4)

		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(8, 8); dot.Position = UDim2.fromOffset(8, 10)
		dot.BackgroundColor3 = PERSONALITY_COLORS[entry.personality] or C_SUBTEXT
		dot.BorderSizePixel = 0; dot.Parent = row; corner(dot, 4)

		local nameStr = (PERSONALITY_LABELS[entry.personality] or entry.personality) .. " AI"
		label(row, nameStr, 11, C_TEXT, Enum.Font.Gotham,
			UDim2.new(0.55, -20, 1, 0), UDim2.fromOffset(22, 0), Enum.TextXAlignment.Left)

		label(row, levelDots(entry.level), 11, PERSONALITY_COLORS[entry.personality] or C_SUBTEXT,
			Enum.Font.GothamBold, UDim2.new(0.35, 0, 1, 0), UDim2.new(0.45, 0, 0, 0),
			Enum.TextXAlignment.Center)

		local xBtn = Instance.new("TextButton")
		xBtn.Size = UDim2.fromOffset(22, 22); xBtn.Position = UDim2.new(1, -28, 0.5, -11)
		xBtn.BackgroundColor3 = Color3.fromRGB(100, 30, 30); xBtn.BorderSizePixel = 0
		xBtn.Font = Enum.Font.GothamBold; xBtn.TextSize = 13
		xBtn.TextColor3 = Color3.fromRGB(255, 180, 180); xBtn.Text = "×"
		xBtn.Parent = row; corner(xBtn, 4)

		local capturedPersonality = entry.personality
		xBtn.MouseButton1Click:Connect(function()
			RemoteHandler.get(Config.REMOTES.LobbyRemoveAIFull):FireServer(capturedPersonality)
		end)
	end
	updatePersonalityButtons()
end

-- ── Map-roll scan animation ───────────────────────────────────────────────────
local function playMapScan(onDone: () -> ())
	local scan = Instance.new("Frame")
	scan.Name = "ScanLine"; scan.Size = UDim2.new(1, 0, 0, 90)
	scan.Position = UDim2.new(0, 0, 0, -90); scan.BackgroundColor3 = C_ACCENT
	scan.BackgroundTransparency = 0.25; scan.BorderSizePixel = 0; scan.ZIndex = 20
	scan.Parent = mapCanvas

	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,    1), NumberSequenceKeypoint.new(0.18, 0.3),
		NumberSequenceKeypoint.new(0.82, 0.3), NumberSequenceKeypoint.new(1,    1),
	})
	grad.Rotation = 90; grad.Parent = scan

	TweenService:Create(mapBorder, TweenInfo.new(0.08), { BackgroundColor3 = C_ACCENT }):Play()
	task.delay(0.2, function()
		TweenService:Create(mapBorder, TweenInfo.new(0.3), { BackgroundColor3 = C_BORDER }):Play()
	end)

	local sweep = TweenService:Create(scan,
		TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ Position = UDim2.new(0, 0, 1, 0) })
	sweep:Play()
	sweep.Completed:Connect(function() scan:Destroy(); onDone() end)
end

-- ── Game-start transition ─────────────────────────────────────────────────────
--[[
  t=0.00  countdown "3"
  t=0.65  "2"
  t=1.30  "1"
  t=1.80  "GO!" + text/panel fade (0.38s)  — bg stays opaque
  t=2.00  mapBorder captured via AbsolutePosition/Size, re-parented to sg;
          slide+shrink starts (0.70s)
  t=2.70  arrival flash
  t=3.10  map fades (0.26s)
  t=3.38  onComplete() — Camera.init() + HUD.create()
  t=3.38  bg fades (0.25s)
  t=3.63  sg:Destroy()
]]
local function playGameStartTransition(onComplete: () -> ())
	readyBtn.Active  = false
	optionsBtn.Active = false

	task.spawn(function()
		for _, txt in { "3", "2", "1" } do
			statusLbl.Text = "Game starting in  " .. txt
			statusLbl.TextColor3 = C_TEXT; statusLbl.TextSize = 16
			TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 21 }):Play()
			task.delay(0.12, function()
				TweenService:Create(statusLbl, TweenInfo.new(0.22), { TextSize = 15 }):Play()
			end)
			task.wait(0.65)
		end
		statusLbl.Text = "GO!"; statusLbl.TextColor3 = C_READY_DOT; statusLbl.TextSize = 16
		TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 26 }):Play()
		task.delay(0.14, function()
			TweenService:Create(statusLbl, TweenInfo.new(0.30), { TextSize = 16 }):Play()
		end)
	end)

	-- Fade out UI elements (bg stays opaque to hide camera snap)
	task.delay(1.80, function()
		local fade = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(titleLbl,    fade, { TextTransparency = 1 }):Play()
		TweenService:Create(statusLbl,   fade, { TextTransparency = 1 }):Play()
		TweenService:Create(mapLabelRef, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(panel, fade, { BackgroundTransparency = 1 }):Play()
		for _, d in panel:GetDescendants() do
			if d:IsA("GuiObject") then
				pcall(function() TweenService:Create(d, fade, { BackgroundTransparency = 1 }):Play() end)
			end
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				pcall(function() TweenService:Create(d, fade, { TextTransparency = 1 }):Play() end)
			end
		end
		if optionsCard then
			TweenService:Create(optionsCard, fade, { BackgroundTransparency = 1 }):Play()
			for _, d in optionsCard:GetDescendants() do
				if d:IsA("GuiObject") then
					pcall(function() TweenService:Create(d, fade, { BackgroundTransparency = 1 }):Play() end)
				end
				if d:IsA("TextLabel") or d:IsA("TextButton") then
					pcall(function() TweenService:Create(d, fade, { TextTransparency = 1 }):Play() end)
				end
			end
		end
		task.delay(0.42, function()
			panel.Visible = false
			if optionsCard then optionsCard.Visible = false end
		end)
	end)

	-- Map card slide to minimap corner
	task.delay(2.00, function()
		mapBorder.ClipsDescendants = true

		-- Capture real screen-space position/size BEFORE reparenting.
		-- AbsolutePosition/Size already account for UIScale.
		local absPos  = mapBorder.AbsolutePosition
		local absSize = mapBorder.AbsoluteSize
		local canvasAbsPos = mapCanvas.AbsolutePosition

		-- Move mapBorder into sg (screen space) at its current visual position
		mapBorder.Size     = UDim2.fromOffset(absSize.X, absSize.Y)
		mapBorder.Position = UDim2.fromOffset(absPos.X, absPos.Y)
		mapBorder.ZIndex   = 12
		mapBorder.Parent   = sg

		-- mapCanvas: adjust relative to new parent (mapBorder in screen space)
		local relX = canvasAbsPos.X - absPos.X
		local relY = canvasAbsPos.Y - absPos.Y
		mapCanvas.Position = UDim2.fromOffset(relX, relY)
		mapCanvas.Size     = UDim2.fromOffset(mapCanvas.AbsoluteSize.X, mapCanvas.AbsoluteSize.Y)

		-- Departure flash
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
			TweenService:Create(mapBorder, TweenInfo.new(0.08), {
				BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			}):Play()
			task.delay(0.10, function()
				TweenService:Create(mapBorder, TweenInfo.new(0.30), {
					BackgroundColor3 = C_BORDER
				}):Play()
			end)

			task.delay(0.40, function()
				local finalFade = TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				TweenService:Create(mapBorder, finalFade, { BackgroundTransparency = 1 }):Play()
				TweenService:Create(mapCanvas, finalFade, { BackgroundTransparency = 1 }):Play()
				for _, child in mapCanvas:GetDescendants() do
					if child:IsA("GuiObject") then
						pcall(function()
							TweenService:Create(child, finalFade, { BackgroundTransparency = 1 }):Play()
						end)
					end
				end

				task.delay(0.28, function()
					onComplete()
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

-- ── Options toggle ────────────────────────────────────────────────────────────
local function setOptionsOpen(open: boolean)
	optionsOpen = open
	optionsBtn.BackgroundColor3 = open and C_OPTIONS_ON or C_OPTIONS_BTN
	optionsBtn.Text = open and "OPTIONS  ▲" or "OPTIONS  ▼"
	optionsCard.Visible = open
end

-- ── Build UI ──────────────────────────────────────────────────────────────────
local function buildUI()
	sg = Instance.new("ScreenGui")
	sg.Name = "LobbyUI"; sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = true; sg.DisplayOrder = 100
	sg.Parent = localPlayer.PlayerGui

	-- Full-screen backdrop — NOT inside container so it always fills the screen
	bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0); bg.BackgroundColor3 = C_BG
	bg.BorderSizePixel = 0; bg.Parent = sg

	-- Centered design-space container with UIScale
	container = Instance.new("Frame")
	container.Name             = "Container"
	container.Size             = UDim2.fromOffset(DESIGN_W, DESIGN_H)
	container.AnchorPoint      = Vector2.new(0.5, 0.5)
	container.Position         = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundTransparency = 1
	container.ClipsDescendants = false
	container.Parent           = sg

	uiScaleObj = Instance.new("UIScale")
	uiScaleObj.Scale = 1
	uiScaleObj.Parent = container

	-- Title
	titleLbl = label(container, "LUCENT", 40, C_TITLE, Enum.Font.GothamBold,
		UDim2.new(1, 0, 0, 56), UDim2.fromOffset(0, 16))

	statusLbl = label(container, "Waiting for players to ready up...", 14, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 68))

	-- ── Content frame (map + panel, centered in container) ────────────────────
	local content = Instance.new("Frame")
	content.Size             = UDim2.fromOffset(CONTENT_W, PANEL_H)
	content.Position         = UDim2.fromOffset(CONTENT_X, CONTENT_Y)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = false
	content.Parent           = container

	-- ── Map preview ───────────────────────────────────────────────────────────
	mapLabelRef = label(content, "MAP PREVIEW", 11, C_BORDER, Enum.Font.GothamBold,
		UDim2.fromOffset(PREVIEW_PX + 4, 22), UDim2.fromOffset(0, 0))

	mapBorder = Instance.new("Frame")
	mapBorder.Size             = UDim2.fromOffset(PREVIEW_PX + 4, PREVIEW_PX + 4)
	mapBorder.Position         = UDim2.fromOffset(0, 22)
	mapBorder.BackgroundColor3 = C_BORDER
	mapBorder.BorderSizePixel  = 0
	mapBorder.Parent           = content
	corner(mapBorder, 4)

	mapCanvas = Instance.new("Frame")
	mapCanvas.Size             = UDim2.fromOffset(PREVIEW_PX, PREVIEW_PX)
	mapCanvas.Position         = UDim2.fromOffset(2, 2)
	mapCanvas.BackgroundColor3 = Color3.fromRGB(10, 16, 34)
	mapCanvas.BorderSizePixel  = 0
	mapCanvas.ClipsDescendants = true
	mapCanvas.Parent           = mapBorder

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
		c2.BackgroundColor3 = Color3.fromRGB(30,46,90); c2.BorderSizePixel = 0
		c2.ZIndex = 2; c2.Parent = mapCanvas
	end

	-- ── Right panel ───────────────────────────────────────────────────────────
	panel = Instance.new("Frame")
	panel.Size             = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Position         = UDim2.fromOffset(PREVIEW_PX + 4 + 16, 0)
	panel.BackgroundColor3 = C_PANEL
	panel.BorderSizePixel  = 0
	panel.ClipsDescendants = false
	panel.Parent           = content
	corner(panel, 6); stroke(panel, C_BORDER, 1)

	-- PLAYERS header
	label(panel, "PLAYERS", 11, C_BORDER, Enum.Font.GothamBold,
		UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 10), Enum.TextXAlignment.Left)

	-- Player list
	playerList = Instance.new("Frame")
	playerList.Size = UDim2.new(1, -20, 0, 108); playerList.Position = UDim2.fromOffset(10, 36)
	playerList.BackgroundTransparency = 1; playerList.ClipsDescendants = true
	playerList.Parent = panel

	-- AI section header
	aiSectionHeader = Instance.new("Frame")
	aiSectionHeader.Size = UDim2.new(1, -20, 0, 22); aiSectionHeader.Position = UDim2.fromOffset(10, 150)
	aiSectionHeader.BackgroundTransparency = 1; aiSectionHeader.Visible = false
	aiSectionHeader.Parent = panel

	for _, cfg in {
		{ size = UDim2.new(0.2, 0, 0, 1), pos = UDim2.new(0,   0, 0.5, 0) },
		{ size = UDim2.new(0.2, 0, 0, 1), pos = UDim2.new(0.8, 0, 0.5, 0) },
	} do
		local ln = Instance.new("Frame")
		ln.Size = cfg.size; ln.Position = cfg.pos
		ln.BackgroundColor3 = C_SECTION_DIV; ln.BackgroundTransparency = 0.3
		ln.BorderSizePixel = 0; ln.Parent = aiSectionHeader
	end
	label(aiSectionHeader, "AI", 10, C_AI_HEADER, Enum.Font.GothamBold,
		UDim2.new(0.6, 0, 1, 0), UDim2.new(0.2, 0, 0, 0))

	-- AI list
	aiListFrame = Instance.new("Frame")
	aiListFrame.Size = UDim2.new(1, -20, 0, 96); aiListFrame.Position = UDim2.fromOffset(10, 174)
	aiListFrame.BackgroundTransparency = 1; aiListFrame.ClipsDescendants = true
	aiListFrame.Visible = false; aiListFrame.Parent = panel

	-- Bottom buttons (anchored from panel bottom edge)
	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, -20, 0, 1); div.Position = UDim2.new(0, 10, 1, -96)
	div.BackgroundColor3 = C_BORDER; div.BackgroundTransparency = 0.55
	div.BorderSizePixel = 0; div.Parent = panel

	readyBtn = makeBtn(panel, "READY UP",
		UDim2.new(1, -20, 0, 46), UDim2.new(0, 10, 1, -88),
		C_READY_OFF, Color3.fromRGB(255, 255, 255), 15)

	optionsBtn = makeBtn(panel, "OPTIONS  ▼",
		UDim2.new(1, -20, 0, 34), UDim2.new(0, 10, 1, -38),
		C_OPTIONS_BTN, Color3.fromRGB(150, 185, 235), 12)
	stroke(optionsBtn, C_BORDER, 1)

	-- ── Options dropdown card (child of panel, below it) ─────────────────────
	optionsCard = Instance.new("Frame")
	optionsCard.Size             = UDim2.fromOffset(PANEL_W, OPT_H)
	optionsCard.Position         = UDim2.fromOffset(0, PANEL_H + 4)
	optionsCard.BackgroundColor3 = C_OPTIONS_BG
	optionsCard.BorderSizePixel  = 0
	optionsCard.Visible          = false
	optionsCard.ZIndex           = 8
	optionsCard.Parent           = panel
	corner(optionsCard, 6); stroke(optionsCard, C_BORDER, 1)

	local oy = 8

	label(optionsCard, "MAP & SETTINGS", 10, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -20, 0, 12), UDim2.fromOffset(10, oy), Enum.TextXAlignment.Left)
	oy += 16

	rerollBtn = makeBtn(optionsCard, "RE-ROLL MAP",
		UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, oy),
		C_REROLL, Color3.fromRGB(150, 185, 235), 12)
	stroke(rerollBtn, C_BORDER, 1); oy += 30

	terrainToggleBtn = makeBtn(optionsCard, "TERRAIN: OFF",
		UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, oy),
		C_TERRAIN_OFF, Color3.fromRGB(185, 155, 110), 12)
	stroke(terrainToggleBtn, C_BORDER, 1); oy += 30

	label(optionsCard, "AI PERSONALITIES", 10, C_SUBTEXT, Enum.Font.GothamBold,
		UDim2.new(1, -20, 0, 12), UDim2.fromOffset(10, oy), Enum.TextXAlignment.Left)
	oy += 16

	for _, d in ipairs({
		{ personality = "balanced",    bgColor = C_AI_BALANCED, tc = Color3.fromRGB(130, 215, 155) },
		{ personality = "territorial", bgColor = C_AI_TERR,     tc = Color3.fromRGB(220, 170, 100) },
		{ personality = "waves",       bgColor = C_AI_WAVES,    tc = Color3.fromRGB(130, 185, 255) },
	}) do
		local btn = makeBtn(optionsCard, PERSONALITY_LABELS[d.personality],
			UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, oy),
			d.bgColor, d.tc, 11)
		stroke(btn, C_BORDER, 1)
		oy += 30

		local p = d.personality
		personalityBtns[p] = btn

		btn.MouseButton1Click:Connect(function()
			RemoteHandler.get(Config.REMOTES.LobbyAddAI):FireServer(p)
		end)
		btn.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				RemoteHandler.get(Config.REMOTES.LobbyRemoveAI):FireServer(p)
			end
		end)
	end
end

-- ── Public init ───────────────────────────────────────────────────────────────
function LobbyUI.init(onGameStart: () -> ())
	buildUI()

	-- Scale to fit viewport
	updateScale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)

	-- Overhead camera
	task.spawn(function()
		task.wait(0.1)
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 700, 1), Vector3.new(0, 0, 0))
	end)

	-- LobbySync
	RemoteHandler.get(Config.REMOTES.LobbySync).OnClientEvent:Connect(
		function(
			readyList: { { name: string, ready: boolean } },
			positions: { Vector3 },
			terrainOn: boolean,
			aiList:    { AIEntry }?
		)
			syncPlayers(readyList)
			localAIQueue = aiList or {}
			rebuildAIList()
			if pendingRerollAnim then
				pendingRerollAnim = false
				playMapScan(function()
					syncDeposits(positions, true)
					task.wait(0.05)
					syncTerrain(terrainOn)
				end)
			else
				syncDeposits(positions, false)
				syncTerrain(terrainOn)
			end
		end
	)

	readyBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyReady):FireServer()
	end)

	optionsBtn.MouseButton1Click:Connect(function()
		setOptionsOpen(not optionsOpen)
	end)

	rerollBtn.MouseButton1Click:Connect(function()
		if rerollOnCooldown then return end
		rerollOnCooldown  = true
		pendingRerollAnim = true
		RemoteHandler.get(Config.REMOTES.LobbyReroll):FireServer()
		rerollBtn.BackgroundColor3 = C_COOLDOWN
		for i = 3, 1, -1 do
			rerollBtn.Text = string.format("RE-ROLL  (%ds)", i)
			task.wait(1)
		end
		rerollOnCooldown           = false
		rerollBtn.BackgroundColor3 = C_REROLL
		rerollBtn.Text             = "RE-ROLL MAP"
	end)

	terrainToggleBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle):FireServer()
	end)

	RemoteHandler.get(Config.REMOTES.LobbyStart).OnClientEvent:Connect(function()
		playGameStartTransition(onGameStart)
	end)
end

return LobbyUI
