local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config"))
local RangeRing        = require(script.Parent:WaitForChild("RangeRing"))
local SelectionRing    = require(script.Parent:WaitForChild("SelectionRing"))
local InjectPlants     = require(Shared:WaitForChild("InjectPlants"))

local UnitController = {}

local localPlayer  = Players.LocalPlayer
local mouse        = localPlayer:GetMouse()
local selected: {string}  = {}
local knownUnits: {[string]: {part: BasePart, ownerId: number}} = {}
local knownBuildings: {[string]: {base: BasePart, ownerId: number, buildingType: string}} = {}
local unitRings: {[string]: SelectionRing.Ring} = {}
local onChangedCb: ((number) -> ())?
local onBarracksSelectedCb:  ((string?) -> ())?
local onMineSelectedCb:      ((string?) -> ())?
local onCCSelectedCb:        ((string?) -> ())?
local onTurretSelectedCb:    ((string?) -> ())?
local onBlobSelectedCb:      ((string?) -> ())?
local onDeployerSelectedCb:  ((string?) -> ())?
local onTestSelectedCb:      ((string?) -> ())?
local onLampreyNestSelectedCb: ((string?) -> ())?
local onEngineeringSelectedCb: ((string?) -> ())?
-- Fires for an owned building that has no dedicated panel (so init.client can show
-- a generic "upgrades coming soon" command card). (buildingId, buildingType) or nil.
local onOtherBuildingSelectedCb: ((string?, string?) -> ())?
-- Fires with the selected Egg-Sac egg ids (the clicked egg + its tentacle-tree descendants),
-- or nil to close the panel, so init.client can show the EggPanel where the player chooses
-- what those eggs hatch.
local onEggSelectedCb: (({ string }?) -> ())?
-- Fires whenever the selected UNIT set changes (with the current owned-unit ids),
-- so init.client can show a unit command card (e.g. the Survivor upgrade menu).
local onUnitsSelectedCb:     (({string}) -> ())?
-- Fires with the ordered unit ids whenever the player hand-issues an order (move,
-- attack-move, focus-attack, or formation), so army-command modes can release them.
local onMoveIssuedCb:        (({string}) -> ())?
local isBlockedFn: (() -> boolean)?
-- The Camera module, handed over in init. The plant picker needs the ground point
-- under the cursor, which is the camera's to work out.
local cameraRef: any = nil
-- Fires with the wild plant the player clicked (or nil on deselect), so init.client can
-- put its name on the command card.
local onPlantSelectedCb: ((Model?) -> ())? = nil
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
	if onTestSelectedCb        then onTestSelectedCb(nil)        end
	if onLampreyNestSelectedCb then onLampreyNestSelectedCb(nil) end
	if onEngineeringSelectedCb then onEngineeringSelectedCb(nil) end
	if onOtherBuildingSelectedCb then onOtherBuildingSelectedCb(nil, nil) end
end

-- Like clearBuildingPanels but skips the panel for `exceptType` — used when
-- selecting a building so we don't hide-then-immediately-reshow the same panel.
-- (Hiding runs a delayed collapse that would otherwise fire ~0.18 s later and
-- hide the freshly-opened panel — the "nodes appear then vanish" bug.)
local function clearBuildingPanelsExcept(exceptType: string?)
	if exceptType ~= "Barracks"        and onBarracksSelectedCb    then onBarracksSelectedCb(nil)    end
	if exceptType ~= "Foundry"         and onMineSelectedCb        then onMineSelectedCb(nil)        end
	if exceptType ~= "CommandCenter"   and onCCSelectedCb          then onCCSelectedCb(nil)          end
	if exceptType ~= "Turret"          and onTurretSelectedCb      then onTurretSelectedCb(nil)      end
	if exceptType ~= "CreepyBlob"      and onBlobSelectedCb        then onBlobSelectedCb(nil)        end
	if exceptType ~= "Deployer"        and onDeployerSelectedCb    then onDeployerSelectedCb(nil)    end
	if exceptType ~= "TEST"            and onTestSelectedCb        then onTestSelectedCb(nil)        end
	if exceptType ~= "LampreyNest"     and onLampreyNestSelectedCb then onLampreyNestSelectedCb(nil) end
	if exceptType ~= "EngineeringPost" and onEngineeringSelectedCb then onEngineeringSelectedCb(nil) end
	-- Always clear the generic "other" structure card; the click handler re-shows it
	-- afterwards if the newly-selected building has no dedicated panel.
	if onOtherBuildingSelectedCb then onOtherBuildingSelectedCb(nil, nil) end
end

-- ── Selection ring palette ────────────────────────────────────────────────────
-- One language for "this is picked": a lit circle on the ground, coloured by what kind
-- of thing is standing in it. Hover is always the same quiet white so it never competes
-- with a live selection.
local RING_UNIT  = Color3.fromRGB(90, 215, 255)
local RING_BLD   = Color3.fromRGB(80, 255, 180)
local RING_EGG   = Color3.fromRGB(255, 180, 90)
local RING_PLANT = Color3.fromRGB(215, 110, 255)
local RING_HOVER = Color3.fromRGB(235, 240, 245)

-- ── Building hover + selection highlight ──────────────────────────────────────
local hoverBuildingId:   string?            = nil
local hoverBldRing:      SelectionRing.Ring? = nil
local selectedBuildingId: string?           = nil
local selectedBldRing:   SelectionRing.Ring? = nil
local multiBldRings:     { [string]: SelectionRing.Ring } = {}  -- extra rings from double-click

-- ── Egg-Sac egg selection (own lightweight highlight; eggs aren't units/buildings) ──
-- Selecting an egg also selects its descendants in the tentacle tree, so a whole subtree
-- can be assigned a unit at once. Tracked as a set of egg ids → their highlight boxes.
local selectedEggIds:  { string }                          = {}
local selectedEggRings: { [string]: SelectionRing.Ring }   = {}

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
local SNIPER_VOICE_IDS      = {78319577229180}
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

-- The Mother answers a move order the way a marine does: one line, then quiet for a
-- while. The cooldown IS the feature -- right-clicking over and over is how anyone drives
-- a piece across an RTS map, and without it she stacks a dozen copies of herself over one
-- walk. Her order is issued from init.client (she is a building, not a unit), so the line
-- is exposed as UnitController.playMotherVoice.
local MOTHER_VOICE_IDS: { number }   = {}   -- her move-order line(s); empty = she stays quiet
local MOTHER_VOICE_COOLDOWN          = 2    -- seconds of silence after one plays
local MOTHER_VOICE_VOLUME            = 3    -- she is the size of a building; she carries
local motherVoiceAt                  = -math.huge

local function motherVoiceLine()
	if #MOTHER_VOICE_IDS == 0 then return end
	local now = os.clock()
	if now - motherVoiceAt < MOTHER_VOICE_COOLDOWN then return end
	motherVoiceAt = now
	playSound(MOTHER_VOICE_IDS[math.random(#MOTHER_VOICE_IDS)], 0.08, MOTHER_VOICE_VOLUME)
end

local function playSoldierVoice() playSound(SOLDIER_VOICE_IDS[math.random(#SOLDIER_VOICE_IDS)], 0.2, 1) end
local function playSniperVoice()  playSound(SNIPER_VOICE_IDS[math.random(#SNIPER_VOICE_IDS)],   0.12, 1) end
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
				if      ut.Value == "Tank"     then playTankVoice();    return
				elseif  ut.Value == "Sniper"   then playSniperVoice();  return
				elseif  ut.Value == "Survivor" then playSoldierVoice(); return
				end
			end
		end
	end
end

-- Ring size for a unit: its own footprint, with a floor under it so a 4-stud Survivor
-- still gets a circle that reads from the RTS camera height.
local function unitRingRadius(part: BasePart): number
	return math.max(2.2, SelectionRing.radiusFor(part, 0.5))
end

local function syncSelectionRings()
	-- Drop rings for units no longer selected
	local selectedSet: {[string]: boolean} = {}
	for _, id in selected do selectedSet[id] = true end

	for id, ring in unitRings do
		if not selectedSet[id] then
			SelectionRing.destroy(ring)
			unitRings[id] = nil
		end
	end

	-- Ring the newly selected ones
	for _, id in selected do
		if unitRings[id] then continue end
		local info = knownUnits[id]
		if not info or not info.part.Parent then continue end  -- stale / destroyed

		-- No per-ring Destroying hook: a unit dying already drops itself from the
		-- selection (see network.onUnitSpawned) which sweeps its ring on the next sync,
		-- and SelectionRing drops any ring whose target left the world. Connecting here
		-- would add one connection per unit per re-selection and never release them.
		unitRings[id] = SelectionRing.attach(info.part, {
			color  = RING_UNIT,
			radius = unitRingRadius(info.part),
		})
	end
end

local function notify()
	syncSelectionRings()
	if onChangedCb then onChangedCb(#selected) end
	if onUnitsSelectedCb then onUnitsSelectedCb(selected) end
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
	local inst = result.Instance
	for id, info in knownUnits do
		-- Riders aboard a Roller aren't clickable (they're tagged "Carried" by the server).
		if info.part:GetAttribute("Carried") then continue end
		-- Match the pivot part itself OR any descendant (e.g. the Leech's roomy
		-- invisible ClickHitbox), so clicking the visible body selects the unit.
		if info.ownerId == localPlayer.UserId
			and (info.part == inst or inst:IsDescendantOf(info.part)) then
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
			if inst == info.base or (model and inst:IsDescendantOf(model)) then
				return id
			end
		end
	end
	return nil
end

-- Raycast for an owned Egg-Sac nest under the cursor. Each one is a clickable Model (the
-- bowl, plus its egg when one is present) tagged with an "EggId" attribute, living in
-- workspace.EggNests. Returns the egg id and the clump Model, or nil.
local function hitEgg(): (string?, Instance?)
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	local inst: Instance? = result.Instance
	while inst and inst ~= workspace do
		local eid = inst:GetAttribute("EggId")
		if eid ~= nil then
			if inst:GetAttribute("EggOwnerId") == localPlayer.UserId then
				return eid :: string, inst
			end
			return nil
		end
		inst = inst.Parent
	end
	return nil
end

local function hitEnemyUnit(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	if not result then return nil end
	local inst = result.Instance
	for id, info in knownUnits do
		if info.part:GetAttribute("Carried") then continue end   -- riders aboard a Roller
		if info.ownerId ~= localPlayer.UserId
			and (info.part == inst or inst:IsDescendantOf(info.part)) then
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

-- An enemy egg or Egg-Sac nest under the cursor, as a focus-attack target id. Eggs
-- aren't buildings — they live in workspace.EggNests, or under a Lamprey Nest — but the
-- server accepts their id in the same focus order, so right-clicking one is identical to
-- right-clicking a structure. The id is stamped on the egg itself and on a nest's clump
-- (whose invisible Hitbox is what the ray actually lands on), so walk up a couple of
-- levels from whatever was hit.
local function hitEnemyEgg(): string?
	local ray    = mouse.UnitRay
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000)
	local inst: Instance? = result and result.Instance
	for _ = 1, 3 do
		if not inst then break end
		local id = inst:GetAttribute("EggTargetId")
		if type(id) == "string" then
			-- Found the clutch: only an enemy's is a target.
			if inst:GetAttribute("EggTargetOwner") ~= localPlayer.UserId then return id end
			return nil
		end
		inst = inst.Parent
	end
	return nil
end

-- Every building ring is drawn around the model's Base part. The base IS the footprint
-- the structure was placed on, which is what a ground ring wants; a model bounding box
-- would balloon out to cover the Hollowed Mother's sprawling tentacles and egg nests.

-- Show/clear the quiet white hover ring.
local function setHover(bid: string?)
	if bid == hoverBuildingId then return end
	if hoverBldRing then SelectionRing.destroy(hoverBldRing); hoverBldRing = nil end
	if hoverRing then hoverRing:Destroy(); hoverRing = nil end
	hoverBuildingId = bid

	-- Don't overlap with the selection ring on the same building.
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

	local binfo = knownBuildings[bid]
	if not binfo or not binfo.base.Parent then return end

	hoverBldRing = SelectionRing.attach(binfo.base, {
		color  = RING_HOVER,
		radius = SelectionRing.radiusFor(binfo.base, 1.0),
	})
end

local function clearMultiBldRings()
	for _, ring in multiBldRings do SelectionRing.destroy(ring) end
	multiBldRings = {}
end

-- Show/clear the teal selection ring under a structure.
local function selectBuilding(bid: string?)
	if selectedBldRing then SelectionRing.destroy(selectedBldRing); selectedBldRing = nil end
	if selectedRing then selectedRing:Destroy(); selectedRing = nil end
	clearMultiBldRings()
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

	local binfo = knownBuildings[bid]
	if not binfo or not binfo.base.Parent then return end

	selectedBldRing = SelectionRing.attach(binfo.base, {
		color  = RING_BLD,
		radius = SelectionRing.radiusFor(binfo.base, 1.0),
	})

	-- Auto-clear when the building is destroyed.
	binfo.base.Destroying:Connect(function()
		if selectedBuildingId ~= bid then return end
		if selectedBldRing then SelectionRing.destroy(selectedBldRing); selectedBldRing = nil end
		if selectedRing then selectedRing:Destroy(); selectedRing = nil end
		selectedBuildingId = nil
	end)
end

-- Returns true if a world position is within the current viewport.
local function isOnScreen(worldPos: Vector3): boolean
	local sv = workspace.CurrentCamera:WorldToViewportPoint(worldPos)
	if sv.Z <= 0 then return false end
	local vp = workspace.CurrentCamera.ViewportSize
	return sv.X >= 0 and sv.X <= vp.X and sv.Y >= 0 and sv.Y <= vp.Y
end

-- ── Wild plants ───────────────────────────────────────────────────────────────
-- The Mother's growths are scenery: no owner, no orders, nothing to command. Clicking
-- one only names it, so the player can walk up to something strange in the fog and be
-- told what it is and that a Mother could do something with it.
--
-- They are picked off the GROUND POINT under the cursor rather than by a ray at the
-- plant itself: every part of a plant is CanQuery = false, and giving each one a hitbox
-- would put a solid object in the path of the rays that drive move orders, building
-- placement and the Mother's own inject sight. This is the same snap her sight uses.
local PLANT_PICK_PAD   = 1.5    -- studs of slack beyond the plant's own spread
local PLANT_CACHE_SECS = 0.5    -- how long a scan of the plant folder is trusted

local selectedPlant:  Model? = nil
local plantRing:      SelectionRing.Ring? = nil
local hoverPlant:     Model? = nil
local plantHoverRing: SelectionRing.Ring? = nil

type PlantHit = { model: Model, x: number, z: number, r2: number }
local plantCache: { PlantHit } = {}
local plantCacheAt = 0

-- Plants never move once they are up, and there are hundreds of them, so their positions
-- are scanned on a timer rather than every time the mouse twitches.
local function refreshPlantCache()
	local now = os.clock()
	if now - plantCacheAt < PLANT_CACHE_SECS then return end
	plantCacheAt = now
	plantCache   = {}
	local folder = workspace:FindFirstChild("InjectPlants")
	if not folder then return end
	for _, m in folder:GetChildren() do
		if not m:IsA("Model") then continue end
		local variant = m:GetAttribute("Variant")
		if type(variant) ~= "string" then continue end
		local r   = ((InjectPlants.RADIUS :: any)[variant] or 4.5) + PLANT_PICK_PAD
		local pos = m:GetPivot().Position
		table.insert(plantCache, { model = m, x = pos.X, z = pos.Z, r2 = r * r })
	end
end

-- The plant under the cursor, or nil.
local function hitPlant(): Model?
	if not cameraRef then return nil end
	local g = cameraRef.getGroundPosition()
	if not g then return nil end
	refreshPlantCache()
	local best:  Model? = nil
	local bestD = math.huge
	for _, e in plantCache do
		if not e.model.Parent then continue end
		local dx, dz = e.x - g.X, e.z - g.Z
		local d = dx * dx + dz * dz
		if d < e.r2 and d < bestD then best, bestD = e.model, d end
	end
	return best
end

-- The part a plant's ring hangs off: its Anchor sits at the exact spot on the ground the
-- plant was grown from.
local function plantAnchor(m: Model): BasePart?
	local a = m.PrimaryPart or m:FindFirstChild("Anchor")
	return (a and a:IsA("BasePart")) and a :: BasePart or nil
end

local function plantRingRadius(m: Model): number
	local variant = m:GetAttribute("Variant")
	local r = (type(variant) == "string" and (InjectPlants.RADIUS :: any)[variant]) or 4.5
	return r + 0.6
end

local function clearPlantSelection()
	if plantRing then SelectionRing.destroy(plantRing); plantRing = nil end
	if selectedPlant then
		selectedPlant = nil
		if onPlantSelectedCb then onPlantSelectedCb(nil) end
	end
end

local function setPlantHover(m: Model?)
	if m == hoverPlant then return end
	hoverPlant = m
	if plantHoverRing then SelectionRing.destroy(plantHoverRing); plantHoverRing = nil end
	-- Never stack the hover ring on the plant that is already selected.
	if not m or m == selectedPlant then return end
	local anchor = plantAnchor(m)
	if not anchor then return end
	plantHoverRing = SelectionRing.attach(anchor, {
		color  = RING_HOVER,
		radius = plantRingRadius(m),
	})
end

local function selectPlant(m: Model)
	clearPlantSelection()
	local anchor = plantAnchor(m)
	if not anchor then return end
	setPlantHover(nil)
	selectedPlant = m
	plantRing = SelectionRing.attach(anchor, {
		color  = RING_PLANT,
		radius = plantRingRadius(m),
	})
	-- A Mother injecting it bursts the plant; the card and ring go with it.
	m.Destroying:Connect(function()
		if selectedPlant == m then clearPlantSelection() end
	end)
	if onPlantSelectedCb then onPlantSelectedCb(m) end
end

-- Clear all egg highlights + tell init.client to close the EggPanel.
local function clearEggSelection()
	for id, ring in selectedEggRings do SelectionRing.destroy(ring); selectedEggRings[id] = nil end
	if #selectedEggIds > 0 then
		selectedEggIds = {}
		if onEggSelectedCb then onEggSelectedCb(nil) end
	end
end

-- Scan the local player's egg clump Models, returning eggId → clump Model plus a
-- parentEggId → { childEggId } adjacency map (from each clump's "ParentEgg" attribute).
-- The adjacency map no longer drives selection (a click takes one egg); it is kept because
-- the tentacle tree is still what the nests are physically grown along.
-- Nests sit in workspace.EggNests (grouped per owning Mother) rather than under the
-- Mother's model, so they stay put when she uproots and walks off.
local function scanOwnedEggs(): ({ [string]: Instance }, { [string]: { string } })
	local models:   { [string]: Instance }   = {}
	local children: { [string]: { string } } = {}
	local folder = workspace:FindFirstChild("EggNests")
	if not folder then return models, children end
	for _, cc in folder:GetChildren() do
		for _, m in cc:GetChildren() do
			local eid = m:GetAttribute("EggId")
			if eid ~= nil and m:GetAttribute("EggOwnerId") == localPlayer.UserId then
				models[eid :: string] = m
				local pid = m:GetAttribute("ParentEgg")
				if pid ~= nil then
					local list = children[pid :: string]
					if not list then list = {}; children[pid :: string] = list end
					table.insert(list, eid :: string)
				end
			end
		end
	end
	return models, children
end

-- Highlight the given eggs and open the panel for the set. Picking a creature spends every
-- ripe egg in it. Caller supplies the id list plus the eggId → clump Model lookup.
local function applyEggSelection(ids: { string }, models: { [string]: Instance })
	selectedEggIds = ids
	for _, id in ids do
		local m = models[id]
		-- Ring the nest bowl: the egg only exists while a creature is incubating, and it
		-- changes size as it grows, so the bowl is the one steady thing to circle.
		local anchor = m and ((m :: any):FindFirstChild("Bowl") or (m :: any):FindFirstChild("Egg"))
		if anchor and anchor:IsA("BasePart") then
			selectedEggRings[id] = SelectionRing.attach(anchor, {
				color  = RING_EGG,
				radius = SelectionRing.radiusFor(anchor, 0.8),
			})
			m.Destroying:Connect(function()
				local r = selectedEggRings[id]
				if r then SelectionRing.destroy(r); selectedEggRings[id] = nil end
			end)
		end
	end
	if onEggSelectedCb then onEggSelectedCb(ids) end
end

-- Select the clicked egg and NOTHING else. A click used to take the whole tentacle
-- subtree under it, which made a single egg impossible to spend on its own: every pick
-- went to the sisters too. The tree is still there, it just no longer decides selection.
-- Double-clicking is how you get the whole colony (see below). Caller has already cleared
-- unit/building selection.
local function selectEgg(rootEggId: string)
	clearEggSelection()
	clearPlantSelection()
	local models = scanOwnedEggs()
	if not models[rootEggId] then return end
	applyEggSelection({ rootEggId }, models)
end

-- Is this nest's egg grown and waiting to be spent? The server stamps "EggReady" on the
-- egg part as it ripens and clears it the moment it is spent, so it replicates.
local function eggIsReady(clump: Instance): boolean
	local egg = (clump :: any):FindFirstChild("Egg")
	return egg ~= nil and egg:GetAttribute("EggReady") == true
end

-- Double-click on an egg: take every AVAILABLE egg on screen, meaning every one of yours
-- that has finished growing. Since a hatch is now a one-shot order rather than a standing
-- choice, this is the "spend the whole colony at once" gesture: double-click, pick a
-- creature, and every ripe nest hatches one.
--
-- Eggs still growing are deliberately left out. Including them would put tiles in front of
-- the player that silently do nothing for part of the selection.
local function selectAllReadyEggsOnScreen(rootEggId: string)
	local models = scanOwnedEggs()
	if not models[rootEggId] then return end

	clearEggSelection()
	clearPlantSelection()
	local ids: { string } = {}
	for id, m in models do
		if not eggIsReady(m) then continue end
		local adornee = (m :: any):FindFirstChild("Bowl") or (m :: any):FindFirstChild("Egg") or m
		local pos = adornee:IsA("BasePart") and adornee.Position or (m :: any):GetPivot().Position
		if isOnScreen(pos) then table.insert(ids, id) end
	end
	-- Double-clicking a nest whose own egg is still growing would otherwise select nothing
	-- and read as a dead click; fall back to just that egg.
	if #ids == 0 then applyEggSelection({ rootEggId }, models); return end
	applyEggSelection(ids, models)
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
	clearMultiBldRings()
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
		multiBldRings[bid] = SelectionRing.attach(binfo.base, {
			color  = RING_BLD,
			radius = SelectionRing.radiusFor(binfo.base, 1.0),
		})
		binfo.base.Destroying:Connect(function()
			local r = multiBldRings[bid]
			if r then SelectionRing.destroy(r); multiBldRings[bid] = nil end
		end)
	end
end

-- Everything that is not a unit selection: the building ring and its panel, the egg
-- pick and the plant pick. Called before taking a fresh set of units.
local function clearNonUnitSelection()
	selectBuilding(nil)
	clearEggSelection()
	clearPlantSelection()
	clearBuildingPanels()
end

-- Select a building exactly as clicking on it does: its ring, its range ring, and the
-- one panel that belongs to it. `multi` also rings every visible sibling of its type
-- (the double-click gesture). Shared by the click handler and the quick-select bar, so
-- a button press and a click land on identical state.
local function applyBuildingSelection(bid: string, multi: boolean?)
	clearEggSelection()
	clearPlantSelection()
	clearSelection()
	selectBuilding(bid)
	if multi then multiSelectBuildingsOnScreen(bid) end

	local info  = knownBuildings[bid]
	local owned = info ~= nil and info.ownerId == localPlayer.UserId
	clearBuildingPanelsExcept(owned and info.buildingType or nil)
	if not owned then return end
	local bt = (info :: any).buildingType
	if bt == "Barracks" then
		if onBarracksSelectedCb then onBarracksSelectedCb(bid) end
	elseif bt == "Foundry" then
		if onMineSelectedCb then onMineSelectedCb(bid) end
	elseif bt == "CommandCenter" then
		if onCCSelectedCb then onCCSelectedCb(bid) end
	elseif bt == "Turret" then
		if onTurretSelectedCb then onTurretSelectedCb(bid) end
	elseif bt == "CreepyBlob" then
		if onBlobSelectedCb then onBlobSelectedCb(bid) end
	elseif bt == "Deployer" then
		if onDeployerSelectedCb then onDeployerSelectedCb(bid) end
	elseif bt == "TEST" then
		if onTestSelectedCb then onTestSelectedCb(bid) end
	elseif bt == "LampreyNest" then
		if onLampreyNestSelectedCb then onLampreyNestSelectedCb(bid) end
	elseif bt == "EngineeringPost" then
		if onEngineeringSelectedCb then onEngineeringSelectedCb(bid) end
	else
		-- Owned building with no dedicated panel -> generic command card.
		if onOtherBuildingSelectedCb then onOtherBuildingSelectedCb(bid, bt) end
	end
end

-- Take every owned, free-standing unit whose type `want` accepts. Riders aboard a
-- Roller are never taken: the Roller carries them, and ordering a passenger about is
-- an order that goes nowhere.
local function selectUnitsMatching(want: (string?) -> boolean): number
	selected = {}
	for id, info in knownUnits do
		if info.ownerId ~= localPlayer.UserId or not info.part.Parent then continue end
		if info.part:GetAttribute("Carried") then continue end
		local ut = info.part:FindFirstChild("UnitType") :: StringValue?
		if want(ut and ut.Value or nil) then table.insert(selected, id) end
	end
	notify()
	return #selected
end

-- Box-select owned units inside the rectangle. Returns the id of the player's Command
-- Center if the box caught THAT instead, which the caller opens as a building selection.
--
-- The Hollowed Mother walks with the army and is the piece that player moves most, but she
-- is a BUILDING, so a units-only box never touched her and she could only be picked by
-- clicking her directly. She is taken only when the box caught no units at all: a
-- selection cannot hold units and a building at once, and dragging a box over a fight
-- should give you the fighters, not the thing standing behind them.
local function boxSelect(x0: number, y0: number, x1: number, y1: number): string?
	local cam = workspace.CurrentCamera
	local function inBox(pos: Vector3): boolean
		local sp = cam:WorldToViewportPoint(pos)
		return sp.X >= x0 and sp.X <= x1 and sp.Y >= y0 and sp.Y <= y1 and sp.Z > 0
	end

	selected = {}
	for id, info in knownUnits do
		if info.ownerId ~= localPlayer.UserId then continue end
		if info.part:GetAttribute("Carried") then continue end   -- riders aboard a Roller
		if inBox(info.part.Position) then table.insert(selected, id) end
	end
	notify()
	if #selected > 0 then return nil end

	for bid, info in knownBuildings do
		if info.ownerId ~= localPlayer.UserId then continue end
		if info.buildingType ~= "CommandCenter" then continue end
		if not info.base.Parent then continue end
		-- Her footprint, not just her centre. A unit is a dot on screen so one point is
		-- enough; the Mother is tens of studs across, and a box drawn over the half of her
		-- you can see would miss a centre-only test and read as a dead drag.
		local c  = info.base.Position
		local hx = info.base.Size.X * 0.5
		local hz = info.base.Size.Z * 0.5
		if inBox(c)
			or inBox(c + Vector3.new(-hx, 0, -hz)) or inBox(c + Vector3.new(hx, 0, -hz))
			or inBox(c + Vector3.new(-hx, 0,  hz)) or inBox(c + Vector3.new(hx, 0,  hz)) then
			return bid
		end
	end
	return nil
end

function UnitController.init(network, cameraModule, frame: Frame, isBlocked: () -> boolean)
	dragFrame    = frame
	isBlockedFn  = isBlocked
	cameraRef    = cameraModule

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
			-- Right-click an owned Roller with other units selected → those units climb in.
			local ownUnitId = hitUnit()
			if ownUnitId then
				local ownType = UnitController.getUnitType(ownUnitId)
				if ownType == "Roller" then
					local riders: { string } = {}
					for _, sid in selected do
						if sid ~= ownUnitId and UnitController.getUnitType(sid) ~= "Roller" then
							table.insert(riders, sid)
						end
					end
					if #riders > 0 then
						maybeUnitVoice()
						network.rollerMount(ownUnitId, riders)
						if ground then spawnMovePing(ground, false) end
						if onMoveIssuedCb then onMoveIssuedCb(selected) end
						return
					end
				end
			end
			local enemyUnitId = hitEnemyUnit()
			if enemyUnitId then
				maybeUnitVoice()
				network.focusAttack(selected, enemyUnitId, "unit")
				if ground then spawnMovePing(ground, true) end
				if onMoveIssuedCb then onMoveIssuedCb(selected) end
				return
			end
			local enemyBldId = hitEnemyBuilding()
			if enemyBldId then
				maybeUnitVoice()
				network.focusAttack(selected, enemyBldId, "building")
				if ground then spawnMovePing(ground, true) end
				if onMoveIssuedCb then onMoveIssuedCb(selected) end
				return
			end
			local enemyEggId = hitEnemyEgg()
			if enemyEggId then
				maybeUnitVoice()
				network.focusAttack(selected, enemyEggId, "building")
				if ground then spawnMovePing(ground, true) end
				if onMoveIssuedCb then onMoveIssuedCb(selected) end
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
			if onMoveIssuedCb then onMoveIssuedCb(selected) end
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
			if onMoveIssuedCb then onMoveIssuedCb(selected) end
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
					if      ut.Value == "Survivor" then playSoldierVoice()
					elseif  ut.Value == "Sniper"   then playSniperVoice()
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
				-- Clean up its selection ring
				local ring = unitRings[id]
				if ring then SelectionRing.destroy(ring); unitRings[id] = nil end
				notify()
			end)
		end)
	end)

	-- Unit death sounds
	network.onUnitDied(function(unitType: string, _pos: Vector3)
		if      unitType == "Tank"    then playTankDeath()
		elseif  unitType == "Survivor" then playSoldierDeath()
		elseif  unitType == "Lamprey" then playLampreyDeath()
		end
	end)

	-- Register a building for click detection + auto-cleanup on destroy.
	local function trackBuilding(id: string, base: BasePart, ownerId: number, buildingType: string)
		if knownBuildings[id] then return end
		knownBuildings[id] = { base = base, ownerId = ownerId, buildingType = buildingType }
		base.Destroying:Connect(function()
			knownBuildings[id] = nil
			if hoverBuildingId == id then
				if hoverBldRing then SelectionRing.destroy(hoverBldRing); hoverBldRing = nil end
				if hoverRing then hoverRing:Destroy(); hoverRing = nil end
				hoverBuildingId = nil
			end
		end)
	end

	-- Track all replicated buildings for click detection
	network.onBuildingPlaced(function(id: string, ownerId: number, _pos: Vector3, buildingType: string)
		task.spawn(function()
			local folder = workspace:WaitForChild("Buildings", 10)
			if not folder then return end
			local model = folder:WaitForChild(id, 10)
			if not model then return end
			local base = model:WaitForChild("Base", 5) :: BasePart
			if not base then return end
			trackBuilding(id, base, ownerId, buildingType or "Barracks")
		end)
	end)

	-- Reconcile buildings that were placed before this handler connected — notably
	-- the Command Center, whose BuildingPlaced event fires during the ~4-7s lobby
	-- transition. We read OwnerId / BuildingType straight off the replicated model so
	-- the CC becomes clickable exactly like a player-built Barracks.
	task.spawn(function()
		local folder = workspace:WaitForChild("Buildings", 20) :: Folder?
		if not folder then return end
		local function tryTrack(model: Instance)
			if knownBuildings[model.Name] then return end
			local base = model:FindFirstChild("Base")
			local ov   = model:FindFirstChild("OwnerId")      :: StringValue?
			local btv  = model:FindFirstChild("BuildingType") :: StringValue?
			if not (base and base:IsA("BasePart") and ov) then return end
			trackBuilding(model.Name, base :: BasePart, tonumber(ov.Value) or 0, (btv and btv.Value) or "Barracks")
		end
		for _, m in folder:GetChildren() do tryTrack(m) end
		folder.ChildAdded:Connect(function(m: Instance)
			task.spawn(function()
				m:WaitForChild("Base", 10)
				m:WaitForChild("OwnerId", 5)
				tryTrack(m)
			end)
		end)
	end)

	-- Hover highlight: update whenever the mouse moves.
	-- Skip when cursor is over any GUI element to avoid highlighting buildings
	-- that are visually beneath panels.
	mouse.Move:Connect(function()
		if isBlockedFn and isBlockedFn() then
			setHover(nil)
			setPlantHover(nil)
			return
		end
		local mp  = UserInputService:GetMouseLocation()
		local gui = localPlayer.PlayerGui:GetGuiObjectsAtPosition(mp.X, mp.Y)
		if #gui > 0 then
			setHover(nil)
			setPlantHover(nil)
			return
		end
		-- Hovering an egg (a child of the Mother model) shouldn't light up the whole
		-- Command Center — suppress the building hover in that case.
		if hitEgg() then setHover(nil); setPlantHover(nil); return end
		local hoverBid = hitBuilding()
		setHover(hoverBid)
		-- Plants sit behind everything else you can point at: light one up only when the
		-- cursor is on neither a structure nor a unit.
		if hoverBid or hitUnit() then
			setPlantHover(nil)
		else
			setPlantHover(hitPlant())
		end
	end)

	-- Input
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		-- F2: select all owned living units (works even during building placement).
		-- Leeches are excluded: a Leech is economy, not army -- it crawls off to burrow and
		-- pays out while anchored, so sweeping it into an army selection and marching it
		-- somewhere silently costs the player their income.
		if input.KeyCode == Enum.KeyCode.F2 then
			UnitController.selectArmy()
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
			clearEggSelection()
			clearPlantSelection()
			local boxCCId = boxSelect(
				math.min(dragStart.X, dragEnd.X), math.min(dragStart.Y, dragEnd.Y),
				math.max(dragStart.X, dragEnd.X), math.max(dragStart.Y, dragEnd.Y)
			)
			if boxCCId then
				-- The box found her and nothing else: select her exactly as a click would,
				-- so her card opens and right-click becomes a move order again.
				clearBuildingPanelsExcept("CommandCenter")
				selectBuilding(boxCCId)
				if onCCSelectedCb then onCCSelectedCb(boxCCId) end
			else
				clearBuildingPanels()
			end
		else
			-- Single / double click — check unit first, then eggs, then buildings
			local now = os.clock()
			local uid = hitUnit()
			local eggId: string? = nil
			if not uid then eggId = hitEgg() end
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
				clearEggSelection()
				clearPlantSelection()
				clearBuildingPanels()
			elseif eggId then
				-- Own Egg-Sac egg: highlight THAT egg alone and open the "what to hatch" panel.
				-- Double-clicking takes every ripe egg on screen instead, so a whole colony
				-- can be spent on one pick.
				local isDouble = (now - lastClickTime < DOUBLE_CLICK_SECS) and lastClickTarget == eggId
				lastClickTime   = now
				lastClickTarget = eggId
				clearSelection()
				selectBuilding(nil)
				clearBuildingPanels()
				if isDouble then
					selectAllReadyEggsOnScreen(eggId)
				else
					selectEgg(eggId)
				end
			else
				local bid = hitBuilding()
				if bid then
					local isDouble = (now - lastClickTime < DOUBLE_CLICK_SECS) and lastClickTarget == bid
					lastClickTime   = now
					lastClickTarget = bid
					applyBuildingSelection(bid, isDouble)
				else
					lastClickTime   = 0
					lastClickTarget = nil
					clearSelection()
					selectBuilding(nil)
					clearEggSelection()
					clearBuildingPanels()
					-- Nothing of yours under the cursor: a plant standing there is still
					-- worth naming, so it takes the click before it counts as a deselect.
					local plant = hitPlant()
					if plant then
						selectPlant(plant)
					else
						clearPlantSelection()
					end
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

function UnitController.onUnitsSelected(fn: ({string}) -> ())
	onUnitsSelectedCb = fn
end

-- The UnitType of a tracked unit (reads the "UnitType" StringValue on its part).
function UnitController.getUnitType(id: string): string?
	local info = knownUnits[id]
	if not info then return nil end
	local tv = info.part:FindFirstChild("UnitType")
	return tv and (tv :: StringValue).Value or nil
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

function UnitController.onTestSelected(fn: (string?) -> ())
	onTestSelectedCb = fn
end

function UnitController.onLampreyNestSelected(fn: (string?) -> ())
	onLampreyNestSelectedCb = fn
end

function UnitController.onEngineeringSelected(fn: (string?) -> ())
	onEngineeringSelectedCb = fn
end

-- Fires (buildingId, buildingType) for an owned building with no dedicated panel,
-- or (nil, nil) on deselect.
function UnitController.onOtherBuildingSelected(fn: (string?, string?) -> ())
	onOtherBuildingSelectedCb = fn
end

-- Fires with the wild plant the player clicked, or nil when it is dropped. Plants have
-- nothing to command, so the card this opens is a name and a line of text.
function UnitController.onPlantSelected(fn: (Model?) -> ())
	onPlantSelectedCb = fn
end

-- Fires with the selected Egg-Sac egg ids (clicked egg + subtree), or nil to close its panel.
function UnitController.onEggSelected(fn: ({ string }?) -> ())
	onEggSelectedCb = fn
end

-- Returns the primary selected building ID plus all secondary double-click selected IDs.
function UnitController.getSelectedBuildingIds(): {string}
	local result: {string} = {}
	if selectedBuildingId then
		table.insert(result, selectedBuildingId)
	end
	for bid in multiBldRings do
		table.insert(result, bid)
	end
	return result
end

function UnitController.onMoveIssued(fn: ({string}) -> ())
	onMoveIssuedCb = fn
end

-- The Mother's move-order line, rate-limited to one every MOTHER_VOICE_COOLDOWN seconds.
-- Called by init.client, which owns her right-click move order.
function UnitController.playMotherVoice()
	motherVoiceLine()
end

-- ── Quick-select (the bar above the minimap) ──────────────────────────────────
-- One entry point per group the bar offers. Each leaves the game in exactly the state
-- the equivalent hand gesture would: the same rings, the same command card, the same
-- dropped panels. They return how much was taken so the bar can ignore a dead press.

-- Your Command Center (the Mother, or the Fabricator Core). Opens her card.
function UnitController.selectCommandCenter(): boolean
	for bid, info in knownBuildings do
		if info.ownerId == localPlayer.UserId
			and info.buildingType == "CommandCenter"
			and info.base.Parent then
			applyBuildingSelection(bid, false)
			return true
		end
	end
	return false
end

-- Every army unit you own. Leeches are left out for the reason [F2] leaves them out:
-- a Leech is economy, and marching one off its burrow silently costs you the income.
function UnitController.selectArmy(): number
	clearNonUnitSelection()
	return selectUnitsMatching(function(ut) return ut ~= "Leech" end)
end

-- Every Leech you own, burrowed or crawling.
function UnitController.selectLeeches(): number
	clearNonUnitSelection()
	return selectUnitsMatching(function(ut) return ut == "Leech" end)
end

-- Every egg you own, and opens the panel that picks what they hatch. Ripe eggs are
-- taken alone when there are any: a pick spends the whole selection, and eggs still
-- growing would silently take no part in it. With nothing ripe yet the whole clutch is
-- taken instead, so the button still shows you where your nests are.
function UnitController.selectAllEggs(): number
	local models = scanOwnedEggs()
	local ready: { string } = {}
	local all:   { string } = {}
	for id, m in models do
		table.insert(all, id)
		if eggIsReady(m) then table.insert(ready, id) end
	end
	local ids = if #ready > 0 then ready else all
	if #ids == 0 then return 0 end

	clearSelection()
	selectBuilding(nil)
	clearPlantSelection()
	clearBuildingPanels()
	clearEggSelection()
	applyEggSelection(ids, models)
	return #ids
end

-- What you own right now, for the bar's visibility and its counts. One pass, so the
-- bar can poll this on a timer rather than walking the world four times.
export type Tally = { cc: boolean, eggs: number, leeches: number, army: number }
function UnitController.ownedTally(): Tally
	local me      = localPlayer.UserId
	local army    = 0
	local leeches = 0
	for _, info in knownUnits do
		if info.ownerId ~= me or not info.part.Parent then continue end
		if info.part:GetAttribute("Carried") then continue end
		local ut = info.part:FindFirstChild("UnitType") :: StringValue?
		if ut and ut.Value == "Leech" then leeches += 1 else army += 1 end
	end

	local cc = false
	for _, info in knownBuildings do
		if info.ownerId == me and info.buildingType == "CommandCenter" and info.base.Parent then
			cc = true
			break
		end
	end

	local eggs   = 0
	local models = scanOwnedEggs()
	for _ in models do eggs += 1 end

	return { cc = cc, eggs = eggs, leeches = leeches, army = army }
end

-- Where the current selection is standing, as one point: what the camera flies to when
-- a quick-select button is tapped twice. Units first, then eggs, then a structure, then
-- a plant -- whichever of those the selection actually holds.
function UnitController.selectionCentroid(): Vector3?
	local sum = Vector3.zero
	local n   = 0

	for _, id in selected do
		local info = knownUnits[id]
		if info and info.part.Parent then
			sum += info.part.Position
			n   += 1
		end
	end
	if n > 0 then return sum / n end

	if #selectedEggIds > 0 then
		local models = scanOwnedEggs()
		for _, id in selectedEggIds do
			local m = models[id]
			if m then
				sum += (m :: any):GetPivot().Position
				n   += 1
			end
		end
		if n > 0 then return sum / n end
	end

	if selectedBuildingId then
		local info = knownBuildings[selectedBuildingId]
		if info and info.base.Parent then return info.base.Position end
	end

	local plant = selectedPlant
	if plant and plant.Parent then return plant:GetPivot().Position end
	return nil
end

return UnitController
