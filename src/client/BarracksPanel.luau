local Players = game:GetService("Players")

local BarracksPanel  = {}
local localPlayer    = Players.LocalPlayer
local panel: Frame?
local activeBarracksId: string? = nil
local networkRef: any

local BLUE  = Color3.fromRGB(40,  90, 150)
local GREEN = Color3.fromRGB(30, 120,  60)
local DARK  = Color3.fromRGB(20,  20,  20)
local WHITE = Color3.new(1, 1, 1)

local function makeButton(parent: Instance, text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
	local b                  = Instance.new("TextButton")
	b.Text                   = text
	b.Position               = pos
	b.Size                   = size
	b.BackgroundColor3       = color
	b.TextColor3             = WHITE
	b.TextScaled             = true
	b.Font                   = Enum.Font.GothamBold
	b.Parent                 = parent
	local c                  = Instance.new("UICorner")
	c.CornerRadius           = UDim.new(0, 6)
	c.Parent                 = b
	return b
end

function BarracksPanel.init(network)
	networkRef = network

	-- Attach to the existing RTSHUD ScreenGui (created by HUD.create())
	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	-- Panel frame — sits just above the bottom action bar
	panel                          = Instance.new("Frame")
	panel.Name                     = "BarracksPanel"
	panel.Size                     = UDim2.fromOffset(360, 120)
	panel.Position                 = UDim2.new(0.5, -180, 1, -200)
	panel.BackgroundColor3         = DARK
	panel.BackgroundTransparency   = 0.25
	panel.Visible                  = false
	panel.ZIndex                   = 10
	panel.Parent                   = sg

	local corner           = Instance.new("UICorner")
	corner.CornerRadius    = UDim.new(0, 8)
	corner.Parent          = panel

	local title            = Instance.new("TextLabel")
	title.Text             = "Barracks — select unit to train"
	title.Size             = UDim2.new(1, -12, 0, 28)
	title.Position         = UDim2.fromOffset(6, 6)
	title.BackgroundTransparency = 1
	title.TextColor3       = WHITE
	title.Font             = Enum.Font.GothamBold
	title.TextScaled       = true
	title.Parent           = panel

	-- Soldier button (left)
	local soldierBtn = makeButton(panel,
		"Train Soldier\n25 resources",
		UDim2.fromOffset(10, 42),
		UDim2.fromOffset(165, 68),
		GREEN)

	-- Tank button (right)
	local tankBtn = makeButton(panel,
		"Train Tank\n60 resources",
		UDim2.fromOffset(185, 42),
		UDim2.fromOffset(165, 68),
		BLUE)

	soldierBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then
			networkRef.trainUnit(activeBarracksId, "Soldier")
		end
	end)

	tankBtn.MouseButton1Click:Connect(function()
		if activeBarracksId then
			networkRef.trainUnit(activeBarracksId, "Tank")
		end
	end)
end

function BarracksPanel.show(barrackId: string)
	activeBarracksId = barrackId
	if panel then panel.Visible = true end
end

function BarracksPanel.hide()
	activeBarracksId = nil
	if panel then panel.Visible = false end
end

function BarracksPanel.isVisible(): boolean
	return panel ~= nil and (panel :: Frame).Visible
end

return BarracksPanel
