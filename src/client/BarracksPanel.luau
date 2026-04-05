local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local BarracksPanel  = {}
local localPlayer    = Players.LocalPlayer
local C              = UILib.C

local panel:            Frame?
local activeBarracksId: string? = nil
local networkRef:       any
local hasResearchFn:    ((string) -> boolean)?

local lastTrainingState: { [string]: { queue: {string}, progress: number } } = {}

-- Screen-panel training refs
local progFill:   Frame?
local progLabel:  TextLabel?
local queueLabel: TextLabel?
local statusSection: Frame?

-- Elite button ref (for research-gate refresh)
local eliteBtn: TextButton?

-- ── World-space training bar (above barracks in 3D) ───────────────────────────

local function updateWorldTrainBar(barrackId: string, queue: {string}, progress: number)
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return end
	local model = bf:FindFirstChild(barrackId)
	if not model then return end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return end

	local bb = base:FindFirstChild("TrainBar") :: BillboardGui?

	if #queue == 0 then
		if bb then bb:Destroy() end
		return
	end

	if not bb then
		bb            = Instance.new("BillboardGui")
		bb.Name       = "TrainBar"
		bb.Size       = UDim2.fromOffset(70, 6)
		bb.StudsOffset = Vector3.new(0, base.Size.Y / 2 + 4.5, 0)
		bb.AlwaysOnTop = false
		bb.Parent     = base

		local track              = Instance.new("Frame")
		track.Size               = UDim2.new(1, 0, 1, 0)
		track.BackgroundColor3   = Color3.fromRGB(10, 12, 22)
		track.BorderSizePixel    = 0
		track.Parent             = bb
		UILib.corner(track, 2)

		local fill               = Instance.new("Frame")
		fill.Name                = "Fill"
		fill.Size                = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3    = C.ACCENT
		fill.BorderSizePixel     = 0
		fill.Parent              = track
		UILib.corner(fill, 2)
	end

	local track = bb:FindFirstChildWhichIsA("Frame") :: Frame?
	if track then
		local fill = track:FindFirstChild("Fill") :: Frame?
		if fill then fill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) end
	end
end

-- ── Screen panel update ───────────────────────────────────────────────────────

local function updateScreenUI(queue: {string}, progress: number)
	if not statusSection then return end
	local training = #queue > 0
	statusSection.Visible = training
	if not training then return end

	if progLabel then
		progLabel.Text = "Training:  " .. queue[1]
	end
	if progFill then
		progFill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
	end
	if queueLabel then
		if #queue > 1 then
			local rest = {}
			for i = 2, #queue do table.insert(rest, queue[i]) end
			queueLabel.Text = "Next:  " .. table.concat(rest, "  →  ")
		else
			queueLabel.Text = "Queue empty after this"
		end
	end
end

-- ── Elite button state refresh ────────────────────────────────────────────────

local function refreshEliteBtn()
	if not eliteBtn then return end
	local unlocked = hasResearchFn and hasResearchFn("EliteUnits") or false

	local labels: {TextLabel} = {}
	for _, ch in eliteBtn:GetChildren() do
		if ch:IsA("TextLabel") then table.insert(labels, ch) end
	end
	local nameLbl = labels[1]
	local costLbl = labels[2]

	if unlocked then
		eliteBtn.BackgroundColor3       = Color3.fromRGB(180, 80, 230)
		eliteBtn.BackgroundTransparency = 0.12
		eliteBtn.Active                 = true
		if nameLbl then nameLbl.TextColor3 = C.TEXT end
		if costLbl then costLbl.TextColor3 = C.GOLD; costLbl.Text = "◆ 100 res" end
	else
		eliteBtn.BackgroundColor3       = C.BG_LOCKED
		eliteBtn.BackgroundTransparency = 0
		eliteBtn.Active                 = false
		if nameLbl then nameLbl.TextColor3 = C.DIM end
		if costLbl then costLbl.TextColor3 = C.DIM; costLbl.Text = "Needs: Elite Units research" end
	end
end

-- ── Train button (custom multi-label card) ────────────────────────────────────

local function makeTrainBtn(parent: Instance, name: string, cost: string, color: Color3, zi: number): TextButton
	local btn                  = Instance.new("TextButton")
	btn.Name                   = name .. "Btn"
	btn.Size                   = UDim2.fromOffset(108, 68)
	btn.BackgroundColor3       = color
	btn.BackgroundTransparency = 0.12
	btn.Text                   = ""
	btn.AutoButtonColor        = true
	btn.BorderSizePixel        = 0
	btn.ZIndex                 = zi
	btn.Parent                 = parent
	UILib.corner(btn, 9)
	UILib.stroke(btn, C.BORDER, 1)

	-- Accent bar at top
	local bar                  = Instance.new("Frame")
	bar.Size                   = UDim2.new(1, -2, 0, 4)
	bar.Position               = UDim2.fromOffset(1, 1)
	bar.BackgroundColor3       = color
	bar.BackgroundTransparency = 0
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = zi + 1
	bar.Parent                 = btn
	UILib.corner(bar, 6)

	-- Unit name
	UILib.lbl(btn, name:upper(),
		UDim2.fromOffset(88, 22), UDim2.fromOffset(10, 14),
		{ bold = true, size = 13, color = C.TEXT, zIndex = zi + 1 })

	-- Cost
	UILib.lbl(btn, "◆ " .. cost,
		UDim2.fromOffset(88, 16), UDim2.fromOffset(10, 38),
		{ size = 11, color = C.GOLD, zIndex = zi + 1 })

	return btn
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function BarracksPanel.init(network, hasResearch)
	networkRef    = network
	hasResearchFn = hasResearch
	local sg      = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- Panel frame
	local p = UILib.panel(sg,
		UDim2.fromOffset(370, 172),
		UDim2.new(0.5, -185, 1, -320), 10)
	p.Name = "BarracksPanel"
	p.Visible = false
	panel = p

	-- Title bar
	UILib.titleBar(p, "BARRACKS", function() BarracksPanel.hide() end, C.BARRACKS)

	-- Train buttons row (3 buttons)
	local trainRow                   = Instance.new("Frame")
	trainRow.Name                    = "TrainRow"
	trainRow.Size                    = UDim2.fromOffset(354, 68)
	trainRow.Position                = UDim2.fromOffset(8, 42)
	trainRow.BackgroundTransparency  = 1
	trainRow.ZIndex                  = 10
	trainRow.Parent                  = p

	local rowLayout                  = Instance.new("UIListLayout")
	rowLayout.FillDirection          = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment    = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment      = Enum.VerticalAlignment.Center
	rowLayout.Padding                = UDim.new(0, 8)
	rowLayout.Parent                 = trainRow

	local soldierBtn = makeTrainBtn(trainRow, "Soldier", "25 res",  C.GREEN,    11)
	local tankBtn    = makeTrainBtn(trainRow, "Tank",    "60 res",  C.BARRACKS, 11)
	local eliteBtnL  = makeTrainBtn(trainRow, "Elite",   "100 res", Color3.fromRGB(180, 80, 230), 11)
	eliteBtn         = eliteBtnL

	refreshEliteBtn()

	-- Divider
	UILib.divider(p, 118, 10, 10)

	-- Training status section
	local sec                        = Instance.new("Frame")
	sec.Name                         = "StatusSection"
	sec.Size                         = UDim2.fromOffset(350, 48)
	sec.Position                     = UDim2.fromOffset(10, 122)
	sec.BackgroundTransparency       = 1
	sec.ZIndex                       = 10
	sec.Visible                      = false
	sec.Parent                       = p
	statusSection = sec

	-- Progress label
	local pl = UILib.lbl(sec, "Training:  —",
		UDim2.fromOffset(350, 16), UDim2.fromOffset(0, 0),
		{ size = 13, color = C.TEXT, bold = true, zIndex = 11 })
	pl.Name  = "ProgressLabel"
	progLabel = pl

	-- Progress bar
	local pb = UILib.progressBar(sec,
		UDim2.fromOffset(350, 10), UDim2.fromOffset(0, 20),
		C.ACCENT, 11)
	progFill = pb.fill

	-- Queue label
	local ql = UILib.lbl(sec, "",
		UDim2.fromOffset(350, 16), UDim2.fromOffset(0, 34),
		{ size = 11, color = C.SUBTEXT, zIndex = 11 })
	ql.Name   = "QueueLabel"
	queueLabel = ql

	-- ── Button callbacks ──────────────────────────────────────────────────
	soldierBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then networkRef.trainUnit(activeBarracksId, "Soldier") end
	end)

	tankBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then networkRef.trainUnit(activeBarracksId, "Tank") end
	end)

	eliteBtnL.MouseButton1Click:Connect(function()
		if activeBarracksId and eliteBtnL.Active then
			networkRef.trainUnit(activeBarracksId, "Elite")
		end
	end)

	-- Training update listener
	network.onTrainingUpdate(function(barrackId: string, queue: {string}, progress: number)
		lastTrainingState[barrackId] = { queue = queue, progress = progress }
		updateWorldTrainBar(barrackId, queue, progress)
		if barrackId == activeBarracksId then
			updateScreenUI(queue, progress)
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BarracksPanel.show(barrackId: string)
	activeBarracksId = barrackId
	if panel then panel.Visible = true end
	refreshEliteBtn()
	local state = lastTrainingState[barrackId]
	if state then
		updateScreenUI(state.queue, state.progress)
	else
		if statusSection then statusSection.Visible = false end
	end
end

function BarracksPanel.hide()
	activeBarracksId = nil
	if panel then panel.Visible = false end
end

function BarracksPanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refreshEliteBtn() end
end

function BarracksPanel.isVisible(): boolean
	return panel ~= nil and (panel :: Frame).Visible
end

return BarracksPanel
