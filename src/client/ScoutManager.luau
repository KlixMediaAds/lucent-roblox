--[[
	ScoutManager — army master-control panel.

	A persistent command icon sits just above the minimap (bottom-right) showing a
	3D portrait of the player's most expensive owned unit. It appears whenever the
	player owns at least one unit. Clicking it opens a small collapsible menu above
	with three one-button army commands:

	  • SCOUT  — every unit roams the fog of war hunting for the enemy. When an enemy
	             STRUCTURE is first revealed, the army falls back to the nearest
	             Command Center, an alert card slides in, and a crosshair forms on
	             the minimap where it was found.
	  • ATTACK — the whole army attack-moves toward the nearest known enemy structure
	             (or pushes into enemy territory if none has been spotted yet).
	  • DEFEND — analyses the player's buildings, finds the outer perimeter of the
	             base, and posts units around it. A third of them patrol the
	             perimeter loop; the rest hold their posts. All stay vigilant — the
	             unit aggro system engages any enemy that wanders into range.

	Everything is client-side and reuses the existing move / attack-move plumbing.
]]

local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")
local SoundService  = game:GetService("SoundService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))

local ScoutManager = {}
local C = UILib.C

local localPlayer = Players.LocalPlayer
local localUserId = localPlayer.UserId
local myStr       = tostring(localUserId)

-- ── Injected refs ─────────────────────────────────────────────────────────────
local network:    any
local fogManager: any
local miniMap:    any

-- ── Tunables ──────────────────────────────────────────────────────────────────
local SCOUT_TICK     = 2.0   -- s between scout re-assignment passes
local ATTACK_TICK    = 5.0   -- s between attack re-pushes
local DEFEND_TICK    = 2.0   -- s between defend maintenance passes
local ARRIVE_DIST    = 14    -- studs; "arrived" tolerance
local REASSIGN_AFTER = 9     -- s; force a fresh scout target if stalled
local DEFEND_POST_OFFSET = 14   -- studs a guard stands outside its building
local DEFEND_RECALL      = 32   -- studs from post before a guard is recalled
local PATROL_DWELL       = 5    -- s a patroller waits before advancing
local PATROL_EVERY       = 3    -- every Nth unit patrols instead of holding
local MOVE_BOUND         = 420  -- map half-extent clamp for blind pushes

-- ── State ─────────────────────────────────────────────────────────────────────
type Scout  = { part: BasePart, target: Vector3?, assignedAt: number }
type Defend = { postIdx: number, patrol: boolean, idx: number, lastAdvance: number }

local ownUnits: { [string]: BasePart } = {}
local currentMode: string? = nil   -- "scout" | "attack" | "defend" | nil
local modeLoopId  = 0              -- bump to cancel running mode loops
local enemyFound  = false         -- ATTACK unlocks once an enemy structure is seen

local scouts:       { [string]: Scout }  = {}
local defendAssign: { [string]: Defend } = {}
local defendPosts:    { Vector3 } = {}
local defendCentroid: Vector3     = Vector3.zero

local activeCard: Frame? = nil

-- UI refs (populated in createPanel)
local panelGui:   ScreenGui?  = nil
local iconBtn:    TextButton?  = nil
local iconRing:   UIStroke?    = nil
local iconHolder: Frame?       = nil
local menuFrame:  Frame?       = nil
local menuOpen   = false
local currentIconType: string? = nil
type ModeBtn = { btn: TextButton, stroke: UIStroke, color: Color3, lbl: TextLabel, accent: Frame }
local modeButtons: { [string]: ModeBtn } = {}

local ICON        = 46
local ICON_RIGHT  = 10
local ICON_BOTTOM = 202   -- minimap span (180+4 border +10 pad) + 8 gap

-- ── Generic helpers ────────────────────────────────────────────────────────────

local function getScreenGui(): ScreenGui?
	local pg = localPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	return pg:FindFirstChild("RTSHUD") :: ScreenGui?
end

local function playSound(id: number, volume: number)
	local s   = Instance.new("Sound")
	s.SoundId = "rbxassetid://" .. id
	s.Volume  = volume
	s.Parent  = SoundService
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
end

local function unitTypeOf(part: BasePart): string
	local tv = part:FindFirstChild("UnitType") :: StringValue?
	return (tv and tv.Value) or "Soldier"
end

local function unitCost(unitType: string): number
	local info = Config.UNIT_TYPES[unitType]
	return (info and info.cost) or 0
end

-- Most expensive owned unit type (for the command icon portrait), or nil.
local function topUnitType(): string?
	local bestType: string?, bestCost = nil, -1
	for _, part in ownUnits do
		if not part.Parent then continue end
		local t = unitTypeOf(part)
		local c = unitCost(t)
		if c > bestCost then bestCost = c; bestType = t end
	end
	return bestType
end

local function ownUnitIds(): { string }
	local ids: { string } = {}
	for id, part in ownUnits do
		if part.Parent then ids[#ids + 1] = id end
	end
	return ids
end

local function armyCentroid(): Vector3?
	local sum, n = Vector3.zero, 0
	for _, part in ownUnits do
		if part.Parent then sum += part.Position; n += 1 end
	end
	if n == 0 then return nil end
	return sum / n
end

local function nearestOwnCC(point: Vector3): Vector3?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local best: Vector3?, bestD = nil, math.huge
	for _, model in bf:GetChildren() do
		local ov  = model:FindFirstChild("OwnerId")      :: StringValue?
		local btv = model:FindFirstChild("BuildingType") :: StringValue?
		if not ov or not btv then continue end
		if ov.Value ~= myStr or btv.Value ~= "CommandCenter" then continue end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base then continue end
		local d = (base.Position - point).Magnitude
		if d < bestD then bestD = d; best = base.Position end
	end
	return best
end

-- ── Comms / alert card (kept from the original scout flow) ─────────────────────

local CARD_W = 320
local CARD_H = 124
local SLIDE_IN  = TweenInfo.new(0.30, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function cardHidden(): UDim2 return UDim2.new(0, -(CARD_W + 30), 0.5, -20) end
local function cardShown():  UDim2 return UDim2.new(0, 18,            0.5, -20) end

local function dismissCard()
	local card = activeCard
	if not card then return end
	activeCard = nil
	TweenService:Create(card, SLIDE_OUT, { Position = cardHidden() }):Play()
	task.delay(SLIDE_OUT.Time + 0.05, function()
		if card.Parent then card:Destroy() end
	end)
end

local function showAlert(accent: Color3, unitType: string, header: string, body: string)
	local sg = getScreenGui()
	if not sg then return end
	if activeCard then activeCard:Destroy(); activeCard = nil end

	local card                  = Instance.new("Frame")
	card.Name                   = "ArmyAlertCard"
	card.Size                   = UDim2.fromOffset(CARD_W, CARD_H)
	card.AnchorPoint            = Vector2.new(0, 0.5)
	card.Position               = cardHidden()
	card.BackgroundColor3       = Color3.fromRGB(7, 9, 22)
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel        = 0
	card.ZIndex                 = 120
	card.Parent                 = sg
	UILib.corner(card, 12)
	UILib.stroke(card, accent, 1.8)

	local stripe            = Instance.new("Frame")
	stripe.Size             = UDim2.new(0, 3, 1, -18)
	stripe.Position         = UDim2.fromOffset(7, 9)
	stripe.BackgroundColor3 = accent
	stripe.BorderSizePixel  = 0
	stripe.ZIndex           = 121
	stripe.Parent           = card
	UILib.corner(stripe, 2)

	local PORT = 84
	local holder                = Instance.new("Frame")
	holder.Size                 = UDim2.fromOffset(PORT, PORT)
	holder.Position             = UDim2.fromOffset(16, (CARD_H - PORT) / 2)
	holder.BackgroundColor3     = Color3.fromRGB(13, 18, 34)
	holder.BorderSizePixel      = 0
	holder.ZIndex               = 121
	holder.Parent               = card
	UILib.corner(holder, 10)
	UILib.stroke(holder, accent, 1.2)

	local vpf = ViewportPreview.forUnit(unitType, Vector2.new(PORT - 8, PORT - 8), localPlayer.TeamColor)
	vpf.Position = UDim2.fromOffset(4, 4)
	vpf.ZIndex   = 122
	vpf.Parent   = holder

	local contentX = 16 + PORT + 12

	local hdr                   = Instance.new("TextLabel")
	hdr.Size                    = UDim2.fromOffset(CARD_W - contentX - 14, 16)
	hdr.Position                = UDim2.fromOffset(contentX, 16)
	hdr.BackgroundTransparency  = 1
	hdr.Font                    = Enum.Font.GothamBold
	hdr.TextSize                = 11
	hdr.TextColor3              = accent
	hdr.TextXAlignment          = Enum.TextXAlignment.Left
	hdr.Text                    = header
	hdr.ZIndex                  = 122
	hdr.Parent                  = card

	local bodyLbl               = Instance.new("TextLabel")
	bodyLbl.Size                = UDim2.fromOffset(CARD_W - contentX - 14, 64)
	bodyLbl.Position            = UDim2.fromOffset(contentX, 34)
	bodyLbl.BackgroundTransparency = 1
	bodyLbl.Font                = Enum.Font.GothamBold
	bodyLbl.TextSize            = 16
	bodyLbl.TextColor3          = C.TEXT
	bodyLbl.TextXAlignment      = Enum.TextXAlignment.Left
	bodyLbl.TextYAlignment      = Enum.TextYAlignment.Top
	bodyLbl.TextWrapped         = true
	bodyLbl.Text                = body
	bodyLbl.ZIndex              = 122
	bodyLbl.Parent              = card

	local clickCatcher                  = Instance.new("TextButton")
	clickCatcher.Size                   = UDim2.new(1, 0, 1, 0)
	clickCatcher.BackgroundTransparency = 1
	clickCatcher.Text                   = ""
	clickCatcher.ZIndex                 = 123
	clickCatcher.Parent                 = card
	clickCatcher.MouseButton1Click:Connect(dismissCard)

	activeCard = card
	TweenService:Create(card, SLIDE_IN, { Position = cardShown() }):Play()
	playSound(104003605923230, 0.55)

	task.delay(5, function()
		if activeCard == card then dismissCard() end
	end)
end

-- ── Mode loop runner ────────────────────────────────────────────────────────────

local function startModeLoop(mode: string, tickFn: () -> (), interval: number)
	modeLoopId += 1
	local myId = modeLoopId
	task.spawn(function()
		while currentMode == mode and modeLoopId == myId do
			tickFn()
			task.wait(interval)
		end
	end)
end

-- ── SCOUT ───────────────────────────────────────────────────────────────────────

local function assignScout(id: string, s: Scout)
	local target = fogManager.pickScoutTarget(s.part.Position)
	if not target then return end
	s.target     = target
	s.assignedAt = os.clock()
	network.moveUnits({ id }, target)
end

local function enlistScout(id: string, part: BasePart)
	if scouts[id] then return end
	local s: Scout = { part = part, target = nil, assignedAt = 0 }
	scouts[id] = s
	assignScout(id, s)
end

local function scoutPass()
	-- Enlist any newly-spawned units not yet scouting (so new units join the scout
	-- without the player re-clicking the army control).
	for id, part in ownUnits do
		if part.Parent and not scouts[id] then enlistScout(id, part) end
	end
	for id, s in scouts do
		if not s.part.Parent then scouts[id] = nil; continue end
		local now      = os.clock()
		local arrived  = s.target ~= nil and (s.part.Position - s.target).Magnitude <= ARRIVE_DIST
		local explored = s.target ~= nil and fogManager.isExplored(s.target)
		local stalled  = (now - s.assignedAt) >= REASSIGN_AFTER
		if s.target == nil or arrived or explored or stalled then
			assignScout(id, s)
		end
	end
end

local function beginScout()
	for id, part in ownUnits do enlistScout(id, part) end
	startModeLoop("scout", scoutPass, SCOUT_TICK)
end

-- ── ATTACK ──────────────────────────────────────────────────────────────────────

-- Nearest enemy building we currently have intel on (not fully fogged).
local function nearestKnownEnemyBuilding(point: Vector3): Vector3?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local best: Vector3?, bestD = nil, math.huge
	for _, model in bf:GetChildren() do
		local ov = model:FindFirstChild("OwnerId") :: StringValue?
		if not ov or ov.Value == myStr then continue end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base or not base:IsA("BasePart") then continue end
		if base.LocalTransparencyModifier >= 1 then continue end  -- fully hidden by fog
		local d = (base.Position - point).Magnitude
		if d < bestD then bestD = d; best = base.Position end
	end
	return best
end

local function currentAttackTarget(): Vector3?
	local centroid = armyCentroid()
	if not centroid then return nil end
	local known = nearestKnownEnemyBuilding(centroid)
	if known then return known end
	-- No intel: push toward the opposite side of the map from our base.
	local base = nearestOwnCC(centroid) or centroid
	return Vector3.new(
		math.clamp(-base.X * 1.5, -MOVE_BOUND, MOVE_BOUND),
		0,
		math.clamp(-base.Z * 1.5, -MOVE_BOUND, MOVE_BOUND)
	)
end

local function attackPass()
	local tgt = currentAttackTarget()
	if not tgt then return end
	local ids = ownUnitIds()
	if #ids > 0 then network.attackMoveUnits(ids, tgt) end
end

local function beginAttack()
	attackPass()
	startModeLoop("attack", attackPass, ATTACK_TICK)
end

-- ── DEFEND ──────────────────────────────────────────────────────────────────────

local function ownBuildingPositions(): { Vector3 }
	local out: { Vector3 } = {}
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return out end
	for _, model in bf:GetChildren() do
		local ov = model:FindFirstChild("OwnerId") :: StringValue?
		if not ov or ov.Value ~= myStr then continue end
		local base = model:FindFirstChild("Base") :: BasePart?
		if base and base:IsA("BasePart") then
			out[#out + 1] = Vector3.new(base.Position.X, 0, base.Position.Z)
		end
	end
	return out
end

-- Perimeter guard posts: the outer ring of the base, each pushed a little outward
-- from the centre so guards face likely enemy approaches. Falls back to a ring
-- around the centroid when there are too few outlying buildings to spread units.
local function computePerimeterPosts(): ({ Vector3 }, Vector3)
	local blds = ownBuildingPositions()
	if #blds == 0 then return {}, Vector3.zero end

	local sum = Vector3.zero
	for _, p in blds do sum += p end
	local centroid = sum / #blds

	local maxD = 0
	for _, p in blds do maxD = math.max(maxD, (p - centroid).Magnitude) end

	local posts: { Vector3 } = {}
	local thresh = maxD * 0.55
	for _, p in blds do
		local d = (p - centroid).Magnitude
		if d >= thresh then
			local dir = d > 1e-3 and (p - centroid) / d or Vector3.new(1, 0, 0)
			posts[#posts + 1] = p + dir * DEFEND_POST_OFFSET
		end
	end

	if #posts < 4 then
		local R = (maxD > 5 and maxD or 28) + DEFEND_POST_OFFSET
		for k = 0, 7 do
			local ang = k * math.pi / 4
			posts[#posts + 1] = centroid + Vector3.new(math.cos(ang), 0, math.sin(ang)) * R
		end
	end

	-- Order posts around the perimeter so a patrol route flows cleanly.
	table.sort(posts, function(a, b)
		return math.atan2(a.Z - centroid.Z, a.X - centroid.X)
			 < math.atan2(b.Z - centroid.Z, b.X - centroid.X)
	end)
	return posts, centroid
end

local function assignDefend(id: string, postIdx: number, patrol: boolean)
	defendAssign[id] = { postIdx = postIdx, patrol = patrol, idx = postIdx, lastAdvance = os.clock() }
	local post = defendPosts[postIdx]
	if post then network.attackMoveUnits({ id }, post) end
end

local function defendPass()
	local now = os.clock()
	-- Pick up any newly-spawned units not yet assigned a post (so new units defend
	-- without the player re-clicking the army control).
	if #defendPosts > 0 then
		for id, part in ownUnits do
			if part.Parent and not defendAssign[id] then
				local bestIdx, bestD = 1, math.huge
				for i, post in defendPosts do
					local d = (part.Position - post).Magnitude
					if d < bestD then bestD = d; bestIdx = i end
				end
				assignDefend(id, bestIdx, false)
			end
		end
	end
	for id, a in defendAssign do
		local part = ownUnits[id]
		if not part or not part.Parent then defendAssign[id] = nil; continue end
		if #defendPosts == 0 then continue end
		if a.patrol then
			local wp = defendPosts[a.idx] or defendPosts[1]
			if (part.Position - wp).Magnitude <= ARRIVE_DIST or (now - a.lastAdvance) >= PATROL_DWELL then
				a.idx = (a.idx % #defendPosts) + 1
				a.lastAdvance = now
				network.attackMoveUnits({ id }, defendPosts[a.idx])
			end
		else
			local post = defendPosts[a.postIdx]
			if post and (part.Position - post).Magnitude > DEFEND_RECALL then
				network.attackMoveUnits({ id }, post)
			end
		end
	end
end

local function beginDefend()
	local posts, centroid = computePerimeterPosts()
	if #posts == 0 then return end
	defendPosts    = posts
	defendCentroid = centroid

	local ids   = ownUnitIds()
	local nPost = #posts
	local cap   = math.max(1, math.ceil(#ids / nPost))
	local counts = table.create(nPost, 0)

	local k = 0
	for _, id in ids do
		local part = ownUnits[id]
		if not part then continue end
		k += 1
		-- nearest post that still has capacity
		local bestIdx, bestD = 1, math.huge
		for i, post in posts do
			if counts[i] >= cap then continue end
			local d = (part.Position - post).Magnitude
			if d < bestD then bestD = d; bestIdx = i end
		end
		counts[bestIdx] += 1
		assignDefend(id, bestIdx, k % PATROL_EVERY == 0)
	end
	startModeLoop("defend", defendPass, DEFEND_TICK)
end

-- ── Mode switching ───────────────────────────────────────────────────────────────

local updatePanel  -- forward (defined with the UI)

local function clearModeAssignments()
	scouts       = {}
	defendAssign = {}
	defendPosts  = {}
end

local function stopMode()
	currentMode = nil
	modeLoopId += 1          -- cancels any running loop
	clearModeAssignments()
	if updatePanel then updatePanel() end
end

local function setMode(mode: string)
	if mode == "attack" and not enemyFound then return end  -- locked until enemy found
	if currentMode == mode then stopMode(); return end
	modeLoopId += 1          -- kill the previous mode's loop
	clearModeAssignments()
	currentMode = mode
	if     mode == "scout"  then beginScout()
	elseif mode == "attack" then beginAttack()
	elseif mode == "defend" then beginDefend()
	end
	if updatePanel then updatePanel() end
end

-- Enemy structure spotted during a scout: rally home and raise the alert.
local function onEnemyStructureFound(worldPos: Vector3)
	if currentMode ~= "scout" then return end

	local reportType = "Soldier"
	for _, s in scouts do
		if s.part.Parent then reportType = unitTypeOf(s.part); break end
	end

	local ids = ownUnitIds()
	if #ids > 0 then
		local centroid = armyCentroid() or workspace.CurrentCamera.CFrame.Position
		local cc = nearestOwnCC(centroid)
		if cc then network.moveUnits(ids, cc) end
	end

	stopMode()
	miniMap.markEnemyStructure(worldPos)
	showAlert(C.RED, reportType, "⚠  ENEMY DISCOVERED", "Enemy structure found! Army is falling back to base.")
end

-- ── New unit incorporation ──────────────────────────────────────────────────────

local function incorporateNewUnit(id: string, part: BasePart)
	if currentMode == "scout" then
		enlistScout(id, part)
	elseif currentMode == "attack" then
		local tgt = currentAttackTarget()
		if tgt then network.attackMoveUnits({ id }, tgt) end
	elseif currentMode == "defend" then
		if #defendPosts == 0 then
			local posts, centroid = computePerimeterPosts()
			defendPosts = posts; defendCentroid = centroid
		end
		if #defendPosts > 0 then
			local bestIdx, bestD = 1, math.huge
			for i, post in defendPosts do
				local d = (part.Position - post).Magnitude
				if d < bestD then bestD = d; bestIdx = i end
			end
			assignDefend(id, bestIdx, false)
		end
	end
end

-- ── Command panel UI ─────────────────────────────────────────────────────────────

local MODE_COLORS = { scout = C.ACCENT, attack = C.RED, defend = C.GREEN }

-- ATTACK is unavailable until the enemy has been located.
local function modeLocked(mode: string): boolean
	return mode == "attack" and not enemyFound
end

function updatePanel()
	if iconRing then
		iconRing.Color = currentMode and MODE_COLORS[currentMode] or C.BORDER
	end
	for mode, m in modeButtons do
		local active = currentMode == mode
		if modeLocked(mode) then
			m.btn.BackgroundColor3       = C.BG_LOCKED
			m.btn.BackgroundTransparency = 0.1
			m.stroke.Color               = C.BORDER_LO
			m.stroke.Thickness           = 1
			m.lbl.TextColor3             = C.DIM
			m.lbl.Text                   = "ATTACK  🔒"
			m.accent.BackgroundColor3    = C.DIM
		else
			m.btn.BackgroundColor3       = active and m.color or C.BG_CARD
			m.btn.BackgroundTransparency = active and 0.12 or 0
			m.stroke.Color               = m.color
			m.stroke.Thickness           = active and 2.5 or 1.4
			m.lbl.TextColor3             = C.TEXT
			m.lbl.Text                   = string.upper(mode)
			m.accent.BackgroundColor3    = m.color
		end
	end
end

local function refreshIcon()
	if not iconBtn then return end
	local t = topUnitType()
	if not t then
		iconBtn.Visible = false
		if menuFrame then menuFrame.Visible = false end
		menuOpen = false
		return
	end
	iconBtn.Visible = true
	if t ~= currentIconType and iconHolder then
		currentIconType = t
		iconHolder:ClearAllChildren()
		local vpf = ViewportPreview.forUnit(t, Vector2.new(ICON - 6, ICON - 6), localPlayer.TeamColor)
		vpf.Size     = UDim2.new(1, 0, 1, 0)
		vpf.Position = UDim2.fromOffset(0, 0)
		vpf.ZIndex   = 52
		vpf.Parent   = iconHolder
	end
end

local function makeModeButton(parent: Frame, mode: string, label: string, color: Color3, order: number)
	local b                  = Instance.new("TextButton")
	b.Name                   = mode .. "Btn"
	b.Size                   = UDim2.fromOffset(132, 32)
	b.BackgroundColor3       = C.BG_CARD
	b.AutoButtonColor        = false
	b.Text                   = ""
	b.LayoutOrder            = order
	b.ZIndex                 = 51
	b.Parent                 = parent
	UILib.corner(b, 8)
	local st = UILib.stroke(b, color, 1.4)

	local accent            = Instance.new("Frame")
	accent.Size             = UDim2.new(0, 3, 1, -10)
	accent.Position         = UDim2.fromOffset(6, 5)
	accent.BackgroundColor3 = color
	accent.BorderSizePixel  = 0
	accent.ZIndex           = 52
	accent.Parent           = b
	UILib.corner(accent, 2)

	local lbl                   = Instance.new("TextLabel")
	lbl.Size                    = UDim2.new(1, -18, 1, 0)
	lbl.Position                = UDim2.fromOffset(16, 0)
	lbl.BackgroundTransparency  = 1
	lbl.Font                    = Enum.Font.GothamBold
	lbl.TextSize                = 13
	lbl.TextColor3              = C.TEXT
	lbl.TextXAlignment          = Enum.TextXAlignment.Left
	lbl.Text                    = label
	lbl.ZIndex                  = 52
	lbl.Parent                  = b

	b.MouseButton1Click:Connect(function() setMode(mode) end)
	modeButtons[mode] = { btn = b, stroke = st, color = color, lbl = lbl, accent = accent }
end

local function createPanel()
	local pg = localPlayer:WaitForChild("PlayerGui")

	local sg              = Instance.new("ScreenGui")
	sg.Name              = "UnitCommandGui"
	sg.ResetOnSpawn      = false
	sg.IgnoreGuiInset    = true
	sg.DisplayOrder      = 8
	sg.ZIndexBehavior    = Enum.ZIndexBehavior.Sibling
	sg.Parent            = pg
	panelGui = sg

	-- Collapsible menu (above the icon)
	local menu               = Instance.new("Frame")
	menu.Name                = "CommandMenu"
	menu.AnchorPoint         = Vector2.new(1, 1)
	menu.Position            = UDim2.new(1, -ICON_RIGHT, 1, -(ICON_BOTTOM + ICON + 6))
	menu.Size                = UDim2.fromOffset(132, 32 * 3 + 6 * 2)
	menu.BackgroundTransparency = 1
	menu.Visible             = false
	menu.ZIndex              = 50
	menu.Parent              = sg
	local layout             = Instance.new("UIListLayout")
	layout.FillDirection       = Enum.FillDirection.Vertical
	layout.VerticalAlignment   = Enum.VerticalAlignment.Bottom
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding             = UDim.new(0, 6)
	layout.SortOrder           = Enum.SortOrder.LayoutOrder
	layout.Parent              = menu
	menuFrame = menu

	makeModeButton(menu, "scout",  "SCOUT",  C.ACCENT, 1)
	makeModeButton(menu, "attack", "ATTACK", C.RED,    2)
	makeModeButton(menu, "defend", "DEFEND", C.GREEN,  3)

	-- Command icon
	local btn                 = Instance.new("TextButton")
	btn.Name                  = "CommandIcon"
	btn.Size                  = UDim2.fromOffset(ICON, ICON)
	btn.AnchorPoint           = Vector2.new(1, 1)
	btn.Position              = UDim2.new(1, -ICON_RIGHT, 1, -ICON_BOTTOM)
	btn.BackgroundColor3      = Color3.fromRGB(10, 15, 28)
	btn.BackgroundTransparency = 0.05
	btn.AutoButtonColor       = false
	btn.Text                  = ""
	btn.Visible               = false
	btn.ZIndex                = 50
	btn.Parent                = sg
	UILib.corner(btn, 10)
	iconRing = UILib.stroke(btn, C.BORDER, 2)
	iconBtn  = btn

	local holder                = Instance.new("Frame")
	holder.Name                 = "Portrait"
	holder.Size                 = UDim2.new(1, -6, 1, -6)
	holder.Position             = UDim2.fromOffset(3, 3)
	holder.BackgroundTransparency = 1
	holder.ZIndex               = 51
	holder.Parent               = btn
	iconHolder = holder

	btn.MouseButton1Click:Connect(function()
		menuOpen = not menuOpen
		menu.Visible = menuOpen
		updatePanel()
	end)
	btn.MouseEnter:Connect(function()
		if iconRing and not currentMode then iconRing.Color = C.ACCENT end
	end)
	btn.MouseLeave:Connect(function()
		if iconRing and not currentMode then iconRing.Color = C.BORDER end
	end)

	updatePanel()
end

-- ── Unit tracking ────────────────────────────────────────────────────────────────

local function registerUnit(id: string, part: BasePart)
	ownUnits[id] = part
	part.Destroying:Connect(function()
		ownUnits[id]     = nil
		scouts[id]       = nil
		defendAssign[id] = nil
		refreshIcon()
	end)
	refreshIcon()
	incorporateNewUnit(id, part)
end

-- ── Public API ────────────────────────────────────────────────────────────────────

function ScoutManager.init(net: any, _cameraModule: any, fog: any, mini: any)
	network    = net
	fogManager = fog
	miniMap    = mini

	createPanel()

	fogManager.onEnemyBuildingDiscovered(function(_bid: string, pos: Vector3)
		-- Any first sighting of an enemy structure unlocks ATTACK (latched).
		if not enemyFound then
			enemyFound = true
			if updatePanel then updatePanel() end
		end
		onEnemyStructureFound(pos)
	end)

	network.onUnitSpawned(function(id: string, ownerId: number, _pos: Vector3)
		if ownerId ~= localUserId then return end
		task.spawn(function()
			local folder = workspace:WaitForChild("Units", 10) :: Folder?
			if not folder then return end
			local part = folder:WaitForChild(id, 10) :: BasePart?
			if not part then return end
			registerUnit(id, part)
		end)
	end)
end

-- Wipes all army-command state (call on player elimination / new match).
function ScoutManager.reset()
	currentMode = nil
	modeLoopId += 1
	enemyFound  = false
	ownUnits     = {}
	clearModeAssignments()
	currentIconType = nil
	menuOpen = false
	if iconHolder then iconHolder:ClearAllChildren() end
	if iconBtn   then iconBtn.Visible = false end
	if menuFrame then menuFrame.Visible = false end
	if updatePanel then updatePanel() end
	if activeCard then activeCard:Destroy(); activeCard = nil end
	if miniMap then miniMap.clearEnemyStructures() end
end

return ScoutManager
