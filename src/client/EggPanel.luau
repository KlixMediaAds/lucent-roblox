--!strict
--[[
    EggPanel — command-card menu shown when one of the Mother's Egg-Sac eggs is selected.
    Renders as a 2×2 tile grid, offering the same four choices an Embryo had.

    Picking an option sends Network.assignEgg: the egg then keeps exactly one of that
    unit alive, re-hatching it after it dies. The choice can be changed at any time, but
    a new unit only hatches once the current one dies.

    Each creature has its own incubation (Config.EGG_SPAWN_TIME), which is the real cost
    of the choice, so every tile carries the time as a badge and repeats it in the tip.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local EggPanel = {}
local OWNER    = "egg"

local LAMPREY_COL = Color3.fromRGB(120, 190,  60)
local HAGFISH_COL = Color3.fromRGB( 90, 200, 150)
local ROLLER_COL  = Color3.fromRGB(150,  70, 110)
local NEEDLER_COL = Color3.fromRGB(170, 100,  60)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Lamprey", name = "LAMPREY", icon = "🐍", color = LAMPREY_COL, desc = "This egg hatches Lampreys." },
	{ key = "Hagfish", name = "HAGFISH", icon = "🪱", color = HAGFISH_COL, desc = "This egg hatches Hagfish." },
	{ key = "Roller",  name = "ROLLER",  icon = "⚙", color = ROLLER_COL,  desc = "This egg hatches Rollers, fast armored grinders." },
	{ key = "Needler", name = "NEEDLER", icon = "🦂", color = NEEDLER_COL, desc = "This egg hatches Needlers, slow stalkers that strike with one long insect arm." },
}

-- ── State ─────────────────────────────────────────────────────────────────────
-- The selected egg + its tentacle-tree descendants; a unit choice applies to all of them.
local activeEggIds: { string } = {}
local networkRef:   any

function EggPanel.init(network: any)
	networkRef = network
end

local function buildPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {}
	for i, opt in OPTIONS do
		local secs = Config.eggSpawnTime(opt.key)
		table.insert(slots, {
			index   = i,
			name    = opt.name .. "  (" .. secs .. "s)",
			icon    = opt.icon,
			color   = opt.color,
			badge   = secs .. "s",
			desc    = opt.desc .. " Incubation: " .. secs .. "s per spawn.",
			onClick = function()
				for _, id in activeEggIds do networkRef.assignEgg(id, opt.key) end
			end,
		})
	end
	local n = #activeEggIds
	local header = (n > 1) and ("EGGS ×" .. n) or "EGG"
	return { header = header, slots = slots, cols = 2 }
end

-- ── Public API ────────────────────────────────────────────────────────────────
function EggPanel.show(eggIds: { string })
	activeEggIds = eggIds
	CommandCard.show(OWNER, buildPage())
end

function EggPanel.hide()
	activeEggIds = {}
	CommandCard.hide(OWNER)
end

function EggPanel.isActive(): boolean
	return #activeEggIds > 0 and CommandCard.isOwner(OWNER)
end

return EggPanel
