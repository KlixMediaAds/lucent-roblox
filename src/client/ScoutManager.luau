--[[
	ScoutManager — army master-control panel.

	A persistent command icon sits at the bottom-left, just right of the minimap,
	showing a 3D portrait of the player's most expensive owned unit. It appears
	whenever the player owns at least one unit. Hovering it wipes open a row of three
	command pills that also act as sliders — an army-composition mixer:

	  • CLICK a pill  → all-in: the whole army snaps to that order, and newly-built
	                    units auto-join it too (a "global" mode).
	  • DRAG a pill   → set just that mode's headcount (0…army size). The newest drag
	                    wins: extra units are taken from idle first, then from the
	                    oldest-set modes. Dragging drops the global capture, so from
	                    then on new units fall to idle.

	Assignment is per-unit, so the three orders run at once over their own subsets:

	  • SCOUT  — assigned units roam the fog hunting the enemy. On the first enemy
	             STRUCTURE sighting the scouts fall back to the nearest Command Center
	             (→ idle), an alert card slides in, and a crosshair marks the minimap.
	  • ATTACK — attack-moves toward the nearest known enemy structure (or pushes into
	             enemy territory if none is known). Locked until an enemy is spotted.
	  • DEFEND — posts units around the base perimeter; some patrol, the rest hold.

	Idle units hold position (aggro still fires if attacked). Hand-ordering a unit
	drops it to idle. Leeches are economy units — never pooled, counted, or idle.
	A compact breakdown ("3 Defending · 2 Attacking · 5 Idle") shows beside the icon
	when the row is closed. Everything is client-side over the move / attack-move RPCs.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local SoundService      = game:GetService("SoundService")
local UserInputService  = game:GetService("UserInputService")

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
local network:      any
local fogManager:   any
local miniMap:      any
local cameraModule: any

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

local MODES = { "scout", "attack", "defend" }

local ownUnits: { [string]: BasePart } = {}
local enemyFound  = false         -- ATTACK unlocks once an enemy structure is seen

-- Per-unit assignment is the source of truth: a commandable unit is either in one
-- of the three modes here, or absent = "idle". (Leeches are never tracked.)
local assign:   { [string]: string } = {}   -- id -> "scout" | "attack" | "defend"
-- Recency of each mode, for the "newest slider wins, sacrifice the oldest" rule.
local modeRank: { [string]: number } = { scout = 0, attack = 0, defend = 0 }
local rankSeq   = 0
-- When a pill is *clicked* (all-in), newly-built units auto-join this mode. Any
-- slider drag or manual unit control clears it, so new units fall to idle instead.
local globalMode: string? = nil

local scouts:       { [string]: Scout }  = {}   -- working data for scout-assigned units
local defendAssign: { [string]: Defend } = {}   -- working data for defend-assigned units
local defendPosts:    { Vector3 } = {}
local defendCentroid: Vector3     = Vector3.zero

local activeCard: Frame? = nil

-- UI refs (populated in createPanel)
local panelGui:    ScreenGui?  = nil
local iconBtn:     TextButton? = nil
local iconRing:    UIStroke?   = nil
local iconHolder:  Frame?      = nil
local menuFrame:   Frame?      = nil   -- clip wrapper that wipes the row open
local menuContent: Frame?      = nil   -- auto-sizing row of mode buttons inside the wrapper
local statusLabel: TextLabel?  = nil   -- "Scouting…" status shown beside the toggle

-- Eye "camera jumper" that pops above the pill the cursor rests on (see the eye block).
local eyeBtn:      TextButton? = nil
local eyeScale:    UIScale?    = nil
local eyeMode:     string? = nil       -- mode the eye is currently shown for (nil = hidden)
local eyeHoverMode: string? = nil      -- pill the cursor is currently over
local eyeHoverEye  = false             -- cursor is over the eye itself
local eyeToken     = 0                 -- cancels stale reveal timers
-- The DEFEND eye is offered even at 0 units, but once clicked it stays hidden until the
-- player pans the camera again (jumping home while already home is pointless).
local defendEyeSuppressed = false
local onPillEnter: (string) -> ()      -- forward (defined with the eye helpers)
local onPillLeave: (string) -> ()

local menuOpen   = false
local currentIconType: string? = nil
local setMenuOpen  -- forward (defined with the UI)
type ModeBtn = { btn: TextButton, stroke: UIStroke, color: Color3, fill: Frame, nameLbl: TextLabel, countLbl: TextLabel }
local modeButtons: { [string]: ModeBtn } = {}

local MENU_H      = 32     -- height of the command row (the pills)
local EYE_ROOM    = 34     -- extra headroom above the pills the menu reserves for the eye
local MENU_FRAME_H = MENU_H + EYE_ROOM   -- full menu-wrapper height (pills sit at its bottom)
local ICON        = 46
-- Command toggle lives at the bottom-left, just to the right of the minimap.
local MAP_SPAN    = 148   -- minimap border footprint (144 + 4)
local MAP_PAD     = 10    -- minimap's gap from the screen edge
local ICON_LEFT   = MAP_PAD + MAP_SPAN + 8   -- right of the minimap, 8px gap
local ICON_BOTTOM = MAP_PAD                   -- bottom flush with the minimap

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

-- Army-command pill press cue: one clip, but each order gets its own fixed pitch
-- (defend low, scout mid, attack high) so the three read distinctly — no random variation.
local ARMY_CMD_ID    = 102609652962425
local ARMY_CMD_PITCH: { [string]: number } = { defend = 0.82, scout = 1.0, attack = 1.2 }
local function playArmyCommand(mode: string)
	local s           = Instance.new("Sound")
	s.SoundId         = "rbxassetid://" .. ARMY_CMD_ID
	s.Volume          = 0.6
	s.PlaybackSpeed   = ARMY_CMD_PITCH[mode] or 1.0
	s.Parent          = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
end

local function unitTypeOf(part: BasePart): string
	local tv = part:FindFirstChild("UnitType") :: StringValue?
	return (tv and tv.Value) or "Survivor"
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

-- Leeches are economy units — they never join the army pool, count, or show as idle.
local function isCommandable(part: BasePart): boolean
	return part.Parent ~= nil and unitTypeOf(part) ~= "Leech"
end

-- Live owned units eligible for army orders (excludes Leeches).
local function commandableUnitIds(): { string }
	local ids: { string } = {}
	for id, part in ownUnits do
		if isCommandable(part) then ids[#ids + 1] = id end
	end
	return ids
end

local function armySize(): number
	local n = 0
	for _, part in ownUnits do if isCommandable(part) then n += 1 end end
	return n
end

-- Live commandable units currently assigned to `mode`.
local function unitsInMode(mode: string): { string }
	local ids: { string } = {}
	for id in assign do
		local part = ownUnits[id]
		if assign[id] == mode and part and isCommandable(part) then ids[#ids + 1] = id end
	end
	return ids
end

local function countInMode(mode: string): number
	return #unitsInMode(mode)
end

-- Idle = commandable + not in any mode.
local function idleUnitIds(): { string }
	local ids: { string } = {}
	for id, part in ownUnits do
		if isCommandable(part) and not assign[id] then ids[#ids + 1] = id end
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
	playSound(138317894393091, 0.55)   -- enemy-spotted cue

	task.delay(5, function()
		if activeCard == card then dismissCard() end
	end)
end

-- All three passes run concurrently and always-on (started once in init). Each
-- only touches the units currently assigned to its mode, so idle / manually-driven
-- units are never grabbed. Passes no-op when their subset is empty.

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
	for id, s in scouts do
		-- Drop working data for units that died or left the scout assignment.
		if assign[id] ~= "scout" or not s.part.Parent then scouts[id] = nil; continue end
		local now      = os.clock()
		local arrived  = s.target ~= nil and (s.part.Position - s.target).Magnitude <= ARRIVE_DIST
		local explored = s.target ~= nil and fogManager.isExplored(s.target)
		local stalled  = (now - s.assignedAt) >= REASSIGN_AFTER
		if s.target == nil or arrived or explored or stalled then
			assignScout(id, s)
		end
	end
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
	local ids = unitsInMode("attack")
	if #ids == 0 then return end
	local tgt = currentAttackTarget()
	if tgt then network.attackMoveUnits(ids, tgt) end
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

-- Recompute perimeter posts from the current buildings.
local function ensureDefendPosts()
	local posts, centroid = computePerimeterPosts()
	defendPosts    = posts
	defendCentroid = centroid
end

local function assignNearestDefendPost(id: string, part: BasePart, patrol: boolean?)
	if #defendPosts == 0 then return end
	local bestIdx, bestD = 1, math.huge
	for i, post in defendPosts do
		local d = (part.Position - post).Magnitude
		if d < bestD then bestD = d; bestIdx = i end
	end
	assignDefend(id, bestIdx, patrol == true)
end

local function defendPass()
	local ids = unitsInMode("defend")
	if #ids == 0 then return end
	ensureDefendPosts()
	if #defendPosts == 0 then return end
	local now = os.clock()

	-- Give any defender that lost its post (reassigned mid-mode) a fresh one.
	local k = 0
	for _, id in ids do
		if not defendAssign[id] then
			k += 1
			assignNearestDefendPost(id, ownUnits[id], k % PATROL_EVERY == 0)
		end
	end

	for id, a in defendAssign do
		if assign[id] ~= "defend" then defendAssign[id] = nil; continue end
		local part = ownUnits[id]
		if not part or not part.Parent then defendAssign[id] = nil; continue end
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

-- ── Mode switching ───────────────────────────────────────────────────────────────

local updatePanel  -- forward (defined with the UI)

local function bumpRank(mode: string)
	rankSeq += 1
	modeRank[mode] = rankSeq
end

-- Staging point a mode pulls units toward (for "grab the nearest units" ordering).
local function modeStagePoint(mode: string): Vector3?
	if mode == "attack" then return currentAttackTarget() end
	if mode == "defend" then
		if #defendPosts == 0 then ensureDefendPosts() end
		return defendCentroid
	end
	return armyCentroid()   -- scout: no strong anchor
end

-- Move one unit into "scout"|"attack"|"defend" or "idle", issuing the right order.
local function applyUnitMode(id: string, mode: string)
	local part = ownUnits[id]
	if not part or not isCommandable(part) then return end
	local prev = assign[id] or "idle"
	if prev == mode then return end

	scouts[id]       = nil   -- tear down any previous working data
	defendAssign[id] = nil

	if mode == "idle" then
		assign[id] = nil
		network.moveUnits({ id }, Vector3.new(part.Position.X, 0, part.Position.Z))  -- hold
	else
		assign[id] = mode
		if mode == "scout" then
			enlistScout(id, part)
		elseif mode == "attack" then
			local tgt = currentAttackTarget()
			if tgt then network.attackMoveUnits({ id }, tgt) end
		elseif mode == "defend" then
			if #defendPosts == 0 then ensureDefendPosts() end
			assignNearestDefendPost(id, part, false)
		end
	end
end

-- Choose `need` units to pull into `targetMode`: idle first, then the other modes
-- oldest-set first; within each source the nearest units to the new job go first.
local function pickUnits(need: number, targetMode: string): { string }
	local result: { string } = {}
	if need <= 0 then return result end
	local stage = modeStagePoint(targetMode)

	local groups: { { string } } = { idleUnitIds() }
	local others: { string } = {}
	for _, m in MODES do if m ~= targetMode then others[#others + 1] = m end end
	table.sort(others, function(a, b) return modeRank[a] < modeRank[b] end)  -- oldest first
	for _, m in others do groups[#groups + 1] = unitsInMode(m) end

	for _, group in groups do
		if #result >= need then break end
		if stage then
			table.sort(group, function(a, b)
				local pa, pb = ownUnits[a], ownUnits[b]
				if not (pa and pb) then return false end
				return (pa.Position - stage).Magnitude < (pb.Position - stage).Magnitude
			end)
		end
		for _, id in group do
			if #result >= need then break end
			result[#result + 1] = id
		end
	end
	return result
end

-- Slider: commit exactly `target` units to `mode` (0..armySize). The newest slider
-- wins — shortfall is stolen from idle first, then the oldest-set modes.
local function setModeCount(mode: string, target: number)
	if mode == "attack" and not enemyFound then return end
	globalMode = nil                       -- dragging drops the all-in capture
	bumpRank(mode)
	target = math.clamp(math.floor(target + 0.5), 0, armySize())
	local cur = countInMode(mode)
	if target > cur then
		for _, id in pickUnits(target - cur, mode) do applyUnitMode(id, mode) end
	elseif target < cur then
		-- Release the surplus to idle, farthest-from-the-job first.
		local ids   = unitsInMode(mode)
		local stage = modeStagePoint(mode)
		if stage then
			table.sort(ids, function(a, b)
				local pa, pb = ownUnits[a], ownUnits[b]
				if not (pa and pb) then return false end
				return (pa.Position - stage).Magnitude > (pb.Position - stage).Magnitude
			end)
		end
		for i = 1, cur - target do
			if ids[i] then applyUnitMode(ids[i], "idle") end
		end
	end
	if updatePanel then updatePanel() end
end

-- Click a pill: put the whole army on this status and capture future spawns too.
local function setGlobalMode(mode: string)
	if mode == "attack" and not enemyFound then return end
	globalMode = mode
	bumpRank(mode)
	if mode == "defend" then ensureDefendPosts() end
	for _, id in commandableUnitIds() do applyUnitMode(id, mode) end
	if updatePanel then updatePanel() end
end

-- The player hand-ordered these units: drop them to idle and stop auto-capturing.
local function releaseUnits(ids: { string })
	local changed = false
	for _, id in ids do
		if assign[id] then
			assign[id]       = nil
			scouts[id]       = nil
			defendAssign[id] = nil
			changed = true
		end
	end
	if changed then
		globalMode = nil   -- manual control means the player is mixing by hand now
		if updatePanel then updatePanel() end
	end
end

-- Enemy structure spotted by a scout: rally the scouts home and drop them to idle.
-- Attack / Defend units keep doing their jobs.
local function onEnemyStructureFound(worldPos: Vector3, buildingId: string?)
	local scoutIds = unitsInMode("scout")
	if #scoutIds == 0 then return end

	local reportType = unitTypeOf(ownUnits[scoutIds[1]])
	for _, id in scoutIds do
		assign[id] = nil
		scouts[id] = nil
	end
	if globalMode == "scout" then globalMode = nil end

	local centroid = armyCentroid() or workspace.CurrentCamera.CFrame.Position
	local cc = nearestOwnCC(centroid)
	if cc then network.moveUnits(scoutIds, cc) end

	if updatePanel then updatePanel() end
	miniMap.markEnemyStructure(worldPos, buildingId)
	showAlert(C.RED, reportType, "⚠  ENEMY DISCOVERED", "Enemy structure found! Scouts are falling back to base.")
end

-- ── New unit incorporation ──────────────────────────────────────────────────────
-- New units idle by default; they auto-join a mode only if a pill was *clicked*.
local function incorporateNewUnit(id: string, part: BasePart)
	if not isCommandable(part) then return end
	if globalMode then applyUnitMode(id, globalMode) end
	if updatePanel then updatePanel() end
end

-- ── Command panel UI ─────────────────────────────────────────────────────────────

local MODE_COLORS = { scout = C.ACCENT, attack = C.RED, defend = C.GREEN }
local MODE_VERB   = { scout = "Scouting", attack = "Attacking", defend = "Defending" }

-- ATTACK is unavailable until the enemy has been located.
local function modeLocked(mode: string): boolean
	return mode == "attack" and not enemyFound
end

-- Fade/slide the status label in from the toggle when an order is first issued.
local function revealStatus()
	if not statusLabel then return end
	local rest = statusLabel.Position                       -- resting spot beside the toggle
	statusLabel.TextTransparency = 1
	statusLabel.Position = UDim2.new(0, rest.X.Offset - 10, rest.Y.Scale, rest.Y.Offset)
	TweenService:Create(statusLabel,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0, Position = rest }
	):Play()
end

local function hex(c: Color3): string
	return string.format("#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

-- RichText breakdown of the army split (e.g. "3 Defending · 2 Attacking · 5 Idle").
-- Each mode shows only when it has units; Idle shows whenever any unit is idle
-- (so sliding everything back down still reads "N Idle"). Empty only when the
-- player has no commandable units at all.
local function composeStatus(): string
	local segs: { string } = {}
	for _, mode in MODES do
		local c = countInMode(mode)
		if c > 0 then
			segs[#segs + 1] = string.format('<font color="%s">%d %s</font>', hex(MODE_COLORS[mode]), c, MODE_VERB[mode])
		end
	end
	local idle = #idleUnitIds()
	if idle > 0 then
		segs[#segs + 1] = string.format('<font color="%s">%d Idle</font>', hex(C.DIM), idle)
	end
	return table.concat(segs, "  ·  ")
end

function updatePanel()
	local army = armySize()
	if iconRing then
		iconRing.Color = globalMode and MODE_COLORS[globalMode] or C.BORDER
	end
	-- Pills double as sliders: the fill bar shows each mode's share of the army.
	for mode, m in modeButtons do
		if modeLocked(mode) then
			m.btn.Visible = false        -- ATTACK hidden until an enemy is spotted
		else
			m.btn.Visible      = true
			local c            = countInMode(mode)
			local frac         = army > 0 and c / army or 0
			m.fill.Size        = UDim2.new(frac, 0, 1, 0)
			m.countLbl.Text    = tostring(c)
			m.stroke.Thickness = c > 0 and 2.2 or 1.2
		end
	end
	-- Compact breakdown beside the toggle, only while the row is closed.
	if statusLabel then
		local txt = (not menuOpen) and composeStatus() or ""
		if txt ~= "" then
			statusLabel.Text = txt
			if not statusLabel.Visible then
				statusLabel.Visible = true
				revealStatus()
			end
		else
			statusLabel.Visible = false
		end
	end
end

local function refreshIcon()
	if not iconBtn then return end
	local t = topUnitType()
	if not t then
		iconBtn.Visible = false
		if menuFrame then menuFrame.Visible = false; menuFrame.Size = UDim2.fromOffset(0, MENU_FRAME_H) end
		if statusLabel then statusLabel.Visible = false end
		menuOpen = false
		-- Army gone → drop any eye (defined later; clear inline).
		eyeToken += 1
		eyeMode = nil
		if eyeBtn then eyeBtn.Visible = false end
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

-- ── Eye "camera jumper" ──────────────────────────────────────────────────────────
-- Hovering a pill for a full second (when that order has ≥1 unit) pops a 👁 above it.
-- Clicking the eye snaps the camera to that order's forces:
--   • DEFEND — flies home to the base (same as the [R] recenter).
--   • ATTACK — jumps to a random attacking troop and follows it until it dies or the
--              player pans away.
--   • SCOUT  — jumps to a random one of the OUTERMOST scouts and follows it (each press
--              re-rolls a new outer scout).
local EYE_GAP = 3   -- local px the eye's bottom overlaps onto the pill's top edge

local function homeBasePos(): Vector3?
	local ref = (defendCentroid ~= Vector3.zero and defendCentroid) or armyCentroid() or Vector3.zero
	return nearestOwnCC(ref)
end

-- Perform the camera jump for `mode` (called when its eye is clicked).
local function jumpForMode(mode: string)
	if not cameraModule then return end

	if mode == "defend" then
		local home = homeBasePos()
		if home then cameraModule.returnToBase(home) end

	elseif mode == "attack" then
		local live: { BasePart } = {}
		for _, id in unitsInMode("attack") do
			local p = ownUnits[id]
			if p and p.Parent then live[#live + 1] = p end
		end
		if #live > 0 then
			local part = live[math.random(1, #live)]
			cameraModule.setFocus(part.Position)   -- instant jump…
			cameraModule.followPart(part)          -- …then lock on until it dies / player pans
		end

	elseif mode == "scout" then
		-- Rank scouts by distance from home, jump to a random one of the outermost, and
		-- follow it (until it dies or the player pans).
		local home = homeBasePos() or armyCentroid() or Vector3.zero
		local ranked: { { part: BasePart, d: number } } = {}
		for _, id in unitsInMode("scout") do
			local p = ownUnits[id]
			if p and p.Parent then
				ranked[#ranked + 1] = { part = p, d = (p.Position - home).Magnitude }
			end
		end
		if #ranked > 0 then
			table.sort(ranked, function(a, b) return a.d > b.d end)
			local outer = math.max(1, math.ceil(#ranked * 0.4))   -- the farthest ~40%
			local pick  = ranked[math.random(1, outer)]
			cameraModule.setFocus(pick.part.Position)   -- instant jump…
			cameraModule.followPart(pick.part)          -- …then follow it
		end
	end
end

-- An order's eye is offered when the row is open and either it has units, or it's DEFEND
-- (always available) and not currently suppressed.
local function eyeAllowed(mode: string): boolean
	if not menuOpen then return false end
	if mode == "defend" then return not defendEyeSuppressed end
	return countInMode(mode) > 0
end

-- Park the eye right on top of the hovered pill. It's parented straight to the pill and
-- positioned with SCALE (bottom-centre anchored at the pill's top-centre), so it inherits
-- the pill's exact HUD UIScale and always sits flush on the pill — no pixel math.
local function positionEye()
	if not (eyeBtn and eyeMode) then return end
	local m = modeButtons[eyeMode]
	if not m then return end
	eyeBtn.Parent   = m.btn
	-- Y offset +EYE_GAP nudges the eye's bottom a hair onto the pill top so it reads as
	-- sitting ON the pill rather than hovering over a gap.
	eyeBtn.Position = UDim2.new(0.5, 0, 0, EYE_GAP)
end

local function hideEye()
	if not eyeBtn then return end
	eyeMode = nil
	eyeBtn.Visible = false
end

local function showEye(mode: string)
	if not (eyeBtn and eyeScale) then return end
	if eyeMode == mode and eyeBtn.Visible then positionEye(); return end   -- already up; don't re-animate
	eyeMode = mode
	positionEye()
	eyeBtn.Visible          = true
	eyeBtn.TextTransparency = 1
	eyeScale.Scale          = 0.8
	-- A gentle fade-in over 0.3s.
	TweenService:Create(eyeBtn,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }):Play()
	TweenService:Create(eyeScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

-- After the DEFEND eye jumps home, keep it hidden until the player pans the camera away
-- from the home focus (moving the camera "re-arms" the jump-home eye).
local function armDefendSuppression()
	defendEyeSuppressed = true
	if not cameraModule then return end
	task.spawn(function()
		task.wait(0.75)   -- let the fly-home animation settle first
		local home = cameraModule.getFocus()
		while defendEyeSuppressed do
			if (cameraModule.getFocus() - home).Magnitude > 4 then
				defendEyeSuppressed = false
				-- If the cursor never left the DEFEND pill, pop the eye back right away.
				if eyeHoverMode == "defend" and menuOpen then showEye("defend") end
				break
			end
			task.wait(0.1)
		end
	end)
end

-- Pill hover → reveal the eye immediately (no delay) when the order allows it. Leaving
-- grants a short grace so the cursor can travel up onto the eye.
onPillEnter = function(mode: string)
	if modeLocked(mode) then return end
	eyeHoverMode = mode
	if eyeMode and eyeMode ~= mode then hideEye() end
	eyeToken += 1
	if eyeAllowed(mode) then showEye(mode) end
end

onPillLeave = function(mode: string)
	if eyeHoverMode == mode then eyeHoverMode = nil end
	eyeToken += 1   -- cancel any pending reveal
	task.delay(0.12, function()
		if eyeHoverMode == nil and not eyeHoverEye then hideEye() end
	end)
end

-- ── Pill slider input ──────────────────────────────────────────────────────────
-- A press that never travels past the threshold is a *click* (all-in); a press that
-- drags sets that mode's count from the cursor's horizontal position on the pill.
local PILL_W           = 116
local PILL_DRAG_THRESH = 5
local pillPressMode: string? = nil
local pillPressX = 0
local pillDragged = false

local function beginPillPress(mode: string)
	if modeLocked(mode) then return end
	pillPressMode = mode
	pillDragged   = false
	pillPressX    = UserInputService:GetMouseLocation().X
end

local function makeModeButton(parent: Frame, mode: string, label: string, color: Color3, order: number)
	local b                  = Instance.new("TextButton")
	b.Name                   = mode .. "Btn"
	b.Size                   = UDim2.fromOffset(PILL_W, MENU_H)
	b.BackgroundColor3       = C.BG_CARD
	b.AutoButtonColor        = false
	b.Text                   = ""
	b.LayoutOrder            = order
	-- NOT clipped: the eye floats above the pill's top edge (see the eye block). The fill
	-- bar is clipped by its own holder instead so it keeps the rounded pill shape.
	b.ClipsDescendants       = false
	b.ZIndex                 = 51
	b.Parent                 = parent
	UILib.corner(b, 8)
	local st = UILib.stroke(b, color, 1.4)

	-- Fill bar: the mode's committed fraction of the whole army. Lives in a full-size
	-- clipping holder so it stays inside the pill's rounded corners.
	local fillClip              = Instance.new("Frame")
	fillClip.Name               = "FillClip"
	fillClip.Size               = UDim2.fromScale(1, 1)
	fillClip.BackgroundTransparency = 1
	fillClip.ClipsDescendants   = true
	fillClip.ZIndex             = 51
	fillClip.Parent             = b
	UILib.corner(fillClip, 8)

	local fill                  = Instance.new("Frame")
	fill.Name                   = "Fill"
	fill.AnchorPoint            = Vector2.new(0, 0.5)
	fill.Position               = UDim2.new(0, 0, 0.5, 0)
	fill.Size                   = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3       = color
	fill.BackgroundTransparency = 0.62
	fill.BorderSizePixel        = 0
	fill.ZIndex                 = 51
	fill.Parent                 = fillClip

	local nameLbl                   = Instance.new("TextLabel")
	nameLbl.Size                    = UDim2.new(1, -34, 1, 0)
	nameLbl.Position                = UDim2.fromOffset(10, 0)
	nameLbl.BackgroundTransparency  = 1
	nameLbl.Font                    = Enum.Font.GothamBold
	nameLbl.TextSize                = 13
	nameLbl.TextColor3              = C.TEXT
	nameLbl.TextXAlignment          = Enum.TextXAlignment.Left
	nameLbl.Text                    = label
	nameLbl.ZIndex                  = 53
	nameLbl.Parent                  = b

	local countLbl                  = Instance.new("TextLabel")
	countLbl.AnchorPoint            = Vector2.new(1, 0)
	countLbl.Size                   = UDim2.new(0, 26, 1, 0)
	countLbl.Position               = UDim2.new(1, -8, 0, 0)
	countLbl.BackgroundTransparency = 1
	countLbl.Font                   = Enum.Font.GothamBlack
	countLbl.TextSize               = 14
	countLbl.TextColor3             = color
	countLbl.TextXAlignment         = Enum.TextXAlignment.Right
	countLbl.Text                   = "0"
	countLbl.ZIndex                 = 53
	countLbl.Parent                 = b

	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then beginPillPress(mode) end
	end)

	-- Hovering the pill arms the 1-second eye reveal for this order.
	b.MouseEnter:Connect(function() if onPillEnter then onPillEnter(mode) end end)
	b.MouseLeave:Connect(function() if onPillLeave then onPillLeave(mode) end end)

	modeButtons[mode] = { btn = b, stroke = st, color = color, fill = fill, nameLbl = nameLbl, countLbl = countLbl }
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
	-- Same shared HUD scale as the minimap so the scout toggle/menu stay locked to the
	-- (also-scaled) minimap and grow together on large screens.
	UILib.applyHudScale(sg)

	-- StarCraft-style command bar: a full-width black backdrop that sits beneath
	-- every other HUD element, its top flush with the top of the minimap.
	local backdropGui           = Instance.new("ScreenGui")
	backdropGui.Name            = "HUDBackdrop"
	backdropGui.ResetOnSpawn    = false
	backdropGui.IgnoreGuiInset  = true
	backdropGui.DisplayOrder    = -5   -- below the minimap (0) and every other panel
	backdropGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	backdropGui.Parent          = pg
	-- Shared HUD scale so the band's height scales with the rest of the cluster instead
	-- of staying a thin sliver under a large minimap/grid on big screens.
	UILib.applyHudScale(backdropGui)

	local bar                   = Instance.new("Frame")
	bar.Name                    = "CommandBar"
	bar.AnchorPoint             = Vector2.new(0.5, 1)
	bar.Position                = UDim2.new(0.5, 0, 1, 0)
	bar.Size                    = UDim2.new(1, 0, 0, (MAP_PAD + MAP_SPAN) / 2)  -- half-height strip
	bar.BackgroundColor3        = Color3.fromRGB(0, 0, 0)
	bar.BackgroundTransparency  = 0.12
	bar.BorderSizePixel         = 0
	bar.Parent                  = backdropGui

	local topEdge               = Instance.new("Frame")
	topEdge.Name                = "TopEdge"
	topEdge.Size                = UDim2.new(1, 0, 0, 2)
	topEdge.Position            = UDim2.fromOffset(0, 0)
	topEdge.BackgroundColor3    = C.BORDER
	topEdge.BorderSizePixel     = 0
	topEdge.Parent              = bar

	-- Where the row / status sit: just right of the toggle, vertically centred on it.
	local ROW_X   = ICON_LEFT + ICON + 8
	local ROW_Y   = UDim.new(1, -(ICON_BOTTOM + ICON // 2))

	-- Command row: a clipped wrapper whose width wipes open, so the buttons appear to
	-- push out of the toggle. The inner content auto-sizes to hug the buttons. The wrapper
	-- is taller than the pills (MENU_FRAME_H) with the pills pinned to its BOTTOM, leaving
	-- headroom on top for the eye to pop up into without being clipped away.
	local menu               = Instance.new("Frame")
	menu.Name                = "CommandMenu"
	menu.AnchorPoint         = Vector2.new(0, 1)   -- pinned by its bottom edge
	menu.Position            = UDim2.new(0, ROW_X, ROW_Y.Scale, ROW_Y.Offset + MENU_H // 2)
	menu.Size                = UDim2.fromOffset(0, MENU_FRAME_H)
	menu.ClipsDescendants    = true
	menu.BackgroundTransparency = 1
	menu.Visible             = false
	menu.ZIndex              = 50
	menu.Parent              = sg
	menuFrame = menu

	local content            = Instance.new("Frame")
	content.Name             = "Content"
	content.AnchorPoint      = Vector2.new(0, 1)    -- pills hug the wrapper's bottom
	content.Position         = UDim2.new(0, 0, 1, 0)
	content.Size             = UDim2.fromOffset(0, MENU_H)
	content.AutomaticSize    = Enum.AutomaticSize.X
	content.BackgroundTransparency = 1
	content.ZIndex           = 50
	content.Parent           = menu
	menuContent = content

	local layout             = Instance.new("UIListLayout")
	layout.FillDirection       = Enum.FillDirection.Horizontal
	layout.VerticalAlignment   = Enum.VerticalAlignment.Center
	layout.Padding             = UDim.new(0, 8)
	layout.SortOrder           = Enum.SortOrder.LayoutOrder
	layout.Parent              = content

	makeModeButton(content, "scout",  "SCOUT",  C.ACCENT, 1)
	makeModeButton(content, "attack", "ATTACK", C.RED,    2)
	makeModeButton(content, "defend", "DEFEND", C.GREEN,  3)

	-- Status readout ("Scouting…") that replaces the row once an order is issued.
	local status             = Instance.new("TextLabel")
	status.Name              = "CommandStatus"
	status.AnchorPoint       = Vector2.new(0, 0.5)
	status.Position          = UDim2.new(0, ROW_X + 2, ROW_Y.Scale, ROW_Y.Offset)
	status.Size              = UDim2.fromOffset(0, 22)
	status.AutomaticSize     = Enum.AutomaticSize.X
	status.BackgroundTransparency = 1
	status.Font              = Enum.Font.GothamBold
	status.TextSize          = 15
	status.RichText          = true   -- per-segment colours in the breakdown
	status.TextXAlignment    = Enum.TextXAlignment.Left
	status.TextColor3        = C.TEXT
	status.TextStrokeTransparency = 0.6
	status.Text              = ""
	status.Visible           = false
	status.ZIndex            = 49
	status.Parent            = sg
	statusLabel = status

	-- Wipe the row open/closed from the toggle. Opening measures the row's natural
	-- width, then tweens the clip wrapper out with a little overshoot so the buttons
	-- appear to push out of the toggle; closing collapses them back into it.
	setMenuOpen = function(open: boolean)
		menuOpen = open
		if not menuFrame then return end
		if open then
			menuFrame.Visible = true
			-- Width the row wipes open to, in LOCAL (pre-UIScale) units. We compute it
			-- from the pill constants instead of AbsoluteContentSize — that reads back in
			-- already-scaled pixels, which on a scaled HUD left the wrapper a hair short and
			-- clipped the last pill. Only count pills that are actually shown (ATTACK is
			-- hidden until an enemy is found); +6 is slack so the row never cuts off.
			local PILL_PAD = 8   -- matches the row UIListLayout padding
			local visible  = 0
			for mode in modeButtons do
				if not modeLocked(mode) then visible += 1 end
			end
			local target = visible > 0 and (visible * PILL_W + (visible - 1) * PILL_PAD + 6) or 0
			menuFrame.Size = UDim2.fromOffset(0, MENU_FRAME_H)
			TweenService:Create(menuFrame,
				TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = UDim2.fromOffset(target, MENU_FRAME_H) }
			):Play()
		else
			local tw = TweenService:Create(menuFrame,
				TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = UDim2.fromOffset(0, MENU_FRAME_H) })
			tw.Completed:Connect(function()
				if not menuOpen and menuFrame then menuFrame.Visible = false end
			end)
			tw:Play()
			eyeToken += 1   -- cancel a pending reveal; the row is closing
			hideEye()
		end
		updatePanel()
	end

	-- Hover reveals the mixer: it stays open while the cursor is over the hover zone,
	-- the toggle, or the row (or mid-drag), and closes shortly after the cursor leaves
	-- them all. The small delay bridges any gaps without flicker.
	local hoverIcon, hoverMenu, hoverZone = false, false, false
	local closeToken = 0
	local function openMenuHover()
		if not (iconBtn and iconBtn.Visible) then return end   -- no army → nothing to reveal
		closeToken += 1                       -- cancel any pending close
		if not menuOpen then setMenuOpen(true) end
	end
	local function scheduleMenuClose()
		closeToken += 1
		local my = closeToken
		task.delay(0.12, function()
			if my ~= closeToken then return end
			if hoverIcon or hoverMenu or hoverZone or pillPressMode or eyeHoverEye then return end
			if menuOpen then setMenuOpen(false) end
		end)
	end
	menu.MouseEnter:Connect(function() hoverMenu = true;  openMenuHover() end)
	menu.MouseLeave:Connect(function() hoverMenu = false; scheduleMenuClose() end)

	-- Generous invisible hotzone spanning the toggle + the row's full footprint, so
	-- hovering anywhere in that stretch of the command bar reveals the bars — you
	-- don't have to land precisely on the little toggle.
	local ROW_MAX_W = 3 * PILL_W + 2 * 8   -- width of the row with all three pills
	local zoneLeft  = ICON_LEFT - 6
	local zoneRight = ROW_X + ROW_MAX_W + 8
	local hotzone               = Instance.new("Frame")
	hotzone.Name                = "MixerHoverZone"
	hotzone.AnchorPoint         = Vector2.new(0, 1)
	hotzone.Position            = UDim2.new(0, zoneLeft, 1, -4)
	hotzone.Size                = UDim2.fromOffset(zoneRight - zoneLeft, MENU_H + ICON)
	hotzone.BackgroundTransparency = 1
	hotzone.ZIndex              = 48   -- behind the toggle/pills so their input still works
	hotzone.Parent              = sg
	hotzone.MouseEnter:Connect(function() hoverZone = true;  openMenuHover() end)
	hotzone.MouseLeave:Connect(function() hoverZone = false; scheduleMenuClose() end)

	-- Pill drag/click: a stationary press = click (all-in); a press that travels =
	-- slider drag, mapping cursor-X on the pill to that mode's count.
	UserInputService.InputChanged:Connect(function(input)
		if not pillPressMode then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local mx = UserInputService:GetMouseLocation().X
		if not pillDragged and math.abs(mx - pillPressX) > PILL_DRAG_THRESH then pillDragged = true end
		if pillDragged then
			local m = modeButtons[pillPressMode]
			if m then
				local ap   = m.btn.AbsolutePosition.X
				local aw   = m.btn.AbsoluteSize.X
				local frac = math.clamp((mx - ap) / math.max(aw, 1), 0, 1)
				local v    = math.floor(frac * armySize() + 0.5)
				if v ~= countInMode(pillPressMode) then setModeCount(pillPressMode, v) end
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not pillPressMode then return end
		if not pillDragged then
			playArmyCommand(pillPressMode)   -- per-order fixed-pitch cue
			setGlobalMode(pillPressMode)     -- clean click = commit everyone
		end
		pillPressMode = nil
		scheduleMenuClose()                -- collapse if the cursor has left the mixer
	end)

	-- Command icon
	local btn                 = Instance.new("TextButton")
	btn.Name                  = "CommandIcon"
	btn.Size                  = UDim2.fromOffset(ICON, ICON)
	btn.AnchorPoint           = Vector2.new(0, 1)
	btn.Position              = UDim2.new(0, ICON_LEFT, 1, -ICON_BOTTOM)
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

	btn.MouseEnter:Connect(function()
		if iconRing then iconRing.Color = C.ACCENT end
		hoverIcon = true
		openMenuHover()
	end)
	btn.MouseLeave:Connect(function()
		if iconRing then iconRing.Color = globalMode and MODE_COLORS[globalMode] or C.BORDER end
		hoverIcon = false
		scheduleMenuClose()
	end)

	-- Eye "camera jumper": a plain 👁 (no frame/outline). It's reparented onto whichever
	-- pill is hovered (see positionEye) and anchored bottom-centre so it sits right on the
	-- pill's top edge, inheriting the pill's HUD UIScale. Sized in local px like the pills.
	local eye                   = Instance.new("TextButton")
	eye.Name                    = "CommandEye"
	eye.Size                    = UDim2.fromOffset(MENU_H - 6, MENU_H - 6)
	eye.AnchorPoint             = Vector2.new(0.5, 1)   -- bottom-centre lands on the pill top
	eye.BackgroundTransparency  = 1
	eye.AutoButtonColor         = false
	eye.Font                    = Enum.Font.GothamBold
	eye.Text                    = "👁"
	eye.TextSize                = MENU_H - 6
	eye.TextColor3              = C.TEXT
	eye.TextStrokeTransparency  = 0.4   -- slight stroke keeps the glyph legible over the world
	eye.Visible                 = false
	eye.ZIndex                  = 60
	eye.Parent                  = sg
	local escale                = Instance.new("UIScale")
	escale.Parent               = eye
	eyeBtn   = eye
	eyeScale = escale

	eye.MouseEnter:Connect(function()
		eyeHoverEye = true
		openMenuHover()
	end)
	eye.MouseLeave:Connect(function()
		eyeHoverEye = false
		task.delay(0.12, function()
			if eyeHoverMode == nil and not eyeHoverEye then hideEye() end
		end)
		scheduleMenuClose()
	end)
	eye.MouseButton1Click:Connect(function()
		local m = eyeMode
		-- DEFEND is clickable even at 0 units; the others need someone to look at.
		if not m or (m ~= "defend" and countInMode(m) <= 0) then hideEye(); return end
		playSound(137887356175873, 0.6)   -- eye camera-jump cue
		-- A quick confirm-squish, then run the jump and tuck the eye away.
		if eyeScale then
			TweenService:Create(eyeScale,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1.25 }):Play()
		end
		jumpForMode(m)
		if m == "defend" then
			-- DEFEND jumps home, then tucks away until the camera pans (re-arming it).
			armDefendSuppression()
			task.delay(0.12, hideEye)
		elseif eyeScale then
			-- SCOUT / ATTACK: the eye stays put so the player can click again to re-roll a
			-- new troop to follow. Just settle the confirm-squish back to rest.
			task.delay(0.1, function()
				if eyeScale then
					TweenService:Create(eyeScale,
						TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Scale = 1 }):Play()
				end
			end)
		end
	end)

	updatePanel()
end

-- ── Unit tracking ────────────────────────────────────────────────────────────────

local function registerUnit(id: string, part: BasePart)
	ownUnits[id] = part
	part.Destroying:Connect(function()
		ownUnits[id]     = nil
		assign[id]       = nil
		scouts[id]       = nil
		defendAssign[id] = nil
		refreshIcon()
		if updatePanel then updatePanel() end   -- counts drop as units fall
	end)
	refreshIcon()
	incorporateNewUnit(id, part)
end

-- ── Public API ────────────────────────────────────────────────────────────────────

function ScoutManager.init(net: any, camera: any, fog: any, mini: any)
	network      = net
	cameraModule = camera
	fogManager   = fog
	miniMap      = mini

	createPanel()

	fogManager.onEnemyBuildingDiscovered(function(bid: string, pos: Vector3)
		-- Any first sighting of an enemy structure unlocks ATTACK (latched).
		if not enemyFound then
			enemyFound = true
			if updatePanel then updatePanel() end
		end
		onEnemyStructureFound(pos, bid)
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

	-- The three army passes run concurrently, forever; each early-returns when it has
	-- no assigned units, so idle / manually-driven units are never disturbed.
	local function runLoop(fn: () -> (), interval: number)
		task.spawn(function()
			while true do
				local ok, err = pcall(fn)
				if not ok then warn("[ScoutManager] pass error:", err) end
				task.wait(interval)
			end
		end)
	end
	runLoop(scoutPass,  SCOUT_TICK)
	runLoop(attackPass, ATTACK_TICK)
	runLoop(defendPass, DEFEND_TICK)
end

-- Wipes all army-command state (call on player elimination / new match).
function ScoutManager.reset()
	enemyFound   = false
	ownUnits     = {}
	assign       = {}
	scouts       = {}
	defendAssign = {}
	defendPosts  = {}
	modeRank     = { scout = 0, attack = 0, defend = 0 }
	rankSeq      = 0
	globalMode   = nil
	currentIconType = nil
	menuOpen = false
	eyeToken += 1
	eyeMode = nil
	eyeHoverMode = nil
	eyeHoverEye = false
	if eyeBtn then eyeBtn.Visible = false end
	if iconHolder then iconHolder:ClearAllChildren() end
	if iconBtn   then iconBtn.Visible = false end
	if menuFrame then menuFrame.Visible = false; menuFrame.Size = UDim2.fromOffset(0, MENU_H) end
	if statusLabel then statusLabel.Visible = false end
	if updatePanel then updatePanel() end
	if activeCard then activeCard:Destroy(); activeCard = nil end
	if miniMap then miniMap.clearEnemyStructures() end
end

-- The player hand-ordered these units — pull them out of any army order (→ idle).
function ScoutManager.releaseUnits(ids: { string })
	releaseUnits(ids)
end

return ScoutManager
