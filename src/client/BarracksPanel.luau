local Players = game:GetService("Players")

local BarracksPanel  = {}
local localPlayer    = Players.LocalPlayer
local panel: Frame?
local activeBarracksId: string? = nil
local networkRef: any

-- Cache last known training state per barracks
local lastTrainingState: { [string]: { queue: {string}, progress: number } } = {}

-- Screen-panel refs
local screenProgressFill:  Frame?
local screenProgressLabel: TextLabel?
local screenQueueLabel:    TextLabel?
local screenProgressBg:    Frame?

-- ── Colours ───────────────────────────────────────────────────────────────────
local BG      = Color3.fromRGB(14, 22, 40)       -- dark navy
local BORDER  = Color3.fromRGB(55, 90, 150)
local GREEN   = Color3.fromRGB(35, 140, 65)
local BLUE    = Color3.fromRGB(35, 95, 175)
local DIM     = Color3.fromRGB(22, 32, 55)        -- progress bar track
local FILL    = Color3.fromRGB(55, 185, 255)      -- training fill (cyan-blue)
local WHITE   = Color3.new(1, 1, 1)
local SUBTEXT = Color3.fromRGB(160, 180, 210)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function addCorner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function makeButton(parent: Instance, text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
	local b                = Instance.new("TextButton")
	b.Text                 = text
	b.Position             = pos
	b.Size                 = size
	b.BackgroundColor3     = color
	b.TextColor3           = WHITE
	b.TextScaled           = true
	b.Font                 = Enum.Font.GothamBold
	b.AutoButtonColor      = true
	b.Parent               = parent
	addCorner(b, 7)
	addStroke(b, Color3.fromRGB(255, 255, 255), 0.8)
	return b
end

-- ── World-space training bar (above barracks in 3D world) ─────────────────────

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

	-- Create billboard if needed
	if not bb then
		bb                = Instance.new("BillboardGui")
		bb.Name           = "TrainBar"
		bb.Size           = UDim2.fromOffset(68, 5)
		-- Position just above the health bar (health bar is at size.Y/2 + 2.5)
		bb.StudsOffset    = Vector3.new(0, base.Size.Y / 2 + 4.2, 0)
		bb.AlwaysOnTop    = false
		bb.Parent         = base

		local track              = Instance.new("Frame")
		track.Name               = "Track"
		track.Size               = UDim2.new(1, 0, 1, 0)
		track.BackgroundColor3   = Color3.fromRGB(20, 20, 30)
		track.BorderSizePixel    = 0
		track.Parent             = bb
		addCorner(track, 2)

		local fill               = Instance.new("Frame")
		fill.Name                = "Fill"
		fill.Size                = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3    = FILL
		fill.BorderSizePixel     = 0
		fill.Parent              = track
		addCorner(fill, 2)
	end

	-- Update fill width
	local track = bb:FindFirstChild("Track") :: Frame?
	if track then
		local fill = track:FindFirstChild("Fill") :: Frame?
		if fill then
			fill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
		end
	end
end

-- ── Screen panel UI update ────────────────────────────────────────────────────

local function updateScreenUI(queue: {string}, progress: number)
	if not screenProgressBg then return end

	local training = #queue > 0
	screenProgressBg.Visible = training

	if training then
		if screenProgressLabel then
			screenProgressLabel.Text = "Training:  " .. queue[1]
		end
		if screenProgressFill then
			screenProgressFill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
		end
		if screenQueueLabel then
			if #queue > 1 then
				local rest = {}
				for i = 2, #queue do table.insert(rest, queue[i]) end
				screenQueueLabel.Text = "Next:  " .. table.concat(rest, "  →  ")
			else
				screenQueueLabel.Text = "Queue empty after this"
			end
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function BarracksPanel.init(network)
	networkRef = network

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- ── Panel frame ──────────────────────────────────────────────────────
	panel                        = Instance.new("Frame")
	panel.Name                   = "BarracksPanel"
	panel.Size                   = UDim2.fromOffset(370, 172)
	panel.Position               = UDim2.new(0.5, -185, 1, -248)
	panel.BackgroundColor3       = BG
	panel.BackgroundTransparency = 0.08
	panel.Visible                = false
	panel.ZIndex                 = 10
	panel.Parent                 = sg
	addCorner(panel, 10)
	addStroke(panel, BORDER, 1.5)

	-- Title bar
	local titleBar               = Instance.new("Frame")
	titleBar.Size                = UDim2.new(1, 0, 0, 30)
	titleBar.Position            = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3    = Color3.fromRGB(20, 32, 60)
	titleBar.BackgroundTransparency = 0.2
	titleBar.BorderSizePixel     = 0
	titleBar.Parent              = panel
	addCorner(titleBar, 10)   -- top corners match panel

	local title                  = Instance.new("TextLabel")
	title.Text                   = "BARRACKS"
	title.Size                   = UDim2.new(1, -42, 1, 0)   -- leave room for close btn
	title.Position               = UDim2.fromOffset(8, 0)
	title.BackgroundTransparency = 1
	title.TextColor3             = WHITE
	title.Font                   = Enum.Font.GothamBold
	title.TextSize               = 14
	title.TextXAlignment         = Enum.TextXAlignment.Left
	title.Parent                 = titleBar

	local closeBtn               = Instance.new("TextButton")
	closeBtn.Text                = "✕"
	closeBtn.Size                = UDim2.fromOffset(26, 22)
	closeBtn.Position            = UDim2.new(1, -30, 0.5, -11)
	closeBtn.BackgroundColor3    = Color3.fromRGB(140, 30, 30)
	closeBtn.TextColor3          = WHITE
	closeBtn.Font                = Enum.Font.GothamBold
	closeBtn.TextSize            = 14
	closeBtn.AutoButtonColor     = true
	closeBtn.Parent              = titleBar
	addCorner(closeBtn, 4)

	closeBtn.MouseButton1Click:Connect(function()
		BarracksPanel.hide()
	end)

	-- ── Train buttons ────────────────────────────────────────────────────
	local soldierBtn = makeButton(panel,
		"Train Soldier\n25 resources",
		UDim2.fromOffset(10, 38),
		UDim2.fromOffset(170, 64),
		GREEN)

	local tankBtn = makeButton(panel,
		"Train Tank\n60 resources",
		UDim2.fromOffset(190, 38),
		UDim2.fromOffset(170, 64),
		BLUE)

	-- ── Divider ──────────────────────────────────────────────────────────
	local divider                = Instance.new("Frame")
	divider.Size                 = UDim2.new(1, -20, 0, 1)
	divider.Position             = UDim2.fromOffset(10, 108)
	divider.BackgroundColor3     = BORDER
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel      = 0
	divider.Parent               = panel

	-- ── Training status section ───────────────────────────────────────────
	local statusSection          = Instance.new("Frame")
	statusSection.Name           = "StatusSection"
	statusSection.Size           = UDim2.new(1, -20, 0, 52)
	statusSection.Position       = UDim2.fromOffset(10, 114)
	statusSection.BackgroundTransparency = 1
	statusSection.Parent         = panel
	screenProgressBg = statusSection

	local trainLabel             = Instance.new("TextLabel")
	trainLabel.Name              = "TrainLabel"
	trainLabel.Size              = UDim2.new(1, 0, 0, 18)
	trainLabel.Position          = UDim2.new(0, 0, 0, 0)
	trainLabel.BackgroundTransparency = 1
	trainLabel.TextColor3        = WHITE
	trainLabel.Font              = Enum.Font.Gotham
	trainLabel.TextSize          = 13
	trainLabel.TextXAlignment    = Enum.TextXAlignment.Left
	trainLabel.Text              = "Training:  —"
	trainLabel.Parent            = statusSection
	screenProgressLabel = trainLabel

	-- Progress track
	local track                  = Instance.new("Frame")
	track.Size                   = UDim2.new(1, 0, 0, 12)
	track.Position               = UDim2.fromOffset(0, 20)
	track.BackgroundColor3       = DIM
	track.BorderSizePixel        = 0
	track.Parent                 = statusSection
	addCorner(track, 4)

	local fill                   = Instance.new("Frame")
	fill.Name                    = "Fill"
	fill.Size                    = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3        = FILL
	fill.BorderSizePixel         = 0
	fill.Parent                  = track
	addCorner(fill, 4)
	screenProgressFill = fill

	local qLabel                 = Instance.new("TextLabel")
	qLabel.Name                  = "QueueLabel"
	qLabel.Size                  = UDim2.new(1, 0, 0, 16)
	qLabel.Position              = UDim2.fromOffset(0, 35)
	qLabel.BackgroundTransparency = 1
	qLabel.TextColor3            = SUBTEXT
	qLabel.Font                  = Enum.Font.Gotham
	qLabel.TextSize              = 12
	qLabel.TextXAlignment        = Enum.TextXAlignment.Left
	qLabel.Text                  = ""
	qLabel.Parent                = statusSection
	screenQueueLabel = qLabel

	-- ── Button callbacks ──────────────────────────────────────────────────
	soldierBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then networkRef.trainUnit(activeBarracksId, "Soldier") end
	end)

	tankBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then networkRef.trainUnit(activeBarracksId, "Tank") end
	end)

	-- ── Training update listener ──────────────────────────────────────────
	network.onTrainingUpdate(function(barrackId: string, queue: {string}, progress: number)
		lastTrainingState[barrackId] = { queue = queue, progress = progress }

		-- Always update the world-space bar for any barracks
		updateWorldTrainBar(barrackId, queue, progress)

		-- Update screen panel only when this barracks is open
		if barrackId == activeBarracksId then
			updateScreenUI(queue, progress)
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BarracksPanel.show(barrackId: string)
	activeBarracksId = barrackId
	if panel then panel.Visible = true end

	local state = lastTrainingState[barrackId]
	if state then
		updateScreenUI(state.queue, state.progress)
	else
		if screenProgressBg then screenProgressBg.Visible = false end
	end
end

function BarracksPanel.hide()
	activeBarracksId = nil
	if panel then panel.Visible = false end
end

function BarracksPanel.isVisible(): boolean
	return panel ~= nil and (panel :: Frame).Visible
end

return BarracksPanel
