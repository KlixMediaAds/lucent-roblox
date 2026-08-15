--!strict
--[[
	SpawnPoints — where commanders start.

	Every commander (human or AI) begins on a ring hugging the map perimeter, at a
	RANDOM point along it. The old layout pinned players to four fixed slots in the
	SE quadrant and mirrored the AI diagonally across the map, so every match opened
	on the same board from the same angle; now the whole rim is in play and no two
	openings look alike.

	Placement rules:
	  • The ring is a SQUARE of half-extent RING_HALF, so a base sits the same
	    distance in from the nearest wall wherever it lands — no side is safer.
	  • Spots are sampled uniformly along the perimeter, then judged on how far they
	    sit from everything already taken. The separation demanded starts at
	    IDEAL_SEP (essentially opposite ends of the map) and decays toward MIN_SEP as
	    attempts run out, so a duel opens across the map while a crowded seven-way
	    still fits. It degrades to "as spread out as possible" rather than failing.
	  • Both reservations made here and live Command Centers standing in the world
	    count as taken, so a spot claimed before its CC exists is still respected.

	RING_HALF sits halfway between the old front spawn (250) and the ±432 map wall,
	and leaves room for the deposits seeded outward from each base
	(MineralManager.spawnDepositsForBase reaches ~60 studs further out) to stay in
	bounds on every side.
]]

local SpawnPoints = {}

local RING_HALF = 340    -- half-extent of the spawn ring (map walls sit at ±432)
local IDEAL_SEP = 700    -- preferred spacing: near-opposite sides of the map
local MIN_SEP   = 260    -- the crowded-lobby floor we relax toward
local ATTEMPTS  = 240

local claimed: { Vector3 } = {}

-- A point at fraction `t` (0..1) around the ring, walking the four sides in order.
-- Sampling `t` uniformly spreads candidates evenly along the rim, corners included.
local function perimeterPoint(t: number): Vector3
	local p    = (t % 1) * 4
	local side = math.floor(p)
	local f    = (p - side) * 2 - 1     -- -1 → 1 along this side
	local H    = RING_HALF
	if side == 0 then
		return Vector3.new(f * H, 0, -H)
	elseif side == 1 then
		return Vector3.new(H, 0, f * H)
	elseif side == 2 then
		return Vector3.new(-f * H, 0, H)
	end
	return Vector3.new(-H, 0, -f * H)
end

-- Everything that counts as occupied: reservations plus any Command Center already
-- standing (a bot rebuilding mid-match, a late joiner, a previous round's base).
local function takenSpots(): { Vector3 }
	local spots: { Vector3 } = {}
	for _, v in claimed do spots[#spots + 1] = v end
	local folder = workspace:FindFirstChild("Buildings")
	if folder then
		for _, model in folder:GetChildren() do
			local tv = model:FindFirstChild("BuildingType") :: StringValue?
			if tv and tv.Value == "CommandCenter" then
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then
					spots[#spots + 1] = Vector3.new(base.Position.X, 0, base.Position.Z)
				end
			end
		end
	end
	return spots
end

local function nearestDist(pos: Vector3, spots: { Vector3 }): number
	local best = math.huge
	for _, s in spots do
		local d = (pos - s).Magnitude
		if d < best then best = d end
	end
	return best
end

--[[
	Reserve and return a perimeter spot, kept as far from every other commander as
	the map allows. Always returns a point: with nowhere roomy left it hands back
	the most isolated spot it found rather than failing.
]]
function SpawnPoints.claim(): Vector3
	local spots    = takenSpots()
	local best     = perimeterPoint(math.random())
	local bestDist = nearestDist(best, spots)

	for attempt = 1, ATTEMPTS do
		local need = IDEAL_SEP + (MIN_SEP - IDEAL_SEP) * (attempt / ATTEMPTS)
		if bestDist >= need then break end
		local cand = perimeterPoint(math.random())
		local d    = nearestDist(cand, spots)
		if d > bestDist then best, bestDist = cand, d end
	end

	claimed[#claimed + 1] = best
	return best
end

-- Mark a spot as taken without picking one. Used to re-register the bases of bots
-- that survive a match reset, so the next round's claims still route around them.
function SpawnPoints.reserve(pos: Vector3)
	claimed[#claimed + 1] = Vector3.new(pos.X, 0, pos.Z)
end

-- Drop every reservation so the next match re-rolls the whole board. Live Command
-- Centers are still honoured through takenSpots.
function SpawnPoints.reset()
	claimed = {}
end

-- Half-extent of the ring. World generation reads this to keep the whole band clear
-- of obstacles, since a base can land anywhere along it (see TerrainManager).
SpawnPoints.RING_HALF = RING_HALF

return SpawnPoints
