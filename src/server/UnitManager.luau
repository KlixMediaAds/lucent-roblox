local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local UnitBlueprints    = require(Shared:WaitForChild("UnitBlueprints"))
local AlertManager      = require(script.Parent:WaitForChild("AlertManager"))
local GoreManager       = require(script.Parent:WaitForChild("GoreManager"))

local UnitManager = {}

type UnitData = {
	part        : BasePart,
	owner       : Player,
	target      : Vector3?,
	hp          : number,
	maxHp       : number,
	attackTimer : number,
	attackDmg   : number,
	attackRate  : number,
	unitType    : string,
	home        : Vector3,
	aggroId     : string?,
	aggroHome   : Vector3?,
	atkMoveDest : Vector3?,
	velocity    : Vector3,   -- current world-space velocity (XZ only)
	path        : { Vector3 }?, -- nav waypoints toward the move destination (cliff-aware)
	pathIdx     : number?,   -- index of the current waypoint within `path`
	moveSpeed   : number,    -- max speed in studs/s
	accel       : number,    -- velocity lerp factor (higher = snappier)
	focusBldId  : string?,   -- building ID to focus-fire (nil = none)
	hpBarHideAt : number?,   -- tick() timestamp; hide health bar after this time
	slowUntil          : number?,  -- tick() timestamp; unit moves at TANK_SLOW_MULT speed until then
	stimUntil          : number?,  -- tick() timestamp; soldier stims active until then
	stimCooldownUntil  : number?,  -- tick() timestamp; stims cannot reactivate until then
	incomingHarpoons   : number?,  -- count of active harpoons embedded in this unit (stacks slow)
	harpoonCount       : number?,  -- nil for non-trappers; current available harpoons (0–5)
	harpoonRestockAt   : number?,  -- tick() timestamp when next harpoon restocks
	trapperHarpooned   : {[string]: number}?,  -- unitId → expiry tick() for active harpoons this trapper fired
	rollerAngle        : number?,   -- accumulated Z-roll radians
	rollerCharging     : boolean?,  -- dashing toward charge target
	rollerChargingOut  : boolean?,  -- bouncing back from charge
	rollerChargeTarget : Vector3?,  -- charge destination
	rollerChargeHome   : Vector3?,  -- position to return to after charge
	-- Roller mount system (see Config.ROLLER_MOUNT_*): carried units stay LIVE and are
	-- snapped to a seat ON TOP of their Roller each heartbeat (so their real model rides
	-- along). While aboard, a rider's own AI is suspended and it's pulled out of the
	-- spatial grid, so enemies can't target it. `carrying` is the Roller's ordered list of
	-- rider ids; `carriedBy` tags each rider with its Roller.
	carrying           : { string }?,     -- (Roller) ids of units riding on top; nil/empty = none
	carriedBy          : string?,         -- (rider) the Roller id currently carrying this unit
	mountTargetId      : string?,         -- this unit is walking toward this Roller to climb in
	-- Foamer deploy state machine
	foamState       : string?,    -- nil = not a foamer; "mobile"|"deploying"|"deployed"|"undeploying"
	foamDeployStart : number?,    -- tick() when current transition began
	foamSinkBaseY   : number?,    -- body Y when deploy/undeploy transition started
	foamBarrelDec   : Decorator?, -- cached ref to the FoamBarrel decorator for barrel animation
	-- Foam debuff received by any unit (including non-foamers)
	foamedUntil     : number?,    -- tick() when foam expires on this unit; nil = not foamed
	foamDotAccum    : number?,    -- accumulated dt for 1-s DoT tick
	-- Hagfish
	attackLockUntil : number?,    -- tick() until which a hagfish stays rooted mid-attack
	-- Broodmother glowing-orb aura
	broodAuraState     : string?,  -- nil = idle; "charging" | "active"
	broodAuraStart     : number?,  -- tick() the current aura phase began
	broodDotAccum      : number?,  -- accumulated dt for the aura DoT tick
	broodRechargeUntil : number?,  -- tick() before which the swarm cannot re-form
	dying              : boolean?, -- Broodmother is mid death-collapse (frozen, awaiting final removal)
	-- Wounded-soldier system (see Config.SOLDIER_IMMOBILIZE_*)
	immobilized   : boolean?,        -- collapsed at low HP: prone, can shoot, can't move
	immobCheckAt  : number?,         -- tick() throttle for the collapse roll
	draggedBy     : { string }?,     -- (casualty) unit ids currently hauling this soldier (≤ DRAG_SLOTS)
	draggingId    : string?,         -- (rescuer) the casualty unit id this soldier is hauling
	healingAtCC   : boolean?,        -- casualty has been brought home and is regenerating
	-- Leech (Hollowed): burrowed = rooted underground, paying passive income (structure state)
	burrowed      : boolean?,
	burrowIncomeAt: number?,         -- os.clock() throttle for the next burrow income payout
	autoBurrow    : boolean?,        -- freshly-spawned Leech: burrow itself on reaching its scatter point
	-- Bloody-footprint trail: a unit that walks through a blood stain tracks it a few steps.
	lastStepPos   : Vector3?,        -- position at the last footstep sample (distance throttle)
	bloodStepsLeft: number?,         -- footsteps of blood still on its feet (counts down as it walks)
	bloodColor    : Color3?,         -- colour of the blood currently tracked
	-- Body CFrame at the last decorator sync. Decorators are only re-CFramed when this
	-- changes, so idle units cost zero property writes / replication per heartbeat.
	decorLastCF   : CFrame?,
}

type QueueItem = { unitType: string, trainTime: number, player: Player, spawnPos: Vector3 }

local units: { [string]: UnitData } = {}
local counter    = 0
local unitsFolder: Folder
local buildingManagerRef:  any
local resourceManagerRef:  any
local researchManagerRef:  any
local mineralManagerRef:   any
local forestManagerRef:    any
local terrainManagerRef:   any
local navGridRef:          any
local broodDeathRemote:    any   -- RemoteEvent fired (to all clients) when a Broodmother begins dying

-- Units big enough to bulldoze trees as they move (basic 4×4 infantry can't).
local FELLS_TREES: { [string]: boolean } = {}
for utype, info in Config.UNIT_TYPES do
	if math.max(info.size.X, info.size.Z) >= 5 then FELLS_TREES[utype] = true end
end

local barrackQueues:     { [string]: { QueueItem } } = {}
local barrackIsTraining: { [string]: boolean }       = {}
local barrackTrainStart: { [string]: number }        = {}

local MAX_QUEUE = 5
local laneModeActive = false

-- Deployer unit tracking: forward (deployerId → set of unitIds) and reverse maps
local deployerUnits:   { [string]: { [string]: boolean } } = {}
local unitToDeployer:  { [string]: string }                = {}

local aggroScanFrame = 0
local AGGRO_SCAN_EVERY = 18   -- ~0.3 s at 60 Hz

local SEP_DIST   = 5.5   -- studs: same-team separation trigger radius
local SEP_PUSH   = 0.18  -- studs pushed per frame per overlapping neighbour
local MOVE_BOUND = 427   -- studs: clamp units inside the ±432 boundary walls
local HP_BAR_SHOW_SECS = 3

-- Bloody-footprint trail: a unit samples the ground every FOOTSTEP_DIST studs; stepping
-- on a blood stain re-inks its feet for TRAIL_STEPS footprints, which it drops as it
-- walks on (leaving a trail that carries out of the pool).
local FOOTSTEP_DIST = 3.5
local TRAIL_STEPS   = 6

-- Spatial grid rebuilt each Heartbeat; maps a packed (cx, cz) integer key to the
-- list of unit IDs in that cell.  GRID_CELL > SEP_DIST so separation queries cover
-- at most a 2×2 block; AGGRO queries cover a small fixed neighbourhood regardless of n.
local GRID_CELL   = 16    -- studs per cell side
local GRID_OFFSET = 30    -- shifts cell index: world [-432..432] → cx/cz [3..57]
local GRID_STRIDE = 70    -- column count for packing (cx, cz) into one integer key
local spatialGrid: { [number]: { string } } = {}
local gridOccupied: { number }               = {}
local gridOccupiedCount                      = 0

-- Reusable scratch buffer for grid-range queries — avoids a table alloc per lookup.
local gridScratch: { string } = {}
local gridScratchN             = 0

-- Active Howitzer fire zones: persist for FULL+FADE seconds, deal DoT to all units.
type FireZone = { pos: Vector3, elapsed: number, dotAccum: number }
local fireZones: { FireZone } = {}

-- Per-unit anchored decorator parts (treads, pill body, eyes, etc.).
-- Replaced unanchored+WeldConstraint parts to cut physics body count.
type Decorator = { part: Part, localCF: CFrame }
local unitDecorators: { [string]: { Decorator } } = {}

-- Reusable scratch buffers for the per-heartbeat decorator BulkMoveTo (no per-frame allocs).
local decorBulkParts: { BasePart } = {}
local decorBulkCFs:   { CFrame }   = {}

-- Ground-height memo: terrain is static once generated, so downward raycasts are
-- cached on a 1-stud grid (flat tiers are exact; ramp stairstepping stays under the
-- movement slope-check slack). Moving armies hammer the same cells every heartbeat,
-- turning thousands of physics raycasts/sec into dictionary hits. Cleared on resetAll.
local groundYCache: { [number]: number } = {}
local groundYCacheN = 0
local GROUND_CACHE_MAX = 500000  -- safety cap; wipe-and-refill beyond this

-- Live unit count per player userId (for unit cap enforcement).
local playerUnitCount: { [number]: number } = {}
local MAX_UNITS_PER_PLAYER = 30

-- ── Engineering Post random upgrades ────────────────────────────────────────────
-- Per-player, per-unit-type stat multipliers granted by Light research. Applied to
-- every unit of that type at spawn (and retroactively to live units when granted).
-- Each stat is a plain multiplier (rate is a period multiplier: <1 means faster).
type StatMult = { dmg: number, range: number, speed: number, rate: number, hp: number }
local playerStatMult:  { [number]: { [string]: StatMult } } = {}
-- Global per-player discovery log (newest last); each entry is the popup/history line.
local playerUpgradeLog: { [number]: { string } } = {}

-- Unit types a Light research may roll, with player-facing plural names.
local UPGRADE_UNITS: { string } = { "Survivor", "Sniper", "Tank", "Howitzer", "Foamer", "Elite", "Medic", "Lamprey", "Hagfish", "Broodmother", "Roller" }
local UPGRADE_UNIT_NAME: { [string]: string } = {
	Survivor = "Survivors", Sniper = "Snipers", Tank = "Tanks", Howitzer = "Howitzers", Foamer = "Foamers",
	Elite = "Elites", Medic = "Medics", Lamprey = "Lampreys", Hagfish = "Hagfish",
	Broodmother = "Broodmothers", Roller = "Rollers",
}
-- Stats a Light research may roll: { field key, player-facing name }.
local UPGRADE_STATS: { { field: string, name: string } } = {
	{ field = "dmg",   name = "damage" },
	{ field = "range", name = "range" },
	{ field = "speed", name = "movement speed" },
	{ field = "rate",  name = "attack speed" },
	{ field = "hp",    name = "durability" },
}

local function statMultFor(userId: number, unitType: string): StatMult
	local byType = playerStatMult[userId]
	if not byType then byType = {}; playerStatMult[userId] = byType end
	local m = byType[unitType]
	if not m then
		m = { dmg = 1, range = 1, speed = 1, rate = 1, hp = 1 }
		byType[unitType] = m
	end
	return m
end

local function rebuildSpatialGrid()
	for i = 1, gridOccupiedCount do
		local cell = spatialGrid[gridOccupied[i]]
		for j = 1, #cell do cell[j] = nil end
	end
	gridOccupiedCount = 0
	for id, data in units do
		if data.carriedBy then continue end   -- riding on a Roller: not targetable while aboard
		local pos = data.part.Position
		local cx  = math.floor(pos.X / GRID_CELL) + GRID_OFFSET
		local cz  = math.floor(pos.Z / GRID_CELL) + GRID_OFFSET
		local k   = cx * GRID_STRIDE + cz
		local cell = spatialGrid[k]
		if not cell then
			cell = {}
			spatialGrid[k] = cell
			gridOccupiedCount += 1
			gridOccupied[gridOccupiedCount] = k
		end
		cell[#cell + 1] = id
	end
end

-- Fill gridScratch with every unit ID whose cell overlaps a circle of `range` around
-- `fromPos`. No table allocation — callers iterate gridScratch[1..gridScratchN].
local function fillGridScratch(fromPos: Vector3, range: number)
	gridScratchN = 0
	local cx0 = math.floor((fromPos.X - range) / GRID_CELL) + GRID_OFFSET
	local cx1 = math.floor((fromPos.X + range) / GRID_CELL) + GRID_OFFSET
	local cz0 = math.floor((fromPos.Z - range) / GRID_CELL) + GRID_OFFSET
	local cz1 = math.floor((fromPos.Z + range) / GRID_CELL) + GRID_OFFSET
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			local cell = spatialGrid[cx * GRID_STRIDE + cz]
			if cell then
				for _, id in cell do
					gridScratchN += 1
					gridScratch[gridScratchN] = id
				end
			end
		end
	end
end

-- ── Decorator construction ────────────────────────────────────────────────────

-- Builds a unit's static decorator parts from its shared blueprint (see
-- UnitBlueprints). Anchored parts are tracked in `unitDecorators` so the
-- Heartbeat re-applies `bodyCF * localCF` each frame as the body moves.
local function buildFromBlueprint(id: string, body: BasePart, bp: UnitBlueprints.Blueprint)
	if bp.rootTransparent then body.Transparency = 1 end
	local teamColor = body.Color
	local skinColor = UnitBlueprints.randomSkinTone()  -- one tone per unit (head + arms match)
	local decs      = unitDecorators[id]
	for _, spec in bp.parts do
		local p   = UnitBlueprints.instantiate(spec, body.CFrame, teamColor, skinColor)
		p.Parent  = body
		decs[#decs + 1] = { part = p, localCF = spec.cf }
	end
	if bp.healthBarY then
		local bb = body:FindFirstChild("HealthBar")
		if bb and bb:IsA("BillboardGui") then
			bb.StudsOffset = Vector3.new(0, bp.healthBarY, 0)
		end
	end
end

-- Howitzer-only: continuous black smoke from both smokestacks. Server-side only
-- (previews omit particles). The stacks are named by the blueprint.
local function attachHowitzerSmoke(body: BasePart)
	for _, stackName in { "_HwStack1", "_HwStack2" } do
		local stk = body:FindFirstChild(stackName) :: BasePart?
		if not stk then continue end
		-- The stack is an upright cylinder: its length runs along local X and the
		-- blueprint rotates it Z+90° so that axis points up. Place the emitter at
		-- the top face and cancel that rotation (Z−90°) so the emitter's Top (+Y,
		-- the default EmissionDirection) points world-up and smoke rises.
		local att      = Instance.new("Attachment")
		att.CFrame     = CFrame.new(stk.Size.X / 2, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2)
		att.Parent     = stk
		local pe                = Instance.new("ParticleEmitter")
		pe.Color                = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(90, 90, 90)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(55, 55, 55)),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(28, 28, 28)),
		})
		pe.LightEmission        = 0
		pe.LightInfluence       = 0.5
		pe.Lifetime             = NumberRange.new(2.0, 3.5)
		pe.Rate                 = if stackName == "_HwStack1" then 10 else 7
		pe.Rotation             = NumberRange.new(0, 360)
		pe.RotSpeed             = NumberRange.new(-25, 25)
		pe.Size                 = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.5),
			NumberSequenceKeypoint.new(0.5, 2.0),
			NumberSequenceKeypoint.new(1,   3.2),
		})
		pe.Transparency         = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   0.10),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1,   1.00),
		})
		pe.Speed                = NumberRange.new(2.5, 5)
		pe.SpreadAngle          = Vector2.new(12, 12)
		pe.VelocityInheritance  = 0.2
		pe.Parent               = att
	end
end

-- Bar length scales with max HP (tougher units get longer bars), within bounds.
local function hpBarWidth(maxHp: number): number
	return math.clamp(math.floor(40 + maxHp * 0.18 + 0.5), 40, 110)
end

local function addHealthBar(part: BasePart, maxHp: number)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.new(0, hpBarWidth(maxHp), 0, 4)
	bb.StudsOffset      = Vector3.new(0, part.Size.Y / 2 + 1.5, 0)
	bb.AlwaysOnTop      = false
	bb.Enabled          = false
	bb.Parent           = part

	local bg            = Instance.new("Frame")
	bg.Size             = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	bg.BorderSizePixel  = 0
	bg.Parent           = bb
	local bgCorner      = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(1, 0)
	bgCorner.Parent     = bg
	local bgStroke      = Instance.new("UIStroke")
	bgStroke.Color      = Color3.fromRGB(0, 0, 0)
	bgStroke.Thickness  = 1
	bgStroke.Transparency = 0.35
	bgStroke.Parent     = bg

	local fill          = Instance.new("Frame")
	fill.Name           = "Fill"
	fill.Size           = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel  = 0
	fill.Parent         = bg
	local fillCorner    = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent   = fill
end

local function applyHP(data: UnitData, tookDamage: boolean?)
	-- Notify the owner that their army is under attack here (throttled per region).
	if tookDamage and data.hp > 0 then
		AlertManager.report(data.owner, data.part.Position, "army")
		-- Stamp when this unit was last hit so the client's camera-hop eye can give
		-- recently-attacked units priority (see ScoutManager hopOrder).
		data.part:SetAttribute("LastHit", workspace:GetServerTimeNow())
	end
	local bb = data.part:FindFirstChild("HealthBar") :: BillboardGui?
	if not bb then return end
	local ratio = math.clamp(data.hp / data.maxHp, 0, 1)
	local bg    = bb:FindFirstChildWhichIsA("Frame")
	if not bg then return end
	local fill  = bg:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		local r = math.clamp(2 * (1 - ratio), 0, 1)
		local g = math.clamp(2 * ratio, 0, 1)
		fill.BackgroundColor3 = Color3.new(r, g, 0)
	end
	if data.hp >= data.maxHp then
		bb.Enabled       = false
		data.hpBarHideAt = nil
	elseif tookDamage then
		bb.Enabled = true
		local t = tick() + HP_BAR_SHOW_SECS
		data.hpBarHideAt = t
		task.delay(HP_BAR_SHOW_SECS, function()
			if data.hpBarHideAt == t and bb.Parent then
				bb.Enabled = false
			end
		end)
	end
end

-- A Lamprey that fells trees grows: every felled tree scales its body size and
-- max HP by LAMPREY_GROWTH_PER_TREE, compounding up to LAMPREY_GROWTH_MAX_SCALE.
-- The client LampreyBody animator derives its render scale from part.Size.Y, so
-- simply resizing the (invisible) pivot part grows the whole visible creature.
local LAMPREY_BASE_Y = Config.UNIT_TYPES.Lamprey.size.Y
local function growLamprey(data: UnitData, treeCount: number)
	local g        = 1 + Config.LAMPREY_GROWTH_PER_TREE
	local maxScale = Config.LAMPREY_GROWTH_MAX_SCALE
	for _ = 1, treeCount do
		if data.part.Size.Y / LAMPREY_BASE_Y >= maxScale then break end
		local oldY  = data.part.Size.Y
		data.part.Size = data.part.Size * g
		-- Keep ground-snapped: the pivot centre rises by half the height gained.
		data.part.CFrame = data.part.CFrame + Vector3.new(0, (data.part.Size.Y - oldY) / 2, 0)
		-- Toughen alongside size (current HP scales too, so a healthy Lamprey
		-- stays healthy rather than suddenly looking wounded).
		data.maxHp = data.maxHp * g
		data.hp    = data.hp * g
	end
	-- Grow the health bar's length to match the new (larger) max HP.
	local bb = data.part:FindFirstChild("HealthBar") :: BillboardGui?
	if bb then bb.Size = UDim2.new(0, hpBarWidth(data.maxHp), 0, 4) end
	applyHP(data)
end

-- Returns the effective damage dealt to a unit after applying Hardened Armor.
local function calcDamage(targetData: UnitData, rawDmg: number): number
	if targetData.unitType == "Survivor" and researchManagerRef
		and researchManagerRef.hasResearch(targetData.owner, "HardenedArmor") then
		return math.max(1, rawDmg - Config.SOLDIER_ARMOR)
	end
	return rawDmg
end

-- ── Spawn ─────────────────────────────────────────────────────────────────────

local function spawnUnit(player: Player, position: Vector3, unitType: string): string?
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return nil end

	-- Enforce per-player unit cap
	if (playerUnitCount[player.UserId] or 0) >= MAX_UNITS_PER_PLAYER then return nil end

	counter += 1
	local id = "u" .. counter

	-- Initialize decorator list before any decoration function is called
	unitDecorators[id] = {}

	-- Use the raycast surface height (not the analytic heightAt, which sits ~2 studs
	-- below the rendered voxel top on a raised tier and buries small units at spawn).
	-- Matches the getGroundY raycast that movement uses, so there's no spawn pop.
	local spawnGroundY  = terrainManagerRef and terrainManagerRef.surfaceHeightAt(position.X, position.Z) or 0
	local part          = Instance.new("Part")
	part.Name           = id
	part.Size           = typeDef.size
	part.Position       = Vector3.new(position.X, spawnGroundY + typeDef.size.Y / 2 + 0.1, position.Z)
	part.BrickColor     = player.TeamColor
	part.Material       = Enum.Material.SmoothPlastic
	part.Anchored       = true
	part.CastShadow     = false

	-- CreepySoldier + Embryo: MVP single black parts (no blueprint geometry yet).
	-- (Leech is drawn client-side by LeechBody — see the invisible-pivot block below.)
	if unitType == "CreepySoldier" or unitType == "Embryo" then
		part.BrickColor = BrickColor.new("Black")
		part.Color      = Color3.fromRGB(10, 10, 12)
		part.Material   = Enum.Material.Slate
	end

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = part

	local tv        = Instance.new("StringValue")
	tv.Name         = "UnitType"
	tv.Value        = unitType
	tv.Parent       = part

	part.Parent = unitsFolder

	local maxHp    = (Config.UNIT_HP :: any)[unitType] or 100
	local dmg      = (Config.UNIT_ATTACK_DAMAGE :: any)[unitType] or 10
	local atkRate  = (Config.UNIT_ATTACK_RATE :: any)[unitType] or 1.0
	local spd      = (Config.UNIT_MOVE_SPEED :: any)[unitType] or 22
	local acc      = (Config.UNIT_ACCEL :: any)[unitType] or 8
	local atkRange = (Config.UNIT_ATTACK_RANGE :: any)[unitType] or 15

	-- Apply any Engineering-Post stat upgrades this player has researched.
	local pm = playerStatMult[player.UserId] and playerStatMult[player.UserId][unitType]
	if pm then
		maxHp    = maxHp    * pm.hp
		dmg      = dmg      * pm.dmg
		atkRate  = atkRate  * pm.rate
		spd      = spd      * pm.speed
		atkRange = atkRange * pm.range
	end
	addHealthBar(part, maxHp)

	-- Static body geometry comes from the shared blueprint (single source of
	-- truth, also used by the ViewportFrame previews in UnitVisuals).
	local blueprint = UnitBlueprints.get(unitType, part.Size)
	if blueprint then
		buildFromBlueprint(id, part, blueprint)
	end

	-- Per-unit extras that aren't plain geometry:
	if unitType == "Tank" then
		local hv   = Instance.new("NumberValue")
		hv.Name    = "HarpoonCount"
		hv.Value   = 0
		hv.Parent  = part
	end
	if unitType == "Howitzer" then
		attachHowitzerSmoke(part)
	end
	if unitType == "Leech" then
		-- The whole leech is drawn client-side (LeechBody) as a low, sideways worm; the
		-- body part is an invisible, ground-snapped pivot for movement/targeting.
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 2.5, 0) end  -- just above the crawling body
		-- The visible worm sprawls sideways and rears up to feed, well outside the thin
		-- pivot, so top-down clicks slip past it. Add a roomy invisible, query-able click
		-- hitbox that rides along as a decorator (posed to bodyCF each frame), so the
		-- selection raycast reliably lands on the worm the player is aiming at.
		local hbox         = Instance.new("Part")
		hbox.Name          = "ClickHitbox"
		hbox.Size          = Vector3.new(6, 6, 8)
		hbox.Transparency  = 1
		hbox.Anchored      = true
		hbox.CanCollide    = false
		hbox.CanQuery      = true    -- must be hit by the (unfiltered) selection ray
		hbox.CastShadow    = false
		hbox.CFrame        = part.CFrame * CFrame.new(0, 1.5, 0)
		hbox.Parent        = part
		local decs = unitDecorators[id]
		decs[#decs + 1] = { part = hbox, localCF = CFrame.new(0, 1.5, 0) }
	end
	if unitType == "Lamprey" then
		-- The entire creature is drawn by the client LampreyBody animator; the body
		-- part is just an invisible, ground-snapped pivot used for movement/targeting.
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 2.5, 0) end  -- just above the reared head
	end
	if unitType == "Hagfish" then
		-- Like the Lamprey, the whole hagfish is drawn client-side (HagfishBody); the
		-- body part is an invisible, ground-snapped pivot for movement/targeting.
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 2.0, 0) end  -- just above the reared head
	end
	if unitType == "Broodmother" then
		-- The whole creature is drawn client-side (BroodmotherBody); the body part is
		-- an invisible, ground-snapped pivot (centre sits size.Y/2 above the terrain).
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 10.0, 0) end  -- above the anemone mass + crown tendrils
	end
	if unitType == "Roller" then
		-- The armored disc is drawn client-side (RollerBody); the body part is an
		-- invisible, ground-snapped pivot (centre sits size.Y/2 = the wheel radius
		-- above the terrain, so the rim rests on the ground).
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 6.5, 0) end  -- just above the top of the wheel
		-- Mount system: starts empty; the client RollerPanel reads these attributes.
		part:SetAttribute("Passengers", 0)
		part:SetAttribute("MountCap", Config.ROLLER_MOUNT_CAPACITY)
	end
	if unitType == "Watcher" then
		-- The floating cluster of eyes is drawn client-side (WatcherBody); the body part
		-- is an invisible, ground-snapped pivot for movement/targeting (centre sits
		-- size.Y/2 above the terrain).
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 3.5, 0) end  -- just above the top of the eye cluster
	end
	if unitType == "Needler" then
		-- The spherical body + single long insect arm is drawn client-side (NeedlerBody);
		-- the body part is an invisible, ground-snapped pivot for movement/targeting.
		part.Transparency = 1
		local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, 3.0, 0) end  -- just above the spherical body
	end
	units[id] = {
		part        = part,
		owner       = player,
		target      = nil,
		hp          = maxHp,
		maxHp       = maxHp,
		attackTimer = math.random() * atkRate,
		attackDmg   = dmg,
		attackRate  = atkRate,
		attackRange = atkRange,
		unitType    = unitType,
		home        = position,
		aggroId     = nil,
		aggroHome   = nil,
		atkMoveDest = nil,
		velocity    = Vector3.zero,
		moveSpeed   = spd,
		accel       = acc,
		focusBldId  = nil,
	}

	-- Leech: don't idle at the nest. Crawl 3–5 tiles out on a random heading to open
	-- ground, then burrow (heartbeat handles the burrow on arrival via data.autoBurrow).
	if unitType == "Leech" then
		local d    = units[id]
		local ang  = math.random() * math.pi * 2
		local dist = Config.LEECH_SCATTER_MIN
			+ math.random() * (Config.LEECH_SCATTER_MAX - Config.LEECH_SCATTER_MIN)
		local dest = position + Vector3.new(math.cos(ang) * dist, 0, math.sin(ang) * dist)
		if navGridRef then
			local path = navGridRef.findPath(position, dest)
			d.path    = path
			d.pathIdx = 1
			d.target  = path[1]
		else
			d.target = dest
		end
		d.autoBurrow = true
	end

	playerUnitCount[player.UserId] = (playerUnitCount[player.UserId] or 0) + 1
	RemoteHandler.get(Config.REMOTES.UnitSpawned):FireAllClients(id, player.UserId, part.Position)

	-- Foamer: initialise deploy state and cache the barrel decorator reference
	if unitType == "Foamer" then
		units[id].foamState = "mobile"
		for _, dec in unitDecorators[id] do
			if dec.part.Name == "FoamBarrel" then
				units[id].foamBarrelDec = dec
				break
			end
		end
	end

	return id
end

-- ── Move helpers ──────────────────────────────────────────────────────────────

-- Issue a cliff-aware move: route the unit to `slot` via the nav grid so it walks
-- around cliffs and up ramps instead of trying to climb. The final waypoint is the
-- exact slot; intermediate ones are cleared of cliffs.
local function orderMove(data: UnitData, slot: Vector3)
	if navGridRef then
		local path = navGridRef.findPath(data.part.Position, slot)
		data.path    = path
		data.pathIdx = 1
		data.target  = path[1]
	else
		data.path    = nil
		data.pathIdx = nil
		data.target  = slot
	end
end

-- ── Leech burrow state ─────────────────────────────────────────────────────────
-- Put a Leech into (or out of) its burrowed structure state: rooted underground,
-- paying passive income. Shared by the manual ToggleBurrow handler and the
-- auto-burrow a freshly-spawned Leech runs on reaching its scatter point.
local function setLeechBurrowed(data: UnitData, on: boolean)
	data.burrowed    = on
	data.velocity    = Vector3.zero
	data.target      = nil
	data.path        = nil
	data.pathIdx     = nil
	data.aggroId     = nil
	data.aggroHome   = nil
	data.atkMoveDest = nil
	data.autoBurrow  = nil   -- one-shot; clear so a later unburrow stays manual

	local part = data.part

	-- Roll a per-burrow anchoring delay: the leech rears up and quests for this long
	-- before planting its head. Offset the first income tick by it so a batch anchored
	-- together desyncs and pays out organically. The client reads AnchorDelay to match
	-- its head-plant to the same moment. (Reset on unburrow.)
	if on then
		local anchorDelay = Config.LEECH_ANCHOR_DELAY_MIN
			+ math.random() * (Config.LEECH_ANCHOR_DELAY_MAX - Config.LEECH_ANCHOR_DELAY_MIN)
		part:SetAttribute("AnchorDelay", anchorDelay)
		data.burrowIncomeAt = os.clock() + anchorDelay + Config.LEECH_BURROW_INTERVAL
	else
		data.burrowIncomeAt = nil
	end

	local groundY = terrainManagerRef and terrainManagerRef.surfaceHeightAt(part.Position.X, part.Position.Z)
		or (part.Position.Y - part.Size.Y / 2)
	local restY = groundY + part.Size.Y / 2 + 0.1
	part.Position = Vector3.new(part.Position.X,
		on and (restY - Config.LEECH_BURROW_SINK) or restY,
		part.Position.Z)

	local bv = part:FindFirstChild("Burrowed") :: BoolValue?
	if not bv then
		bv = Instance.new("BoolValue")
		bv.Name = "Burrowed"
		bv.Parent = part
	end
	(bv :: BoolValue).Value = on
end

-- ── Wounded-soldier rescue links ───────────────────────────────────────────────

local function getOwnerCC(owner: any): Vector3?
	if not buildingManagerRef then return nil end
	return buildingManagerRef.getCCPosition(owner)
end

-- Sever any drag links touching `id` (call before a unit is removed so its rescuer
-- or casualty doesn't keep a dangling reference). processRescues also self-heals,
-- so this is a fast best-effort cleanup, not the only safety net.
local function releaseDragLinks(id: string)
	local d = units[id]
	if not d then return end
	if d.draggedBy then
		for _, rid in d.draggedBy do
			local r = units[rid]
			if r and r.draggingId == id then r.draggingId = nil end
		end
		d.draggedBy = nil
	end
	if d.draggingId then
		local cas = units[d.draggingId]
		if cas and cas.draggedBy then
			local i = table.find(cas.draggedBy, id)
			if i then table.remove(cas.draggedBy, i) end
		end
		d.draggingId = nil
	end
end

-- A command was issued to `candidates`: peel off the nearest healthy soldiers to
-- haul any of the owner's casualties home (filling each casualty's free drag
-- slots). Casualties already crewed or already healing are skipped. No-op if the
-- owner has no Command Center to carry them to.
local function assignRescues(owner: any, candidates: { string })
	if not getOwnerCC(owner) then return end

	local casualties: { string } = {}
	for id, d in units do
		if d.owner == owner and d.immobilized and not d.healingAtCC then
			local crew = d.draggedBy and #d.draggedBy or 0
			if crew < Config.SOLDIER_DRAG_SLOTS then table.insert(casualties, id) end
		end
	end
	if #casualties == 0 then return end

	-- Available rescuers: healthy, mobile soldiers from the commanded group.
	local pool: { string } = {}
	for _, id in candidates do
		local d = units[id]
		if d and d.owner == owner and d.unitType == "Survivor"
			and not d.immobilized and not d.draggingId and d.hp > 0 then
			table.insert(pool, id)
		end
	end

	for _, cid in casualties do
		if #pool == 0 then break end
		local cas = units[cid]
		if cas then
			cas.draggedBy = cas.draggedBy or {}
			local cp = cas.part.Position
			while #cas.draggedBy < Config.SOLDIER_DRAG_SLOTS and #pool > 0 do
				-- Grab the nearest available rescuer.
				local bestIdx, bestD = nil :: number?, math.huge
				for i, rid in pool do
					local r = units[rid]
					if r then
						local dd = (r.part.Position - cp).Magnitude
						if dd < bestD then bestD = dd; bestIdx = i end
					end
				end
				if not bestIdx then break end
				local rid = table.remove(pool, bestIdx) :: string
				local r   = units[rid]
				if r then
					r.draggingId = cid
					r.target, r.path, r.pathIdx = nil, nil, nil
					r.aggroId, r.aggroHome, r.focusBldId, r.atkMoveDest = nil, nil, nil, nil
					r.rollerCharging, r.rollerChargingOut = nil, nil
					r.velocity = Vector3.zero
					table.insert(cas.draggedBy, rid)
				end
			end
		end
	end
end

local function applyFormation(valid: { string }, targetPos: Vector3)
	local cols = math.max(1, math.ceil(math.sqrt(#valid)))
	for i, id in valid do
		local c = (i - 1) % cols
		local r = math.floor((i - 1) / cols)
		local formPos = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
		local data = units[id]
		data.aggroId    = nil
		data.aggroHome  = nil
		data.focusBldId = nil
		orderMove(data, formPos)
	end
end

local function moveUnits(player: Player, ids: { string }, targetPos: Vector3)
	local valid = {}
	for _, id in ids do
		local d = units[id]
		-- Downed soldiers can't march, and active rescuers are busy hauling.
		if d and d.owner == player and not d.immobilized and not d.draggingId then
			table.insert(valid, id)
		end
	end
	applyFormation(valid, targetPos)
	for _, id in valid do units[id].atkMoveDest = nil end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
	assignRescues(player, valid)
end

-- Drag-formation move: each unit gets its own destination slot (parallel arrays).
-- `positions[i]` is the world slot for `ids[i]`. When `attackMove` is true the
-- units attack-march to their slots (aggro scan stays live); otherwise it's a
-- plain move. Replicates one UnitsOrderedMove so clients can play move VFX.
local FORMATION_MAX = 64
local function formationMove(player: Player, ids: { string }, positions: { Vector3 }, attackMove: boolean)
	local n = math.min(#ids, #positions, FORMATION_MAX)
	local valid: { string } = {}
	for i = 1, n do
		local id  = ids[i]
		local pos = positions[i]
		if type(id) ~= "string" or typeof(pos) ~= "Vector3" then continue end
		local data = units[id]
		if not data or data.owner ~= player then continue end
		if data.immobilized or data.draggingId then continue end
		local slot       = Vector3.new(pos.X, 0, pos.Z)
		data.aggroId     = nil
		data.aggroHome   = nil
		data.focusBldId  = nil
		data.atkMoveDest = attackMove and slot or nil
		orderMove(data, slot)
		table.insert(valid, id)
	end
	if #valid > 0 then
		RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, positions[1])
	end
	assignRescues(player, valid)
end

local function attackMoveUnits(player: Player, ids: { string }, targetPos: Vector3)
	local valid = {}
	for _, id in ids do
		local d = units[id]
		if d and d.owner == player and not d.immobilized and not d.draggingId then
			table.insert(valid, id)
		end
	end
	local cols = math.max(1, math.ceil(math.sqrt(#valid)))
	for i, id in valid do
		local c = (i - 1) % cols
		local r = math.floor((i - 1) / cols)
		local formPos = Vector3.new(
			targetPos.X + (c - (cols - 1) / 2) * Config.UNIT_FORMATION_SPACING,
			0,
			targetPos.Z + r * Config.UNIT_FORMATION_SPACING
		)
		local data = units[id]
		data.aggroId     = nil
		data.aggroHome   = nil
		data.focusBldId  = nil
		data.atkMoveDest = formPos
		orderMove(data, formPos)
	end
	RemoteHandler.get(Config.REMOTES.UnitsOrderedMove):FireAllClients(valid, targetPos)
	assignRescues(player, valid)
end

-- ── Barracks queue ────────────────────────────────────────────────────────────

local function fireTrainingUpdate(barrackId: string, player: Player)
	if not player.Parent then return end
	if player.UserId < 0 then return end
	local q = barrackQueues[barrackId] or {}
	local progress = 0
	if barrackIsTraining[barrackId] and #q > 0 and barrackTrainStart[barrackId] then
		local elapsed = tick() - barrackTrainStart[barrackId]
		progress = math.clamp(elapsed / q[1].trainTime, 0, 1)
	end
	local types: { string } = {}
	for _, item in q do table.insert(types, item.unitType) end
	RemoteHandler.get(Config.REMOTES.TrainingUpdate):FireClient(player, barrackId, types, progress)
end

local function startNextInQueue(barrackId: string)
	local q = barrackQueues[barrackId]
	if not q or #q == 0 then
		barrackIsTraining[barrackId] = false
		return
	end
	barrackIsTraining[barrackId] = true
	barrackTrainStart[barrackId] = tick()
	local item   = q[1]
	local player = item.player
	fireTrainingUpdate(barrackId, player)

	task.spawn(function()
		local startSnapshot = barrackTrainStart[barrackId]
		while true do
			task.wait(0.2)
			local q2 = barrackQueues[barrackId]
			if not q2 or #q2 == 0 then break end
			if barrackTrainStart[barrackId] ~= startSnapshot then break end
			if not player.Parent then break end
			fireTrainingUpdate(barrackId, player)
		end
	end)

	task.delay(item.trainTime, function()
		local q2 = barrackQueues[barrackId]
		if not q2 or q2[1] ~= item then return end
		table.remove(q2, 1)
		local bf = workspace:FindFirstChild("Buildings")
		if bf and bf:FindFirstChild(barrackId) then
			spawnUnit(player, item.spawnPos, item.unitType)
			if researchManagerRef and player.UserId > 0 then
				researchManagerRef.recordUnitTrained(player, item.unitType)
			end
		end
		fireTrainingUpdate(barrackId, player)
		startNextInQueue(barrackId)
	end)
end

-- ── Public AI API ─────────────────────────────────────────────────────────────

function UnitManager.trainFromBarracks(barrackId: string, unitType: string, player: any): boolean
	local typeDef = Config.UNIT_TYPES[unitType]
	if not typeDef then return false end
	-- Lampreys, Hagfish and Broodmothers are born at the Lamprey Nest, never trained at a Barracks.
	if unitType == "Lamprey" or unitType == "Hagfish" or unitType == "Broodmother" then return false end

	if typeDef.researchReq then
		if not researchManagerRef or not researchManagerRef.hasResearch(player, typeDef.researchReq) then
			return false
		end
	end

	local buildingsFolder = workspace:FindFirstChild("Buildings")
	if not buildingsFolder then return false end
	local building = buildingsFolder:FindFirstChild(barrackId)
	if not building then return false end

	local base = building:FindFirstChild("Base") :: BasePart?
	if not base then return false end

	local q = barrackQueues[barrackId] or {}
	if #q >= MAX_QUEUE then return false end

	if not resourceManagerRef then return false end
	if not resourceManagerRef.spend(player, typeDef.cost) then return false end

	local spawnPos  = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
	local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0

	if trainTime <= 0 then
		spawnUnit(player, spawnPos, unitType)
		return true
	end

	barrackQueues[barrackId] = q
	table.insert(q, { unitType = unitType, trainTime = trainTime, player = player, spawnPos = spawnPos })

	if not barrackIsTraining[barrackId] then
		startNextInQueue(barrackId)
	end
	return true
end

function UnitManager.spawnUnitAt(player: Player, position: Vector3, unitType: string)
	local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0
	if trainTime > 0 then
		task.delay(trainTime, function() spawnUnit(player, position, unitType) end)
	else
		spawnUnit(player, position, unitType)
	end
end

-- Spawns immediately and returns the unit ID (for turret-spawned units that need tracking).
function UnitManager.spawnUnitNow(player: Player, position: Vector3, unitType: string): string?
	return spawnUnit(player, position, unitType)
end

-- Remove a living unit immediately (used by the Embryo evolve). Mirrors the
-- heartbeat's dead-unit cleanup: drop decorators, decrement the owner's unit count,
-- destroy the part, and clear any deployer bookkeeping. Returns the unit's world position
-- (so the caller can spawn a structure/unit where it stood).
local function despawnUnit(id: string): Vector3?
	local d = units[id]
	if not d then return nil end
	local pos = d.part and d.part.Position or nil
	unitDecorators[id] = nil
	playerUnitCount[d.owner.UserId] = math.max(0, (playerUnitCount[d.owner.UserId] or 1) - 1)
	if d.part then d.part:Destroy() end
	units[id] = nil
	local dep = unitToDeployer[id]
	if dep then
		unitToDeployer[id] = nil
		if deployerUnits[dep] then deployerUnits[dep][id] = nil end
	end
	return pos
end

-- ── Roller mount system ─────────────────────────────────────────────────────────
-- How a passenger contributes to its Roller once inside.
local function classifyPassenger(unitType: string): string
	if unitType == "Embryo" then return "neutral" end
	local range = (Config.UNIT_ATTACK_RANGE :: any)[unitType] or 0
	if range >= Config.ROLLER_MOUNT_RANGED_MIN then return "ranged" end
	return "melee"
end

-- Any unit type may ride except another Roller (no nesting).
local function isMountableType(unitType: string): boolean
	return unitType ~= "Roller" and Config.UNIT_TYPES[unitType] ~= nil
end

-- Publish the passenger count (client RollerPanel reads these attributes).
local function syncRollerAttrs(roller: UnitData)
	if roller.part then
		roller.part:SetAttribute("Passengers", roller.carrying and #roller.carrying or 0)
		roller.part:SetAttribute("MountCap", Config.ROLLER_MOUNT_CAPACITY)
	end
end

-- Show/hide a unit's floating health bar (used to hide a rider's bar while it's aboard).
local function setHealthBarEnabled(data: UnitData, on: boolean)
	local bb = data.part and data.part:FindFirstChild("HealthBar") :: BillboardGui?
	if bb then bb.Enabled = on end
end

-- One-shot 3D mount/dismount cue. Played from a throwaway anchored part (not the
-- Roller itself) so it still sounds when the Roller is destroyed on death.
local ROLLER_MOUNT_SOUND = "rbxassetid://140702055224501"
local function playRollerMountSound(pos: Vector3)
	local p         = Instance.new("Part")
	p.Anchored      = true
	p.CanCollide    = false
	p.CanQuery      = false
	p.Transparency  = 1
	p.Size          = Vector3.new(1, 1, 1)
	p.Position      = pos
	p.Parent        = workspace
	local s              = Instance.new("Sound")
	s.SoundId            = ROLLER_MOUNT_SOUND
	s.Volume             = 0.75
	s.RollOffMinDistance = 8
	s.RollOffMaxDistance = 130
	s.RollOffMode        = Enum.RollOffMode.Linear
	s.Parent             = p
	s:Play()
	s.Ended:Once(function() if p.Parent then p:Destroy() end end)
	Debris:AddItem(p, 6)
end

-- Fold a live unit into a Roller as a passenger: keep it alive but suspend its AI, pull
-- it out of the spatial grid (untargetable), and ride it on top from here on.
local function mountUnitInto(rollerId: string, unitId: string): boolean
	local roller = units[rollerId]
	local rider  = units[unitId]
	if not roller or not rider then return false end
	if roller.unitType ~= "Roller" or roller.hp <= 0 or roller.dying then return false end
	if roller.owner ~= rider.owner then return false end
	if not isMountableType(rider.unitType) then return false end
	if rider.carriedBy then return false end
	roller.carrying = roller.carrying or {}
	if #roller.carrying >= Config.ROLLER_MOUNT_CAPACITY then return false end

	table.insert(roller.carrying, unitId)
	rider.carriedBy     = rollerId
	-- Suspend the rider's own orders/AI while aboard; the Roller drives its combat.
	rider.velocity      = Vector3.zero
	rider.target, rider.path, rider.pathIdx           = nil, nil, nil
	rider.aggroId, rider.aggroHome, rider.focusBldId  = nil, nil, nil
	rider.atkMoveDest, rider.mountTargetId            = nil, nil
	-- Re-phase its attack timer so two same-type riders fire out of sync.
	rider.attackTimer   = math.random() * (rider.attackRate or 1)
	rider.part.CanQuery = false            -- not click-selectable while riding
	-- Tell the client body animators to hold the idle pose while aboard (the part is
	-- dragged along by the Roller each frame, which would otherwise read as walking).
	rider.part:SetAttribute("Carried", true)
	setHealthBarEnabled(rider, false)      -- hide its floating bar on top
	syncRollerAttrs(roller)
	if roller.part then playRollerMountSound(roller.part.Position) end
	return true
end

-- Snap a carried rider to its seat on the Roller for one frame. The disc's axle runs
-- along `right` (it rolls about that axis), so riders sit on its two flat side faces at
-- the wheel's centre height — one to the left, one to the right — facing the Roller's front.
local function positionCarried(roller: UnitData, riderId: string, rider: UnitData)
	local rp     = roller.part
	local center = rp.Position
	local lv     = rp.CFrame.LookVector
	local fwd    = Vector3.new(lv.X, 0, lv.Z)
	if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
	fwd          = fwd.Unit
	local right  = fwd:Cross(Vector3.yAxis).Unit

	-- This rider's index within the Roller's seat list.
	local list  = roller.carrying or {}
	local idx   = 1
	for i, uid in list do if uid == riderId then idx = i; break end end

	-- Alternate riders onto the left / right of the axle, tucked in toward the centre.
	local halfAxle   = rp.Size.X * 0.5                       -- half the disc's width (its flat side)
	local sideOffset = halfAxle * 0.5 + rider.part.Size.X * 0.15
	local sideSign   = if idx % 2 == 1 then -1 else 1        -- 1st rider left, 2nd rider right
	local seat       = center + right * (sideSign * sideOffset)  -- centre height, near the middle
	rider.part.CFrame = CFrame.lookAt(seat, seat + fwd)
end

-- Release a single rider from its carrier (carrier gone, or dismounting): restore its
-- selectability + health bar so normal AI resumes next heartbeat.
local function freeCarried(rider: UnitData)
	rider.carriedBy = nil
	if rider.part then
		rider.part.CanQuery = true
		rider.part:SetAttribute("Carried", nil)   -- resume normal walk/idle gait
	end
	-- Only restore the bar if the unit is actually hurt — a full-HP unit shows no bar,
	-- and forcing it on would leave a healthy dismounted unit with a bar stuck visible.
	setHealthBarEnabled(rider, rider.hp < rider.maxHp)
	rider.velocity    = Vector3.zero
	rider.decorLastCF = nil
end

-- Spill every rider off a Roller (dismount button, or on the Roller's death). Riders stay
-- the same live units — they're just placed back on the ground around the Roller.
local function dismountAll(roller: UnitData, at: Vector3)
	local list = roller.carrying
	if not list or #list == 0 then return end
	for i, uid in list do
		local rider = units[uid]
		if rider then
			freeCarried(rider)
			local ang  = (i / #list) * math.pi * 2 + math.random() * 0.6
			local dist = roller.part and (roller.part.Size.X * 0.5 + 3) or 6
			local gp   = at + Vector3.new(math.cos(ang) * dist, 0, math.sin(ang) * dist)
			local gy   = (terrainManagerRef and terrainManagerRef.surfaceHeightAt(gp.X, gp.Z)) or at.Y
			rider.part.CFrame = CFrame.new(gp.X, gy + rider.part.Size.Y * 0.5 + 0.1, gp.Z)
		end
	end
	roller.carrying = {}
	syncRollerAttrs(roller)
	playRollerMountSound(at)
end

-- Spawns a unit for a Deployer and records it in the tracking tables.
-- Deployed units automatically attack-march toward enemy territory at no resource cost.
function UnitManager.spawnForDeployer(deployerId: string, player: Player, spawnPos: Vector3, unitType: string?)
	local spawnType = unitType or "Survivor"
	local uid = spawnUnit(player, spawnPos, spawnType)
	if uid then
		-- Bonfire summons count as "trained" so train-gated unlocks (e.g. EliteUnits)
		-- still progress now that the Barracks is gone.
		if researchManagerRef and player.UserId > 0 then
			researchManagerRef.recordUnitTrained(player, spawnType)
		end
		if not deployerUnits[deployerId] then deployerUnits[deployerId] = {} end
		deployerUnits[deployerId][uid] = true
		unitToDeployer[uid] = deployerId
		-- Summoned units hold at the bonfire awaiting orders — they keep the spawnUnit
		-- defaults (target=nil, home=spawnPos, atkMoveDest=nil), so they idle where they
		-- appear, still defend against enemies that wander into range, and return to the
		-- bonfire afterwards. The player (or the AI brain) then commands them. Previously
		-- human bonfires auto-attack-marched toward the enemy corner; that is removed.
	end
end

-- Field-upgrade one of `player`'s living Survivors into a Sniper in place: charges
-- the upgrade cost, re-stats it from Config (keeping its current HP fraction so a
-- hurt trooper stays hurt), swaps its decorators to the Sniper blueprint, and
-- retags its UnitType so the client treats it as a Sniper from then on. Keeps the
-- same unit id, so selection and orders carry over. Returns whether it converted.
function UnitManager.upgradeUnit(player: Player, id: string, toType: string): boolean
	local data = units[id]
	if not data or data.owner ~= player or data.hp <= 0 then return false end
	if data.dying or data.immobilized then return false end
	-- Only the Survivor → Sniper path exists for now.
	if data.unitType ~= "Survivor" or toType ~= "Sniper" then return false end
	if not resourceManagerRef then return false end
	if not resourceManagerRef.spend(player, Config.SNIPER_UPGRADE_COST) then return false end

	local part   = data.part
	local hpFrac = math.clamp(data.hp / data.maxHp, 0, 1)

	-- Re-stat from Config for the new type, respecting this player's Engineering upgrades.
	local maxHp    = (Config.UNIT_HP :: any)[toType] or data.maxHp
	local dmg      = (Config.UNIT_ATTACK_DAMAGE :: any)[toType] or data.attackDmg
	local atkRate  = (Config.UNIT_ATTACK_RATE :: any)[toType] or data.attackRate
	local spd      = (Config.UNIT_MOVE_SPEED :: any)[toType] or data.moveSpeed
	local acc      = (Config.UNIT_ACCEL :: any)[toType] or data.accel
	local atkRange = (Config.UNIT_ATTACK_RANGE :: any)[toType] or data.attackRange
	local pm = playerStatMult[player.UserId] and playerStatMult[player.UserId][toType]
	if pm then
		maxHp = maxHp * pm.hp; dmg = dmg * pm.dmg; atkRate = atkRate * pm.rate
		spd = spd * pm.speed; atkRange = atkRange * pm.range
	end

	data.unitType    = toType
	data.maxHp       = maxHp
	data.hp          = math.max(1, math.floor(maxHp * hpFrac + 0.5))
	data.attackDmg   = dmg
	data.attackRate  = atkRate
	data.moveSpeed   = spd
	data.accel       = acc
	data.attackRange = atkRange
	-- Drop Survivor-only transient state so it doesn't linger on the Sniper.
	data.stimUntil, data.stimCooldownUntil = nil, nil

	-- Retag so client voice / projectile / visuals switch to the Sniper.
	local tv = part:FindFirstChild("UnitType")
	if tv and tv:IsA("StringValue") then (tv :: StringValue).Value = toType end

	-- Rebuild the visual decorators from the Sniper blueprint.
	local decs = unitDecorators[id]
	if decs then
		for _, dec in decs do dec.part:Destroy() end
	end
	unitDecorators[id] = {}
	local blueprint = UnitBlueprints.get(toType, part.Size)
	if blueprint then buildFromBlueprint(id, part, blueprint) end
	data.decorLastCF = nil  -- decorators rebuilt → force a fresh sync next heartbeat

	-- Resize the health bar for the new max HP and refresh the fill.
	local bb = part:FindFirstChild("HealthBar") :: BillboardGui?
	if bb then bb.Size = UDim2.new(0, hpBarWidth(maxHp), 0, 4) end
	applyHP(data, false)

	return true
end

-- Returns the number of soldiers currently alive that belong to this Deployer.
function UnitManager.getDeployerAliveCount(deployerId: string): number
	local set = deployerUnits[deployerId]
	if not set then return 0 end
	local count = 0
	for uid in set do
		if units[uid] then count += 1 end
	end
	return count
end

function UnitManager.getUnitCount(player: Player): number
	local n = 0
	for _, data in units do
		if data.owner == player then n += 1 end
	end
	return n
end

function UnitManager.sendAllUnitsTo(player: Player, targetPos: Vector3)
	local ids = {}
	for id, data in units do
		if data.owner == player then table.insert(ids, id) end
	end
	if #ids > 0 then moveUnits(player, ids, targetPos) end
end

-- Send a specific subset of unit IDs to a position (used by AI squad system).
function UnitManager.sendUnitsTo(player: any, ids: { string }, targetPos: Vector3)
	if #ids > 0 then moveUnits(player :: Player, ids, targetPos) end
end

-- Return a list of { id, part, unitType } for all units owned by player.
-- Used by the AI to rebuild squad role assignments each strategy tick.
function UnitManager.getPlayerUnitData(player: any): { { id: string, part: BasePart, unitType: string } }
	local result = {}
	for id, data in units do
		if data.owner == player then
			table.insert(result, { id = id, part = data.part, unitType = data.unitType })
		end
	end
	return result
end

function UnitManager.removeAllUnitsFor(player: any)
	local toRemove = {}
	for id, data in units do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		units[id].part:Destroy()
		units[id] = nil
		local dep = unitToDeployer[id]
		if dep then
			unitToDeployer[id] = nil
			if deployerUnits[dep] then deployerUnits[dep][id] = nil end
		end
	end
end

function UnitManager.resetAll()
	for id, data in units do
		if data.part and data.part.Parent then data.part:Destroy() end
	end
	units            = {}
	unitDecorators   = {}
	playerUnitCount  = {}
	playerStatMult   = {}
	playerUpgradeLog = {}
	table.clear(groundYCache)   -- terrain may regenerate for the next match
	groundYCacheN = 0
	GoreManager.clear()
end

-- Rolls one random Light-research upgrade for `player`: a random stat on a random unit
-- type, improved by a random % within the configured band. Updates the player's stat
-- multipliers (future spawns), retroactively buffs their live units of that type, logs
-- the discovery, and returns (discoveryText, fullHistory). Called by the Engineering Post.
function UnitManager.applyRandomUpgrade(player: any): (string, { string })
	local userId   = player.UserId
	local unitType = UPGRADE_UNITS[math.random(1, #UPGRADE_UNITS)]
	local stat     = UPGRADE_STATS[math.random(1, #UPGRADE_STATS)]
	local pct      = math.random(Config.ENGINEERING_UPGRADE_MIN_PCT, Config.ENGINEERING_UPGRADE_MAX_PCT)
	local factor   = 1 + pct / 100

	local m = statMultFor(userId, unitType)
	for _, data in units do
		local hit = data.owner == player and data.unitType == unitType
		if stat.field == "rate" then
			-- "attack speed" — lower period is faster
			if hit then data.attackRate = data.attackRate / factor end
		elseif stat.field == "dmg" then
			if hit then data.attackDmg = data.attackDmg * factor end
		elseif stat.field == "range" then
			if hit then data.attackRange = data.attackRange * factor end
		elseif stat.field == "speed" then
			if hit then data.moveSpeed = data.moveSpeed * factor end
		elseif stat.field == "hp" then
			if hit then data.maxHp = data.maxHp * factor; data.hp = data.hp * factor end
		end
	end
	if stat.field == "rate" then
		m.rate = m.rate / factor
	else
		(m :: any)[stat.field] = (m :: any)[stat.field] * factor
	end

	local text = string.format("We have improved %s %s by %d%%.",
		UPGRADE_UNIT_NAME[unitType] or unitType, stat.name, pct)
	local log = playerUpgradeLog[userId]
	if not log then log = {}; playerUpgradeLog[userId] = log end
	table.insert(log, text)
	return text, log
end

function UnitManager.getUpgradeHistory(player: any): { string }
	return playerUpgradeLog[player.UserId] or {}
end

function UnitManager.setBuildingManager(bm: any)
	buildingManagerRef = bm
end

function UnitManager.setResearchManager(rm: any)
	researchManagerRef = rm
end

function UnitManager.setMineralManager(mm: any)
	mineralManagerRef = mm
end

function UnitManager.setForestManager(fm: any)
	forestManagerRef = fm
end

function UnitManager.setTerrainManager(tm: any)
	terrainManagerRef = tm
end

function UnitManager.setNavGrid(ng: any)
	navGridRef = ng
end

-- Returns world positions of all of `ownerStr`'s living units. Used by the
-- Artillery spotter check to decide whether a far target is out of the fog.
function UnitManager.getOwnerUnitPositions(ownerStr: string): { Vector3 }
	local out: { Vector3 } = {}
	for _, data in units do
		if data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == ownerStr then
			out[#out + 1] = data.part.Position
		end
	end
	return out
end

-- ── Biological death sounds ────────────────────────────────────────────────────
-- Flesh-and-blood units (troopers + nest creatures) play a wet "blood" splat when
-- they die. Mechanical units (Tank / Howitzer / Foamer / Harvester) are excluded —
-- they read as wreckage, not gore. Each death rolls a random clip AND a random
-- pitch so a crowd of dying units never sounds like the same sample on repeat.
local BLOOD_DEATH_SOUNDS = {
	"rbxassetid://135417409504018",
	"rbxassetid://140325083438865",
	"rbxassetid://135417409504018",
	"rbxassetid://136038559178753",
	"rbxassetid://106771269229569",
}
local BIOLOGICAL_UNIT: { [string]: boolean } = {
	Survivor = true, Sniper = true, Elite = true, Medic = true, CreepySoldier = true,
	Lamprey = true, Hagfish = true, Broodmother = true, Leech = true, Embryo = true,
	Roller = true, Watcher = true, Needler = true,
}

-- Per-type death-sound override: a unit listed here plays this single clip on death
-- instead of the random blood roll (used for units with a distinct death cry). Units
-- that aren't biological still get their death sound this way, but no gore.
local DEATH_SOUND_OVERRIDE: { [string]: string } = {
	Leech = "rbxassetid://9125892855",
}

-- 1-in-N chance a dying soldier is decapitated instead of a normal gore burst.
local SOLDIER_DECAP_CHANCE = 0.1

-- Every dying soldier lets out a death scream (layered over the blood).
local SOLDIER_SCREAM_CHANCE = 1
local SOLDIER_SCREAM_ID     = "rbxassetid://115196347669370"

-- Overkill grading: how far the killing blow drove HP below zero, relative to the
-- unit's max HP, picks the gore tier (1–3). A clean kill ruptures normally; a
-- heavy hit tears the body open; a massive one blows it apart. Read AFTER the
-- fatal damage is applied, when `data.hp` is already negative.
local function goreLevel(data: UnitData): number
	local ratio = -data.hp / math.max(1, data.maxHp)   -- overkill as a fraction of max HP
	if ratio >= 1.5 then return 3
	elseif ratio >= 0.6 then return 2
	else return 1 end
end

-- Death FX for a biological unit: a pitch-varied blood sound plus gore. `level`
-- (1–3) is the gore tier from goreLevel. Most deaths get the standard
-- spray/gibs/pool; ~1 soldier in 10 instead loses its head in a geyser of blood
-- and ragdolls to the ground (reuses its live parts as the corpse, so MUST run
-- before the body root is destroyed).
local function spawnDeathFX(unitType: string, part: BasePart, level: number?, maxHp: number?)
	local override = DEATH_SOUND_OVERRIDE[unitType]
	if not BIOLOGICAL_UNIT[unitType] and not override then return end
	local pos = part.Position

	local anchor        = Instance.new("Part")
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanTouch     = false
	anchor.CanQuery     = false
	anchor.CastShadow   = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.one * 0.1
	anchor.Position     = pos
	anchor.Parent       = workspace

	local s                = Instance.new("Sound")
	s.SoundId              = override or BLOOD_DEATH_SOUNDS[math.random(1, #BLOOD_DEATH_SOUNDS)]
	s.Volume               = 0.5625   -- gore SFX, -25%
	s.PlaybackSpeed        = 0.85 + math.random() * 0.4   -- ~0.85×–1.25× pitch jitter
	s.RollOffMode          = Enum.RollOffMode.Linear
	s.RollOffMinDistance   = 10
	s.RollOffMaxDistance   = 120
	s.Parent               = anchor
	s:Play()

	-- Survivors occasionally scream as they die.
	if unitType == "Survivor" and math.random() < SOLDIER_SCREAM_CHANCE then
		local scream              = Instance.new("Sound")
		scream.SoundId            = SOLDIER_SCREAM_ID
		scream.Volume             = 0.85
		scream.RollOffMode        = Enum.RollOffMode.Linear
		scream.RollOffMinDistance = 14
		scream.RollOffMaxDistance = 160
		scream.Parent             = anchor
		scream:Play()
	end
	Debris:AddItem(anchor, 6)

	-- Gore is only for flesh-and-blood units; override-only units (e.g. Leech) just
	-- get their death sound above.
	if BIOLOGICAL_UNIT[unitType] then
		if unitType == "Survivor" and math.random() < SOLDIER_DECAP_CHANCE then
			GoreManager.decapitate(part)
		else
			GoreManager.spawn(unitType, pos, level, maxHp)
		end
	end
end

-- A Broodmother does not vanish when killed: it freezes, the client plays the
-- collapse/ribcage-split animation, and after BROODMOTHER_DEATH_DURATION the body
-- is removed and BROODMOTHER_DEATH_EGGS Lampreys are born from the wreckage. This
-- is called from every removal path in place of the normal destroy; the unit stays
-- in `units` (flagged `dying`) so the loops skip it until the timer fires.
local function beginBroodmotherDeath(id: string, data: UnitData)
	if data.dying then return end
	spawnDeathFX(data.unitType, data.part, goreLevel(data), data.maxHp)
	data.dying          = true
	data.target         = nil
	data.path           = nil
	data.pathIdx        = nil
	data.velocity       = Vector3.zero
	data.aggroId        = nil
	data.aggroHome      = nil
	data.focusBldId     = nil
	data.broodAuraState = nil

	local owner    = data.owner
	local deathPos = data.part.Position
	if broodDeathRemote then broodDeathRemote:FireAllClients(deathPos) end

	task.delay(Config.BROODMOTHER_DEATH_DURATION, function()
		-- If the Broodmother is already gone (match reset, owner cleanup, etc.) do
		-- nothing — don't birth a phantom brood into a torn-down match.
		local d = units[id]
		if not d then return end

		-- Final removal of the spent Broodmother body.
		unitDecorators[id] = nil
		playerUnitCount[owner.UserId] = math.max(0, (playerUnitCount[owner.UserId] or 1) - 1)
		d.part:Destroy()
		units[id] = nil
		local dep = unitToDeployer[id]
		if dep then
			unitToDeployer[id] = nil
			if deployerUnits[dep] then deployerUnits[dep][id] = nil end
		end

		-- Birth the brood from the wreckage (only if the owner is still playing;
		-- ground Y is resolved inside spawnUnit).
		if owner.Parent then
			local eggs = Config.BROODMOTHER_DEATH_EGGS
			for k = 1, eggs do
				local ang = (k / eggs) * math.pi * 2
				local px  = deathPos.X + math.cos(ang) * 4.5
				local pz  = deathPos.Z + math.sin(ang) * 4.5
				spawnUnit(owner, Vector3.new(px, 0, pz), "Lamprey")
			end
		end
	end)
end

-- `canTarget` (optional): predicate `(targetPos) -> boolean`. When supplied, only
-- enemies it approves are eligible (Artillery uses it to require a spotter).
function UnitManager.damageNearestUnit(fromPos: Vector3, attackerOwnerIdStr: string, range: number, damage: number, canTarget: ((Vector3) -> boolean)?): (boolean, Vector3?)
	local bestId, bestDist = nil :: string?, math.huge
	fillGridScratch(fromPos, range)
	for i = 1, gridScratchN do
		local id   = gridScratch[i]
		local data = units[id]
		if not data or data.hp <= 0 then continue end
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.part.Position - fromPos).Magnitude
		if d <= range and d < bestDist and (not canTarget or canTarget(data.part.Position)) then
			bestDist = d; bestId = id
		end
	end
	if not bestId then return false, nil end
	local data   = units[bestId]
	local hitPos = data.part.Position + Vector3.new(0, data.part.Size.Y * 0.5, 0)
	data.hp -= calcDamage(data, damage)
	applyHP(data, true)
	-- Non-fatal hit on flesh: a small blood spurt (cheap, particle-only, throttled).
	if data.hp > 0 and BIOLOGICAL_UNIT[data.unitType] and math.random() < 0.55 then
		GoreManager.spurt(data.unitType, hitPos)
	end
	if data.hp <= 0 then
		if data.trapperHarpooned then
			for tId, _ in data.trapperHarpooned do
				local tgt = units[tId]
				if tgt then
					local n = (tgt.incomingHarpoons or 1) - 1
					tgt.incomingHarpoons = if n > 0 then n else nil
				end
			end
		end
		if (data.unitType == "Tank" or data.unitType == "Survivor" or data.unitType == "Lamprey")
			and data.owner.UserId > 0 and data.owner.Parent then
			RemoteHandler.get(Config.REMOTES.UnitDied):FireClient(data.owner, data.unitType, hitPos)
		end
		if researchManagerRef and data.owner.UserId ~= tonumber(attackerOwnerIdStr) then
			researchManagerRef.recordEnemyKilled(attackerOwnerIdStr)
		end
		-- Broodmother: collapse + birth its brood instead of vanishing.
		if data.unitType == "Broodmother" then
			beginBroodmotherDeath(bestId, data)
			return true, hitPos
		end
		spawnDeathFX(data.unitType, data.part, goreLevel(data), data.maxHp)
		releaseDragLinks(bestId)
		unitDecorators[bestId] = nil
		playerUnitCount[data.owner.UserId] = math.max(0, (playerUnitCount[data.owner.UserId] or 1) - 1)
		data.part:Destroy()
		units[bestId] = nil
		local dep = unitToDeployer[bestId]
		if dep then
			unitToDeployer[bestId] = nil
			if deployerUnits[dep] then deployerUnits[dep][bestId] = nil end
		end
	end
	return true, hitPos
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function UnitManager.init(resourceManager)
	resourceManagerRef = resourceManager
	unitsFolder        = Instance.new("Folder")
	unitsFolder.Name   = "Units"
	unitsFolder.Parent = workspace

	local LEASH         = Config.UNIT_LEASH_RANGE
	local AGGRO         = Config.UNIT_AGGRO_RADIUS
	local unitHitRemote  = RemoteHandler.get(Config.REMOTES.UnitHit)
	local unitDiedRemote = RemoteHandler.get(Config.REMOTES.UnitDied)
	local healBeamRemote = RemoteHandler.get(Config.REMOTES.HealBeam)
	local hagfishStrikeRemote = RemoteHandler.get(Config.REMOTES.HagfishStrike)
	broodDeathRemote          = RemoteHandler.get(Config.REMOTES.BroodmotherDeath)

	-- Terrain-height snapping: cast straight down to find the surface Y at any XZ.
	-- Filters to Terrain only so buildings/units don't interfere.
	local terrainRp = RaycastParams.new()
	terrainRp.FilterType = Enum.RaycastFilterType.Include
	terrainRp.FilterDescendantsInstances = { workspace.Terrain }

	local RAY_DOWN = Vector3.new(0, -120, 0)
	local function getGroundY(x: number, z: number, halfSizeY: number): number
		-- Quantise to the 1-stud memo grid (map is ±432, so qx offsets by 4096 pack
		-- uniquely with qz into one integer key).
		local qx  = math.floor(x + 0.5)
		local qz  = math.floor(z + 0.5)
		local key = qx * 4096 + qz
		local y   = groundYCache[key]
		if y == nil then
			-- Origin well above the tallest terrain (main plateau ≈20, lane walls 26).
			local result = workspace:Raycast(Vector3.new(qx, 80, qz), RAY_DOWN, terrainRp)
			y = if result then result.Position.Y else 0.1
			if groundYCacheN >= GROUND_CACHE_MAX then
				table.clear(groundYCache)
				groundYCacheN = 0
			end
			groundYCache[key] = y
			groundYCacheN += 1
		end
		return y + halfSizeY
	end

	-- Cliff-aware move resolution: units may only change elevation gently (ramps).
	-- If a straight step would cross a cliff, slide along it (try each axis alone);
	-- if both are blocked, hold position. Returns the resolved world position.
	local NAV_MAX_SLOPE = 0.6
	local function resolveStep(pos: Vector3, nx: number, nz: number, halfSizeY: number, radius: number?): Vector3
		-- Units don't walk through structures. Skip the check if the unit is already
		-- overlapping a building (e.g. one was placed on top of it) so it can walk out
		-- instead of freezing in place.
		local checkBuildings = radius ~= nil and buildingManagerRef ~= nil
			and not buildingManagerRef.blocksMovement(pos.X, pos.Z, radius)
		local function tryXZ(x: number, z: number): (boolean, number)
			local gy    = getGroundY(x, z, halfSizeY)
			local dxx   = x - pos.X
			local dzz   = z - pos.Z
			local horiz = math.sqrt(dxx * dxx + dzz * dzz)
			-- Constant slack absorbs voxel-smoothing noise and the small spawn offset;
			-- a real cliff (a full STEP ≈12) is far above it and stays blocked.
			if math.abs(gy - pos.Y) > NAV_MAX_SLOPE * horiz + 0.5 then return false, gy end
			if checkBuildings and buildingManagerRef.blocksMovement(x, z, radius) then return false, gy end
			return true, gy
		end
		local ok, gy = tryXZ(nx, nz)
		if ok then return Vector3.new(nx, gy, nz) end
		local okx, gyx = tryXZ(nx, pos.Z)
		if okx then return Vector3.new(nx, gyx, pos.Z) end
		local okz, gyz = tryXZ(pos.X, nz)
		if okz then return Vector3.new(pos.X, gyz, nz) end
		return pos
	end

	-- ── Wounded-soldier pose + rescue movement ─────────────────────────────────

	-- Lay a downed soldier on the ground, head up, preserving its facing yaw.
	local PRONE_DROP = 0.28   -- fraction of body height the reclined body sinks
	local function applyPronePose(data: UnitData, yaw: number?)
		local p   = data.part
		local pos = p.Position
		local y   = yaw
		if not y then local _, yy, _ = p.CFrame:ToOrientation(); y = yy end
		local groundY = getGroundY(pos.X, pos.Z, p.Size.Y / 2)
		local proneY  = groundY - p.Size.Y * PRONE_DROP
		p.CFrame = CFrame.new(pos.X, proneY, pos.Z)
			* CFrame.Angles(0, y :: number, 0)
			* CFrame.Angles(-Config.SOLDIER_PRONE_PITCH, 0, 0)
	end

	-- Per-frame rescue logic for every downed soldier: recover if healed, haul home
	-- if crewed, heal at base on arrival, else just lie prone awaiting rescue.
	local function processRescues(dt: number)
		for cid, cas in units do
			if not cas.immobilized then continue end

			-- Recovered enough (CC heal or a Medic patched them up) → get back up.
			if cas.hp / cas.maxHp >= Config.SOLDIER_RECOVER_RATIO then
				if cas.draggedBy then
					for _, rid in cas.draggedBy do
						local r = units[rid]
						if r and r.draggingId == cid then r.draggingId = nil end
					end
					cas.draggedBy = nil
				end
				cas.immobilized = false
				cas.healingAtCC = false
				cas.velocity    = Vector3.zero
				local p = cas.part
				local _, yaw, _ = p.CFrame:ToOrientation()
				p.CFrame  = CFrame.new(p.Position.X, getGroundY(p.Position.X, p.Position.Z, p.Size.Y / 2), p.Position.Z)
					* CFrame.Angles(0, yaw, 0)
				cas.home  = p.Position
				continue
			end

			-- Drop rescuers that died, went down themselves, or got reassigned.
			if cas.draggedBy then
				local i = 1
				while i <= #cas.draggedBy do
					local r = units[cas.draggedBy[i]]
					if not r or r.hp <= 0 or r.immobilized or r.draggingId ~= cid then
						if r and r.draggingId == cid then r.draggingId = nil end
						table.remove(cas.draggedBy, i)
					else
						i += 1
					end
				end
				if #cas.draggedBy == 0 then cas.draggedBy = nil end
			end

			-- Already home: regenerate slowly until RECOVER_RATIO (handled above).
			if cas.healingAtCC then
				cas.hp = math.min(cas.maxHp, cas.hp + Config.SOLDIER_HEAL_RATE * dt)
				applyHP(cas)
				applyPronePose(cas)
				continue
			end

			local ccPos = getOwnerCC(cas.owner)
			local crew  = cas.draggedBy and #cas.draggedBy or 0
			if crew == 0 or not ccPos then
				applyPronePose(cas)   -- no rescuers (or no base): lie where they fell
				continue
			end

			local cp   = cas.part.Position
			local flat = Vector3.new(ccPos.X - cp.X, 0, ccPos.Z - cp.Z)
			local dist = flat.Magnitude
			if dist <= Config.SOLDIER_HEAL_RADIUS then
				-- Arrived home: release rescuers and begin healing.
				for _, rid in cas.draggedBy do
					local r = units[rid]
					if r and r.draggingId == cid then
						r.draggingId = nil
						r.home       = r.part.Position
						r.target     = nil
						r.velocity   = Vector3.zero
					end
				end
				cas.draggedBy   = nil
				cas.healingAtCC = true
				applyPronePose(cas)
				continue
			end

			-- Haul toward the CC; each rescuer adds DRAG_SPEED (2 = twice as fast).
			local dir   = Vector3.new(flat.X / dist, 0, flat.Z / dist)
			local speed = Config.SOLDIER_DRAG_SPEED * math.min(crew, Config.SOLDIER_DRAG_SLOTS)
			local step  = math.min(speed * dt, dist)
			local nx, nz = cp.X + dir.X * step, cp.Z + dir.Z * step
			local yaw    = math.atan2(-dir.X, -dir.Z)   -- face travel direction
			cas.part.CFrame = CFrame.new(nx, cas.part.Position.Y, nz)  -- XZ first; pose fixes Y/tilt
			applyPronePose(cas, yaw)

			-- Position rescuers just ahead, flanking, facing the CC.
			local perp = Vector3.new(-dir.Z, 0, dir.X)
			for k, rid in cas.draggedBy do
				local r = units[rid]
				if not r then continue end
				local side = (k == 1) and -1 or 1
				local rx = nx + dir.X * 2.2 + perp.X * 1.6 * side
				local rz = nz + dir.Z * 2.2 + perp.Z * 1.6 * side
				local ry = getGroundY(rx, rz, r.part.Size.Y / 2)
				r.part.CFrame = CFrame.lookAt(Vector3.new(rx, ry, rz), Vector3.new(rx + dir.X, ry, rz + dir.Z))
				r.velocity = Vector3.zero
			end
		end
	end

	RunService.Heartbeat:Connect(function(dt)
		local toRemove: { string } = {}
		rebuildSpatialGrid()
		aggroScanFrame = (aggroScanFrame + 1) % AGGRO_SCAN_EVERY
		local doAggro  = aggroScanFrame == 0

		for id, data in units do
			-- A dying Broodmother is frozen mid-collapse; skip all AI until the
			-- death timer (beginBroodmotherDeath) removes it.
			if data.dying then continue end

			-- ── Carried passenger: snapped to a seat on top of its Roller ─────────
			-- Its own AI is suspended (the Roller fires ranged riders + grinds with melee
			-- riders — see the Roller attack block). If the carrier is gone, become free.
			if data.carriedBy then
				local roller = units[data.carriedBy]
				if roller and roller.hp > 0 and not roller.dying and roller.unitType == "Roller" then
					data.velocity = Vector3.zero
					positionCarried(roller, id, data)
					continue
				end
				freeCarried(data)   -- carrier lost: resume normal AI this frame
			end

			-- A burrowed Leech is in a structure state: rooted underground, paying out
			-- passive income each interval, never moving or attacking. Skip all of its
			-- unit AI until it unburrows.
			if data.burrowed then
				data.velocity = Vector3.zero
				local now = os.clock()
				if not data.burrowIncomeAt then
					data.burrowIncomeAt = now + Config.LEECH_BURROW_INTERVAL
				elseif now >= (data.burrowIncomeAt :: number) then
					data.burrowIncomeAt = now + Config.LEECH_BURROW_INTERVAL
					if resourceManagerRef and data.owner and data.owner.UserId > 0 then
						resourceManagerRef.add(data.owner, Config.LEECH_BURROW_INCOME)
					end
					-- Signal every client to play this leech's feeding/harvest animation.
					RemoteHandler.get(Config.REMOTES.LeechHarvest):FireAllClients(id)
				end
				continue
			end

			-- ── Mount intent: walk into a Roller and climb in ─────────────────────
			-- Set when the player right-clicks (or "mount nearby"s) a Roller. The rider
			-- heads for the Roller and is folded in as a passenger once it's close enough.
			if data.mountTargetId then
				local roller = units[data.mountTargetId]
				if not roller or roller.hp <= 0 or roller.dying or roller.unitType ~= "Roller"
					or roller.owner ~= data.owner then
					data.mountTargetId = nil
				else
					local rp   = roller.part.Position
					local mp   = data.part.Position
					local dist = math.sqrt((rp.X - mp.X)^2 + (rp.Z - mp.Z)^2)
					if dist <= Config.ROLLER_MOUNT_RANGE then
						if roller.carrying and #roller.carrying >= Config.ROLLER_MOUNT_CAPACITY then
							data.mountTargetId = nil   -- Roller filled up before we arrived
						elseif mountUnitInto(data.mountTargetId, id) then
							continue                    -- this unit is now carried on top
						end
					else
						-- Steer toward the Roller; drop any competing orders while boarding.
						data.aggroId, data.aggroHome, data.focusBldId, data.atkMoveDest = nil, nil, nil, nil
						data.path, data.pathIdx = nil, nil
						data.target = Vector3.new(rp.X, 0, rp.Z)
					end
				end
			end

			-- ── Roller passengers: ranged riders fire from on top ─────────────────
			-- Each ranged rider fires its OWN shot on its OWN timer (re-phased at boarding
			-- so they never fire in unison). When several enemies are in range they spread
			-- onto different targets so you see each projectile individually, only doubling
			-- up on one foe once every other target has been claimed. Shots visibly leave
			-- the rider's seat (its live part), so it looks like the real unit is firing.
			if data.unitType == "Roller" and data.carrying and #data.carrying > 0 then
				local rPos    = data.part.Position
				local ownerStr= tostring(data.owner.UserId)
				local claimed: { [string]: boolean } = {}   -- targets already shot at this frame
				for _, uid in data.carrying do
					local pass = units[uid]
					if not pass then continue end
					if classifyPassenger(pass.unitType) ~= "ranged" then continue end
					pass.attackTimer += dt
					if pass.attackTimer < pass.attackRate then continue end
					local fromP = pass.part.Position   -- rider's seat on top of the Roller
					-- Prefer the nearest UNCLAIMED enemy; keep a claimed fallback so a lone
					-- enemy still takes both shots rather than one rider holding fire.
					local tgtId: string?, tgtPos: Vector3?, best  = nil, nil, math.huge
					local fbId:  string?, fbPos:  Vector3?, fbBest = nil, nil, math.huge
					fillGridScratch(rPos, pass.attackRange)
					for gi = 1, gridScratchN do
						local oid   = gridScratch[gi]
						local other = units[oid]
						if not other or other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == ownerStr then continue end
						local d = (other.part.Position - rPos).Magnitude
						if d > pass.attackRange then continue end
						if claimed[oid] then
							if d < fbBest then fbBest = d; fbId = oid; fbPos = other.part.Position end
						elseif d < best then
							best = d; tgtId = oid; tgtPos = other.part.Position
						end
					end
					if not tgtId then tgtId, tgtPos = fbId, fbPos end   -- all claimed → double up
					if tgtId then
						pass.attackTimer = 0
						claimed[tgtId] = true
						local other = units[tgtId]
						other.hp -= calcDamage(other, pass.attackDmg)
						applyHP(other, true)
						if other.hp <= 0 then table.insert(toRemove, tgtId) end
						unitHitRemote:FireAllClients(fromP, (tgtPos :: Vector3) + Vector3.new(0, 2, 0), pass.unitType)
					elseif buildingManagerRef then
						local bId, bPos = buildingManagerRef.getNearestEnemyBuilding(rPos, ownerStr, pass.attackRange)
						if bId and bPos then
							pass.attackTimer = 0
							buildingManagerRef.damage(bId, pass.attackDmg)
							unitHitRemote:FireAllClients(fromP, bPos, pass.unitType)
						end
					end
				end
			end

			-- ── Bloody footprints ─────────────────────────────────────────────
			-- Sampled every FOOTSTEP_DIST studs walked: stepping on a blood stain re-inks
			-- the feet, and while inked the unit drops a fading footprint each step, so it
			-- tracks a trail through and out of the pool.
			do
				local ppos = data.part.Position
				local last = data.lastStepPos
				if not last then
					data.lastStepPos = ppos
				elseif (ppos - last).Magnitude >= FOOTSTEP_DIST then
					data.lastStepPos = ppos
					local col = GoreManager.bloodColorAt(ppos.X, ppos.Z)
					if col then
						data.bloodColor     = col
						data.bloodStepsLeft = TRAIL_STEPS
					end
					if data.bloodStepsLeft and data.bloodStepsLeft > 0 and data.bloodColor then
						GoreManager.leaveFootprint(ppos, data.bloodColor)
						data.bloodStepsLeft -= 1
					end
				end
			end

			-- ── Wounded-soldier collapse roll ─────────────────────────────────
			-- A badly-hurt soldier may go down: prone, still able to shoot but
			-- unable to move. Chance rises the closer to death they are. Posing,
			-- dragging and healing of downed soldiers run in the rescue pass below.
			if data.unitType == "Survivor" and not data.immobilized and data.hp > 0 then
				local ratio = data.hp / data.maxHp
				if ratio <= Config.SOLDIER_IMMOBILIZE_THRESHOLD then
					local nowT = tick()
					if not data.immobCheckAt or nowT >= (data.immobCheckAt :: number) then
						data.immobCheckAt = nowT + Config.SOLDIER_IMMOBILIZE_CHECK_EVERY
						local frac   = 1 - (ratio / Config.SOLDIER_IMMOBILIZE_THRESHOLD)  -- 0 at threshold → 1 near death
						local chance = Config.SOLDIER_IMMOBILIZE_MIN_CHANCE
							+ frac * (Config.SOLDIER_IMMOBILIZE_MAX_CHANCE - Config.SOLDIER_IMMOBILIZE_MIN_CHANCE)
						if math.random() < chance then
							data.immobilized = true
							data.target, data.path, data.pathIdx = nil, nil, nil
							data.aggroId, data.aggroHome, data.focusBldId, data.atkMoveDest = nil, nil, nil, nil
							data.rollerCharging, data.rollerChargingOut = nil, nil
							data.velocity = Vector3.zero
							if data.draggingId then releaseDragLinks(id) end  -- a rescuer that just went down
						end
					end
				end
			end

			local isRoller  = data.unitType == "Survivor" and researchManagerRef ~= nil
				and researchManagerRef.hasResearch(data.owner, "Rollers")
			if isRoller then data.attackRange = Config.ROLLER_ATTACK_RANGE end

			local isFoamer  = data.foamState ~= nil
			local foamState = data.foamState or ""

			-- ── 1. Aggro: update chase target or resolve ───────────────────────
			if data.aggroId then
				local aggroTarget = units[data.aggroId]
				if not aggroTarget or aggroTarget.hp <= 0 then
					data.aggroId   = nil
					data.aggroHome = nil
					data.target    = data.atkMoveDest or data.home
				else
					local ep    = aggroTarget.part.Position
					local myPos = data.part.Position
					local dx    = ep.X - myPos.X
					local dz    = ep.Z - myPos.Z
					local dist  = math.sqrt(dx * dx + dz * dz)
					local stopAt = data.attackRange * 0.85
					if dist > stopAt then
						local frac  = (dist - stopAt) / dist
						data.target = Vector3.new(myPos.X + dx * frac, 0, myPos.Z + dz * frac)
					else
						data.target = nil   -- already in range, hold position
					end

					if data.aggroHome then
						if (myPos - data.aggroHome).Magnitude > LEASH then
							data.aggroId   = nil
							data.aggroHome = nil
							data.target    = data.atkMoveDest or data.home
						end
					end
				end
			end

			-- ── 1b. Focus building: approach and hold at attack range ──────────
			if data.focusBldId and not data.aggroId then
				local bf    = workspace:FindFirstChild("Buildings")
				local model = bf and bf:FindFirstChild(data.focusBldId)
				local base  = model and model:FindFirstChild("Base")
				if not base or not (base :: BasePart).Parent then
					data.focusBldId = nil
				else
					local bpos  = (base :: BasePart).Position
					local myPos = data.part.Position
					local dx    = bpos.X - myPos.X
					local dz    = bpos.Z - myPos.Z
					local dist  = math.sqrt(dx * dx + dz * dz)
					local stopAt = data.attackRange * 0.85
					if dist > stopAt then
						local frac  = (dist - stopAt) / dist
						data.target = Vector3.new(myPos.X + dx * frac, 0, myPos.Z + dz * frac)
					else
						data.target = nil   -- in range, hold position
					end
				end
			end

			-- ── Hagfish: rooted while its head is buried mid-attack ───────────
			-- Holds position from the head-slap until the tentacles retreat and the
			-- head rears back up, so the body doesn't slide during the animation.
			if data.attackLockUntil and tick() < (data.attackLockUntil :: number) then
				data.target   = nil
				data.velocity = Vector3.zero
			end

			-- ── Foamer: deploy / undeploy state machine ───────────────────────
			if isFoamer then
				local ft = tick()
				if foamState == "mobile" then
					-- Deploy when aggro target enters attack range
					if data.aggroId then
						local aggroTarget = units[data.aggroId]
						if aggroTarget and aggroTarget.hp > 0 then
							local dist = (aggroTarget.part.Position - data.part.Position).Magnitude
							if dist <= data.attackRange then
								foamState            = "deploying"
								data.foamState       = "deploying"
								data.foamDeployStart = ft
								data.foamSinkBaseY   = data.part.Position.Y
								data.target          = nil
								data.velocity        = Vector3.zero
							end
						end
					end
				else
					-- Freeze movement in all non-mobile states
					data.target   = nil
					data.velocity = Vector3.zero
					if foamState == "deploying" then
						local elapsed  = ft - (data.foamDeployStart :: number)
						local progress = math.min(elapsed / Config.FOAMER_DEPLOY_TIME, 1)
						-- Sink body
						local sinkY = (data.foamSinkBaseY :: number) - Config.FOAMER_SINK_DEPTH * progress
						data.part.CFrame = CFrame.new(data.part.Position.X, sinkY, data.part.Position.Z) * data.part.CFrame.Rotation
						-- Raise barrel (localCF.Y interpolates from 0.3 → 3.5)
						if data.foamBarrelDec then
							(data.foamBarrelDec :: Decorator).localCF = CFrame.new(0, 0.3 + 3.2 * progress, 0)
							data.decorLastCF = nil  -- localCF changed → force decorator resync
						end
						if progress >= 1 then
							foamState      = "deployed"
							data.foamState = "deployed"
						end
					elseif foamState == "deployed" then
						-- Undeploy if no enemies remain in range
						local hasEnemy = false
						local fmPos    = data.part.Position
						local fmStr    = tostring(data.owner.UserId)
						fillGridScratch(fmPos, data.attackRange)
						for fgi = 1, gridScratchN do
							local fmOther = units[gridScratch[fgi]]
							if fmOther and fmOther.hp > 0 and tostring(fmOther.owner.UserId) ~= fmStr then
								hasEnemy = true; break
							end
						end
						if not hasEnemy then
							foamState            = "undeploying"
							data.foamState       = "undeploying"
							data.foamDeployStart = ft
							data.foamSinkBaseY   = data.part.Position.Y
							data.aggroId         = nil
							data.aggroHome       = nil
						end
					elseif foamState == "undeploying" then
						local elapsed  = ft - (data.foamDeployStart :: number)
						local progress = math.min(elapsed / Config.FOAMER_UNDEPLOY_TIME, 1)
						-- Rise body back
						local riseY = (data.foamSinkBaseY :: number) + Config.FOAMER_SINK_DEPTH * progress
						data.part.CFrame = CFrame.new(data.part.Position.X, riseY, data.part.Position.Z) * data.part.CFrame.Rotation
						-- Retract barrel (localCF.Y interpolates from 3.5 → 0.3)
						if data.foamBarrelDec then
							(data.foamBarrelDec :: Decorator).localCF = CFrame.new(0, 3.5 - 3.2 * progress, 0)
							data.decorLastCF = nil  -- localCF changed → force decorator resync
						end
						if progress >= 1 then
							foamState      = "mobile"
							data.foamState = "mobile"
							-- Re-snap to ground after undeploy
							local fpos3   = data.part.Position
							local groundY = getGroundY(fpos3.X, fpos3.Z, data.part.Size.Y / 2)
							data.part.CFrame = CFrame.new(fpos3.X, groundY, fpos3.Z) * data.part.CFrame.Rotation
						end
					end
				end
			end
			-- ────────────────────────────────────────────────────────────────────

			-- ── 2. Velocity-based movement ────────────────────────────────────
			local pos = data.part.Position

			-- Roller charge: fast dash to target and bounce back, bypasses normal movement
			if isRoller and (data.rollerCharging or data.rollerChargingOut) then
				local chargeTarget = if data.rollerCharging
					then (data.rollerChargeTarget :: Vector3)
					else (data.rollerChargeHome  :: Vector3)
				local cDelta = Vector3.new(chargeTarget.X - pos.X, 0, chargeTarget.Z - pos.Z)
				local cDist  = cDelta.Magnitude
				if cDist < 1.5 then
					if data.rollerCharging then
						data.rollerCharging    = false
						data.rollerChargingOut = true
					else
						data.rollerChargingOut  = false
						data.rollerChargeHome   = nil
						data.rollerChargeTarget = nil
					end
				else
					local step   = math.min(Config.ROLLER_CHARGE_SPEED * dt, cDist)
					local np     = pos + cDelta.Unit * step
					local newPos = resolveStep(pos, np.X, np.Z, data.part.Size.Y / 2, data.part.Size.X / 2)
					data.rollerAngle = ((data.rollerAngle or 0) + step * Config.ROLLER_ROLL_PER_STUD) % (2 * math.pi)
					data.part.CFrame = CFrame.lookAt(newPos, newPos + cDelta.Unit) * CFrame.Angles(-data.rollerAngle, 0, 0)
				end
			else
				-- Normal velocity-based movement
				local desired = Vector3.zero
				if data.target then
					-- Intermediate nav waypoints use a looser arrival radius than the
					-- final destination so units don't stutter passing through them.
					local onPath    = data.path ~= nil and data.pathIdx ~= nil
						and (data.pathIdx :: number) < #(data.path :: { Vector3 })
						and data.target == (data.path :: { Vector3 })[data.pathIdx :: number]
					local arriveR   = onPath and 3.5 or 1.5
					local flat  = Vector3.new(data.target.X, pos.Y, data.target.Z)
					local delta = flat - pos
					if delta.Magnitude < arriveR then
						if onPath then
							-- Advance to the next waypoint
							local nextIdx = (data.pathIdx :: number) + 1
							data.pathIdx  = nextIdx
							data.target   = (data.path :: { Vector3 })[nextIdx]
						else
							-- Arrived at the final destination
							data.path    = nil
							data.pathIdx = nil
							data.target  = nil
							if not data.aggroId then
								data.home = pos
								if data.atkMoveDest and (pos - data.atkMoveDest).Magnitude < 3 then
									data.atkMoveDest = nil
								end
							end
							-- A freshly-spawned Leech reached its scatter point: burrow itself.
							if data.autoBurrow and data.hp > 0 then
								setLeechBurrowed(data, true)
							end
						end
					else
						local effSpeed = data.moveSpeed
						local t = tick()
						if data.slowUntil and t < (data.slowUntil :: number) then
							effSpeed = effSpeed * Config.TANK_SLOW_MULT
						end
						if data.incomingHarpoons and (data.incomingHarpoons :: number) > 0 then
							effSpeed = effSpeed * (Config.TRAPPER_SLOW_MULT ^ (data.incomingHarpoons :: number))
						end
						if data.foamedUntil and t < (data.foamedUntil :: number) then
							effSpeed = effSpeed * Config.FOAMER_FOAM_SLOW_MULT
						end
						if data.unitType == "Survivor" and data.stimUntil and t < (data.stimUntil :: number) then
							effSpeed = effSpeed * Config.SOLDIER_STIM_SPEED
						end
						if isRoller then effSpeed = effSpeed * Config.ROLLER_SPEED_MULT end
						desired = delta.Unit * effSpeed

						-- Terrain obstacle avoidance: repel from obstacle edges.
						-- Elevated units (on ramps/platforms) skip this so the platform
						-- obstacle parts don't push them sideways off the terrain.
						local unitIsElevated = pos.Y > data.part.Size.Y / 2 + 4
						local terrainF = if unitIsElevated then nil else workspace:FindFirstChild("TerrainObstacles")
						if terrainF then
							local repX, repZ = 0, 0
							local AVOID_R = Config.TERRAIN_AVOIDANCE_RADIUS
							for _, obs in terrainF:GetChildren() do
								if not obs:IsA("BasePart") then continue end
								local hw = obs.Size.X / 2
								local hd = obs.Size.Z / 2
								local ox = obs.Position.X
								local oz = obs.Position.Z
								local cx2 = math.clamp(pos.X, ox - hw, ox + hw)
								local cz2 = math.clamp(pos.Z, oz - hd, oz + hd)
								local sx  = pos.X - cx2
								local sz  = pos.Z - cz2
								local sd  = math.sqrt(sx * sx + sz * sz)
								if sd < AVOID_R then
									local nx, nz
									if sd > 0.05 then
										nx = sx / sd; nz = sz / sd
									else
										nx = 1; nz = 0  -- emergency escape
									end
									local strength = (1 - sd / AVOID_R) ^ 2
									repX = repX + nx * strength
									repZ = repZ + nz * strength
								end
							end
							if repX ~= 0 or repZ ~= 0 then
								desired = desired + Vector3.new(repX, 0, repZ) * effSpeed * 2
								local dMag = desired.Magnitude
								if dMag > effSpeed then
									desired = desired * (effSpeed / dMag)
								end
							end
						end
					end
				end

				-- Lerp velocity: decelerate faster than accelerate for snappier stops
				local lerpFactor = if desired.Magnitude < 0.1
					then math.min(data.accel * 2.5 * dt, 1)
					else math.min(data.accel * dt, 1)
				data.velocity = data.velocity:Lerp(desired, lerpFactor)

				-- Apply velocity and face the direction of travel
				local vel = data.velocity
				if vel.Magnitude > 0.15 then
					local newX   = math.clamp(pos.X + vel.X * dt, -MOVE_BOUND, MOVE_BOUND)
					local newZ   = math.clamp(pos.Z + vel.Z * dt, -MOVE_BOUND, MOVE_BOUND)
					-- (elevation handled by resolveStep)
					local newPos = resolveStep(pos, newX, newZ, data.part.Size.Y / 2, data.part.Size.X / 2)
					local flatVel = Vector3.new(vel.X, 0, vel.Z)
					if flatVel.Magnitude > 0.5 then
						if isRoller then
							data.rollerAngle = ((data.rollerAngle or 0) + vel.Magnitude * dt * Config.ROLLER_ROLL_PER_STUD) % (2 * math.pi)
							data.part.CFrame = CFrame.lookAt(newPos, newPos + flatVel) * CFrame.Angles(-data.rollerAngle, 0, 0)
						else
							data.part.CFrame = CFrame.lookAt(newPos, newPos + flatVel)
						end
					else
						data.part.Position = newPos
					end

					-- Medium+ units bulldoze any trees they push into.
					if forestManagerRef and FELLS_TREES[data.unitType] then
						local felled = forestManagerRef.knockNear(newPos, math.max(data.part.Size.X, data.part.Size.Z) * 0.5)
						-- Lampreys feed on the forest: each felled tree grows them.
						if felled > 0 and data.unitType == "Lamprey" then
							growLamprey(data, felled)
						end
					end
				end
			end

			-- ── 3. Aggro scan (idle + A-moving units only; Medics/frozen Foamers skip) ──
			-- Downed soldiers hold position (they still shoot via the combat scan below,
			-- just never chase); active rescuers are busy hauling.
			if doAggro and not data.aggroId and not data.focusBldId and data.unitType ~= "Medic"
				and data.unitType ~= "Leech"  -- non-combat Hollowed unit
				and not data.immobilized and not data.draggingId
				and not (isFoamer and foamState ~= "mobile") then
				if data.target == nil or data.atkMoveDest ~= nil then
					local myStr = tostring(data.owner.UserId)
					local myPos = data.part.Position
					-- Acquire from the unit's actual reach: a long-range unit (Sniper,
					-- Howitzer, …) engages the moment an enemy enters firing range
					-- instead of marching to the fixed short aggro radius first.
					local acqR = math.max(AGGRO, data.attackRange)
					-- Snipers won't lock onto a target hidden in the fog (so they don't
					-- march up to something they aren't allowed to shoot).
					local acqSpotter: ((Vector3) -> boolean)? = nil
					if data.unitType == "Sniper" and buildingManagerRef and buildingManagerRef.makeSpotterCheck then
						acqSpotter = buildingManagerRef.makeSpotterCheck(myStr)
					end
					local bestId2, bestDist2 = nil :: string?, acqR + 1
					local acx0 = math.floor((myPos.X - acqR) / GRID_CELL) + GRID_OFFSET
					local acx1 = math.floor((myPos.X + acqR) / GRID_CELL) + GRID_OFFSET
					local acz0 = math.floor((myPos.Z - acqR) / GRID_CELL) + GRID_OFFSET
					local acz1 = math.floor((myPos.Z + acqR) / GRID_CELL) + GRID_OFFSET
					for gx = acx0, acx1 do
						for gz = acz0, acz1 do
							local cell = spatialGrid[gx * GRID_STRIDE + gz]
							if not cell then continue end
							for _, otherId in cell do
								local other = units[otherId]
								if not other or other.hp <= 0 then continue end
								if tostring(other.owner.UserId) == myStr then continue end
								local dx = other.part.Position.X - myPos.X
								local dz = other.part.Position.Z - myPos.Z
								local d  = math.sqrt(dx * dx + dz * dz)
								if d <= acqR and d < bestDist2 and (not acqSpotter or acqSpotter(other.part.Position)) then
									bestDist2 = d; bestId2 = otherId
								end
							end
						end
					end
					if bestId2 then
						data.aggroId   = bestId2
						data.aggroHome = data.part.Position
						-- Auto-trigger Combat Stims on engagement
						if data.unitType == "Survivor" and researchManagerRef
							and researchManagerRef.hasResearch(data.owner, "CombatStims") then
							local t = tick()
							if not data.stimCooldownUntil or t >= (data.stimCooldownUntil :: number) then
								data.stimUntil         = t + Config.SOLDIER_STIM_DURATION
								data.stimCooldownUntil = t + Config.SOLDIER_STIM_DURATION + Config.SOLDIER_STIM_COOLDOWN
							end
						end
					end
				end
			end

			-- ── 4. Combat ─────────────────────────────────────────────────────
			if data.hp <= 0 then continue end
			-- Rescuers carrying a casualty can't fire (downed soldiers still can).
			if data.draggingId then continue end

			-- Foamer: foam attack when deployed; skip normal combat in all states
			if isFoamer then
				if foamState == "deployed" then
					data.attackTimer += dt
					if data.attackTimer >= data.attackRate then
						data.attackTimer -= data.attackRate
						local fmPos  = data.part.Position
						local fmStr  = tostring(data.owner.UserId)
						local fmBest: string?  = nil
						local fmDist           = math.huge
						fillGridScratch(fmPos, data.attackRange)
						for fgi = 1, gridScratchN do
							local otherId = gridScratch[fgi]
							local other   = units[otherId]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == fmStr then continue end
							local d = (other.part.Position - fmPos).Magnitude
							if d <= data.attackRange and d < fmDist then
								fmDist = d; fmBest = otherId
							end
						end
						if fmBest then
							local other   = units[fmBest]
							local hitPos  = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							-- Apply foam debuff only if the target is not already foamed
							local now = tick()
							if not other.foamedUntil or now >= (other.foamedUntil :: number) then
								other.foamedUntil  = now + Config.FOAMER_FOAM_DURATION
								other.foamDotAccum = 0
							end
							-- Small direct-hit damage
							other.hp -= calcDamage(other, data.attackDmg)
							applyHP(other, true)
							if other.hp <= 0 then table.insert(toRemove, fmBest) end
							-- Face the target
							local flatDir = Vector3.new(hitPos.X - fmPos.X, 0, hitPos.Z - fmPos.Z)
							if flatDir.Magnitude > 0.1 then
								data.part.CFrame = CFrame.lookAt(fmPos, fmPos + flatDir)
							end
							-- Fire foam VFX from barrel tip
							local barrelTip = fmPos + Vector3.new(0, data.part.Size.Y / 2 + 2, 0)
							unitHitRemote:FireAllClients(barrelTip, hitPos, "Foam")
						end
					end
				end
				continue  -- Foamers skip all standard combat paths
			end

			-- ── Broodmother: glowing-orb damage aura (charge 4s → orbit 5s → recharge) ──
			-- No standard attack: when an enemy is in range and the swarm has recharged,
			-- the tendrils glow and spit a swarm of orbs that orbit the creature. After
			-- a charge window the orbs deal weak, constant aura damage to every enemy in
			-- range each tick (multiple Broodmothers stack naturally). Movement, aggro and
			-- separation still run for it via the earlier sections.
			if data.unitType == "Broodmother" then
				local bt     = tick()
				local bPos   = data.part.Position
				local bStr   = tostring(data.owner.UserId)
				local auraR  = data.attackRange
				local st     = data.broodAuraState

				if st == nil then
					if not data.broodRechargeUntil or bt >= (data.broodRechargeUntil :: number) then
						local hasEnemy = false
						fillGridScratch(bPos, auraR)
						for gi = 1, gridScratchN do
							local other = units[gridScratch[gi]]
							if other and other.hp > 0 and tostring(other.owner.UserId) ~= bStr
								and (other.part.Position - bPos).Magnitude <= auraR then
								hasEnemy = true; break
							end
						end
						if hasEnemy then
							data.broodAuraState = "charging"
							data.broodAuraStart = bt
							data.broodDotAccum  = 0
							-- Tendrils glow + spit the orb swarm (client matches the nearest Broodmother).
							unitHitRemote:FireAllClients(bPos, bPos, "Broodmother")
						end
					end
				elseif st == "charging" then
					if bt - (data.broodAuraStart :: number) >= Config.BROODMOTHER_CHARGE_TIME then
						data.broodAuraState = "active"
						data.broodAuraStart = bt
						data.broodDotAccum  = 0
					end
				elseif st == "active" then
					data.broodDotAccum = (data.broodDotAccum or 0) + dt
					if (data.broodDotAccum :: number) >= Config.BROODMOTHER_AURA_TICK then
						data.broodDotAccum = (data.broodDotAccum :: number) - Config.BROODMOTHER_AURA_TICK
						fillGridScratch(bPos, auraR)
						for gi = 1, gridScratchN do
							local oid   = gridScratch[gi]
							local other = units[oid]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == bStr then continue end
							if (other.part.Position - bPos).Magnitude > auraR then continue end
							other.hp -= calcDamage(other, data.attackDmg)
							applyHP(other, true)
							if other.hp <= 0 then table.insert(toRemove, oid) end
						end
					end
					if bt - (data.broodAuraStart :: number) >= Config.BROODMOTHER_ACTIVE_TIME then
						data.broodAuraState     = nil
						data.broodRechargeUntil = bt + Config.BROODMOTHER_RECHARGE_TIME
					end
				end
				continue  -- Broodmother deals damage only through its aura
			end

			data.attackTimer += dt
			local effectiveRate = data.attackRate
			if data.unitType == "Survivor" and data.stimUntil and tick() < (data.stimUntil :: number) then
				effectiveRate = effectiveRate * Config.SOLDIER_STIM_RATE
			end
			-- Trapper uses a fast check interval so it reacts quickly when a harpoon slot opens
			if data.unitType == "Tank" and researchManagerRef
				and researchManagerRef.hasResearch(data.owner, "Trapper") then
				effectiveRate = math.min(effectiveRate, 0.5)
			end
			if data.attackTimer < effectiveRate then continue end
			data.attackTimer -= effectiveRate

			local myPos      = data.part.Position
			local myOwnerStr = tostring(data.owner.UserId)
			local hitPos:  Vector3? = nil
			local vfxType: string   = data.unitType

			local atkRange = data.attackRange

			-- ── Medic: heal most-damaged nearby friendly unit ──────────────────
			if data.unitType == "Medic" then
				local bestId2: string?  = nil
				local lowestRatio       = 1.0
				fillGridScratch(myPos, atkRange)
				for gi = 1, gridScratchN do
					local otherId = gridScratch[gi]
					if otherId == id then continue end
					local other = units[otherId]
					if not other or other.hp <= 0 then continue end
					if tostring(other.owner.UserId) ~= myOwnerStr then continue end
					local ratio = other.hp / other.maxHp
					if ratio >= 1.0 then continue end
					local d = (other.part.Position - myPos).Magnitude
					if d <= atkRange and ratio < lowestRatio then
						lowestRatio = ratio; bestId2 = otherId
					end
				end
				if bestId2 then
					local other    = units[bestId2]
					other.hp       = math.min(other.maxHp, other.hp + data.attackDmg)
					applyHP(other)
					local targetTop = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
					local myTop     = myPos + Vector3.new(0, data.part.Size.Y * 0.5, 0)
					-- Face the patient
					local flatDir = Vector3.new(targetTop.X - myPos.X, 0, targetTop.Z - myPos.Z)
					if flatDir.Magnitude > 0.1 then
						data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
					end
					healBeamRemote:FireAllClients(myTop, targetTop)
				end
				continue  -- Medics never attack buildings or miners
			end

			if data.unitType == "Tank" then
				-- Tanks: buildings first (+ AoE splash on nearby units), fall back to units.
				-- With RocketBarrage researched: fires 3 rockets (each 65% damage) instead of
				-- one shell, with random landing spread and individual splash per rocket.
				-- With Trapper researched (mutually exclusive with RocketBarrage): fires harpoons
				-- that slow enemies by 90% for 7 s without dealing damage.
				local hasConcussion = researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "ConcussionShells")
				local hasBarrage    = researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "RocketBarrage")
				local hasTrapper    = not hasBarrage and researchManagerRef
					and researchManagerRef.hasResearch(data.owner, "Trapper")

				if hasTrapper then
					-- ── Trapper: harpoon launcher ────────────────────────────────
					-- Initialize harpoon state the first time this tank fires as a trapper
					if not data.harpoonCount then
						data.harpoonCount     = Config.TRAPPER_HARPOON_MAX
						data.harpoonRestockAt = 0
						data.trapperHarpooned = {}
						local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
						if hv then hv.Value = Config.TRAPPER_HARPOON_MAX end
					end

					local t      = tick()
					local hrp    = data.trapperHarpooned :: {[string]: number}
					local hCount = data.harpoonCount :: number
					local restAt = data.harpoonRestockAt :: number

					-- Expire old harpoons and decrement the target's incoming-harpoon counter
					for tId, exp in hrp do
						if t >= exp then
							hrp[tId] = nil
							local tgt = units[tId]
							if tgt then
								local n = (tgt.incomingHarpoons or 1) - 1
								tgt.incomingHarpoons = if n > 0 then n else nil
							end
						end
					end

					-- Restock one harpoon if the timer has elapsed
					if hCount < Config.TRAPPER_HARPOON_MAX and t >= restAt then
						hCount += 1
						data.harpoonCount = hCount
						if hCount < Config.TRAPPER_HARPOON_MAX then
							data.harpoonRestockAt = t + Config.TRAPPER_RESTOCK_TIME
						end
						local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
						if hv then hv.Value = hCount end
					end

					-- Fire a harpoon at the nearest enemy unit not already harpooned
					if hCount > 0 then
						local bestId2: string? = nil
						local bestDist2 = math.huge
						fillGridScratch(myPos, atkRange)
						for gi = 1, gridScratchN do
							local otherId = gridScratch[gi]
							local other = units[otherId]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							if hrp[otherId] then continue end
							local d = (other.part.Position - myPos).Magnitude
							if d <= atkRange and d < bestDist2 then
								bestDist2 = d; bestId2 = otherId
							end
						end
						if bestId2 then
							local other = units[bestId2]
							hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							-- Increment stacking slow counter on target
							other.incomingHarpoons = (other.incomingHarpoons or 0) + 1
							hrp[bestId2] = t + Config.TRAPPER_SLOW_DURATION
							hCount -= 1
							data.harpoonCount = hCount
							-- Start restock countdown for the consumed harpoon
							if hCount < Config.TRAPPER_HARPOON_MAX and t >= restAt then
								data.harpoonRestockAt = t + Config.TRAPPER_RESTOCK_TIME
							end
							local hv = data.part:FindFirstChild("HarpoonCount") :: NumberValue?
							if hv then hv.Value = hCount end
							vfxType = "TankHarpoon"
						end
					end
				else
					-- ── Normal tank / Rocket Barrage ─────────────────────────────
					local slowEnd = tick() + Config.TANK_SLOW_DURATION

					-- Per-shot stats: barrage = 3 rockets × 65%; normal = 1 shell × 100%
					local shotCount = hasBarrage and Config.ROCKET_BARRAGE_COUNT    or 1
					local shotDmg   = hasBarrage
						and math.floor(data.attackDmg * Config.ROCKET_BARRAGE_DMG_MULT)
						or  data.attackDmg
					local spreadR   = hasBarrage and Config.ROCKET_BARRAGE_SPREAD or 0.0

					local function applySplash(centre: Vector3, skipId: string?)
						local splashR   = Config.TANK_SPLASH_RANGE
						local splashDmg = math.floor(shotDmg * Config.TANK_SPLASH_DAMAGE_MULT)
						for otherId, other in units do
							if other.hp <= 0 then continue end
							if skipId and otherId == skipId then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							if (other.part.Position - centre).Magnitude <= splashR then
								other.hp -= calcDamage(other, splashDmg)
								applyHP(other, true)
								if hasConcussion then other.slowUntil = slowEnd end
								if other.hp <= 0 then table.insert(toRemove, otherId) end
							end
						end
					end

					if buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
						end
						if bId and bPos then
							buildingManagerRef.damage(bId, shotDmg)
							hitPos = bPos
							for _ = 1, shotCount do
								local ox = (math.random() - 0.5) * 2 * spreadR
								local oz = (math.random() - 0.5) * 2 * spreadR
								applySplash(bPos + Vector3.new(ox, 0, oz), nil)
							end
						end
					end
					if not hitPos then
						local bestId2, bestDist2 = nil :: string?, math.huge
						for otherId, other in units do
							if other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							local d = (other.part.Position - myPos).Magnitude
							if d <= atkRange and d < bestDist2 then
								bestDist2 = d; bestId2 = otherId
							end
						end
						if bestId2 then
							local other = units[bestId2]
							hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
							other.hp -= calcDamage(other, shotDmg)
							applyHP(other, true)
							if hasConcussion and other.hp > 0 then other.slowUntil = slowEnd end
							if other.hp <= 0 then table.insert(toRemove, bestId2) end
							for _ = 1, shotCount do
								local ox = (math.random() - 0.5) * 2 * spreadR
								local oz = (math.random() - 0.5) * 2 * spreadR
								applySplash(hitPos + Vector3.new(ox, 0, oz), bestId2)
							end
						end
					end

					if hasBarrage and hitPos then vfxType = "TankBarrage" end
				end
			else
				if data.unitType == "Hagfish" then
					-- ── Hagfish: head-slap ground eruption ───────────────────────
					-- The hagfish slaps its head down and six teeth-like tentacles
					-- erupt from the earth around nearby foes. The six strikes are
					-- split as evenly as possible across whatever enemies are in
					-- range, doubling up on the same target(s) when fewer than six
					-- are present. All damage lands at once; the client renders the
					-- staggered 2.5 s strike → retreat → head-rear animation.
					local nT = Config.HAGFISH_TENTACLES

					-- Collect enemy units in range, nearest first.
					local targets: { string } = {}
					do
						local scratch: { {id: string, d: number} } = {}
						fillGridScratch(myPos, atkRange)
						for gi = 1, gridScratchN do
							local otherId = gridScratch[gi]
							local other = units[otherId]
							if not other or other.hp <= 0 then continue end
							if tostring(other.owner.UserId) == myOwnerStr then continue end
							local d = (other.part.Position - myPos).Magnitude
							if d <= atkRange then table.insert(scratch, { id = otherId, d = d }) end
						end
						table.sort(scratch, function(a, b) return a.d < b.d end)
						for _, t in scratch do table.insert(targets, t.id) end
					end

					local strikes: { Vector3 } = {}
					local function strikeAt(px: number, pz: number)
						local jx = (math.random() - 0.5) * 5
						local jz = (math.random() - 0.5) * 5
						strikes[#strikes + 1] = Vector3.new(px + jx, getGroundY(px + jx, pz + jz, 0), pz + jz)
					end

					if #targets > 0 then
						-- Round-robin the six strikes across the in-range enemies.
						for k = 1, nT do
							local tId   = targets[((k - 1) % #targets) + 1]
							local other = units[tId]
							if other and other.hp > 0 then
								other.hp -= calcDamage(other, data.attackDmg)
								applyHP(other, true)
								if other.hp <= 0 then table.insert(toRemove, tId) end
							end
							local tp = other and other.part.Position or myPos
							strikeAt(tp.X, tp.Z)
						end
					else
						-- No enemy units: erupt the whole cluster on a building, else a miner.
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId and buildingManagerRef then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
						end
						if bId and bPos and buildingManagerRef then
							for _ = 1, nT do
								buildingManagerRef.damage(bId, data.attackDmg)
								strikeAt((bPos :: Vector3).X, (bPos :: Vector3).Z)
							end
						end
					end

					-- If anything was struck: root the hagfish, face the cluster, and
					-- tell every client to erupt the tentacles. hitPos stays nil so the
					-- generic single-bolt VFX path below is skipped.
					if #strikes > 0 then
						data.attackLockUntil = tick() + Config.HAGFISH_ROOT_TIME
						local cx, cz = 0, 0
						for _, s in strikes do cx += s.X; cz += s.Z end
						cx /= #strikes; cz /= #strikes
						local flatDir = Vector3.new(cx - myPos.X, 0, cz - myPos.Z)
						if flatDir.Magnitude > 0.1 then
							data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
						end
						hagfishStrikeRemote:FireAllClients(myPos, strikes)
					else
						-- Nothing in range this cycle: stay loaded and re-check next
						-- frame rather than burning the full cooldown on an empty swing.
						data.attackTimer = effectiveRate
					end
				elseif isRoller then
					-- Roller: melee charge attack — find target, deal damage, start dash
					local bestId2, bestDist2 = nil :: string?, math.huge
					for otherId, other in units do
						if other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myOwnerStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= atkRange and d < bestDist2 then
							bestDist2 = d; bestId2 = otherId
						end
					end
					if bestId2 then
						local other = units[bestId2]
						hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
						other.hp -= calcDamage(other, data.attackDmg)
						applyHP(other, true)
						if other.hp <= 0 then table.insert(toRemove, bestId2) end
						if not data.rollerCharging and not data.rollerChargingOut then
							data.rollerCharging     = true
							local chargeDir = (other.part.Position - myPos)
							data.rollerChargeTarget = myPos + chargeDir.Unit * Config.ROLLER_CHARGE_DIST
							data.rollerChargeHome   = myPos
						end
					elseif buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
						end
						if bId and bPos then
							buildingManagerRef.damage(bId, data.attackDmg)
							hitPos = bPos
							if not data.rollerCharging and not data.rollerChargingOut then
								data.rollerCharging     = true
								local chargeDir = (bPos - myPos)
								data.rollerChargeTarget = myPos + chargeDir.Unit * Config.ROLLER_CHARGE_DIST
								data.rollerChargeHome   = myPos
							end
						end
					end
				elseif data.unitType == "Roller" then
					-- Roller: melee grind — nearest enemy unit first, else a building. Each
					-- carried MELEE rider adds its damage to the grind (see mount system).
					local dmg = data.attackDmg
					if data.carrying then
						for _, uid in data.carrying do
							local p = units[uid]
							if p and classifyPassenger(p.unitType) == "melee" then
								dmg += p.attackDmg * Config.ROLLER_MOUNT_MELEE_MULT
							end
						end
					end
					local bestId2, bestDist2 = nil :: string?, math.huge
					fillGridScratch(myPos, atkRange)
					for gi = 1, gridScratchN do
						local otherId = gridScratch[gi]
						local other = units[otherId]
						if not other or other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myOwnerStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= atkRange and d < bestDist2 then bestDist2 = d; bestId2 = otherId end
					end
					if bestId2 then
						local other = units[bestId2]
						hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
						other.hp -= calcDamage(other, dmg)
						applyHP(other, true)
						if other.hp <= 0 then table.insert(toRemove, bestId2) end
					elseif buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange)
						end
						if bId and bPos then
							buildingManagerRef.damage(bId, dmg)
							hitPos = bPos
						end
					end
				else
					-- Survivors / Elite / Sniper: nearest enemy unit first, fall back to
					-- buildings. The Sniper out-ranges its own sight, so it must never
					-- fire into unexplored fog — a target only counts if it's spotted by
					-- the owner's units/buildings (same rule as the Artillery turret).
					local spotter: ((Vector3) -> boolean)? = nil
					if data.unitType == "Sniper" and buildingManagerRef and buildingManagerRef.makeSpotterCheck then
						spotter = buildingManagerRef.makeSpotterCheck(myOwnerStr)
					end
					local bestId2, bestDist2 = nil :: string?, math.huge
					fillGridScratch(myPos, atkRange)
					for gi = 1, gridScratchN do
						local otherId = gridScratch[gi]
						local other = units[otherId]
						if not other or other.hp <= 0 then continue end
						if tostring(other.owner.UserId) == myOwnerStr then continue end
						local d = (other.part.Position - myPos).Magnitude
						if d <= atkRange and d < bestDist2 and (not spotter or spotter(other.part.Position)) then
							bestDist2 = d; bestId2 = otherId
						end
					end
					if bestId2 then
						local other = units[bestId2]
						hitPos = other.part.Position + Vector3.new(0, other.part.Size.Y * 0.5, 0)
						other.hp -= calcDamage(other, data.attackDmg)
						applyHP(other, true)
						if other.hp <= 0 then table.insert(toRemove, bestId2) end
					elseif buildingManagerRef then
						local bId: string?, bPos: Vector3?
						if data.focusBldId then
							local bf    = workspace:FindFirstChild("Buildings")
							local model = bf and bf:FindFirstChild(data.focusBldId)
							local base  = model and model:FindFirstChild("Base")
							if base and (base :: BasePart).Parent then
								local bp = base :: BasePart
								if (bp.Position - myPos).Magnitude <= atkRange and (not spotter or spotter(bp.Position)) then
									bId = data.focusBldId; bPos = bp.Position + Vector3.new(0, bp.Size.Y * 0.5, 0)
								end
							else
								data.focusBldId = nil
							end
						end
						if not bId then
							bId, bPos = buildingManagerRef.getNearestEnemyBuilding(myPos, myOwnerStr, atkRange, spotter)
						end
						if bId and bPos then
							buildingManagerRef.damage(bId, data.attackDmg)
							hitPos = bPos
						end
					end
				end
			end

			-- Face attack target, then fire VFX
			if hitPos then
				if not isRoller then
					local flatDir = Vector3.new(hitPos.X - myPos.X, 0, hitPos.Z - myPos.Z)
					if flatDir.Magnitude > 0.1 then
						data.part.CFrame = CFrame.lookAt(myPos, myPos + flatDir)
					end
				end
				unitHitRemote:FireAllClients(myPos, hitPos, vfxType)
				-- Howitzer: leave a fire zone at the impact site
				if data.unitType == "Howitzer" then
					fireZones[#fireZones + 1] = {
						pos      = Vector3.new(hitPos.X, 0, hitPos.Z),
						elapsed  = 0,
						dotAccum = 0,
					}
				end
			end
		end

		-- ── Foam DoT tick ──────────────────────────────────────────────────────
		do
			local now = tick()
			for dotId, dotData in units do
				if not dotData.foamedUntil then continue end
				if now >= (dotData.foamedUntil :: number) then
					dotData.foamedUntil  = nil
					dotData.foamDotAccum = nil
					continue
				end
				dotData.foamDotAccum = (dotData.foamDotAccum or 0) + dt
				if (dotData.foamDotAccum :: number) >= 1.0 then
					dotData.foamDotAccum = (dotData.foamDotAccum :: number) - 1.0
					dotData.hp -= Config.FOAMER_FOAM_DOT
					applyHP(dotData, true)
					if dotData.hp <= 0 then table.insert(toRemove, dotId) end
				end
			end
		end

		-- ── Howitzer fire zone DoT (damages ALL units, both teams) ─────────────
		do
			local FIRE_FULL  = Config.HOWITZER_FIRE_FULL_DURATION
			local FIRE_FADE  = Config.HOWITZER_FIRE_FADE_DURATION
			local FIRE_TOTAL = FIRE_FULL + FIRE_FADE
			local FIRE_R     = Config.HOWITZER_FIRE_RADIUS
			local FIRE_DPS   = Config.HOWITZER_FIRE_DMG_PER_SEC
			local fzi = #fireZones
			while fzi > 0 do
				local fz    = fireZones[fzi]
				fz.elapsed += dt
				if fz.elapsed >= FIRE_TOTAL then
					table.remove(fireZones, fzi)
				else
					local dps = FIRE_DPS
					if fz.elapsed > FIRE_FULL then
						dps = FIRE_DPS * (1 - (fz.elapsed - FIRE_FULL) / FIRE_FADE)
					end
					fz.dotAccum += dt
					if fz.dotAccum >= 1.0 then
						fz.dotAccum -= 1.0
						local dmgTick = math.max(1, math.floor(dps))
						fillGridScratch(fz.pos, FIRE_R)
						for gi = 1, gridScratchN do
							local uid   = gridScratch[gi]
							local udata = units[uid]
							if not udata or udata.hp <= 0 then continue end
							if (udata.part.Position - fz.pos).Magnitude > FIRE_R then continue end
							udata.hp -= dmgTick
							applyHP(udata, true)
							if udata.hp <= 0 then table.insert(toRemove, uid) end
						end
					end
				end
				fzi -= 1
			end
		end

		-- ── Separation pass ────────────────────────────────────────────────────
		for id, data in units do
			if data.dying then continue end   -- a collapsing Broodmother stays put
			if data.carriedBy then continue end   -- riding a Roller: positionCarried owns its seat
			if data.immobilized or data.draggingId then continue end  -- rescue pass owns these
			local myPos = data.part.Position
			local myStr = tostring(data.owner.UserId)
			local pushX, pushZ = 0, 0
			local count = 0

			local scx0 = math.floor((myPos.X - SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scx1 = math.floor((myPos.X + SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scz0 = math.floor((myPos.Z - SEP_DIST) / GRID_CELL) + GRID_OFFSET
			local scz1 = math.floor((myPos.Z + SEP_DIST) / GRID_CELL) + GRID_OFFSET
			for gx = scx0, scx1 do
				for gz = scz0, scz1 do
					local cell = spatialGrid[gx * GRID_STRIDE + gz]
					if not cell then continue end
					for _, otherId in cell do
						if otherId == id then continue end
						local other = units[otherId]
						if not other then continue end
						-- A rider that mounted this tick is still in the (start-of-tick) grid;
						-- don't let it shove its Roller off course from the seat it's sitting in.
						if other.carriedBy then continue end
						if tostring(other.owner.UserId) ~= myStr then continue end
						local dx   = myPos.X - other.part.Position.X
						local dz   = myPos.Z - other.part.Position.Z
						local dist = math.sqrt(dx * dx + dz * dz)
						if dist < SEP_DIST and dist > 0.01 then
							local strength = (SEP_DIST - dist) / SEP_DIST
							pushX += (dx / dist) * strength
							pushZ += (dz / dist) * strength
							count += 1
						end
					end
				end
			end

			-- Deployed Foamers are frozen in place; separation would fight the sink animation
			if count > 0 and not (data.foamState and data.foamState ~= "mobile") then
				local mag = math.sqrt(pushX * pushX + pushZ * pushZ)
				if mag > 0.01 then
					local nx = myPos.X + (pushX / mag) * SEP_PUSH
					local nz = myPos.Z + (pushZ / mag) * SEP_PUSH
					data.part.CFrame = CFrame.new(nx, getGroundY(nx, nz, data.part.Size.Y / 2), nz) * data.part.CFrame.Rotation
				end
			end
		end

		-- Wounded soldiers: collapse pose, drag-home movement and base healing. Runs
		-- before the decorator sync so the prone/carry CFrames propagate this frame.
		processRescues(dt)

		-- Update anchored decorator parts (treads, pill body, eyes, etc.) to match body CFrame.
		-- This replaces the old WeldConstraint physics pass for all decorated units.
		-- Perf: units that haven't moved since the last sync are skipped entirely
		-- (decorLastCF dirty check), and all moved units' decorators are written in a
		-- single BulkMoveTo — far cheaper than thousands of individual .CFrame sets,
		-- both server-side and in replication.
		local bulkParts: { BasePart } = decorBulkParts
		local bulkCFs:   { CFrame }   = decorBulkCFs
		table.clear(bulkParts)
		table.clear(bulkCFs)
		for id, data in units do
			local decs = unitDecorators[id]
			if not decs then continue end
			local bodyCF = data.part.CFrame
			if data.decorLastCF == bodyCF then continue end
			data.decorLastCF = bodyCF
			for _, d in decs do
				bulkParts[#bulkParts + 1] = d.part
				bulkCFs[#bulkCFs + 1]    = bodyCF * d.localCF
			end
		end
		if #bulkParts > 0 then
			workspace:BulkMoveTo(bulkParts, bulkCFs, Enum.BulkMoveMode.FireCFrameChanged)
		end

		-- Remove dead units
		for _, id in toRemove do
			local d = units[id]
			if d then
				if d.trapperHarpooned then
					for tId, _ in d.trapperHarpooned do
						local tgt = units[tId]
						if tgt then
							local n = (tgt.incomingHarpoons or 1) - 1
							tgt.incomingHarpoons = if n > 0 then n else nil
						end
					end
				end
				-- Broodmother: enter the collapse/birth sequence instead of vanishing
				-- (idempotent — duplicate toRemove entries while dying are ignored).
				if d.unitType == "Broodmother" then
					beginBroodmotherDeath(id, d)
					continue
				end
				if (d.unitType == "Tank" or d.unitType == "Survivor")
					and d.owner.UserId > 0 and d.owner.Parent then
					unitDiedRemote:FireClient(d.owner, d.unitType, d.part.Position)
				end
				if d.unitType == "Roller" and d.carrying and #d.carrying > 0 then
						dismountAll(d, d.part.Position)   -- riders spill off on death (kept alive)
					end
					spawnDeathFX(d.unitType, d.part, goreLevel(d), d.maxHp)
				releaseDragLinks(id)
				unitDecorators[id] = nil
				playerUnitCount[d.owner.UserId] = math.max(0, (playerUnitCount[d.owner.UserId] or 1) - 1)
				d.part:Destroy()
				units[id] = nil
				local dep = unitToDeployer[id]
				if dep then
					unitToDeployer[id] = nil
					if deployerUnits[dep] then deployerUnits[dep][id] = nil end
				end
			end
		end
	end)

	-- Train remote
	RemoteHandler.get(Config.REMOTES.TrainUnit).OnServerEvent:Connect(function(player, barrackIds, unitType)
		if type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end
		-- Lampreys, Hagfish and Broodmothers are born at the Lamprey Nest, never trained at a Barracks.
		if unitType == "Lamprey" or unitType == "Hagfish" or unitType == "Broodmother" then return end

		-- Research gate: if this unit type requires a tech, verify the player has it
		if typeDef.researchReq then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, typeDef.researchReq) then
				return
			end
		end

		local ids = type(barrackIds) == "string" and {barrackIds} or barrackIds
		if type(ids) ~= "table" then return end

		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end

		for _, barrackId in ids do
			if type(barrackId) ~= "string" then continue end
			local building = buildingsFolder:FindFirstChild(barrackId)
			if not building then continue end

			local ownerVal = building:FindFirstChild("OwnerId")
			if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then continue end

			local base = building:FindFirstChild("Base") :: BasePart
			if not base then continue end

			local q = barrackQueues[barrackId] or {}
			if #q >= MAX_QUEUE then continue end

			if not resourceManagerRef.spend(player, typeDef.cost) then continue end

			local spawnPos  = base.Position + Vector3.new(Config.BUILDING_SIZE.X + typeDef.size.X, 0, 0)
			local trainTime = (Config.UNIT_TRAIN_TIME :: any)[unitType] or 0

			if trainTime <= 0 then
				spawnUnit(player, spawnPos, unitType)
				continue
			end

			barrackQueues[barrackId] = q
			table.insert(q, { unitType = unitType, trainTime = trainTime, player = player, spawnPos = spawnPos })

			if not barrackIsTraining[barrackId] then
				startNextInQueue(barrackId)
			else
				fireTrainingUpdate(barrackId, player)
			end
		end
	end)

	-- ── Mother (Hollowed CC) trains a unit beside itself ──────────────────────────
	-- Instant-spawn model: click a Mother option → spend its cost → the unit appears on
	-- a jittered ring just outside the Mother's footprint.
	RemoteHandler.get(Config.REMOTES.TrainFromMother).OnServerEvent:Connect(function(player, ccId, unitType)
		if type(ccId) ~= "string" or type(unitType) ~= "string" then return end
		-- Embryos are no longer trained by hand — they auto-hatch from the Egg Sacs
		-- upgrade's nests (see BuildingManager). Only the Leech is trained here now.
		if unitType ~= "Leech" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef then return end

		local buildingsFolder = workspace:FindFirstChild("Buildings")
		if not buildingsFolder then return end
		local building = buildingsFolder:FindFirstChild(ccId)
		if not building then return end
		local btv = building:FindFirstChild("BuildingType") :: StringValue?
		if not btv or btv.Value ~= "CommandCenter" then return end
		local ownerVal = building:FindFirstChild("OwnerId")
		if not ownerVal or ownerVal.Value ~= tostring(player.UserId) then return end
		local base = building:FindFirstChild("Base") :: BasePart?
		if not base then return end

		if not resourceManagerRef or not resourceManagerRef.spend(player, typeDef.cost) then return end

		-- The Mother spits an egg into the area in front of it that incubates under a
		-- progress bar, then hatches into the unit (inspired by the Lamprey Nest). The
		-- cost was just spent above, so produceMotherEgg never charges again.
		if buildingManagerRef and buildingManagerRef.produceMotherEgg then
			task.spawn(buildingManagerRef.produceMotherEgg, player, ccId, unitType)
		else
			-- Fallback: instant spawn on a jittered ring if the egg path is unavailable.
			local ang      = math.random() * math.pi * 2
			local reach    = Config.COMMAND_CENTER_SIZE.X / 2 + 4 + typeDef.size.X
			local spawnPos = base.Position + Vector3.new(math.cos(ang) * reach, 0, math.sin(ang) * reach)
			spawnUnit(player, spawnPos, unitType)
		end
	end)

	-- ── Leech burrow / unburrow toggle ────────────────────────────────────────────
	-- Burrowing puts the Leech into a structure state (rooted, passive income); the
	-- heartbeat skip above handles income + freezing. Here we flip the flag, sink/raise
	-- the body, and tag a Burrowed BoolValue the client LeechPanel reads.
	RemoteHandler.get(Config.REMOTES.ToggleBurrow).OnServerEvent:Connect(function(player, unitId)
		if type(unitId) ~= "string" then return end
		local data = units[unitId]
		if not data or data.owner ~= player then return end
		if data.unitType ~= "Leech" or data.hp <= 0 or data.dying then return end

		setLeechBurrowed(data, not data.burrowed)
	end)

	-- ── Embryo evolve → Lamprey / Hagfish / Roller / Needler (available to every Embryo) ──
	RemoteHandler.get(Config.REMOTES.EvolveEmbryo).OnServerEvent:Connect(function(player, embryoId, targetType)
		if type(embryoId) ~= "string" or type(targetType) ~= "string" then return end
		local data = units[embryoId]
		if not data or data.owner ~= player or data.unitType ~= "Embryo" then return end
		if data.hp <= 0 or data.dying then return end
		if targetType ~= "Lamprey" and targetType ~= "Hagfish" and targetType ~= "Roller" and targetType ~= "Needler" then return end
		local pos = despawnUnit(embryoId)
		if not pos then return end
		spawnUnit(player, pos, targetType)
	end)

	-- ── Leech evolve → Watcher (ranged cluster of eyes) or Mother (Command Center) ──
	-- Charges the appropriate cost, then despawns the Leech and spawns the chosen
	-- unit/structure in its place. Works whether the Leech is mobile or burrowed.
	RemoteHandler.get(Config.REMOTES.EvolveLeech).OnServerEvent:Connect(function(player, leechId, targetType)
		if type(leechId) ~= "string" then return end
		if targetType == nil then targetType = "Watcher" end -- back-compat with older clients
		if targetType ~= "Watcher" and targetType ~= "Mother" then return end
		local data = units[leechId]
		if not data or data.owner ~= player or data.unitType ~= "Leech" then return end
		if data.hp <= 0 or data.dying then return end
		if targetType == "Mother" and not buildingManagerRef then return end

		local cost = (targetType == "Mother") and Config.LEECH_MOTHER_COST or Config.LEECH_EVOLVE_COST
		if not resourceManagerRef or not resourceManagerRef.spend(player, cost) then return end
		local pos = despawnUnit(leechId)
		if not pos then
			-- Refund if the Leech vanished between the checks and the despawn.
			resourceManagerRef.add(player, cost)
			return
		end
		if targetType == "Mother" then
			buildingManagerRef.morphStructureForPlayer(player, pos, "CommandCenter")
		else
			spawnUnit(player, pos, "Watcher")
		end
	end)

	-- ── Roller mount system ────────────────────────────────────────────────────────
	-- How many more riders a Roller can still accept (passengers already aboard +
	-- riders already walking in count against the cap).
	local function rollerSlotsLeft(rollerId: string, roller: UnitData): number
		local used = roller.carrying and #roller.carrying or 0
		for _, other in units do
			if other.mountTargetId == rollerId then used += 1 end
		end
		return Config.ROLLER_MOUNT_CAPACITY - used
	end

	-- Right-click / drag specific units into a Roller: give them a mount intent so
	-- they walk over and climb in (up to the remaining capacity).
	RemoteHandler.get(Config.REMOTES.RollerMount).OnServerEvent:Connect(function(player, rollerId, unitIds)
		if type(rollerId) ~= "string" or type(unitIds) ~= "table" then return end
		local roller = units[rollerId]
		if not roller or roller.owner ~= player or roller.unitType ~= "Roller" or roller.hp <= 0 or roller.dying then return end
		local slots = rollerSlotsLeft(rollerId, roller)
		for _, uid in unitIds do
			if slots <= 0 then break end
			if type(uid) ~= "string" then continue end
			local rider = units[uid]
			if rider and rider.owner == player and rider.hp > 0 and not rider.dying and not rider.carriedBy
				and isMountableType(rider.unitType) and rider.mountTargetId ~= rollerId then
				rider.mountTargetId = rollerId
				slots -= 1
			end
		end
	end)

	-- "Mount nearby" (Roller command-card button): auto-board owned units already within
	-- ROLLER_MOUNT_RANGE, nearest first, up to the remaining capacity.
	RemoteHandler.get(Config.REMOTES.RollerMountNearby).OnServerEvent:Connect(function(player, rollerId)
		if type(rollerId) ~= "string" then return end
		local roller = units[rollerId]
		if not roller or roller.owner ~= player or roller.unitType ~= "Roller" or roller.hp <= 0 or roller.dying then return end
		local slots = rollerSlotsLeft(rollerId, roller)
		if slots <= 0 then return end
		local rPos = roller.part.Position
		local near: { { id: string, d: number } } = {}
		for uid, rider in units do
			if uid == rollerId or rider.owner ~= player or rider.hp <= 0 or rider.dying or rider.carriedBy then continue end
			if not isMountableType(rider.unitType) or rider.mountTargetId == rollerId then continue end
			local d = (rider.part.Position - rPos).Magnitude
			if d <= Config.ROLLER_MOUNT_RANGE then table.insert(near, { id = uid, d = d }) end
		end
		table.sort(near, function(a, b) return a.d < b.d end)
		for i = 1, math.min(slots, #near) do
			local rider = units[near[i].id]
			if rider then rider.mountTargetId = rollerId end
		end
	end)

	-- Dismount: spill all riders back out around the Roller.
	RemoteHandler.get(Config.REMOTES.RollerDismount).OnServerEvent:Connect(function(player, rollerId)
		if type(rollerId) ~= "string" then return end
		local roller = units[rollerId]
		if not roller or roller.owner ~= player or roller.unitType ~= "Roller" then return end
		if roller.carrying and #roller.carrying > 0 then
			dismountAll(roller, roller.part.Position)
		end
	end)

	RemoteHandler.get(Config.REMOTES.MoveUnits).OnServerEvent:Connect(function(player, ids, targetPos)
		if type(ids) ~= "table" or typeof(targetPos) ~= "Vector3" then return end
		moveUnits(player, ids, targetPos)
	end)

	RemoteHandler.get(Config.REMOTES.FormationMove).OnServerEvent:Connect(function(player, ids, positions, attackMove)
		if type(ids) ~= "table" or type(positions) ~= "table" then return end
		formationMove(player, ids, positions, attackMove == true)
	end)

	RemoteHandler.get(Config.REMOTES.AttackMoveUnits).OnServerEvent:Connect(function(player, ids, targetPos)
		if type(ids) ~= "table" or typeof(targetPos) ~= "Vector3" then return end
		attackMoveUnits(player, ids, targetPos)
	end)

	RemoteHandler.get(Config.REMOTES.FocusAttack).OnServerEvent:Connect(function(player, ids, targetId, targetType)
		if type(ids) ~= "table" or type(targetId) ~= "string" or type(targetType) ~= "string" then return end
		for _, id in ids do
			local data = units[id]
			if not data or data.owner ~= player then continue end
			if data.immobilized or data.draggingId then continue end  -- downed/hauling: can't take orders
			data.atkMoveDest = nil
			data.target      = nil
			if targetType == "unit" then
				if units[targetId] then
					data.aggroId    = targetId
					data.aggroHome  = nil   -- no leash on manual focus attacks
					data.focusBldId = nil
				end
			elseif targetType == "building" then
				data.focusBldId = targetId
				data.aggroId    = nil
				data.aggroHome  = nil
			end
		end
	end)

	RemoteHandler.get(Config.REMOTES.UpgradeUnit).OnServerEvent:Connect(function(player, ids, toType)
		if type(ids) ~= "table" or type(toType) ~= "string" then return end
		for _, id in ids do
			if type(id) == "string" then UnitManager.upgradeUnit(player, id, toType) end
		end
	end)

	RemoteHandler.get(Config.REMOTES.SpawnLaneUnit).OnServerEvent:Connect(function(player, unitType)
		if not laneModeActive then return end
		if type(unitType) ~= "string" then return end
		local typeDef = Config.UNIT_TYPES[unitType]
		if not typeDef or unitType == "CreepySoldier" then return end
		if not resourceManagerRef.spend(player, typeDef.cost) then return end
		local ccPos = buildingManagerRef and buildingManagerRef.getCCPosition(player)
		if not ccPos then
			resourceManagerRef.add(player, typeDef.cost)
			return
		end
		local id = spawnUnit(player, Vector3.new(ccPos.X, 0, ccPos.Z), unitType)
		if id then
			local data = units[id]
			if data then
				-- Auto-march toward enemy end of the lane
				local marchTarget = Vector3.new(ccPos.X, 0, -ccPos.Z * 1.2)
				data.target    = marchTarget
				data.home      = marchTarget
				data.atkMoveDest = marchTarget
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		AlertManager.clearPlayer(player.UserId)
		local toRemove = {}
		for id, data in units do
			if data.owner == player then table.insert(toRemove, id) end
		end
		for _, id in toRemove do
			units[id].part:Destroy()
			units[id] = nil
			local dep = unitToDeployer[id]
			if dep then
				unitToDeployer[id] = nil
				if deployerUnits[dep] then deployerUnits[dep][id] = nil end
			end
		end
		local qToClean = {}
		for barrackId, q in barrackQueues do
			if #q > 0 and q[1].player == player then
				table.insert(qToClean, barrackId)
			end
		end
		for _, bid in qToClean do
			barrackQueues[bid]     = nil
			barrackIsTraining[bid] = nil
			barrackTrainStart[bid] = nil
		end
	end)
end

function UnitManager.setLaneMode(enabled: boolean)
	laneModeActive = enabled
end

return UnitManager
