local Players = game:GetService("Players")

local HUD         = {}
local localPlayer = Players.LocalPlayer

local resLabel: TextLabel?
local selLabel: TextLabel?

local BLUE   = Color3.fromRGB(40,  90, 150)
local GOLD   = Color3.fromRGB(160, 120,  10)
local RED    = Color3.fromRGB(160, 50,  50)
local DARK   = Color3.fromRGB(20,  20,  20)
local WHITE  = Color3.new(1, 1, 1)

local function makeLabel(parent: Instance, text: string, pos: UDim2, size: UDim2): TextLabel
	local l                    = Instance.new("TextLabel")
	l.Text                     = text
	l.Position                 = pos
	l.Size                     = size
	l.BackgroundColor3         = DARK
	l.BackgroundTransparency   = 0.4
	l.TextColor3               = WHITE
	l.TextScaled               = true
	l.Font                     = Enum.Font.GothamBold
	l.Parent                   = parent
	return l
end

local function makeButton(parent: Instance, text: string, pos: UDim2, size: UDim2, color: Color3?): TextButton
	local b                    = Instance.new("TextButton")
	b.Text                     = text
	b.Position                 = pos
	b.Size                     = size
	b.BackgroundColor3         = color or BLUE
	b.TextColor3               = WHITE
	b.TextScaled               = true
	b.Font                     = Enum.Font.GothamBold
	b.Parent                   = parent
	local c                    = Instance.new("UICorner")
	c.CornerRadius             = UDim.new(0, 6)
	c.Parent                   = b
	return b
end

-- Creates the ScreenGui and returns the elements needed by other modules.
-- Returns: dragFrame, barracksBuildBtn, mineBuildBtn, cancelBtn
function HUD.create(): (Frame, TextButton, TextButton, TextButton)
	local sg          = Instance.new("ScreenGui")
	sg.Name           = "RTSHUD"
	sg.ResetOnSpawn   = false
	sg.Parent         = localPlayer.PlayerGui

	-- Resource counter (top-left)
	resLabel = makeLabel(sg, "Resources: 100",
		UDim2.fromOffset(10, 10),
		UDim2.fromOffset(210, 42))

	-- Selection info (top-centre)
	selLabel = makeLabel(sg, "",
		UDim2.new(0.5, -120, 0, 10),
		UDim2.fromOffset(240, 42))
	selLabel.BackgroundTransparency = 1

	-- Drag-select overlay frame
	local dragFrame                     = Instance.new("Frame")
	dragFrame.Name                      = "DragSelect"
	dragFrame.BackgroundColor3          = Color3.fromRGB(100, 200, 255)
	dragFrame.BackgroundTransparency    = 0.7
	dragFrame.BorderSizePixel           = 1
	dragFrame.BorderColor3              = Color3.fromRGB(160, 220, 255)
	dragFrame.Visible                   = false
	dragFrame.ZIndex                    = 20
	dragFrame.Parent                    = sg

	-- Bottom action buttons
	local buildBtn = makeButton(sg, "Build Barracks (50)",
		UDim2.new(0, 10,  1, -60), UDim2.fromOffset(185, 50))
	local mineBtn  = makeButton(sg, "Build Mine (75)",
		UDim2.new(0, 205, 1, -60), UDim2.fromOffset(155, 50), GOLD)
	local cancelBtn = makeButton(sg, "Cancel [Esc]",
		UDim2.new(0, 370, 1, -60), UDim2.fromOffset(140, 50), RED)
	cancelBtn.Visible = false

	return dragFrame, buildBtn, mineBtn, cancelBtn
end

-- Wires up network events and button callbacks (call after UnitController is init'd).
function HUD.wire(network, unitController, buildingPlacer,
	buildBtn: TextButton, mineBtn: TextButton, cancelBtn: TextButton)

	network.onResourceSync(function(n: number)
		if resLabel then resLabel.Text = "Resources: " .. n end
	end)

	unitController.onSelectionChanged(function(n: number)
		if selLabel then
			selLabel.Text = n > 0 and (n .. " unit" .. (n == 1 and "" or "s") .. " selected") or ""
		end
	end)

	buildBtn.MouseButton1Click:Connect(function()
		buildingPlacer.enterPlacementMode("Barracks")
	end)

	mineBtn.MouseButton1Click:Connect(function()
		buildingPlacer.enterPlacementMode("Mine")
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		buildingPlacer.exitPlacementMode()
	end)

	-- Highlight whichever button is active; restore both when mode exits
	buildingPlacer.onModeChanged(function(active: boolean, buildingType: string?)
		buildBtn.BackgroundColor3 = (active and buildingType == "Barracks") and RED or BLUE
		mineBtn.BackgroundColor3  = (active and buildingType == "Mine")     and RED or GOLD
		cancelBtn.Visible         = active
	end)
end

return HUD
