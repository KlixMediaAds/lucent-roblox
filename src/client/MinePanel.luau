local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local MinePanel   = {}
local localPlayer = Players.LocalPlayer
local C           = UILib.C

local panel:          Frame?
local activeMineId:   string? = nil
local networkRef:     any
local getResources:   (() -> number)?
local getMinerCount:  ((string) -> number)?
local hasResearchFn:  ((string) -> boolean)?

-- Button refs for state updates
local effBtn:    TextButton?
local capBtn:    TextButton?
local statusLbl: TextLabel?
local infoLbl:   TextLabel?

-- ── Upgrade card builder ──────────────────────────────────────────────────────

local function makeUpgradeCard(
	parent:  Instance,
	name:    string,
	desc:    string,
	cost:    string,
	color:   Color3,
	zi:      number
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

	-- Accent bar
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

local function getUpgradeState(mineId: string): string?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local model = bf:FindFirstChild(mineId)
	if not model then return nil end
	local uv = model:FindFirstChild("Upgrade") :: StringValue?
	return uv and uv.Value or nil
end

-- ── Refresh ───────────────────────────────────────────────────────────────────

local function refresh()
	if not activeMineId then return end
	local mineId      = activeMineId
	local upgrade     = getUpgradeState(mineId)
	local res         = getResources and getResources() or 0
	local hasResearch = hasResearchFn and hasResearchFn("BetterMines") or false
	local miners      = getMinerCount and getMinerCount(mineId) or 0
	local cap         = if upgrade == "Capacity" then 10 else 6
	local mult        = if upgrade == "Efficiency" then 2.0 else 1.0
	local incMin      = miners * 5 * (60 / 10) * mult

	if infoLbl then
		infoLbl.Text = string.format(
			"Miners  %d / %d    ·    Income  %.0f / min", miners, cap, incMin)
	end

	-- ── Efficiency button ─────────────────────────────────────────────────
	if effBtn then
		-- Get child labels (by index order: name, desc, cost — children 3-5 since 1=AccentBar, 2=NameLbl... )
		-- Actually find by scanning for TextLabels
		local labels: {TextLabel} = {}
		for _, ch in effBtn:GetChildren() do
			if ch:IsA("TextLabel") then table.insert(labels, ch) end
		end
		local nameLbl = #labels >= 1 and labels[1] or nil
		local descLbl = #labels >= 2 and labels[2] or nil
		local costLbl = #labels >= 3 and labels[3] or nil

		if upgrade == "Efficiency" then
			effBtn.BackgroundColor3       = C.GREEN
			effBtn.BackgroundTransparency = 0.08
			effBtn.Active                 = false
			if nameLbl then nameLbl.Text = "EFFICIENCY" end
			if descLbl then descLbl.Text = "Double income" end
			if costLbl then costLbl.Text = "✓  ACTIVE"; costLbl.TextColor3 = C.GREEN end
		elseif upgrade ~= nil then
			effBtn.BackgroundColor3       = C.BG_LOCKED
			effBtn.BackgroundTransparency = 0
			effBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.DIM; nameLbl.Text = "EFFICIENCY" end
			if descLbl then descLbl.TextColor3 = C.DIM; descLbl.Text = "Double income" end
			if costLbl then costLbl.TextColor3 = C.DIM; costLbl.Text = "LOCKED" end
		elseif not hasResearch then
			effBtn.BackgroundColor3       = C.BG_LOCKED
			effBtn.BackgroundTransparency = 0
			effBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.DIM; nameLbl.Text = "EFFICIENCY" end
			if descLbl then descLbl.TextColor3 = C.DIM; descLbl.Text = "Double income" end
			if costLbl then costLbl.TextColor3 = C.DIM; costLbl.Text = "Needs: Better Mines" end
		else
			local ok = res >= 150
			effBtn.BackgroundColor3       = ok and C.MINE or C.BG_LOCKED
			effBtn.BackgroundTransparency = ok and 0.14 or 0
			effBtn.Active                 = ok
			if nameLbl then nameLbl.TextColor3 = ok and C.TEXT or C.DIM; nameLbl.Text = "EFFICIENCY" end
			if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = "Double income" end
			if costLbl then
				costLbl.Text       = ok and "◆ 150 res" or "◆ 150 res  (need more)"
				costLbl.TextColor3 = ok and C.GOLD or C.DIM
			end
		end
	end

	-- ── Capacity button ───────────────────────────────────────────────────
	if capBtn then
		local labels: {TextLabel} = {}
		for _, ch in capBtn:GetChildren() do
			if ch:IsA("TextLabel") then table.insert(labels, ch) end
		end
		local nameLbl = #labels >= 1 and labels[1] or nil
		local descLbl = #labels >= 2 and labels[2] or nil
		local costLbl = #labels >= 3 and labels[3] or nil

		if upgrade == "Capacity" then
			capBtn.BackgroundColor3       = C.GREEN
			capBtn.BackgroundTransparency = 0.08
			capBtn.Active                 = false
			if nameLbl then nameLbl.Text = "CAPACITY" end
			if descLbl then descLbl.Text = "+4 miner slots" end
			if costLbl then costLbl.Text = "✓  ACTIVE"; costLbl.TextColor3 = C.GREEN end
		elseif upgrade ~= nil then
			capBtn.BackgroundColor3       = C.BG_LOCKED
			capBtn.BackgroundTransparency = 0
			capBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.DIM; nameLbl.Text = "CAPACITY" end
			if descLbl then descLbl.TextColor3 = C.DIM; descLbl.Text = "+4 miner slots" end
			if costLbl then costLbl.TextColor3 = C.DIM; costLbl.Text = "LOCKED" end
		elseif not hasResearch then
			capBtn.BackgroundColor3       = C.BG_LOCKED
			capBtn.BackgroundTransparency = 0
			capBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.DIM; nameLbl.Text = "CAPACITY" end
			if descLbl then descLbl.TextColor3 = C.DIM; descLbl.Text = "+4 miner slots" end
			if costLbl then costLbl.TextColor3 = C.DIM; costLbl.Text = "Needs: Better Mines" end
		else
			local ok = res >= 125
			capBtn.BackgroundColor3       = ok and C.TURRET or C.BG_LOCKED
			capBtn.BackgroundTransparency = ok and 0.14 or 0
			capBtn.Active                 = ok
			if nameLbl then nameLbl.TextColor3 = ok and C.TEXT or C.DIM; nameLbl.Text = "CAPACITY" end
			if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = "+4 miner slots" end
			if costLbl then
				costLbl.Text       = ok and "◆ 125 res" or "◆ 125 res  (need more)"
				costLbl.TextColor3 = ok and C.GOLD or C.DIM
			end
		end
	end

	-- ── Status label ──────────────────────────────────────────────────────
	if statusLbl then
		if not hasResearch then
			statusLbl.Text = "Research 'Better Mines' at your Command Center to unlock upgrades."
		elseif upgrade then
			statusLbl.Text = upgrade .. " upgrade active.  The other option is permanently locked."
		else
			statusLbl.Text = "Choose one upgrade — your choice is permanent."
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function MinePanel.init(network, getResourcesFn, getMinerCountFn, hasResearchFn_)
	networkRef    = network
	getResources  = getResourcesFn
	getMinerCount = getMinerCountFn
	hasResearchFn = hasResearchFn_

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local p = UILib.panel(sg,
		UDim2.fromOffset(370, 172),
		UDim2.new(0.5, -185, 1, -320), 10)
	p.Name    = "MinePanel"
	p.Visible = false
	panel     = p

	UILib.titleBar(p, "MINE — UPGRADES", function() MinePanel.hide() end, C.MINE)

	-- Miner info row
	local iLbl = UILib.lbl(p, "",
		UDim2.fromOffset(350, 16), UDim2.fromOffset(10, 40),
		{ size = 11, color = C.SUBTEXT, zIndex = 11 })
	iLbl.Name = "InfoLabel"
	infoLbl   = iLbl

	-- Upgrade buttons row
	local row                        = Instance.new("Frame")
	row.Name                         = "UpgradeRow"
	row.Size                         = UDim2.fromOffset(354, 78)
	row.Position                     = UDim2.fromOffset(8, 58)
	row.BackgroundTransparency       = 1
	row.ZIndex                       = 10
	row.Parent                       = p

	local rl                         = Instance.new("UIListLayout")
	rl.FillDirection                 = Enum.FillDirection.Horizontal
	rl.HorizontalAlignment           = Enum.HorizontalAlignment.Center
	rl.VerticalAlignment             = Enum.VerticalAlignment.Center
	rl.Padding                       = UDim.new(0, 10)
	rl.Parent                        = row

	effBtn = makeUpgradeCard(row, "Efficiency", "Double income", "◆ 150 res", C.MINE,   11)
	capBtn = makeUpgradeCard(row, "Capacity",  "+4 miner slots", "◆ 125 res", C.TURRET, 11)

	-- Divider + status
	UILib.divider(p, 142, 10, 10)

	local sLbl = UILib.lbl(p, "",
		UDim2.fromOffset(350, 26), UDim2.fromOffset(10, 146),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 11 })
	sLbl.Name = "StatusLabel"
	statusLbl = sLbl

	-- ── Button clicks ─────────────────────────────────────────────────────
	effBtn.MouseButton1Click:Connect(function()
		if not activeMineId or not effBtn or not effBtn.Active then return end
		networkRef.upgradeMine(activeMineId, "Efficiency")
		task.delay(0.35, refresh)
	end)

	capBtn.MouseButton1Click:Connect(function()
		if not activeMineId or not capBtn or not capBtn.Active then return end
		networkRef.upgradeMine(activeMineId, "Capacity")
		task.delay(0.35, refresh)
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function MinePanel.show(mineId: string)
	activeMineId = mineId
	if panel then panel.Visible = true end
	refresh()

	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(mineId, 10)
		if not model then return end
		model.ChildAdded:Connect(function(child)
			if child.Name == "Upgrade" and activeMineId == mineId then refresh() end
		end)
	end)
end

function MinePanel.hide()
	activeMineId = nil
	if panel then panel.Visible = false end
end

function MinePanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refresh() end
end

return MinePanel
