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

-- ── Palette ───────────────────────────────────────────────────────────────────
local C_BG          = Color3.fromRGB(  8,  12,  26)
local C_PANEL       = Color3.fromRGB( 14,  20,  40)
local C_BORDER      = Color3.fromRGB( 35,  75, 140)
local C_GRID        = Color3.fromRGB( 20,  30,  55)
local C_TITLE       = Color3.fromRGB(180, 210, 255)
local C_TEXT        = Color3.fromRGB(200, 220, 255)
local C_SUBTEXT     = Color3.fromRGB(100, 130, 180)
local C_DEPOSIT     = Color3.fromRGB(255, 248, 160)
local C_READY_ON    = Color3.fromRGB( 45, 190,  75)
local C_READY_OFF   = Color3.fromRGB( 30,  60, 120)
local C_READY_DOT   = Color3.fromRGB( 45, 190,  75)
local C_WAITING_DOT = Color3.fromRGB(180,  60,  60)
local C_REROLL      = Color3.fromRGB( 18,  34,  72)
local C_COOLDOWN    = Color3.fromRGB( 40,  40,  70)

-- ── Module state ──────────────────────────────────────────────────────────────
local sg:          ScreenGui
local mapCanvas:   Frame
local playerList:  Frame
local readyBtn:    TextButton
local rerollBtn:   TextButton
local rerollHint:  TextLabel
local statusLbl:   TextLabel

local depositDots: { Frame } = {}
local isReady          = false
local rerollOnCooldown = false

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
local function syncDeposits(positions: { Vector3 })
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

-- ── Build UI ──────────────────────────────────────────────────────────────────
local function buildUI()
	sg               = Instance.new("ScreenGui")
	sg.Name          = "LobbyUI"
	sg.ResetOnSpawn  = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = true
	sg.Parent        = localPlayer.PlayerGui

	-- Full backdrop
	local bg         = Instance.new("Frame")
	bg.Size          = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = C_BG
	bg.BorderSizePixel  = 0
	bg.Parent        = sg

	-- Title
	label(bg, "LUCENT", 40, C_TITLE, Enum.Font.GothamBold,
		UDim2.new(1, 0, 0, 56), UDim2.new(0, 0, 0, 16))

	statusLbl = label(bg, "Waiting for players to ready up...", 14, C_SUBTEXT, Enum.Font.Gotham,
		UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 62))

	-- ── Content row ──────────────────────────────────────────────────────────
	local totalW = PREVIEW_PX + 16 + 300   -- map + gap + panel
	local totalH = PREVIEW_PX + 26
	local content = Instance.new("Frame")
	content.Size             = UDim2.fromOffset(totalW, totalH)
	content.Position         = UDim2.new(0.5, -totalW / 2, 0.5, -totalH / 2 + 18)
	content.BackgroundTransparency = 1
	content.Parent           = bg

	-- ── Map preview ───────────────────────────────────────────────────────────
	local mapLabel = label(content, "MAP PREVIEW", 11, C_BORDER, Enum.Font.GothamBold,
		UDim2.fromOffset(PREVIEW_PX + 4, 22), UDim2.fromOffset(0, 0))

	local mapBorder = Instance.new("Frame")
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
	local panel = Instance.new("Frame")
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
		function(readyList: {{ name: string, ready: boolean }}, positions: { Vector3 })
			syncPlayers(readyList)
			syncDeposits(positions)
		end
	)

	-- ── Ready button ──────────────────────────────────────────────────────────
	readyBtn.MouseButton1Click:Connect(function()
		RemoteHandler.get(Config.REMOTES.LobbyReady):FireServer()
	end)

	-- ── Re-roll button (3-second client-side cooldown) ────────────────────────
	rerollBtn.MouseButton1Click:Connect(function()
		if rerollOnCooldown then return end
		rerollOnCooldown = true
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

	-- ── LobbyStart ────────────────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.LobbyStart).OnClientEvent:Connect(function()
		statusLbl.Text      = "All players ready!  Starting..."
		statusLbl.TextColor3 = C_READY_DOT
		readyBtn.Active     = false
		rerollBtn.Active    = false

		-- Animate overlay fade-out then hand off to game
		task.delay(2.8, function()
			-- Restore camera control to the game
			local cam = workspace.CurrentCamera
			cam.CameraType = Enum.CameraType.Custom

			-- Fade out and destroy
			local info = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local over = sg:FindFirstChildWhichIsA("Frame")
			if over then
				TweenService:Create(over, info, { BackgroundTransparency = 1 }):Play()
			end
			task.delay(0.45, function()
				sg:Destroy()
				onGameStart()
			end)
		end)
	end)
end

return LobbyUI
