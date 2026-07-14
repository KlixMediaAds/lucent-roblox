--!strict
--[[
    EmbryoPanel — command-card menu shown when one or more owned Embryos are selected.
    Renders as a 2×2 tile grid.

    Every Embryo can evolve straight away (no unlock required): the grid always offers
    four evolutions — Lamprey, Hagfish, Roller, Needler — each sends Network.evolveEmbryo,
    and the server despawns the Embryo and spawns the chosen unit in its place.
]]

local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local EmbryoPanel = {}
local OWNER       = "embryo"

local LAMPREY_COL = Color3.fromRGB(120, 190,  60)
local HAGFISH_COL = Color3.fromRGB( 90, 200, 150)
local ROLLER_COL  = Color3.fromRGB(150,  70, 110)
local NEEDLER_COL = Color3.fromRGB(170, 100,  60)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Lamprey", name = "LAMPREY", icon = "🐍", color = LAMPREY_COL, desc = "Evolve into a Lamprey." },
	{ key = "Hagfish", name = "HAGFISH", icon = "🪱", color = HAGFISH_COL, desc = "Evolve into a Hagfish." },
	{ key = "Roller",  name = "ROLLER",  icon = "⚙", color = ROLLER_COL,  desc = "Evolve into a Roller — a fast, armored grinder." },
	{ key = "Needler", name = "NEEDLER", icon = "🦂", color = NEEDLER_COL, desc = "Evolve into a Needler — a slow stalker that hauls itself along on one long insect arm and strikes with it." },
}

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any

function EmbryoPanel.init(network: any)
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
				for _, id in activeIds do networkRef.evolveEmbryo(id, opt.key) end
			end,
		})
	end
	local n = #activeIds
	local header = (n > 1) and ("EMBRYOS ×" .. n) or "EMBRYO"
	return { header = header, slots = slots, cols = 2 }
end

local function renderIfActive()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────
function EmbryoPanel.show(ids: { string })
	activeIds = ids
	CommandCard.show(OWNER, buildPage())
end

function EmbryoPanel.hide()
	activeIds = {}
	CommandCard.hide(OWNER)
end

function EmbryoPanel.refreshIfVisible()
	renderIfActive()
end

function EmbryoPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return EmbryoPanel
