--!strict
--[[
    RollerPanel — command-card menu shown when one or more owned Rollers are selected.
    Renders as a 2×2 tile grid (the Hollowed unit style).

    A Roller carries up to MountCap passengers. The panel offers:
        MOUNT    — board owned units standing nearby (up to remaining capacity)
        DISMOUNT — eject all current passengers

    Passenger counts are read live from the server-set "Passengers" / "MountCap"
    attributes on each Roller's pivot part. Actions apply to every selected Roller.
]]

local Players     = game:GetService("Players")
local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local RollerPanel = {}
local OWNER       = "roller"
local localPlayer = Players.LocalPlayer

local MOUNT_COL    = Color3.fromRGB(150,  70, 110)
local DISMOUNT_COL = Color3.fromRGB(210, 150,  80)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any
local attrConns:  { RBXScriptConnection } = {}

function RollerPanel.init(network: any)
	networkRef = network
end

-- ── Helpers ─────────────────────────────────────────────────────────────────────
local function unitPart(id: string): BasePart?
	local uf = workspace:FindFirstChild("Units") :: Folder?
	return uf and uf:FindFirstChild(id) :: BasePart?
end

-- Total passengers + total capacity across the selected Rollers.
local function tally(): (number, number)
	local pax, cap = 0, 0
	for _, id in activeIds do
		local part = unitPart(id)
		if part then
			pax += (part:GetAttribute("Passengers") :: number?) or 0
			cap += (part:GetAttribute("MountCap") :: number?) or 0
		end
	end
	return pax, cap
end

local function renderIfActive()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, RollerPanel._buildPage())
	end
end

-- ── Command-card page ───────────────────────────────────────────────────────────
function RollerPanel._buildPage(): CommandCard.Page
	local n        = #activeIds
	local pax, cap = tally()
	local hasRoom  = pax < cap
	local hasPax   = pax > 0

	local slots: { CommandCard.Slot } = {
		{
			index   = 1,
			name    = "MOUNT",
			icon    = "🛡",
			color   = MOUNT_COL,
			enabled = hasRoom,
			locked  = not hasRoom,
			desc    = hasRoom
				and ("Board nearby units into the Roller. Melee units add grind damage; ranged units fire from within. (" .. pax .. "/" .. cap .. ")")
				or ("Roller is full (" .. pax .. "/" .. cap .. ")."),
			onClick = function()
				for _, id in activeIds do networkRef.rollerMountNearby(id) end
			end,
		},
		{
			index   = 2,
			name    = "DISMOUNT",
			icon    = "🚪",
			color   = DISMOUNT_COL,
			enabled = hasPax,
			locked  = not hasPax,
			desc    = hasPax
				and ("Eject all passengers (" .. pax .. "/" .. cap .. ").")
				or "No passengers aboard.",
			onClick = function()
				for _, id in activeIds do networkRef.rollerDismount(id) end
			end,
		},
	}

	local header = (n > 1) and ("ROLLERS ×" .. n) or ("ROLLER  " .. pax .. "/" .. cap)
	return { header = header, slots = slots, cols = 2 }
end

local function clearConns()
	for _, c in attrConns do c:Disconnect() end
	table.clear(attrConns)
end

-- ── Public API ────────────────────────────────────────────────────────────────
function RollerPanel.show(ids: { string })
	activeIds = ids
	clearConns()
	-- Re-render live as passenger counts change on any selected Roller.
	for _, id in ids do
		local part = unitPart(id)
		if part then
			table.insert(attrConns, part:GetAttributeChangedSignal("Passengers"):Connect(renderIfActive))
		end
	end
	CommandCard.show(OWNER, RollerPanel._buildPage())
end

function RollerPanel.hide()
	activeIds = {}
	clearConns()
	CommandCard.hide(OWNER)
end

function RollerPanel.refreshIfVisible()
	renderIfActive()
end

function RollerPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return RollerPanel
