local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config"))
local RangeRing        = require(script.Parent:WaitForChild("RangeRing"))

local UnitController = {}

local localPlayer  = Players.LocalPlayer
local mouse        = localPlayer:GetMouse()
local selected: {string}  = {}
local knownUnits: {[string]: {part: BasePart, ownerId: number}} = {}
local knownBuildings: {[string]: {base: BasePart, ownerId: number, buildingType: string}} = {}
local selectionBoxes: {[string]: SelectionBox} = {}
local onChangedCb: ((number) -> ())?
local onBarracksSelectedCb:  ((string?) -> ())?
local onMineSelectedCb:      ((string?) -> ())?
local onCCSelectedCb:        ((string?) -> ())?
local onTurretSelectedCb:    ((string?) -> ())?
local onBlobSelectedCb:      ((string?) -> ())?
local onDeployerSelectedCb:  ((string?) -> ())?
local onLampreyNestSelectedCb: ((string?) -> ())?
local onEngineeringSelectedCb: ((string?) -> ())?
local onMoveIssuedCb:        (() -> ())?
local isBlockedFn: (() -> boolean)?
local dragFrame: Frame?

-- Tell every building-info panel to close. Each branch of the selection handler calls
-- this, then re-opens the one panel for the building actually selected.
local function clearBuildingPanels()
	if onBarracksSelectedCb    then onBarracksSelectedCb(nil)    end
	if onMineSelectedCb        then onMineSelectedCb(nil)        end
	if onCCSelectedCb          then onCCSelectedCb(nil)          end
	if onTurretSelectedCb      then onTurretSelectedCb(nil)      end
	if onBlobSelectedCb        then onBlobSelectedCb(nil)        end
	if onDeployerSelectedCb    then onDeployerSelectedCb(nil)    end
	if onLampreyNestSelectedCb then onLampreyNestSelectedCb(nil) end
	if onEngineeringSelectedCb then onEngineeringSelectedCb(nil) end
end

-- ── Building hover + selection highlight ──────────────────────────────────────
local hoverBuildingId:     string?      = nil
local hoverBox:            SelectionBox? = nil
local selectedBuildingId:  string?      = nil
local selectedBuildingBox: SelectionBox? = nil
local multiBldBoxes:       { [string]: SelectionBox } = {}  -- extra boxes from double-click

-- ── Double-click tracking ─────────────────────────────────────────────────────
local lastClickTime:   number  = 0
local lastClickTarget: string? = nil
local DOUBLE_CLICK_SECS        = 0.35

-- ── Range rings for turrets and mines ─────────────────────────────────────────
local hoverRing:    Model? = nil
local selectedRing: Model? = nil

local function getBuildingRange(id: string): number?
	local info = knownBuildings[id]
	if not info then return nil end
	local bt = info.buildingType
	if bt == "Foundry" then
		return Config.FOUNDRY_BOOST_RADIUS
	elseif bt == "Turret" then
		local model = info.base.Parent
		if model and (model :: any):IsA("Model") then
			local upg = model:FindFirstChild("Upgrade") :: StringValue?
			if upg then
				if upg.Value == "Flamethrower"   then return Config.TURRET_FLAME.range end
				if upg.Value == "RocketLauncher" then return Config.TURRET_ROCKET.range end
			end
		end
		return Config.TURRET_RANGE
	end
	return nil
end

local dragStart  = Vector2.zero
local dragEnd    = Vector2.zero
local isDragging = false
local atkMoveHeld = false  -- true while A key is held
local MIN_DRAG   = 8   -- pixels

-- ── Unit voice lines ─────────────────────────────────────────────────────────
local SOLDIER_VOICE_IDS     = {88664954760340,  70872333577296,  135999718666781}
local TANK_VOICE_IDS        = {128274629467753, 139954121143852, 75168311027870}
local SOLDIER_DEATH_ID      = 97350089441789
local TANK_DEATH_ID         = 137547229383680
local LAMPREY_DEATH_ID      = 135417409504018
local LAMPREY_DEATH_RARE_ID = 168208965

local function playSound(id: number, pitchRange: number, volume: number)
	local s = Instance.new("Sound")
	s.SoundId             = "rbxassetid://" .. id
	s.PlaybackSpeed       = 1 + (math.random() * pitchRange - pitchRange * 0.5)
	s.Volume              = volume
	s.RollOffMaxDistance  = 0
	s.Parent              = workspace
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
end

local function playSoldierVoice() playSound(SOLDIER_VOICE_IDS[math.random(#SOLDIER_VOICE_IDS)], 0.2, 1) end
local function playSoldierDeath() playSound(SOLDIER_DEATH_ID, 0.12, 1) end
local function playTankVoice()    playSound(TANK_VOICE_IDS[math.random(#TANK_VOICE_IDS)],       0.1, 7) end
local function playTankDeath()    playSound(TANK_DEATH_ID, 0.06, 7) end
local function playLampreyDeath()
	if math.random(1000) == 1 then
		playSound(LAMPREY_DEATH_RARE_ID, 0, 1.5)
	else
		playSound(LAMPREY_DEATH_ID, 0.25, 1)
	end
end

-- Straight-down terrain raycast so range rings around buildings sit on their tier.
local terrainRayParams = RaycastParams.new()
terrainRayParams.FilterType = Enum.RaycastFilterType.Include
terrainRayParams.FilterDescendantsInstances = { workspace.Terrain }

local function terrainHeightAt(x: number, z: number): number
	local result = workspace:Raycast(Vector3.new(x, 250, z), Vector3.new(0, -500, 0), terrainRayParams)
	return result and result.Position.Y or 0
end

-- ── Move-order ping ───────────────────────────────────────────────────────────
local function spawnMovePing(pos: Vector3, isAtkMove: boolean)
	local color = isAtkMove
		and Color3.fromRGB(255, 140, 0)   -- orange = attack-move
		or  Color3.fromRGB(0, 230, 80)    -- green  = regular move

	-- Resolve the real terrain Y under the target so the ping shows on whichever
	-- tier it lands on (callers sometimes flatten the order target to Y=0).
	local pingY         = terrainHeightAt(pos.X, pos.Z) + 0.3

	local ring          = Instance.new("Part")
	ring.Name           = "_MovePing"
	ring.Shape          = Enum.PartType.Cylinder
	-- Cylinder's length runs along X by default; rotate so it lies flat (Y-up)
	ring.CFrame         = CFrame.new(pos.X, pingY, pos.Z)
		* CFrame.Angles(0, 0, math.pi / 2)
	ring.Size           = Vector3.new(0.12, 2, 2)
	ring.Color          = color
	ring.Material       = Enum.Material.Neon
	ring.Anchored       = true
	ring.CanCollide     = false
	ring.CanQuery       = false
	ring.CastShadow     = false
	ring.Transparency   = 0.2
	ring.Parent         = workspace

	-- Expand + fade over ~0.45 s without TweenService
	task.spawn(function()
		for i = 1, 6 do
			task.wait(0.07)
			if not ring.Parent then break end
			local t = i / 6
			local d = 2 + t * 9
			ring.Size         = Vector3.new(0.12, d, d)
			ring.Transparency = 0.2 + t * 0.8
		end
		if ring.Parent then ring:Destroy() end
	end)
end

-- ── Drag-formation (BAR / SupCom style) ───────────────────────────────────────
-- Minimum spacing between adjacent slots. If the dragged line is too short to fit
-- every unit at this spacing, the line is widened about the same midpoint so units
-- never overlap.
local FORMATION_MIN_SPACING = Config.UNIT_FORMATION_SPACING
local FORMATION_DRAG_MIN    = 8   -- studs the cursor must travel to start a formation

-- ── Freehand path helpers ──────────────────────────────────────────────────────
-- `path` is the polyline of ground points the cursor traced (flat, Y = 0).

-- Cumulative arc length at each path vertex, plus the total length.
local function pathLengths(path: { Vector3 }): ({ number }, number)
	local cum: { number } = { 0 }
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
		cum[i] = total
	end
	return cum, total
end

-- World position at arc-length `dist` along the path. `dist` may be negative or
-- exceed the total length — the ends are extrapolated along their tangents so a
-- cramped formation can spill past the drawn path instead of overlapping.
local function sampleAlongPath(path: { Vector3 }, cum: { number }, total: number, dist: number): Vector3
	local m = #path
	if m == 1 then return path[1] end
	if dist <= 0 then
		local d = path[2] - path[1]
		local dir = d.Magnitude > 1e-4 and d.Unit or Vector3.new(1, 0, 0)
		return path[1] + dir * dist
	end
	if dist >= total then
		local d = path[m] - path[m - 1]
		local dir = d.Magnitude > 1e-4 and d.Unit or Vector3.new(1, 0, 0)
		return path[m] + dir * (dist - total)
	end
	for i = 2, m do
		if cum[i] >= dist then
			local segLen = cum[i] - cum[i - 1]
			local t = segLen > 1e-6 and (dist - cum[i - 1]) / segLen or 0
			return path[i - 1]:Lerp(path[i], t)
		end
	end
	return path[m]
end

-- Even-spaced slot positions along the path, centred on the path's arc midpoint.
-- Spacing clamps up to FORMATION_MIN_SPACING so units never overlap; when clamped
-- the formation extends symmetrically past both ends via tangent extrapolation.
local function computeFormationSlots(path: { Vector3 }, n: number): { Vector3 }
	local slots: { Vector3 } = {}
	if n <= 0 or #path == 0 then return slots end
	local cum, total = pathLengths(path)
	if n == 1 then slots[1] = sampleAlongPath(path, cum, total, total / 2); return slots end
	local spacing = math.max(total / (n - 1), FORMATION_MIN_SPACING)
	local mid     = total / 2
	for i = 1, n do
		local arc = mid + (i - 1 - (n - 1) / 2) * spacing
		slots[i] = sampleAlongPath(path, cum, total, arc)
	end
	return slots
end

-- Greedy nearest-slot assignment so units don't cross paths. Returns parallel
-- arrays (ids[i] is the unit assigned to slot positions[i]).
local function buildFormationOrders(unitIds: { string }, path: { Vector3 }): ({ string }, { Vector3 })
	local n     = #unitIds
	local slots = computeFormationSlots(path, n)
	local remaining = table.clone(unitIds)
	local ids:       { string }  = {}
	local positions: { Vector3 } = {}
	for i = 1, n do
		local s = slots[i]
		local bestIdx, bestD = 1, math.huge
		for k, id in remaining do
			local info = knownUnits[id]
			local pos  = info and info.part.Position or Vector3.zero
			local dx, dz = pos.X - s.X, pos.Z - s.Z
			local d = dx * dx + dz * dz
			if d < bestD then bestD = d; bestIdx = k end
		end
		ids[i]       = remaining[bestIdx]
		positions[i] = s
		table.remove(remaining, bestIdx)
	end
	return ids, positions
end

-- ── Formation preview rendering ────────────────────────────────────────────────
local segMarkers:  { Part } = {}   -- polyline segments tracing the drawn path
local slotMarkers: { Part } = {}   -- discs at each unit's destination slot

local function makeNeonPart(name: string, shape: Enum.PartType?): Part
	local p        = Instance.new("Part")
	p.Name         = name
	if shape then p.Shape = shape end
	p.Material     = Enum.Material.Neon
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CastShadow   = false
	p.Parent       = workspace
	return p
end

local function clearFormationPreview()
	for _, m in segMarkers  do if m.Parent then m:Destroy() end end
	for _, m in slotMarkers do if m.Parent then m:Destroy() end end
	table.clear(segMarkers)
	table.clear(slotMarkers)
end

-- Draws the polyline that follows the cursor's path plus the slot discs.
local function updateFormationPreview(path: { Vector3 }, atkMove: boolean)
	local color = atkMove and Color3.fromRGB(255, 140, 0) or Color3.fromRGB(0, 230, 80)
	local n     = #selected

	-- Polyline segments (one part per drawn segment) — follows the curve exactly.
	local segIdx = 0
	for i = 2, #path do
		local a = Vector3.new(path[i - 1].X, 0.3, path[i - 1].Z)
		local b = Vector3.new(path[i].X,     0.3, path[i].Z)
		local len = (b - a).Magnitude
		if len < 1e-3 then continue end
		segIdx += 1
		local m = segMarkers[segIdx]
		if not (m and m.Parent) then
			m = makeNeonPart("_FormationLine")
			m.Transparency = 0.25
			segMarkers[segIdx] = m
		end
		m.Color  = color
		m.Size   = Vector3.new(0.4, 0.1, len)
		m.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	end
	for i = #segMarkers, segIdx + 1, -1 do
		local m = segMarkers[i]
		if m then m:Destroy() end
		segMarkers[i] = nil
	end

	-- Slot discs at each unit's destination.
	local slots = computeFormationSlots(path, n)
	for i = 1, n do
		local s = slots[i]
		local m = slotMarkers[i]
		if not (m and m.Parent) then
			m = makeNeonPart("_FormationSlot", Enum.PartType.Cylinder)
			m.Size = Vector3.new(0.12, 1.6, 1.6)
			m.Transparency = 0.1
			slotMarkers[i] = m
		end
		m.Color  = color
		m.CFrame = CFrame.new(s.X, terrainHeightAt(s.X, s.Z) + 0.3, s.Z) * CFrame.Angles(0, 0, math.pi / 2)
	end
	for i = #slotMarkers, n + 1, -1 do
		local m = slotMarkers[i]
		if m then m:Destroy() end
		slotMarkers[i] = nil
	end
end

-- Voice bark when issuing an order (one per order; prefer tank, then soldier).
local function maybeUnitVoice()
	for _, id in selected do
		local info = knownUnits[id]
		if info and info.ownerId == localPlayer.UserId then
			local ut = info.part:FindFirstChild("UnitType")
			if ut then
				if      ut.Value == "Tank"    then playTankVoice();    return
				elseif  ut.Value == "Soldier" then playSoldierVoice(); return
				end
			end
		end
	end
end

local function syncSelectionBoxes()
	-- Remove boxes for units no longer selected
	local selectedSet: {[string]: boolean} = {}
	for _, id in selected do selectedSet[id] = true end

	for id, box in selectionBoxes do
		if not selectedSet[id] then
			box:Destroy()
			selectionBoxes[id] = nil
		end
	end

	-- Add boxes for newly selected units
	for _, id in selected do
		if selectionBoxes[id] then continue end
		local info = knownUnits[id]
		if not info or not info.part.Parent then continue end  -- stale / destroyed

		local box                  = Instance.new("SelectionBox")
		box.Adornee                = info.part
		box.Color3                 = Color3.fromRGB(0, 200, 255)
		box.LineThickness          = 0.06
		box.SurfaceTransparency    = 0.8
		box.SurfaceColor3          = Color3.fromRGB(0, 200, 255)
		box.Parent                 = workspace

		selectionBoxes[id] = box

		-- Clean up automatically if the unit is destroyed
		info.part.Destroying:Connect(function()
			local b = selectionBoxes[id]
			if b then b:Destroy(); selectionBoxes[id] = nil end
		end)
	end
end

local function notify()
	syncSelectionBoxes()
	if onChangedCb then onChangedCb(#selected) end
end

local function clearSelection()
	selected = {}
	notify()
end

local function addToSelection(id: string)
	for _, v in selected do if v == id then return end end
	table.insert(selected, id)
	notify()
end

local function hitUnit(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	for id, info in knownUnits do
		if info.part == result.Instance and info.ownerId == localPlayer.UserId then
			return id
		end
	end
	return nil
end

local function hitBuilding(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	local inst = result.Instance
	for id, info in knownBuildings do
		if info.ownerId == localPlayer.UserId then
			-- Match the base itself OR any part that shares the same model parent
			-- (handles multi-part buildings like the new mine with pillars/crystal/beams)
			local model = info.base.Parent
			if inst == info.base or (model and inst.Parent == model) then
				return id
			end
		end
	end
	return nil
end

local function hitEnemyUnit(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	for id, info in knownUnits do
		if info.part == result.Instance and info.ownerId ~= localPlayer.UserId then
			return id
		end
	end
	return nil
end

local function hitEnemyBuilding(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	local inst = result.Instance
	for id, info in knownBuildings do
		if info.ownerId ~= localPlayer.UserId then
			-- Match on Base part or any part whose parent is the same model
			if info.base == inst or info.base.Parent == inst.Parent then
				return id
			end
		end
	end
	return nil
end

-- Returns the Model that owns a building's Base part, or nil.
local function buildingModel(bid: string): Model?
	local info = knownBuildings[bid]
	if not info then return nil end
	local parent = info.base.Parent
	return (parent and parent:IsA("Model")) and parent :: Model or nil
end

-- Show/clear the thin white hover outline.
local function setHover(bid: string?)
	if bid == hoverBuildingId then return end
	if hoverBox then hoverBox:Destroy(); hoverBox = nil end
	if hoverRing then hoverRing:Destroy(); hoverRing = nil end
	hoverBuildingId = bid

	-- Don't overlap with the selection box on the same building.
	if not bid or bid == selectedBuildingId then return end

	-- Range ring for turrets and mines
	local range = getBuildingRange(bid)
	if range then
		local info = knownBuildings[bid]
		if info then
			local pos = info.base.Position
			hoverRing = RangeRing.create(range, pos.X, pos.Z, terrainHeightAt(pos.X, pos.Z))
		end
	end

	local model = buildingModel(bid)
	if not model then return end

	local box                = Instance.new("SelectionBox")
	box.Adornee              = model
	box.Color3               = Color3.fromRGB(255, 255, 255)
	box.LineThickness        = 0.05
	box.SurfaceTransparency  = 1
	box.Parent               = workspace
	hoverBox                 = box
end

local function clearMultiBldBoxes()
	for _, box in multiBldBoxes do box:Destroy() end
	multiBldBoxes = {}
end

-- Show/clear the teal selection box with a slight surface fill.
local function selectBuilding(bid: string?)
	if selectedBuildingBox then selectedBuildingBox:Destroy(); selectedBuildingBox = nil end
	if selectedRing then selectedRing:Destroy(); selectedRing = nil end
	clearMultiBldBoxes()
	selectedBuildingId = bid

	-- Re-evaluate hover so it doesn't stack on the newly selected building.
	setHover(hoverBuildingId == bid and nil or hoverBuildingId)

	if not bid then return end

	-- Range ring for turrets and mines
	local range = getBuildingRange(bid)
	if range then
		local info = knownBuildings[bid]
		if info then
			local pos = info.base.Position
			selectedRing = RangeRing.create(range, pos.X, pos.Z, terrainHeightAt(pos.X, pos.Z))
		end
	end

	local model = buildingModel(bid)
	if not model then return end

	local box                = Instance.new("SelectionBox")
	box.Adornee              = model
	box.Color3               = Color3.fromRGB(80, 255, 180)
	box.LineThickness        = 0.10
	box.SurfaceTransparency  = 0.78
	box.SurfaceColor3        = Color3.fromRGB(80, 255, 180)
	box.Parent               = workspace
	selectedBuildingBox      = box

	-- Auto-clear when the building is destroyed.
	local info = knownBuildings[bid]
	if info then
		info.base.Destroying:Connect(function()
			if selectedBuildingId ~= bid then return end
			if selectedBuildingBox then selectedBuildingBox:Destroy(); selectedBuildingBox = nil end
			if selectedRing then selectedRing:Destroy(); selectedRing = nil end
			selectedBuildingId = nil
		end)
	end
end

-- Returns true if a world position is within the current viewport.
local function isOnScreen(worldPos: Vector3): boolean
	local sv = workspace.CurrentCamera:WorldToViewportPoint(worldPos)
	if sv.Z <= 0 then return false end
	local vp = workspace.CurrentCamera.ViewportSize
	return sv.X >= 0 and sv.X <= vp.X and sv.Y >= 0 and sv.Y <= vp.Y
end

-- Select all owned visible units of the same UnitType as the given id.
local function selectAllSameUnitOnScreen(id: string)
	local info = knownUnits[id]
	if not info then return end
	local ut = info.part:FindFirstChild("UnitType") :: StringValue?
	local targetType = ut and ut.Value
	selected = {}
	for uid, uinfo in knownUnits do
		if uinfo.ownerId ~= localPlayer.UserId then continue end
		if not uinfo.part.Parent then continue end
		local ut2 = uinfo.part:FindFirstChild("UnitType") :: StringValue?
		if (ut2 and ut2.Value) ~= targetType then continue end
		if isOnScreen(uinfo.part.Position) then
			table.insert(selected, uid)
		end
	end
	notify()
end

-- Show selection boxes on all owned visible buildings of the same type.
-- The panel is opened for `primaryId` by the caller via selectBuilding().
local function multiSelectBuildingsOnScreen(primaryId: string)
	clearMultiBldBoxes()
	local primary = knownBuildings[primaryId]
	if not primary then return end
	local cam = workspace.CurrentCamera
	local vp  = cam.ViewportSize
	for bid, binfo in knownBuildings do
		if bid == primaryId then continue end
		if binfo.ownerId ~= localPlayer.UserId then continue end
		if binfo.buildingType ~= primary.buildingType then continue end
		local sv = cam:WorldToViewportPoint(binfo.base.Position)
		if sv.Z <= 0 or sv.X < 0 or sv.X > vp.X or sv.Y < 0 or sv.Y > vp.Y then continue end
		local model2 = buildingModel(bid)
		if not model2 then continue end
		local box               = Instance.new("SelectionBox")
		box.Adornee             = model2
		box.Color3              = Color3.fromRGB(80, 255, 180)
		box.LineThickness       = 0.10
		box.SurfaceTransparency = 0.78
		box.SurfaceColor3       = Color3.fromRGB(80, 255, 180)
		box.Parent              = workspace
		multiBldBoxes[bid]      = box
		binfo.base.Destroying:Connect(function()
			local b = multiBldBoxes[bid]
			if b then b:Destroy(); multiBldBoxes[bid] = nil end
		end)
	end
end

local function boxSelect(x0: number, y0: number, x1: number, y1: number)
	selected = {}
	for id, info in knownUnits do
		if info.ownerId ~= localPlayer.UserId then continue end
		local sp = workspace.CurrentCamera:WorldToViewportPoint(info.part.Position)
		if sp.X >= x0 and sp.X <= x1 and sp.Y >= y0 and sp.Y <= y1 and sp.Z > 0 then
			table.insert(selected, id)
		end
	end
	notify()
end

function UnitController.init(network, cameraModule, frame: Frame, isBlocked: () -> boolean)
	dragFrame    = frame
	isBlockedFn  = isBlocked

	-- ── Right-mouse drag-formation state ───────────────────────────────────────
	local rmbActive      = false
	local rmbStartGround: Vector3? = nil
	local rmbAtkMove     = false
	local rmbDragging    = false
	local rmbPath: { Vector3 } = {}   -- freehand polyline the cursor traced (flat)
	local PATH_SAMPLE_MIN = 4         -- studs between recorded path points

	-- Returns the traced path with the live cursor appended as the final point so
	-- the polyline always reaches the cursor between samples.
	local function renderPath(cur: Vector3): { Vector3 }
		local rp = table.clone(rmbPath)
		local last = rp[#rp]
		if not last or (cur - last).Magnitude > 0.5 then table.insert(rp, cur) end
		return rp
	end

	-- A plain right-click order (no drag): focus-attack an enemy under the cursor,
	-- otherwise a single move / attack-move. Mirrors the classic behaviour.
	local function issueClickOrder(ground: Vector3?)
		if not rmbAtkMove then
			local enemyUnitId = hitEnemyUnit()
			if enemyUnitId then
				maybeUnitVoice()
				network.focusAttack(selected, enemyUnitId, "unit")
				if ground then spawnMovePing(ground, true) end
				return
			end
			local enemyBldId = hitEnemyBuilding()
			if enemyBldId then
				maybeUnitVoice()
				network.focusAttack(selected, enemyBldId, "building")
				if ground then spawnMovePing(ground, true) end
				return
			end
		end
		if ground then
			maybeUnitVoice()
			if rmbAtkMove then
				network.attackMoveUnits(selected, ground)
			else
				network.moveUnits(selected, ground)
			end
			spawnMovePing(ground, rmbAtkMove)
			if onMoveIssuedCb then onMoveIssuedCb() end
		end
	end

	-- While the right button is held, grow the formation preview once the cursor
	-- has travelled past the drag threshold (needs 2+ units to form a line).
	RunService.RenderStepped:Connect(function()
		if not rmbActive or not rmbStartGround then return end
		local cur = cameraModule.getGroundPosition()
		if not cur then return end
		cur = Vector3.new(cur.X, 0, cur.Z)
		rmbAtkMove = atkMoveHeld  -- allow toggling A mid-drag
		if not rmbDragging then
			if #selected >= 2 and (cur - rmbStartGround).Magnitude >= FORMATION_DRAG_MIN then
				rmbDragging = true
				rmbPath = { rmbStartGround }
			end
		end
		if rmbDragging then
			-- Record points as the cursor travels so the formation follows the curve.
			local last = rmbPath[#rmbPath]
			if not last or (cur - last).Magnitude >= PATH_SAMPLE_MIN then
				table.insert(rmbPath, cur)
			end
			updateFormationPreview(renderPath(cur), rmbAtkMove)
		end
	end)

	-- Right button released: a drag issues a line formation; a click falls back to
	-- the standard single-point order.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
		if not rmbActive then return end
		rmbActive = false
		clearFormationPreview()
		local dragging = rmbDragging
		local path     = rmbPath
		rmbStartGround = nil
		rmbDragging    = false
		rmbPath        = {}

		if #selected == 0 then return end
		local endG = cameraModule.getGroundPosition()

		if dragging and endG and #selected >= 2 then
			endG = Vector3.new(endG.X, 0, endG.Z)
			local last = path[#path]
			if not last or (endG - last).Magnitude > 0.5 then table.insert(path, endG) end
			local ids, positions = buildFormationOrders(selected, path)
			maybeUnitVoice()
			network.formationMove(ids, positions, rmbAtkMove)
			spawnMovePing(endG, rmbAtkMove)
			if onMoveIssuedCb then onMoveIssuedCb() end
		else
			issueClickOrder(endG)
		end
	end)

	-- Track all replicated units; auto-clean when a unit is destroyed
	network.onUnitSpawned(function(id: string, ownerId: number, _pos: Vector3)
		task.spawn(function()
			local folder = workspace:WaitForChild("Units", 10)
			if not folder then return end
			local part = folder:WaitForChild(id, 10) :: BasePart
			if not part then return end
			knownUnits[id] = { part = part, ownerId = ownerId }

			if ownerId == localPlayer.UserId then
				local ut = part:FindFirstChild("UnitType")
				if ut then
					if      ut.Value == "Soldier" then playSoldierVoice()
					elseif  ut.Value == "Tank"    then playTankVoice()
					end
				end
			end

			part.Destroying:Connect(function()
				knownUnits[id] = nil
				-- Remove from active selection
				for i = #selected, 1, -1 do
					if selected[i] == id then table.remove(selected, i); break end
				end
				-- Clean up SelectionBox
				local box = selectionBoxes[id]
				if box then box:Destroy(); selectionBoxes[id] = nil end
				notify()
			end)
		end)
	end)

	-- Unit death sounds
	network.onUnitDied(function(unitType: string, _pos: Vector3)
		if      unitType == "Tank"    then playTankDeath()
		elseif  unitType == "Soldier" then playSoldierDeath()
		elseif  unitType == "Lamprey" then playLampreyDeath()
		end
	end)

	-- Track all replicated buildings for click detection
	network.onBuildingPlaced(function(id: string, ownerId: number, _pos: Vector3, buildingType: string)
		task.spawn(function()
			local folder = workspace:WaitForChild("Buildings", 10)
			if not folder then return end
			local model = folder:WaitForChild(id, 10)
			if not model then return end
			local base = model:WaitForChild("Base", 5) :: BasePart
			if not base then return end
			knownBuildings[id] = { base = base, ownerId = ownerId, buildingType = buildingType or "Barracks" }

			base.Destroying:Connect(function()
				knownBuildings[id] = nil
				if hoverBuildingId == id then
					if hoverBox  then hoverBox:Destroy();  hoverBox  = nil end
					if hoverRing then hoverRing:Destroy(); hoverRing = nil end
					hoverBuildingId = nil
				end
			end)
		end)
	end)

	-- Hover highlight: update whenever the mouse moves.
	-- Skip when cursor is over any GUI element to avoid highlighting buildings
	-- that are visually beneath panels.
	mouse.Move:Connect(function()
		if isBlockedFn and isBlockedFn() then
			setHover(nil)
			return
		end
		local mp  = UserInputService:GetMouseLocation()
		local gui = localPlayer.PlayerGui:GetGuiObjectsAtPosition(mp.X, mp.Y)
		if #gui > 0 then
			setHover(nil)
			return
		end
		setHover(hitBuilding())
	end)

	-- Input
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		-- F2: select all owned living units (works even during building placement)
		if input.KeyCode == Enum.KeyCode.F2 then
			selected = {}
			for id, info in knownUnits do
				if info.ownerId == localPlayer.UserId and info.part.Parent then
					table.insert(selected, id)
				end
			end
			notify()
			selectBuilding(nil)
			if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
			if onMineSelectedCb     then onMineSelectedCb(nil)     end
			if onCCSelectedCb       then onCCSelectedCb(nil)       end
			if onTurretSelectedCb   then onTurretSelectedCb(nil)   end
			if onBlobSelectedCb     then onBlobSelectedCb(nil)     end
			if onDeployerSelectedCb then onDeployerSelectedCb(nil) end
			return
		end

		-- A: hold for attack-move mode
		if input.KeyCode == Enum.KeyCode.A then
			atkMoveHeld = true
			return
		end

		if isBlockedFn and isBlockedFn() then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart  = UserInputService:GetMouseLocation()
			dragEnd    = dragStart
			isDragging = true

		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- Begin a right-mouse drag. The order is issued on release:
			-- a quick click = single move / focus-attack; a drag = line formation.
			if #selected == 0 then return end
			local ground = cameraModule.getGroundPosition()
			if not ground then return end
			rmbActive      = true
			rmbStartGround = Vector3.new(ground.X, 0, ground.Z)
			rmbAtkMove     = atkMoveHeld
			rmbDragging    = false

		elseif input.KeyCode == Enum.KeyCode.Escape then
			if onBarracksSelectedCb then onBarracksSelectedCb(nil) end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.A then
			atkMoveHeld = false
		end
	end)

	-- Mouse move: update drag box
	UserInputService.InputChanged:Connect(function(input)
		if not isDragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		dragEnd = UserInputService:GetMouseLocation()
		local d = dragEnd - dragStart
		if math.abs(d.X) > MIN_DRAG or math.abs(d.Y) > MIN_DRAG then
			if dragFrame then
				-- GetMouseLocation() is in raw viewport space; ScreenGui positions
				-- are offset by the GUI inset (top bar), so subtract it.
				-- Then divide by UIScale so design-unit positions land on the cursor
				-- at any resolution (RTSHUD applies a UIScale for scaling).
				local inset      = GuiService:GetGuiInset()
				local sg         = dragFrame.Parent
				local scaleObj   = sg and sg:FindFirstChildWhichIsA("UIScale")
				local scale      = (scaleObj and scaleObj.Scale > 0) and scaleObj.Scale or 1
				local x0 = (math.min(dragStart.X, dragEnd.X) - inset.X) / scale
				local y0 = (math.min(dragStart.Y, dragEnd.Y) - inset.Y) / scale
				dragFrame.Position = UDim2.fromOffset(x0, y0)
				dragFrame.Size     = UDim2.fromOffset(math.abs(d.X) / scale, math.abs(d.Y) / scale)
				dragFrame.Visible  = true
			end
		end
	end)

	-- LMB up: finalise selection
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not isDragging then return end
		isDragging = false
		if dragFrame then dragFrame.Visible = false end
		if isBlockedFn and isBlockedFn() then return end

		local d = dragEnd - dragStart
		if math.abs(d.X) > MIN_DRAG or math.abs(d.Y) > MIN_DRAG then
			-- Box select
			lastClickTime   = 0
			lastClickTarget = nil
			clearSelection()
			selectBuilding(nil)
			boxSelect(
				math.min(dragStart.X, dragEnd.X), math.min(dragStart.Y, dragEnd.Y),
				math.max(dragStart.X, dragEnd.X), math.max(dragStart.Y, dragEnd.Y)
			)
			if onBarracksSelectedCb  then onBarracksSelectedCb(nil)  end
			if onMineSelectedCb      then onMineSelectedCb(nil)      end
			if onCCSelectedCb        then onCCSelectedCb(nil)        end
			if onTurretSelectedCb    then onTurretSelectedCb(nil)    end
		else
			-- Single / double click — check unit first, then buildings
			local now = os.clock()
			local uid = hitUnit()
			if uid then
				local isDouble = (now - lastClickTime < DOUBLE_CLICK_SECS) and lastClickTarget == uid
				lastClickTime   = now
				lastClickTarget = uid
				if isDouble then
					selectAllSameUnitOnScreen(uid)
				else
					if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then clearSelection() end
					addToSelection(uid)
				end
				selectBuilding(nil)
				if onBarracksSelectedCb  then onBarracksSelectedCb(nil)  end
				if onMineSelectedCb      then onMineSelectedCb(nil)      end
				if onCCSelectedCb        then onCCSelectedCb(nil)        end
				if onTurretSelectedCb    then onTurretSelectedCb(nil)    end
			else
				local bid = hitBuilding()
				if bid then
					local isDouble = (now - lastClickTime < DOUBLE_CLICK_SECS) and lastClickTarget == bid
					lastClickTime   = now
					lastClickTarget = bid
					clearSelection()
					selectBuilding(bid)
					if isDouble then
						multiSelectBuildingsOnScreen(bid)
					end
					local info = knownBuildings[bid]
					local owned = info ~= nil and info.ownerId == localPlayer.UserId
					clearBuildingPanels()
					if owned and info.buildingType == "Barracks" then
						if onBarracksSelectedCb then onBarracksSelectedCb(bid) end
					elseif owned and info.buildingType == "Foundry" then
						if onMineSelectedCb then onMineSelectedCb(bid) end
					elseif owned and info.buildingType == "CommandCenter" then
						if onCCSelectedCb then onCCSelectedCb(bid) end
					elseif owned and info.buildingType == "Turret" then
						if onTurretSelectedCb then onTurretSelectedCb(bid) end
					elseif owned and info.buildingType == "CreepyBlob" then
						if onBlobSelectedCb then onBlobSelectedCb(bid) end
					elseif owned and info.buildingType == "Deployer" then
						if onDeployerSelectedCb then onDeployerSelectedCb(bid) end
					elseif owned and info.buildingType == "LampreyNest" then
						if onLampreyNestSelectedCb then onLampreyNestSelectedCb(bid) end
					elseif owned and info.buildingType == "EngineeringPost" then
						if onEngineeringSelectedCb then onEngineeringSelectedCb(bid) end
					end
				else
					lastClickTime   = 0
					lastClickTarget = nil
					clearSelection()
					selectBuilding(nil)
					clearBuildingPanels()
				end
			end
		end
	end)
end

function UnitController.getSelected(): {string}
	return selected
end

-- Programmatically select a single owned unit by id (used to auto-select the Core
-- the instant it deploys so the player can drive it immediately).
function UnitController.selectUnit(id: string)
	selected = { id }
	notify()
end

function UnitController.onSelectionChanged(fn: (number) -> ())
	onChangedCb = fn
end

function UnitController.onBarracksSelected(fn: (string?) -> ())
	onBarracksSelectedCb = fn
end

function UnitController.onMineSelected(fn: (string?) -> ())
	onMineSelectedCb = fn
end

function UnitController.onCCSelected(fn: (string?) -> ())
	onCCSelectedCb = fn
end

function UnitController.onTurretSelected(fn: (string?) -> ())
	onTurretSelectedCb = fn
end

function UnitController.onBlobSelected(fn: (string?) -> ())
	onBlobSelectedCb = fn
end

function UnitController.onDeployerSelected(fn: (string?) -> ())
	onDeployerSelectedCb = fn
end

function UnitController.onLampreyNestSelected(fn: (string?) -> ())
	onLampreyNestSelectedCb = fn
end

function UnitController.onEngineeringSelected(fn: (string?) -> ())
	onEngineeringSelectedCb = fn
end

-- Returns the primary selected building ID plus all secondary double-click selected IDs.
function UnitController.getSelectedBuildingIds(): {string}
	local result: {string} = {}
	if selectedBuildingId then
		table.insert(result, selectedBuildingId)
	end
	for bid in multiBldBoxes do
		table.insert(result, bid)
	end
	return result
end

function UnitController.onMoveIssued(fn: () -> ())
	onMoveIssuedCb = fn
end

return UnitController
