--!strict
--[[
    BlobPanel — Radial evolution nodes anchored to the blob's screen position.

    Uses its own ScreenGui with IgnoreGuiInset = true so that WorldToViewportPoint
    coordinates map 1:1 — no UIScale or inset correction needed.

    While constructing: shows a small progress bar above the blob.
    When ready: fans Mine / Barracks / Turret radial nodes outward from the blob.
    RenderStepped re-projects every frame so nodes track camera movement.
]]

local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local Network           = require(script.Parent:WaitForChild("Network"))

local BlobPanel = {}
local C         = UILib.C

-- ── Evolution options ─────────────────────────────────────────────────────────
local EVOLVE_OPTS = {
	{ type = "Mine",     icon = "⛏", color = C.MINE,     cost = Config.MINE_COST     },
	{ type = "Barracks", icon = "⚔", color = C.BARRACKS, cost = Config.BUILDING_COST },
	{ type = "Turret",   icon = "⚙", color = C.TURRET,   cost = Config.TURRET_COST   },
}

-- ── Radial layout ─────────────────────────────────────────────────────────────
local NODE_ANGLES = { -150, -90, -30 }  -- fan upward: left / top / right
local NODE_RADIUS = 130
local NODE_DIAM   = 80

-- ── Module state ──────────────────────────────────────────────────────────────
local blobSg:         ScreenGui?              = nil  -- dedicated ScreenGui (IgnoreGuiInset=true)
local overlay:        Frame?                  = nil
local nodeWrappers:   { Frame }               = {}
local connLines:      { Frame }               = {}
local progressComp:   Frame?                  = nil
local progressFill:   Frame?                  = nil
local progressLbl:    TextLabel?              = nil

local currentBlobId:  string?                 = nil
local readyConn:      RBXScriptConnection?    = nil
local renderConn:     RBXScriptConnection?    = nil
local isEvolveMode:   boolean                 = false

-- ── Blob helpers ──────────────────────────────────────────────────────────────
local function getBlob(): Model?
	local f = workspace:FindFirstChild("Buildings") :: Folder?
	if not f or not currentBlobId then return nil end
	return f:FindFirstChild(currentBlobId) :: Model?
end

-- Returns screen position and whether it is on-screen.
-- Uses WorldToViewportPoint; blobSg has IgnoreGuiInset=true so coords are 1:1.
local function getBlobScreenPos(): (Vector2, boolean)
	local m = getBlob()
	if not m then return Vector2.zero, false end
	local base = m:FindFirstChild("Base") :: BasePart?
	if not base then return Vector2.zero, false end
	local cam = workspace.CurrentCamera
	local sv, onScreen = cam:WorldToViewportPoint(base.Position + Vector3.new(0, 5, 0))
	return Vector2.new(sv.X, sv.Y), onScreen and sv.Z > 0
end

local function isBlobReady(): boolean
	local m = getBlob()
	if not m then return false end
	local rv = m:FindFirstChild("IsReady") :: BoolValue?
	return rv ~= nil and rv.Value == true
end

local function getBlobProgress(): number
	local m = getBlob()
	if not m then return 0 end
	local base = m:FindFirstChild("Base") :: BasePart?
	if not base then return 0 end
	local bb   = base:FindFirstChild("HealthBar") :: BillboardGui?
	if not bb  then return 1 end
	local bg   = bb:FindFirstChildWhichIsA("Frame")
	local fill = bg and bg:FindFirstChild("Fill") :: Frame?
	if not fill then return 1 end
	return fill.Size.X.Scale
end

-- ── Overlay management ────────────────────────────────────────────────────────
local function clearOverlay()
	if renderConn then renderConn:Disconnect(); renderConn = nil end
	nodeWrappers  = {}
	connLines     = {}
	progressComp  = nil
	progressFill  = nil
	progressLbl   = nil
	isEvolveMode  = false
	if overlay then overlay:Destroy(); overlay = nil end
end

-- ── Geometry helpers ──────────────────────────────────────────────────────────
local function calcNodePos(screenPos: Vector2, angleDeg: number): UDim2
	local rad = math.rad(angleDeg)
	return UDim2.fromOffset(
		screenPos.X + math.cos(rad) * NODE_RADIUS,
		screenPos.Y + math.sin(rad) * NODE_RADIUS
	)
end

-- Recompute a connector line in-place so it stretches from blobPos to nodePos.
local CIRC_OFF = 20  -- circle centre sits CIRC_OFF px above wrapper centre
local function repositionLine(line: Frame, blobPos: Vector2, nPos: UDim2)
	local ax = blobPos.X;     local ay = blobPos.Y    - CIRC_OFF
	local bx = nPos.X.Offset; local by = nPos.Y.Offset - CIRC_OFF
	local dx = bx - ax;       local dy = by - ay
	local len   = math.sqrt(dx * dx + dy * dy)
	local midX  = (ax + bx) * 0.5
	local midY  = (ay + by) * 0.5
	line.Size     = UDim2.fromOffset(len, 2)
	line.Position = UDim2.fromOffset(midX, midY)
	line.Rotation = math.deg(math.atan2(dy, dx))
end

-- ── Build constructing progress bar ──────────────────────────────────────────
local function buildConstructIndicator(ov: Frame, screenPos: Vector2)
	local W, H = 140, 36
	local pc                   = Instance.new("Frame")
	pc.Name                    = "ProgressComp"
	pc.Size                    = UDim2.fromOffset(W, H)
	pc.Position                = UDim2.fromOffset(screenPos.X - W / 2, screenPos.Y - H - 14)
	pc.BackgroundColor3        = Color3.fromRGB(7, 10, 20)
	pc.BackgroundTransparency  = 0.1
	pc.BorderSizePixel         = 0
	pc.ZIndex                  = 30
	pc.Parent                  = ov
	UILib.corner(pc, 6)
	UILib.stroke(pc, C.TEAL, 1.5)
	progressComp = pc

	local lbl                  = Instance.new("TextLabel")
	lbl.Size                   = UDim2.new(1, 0, 0, 16)
	lbl.Position               = UDim2.fromOffset(0, 4)
	lbl.BackgroundTransparency = 1
	lbl.Text                   = "Constructing…"
	lbl.TextSize               = 11
	lbl.Font                   = Enum.Font.Gotham
	lbl.TextColor3             = C.SUBTEXT
	lbl.TextXAlignment         = Enum.TextXAlignment.Center
	lbl.ZIndex                 = 31
	lbl.Parent                 = pc

	local track                = Instance.new("Frame")
	track.Size                 = UDim2.new(1, -16, 0, 10)
	track.Position             = UDim2.fromOffset(8, 22)
	track.BackgroundColor3     = Color3.fromRGB(20, 30, 50)
	track.BorderSizePixel      = 0
	track.ZIndex               = 31
	track.Parent               = pc
	UILib.corner(track, 3)

	local pf                   = Instance.new("Frame")
	pf.Size                    = UDim2.new(0, 0, 1, 0)
	pf.BackgroundColor3        = C.TEAL
	pf.BorderSizePixel         = 0
	pf.ZIndex                  = 32
	pf.Parent                  = track
	UILib.corner(pf, 3)
	progressFill = pf

	local pLbl                 = Instance.new("TextLabel")
	pLbl.Size                  = UDim2.fromOffset(36, 16)
	pLbl.Position              = UDim2.new(1, -36, 0, 22)
	pLbl.BackgroundTransparency = 1
	pLbl.Text                  = "0%"
	pLbl.TextSize              = 11
	pLbl.Font                  = Enum.Font.GothamBold
	pLbl.TextColor3            = C.SUBTEXT
	pLbl.TextXAlignment        = Enum.TextXAlignment.Right
	pLbl.ZIndex                = 31
	pLbl.Parent                = pc
	progressLbl = pLbl
end

-- ── Build evolution nodes ─────────────────────────────────────────────────────
local function buildEvolveNodes(ov: Frame, screenPos: Vector2)
	local EASE = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	for i, opt in ipairs(EVOLVE_OPTS) do
		local np = calcNodePos(screenPos, NODE_ANGLES[i])

		-- Connector line from blob centre to node
		local blobUDim = UDim2.fromOffset(screenPos.X, screenPos.Y)
		local line     = UILib.connectorLineBetween(ov, blobUDim, np, 11)
		table.insert(connLines, line)
		TweenService:Create(line, TweenInfo.new(0.15), { BackgroundTransparency = 0.4 }):Play()

		-- Node circle pops open from size 0
		local wrapper, btn = UILib.radialNode(
			ov,
			opt.type:upper() .. "\n◆ " .. opt.cost,
			opt.icon, opt.color, np, NODE_DIAM, 12
		)
		wrapper.Size = UDim2.fromOffset(0, 0)
		table.insert(nodeWrappers, wrapper)
		TweenService:Create(wrapper, EASE, {
			Size = UDim2.fromOffset(NODE_DIAM, NODE_DIAM + 48)
		}):Play()

		local captOpt = opt
		btn.MouseButton1Click:Connect(function()
			if not currentBlobId then return end
			local id = currentBlobId
			Network.evolveBlob(id, captOpt.type)
			BlobPanel.hide()
		end)
	end
end

-- ── Constructing → ready transition ──────────────────────────────────────────
local function onBlobReady()
	if isEvolveMode or not overlay then return end
	isEvolveMode = true
	if progressComp then progressComp:Destroy(); progressComp = nil end
	progressFill = nil
	progressLbl  = nil
	local sp, _ = getBlobScreenPos()
	buildEvolveNodes(overlay, sp)
end

-- ── RenderStepped: track blob → update all elements ──────────────────────────
local function startTracking()
	if renderConn then renderConn:Disconnect() end
	renderConn = RunService.RenderStepped:Connect(function()
		if not currentBlobId then return end
		local screenPos, visible = getBlobScreenPos()

		-- Move progress indicator with blob
		if progressComp then
			local W, H = 140, 36
			progressComp.Visible  = visible
			progressComp.Position = UDim2.fromOffset(screenPos.X - W / 2, screenPos.Y - H - 14)
			local prog = getBlobProgress()
			if progressFill then progressFill.Size = UDim2.new(prog, 0, 1, 0) end
			if progressLbl  then progressLbl.Text  = math.floor(prog * 100) .. "%" end
		end

		-- Reposition nodes and recompute connector lines
		for i, wrapper in ipairs(nodeWrappers) do
			local np       = calcNodePos(screenPos, NODE_ANGLES[i])
			wrapper.Position = np
			wrapper.Visible  = visible
			local line = connLines[i]
			if line then
				repositionLine(line, screenPos, np)
				line.Visible = visible
			end
		end
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function BlobPanel.init()
	-- Dedicated ScreenGui with IgnoreGuiInset so WorldToViewportPoint coords
	-- map 1:1 without any UIScale or inset correction.
	local sg                    = Instance.new("ScreenGui")
	sg.Name                     = "BlobPanelGui"
	sg.IgnoreGuiInset           = true
	sg.ResetOnSpawn             = false
	sg.ZIndexBehavior           = Enum.ZIndexBehavior.Sibling
	sg.Parent                   = Players.LocalPlayer.PlayerGui
	blobSg = sg
end

-- ── Public API ────────────────────────────────────────────────────────────────
function BlobPanel.show(blobId: string)
	if currentBlobId == blobId then return end
	BlobPanel.hide()
	currentBlobId = blobId

	if not blobSg then return end

	local ov                   = Instance.new("Frame")
	ov.Name                    = "BlobOverlay"
	ov.Size                    = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency  = 1
	ov.BorderSizePixel         = 0
	ov.ZIndex                  = 28
	ov.Parent                  = blobSg
	overlay = ov

	local screenPos, _ = getBlobScreenPos()

	if isBlobReady() then
		isEvolveMode = true
		buildEvolveNodes(ov, screenPos)
	else
		buildConstructIndicator(ov, screenPos)

		local m = getBlob()
		if m then
			local rv = m:FindFirstChild("IsReady") :: BoolValue?
			if rv then
				readyConn = rv.Changed:Connect(function(val)
					if val and currentBlobId == blobId then
						onBlobReady()
					end
				end)
			end
		end
	end

	startTracking()
end

function BlobPanel.hide()
	if readyConn then readyConn:Disconnect(); readyConn = nil end
	currentBlobId = nil
	clearOverlay()
end

return BlobPanel
