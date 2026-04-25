--[[
	LobbyUI — full-screen pre-game lobby.

	Shows a 2D map preview with ore-deposit markers, a player ready-state list,
	a Ready Up toggle button, and a Re-Roll Map button (3-second client cooldown
	enforced by the server as well).

	All game UI and controls are deliberately NOT initialised until onGameStart()
	fires, ensuring nothing is active while the lobby is open.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))

local LobbyUI     = {}
local localPlayer = Players.LocalPlayer

-- ── Map-preview constants ─────────────────────────────────────────────────────
local WORLD_HALF   = 432    -- must match FogManager / MiniMap
local PREVIEW_PX   = 370    -- pixel side-length of the map preview square

-- Minimap constants — must match MiniMap.luau exactly
local MINIMAP_SIZE = 180    -- MAP_SIZE in MiniMap.luau
local MINIMAP_PAD  = 10     -- PADDING in MiniMap.luau

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
local C_REROLL        = Color3.fromRGB( 18,  34,  72)
local C_COOLDOWN      = Color3.fromRGB( 40,  40,  70)
local C_TERRAIN_OFF   = Color3.fromRGB( 18,  34,  72)
local C_TERRAIN_ON    = Color3.fromRGB( 55,  38,  18)

-- ── Module state ──────────────────────────────────────────────────────────────
local sg:          ScreenGui
local bg:          Frame       -- full-screen backdrop
local mapBorder:   Frame       -- coloured border around the map canvas
local mapCanvas:   Frame       -- the actual drawable map area
local panel:       Frame       -- right-side player/button panel
local playerList:  Frame
local readyBtn:    TextButton
local rerollBtn:   TextButton
local rerollHint:  TextLabel
local statusLbl:   TextLabel
local titleLbl:    TextLabel
local mapLabelRef: TextLabel   -- "MAP PREVIEW" text above the map

local depositDots:    { Frame } = {}
local terrainDots:    { Frame } = {}   -- grey obstacle rectangles on map preview
local isReady          = false
local rerollOnCooldown = false
local pendingRerollAnim = false  -- true after client fires reroll, cleared on next sync
local terrainToggleBtn: TextButton
local lobbyTerrainEnabled = false

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
	l.TextXAlignment     = align or Enum.TextXAlignment.Center
	l.Parent             = parent
	return l
end

-- ── Deposit dots ──────────────────────────────────────────────────────────────
local function syncDeposits(positions: { Vector3 }, animate: boolean?)
	if animate then
		-- Fade out existing dots
		for _, dot in depositDots do
			TweenService:Create(dot, TweenInfo.new(0.14), { BackgroundTransparency = 1 }):Play()
		end

		task.delay(0.17, function()
			-- Resize pool
			while #depositDots > #positions do
				depositDots[#depositDots]:Destroy()
				table.remove(depositDots)
			end
			for _ = #depositDots + 1, #positions do
				local f = Instance.new("Frame")
				f.Size                    = UDim2.fromOffset(2, 2)
				f.AnchorPoint             = Vector2.new(0.5, 0.5)
				f.BackgroundColor3        = C_DEPOSIT
				f.BorderSizePixel         = 0
				f.ZIndex                  = 5
				f.BackgroundTransparency  = 1
				f.Parent                  = mapCanvas
				table.insert(depositDots, f)
			end

			-- Pop new dots in with a Back-ease scale
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
			depositDots[#depositDots]:Destroy()
			table.remove(depositDots)
		end
		while #depositDots < #positions do
			local f = Instance.new("Frame")
			f.Size             = UDim2.fromOffset(6, 6)
			f.AnchorPoint      = Vector2.new(0.5, 0.5)
			f.BackgroundColor3 = C_DEPOSIT
			f.BorderSizePixel  = 0
			f.ZIndex           = 5
			f.Parent           = mapCanvas
			table.insert(depositDots, f)
		end
		for i, pos in positions do
			local u, v = w2p(pos.X, pos.Z)
			depositDots[i].Position = UDim2.fromOffset(u, v)
		end
	end
end

-- ── Terrain preview dots ─────────────────────────────────────────────────────
local C_TERRAIN_DOT = Color3.fromRGB(80, 68, 58)

local function syncTerrain(enabled: boolean)
	lobbyTerrainEnabled = enabled

	-- Update button label if it's built yet
	if terrainToggleBtn then
		terrainToggleBtn.Text             = enabled and "TERRAIN: ON" or "TERRAIN: OFF"
		terrainToggleBtn.BackgroundColor3 = enabled and C_TERRAIN_ON or C_TERRAIN_OFF
	end

	-- Clear existing dots
	for _, dot in terrainDots do dot:Destroy() end
	terrainDots = {}

	if not enabled then return end
	if not mapCanvas then return end

	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return end

	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		local cx, cz = part.Position.X, part.Position.Z
		local hw, hd = part.Size.X / 2, part.Size.Z / 2
		local pu, pv = w2p(cx, cz)
		local pw     = hw * 2 / (WORLD_HALF * 2) * PREVIEW_PX
		local ph     = hd * 2 / (WORLD_HALF * 2) * PREVIEW_PX

		local dot               = Instance.new("Frame")
		dot.Size                = UDim2.fromOffset(math.max(4, pw), math.max(4, ph))
		dot.AnchorPoint         = Vector2.new(0.5, 0.5)
		dot.Position            = UDim2.fromOffset(pu, pv)
		dot.BackgroundColor3    = C_TERRAIN_DOT
		dot.BackgroundTransparency = 0.25
		dot.BorderSizePixel     = 0
		dot.ZIndex              = 3
		dot.Parent              = mapCanvas
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 2); c.Parent = dot
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
		row.Size             = UDim2.new(1, 0, 0, 34)
		row.Position         = UDim2.fromOffset(0, (i - 1) * 40)
		row.BackgroundColor3 = Color3.fromRGB(18, 28, 55)
		row.BorderSizePixel  = 0
		row.Parent           = playerList
		corner(row, 5)

		-- Status dot
		local dot = Instance.new("Frame")
		dot.Size             = UDim2.fromOffset(10, 10)
		dot.Position         = UDim2.fromOffset(10, 12)
		dot.BackgroundColor3 = entry.ready and C_READY_DOT or C_WAITING_DOT
		dot.BorderSizePixel  = 0
		dot.Parent           = row
		corner(dot, 6)

		-- Name
		label(row, entry.name, 14, C_TEXT, Enum.Font.Gotham,
			UDim2.new(0.55, -28, 1, 0), UDim2.fromOffset(28, 0),
			Enum.TextXAlignment.Left)

		-- Status text
		label(row,
			entry.ready and "READY" or "waiting...", 12,
			entry.ready and C_READY_DOT or C_SUBTEXT,
			Enum.Font.GothamBold,
			UDim2.new(0.45, -8, 1, 0),
			UDim2.new(0.55, 0, 0, 0),
			Enum.TextXAlignment.Right)
	end

	-- Reflect own ready state
	for _, entry in list do
		if entry.name == localPlayer.Name then
			isReady = entry.ready
			readyBtn.BackgroundColor3 = isReady and C_READY_ON or C_READY_OFF
			readyBtn.Text = isReady and "✓  CANCEL READY" or "READY UP"
			break
		end
	end
end

-- ── Map-roll scan animation ────────────────────────────────────────────────────
local function playMapScan(onDone: () -> ())
	-- Glowing sweep line from top → bottom of the map canvas
	local scan                      = Instance.new("Frame")
	scan.Name                       = "ScanLine"
	scan.Size                       = UDim2.new(1, 0, 0, 90)
	scan.Position                   = UDim2.new(0, 0, 0, -90)
	scan.BackgroundColor3           = C_ACCENT
	scan.BackgroundTransparency     = 0.25
	scan.BorderSizePixel            = 0
	scan.ZIndex                     = 20
	scan.Parent                     = mapCanvas

	local grad                      = Instance.new("UIGradient")
	grad.Transparency               = NumberSequence.new({
		NumberSequenceKeypoint.new(0,    1),
		NumberSequenceKeypoint.new(0.18, 0.3),
		NumberSequenceKeypoint.new(0.82, 0.3),
		NumberSequenceKeypoint.new(1,    1),
	})
	grad.Rotation                   = 90
	grad.Parent                     = scan

	-- Border colour flash
	TweenService:Create(mapBorder, TweenInfo.new(0.08), { BackgroundColor3 = C_ACCENT }):Play()
	task.delay(0.2, function()
		TweenService:Create(mapBorder, TweenInfo.new(0.3), { BackgroundColor3 = C_BORDER }):Play()
	end)

	local sweep = TweenService:Create(scan,
		TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ Position = UDim2.new(0, 0, 1, 0) }
	)
	sweep:Play()
	sweep.Completed:Connect(function()
		scan:Destroy()
		onDone()
	end)
end

-- ── Game-start transition sequence ────────────────────────────────────────────
--[[
  Timing:
    t = 0.00  countdown "3"
    t = 0.65  "2"
    t = 1.30  "1"
    t = 1.80  "GO!" + text/panel fade begins (0.38s)
              bg stays OPAQUE — hides the 3D world so no camera snap is visible
    t = 2.00  mapBorder re-parented to sg root; slide+shrink starts (0.70s)
    t = 2.70  slide complete; arrival flash
    t = 3.10  map card fades out (0.28s)
    t = 3.38  onComplete() fired — Camera.init() runs and positions the RTS camera
              bg is still opaque here, so the camera snap is invisible
    t = 3.38  bg fades out (0.25s), cleanly revealing the already-positioned game view
    t = 3.63  sg:Destroy()
]]
local function playGameStartTransition(onComplete: () -> ())
	readyBtn.Active  = false
	rerollBtn.Active = false

	-- ── Phase 1: countdown (0 → 1.8 s) ──────────────────────────────────────
	task.spawn(function()
		local steps   = { "3", "2", "1" }
		local stepGap = 0.65
		for _, txt in steps do
			statusLbl.Text       = "Game starting in  " .. txt
			statusLbl.TextColor3 = C_TEXT
			statusLbl.TextSize   = 16
			TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 21 }):Play()
			task.delay(0.12, function()
				TweenService:Create(statusLbl, TweenInfo.new(0.22), { TextSize = 15 }):Play()
			end)
			task.wait(stepGap)
		end
		statusLbl.Text       = "GO!"
		statusLbl.TextColor3 = C_READY_DOT
		statusLbl.TextSize   = 16
		TweenService:Create(statusLbl, TweenInfo.new(0.10), { TextSize = 26 }):Play()
		task.delay(0.14, function()
			TweenService:Create(statusLbl, TweenInfo.new(0.30), { TextSize = 16 }):Play()
		end)
	end)

	-- ── Phase 2: fade out text + panel; bg stays opaque (t = 1.80 s) ────────
	-- Keeping bg opaque prevents the 3D world from ever being visible while the
	-- lobby camera is still at the aerial Y=700 position.
	task.delay(1.80, function()
		local fade = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- Text labels only
		TweenService:Create(titleLbl,    fade, { TextTransparency = 1 }):Play()
		TweenService:Create(statusLbl,   fade, { TextTransparency = 1 }):Play()
		TweenService:Create(mapLabelRef, fade, { TextTransparency = 1 }):Play()

		-- Player panel background + all its child frames / labels / buttons
		TweenService:Create(panel, fade, { BackgroundTransparency = 1 }):Play()
		for _, d in panel:GetDescendants() do
			if d:IsA("GuiObject") then
				pcall(function() TweenService:Create(d, fade, { BackgroundTransparency = 1 }):Play() end)
			end
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				pcall(function() TweenService:Create(d, fade, { TextTransparency = 1 }):Play() end)
			end
		end

		-- Once the fade is done, hide the panel completely so it cannot
		-- intercept mouse events during the rest of the transition
		task.delay(0.42, function()
			panel.Visible = false
		end)
	end)

	-- ── Phase 3: map slides to minimap corner (t = 2.00 s) ──────────────────
	task.delay(2.00, function()
		mapBorder.ClipsDescendants = true

		-- Screen-relative top-left of mapBorder:
		--   content starts at (0.5, -totalW/2, 0.5, -totalH/2 + 18)
		--   mapBorder is at fromOffset(0, 22) inside content
		local totalW = PREVIEW_PX + 16 + 300   -- 686
		local totalH = PREVIEW_PX + 26          -- 396
		local bxOff  = -math.floor(totalW / 2)            -- -343
		local byOff  = -math.floor(totalH / 2) + 18 + 22  -- -158

		mapBorder.ZIndex   = 12
		mapBorder.Position = UDim2.new(0.5, bxOff, 0.5, byOff)
		mapBorder.Parent   = sg   -- re-parent so it can travel anywhere on screen

		-- Departure flash
		TweenService:Create(mapBorder, TweenInfo.new(0.08), { BackgroundColor3 = C_ACCENT }):Play()
		task.delay(0.12, function()
			TweenService:Create(mapBorder, TweenInfo.new(0.22), { BackgroundColor3 = C_BORDER }):Play()
		end)

		-- Slide + shrink to minimap position.
		-- mapCanvas position is also tweened to keep the map centre locked.
		local mmBorder    = MINIMAP_SIZE + 4                        -- 184
		local canvasFinal = math.floor((mmBorder - PREVIEW_PX) / 2) -- ≈ -93
		local slideInfo   = TweenInfo.new(0.70, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)

		TweenService:Create(mapBorder, slideInfo, {
			Position = UDim2.new(1, -(mmBorder + MINIMAP_PAD), 1, -(mmBorder + MINIMAP_PAD)),
			Size     = UDim2.fromOffset(mmBorder, mmBorder),
		}):Play()
		TweenService:Create(mapCanvas, slideInfo, {
			Position = UDim2.fromOffset(canvasFinal, canvasFinal),
		}):Play()

		-- ── Phase 4: arrival pulse (t = 2.72 s) ──────────────────────────────
		task.delay(0.72, function()
			TweenService:Create(mapBorder, TweenInfo.new(0.08), {
				BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			}):Play()
			task.delay(0.10, function()
				TweenService:Create(mapBorder, TweenInfo.new(0.30), {
					BackgroundColor3 = C_BORDER
				}):Play()
			end)

			-- ── Phase 5: fade map card out (t = 3.12 s) ──────────────────────
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

				-- ── Phase 6: start game + fade backdrop (t = 3.38 s) ─────────
				-- Camera.init() runs inside onComplete() and sets the RTS CFrame.
				-- bg is still fully opaque at this point, so the camera snap from
				-- the aerial lobby position to the RTS position is completely hidden.
				-- We then fade bg out, cleanly revealing the already-positioned view.
				task.delay(0.28, function()
					onComplete()   -- Camera.init() + HUD.create() happen here

					local bgFade = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					TweenService:Create(bg, bgFade, { BackgroundTransparency = 1 }):Play()

					task.delay(0.27, function()
						sg:Destroy()
					end)
				end)
			end)
		end)
	end)
end

-- ── Build UI ──────────────────────────────────────────────────────────────────
local function buildUI()
	sg               = Instance.new("ScreenGui")
	sg.Name          = "LobbyUI"
	sg.ResetOnSpawn  = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = true
	sg.DisplayOrder  = 100   -- always above RTSHUD (DisplayOrder 0) during transition
	sg.Parent        = localPlayer.PlayerGui

	-- Full backdrop
	bg               = Instance.new("Frame")
	bg.Size          = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = C_BG
	bg.BorderSizePixel  = 0
	bg.Parent        = sg

	-- Title
	titleLbl = label(bg, "LUCENT", 40, C_TITLE, Enum.Font.GothamBold,
		UDim2.new(1, 0, 0, 56), UDim2.new(0, 0, 0, 16))

	statusLbl = label(bg, "Waiting for players to ready up...", 14, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 62))

	-- ── Content row ──────────────────────────────────────────────────────────
	local totalW = PREVIEW_PX + 16 + 300   -- map + gap + panel
	local totalH = PREVIEW_PX + 74         -- extra 48px for terrain toggle button
	local content = Instance.new("Frame")
	content.Size             = UDim2.fromOffset(totalW, totalH)
	content.Position         = UDim2.new(0.5, -totalW / 2, 0.5, -totalH / 2 + 18)
	content.BackgroundTransparency = 1
	content.Parent           = bg

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

	-- Grid lines
	for _, frac in { 0.25, 0.5, 0.75 } do
		local h = Instance.new("Frame")
		h.Size = UDim2.new(1, 0, 0, 1); h.Position = UDim2.new(0, 0, frac, 0)
		h.BackgroundColor3 = C_GRID; h.BorderSizePixel = 0; h.ZIndex = 2; h.Parent = mapCanvas
		local v = Instance.new("Frame")
		v.Size = UDim2.new(0, 1, 1, 0); v.Position = UDim2.new(frac, 0, 0, 0)
		v.BackgroundColor3 = C_GRID; v.BorderSizePixel = 0; v.ZIndex = 2; v.Parent = mapCanvas
	end
	-- Brighter center cross
	local hc = Instance.new("Frame"); hc.Size = UDim2.new(1,0,0,1); hc.Position = UDim2.new(0,0,0.5,0)
	hc.BackgroundColor3 = Color3.fromRGB(30,46,90); hc.BorderSizePixel=0; hc.ZIndex=2; hc.Parent=mapCanvas
	local vc = Instance.new("Frame"); vc.Size = UDim2.new(0,1,1,0); vc.Position = UDim2.new(0.5,0,0,0)
	vc.BackgroundColor3 = Color3.fromRGB(30,46,90); vc.BorderSizePixel=0; vc.ZIndex=2; vc.Parent=mapCanvas

	-- ── Right panel ───────────────────────────────────────────────────────────
	panel = Instance.new("Frame")
	panel.Size             = UDim2.fromOffset(300, totalH)
	panel.Position         = UDim2.fromOffset(PREVIEW_PX + 16, 0)
	panel.BackgroundColor3 = C_PANEL
	panel.BorderSizePixel  = 0
	panel.Parent           = content
	corner(panel, 6)
	stroke(panel, C_BORDER, 1)

	label(panel, "PLAYERS", 12, C_BORDER, Enum.Font.GothamBold,
		UDim2.new(1, -20, 0, 28), UDim2.fromOffset(10, 12),
		Enum.TextXAlignment.Left)

	playerList = Instance.new("Frame")
	playerList.Size              = UDim2.new(1, -20, 0, 200)
	playerList.Position          = UDim2.fromOffset(10, 44)
	playerList.BackgroundTransparency = 1
	playerList.ClipsDescendants  = true
	playerList.Parent            = panel

	-- Divider
	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, -20, 0, 1); div.Position = UDim2.fromOffset(10, 254)
	div.BackgroundColor3 = C_BORDER; div.BackgroundTransparency = 0.55
	div.BorderSizePixel = 0; div.Parent = panel

	-- Ready button
	readyBtn = Instance.new("TextButton")
	readyBtn.Size             = UDim2.new(1, -20, 0, 46)
	readyBtn.Position         = UDim2.fromOffset(10, 264)
	readyBtn.BackgroundColor3 = C_READY_OFF
	readyBtn.BorderSizePixel  = 0
	readyBtn.Font             = Enum.Font.GothamBold
	readyBtn.TextSize         = 16
	readyBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	readyBtn.Text             = "READY UP"
	readyBtn.Parent           = panel
	corner(readyBtn, 6)

	-- Reroll button
	rerollBtn = Instance.new("TextButton")
	rerollBtn.Size             = UDim2.new(1, -20, 0, 38)
	rerollBtn.Position         = UDim2.fromOffset(10, 320)
	rerollBtn.BackgroundColor3 = C_REROLL
	rerollBtn.BorderSizePixel  = 0
	rerollBtn.Font             = Enum.Font.GothamBold
	rerollBtn.TextSize         = 13
	rerollBtn.TextColor3       = Color3.fromRGB(150, 185, 235)
	rerollBtn.Text             = "RE-ROLL MAP"
	rerollBtn.Parent           = panel
	corner(rerollBtn, 6)
	stroke(rerollBtn, C_BORDER, 1)

	rerollHint = label(panel, "Re-rolling resets all ready states", 11, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, -20, 0, 18), UDim2.fromOffset(10, 364),
		Enum.TextXAlignment.Center)

	-- Terrain toggle button
	terrainToggleBtn = Instance.new("TextButton")
	terrainToggleBtn.Size             = UDim2.new(1, -20, 0, 38)
	terrainToggleBtn.Position         = UDim2.fromOffset(10, 388)
	terrainToggleBtn.BackgroundColor3 = C_TERRAIN_OFF
	terrainToggleBtn.BorderSizePixel  = 0
	terrainToggleBtn.Font             = Enum.Font.GothamBold
	terrainToggleBtn.TextSize         = 13
	terrainToggleBtn.TextColor3       = Color3.fromRGB(185, 155, 110)
	terrainToggleBtn.Text             = "TERRAIN: OFF"
	terrainToggleBtn.Parent           = panel
	corner(terrainToggleBtn, 6)
	stroke(terrainToggleBtn, C_BORDER, 1)
end

-- ── Public init ───────────────────────────────────────────────────────────────

function LobbyUI.init(onGameStart: () -> ())
	buildUI()

	-- Fixed overhead camera so players can see the terrain / map
	task.spawn(function()
		task.wait(0.1)
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 700, 1), Vector3.new(0, 0, 0))
	end)

	-- ── LobbySync ─────────────────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.LobbySync).OnClientEvent:Connect(
		function(readyList: {{ name: string, ready: boolean }}, positions: { Vector3 }, terrainOn: boolean)
			syncPlayers(readyList)
			if pendingRerollAnim then
				pendingRerollAnim = false
				playMapScan(function()
					syncDeposits(positions, true)
					task.wait(0.05)  -- let workspace replicate terrain changes
					syncTerrain(terrainOn)
				end)
			else
				syncDeposits(positions, false)
				syncTerrain(terrainOn)
			end
		end
	)

	-- ── Ready button ──────────────────────────────────────────────────────────
	readyBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyReady):FireServer()
	end)

	-- ── Re-roll button (3-second client-side cooldown) ────────────────────────
	rerollBtn.MouseButton1Click:Connect(function()
		if rerollOnCooldown then return end
		rerollOnCooldown    = true
		pendingRerollAnim   = true
		RemoteHandler.get(Config.REMOTES.LobbyReroll):FireServer()

		rerollBtn.BackgroundColor3 = C_COOLDOWN
		rerollHint.Text            = "Cooldown..."

		for i = 3, 1, -1 do
			rerollBtn.Text = string.format("RE-ROLL  (%ds)", i)
			task.wait(1)
		end

		rerollOnCooldown           = false
		rerollBtn.BackgroundColor3 = C_REROLL
		rerollBtn.Text             = "RE-ROLL MAP"
		rerollHint.Text            = "Re-rolling resets all ready states"
	end)

	-- ── Terrain toggle ────────────────────────────────────────────────────────
	terrainToggleBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyTerrainToggle):FireServer()
	end)

	-- ── LobbyStart ────────────────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.LobbyStart).OnClientEvent:Connect(function()
		playGameStartTransition(function()
			onGameStart()
		end)
	end)
end

return LobbyUI
