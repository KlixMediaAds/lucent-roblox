--!strict
--[[
    BrainPanel — command-card menu shown when an owned Brain is selected. Renders as a
    2×2 tile grid with one option for now: BITER GENOME, a 3-second research that unlocks
    Biter evolution (tracked server-side as the "BiterGenome" player attribute).

    The slot shows a progress bar while researching and a ✓ once done. Progress is driven
    client-side (optimistic) from the click; the attribute flip confirms completion.
]]

local Players     = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Config      = require(Shared:WaitForChild("Config"))
local CommandCard = require(script.Parent:WaitForChild("CommandCard"))

local BrainPanel  = {}
local OWNER       = "brain"
local localPlayer = Players.LocalPlayer

local GENE_COL = Color3.fromRGB(120, 200, 255)

-- ── State ─────────────────────────────────────────────────────────────────────
local activeBrainId: string? = nil
local networkRef:    any
local researchStart: number? = nil   -- os.clock() when research began locally (optimistic)
local genomeConn:    RBXScriptConnection? = nil

function BrainPanel.init(network: any)
	networkRef = network
end

local function genomeDone(): boolean
	return localPlayer:GetAttribute("BiterGenome") == true
end

local function buildPage(): CommandCard.Page
	local done        = genomeDone()
	local researching = (not done) and researchStart ~= nil
	if done then researchStart = nil end

	local name, desc = "BITER GENOME", "Research Biter Genome — unlocks Biter evolution."
	local badge:    string? = nil
	local progress: number? = nil
	local locked = false

	if done then
		desc, badge, locked = "Researched — Biters can now evolve.", "✓", true
	elseif researching then
		progress = math.clamp((os.clock() - (researchStart :: number)) / Config.BITER_GENOME_TIME, 0, 1)
		name, desc, locked = "RESEARCHING…", "Decoding the Biter Genome…", true
	end

	local slot: CommandCard.Slot = {
		index    = 1,
		name     = name,
		icon     = "🧬",
		color    = GENE_COL,
		desc     = desc,
		badge    = badge,
		locked   = locked,
		progress = progress,
		onClick  = function()
			if genomeDone() or researchStart ~= nil or not activeBrainId then return end
			researchStart = os.clock()
			networkRef.researchBrain(activeBrainId)
			CommandCard.update(OWNER, buildPage())
		end,
	}
	return { header = "BRAIN", slots = { slot }, cols = 2 }
end

local function renderIfActive()
	if activeBrainId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────
function BrainPanel.show(brainId: string)
	activeBrainId = brainId
	if not genomeConn then
		genomeConn = localPlayer:GetAttributeChangedSignal("BiterGenome"):Connect(renderIfActive)
	end
	CommandCard.show(OWNER, buildPage())
	-- Tick the progress bar while a research is running and this Brain stays selected.
	task.spawn(function()
		while activeBrainId == brainId and CommandCard.isOwner(OWNER) do
			if researchStart ~= nil and not genomeDone() then renderIfActive() end
			task.wait(0.1)
		end
	end)
end

function BrainPanel.hide()
	activeBrainId = nil
	CommandCard.hide(OWNER)
end

function BrainPanel.refreshIfVisible()
	renderIfActive()
end

function BrainPanel.isActive(): boolean
	return activeBrainId ~= nil and CommandCard.isOwner(OWNER)
end

return BrainPanel
