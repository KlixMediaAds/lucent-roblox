local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))

local MinePanel   = {}
local localPlayer = Players.LocalPlayer

-- mineId → miner count (only tracks this player's mines)
local mineData:   {[string]: number} = {}
-- stable display number per mine ("Mine 1", "Mine 2", ...)
local mineLabel:  {[string]: number} = {}
local labelCount  = 0

local container: Frame?
local listFrame: Frame?
local rowLabels: {[string]: TextLabel} = {}

local DARK = Color3.fromRGB(20,  20, 20)
local GOLD = Color3.fromRGB(210, 170, 30)
local WHITE = Color3.new(1, 1, 1)

local ROW_H  = 22
local PAD_TOP = 32

local function refresh()
	if not container or not listFrame then return end

	-- Destroy old rows
	for _, lbl in rowLabels do lbl:Destroy() end
	rowLabels = {}

	local i = 0
	for mineId, count in mineData do
		local income  = count * Config.MINI_MINER_INCOME
		local lbl     = Instance.new("TextLabel")
		lbl.Size      = UDim2.new(1, -8, 0, ROW_H)
		lbl.Position  = UDim2.fromOffset(4, i * (ROW_H + 2))
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = WHITE
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Font       = Enum.Font.Gotham
		lbl.TextSize   = 13
		lbl.Text       = "Mine " .. mineLabel[mineId]
			.. ":  " .. count .. "/" .. Config.MINI_MINER_MAX .. " miners"
			.. "  (+" .. income .. "/10s)"
		lbl.Parent     = listFrame
		rowLabels[mineId] = lbl
		i += 1
	end

	-- Resize the container to fit all rows (or collapse if empty)
	local rowCount = i
	container.Visible = rowCount > 0
	container.Size    = UDim2.fromOffset(300, PAD_TOP + math.max(0, rowCount) * (ROW_H + 2) + 6)
end

function MinePanel.init()
	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	container                    = Instance.new("Frame")
	container.Name               = "MinePanel"
	container.BackgroundColor3   = DARK
	container.BackgroundTransparency = 0.3
	container.Size               = UDim2.fromOffset(300, PAD_TOP)
	container.Position           = UDim2.new(1, -310, 0, 10)
	container.Visible            = false
	container.ZIndex             = 8
	container.Parent             = sg

	local corner         = Instance.new("UICorner")
	corner.CornerRadius  = UDim.new(0, 6)
	corner.Parent        = container

	local header             = Instance.new("TextLabel")
	header.Size              = UDim2.new(1, -8, 0, 24)
	header.Position          = UDim2.fromOffset(4, 4)
	header.BackgroundTransparency = 1
	header.TextColor3        = GOLD
	header.Font              = Enum.Font.GothamBold
	header.TextSize          = 14
	header.TextXAlignment    = Enum.TextXAlignment.Left
	header.Text              = "  Mines"
	header.Parent            = container

	listFrame                = Instance.new("Frame")
	listFrame.Name           = "List"
	listFrame.Size           = UDim2.new(1, 0, 1, -PAD_TOP)
	listFrame.Position       = UDim2.fromOffset(0, PAD_TOP)
	listFrame.BackgroundTransparency = 1
	listFrame.Parent         = container
end

-- Called when this player places a Mine (via onBuildingPlaced filter in init.client)
function MinePanel.registerMine(mineId: string)
	if mineData[mineId] then return end
	labelCount           += 1
	mineLabel[mineId]    = labelCount
	mineData[mineId]     = 0
	refresh()
end

-- Called when MinerSpawned fires for a mine this player owns
function MinePanel.updateMinerCount(mineId: string, count: number)
	if not mineData[mineId] then return end
	mineData[mineId] = count
	refresh()
end

return MinePanel
