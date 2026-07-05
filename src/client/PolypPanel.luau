--!strict
--[[
    PolypPanel — command-card menu shown when one or more owned Polyps are selected.
    Renders as a 2×2 tile grid. The Polyp morphs (instantly, for free) into one of two
    structures: the Brain or a Creepy Turret. Sends Network.morphPolyp; the server
    despawns the Polyp and builds the structure where it stood.
]]

local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local PolypPanel = {}
local OWNER      = "polyp"

local BRAIN_COL  = Color3.fromRGB(150,  90, 180)
local TURRET_COL = Color3.fromRGB(190,  70,  70)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Brain",        name = "BRAIN",         icon = "🧠", color = BRAIN_COL,  desc = "Morph into a Brain — researches Biter Genome." },
	{ key = "CreepyTurret", name = "CREEPY TURRET", icon = "🗼", color = TURRET_COL, desc = "Morph into a Creepy Turret." },
}

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any

function PolypPanel.init(network: any)
	networkRef = network
end

local function buildPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {}
	for i, opt in OPTIONS do
		table.insert(slots, {
			index   = i,
			name    = opt.name,
			icon    = opt.icon,
			color   = opt.color,
			desc    = opt.desc,
			onClick = function()
				for _, id in activeIds do networkRef.morphPolyp(id, opt.key) end
			end,
		})
	end
	local n = #activeIds
	local header = (n > 1) and ("POLYPS ×" .. n) or "POLYP"
	return { header = header, slots = slots, cols = 2 }
end

-- ── Public API ────────────────────────────────────────────────────────────────
function PolypPanel.show(ids: { string })
	activeIds = ids
	CommandCard.show(OWNER, buildPage())
end

function PolypPanel.hide()
	activeIds = {}
	CommandCard.hide(OWNER)
end

function PolypPanel.refreshIfVisible()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

function PolypPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return PolypPanel
