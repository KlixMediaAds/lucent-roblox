--!strict
--[[
	WildPlants — the Mother's growths, growing on their own.

	The same three plants a spike forces out of the ground (see InjectPlants) are also
	seeded across the map at world generation, so the Hollowed flora looks like it was
	there before anybody arrived. Any Mother can drive her spike into one of these and
	take what it was growing, exactly as if she had planted it herself: they carry no
	OwnerUserId, and both the targeting sight and the InjectGround handler read a missing
	owner as "wild, anyone's".

	It scatters differently from the forest, on purpose. Trees sweep a jittered grid and
	fill whole groves; plants come up in BLOOMS — a handful of scattered clumps of two to
	five, sparse enough that finding one is worth something. Blooms keep out from under
	the canopy (ForestManager.treeNear), off deposits, obstacles and buildings, and are
	mirrored across the diagonal like everything else on the map, so neither side of a
	symmetric map is richer in wild growth than the other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local InjectPlants      = require(Shared:WaitForChild("InjectPlants"))

local ForestManager = require(script.Parent:WaitForChild("ForestManager"))

local WildPlants = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
local HALF          = 432   -- map half-extent (studs), same as the forest
local EDGE_MARGIN   = 30    -- keep blooms well off the boundary walls
local TRIES         = 900   -- candidate bloom sites tested per generation
local MAX_BLOOMS    = 20    -- hard cap on blooms (each is mirrored, so twice this on the map)
local BLOOM_MIN     = 2     -- plants in the smallest bloom
local BLOOM_MAX     = 5     -- plants in the biggest
local BLOOM_SPREAD  = 11    -- studs the plants of one bloom scatter within
local BLOOM_GAP     = 90    -- min studs between two bloom centres, so they stay findable
local CANOPY_CLEAR  = 16    -- no bloom this close to a standing tree
local DEPOSIT_CLEAR = 22    -- no bloom this close to a resource deposit
local BUILDING_PAD  = 40    -- no bloom this close to a structure that already exists

-- Blooms follow their own Perlin field rather than the forest's, so where the flora
-- gathers has nothing to do with where the woods are. Coarser scale than the trees:
-- a few broad regions of the map are simply more fertile than the rest.
local NOISE_SCALE  = 0.006
local NOISE_THRESH = 0.55

-- ── State ───────────────────────────────────────────────────────────────────
local plantFolder: Folder? = nil
local centres: { Vector3 } = {}
local mineralManagerRef: any = nil
local terrainManagerRef:  any = nil
local rng = Random.new()

-- ── Placement filters ───────────────────────────────────────────────────────
local function tooCloseToBloom(x: number, z: number): boolean
	local g2 = BLOOM_GAP * BLOOM_GAP
	for _, c in centres do
		local dx = c.X - x
		local dz = c.Z - z
		if dx * dx + dz * dz < g2 then return true end
	end
	return false
end

local function nearDeposit(x: number, z: number): boolean
	if not mineralManagerRef then return false end
	local c2 = DEPOSIT_CLEAR * DEPOSIT_CLEAR
	for _, d in mineralManagerRef.getUnclaimedPositions() do
		local dx = d.X - x
		local dz = d.Z - z
		if dx * dx + dz * dz < c2 then return true end
	end
	return false
end

local function onObstacle(x: number, z: number): boolean
	local f = workspace:FindFirstChild("TerrainObstacles")
	if not f then return false end
	for _, part in f:GetChildren() do
		if part:IsA("BasePart") then
			if math.abs(x - part.Position.X) < part.Size.X / 2 + 3
				and math.abs(z - part.Position.Z) < part.Size.Z / 2 + 3 then
				return true
			end
		end
	end
	return false
end

-- Starting command centres and any structure already standing. Wild growth right on a
-- doorstep would be free income for whoever spawned next to it.
local function nearBuilding(x: number, z: number): boolean
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return false end
	for _, model in bf:GetChildren() do
		local base = model:FindFirstChild("Base") :: BasePart?
		if base then
			local bt  = model:FindFirstChild("BuildingType") :: StringValue?
			local pad = if bt and bt.Value == "CommandCenter" then Config.FOREST_CC_CLEARING else BUILDING_PAD
			local dx  = base.Position.X - x
			local dz  = base.Position.Z - z
			if dx * dx + dz * dz < pad * pad then return true end
		end
	end
	return false
end

-- ── Planting ────────────────────────────────────────────────────────────────
local function surfaceAt(x: number, z: number): number
	return (terrainManagerRef and terrainManagerRef.surfaceHeightAt(x, z)) or 0
end

-- One bloom: a few plants of mixed variety knotted around `cx, cz`. No owner attribute
-- is set, which is exactly what marks it as wild.
local function bloom(cx: number, cz: number, seed: number, count: number)
	local folder   = plantFolder
	if not folder then return end
	local variants = InjectPlants.VARIANTS
	local r        = Random.new(seed)

	for i = 1, count do
		local variant = variants[r:NextInteger(1, #variants)]
		local a  = r:NextNumber(0, math.pi * 2)
		local d  = BLOOM_SPREAD * math.sqrt(r:NextNumber(0.05, 1))   -- even fill, not centre-heavy
		-- A bloom scatters within BLOOM_SPREAD, which is easily tight enough for two of
		-- its plants to land on the same spot. findSpot nudges each one clear of whatever
		-- is already standing, and drops it if the clump has genuinely run out of room.
		local px, pz = InjectPlants.findSpot(folder,
			cx + math.cos(a) * d, cz + math.sin(a) * d, variant, r)
		if px and pz then
			InjectPlants.grow(folder, Vector3.new(px, surfaceAt(px, pz), pz),
				variant, seed + i, true)
		end
	end
end

-- ── Public ──────────────────────────────────────────────────────────────────
function WildPlants.clear()
	-- Only the wild ones: an injection's plants live in the same folder, but generation
	-- happens before any Mother has swung, so clearing the folder wholesale is safe.
	local existing = workspace:FindFirstChild("InjectPlants")
	if existing then existing:Destroy() end
	plantFolder = nil
	centres     = {}
end

function WildPlants.generate()
	WildPlants.clear()

	local folder = Instance.new("Folder")
	folder.Name   = "InjectPlants"
	folder.Parent = workspace
	plantFolder   = folder

	-- Fresh offset per match, so the fertile regions move around.
	local nox = rng:NextNumber(-500, 500)
	local noz = rng:NextNumber(-500, 500)
	local lim = HALF - EDGE_MARGIN
	local n   = 0

	for _ = 1, TRIES do
		if n >= MAX_BLOOMS then break end

		local x = rng:NextNumber(-lim, lim)
		local z = rng:NextNumber(-lim, lim)
		-- Decide in the SE half only and twin each bloom across z = x, the same diagonal
		-- mirror the forest and the starting bases use.
		if z > x then x, z = z, x end

		local dens = math.noise(x * NOISE_SCALE + nox, z * NOISE_SCALE + noz, 2.5) + 0.5
		if dens <= NOISE_THRESH then continue end
		if tooCloseToBloom(x, z) then continue end
		if ForestManager.treeNear(x, z, CANOPY_CLEAR) then continue end
		if nearDeposit(x, z) or onObstacle(x, z) or nearBuilding(x, z) then continue end

		local seed  = rng:NextInteger(1, 1000000)
		local count = rng:NextInteger(BLOOM_MIN, BLOOM_MAX)
		bloom(x, z, seed, count)
		table.insert(centres, Vector3.new(x, 0, z))
		n += 1

		-- The mirror twin, skipped when the site sits on the diagonal itself.
		if math.abs(x - z) > 1 then
			bloom(z, x, seed, count)
			table.insert(centres, Vector3.new(z, 0, x))
		end

		if n % 12 == 0 then task.wait() end   -- spread the part creation over a few frames
	end

	print("[WildPlants] Seeded", n, "blooms (diagonally mirrored)")
end

function WildPlants.init(mineralManager: any)
	mineralManagerRef = mineralManager
end

function WildPlants.setTerrainManager(tm: any)
	terrainManagerRef = tm
end

return WildPlants
