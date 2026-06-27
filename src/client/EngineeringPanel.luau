--!strict
--[[
	EngineeringPanel — info/research panel shown when the player clicks an Engineering
	Post. Offers Light Research (rolls a random combat upgrade after 30s) and Heavy
	Research ("coming soon"). When a research is ready, the post shows a notifier and the
	Light button becomes COLLECT; collecting reveals the discovery in a typewriter popup
	and adds it to the player's global discovery history (listed in the panel).

	Driven by Network.onEngineeringSync(buildingId, payload):
	  payload = { state = "idle"|"researching"|"ready", remaining, history, discovery? }
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))

local EngineeringPanel = {}
local localPlayer      = Players.LocalPlayer
local C                = UILib.C
local ACCENT           = Color3.fromRGB(90, 200, 255)

-- ── State ─────────────────────────────────────────────────────────────────────
local networkRef:   any
local activeId:     string?
local lastPayload:  any

local panel:       Frame?
local lightBtn:    TextButton?
local lightLbl:    TextLabel?
local heavyBtn:    TextButton?
local statusLbl:   TextLabel?
local progFill:    Frame?
local progTrack:   Frame?
local historyList: ScrollingFrame?
local toastLbl:    TextLabel?

-- Typewriter popup
local popup:     Frame?
local popupText: TextLabel?
local typeToken = 0

-- ── History rendering ───────────────────────────────────────────────────────────
local function renderHistory(history: { string })
	local list = historyList
	if not list then return end
	for _, c in list:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	local n = #history
	for i = 1, n do
		-- Newest first
		local text = history[n - i + 1]
		local row = UILib.lbl(list, "• " .. text,
			UDim2.new(1, -8, 0, 18), UDim2.fromOffset(4, (i - 1) * 20),
			{ size = 11, color = C.SUBTEXT, wrap = false, zIndex = 22 })
		row.LayoutOrder = i
	end
	list.CanvasSize = UDim2.new(0, 0, 0, n * 20 + 4)
	if n == 0 then
		UILib.lbl(list, "No discoveries yet.",
			UDim2.new(1, -8, 0, 18), UDim2.fromOffset(4, 0),
			{ size = 11, color = C.DIM, zIndex = 22 })
	end
end

-- ── Typewriter popup ──────────────────────────────────────────────────────────
local function showTypewriter(text: string)
	if not (popup and popupText) then return end
	typeToken += 1
	local myToken = typeToken
	popup.Visible = true
	popupText.Text = ""
	task.spawn(function()
		for i = 1, #text do
			if myToken ~= typeToken or not popupText then return end
			popupText.Text = string.sub(text, 1, i)
			task.wait(0.03)
		end
	end)
end

local function hideTypewriter()
	typeToken += 1
	if popup then popup.Visible = false end
end

-- ── Heavy "coming soon" toast ───────────────────────────────────────────────────
local toastToken = 0
local function showToast(msg: string)
	if not toastLbl then return end
	toastToken += 1
	local my = toastToken
	toastLbl.Text             = msg
	toastLbl.Visible          = true
	toastLbl.TextTransparency = 0
	task.delay(1.6, function()
		if my == toastToken and toastLbl then toastLbl.Visible = false end
	end)
end

-- ── Render the panel from the latest payload ────────────────────────────────────
local function render()
	local p = lastPayload
	if not (p and lightBtn and lightLbl and statusLbl and progFill and progTrack) then return end
	local state = p.state or "idle"

	if state == "researching" then
		local remaining = math.max(0, math.ceil(p.remaining or 0))
		local frac      = 1 - (p.remaining or 0) / Config.ENGINEERING_LIGHT_TIME
		lightBtn.Active            = false
		lightBtn.AutoButtonColor   = false
		lightBtn.BackgroundColor3  = C.BG_LOCKED
		lightLbl.Text              = "RESEARCHING…\n" .. remaining .. "s"
		lightLbl.TextColor3        = C.SUBTEXT
		statusLbl.Text             = "Light research in progress."
		progTrack.Visible          = true
		progFill.Size              = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)

	elseif state == "ready" then
		lightBtn.Active            = true
		lightBtn.AutoButtonColor   = true
		lightBtn.BackgroundColor3  = C.GREEN
		lightLbl.Text              = "COLLECT\nDiscovery ready!"
		lightLbl.TextColor3        = C.TEXT
		statusLbl.Text             = "A discovery is ready — collect it!"
		progTrack.Visible          = false

	else -- idle
		lightBtn.Active            = true
		lightBtn.AutoButtonColor   = true
		lightBtn.BackgroundColor3  = ACCENT
		lightLbl.Text              = string.format("LIGHT RESEARCH\n◆ %d · %ds",
			Config.ENGINEERING_RESEARCH_COST, Config.ENGINEERING_LIGHT_TIME)
		lightLbl.TextColor3        = C.TEXT
		statusLbl.Text             = "Research a random upgrade for one of your unit types."
		progTrack.Visible          = false
	end

	renderHistory(p.history or {})
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function EngineeringPanel.init(network)
	networkRef = network
	local sg = localPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui

	local pn = UILib.panel(sg, UDim2.fromOffset(372, 318), UDim2.new(0.5, -186, 0.5, -180), 30)
	pn.Visible = false
	pn.Active  = true   -- absorb clicks so the panel background doesn't deselect the post
	panel = pn
	UILib.titleBar(pn, "ENGINEERING POST", function() EngineeringPanel.hide() end, ACCENT)

	-- Light / Heavy buttons
	local lb = UILib.btn(pn, "", UDim2.fromOffset(168, 56), UDim2.fromOffset(12, 44), ACCENT, 32)
	lightBtn = lb
	lightLbl = UILib.lbl(lb, "", UDim2.new(1, -8, 1, -6), UDim2.fromOffset(4, 3),
		{ size = 12, bold = true, align = Enum.TextXAlignment.Center, wrap = true, zIndex = 33 })
	lightLbl.TextYAlignment = Enum.TextYAlignment.Center
	lb.MouseButton1Click:Connect(function()
		if not activeId or not lightBtn or not lightBtn.Active then return end
		local state = lastPayload and lastPayload.state or "idle"
		if state == "ready" then
			networkRef.engineeringCollect(activeId)
		elseif state == "idle" then
			networkRef.engineeringStart(activeId)
		end
	end)

	local hb = UILib.btn(pn, "HEAVY RESEARCH", UDim2.fromOffset(168, 56), UDim2.fromOffset(192, 44), C.BG_CARD, 32)
	heavyBtn = hb
	hb.MouseButton1Click:Connect(function()
		showToast("Heavy research — coming soon")
	end)

	-- Status line
	statusLbl = UILib.lbl(pn, "", UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 106),
		{ size = 11, color = C.SUBTEXT, wrap = true, zIndex = 32 })

	-- Progress bar (shown while researching)
	local pb = UILib.progressBar(pn, UDim2.new(1, -24, 0, 4), UDim2.fromOffset(12, 138), ACCENT)
	progTrack = pb.track
	progFill  = pb.fill
	pb.track.ZIndex = 32
	pb.fill.ZIndex  = 33
	pb.track.Visible = false

	-- History header + scroll list
	UILib.lbl(pn, "DISCOVERY LOG", UDim2.new(1, -24, 0, 16), UDim2.fromOffset(12, 154),
		{ size = 11, bold = true, color = ACCENT, zIndex = 32 })

	local sf                  = Instance.new("ScrollingFrame")
	sf.Name                   = "History"
	sf.Size                   = UDim2.new(1, -24, 1, -188)
	sf.Position               = UDim2.fromOffset(12, 174)
	sf.BackgroundColor3       = C.FILL_BG
	sf.BackgroundTransparency = 0.2
	sf.BorderSizePixel        = 0
	sf.ScrollBarThickness     = 4
	sf.CanvasSize             = UDim2.new(0, 0, 0, 0)
	sf.ZIndex                 = 32
	sf.Parent                 = pn
	UILib.corner(sf, 6)
	historyList = sf

	-- Heavy "coming soon" toast
	toastLbl = UILib.lbl(pn, "", UDim2.new(1, -24, 0, 18), UDim2.fromOffset(12, 296),
		{ size = 12, bold = true, color = C.GOLD, align = Enum.TextXAlignment.Center, zIndex = 34 })
	toastLbl.Visible = false

	-- ── Typewriter reveal popup (separate overlay) ─────────────────────────────
	local ov                  = Instance.new("Frame")
	ov.Name                   = "EngDiscovery"
	ov.Size                   = UDim2.new(1, 0, 1, 0)
	ov.BackgroundColor3       = Color3.new(0, 0, 0)
	ov.BackgroundTransparency = 0.45
	ov.BorderSizePixel        = 0
	ov.ZIndex                 = 60
	ov.Visible                = false
	ov.Active                 = true   -- modal: block clicks to the world while revealing
	ov.Parent                 = sg
	popup = ov

	local card = UILib.panel(ov, UDim2.fromOffset(420, 180), UDim2.new(0.5, -210, 0.5, -90), 61)
	UILib.titleBar(card, "RESEARCH BREAKTHROUGH", function() hideTypewriter() end, ACCENT)
	popupText = UILib.lbl(card, "", UDim2.new(1, -28, 1, -56), UDim2.fromOffset(14, 46),
		{ size = 16, bold = true, color = C.TEXT, wrap = true, align = Enum.TextXAlignment.Center, zIndex = 63 })
	popupText.TextYAlignment = Enum.TextYAlignment.Center
end

-- ── Public API ────────────────────────────────────────────────────────────────
function EngineeringPanel.show(buildingId: string)
	activeId    = buildingId
	lastPayload = { state = "idle", remaining = 0, history = {} }
	if panel then panel.Visible = true end
	render()
	if networkRef then networkRef.engineeringRequest(buildingId) end
end

function EngineeringPanel.hide()
	activeId = nil
	hideTypewriter()
	if panel then panel.Visible = false end
end

-- Called from init.client when an EngineeringSync arrives.
function EngineeringPanel.applySync(buildingId: string, payload: any)
	if buildingId ~= activeId then return end
	lastPayload = payload
	render()
	if payload and type(payload.discovery) == "string" then
		showTypewriter(payload.discovery)
	end
end

function EngineeringPanel.refreshIfVisible() end

return EngineeringPanel
