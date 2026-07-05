--!strict
--[[
    LeechPanel — command-card menu shown when one or more owned Leeches are selected
    (the Hollowed unit equivalent of SurvivorPanel). Renders as a 2×2 tile grid.

    A Leech has a single contextual action:
        BURROW    — dig into the ground (structure state, passive income)
        UNBURROW  — surface again as a mobile unit

    The button shown reflects the current state of the selection (read from the
    server-set `Burrowed` BoolValue on each unit part). Clicking sends Network.toggleBurrow
    for every selected Leech that is in the opposite state, so the group ends up consistent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local LeechPanel = {}
local OWNER      = "leech"

local BURROW_COL   = Color3.fromRGB(120, 190,  90)
local UNBURROW_COL = Color3.fromRGB(210, 170,  70)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:   { string } = {}
local networkRef:  any
local stateConns:  { RBXScriptConnection } = {}

function LeechPanel.init(network: any)
	networkRef = network
end

-- ── Helpers ─────────────────────────────────────────────────────────────────────
local function unitPart(id: string): BasePart?
	local uf = workspace:FindFirstChild("Units") :: Folder?
	return uf and uf:FindFirstChild(id) :: BasePart?
end

local function isBurrowed(id: string): boolean
	local part = unitPart(id)
	local bv   = part and part:FindFirstChild("Burrowed") :: BoolValue?
	return bv ~= nil and bv.Value == true
end

local function renderIfActive()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, LeechPanel._buildPage())
	end
end

-- ── Command-card page ───────────────────────────────────────────────────────────
function LeechPanel._buildPage(): CommandCard.Page
	local n = #activeIds

	-- Any surfaced (mobile) Leech in the selection → offer BURROW; else UNBURROW.
	local anyMobile = false
	for _, id in activeIds do
		if not isBurrowed(id) then anyMobile = true; break end
	end

	local slot: CommandCard.Slot
	if anyMobile then
		slot = {
			index   = 1,
			name    = "BURROW",
			icon    = "⬇",
			color   = BURROW_COL,
			desc    = (n > 1) and ("Burrow all " .. n .. " Leeches for passive income.")
				or "Burrow into the ground — becomes a structure that generates passive income.",
			onClick = function()
				for _, id in activeIds do
					if not isBurrowed(id) then networkRef.toggleBurrow(id) end
				end
			end,
		}
	else
		slot = {
			index   = 1,
			name    = "UNBURROW",
			icon    = "⬆",
			color   = UNBURROW_COL,
			desc    = (n > 1) and ("Unburrow all " .. n .. " Leeches back into mobile units.")
				or "Surface again as a mobile unit.",
			onClick = function()
				for _, id in activeIds do
					if isBurrowed(id) then networkRef.toggleBurrow(id) end
				end
			end,
		}
	end

	local header = (n > 1) and ("LEECHES ×" .. n) or "LEECH"
	return { header = header, slots = { slot }, cols = 2 }
end

local function clearConns()
	for _, c in stateConns do c:Disconnect() end
	table.clear(stateConns)
end

-- ── Public API ────────────────────────────────────────────────────────────────
-- `ids` = the currently-selected owned Leech unit ids.
function LeechPanel.show(ids: { string })
	activeIds = ids
	clearConns()
	-- Re-render live when any selected Leech's burrow state flips.
	for _, id in ids do
		local part = unitPart(id)
		local bv   = part and part:FindFirstChild("Burrowed") :: BoolValue?
		if bv then
			table.insert(stateConns, bv.Changed:Connect(renderIfActive))
		elseif part then
			-- Burrowed value only exists after the first toggle; watch for it appearing.
			table.insert(stateConns, part.ChildAdded:Connect(function(ch)
				if ch.Name == "Burrowed" then
					table.insert(stateConns, (ch :: BoolValue).Changed:Connect(renderIfActive))
					renderIfActive()
				end
			end))
		end
	end
	CommandCard.show(OWNER, LeechPanel._buildPage())
end

function LeechPanel.hide()
	activeIds = {}
	clearConns()
	CommandCard.hide(OWNER)
end

function LeechPanel.refreshIfVisible()
	renderIfActive()
end

function LeechPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return LeechPanel
