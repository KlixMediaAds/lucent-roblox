local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel     = {}
local localPlayer       = Players.LocalPlayer
local C                 = UILib.C

local panel:            Frame?
local activeWorkshopId: string? = nil
local networkRef:       any
local getResearchedFn:  ((string) -> boolean)?
local getProgressFn:    ((string) -> number?)?

local techBtn:    TextButton?
local progFill:   Frame?
local progTrack:  Frame?
local statusLbl:  TextLabel?

-- ── Refresh ───────────────────────────────────────────────────────────────────

local function refresh()
	if not activeWorkshopId then return end

	local done       = getResearchedFn and getResearchedFn("BetterMines") or false
	local progress   = getProgressFn   and getProgressFn("BetterMines")   or nil
	local inProgress = progress ~= nil and not done

	-- Button state
	if techBtn then
		local labels: {TextLabel} = {}
		for _, ch in techBtn:GetChildren() do
			if ch:IsA("TextLabel") then table.insert(labels, ch) end
		end
		local nameLbl = #labels >= 1 and labels[1] or nil
		local descLbl = #labels >= 2 and labels[2] or nil
		local costLbl = #labels >= 3 and labels[3] or nil

		if done then
			techBtn.BackgroundColor3       = C.GREEN
			techBtn.BackgroundTransparency = 0.08
			techBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.TEXT;    nameLbl.Text = "BETTER MINES" end
			if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = "Unlocks mine upgrades" end
			if costLbl then costLbl.TextColor3 = C.GREEN;   costLbl.Text = "✓  RESEARCH COMPLETE" end

		elseif inProgress then
			techBtn.BackgroundColor3       = Color3.fromRGB(14, 20, 38)
			techBtn.BackgroundTransparency = 0
			techBtn.Active                 = false
			if nameLbl then nameLbl.TextColor3 = C.ACCENT;  nameLbl.Text = "BETTER MINES" end
			if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = "Unlocks mine upgrades" end
			if costLbl then
				local pct = math.floor((progress :: number) * 100)
				costLbl.TextColor3 = C.ACCENT
				costLbl.Text       = string.format("Researching...  %d%%", pct)
			end

		else
			techBtn.BackgroundColor3       = C.WORKSHOP
			techBtn.BackgroundTransparency = 0.14
			techBtn.Active                 = true
			if nameLbl then nameLbl.TextColor3 = C.TEXT;    nameLbl.Text = "BETTER MINES" end
			if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = "Unlocks mine upgrades" end
			if costLbl then costLbl.TextColor3 = C.GOLD;    costLbl.Text = "Click to research  (5 sec)" end
		end
	end

	-- Progress bar
	if progTrack then
		progTrack.Visible = inProgress or done
	end
	if progFill then
		local t = done and 1 or (progress or 0)
		progFill.Size = UDim2.new(math.clamp(t, 0, 1), 0, 1, 0)
	end

	-- Status
	if statusLbl then
		if done then
			statusLbl.Text = "Mine upgrade panels are now unlocked. Select a mine to upgrade it."
		elseif inProgress then
			statusLbl.Text = "Research in progress..."
		else
			statusLbl.Text = "Click the card above to begin. Takes 5 seconds."
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function WorkshopPanel.init(
	network,
	getResearched: (string) -> boolean,
	getProgress:   (string) -> number?
)
	networkRef      = network
	getResearchedFn = getResearched
	getProgressFn   = getProgress

	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local p = UILib.panel(sg,
		UDim2.fromOffset(370, 172),
		UDim2.new(0.5, -185, 1, -320), 10)
	p.Name    = "WorkshopPanel"
	p.Visible = false
	panel     = p

	UILib.titleBar(p, "WORKSHOP — RESEARCH", function() WorkshopPanel.hide() end, C.WORKSHOP)

	-- Research card (full-width button)
	local btn                  = Instance.new("TextButton")
	btn.Name                   = "TechCard"
	btn.Size                   = UDim2.fromOffset(350, 80)
	btn.Position               = UDim2.fromOffset(10, 42)
	btn.BackgroundColor3       = C.WORKSHOP
	btn.BackgroundTransparency = 0.14
	btn.Text                   = ""
	btn.AutoButtonColor        = true
	btn.BorderSizePixel        = 0
	btn.ZIndex                 = 11
	btn.Parent                 = p
	UILib.corner(btn, 9)
	UILib.stroke(btn, C.BORDER, 1)

	-- Accent bar
	local bar                  = Instance.new("Frame")
	bar.Size                   = UDim2.new(1, -2, 0, 4)
	bar.Position               = UDim2.fromOffset(1, 1)
	bar.BackgroundColor3       = C.WORKSHOP
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = 12
	bar.Parent                 = btn
	UILib.corner(bar, 6)

	UILib.lbl(btn, "BETTER MINES",
		UDim2.fromOffset(330, 20), UDim2.fromOffset(10, 10),
		{ bold = true, size = 14, color = C.TEXT, zIndex = 12 })

	UILib.lbl(btn, "Unlocks mine upgrades",
		UDim2.fromOffset(330, 16), UDim2.fromOffset(10, 34),
		{ size = 12, color = C.SUBTEXT, zIndex = 12 })

	UILib.lbl(btn, "Click to research  (5 sec)",
		UDim2.fromOffset(330, 16), UDim2.fromOffset(10, 56),
		{ size = 11, color = C.GOLD, zIndex = 12 })

	techBtn = btn

	-- Progress bar
	local pb = UILib.progressBar(p,
		UDim2.fromOffset(350, 10), UDim2.fromOffset(10, 130),
		C.WORKSHOP, 11)
	progFill  = pb.fill
	progTrack = pb.track
	pb.track.Visible = false

	-- Status label
	local sLbl = UILib.lbl(p, "Click the card above to begin. Takes 5 seconds.",
		UDim2.fromOffset(350, 28), UDim2.fromOffset(10, 144),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 11 })
	sLbl.Name = "StatusLabel"
	statusLbl  = sLbl

	-- Click handler
	btn.MouseButton1Click:Connect(function()
		if not activeWorkshopId or not btn.Active then return end
		networkRef.startResearch(activeWorkshopId, "BetterMines")
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(workshopId: string)
	activeWorkshopId = workshopId
	if panel then panel.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeWorkshopId = nil
	if panel then panel.Visible = false end
end

function WorkshopPanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refresh() end
end

return WorkshopPanel
