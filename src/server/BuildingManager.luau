local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe = require(Shared:WaitForChild("PerfProbe"))
local Config            = require(Shared:WaitForChild("Config"))
local RemoteHandler     = require(Shared:WaitForChild("RemoteHandler"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))
local InjectPlants      = require(Shared:WaitForChild("InjectPlants"))
local AlertManager      = require(script.Parent:WaitForChild("AlertManager"))
local GoreManager       = require(script.Parent:WaitForChild("GoreManager"))
-- Every one-shot world effect the building systems throw off (explosions, gore, bursts,
-- the spike's sounds). Pulled out of this file: it is pure scenery, and this chunk lives
-- close enough to Luau's 200-local ceiling that a dozen VFX helpers is real weight.
local BuildFX           = require(script.Parent:WaitForChild("BuildFX"))

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
-- Bonfire unit unlocks bought per id. The only thing a bonfire upgrades: it decides WHICH
-- units that one may summon (Config.BONFIRE_UNLOCK_ORDER), not how fast or how many.
local deployerUnlock:    { [string]: number } = {}
-- TEST building shares the deployer summon maps above (timers/unitType/updateAcc) but
-- tracks its two upgrades SEPARATELY: supply (capacity) and rate (summon interval).
local testSupplyLevel:   { [string]: number } = {}   -- TEST id → Supply upgrades bought
local testRateLevel:     { [string]: number } = {}   -- TEST id → Spawn Rate upgrades bought

-- Record a bonfire's unit-unlock level and mirror it onto the model, which is how every
-- client reads it back (the panel needs it for a bonfire it has merely selected, so an
-- owner-only remote would not do). Returns the unit the purchase just taught it.
local function applyBonfireUnlock(deployerId: string, level: number): string?
	deployerUnlock[deployerId] = level
	local data  = buildingData[deployerId]
	local model = data and data.base and data.base.Parent
	if model then model:SetAttribute("BonfireUnlock", level) end
	return Config.BONFIRE_UNLOCK_ORDER[level + 1]
end

-- Engineering Post research state per building id.
local engState:     { [string]: string } = {}   -- "idle" | "researching" | "ready"
local engResearchEnd: { [string]: number } = {}  -- os.clock() when the active research finishes
local engUpdateAcc:  { [string]: number } = {}   -- accumulator for periodic client progress pushes

local onPlayerWonCb: ((number) -> ())?

local monumentByOwner:       { [number]: string } = {}  -- userId → buildingId
local monumentWinTimer:      { [string]: number } = {}  -- buildingId → active seconds elapsed
local monumentHeartbeatAccum = 0
local ccIncomeAccum          = 0   -- accumulator for Command Center passive income
-- Foundry payout clocks, one per Foundry id. Each runs from when that Foundry finished
-- building, so their income ticks are staggered rather than all landing on one beat.
local foundryTimers: { [string]: number } = {}

local ccAttackThrottle: { [number]: number } = {}   -- userId → last-fire timestamp
local CC_ATTACK_THROTTLE = 5  -- seconds between CC attack notifications
local blobCooldowns:    { [string]: number } = {}   -- blobId → os.clock() expiry for soldier spawn
local nestEggs:         { [string]: number } = {}   -- LampreyNest id → count of in-flight + incubating eggs
local nestEggCounter    = 0                          -- monotonic id for naming egg parts
local nestLauncherBusy: { [string]: boolean } = {}  -- LampreyNest id → a launcher throw is mid-animation

-- Hollowed Mother "Egg Sacs" upgrade state, per Command Center (Mother) id.
local eggSacLevel:      { [string]: number } = {}   -- Mother id → Egg Sacs purchases (0–MAX)
-- Persistent nests planted by the Egg Sacs upgrade, one per purchase. Each nest is an
-- ON-DEMAND spawner, not a standing order:
--
--   planted → grows for EGG_GROW_TIME → RIPE and waiting → player picks a creature →
--   shell carries it for EGG_HATCH_TIME → creature climbs out, shell spent → regrows → ripe
--
-- Nothing hatches on its own and a nest remembers no creature between hatches: every hatch
-- is a fresh choice made at the moment it is taken.
--
-- `ripeAt` is the os.clock() the growing egg finishes at (nil once it has) and `ready` is
-- whether it is sitting ripe and can be ordered right now; `hatchAt`/`hatching` are the
-- deadline and the creature for an order already placed. Exactly one of the three phases is
-- live at a time. The egg part mirrors `ready` in an "EggReady" attribute and the creature
-- in flight in "SpawnType", so clients can read a colony's state without asking.
-- `parentId`/`dir`/`numChildren` describe this egg's place in the tentacle tree: its parent
-- node (nil = grown from the Mother), its outward growth direction (XZ unit), and how many
-- children have branched off it (used to fan the next sibling into its own direction).
-- `baseY` is the top of the egg's nest slab: the egg swells while it grows, so it is
-- re-seated on that Y every frame instead of growing symmetrically about its center.
-- `slot` is which egg of its nest this is. A nest starts with one and grows another every
-- time the Mother injects it (BuildingManager.swellEggNest), all of them sharing the one
-- bowl, the one click box and the one health bar. Only slot 1 is a node of the tentacle
-- tree -- `parentId`, `dir` and `numChildren` describe where the NEST hangs, and the eggs
-- that come after it are inside that nest rather than anywhere new.
-- `scale` sizes the shell against a normal egg. A Large nest's single PRIME egg carries
-- Config.NEST_PRIME_EGG_SCALE; every other egg is 1.
type SacEgg = { egg: BasePart, ripeAt: number?, ready: boolean, hatchAt: number?, hatching: string?, parentId: string?, dir: Vector3, numChildren: number, baseY: number, slot: number, scale: number }
local eggSacEggs:       { [string]: { [string]: SacEgg } } = {}  -- Mother id → eggId → egg state
local eggSacEggCounter  = 0
local eggSacNestCounter = 0   -- nests are named apart from the eggs they hold

-- Eggs and Egg-Sac nests that enemies can shoot. Declared up here (rather than beside the
-- egg code far below) so resetAll can clear the registry between matches; the functions
-- that drive it live with the rest of the egg code. See "Attackable eggs & nests".
type EggTarget = {
	hp: number, maxHp: number, hpBarHideAt: number?,   -- the shape applyHP reads
	base: BasePart,          -- what attackers aim at; carries the HP bar
	root: Instance,          -- what is destroyed on death (the egg, or its whole nest clump)
	owner: any,
	gore: string,            -- unit type whose blood colours the burst
	onDeath: (() -> ())?,
}
local eggTargets: { [string]: EggTarget } = {}
local eggTargetCounter = 0
local EGG_TARGET_TAG   = "egg:"
local skipNextConstruction = false  -- set true to bypass build-time for the next placeForPlayer call
local laneModeActive       = false  -- blocks non-CC placement from the PlaceBuilding remote

-- ── Drop pod delivery / on-site construction ──────────────────────────────
-- Pods launch instantly when a building is placed — no queue, no cooldown. When a
-- pod lands, its welding arms assemble the structure on-site through staged passes
-- (foundation → support beams → roof outline) before the finished building rises
-- from the ground and the scaffold sinks away.
-- One table rather than seven locals: this chunk lives close to Luau's ceiling of 200
-- locals, and a bag of build-timing numbers has no need of a register each.
-- The on-site assembly fills the structure's Config.BUILD_TIME; the FRAC fields weight how
-- that time splits across the foundation → beams → roof stages (they sum to 1). The final
-- building-rise is a fixed tail on top.
local BUILD = {
	POD_FLIGHT_TIME  = 2.5,   -- seconds from CC launch to ground impact
	FOUNDATION_FRAC  = 0.30,  -- foundation slab welds in
	BEAMS_FRAC       = 0.42,  -- support beams + scaffold posts rise
	ROOF_FRAC        = 0.28,  -- roof-outline frame welded across the top
	RISE_TIME        = 1.30,  -- finished building rises as the scaffold sinks
	RELAY_CATCH_Y    = 11,    -- studs above a relay's base to aim for (top of its CatchRing)
	SPARK_TEX        = "rbxasset://textures/particles/sparkles_main.dds",
}

local nextBuildRiseTime: number? = nil  -- overrides BUILD_TIME for the next createBuilding call

-- ── Mobile CC state ───────────────────────────────────────────────────────────
local ccMobileUnlocked: { [number]: boolean } = {}  -- userId → has paid 200 to unlock mobility
local ccMobile:         { [string]: boolean } = {}  -- ccId   → currently walking
local ccMoveTargets:    { [string]: Vector3 } = {}  -- ccId   → current move target
local playerCCId:       { [number]: string  } = {}  -- userId → their CC building id

-- ── Mother "Inject" state ─────────────────────────────────────────────────────
-- One order per Mother. She uproots (if rooted), walks to `target`, drives her spike
-- into the soil, and three plants tear their way out. `wasRooted` remembers whether to
-- root her back down once she is done.
-- `plant` set means the spike goes into one of her own grown plants instead of bare
-- ground: the plant bursts and gives up what it was growing (InjectPlants.INJECT).
-- `nest` set means it goes into one of her own egg nests instead, which swells that nest
-- and grows another egg in it (BuildingManager.swellEggNest). The two are exclusive: the
-- client aims at one thing at a time.
type InjectOrder = { target: Vector3, phase: string, wasRooted: boolean, plant: Model?, nest: Model? }  -- phase: "walk" | "inject"
local injectOrders: { [string]: InjectOrder } = {}

-- Take her out of the injection pose wherever an order is abandoned rather than finished.
local function clearInjectPose(ccId: string)
	local data = buildingData[ccId]
	if data and data.base and data.base.Parent then
		data.base:SetAttribute("Injecting", false)
	end
end

-- Shift-clicked spots waiting behind the active order, oldest first. She works through
-- them one after another without rooting back down in between; `wasRooted` rides along
-- on the running order, so she only settles once the last wound is made.
type InjectQueued = { target: Vector3, plant: Model?, nest: Model? }
local injectQueues: { [string]: { InjectQueued } } = {}
local MAX_INJECT_QUEUE = 8

-- ccId → the workspace:GetServerTimeNow() moment this Mother's spike is usable again.
-- Injecting costs nothing now, so this is the whole limiter. The same timestamp is
-- stamped on her base as an "InjectReadyAt" attribute, which replicates, so every client
-- can run the countdown on the INJECT tile without asking the server for it.
local injectReadyAt: { [string]: number } = {}

-- ccId → the Mother's energy pool, as a float that regen ticks every heartbeat. A wound
-- spends MOTHER_INJECT_ENERGY of it. Only the WHOLE number is published to the client
-- (as a "MotherEnergy" attribute), so a pool filling at 1/second replicates about once a
-- second instead of sixty times.
local motherEnergy: { [string]: number } = {}

-- Her ceiling and refill rate, which Spike Glands raise. Cached per Mother and restated
-- only when the gland count actually moves (refreshMotherEnergy), because counting glands
-- walks every building and the regen tick runs every heartbeat.
local motherEnergyMax:   { [string]: number } = {}
local motherEnergyRegen: { [string]: number } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Flip a Command Center between rooted (structure) and mobile (walking), keeping the
-- model's IsMobile value and the owner's client in sync. Shared by the MobilizeCC
-- remote and the Mother's Inject walk, which uproots her on its own.
local function setCCMobileState(ccId: string, owner: any, mobile: boolean)
	ccMobile[ccId] = mobile
	if not mobile then ccMoveTargets[ccId] = nil end

	local model = buildingsFolder and buildingsFolder:FindFirstChild(ccId)
	if model then
		local mv = model:FindFirstChild("IsMobile") :: BoolValue?
		if not mv then
			mv        = Instance.new("BoolValue")
			mv.Name   = "IsMobile"
			mv.Parent = model
		end
		(mv :: BoolValue).Value = mobile
	end

	-- AI bots are plain tables, not Players, so there is nothing to sync for them.
	if type(owner) ~= "table" then
		RemoteHandler.get(Config.REMOTES.CCMobileSync):FireClient(owner, ccId, true, mobile)
	end
end

-- Everything the Mother's injections grow lives in one workspace folder. It is scenery, so
-- it stays out of Buildings (nothing selects, targets or pathfinds around it).
local function injectPlantFolder(): Folder
	local existing = workspace:FindFirstChild("InjectPlants")
	if existing and existing:IsA("Folder") then return existing end
	local f  = Instance.new("Folder")
	f.Name   = "InjectPlants"
	f.Parent = workspace
	return f
end

-- Clear any inject plants a structure is about to be dropped on, wild or planted. Same
-- idea as felling the forest under a footprint; plants are scenery too, so they just go.
local function clearPlantsAround(pos: Vector3, radius: number)
	local folder = workspace:FindFirstChild("InjectPlants")
	if not folder then return end
	local r2 = radius * radius
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local p  = child:GetPivot().Position
			local dx = p.X - pos.X
			local dz = p.Z - pos.Z
			if dx * dx + dz * dz <= r2 then child:Destroy() end
		end
	end
end

-- The spike goes into one of her own plants: it bursts and gives up whatever it was
-- growing. A spire lets a knot of Leeches out; a pod cluster comes up as more of her own
-- egg nests. The plant is spent either way, so it comes down first.
local function harvestInjectPlant(ccId: string, owner: any, plant: Model, origin: Vector3)
	local info = InjectPlants.injectInfo(plant)
	local kind = info and info.kind
	plant:Destroy()
	BuildFX.injectBurst(origin)
	if not kind then return end
	BuildFX.injectSound(origin, BuildFX.SND_EVOLVE, 1.1)

	local function surfaceAt(x: number, z: number): number
		return (terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z)) or origin.Y
	end

	if kind == "leeches" then
		local count = Config.MOTHER_INJECT_PLANT_LEECHES
		for i = 1, count do
			local a  = ((i - 1) / count) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local d  = rng:NextNumber(4, 8)
			local px = origin.X + math.cos(a) * d
			local pz = origin.Z + math.sin(a) * d
			if unitManagerRef then
				unitManagerRef.spawnUnitNow(owner, Vector3.new(px, surfaceAt(px, pz), pz), "Leech")
			end
		end
		return
	end

	if kind == "glands" then
		-- Called through the module table for the same reason the nests below are: the
		-- planter needs createBuilding, which is declared much further down this file.
		BuildingManager.plantInjectGland(ccId, origin, Config.MOTHER_INJECT_PLANT_GLANDS)
		return
	end

	if kind == "nests" then
		-- Her own egg nests, the same ones the Egg Sacs purchase plants: tentacled out of
		-- the node tree around her, each one a clickable spawner. Called through the module
		-- table because the planter itself is declared much further down this file.
		BuildingManager.plantInjectEggNests(ccId, Config.MOTHER_INJECT_PLANT_NESTS)
	end
end

-- Is `target` clear enough of standing plants to take a spike? Every plant counts, whoever
-- grew it: a rival's growth occupies the ground just as much as her own.
local function groundClearForInject(target: Vector3): boolean
	local folder = workspace:FindFirstChild("InjectPlants")
	if not folder then return true end
	local r2 = Config.MOTHER_INJECT_CLEAR * Config.MOTHER_INJECT_CLEAR
	for _, child in folder:GetChildren() do
		if not child:IsA("Model") then continue end
		local p  = child:GetPivot().Position
		local dx = p.X - target.X
		local dz = p.Z - target.Z
		if dx * dx + dz * dz < r2 then return false end
	end
	return true
end

-- Seconds until this Mother's spike is usable again; 0 when she is ready.
local function injectCooldownLeft(ccId: string): number
	local ready = injectReadyAt[ccId]
	if not ready then return 0 end
	return math.max(0, ready - workspace:GetServerTimeNow())
end

-- Her pool right now. A Mother that has never been touched starts full of START, which
-- is what makes her openable without waiting; the table is only written once she spends
-- or banks anything.
local function energyOf(ccId: string): number
	local e = motherEnergy[ccId]
	if e == nil then return Config.MOTHER_ENERGY_START end
	return e
end

local function energyMaxOf(ccId: string): number
	return motherEnergyMax[ccId] or Config.MOTHER_ENERGY_MAX
end

local function energyRegenOf(ccId: string): number
	return motherEnergyRegen[ccId] or Config.MOTHER_ENERGY_REGEN
end

-- Write the pool and publish the whole number if it moved. Every caller goes through
-- here so the attribute can never drift from the value the server is spending. Clamping
-- to the live ceiling here is also what takes her overflow away when a gland dies.
local function setEnergy(ccId: string, value: number)
	local e = math.clamp(value, 0, energyMaxOf(ccId))
	motherEnergy[ccId] = e
	local data = buildingData[ccId]
	if not data or not data.base.Parent then return end
	local shown = math.floor(e)
	if data.base:GetAttribute("MotherEnergy") ~= shown then
		data.base:SetAttribute("MotherEnergy", shown)
	end
end

-- Seconds until the pool covers one more wound; 0 when it already does.
local function injectEnergyWait(ccId: string): number
	return Config.injectEnergyWait(energyOf(ccId))
end

-- Take one wound's worth out of the pool. False when there is not enough, which is the
-- caller's cue to abandon the run rather than drive a free spike.
local function spendInjectEnergy(ccId: string): boolean
	local e = energyOf(ccId)
	if e < Config.MOTHER_INJECT_ENERGY then return false end
	setEnergy(ccId, e - Config.MOTHER_INJECT_ENERGY)
	return true
end

-- How many Spike Glands this owner has standing. Counted live off buildingData rather
-- than tallied, so a gland shot down stops shortening her cooldown the moment it dies and
-- there is no bookkeeping to leak.
local function glandCount(owner: any): number
	local n = 0
	for _, d in buildingData do
		if d.buildingType == "Gland" and d.owner == owner and not d.isConstructing then
			n += 1
		end
	end
	return n
end

-- Restate this owner's Mother energy stats. Called when the gland count moves (one
-- raised, one shot down), which is the only thing that changes them, so the header can
-- name the real ceiling immediately instead of waiting for the next tick to notice.
-- Re-running setEnergy re-clamps her pool, which is what drops her overflow when a
-- gland is shot down and her ceiling falls.
local function refreshMotherEnergy(owner: any)
	if not owner then return end
	local glands = glandCount(owner)
	local maxE   = Config.motherEnergyMax(glands)
	local regen  = Config.motherEnergyRegen(glands)
	for ccId, d in buildingData do
		if d.buildingType == "CommandCenter" and d.owner == owner and d.base.Parent then
			motherEnergyMax[ccId]   = maxE
			motherEnergyRegen[ccId] = regen
			d.base:SetAttribute("MotherEnergyMax", maxE)
			setEnergy(ccId, energyOf(ccId))
		end
	end
end

-- Put the spike on cooldown, starting now. Both the moment it comes back AND the length
-- of the window are stamped on her base: the client needs the length to draw the sweep at
-- the right fraction, and glands make it a moving number.
local function startInjectCooldown(ccId: string)
	local data = buildingData[ccId]
	local cd   = Config.injectCooldown()
	if cd <= 0 then return end
	local ready         = workspace:GetServerTimeNow() + cd
	injectReadyAt[ccId] = ready
	if data and data.base.Parent then
		data.base:SetAttribute("InjectReadyAt", ready)
		data.base:SetAttribute("InjectCooldown", cd)
	end
end

-- She has arrived: turn to face the spot, hold while the spike goes in, then push three
-- plants up out of the ground (or burst the plant she was sent to, if that is what she
-- was aimed at). Runs on its own thread (it waits out the injection).
local function runInjection(ccId: string, order: InjectOrder)
	local data = buildingData[ccId]
	if not data then injectOrders[ccId] = nil; injectQueues[ccId] = nil; clearInjectPose(ccId); return end

	local groundY = (terrainManagerRef and terrainManagerRef.surfaceHeightAt(order.target.X, order.target.Z)) or 0
	local origin  = Vector3.new(order.target.X, groundY, order.target.Z)

	-- Face the wound while she works (same heading convention as the walk loop).
	local model = buildingsFolder:FindFirstChild(ccId)
	if model and model:IsA("Model") and data.base.Parent then
		local pos  = data.base.Position
		local flat = Vector3.new(origin.X - pos.X, 0, origin.Z - pos.Z)
		if flat.Magnitude > 0.1 then
			model:PivotTo(CFrame.new(pos) * CFrame.lookAt(pos, pos - flat.Unit).Rotation)
		end
	end

	-- The clock starts HERE, as the spike goes in -- not when the order was given. Her
	-- walk can be most of a minute, and counting it as cooldown meant the tile recovered
	-- while she was still on her way to the wound that was supposed to have cost it.
	--
	-- The wound that STARTS a run finds the clock already at zero (ordering it is what
	-- required that), so this waits for nothing. Wounds stacked behind it on the queue do
	-- wait, which is what paces a run to one wound per window.
	local wait = math.max(injectCooldownLeft(ccId), injectEnergyWait(ccId))
	if wait > 0 then
		task.wait(wait)
		-- The run can be called off from under her while she waits (a hand-issued move
		-- order, a re-root), and she can die standing there.
		if injectOrders[ccId] ~= order then return end
		if not data.base.Parent then
			injectOrders[ccId] = nil
			injectQueues[ccId] = nil
			clearInjectPose(ccId)
			return
		end
	end
	-- The pool is charged at the spike, not at the order, for the same reason the clock
	-- is: her walk can be most of a minute and a run called off on the way should cost
	-- her nothing. If the pool somehow came up short anyway, the run is abandoned rather
	-- than run for free.
	if not spendInjectEnergy(ccId) then
		injectOrders[ccId] = nil
		injectQueues[ccId] = nil
		clearInjectPose(ccId)
		return
	end
	startInjectCooldown(ccId)

	-- Replicated so every client animates the brace (MotherLegs reads this attribute),
	-- not just whoever ordered it.
	data.base:SetAttribute("Injecting", true)
	BuildFX.injectBurst(origin)
	BuildFX.injectSound(origin, BuildFX.SND_INJECT, 0.95)
	task.wait(Config.MOTHER_INJECT_DURATION)
	if data.base.Parent then data.base:SetAttribute("Injecting", false) end

	-- She may have died mid-injection; the ground still keeps what she put in it.
	local plant = order.plant
	local nest  = order.nest
	if nest then
		-- The spike goes into a standing nest: it swells rather than bursts. Raided out
		-- from under the order (or already swollen to its cap) and the spike finds
		-- nothing, exactly as with a plant someone else got to first.
		if nest.Parent then
			BuildFX.injectBurst(origin)
			BuildFX.injectSound(origin, BuildFX.SND_EVOLVE, 1.1)
			-- Through the module table: the swelling needs the egg builders, which are
			-- declared much further down this file.
			BuildingManager.swellEggNest(ccId, nest)
		end
	elseif plant then
		-- Someone (or a queued order of her own) already burst it: this spike finds
		-- nothing, and nothing grows in its place.
		if plant.Parent then harvestInjectPlant(ccId, data.owner, plant, origin) end
	else
		local folder   = injectPlantFolder()
		local variants = InjectPlants.VARIANTS
		local seed     = rng:NextInteger(1, 1000000)
		local count    = Config.MOTHER_INJECT_PLANTS
		for i = 1, count do
			local variant = variants[((i - 1) % #variants) + 1]
			local a  = ((i - 1) / count) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
			local d  = Config.MOTHER_INJECT_SPREAD * rng:NextNumber(0.45, 1.0)
			-- The ring is only where each plant WANTS to come up. Angular jitter can put
			-- two of them almost on top of each other (and the ground may already be
			-- growing something), so findSpot walks it out to where there is actually
			-- room. No room at all means this one simply does not come up, which is
			-- better than a plant growing through its neighbour.
			local px, pz = InjectPlants.findSpot(folder,
				origin.X + math.cos(a) * d, origin.Z + math.sin(a) * d, variant, rng)
			if px and pz then
				local py = (terrainManagerRef and terrainManagerRef.surfaceHeightAt(px, pz)) or groundY
				-- The plant does not simply push up here: it is carried out of the wound by
				-- a parasite that runs to this spot first (clients animate that from
				-- ParasiteFrom), so it waits underground for exactly that long. Ownership
				-- rides along because only her own plants take her spike.
				InjectPlants.grow(folder, Vector3.new(px, py, pz), variant, seed + i, false, {
					ownerUserId  = data.owner.UserId,
					parasiteFrom = origin,
					delay        = Config.injectParasiteLead(),
				})
			end
		end
	end

	injectOrders[ccId] = nil

	-- Straight on to the next shift-queued spot, if there is one.
	local queue    = injectQueues[ccId]
	local nextUp   = queue and table.remove(queue, 1) or nil
	if queue and #queue == 0 then injectQueues[ccId] = nil end
	local live     = buildingData[ccId]
	if nextUp and live and live.base.Parent then
		injectOrders[ccId] = {
			target    = nextUp.target,
			phase     = "walk",
			wasRooted = order.wasRooted,
			plant     = nextUp.plant,
			nest      = nextUp.nest,
		}
		if not ccMobile[ccId] then setCCMobileState(ccId, live.owner, true) end
		ccMoveTargets[ccId] = nextUp.target
		return
	end

	if order.wasRooted and live then
		setCCMobileState(ccId, live.owner, false)
	end
end

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
	if buildingType == "Gland"         then return Config.GLAND_SIZE end
	return Config.BUILDING_SIZE
end

-- Forward-declared so functions defined before their bodies can call them.
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

-- How briskly an uprooted Mother swings around to face where she is walking
-- (higher = snappier). Tuned to read as a big creature turning, not a turret.
local MOTHER_TURN_RATE = 4

local function isOutOfMapBounds(pos: Vector3, buildType: string): boolean
	local ns = buildingSize(buildType)
	return math.abs(pos.X) + ns.X / 2 > 432 or math.abs(pos.Z) + ns.Z / 2 > 432
end

-- ── Health bar ────────────────────────────────────────────────────────────────

-- Bar length scales with max HP (tougher structures get longer bars), within bounds.
local function hpBarWidth(maxHp: number): number
	return math.clamp(math.floor(50 + maxHp * 0.06 + 0.5), 56, 150)
end

-- `studsY` overrides how high the bar floats above the part's centre. Eggs need it:
-- their shell is tweened larger and smaller as the creature inside grows, so the
-- height read off the part at build time would be wrong for most of its life.
local function addHealthBar(part: BasePart, maxHp: number, studsY: number?)
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "HealthBar"
	bb.Size             = UDim2.new(0, hpBarWidth(maxHp), 0, 5)
	bb.StudsOffset      = Vector3.new(0, studsY or (part.Size.Y / 2 + 2.5), 0)
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
-- A player is "Hollowed" (the nest/blob creature faction: spike CC, can only place
-- Blobs + Nests) if they chose that team in the lobby, or if they're a Hollowed /
-- Swarm-mode AI bot (plain Lua table carrying isSwarm). Everyone else is Humans.
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
			-- egg-laying gaster). The team-coloured base stays as the invisible
			-- collision/HP part; all geometry comes from the shared builder so
			-- ghosts/previews stay in sync.
			base.Transparency = 1

			-- Marks this CC as the Hollowed spike rather than the Fabricator Core.
			-- Read by init.server to perch the avatar on the spike (no operator pulpit).
			model:SetAttribute("SwarmCC", true)

			-- The Mother is born UPROOTED: she stands up as a walking creature so the
			-- player carries her to a site and plants her, instead of starting rooted
			-- wherever the match happened to drop her. Clients pick this up from the
			-- IsMobile value (see the reconcile in init.client) as well as the sync
			-- event, since the event can fire before the client wires its handlers.
			ccMobile[id] = true
			local startMobile   = Instance.new("BoolValue")
			startMobile.Name    = "IsMobile"
			startMobile.Value   = true
			startMobile.Parent  = model

			-- Flip the creature 180° so its head faces +Z — i.e. toward the default
			-- camera (which sits at +Z looking toward -Z) — instead of away from it.
			-- The flip is UnitVisuals.MOTHER_FLIP rather than a literal here because the
			-- client walk animator has to undo exactly this to find her rig again
			-- (UnitVisuals.motherBodyCF); the two must never drift apart.
			UnitVisuals.buildMotherDecor(model,
				CFrame.new(position) * UnitVisuals.MOTHER_FLIP, player.TeamColor, true)

			-- The Mother's head / body / gaster are all CanQuery=false decor and
			-- sprawl well beyond and above the invisible 14×14 Base, so clicks on the
			-- creature itself miss. Drop in a roomy invisible, query-able hitbox over the
			-- whole creature — hitBuilding matches any descendant of the model, so this
			-- alone makes the Mother easy to select. It's a model child, so it rides along
			-- with uproot/downroot PivotTo moves and the construction sink animation.
			local mhb        = Instance.new("Part")
			mhb.Name         = "ClickHitbox"
			mhb.Size         = Vector3.new(18, 16, 24) * UnitVisuals.MOTHER_SCALE
			mhb.CFrame       = CFrame.new(position + Vector3.new(0, 8 * UnitVisuals.MOTHER_SCALE, 0))
			mhb.Transparency = 1
			mhb.Anchored     = true
			mhb.CanCollide   = false
			mhb.CanQuery     = true
			mhb.CanTouch     = false
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
		-- preview stays in sync. A floating "Refining +N" label is added below.
		base.Transparency = 1
		UnitVisuals.buildFoundryDecor(model, CFrame.new(position), player.TeamColor, true)

	elseif buildingType == "EngineeringPost" then
		-- Engineering Post: invisible logic box + shared lab decor; a hidden "research
		-- ready" notifier billboard is added below and toggled when research completes.
		base.Transparency = 1
		UnitVisuals.buildEngineeringPostDecor(model, CFrame.new(position), player.TeamColor, true)

	elseif buildingType == "Gland" then
		-- Spike Gland: invisible logic box + the shared organ decor. Never placed by hand;
		-- it only ever comes up out of a frond the Mother injected.
		base.Transparency = 1
		UnitVisuals.buildGlandDecor(model, CFrame.new(position), player.TeamColor, true)

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
	clearPlantsAround(position, math.max(size.X, size.Z) / 2 + 3)

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
		-- Floating "Refining +N" readout, updated by the income tick. Server-created so
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
		lbl.Text                   = "Refining +0"
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
	if buildingType == "Foundry" then
		-- Seeded here, but only advanced once isConstructing clears, so the payout clock
		-- starts from the moment this Foundry is standing.
		foundryTimers[id] = 0
	end
	if buildingType == "Deployer" then
		deployerTimers[id]    = 0
		deployerUnitType[id]  = "Survivor"
		deployerUpdateAcc[id] = 0
		-- Knows only the first unit on the ladder until its unlocks are bought. The level
		-- rides on the model as an attribute so every client can read it straight off the
		-- bonfire it has selected (see DeployerPanel).
		deployerUnlock[id]    = 0
		model:SetAttribute("BonfireUnlock", 0)
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
					task.spawn(BuildFX.wormBurst, position + Vector3.new(0, 5, 0))
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

-- ── On-site construction (welding-arm assembly) ────────────────────────────

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
		pe.Texture       = BUILD.SPARK_TEX
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
	local F  = assembly * BUILD.FOUNDATION_FRAC
	local B  = F + assembly * BUILD.BEAMS_FRAC
	local R  = B + assembly * BUILD.ROOF_FRAC
	local Ri = R + BUILD.RISE_TIME

	local built    = false
	local podParts: { BasePart } = {}
	local sinkBase: { [BasePart]: CFrame } = {}
	local elapsed  = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onHeartbeat("BuildingManager", function(dt)
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
					nextBuildRiseTime = BUILD.RISE_TIME
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
		endPos   = Vector3.new(rp.X, rp.Y + BUILD.RELAY_CATCH_Y, rp.Z)
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
	conn = PerfProbe.onHeartbeat("BuildingManager", function(dt)
		if not pod or not pod.Parent then conn:Disconnect(); return end
		elapsed = elapsed + dt
		local t    = math.min(elapsed / BUILD.POD_FLIGHT_TIME, 1)
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
			if relayModel then BuildFX.relayFlash(relayModel) end

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

-- Per-owner count of finished structures, keyed by owner id string (players AND
-- AI). Sampled periodically for the end-screen performance graph.
function BuildingManager.getBuildingTally(): { [string]: number }
	local out: { [string]: number } = {}
	for _, data in buildingData do
		if data.isConstructing or not data.owner then continue end
		local key = tostring(data.owner.UserId)
		out[key] = (out[key] or 0) + 1
	end
	return out
end

function BuildingManager.resetAll()
	for _, model in buildingsFolder:GetChildren() do model:Destroy() end
	buildingData             = {}
	pendingBuildings         = {}
	playerHasCC              = {}
	turretTimers             = {}
	deployerTimers           = {}
	deployerUnlock           = {}
	deployerUnitType         = {}
	deployerUpdateAcc        = {}
	testSupplyLevel          = {}
	testRateLevel            = {}
	eggSacLevel              = {}
	eggSacEggs               = {}
	eggTargets               = {}
	local nestRoot = workspace:FindFirstChild("EggNests")
	if nestRoot then nestRoot:Destroy() end
	eggNestsRoot = nil
	monumentByOwner          = {}
	monumentWinTimer         = {}
	monumentHeartbeatAccum   = 0
	ccIncomeAccum            = 0
	foundryTimers            = {}
	engState                 = {}
	engResearchEnd           = {}
	engUpdateAcc             = {}
	blobCooldowns            = {}
	ccMobileUnlocked         = {}
	ccMobile                 = {}
	ccMoveTargets            = {}
	injectOrders             = {}
	injectQueues             = {}
	injectReadyAt            = {}
	motherEnergy             = {}
	motherEnergyMax          = {}
	motherEnergyRegen        = {}
	playerCCId               = {}
	local plants = workspace:FindFirstChild("InjectPlants")
	if plants then plants:Destroy() end
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

-- ── Launcher tentacle (rally-upgraded nests) ────────────────────────────────
-- A single large tentacle sprouting from the centre of an upgraded nest. It aims
-- at the rally point and whips toward it to fling each egg in that direction.
-- Grouped into one table rather than six locals: this module sits near Luau's 200-local
-- ceiling per chunk, and a bag of constants costs one register instead of six.
local LAUNCHER = {
	M    = 5,      -- spine segments
	H    = 16,     -- length (larger than the decorative tentacles)
	BT   = 2.3,    -- base thickness
	TT   = 0.9,    -- tip thickness
	COL  = Color3.fromRGB(96, 32, 66),
	REST = 0.55,   -- rest lean (radians) toward the aim direction
}

-- Where an upgraded nest's launcher tentacle sprouts from (centre, near the Core).
local function launcherBase(data: BuildingData): Vector3
	local p = data.base.Position
	return Vector3.new(p.X, p.Y - buildingSize("LampreyNest").Y / 2 + 1.8, p.Z)
end

-- Curved spine of the launcher: rises from `basePos`, bending toward the horizontal
-- `aimDir` by `lean` radians (negative leans back, away from aim).
local function launcherSpine(basePos: Vector3, aimDir: Vector3, lean: number): { Vector3 }
	local segLen = LAUNCHER.H / LAUNCHER.M
	local pts    = { basePos }
	local pos    = basePos
	for j = 1, LAUNCHER.M do
		local s    = j / LAUNCHER.M
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
	for j = 1, LAUNCHER.M do
		local segP = model:FindFirstChild("Launcher_Seg" .. j) :: BasePart?
		if segP then
			local th = LAUNCHER.BT + (LAUNCHER.TT - LAUNCHER.BT) * ((j - 1) / LAUNCHER.M)
			UnitVisuals.orientYBetween(segP, pts[j], pts[j + 1], th)
		end
		if j < LAUNCHER.M then
			local knot = model:FindFirstChild("Launcher_Knot" .. j) :: BasePart?
			if knot then
				local th = LAUNCHER.BT + (LAUNCHER.TT - LAUNCHER.BT) * (j / LAUNCHER.M)
				knot.Size   = Vector3.new(th, th, th)
				knot.CFrame = CFrame.new(pts[j + 1])
			end
		end
	end
	local tipPos = pts[LAUNCHER.M + 1]
	local tipDir = (pts[LAUNCHER.M + 1] - pts[LAUNCHER.M]).Unit
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
		p.Color      = LAUNCHER.COL
		p.Material   = Enum.Material.SmoothPlastic
		p.Size       = Vector3.new(1, 1, 1)
		p.Anchored   = true
		p.CanCollide = false
		p.CanQuery   = false
		p.CanTouch   = false
		p.CastShadow = false
		p.Parent     = model
		return p
	end
	for j = 1, LAUNCHER.M do lp("Launcher_Seg" .. j) end
	for j = 1, LAUNCHER.M - 1 do lp("Launcher_Knot" .. j, Enum.PartType.Ball) end
	local tip = lp("Launcher_Tip", Enum.PartType.Ball)
	tip.Size  = Vector3.new(1.9, 1.9, 1.9)
	tip.Color = Color3.fromRGB(66, 22, 46)
	layoutNestLauncher(model, basePos, aimDir, LAUNCHER.REST)
end

-- Animate the launcher whipping toward `aimDir` and fling `egg` to `target`.
-- Blocks (stepping via task.wait) until the egg reaches the target.
local function throwNestLauncher(model: Instance, basePos: Vector3, aimDir: Vector3, egg: BasePart, eggFull: Vector3, target: Vector3)
	local WIND, WHIP, FLIGHT      = 0.18, 0.16, 0.62
	local restLean, backLean, whipLean = LAUNCHER.REST, -0.55, 1.75

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

-- ── Attackable eggs & nests ───────────────────────────────────────────────────
-- A clutch on the ground is a target, not scenery. Eggs are not buildings though —
-- they live outside workspace.Buildings and have no BuildingData — so they get their
-- own registry keyed by an "egg:" id. getNearestEnemyBuilding hands those ids out and
-- BuildingManager.damage routes them back here, which means every existing attacker
-- (units, turrets, AI bots, a player's focus-fire order) can kill a clutch without
-- knowing eggs exist.
--
-- `base` is what attackers aim at and what carries the HP bar; `root` is what gets
-- destroyed when it dies — the egg part itself for a loose egg, the whole clump for an
-- Egg-Sac nest. Entries are pruned lazily: anything whose parts have left the workspace
-- (hatched, or razed along with its Mother) is dropped the next time it's looked at, so
-- no caller has to unregister by hand. The registry itself is declared at the top of the
-- file, next to the rest of the egg state.
local function isEggTargetId(id: string): boolean
	return id:sub(1, #EGG_TARGET_TAG) == EGG_TARGET_TAG
end

-- Make an egg shootable. The id is stamped on both instances as an EggTargetId
-- attribute, which is how a client turns a right-click on a clutch into a focus order.
local function registerEggTarget(base: BasePart, root: Instance, owner: any, maxHp: number,
	gore: string, barY: number?, onDeath: (() -> ())?): string
	eggTargetCounter += 1
	local id = EGG_TARGET_TAG .. eggTargetCounter
	eggTargets[id] = {
		hp = maxHp, maxHp = maxHp, base = base, root = root,
		owner = owner, gore = gore, onDeath = onDeath,
	}
	addHealthBar(base, maxHp, barY)
	local ownerId = (owner and owner.UserId) or 0
	base:SetAttribute("EggTargetId", id)
	base:SetAttribute("EggTargetOwner", ownerId)
	if root ~= base then
		root:SetAttribute("EggTargetId", id)
		root:SetAttribute("EggTargetOwner", ownerId)
	end
	return id
end

-- The live entry for `id`, or nil — pruning it if what it pointed at is already gone.
local function eggTargetAt(id: string): EggTarget?
	local e = eggTargets[id]
	if not e then return nil end
	if not e.base.Parent or not e.root.Parent then
		eggTargets[id] = nil
		return nil
	end
	return e
end

-- Burst an egg: shell shards, a splash of whatever was growing inside, then the whole
-- thing comes down. onDeath lets the owner settle up (a nest reclaiming its egg slot).
local function killEggTarget(id: string, e: EggTarget)
	eggTargets[id] = nil
	local pos = e.base.Position
	-- Take the shell down first: the gore's ground raycast would otherwise land the
	-- blood pool on top of the egg it just burst, leaving a stain floating in the air.
	if e.root.Parent then e.root:Destroy() end
	BuildFX.eggHatch(pos)
	GoreManager.spawn(e.gore, pos, 2, e.maxHp)
	if e.onDeath then task.spawn(e.onDeath) end
end

local function damageEggTarget(id: string, amount: number)
	local e = eggTargetAt(id)
	if not e then return end
	e.hp = math.max(0, e.hp - amount)
	applyHP(e :: any, true)   -- EggTarget carries the hp/maxHp/base/hpBarHideAt applyHP reads
	if e.hp > 0 then
		AlertManager.report(e.owner, e.base.Position, "base")   -- "under attack" map ping
		return
	end
	killEggTarget(id, e)
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
	local eggFull = Vector3.new(3, 3.8, 3)
	-- Eggs must rest on whichever terrain tier they land on — a fixed world Y left
	-- them buried below a raised nest (looking like nothing spawned). Resolve the
	-- settle height per-XZ from the real terrain surface.
	local function settleYAt(x: number, z: number): number
		local surf = terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z) or 0
		return surf + eggFull.Y / 2
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
	egg.Size            = eggFull * 0.4
	egg.Position        = startPos
	egg.Color           = eggColor
	egg.Material        = Enum.Material.Neon
	egg.Anchored        = true
	egg.CanCollide      = false
	egg.CanQuery        = false
	egg.CanTouch        = false
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
		throwNestLauncher(model, lbase, aim, egg, eggFull, target)
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
			Position = apex, Size = eggFull,
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

	-- Down and vulnerable: an enemy that reaches the clutch can pop the egg before it
	-- hatches, and doing so gives the nest its reserved slot back. Only now does it take
	-- raycasts — while it was arcing through the air it was untouchable scenery.
	egg.CanQuery = true
	egg.CanTouch = false
	registerEggTarget(egg, egg, player, Config.EGG_HP, unitType, nil, function()
		nestEggs[nestId] = math.max(0, (nestEggs[nestId] or 1) - 1)
	end)

	-- ── Incubate: the egg breathes green until it hatches ─────────────────────
	TweenService:Create(egg,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Size = eggFull * 1.12, Transparency = 0,
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
	BuildFX.eggHatch(hatchPos)
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
-- ── Where a Mother's eggs live ──────────────────────────────────────────────
-- Eggs are laid in the GROUND, not carried by the Mother, so they live in their own
-- workspace folder instead of under her model. An uprooted Mother therefore walks out
-- from under her clutch and leaves it exactly where she laid it, rather than dragging
-- everything along with her PivotTo. Grouped per-CC so one Mother's whole clutch can
-- be cleared when she dies. Used by both her spat eggs and her Egg-Sac nests.
local eggNestsRoot: Folder? = nil

local function eggNestFolder(ccId: string): Folder
	if not eggNestsRoot or not eggNestsRoot.Parent then
		local existing = workspace:FindFirstChild("EggNests") :: Folder?
		if not existing then
			existing        = Instance.new("Folder")
			existing.Name   = "EggNests"
			existing.Parent = workspace
		end
		eggNestsRoot = existing
	end
	local root = eggNestsRoot :: Folder
	local sub  = root:FindFirstChild(ccId) :: Folder?
	if not sub then
		sub        = Instance.new("Folder")
		sub.Name   = ccId
		sub.Parent = root
	end
	return sub :: Folder
end

-- Drop one Mother's clutch (spat eggs, nests, and the tentacles linking them).
local function clearEggNests(ccId: string)
	local root = workspace:FindFirstChild("EggNests")
	local sub  = root and root:FindFirstChild(ccId)
	if sub then sub:Destroy() end
end

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

	local eggFull = Vector3.new(2.6, 3.2, 2.6)
	local function settleYAt(x: number, z: number): number
		local surf = terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z) or 0
		return surf + eggFull.Y / 2
	end
	local clutch = eggNestFolder(ccId)
	local function overlapsEgg(x: number, z: number): boolean
		for _, child in clutch:GetChildren() do
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

	-- Egg lives in the Mother's clutch folder, NOT under her model — she walks off and
	-- leaves it lying where she laid it instead of towing it around.
	motherEggCounter += 1
	local egg           = Instance.new("Part")
	egg.Name            = "MotherEgg_" .. motherEggCounter
	egg.Shape           = Enum.PartType.Ball
	egg.Size            = eggFull * 0.4
	egg.Position        = startPos
	egg.Color           = Color3.fromRGB(255, 120, 60)   -- warm orange (Hagfish-eye glow)
	egg.Material        = Enum.Material.Neon
	egg.Anchored        = true
	egg.CanCollide      = false
	egg.CanQuery        = false
	egg.CanTouch        = false
	egg.CastShadow      = false
	egg.Transparency    = 0.1
	egg.Parent          = clutch
	local eggLight      = Instance.new("PointLight")
	eggLight.Color      = Color3.fromRGB(255, 140, 70)
	eggLight.Brightness = 3
	eggLight.Range      = 12
	eggLight.Parent     = egg

	-- Progress bar floating on top of the egg.
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "EggProgress"
	bb.Size             = UDim2.fromOffset(48, 7)
	bb.StudsOffset      = Vector3.new(0, eggFull.Y * 0.95, 0)
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
		Position = apex, Size = eggFull,
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

	-- Lying in the open in front of the Mother, so it can be shot before it hatches.
	egg.CanQuery = true
	egg.CanTouch = false
	registerEggTarget(egg, egg, player, Config.EGG_HP, unitType, nil)

	-- Incubate: the egg breathes while the progress bar fills over the incubation.
	bb.Enabled = true
	TweenService:Create(egg,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = eggFull * 1.12 }):Play()
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
	BuildFX.eggHatch(hatchPos)
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(hatchPos, hatchPos, "LampreyEggHatch")
	if unitManagerRef then
		unitManagerRef.spawnUnitNow(player, Vector3.new(hatchPos.X, 0, hatchPos.Z), unitType)
	end
end

-- ── Hollowed Mother "Egg Sacs" upgrade ──────────────────────────────────────────
-- Eggs are scattered around the Mother like an electron cloud / slime-mold colony:
-- densest near the center, thinning outward, and only spilling further out once the
-- inner ground is crowded. When an egg is bought a wobbly "creepygrass" tentacle (dark
-- veins + purple glow) grows out from the Mother / nearest egg at a FIXED speed —
-- so a farther egg simply takes longer — and once
-- it reaches the spot the egg forms at the tip. The tentacles double as the edges of a
-- growing node network.
-- One table rather than ten locals: this module sits near Luau's 200-local ceiling per
-- chunk, and none of these are read anywhere hot enough to want a register of their own.
local EGG = {
	GRASS_COLOR    = Color3.fromRGB(10, 9, 13),
	GLOW_COLOR     = Color3.fromRGB(150, 55, 225),  -- swarm purple
	MIN_SPACING    = 11,                            -- min distance between egg centers
	TENTACLE_SPEED = 22,                            -- studs/sec the tentacle grows (fixed; distance → time)
	BRANCH_MIN     = 11.5,                          -- min distance a child sits from its parent node
	BRANCH_MAX     = 22,                            -- max (each egg picks a random length in between → uneven, organic spacing)
	GOLDEN         = math.rad(137.5),               -- root children fan around the Mother by the golden angle
	ROOT_MAX_KIDS  = 6,                             -- eggs that attach directly to the Mother
	NODE_MAX_KIDS  = 3,                             -- children each egg branches into
	NODE_FAN       = { 0, math.rad(58), math.rad(-58) },  -- sibling fan slots around a node's outward dir
}

-- A thin dark vein hugging the ground from `a` to `b` (both already at ground Y). Used for
-- both the creepygrass strands and the node-network edges between eggs.
local function addGroundVein(parent: Instance, a: Vector3, b: Vector3, width: number)
	local dir = b - a
	local len = dir.Magnitude
	if len < 1e-3 then return end
	local mid = (a + b) * 0.5
	local seg        = Instance.new("Part")
	seg.Size         = Vector3.new(width, 0.16, len + 0.15)   -- slight overlap hides seams
	seg.Color        = EGG.GRASS_COLOR
	seg.Transparency = 0.45
	seg.Material     = Enum.Material.Slate
	seg.Anchored     = true
	seg.CanCollide   = false
	seg.CanQuery     = false
	seg.CanTouch     = false
	seg.CastShadow   = false
	seg.Massless     = true
	seg.CFrame       = CFrame.lookAt(mid, b)
	seg.Parent       = parent
end

local function addGlowBlob(parent: Instance, pos: Vector3, size: number)
	local g        = Instance.new("Part")
	g.Shape        = Enum.PartType.Ball
	g.Size         = Vector3.new(size, size, size)
	g.Color        = EGG.GLOW_COLOR
	g.Material     = Enum.Material.Neon
	g.Anchored     = true
	g.CanCollide   = false
	g.CanQuery     = false
	g.CanTouch     = false
	g.CastShadow   = false
	g.Massless     = true
	g.CFrame       = CFrame.new(pos.X, pos.Y + size * 0.4, pos.Z)
	g.Parent       = parent
	return g
end

-- Sprout a handful of short, wandering creepygrass roots + purple glow nubs from an egg's
-- base, parented into its clump so they clean up with it.
local function buildEggGrass(clump: Model, center: Vector3, groundY: number)
	local y       = groundY + 0.09
	local strands = math.random(5, 8)
	local baseAng = math.random() * math.pi * 2
	for i = 1, strands do
		local ang   = baseAng + (i / strands) * math.pi * 2 + (math.random() - 0.5) * 0.6
		local pos   = Vector3.new(center.X, y, center.Z)
		local width = 0.5
		local segs  = math.random(2, 3)
		local step  = (2 + math.random() * 2.5) / segs
		for _ = 1, segs do
			ang += (math.random() - 0.5) * 0.7
			local nextPos = pos + Vector3.new(math.cos(ang), 0, math.sin(ang)) * step
			addGroundVein(clump, pos, nextPos, width)
			pos    = nextPos
			width *= 0.68
		end
		if math.random() < 0.4 then addGlowBlob(clump, pos, 0.25 + math.random() * 0.25) end
	end
	-- A brighter node glow right at the egg's foot so it reads as a network node.
	addGlowBlob(clump, Vector3.new(center.X, y, center.Z), 0.55)
end

-- Ground height at an XZ (falls back to 0 if terrain isn't ready).
local function eggGroundY(x: number, z: number): number
	return (terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z)) or 0
end

-- Rotate an XZ vector about the Y axis.
local function eggRotY(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

-- True if (x,z) is within EGG.MIN_SPACING of any of this Mother's nests. Only the first
-- egg of each is consulted: the rest share its bowl, so they stand on ground that is
-- already spoken for.
local function eggTooClose(ccId: string, x: number, z: number): boolean
	local eggs = eggSacEggs[ccId]
	if not eggs then return false end
	for _, e in eggs do
		if e.slot == 1 and e.egg.Parent then
			local p = e.egg.Position
			local dx, dz = p.X - x, p.Z - z
			if dx * dx + dz * dz < EGG.MIN_SPACING * EGG.MIN_SPACING then return true end
		end
	end
	return false
end

-- Try to seat a child out from `(fromX,fromZ)` along `dir`. Each egg picks its OWN random
-- branch length (so nest spacing is uneven / organic), then the length grows and the angle
-- nudges until it clears every other egg. Returns nil if it can't.
local function eggTryBranch(ccId: string, fromX: number, fromZ: number, dir: Vector3): Vector3?
	local baseLen = EGG.BRANCH_MIN + math.random() * (EGG.BRANCH_MAX - EGG.BRANCH_MIN)
	for _, extra in { 0, 3, 6, 10, 15 } do
		local len = baseLen + extra
		for _, aj in { 0, 0.22, -0.22, 0.45, -0.45 } do
			local d = eggRotY(dir, aj)
			local x = fromX + d.X * len
			local z = fromZ + d.Z * len
			if not eggTooClose(ccId, x, z) then
				return Vector3.new(x, eggGroundY(x, z), z)
			end
		end
	end
	return nil
end

-- Plan the next egg as a node in the tentacle tree. Picks a not-yet-full parent (biased to
-- inner nodes so the colony packs dense near the Mother and fans outward — the electron-cloud
-- spread), and aims the new child into its OWN direction so siblings never overlap: root
-- children fan around the Mother by the golden angle; deeper children fan ±58° around their
-- parent's outward direction. Returns (eggPos, originPos, parentId, outwardDir).
local function planEgg(ccId: string, base: BasePart): (Vector3, Vector3, string?, Vector3)
	local eggs     = eggSacEggs[ccId]
	local center   = base.Position
	local motherPos = Vector3.new(center.X, eggGroundY(center.X, center.Z), center.Z)

	-- Candidate parents (each with a proposed outward direction for its next child).
	type Cand = { pos: Vector3, dir: Vector3, parentId: string?, score: number }
	local cands: { Cand } = {}

	-- Only slot-1 eggs are nodes of the tree; the eggs an injection adds sit inside a nest
	-- that is already hanging somewhere and are not places anything can branch from.
	local rootCount = 0
	if eggs then for _, e in eggs do if e.slot == 1 and e.egg.Parent and not e.parentId then rootCount += 1 end end end
	if rootCount < EGG.ROOT_MAX_KIDS then
		local ang = rootCount * EGG.GOLDEN + (math.random() - 0.5) * 0.35   -- golden spread + organic jitter
		table.insert(cands, {
			pos = motherPos, parentId = nil,
			dir = Vector3.new(math.cos(ang), 0, math.sin(ang)),
			score = math.random() * EGG.MIN_SPACING,  -- inner (dist 0) + jitter
		})
	end
	if eggs then
		for id, e in eggs do
			if e.slot == 1 and e.egg.Parent and e.numChildren < EGG.NODE_MAX_KIDS then
				local p    = e.egg.Position
				local dist = math.sqrt((p.X - center.X) ^ 2 + (p.Z - center.Z) ^ 2)
				local fan  = (EGG.NODE_FAN[e.numChildren + 1] or 0) + (math.random() - 0.5) * 0.35
				table.insert(cands, {
					pos = Vector3.new(p.X, eggGroundY(p.X, p.Z), p.Z), parentId = id,
					dir = eggRotY(e.dir, fan),                          -- fan around parent's outward dir + jitter
					score = dist + math.random() * (EGG.MIN_SPACING * 1.5),  -- inner-biased, jittered
				})
			end
		end
	end

	-- Inner-first with jitter, then take the first candidate that finds a clear spot.
	table.sort(cands, function(a, b) return a.score < b.score end)
	for _, c in cands do
		local pos = eggTryBranch(ccId, c.pos.X, c.pos.Z, c.dir)
		if pos then
			local out = Vector3.new(pos.X - c.pos.X, 0, pos.Z - c.pos.Z)
			out = out.Magnitude > 1e-3 and out.Unit or c.dir
			return pos, c.pos, c.parentId, out
		end
	end

	-- Fallback (everything crowded): drop on a random outer ring off the Mother.
	local eggCount = 0
	if eggs then for _, e in eggs do if e.slot == 1 then eggCount += 1 end end end
	local ang  = math.random() * math.pi * 2
	local r    = Config.COMMAND_CENTER_SIZE.X / 2 + 6 + eggCount * 1.5
	local x, z = center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r
	local pos  = Vector3.new(x, eggGroundY(x, z), z)
	return pos, motherPos, nil, Vector3.new(math.cos(ang), 0, math.sin(ang))
end

-- Grow a wobbly creepygrass tentacle from `from` to `to`, revealing it segment-by-segment
-- at a FIXED speed (more distance → more segments → longer growth). Yields until it reaches
-- the far end. The finished tentacle stays as the node-network edge. Aborts if the Mother
-- dies mid-grow. `parent` is the CC model.
local function growTentacle(parent: Instance, ccId: string, from: Vector3, to: Vector3)
	local container   = Instance.new("Folder")
	container.Name    = "EggTentacle"
	container.Parent  = parent

	local a    = Vector3.new(from.X, 0, from.Z)
	local b    = Vector3.new(to.X, 0, to.Z)
	local flat = b - a
	local dist = flat.Magnitude
	if dist < 0.5 then return end
	local perp = Vector3.new(-flat.Z, 0, flat.X)
	perp = perp.Magnitude > 1e-3 and perp.Unit or Vector3.new(1, 0, 0)

	local segLen  = 1.8
	local nSeg    = math.max(2, math.ceil(dist / segLen))
	local wiggles = 1.5 + math.random() * 1.5          -- lateral wobble waves along the length
	local ampMax  = 2.6
	local phase   = math.random() * math.pi * 2

	-- Precompute the wobbly ground path (offset tapers to 0 at both ends).
	local pts = table.create(nSeg + 1)
	for i = 0, nSeg do
		local t    = i / nSeg
		local mid  = a:Lerp(b, t)
		local off  = math.sin(phase + t * math.pi * 2 * wiggles) * (math.sin(t * math.pi) * ampMax)
		local px   = mid.X + perp.X * off
		local pz   = mid.Z + perp.Z * off
		pts[i + 1] = Vector3.new(px, eggGroundY(px, pz) + 0.12, pz)
	end

	for i = 1, nSeg do
		if not parent.Parent or not buildingData[ccId] then container:Destroy(); return end
		local t     = i / nSeg
		local width = 1.5 * (1 - t) + 0.3              -- taper thick base → thin tip
		addGroundVein(container, pts[i], pts[i + 1], width)
		if math.random() < 0.12 then addGlowBlob(container, pts[i + 1], 0.28 + math.random() * 0.2) end
		task.wait(segLen / EGG.TENTACLE_SPEED)
	end
end

-- Emoji shown on top of an egg for the unit it is set to hatch.
EGG.FULL = Vector3.new(2.2, 2.7, 2.2)

-- A freshly-planted nest is not empty: a dormant egg sits in its socket from the moment
-- the nest pops in, so the colony reads as eggs rather than bowls. It is inert — no
-- breathing, no light, no progress bar — until the player picks the unit it should keep
-- alive, at which point incubation takes over and swells it. Once that first creature
-- hatches the egg is spent for good; the nest only grows another when its unit dies.
EGG.DORMANT       = EGG.FULL * 0.78
EGG.DORMANT_TRANS = 0.18

-- ── The nest an Egg Sac egg is laid in ──────────────────────────────────────────
-- A shallow bramble bowl rather than a slab: a ring of dark flesh ribs that lean out of
-- the ground and curl back inward over the socket, a few pale bone slivers woven across
-- the rim, and a black goo pool in the middle that the egg sits in.
-- One table rather than nine locals; see LAUNCHER above for why.
local NEST = {
	FLESH    = Color3.fromRGB(24, 15, 26),
	FLESH_HI = Color3.fromRGB(38, 22, 40),
	BONE     = Color3.fromRGB(96, 84, 84),
	RIM_R    = 2.95,   -- radius the rim curls over at
	RIBS     = 15,
	FLOOR_Y  = 0.3,    -- top of the goo pool: where an egg sits
	-- The socket pool. Black and unlit at rest; it only warms up while a creature is
	-- incubating, so the glow reads as the egg growing rather than as nest decoration.
	GOO_COLOR = Color3.fromRGB(8, 7, 10),
	GOO_LIGHT = Color3.fromRGB(255, 140, 70),   -- matches the egg's own light
	GOO_REST  = 0,                              -- goo light brightness with nothing growing
}

-- One tapered strand from `a` to `b`. Unlike addGroundVein this one is free in 3D, so the
-- ribs can climb and curl.
local function addNestStrand(parent: Instance, a: Vector3, b: Vector3, width: number, color: Color3)
	local dir = b - a
	local len = dir.Magnitude
	if len < 1e-3 then return end
	local up = math.abs(dir.Unit.Y) > 0.98 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
	local p        = Instance.new("Part")
	p.Name         = "NestRib"
	p.Size         = Vector3.new(width, width * 0.85, len + 0.14)   -- slight overlap hides seams
	p.CFrame       = CFrame.lookAt((a + b) * 0.5, b, up)
	p.Color        = color
	p.Material     = Enum.Material.Slate
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CanTouch     = false
	p.CastShadow   = false
	p.Massless     = true
	p.Transparency = 1          -- faded in by revealEggClump
	p.Parent       = parent
end

-- A flat disc lying on the ground (Cylinder parts are circular about their X axis, so it
-- gets stood on end). Used for the nest floor and its glowing goo pool.
local function addNestDisc(parent: Instance, center: Vector3, diameter: number, thickness: number,
	color: Color3, material: Enum.Material, name: string): BasePart
	local d        = Instance.new("Part")
	d.Name         = name
	d.Shape        = Enum.PartType.Cylinder
	d.Size         = Vector3.new(thickness, diameter, diameter)
	d.CFrame       = CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2)
	d.Color        = color
	d.Material     = material
	d.Anchored     = true
	d.CanCollide   = false
	d.CanQuery     = false
	d.CanTouch     = false
	d.CastShadow   = false
	d.Massless     = true
	d.Transparency = 1
	d.Parent       = parent
	return d
end

-- Build the bowl at `nestPos` (ground level) under `clump`. Every part starts invisible;
-- revealEggClump fades them in to the transparency stamped on each one's "ShownAt" attribute.
local function buildEggNest(clump: Model, nestPos: Vector3)
	local ground = nestPos.Y

	-- Wet floor, then the goo pool that sits in it (the socket the egg forms in).
	addNestDisc(clump, nestPos + Vector3.new(0, 0.12, 0), NEST.RIM_R * 1.75, 0.24,
		Color3.fromRGB(18, 11, 20), Enum.Material.Slate, "NestFloor")
	local goo = addNestDisc(clump, nestPos + Vector3.new(0, NEST.FLOOR_Y, 0), NEST.RIM_R * 1.25, 0.22,
		NEST.GOO_COLOR, Enum.Material.Slate, "NestGoo")
	goo:SetAttribute("ShownAt", 0.55)

	-- Rim ribs: each roots just outside the pool, leans out and up to the rim, then curls
	-- back in over the socket. Lengths and angles jitter so no two nests read the same.
	for i = 1, NEST.RIBS do
		local ang  = (i / NEST.RIBS) * math.pi * 2 + (math.random() - 0.5) * 0.2
		local out  = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local r0   = NEST.RIM_R * (0.6 + math.random() * 0.12)
		local h    = 1.1 + math.random() * 0.6
		local root = nestPos + out * r0 + Vector3.new(0, 0.05, 0)
		local rim  = nestPos + out * NEST.RIM_R + Vector3.new(0, h * 0.66, 0)
		local tip  = rim - out * (0.5 + math.random() * 0.55) + Vector3.new(0, h * 0.38, 0)
		local col  = if math.random() < 0.3 then NEST.FLESH_HI else NEST.FLESH
		addNestStrand(clump, root, rim, 0.66, col)
		addNestStrand(clump, rim,  tip, 0.4,  col)
	end

	-- Pale bone slivers laid across the rim, tangential so they read as woven in.
	for _ = 1, 5 do
		local ang  = math.random() * math.pi * 2
		local span = 0.5 + math.random() * 0.35
		local y    = ground + 0.75 + math.random() * 0.45
		local a    = Vector3.new(nestPos.X + math.cos(ang) * NEST.RIM_R, y, nestPos.Z + math.sin(ang) * NEST.RIM_R)
		local b    = Vector3.new(nestPos.X + math.cos(ang + span) * NEST.RIM_R, y + (math.random() - 0.5) * 0.3,
			nestPos.Z + math.sin(ang + span) * NEST.RIM_R)
		addNestStrand(clump, a, b, 0.3, NEST.BONE)
	end

	-- Glow nubs tucked between the ribs so an empty nest still looks alive at night.
	for _ = 1, 4 do
		local ang  = math.random() * math.pi * 2
		local blob = addGlowBlob(clump, Vector3.new(
			nestPos.X + math.cos(ang) * NEST.RIM_R * 0.85,
			ground + 0.1,
			nestPos.Z + math.sin(ang) * NEST.RIM_R * 0.85
		), 0.3 + math.random() * 0.25)
		blob.Transparency = 1
	end

	local light      = Instance.new("PointLight")
	light.Name       = "NestLight"
	light.Color      = NEST.GOO_LIGHT
	light.Brightness = NEST.GOO_REST   -- dark until something incubates in the socket
	light.Range      = 12
	light.Parent     = goo

	-- Invisible box hugging the bowl. The client adorns the selection outline to this: the egg
	-- changes size as it grows and is gone entirely between broods, and the click box is
	-- deliberately oversized, so neither is a good fit for an outline.
	local bowl        = Instance.new("Part")
	bowl.Name         = "Bowl"
	bowl.Size         = Vector3.new(NEST.RIM_R * 2 + 0.5, 2, NEST.RIM_R * 2 + 0.5)
	bowl.Position     = nestPos + Vector3.new(0, 1, 0)
	bowl.Anchored     = true
	bowl.CanCollide   = false
	bowl.CanQuery     = false
	bowl.CanTouch     = false
	bowl.CastShadow   = false
	bowl.Transparency = 1
	bowl:SetAttribute("ShownAt", 1)   -- stays invisible when the nest fades in
	bowl.Parent       = clump
end

-- ── The eggs a nest holds ───────────────────────────────────────────────────────
-- A nest starts with one egg in the middle of its socket and grows another every time the
-- Mother injects it, all of them sharing the one bowl. They are siblings, all named "Egg",
-- each stamped with its own EggId, and `layoutNestEggs` seats them: one sits dead centre,
-- and any more ring the socket evenly.

-- How far out from the socket's centre the eggs of a shared nest sit, at nest scale 1.
-- Sized against a RIPE shell (EGG.FULL, 1.1 across the radius), which is what a nest looks
-- like nearly all of the time. A shell carrying something big swells past this for the
-- length of the hatch and the two press into each other, which on a bramble full of meat
-- reads as a twin-lobed sac rather than as a mistake.
EGG.SLOT_SPREAD = 1.3

-- What tier a nest stands at: 1 Small (as planted), 2 Medium, 3 Large. Stamped on the
-- clump by every injection, so both sides can read it off the model.
local function nestTier(clump: Instance): number
	return (clump:GetAttribute("NestTier") :: number?) or 1
end

-- The id stamped on a shell, or nil for scenery (a Large nest's buds carry none).
local function eggIdOf(egg: BasePart): string?
	local id = egg:GetAttribute("EggId")
	return type(id) == "string" and id or nil
end

-- The nest's ground point and its current size, both read straight off the Bowl (which is
-- centred on the socket and swells with the rest of the bramble), so nothing has to be
-- remembered between injections.
local function nestGround(clump: Model): (Vector3, number)
	local bowl = clump:FindFirstChild("Bowl") :: BasePart?
	if not bowl then return clump:GetPivot().Position, 1 end
	local scale = (clump:GetAttribute("NestScale") :: number?) or 1
	return bowl.Position - Vector3.new(0, bowl.Size.Y * 0.5, 0), scale
end

-- Seat `entries` in the socket at `centre` and re-seat each on the (possibly new) floor.
-- Called on every injection, so an egg already ripening simply slides over to make room:
-- growSacEgg drives only the egg's Y, and reads X/Z back off the part, so a move sticks.
local function layoutNestEggs(entries: { SacEgg }, centre: Vector3, scale: number)
	local floorY = NEST.FLOOR_Y * scale
	local n      = #entries
	for i, e in entries do
		local x, z = centre.X, centre.Z
		if n > 1 then
			local ang = ((i - 1) / n) * math.pi * 2
			x += math.cos(ang) * EGG.SLOT_SPREAD * scale
			z += math.sin(ang) * EGG.SLOT_SPREAD * scale
		end
		e.baseY        = centre.Y + floorY
		e.egg.Position = Vector3.new(x, e.baseY + e.egg.Size.Y * 0.5, z)
	end
end

-- Build one egg shell in `clump`'s socket: the shell itself, the light it carries while it
-- is alive, and its growth bar. Built dormant (invisible, seated at the centre) -- either
-- revealEggClump fades it in with the rest of a new nest, or growSacEgg wells it up out of
-- the goo when an injection adds it to a nest already standing. Returns its id and part.
-- `scale` is the NEST's size (where the shell sits); `eggScale` is the shell's own size
-- against a normal egg, which only a Large nest's prime egg raises.
local function buildSacEgg(clump: Model, nestPos: Vector3, scale: number, eggScale: number?): (string, BasePart)
	local es = eggScale or 1
	eggSacEggCounter += 1
	local eggId = "SacEgg_" .. eggSacEggCounter

	local egg         = Instance.new("Part")
	egg.Name          = "Egg"
	egg.Shape         = Enum.PartType.Ball
	egg.Size          = EGG.DORMANT * es
	egg.Position      = nestPos + Vector3.new(0, NEST.FLOOR_Y * scale + EGG.DORMANT.Y * es * 0.5, 0)
	egg.Color         = Color3.fromRGB(255, 120, 60)
	egg.Material      = Enum.Material.Neon
	egg.Anchored      = true
	egg.CanCollide    = false
	egg.CanQuery      = false     -- the Hitbox takes every click; the egg is often not there
	egg.CastShadow    = false
	egg.Transparency  = 1
	egg:SetAttribute("EggId", eggId)   -- the id lives on the shell: a nest holds several
	egg.Parent        = clump
	local eggLight      = Instance.new("PointLight")
	eggLight.Color      = Color3.fromRGB(255, 140, 70)
	eggLight.Brightness = 0            -- lit while incubating
	eggLight.Range      = 10
	eggLight.Parent     = egg

	-- Growth progress bar, same look as the Mother's spat eggs. Runs while the egg ripens
	-- (see growSacEgg) and comes down once it is ready to spend.
	local bb            = Instance.new("BillboardGui")
	bb.Name             = "EggProgress"
	bb.Size             = UDim2.fromOffset(48, 7)
	bb.StudsOffset      = Vector3.new(0, EGG.FULL.Y * es * 0.95, 0)
	bb.AlwaysOnTop      = true
	bb.LightInfluence   = 0
	bb.MaxDistance      = 240
	bb.Enabled          = false
	bb.Parent           = egg
	local barBg         = Instance.new("Frame")
	barBg.Name          = "Bg"
	barBg.Size          = UDim2.fromScale(1, 1)
	barBg.BackgroundColor3 = Color3.fromRGB(12, 8, 16)
	barBg.BackgroundTransparency = 0.25
	barBg.BorderSizePixel = 0
	barBg.Parent        = bb
	local bgCorner      = Instance.new("UICorner"); bgCorner.CornerRadius = UDim.new(1, 0); bgCorner.Parent = barBg
	local barStroke     = Instance.new("UIStroke"); barStroke.Color = Color3.fromRGB(0, 0, 0); barStroke.Thickness = 1; barStroke.Transparency = 0.35; barStroke.Parent = barBg
	local fill          = Instance.new("Frame")
	fill.Name           = "Fill"
	fill.Size           = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 150, 70)
	fill.BorderSizePixel = 0
	fill.Parent         = barBg
	local fillCorner    = Instance.new("UICorner"); fillCorner.CornerRadius = UDim.new(1, 0); fillCorner.Parent = fill

	return eggId, egg
end

-- Build one egg clump at `nestPos`: the bramble nest, the (hidden) first egg that forms in
-- it, and a generous invisible click box, grouped in a Model tagged with NestId/EggOwnerId.
-- The NEST is what the client clicks and what carries the health bar; the eggs inside it
-- carry their own ids. Created HIDDEN (invisible, unclickable): revealEggClump pops it in
-- once its tentacle finishes growing. Returns the clump, the first egg's id and its part.
local function buildEggClump(container: Instance, ownerId: number, nestPos: Vector3): (Model, string, BasePart)
	eggSacNestCounter += 1
	local nestId = "SacNest_" .. eggSacNestCounter

	local clump = Instance.new("Model")
	clump.Name  = nestId
	clump:SetAttribute("NestId", nestId)
	clump:SetAttribute("EggOwnerId", ownerId)
	clump:SetAttribute("NestScale", 1)

	buildEggNest(clump, nestPos)
	local eggId, egg = buildSacEgg(clump, nestPos, 1)

	-- Generous invisible click box: the low bowl and its thin ribs are awkward targets at RTS
	-- camera pitch, so a tall box around the whole clump makes the nest easy to grab from any
	-- angle. Enabled on reveal. Width < egg spacing (11) so it never grabs a neighbour, even
	-- once an injection has swollen it.
	local hit        = Instance.new("Part")
	hit.Name         = "Hitbox"
	hit.Size         = Vector3.new(7, 8, 7)
	hit.Position     = nestPos + Vector3.new(0, 4, 0)
	hit.Anchored     = true
	hit.CanCollide   = false
	hit.CanQuery     = false          -- enabled on reveal
	hit.CanTouch     = false
	hit.CastShadow   = false
	hit.Transparency = 1
	hit.Parent       = clump

	clump.PrimaryPart = egg
	clump.Parent      = container
	return clump, eggId, egg
end

-- Eggs currently mid-incubation, so a second incubation cannot start on top of one that is
-- still running. Weak-keyed, so destroyed eggs (Mother razed) drop out on their own.
local eggIncubating: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Pop a finished nest into view at the tip of its tentacle: fade in every nest part to its
-- own resting transparency, sprout the creepygrass roots, make it clickable. The dormant
-- egg fades in with the rest, so a new nest arrives with an egg already sitting in it.
local function revealEggClump(egg: BasePart, nestPos: Vector3, owner: any)
	local clump = egg.Parent :: Model
	local hit = clump:FindFirstChild("Hitbox") :: BasePart?
	if hit then hit.CanQuery = true end

	-- A standing nest is a structure worth raiding: it respawns its creature forever
	-- until someone breaks it. ONE target for the whole nest however many eggs it ends up
	-- holding, aimed at (and health-barred on) the invisible Bowl: the bowl is centred on
	-- the socket and always there, where a shell wanders off-centre once an injection puts
	-- a second egg beside it and is gone entirely between broods. Killing it takes the
	-- whole clump, eggs and all. The bar height is pinned because incubation tweens the
	-- shells' sizes continuously.
	local bowl = clump:FindFirstChild("Bowl") :: BasePart?
	registerEggTarget(bowl or egg, clump, owner, Config.EGG_NEST_HP, "Embryo", 3.4)

	-- Wet water-balloon burst + pop sound the instant the nest appears.
	BuildFX.eggNestBurst(nestPos + Vector3.new(0, 0.6, 0))

	for _, part in clump:GetChildren() do
		if part:IsA("BasePart") and part ~= egg and part ~= hit then
			local shownAt = (part:GetAttribute("ShownAt") :: number?) or 0
			TweenService:Create(part, TweenInfo.new(0.35), { Transparency = shownAt }):Play()
		end
	end

	-- The dormant egg, unless incubation already claimed it (the player can pick a unit
	-- the instant the nest lands, and that animation owns the egg's size/transparency).
	if not eggIncubating[egg] then
		TweenService:Create(egg, TweenInfo.new(0.35), { Transparency = EGG.DORMANT_TRANS }):Play()
	end

	buildEggGrass(clump, nestPos, nestPos.Y)
end

-- Where an egg starts: a bud in the goo, before it packs itself out.
EGG.SEED = EGG.FULL * 0.34

-- Mark an egg ripe (or spent) both in state and on the part, so clients can pick the
-- usable ones out of a colony without asking the server.
local function setEggReady(entry: SacEgg, ready: boolean)
	entry.ready = ready
	if entry.egg.Parent then entry.egg:SetAttribute("EggReady", ready) end
end

-- Grow a nest's egg to ripeness over Config.EGG_GROW_TIME. The egg forms in the goo as a
-- small bud, the client sprouts the same enveloping tentacles a spat Mother egg gets, a
-- progress bar fills, and the egg breathes while it swells. When the clock runs out it
-- STAYS: a ripe egg sits in its nest waiting to be spent, where the old incubation
-- collapsed the shell the instant its creature was due.
local function growSacEgg(entry: SacEgg)
	local egg = entry.egg
	-- The previous brood's shell may still be collapsing; wait it out rather than skip this one.
	for _ = 1, 40 do
		if not eggIncubating[egg] then break end
		task.wait(0.05)
	end
	if not egg.Parent or eggIncubating[egg] or not entry.ripeAt then return end
	eggIncubating[egg] = true
	local clump = egg.Parent :: Model
	local light = egg:FindFirstChildWhichIsA("PointLight")
	local bar   = egg:FindFirstChild("EggProgress") :: BillboardGui?
	local barBg = bar and bar:FindFirstChild("Bg")
	local fill  = barBg and barBg:FindFirstChild("Fill") :: Frame?
	local goo      = clump:FindFirstChild("NestGoo") :: BasePart?
	local gooLight = goo and goo:FindFirstChildWhichIsA("PointLight")

	if bar then bar.Enabled = true end
	if fill then fill.Size = UDim2.fromScale(0, 1) end

	-- A nest that has never hatched still has its dormant egg in the socket, so growth
	-- picks up from that size. A regrow after a hatch has no shell left, so it wells back
	-- up out of the goo as a fresh bud.
	local full      = EGG.FULL * entry.scale
	local startSize = if egg.Transparency < 1 then egg.Size else EGG.SEED * entry.scale
	egg.Size     = startSize
	egg.Position = Vector3.new(egg.Position.X, entry.baseY + startSize.Y * 0.5, egg.Position.Z)
	TweenService:Create(egg, TweenInfo.new(0.4), { Transparency = 0.1 }):Play()
	if goo then TweenService:Create(goo, TweenInfo.new(0.4), { Transparency = 0.25 }):Play() end
	if gooLight then TweenService:Create(gooLight, TweenInfo.new(0.4), { Brightness = 3 }):Play() end

	-- Tentacles erupt from the egg's base and climb it, hugging its live size (MotherEggBody).
	RemoteHandler.get(Config.REMOTES.MotherEggLand):FireAllClients(egg)

	-- Progress is read off the deadline, so bar and swell stay in step even if this
	-- animation started a beat late.
	local dur = Config.EGG_GROW_TIME
	while entry.ripeAt and egg.Parent do
		local now     = os.clock()
		local left    = (entry.ripeAt :: number) - now
		if left <= 0 then break end
		local k       = math.clamp(1 - left / dur, 0, 1)
		local breathe = 1 + 0.06 * math.sin(now * 4.5)          -- same beat as a spat Mother egg
		local size    = startSize:Lerp(full, k) * breathe
		egg.Size      = size
		egg.Position  = Vector3.new(egg.Position.X, entry.baseY + size.Y * 0.5, egg.Position.Z)
		if light then light.Brightness = 2.5 + 2.5 * (0.5 + 0.5 * math.sin(now * 4.5)) end
		if fill then fill.Size = UDim2.fromScale(k, 1) end
		if bar  then bar.StudsOffset  = Vector3.new(0, size.Y * 0.62, 0) end
		task.wait(1 / 20)
	end

	eggIncubating[egg] = nil
	if not egg.Parent then return end
	-- Cancelled out from under us (the nest was destroyed, or a hatch raced in): leave the
	-- shell exactly as the canceller left it.
	if not entry.ripeAt then return end

	-- Ripe. The shell settles at full size and stays lit; the growth bar has nothing left
	-- to report, so it comes down and the egg itself is the signal.
	entry.ripeAt = nil
	egg.Size     = full
	egg.Position = Vector3.new(egg.Position.X, entry.baseY + full.Y * 0.5, egg.Position.Z)
	egg.Transparency = 0.1
	if bar then bar.Enabled = false end
	if light then light.Brightness = 4 end
	setEggReady(entry, true)
end

-- Start (or restart) an egg's growth clock.
local function beginEggGrowth(entry: SacEgg)
	setEggReady(entry, false)
	entry.ripeAt = os.clock() + Config.EGG_GROW_TIME
	task.spawn(growSacEgg, entry)
end

-- Spend a ripe egg: the shell collapses back into the goo and the tentacles let go,
-- leaving an empty nest that immediately starts growing the next one.
local function spendSacEgg(entry: SacEgg)
	local egg = entry.egg
	setEggReady(entry, false)
	entry.ripeAt = nil
	if not egg.Parent then return end

	local clump    = egg.Parent :: Model
	local light    = egg:FindFirstChildWhichIsA("PointLight")
	local bar      = egg:FindFirstChild("EggProgress") :: BillboardGui?
	local goo      = clump:FindFirstChild("NestGoo") :: BasePart?
	local gooLight = goo and goo:FindFirstChildWhichIsA("PointLight")

	eggIncubating[egg] = true   -- held through the collapse so the regrow cannot fight it
	RemoteHandler.get(Config.REMOTES.MotherEggLand):FireAllClients(egg, true)   -- retract tentacles
	if bar   then bar.Enabled = false end
	if light then TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 0 }):Play() end
	if goo then TweenService:Create(goo, TweenInfo.new(0.5), { Transparency = 0.55 }):Play() end
	if gooLight then TweenService:Create(gooLight, TweenInfo.new(0.5), { Brightness = NEST.GOO_REST }):Play() end

	local COLLAPSE = 0.3
	TweenService:Create(egg, TweenInfo.new(COLLAPSE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size         = EGG.SEED * entry.scale,
		Position     = Vector3.new(egg.Position.X, entry.baseY + EGG.SEED.Y * entry.scale * 0.5, egg.Position.Z),
		Transparency = 1,
	}):Play()

	task.spawn(function()
		task.wait(COLLAPSE)
		eggIncubating[egg] = nil
		if egg.Parent then beginEggGrowth(entry) end
	end)
end

-- How big the shell swells to while it carries a creature: half that creature's size,
-- never smaller than a plain egg (so a Needler's shell still reads as an egg). A Roller
-- visibly strains its shell where a Needler barely fills it.
local function sacEggTargetSize(unitType: string?, eggScale: number?): Vector3
	local full = EGG.FULL * (eggScale or 1)
	local def  = unitType and (Config.UNIT_TYPES :: any)[unitType]
	if not def then return full end
	local s = def.size * 0.5
	return Vector3.new(
		math.max(s.X, full.X),
		math.max(s.Y, full.Y),
		math.max(s.Z, full.Z)
	)
end

-- How long a finished shell waits before trying again when the spawn was refused (the
-- owner is at their unit cap). The creature is already paid for, so it is held rather than
-- thrown away: short enough that it turns up as soon as a slot frees, long enough that a
-- capped colony is not asking every frame.
EGG.HATCH_RETRY = 1.0

-- Carry an ordered creature to term, then let it out. The shell swells toward the thing
-- inside it while a progress bar runs down EGG_HATCH_TIME, and only then does the unit
-- appear -- picking a creature is an ORDER, not a delivery.
--
-- `refund` hands the price back if the shell is destroyed before the creature is out; the
-- player paid at the moment of ordering.
local function hatchSacEgg(entry: SacEgg, player: any, refund: () -> ())
	local egg      = entry.egg
	local unitType = entry.hatching
	if not unitType then return end

	local clump    = egg.Parent :: Model
	local light    = egg:FindFirstChildWhichIsA("PointLight")
	local bar      = egg:FindFirstChild("EggProgress") :: BillboardGui?
	local barBg    = bar and bar:FindFirstChild("Bg")
	local fill     = barBg and barBg:FindFirstChild("Fill") :: Frame?
	local goo      = clump and clump:FindFirstChild("NestGoo") :: BasePart?
	local gooLight = goo and goo:FindFirstChildWhichIsA("PointLight")

	eggIncubating[egg] = true
	if bar  then bar.Enabled = true end
	if fill then fill.Size = UDim2.fromScale(0, 1) end
	if goo  then TweenService:Create(goo, TweenInfo.new(0.3), { Transparency = 0.2 }):Play() end

	local startSize = egg.Size
	local target    = sacEggTargetSize(unitType, entry.scale)
	local dur       = Config.EGG_HATCH_TIME

	while entry.hatchAt and egg.Parent do
		local now  = os.clock()
		local left = (entry.hatchAt :: number) - now
		if left <= 0 then break end
		local k       = math.clamp(1 - left / dur, 0, 1)
		local breathe = 1 + 0.07 * math.sin(now * 5.2)   -- a harder beat than ripening: something is in there
		local size    = startSize:Lerp(target, k) * breathe
		egg.Size      = size
		egg.Position  = Vector3.new(egg.Position.X, entry.baseY + size.Y * 0.5, egg.Position.Z)
		if light then light.Brightness = 3 + 3 * (0.5 + 0.5 * math.sin(now * 5.2)) end
		if fill then fill.Size = UDim2.fromScale(k, 1) end
		if bar  then bar.StudsOffset = Vector3.new(0, size.Y * 0.62, 0) end
		task.wait(1 / 20)
	end

	-- The nest was destroyed out from under the order: the creature is never coming, so
	-- the player gets their money back.
	if not egg.Parent or not entry.hatchAt then
		eggIncubating[egg] = nil
		if entry.hatchAt then refund() end
		entry.hatchAt, entry.hatching = nil, nil
		return
	end

	-- Term. Hold at full and keep knocking if the owner is capped; bursting the shell on a
	-- creature that cannot be born would throw away both the wait and the price.
	local p = egg.Position
	local uid: string? = nil
	while egg.Parent do
		uid = unitManagerRef and unitManagerRef.spawnUnitNow(player, Vector3.new(p.X, 0, p.Z), unitType)
		if uid then break end
		task.wait(EGG.HATCH_RETRY)
	end

	eggIncubating[egg] = nil
	entry.hatchAt, entry.hatching = nil, nil
	if egg.Parent then egg:SetAttribute("SpawnType", nil) end

	if not uid then
		-- Only reachable if the shell went away while we were knocking.
		refund()
		return
	end

	BuildFX.eggHatch(p)
	RemoteHandler.get(Config.REMOTES.UnitHit):FireAllClients(p, p, "LampreyEggHatch")
	spendSacEgg(entry)
end

-- Plant `toSlot - fromSlot` new eggs (one per purchase) as nodes of the tentacle tree —
-- inner-biased for the electron-cloud spread, with siblings fanned into their own directions
-- so they never overlap. Each grows its tentacle first, then pops the egg in at the tip.
local function plantEggSacNests(base: BasePart, ccId: string, ownerId: number, fromSlot: number, toSlot: number)
	local eggs = eggSacEggs[ccId]
	if not eggs then eggs = {}; eggSacEggs[ccId] = eggs end
	local container = eggNestFolder(ccId)
	for _ = fromSlot + 1, toSlot do
		local pos, origin, parentId, dir = planEgg(ccId, base)
		local _, eggId, egg = buildEggClump(container, ownerId, pos)
		local entry: SacEgg = { egg = egg, ripeAt = nil, ready = false, parentId = parentId,
			dir = dir, numChildren = 0, baseY = pos.Y + NEST.FLOOR_Y,   -- eggs sit in the goo pool
			slot = 1, scale = 1 }
		eggs[eggId] = entry
		if parentId and eggs[parentId] then eggs[parentId].numChildren += 1 end

		task.spawn(function()
			growTentacle(container, ccId, origin, pos)            -- fixed speed → distance sets duration
			local cc = buildingData[ccId]
			if cc and egg.Parent then
				revealEggClump(egg, pos, cc.owner)
				-- The nest is in the ground: its first egg starts growing straight away.
				beginEggGrowth(entry)
			end
		end)
	end
end

-- The only creatures a nest will hatch, and it depends on the nest. The client sends a
-- bare string, so without this a crafted request would order anything in Config.UNIT_TYPES
-- out of any egg -- a Broodmother from a nest that was never worked for.
--
-- Small and Medium nests field the ordinary brood. A LARGE nest (three injections' worth of
-- her spike) fields the heavy three instead, and only one at a time: that is the whole
-- trade the tier makes. The Roller sits on the heavy list and nowhere else.
local EGG_HATCHABLE_BASIC: { [string]: boolean } = {
	Lamprey = true, Hagfish = true, Needler = true,
}
local EGG_HATCHABLE_PRIME: { [string]: boolean } = {
	Roller = true, Broodmother = true, Watcher = true,
}
local function eggHatchable(clump: Instance?, unitType: string): boolean
	if clump and nestTier(clump) >= Config.MOTHER_INJECT_NEST_TIERS then
		return EGG_HATCHABLE_PRIME[unitType] == true
	end
	return EGG_HATCHABLE_BASIC[unitType] == true
end
BuildingManager.EGG_HATCHABLE_BASIC = EGG_HATCHABLE_BASIC
BuildingManager.EGG_HATCHABLE_PRIME = EGG_HATCHABLE_PRIME

-- Order `unitType` out of one ripe egg. The price is charged now and the shell starts
-- carrying that creature; it climbs out EGG_HATCH_TIME later (see hatchSacEgg), and only
-- then is the shell spent and regrown. Refused if the creature is not one a nest hatches,
-- the egg is not ripe (already growing, or already carrying an order), it is not this
-- player's, or they cannot pay -- and a refusal leaves the egg untouched and still ripe.
-- Returns whether an order was actually placed.
function BuildingManager.hatchEgg(player: any, eggId: string, unitType: string): boolean
	if not unitManagerRef then return false end
	local typeDef = (Config.UNIT_TYPES :: any)[unitType]
	if not typeDef then return false end

	for ccId, eggs in eggSacEggs do
		local entry = eggs[eggId]
		if not entry then continue end
		local data = buildingData[ccId]
		if not data or data.owner ~= player then return false end
		if not entry.ready or entry.hatching or not entry.egg.Parent then return false end
		-- Which list this egg draws from is the NEST's business, not the client's.
		if not eggHatchable(entry.egg.Parent, unitType) then return false end

		-- The egg is the timer; the creature still costs what it costs. Charged at the
		-- moment of ordering, and handed back by hatchSacEgg if the shell is destroyed
		-- before the creature is out.
		local cost = typeDef.cost or 0
		if cost > 0 then
			if not resourceManagerRef or not resourceManagerRef.spend(player, cost) then return false end
		end
		local function refund()
			if cost > 0 and resourceManagerRef then resourceManagerRef.add(player, cost) end
		end

		-- Ordered: no longer available to order again, and now visibly carrying something.
		setEggReady(entry, false)
		entry.hatching = unitType
		entry.hatchAt  = os.clock() + Config.EGG_HATCH_TIME
		entry.egg:SetAttribute("SpawnType", unitType)
		task.spawn(hatchSacEgg, entry, player, refund)
		return true
	end
	return false
end

-- Purchase one Egg Sacs upgrade for `player`'s Mother `ccId`: charges the cost, bumps
-- the level, plants the new pair of nests, and stamps the level on the model (an
-- attribute the client MotherPanel reads to render the tile). Returns whether it bought.
-- Plant `count` extra egg nests on a Mother out of band, with no purchase behind them and
-- no level spent: an injected pod cluster comes up as her nests. They join the same tentacle
-- tree and the same eggSacEggs bookkeeping as bought ones, so they click and hatch identically.
-- Raise `count` Spike Glands where an injected frond stood. Real buildings, owned by the
-- Mother's owner and standing on their own: they can be shot down, which is the only thing
-- holding the inject → frond → gland → faster inject loop in check.
function BuildingManager.plantInjectGland(ccId: string, origin: Vector3, count: number)
	local data = buildingData[ccId]
	if not data or not data.owner then return end
	local size = Config.GLAND_SIZE
	for i = 1, math.max(1, count) do
		-- One gland lands on the spot; any beyond the first ring around it so they do not
		-- grow through each other.
		local px, pz = origin.X, origin.Z
		if i > 1 then
			local a = ((i - 2) / math.max(1, count - 1)) * math.pi * 2
			px += math.cos(a) * (size.X + 2)
			pz += math.sin(a) * (size.Z + 2)
		end
		-- Instant: the spike forced it up, there is no crew building it.
		skipNextConstruction = true
		createBuilding(data.owner, Vector3.new(px, 0, pz), "Gland")
		skipNextConstruction = false
	end
	refreshMotherEnergy(data.owner)
end

function BuildingManager.plantInjectEggNests(ccId: string, count: number)
	local data = buildingData[ccId]
	if not data or not data.base or not data.base.Parent then return end
	plantEggSacNests(data.base, ccId, (data.owner and data.owner.UserId) or 0, 0, count)
end

-- ── Injecting an egg nest ───────────────────────────────────────────────────
-- Her spike goes into a nest she already has rather than into the ground. The nest does
-- not burst and it does not split off a second nest: it SWELLS. The whole bramble grows by
-- Config.MOTHER_INJECT_NEST_SWELL and another egg forms in the socket alongside the first,
-- so what stands there is still one nest -- one thing to click, one health bar, one thing
-- to raid -- that now carries two eggs. Each egg keeps its own clock and its own creature,
-- which is the whole point: a swollen nest hatches two at a time.

-- The nest clump an egg entry sits in, or nil if it has already come down.
local function eggClumpOf(entry: SacEgg): Model?
	local clump = entry.egg.Parent
	if clump and clump:IsA("Model") then return clump end
	return nil
end

-- Every one of this Mother's eggs that sits in `clump`, ordered by slot so a re-layout
-- always seats them the same way round.
local function nestEggEntries(ccId: string, clump: Model): { SacEgg }
	local out: { SacEgg } = {}
	local eggs = eggSacEggs[ccId]
	if not eggs then return out end
	for _, entry in eggs do
		if eggClumpOf(entry) == clump then table.insert(out, entry) end
	end
	table.sort(out, function(a, b) return a.slot < b.slot end)
	return out
end

-- Can this nest take a spike? Only a standing nest of `ccId`'s that is not already Large.
-- Returns the eggs it holds, so the caller does not look them up twice.
local function eggNestInjectable(ccId: string, clump: Model): { SacEgg }?
	if not clump.Parent then return nil end
	if type(clump:GetAttribute("NestId")) ~= "string" then return nil end
	-- Still growing in at the tip of its tentacle: there is nothing standing there to
	-- spike yet. The click box going live is what says a nest has arrived.
	local hit = clump:FindFirstChild("Hitbox") :: BasePart?
	if not hit or not hit.CanQuery then return nil end
	if nestTier(clump) >= Config.MOTHER_INJECT_NEST_TIERS then return nil end
	local entries = nestEggEntries(ccId, clump)
	if #entries == 0 then return nil end   -- not one of hers, or already dead
	return entries
end

-- Grow every part of a nest outward from its own centre. Position offsets and sizes both
-- scale, so the bowl, its ribs, its click box and the creepygrass around it all swell as
-- one piece. The eggs are left alone: they are seated by layoutNestEggs afterwards and
-- keep their own size, since an egg is an egg however big the nest holding it is.
local function swellNest(clump: Model, centre: Vector3, factor: number)
	local tween = TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	-- Every piece of the bramble is a direct child of the clump (the bowl, its ribs, the
	-- goo, the click box, the creepygrass roots), so this never reaches inside an egg.
	for _, p in clump:GetChildren() do
		if not p:IsA("BasePart") or p.Name == "Egg" then continue end
		local cf  = p.CFrame
		local off = cf.Position - centre
		TweenService:Create(p, tween, {
			CFrame = (cf - cf.Position) + (centre + off * factor),
			Size   = p.Size * factor,
		}):Play()
		-- The socket's own glow reaches as far as the bowl now does.
		for _, l in p:GetChildren() do
			if l:IsA("PointLight") then l.Range *= factor end
		end
	end
end

-- One of the small shells that ring a Large nest's prime egg. They are scenery: no EggId,
-- no entry, no clock, nothing to click -- what the Large nest actually hatches is the one
-- big egg in the middle. They exist so the nest reads as a brood rather than as one egg
-- that got fat.
local function addNestBud(clump: Model, pos: Vector3, size: Vector3)
	local bud        = Instance.new("Part")
	bud.Name         = "NestBud"
	bud.Shape        = Enum.PartType.Ball
	bud.Size         = size
	bud.Position     = pos
	bud.Color        = Color3.fromRGB(255, 120, 60)
	bud.Material     = Enum.Material.Neon
	bud.Anchored     = true
	bud.CanCollide   = false
	bud.CanQuery     = false
	bud.CanTouch     = false
	bud.CastShadow   = false
	bud.Transparency = 1
	bud.Parent       = clump
	TweenService:Create(bud, TweenInfo.new(0.4), { Transparency = EGG.DORMANT_TRANS }):Play()
	return bud
end

-- Take `clump` (one of `ccId`'s egg nests) up one tier. The bowl swells either way; what
-- happens in the socket depends on where it lands:
--
--   Small → Medium  a second egg forms beside the first. Both are real eggs on their own
--                   clocks, so one pick of a creature hatches two.
--   Medium → Large  the pair is spent and replaced by a single PRIME egg, 40% across a
--                   normal one, ringed by three small buds. It hatches ONE creature at a
--                   time -- but from the heavy list nothing else can produce.
--
-- Silently does nothing if the nest died on the way or it is already Large; both are
-- re-checked here, since an order can sit on the queue through a long walk.
function BuildingManager.swellEggNest(ccId: string, clump: Model)
	local data = buildingData[ccId]
	if not data or not data.owner then return end
	local entries = eggNestInjectable(ccId, clump)
	if not entries then return end

	local eggs = eggSacEggs[ccId]
	if not eggs then return end

	local centre, scale = nestGround(clump)
	local newScale      = scale * Config.MOTHER_INJECT_NEST_SWELL
	local newTier       = nestTier(clump) + 1
	swellNest(clump, centre, Config.MOTHER_INJECT_NEST_SWELL)
	clump:SetAttribute("NestScale", newScale)
	clump:SetAttribute("NestTier", newTier)
	BuildFX.eggNestBurst(centre + Vector3.new(0, 0.6, 0))

	if newTier >= Config.MOTHER_INJECT_NEST_TIERS then
		-- ── Large: one prime egg where the brood was ──────────────────────────
		-- The nest's first egg is kept and swollen into the prime; the rest are spent as
		-- raw material. One of those spent shells may have been carrying a paid order --
		-- destroying it is how hatchSacEgg learns to hand the price back.
		local prime = entries[1]
		for i = #entries, 2, -1 do
			local e  = entries[i]
			local id = eggIdOf(e.egg)
			if id then eggs[id] = nil end
			e.ripeAt, e.hatchAt = nil, nil
			e.egg:Destroy()          -- an order in flight on it refunds itself (hatchSacEgg)
			table.remove(entries, i)
		end
		prime.scale = Config.NEST_PRIME_EGG_SCALE
		layoutNestEggs(entries, centre, newScale)

		-- The buds ringing it. Scenery, evenly spread but jittered so no two Large nests
		-- wear the same arrangement. Sized against a NORMAL egg, like the prime is: the
		-- bowl grew, the brood inside it did not become a different species.
		local budSize = EGG.FULL * Config.NEST_BUD_SCALE
		local ring    = (EGG.FULL.X * Config.NEST_PRIME_EGG_SCALE + budSize.X) * 0.5 + 0.35
		for i = 1, Config.NEST_BUDS do
			local ang = ((i - 1) / Config.NEST_BUDS) * math.pi * 2 + rng:NextNumber(-0.45, 0.45)
			local d   = ring * rng:NextNumber(0.88, 1.12)
			addNestBud(clump, Vector3.new(
				centre.X + math.cos(ang) * d,
				centre.Y + NEST.FLOOR_Y * newScale + budSize.Y * 0.5,
				centre.Z + math.sin(ang) * d), budSize)
		end

		-- The prime grows from scratch at its new size, and the wait is part of what the
		-- heavy creatures are priced against. An egg already carrying an order is left to
		-- finish: spendSacEgg regrows it as the prime the moment its creature is out.
		if not prime.hatching then beginEggGrowth(prime) end
		return
	end

	-- ── Medium: another egg beside the first ──────────────────────────────────
	-- Built dormant and invisible; beginEggGrowth is what pushes it up out of the goo, so
	-- it arrives as something forming rather than something placed.
	local eggId, egg = buildSacEgg(clump, centre, newScale)
	local entry: SacEgg = { egg = egg, ripeAt = nil, ready = false, parentId = nil,
		dir = Vector3.new(1, 0, 0), numChildren = 0, baseY = centre.Y + NEST.FLOOR_Y * newScale,
		slot = #entries + 1, scale = 1 }
	eggs[eggId] = entry
	table.insert(entries, entry)

	-- Everything in the socket is re-seated together: one egg sits centred, two or more
	-- ring the middle, and all of them ride the new (higher) floor.
	layoutNestEggs(entries, centre, newScale)
	beginEggGrowth(entry)
end

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
		plantEggSacNests(data.base, ccId, (data.owner and data.owner.UserId) or 0,
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

-- ── The last Command Center coming down ─────────────────────────────────────────
-- A commander's final Centre is the match turning over, so its death is staged instead of
-- played the instant its HP runs out (see Config.FINAL_BLOW_*). Three beats:
--
--   1. every client is told where it is happening and jumps its camera there, winner and
--      loser alike -- the one who landed the blow watches it land, the one who lost it
--      watches it go;
--   2. the Centre comes apart under those cameras -- a Core goes up in a chain of blasts,
--      a Mother ruptures and floods the ground she was rooted in;
--   3. only once the wreck has settled is the commander actually eliminated, which is
--      what raises the victory/defeat card.
--
-- The whole point is that nobody reads how the match ended off a card that appeared out
-- of nowhere: they see it happen first. The deaths themselves are BuildFX.coreDeath /
-- BuildFX.motherDeath; what lives here is the pacing.

-- Run the three beats above for `owner`, whose last Centre (`model`, standing at `pos`)
-- has just taken its killing blow. Yields, so it is always called on its own thread.
local function runFinalBlow(owner: any, model: Instance?, pos: Vector3)
	local hollowed = isHollowed(owner)
	RemoteHandler.get(Config.REMOTES.FinalBlow):FireAllClients((owner and owner.UserId) or 0, pos, hollowed)

	-- It stands through the camera's flight, so the cameras land on a building that is
	-- still there and then watch it die. Nothing can target, repair or use it in the
	-- meantime: it left buildingData with its last point of HP.
	task.wait(Config.FINAL_BLOW_CAM_LEAD)
	if model and model.Parent then model:Destroy() end
	if hollowed then BuildFX.motherDeath(pos) else BuildFX.coreDeath(pos) end

	-- The verdict waits for the wreck.
	task.wait(Config.FINAL_BLOW_DEATH_HOLD)
	if onCCDestroyedCb then onCCDestroyedCb(owner) end
end

function BuildingManager.damage(id: string, amount: number)
	if isEggTargetId(id) then
		damageEggTarget(id, amount)   -- eggs/nests keep their own HP; see the egg registry
		return
	end
	local data = buildingData[id]
	if not data then return end
	data.hp = math.max(0, data.hp - amount)
	applyHP(data, true)

	-- Map ping: this part of the owner's base is under attack (throttled per region).
	if data.hp > 0 then
		AlertManager.report(data.owner, data.base.Position, "base")
	end

	-- Extra banner notification for the Command Center specifically (throttled).
	-- Real, connected players only: an AI owner is a mock table, and FireClient on one
	-- throws "Unable to cast value to Object" out of the middle of the attacker's turn.
	if data.buildingType == "CommandCenter" and data.hp > 0
		and data.owner.UserId > 0 and data.owner.Parent then
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
	local wasGland    = data.buildingType == "Gland"
	local owner       = data.owner
	buildingData[id]      = nil   -- nil BEFORE Destroy so construction coroutine exits cleanly
	turretTimers[id]      = nil
	foundryTimers[id]     = nil
	deployerTimers[id]    = nil
	deployerUnlock[id]    = nil
	deployerUnitType[id]  = nil
	deployerUpdateAcc[id] = nil
	testSupplyLevel[id]   = nil
	testRateLevel[id]     = nil
	nestEggs[id]          = nil
	eggSacLevel[id]       = nil
	eggSacEggs[id]        = nil
	clearEggNests(id)     -- nests live outside the model, so take them down by hand
	engState[id]          = nil
	engResearchEnd[id]    = nil
	engUpdateAcc[id]      = nil

	local model      = buildingsFolder:FindFirstChild(id)
	local destroyPos = data.base.Position + Vector3.new(0, data.base.Size.Y * 0.5, 0)

	-- A player can own several Command Centers (Embryo → Mother stacks them). Only the
	-- LAST one falling ends their match; any other just re-points the primary CC id and
	-- comes down like any building.
	local lastCC = false
	if wasCC then
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
			lastCC = true
			playerHasCC[owner.UserId] = nil
			playerCCId[owner.UserId] = nil
		end
	end

	-- The killing blow on a commander. It is staged rather than played here and now:
	-- every camera is sent to the spot first, the Centre comes apart under them, and the
	-- elimination (which is what raises the victory/defeat card) waits until it has. It
	-- is already out of buildingData, so nothing can target or repair it in the meantime.
	if lastCC then
		task.spawn(runFinalBlow, owner, model, destroyPos)
		return
	end

	if model then model:Destroy() end

	-- CreepyWorm vanishes silently (either burst already fired VFX, or destroyed mid-construction)
	if data.buildingType ~= "CreepyWorm" then
		task.spawn(BuildFX.destruction, destroyPos)
	end

	if wasGland then
		-- One fewer organ feeding her spike: her cooldown goes straight back up.
		refreshMotherEnergy(owner)
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
	if bestId then return bestId, bestPos end

	-- Nothing built is in reach, so fall through to the clutch. Eggs and Egg-Sac nests
	-- are shootable, but they rank strictly below real structures: a raider standing
	-- between a Mother's eggs and the Mother herself goes for the Mother, and eggs never
	-- soak fire that a defended building should be taking.
	for id in eggTargets do
		local e = eggTargetAt(id)
		if not e then continue end
		if tostring(e.owner.UserId) == attackerOwnerIdStr then continue end
		local d = (e.base.Position - fromPos).Magnitude
		if d < range and d < bestDist and (not canTarget or canTarget(e.base.Position)) then
			bestDist = d; bestId = id; bestPos = e.base.Position + Vector3.new(0, e.base.Size.Y * 0.5, 0)
		end
	end
	return bestId, bestPos
end

-- What an attacker aims at for `id`: a building's Base, or an egg/nest's shell. Lets a
-- focus-fire order name either kind of target without the caller telling them apart.
function BuildingManager.getTargetPart(id: string): BasePart?
	if isEggTargetId(id) then
		local e = eggTargetAt(id)
		return e and e.base or nil
	end
	local data = buildingData[id]
	return data and data.base or nil
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
		foundryTimers[id]     = nil
		deployerTimers[id]    = nil
		deployerUnlock[id]    = nil
		deployerUnitType[id]  = nil
		deployerUpdateAcc[id] = nil
		testSupplyLevel[id]   = nil
		testRateLevel[id]     = nil
		monumentWinTimer[id]  = nil
		blobCooldowns[id]     = nil
		eggSacLevel[id]       = nil
		eggSacEggs[id]        = nil
		clearEggNests(id)     -- nests live outside the model, so take them down by hand
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
	-- Bonfire; Relay needs research. AI bots obey the same tree as players.
	if buildingType == "Deployer" and getPlayerBuildingCount(player, "Foundry") < 1 then return false end
	if buildingType == "Turret"   and getPlayerBuildingCount(player, "Deployer") < 1 then return false end
	if buildingType == "EngineeringPost"
		and getPlayerBuildingCount(player, "Deployer") < 1 then return false end
	-- LampreyNest needs a Bonfire first. Sole exemption: SWARM-gamemode bots, whose
	-- entire army comes from nests + creepy structures by design.
	if buildingType == "LampreyNest"
		and (player.UserId > 0 or not player.isSwarm)
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
	-- Each unit brings its own radius: a Watcher sees further than the rest, and the
	-- artillery it spots for should be able to use that.
	if unitManagerRef and unitManagerRef.getOwnerUnitSight then
		for _, u in unitManagerRef.getOwnerUnitSight(ownerStr) do
			sources[#sources + 1] = { x = u.x, z = u.z, r2 = u.r * u.r }
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
	PerfProbe.onHeartbeat("BuildingManager", function(dt)
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
		-- capacity, on an interval. The Bonfire's are fixed for every bonfire; the TEST
		-- building scales capacity (Supply) and interval (Spawn Rate) separately.
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
				capacity = Config.DEPLOYER_CAPACITY
				interval = Config.DEPLOYER_SUMMON_INTERVAL
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
						deployerUpdateRemote:FireClient(data.owner, id, unitType, progress)
					end
				end
			end
		end

		-- ── Mother Egg Sacs: reap destroyed nests ──────────────────────────────
		-- Nothing hatches on a timer any more: a nest's egg grows on its own clock
		-- (growSacEgg) and then waits to be spent by hand, so all this loop has left to do
		-- is drop the bookkeeping for eggs whose nest is gone.
		for _, eggs in eggSacEggs do
			for eggId, entry in eggs do
				if not entry.egg.Parent then eggs[eggId] = nil end
			end
		end

		-- ── Command Center passive income ──────────────────────────────────────
		ccIncomeAccum += dt
		if ccIncomeAccum >= Config.CC_PASSIVE_INTERVAL then
			ccIncomeAccum -= Config.CC_PASSIVE_INTERVAL
			if resourceManagerRef then
				-- Every standing CC pays out — AI bots included, since they run the same
				-- economy as players.
				for _, data in buildingData do
					if data.buildingType == "CommandCenter" and not data.isConstructing
						and data.owner then
						resourceManagerRef.add(data.owner, Config.CC_PASSIVE_INCOME)
					end
				end
			end
		end

		-- ── Foundry passive income ─────────────────────────────────────────────
		-- Each Foundry keeps its OWN payout clock, running from the moment it finished
		-- building, so one raised mid-match pays out on its own beat instead of falling
		-- into step with every other Foundry on the map. Each pays FOUNDRY_BASE_INCOME,
		-- boosted +15% per active mineral deposit within FOUNDRY_BOOST_RADIUS (uncapped).
		-- Boosting deposits are drained a little each tick, and the floating "Refining +N"
		-- label is refreshed.
		for id, data in buildingData do
			if data.buildingType ~= "Foundry" or data.isConstructing then continue end

			-- The clock only advances once the structure is standing, so the first payout
			-- lands a full interval after it was built rather than after it was ordered.
			local elapsed = (foundryTimers[id] or 0) + dt
			if elapsed < Config.FOUNDRY_INCOME_INTERVAL then
				foundryTimers[id] = elapsed
				continue
			end
			foundryTimers[id] = elapsed - Config.FOUNDRY_INCOME_INTERVAL
			local pos = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)

			local depositCount = 0
			if mineralManager then
				depositCount = mineralManager.drainAllNear(
					pos, Config.FOUNDRY_BOOST_RADIUS, Config.FOUNDRY_DRAIN_PER_DEPOSIT)
			end

			local income = Config.FOUNDRY_BASE_INCOME
				+ depositCount * Config.FOUNDRY_INCOME_PER_DEPOSIT
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
						lbl.Text = string.format("Refining +%d",
							depositCount * Config.FOUNDRY_INCOME_PER_DEPOSIT)
					end
				else
					bl.Enabled = false
				end
			end
		end

		-- ── Engineering Post research timers ───────────────────────────────────
		-- Runs for every owner — AI bots research at their posts too (engSync itself
		-- skips the client push for fake players).
		for id, data in buildingData do
			if data.buildingType ~= "EngineeringPost" then continue end
			if engState[id] ~= "researching" then continue end
			if not data.owner then continue end

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

			-- The Mother walks on her own legs and is markedly quicker than the
			-- Human core, which drags itself along on treads.
			local hollowed = isHollowed(data.owner)
			local speed = hollowed and Config.MOTHER_MOVE_SPEED or Config.MOBILE_CC_SPEED
			local step  = math.min(speed * dt, flat.Magnitude)
			local move  = flat.Unit * step
			local model = buildingsFolder:FindFirstChild(ccId) :: Model?
			if model and model:IsA("Model") then
				local dest = Vector3.new(
					data.base.Position.X + move.X,
					data.base.Position.Y,
					data.base.Position.Z + move.Z
				)
				if hollowed then
					-- Turn to walk head-first instead of sliding sideways. The creature is
					-- built facing +Z relative to its base, so LookVector (−Z) has to point
					-- AWAY from the heading. Eased, so she banks into a turn rather than
					-- snapping around.
					local want    = CFrame.lookAt(dest, dest - flat.Unit).Rotation
					local current = model:GetPivot().Rotation
					local turned  = current:Lerp(want, math.min(1, dt * MOTHER_TURN_RATE))
					model:PivotTo(CFrame.new(dest) * turned)
				else
					model:PivotTo(CFrame.new(dest))
				end
			end
		end

		-- ── Mother injections ─────────────────────────────────────────────────
		-- She is walking to the spot she was told to inject; once she is standing
		-- over it (or has stopped short), the spike goes in.
		for ccId, order in injectOrders do
			if order.phase ~= "walk" then continue end
			local data = buildingData[ccId]
			if not data or not data.base.Parent then
				injectOrders[ccId] = nil
				injectQueues[ccId] = nil
				continue
			end

			local pos  = data.base.Position
			local flat = Vector3.new(order.target.X - pos.X, 0, order.target.Z - pos.Z)
			if flat.Magnitude <= Config.MOTHER_INJECT_ARRIVE or ccMoveTargets[ccId] == nil then
				order.phase         = "inject"
				ccMoveTargets[ccId] = nil
				task.spawn(runInjection, ccId, order)
			end
		end

		-- ── "She is on it" flag ───────────────────────────────────────────────
		-- Now that the cooldown only starts at the spike, the stretch between the click
		-- and the wound would otherwise read as a fully idle tile. This says she is
		-- already working, so a press during it is understood as re-aiming her rather
		-- than as ordering a second injection.
		--
		-- Derived here each tick rather than stamped at every mutation: an order can be
		-- called off from half a dozen places (a move order, a re-root, her death, the run
		-- running dry) and a flag set by hand would eventually be left standing by one of
		-- them.
		for ccId, d in buildingData do
			if d.buildingType ~= "CommandCenter" or not d.base.Parent then continue end
			local busy = injectOrders[ccId] ~= nil
			if (d.base:GetAttribute("InjectBusy") == true) ~= busy then
				d.base:SetAttribute("InjectBusy", busy)
			end

			-- Energy regen. The pool belongs to the Hollowed Mother; a Human Fabricator
			-- Core is the same buildingType and has no use for it, so it is skipped
			-- rather than handed an attribute nothing reads.
			if not isHollowed(d.owner) then continue end
			-- setEnergy only writes the attribute when the whole number moves, so this is
			-- a float add per Mother per frame and one replicated change per second.
			local maxE = energyMaxOf(ccId)
			if d.base:GetAttribute("MotherEnergyMax") ~= maxE then
				d.base:SetAttribute("MotherEnergyMax", maxE)
			end
			local e = energyOf(ccId)
			if e < maxE then
				setEnergy(ccId, e + energyRegenOf(ccId) * dt)
			elseif d.base:GetAttribute("MotherEnergy") == nil then
				setEnergy(ccId, e)   -- publish the opening value once
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
			-- Rooting mid-walk also drops any injection she was on her way to make,
			-- along with anything queued behind it.
			injectOrders[ccId] = nil
			injectQueues[ccId] = nil
			setCCMobileState(ccId, player, not ccMobile[ccId])
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
		injectOrders[ccId] = nil   -- a hand-issued move cancels the walk to an injection
		injectQueues[ccId] = nil   -- and everything queued behind it
		ccMoveTargets[ccId] = Vector3.new(pos.X, 0, pos.Z)
	end)

	-- ── InjectGround remote (Hollowed Mother → "Inject") ──────────────────
	-- The player picked a spot on the ground: the Mother uproots herself if she was
	-- rooted, walks over, drives her spike in, and three plants come up out of it.
	-- She roots back down afterwards if that is how she started.
	-- `queued` (the player held [Shift]) stacks the spot behind whatever she is already
	-- doing instead of replacing it, so a whole run of injections can be laid out at once.
	-- `targetInst`, when given, aims the spike at something standing rather than at bare
	-- ground -- one of her own grown plants (it bursts) or one of her own egg nests (it
	-- divides). Either way the target's own position is the spot she walks to.
	RemoteHandler.get(Config.REMOTES.InjectGround).OnServerEvent:Connect(function(player, ccId, pos, queued, targetInst)
		if type(ccId) ~= "string" then return end
		if typeof(pos) ~= "Vector3" then return end
		local data = buildingData[ccId]
		if not data or data.buildingType ~= "CommandCenter" then return end
		if data.owner ~= player then return end
		if data.isConstructing then return end
		if not isHollowed(player) then return end
		if not data.base.Parent then return end

		-- A plant target is only as good as the plant: it has to be hers or wild (no
		-- owner, so grown by WildPlants rather than planted by a rival), still standing,
		-- and one of the kinds that actually gives something up. The client sends the
		-- model itself, so the spot comes off the plant, not off the cursor.
		local plant: Model? = nil
		local nest:  Model? = nil
		if targetInst ~= nil then
			if typeof(targetInst) ~= "Instance" or not targetInst:IsA("Model") then return end
			local folder = workspace:FindFirstChild("InjectPlants")
			if folder and targetInst.Parent == folder then
				local owner = targetInst:GetAttribute("OwnerUserId")
				if owner ~= nil and owner ~= player.UserId then return end
				local info = InjectPlants.injectInfo(targetInst)
				if not (info and info.kind) then return end
				plant = targetInst
			else
				-- An egg nest instead. It has to be one of THIS Mother's, which the
				-- folder tree already says: nests live in workspace.EggNests/<ccId>.
				local sub  = targetInst.Parent
				local root = sub and sub.Parent
				if not sub or root ~= workspace:FindFirstChild("EggNests") then return end
				if sub.Name ~= ccId then return end
				if targetInst:GetAttribute("EggOwnerId") ~= player.UserId then return end
				-- Re-checked when the spike actually goes in; refusing here as well keeps
				-- a full socket from eating the walk and the cooldown for nothing.
				if not eggNestInjectable(ccId, targetInst) then return end
				nest = targetInst
			end
			pos = targetInst:GetPivot().Position
		end

		local target = Vector3.new(pos.X, 0, pos.Z)
		local here   = Vector3.new(data.base.Position.X, 0, data.base.Position.Z)
		if (target - here).Magnitude > Config.MOTHER_INJECT_RANGE then return end

		-- Bare ground has to BE bare. Without this the same clearing takes spike after
		-- spike and grows into a thicket; the client draws the very radius being tested
		-- (the hologram disc), so a refusal here is one the player already saw coming.
		-- Aiming at a plant or a nest skips it: that is a deliberate target, not a
		-- crowded patch.
		if not plant and not nest and not groundClearForInject(target) then return end

		local wantQueue = queued == true
		local order     = injectOrders[ccId]

		-- Re-targeting mid-walk just moves the spot; once the spike is in, she finishes.
		-- A shift-order never re-targets, so it stacks up even while she is hunched over.
		if order and order.phase == "inject" and not wantQueue then return end

		local queue = injectQueues[ccId]
		if wantQueue and order and queue and #queue >= MAX_INJECT_QUEUE then return end

		-- Injecting is free; the spike's cooldown is the limiter, and it is only checked
		-- when STARTING a run. Nudging the spot of an order already under way, or stacking
		-- another wound behind it, is laying out a plan rather than driving a spike --
		-- each queued wound waits out the cooldown itself when she gets there.
		if not order and injectCooldownLeft(ccId) > 0 then return end
		-- Same rule for the pool: it only blocks STARTING a run. Wounds stacked behind one
		-- already under way wait for their own energy when she gets to them.
		if not order and energyOf(ccId) < Config.MOTHER_INJECT_ENERGY then return end

		if wantQueue and order then
			if not queue then queue = {}; injectQueues[ccId] = queue end
			table.insert(queue, { target = target, plant = plant, nest = nest })
			return
		end

		-- A plain order wipes the queue: this spot is the whole plan now.
		if not wantQueue then injectQueues[ccId] = nil end

		if order then
			order.target = target
			order.plant  = plant
			order.nest   = nest
		else
			injectOrders[ccId] = {
				target    = target,
				phase     = "walk",
				wasRooted = not ccMobile[ccId],
				plant     = plant,
				nest      = nest,
			}
		end

		if not ccMobile[ccId] then setCCMobileState(ccId, player, true) end
		ccMoveTargets[ccId] = target
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
		-- TEST is deliberately absent: the sandbox bonfire is off the build tray, and the
		-- whitelist is what makes that stick against a hand-rolled placement request. The
		-- rest of its implementation is intact, so re-listing it here brings it back.
		local PLACEABLE = { CommandCenter=true, Foundry=true, Deployer=true, Turret=true, Relay=true, CreepyBlob=true, LampreyNest=true, EngineeringPost=true }
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
		-- This bonfire only knows the units its own unlock ladder has reached.
		if not Config.bonfireUnitUnlocked(unitType, deployerUnlock[deployerId] or 0) then return end
		deployerUnitType[deployerId] = unitType
		-- Immediately send an update so the client reflects the change without waiting for next poll
		local progress = math.clamp((deployerTimers[deployerId] or 0) / Config.DEPLOYER_SUMMON_INTERVAL, 0, 1)
		RemoteHandler.get(Config.REMOTES.DeployerUpdate):FireClient(player, deployerId, unitType, progress)
	end)

	-- ── UnlockDeployerUnit remote (teach a bonfire the next unit on its ladder) ─
	-- Accepts one id or a list (multi-select). The LOWEST unlock level in the selection
	-- is the one advanced, so a press evens the group out, and each bonfire pays its own
	-- price until the player runs out.
	RemoteHandler.get(Config.REMOTES.UnlockDeployerUnit).OnServerEvent:Connect(function(player, deployerIds)
		local ids = type(deployerIds) == "string" and { deployerIds } or deployerIds
		if type(ids) ~= "table" then return end

		local eligible: { string } = {}
		local minLevel = math.huge
		for _, id in ids do
			if type(id) ~= "string" then continue end
			local data = buildingData[id]
			if not data or data.buildingType ~= "Deployer" or data.owner ~= player or data.isConstructing then continue end
			local lvl = deployerUnlock[id] or 0
			if lvl >= Config.BONFIRE_UNLOCK_MAX_LEVEL then continue end
			table.insert(eligible, id)
			if lvl < minLevel then minLevel = lvl end
		end
		if #eligible == 0 then return end

		local cost         = Config.bonfireUnlockCost(minLevel)
		local updateRemote = RemoteHandler.get(Config.REMOTES.DeployerUpdate)
		for _, id in eligible do
			if (deployerUnlock[id] or 0) ~= minLevel then continue end
			if not resourceManagerRef or resourceManagerRef.get(player) < cost then break end
			resourceManagerRef.spend(player, cost)
			applyBonfireUnlock(id, minLevel + 1)

			-- Push an update straight back so the card redraws on the purchase rather than
			-- on the next periodic tick. `true` plays the flare.
			local unitType = deployerUnitType[id] or "Survivor"
			local progress = math.clamp((deployerTimers[id] or 0) / Config.DEPLOYER_SUMMON_INTERVAL, 0, 1)
			updateRemote:FireClient(player, id, unitType, progress, true)
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

	-- ── AssignEgg remote: spend a ripe egg on a creature ────────────────────────
	-- The creature comes out at once and the shell is spent; the nest then regrows its
	-- egg. Nothing is remembered between hatches, so this is a one-shot order rather than
	-- a standing choice. hatchEgg does every check (ownership, ripeness, unit cap).
	RemoteHandler.get(Config.REMOTES.AssignEgg).OnServerEvent:Connect(function(player, eggId, unitType)
		if type(eggId) ~= "string" or type(unitType) ~= "string" then return end
		BuildingManager.hatchEgg(player, eggId, unitType)
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

					nextBuildRiseTime = Config.CREEPY_TURRET_BUILD_TIME
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
					layoutNestLauncher(model, lbase, aim, LAUNCHER.REST)
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
-- Enforces the same whitelist and the same per-bonfire unlock ladder as the
-- SetDeployerType remote, so a bot can't summon anything a player couldn't pick.
function BuildingManager.setBonfireSummonType(player: any, deployerId: string, unitType: string): boolean
	local VALID = { Survivor = true, Sniper = true, Tank = true, Howitzer = true, Elite = true, Medic = true, Foamer = true }
	if not VALID[unitType] then return false end
	local data = buildingData[deployerId]
	if not data or data.buildingType ~= "Deployer" or data.owner ~= player then return false end
	if not Config.bonfireUnitUnlocked(unitType, deployerUnlock[deployerId] or 0) then return false end
	deployerUnitType[deployerId] = unitType
	return true
end

-- ── Engineering Post helpers for AI bots (mirror the player remotes exactly) ──

function BuildingManager.getEngineeringState(player: any, id: string): string?
	local data = buildingData[id]
	if not data or data.buildingType ~= "EngineeringPost" or data.owner ~= player
		or data.isConstructing then return nil end
	return engState[id] or "idle"
end

-- Start a Light research (charges ENGINEERING_RESEARCH_COST, same as the remote).
function BuildingManager.startEngineeringForPlayer(player: any, id: string): boolean
	local data = buildingData[id]
	if not data or data.buildingType ~= "EngineeringPost" or data.owner ~= player
		or data.isConstructing then return false end
	if (engState[id] or "idle") ~= "idle" then return false end
	if not resourceManagerRef or resourceManagerRef.get(player) < Config.ENGINEERING_RESEARCH_COST then return false end
	resourceManagerRef.spend(player, Config.ENGINEERING_RESEARCH_COST)
	engState[id]       = "researching"
	engResearchEnd[id] = os.clock() + Config.ENGINEERING_LIGHT_TIME
	engUpdateAcc[id]   = 0
	return true
end

-- Collect a finished research: roll + apply a random upgrade (same as the remote).
function BuildingManager.collectEngineeringForPlayer(player: any, id: string): boolean
	local data = buildingData[id]
	if not data or data.buildingType ~= "EngineeringPost" or data.owner ~= player
		or data.isConstructing then return false end
	if engState[id] ~= "ready" then return false end
	engState[id]       = "idle"
	engResearchEnd[id] = nil
	engNotifier(id, false)
	if unitManagerRef then unitManagerRef.applyRandomUpgrade(player) end
	return true
end

-- Buy the next unit unlock on one bonfire, up to `maxLevel` (mirrors the player remote,
-- charging the same price). Lets a bot field a varied army only by paying for it.
function BuildingManager.unlockBonfireUnitForPlayer(player: any, deployerId: string, maxLevel: number): boolean
	local data = buildingData[deployerId]
	if not data or data.buildingType ~= "Deployer" or data.owner ~= player or data.isConstructing then return false end
	local level = deployerUnlock[deployerId] or 0
	local cap   = math.min(Config.BONFIRE_UNLOCK_MAX_LEVEL, maxLevel or 0)
	if level >= cap then return false end
	local cost = Config.bonfireUnlockCost(level)
	if not resourceManagerRef or resourceManagerRef.get(player) < cost then return false end
	resourceManagerRef.spend(player, cost)
	applyBonfireUnlock(deployerId, level + 1)
	return true
end

-- How many unit unlocks this bonfire has bought (nil if it is not one).
function BuildingManager.getBonfireUnlockLevel(player: any, deployerId: string): number?
	local data = buildingData[deployerId]
	if not data or data.buildingType ~= "Deployer" or data.owner ~= player then return nil end
	return deployerUnlock[deployerId] or 0
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
