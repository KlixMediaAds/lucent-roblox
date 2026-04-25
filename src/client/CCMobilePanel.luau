--!strict
--[[
    CCMobilePanel — Radial panel for Command Center mobility upgrade.

    Shown when the player clicks their own CC.  One child node at -90°
    cycles through four states depending on research + unlock + mobile status:
      Needs Research  →  Unlock ◆200  →  Mobilize  →  Deploy
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local CCMobilePanel = {}
local localPlayer   = Players.LocalPlayer
local C             = UILib.C

-- ── Colors ─────────────────────────────────────────────────────────────────────
local UNLOCK_COLOR  = Color3.fromRGB(110, 55, 210)
local MOBILIZE_COL  = Color3.fromRGB(20,  200, 160)
local DEPLOY_COL    = Color3.fromRGB(225, 130, 20)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeCCId:  string? = nil
local networkRef:  any
local getResources: (() -> number)?
local hasResearchFn: ((string) -> boolean)?

local ccIsUnlocked = false
local ccIsMobile   = false

-- ── UI refs ────────────────────────────────────────────────────────────────────
local overlay: Frame?

type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	stroke:   UIStroke,
	label:    TextLabel,
	finalPos: UDim2,
	startPos: UDim2,
}
local childNode: ChildNode?

local RADIUS   = 130
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)
local CC_COLOR = Color3.fromRGB(55, 130, 225)

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNode()
	local c = childNode
	if not c then return end
	c.wrapper.Visible             = true
	c.wrapper.Position            = c.startPos
	c.btn.BackgroundTransparency  = 1
	c.line.BackgroundTransparency = 1
	TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
	TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
	TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
end

local function collapseNode(then_: (() -> ())?)
	local c = childNode
	if not c then if then_ then then_() end; return end
	TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
	TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	task.delay(COLLAPSE_TI.Time, function()
		c.wrapper.Visible = false
		if then_ then then_() end
	end)
end

-- ── Refresh node appearance ────────────────────────────────────────────────────
local function refresh()
	local c = childNode
	if not c then return end

	local researched = hasResearchFn and hasResearchFn("MobileCC") or false
	local res        = getResources and getResources() or 0

	if not researched then
		c.btn.BackgroundColor3       = C.BG_LOCKED
		c.btn.BackgroundTransparency = 0.35
		c.stroke.Color               = C.BORDER_LO
		c.stroke.Thickness           = 1.5
		c.label.Text                 = "Mobility\nNeeds Research"
		c.label.TextColor3           = C.DIM
		c.btn.Active                 = false

	elseif not ccIsUnlocked then
		local canAfford = res >= Config.MOBILE_CC_COST
		c.btn.BackgroundColor3       = canAfford and UNLOCK_COLOR or C.BG_LOCKED
		c.btn.BackgroundTransparency = canAfford and 0.35 or 0.45
		c.stroke.Color               = canAfford and UNLOCK_COLOR or C.BORDER_LO
		c.stroke.Thickness           = canAfford and 2 or 1.5
		c.label.Text                 = "Mobility\n◆ " .. Config.MOBILE_CC_COST
		c.label.TextColor3           = canAfford and C.TEXT or C.DIM
		c.btn.Active                 = canAfford

	elseif ccIsMobile then
		c.btn.BackgroundColor3       = DEPLOY_COL
		c.btn.BackgroundTransparency = 0.35
		c.stroke.Color               = DEPLOY_COL
		c.stroke.Thickness           = 2
		c.label.Text                 = "Deploy\n⬛"
		c.label.TextColor3           = C.TEXT
		c.btn.Active                 = true

	else
		c.btn.BackgroundColor3       = MOBILIZE_COL
		c.btn.BackgroundTransparency = 0.35
		c.stroke.Color               = MOBILIZE_COL
		c.stroke.Thickness           = 2
		c.label.Text                 = "Mobilize\n▶"
		c.label.TextColor3           = C.TEXT
		c.btn.Active                 = true
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function CCMobilePanel.init(network: any, getResourcesFn: () -> number, hasResearch: (string) -> boolean)
	networkRef    = network
	getResources  = getResourcesFn
	hasResearchFn = hasResearch

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local ov                      = Instance.new("Frame")
	ov.Name                       = "CCMobileOverlay"
	ov.Size                       = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency     = 1
	ov.BorderSizePixel            = 0
	ov.ZIndex                     = 10
	ov.Visible                    = false
	ov.Parent                     = sg
	overlay = ov

	-- Root node
	local _, rBtn = UILib.radialNode(ov, "MECH CC", "🦾", CC_COLOR, ROOT_POS, 70, 11)
	rBtn.MouseButton1Click:Connect(function()
		CCMobilePanel.hide()
	end)

	-- Single child at -90° (directly above root in screen space)
	local angle = -90
	local rad   = math.rad(angle)
	local dx    = math.cos(rad) * RADIUS
	local dy    = math.sin(rad) * RADIUS
	local final = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx,
	                         ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

	local line         = UILib.connectorLine(ov, ROOT_POS, angle, RADIUS, 10)
	local wrapper, btn = UILib.radialNode(ov, "Mobility\nNeeds Research", "🦾", C.BG_LOCKED, ROOT_POS, 70, 11)
	wrapper.Visible    = false

	local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
	local label  = wrapper:FindFirstChild("NodeLabel") :: TextLabel

	btn.MouseButton1Click:Connect(function()
		if not activeCCId or not btn.Active then return end
		networkRef.mobilizeCC(activeCCId)
	end)

	childNode = {
		wrapper  = wrapper,
		btn      = btn,
		line     = line,
		stroke   = stroke,
		label    = label,
		finalPos = final,
		startPos = ROOT_POS,
	}
end

-- ── Public API ────────────────────────────────────────────────────────────────

function CCMobilePanel.show(ccId: string)
	activeCCId = ccId
	if overlay then overlay.Visible = true end
	refresh()
	expandNode()
end

function CCMobilePanel.hide()
	activeCCId = nil
	collapseNode(function()
		if overlay then overlay.Visible = false end
	end)
end

function CCMobilePanel.setMobileState(isUnlocked: boolean, isMobile: boolean)
	ccIsUnlocked = isUnlocked
	ccIsMobile   = isMobile
	if overlay and (overlay :: Frame).Visible then
		refresh()
	end
end

function CCMobilePanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

function CCMobilePanel.isVisible(): boolean
	return overlay ~= nil and (overlay :: Frame).Visible
end

return CCMobilePanel
