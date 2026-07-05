--!strict
--[[
    BiterPanel — command-card menu shown when one or more owned Biters are selected.
    Renders as a 2×2 tile grid.

    A Biter has no options until the player researches "Biter Genome" at a Brain (tracked
    as the "BiterGenome" player attribute). Before then the grid is empty. Once researched
    it offers three evolutions: Lamprey, Hagfish, Mother — each sends Network.evolveBiter,
    and the server despawns the Biter and spawns the chosen unit/structure in its place.
]]

local Players     = game:GetService("Players")
local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local BiterPanel  = {}
local OWNER       = "biter"
local localPlayer = Players.LocalPlayer

local LAMPREY_COL = Color3.fromRGB(120, 190,  60)
local HAGFISH_COL = Color3.fromRGB( 90, 200, 150)
local MOTHER_COL  = Color3.fromRGB( 40,  40,  48)

type Opt = { key: string, name: string, icon: string, color: Color3, desc: string }
local OPTIONS: { Opt } = {
	{ key = "Lamprey", name = "LAMPREY", icon = "🐍", color = LAMPREY_COL, desc = "Evolve into a Lamprey." },
	{ key = "Hagfish", name = "HAGFISH", icon = "🪱", color = HAGFISH_COL, desc = "Evolve into a Hagfish." },
	{ key = "Mother",  name = "MOTHER",  icon = "⬛", color = MOTHER_COL,  desc = "Evolve into a new Mother (Command Center)." },
}

-- ── State ─────────────────────────────────────────────────────────────────────
local activeIds:  { string } = {}
local networkRef: any
local genomeConn: RBXScriptConnection? = nil

function BiterPanel.init(network: any)
	networkRef = network
end

local function genomeReady(): boolean
	return localPlayer:GetAttribute("BiterGenome") == true
end

local function buildPage(): CommandCard.Page
	local slots: { CommandCard.Slot } = {}
	if genomeReady() then
		for i, opt in OPTIONS do
			table.insert(slots, {
				index   = i,
				name    = opt.name,
				icon    = opt.icon,
				color   = opt.color,
				desc    = opt.desc,
				onClick = function()
					for _, id in activeIds do networkRef.evolveBiter(id, opt.key) end
				end,
			})
		end
	end
	-- No genome yet → empty grid (Biter is a plain combatant until then).
	local n = #activeIds
	local header = (n > 1) and ("BITERS ×" .. n) or "BITER"
	return { header = header, slots = slots, cols = 2 }
end

local function renderIfActive()
	if #activeIds > 0 and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────
function BiterPanel.show(ids: { string })
	activeIds = ids
	-- Re-render if the genome unlocks while a Biter is selected.
	if not genomeConn then
		genomeConn = localPlayer:GetAttributeChangedSignal("BiterGenome"):Connect(renderIfActive)
	end
	CommandCard.show(OWNER, buildPage())
end

function BiterPanel.hide()
	activeIds = {}
	CommandCard.hide(OWNER)
end

function BiterPanel.refreshIfVisible()
	renderIfActive()
end

function BiterPanel.isActive(): boolean
	return #activeIds > 0 and CommandCard.isOwner(OWNER)
end

return BiterPanel
