--!strict
--[[
    TurretPanel — Radial bubble node-graph for turret upgrades.

    Root node "TURRET" auto-expands to two children when show() is called:
      Flamethrower (-135°)  ·  Rocket Launcher (-45°)

    All upgrade state is shown directly on child nodes.
    All network calls and logic are preserved unchanged.
]]

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local TurretPanel  = {}
local localPlayer  = Players.LocalPlayer
local C            = UILib.C

local FLAME_COLOR   = Color3.fromRGB(230, 90,  15)
local ROCKET_COLOR  = Color3.fromRGB(55,  115, 225)
local CREEPY_COLOR  = Color3.fromRGB(80,  200, 100)
local MUTANT_COLOR  = Color3.fromRGB(140, 30,  210)
local FLAME_COST    = (Config.TURRET_UPGRADE_COST :: any)["Flamethrower"]   or 200
local ROCKET_COST   = (Config.TURRET_UPGRADE_COST :: any)["RocketLauncher"] or 225
local CREEPY_COST   = (Config.TURRET_UPGRADE_COST :: any)["Creepy"]         or 275
local MUTANT_COST   = (Config.TURRET_UPGRADE_COST :: any)["Mutant"]         or 350

-- ── State ─────────────────────────────────────────────────────────────────────
local activeTurretId: string?
local networkRef:     any
local getResources:   (() -> number)?
local hasResearchFn:  ((string) -> boolean)?

-- Info panel refs
local statusLbl: TextLabel?
local infoPanel: Frame?

-- Overlay instances
local overlay: Frame?

local RADIUS   = 155
local ROOT_POS = UDim2.new(0.5, 0, 0.68, 0)

-- ── Radial node refs ──────────────────────────────────────────────────────────
type ChildNode = {
	wrapper:  Frame,
	btn:      TextButton,
	line:     Frame,
	stroke:   UIStroke,
	label:    TextLabel,
	key:      string,
	cost:     number,
	color:    Color3,
	needsRes: boolean,  -- true = requires TurretUpgrades research
	finalPos: UDim2,
	startPos: UDim2,
}
local childNodes: { ChildNode } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getUpgradeState(turretId: string): string?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local model = bf:FindFirstChild(turretId)
	if not model then return nil end
	local uv = model:FindFirstChild("Upgrade") :: StringValue?
	return uv and uv.Value or nil
end

-- ── Expand / collapse ─────────────────────────────────────────────────────────
local EXPAND_TI   = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_TI = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function expandNodes()
	local upgrade = activeTurretId and getUpgradeState(activeTurretId) or nil
	for _, c in childNodes do
		-- Mutant is tier-2: only show when Creepy is active or Mutant already applied
		if c.key == "Mutant" then
			if upgrade ~= "Creepy" and upgrade ~= "Mutant" then
				c.wrapper.Visible = false
				continue
			end
			c.line.Visible = true
		end
		c.wrapper.Visible             = true
		c.wrapper.Position            = c.startPos
		c.btn.BackgroundTransparency  = 1
		c.line.BackgroundTransparency = 1
		TweenService:Create(c.wrapper, EXPAND_TI, { Position = c.finalPos }):Play()
		TweenService:Create(c.btn,     EXPAND_TI, { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(c.line,    EXPAND_TI, { BackgroundTransparency = 0.65 }):Play()
	end
end

local function collapseNodes(then_: (() -> ())?)
	for _, c in childNodes do
		if not c.wrapper.Visible then continue end
		TweenService:Create(c.wrapper, COLLAPSE_TI, { Position = c.startPos }):Play()
		TweenService:Create(c.btn,     COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(c.line,    COLLAPSE_TI, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(COLLAPSE_TI.Time, function()
		for _, c in childNodes do
			c.wrapper.Visible = false
			c.line.Visible    = false
		end
		if then_ then then_() end
	end)
end

-- ── Refresh ───────────────────────────────────────────────────────────────────
local function refresh()
	if not activeTurretId then return end
	local upgrade    = getUpgradeState(activeTurretId)
	local res        = getResources and getResources() or 0
	local hasBase    = hasResearchFn and hasResearchFn("TurretUpgrades") or false

	if statusLbl then
		if not hasBase then
			statusLbl.Text = "Research 'Turret Upgrades' at your Command Center to unlock."
		elseif upgrade then
			statusLbl.Text = upgrade .. " upgrade active.  Other paths are permanently locked."
		else
			statusLbl.Text = "Choose one upgrade path — your choice is permanent."
		end
	end

	for _, c in childNodes do
		-- ── Mutant: tier-2 node, only visible after Creepy is chosen ──────────
		if c.key == "Mutant" then
			local showMutant = upgrade == "Creepy" or upgrade == "Mutant"
			if not showMutant then
				c.wrapper.Visible = false
				continue
			end
			if upgrade == "Mutant" then
				c.btn.BackgroundColor3       = C.GREEN
				c.btn.BackgroundTransparency = 0.15
				c.stroke.Color               = C.GREEN
				c.stroke.Thickness           = 2.5
				c.label.Text                 = "MUTANT\n✓ ACTIVE"
				c.label.TextColor3           = C.GREEN
				c.btn.Active                 = false
			else
				local ok = res >= c.cost
				c.btn.BackgroundColor3       = ok and c.color or C.BG_LOCKED
				c.btn.BackgroundTransparency = ok and 0.35 or 0.45
				c.stroke.Color               = ok and c.color or C.BORDER_LO
				c.stroke.Thickness           = 2
				c.label.Text                 = "MUTANT\n◆ " .. c.cost
				c.label.TextColor3           = ok and C.TEXT or C.DIM
				c.btn.Active                 = ok
			end
			continue
		end

		-- ── Normal tier-1 nodes ───────────────────────────────────────────────
		local nodeResearch = (not c.needsRes)
			or (hasResearchFn ~= nil and hasResearchFn("TurretUpgrades"))

		if upgrade == c.key then
			c.btn.BackgroundColor3       = C.GREEN
			c.btn.BackgroundTransparency = 0.15
			c.stroke.Color               = C.GREEN
			c.stroke.Thickness           = 2.5
			c.label.Text                 = c.key .. "\n✓ ACTIVE"
			c.label.TextColor3           = C.GREEN
			c.btn.Active                 = false

		elseif upgrade ~= nil then
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.35
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.key .. "\nLOCKED"
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false

		elseif not nodeResearch then
			c.btn.BackgroundColor3       = C.BG_LOCKED
			c.btn.BackgroundTransparency = 0.35
			c.stroke.Color               = C.BORDER_LO
			c.stroke.Thickness           = 1.5
			c.label.Text                 = c.key .. "\nNeeds Research"
			c.label.TextColor3           = C.DIM
			c.btn.Active                 = false

		else
			local ok = res >= c.cost
			c.btn.BackgroundColor3       = ok and c.color or C.BG_LOCKED
			c.btn.BackgroundTransparency = ok and 0.35 or 0.45
			c.stroke.Color               = ok and c.color or C.BORDER_LO
			c.stroke.Thickness           = 2
			c.label.Text                 = c.key .. "\n◆ " .. c.cost
			c.label.TextColor3           = ok and C.TEXT or C.DIM
			c.btn.Active                 = ok
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function TurretPanel.init(network, getResourcesFn, hasResearchFn_)
	networkRef    = network
	getResources  = getResourcesFn
	hasResearchFn = hasResearchFn_

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- Full-screen transparent overlay
	local ov                         = Instance.new("Frame")
	ov.Name                          = "TurretOverlay"
	ov.Size                          = UDim2.new(1, 0, 1, 0)
	ov.BackgroundTransparency        = 1
	ov.BorderSizePixel               = 0
	ov.ZIndex                        = 10
	ov.Visible                       = false
	ov.Parent                        = sg
	overlay = ov

	-- Root "TURRET" node
	local _rootWrapper, rBtn = UILib.radialNode(ov, "TURRET", "⚙", C.TURRET, ROOT_POS, 70, 11)
	rBtn.MouseButton1Click:Connect(function()
		TurretPanel.hide()
	end)

	-- Creepy node final position (Mutant chained above it at same angle, larger radius)
	local RADIUS2      = 260
	local CREEPY_RAD   = math.rad(-90)
	local CREEPY_FINAL = UDim2.new(
		ROOT_POS.X.Scale, ROOT_POS.X.Offset + math.cos(CREEPY_RAD) * RADIUS,
		ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + math.sin(CREEPY_RAD) * RADIUS
	)

	-- Child nodes  (Mutant is tier-2: chains from Creepy's position)
	local UPGRADES = {
		{ key = "Flamethrower",   icon = "◈", color = FLAME_COLOR,  cost = FLAME_COST,  angle = -135, needsRes = true,  tier2 = false },
		{ key = "Creepy",         icon = "⊛", color = CREEPY_COLOR, cost = CREEPY_COST, angle = -90,  needsRes = false, tier2 = false },
		{ key = "RocketLauncher", icon = "⊕", color = ROCKET_COLOR, cost = ROCKET_COST, angle = -45,  needsRes = true,  tier2 = false },
		{ key = "Mutant",         icon = "◉", color = MUTANT_COLOR, cost = MUTANT_COST, angle = -90,  needsRes = false, tier2 = true  },
	}

	for _, def in UPGRADES do
		local rad      = math.rad(def.angle)
		local radius   = if def.tier2 then RADIUS2 else RADIUS
		local origin   = if def.tier2 then CREEPY_FINAL else ROOT_POS
		local lineLen  = if def.tier2 then RADIUS2 - RADIUS else RADIUS
		local startPos = if def.tier2 then CREEPY_FINAL else ROOT_POS

		local dx = math.cos(rad) * radius
		local dy = math.sin(rad) * radius
		local finalPos = UDim2.new(ROOT_POS.X.Scale, ROOT_POS.X.Offset + dx, ROOT_POS.Y.Scale, ROOT_POS.Y.Offset + dy)

		local line         = UILib.connectorLine(ov, origin, def.angle, lineLen, 10)
		local wrapper, btn = UILib.radialNode(ov, def.key, def.icon, def.color, startPos, 70, 11)
		wrapper.Visible    = false
		if def.tier2 then
			line.Visible = false  -- hidden until Creepy is chosen
		end

		local stroke = btn:FindFirstChildWhichIsA("UIStroke") :: UIStroke
		local label  = wrapper:FindFirstChild("NodeLabel")    :: TextLabel

		local key  = def.key
		local cost = def.cost
		btn.MouseButton1Click:Connect(function()
			if not activeTurretId or not btn.Active then return end
			networkRef.upgradeTurret(activeTurretId, key)
			task.delay(0.35, refresh)
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
			needsRes = def.needsRes,
			finalPos = finalPos,
			startPos = startPos,
		})
	end

	-- ── Info panel (bottom-centre) ─────────────────────────────────────────────
	local dp                         = Instance.new("Frame")
	dp.Name                          = "TurretInfo"
	dp.Size                          = UDim2.fromOffset(370, 56)
	dp.Position                      = UDim2.new(0.5, -185, 1, -86)
	dp.BackgroundColor3              = Color3.fromRGB(8, 11, 22)
	dp.BackgroundTransparency        = 0.05
	dp.BorderSizePixel               = 0
	dp.ZIndex                        = 20
	dp.Visible                       = false
	dp.Parent                        = sg
	UILib.corner(dp, 10)
	UILib.stroke(dp, C.BORDER, 1.5)
	infoPanel = dp

	local acc                        = Instance.new("Frame")
	acc.Size                         = UDim2.new(1, -16, 0, 2)
	acc.Position                     = UDim2.fromOffset(8, 4)
	acc.BackgroundColor3             = C.TURRET
	acc.BackgroundTransparency       = 0.35
	acc.BorderSizePixel              = 0
	acc.ZIndex                       = 21
	acc.Parent                       = dp

	local sLbl = UILib.lbl(dp, "",
		UDim2.fromOffset(350, 38), UDim2.fromOffset(10, 10),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 21 })
	sLbl.Name = "StatusLabel"
	statusLbl = sLbl
end

-- ── Public API ────────────────────────────────────────────────────────────────

function TurretPanel.show(turretId: string)
	activeTurretId = turretId
	if overlay   then overlay.Visible   = true end
	if infoPanel then infoPanel.Visible = true end
	refresh()
	expandNodes()

	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(turretId, 10)
		if not model then return end
		model.ChildAdded:Connect(function(child)
			if child.Name == "Upgrade" and activeTurretId == turretId then refresh() end
		end)
	end)
end

function TurretPanel.hide()
	activeTurretId = nil
	if infoPanel then infoPanel.Visible = false end
	collapseNodes(function()
		if overlay then overlay.Visible = false end
	end)
end

function TurretPanel.refreshIfVisible()
	if overlay and (overlay :: Frame).Visible then refresh() end
end

return TurretPanel
