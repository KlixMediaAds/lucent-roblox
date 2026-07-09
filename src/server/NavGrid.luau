--!strict
--[[
	NavGrid — coarse navigation grid + A* for the tiered terrain.

	A cell's "height" is the logical level it sits on (from TerrainManager.heightAt:
	0 / STEP / 2*STEP, ramps interpolate). An edge between two cells is walkable only
	when the height change per stud stays under MAX_SLOPE — so ramps (gentle) connect
	levels while cliffs (a full STEP over one cell) are impassable walls.

	findPath() returns a list of world waypoints (XZ; Y left 0) that units steer
	through; straight, cliff-free moves skip A* via a cheap line-of-sight test.
]]

local NavGrid = {}

local HALF      = 432
local CELL      = 12
local DIM       = math.floor((HALF * 2) / CELL) + 1   -- 73 cells per axis
local ORIGIN    = -HALF
local MAX_SLOPE = 0.6   -- ramp slope ≈0.43 (passable); cliff slope ≈1.0 (blocked)

local terrainRef: any = nil
local heights: { { number } } = {}
local blocked: { { boolean } } = {}   -- cell centre sits inside a TerrainObstacle (e.g. a walled-map wall)

local function cellCenter(i: number, j: number): (number, number)
	return ORIGIN + (i - 1) * CELL, ORIGIN + (j - 1) * CELL
end

local function worldToCell(x: number, z: number): (number, number)
	local i = math.floor((x - ORIGIN) / CELL + 0.5) + 1
	local j = math.floor((z - ORIGIN) / CELL + 0.5) + 1
	return math.clamp(i, 1, DIM), math.clamp(j, 1, DIM)
end

local function heightAt(x: number, z: number): number
	return terrainRef and terrainRef.heightAt(x, z) or 0
end

-- Whether a point sits inside a terrain obstacle (walled-map walls). A half-extent of
-- CELL/2 makes a cell count as blocked when a wall clips through its centre area.
local function obstacleAt(x: number, z: number): boolean
	if not (terrainRef and terrainRef.isPositionBlocked) then return false end
	return terrainRef.isPositionBlocked(Vector3.new(x, 0, z), CELL / 2, CELL / 2)
end

function NavGrid.setTerrainManager(tm: any)
	terrainRef = tm
end

-- Resample every cell's level. Call after the terrain (re)generates.
function NavGrid.rebuild()
	for i = 1, DIM do
		heights[i] = heights[i] or {}
		blocked[i] = blocked[i] or {}
		for j = 1, DIM do
			local x, z = cellCenter(i, j)
			heights[i][j] = heightAt(x, z)
			blocked[i][j] = obstacleAt(x, z)
		end
	end
end

-- Blocked-cell test at a world point (nearest cell). Used by the straight-line check.
local function cellBlockedAt(x: number, z: number): boolean
	local i, j = worldToCell(x, z)
	return blocked[i] ~= nil and blocked[i][j] == true
end

local function passable(i: number, j: number, ni: number, nj: number): boolean
	if (blocked[i] and blocked[i][j]) or (blocked[ni] and blocked[ni][nj]) then return false end
	local ha = heights[i] and heights[i][j]
	local hb = heights[ni] and heights[ni][nj]
	if ha == nil or hb == nil then return false end
	local di    = (ni - i) * CELL
	local dj    = (nj - j) * CELL
	local horiz = math.sqrt(di * di + dj * dj)
	return math.abs(hb - ha) <= MAX_SLOPE * horiz
end

-- Cheap straight-line walkability test: samples the segment and rejects it if any
-- step crosses a cliff. Lets flat/same-tier moves skip A* entirely.
function NavGrid.lineClear(from: Vector3, to: Vector3): boolean
	local dx   = to.X - from.X
	local dz   = to.Z - from.Z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist < 1 then return true end
	local steps   = math.ceil(dist / (CELL * 0.5))
	local segDist = dist / steps
	local prevH   = heightAt(from.X, from.Z)
	for s = 1, steps do
		local t  = s / steps
		local sx = from.X + dx * t
		local sz = from.Z + dz * t
		if cellBlockedAt(sx, sz) then return false end
		local h = heightAt(sx, sz)
		if math.abs(h - prevH) > MAX_SLOPE * segDist then return false end
		prevH = h
	end
	return true
end

local NEIGHBORS = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

local KSTRIDE = DIM + 1
local function keyOf(i: number, j: number): number
	return i * KSTRIDE + j
end

-- String-pull: drop intermediate waypoints we can reach in a straight cliff-free line.
local function simplify(from: Vector3, path: { Vector3 }): { Vector3 }
	if #path <= 1 then return path end
	local out: { Vector3 } = {}
	local anchor = from
	local i = 1
	while i <= #path do
		local j = i
		while j + 1 <= #path and NavGrid.lineClear(anchor, path[j + 1]) do
			j += 1
		end
		table.insert(out, path[j])
		anchor = path[j]
		i = j + 1
	end
	return out
end

-- Returns world-space waypoints from `from` to `to` that never cross a cliff.
-- Falls back to a direct { to } when already clear or when no route exists (the
-- per-unit step blocker still prevents any actual cliff climbing).
function NavGrid.findPath(from: Vector3, to: Vector3): { Vector3 }
	if NavGrid.lineClear(from, to) then return { to } end

	local si, sj = worldToCell(from.X, from.Z)
	local ti, tj = worldToCell(to.X, to.Z)
	if si == ti and sj == tj then return { to } end

	local goalKey = keyOf(ti, tj)
	local startKey = keyOf(si, sj)
	local gScore:   { [number]: number } = { [startKey] = 0 }
	local cameFrom: { [number]: number } = {}
	local closed:   { [number]: boolean } = {}

	-- Binary min-heap keyed by f-score.
	local heap: { { f: number, i: number, j: number } } = {}
	local function hpush(f: number, i: number, j: number)
		table.insert(heap, { f = f, i = i, j = j })
		local c = #heap
		while c > 1 do
			local p = c // 2
			if heap[p].f <= heap[c].f then break end
			heap[p], heap[c] = heap[c], heap[p]
			c = p
		end
	end
	local function hpop()
		local top = heap[1]
		local n = #heap
		heap[1] = heap[n]
		heap[n] = nil
		n -= 1
		local c = 1
		while true do
			local l, r = c * 2, c * 2 + 1
			local s = c
			if l <= n and heap[l].f < heap[s].f then s = l end
			if r <= n and heap[r].f < heap[s].f then s = r end
			if s == c then break end
			heap[c], heap[s] = heap[s], heap[c]
			c = s
		end
		return top
	end
	local function hcost(i: number, j: number): number
		local di, dj = ti - i, tj - j
		return math.sqrt(di * di + dj * dj) * CELL
	end

	hpush(hcost(si, sj), si, sj)
	local found = false
	local expansions = 0
	while #heap > 0 and expansions < 8000 do
		local cur = hpop()
		local ci, cj = cur.i, cur.j
		local ck = keyOf(ci, cj)
		if not closed[ck] then
			closed[ck] = true
			if ck == goalKey then found = true; break end
			expansions += 1
			local cg = gScore[ck]
			for _, nb in NEIGHBORS do
				local ni, nj = ci + nb[1], cj + nb[2]
				if ni >= 1 and ni <= DIM and nj >= 1 and nj <= DIM and passable(ci, cj, ni, nj) then
					local nk = keyOf(ni, nj)
					if not closed[nk] then
						local diag = (nb[1] ~= 0 and nb[2] ~= 0)
						local tg = cg + (diag and CELL * 1.41421 or CELL)
						if not gScore[nk] or tg < gScore[nk] then
							gScore[nk] = tg
							cameFrom[nk] = ck
							hpush(tg + hcost(ni, nj), ni, nj)
						end
					end
				end
			end
		end
	end

	if not found then return { to } end

	-- Reconstruct cell chain (start → goal), then convert to world waypoints.
	local chain: { number } = {}
	local ck: number? = goalKey
	while ck do
		table.insert(chain, 1, ck)
		ck = cameFrom[ck]
	end

	local path: { Vector3 } = {}
	for idx = 2, #chain do
		local k = chain[idx]
		local i = k // KSTRIDE
		local j = k % KSTRIDE
		local wx, wz = cellCenter(i, j)
		table.insert(path, Vector3.new(wx, 0, wz))
	end
	if #path > 0 then
		path[#path] = Vector3.new(to.X, 0, to.Z)   -- end exactly on the destination
	else
		path = { Vector3.new(to.X, 0, to.Z) }
	end

	return simplify(from, path)
end

return NavGrid
