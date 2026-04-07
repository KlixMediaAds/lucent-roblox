local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UILib             = require(script.Parent:WaitForChild("UILib"))

local WorkshopPanel     = {}
local localPlayer       = Players.LocalPlayer
local C                 = UILib.C

local panel:       Frame?
local activeCCId:  string? = nil
local networkRef:  any
local getResearchedFn:  ((string) -> boolean)?
local getProgressFn:    ((string) -> number?)?

-- Per-tech UI refs
type TechRefs = {
	btn:      TextButton,
	progFill: Frame,
	progTrack: Frame,
}

local techRefs: { [string]: TechRefs } = {}
local statusLbl: TextLabel?

-- ── Research card builder ─────────────────────────────────────────────────────

local function makeTechCard(
	parent:   Instance,
	techKey:  string,
	name:     string,
	desc:     string,
	position: UDim2
): TechRefs
	local btn                  = Instance.new("TextButton")
	btn.Name                   = techKey .. "Card"
	btn.Size                   = UDim2.fromOffset(350, 68)
	btn.Position               = position
	btn.BackgroundColor3       = C.TEAL
	btn.BackgroundTransparency = 0.14
	btn.Text                   = ""
	btn.AutoButtonColor        = true
	btn.BorderSizePixel        = 0
	btn.ZIndex                 = 11
	btn.Parent                 = parent
	UILib.corner(btn, 9)
	UILib.stroke(btn, C.BORDER, 1)

	local bar                  = Instance.new("Frame")
	bar.Size                   = UDim2.new(1, -2, 0, 4)
	bar.Position               = UDim2.fromOffset(1, 1)
	bar.BackgroundColor3       = C.TEAL
	bar.BorderSizePixel        = 0
	bar.ZIndex                 = 12
	bar.Parent                 = btn
	UILib.corner(bar, 6)

	UILib.lbl(btn, name:upper(),
		UDim2.fromOffset(330, 18), UDim2.fromOffset(10, 8),
		{ bold = true, size = 13, color = C.TEXT, zIndex = 12 })

	UILib.lbl(btn, desc,
		UDim2.fromOffset(330, 14), UDim2.fromOffset(10, 28),
		{ size = 11, color = C.SUBTEXT, zIndex = 12 })

	UILib.lbl(btn, "Click to research",
		UDim2.fromOffset(330, 14), UDim2.fromOffset(10, 48),
		{ size = 11, color = C.GOLD, zIndex = 12 })

	-- Inline mini progress bar
	local pb = UILib.progressBar(parent,
		UDim2.fromOffset(350, 6),
		UDim2.new(position.X.Scale, position.X.Offset, position.Y.Scale, position.Y.Offset + 70),
		C.TEAL, 11)
	pb.track.Visible = false

	btn.MouseButton1Click:Connect(function()
		if not activeCCId or not btn.Active then return end
		networkRef.startResearch(activeCCId, techKey)
	end)

	return { btn = btn, progFill = pb.fill, progTrack = pb.track }
end

-- ── Refresh a single tech card ────────────────────────────────────────────────

local function refreshCard(techKey: string, name: string, desc: string)
	local refs = techRefs[techKey]
	if not refs then return end
	local btn      = refs.btn
	local done     = getResearchedFn and getResearchedFn(techKey) or false
	local progress = getProgressFn   and getProgressFn(techKey)   or nil
	local inProg   = progress ~= nil and not done

	local labels: {TextLabel} = {}
	for _, ch in btn:GetChildren() do
		if ch:IsA("TextLabel") then table.insert(labels, ch) end
	end
	local nameLbl = labels[1]
	local descLbl = labels[2]
	local costLbl = labels[3]

	if done then
		btn.BackgroundColor3       = C.GREEN
		btn.BackgroundTransparency = 0.08
		btn.Active                 = false
		if nameLbl then nameLbl.TextColor3 = C.TEXT;    nameLbl.Text = name:upper() end
		if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = desc end
		if costLbl then costLbl.TextColor3 = C.GREEN;   costLbl.Text = "✓  RESEARCH COMPLETE" end

	elseif inProg then
		btn.BackgroundColor3       = Color3.fromRGB(14, 20, 38)
		btn.BackgroundTransparency = 0
		btn.Active                 = false
		if nameLbl then nameLbl.TextColor3 = C.ACCENT;  nameLbl.Text = name:upper() end
		if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = desc end
		if costLbl then
			local pct = math.floor((progress :: number) * 100)
			costLbl.TextColor3 = C.ACCENT
			costLbl.Text       = string.format("Researching...  %d%%", pct)
		end

	else
		btn.BackgroundColor3       = C.TEAL
		btn.BackgroundTransparency = 0.14
		btn.Active                 = true
		if nameLbl then nameLbl.TextColor3 = C.TEXT;    nameLbl.Text = name:upper() end
		if descLbl then descLbl.TextColor3 = C.SUBTEXT; descLbl.Text = desc end
		if costLbl then costLbl.TextColor3 = C.GOLD;    costLbl.Text = "Click to research" end
	end

	if refs.progTrack then refs.progTrack.Visible = inProg or done end
	if refs.progFill  then
		local t = done and 1 or (progress or 0)
		refs.progFill.Size = UDim2.new(math.clamp(t, 0, 1), 0, 1, 0)
	end
end

local TECHS = {
	{ key = "BetterMines", name = "Better Mines",  desc = "Unlocks mine upgrades." },
	{ key = "EliteUnits",  name = "Elite Units",   desc = "Unlocks the Elite unit at Barracks." },
}

local function refresh()
	if not activeCCId then return end
	for _, t in TECHS do
		refreshCard(t.key, t.name, t.desc)
	end

	if statusLbl then
		local anyInProg = false
		for _, t in TECHS do
			local p = getProgressFn and getProgressFn(t.key)
			local d = getResearchedFn and getResearchedFn(t.key)
			if p ~= nil and not d then anyInProg = true; break end
		end
		if anyInProg then
			statusLbl.Text = "Research in progress..."
		else
			statusLbl.Text = "Click a card above to begin research."
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

	-- Panel tall enough for 2 cards + status
	local p = UILib.panel(sg,
		UDim2.fromOffset(370, 230),
		UDim2.new(0.5, -185, 1, -378), 10)
	p.Name    = "WorkshopPanel"
	p.Visible = false
	panel     = p

	UILib.titleBar(p, "COMMAND CENTER — RESEARCH", function() WorkshopPanel.hide() end, C.TEAL)

	-- Card 1: Better Mines  (y=42)
	techRefs["BetterMines"] = makeTechCard(p, "BetterMines", "Better Mines",
		"Unlocks mine upgrades.", UDim2.fromOffset(10, 42))

	-- Card 2: Elite Units  (y=122)
	techRefs["EliteUnits"] = makeTechCard(p, "EliteUnits", "Elite Units",
		"Unlocks the Elite unit at Barracks.", UDim2.fromOffset(10, 122))

	-- Status label
	local sLbl = UILib.lbl(p, "Click a card above to begin research.",
		UDim2.fromOffset(350, 24), UDim2.fromOffset(10, 200),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 11 })
	sLbl.Name = "StatusLabel"
	statusLbl  = sLbl
end

-- ── Public API ────────────────────────────────────────────────────────────────

function WorkshopPanel.show(ccId: string)
	activeCCId = ccId
	if panel then panel.Visible = true end
	refresh()
end

function WorkshopPanel.hide()
	activeCCId = nil
	if panel then panel.Visible = false end
end

function WorkshopPanel.refreshIfVisible()
	if panel and (panel :: Frame).Visible then refresh() end
end

return WorkshopPanel
