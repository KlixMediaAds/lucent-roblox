local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local TurretPanel  = {}
local localPlayer  = Players.LocalPlayer
local C            = UILib.C

local FLAME_COLOR  = Color3.fromRGB(230, 90, 15)
local ROCKET_COLOR = Color3.fromRGB(55, 115, 225)

local FLAME_COST   = (Config.TURRET_UPGRADE_COST :: any)["Flamethrower"]  or 200
local ROCKET_COST  = (Config.TURRET_UPGRADE_COST :: any)["RocketLauncher"] or 225

local panel:          Frame?
local activeTurretId: string?
local networkRef:     any
local getResources:   (() -> number)?
local hasResearchFn:  ((string) -> boolean)?

local flameBtn:  TextButton?
local rocketBtn: TextButton?
local statusLbl: TextLabel?

-- ── Upgrade card builder ──────────────────────────────────────────────────────

local function makeUpgradeCard(
	parent: Instance,
	name:   string,
	desc:   string,
	cost:   string,
	color:  Color3,
	zi:     number
): TextButton
	local btn                  = Instance.new("TextButton")
	btn.Size                   = UDim2.fromOffset(171, 78)
	btn.BackgroundColor3       = color
	btn.BackgroundTransparency = 0.14
	btn.Text                   = ""
	btn.AutoButtonColor        = true
	btn.BorderSizePixel        = 0
	btn.ZIndex                 = zi
	btn.Parent                 = parent
	UILib.corner(btn, 9)
	UILib.stroke(btn, C.BORDER, 1)

	local bar                  = Instance.new("Frame")
	bar.Size                   = UDim2.new(1, -2, 0, 4)
	bar.Position               = UDim2.fromOffset(1, 1)
	bar.BackgroundColor3       = color
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = zi + 1
	bar.Parent                 = btn
	UILib.corner(bar, 6)

	UILib.lbl(btn, name:upper(),
		UDim2.fromOffset(151, 20), UDim2.fromOffset(10, 10),
		{ bold = true, size = 13, color = C.TEXT, zIndex = zi + 1 })

	UILib.lbl(btn, desc,
		UDim2.fromOffset(151, 16), UDim2.fromOffset(10, 32),
		{ size = 11, color = C.SUBTEXT, zIndex = zi + 1 })

	UILib.lbl(btn, cost,
		UDim2.fromOffset(151, 16), UDim2.fromOffset(10, 52),
		{ size = 11, color = C.GOLD, zIndex = zi + 1 })

	return btn
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getUpgradeState(turretId: string): string?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local model = bf:FindFirstChild(turretId)
	if not model then return nil end
	local uv = model:FindFirstChild("Upgrade") :: StringValue?
	return uv and uv.Value or nil
end

local function setCardState(
	btn:       TextButton?,
	upgrade:   string?,      -- current active upgrade (or nil)
	thisKey:   string,       -- "Flamethrower" or "RocketLauncher"
	cardColor: Color3,
	costAmt:   number,
	res:       number,
	hasResearch: boolean
)
	if not btn then return end

	local labels: { TextLabel } = {}
	for _, ch in btn:GetChildren() do
		if ch:IsA("TextLabel") then table.insert(labels, ch) end
	end
	local nameLbl = labels[1]
	local descLbl = labels[2]
	local costLbl = labels[3]

	if upgrade == thisKey then
		btn.BackgroundColor3       = C.GREEN
		btn.BackgroundTransparency = 0.08
		btn.Active                 = false
		if costLbl then costLbl.Text = "✓  ACTIVE"; costLbl.TextColor3 = C.GREEN end

	elseif upgrade ~= nil then
		-- Different upgrade is active — lock this one out
		btn.BackgroundColor3       = C.BG_LOCKED
		btn.BackgroundTransparency = 0
		btn.Active                 = false
		if nameLbl then nameLbl.TextColor3 = C.DIM end
		if descLbl then descLbl.TextColor3 = C.DIM end
		if costLbl then costLbl.Text = "LOCKED"; costLbl.TextColor3 = C.DIM end

	elseif not hasResearch then
		btn.BackgroundColor3       = C.BG_LOCKED
		btn.BackgroundTransparency = 0
		btn.Active                 = false
		if nameLbl then nameLbl.TextColor3 = C.DIM end
		if descLbl then descLbl.TextColor3 = C.DIM end
		if costLbl then costLbl.Text = "Needs: Turret Upgrades"; costLbl.TextColor3 = C.DIM end

	else
		local ok = res >= costAmt
		btn.BackgroundColor3       = ok and cardColor or C.BG_LOCKED
		btn.BackgroundTransparency = ok and 0.14 or 0
		btn.Active                 = ok
		if nameLbl then nameLbl.TextColor3 = ok and C.TEXT or C.DIM end
		if descLbl then descLbl.TextColor3 = C.SUBTEXT end
		if costLbl then
			costLbl.Text       = ok and ("◆ " .. costAmt .. " res") or ("◆ " .. costAmt .. " res  (need more)")
			costLbl.TextColor3 = ok and C.GOLD or C.DIM
		end
	end
end

-- ── Refresh ───────────────────────────────────────────────────────────────────

local function refresh()
	if not activeTurretId then return end
	local upgrade     = getUpgradeState(activeTurretId)
	local res         = getResources and getResources() or 0
	local hasResearch = hasResearchFn and hasResearchFn("TurretUpgrades") or false

	setCardState(flameBtn,  upgrade, "Flamethrower",   FLAME_COLOR,  FLAME_COST,  res, hasResearch)
	setCardState(rocketBtn, upgrade, "RocketLauncher",  ROCKET_COLOR, ROCKET_COST, res, hasResearch)

	if statusLbl then
		if not hasResearch then
			statusLbl.Text = "Research 'Turret Upgrades' at your Command Center to unlock."
		elseif upgrade then
			statusLbl.Text = upgrade .. " upgrade active.  The other path is permanently locked."
		else
			statusLbl.Text = "Choose one upgrade — your choice is permanent."
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function TurretPanel.init(network, getResourcesFn, hasResearchFn_)
	networkRef    = network
	getResources  = getResourcesFn
	hasResearchFn = hasResearchFn_

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local p = UILib.panel(sg,
		UDim2.fromOffset(370, 172),
		UDim2.new(0.5, -185, 1, -320), 10)
	p.Name    = "TurretPanel"
	p.Visible = false
	panel     = p

	UILib.titleBar(p, "TURRET — UPGRADES", function() TurretPanel.hide() end, C.TURRET)

	-- Upgrade buttons row
	local row                  = Instance.new("Frame")
	row.Name                   = "UpgradeRow"
	row.Size                   = UDim2.fromOffset(354, 78)
	row.Position               = UDim2.fromOffset(8, 46)
	row.BackgroundTransparency = 1
	row.ZIndex                 = 10
	row.Parent                 = p

	local rl                   = Instance.new("UIListLayout")
	rl.FillDirection           = Enum.FillDirection.Horizontal
	rl.HorizontalAlignment     = Enum.HorizontalAlignment.Center
	rl.VerticalAlignment       = Enum.VerticalAlignment.Center
	rl.Padding                 = UDim.new(0, 10)
	rl.Parent                  = row

	flameBtn  = makeUpgradeCard(row, "Flamethrower",    "Short range, rapid fire",    "◆ " .. FLAME_COST  .. " res", FLAME_COLOR,  11)
	rocketBtn = makeUpgradeCard(row, "Rocket Launcher", "Long range, high damage",    "◆ " .. ROCKET_COST .. " res", ROCKET_COLOR, 11)

	UILib.divider(p, 134, 10, 10)

	local sLbl = UILib.lbl(p, "",
		UDim2.fromOffset(350, 30), UDim2.fromOffset(10, 138),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 11 })
	sLbl.Name = "StatusLabel"
	statusLbl = sLbl

	-- ── Button clicks ─────────────────────────────────────────────────────
	flameBtn.MouseButton1Click:Connect(function()
		if not activeTurretId or not flameBtn or not flameBtn.Active then return end
		networkRef.upgradeTurret(activeTurretId, "Flamethrower")
		task.delay(0.35, refresh)
	end)

	rocketBtn.MouseButton1Click:Connect(function()
		if not activeTurretId or not rocketBtn or not rocketBtn.Active then return end
		networkRef.upgradeTurret(activeTurretId, "RocketLauncher")
		task.delay(0.35, refresh)
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function TurretPanel.show(turretId: string)
	activeTurretId = turretId
	if panel then panel.Visible = true end
	refresh()

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
	if panel then panel.Visible = false end
end

function TurretPanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refresh() end
end

return TurretPanel
