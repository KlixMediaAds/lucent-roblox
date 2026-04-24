--!strict
--[[
    BlobPanel — Radial panel for the Creepy Blob building.
    Three evolutions: CreepySoldier (cooldown-gated, repeatable),
    CreepyWorm (one-shot, consumes blob), CreepyTurret (one-shot, consumes blob).
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local BlobPanel   = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

-- ── State ─────────────────────────────────────────────────────────────────────
local activeBlobId:  string? = nil
local networkRef:    any
local getResources:  (() -> number)?

local rootLbl:  TextLabel?
local overlay:  Frame?

local soldierCooldownExpiry: number = 0   -- os.clock() when soldier becomes ready again

-- ── Product definitions ───────────────────────────────────────────────────────
local SOLDIER_COLOR = Color3.fromRGB(50,  170,  80)
local WORM_COLOR    = Color3.fromRGB(130,  85,  30)
local TURRET_COLOR  = Color3.fromRGB(140,  40, 210)

type ProdDef = { key: string, label: string, icon: string, color: Color3, cost: number, angle: number }

local PROD_DEFS: { ProdDef } = {
	{ key = "CreepySoldier", label = "Soldier", icon = "🪲", color = SOLDIER_COLOR, cost = Config.BLOB_SOLDIER_COST, angle = -150 },
	{ key = "CreepyWorm",    label = "Worm",    icon = "🪱", color = WORM_COLOR,    cost = Config.BLOB_WORM_COST,    angle = -90  },
	{ key = "CreepyTurret",  label = "Turret",  icon = "⊛", color = TURRET_COLOR,  cost = Config.BLOB_TURRET_COST,  angle = -30  },
}

local RADIUS   = 155
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)
local BLOB_COL = Color3.fromRGB(100, 40, 180)

-- ── Node refs ─────────────────────────────────────────────────────────────────
type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	stroke:   UIStroke,
	label:    TextLabel,
	key:      string,
	cost:     number,
	color:    Color3,
	finalPos: UDim2,
}
local childNodes: { ChildNode } = {}

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNodes()
	for _, c in childNodes do
		c.wrapper.Visible             = true
		c.wrapper.Position            = ROOT_POS
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
	end
end

local function collapseNodes(then_: (() -> ())?)
	for _, c in childNodes do
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = ROOT_POS }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in childNodes do c.wrapper.Visible = false end
		if then_ then then_() end
	end)
end

-- ── Refresh node visuals ──────────────────────────────────────────────────────
local function refresh()
	local res = getResources and getResources() or 0
	local now = os.clock()

	for _, c in childNodes do
		local onCooldown = c.key == "CreepySoldier" and soldierCooldownExpiry > now
		local canAfford  = res >= c.cost

		if onCooldown then
			local remaining = math.max(1, math.ceil(soldierCooldownExpiry - now))
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.4
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.label.Text:gsub("\n.*", "") .. "\n⏳ " .. remaining .. "s"
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false
		elseif not canAfford then
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.4
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.label.Text:gsub("\n.*", "") .. "\n◆ " .. c.cost
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false
		else
			c.btn.BackgroundColor3       = c.color
			c.btn.BackgroundTransparency = 0.35
			c.stroke.Color               = c.color
			c.stroke.Thickness           = 2
			c.label.Text                 = c.label.Text:gsub("\n.*", "") .. "\n◆ " .. c.cost
			c.label.TextColor3           = C.TEXT
			c.btn.Active                 = true
		end
	end
end

-- Heartbeat refresh loop (runs while panel is open for cooldown countdown)
local refreshConn: RBXScriptConnection?
local function startRefreshLoop()
	if refreshConn then refreshConn:Disconnect() end
	refreshConn = RunService.Heartbeat:Connect(function()
		if not (overlay and (overlay :: Frame).Visible) then
			if refreshConn then refreshConn:Disconnect(); refreshConn = nil end
			return
		end
		-- Only re-render every ~0.2 s to avoid spamming text updates
		refresh()
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function BlobPanel.init(network: any, getResourcesFn: () -> number, _hasResearch: any)
	networkRef   = network
	getResources = getResourcesFn

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local ov                      = Instance.new("Frame")
	ov.Name                       = "BlobOverlay"
	ov.Size                       = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency     = 1
	ov.BorderSizePixel            = 0
	ov.ZIndex                     = 10
	ov.Visible                    = false
	ov.Parent                     = sg
	overlay = ov

	local rootWrapper, rBtn = UILib.radialNode(ov, "BLOB", "🫧", BLOB_COL, ROOT_POS, 70, 11)
	rootLbl = rootWrapper:FindFirstChild("NodeLabel") :: TextLabel?
	rBtn.MouseButton1Click:Connect(function()
		BlobPanel.hide()
	end)

	for _, def in PROD_DEFS do
		local rad      = math.rad(def.angle)
		local dx       = math.cos(rad) * RADIUS
		local dy       = math.sin(rad) * RADIUS
		local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx, ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

		local line         = UILib.connectorLine(ov, ROOT_POS, def.angle, RADIUS, 10)
		local wrapper, btn = UILib.radialNode(ov, def.label .. "\n◆ " .. def.cost, def.icon, def.color, ROOT_POS, 70, 11)
		wrapper.Visible    = false

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel") :: TextLabel

		local key  = def.key
		local cost = def.cost
		btn.MouseButton1Click:Connect(function()
			if not activeBlobId or not btn.Active then return end
			networkRef.blobProduce(activeBlobId, key)
			if key == "CreepySoldier" then
				soldierCooldownExpiry = os.clock() + Config.BLOB_SOLDIER_COOLDOWN
				refresh()
			end
		end)

		table.insert(childNodes, {
			wrapper  = wrapper,
			btn      = btn,
			line     = line,
			stroke   = stroke,
			label    = label,
			key      = key,
			cost     = cost,
			color    = def.color,
			finalPos = finalPos,
		})
	end

	-- Server confirms cooldown state (authoritative)
	network.onBlobUpdate(function(blobId: string, cooldownRemaining: number)
		if blobId ~= activeBlobId then return end
		soldierCooldownExpiry = cooldownRemaining > 0 and (os.clock() + cooldownRemaining) or 0
		refresh()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────
function BlobPanel.show(blobId: string)
	activeBlobId          = blobId
	soldierCooldownExpiry = 0
	if overlay then overlay.Visible = true end
	refresh()
	expandNodes()
	startRefreshLoop()

	-- Auto-close if the blob is destroyed (worm/turret evolution or killed)
	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(blobId, 10)
		if not model then return end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base then return end
		local conn: RBXScriptConnection
		conn = base.Destroying:Connect(function()
			conn:Disconnect()
			if activeBlobId == blobId then
				BlobPanel.hide()
			end
		end)
	end)
end

function BlobPanel.hide()
	activeBlobId = nil
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function BlobPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

return BlobPanel
