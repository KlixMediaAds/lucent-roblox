local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))
local AlertManager      = require(script.Parent:WaitForChild("AlertManager"))

local rng = Random.new()

local BuildingManager    = {}
local buildingsFolder: Folder
local counter            = 0
local mineralManager: any
local resourceManagerRef: any
local unitManagerRef: any
local researchManagerRef: any
local forestManagerRef: any
local terrainManagerRef: any
local onCCDestroyedCb: ((any) -> ())?

type BuildingData = { hp: number, maxHp: number, base: BasePart, owner: any, buildingType: string, head: BasePart?, barrel: BasePart?, barrels: { BasePart }?, isConstructing: boolean, turretUpgrade: string?, hpBarHideAt: number?, rallyUpgrade: boolean?, rallyPoint: Vector3? }
local buildingData: { [string]: BuildingData } = {}
-- In-flight placements: buildings paid for via PlaceBuilding but not yet landed/
-- added to buildingData (drop-pod is still flying / constructing). Counted in
-- costFor so the exponential price rises at PURCHASE time, not on completion —
-- otherwise a player can spam several at the base price before any finish.
-- Keyed by player UserId → buildingType → count.
local pendingBuildings: { [number]: { [string]: number } } = {}
local playerHasCC:  { [number]: boolean }      = {}
local turretTimers:      { [string]: number } = {}   -- attackTimer per turret id
local deployerTimers:    { [string]: number } = {}   -- auto-spawn cooldown per deployer id
local deployerUnitType:  { [string]: string } = {}   -- deployerId → unit type to spawn
local deployerUpdateAcc: { [string]: number } = {}   -- accumulator for periodic client updates
local deployerLevel:     { [string]: number } = {}   -- bonfire Empower upgrades bought per id
-- TEST building shares the deployer summon maps above (timers/unitType/updateAcc) but
-- tracks its two upgrades SEPARATELY: supply (capacity) and rate (summon interval).
local testSupplyLevel:   { [string]: number } = {}   -- TEST id → Supply upgrades bought
local testRateLevel:     { [string]: number } = {}   -- TEST id → Spawn Rate upgrades bought

-- Engineering Post research state per building id.
local engState:     { [string]: string } = {}   -- "idle" | "researching" | "ready"
local engResearchEnd: { [string]: number } = {}  -- os.clock() when the active research finishes
local engUpdateAcc:  { [string]: number } = {}   -- accumulator for periodic client progress pushes

local onPlayerWonCb: ((number) -> ())?

local monumentByOwner:       { [number]: string } = {}  -- userId → buildingId
local monumentWinTimer:      { [string]: number } = {}  -- buildingId → active seconds elapsed
local monumentHeartbeatAccum = 0
local ccIncomeAccum          = 0   -- accumulator for Command Center passive income
local foundryIncomeAccum     = 0   -- accumulator for Foundry passive income

local ccAttackThrottle: { [number]: number } = {}   -- userId → last-fire timestamp
local CC_ATTACK_THROTTLE = 5  -- seconds between CC attack notifications
local blobCooldowns:    { [string]: number } = {}   -- blobId → os.clock() expiry for soldier spawn
local nestEggs:         { [string]: number } = {}   -- LampreyNest id → count of in-flight + incubating eggs
local nestEggCounter    = 0                          -- monotonic id for naming egg parts
local nestLauncherBusy: { [string]: boolean } = {}  -- LampreyNest id → a launcher throw is mid-animation

-- Hollowed Mother "Egg Sacs" upgrade state, per Command Center (Mother) id.
local eggSacLevel:      { [string]: number } = {}   -- Mother id → Egg Sacs purchases (0–MAX)
local eggSacNests:      { [string]: { Vector3 } } = {}  -- Mother id → world positions of its planted nests
local eggSacTimer:      { [string]: number } = {}   -- Mother id → autospawn interval accumulator
local eggSacInFlight:   { [string]: number } = {}   -- Mother id → Embryo eggs currently incubating
local skipNextConstruction = false  -- set true to bypass build-time for the next placeForPlayer call
local laneModeActive       = false  -- blocks non-CC placement from the PlaceBuilding remote

-- ── Drop pod delivery / on-site construction ──────────────────────────────
-- Pods launch instantly when a building is placed — no queue, no cooldown. When a
-- pod lands, its welding arms assemble the structure on-site through staged passes
-- (foundation → support beams → roof outline) before the finished building rises
-- from the ground and the scaffold sinks away.
local DROP_POD_FLIGHT_TIME      = 2.5   -- seconds from CC launch to ground impact
-- The on-site assembly fills the structure's Config.BUILD_TIME; these fractions
-- weight how that time splits across the foundation → beams → roof stages (they
-- sum to 1). The final building-rise is a fixed tail on top.
local CONSTRUCT_FOUNDATION_FRAC = 0.30  -- foundation slab welds in
local CONSTRUCT_BEAMS_FRAC      = 0.42  -- support beams + scaffold posts rise
local CONSTRUCT_ROOF_FRAC       = 0.28  -- roof-outline frame welded across the top
local CONSTRUCT_RISE_TIME       = 1.30  -- finished building rises as the scaffold sinks

local nextBuildRiseTime: number? = nil  -- overrides BUILD_TIME for the next createBuilding call

-- ── Mobile CC state ───────────────────────────────────────────────────────────
local ccMobileUnlocked: { [number]: boolean } = {}  -- userId → has paid 200 to unlock mobility
local ccMobile:         { [string]: boolean } = {}  -- ccId   → currently walking
local ccMoveTargets:    { [string]: Vector3 } = {}  -- ccId   → current move target
local playerCCId:       { [number]: string  } = {}  -- userId → their CC building id

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildingSize(buildingType: string): Vector3
	if buildingType == "CommandCenter" then return Config.COMMAND_CENTER_SIZE end
	if buildingType == "Monument"      then return Config.MONUMENT_SIZE end
	if buildingType == "Relay"         then return Config.RELAY_SIZE end
	if buildingType == "CreepyWorm"    then return Vector3.new(8, 5, 8) end
	if buildingType == "CreepyBlob"   then return Vector3.new(9, 6, 9) end
	if buildingType == "LampreyNest"   then return Config.LAMPREY_NEST_SIZE end
	if buildingType == "Foundry"       then return Config.FOUNDRY_SIZE end
	if buildingType == "Deployer"      then return Config.BONFIRE_SIZE end
	if buildingType == "TEST"          then return Config.TEST_SIZE end
	if buildingType == "EngineeringPost" then return Config.ENGINEERING_POST_SIZE end
	return Config.BUILDING_SIZE
end

-- Forward-declared so functions defined before their bodies can call them.
local spawnDestructionVFX: (Vector3) -> ()
local spawnWormBurstVFX:   (Vector3) -> ()
local spawnEggHatchVFX:    (Vector3) -> ()
local produceLampreyEgg:   (string, any, string) -> ()

local function snapGrid(v: Vector3): Vector3
	local g = Config.BUILDING_GRID
	return Vector3.new(math.round(v.X / g) * g, 0, math.round(v.Z / g) * g)
end

-- Returns how many buildings of a given type the player currently owns.
local function getPlayerBuildingCount(player: any, buildingType: string): number
	local n = 0
	for _, data in buildingData do
		if data.owner == player and data.buildingType == buildingType then n += 1 end
	end
	return n
end

-- Base (unscaled) resource cost for a placeable building type.
local function baseCostFor(buildingType: string): number
	return buildingType == "Turret"          and Config.TURRET_COST
		or buildingType == "Deployer"        and Config.DEPLOYER_COST
		or buildingType == "Relay"           and Config.RELAY_COST
		or buildingType == "CreepyBlob"      and Config.CREEPY_BLOB_COST
		or buildingType == "LampreyNest"     and Config.LAMPREY_NEST_COST
		or buildingType == "Foundry"         and Config.FOUNDRY_COST
		or buildingType == "EngineeringPost" and Config.ENGINEERING_POST_COST
		or buildingType == "TEST"            and Config.TEST_COST
		or Config.BUILDING_COST
end

-- Count of this player's in-flight (paid, not-yet-landed) placements of a type.
local function pendingCountFor(player: any, buildingType: string): number
	local t = pendingBuildings[player.UserId]
	return (t and t[buildingType]) or 0
end

local function addPending(player: any, buildingType: string, delta: number)
	local uid = player.UserId
	local t   = pendingBuildings[uid]
	if not t then t = {}; pendingBuildings[uid] = t end
	t[buildingType] = math.max(0, (t[buildingType] or 0) + delta)
end

-- Cost for `player` to place the next `buildingType`, applying exponential scaling
-- from their current count — INCLUDING in-flight placements — so the price climbs
-- the moment a building is purchased, not when it finishes building.
local function costFor(player: any, buildingType: string): number
	local count = getPlayerBuildingCount(player, buildingType) + pendingCountFor(player, buildingType)
	return Config.scaledBuildingCost(baseCostFor(buildingType), buildingType, count)
end

-- Returns true if the proposed footprint overlaps any existing building (AABB check).
-- pos is the snapped Y=0 centre; buildingType determines footprint size.
local function isOccupied(pos: Vector3, newType: string): boolean
	local ns = buildingSize(newType)
	for _, data in buildingData do
		local es  = buildingSize(data.buildingType)
		local halfX = (ns.X + es.X) / 2
		local halfZ = (ns.Z + es.Z) / 2
		-- base.Position X/Z always equals the original snapped centre
		local dx = math.abs(data.base.Position.X - pos.X)
		local dz = math.abs(data.base.Position.Z - pos.Z)
		if dx < halfX and dz < halfZ then
			return true
		end
	end
	return false
end

-- Returns true if the proposed footprint overlaps any terrain obstacle.
local function isTerrainBlocked(pos: Vector3, buildType: string): boolean
	local folder = workspace:FindFirstChild("TerrainObstacles")
	if not folder then return false end
	local ns  = buildingSize(buildType)
	local nhw = ns.X / 2
	local nhd = ns.Z / 2
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then continue end
		if math.abs(pos.X - part.Position.X) < nhw + part.Size.X / 2
			and math.abs(pos.Z - part.Position.Z) < nhd + part.Size.Z / 2 then
			return true
		end
	end
	return false
end

local function isOutOfMapBounds(pos: Vector3, buildType: string): boolean
	local ns = buildingSize(buildType)
	return math.abs(pos.X) + ns.X / 2 > 432 or math.abs(pos.Z) + ns.Z / 2 > 432
end

-- ── Health bar ────────────────────────────────────────────────────────────────

-- Bar length scales with max HP (tougher structures get longer bars), within bounds.
local function hpBarWidth(maxHp: number): number
	return math.clamp(math.floor(50 + maxHp * 0.06 + 0.5), 56, 150)
end

local function addHealthBar(part: BasePart, maxHp: number)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.new(0, hpBarWidth(maxHp), 0, 5)
	bb.StudsOffset      = Vector3.new(0, part.Size.Y / 2 + 2.5, 0)
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
	fill.Size           = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 50)
	fill.BorderSizePixel  = 0
	fill.Parent         = bg
	local fillCorner    = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent   = fill
end

local HP_BAR_SHOW_SECS = 3

local function applyHP(data: BuildingData, tookDamage: boolean?)
	local bb = data.base:FindFirstChild("HealthBar") :: BillboardGui?
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

-- ── Faction ───────────────────────────────────────────────────────────────────
-- A player is "Hollowed" (the nest/blob creature faction: spike CC, black grass,
-- can only place Blobs + Nests) if they chose that team in the lobby, or if they're
-- a Swarm-mode AI bot (plain Lua table carrying isSwarm). Everyone else is Humans.
local function isHollowed(player: any): boolean
	if type(player) == "table" then return player.isSwarm == true end
	return player:GetAttribute("Faction") == "Hollowed"
end
BuildingManager.isHollowed = isHollowed

-- Buildings the Hollowed faction places (and which Humans therefore cannot).
local HOLLOWED_BUILDINGS: { [string]: boolean } = { CreepyBlob = true, LampreyNest = true }
BuildingManager.HOLLOWED_BUILDINGS = HOLLOWED_BUILDINGS

-- ── Building creation ─────────────────────────────────────────────────────────

local function createBuilding(player: any, position: Vector3, buildingType: string, groundY: number?): string
	-- Height resolution. If the caller knows the exact ground height the build
	-- should sit on (e.g. the drop-pod path passes the very height the pod landed
	-- and the on-site construction used), trust it so the finished building lines
	-- up with them. Otherwise fall back to the terrain lookup.
	local passedY = position.Y
	local baseBottomY = groundY
	if baseBottomY == nil and terrainManagerRef then
		baseBottomY = terrainManagerRef.surfaceHeightAt(position.X, position.Z)
	end
	if baseBottomY ~= nil then
		position = Vector3.new(position.X, baseBottomY, position.Z)
	end
	print(string.format("[LUCENT-H][createBuilding] %s xz=(%.1f,%.1f) passedY=%.2f groundYParam=%s -> baseBottomY=%.2f  heightAt=%s",
		buildingType, position.X, position.Z, passedY,
		groundY and string.format("%.2f", groundY) or "nil",
		position.Y,
		terrainManagerRef and string.format("%.2f", terrainManagerRef.heightAt(position.X, position.Z)) or "nil"))

	counter += 1
	local id   = "b" .. counter
	local size = buildingSize(buildingType)

	local model     = Instance.new("Model")
	model.Name      = id

	local base      = Instance.new("Part")
	base.Name       = "Base"
	base.Size       = size
	base.Position   = position + Vector3.new(0, size.Y / 2, 0)
	base.BrickColor = player.TeamColor
	base.Material   = Enum.Material.SmoothPlastic
	base.Anchored   = true
	base.Parent     = model

	if buildingType == "CommandCenter" then
		model.PrimaryPart = base   -- needed for PivotTo during mobile movement
		playerCCId[player.UserId] = id

		-- The Hollowed faction (Swarm AIs + players who picked Hollowed) get the
		-- stark spike CC; Humans get the Fabricator Core.
		local isSwarmCC = isHollowed(player)
		if isSwarmCC then
			-- Hollowed Mother: a living brood-queen creature (Diplocaulus head, queen-ant
			-- egg-laying gaster, anemone tentacle crown). The team-coloured base stays as
			-- the invisible collision/HP part; all geometry comes from the shared builder
			-- so ghosts/previews stay in sync.
			base.Transparency = 1

			-- Tag for the client-side SwarmGrass renderer (black grass field). Grass
			-- is drawn locally on each client (zero replication) as one merged mesh.
			model:SetAttribute("SwarmCC", true)

			-- Flip the creature 180° so its head faces +Z — i.e. toward the default
			-- camera (which sits at +Z looking toward -Z) — instead of away from it.
			-- The MotherCrown client animator applies the same flip so the crown tracks.
			UnitVisuals.buildMotherDecor(model, CFrame.new(position) * CFrame.Angles(0, math.pi, 0), player.TeamColor, true)

			-- The Mother's head / body / tentacles are all CanQuery=false decor and
			-- sprawl well beyond and above the invisible 14×14 Base, so clicks on the
			-- creature itself miss. Drop in a roomy invisible, query-able hitbox over the
			-- whole creature — hitBuilding matches any descendant of the model, so this
			-- alone makes the Mother easy to select. It's a model child, so it rides along
			-- with uproot/downroot PivotTo moves and the construction sink animation.
			local mhb        = Instance.new("Part")
			mhb.Name         = "ClickHitbox"
			mhb.Size         = Vector3.new(18, 16, 24)
			mhb.CFrame       = CFrame.new(position + Vector3.new(0, 8, 0))
			mhb.Transparency = 1
			mhb.Anchored     = true
			mhb.CanCollide   = false
			mhb.CanQuery     = true
			mhb.CastShadow   = false
			mhb.Parent       = model
		else
			-- Industrial Fabricator Core. The team-coloured base block stays as the
			-- collision/HP part, visible between the platform rings; all decoration
			-- (reactor pit, rings, pipes, fabrication arms) comes from the shared
			-- builder so the thumbnail preview stays in sync. The avatar sits on the
			-- operator pulpit at the platform edge (see init.server seatAvatarOnCC).
			base.Material = Enum.Material.Metal
			UnitVisuals.buildCommandCenterDecor(model, CFrame.new(position), player.TeamColor, true)
		end

	elseif buildingType == "Turret" then
		-- Military tripod-mounted machine gun
		local grey = BrickColor.new("Dark stone grey")

		-- Helper: create a dark-metal part parented to model
		local function mp(nm: string, sz: Vector3, pos: Vector3): Part
			local p         = Instance.new("Part")
			p.Name          = nm
			p.Size          = sz
			p.Position      = pos
			p.BrickColor    = grey
			p.Material      = Enum.Material.Metal
			p.Anchored      = true
			p.CanCollide    = false
			p.CastShadow    = false
			p.Parent        = model
			return p
		end

		-- Repurpose base as the central mounting hub/platform
		base.BrickColor = grey
		base.Material   = Enum.Material.Metal
		base.Size       = Vector3.new(9, 2.5, 7)
		base.Position   = position + Vector3.new(0, 5.75, 0)

		-- Three tripod legs (two front, one rear) using CFrame orientation
		local legDefs = {
			{ top = Vector3.new(-2.5, 5.5,  1.5), foot = Vector3.new(-7, 0.4,  8) },
			{ top = Vector3.new( 2.5, 5.5,  1.5), foot = Vector3.new( 7, 0.4,  8) },
			{ top = Vector3.new( 0,   5.5, -1.5), foot = Vector3.new( 0, 0.4, -8) },
		}
		for _, l in legDefs do
			local topW  = position + l.top
			local footW = position + l.foot
			local mid   = (topW + footW) * 0.5
			local len   = (topW - footW).Magnitude
			local leg   = mp("Leg", Vector3.new(1.6, len, 1.6), mid)
			leg.CFrame  = CFrame.lookAt(mid, footW) * CFrame.Angles(math.pi / 2, 0, 0)
			-- Small foot pad at each leg base
			mp("FootPad", Vector3.new(3, 0.5, 3),
				position + Vector3.new(l.foot.X, 0.25, l.foot.Z))
		end

		-- Vertical post: hub → gun mount
		mp("Post", Vector3.new(1.4, 2.5, 1.4), position + Vector3.new(0, 8.25, 0))

		-- Machine gun receiver (rotates to track targets) — MUST remain "Head"
		local head   = mp("Head", Vector3.new(3.2, 2, 4), position + Vector3.new(0, 9.75, 0))

		-- Gun barrel (full 3-D aim updated each attack tick) — MUST remain "Barrel"
		local barrel = mp("Barrel", Vector3.new(0.7, 0.7, 7),
			position + Vector3.new(0, 9.75, 3.5))

		-- Rear sight stub above receiver
		mp("Sight", Vector3.new(0.4, 0.7, 0.4), position + Vector3.new(0, 10.85, -1.2))

		-- Muzzle device at barrel tip
		mp("Muzzle", Vector3.new(1.1, 1.1, 0.6), position + Vector3.new(0, 9.75, 7.25))

		-- Neon accent ring at post-to-gun junction — MUST remain "Ring" (upgrade system uses it)
		local ring       = Instance.new("Part")
		ring.Name        = "Ring"
		ring.Size        = Vector3.new(3.2, 0.4, 3.2)
		ring.Position    = position + Vector3.new(0, 8.75, 0)
		ring.BrickColor  = BrickColor.new("Bright red")
		ring.Material    = Enum.Material.Neon
		ring.Anchored    = true
		ring.CanCollide  = false
		ring.CastShadow  = false
		ring.Parent      = model

	elseif buildingType == "Monument" then
		-- Shaft: stone-grey, non-neon so it's not blinding
		base.BrickColor = BrickColor.new("Light stone grey")
		base.Material   = Enum.Material.SmoothPlastic

		-- Small glowing orb at the tip
		local tip        = Instance.new("Part")
		tip.Name         = "Tip"
		tip.Shape        = Enum.PartType.Ball
		tip.Size         = Vector3.new(3.5, 3.5, 3.5)
		tip.Position     = position + Vector3.new(0, size.Y + 1.75, 0)
		tip.BrickColor   = BrickColor.new("Bright yellow")
		tip.Material     = Enum.Material.Neon
		tip.Anchored     = true
		tip.CastShadow   = false
		tip.Parent       = model

		-- Two thin gold ring accents at 35% and 70% of the shaft height
		for i = 1, 2 do
			local ring       = Instance.new("Part")
			ring.Name        = "Ring" .. i
			ring.Shape       = Enum.PartType.Cylinder
			ring.Size        = Vector3.new(0.35, 8, 8)
			ring.CFrame      = CFrame.new(position + Vector3.new(0, size.Y * (i / 3 + 0.05), 0))
				* CFrame.Angles(0, 0, math.pi / 2)
			ring.BrickColor  = BrickColor.new("Bright yellow")
			ring.Material    = Enum.Material.Neon
			ring.Anchored    = true
			ring.CastShadow  = false
			ring.Parent      = model
		end

	elseif buildingType == "Relay" then
		-- Mag-Rail Relay: armored electromagnetic launch tower.
		-- Catches incoming deploy pods and fires them onward toward the target.
		local grey = BrickColor.new("Dark stone grey")
		local tc   = player.TeamColor

		-- Repurpose base as a wide armored foundation slab
		base.Size       = Vector3.new(8, 1.5, 8)
		base.Position   = position + Vector3.new(0, 0.75, 0)
		base.BrickColor = grey
		base.Material   = Enum.Material.Metal

		-- Central launch column (vertical cylinder — the barrel)
		local col      = Instance.new("Part")
		col.Name       = "Column"
		col.Shape      = Enum.PartType.Cylinder
		col.Size       = Vector3.new(9, 2.6, 2.6)
		col.CFrame     = CFrame.new(position + Vector3.new(0, 6, 0))
		              * CFrame.Angles(0, 0, math.pi / 2)
		col.BrickColor = grey
		col.Material   = Enum.Material.Metal
		col.Anchored   = true
		col.CastShadow = false
		col.CanCollide = false
		col.Parent     = model

		-- Three accelerator coil rings along the column (team-color neon)
		for i, ry in {3.5, 5.7, 7.9} do
			local coil      = Instance.new("Part")
			coil.Name       = "CoilRing" .. i
			coil.Shape      = Enum.PartType.Cylinder
			coil.Size       = Vector3.new(0.45, 3.4, 3.4)
			coil.CFrame     = CFrame.new(position + Vector3.new(0, ry, 0))
			             * CFrame.Angles(0, 0, math.pi / 2)
			coil.BrickColor = tc
			coil.Material   = Enum.Material.Neon
			coil.Anchored   = true
			coil.CastShadow = false
			coil.CanCollide = false
			coil.Parent     = model
		end

		-- Barrel cap: dark metal disc sealing the column top
		local cap      = Instance.new("Part")
		cap.Name       = "BarrelCap"
		cap.Shape      = Enum.PartType.Cylinder
		cap.Size       = Vector3.new(0.6, 3.6, 3.6)
		cap.CFrame     = CFrame.new(position + Vector3.new(0, 10.5, 0))
		             * CFrame.Angles(0, 0, math.pi / 2)
		cap.BrickColor = BrickColor.new("Black")
		cap.Material   = Enum.Material.Metal
		cap.Anchored   = true
		cap.CastShadow = false
		cap.CanCollide = false
		cap.Parent     = model

		-- CatchRing: large neon mouth at the top — catches and relaunches pods
		local cr      = Instance.new("Part")
		cr.Name       = "CatchRing"
		cr.Shape      = Enum.PartType.Cylinder
		cr.Size       = Vector3.new(0.7, 7, 7)
		cr.CFrame     = CFrame.new(position + Vector3.new(0, 11.5, 0))
		           * CFrame.Angles(0, 0, math.pi / 2)
		cr.BrickColor = tc
		cr.Material   = Enum.Material.Neon
		cr.Anchored   = true
		cr.CastShadow = false
		cr.CanCollide = false
		cr.Parent     = model

		-- Two diagonal support struts bracing the column to the slab
		for _, sign in {-1, 1} do
			local topPt = position + Vector3.new(0, 7.5, sign * 0.5)
			local botPt = position + Vector3.new(0, 1.5, sign * 3.5)
			local mid   = (topPt + botPt) * 0.5
			local len   = (topPt - botPt).Magnitude
			local strut      = Instance.new("Part")
			strut.Name       = "Strut"
			strut.Size       = Vector3.new(0.65, len, 0.65)
			strut.BrickColor = grey
			strut.Material   = Enum.Material.Metal
			strut.Anchored   = true
			strut.CanCollide = false
			strut.CastShadow = false
			strut.CFrame = CFrame.lookAt(mid, botPt) * CFrame.Angles(math.pi / 2, 0, 0)
			strut.Parent = model
		end

		-- Ambient point light at the catch ring (pulses during relay transit)
		local glowPart      = Instance.new("Part")
		glowPart.Name       = "RelayLight"
		glowPart.Size       = Vector3.one * 0.1
		glowPart.CFrame     = CFrame.new(position + Vector3.new(0, 11.5, 0))
		glowPart.Anchored   = true; glowPart.CanCollide = false
		glowPart.Transparency = 1; glowPart.CastShadow = false
		glowPart.Parent     = model
		local rl            = Instance.new("PointLight")
		rl.Color            = tc.Color
		rl.Brightness       = 2
		rl.Range            = 28
		rl.Parent           = glowPart

	elseif buildingType == "CreepyBlob" then
		base.BrickColor = BrickColor.new("Black")
		base.Material   = Enum.Material.SmoothPlastic

		-- Irregular nodule bumps around the top
		for i = 1, 5 do
			local angle   = (i / 5) * math.pi * 2
			local r       = 2.8
			local bump         = Instance.new("Part")
			bump.Name          = "Bump_" .. i
			bump.Shape         = Enum.PartType.Ball
			bump.Size          = Vector3.new(
				rng:NextNumber(2.2, 3.2),
				rng:NextNumber(2.0, 3.0),
				rng:NextNumber(2.2, 3.2)
			)
			bump.Position      = position + Vector3.new(math.cos(angle) * r, size.Y - 0.5, math.sin(angle) * r)
			bump.BrickColor    = BrickColor.new("Black")
			bump.Material      = Enum.Material.SmoothPlastic
			bump.Anchored      = true
			bump.CanCollide    = false
			bump.CastShadow    = false
			bump.Parent        = model
		end

		-- Small dark-indigo neon eye at the peak
		local eye          = Instance.new("Part")
		eye.Name           = "Eye"
		eye.Shape          = Enum.PartType.Ball
		eye.Size           = Vector3.new(1.8, 1.8, 1.8)
		eye.Position       = position + Vector3.new(0, size.Y + 0.8, 0)
		eye.BrickColor     = BrickColor.new("Dark indigo")
		eye.Material       = Enum.Material.Neon
		eye.Anchored       = true
		eye.CanCollide     = false
		eye.CastShadow     = false
		eye.Parent         = model

	elseif buildingType == "CreepyWorm" then
		base.BrickColor = BrickColor.new("Black")
		base.Material   = Enum.Material.SmoothPlastic

		-- Six bone-black spine protrusions tilting outward from the mound
		local spineCount = 6
		for i = 1, spineCount do
			local angle  = (i / spineCount) * math.pi * 2
			local r      = 3.0
			local spine         = Instance.new("Part")
			spine.Name          = "Spine_" .. i
			spine.Size          = Vector3.new(0.8, 3.5, 0.8)
			spine.BrickColor    = BrickColor.new("Black")
			spine.Material      = Enum.Material.SmoothPlastic
			spine.Anchored      = true
			spine.CanCollide    = false
			spine.CastShadow    = false
			spine.CFrame        = CFrame.new(position + Vector3.new(math.cos(angle) * r, size.Y + 0.75, math.sin(angle) * r))
				* CFrame.Angles(math.sin(angle) * 0.28, 0, -math.cos(angle) * 0.28)
			spine.Parent        = model
		end

	elseif buildingType == "Deployer" or buildingType == "TEST" then
		-- Bonfire / TEST: a mystical purple flame that auto-summons units. The team-coloured
		-- base stays as the invisible collision/HP box; the bonfire comes from the shared
		-- builder so the thumbnail preview stays in sync. TEST reuses the bonfire decor.
		base.Transparency = 1
		UnitVisuals.buildBonfireDecor(model, CFrame.new(position), player.TeamColor, true)

	elseif buildingType == "LampreyNest" then
		-- Lamprey Nest: the team-coloured base stays as the invisible collision/HP
		-- box; the whole structure (seven egg-tipped tentacles erupting from a central
		-- green orifice) comes from the shared builder so the thumbnail preview stays
		-- in sync. The Core + TubeTip_* egg parts are pulsed by the egg-eject
		-- animation; eggs emerge from the central Core and arc out to settle / launch.
		base.Transparency = 1
		UnitVisuals.buildLampreyNestDecor(model, CFrame.new(position), player.TeamColor, true)

	elseif buildingType == "Foundry" then
		-- Foundry: the team-coloured base stays as the invisible collision/HP box; the
		-- molten-crucible structure comes from the shared builder so the thumbnail
		-- preview stays in sync. A floating "Boosted +X%" label is added below.
		base.Transparency = 1
		UnitVisuals.buildFoundryDecor(model, CFrame.new(position), player.TeamColor, true)

	elseif buildingType == "EngineeringPost" then
		-- Engineering Post: invisible logic box + shared lab decor; a hidden "research
		-- ready" notifier billboard is added below and toggled when research completes.
		base.Transparency = 1
		UnitVisuals.buildEngineeringPostDecor(model, CFrame.new(position), player.TeamColor, true)

	else
		-- Generic fallback: keep the team-coloured base visible. No placeable type reaches
		-- here now that the Barracks is gone, but stay safe for any unknown type.
		base.Transparency = 0
	end

	local ov        = Instance.new("StringValue")
	ov.Name         = "OwnerId"
	ov.Value        = tostring(player.UserId)
	ov.Parent       = model

	local tv        = Instance.new("StringValue")
	tv.Name         = "BuildingType"
	tv.Value        = buildingType
	tv.Parent       = model

	model.PrimaryPart = base
	model.Parent      = buildingsFolder

	-- Fell any forest the structure lands on. CCs carve a wide clearing; every
	-- other building just clears its own footprint plus a small margin.
	if forestManagerRef then
		local clearR = (buildingType == "CommandCenter")
			and Config.FOREST_CC_CLEARING
			or  (math.max(size.X, size.Z) / 2 + 6)
		forestManagerRef.clearAround(position, clearR)
	end

	local maxHp    = (Config.BUILDING_HP :: any)[buildingType] or 400
	local buildTime: number
	if buildingType == "CommandCenter" or skipNextConstruction then
		buildTime = 0
	elseif nextBuildRiseTime then
		buildTime        = nextBuildRiseTime
		nextBuildRiseTime = nil
	else
		buildTime = (Config.BUILD_TIME :: any)[buildingType] or 0
	end

	addHealthBar(base, maxHp)
	if buildingType == "CommandCenter" then
		-- Lift the bar clear of the fabrication arms (~19 studs tall)
		local bb = base:FindFirstChild("HealthBar") :: BillboardGui?
		if bb then bb.StudsOffset = Vector3.new(0, size.Y / 2 + 16, 0) end
	end

	if buildingType == "Foundry" then
		-- Floating "Boosted +X%" readout, updated by the income tick. Server-created so
		-- it replicates to every client; hidden until a deposit is actually boosting it.
		local bl           = Instance.new("BillboardGui")
		bl.Name            = "BoostLabel"
		bl.Size            = UDim2.new(0, 75, 0, 15)
		bl.StudsOffset     = Vector3.new(0, size.Y + 6, 0)
		bl.AlwaysOnTop     = true
		bl.Enabled         = false
		bl.Parent          = base
		local lbl                  = Instance.new("TextLabel")
		lbl.Name                   = "Text"
		lbl.Size                   = UDim2.new(1, 0, 1, 0)
		lbl.BackgroundTransparency = 1
		lbl.Font                   = Enum.Font.GothamBold
		lbl.TextSize               = 9
		lbl.TextColor3             = Color3.fromRGB(255, 190, 70)
		lbl.TextStrokeTransparency = 0.3
		lbl.Text                   = "Boosted +0%"
		lbl.Parent                 = bl
	end

	if buildingType == "EngineeringPost" then
		-- "Research ready" notifier, hidden until a research completes (toggled by the
		-- research tick). Server-created so it replicates to every client.
		local nb           = Instance.new("BillboardGui")
		nb.Name            = "ResearchReady"
		nb.Size            = UDim2.new(0, 46, 0, 46)
		nb.StudsOffset     = Vector3.new(0, size.Y + 4, 0)
		nb.AlwaysOnTop     = true
		nb.Enabled         = false
		nb.Parent          = base
		local nlbl                  = Instance.new("TextLabel")
		nlbl.Size                   = UDim2.new(1, 0, 1, 0)
		nlbl.BackgroundTransparency = 1
		nlbl.Font                   = Enum.Font.GothamBold
		nlbl.TextScaled             = true
		nlbl.TextColor3             = Color3.fromRGB(120, 255, 140)
		nlbl.TextStrokeTransparency = 0.2
		nlbl.Text                   = "💡"
		nlbl.Parent                 = nb
	end

	local startHp = (buildTime > 0) and 1 or maxHp
	buildingData[id] = {
		hp             = startHp,
		maxHp          = maxHp,
		base           = base,
		owner          = player,
		buildingType   = buildingType,
		head           = buildingType == "Turret" and (model:FindFirstChild("Head") :: BasePart?) or nil,
		barrel         = buildingType == "Turret" and (model:FindFirstChild("Barrel") :: BasePart?) or nil,
		isConstructing = buildTime > 0,
		turretUpgrade  = nil,
	}
	applyHP(buildingData[id])

	if buildingType == "CommandCenter" then
		playerHasCC[player.UserId] = true
	end
	if buildingType == "Turret" then
		turretTimers[id] = 0
	end
	if buildingType == "Deployer" then
		deployerTimers[id]    = 0
		deployerUnitType[id]  = "Survivor"
		deployerUpdateAcc[id] = 0
		deployerLevel[id]     = 0
	end
	if buildingType == "TEST" then
		deployerTimers[id]    = 0
		deployerUnitType[id]  = "Survivor"
		deployerUpdateAcc[id] = 0
		testSupplyLevel[id]   = 0
		testRateLevel[id]     = 0
	end

	RemoteHandler.get(Config.REMOTES.BuildingPlaced):FireAllClients(
		id, player.UserId, position, buildingType
	)

	-- ── Construction animation ────────────────────────────────────────────────
	if buildTime > 0 then
		model:ScaleTo(0.04)
		model:PivotTo(CFrame.new(position.X, position.Y, position.Z))

		task.spawn(function()
			local elapsed   = 0
			local finalY    = size.Y / 2
			-- All pivot heights below are RELATIVE to the terrain surface the build
			-- sits on (position.Y), so the rise lands on the correct tier instead of
			-- snapping back to the world Y=0 ground.
			local surfY     = position.Y

			while elapsed < buildTime do
				local dt = task.wait(0.05)
				if not buildingData[id] then return end

				elapsed = math.min(elapsed + dt, buildTime)
				local progress = elapsed / buildTime
				-- Ease-out so the grow/rise decelerates into its final position
				local ease = 1 - (1 - progress) ^ 2

				if buildingType == "CreepyWorm" then
					-- Smoothstep easing: slow start → fast finish (fighting to get free)
					local wEase = progress * progress * (3 - 2 * progress)
					-- Pure rotation wobble — stays on its X/Z footprint so it looks grounded
					local tiltX = math.sin(elapsed * 4.1) * math.min(progress * 0.6, 0.14)
					local tiltZ = math.cos(elapsed * 5.7) * math.min(progress * 0.6, 0.11)
					local spin  = elapsed * 0.35  -- slow base rotation
					model:PivotTo(
						CFrame.new(position.X, surfY + wEase * finalY, position.Z)
						* CFrame.Angles(tiltX, spin, tiltZ)
					)
				else
					-- Grow in scale and rise simultaneously — building emerges from ground up
					local s = math.max(ease, 0.04)
					model:ScaleTo(s)
					model:PivotTo(CFrame.new(position.X, surfY + ease * finalY, position.Z))
				end

				local target = math.max(1, math.floor(progress * maxHp))
				local data   = buildingData[id]
				if data.hp < target then
					data.hp = target
					applyHP(data)
				end
			end

			local data = buildingData[id]
			if data then
				model:ScaleTo(1)
				model:PivotTo(CFrame.new(position.X, surfY + finalY, position.Z))
				data.hp            = math.max(data.hp, maxHp)
				data.isConstructing = false
				applyHP(data)

				-- Foundry: 3D "online" sound when it finishes building.
				if buildingType == "Foundry" then
					local snd              = Instance.new("Sound")
					snd.SoundId            = "rbxassetid://87646813759701"
					snd.Volume             = 0.7
					snd.RollOffMode        = Enum.RollOffMode.Linear
					snd.RollOffMinDistance = 12
					snd.RollOffMaxDistance = 160
					snd.Parent             = base
					snd:Play()
					game:GetService("Debris"):AddItem(snd, 6)
				end

				if buildingType == "CreepyWorm" then
					-- Lunge skyward: rapid spiral rise then freeze briefly before eruption
					for i = 1, 12 do
						task.wait(0.025)
						if not buildingData[id] then return end
						local t    = i / 12
						local spin = t * math.pi * 2.2
						local lungeY = surfY + finalY + math.sin(t * math.pi) * 7
						model:PivotTo(
							CFrame.new(position.X, lungeY, position.Z)
							* CFrame.Angles(math.sin(spin * 0.5) * 0.3, spin, math.cos(spin * 0.7) * 0.3)
						)
					end
					if not buildingData[id] then return end
					-- Pause at peak height for a beat, then drop back to spawn height for explosion
					task.wait(0.08)
					if not buildingData[id] then return end
					model:PivotTo(CFrame.new(position.X, surfY + finalY + 4, position.Z))

					-- Erupt: VFX, spawn 10 soldiers, destroy the building
					task.spawn(spawnWormBurstVFX, position + Vector3.new(0, 5, 0))
					if unitManagerRef then
						for i = 1, 10 do
							local angle  = (i / 10) * math.pi * 2
							local offset = Vector3.new(math.cos(angle) * 8, 0, math.sin(angle) * 8)
							unitManagerRef.spawnUnitNow(player, position + offset, "CreepySoldier")
						end
					end
					RemoteHandler.get(Config.REMOTES.WormBurst):FireAllClients(position)
					buildingData[id] = nil
					model:Destroy()
					return
				end

				if buildingType == "Monument" then
					monumentWinTimer[id] = 0
					RemoteHandler.get(Config.REMOTES.MonumentProgress)
						:FireAllClients(player.UserId, Config.MONUMENT_WIN_DURATION)
				end
			end
		end)
	end

	return id
end

-- ── Turret upgrade visuals ────────────────────────────────────────────────────

local function applyTurretUpgradeVisuals(id: string, upgradeType: string)
	local model = buildingsFolder:FindFirstChild(id)
	if not model then return end

	local head   = model:FindFirstChild("Head")   :: BasePart?
	local barrel = model:FindFirstChild("Barrel") :: BasePart?
	local ring   = model:FindFirstChild("Ring")   :: BasePart?

	if upgradeType == "Flamethrower" then
		if head then
			head.BrickColor = BrickColor.new("Bright orange")
			head.Material   = Enum.Material.Neon
		end
		if barrel then
			-- Shorter, wider nozzle
			barrel.BrickColor = BrickColor.new("Bright orange")
			barrel.Material   = Enum.Material.Neon
			barrel.Size       = Vector3.new(2.4, 2.4, 5)
		end
		if ring then
			ring.BrickColor = BrickColor.new("Deep orange")
			ring.Size       = ring.Size + Vector3.new(0, 0.4, 0)
		end

	elseif upgradeType == "RocketLauncher" then
		if head then
			head.BrickColor = BrickColor.new("Dark indigo")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = head.Size + Vector3.new(1, 0.5, 1)
		end
		if barrel then
			-- Long, wide missile tube
			barrel.BrickColor = BrickColor.new("Medium blue")
			barrel.Material   = Enum.Material.Metal
			barrel.Size       = Vector3.new(2.4, 2.4, 11)
		end
		if ring then
			ring.BrickColor = BrickColor.new("Medium blue")
			ring.Material   = Enum.Material.Neon
		end

	elseif upgradeType == "Creepy" then
		if head then
			head.BrickColor = BrickColor.new("Black")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = Vector3.new(6, 4, 6)
		end
		if barrel then barrel.Transparency = 1 end
		if ring then
			ring.BrickColor = BrickColor.new("Black")
			ring.Material   = Enum.Material.SmoothPlastic
			ring.Size       = ring.Size + Vector3.new(3, 0, 3)
		end

	elseif upgradeType == "Artillery" then
		-- Massive siege piece: huge armored mantlet + three long nozzles, mounted
		-- on a reinforced pedestal. Mantlet + barrels rotate to aim; the pedestal,
		-- collar and energy band stay fixed (symmetric, so rotation looks clean).
		local steel = BrickColor.new("Dark stone grey")
		local black = BrickColor.new("Really black")
		local glow  = BrickColor.new("Deep orange")

		local function ap(nm: string, sz: Vector3, cf: CFrame, bc: BrickColor, mat: Enum.Material, shape: Enum.PartType?): Part
			local p       = Instance.new("Part")
			p.Name        = nm
			if shape then (p :: any).Shape = shape end
			p.Size        = sz
			p.CFrame      = cf
			p.BrickColor  = bc
			p.Material     = mat
			p.Anchored    = true
			p.CanCollide  = false
			p.CastShadow  = false
			p.Parent      = model
			return p
		end

		if not head then return end
		local hp = head.Position

		-- Enlarged armored mantlet (~4× the stock gun head) — rotates to aim
		head.BrickColor = steel
		head.Material   = Enum.Material.Metal
		head.Size       = Vector3.new(8, 6, 9)

		-- Original single barrel is replaced by the three nozzles
		if barrel then barrel.Transparency = 1 end

		-- Wide armored collar at the gun/pedestal junction (symmetric → static-safe)
		if ring then
			ring.BrickColor = black
			ring.Material   = Enum.Material.Metal
			ring.Size       = Vector3.new(7.5, 1.4, 7.5)
		end

		-- Fixed reinforced pedestal beneath the mantlet
		ap("ArtPedestal", Vector3.new(7, 3.5, 7), CFrame.new(hp + Vector3.new(0, -3, 0)), black, Enum.Material.Metal)
		-- Glowing energy band around the pedestal (cylinder ring, symmetric)
		ap("ArtCore", Vector3.new(0.7, 7.6, 7.6),
			CFrame.new(hp + Vector3.new(0, -3, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			glow, Enum.Material.Neon, Enum.PartType.Cylinder)

		-- Three long nozzles — stored in data so the attack loop aims them
		local barrels: { BasePart } = {}
		for i, off in { -2.1, 0, 2.1 } do
			local center = hp + Vector3.new(off, 0, 6)
			local b = ap("ArtBarrel" .. i, Vector3.new(1.5, 1.5, 14),
				CFrame.new(center, center + Vector3.new(0, 0, 1)), steel, Enum.Material.Metal)
			barrels[i] = b
		end
		local data = buildingData[id]
		if data then data.barrels = barrels end

	elseif upgradeType == "Mutant" then
		-- Larger, more horrifying mass — pulsing black growth with bone-white teeth ring
		if head then
			head.BrickColor = BrickColor.new("Black")
			head.Material   = Enum.Material.SmoothPlastic
			head.Size       = Vector3.new(9, 6, 9)
		end
		if barrel then barrel.Transparency = 1 end
		if ring then
			ring.BrickColor = BrickColor.new("Black")
			ring.Material   = Enum.Material.SmoothPlastic
			ring.Size       = ring.Size + Vector3.new(7, 0, 7)
		end
		-- Bone-white tooth spines around the enlarged head
		if model and head then
			local toothCount = 8
			for i = 1, toothCount do
				local angle    = (i / toothCount) * math.pi * 2
				local r        = 5.0
				local toothPos = head.Position + Vector3.new(math.cos(angle) * r, -0.5, math.sin(angle) * r)
				local tooth         = Instance.new("Part")
				tooth.Name          = "MutantTooth_" .. i
				tooth.Size          = Vector3.new(0.9, 2.8, 0.9)
				tooth.BrickColor    = BrickColor.new("Institutional white")
				tooth.Material      = Enum.Material.SmoothPlastic
				tooth.Anchored      = true
				tooth.CanCollide    = false
				tooth.CastShadow    = false
				tooth.CFrame        = CFrame.new(toothPos)
					* CFrame.Angles(0, angle, math.pi * 0.12)
				tooth.Parent        = model
			end
		end
	end

	-- Tag the model so clients can read upgrade state (overwrite for tier-2 Mutant)
	local existing = model:FindFirstChild("Upgrade") :: StringValue?
	if existing then
		existing.Value = upgradeType
	else
		local uv  = Instance.new("StringValue")
		uv.Name   = "Upgrade"
		uv.Value  = upgradeType
		uv.Parent = model
	end
end

-- ── Mutant turret: creepy soldier spawning ────────────────────────────────────

local mutantSoldierParts: { [string]: { BasePart } } = {}

local function startMutantSoldierLoop(turretId: string, data: any, owner: Player)
	mutantSoldierParts[turretId] = {}
	task.spawn(function()
		-- Immediate first spawn attempt
		task.wait(2)
		while buildingData[turretId] and data.turretUpgrade == "Mutant" do
			local soldiers = mutantSoldierParts[turretId]
			if soldiers then
				-- Prune dead soldiers
				for i = #soldiers, 1, -1 do
					if not soldiers[i].Parent then table.remove(soldiers, i) end
				end
				-- Spawn a new one if below cap
				if #soldiers < Config.CREEPY_SOLDIER_MAX and unitManagerRef then
					local angle    = math.random() * math.pi * 2
					local offset   = Vector3.new(math.cos(angle) * 5, 0, math.sin(angle) * 5)
					local spawnPos = data.base.Position + offset
					local uid = unitManagerRef.spawnUnitNow(owner, spawnPos, "CreepySoldier")
					if uid then
						local unitsF = workspace:FindFirstChild("Units")
						local part   = unitsF and unitsF:FindFirstChild(uid)
						if part and part:IsA("BasePart") then
							table.insert(soldiers, part :: BasePart)
						end
					end
				end
			end
			task.wait(Config.CREEPY_SOLDIER_SPAWN_INTERVAL)
		end
		mutantSoldierParts[turretId] = nil
	end)
end


-- ── Drop pod model ────────────────────────────────────────────────────────────

local function createDropPodModel(): Model
	local model = Instance.new("Model")
	model.Name  = "_DropPod"

	local function ap(nm: string, sz: Vector3, cf: CFrame, col: Color3, mat: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = nm
		if shape then (p :: any).Shape = shape end
		p.Size = sz; p.CFrame = cf; p.Color = col; p.Material = mat
		p.Anchored = true; p.CanCollide = false; p.CastShadow = false
		p.Parent = model
		return p
	end

	local anchor        = Instance.new("Part")
	anchor.Name         = "Anchor"
	anchor.Size         = Vector3.one * 0.1
	anchor.Anchored     = true; anchor.CanCollide = false; anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Parent       = model
	model.PrimaryPart   = anchor

	-- Colours
	local cBody   = Color3.fromRGB(18, 20, 24)   -- near-black matte
	local cPlate  = Color3.fromRGB(48, 52, 58)   -- dark steel plate
	local cCap    = Color3.fromRGB(32, 35, 40)   -- slightly lighter cap
	local cNeon   = Color3.fromRGB(255, 140, 20) -- amber-orange neon

	-- Core body: X = length (becomes height after 90° Z rotation), Y/Z = diameter
	ap("Body",
		Vector3.new(8, 3.5, 3.5),
		CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.pi / 2),
		cBody, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)

	-- Slim neon band around the waist
	ap("WaistRing",
		Vector3.new(0.18, 4.1, 4.1),
		CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.pi / 2),
		cNeon, Enum.Material.Neon, Enum.PartType.Cylinder)

	-- Cap on top: dark steel block, slightly wider
	ap("Cap",    Vector3.new(4.2, 1.1, 4.2), CFrame.new(0,  4.55, 0), cCap,  Enum.Material.Metal)
	ap("CapRim", Vector3.new(4.6, 0.3, 4.6), CFrame.new(0,  4.15, 0), cPlate, Enum.Material.Metal)

	-- Neon exhaust ring at the very top (thruster glow)
	ap("TopGlow",
		Vector3.new(0.28, 4.8, 4.8),
		CFrame.new(0, 4.9, 0) * CFrame.Angles(0, 0, math.pi / 2),
		cNeon, Enum.Material.Neon, Enum.PartType.Cylinder)

	-- Neon exhaust ring at the bottom
	ap("BotGlow",
		Vector3.new(0.22, 3.9, 3.9),
		CFrame.new(0, -3.8, 0) * CFrame.Angles(0, 0, math.pi / 2),
		cNeon, Enum.Material.Neon, Enum.PartType.Cylinder)

	-- 4 door panels — hinged at the bottom edge of the core (local Y = -4).
	-- Outer shell plate + inner neon strip both carry HingeAngle so they animate together.
	local CORE_R   = 1.75  -- cylinder radius (half of 3.5)
	local PANEL_H  = 5.5
	local PANEL_T  = 0.5
	local PANEL_W  = 3.1
	local STRIP_T  = 0.12
	for i = 0, 3 do
		local beta    = i * math.pi / 2
		local radial  = Vector3.new(math.cos(beta), 0, math.sin(beta))
		local tangent = Vector3.new(-math.sin(beta), 0, math.cos(beta))
		local panelY  = -4 + PANEL_H / 2  -- = -1.25 (flush against bottom half of core)

		-- Outer shell plate
		local outerPos = radial * (CORE_R + PANEL_T / 2) + Vector3.new(0, panelY, 0)
		local cf       = CFrame.fromMatrix(outerPos, tangent, Vector3.new(0, 1, 0))
		local panel    = ap("Door_" .. i, Vector3.new(PANEL_W, PANEL_H, PANEL_T), cf,
			cPlate, Enum.Material.Metal)
		panel:SetAttribute("HingeAngle", beta)

		-- Neon inner strip recessed into the panel's inner half — avoids z-fighting
		-- with the panel's own inner face and the cylinder surface (both at CORE_R).
		local innerPos = radial * (CORE_R + PANEL_T / 2 - STRIP_T / 2) + Vector3.new(0, panelY, 0)
		local cfInner  = CFrame.fromMatrix(innerPos, tangent, Vector3.new(0, 1, 0))
		local strip    = ap("DoorGlow_" .. i,
			Vector3.new(PANEL_W - 0.4, PANEL_H - 0.3, STRIP_T), cfInner,
			cNeon, Enum.Material.Neon)
		strip:SetAttribute("HingeAngle", beta)
	end

	local glowPart        = Instance.new("Part")
	glowPart.Name         = "GlowPart"
	glowPart.Size         = Vector3.one * 0.1
	glowPart.CFrame       = CFrame.new(0, 0, 0)
	glowPart.Anchored     = true; glowPart.CanCollide = false
	glowPart.Transparency = 1; glowPart.CastShadow = false
	glowPart.Parent       = model
	local glow            = Instance.new("PointLight")
	glow.Color            = Color3.fromRGB(255, 140, 20)
	glow.Brightness       = 5
	glow.Range            = 28
	glow.Parent           = glowPart

	return model
end


-- ── Relay chain helpers ───────────────────────────────────────────────────────

local RELAY_CATCH_HEIGHT = 11  -- studs above relay base position to aim for (top of CatchRing)

-- Returns ordered relay base positions the pod should hop through from ccPos to targetPos.
-- Each relay in the list is closer to targetPos than the previous hop.
local function findRelayChain(player: any, ccPos: Vector3, targetPos: Vector3): {Vector3}
	local relays: {Vector3} = {}
	for _, data in buildingData do
		if data.owner == player and data.buildingType == "Relay" then
			table.insert(relays, data.base.Position)
		end
	end
	local chain: {Vector3} = {}
	local current            = ccPos
	local used: {[number]: boolean} = {}
	for _ = 1, #relays do
		local tDist = (Vector3.new(current.X, 0, current.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
		local best: number?  = nil
		local bestDist       = tDist
		for i, rp in relays do
			if used[i] then continue end
			local d = (Vector3.new(rp.X, 0, rp.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
			if d < bestDist then bestDist = d; best = i end
		end
		if not best then break end
		used[best] = true
		table.insert(chain, relays[best])
		current = relays[best]
	end
	return chain
end

local function findRelayModelAt(pos: Vector3, owner: any): Model?
	for _, data in buildingData do
		if data.owner == owner and data.buildingType == "Relay" then
			local d = (Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			        - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if d < 5 then return data.base.Parent :: Model end
		end
	end
	return nil
end

local function relayFlash(model: Model)
	for _, p in model:GetDescendants() do
		if not p:IsA("BasePart") or p.Material ~= Enum.Material.Neon then continue end
		task.spawn(function()
			local orig = p.Color
			p.Color = Color3.new(1, 1, 1)
			task.wait(0.1)
			if p.Parent then p.Color = orig end
		end)
	end
	local cr = model:FindFirstChild("CatchRing")
	if cr then
		local flash      = Instance.new("PointLight")
		flash.Color      = Color3.fromRGB(180, 230, 255)
		flash.Brightness = 16
		flash.Range      = 50
		flash.Parent     = cr
		Debris:AddItem(flash, 0.8)
	end
end

-- ── On-site construction (welding-arm assembly) ────────────────────────────

local CONSTRUCT_SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"

-- Open the four landing fins outward; they stay attached so the grounded pod
-- reads as the fabrication rig the welding arms extend from.
local function openPodFins(pod: Model)
	local OPEN_TIME  = 0.5
	local OPEN_ANGLE = math.rad(108)
	local CORE_R     = 1.75
	local podCF      = pod:GetPivot()

	local panels: { { part: BasePart, closedCF: CFrame, openCF: CFrame } } = {}
	for _, d in pod:GetDescendants() do
		if not d:IsA("BasePart") then continue end
		local beta = d:GetAttribute("HingeAngle")
		if beta == nil then continue end
		local radial  = Vector3.new(math.cos(beta), 0, math.sin(beta))
		local tangent = Vector3.new(-math.sin(beta), 0, math.cos(beta))
		local hw    = podCF:PointToWorldSpace(radial * CORE_R + Vector3.new(0, -4, 0))
		local ax    = podCF:VectorToWorldSpace(tangent)
		local rotCF = CFrame.new(hw) * CFrame.fromAxisAngle(ax, -OPEN_ANGLE) * CFrame.new(hw):Inverse()
		table.insert(panels, { part = d :: BasePart, closedCF = d.CFrame, openCF = rotCF * d.CFrame })
	end

	local elapsed = 0
	while elapsed < OPEN_TIME do
		local dt = task.wait()
		elapsed += dt
		local ease = 1 - (1 - math.min(elapsed / OPEN_TIME, 1)) ^ 3
		for _, pi in panels do
			if pi.part.Parent then pi.part.CFrame = pi.closedCF:Lerp(pi.openCF, ease) end
		end
	end
end

-- Assemble the structure on-site: welding arms emerge from the landed pod and
-- build a scaffold + frame through staged passes, then the finished building
-- rises from the ground while the scaffold sinks and the pod fades away. All
-- scaffold / frame dimensions scale to the building footprint.
-- pod may be nil (the Core→Command-Center deploy has no pod — the welding arms
-- emerge from above the build site instead). assemblyOverride forces the total
-- weld-stage duration (else it stretches to Config.BUILD_TIME). onBuilt(id) fires
-- the moment the finished structure is created.
local function runConstruction(player: any, targetPos: Vector3, buildingType: string, pod: Model?, isMine: boolean, assemblyOverride: number?, onBuilt: ((string) -> ())?)
	local sz   = buildingSize(buildingType)
	local hx   = sz.X / 2 + 1.1                 -- scaffold half-extent (just outside footprint)
	local hz   = sz.Z / 2 + 1.1
	local fx   = math.max(sz.X / 2 - 0.5, 0.6)  -- structural-frame half-extent
	local fz   = math.max(sz.Z / 2 - 0.5, 0.6)
	local topY = math.clamp(sz.Y + 1.5, 5, 14)  -- scaffold height

	-- Clear the woods the moment the pod lands so the arms assemble in the open
	-- (createBuilding clears again later, but the trees are already gone by then).
	if forestManagerRef then
		forestManagerRef.clearAround(targetPos, math.max(sz.X, sz.Z) / 2 + 6)
	end

	local STEEL = Color3.fromRGB(74, 78, 86)
	local CAUTN = Color3.fromRGB(238, 188, 38)
	local tc    = player.TeamColor.Color
	local signs = { {1, 1}, {1, -1}, {-1, 1}, {-1, -1} }
	local edges = { {1, 2}, {3, 4}, {1, 3}, {2, 4} }  -- adjacent-corner pairs (shared X or Z)

	local rig  = Instance.new("Model")
	rig.Name   = "_Construction"
	rig.Parent = workspace

	local function mk(nm: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = nm
		if shape then (p :: any).Shape = shape end
		p.Size = size; p.CFrame = cf; p.Color = color; p.Material = mat
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CastShadow = false
		p.Parent = rig
		return p
	end

	-- Stretch a part (length along local Y) to span world points a → b.
	local function orientBeam(p: BasePart, a: Vector3, b: Vector3, thick: number)
		local mid = (a + b) * 0.5
		local len = math.max((b - a).Magnitude, 0.05)
		p.Size   = Vector3.new(thick, len, thick)
		p.CFrame = CFrame.lookAt(mid, b) * CFrame.Angles(math.pi / 2, 0, 0)
	end

	-- Corner scaffold posts (grow from the ground during the beam stage).
	local posts: { BasePart } = {}
	for _, s in signs do
		table.insert(posts, mk("Post", Vector3.new(0.4, 0.1, 0.4),
			CFrame.new(targetPos + Vector3.new(s[1] * hx, 0.05, s[2] * hz)), CAUTN, Enum.Material.Metal))
	end

	-- Top rails connecting the post tops (welded on once the posts are up).
	local rails: { BasePart } = {}
	for _ = 1, 4 do
		local r = mk("Rail", Vector3.new(0.3, 0.3, 0.3), CFrame.new(targetPos), CAUTN, Enum.Material.Metal)
		r.Transparency = 1
		table.insert(rails, r)
	end

	-- Foundation slab (stage 1).
	local slab = mk("Slab", Vector3.new(sz.X, 0.6, sz.Z),
		CFrame.new(targetPos + Vector3.new(0, 0.3, 0)), STEEL, Enum.Material.Metal)
	slab.Transparency = 1

	-- Support beams (stage 2): team-coloured verticals at the footprint corners.
	local beams: { BasePart } = {}
	for _, s in signs do
		table.insert(beams, mk("Beam", Vector3.new(0.6, 0.1, 0.6),
			CFrame.new(targetPos + Vector3.new(s[1] * fx, 0.05, s[2] * fz)), tc, Enum.Material.Metal))
	end

	-- Roof-outline frame (stage 3): edge beams across the support-beam tops.
	local roof: { BasePart } = {}
	for _ = 1, 4 do
		local r = mk("RoofBeam", Vector3.new(0.4, 0.4, 0.4), CFrame.new(targetPos), tc, Enum.Material.Metal)
		r.Transparency = 1
		table.insert(roof, r)
	end

	-- Welding arms: one per corner, emerging from the pod (or, on a pod-less Core
	-- deploy, from a point hovering above the build site) down to the rising frame.
	local podCenter = pod and pod:GetPivot().Position or (targetPos + Vector3.new(0, topY + 3.5, 0))
	local arms: { any } = {}
	for _, s in signs do
		local dir      = Vector3.new(s[1], 0, s[2]).Unit
		local shoulder = podCenter + dir * 1.7 + Vector3.new(0, -1.4, 0)
		local upper = mk("ArmUpper", Vector3.new(0.34, 1, 0.34), CFrame.new(shoulder), STEEL, Enum.Material.Metal)
		local fore  = mk("ArmFore",  Vector3.new(0.27, 1, 0.27), CFrame.new(shoulder), STEEL, Enum.Material.Metal)
		local tip   = mk("ArmTip",   Vector3.new(0.4, 0.4, 0.4), CFrame.new(shoulder),
			Color3.fromRGB(255, 170, 60), Enum.Material.Neon, Enum.PartType.Ball)
		local pe         = Instance.new("ParticleEmitter")
		pe.Texture       = CONSTRUCT_SPARK_TEX
		pe.Color         = ColorSequence.new(Color3.fromRGB(255, 220, 150), Color3.fromRGB(255, 120, 30))
		pe.LightEmission = 1
		pe.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.05) })
		pe.Lifetime      = NumberRange.new(0.15, 0.4)
		pe.Speed         = NumberRange.new(4, 10)
		pe.SpreadAngle   = Vector2.new(160, 160)
		pe.Rate          = 22
		pe.Enabled       = false
		pe.Parent        = tip
		table.insert(arms, { upper = upper, fore = fore, tip = tip, sparks = pe, shoulder = shoulder, sx = s[1], sz = s[2] })
	end

	-- Phase boundaries (cumulative seconds). The welding-assembly stages stretch to
	-- fill the structure's configured Config.BUILD_TIME; the rise is a fixed tail.
	local buildTime = (Config.BUILD_TIME :: any)[buildingType] or 8
	local assembly  = assemblyOverride or math.max(buildTime, 2)
	local F  = assembly * CONSTRUCT_FOUNDATION_FRAC
	local B  = F + assembly * CONSTRUCT_BEAMS_FRAC
	local R  = B + assembly * CONSTRUCT_ROOF_FRAC
	local Ri = R + CONSTRUCT_RISE_TIME

	local built    = false
	local podParts: { BasePart } = {}
	local sinkBase: { [BasePart]: CFrame } = {}
	local elapsed  = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		local t = elapsed

		if t < R then
			-- ── Assembly stages ────────────────────────────────────
			-- Stage 1: foundation slab welds in.
			slab.Transparency = 1 - math.clamp(t / F, 0, 1)

			-- Stage 2: scaffold posts + support beams rise.
			local bProg = math.clamp((t - F) / (B - F), 0, 1)
			local postH = math.max(topY * bProg, 0.1)
			for i, p in posts do
				p.Size     = Vector3.new(0.4, postH, 0.4)
				p.Position = targetPos + Vector3.new(signs[i][1] * hx, postH / 2, signs[i][2] * hz)
			end
			local beamH = math.max(sz.Y * bProg, 0.1)
			for i, b in beams do
				b.Size     = Vector3.new(0.6, beamH, 0.6)
				b.Position = targetPos + Vector3.new(signs[i][1] * fx, beamH / 2, signs[i][2] * fz)
			end
			local railProg = math.clamp((bProg - 0.6) / 0.4, 0, 1)
			for i, r in rails do
				r.Transparency = 1 - railProg
				local a = signs[edges[i][1]]; local c = signs[edges[i][2]]
				orientBeam(r, targetPos + Vector3.new(a[1] * hx, topY, a[2] * hz),
					targetPos + Vector3.new(c[1] * hx, topY, c[2] * hz), 0.3)
			end

			-- Stage 3: roof-outline frame welds across the support-beam tops.
			local rProg = math.clamp((t - B) / (R - B), 0, 1)
			for i, rb in roof do
				rb.Transparency = 1 - rProg
				local a = signs[edges[i][1]]; local c = signs[edges[i][2]]
				orientBeam(rb, targetPos + Vector3.new(a[1] * fx, sz.Y, a[2] * fz),
					targetPos + Vector3.new(c[1] * fx, sz.Y, c[2] * fz), 0.4)
			end

			-- Welding arms track the rising work height.
			local weldY
			if t < F then weldY = 0.7
			elseif t < B then weldY = 0.7 + (sz.Y - 0.7) * bProg
			else weldY = sz.Y end
			for ai, arm in arms do
				local osc    = math.sin(t * 9 + ai * 1.7) * 0.4
				local tipPos = targetPos + Vector3.new(arm.sx * fx, weldY + osc, arm.sz * fz)
				local elbow  = (arm.shoulder + tipPos) * 0.5 + Vector3.new(0, 1.6, 0)
				orientBeam(arm.upper, arm.shoulder, elbow, 0.34)
				orientBeam(arm.fore, elbow, tipPos, 0.27)
				arm.tip.Position   = tipPos
				arm.sparks.Enabled = t > F * 0.5
			end

		else
			-- ── Final stage: building rises, scaffold sinks, pod fades ──────────
			if not built then
				built = true
				-- The CC is instant in createBuilding (buildTime 0) and wouldn't
				-- consume this override, so only arm it for buildings that rise.
				if buildingType ~= "CommandCenter" then
					nextBuildRiseTime = CONSTRUCT_RISE_TIME
				end
				-- Use the exact height the pod landed at and the on-site rig built
				-- around, so the finished structure lines up with them instead of
				-- being re-snapped to a separately-computed height.
				local id = createBuilding(player, targetPos, buildingType, targetPos.Y)
				-- Building is now in buildingData; release its in-flight reservation so
				-- built + pending stays consistent (only for player-placed buildings).
				if player and pendingBuildings[player.UserId] then
					addPending(player, buildingType, -1)
				end
				if researchManagerRef and buildingType ~= "CommandCenter" then
					researchManagerRef.recordBuildingPlaced(player, buildingType)
				end
				if onBuilt then task.spawn(onBuilt, id) end
				for _, p in rig:GetChildren() do
					if p:IsA("BasePart") then sinkBase[p] = p.CFrame end
				end
				if pod then
					for _, p in pod:GetDescendants() do
						if p:IsA("BasePart") then table.insert(podParts, p) end
					end
				end
				local sp = Instance.new("Part")
				sp.Size = Vector3.one * 0.1; sp.CFrame = CFrame.new(targetPos + Vector3.new(0, 1, 0))
				sp.Anchored = true; sp.CanCollide = false; sp.Transparency = 1; sp.Parent = workspace
				local snd = Instance.new("Sound")
				snd.SoundId = "rbxassetid://104085097305841"; snd.Volume = 0.85; snd.Parent = sp
				snd:Play()
				Debris:AddItem(sp, 6)
			end

			local riseProg = math.clamp((t - R) / (Ri - R), 0, 1)
			local ease     = riseProg * riseProg
			local sink     = ease * (topY + 5)
			for _, p in rig:GetChildren() do
				if p:IsA("BasePart") then
					local base = sinkBase[p]
					if base then p.CFrame = base - Vector3.new(0, sink, 0) end
					if p.Name ~= "ArmTip" then p.Transparency = ease end
				end
			end
			for _, arm in arms do
				local tipPos = arm.tip.Position:Lerp(arm.shoulder, riseProg)
				local elbow  = (arm.shoulder + tipPos) * 0.5 + Vector3.new(0, 1.6, 0)
				orientBeam(arm.upper, arm.shoulder, elbow, 0.34)
				orientBeam(arm.fore, elbow, tipPos, 0.27)
				arm.tip.Position     = tipPos
				arm.tip.Transparency = ease
				arm.sparks.Enabled   = false
			end
			for _, p in podParts do
				if p.Parent then p.Transparency = math.min(1, p.Transparency + (1 - p.Transparency) * ease) end
			end

			if t >= Ri then
				conn:Disconnect()
				rig:Destroy()
				if pod and pod.Parent then pod:Destroy() end
			end
		end
	end)
end



-- ── Drop pod flight & building deployment ─────────────────────────────────────

-- launchPos: already-elevated world position to fire from (CC roof or relay CatchRing).
-- relayChain: ordered list of relay base positions to hop through before targetPos.
local function launchDropPod(player: any, launchPos: Vector3, relayChain: {Vector3}, targetPos: Vector3, buildingType: string, isMine: boolean)
	local isHop = #relayChain > 0

	-- Next landing point: first relay's CatchRing or final ground target
	local endPos: Vector3
	if isHop then
		local rp = relayChain[1]
		endPos   = Vector3.new(rp.X, rp.Y + RELAY_CATCH_HEIGHT, rp.Z)
	else
		endPos = targetPos + Vector3.new(0, 4, 0)
	end

	local pod      = createDropPodModel()
	local startPos = launchPos

	local apexPos = Vector3.new(
		(startPos.X + endPos.X) * 0.5,
		math.max(startPos.Y, endPos.Y) + 70,
		(startPos.Z + endPos.Z) * 0.5
	)

	pod:PivotTo(CFrame.new(startPos))
	pod.Parent = workspace

	-- Launch sound
	do
		local sp  = Instance.new("Part")
		sp.Size   = Vector3.one * 0.1; sp.CFrame = CFrame.new(startPos)
		sp.Anchored = true; sp.CanCollide = false; sp.Transparency = 1
		sp.Parent = workspace
		local snd = Instance.new("Sound")
		snd.SoundId = "rbxassetid://78110429907701"
		snd.Volume  = 1
		snd.Parent  = sp
		snd:Play()
		Debris:AddItem(sp, 12)
	end

	-- Smoke contrail
	do
		local anchor = pod.PrimaryPart
		local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(-1.1, 0, 0); a0.Parent = anchor
		local a1 = Instance.new("Attachment"); a1.Position = Vector3.new( 1.1, 0, 0); a1.Parent = anchor
		local tr          = Instance.new("Trail")
		tr.Attachment0    = a0
		tr.Attachment1    = a1
		tr.Color          = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(225, 222, 215)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(155, 150, 145)),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,  58,  55)),
		})
		tr.Transparency   = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0.2),
			NumberSequenceKeypoint.new(0.55, 0.65),
			NumberSequenceKeypoint.new(1,    1.0),
		})
		tr.WidthScale     = NumberSequence.new({
			NumberSequenceKeypoint.new(0,   1.0),
			NumberSequenceKeypoint.new(1,   0.06),
		})
		tr.Lifetime       = 2.0
		tr.LightEmission  = 0.04
		tr.LightInfluence = 0.85
		tr.Parent         = anchor
	end

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		if not pod or not pod.Parent then conn:Disconnect(); return end
		elapsed = elapsed + dt
		local t    = math.min(elapsed / DROP_POD_FLIGHT_TIME, 1)
		local ease = t * t * (3 - 2 * t)
		local u    = 1 - ease

		local pos = startPos * (u * u) + apexPos * (2 * u * ease) + endPos * (ease * ease)

		local tangent = (apexPos - startPos) * (2 * (1 - ease))
			+ (endPos - apexPos) * (2 * ease)
		if tangent.Magnitude > 0.5 then
			pod:PivotTo(CFrame.new(pos, pos + tangent) * CFrame.Angles(-math.pi / 2, 0, 0))
		else
			pod:PivotTo(CFrame.new(pos))
		end

		if t < 1 then return end
		conn:Disconnect()

		if isHop then
			-- ── Relay catch: pod enters relay, relay aims and fires it onward ──────
			pod:Destroy()

			do
				local sp  = Instance.new("Part")
				sp.Size   = Vector3.one * 0.1; sp.CFrame = CFrame.new(endPos)
				sp.Anchored = true; sp.CanCollide = false; sp.Transparency = 1
				sp.Parent = workspace
				local snd = Instance.new("Sound")
				snd.SoundId = "rbxassetid://76696468542735"
				snd.Volume  = 0.35
				snd.Parent  = sp
				snd:Play()
				Debris:AddItem(sp, 5)
			end

			local relayModel = findRelayModelAt(relayChain[1], player)
			if relayModel then relayFlash(relayModel) end

			local remaining: {Vector3} = {}
			for i = 2, #relayChain do table.insert(remaining, relayChain[i]) end

			task.spawn(function()
				task.wait(0.45)
				launchDropPod(player, endPos, remaining, targetPos, buildingType, isMine)
			end)

		else
			-- ── Final landing sequence ─────────────────────────────────────────────
			if isOccupied(targetPos, buildingType) or isTerrainBlocked(targetPos, buildingType) then
				pod:Destroy()
				return
			end

			-- Landing sound at impact point
			do
				local sp  = Instance.new("Part")
				sp.Size   = Vector3.one * 0.1; sp.CFrame = CFrame.new(targetPos)
				sp.Anchored = true; sp.CanCollide = false; sp.Transparency = 1
				sp.Parent = workspace
				local snd = Instance.new("Sound")
				snd.SoundId = "rbxassetid://76696468542735"
				snd.Volume  = 0.25
				snd.Parent  = sp
				snd:Play()
				Debris:AddItem(sp, 10)
			end

			-- Small dirt burst on impact
			local rng2 = Random.new()
			for _ = 1, 8 do
				local d      = Instance.new("Part")
				d.Shape      = Enum.PartType.Ball
				d.Size       = Vector3.one * rng2:NextNumber(0.12, 0.38)
				d.Color      = Color3.fromRGB(
					rng2:NextInteger(78, 112),
					rng2:NextInteger(52, 76),
					rng2:NextInteger(22, 42)
				)
				d.Material   = Enum.Material.SmoothPlastic
				d.Position   = targetPos + Vector3.new(
					rng2:NextNumber(-2, 2), rng2:NextNumber(0.2, 0.8), rng2:NextNumber(-2, 2)
				)
				d.Anchored   = false; d.CanCollide = false; d.CastShadow = false
				d.Parent     = workspace
				local bv     = Instance.new("BodyVelocity")
				bv.Velocity  = Vector3.new(
					rng2:NextNumber(-9, 9), rng2:NextNumber(5, 12), rng2:NextNumber(-9, 9)
				)
				bv.MaxForce  = Vector3.new(1e5, 1e5, 1e5)
				bv.Parent    = d
				Debris:AddItem(d, 1.2)
			end

			-- ── Fins open → welding arms assemble the structure on-site ──────────
			task.spawn(function()
				openPodFins(pod)
				runConstruction(player, targetPos, buildingType, pod, isMine)
			end)
		end
	end)
end


-- ── Public API ────────────────────────────────────────────────────────────────

function BuildingManager.hasCommandCenter(player: any): boolean
	return playerHasCC[player.UserId] == true
end

-- UserIds of every commander (real players AND AI bots) that still owns at least one
-- Command Center. Source of truth is the live building table, so a destroyed CC drops
-- out immediately. Used by the elimination/victory check so a solo player vs AI (only
-- one real player in the match) can still win by wiping out every enemy commander.
function BuildingManager.getCommanderUserIdsWithCC(): { number }
	local seen: { [number]: boolean } = {}
	local out:  { number } = {}
	for _, data in buildingData do
		-- Count constructing CCs too, so a commander mid-rebuild still reads as "in the
		-- match" and can't be prematurely declared defeated.
		if data.buildingType == "CommandCenter" and data.owner then
			local uid = data.owner.UserId
			if not seen[uid] then
				seen[uid] = true
				table.insert(out, uid)
			end
		end
	end
	return out
end

-- Number of finished + in-progress buildings of `buildingType` owned by `player`.
function BuildingManager.getBuildingCount(player: any, buildingType: string): number
	return getPlayerBuildingCount(player, buildingType)
end

-- How many of `player`'s buildings are still being assembled (not yet finished).
-- The AI uses this to build one structure at a time, matching a human's pacing
-- instead of slapping down a whole base in a single strategy tick.
function BuildingManager.countConstructing(player: any): number
	local n = 0
	for _, data in buildingData do
		if data.owner == player and data.isConstructing then n += 1 end
	end
	return n
end

-- Count of buildings of `buildingType` owned by human players (UserId > 0). Lets the
-- AI economy mirror how many Foundries the humans have running.
function BuildingManager.getHumanBuildingCount(buildingType: string): number
	local n = 0
	for _, data in buildingData do
		if data.buildingType == buildingType and data.owner and data.owner.UserId > 0 then n += 1 end
	end
	return n
end

function BuildingManager.resetAll()
	for _, model in buildingsFolder:GetChildren() do model:Destroy() end
	buildingData             = {}
	pendingBuildings         = {}
	playerHasCC              = {}
	turretTimers             = {}
	deployerTimers           = {}
	deployerUnitType         = {}
	deployerUpdateAcc        = {}
	deployerLevel            = {}
	testSupplyLevel          = {}
	testRateLevel            = {}
	eggSacLevel              = {}
	eggSacNests              = {}
	eggSacTimer              = {}
	eggSacInFlight           = {}
	monumentByOwner          = {}
	monumentWinTimer         = {}
	monumentHeartbeatAccum   = 0
	ccIncomeAccum            = 0
	foundryIncomeAccum       = 0
	engState                 = {}
	engResearchEnd           = {}
	engUpdateAcc             = {}
	blobCooldowns            = {}
	ccMobileUnlocked         = {}
	ccMobile                 = {}
	ccMoveTargets            = {}
	playerCCId               = {}
	-- Clear the per-player Embryo evolution unlock so it doesn't carry into the next match.
	for _, plr in game:GetService("Players"):GetPlayers() do
		plr:SetAttribute("EmbryoGenome", nil)
	end
end

function BuildingManager.setOnCCDestroyed(fn: (any) -> ())
	onCCDestroyedCb = fn
end

-- Player voluntarily forfeits the match: destroy their Command Center, which runs
-- the normal destruction + elimination/endgame path (onCCDestroyedCb). Returns
-- false if the player has no live CC (already eliminated / not yet placed).
function BuildingManager.forfeit(player: any): boolean
	local ccId = playerCCId[player.UserId]
	if not ccId or not buildingData[ccId] then return false end
	BuildingManager.damage(ccId, math.huge)
	return true
end

-- True if a disc centred at (x, z) with the given radius overlaps any building's
-- footprint. Building footprints are grid-aligned, so an AABB test is exact enough.
-- Used by unit movement so units can't walk through structures.
function BuildingManager.blocksMovement(x: number, z: number, radius: number): boolean
	for _, data in buildingData do
		local b = data.base
		if not b then continue end
		if math.abs(x - b.Position.X) < b.Size.X * 0.5 + radius
			and math.abs(z - b.Position.Z) < b.Size.Z * 0.5 + radius then
			return true
		end
	end
	return false
end

-- Fraction of a structure's build cost refunded when it is sold.
local SELL_REFUND_FRAC = 0.5
local SELL_COST: { [string]: number } = {
	Foundry         = Config.FOUNDRY_COST,
	EngineeringPost = Config.ENGINEERING_POST_COST,
	Deployer    = Config.DEPLOYER_COST,
	Turret      = Config.TURRET_COST,
	Relay       = Config.RELAY_COST,
	CreepyBlob  = Config.CREEPY_BLOB_COST,
	LampreyNest = Config.LAMPREY_NEST_COST,
	TEST        = Config.TEST_COST,
}

-- Sell a structure: refund part of its cost to the owner and demolish it. The
-- Command Center and Monument can't be sold. Returns false on any rejection.
function BuildingManager.sellBuilding(player: any, id: string): boolean
	local data = buildingData[id]
	if not data then return false end
	if tostring(data.owner.UserId) ~= tostring(player.UserId) then return false end
	if data.buildingType == "CommandCenter" or data.buildingType == "Monument" then return false end

	-- Refund reflects the (possibly scaled) price of the most recently-built one of
	-- this type, so selling an expensive stacked Foundry refunds proportionally.
	local owned    = getPlayerBuildingCount(player, data.buildingType)
	local scaledCost = Config.scaledBuildingCost(
		SELL_COST[data.buildingType] or 0, data.buildingType, math.max(0, owned - 1))
	local refund = math.floor(scaledCost * SELL_REFUND_FRAC)
	if refund > 0 and resourceManagerRef then
		resourceManagerRef.add(player, refund)
	end
	-- Reuse the normal destruction path (model + timers + mine cleanup + VFX).
	BuildingManager.damage(id, math.huge)
	return true
end

function BuildingManager.setOnPlayerWon(fn: (number) -> ())
	onPlayerWonCb = fn
end

function BuildingManager.setUnitManager(um: any)
	unitManagerRef = um
end

function BuildingManager.setResearchManager(rm: any)
	researchManagerRef = rm
end

function BuildingManager.setForestManager(fm: any)
	forestManagerRef = fm
end

function BuildingManager.setTerrainManager(tm: any)
	terrainManagerRef = tm
end

-- ── Destruction VFX (server-side) ────────────────────────────────────────────

spawnDestructionVFX = function(pos: Vector3)
	-- 3D destruction sound
	local soundPart            = Instance.new("Part")
	soundPart.Anchored         = true
	soundPart.CanCollide       = false
	soundPart.CanTouch         = false
	soundPart.Transparency     = 1
	soundPart.Size             = Vector3.new(1, 1, 1)
	soundPart.CastShadow       = false
	soundPart.Position         = pos
	soundPart.Parent           = workspace
	local snd                  = Instance.new("Sound")
	snd.SoundId                = "rbxassetid://117211977307268"
	snd.Volume                 = 1.1
	snd.RollOffMaxDistance     = 200
	snd.RollOffMinDistance     = 12
	snd.Parent                 = soundPart
	snd:Play()
	Debris:AddItem(soundPart, 6)

	-- Primary explosion
	local exp              = Instance.new("Explosion")
	exp.BlastRadius        = 0
	exp.BlastPressure      = 0
	exp.Position           = pos
	exp.ExplosionType      = Enum.ExplosionType.NoCraters
	exp.Parent             = workspace

	-- Secondary offset explosion
	task.delay(0.08, function()
		local exp2          = Instance.new("Explosion")
		exp2.BlastRadius    = 0
		exp2.BlastPressure  = 0
		exp2.Position       = pos + Vector3.new(rng:NextNumber(-2.5, 2.5), 1.5, rng:NextNumber(-2.5, 2.5))
		exp2.ExplosionType  = Enum.ExplosionType.NoCraters
		exp2.Parent         = workspace
	end)

	-- Tertiary small explosion
	task.delay(0.18, function()
		local exp3          = Instance.new("Explosion")
		exp3.BlastRadius    = 0
		exp3.BlastPressure  = 0
		exp3.Position       = pos + Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(0, 2), rng:NextNumber(-3, 3))
		exp3.ExplosionType  = Enum.ExplosionType.NoCraters
		exp3.Parent         = workspace
	end)

	-- Flash light burst
	local flashPart            = Instance.new("Part")
	flashPart.Anchored         = true
	flashPart.CanCollide       = false
	flashPart.CanTouch         = false
	flashPart.CastShadow       = false
	flashPart.Transparency     = 1
	flashPart.Size             = Vector3.new(1, 1, 1)
	flashPart.Position         = pos + Vector3.new(0, 3, 0)
	flashPart.Parent           = workspace
	local light                = Instance.new("PointLight")
	light.Brightness           = 10
	light.Range                = 50
	light.Color                = Color3.fromRGB(255, 150, 50)
	light.Parent               = flashPart
	Debris:AddItem(flashPart, 0.45)

	-- Debris chunks
	local debrisColors = {
		Color3.fromRGB(120, 110, 100),
		Color3.fromRGB(80,  75,  70),
		Color3.fromRGB(60,  55,  50),
	}
	for _ = 1, 10 do
		local d            = Instance.new("Part")
		d.Anchored         = false
		d.CanCollide       = false
		d.CanTouch         = false
		d.CastShadow       = false
		d.Size             = Vector3.new(
			rng:NextNumber(0.25, 0.9),
			rng:NextNumber(0.25, 0.9),
			rng:NextNumber(0.25, 0.9)
		)
		d.Color            = debrisColors[rng:NextInteger(1, #debrisColors)]
		d.Material         = Enum.Material.SmoothPlastic
		d.Position         = pos + Vector3.new(
			rng:NextNumber(-2, 2),
			rng:NextNumber(0.5, 2.5),
			rng:NextNumber(-2, 2)
		)
		d.Parent           = workspace
		d.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-14, 14),
			rng:NextNumber(9, 22),
			rng:NextNumber(-14, 14)
		)
		d.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6)
		)
		Debris:AddItem(d, rng:NextNumber(1.5, 3.0))
	end
end

-- ── Worm burst VFX (server-side) ─────────────────────────────────────────────

spawnWormBurstVFX = function(pos: Vector3)
	-- Burst sound (reuses the building-destruction sound)
	local soundPart            = Instance.new("Part")
	soundPart.Anchored         = true
	soundPart.CanCollide       = false
	soundPart.CanTouch         = false
	soundPart.Transparency     = 1
	soundPart.Size             = Vector3.new(1, 1, 1)
	soundPart.CastShadow       = false
	soundPart.Position         = pos
	soundPart.Parent           = workspace
	local snd                  = Instance.new("Sound")
	snd.SoundId                = "rbxassetid://117211977307268"
	snd.Volume                 = 1.3
	snd.RollOffMaxDistance     = 220
	snd.RollOffMinDistance     = 14
	snd.Parent                 = soundPart
	snd:Play()
	Debris:AddItem(soundPart, 6)

	-- Earthen dirt chunks hurled outward
	local dirtColors = {
		Color3.fromRGB(90,  60, 30),
		Color3.fromRGB(70,  45, 20),
		Color3.fromRGB(110, 80, 40),
		Color3.fromRGB(55,  85, 20),
	}
	for _ = 1, 18 do
		local d            = Instance.new("Part")
		d.Anchored         = false
		d.CanCollide       = false
		d.CanTouch         = false
		d.CastShadow       = false
		d.Size             = Vector3.new(
			rng:NextNumber(0.3, 1.2),
			rng:NextNumber(0.3, 1.2),
			rng:NextNumber(0.3, 1.2)
		)
		d.Color            = dirtColors[rng:NextInteger(1, #dirtColors)]
		d.Material         = Enum.Material.SmoothPlastic
		d.Position         = pos + Vector3.new(
			rng:NextNumber(-3, 3),
			rng:NextNumber(0.5, 3.0),
			rng:NextNumber(-3, 3)
		)
		d.Parent           = workspace
		d.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-20, 20),
			rng:NextNumber(14, 30),
			rng:NextNumber(-20, 20)
		)
		d.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-9, 9),
			rng:NextNumber(-9, 9),
			rng:NextNumber(-9, 9)
		)
		Debris:AddItem(d, rng:NextNumber(1.5, 3.5))
	end
end

-- ── Lamprey egg hatch VFX (server-side) ──────────────────────────────────────
spawnEggHatchVFX = function(pos: Vector3)
	-- Expanding green flash that fades out
	local flash            = Instance.new("Part")
	flash.Shape            = Enum.PartType.Ball
	flash.Size             = Vector3.new(2, 2, 2)
	flash.Position         = pos
	flash.Color            = Color3.fromRGB(150, 230, 90)
	flash.Material         = Enum.Material.Neon
	flash.Anchored         = true
	flash.CanCollide       = false
	flash.CanQuery         = false
	flash.CastShadow       = false
	flash.Transparency     = 0.1
	flash.Parent           = workspace
	TweenService:Create(flash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = Vector3.new(9, 9, 9),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.6)

	-- Eggshell shards + slime flung outward
	local shardColors = {
		Color3.fromRGB(150, 210, 90),
		Color3.fromRGB(110, 170, 60),
		Color3.fromRGB(90, 120, 50),
	}
	for _ = 1, 12 do
		local s            = Instance.new("Part")
		s.Anchored         = false
		s.CanCollide       = false
		s.CanTouch         = false
		s.CastShadow       = false
		s.Size             = Vector3.new(
			rng:NextNumber(0.3, 0.9),
			rng:NextNumber(0.3, 0.9),
			rng:NextNumber(0.3, 0.9)
		)
		s.Color            = shardColors[rng:NextInteger(1, #shardColors)]
		s.Material         = Enum.Material.SmoothPlastic
		s.Position         = pos + Vector3.new(
			rng:NextNumber(-1.5, 1.5),
			rng:NextNumber(0.5, 2.5),
			rng:NextNumber(-1.5, 1.5)
		)
		s.Parent           = workspace
		s.AssemblyLinearVelocity = Vector3.new(
			rng:NextNumber(-16, 16),
			rng:NextNumber(10, 22),
			rng:NextNumber(-16, 16)
		)
		s.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8)
		)
		Debris:AddItem(s, rng:NextNumber(1.2, 2.5))
	end
end

-- ── Launcher tentacle (rally-upgraded nests) ────────────────────────────────
-- A single large tentacle sprouting from the centre of an upgraded nest. It aims
-- at the rally point and whips toward it to fling each egg in that direction.
local LAUNCHER_M    = 5      -- spine segments
local LAUNCHER_H    = 16     -- length (larger than the decorative tentacles)
local LAUNCHER_BT   = 2.3    -- base thickness
local LAUNCHER_TT   = 0.9    -- tip thickness
local LAUNCHER_COL  = Color3.fromRGB(96, 32, 66)
local LAUNCHER_REST = 0.55   -- rest lean (radians) toward the aim direction

-- Where an upgraded nest's launcher tentacle sprouts from (centre, near the Core).
local function launcherBase(data: BuildingData): Vector3
	local p = data.base.Position
	return Vector3.new(p.X, p.Y - buildingSize("LampreyNest").Y / 2 + 1.8, p.Z)
end

-- Curved spine of the launcher: rises from `basePos`, bending toward the horizontal
-- `aimDir` by `lean` radians (negative leans back, away from aim).
local function launcherSpine(basePos: Vector3, aimDir: Vector3, lean: number): { Vector3 }
	local segLen = LAUNCHER_H / LAUNCHER_M
	local pts    = { basePos }
	local pos    = basePos
	for j = 1, LAUNCHER_M do
		local s    = j / LAUNCHER_M
		local bend = (s ^ 1.7) * lean
		local dir  = (Vector3.yAxis * math.cos(bend) + aimDir * math.sin(bend)).Unit
		pos = pos + dir * segLen
		pts[j + 1] = pos
	end
	return pts
end

-- Position the launcher parts (found by name) along the spine. Returns tip pos + dir.
local function layoutNestLauncher(model: Instance, basePos: Vector3, aimDir: Vector3, lean: number): (Vector3, Vector3)
	local pts = launcherSpine(basePos, aimDir, lean)
	for j = 1, LAUNCHER_M do
		local segP = model:FindFirstChild("Launcher_Seg" .. j) :: BasePart?
		if segP then
			local th = LAUNCHER_BT + (LAUNCHER_TT - LAUNCHER_BT) * ((j - 1) / LAUNCHER_M)
			UnitVisuals.orientYBetween(segP, pts[j], pts[j + 1], th)
		end
		if j < LAUNCHER_M then
			local knot = model:FindFirstChild("Launcher_Knot" .. j) :: BasePart?
			if knot then
				local th = LAUNCHER_BT + (LAUNCHER_TT - LAUNCHER_BT) * (j / LAUNCHER_M)
				knot.Size   = Vector3.new(th, th, th)
				knot.CFrame = CFrame.new(pts[j + 1])
			end
		end
	end
	local tipPos = pts[LAUNCHER_M + 1]
	local tipDir = (pts[LAUNCHER_M + 1] - pts[LAUNCHER_M]).Unit
	local tip    = model:FindFirstChild("Launcher_Tip") :: BasePart?
	if tip then tip.CFrame = CFrame.new(tipPos) end
	return tipPos, tipDir
end

-- Build the launcher parts under the nest model (idempotent; called on upgrade).
local function buildNestLauncher(model: Instance, basePos: Vector3, aimDir: Vector3)
	if model:FindFirstChild("Launcher_Seg1") then return end
	local function lp(name: string, shape: Enum.PartType?): BasePart
		local p      = Instance.new("Part")
		p.Name       = name
		if shape then (p :: any).Shape = shape end
		p.Color      = LAUNCHER_COL
		p.Material   = Enum.Material.SmoothPlastic
		p.Size       = Vector3.new(1, 1, 1)
		p.Anchored   = true
		p.CanCollide = false
		p.CanQuery   = false
		p.CastShadow = false
		p.Parent     = model
		return p
	end
	for j = 1, LAUNCHER_M do lp("Launcher_Seg" .. j) end
	for j = 1, LAUNCHER_M - 1 do lp("Launcher_Knot" .. j, Enum.PartType.Ball) end
	local tip = lp("Launcher_Tip", Enum.PartType.Ball)
	tip.Size  = Vector3.new(1.9, 1.9, 1.9)
	tip.Color = Color3.fromRGB(66, 22, 46)
	layoutNestLauncher(model, basePos, aimDir, LAUNCHER_REST)
end

-- Animate the launcher whipping toward `aimDir` and fling `egg` to `target`.
-- Blocks (stepping via task.wait) until the egg reaches the target.
local function throwNestLauncher(model: Instance, basePos: Vector3, aimDir: Vector3, egg: BasePart, eggFull: Vector3, target: Vector3)
	local WIND, WHIP, FLIGHT      = 0.18, 0.16, 0.62
	local restLean, backLean, whipLean = LAUNCHER_REST, -0.55, 1.75

	-- Seat the egg on the tip before the windup so it doesn't flash at the Core.
	local seatPos = layoutNestLauncher(model, basePos, aimDir, restLean)
	if egg.Parent then egg.Position = seatPos; egg.Size = eggFull * 0.55 end

	-- Windup: rear back, egg riding the tip
	local t = 0
	while t < WIND do
		t += task.wait()
		if not model.Parent then return end
		local lean   = restLean + (backLean - restLean) * math.clamp(t / WIND, 0, 1)
		local tipPos = layoutNestLauncher(model, basePos, aimDir, lean)
		if egg.Parent then egg.Position = tipPos end
	end

	-- Whip forward toward the aim
	t = 0
	local releasePos = seatPos
	while t < WHIP do
		t += task.wait()
		if not model.Parent then return end
		local lean = backLean + (whipLean - backLean) * math.clamp(t / WHIP, 0, 1)
		releasePos = layoutNestLauncher(model, basePos, aimDir, lean)
		if egg.Parent then egg.Position = releasePos; egg.Size = eggFull * 0.75 end
	end

	-- Flight: arc the egg from the release point to the target while the tentacle
	-- settles back to its loaded rest pose.
	local horiz = Vector3.new(target.X - releasePos.X, 0, target.Z - releasePos.Z).Magnitude
	local apex  = Vector3.new((releasePos.X + target.X) / 2, math.max(releasePos.Y, target.Y) + 5 + horiz * 0.12, (releasePos.Z + target.Z) / 2)
	t = 0
	while t < FLIGHT do
		t += task.wait()
		if egg.Parent == nil then return end
		local k = math.clamp(t / FLIGHT, 0, 1)
		egg.Position = releasePos:Lerp(apex, k):Lerp(apex:Lerp(target, k), k)
		egg.Size     = eggFull
		layoutNestLauncher(model, basePos, aimDir, whipLean + (restLean - whipLean) * k)
		if not model.Parent then return end
	end
	if egg.Parent then egg.Position = target end
	layoutNestLauncher(model, basePos, aimDir, restLean)
end

-- ── Lamprey egg production (server-side, one task per egg) ───────────────────
-- Pulses the nest's tubes, ejects an egg to a random spot nearby, lets it
-- incubate on its own timer, then hatches it into `unitType` ("Lamprey" |
-- "Hagfish"). Lamprey eggs glow green; Hagfish eggs glow reddish-purple. The
-- caller must already have reserved a slot (incremented nestEggs[nestId]).
produceLampreyEgg = function(nestId: string, player: any, unitType: string)
	-- Per-creature egg glow: Lamprey green, Hagfish reddish-purple, Broodmother violet.
	local eggColor, eggLightColor
	if unitType == "Hagfish" then
		eggColor, eggLightColor = Color3.fromRGB(150, 60, 120), Color3.fromRGB(150, 50, 120)
	elseif unitType == "Broodmother" then
		eggColor, eggLightColor = Color3.fromRGB(140, 90, 230), Color3.fromRGB(120, 70, 235)
	else
		eggColor, eggLightColor = Color3.fromRGB(150, 230, 90), Color3.fromRGB(120, 230, 70)
	end
	local data = buildingData[nestId]
	if not data then
		if nestEggs[nestId] then nestEggs[nestId] = math.max(0, nestEggs[nestId] - 1) end
		return
	end
	local model = buildingsFolder:FindFirstChild(nestId)
	if not model then
		nestEggs[nestId] = math.max(0, (nestEggs[nestId] or 1) - 1)
		return
	end

	local basePos  = data.base.Position
	local core     = model:FindFirstChild("Core") :: BasePart?
	local startPos = core and core.Position or (basePos + Vector3.new(0, data.base.Size.Y, 0))

	local halfX    = buildingSize("LampreyNest").X / 2
	local EGG_FULL = Vector3.new(3, 3.8, 3)
	-- Eggs must rest on whichever terrain tier they land on — a fixed world Y left
	-- them buried below a raised nest (looking like nothing spawned). Resolve the
	-- settle height per-XZ from the real terrain surface.
	local function settleYAt(x: number, z: number): number
		local surf = terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z) or 0
		return surf + EGG_FULL.Y / 2
	end

	-- Where the egg settles. With the rally upgrade the nest LAUNCHES the egg to the
	-- player's rally point (scattered within a spread radius); otherwise it settles
	-- around the nest's own footprint. Either way, reject spots that would overlap an
	-- egg already resting on the ground for this nest so eggs never stack.
	local centerX, centerZ, minR, maxR
	if data.rallyUpgrade and data.rallyPoint then
		centerX, centerZ = (data.rallyPoint :: Vector3).X, (data.rallyPoint :: Vector3).Z
		minR, maxR       = 0, Config.LAMPREY_NEST_EGG_SPREAD
	else
		centerX, centerZ = basePos.X, basePos.Z
		minR, maxR       = halfX + 2, halfX + 6
	end

	local GAP = Config.LAMPREY_NEST_EGG_GAP
	local function overlapsEgg(x: number, z: number): boolean
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Name:match("^Egg_") then
				local dx, dz = child.Position.X - x, child.Position.Z - z
				if dx * dx + dz * dz < GAP * GAP then return true end
			end
		end
		return false
	end

	local target: Vector3
	do
		local px, pz = centerX, centerZ
		for _ = 1, 14 do
			local a = rng:NextNumber(0, math.pi * 2)
			local r = if maxR > minR then minR + math.sqrt(rng:NextNumber()) * (maxR - minR) else minR
			px, pz  = centerX + math.cos(a) * r, centerZ + math.sin(a) * r
			if not overlapsEgg(px, pz) then break end
		end
		target = Vector3.new(px, settleYAt(px, pz), pz)
	end

	-- Egg (parented to the nest model so it replicates and the panel can count it)
	nestEggCounter += 1
	local egg           = Instance.new("Part")
	egg.Name            = "Egg_" .. nestEggCounter
	egg.Shape           = Enum.PartType.Ball
	egg.Size            = EGG_FULL * 0.4
	egg.Position        = startPos
	egg.Color           = eggColor
	egg.Material        = Enum.Material.Neon
	egg.Anchored        = true
	egg.CanCollide      = false
	egg.CanQuery        = false
	egg.CastShadow      = false
	egg.Transparency    = 0.1
	egg.Parent          = model
	local eggLight      = Instance.new("PointLight")
	eggLight.Color      = eggLightColor
	eggLight.Brightness = 2
	eggLight.Range      = 10
	eggLight.Parent     = egg

	-- ── Eject: pulse the nest core + egg tips, then arc the egg out to its spot ──
	-- The pulse grows a part and settles it back. We capture each part's ORIGINAL
	-- size/transparency once (stored as an attribute) and always tween toward those
	-- constants — so when several eggs are produced at once the overlapping pulses
	-- converge back to the original size instead of compounding larger each time.
	local halfEject = math.max(0.05, Config.LAMPREY_NEST_EJECT_TIME / 2)
	local upInfo    = TweenInfo.new(halfEject, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local downInfo  = TweenInfo.new(halfEject, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	local function pulsePart(part: BasePart, factor: number, addY: number?)
		local base = part:GetAttribute("PulseBase")
		if typeof(base) ~= "Vector3" then
			base = part.Size
			part:SetAttribute("PulseBase", base)
		end
		local baseT = part:GetAttribute("PulseBaseT")
		if typeof(baseT) ~= "number" then
			baseT = part.Transparency
			part:SetAttribute("PulseBaseT", baseT)
		end
		local enlarged = if addY then (base :: Vector3) + Vector3.new(0, addY, 0) else (base :: Vector3) * factor
		TweenService:Create(part, upInfo, { Size = enlarged, Transparency = 0 }):Play()
		task.delay(halfEject, function()
			if part.Parent then
				TweenService:Create(part, downInfo, { Size = base, Transparency = baseT }):Play()
			end
		end)
	end

	if core then pulsePart(core, 1.3) end
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child.Name:match("^Tube_") then
			pulsePart(child, 1.0, 1.6)
		elseif child:IsA("BasePart") and child.Name:match("^TubeTip_") then
			pulsePart(child, 1.6)
		end
	end

	-- Deliver the egg to its settle spot. An upgraded nest's launcher tentacle whips
	-- toward the target and flings the egg in that direction; an un-upgraded nest just
	-- arcs the egg up out of the Core and down. Either way the egg ends on `target`.
	if data.rallyUpgrade and model:FindFirstChild("Launcher_Seg1") then
		-- Serialize throws so several eggs produced at once are flung one after the
		-- other instead of fighting over the single shared launcher tentacle.
		while nestLauncherBusy[nestId] do
			task.wait()
			if egg.Parent == nil then return end
		end
		nestLauncherBusy[nestId] = true
		local lbase = launcherBase(data)
		local aim   = Vector3.new(target.X - lbase.X, 0, target.Z - lbase.Z)
		aim = if aim.Magnitude > 0.1 then aim.Unit else Vector3.new(0, 0, 1)
		throwNestLauncher(model, lbase, aim, egg, EGG_FULL, target)
		nestLauncherBusy[nestId] = nil
		if egg.Parent == nil then return end
	else
		local throwDist = (Vector3.new(target.X, 0, target.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
		local apex = Vector3.new(
			(startPos.X + target.X) / 2,
			math.max(startPos.Y, target.Y) + 3 + throwDist * 0.18,
			(startPos.Z + target.Z) / 2
		)
		TweenService:Create(egg, TweenInfo.new(halfEject, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = apex, Size = EGG_FULL,
		}):Play()
		task.wait(halfEject)
		if egg.Parent == nil then return end
		TweenService:Create(egg, TweenInfo.new(halfEject, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = target,
		}):Play()
		task.wait(halfEject)
		if egg.Parent == nil then return end
	end
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(target, target, "LampreyEggLand")

	-- ── Incubate: the egg breathes green until it hatches ─────────────────────
	TweenService:Create(egg,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Size = EGG_FULL * 1.12, Transparency = 0,
		}):Play()
	TweenService:Create(eggLight,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Brightness = 5,
		}):Play()

	task.wait(Config.LAMPREY_EGG_INCUBATION)

	-- ── Hatch ─────────────────────────────────────────────────────────────────
	if egg.Parent == nil then return end          -- nest destroyed mid-incubation
	if not buildingData[nestId] then               -- nest gone but egg lingered
		egg:Destroy()
		return
	end
	local hatchPos = egg.Position
	egg:Destroy()
	spawnEggHatchVFX(hatchPos)
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(hatchPos, hatchPos, "LampreyEggHatch")
	if unitManagerRef then
		unitManagerRef.spawnUnitNow(player, Vector3.new(hatchPos.X, 0, hatchPos.Z), unitType)
	end
	nestEggs[nestId] = math.max(0, (nestEggs[nestId] or 1) - 1)
end

-- ── Hollowed Mother egg spit (server-side, one task per egg) ─────────────────
-- Inspired by the nest: the Mother spits an egg into the area in FRONT of it (the
-- flipped creature faces +Z / the camera), where it incubates under a progress bar
-- and then hatches into `unitType`. The cost is already spent by the TrainFromMother
-- handler, so this never charges. Multiple eggs can be in flight at once.
local motherEggCounter = 0
function BuildingManager.produceMotherEgg(player: any, ccId: string, unitType: string)
	local data = buildingData[ccId]
	if not data then return end
	local model = buildingsFolder:FindFirstChild(ccId)
	if not model then return end
	local base    = data.base
	local basePos = base.Position
	local halfX   = Config.COMMAND_CENTER_SIZE.X / 2

	-- "Front" = the way the flipped creature's head points. buildMotherDecor is built
	-- flipped 180°, so the head faces -base.LookVector (robust to any base rotation).
	local fwd = -base.CFrame.LookVector
	fwd = Vector3.new(fwd.X, 0, fwd.Z)
	fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, 1)

	local EGG_FULL = Vector3.new(2.6, 3.2, 2.6)
	local function settleYAt(x: number, z: number): number
		local surf = terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z) or 0
		return surf + EGG_FULL.Y / 2
	end
	local function overlapsEgg(x: number, z: number): boolean
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Name:match("^MotherEgg_") then
				local dx, dz = child.Position.X - x, child.Position.Z - z
				if dx * dx + dz * dz < 25 then return true end   -- ~5-stud gap
			end
		end
		return false
	end

	-- Settle spot: an arc within ±55° of straight ahead, just outside the footprint.
	local minR, maxR = halfX + 4, halfX + 13
	local px, pz = basePos.X + fwd.X * minR, basePos.Z + fwd.Z * minR
	for _ = 1, 14 do
		local a    = (rng:NextNumber() - 0.5) * math.rad(110)
		local ca, sa = math.cos(a), math.sin(a)
		local dir  = Vector3.new(fwd.X * ca - fwd.Z * sa, 0, fwd.X * sa + fwd.Z * ca)
		local r    = minR + math.sqrt(rng:NextNumber()) * (maxR - minR)
		px, pz = basePos.X + dir.X * r, basePos.Z + dir.Z * r
		if not overlapsEgg(px, pz) then break end
	end
	local target   = Vector3.new(px, settleYAt(px, pz), pz)
	local startPos = basePos + Vector3.new(0, base.Size.Y * 0.4, 0) + fwd * (halfX * 0.5)

	-- Egg (parented to the CC model so it replicates + the overlap check can see it).
	motherEggCounter += 1
	local egg           = Instance.new("Part")
	egg.Name            = "MotherEgg_" .. motherEggCounter
	egg.Shape           = Enum.PartType.Ball
	egg.Size            = EGG_FULL * 0.4
	egg.Position        = startPos
	egg.Color           = Color3.fromRGB(255, 120, 60)   -- warm orange (Hagfish-eye glow)
	egg.Material        = Enum.Material.Neon
	egg.Anchored        = true
	egg.CanCollide      = false
	egg.CanQuery        = false
	egg.CastShadow      = false
	egg.Transparency    = 0.1
	egg.Parent          = model
	local eggLight      = Instance.new("PointLight")
	eggLight.Color      = Color3.fromRGB(255, 140, 70)
	eggLight.Brightness = 3
	eggLight.Range      = 12
	eggLight.Parent     = egg

	-- Progress bar floating on top of the egg.
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "EggProgress"
	bb.Size             = UDim2.fromOffset(48, 7)
	bb.StudsOffset      = Vector3.new(0, EGG_FULL.Y * 0.95, 0)
	bb.AlwaysOnTop      = true
	bb.LightInfluence   = 0
	bb.MaxDistance      = 240
	bb.Enabled          = false   -- shown once the egg lands and incubation begins
	bb.Parent           = egg
	local barBg         = Instance.new("Frame")
	barBg.Size          = UDim2.fromScale(1, 1)
	barBg.BackgroundColor3 = Color3.fromRGB(12, 8, 16)
	barBg.BackgroundTransparency = 0.25
	barBg.BorderSizePixel = 0
	barBg.Parent        = bb
	local bgCorner      = Instance.new("UICorner"); bgCorner.CornerRadius = UDim.new(1, 0); bgCorner.Parent = barBg
	local barStroke     = Instance.new("UIStroke"); barStroke.Color = Color3.fromRGB(0, 0, 0); barStroke.Thickness = 1; barStroke.Transparency = 0.35; barStroke.Parent = barBg
	local fill          = Instance.new("Frame")
	fill.Size           = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 150, 70)
	fill.BorderSizePixel = 0
	fill.Parent         = barBg
	local fillCorner    = Instance.new("UICorner"); fillCorner.CornerRadius = UDim.new(1, 0); fillCorner.Parent = fill

	-- Spit: arc the egg up out of the Mother's mouth and down onto its settle spot.
	local throwDist = (Vector3.new(target.X, 0, target.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
	local apex      = Vector3.new(
		(startPos.X + target.X) / 2,
		math.max(startPos.Y, target.Y) + 4 + throwDist * 0.2,
		(startPos.Z + target.Z) / 2
	)
	local halfEject = 0.28
	TweenService:Create(egg, TweenInfo.new(halfEject, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = apex, Size = EGG_FULL,
	}):Play()
	task.wait(halfEject)
	if egg.Parent == nil then return end
	TweenService:Create(egg, TweenInfo.new(halfEject, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = target,
	}):Play()
	task.wait(halfEject)
	if egg.Parent == nil then return end
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(target, target, "LampreyEggLand")

	-- Settled: tell clients to sprout the enveloping tentacles from the egg's base and
	-- climb them up, hugging + pulsing with the egg (animated client-side in MotherEggBody).
	RemoteHandler.get(Config.REMOTES.MotherEggLand):FireAllClients(egg)

	-- Incubate: the egg breathes while the progress bar fills over the incubation.
	bb.Enabled = true
	TweenService:Create(egg,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = EGG_FULL * 1.12 }):Play()
	TweenService:Create(eggLight,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Brightness = 5 }):Play()
	TweenService:Create(fill,
		TweenInfo.new(Config.MOTHER_EGG_INCUBATION, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }):Play()

	task.wait(Config.MOTHER_EGG_INCUBATION)

	-- Hatch.
	if egg.Parent == nil then return end
	if not buildingData[ccId] then egg:Destroy(); return end
	local hatchPos = egg.Position
	egg:Destroy()
	spawnEggHatchVFX(hatchPos)
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(hatchPos, hatchPos, "LampreyEggHatch")
	if unitManagerRef then
		unitManagerRef.spawnUnitNow(player, Vector3.new(hatchPos.X, 0, hatchPos.Z), unitType)
	end
end

-- ── Hollowed Mother "Egg Sacs" upgrade ──────────────────────────────────────────
-- Slot order for the planted nests: the first pair sits on the Mother's two flanks
-- (±X), each later pair fills in around the ring so purchases visibly add nests.
local EGGSAC_NEST_ANGLES_DEG = { 0, 180, 90, 270, 45, 225, 135, 315 }

-- World position (on the ground) of nest slot `slotIndex` around Mother `base`.
local function eggSacNestSlotPos(base: BasePart, slotIndex: number): Vector3
	local center = base.Position
	local half   = Config.COMMAND_CENTER_SIZE.X / 2
	local r      = half + 8
	local ang    = math.rad(EGGSAC_NEST_ANGLES_DEG[slotIndex] or (slotIndex * 47))
	local x, z   = center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r
	local surf   = terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z)
		or (center.Y - Config.COMMAND_CENTER_SIZE.Y / 2)
	return Vector3.new(x, surf, z)
end

-- Plant (build + record) the nests for slot indices (fromSlot+1 .. toSlot) around a Mother.
local function plantEggSacNests(model: Model, base: BasePart, ccId: string, fromSlot: number, toSlot: number)
	local nests = eggSacNests[ccId]
	if not nests then nests = {}; eggSacNests[ccId] = nests end
	for slot = fromSlot + 1, toSlot do
		local pos = eggSacNestSlotPos(base, slot)
		nests[slot] = pos
		UnitVisuals.buildMotherNestDecor(model, CFrame.new(pos), base.BrickColor, true)
	end
end

-- Autospawn: settle an Embryo egg in `nestPos`, incubate it, then hatch an Embryo tracked
-- against the Mother (reusing the Deployer alive-count bookkeeping keyed by the Mother
-- id). `eggSacInFlight[ccId]` is always decremented when this finishes, aborted or not.
local function produceEggSacEmbryo(ccId: string, player: any, nestPos: Vector3)
	local function release()
		eggSacInFlight[ccId] = math.max(0, (eggSacInFlight[ccId] or 1) - 1)
	end

	local model = buildingsFolder:FindFirstChild(ccId)
	if not model then release(); return end

	local EGG_FULL = Vector3.new(2.2, 2.7, 2.2)
	motherEggCounter += 1
	local egg           = Instance.new("Part")
	egg.Name            = "EggSacEgg_" .. motherEggCounter
	egg.Shape           = Enum.PartType.Ball
	egg.Size            = EGG_FULL * 0.3
	egg.Position        = nestPos + Vector3.new(0, EGG_FULL.Y * 0.7, 0)
	egg.Color           = Color3.fromRGB(255, 120, 60)
	egg.Material        = Enum.Material.Neon
	egg.Anchored        = true
	egg.CanCollide      = false
	egg.CanQuery        = false
	egg.CastShadow      = false
	egg.Transparency    = 0.1
	egg.Parent          = model
	local eggLight      = Instance.new("PointLight")
	eggLight.Color      = Color3.fromRGB(255, 140, 70)
	eggLight.Brightness = 2.5
	eggLight.Range      = 10
	eggLight.Parent     = egg

	-- Progress bar floating over the egg.
	local bb          = Instance.new("BillboardGui")
	bb.Name           = "EggProgress"
	bb.Size           = UDim2.fromOffset(42, 6)
	bb.StudsOffset    = Vector3.new(0, EGG_FULL.Y * 0.95, 0)
	bb.AlwaysOnTop    = true
	bb.LightInfluence = 0
	bb.MaxDistance    = 220
	bb.Parent         = egg
	local barBg       = Instance.new("Frame")
	barBg.Size        = UDim2.fromScale(1, 1)
	barBg.BackgroundColor3 = Color3.fromRGB(12, 8, 16)
	barBg.BackgroundTransparency = 0.25
	barBg.BorderSizePixel = 0
	barBg.Parent      = bb
	local bgCorner    = Instance.new("UICorner"); bgCorner.CornerRadius = UDim.new(1, 0); bgCorner.Parent = barBg
	local fill        = Instance.new("Frame")
	fill.Size         = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 150, 70)
	fill.BorderSizePixel = 0
	fill.Parent       = barBg
	local fillCorner  = Instance.new("UICorner"); fillCorner.CornerRadius = UDim.new(1, 0); fillCorner.Parent = fill

	-- Pop the egg up out of the sac + breathe while it fills.
	TweenService:Create(egg, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = EGG_FULL }):Play()
	TweenService:Create(egg,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = EGG_FULL * 1.12 }):Play()
	TweenService:Create(fill,
		TweenInfo.new(Config.MOTHER_EGGSAC_INCUBATION, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }):Play()

	task.wait(Config.MOTHER_EGGSAC_INCUBATION)

	if egg.Parent == nil then release(); return end
	local hatchPos = egg.Position
	egg:Destroy()
	spawnEggHatchVFX(hatchPos)
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(hatchPos, hatchPos, "LampreyEggHatch")
	if buildingData[ccId] and unitManagerRef then
		unitManagerRef.spawnForDeployer(ccId, player, Vector3.new(hatchPos.X, 0, hatchPos.Z), "Embryo")
	end
	release()
end

-- Purchase one Egg Sacs upgrade for `player`'s Mother `ccId`: charges the cost, bumps
-- the level, plants the new pair of nests, and stamps the level on the model (an
-- attribute the client MotherPanel reads to render the tile). Returns whether it bought.
function BuildingManager.upgradeEggSacsForPlayer(player: any, ccId: string): boolean
	local data = buildingData[ccId]
	if not data or data.buildingType ~= "CommandCenter" then return false end
	if data.owner ~= player then return false end
	if data.isConstructing then return false end
	if not isHollowed(player) then return false end

	local level = eggSacLevel[ccId] or 0
	if level >= Config.MOTHER_EGGSAC_MAX_LEVEL then return false end
	if not resourceManagerRef or not resourceManagerRef.spend(player, Config.MOTHER_EGGSAC_COST) then return false end

	local newLevel = level + 1
	eggSacLevel[ccId] = newLevel

	local model = buildingsFolder:FindFirstChild(ccId) :: Model?
	if model then
		plantEggSacNests(model, data.base, ccId,
			level * Config.MOTHER_EGGSAC_NESTS_PER_LEVEL,
			newLevel * Config.MOTHER_EGGSAC_NESTS_PER_LEVEL)
		model:SetAttribute("EggSacLevel", newLevel)
	end
	return true
end

-- ── Server-callable production (shared by remote handlers + AI swarm bots) ──────
-- Births one egg from `player`'s Lamprey Nest. Returns true if a slot was
-- reserved and production started. Safe for AI (fake) players — uses FireAllClients.
function BuildingManager.requestNestEgg(player: any, nestId: string, unitType: string): boolean
	local kind = if unitType == "Hagfish" then "Hagfish"
		elseif unitType == "Broodmother" then "Broodmother"
		else "Lamprey"
	local cost = if kind == "Hagfish" then Config.HAGFISH_EGG_COST
		elseif kind == "Broodmother" then Config.BROODMOTHER_EGG_COST
		else Config.LAMPREY_EGG_COST
	local data = buildingData[nestId]
	if not data or data.buildingType ~= "LampreyNest" then return false end
	if data.owner ~= player then return false end
	if data.isConstructing then return false end
	if (nestEggs[nestId] or 0) >= Config.LAMPREY_NEST_MAX_EGGS then return false end
	if not resourceManagerRef or resourceManagerRef.get(player) < cost then return false end

	resourceManagerRef.spend(player, cost)
	nestEggs[nestId] = (nestEggs[nestId] or 0) + 1
	task.spawn(produceLampreyEgg, nestId, player, kind)
	return true
end

-- Spawns one CreepySoldier from `player`'s Creepy Blob (respects the per-blob
-- cooldown + cost). Safe for AI players — the BlobUpdate UI ping is skipped for them.
function BuildingManager.requestBlobSoldier(player: any, blobId: string): boolean
	local data = buildingData[blobId]
	if not data or data.buildingType ~= "CreepyBlob" then return false end
	if data.owner ~= player then return false end
	if data.isConstructing then return false end

	local now = os.clock()
	if (blobCooldowns[blobId] or 0) > now then return false end
	if not resourceManagerRef or resourceManagerRef.get(player) < Config.BLOB_SOLDIER_COST then return false end
	resourceManagerRef.spend(player, Config.BLOB_SOLDIER_COST)

	if unitManagerRef then
		local blobPos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
		local angle   = math.random() * math.pi * 2
		local offset  = Vector3.new(math.cos(angle) * 6, 0, math.sin(angle) * 6)
		unitManagerRef.spawnUnitNow(player, blobPos + offset, "CreepySoldier")
	end

	blobCooldowns[blobId] = now + Config.BLOB_SOLDIER_COOLDOWN
	-- UI cooldown ping only goes to real players (AI players are fake tables).
	if (player.UserId or 0) > 0 then
		RemoteHandler.get(Config.REMOTES.BlobUpdate):FireClient(player, blobId, Config.BLOB_SOLDIER_COOLDOWN)
		task.delay(Config.BLOB_SOLDIER_COOLDOWN, function()
			if buildingData[blobId] then
				RemoteHandler.get(Config.REMOTES.BlobUpdate):FireClient(player, blobId, 0)
			end
		end)
	end
	return true
end

function BuildingManager.damage(id: string, amount: number)
	local data = buildingData[id]
	if not data then return end
	data.hp = math.max(0, data.hp - amount)
	applyHP(data, true)

	-- Map ping: this part of the owner's base is under attack (throttled per region).
	if data.hp > 0 then
		AlertManager.report(data.owner, data.base.Position, "base")
	end

	-- Extra banner notification for the Command Center specifically (throttled)
	if data.buildingType == "CommandCenter" and data.hp > 0 then
		local uid  = data.owner.UserId
		local now  = os.clock()
		if (ccAttackThrottle[uid] or 0) + CC_ATTACK_THROTTLE < now then
			ccAttackThrottle[uid] = now
			RemoteHandler.get(Config.REMOTES.CCAttacked):FireClient(data.owner)
		end
	end

	if data.hp > 0 then return end

	local wasCC       = data.buildingType == "CommandCenter"
	local wasMonument = data.buildingType == "Monument"
	local owner       = data.owner
	buildingData[id]      = nil   -- nil BEFORE Destroy so construction coroutine exits cleanly
	turretTimers[id]      = nil
	deployerTimers[id]    = nil
	deployerUnitType[id]  = nil
	deployerUpdateAcc[id] = nil
	deployerLevel[id]     = nil
	testSupplyLevel[id]   = nil
	testRateLevel[id]     = nil
	nestEggs[id]          = nil
	eggSacLevel[id]       = nil
	eggSacNests[id]       = nil
	eggSacTimer[id]       = nil
	eggSacInFlight[id]    = nil
	engState[id]          = nil
	engResearchEnd[id]    = nil
	engUpdateAcc[id]      = nil

	local model      = buildingsFolder:FindFirstChild(id)
	local destroyPos = data.base.Position + Vector3.new(0, data.base.Size.Y * 0.5, 0)
	if model then model:Destroy() end

	-- CreepyWorm vanishes silently (either burst already fired VFX, or destroyed mid-construction)
	if data.buildingType ~= "CreepyWorm" then
		task.spawn(spawnDestructionVFX, destroyPos)
	end

	if wasCC then
		-- A player can own several Command Centers (Embryo → Mother stacks them). Only
		-- eliminate when the LAST one falls; otherwise re-point the primary CC id to a
		-- surviving Mother and keep the player in the game.
		local remaining: string? = nil
		for otherId, d in buildingData do
			if d.buildingType == "CommandCenter" and d.owner == owner then
				remaining = otherId
				break
			end
		end
		if remaining then
			playerCCId[owner.UserId] = remaining
		else
			playerHasCC[owner.UserId] = nil
			playerCCId[owner.UserId] = nil
			if onCCDestroyedCb then onCCDestroyedCb(owner) end
		end
	end

	if wasMonument then
		monumentByOwner[owner.UserId] = nil
		monumentWinTimer[id] = nil
		RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(owner.UserId, nil)
	end
end

-- ── Engineering Post research helpers ───────────────────────────────────────────

-- Toggle the "research ready" notifier billboard above a post.
local function engNotifier(id: string, on: boolean)
	local model = buildingsFolder and buildingsFolder:FindFirstChild(id)
	local base  = model and model:FindFirstChild("Base") :: BasePart?
	local nb    = base and base:FindFirstChild("ResearchReady") :: BillboardGui?
	if nb then nb.Enabled = on end
end

-- Push a post's research state + the player's global discovery history to the owner.
-- `discovery` (optional) is the freshly-collected line, used to play the typewriter popup.
local function engSync(player: any, id: string, discovery: string?)
	if not player or player.UserId <= 0 or not player.Parent then return end
	local state     = engState[id] or "idle"
	local remaining = 0
	if state == "researching" then
		remaining = math.max(0, (engResearchEnd[id] or 0) - os.clock())
	end
	local history = unitManagerRef and unitManagerRef.getUpgradeHistory(player) or {}
	RemoteHandler.get(Config.REMOTES.EngineeringSync):FireClient(player, id, {
		state     = state,
		remaining = remaining,
		history   = history,
		discovery = discovery,
	})
end

-- `canTarget` (optional): predicate `(targetPos) -> boolean` to gate eligibility
-- (Artillery uses it to require a spotter).
function BuildingManager.getNearestEnemyBuilding(fromPos: Vector3, attackerOwnerIdStr: string, range: number, canTarget: ((Vector3) -> boolean)?): (string?, Vector3?)
	local bestId, bestPos, bestDist = nil :: string?, nil :: Vector3?, math.huge
	for id, data in buildingData do
		if tostring(data.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (data.base.Position - fromPos).Magnitude
		if d < range and d < bestDist and (not canTarget or canTarget(data.base.Position)) then
			bestDist = d; bestId = id; bestPos = data.base.Position + Vector3.new(0, data.base.Size.Y * 0.5, 0)
		end
	end
	return bestId, bestPos
end

function BuildingManager.removeAllBuildingsFor(player: any)
	local toRemove = {}
	for id, data in buildingData do
		if data.owner == player then table.insert(toRemove, id) end
	end
	for _, id in toRemove do
		local data = buildingData[id]
		if not data then continue end
		buildingData[id]      = nil
		turretTimers[id]      = nil
		deployerTimers[id]    = nil
		deployerUnitType[id]  = nil
		deployerUpdateAcc[id] = nil
		deployerLevel[id]     = nil
		testSupplyLevel[id]   = nil
		testRateLevel[id]     = nil
		monumentWinTimer[id]  = nil
		blobCooldowns[id]     = nil
		eggSacLevel[id]       = nil
		eggSacNests[id]       = nil
		eggSacTimer[id]       = nil
		eggSacInFlight[id]    = nil
		engState[id]          = nil
		engResearchEnd[id]    = nil
		engUpdateAcc[id]      = nil
		local model = buildingsFolder:FindFirstChild(id)
		if model then model:Destroy() end
	end
	playerHasCC[player.UserId] = nil
	monumentByOwner[player.UserId] = nil
end

function BuildingManager.placeForPlayer(player: any, position: Vector3, buildingType: string): boolean
	local snapped = snapGrid(position)

	-- Reject if the footprint overlaps any existing building, terrain, or map boundary
	if isOccupied(snapped, buildingType) then return false end
	if isTerrainBlocked(snapped, buildingType) then return false end
	if isOutOfMapBounds(snapped, buildingType) then return false end
	-- NOTE: no flatness gate here. This path places the mandatory starting base
	-- (CC + mines) and AI buildings, which must always succeed — the caller
	-- (findFlatSpot) already nudges them onto flat ground. The flatness gate
	-- lives only on the player-driven PlaceBuilding remote.

	if buildingType == "CommandCenter" then
		if playerHasCC[player.UserId] then return false end
		for _, data in buildingData do
			if data.buildingType ~= "CommandCenter" then continue end
			local d = Vector3.new(snapped.X, 0, snapped.Z)
				- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			if d.Magnitude < Config.COMMAND_CENTER_MIN_DIST then return false end
		end
		local id = createBuilding(player, snapped, "CommandCenter")
		return true, id
	end

	if not playerHasCC[player.UserId] then return false end

	-- Build zone: all non-CC buildings must be within BUILD_RADIUS of the player's CC
	-- OR within RELAY_RADIUS of any owned Relay.
	do
		local inZone = false
		for _, data in buildingData do
			if data.owner ~= player then continue end
			if data.buildingType == "CommandCenter" then
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude <= Config.BUILD_RADIUS then inZone = true; break end
			elseif data.buildingType == "Relay" then
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude <= Config.RELAY_RADIUS then inZone = true; break end
			end
		end
		if not inZone then return false end
	end

	-- Requirement check: Bonfire (Deployer) needs a Foundry; Turret/EngPost/Nest need a
	-- Bonfire; Relay needs research.
	-- AI bots (UserId < 0) bypass the Foundry prerequisite — they build on their own pacing.
	if buildingType == "Deployer" and player.UserId > 0
		and getPlayerBuildingCount(player, "Foundry") < 1 then return false end
	if buildingType == "Turret"   and getPlayerBuildingCount(player, "Deployer") < 1 then return false end
	if buildingType == "EngineeringPost" and player.UserId > 0
		and getPlayerBuildingCount(player, "Deployer") < 1 then return false end
	-- LampreyNest normally needs a Bonfire first; AI swarm bots (UserId < 0) skip
	-- this so their entire army can come from nests + creepy structures.
	if buildingType == "LampreyNest" and player.UserId > 0
		and getPlayerBuildingCount(player, "Deployer") < 1 then return false end
	-- TEST is limited to one per player (placed + in-flight).
	if buildingType == "TEST"
		and getPlayerBuildingCount(player, "TEST") + pendingCountFor(player, "TEST") >= 1 then return false end
	if buildingType == "Relay" then
		if not researchManagerRef or not researchManagerRef.hasResearch(player, "Relay") then return false end
	end
	if buildingType == "CreepyBlob" then
		if not researchManagerRef or not researchManagerRef.hasResearch(player, "CreepyBlob") then return false end
	end

	local cost = costFor(player, buildingType)
	if not resourceManagerRef or resourceManagerRef.get(player) < cost then return false end

	resourceManagerRef.spend(player, cost)
	local id = createBuilding(player, snapped, buildingType)

	if researchManagerRef and buildingType ~= "CommandCenter" then
		researchManagerRef.recordBuildingPlaced(player, buildingType)
	end
	return true, id
end

-- Bypasses build-time so the building is fully-constructed the moment it's placed.
-- Intended for server-side game-start setup only.
function BuildingManager.placeInstantForPlayer(player: any, position: Vector3, buildingType: string): (boolean, string?)
	skipNextConstruction = true
	local ok, id = BuildingManager.placeForPlayer(player, position, buildingType)
	skipNextConstruction = false
	return ok, id
end

-- Embryo morph: instantly create a fully-built structure at `position`, bypassing
-- build-zone / prerequisite / cost gates (the unit already paid to exist).
-- `turretUpgrade` (optional) pre-applies a turret path, e.g. "Creepy". CommandCenter
-- is allowed here even if the player already owns one (Embryo → Mother can stack CCs).
-- Returns the new building id, or nil if the footprint is off-map.
function BuildingManager.morphStructureForPlayer(player: any, position: Vector3, buildingType: string, turretUpgrade: string?): string?
	local snapped = snapGrid(position)
	if isOutOfMapBounds(snapped, buildingType) then return nil end
	skipNextConstruction = true
	local id = createBuilding(player, snapped, buildingType)
	skipNextConstruction = false
	if researchManagerRef and buildingType ~= "CommandCenter" then
		researchManagerRef.recordBuildingPlaced(player, buildingType)
	end
	if buildingType == "Turret" and turretUpgrade then
		local data = buildingData[id]
		if data then
			data.turretUpgrade = turretUpgrade
			applyTurretUpgradeVisuals(id, turretUpgrade)
		end
	end
	return id
end

-- ── Artillery spotter check ───────────────────────────────────────────────────
-- Artillery out-ranges everything but must never fire blindly into the fog: a
-- target only counts if it lies within vision of one of the owner's own units or
-- buildings. Sources are gathered once per shot, then each candidate is tested.

type SightSource = { x: number, z: number, r2: number }

local function gatherSightSources(ownerStr: string): { SightSource }
	local sources: { SightSource } = {}
	for _, bd in buildingData do
		if bd.isConstructing then continue end
		if tostring(bd.owner.UserId) ~= ownerStr then continue end
		local vr = (Config.VISION_RADIUS :: any)[bd.buildingType] or Config.VISION_DEFAULT
		sources[#sources + 1] = { x = bd.base.Position.X, z = bd.base.Position.Z, r2 = vr * vr }
	end
	if unitManagerRef and unitManagerRef.getOwnerUnitPositions then
		local r2 = Config.VISION_UNIT * Config.VISION_UNIT
		for _, p in unitManagerRef.getOwnerUnitPositions(ownerStr) do
			sources[#sources + 1] = { x = p.X, z = p.Z, r2 = r2 }
		end
	end
	return sources
end

local function isSpotted(sources: { SightSource }, pos: Vector3): boolean
	for _, s in sources do
		local dx = s.x - pos.X
		local dz = s.z - pos.Z
		if dx * dx + dz * dz <= s.r2 then return true end
	end
	return false
end

-- Public spotter-check factory: gathers `ownerStr`'s sight sources once, then
-- returns a predicate `(pos) -> boolean` that reports whether a point is out of
-- the fog (within vision of that owner's units/buildings). Long-range units such
-- as the Sniper use this so they never fire blindly into unexplored fog — the same
-- rule the Artillery turret follows. Gather once per volley, reuse for every test.
function BuildingManager.makeSpotterCheck(ownerStr: string): (Vector3) -> boolean
	local sources = gatherSightSources(ownerStr)
	return function(pos) return isSpotted(sources, pos) end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function BuildingManager.init(resourceManager, mineralManager_)
	resourceManagerRef    = resourceManager
	mineralManager        = mineralManager_
	buildingsFolder        = Instance.new("Folder")
	buildingsFolder.Name   = "Buildings"
	buildingsFolder.Parent = workspace

	-- ── Turret attack loop ────────────────────────────────────────────────
	RunService.Heartbeat:Connect(function(dt)
		for id, data in buildingData do
			if data.buildingType ~= "Turret" then continue end
			if data.isConstructing then continue end   -- still under construction

			-- Per-turret stats (may be upgraded)
			local upg      = data.turretUpgrade
			local isCreepy = upg == "Creepy" or upg == "Mutant"
			local tRate   = upg == "Flamethrower"  and Config.TURRET_FLAME.rate
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.rate
			             or upg == "Artillery"      and Config.TURRET_ARTILLERY.rate
			             or isCreepy                and Config.TURRET_CREEPY.rate
			             or Config.TURRET_ATTACK_RATE
			local tRange  = upg == "Flamethrower"  and Config.TURRET_FLAME.range
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.range
			             or upg == "Artillery"      and Config.TURRET_ARTILLERY.range
			             or isCreepy                and Config.TURRET_CREEPY.range
			             or Config.TURRET_RANGE
			local tDamage = upg == "Flamethrower"  and Config.TURRET_FLAME.damage
			             or upg == "RocketLauncher" and Config.TURRET_ROCKET.damage
			             or upg == "Artillery"      and Config.TURRET_ARTILLERY.damage
			             or isCreepy                and Config.TURRET_CREEPY.damage
			             or Config.TURRET_DAMAGE

			turretTimers[id] = (turretTimers[id] or 0) + dt
			if turretTimers[id] < tRate then continue end
			turretTimers[id] -= tRate

			local myPos      = data.base.Position
			local myOwnerStr = tostring(data.owner.UserId)

			-- Creepy / Mutant: 3 independent tentacle strikes, no projectile
			if isCreepy then
				local headPos = myPos + Vector3.new(0, Config.BUILDING_SIZE.Y + 1.5, 0)
				local t1: Vector3? = nil
				local t2: Vector3? = nil
				local t3: Vector3? = nil
				if unitManagerRef then
					local _, p1 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t1 = p1
					local _, p2 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t2 = p2
					local _, p3 = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage)
					t3 = p3
				end
				RemoteHandler.get(Config.REMOTES.TentacleTargets):FireAllClients(id, headPos, t1, t2, t3)
				continue
			end

			-- Artillery only fires at targets that are spotted (out of the fog).
			local canTarget: ((Vector3) -> boolean)? = nil
			if upg == "Artillery" then
				local sources = gatherSightSources(myOwnerStr)
				canTarget = function(pos) return isSpotted(sources, pos) end
			end

			local targetPos: Vector3? = nil

			-- Prefer hitting units → buildings
			if unitManagerRef then
				local hitUnit, unitHitPos = unitManagerRef.damageNearestUnit(myPos, myOwnerStr, tRange, tDamage, canTarget)
				if hitUnit then targetPos = unitHitPos end
			end
			if not targetPos then
				local bId, bPos = BuildingManager.getNearestEnemyBuilding(myPos, myOwnerStr, tRange, canTarget)
				if bId then
					BuildingManager.damage(bId, tDamage)
					targetPos = bPos
				end
			end

			if targetPos then
				local visualTarget = targetPos

				local head    = data.head
				local headPos = head and head.Position
					or (myPos + Vector3.new(0, Config.BUILDING_SIZE.Y + 1.5, 0))

				local aimDir    = visualTarget - headPos
				local barrelTip = headPos   -- fallback

				if aimDir.Magnitude > 0.1 then
					local aimUnit = aimDir.Unit

					-- Yaw the head/mantlet toward the target
					if head then
						local flatDir = (visualTarget - headPos) * Vector3.new(1, 0, 1)
						if flatDir.Magnitude > 0.1 then
							head.CFrame = CFrame.new(headPos, headPos + flatDir.Unit)
						end
					end

					if data.barrels then
						-- Artillery: aim the three long nozzles, fire from their tips
						barrelTip = headPos + aimUnit * 13
						local rightV = aimUnit:Cross(Vector3.new(0, 1, 0))
						rightV = rightV.Magnitude > 0.01 and rightV.Unit or Vector3.new(1, 0, 0)
						local offs = { -2.1, 0, 2.1 }
						for i, bp in data.barrels do
							local center = headPos + rightV * (offs[i] or 0) + aimUnit * 6
							bp.CFrame = CFrame.new(center, center + aimUnit)
						end
					elseif data.barrel then
						barrelTip = headPos + aimUnit * 7
						local barrelCenter = headPos + aimUnit * 3.5
						data.barrel.CFrame = CFrame.new(barrelCenter, barrelCenter + aimUnit)
					else
						barrelTip = headPos + aimUnit * 7
					end
				end

				-- Tell all clients to show a projectile
				RemoteHandler.get(Config.REMOTES.TurretShot):FireAllClients(barrelTip, visualTarget, data.turretUpgrade)
			end
		end

		-- ── Deployer / TEST auto-spawn ────────────────────────────────────────
		-- Both the Bonfire and the TEST building auto-summon their chosen unit up to a
		-- capacity, on an interval. The Bonfire scales both from one Empower level; the
		-- TEST building scales capacity (Supply) and interval (Spawn Rate) separately.
		local deployerUpdateRemote = RemoteHandler.get(Config.REMOTES.DeployerUpdate)
		local testUpdateRemote     = RemoteHandler.get(Config.REMOTES.TestUpdate)
		for id, data in buildingData do
			local isDeployer = data.buildingType == "Deployer"
			local isTest     = data.buildingType == "TEST"
			if not (isDeployer or isTest) then continue end
			if data.isConstructing then continue end

			local capacity, interval
			if isTest then
				capacity = Config.testCapacity(testSupplyLevel[id] or 0)
				interval = Config.testInterval(testRateLevel[id] or 0)
			else
				local level = deployerLevel[id] or 0
				capacity = Config.bonfireCapacity(level)
				interval = Config.bonfireInterval(level)
			end

			deployerTimers[id] = (deployerTimers[id] or 0) + dt
			local progress = math.clamp(deployerTimers[id] / interval, 0, 1)
			if deployerTimers[id] >= interval then
				deployerTimers[id] -= interval
				progress = 0
				if unitManagerRef then
					local aliveCount = unitManagerRef.getDeployerAliveCount(id)
					if aliveCount < capacity then
						local unitType = deployerUnitType[id] or "Survivor"
						local footprint = isTest and Config.TEST_SIZE.X or Config.BONFIRE_SIZE.X
						local spawnPos = data.base.Position + Vector3.new(footprint / 2 + 2, 0, 0)
						unitManagerRef.spawnForDeployer(id, data.owner, spawnPos, unitType)
					end
				end
			end
			-- Periodic client update (~3× per second) — skip AI owners
			if data.owner.UserId > 0 then
				deployerUpdateAcc[id] = (deployerUpdateAcc[id] or 0) + dt
				if deployerUpdateAcc[id] >= 0.35 then
					deployerUpdateAcc[id] = 0
					local unitType = deployerUnitType[id] or "Survivor"
					if isTest then
						local sLvl = testSupplyLevel[id] or 0
						local rLvl = testRateLevel[id] or 0
						local sCost = sLvl < Config.TEST_SUPPLY_MAX_LEVEL and Config.testSupplyCost(sLvl) or 0
						local rCost = rLvl < Config.TEST_RATE_MAX_LEVEL and Config.testRateCost(rLvl) or 0
						testUpdateRemote:FireClient(data.owner, id, unitType, progress, sLvl, rLvl, capacity, sCost, rCost)
					else
						local level    = deployerLevel[id] or 0
						local nextCost = level < Config.DEPLOYER_UPGRADE_MAX_LEVEL and Config.bonfireUpgradeCost(level) or 0
						deployerUpdateRemote:FireClient(data.owner, id, unitType, progress, level, capacity, nextCost)
					end
				end
			end
		end

		-- ── Mother Egg Sacs autospawn ──────────────────────────────────────────
		-- Each Mother that has bought Egg Sacs keeps a clutch of Embryos alive up to its
		-- capacity (level × 4), hatching a fresh egg from one of its planted nests on an
		-- interval whenever alive + incubating Embryos fall short. Free (the upgrade paid).
		for id, data in buildingData do
			if data.buildingType ~= "CommandCenter" or data.isConstructing then continue end
			local level = eggSacLevel[id] or 0
			if level <= 0 then continue end
			local nests = eggSacNests[id]
			if not nests or #nests == 0 then continue end

			eggSacTimer[id] = (eggSacTimer[id] or 0) + dt
			if eggSacTimer[id] < Config.MOTHER_EGGSAC_INTERVAL then continue end
			eggSacTimer[id] -= Config.MOTHER_EGGSAC_INTERVAL

			local capacity = Config.eggSacCapacity(level)
			local alive    = unitManagerRef and unitManagerRef.getDeployerAliveCount(id) or 0
			local pending  = eggSacInFlight[id] or 0
			if alive + pending >= capacity then continue end

			local nestPos = nests[math.random(1, #nests)]
			eggSacInFlight[id] = pending + 1
			task.spawn(produceEggSacEmbryo, id, data.owner, nestPos)
		end

		-- ── Command Center passive income ──────────────────────────────────────
		ccIncomeAccum += dt
		if ccIncomeAccum >= Config.CC_PASSIVE_INTERVAL then
			ccIncomeAccum -= Config.CC_PASSIVE_INTERVAL
			if resourceManagerRef then
				for _, data in buildingData do
					if data.buildingType == "CommandCenter" and not data.isConstructing
						and data.owner and data.owner.UserId > 0 then
						resourceManagerRef.add(data.owner, Config.CC_PASSIVE_INCOME)
					end
				end
			end
		end

		-- ── Foundry passive income ─────────────────────────────────────────────
		-- Each standing Foundry pays out FOUNDRY_BASE_INCOME, boosted +15% per active
		-- mineral deposit within FOUNDRY_BOOST_RADIUS (uncapped). Boosting deposits are
		-- drained a little each tick, and the floating "Boosted +X%" label is refreshed.
		foundryIncomeAccum += dt
		if foundryIncomeAccum >= Config.FOUNDRY_INCOME_INTERVAL then
			foundryIncomeAccum -= Config.FOUNDRY_INCOME_INTERVAL
			for _, data in buildingData do
				if data.buildingType ~= "Foundry" or data.isConstructing then continue end
				local pos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)

				local depositCount = 0
				if mineralManager then
					depositCount = mineralManager.drainAllNear(
						pos, Config.FOUNDRY_BOOST_RADIUS, Config.FOUNDRY_DRAIN_PER_DEPOSIT)
				end

				-- Income goes to every owner, including AI bots (UserId < 0) — unlike CC
				-- passive income, the Foundry is the AI's economic engine just as it is the
				-- player's, so the guard that excludes bots from CC income is not applied here.
				local boostMult = 1 + depositCount * Config.FOUNDRY_BOOST_PER_DEPOSIT
				local income    = math.floor(Config.FOUNDRY_BASE_INCOME * boostMult)
				if resourceManagerRef and data.owner then
					resourceManagerRef.add(data.owner, income)
				end

				local model = data.base.Parent :: Model?

				-- Floating "+N" income popup over the owner's Foundry each tick.
				if data.owner and data.owner.UserId > 0 and data.owner.Parent and model then
					RemoteHandler.get(Config.REMOTES.FoundryIncome):FireClient(data.owner, model.Name, income)
				end

				-- Harvest sound on the crucible when deposits are actually being refined.
				if depositCount > 0 and model then
					local molten = model:FindFirstChild("Molten")
					local harv   = molten and molten:FindFirstChild("_FoundryHarvest") :: Sound?
					if harv then harv:Play() end
				end

				-- Refresh the floating boost readout (replicates to all clients).
				local bl = data.base:FindFirstChild("BoostLabel") :: BillboardGui?
				if bl then
					if depositCount > 0 then
						bl.Enabled = true
						local lbl = bl:FindFirstChild("Text") :: TextLabel?
						if lbl then
							lbl.Text = string.format("Boosted +%d%%",
								math.floor(depositCount * Config.FOUNDRY_BOOST_PER_DEPOSIT * 100 + 0.5))
						end
					else
						bl.Enabled = false
					end
				end
			end
		end

		-- ── Engineering Post research timers ───────────────────────────────────
		for id, data in buildingData do
			if data.buildingType ~= "EngineeringPost" then continue end
			if engState[id] ~= "researching" then continue end
			if not (data.owner and data.owner.UserId > 0) then continue end

			if os.clock() >= (engResearchEnd[id] or 0) then
				-- Research complete: light up the notifier, wait for the player to collect.
				engState[id] = "ready"
				engUpdateAcc[id] = nil
				engNotifier(id, true)
				engSync(data.owner, id)
			else
				-- Periodic progress push so an open panel's bar advances (~3×/sec).
				engUpdateAcc[id] = (engUpdateAcc[id] or 0) + dt
				if engUpdateAcc[id] >= 0.35 then
					engUpdateAcc[id] = 0
					engSync(data.owner, id)
				end
			end
		end

		-- ── Monument win timers ────────────────────────────────────────────────
		monumentHeartbeatAccum += dt
		local sendProgress = false
		if monumentHeartbeatAccum >= 1 then
			monumentHeartbeatAccum -= 1
			sendProgress = true
		end

		for userId, bid in monumentByOwner do
			local mdata = buildingData[bid]
			if not mdata or mdata.isConstructing then continue end

			monumentWinTimer[bid] = (monumentWinTimer[bid] or 0) + dt

			if monumentWinTimer[bid] >= Config.MONUMENT_WIN_DURATION then
				RemoteHandler.get(Config.REMOTES.PlayerWon):FireAllClients(userId)
				monumentByOwner[userId] = nil
				monumentWinTimer[bid]   = nil
				if onPlayerWonCb then task.spawn(onPlayerWonCb, userId) end
				break
			end

			if sendProgress then
				local remaining = Config.MONUMENT_WIN_DURATION - monumentWinTimer[bid]
				RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(userId, remaining)
			end
		end

		-- ── Mobile CC movement ────────────────────────────────────────────────
		for ccId, target in ccMoveTargets do
			local data = buildingData[ccId]
			if not data then ccMoveTargets[ccId] = nil; continue end
			if not data.base.Parent then ccMoveTargets[ccId] = nil; continue end

			local cur  = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			local flat = Vector3.new(target.X - cur.X, 0, target.Z - cur.Z)
			if flat.Magnitude < 1 then
				ccMoveTargets[ccId] = nil
				continue
			end

			local step  = math.min(Config.MOBILE_CC_SPEED * dt, flat.Magnitude)
			local move  = flat.Unit * step
			local model = buildingsFolder:FindFirstChild(ccId) :: Model?
			if model and model:IsA("Model") then
				model:PivotTo(CFrame.new(
					data.base.Position.X + move.X,
					data.base.Position.Y,
					data.base.Position.Z + move.Z
				))
			end
		end

	end)

	-- ── MobilizeCC remote ────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.MobilizeCC).OnServerEvent:Connect(function(player, ccId)
		if type(ccId) ~= "string" then return end
		local data = buildingData[ccId]
		if not data or data.buildingType ~= "CommandCenter" then return end
		if data.owner ~= player then return end

		-- The Hollowed Mother "uproots" / "downroots" for free — no research, no unlock
		-- cost. It just toggles between rooted (structure, has build options) and mobile
		-- (moveable unit). Humans keep the researched + paid Mobile-CC path below.
		if isHollowed(player) then
			local nowMobile = not ccMobile[ccId]
			ccMobile[ccId]  = nowMobile
			if not nowMobile then ccMoveTargets[ccId] = nil end
			local model = buildingsFolder:FindFirstChild(ccId)
			if model then
				local mv = model:FindFirstChild("IsMobile") :: BoolValue?
				if not mv then
					mv        = Instance.new("BoolValue")
					mv.Name   = "IsMobile"
					mv.Parent = model
				end
				(mv :: BoolValue).Value = nowMobile
			end
			RemoteHandler.get(Config.REMOTES.CCMobileSync):FireClient(player, ccId, true, nowMobile)
			return
		end

		if not researchManagerRef or not researchManagerRef.hasResearch(player, "MobileCC") then return end

		if not ccMobileUnlocked[player.UserId] then
			-- First use: spend 200 resources to permanently unlock
			if not resourceManagerRef or resourceManagerRef.get(player) < Config.MOBILE_CC_COST then return end
			resourceManagerRef.spend(player, Config.MOBILE_CC_COST)
			ccMobileUnlocked[player.UserId] = true
			RemoteHandler.get(Config.REMOTES.CCMobileSync):FireClient(player, ccId, true, false)
			return
		end

		-- Toggle mobile/deployed state
		local nowMobile = not ccMobile[ccId]
		ccMobile[ccId]  = nowMobile

		if not nowMobile then
			ccMoveTargets[ccId] = nil
		end

		-- Keep an IsMobile BoolValue on the model so any client can read it
		local model = buildingsFolder:FindFirstChild(ccId)
		if model then
			local mv = model:FindFirstChild("IsMobile") :: BoolValue?
			if not mv then
				mv        = Instance.new("BoolValue")
				mv.Name   = "IsMobile"
				mv.Parent = model
			end
			(mv :: BoolValue).Value = nowMobile
		end

		RemoteHandler.get(Config.REMOTES.CCMobileSync):FireClient(player, ccId, true, nowMobile)
	end)

	-- ── MoveMobileCC remote ───────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.MoveMobileCC).OnServerEvent:Connect(function(player, ccId, pos)
		if type(ccId) ~= "string" then return end
		if typeof(pos) ~= "Vector3" then return end
		local data = buildingData[ccId]
		if not data or data.buildingType ~= "CommandCenter" then return end
		if data.owner ~= player then return end
		if not ccMobile[ccId] then return end
		ccMoveTargets[ccId] = Vector3.new(pos.X, 0, pos.Z)
	end)

	-- ── UnlockEvolve remote (Hollowed Mother → "Evolve") ──────────────────
	-- A one-time purchase on the Mother that spends MOTHER_EVOLVE_COST and sets the
	-- owner's "EmbryoGenome" player attribute (replicates to their client), unlocking
	-- every Embryo's evolution options. Per-player: once unlocked, all Embryos can evolve.
	RemoteHandler.get(Config.REMOTES.UnlockEvolve).OnServerEvent:Connect(function(player, ccId)
		if type(ccId) ~= "string" then return end
		local data = buildingData[ccId]
		if not data or data.buildingType ~= "CommandCenter" or data.owner ~= player then return end
		if data.isConstructing then return end
		if player:GetAttribute("EmbryoGenome") == true then return end
		if not resourceManagerRef or not resourceManagerRef.spend(player, Config.MOTHER_EVOLVE_COST) then return end
		player:SetAttribute("EmbryoGenome", true)
	end)

	-- ── PlaceBuilding remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.PlaceBuilding).OnServerEvent:Connect(function(player, pos, buildingType)
		if typeof(pos) ~= "Vector3" then return end
		if type(buildingType) ~= "string" then return end
		if laneModeActive and buildingType ~= "CommandCenter" then return end

		local snapped = snapGrid(pos)

		-- The client (whose ghost preview already sits at the correct height) sends
		-- the ground point under the cursor in pos.Y. Trust it as the base-bottom
		-- height — it's the same value the holograms use — instead of recomputing
		-- it server-side (which is what was burying structures). snapGrid zeroes Y,
		-- so re-apply the client Y onto the grid-snapped XZ.
		snapped = Vector3.new(snapped.X, pos.Y, snapped.Z)

		-- Reject if the footprint overlaps any existing building, terrain, or map boundary
		if isOccupied(snapped, buildingType) then return end
		if isTerrainBlocked(snapped, buildingType) then return end
		if isOutOfMapBounds(snapped, buildingType) then return end

		-- Reject footprints that straddle a ramp or a tier boundary — the building's
		-- flat base would float over part of the ground and clip into the rest.
		if terrainManagerRef then
			local ns = buildingSize(buildingType)
			if not terrainManagerRef.isFootprintFlat(snapped.X, snapped.Z, ns.X / 2, ns.Z / 2) then return end
		end

		-- Reject non-CC buildings while CC is mobile
		if buildingType ~= "CommandCenter" then
			local myCCId = playerCCId[player.UserId]
			if myCCId and ccMobile[myCCId] then return end
		end

		if buildingType == "CommandCenter" then
			if playerHasCC[player.UserId] then return end
			for _, data in buildingData do
				if data.buildingType ~= "CommandCenter" then continue end
				local d = Vector3.new(snapped.X, 0, snapped.Z)
					- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
				if d.Magnitude < Config.COMMAND_CENTER_MIN_DIST then return end
			end
			-- Trust the client ground height (snapped.Y) so the CC sits where its
			-- ghost previewed, rather than a re-computed server height.
			createBuilding(player, snapped, "CommandCenter", snapped.Y)
			return
		end

		if not playerHasCC[player.UserId] then return end

		-- Build zone: CC radius OR any owned Relay radius
		do
			local inZone = false
			for _, data in buildingData do
				if data.owner ~= player then continue end
				if data.buildingType == "CommandCenter" then
					local d = Vector3.new(snapped.X, 0, snapped.Z)
						- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
					if d.Magnitude <= Config.BUILD_RADIUS then inZone = true; break end
				elseif data.buildingType == "Relay" then
					local d = Vector3.new(snapped.X, 0, snapped.Z)
						- Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
					if d.Magnitude <= Config.RELAY_RADIUS then inZone = true; break end
				end
			end
			if not inZone then return end
		end

		-- Whitelist: only these types may be placed by clients directly
		local PLACEABLE = { CommandCenter=true, Foundry=true, Deployer=true, Turret=true, Relay=true, CreepyBlob=true, LampreyNest=true, EngineeringPost=true, TEST=true }
		if not PLACEABLE[buildingType] then return end

		-- Faction gate: the Hollowed build NOTHING from the tray — every unit and
		-- structure comes from selecting the Mother and its option grid. Humans place
		-- anything EXCEPT the legacy creature buildings (kept in code for the Swarm AI).
		local hollowed = isHollowed(player)
		if hollowed then
			if buildingType ~= "CommandCenter" then return end
		else
			if HOLLOWED_BUILDINGS[buildingType] then return end
		end

		-- Requirement check: Bonfire (Deployer) needs a Foundry; Turret/Post need a
		-- Bonfire; Relay needs research. The Hollowed have no Foundry/Bonfire/research
		-- tree, so their Blob + Nest skip the Human prerequisites entirely.
		if buildingType == "Deployer"
			and getPlayerBuildingCount(player, "Foundry") < 1 then return end
		if buildingType == "Turret"   and getPlayerBuildingCount(player, "Deployer") < 1 then return end
		if buildingType == "EngineeringPost" and getPlayerBuildingCount(player, "Deployer") < 1 then return end
		if buildingType == "LampreyNest" and not hollowed
			and getPlayerBuildingCount(player, "Deployer") < 1 then return end
		-- TEST is limited to one per player (placed + in-flight).
		if buildingType == "TEST"
			and getPlayerBuildingCount(player, "TEST") + pendingCountFor(player, "TEST") >= 1 then return end
		if buildingType == "Relay" then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, "Relay") then return end
		end
		if buildingType == "CreepyBlob" and not hollowed then
			if not researchManagerRef or not researchManagerRef.hasResearch(player, "CreepyBlob") then return end
		end

		local cost = costFor(player, buildingType)
		if resourceManager.get(player) < cost then return end

		resourceManager.spend(player, cost)

		-- Launch a drop pod immediately — no queue, no cooldown. The structure is
		-- assembled on-site by the pod's welding arms when it lands.
		local ccPos: Vector3? = nil
		for _, bd in buildingData do
			if bd.owner == player and bd.buildingType == "CommandCenter" then
				ccPos = Vector3.new(bd.base.Position.X, 0, bd.base.Position.Z)
				break
			end
		end
		if ccPos then
			-- Reserve this placement so the next one of the same type already costs
			-- more (released when the pod lands and the building enters buildingData).
			addPending(player, buildingType, 1)
			local ccTopY     = Config.COMMAND_CENTER_SIZE.Y + 2
			local launchPos  = ccPos + Vector3.new(0, ccTopY, 0)
			local relayChain = findRelayChain(player, ccPos, snapped)
			launchDropPod(player, launchPos, relayChain, snapped, buildingType, false)
		end
	end)

	-- ── BuildMonument remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.BuildMonument).OnServerEvent:Connect(function(player)
		BuildingManager.buildMonument(player)
	end)

	-- ── SellBuilding remote ────────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.SellBuilding).OnServerEvent:Connect(function(player, ids)
		if type(ids) ~= "table" then return end
		for _, id in ids do
			if type(id) == "string" then BuildingManager.sellBuilding(player, id) end
		end
	end)

	-- ── Engineering Post research remotes ───────────────────────────────────────
	local function ownsPost(player: any, id: any): boolean
		if type(id) ~= "string" then return false end
		local data = buildingData[id]
		return data ~= nil and data.buildingType == "EngineeringPost"
			and data.owner == player and not data.isConstructing
	end

	-- Start a Light research (charges ENGINEERING_RESEARCH_COST). Heavy is client-side
	-- "coming soon" and never reaches the server.
	RemoteHandler.get(Config.REMOTES.EngineeringStart).OnServerEvent:Connect(function(player, id)
		if not ownsPost(player, id) then return end
		if (engState[id] or "idle") ~= "idle" then return end
		if not resourceManagerRef or resourceManagerRef.get(player) < Config.ENGINEERING_RESEARCH_COST then return end
		resourceManagerRef.spend(player, Config.ENGINEERING_RESEARCH_COST)
		engState[id]       = "researching"
		engResearchEnd[id] = os.clock() + Config.ENGINEERING_LIGHT_TIME
		engUpdateAcc[id]   = 0
		engSync(player, id)
	end)

	-- Collect a finished research: roll + apply a random upgrade, log it, reveal it.
	RemoteHandler.get(Config.REMOTES.EngineeringCollect).OnServerEvent:Connect(function(player, id)
		if not ownsPost(player, id) then return end
		if engState[id] ~= "ready" then return end
		engState[id]       = "idle"
		engResearchEnd[id] = nil
		engNotifier(id, false)
		local discovery = nil
		if unitManagerRef then
			discovery = unitManagerRef.applyRandomUpgrade(player)
		end
		engSync(player, id, discovery)
	end)

	-- Panel opened: send the post's current state + the player's discovery history.
	RemoteHandler.get(Config.REMOTES.EngineeringRequest).OnServerEvent:Connect(function(player, id)
		if not ownsPost(player, id) then return end
		engSync(player, id)
	end)

	-- ── SetDeployerType remote ─────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.SetDeployerType).OnServerEvent:Connect(function(player, deployerId, unitType)
		if type(deployerId) ~= "string" or type(unitType) ~= "string" then return end
		local VALID = { Survivor = true, Sniper = true, Tank = true, Howitzer = true, Elite = true, Medic = true, Foamer = true }
		if not VALID[unitType] then return end
		local data = buildingData[deployerId]
		if not data or data.buildingType ~= "Deployer" or data.owner ~= player then return end
		-- Research gate for locked unit types
		if (unitType == "Elite" or unitType == "Medic") and researchManagerRef then
			local req = unitType == "Elite" and "EliteUnits" or "MedicUnit"
			if not researchManagerRef.hasResearch(player, req) then return end
		end
		deployerUnitType[deployerId] = unitType
		-- Immediately send an update so the client reflects the change without waiting for next poll
		local level    = deployerLevel[deployerId] or 0
		local progress = math.clamp((deployerTimers[deployerId] or 0) / Config.bonfireInterval(level), 0, 1)
		local nextCost = level < Config.DEPLOYER_UPGRADE_MAX_LEVEL and Config.bonfireUpgradeCost(level) or 0
		RemoteHandler.get(Config.REMOTES.DeployerUpdate):FireClient(player, deployerId, unitType, progress, level, Config.bonfireCapacity(level), nextCost)
	end)

	-- ── UpgradeDeployer remote (Empower bonfires: +capacity, faster summon) ─────
	-- Accepts one id or a list (multi-select). When several bonfires are selected at
	-- different levels, only the LOWEST-level ones are upgraded so a press evens the
	-- group out; each is charged its own (level-based) cost, stopping when broke.
	RemoteHandler.get(Config.REMOTES.UpgradeDeployer).OnServerEvent:Connect(function(player, deployerIds)
		local ids = type(deployerIds) == "string" and { deployerIds } or deployerIds
		if type(ids) ~= "table" then return end

		-- Eligible = owned, finished, below max. Find the lowest level among them.
		local eligible: { string } = {}
		local minLevel = math.huge
		for _, id in ids do
			if type(id) ~= "string" then continue end
			local data = buildingData[id]
			if not data or data.buildingType ~= "Deployer" or data.owner ~= player or data.isConstructing then continue end
			local lvl = deployerLevel[id] or 0
			if lvl >= Config.DEPLOYER_UPGRADE_MAX_LEVEL then continue end
			table.insert(eligible, id)
			if lvl < minLevel then minLevel = lvl end
		end
		if #eligible == 0 then return end

		local cost          = Config.bonfireUpgradeCost(minLevel)  -- all min-level bonfires share this cost
		local updateRemote  = RemoteHandler.get(Config.REMOTES.DeployerUpdate)
		for _, id in eligible do
			if (deployerLevel[id] or 0) ~= minLevel then continue end
			if not resourceManagerRef or resourceManagerRef.get(player) < cost then break end
			resourceManagerRef.spend(player, cost)
			local level = minLevel + 1
			deployerLevel[id] = level
			-- Stack the next tiki log onto the live model (replicates to everyone).
			local bdata = buildingData[id]
			if bdata and bdata.base and bdata.base.Parent then
				UnitVisuals.addBonfireLog(bdata.base.Parent, level)
			end
			local unitType = deployerUnitType[id] or "Survivor"
			local progress = math.clamp((deployerTimers[id] or 0) / Config.bonfireInterval(level), 0, 1)
			local nextCost = level < Config.DEPLOYER_UPGRADE_MAX_LEVEL and Config.bonfireUpgradeCost(level) or 0
			-- `true` 8th arg flags a fresh upgrade so the client plays the empower FX.
			updateRemote:FireClient(player, id, unitType, progress, level, Config.bonfireCapacity(level), nextCost, true)
		end
	end)

	-- ── UpgradeEggSacs remote (Hollowed Mother Egg Sacs purchase) ───────────────
	-- Buys one Egg Sacs upgrade on the Mother: plants a new pair of nests and raises
	-- the auto-spawn Embryo cap. The model's EggSacLevel attribute (set inside the
	-- upgrade fn) replicates the new level back to the client MotherPanel.
	RemoteHandler.get(Config.REMOTES.UpgradeEggSacs).OnServerEvent:Connect(function(player, ccId)
		if type(ccId) ~= "string" then return end
		BuildingManager.upgradeEggSacsForPlayer(player, ccId)
	end)

	-- ── TEST building remotes (separate Supply + Spawn Rate upgrades) ───────────
	-- Fires a full TestUpdate to the owner so the panel reflects the latest state.
	local function sendTestUpdate(player: any, id: string, justUpgraded: boolean?)
		local data = buildingData[id]
		if not data then return end
		local sLvl     = testSupplyLevel[id] or 0
		local rLvl     = testRateLevel[id] or 0
		local unitType = deployerUnitType[id] or "Survivor"
		local capacity = Config.testCapacity(sLvl)
		local interval = Config.testInterval(rLvl)
		local progress = math.clamp((deployerTimers[id] or 0) / interval, 0, 1)
		local sCost    = sLvl < Config.TEST_SUPPLY_MAX_LEVEL and Config.testSupplyCost(sLvl) or 0
		local rCost    = rLvl < Config.TEST_RATE_MAX_LEVEL and Config.testRateCost(rLvl) or 0
		RemoteHandler.get(Config.REMOTES.TestUpdate):FireClient(
			player, id, unitType, progress, sLvl, rLvl, capacity, sCost, rCost, justUpgraded)
	end

	-- Set the unit type a TEST building auto-summons (mirrors SetDeployerType).
	RemoteHandler.get(Config.REMOTES.SetTestType).OnServerEvent:Connect(function(player, testId, unitType)
		if type(testId) ~= "string" or type(unitType) ~= "string" then return end
		local VALID = { Survivor = true, Sniper = true, Tank = true, Howitzer = true, Elite = true, Medic = true, Foamer = true }
		if not VALID[unitType] then return end
		local data = buildingData[testId]
		if not data or data.buildingType ~= "TEST" or data.owner ~= player then return end
		if (unitType == "Elite" or unitType == "Medic") and researchManagerRef then
			local req = unitType == "Elite" and "EliteUnits" or "MedicUnit"
			if not researchManagerRef.hasResearch(player, req) then return end
		end
		deployerUnitType[testId] = unitType
		sendTestUpdate(player, testId)
	end)

	-- Upgrade a TEST building's Supply (capacity) or Spawn Rate (interval) — separately.
	RemoteHandler.get(Config.REMOTES.UpgradeTest).OnServerEvent:Connect(function(player, testId, kind)
		if type(testId) ~= "string" or type(kind) ~= "string" then return end
		local data = buildingData[testId]
		if not data or data.buildingType ~= "TEST" or data.owner ~= player or data.isConstructing then return end
		if not resourceManagerRef then return end

		if kind == "supply" then
			local lvl = testSupplyLevel[testId] or 0
			if lvl >= Config.TEST_SUPPLY_MAX_LEVEL then return end
			local cost = Config.testSupplyCost(lvl)
			if resourceManagerRef.get(player) < cost then return end
			resourceManagerRef.spend(player, cost)
			testSupplyLevel[testId] = lvl + 1
		elseif kind == "rate" then
			local lvl = testRateLevel[testId] or 0
			if lvl >= Config.TEST_RATE_MAX_LEVEL then return end
			local cost = Config.testRateCost(lvl)
			if resourceManagerRef.get(player) < cost then return end
			resourceManagerRef.spend(player, cost)
			testRateLevel[testId] = lvl + 1
		else
			return
		end
		sendTestUpdate(player, testId, true)
	end)

	-- ── UpgradeTurret remote ──────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.UpgradeTurret).OnServerEvent:Connect(
		function(player, turretIds, upgradeType)
			if type(upgradeType) ~= "string" then return end
			local ids = type(turretIds) == "string" and {turretIds} or turretIds
			if type(ids) ~= "table" then return end
			for _, turretId in ids do
				BuildingManager.upgradeTurretForPlayer(player, turretId, upgradeType)
			end
		end
	)

	-- ── BlobProduce remote ────────────────────────────────────────────────
	RemoteHandler.get(Config.REMOTES.BlobProduce).OnServerEvent:Connect(
		function(player: any, blobIds: any, productType: any)
			if type(productType) ~= "string" then return end

			local ids = type(blobIds) == "string" and {blobIds} or blobIds
			if type(ids) ~= "table" then return end

			for _, blobId in ids do
				if type(blobId) ~= "string" then continue end

				local data = buildingData[blobId]
				if not data or data.buildingType ~= "CreepyBlob" then continue end
				if data.owner ~= player then continue end
				if data.isConstructing then continue end

				local blobPos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)

				if productType == "CreepySoldier" then
					BuildingManager.requestBlobSoldier(player, blobId)

				elseif productType == "CreepyWorm" then
					if not resourceManagerRef or resourceManagerRef.get(player) < Config.BLOB_WORM_COST then continue end
					resourceManagerRef.spend(player, Config.BLOB_WORM_COST)

					buildingData[blobId] = nil
					blobCooldowns[blobId] = nil
					local model = buildingsFolder:FindFirstChild(blobId)
					if model then model:Destroy() end

					createBuilding(player, blobPos, "CreepyWorm")

				elseif productType == "CreepyTurret" then
					if not resourceManagerRef or resourceManagerRef.get(player) < Config.BLOB_TURRET_COST then continue end
					resourceManagerRef.spend(player, Config.BLOB_TURRET_COST)

					buildingData[blobId] = nil
					blobCooldowns[blobId] = nil
					local model = buildingsFolder:FindFirstChild(blobId)
					if model then model:Destroy() end

					local tId  = createBuilding(player, blobPos, "Turret")
					local tDat = buildingData[tId]
					if tDat then
						tDat.turretUpgrade = "Creepy"
						applyTurretUpgradeVisuals(tId, "Creepy")
					end
				end
			end
		end
	)

	-- ── LampreyEgg remote: births one egg per request from a Lamprey Nest
	-- (up to LAMPREY_NEST_MAX_EGGS concurrent). Sequence + hatch in produceLampreyEgg.
	RemoteHandler.get(Config.REMOTES.LampreyEgg).OnServerEvent:Connect(
		function(player: any, nestIds: any, unitType: any)
			local ids = type(nestIds) == "string" and {nestIds} or nestIds
			if type(ids) ~= "table" then return end

			for _, nestId in ids do
				if type(nestId) ~= "string" then continue end
				BuildingManager.requestNestEgg(player, nestId, unitType)
			end
		end
	)

	-- ── UpgradeNest remote: unlocks the rally launcher on a Lamprey Nest ──────
	RemoteHandler.get(Config.REMOTES.UpgradeNest).OnServerEvent:Connect(
		function(player: any, nestIds: any)
			local ids = type(nestIds) == "string" and {nestIds} or nestIds
			if type(ids) ~= "table" then return end

			for _, nestId in ids do
				if type(nestId) ~= "string" then continue end
				local data = buildingData[nestId]
				if not data or data.buildingType ~= "LampreyNest" then continue end
				if data.owner ~= player then continue end
				if data.isConstructing then continue end
				if data.rallyUpgrade then continue end
				if not resourceManagerRef or not resourceManagerRef.spend(player, Config.LAMPREY_NEST_RALLY_COST) then continue end

				data.rallyUpgrade = true
				local model = buildingsFolder:FindFirstChild(nestId)
				if model then
					model:SetAttribute("RallyUpgrade", true)
					-- Sprout the launcher tentacle from the nest's centre, aimed at the
					-- rally point if one is already set (otherwise it just stands tall).
					local lbase = launcherBase(data)
					local aim   = Vector3.new(0, 0, 1)
					if data.rallyPoint then
						local f = Vector3.new(data.rallyPoint.X - lbase.X, 0, data.rallyPoint.Z - lbase.Z)
						if f.Magnitude > 0.1 then aim = f.Unit end
					end
					buildNestLauncher(model, lbase, aim)
				end
			end
		end
	)

	-- ── SetNestRally remote: sets where an upgraded nest launches its eggs ────
	RemoteHandler.get(Config.REMOTES.SetNestRally).OnServerEvent:Connect(
		function(player: any, nestId: any, target: any)
			if type(nestId) ~= "string" then return end
			if typeof(target) ~= "Vector3" then return end
			local data = buildingData[nestId]
			if not data or data.buildingType ~= "LampreyNest" then return end
			if data.owner ~= player then return end
			if not data.rallyUpgrade then return end

			-- Clamp the rally point to within range of the nest (flat XZ).
			local basePos = data.base.Position
			local flat    = Vector3.new(target.X - basePos.X, 0, target.Z - basePos.Z)
			local dist    = flat.Magnitude
			if dist > Config.LAMPREY_NEST_RALLY_RANGE then
				flat = flat.Unit * Config.LAMPREY_NEST_RALLY_RANGE
			end
			local rally = Vector3.new(basePos.X + flat.X, 0, basePos.Z + flat.Z)
			data.rallyPoint = rally

			local model = buildingsFolder:FindFirstChild(nestId)
			if model then
				model:SetAttribute("RallyPoint", rally)
				-- Swing the launcher tentacle to point (loaded) at the new rally.
				if model:FindFirstChild("Launcher_Seg1") then
					local lbase = launcherBase(data)
					local aim   = Vector3.new(rally.X - lbase.X, 0, rally.Z - lbase.Z)
					aim = if aim.Magnitude > 0.1 then aim.Unit else Vector3.new(0, 0, 1)
					layoutNestLauncher(model, lbase, aim, LAUNCHER_REST)
				end
			end
		end
	)
end

-- ── Turret upgrade (server-callable) ───────────────────────────────────────────
-- Applies one of the TurretUpgrades branches to a single owned turret. Shared by
-- the UpgradeTurret remote (human players) and the AIManager (bots, which can't
-- fire client remotes). Returns true if the upgrade was applied.
function BuildingManager.upgradeTurretForPlayer(player: any, turretId: string, upgradeType: string): boolean
	if type(turretId) ~= "string" or type(upgradeType) ~= "string" then return false end

	local VALID = { Flamethrower = true, RocketLauncher = true, Artillery = true }
	if not VALID[upgradeType] then return false end

	if not researchManagerRef or not researchManagerRef.hasResearch(player, "TurretUpgrades") then return false end

	local data = buildingData[turretId]
	if not data or data.buildingType ~= "Turret" then return false end
	if data.owner ~= player then return false end
	if data.isConstructing then return false end
	if data.turretUpgrade then return false end

	local cost = (Config.TURRET_UPGRADE_COST :: any)[upgradeType] or 999
	if not resourceManagerRef or not resourceManagerRef.spend(player, cost) then return false end

	data.turretUpgrade = upgradeType
	applyTurretUpgradeVisuals(turretId, upgradeType)
	return true
end

-- ── Bonfire helpers for AI bots (server-side; no client UI involved) ──────────
-- Set which unit a bonfire summons (lets AI armies be varied, not all-Survivor).
function BuildingManager.setBonfireSummonType(player: any, deployerId: string, unitType: string): boolean
	local data = buildingData[deployerId]
	if not data or data.buildingType ~= "Deployer" or data.owner ~= player then return false end
	deployerUnitType[deployerId] = unitType
	return true
end

-- Empower a bonfire one level (same effect as the player's Empower, incl. the tiki log),
-- capped at `maxLevel`. Returns true if it upgraded. Lets AI capacity scale with difficulty.
function BuildingManager.upgradeBonfireForPlayer(player: any, deployerId: string, maxLevel: number): boolean
	local data = buildingData[deployerId]
	if not data or data.buildingType ~= "Deployer" or data.owner ~= player or data.isConstructing then return false end
	local level = deployerLevel[deployerId] or 0
	local cap   = math.min(Config.DEPLOYER_UPGRADE_MAX_LEVEL, maxLevel or 0)
	if level >= cap then return false end
	local cost = Config.bonfireUpgradeCost(level)
	if not resourceManagerRef or resourceManagerRef.get(player) < cost then return false end
	resourceManagerRef.spend(player, cost)
	level += 1
	deployerLevel[deployerId] = level
	if data.base and data.base.Parent then UnitVisuals.addBonfireLog(data.base.Parent, level) end
	return true
end

-- ── Monument upgrade ──────────────────────────────────────────────────────────

function BuildingManager.buildMonument(player: any): boolean
	if monumentByOwner[player.UserId] then return false end
	if not playerHasCC[player.UserId] then return false end
	if not resourceManagerRef or resourceManagerRef.get(player) < Config.MONUMENT_COST then return false end

	-- Find CC ground-level position
	local ccPos: Vector3?
	for _, data in buildingData do
		if data.owner == player and data.buildingType == "CommandCenter" then
			ccPos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
			break
		end
	end
	if not ccPos then return false end

	resourceManagerRef.spend(player, Config.MONUMENT_COST)
	local id = createBuilding(player, ccPos, "Monument")
	monumentByOwner[player.UserId] = id

	-- Signal construction started
	RemoteHandler.get(Config.REMOTES.MonumentProgress):FireAllClients(player.UserId, -1)
	return true
end

function BuildingManager.setLaneMode(enabled: boolean)
	laneModeActive = enabled
end

function BuildingManager.getCCPosition(player: any): Vector3?
	local ccId = playerCCId[player.UserId]
	if not ccId then return nil end
	local data = buildingData[ccId]
	if not data then return nil end
	return data.base.Position
end

return BuildingManager
