--!strict
--[[
    BlobPanel — Command-card page for the Creepy Blob building.
    Three evolutions: CreepySoldier (cooldown-gated, repeatable),
    CreepyWorm (one-shot, consumes blob), CreepyTurret (one-shot, consumes blob).
]]

local RunService   = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local BlobPanel = {}
local C         = UILib.C
local OWNER     = "blob"

-- ── State ─────────────────────────────────────────────────────────────────────
local activeBlobId:  string? = nil
local networkRef:    any
local getResources:  (() -> number)?
local getMultiIdsFn: (() -> {string})?

local soldierCooldownExpiry: number = 0   -- os.clock() when soldier becomes ready again

-- ── Product definitions ───────────────────────────────────────────────────────
local SOLDIER_COLOR = Color3.fromRGB(50,  170,  80)
local WORM_COLOR    = Color3.fromRGB(130,  85,  30)
local TURRET_COLOR  = Color3.fromRGB(140,  40, 210)

type ProdDef = { key: string, label: string, icon: string, color: Color3, cost: number }

local PROD_DEFS: { ProdDef } = {
	{ key = "CreepySoldier", label = "Survivor", icon = "🪲", color = SOLDIER_COLOR, cost = Config.BLOB_SOLDIER_COST },
	{ key = "CreepyWorm",    label = "Worm",    icon = "🪱", color = WORM_COLOR,    cost = Config.BLOB_WORM_COST    },
	{ key = "CreepyTurret",  label = "Turret",  icon = "⊛", color = TURRET_COLOR,  cost = Config.BLOB_TURRET_COST  },
}

local function prodViewport(key: string): ViewportFrame
	if key == "CreepySoldier" then
		return ViewportPreview.forUnit("CreepySoldier", Vector2.new(64, 64))
	elseif key == "CreepyWorm" then
		return ViewportPreview.forBuilding("CreepyWorm", Vector2.new(64, 64))
	else
		return ViewportPreview.forBuilding("Turret", Vector2.new(64, 64), nil, "Creepy")
	end
end

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local res = getResources and getResources() or 0
	local now = os.clock()

	local slots: { CommandCard.Slot } = {}
	for i, def in PROD_DEFS do
		local key        = def.key
		local onCooldown = key == "CreepySoldier" and soldierCooldownExpiry > now
		local afford     = res >= def.cost
		local badge: string? = nil
		if onCooldown then
			badge = math.max(1, math.ceil(soldierCooldownExpiry - now)) .. "s"
		end
		table.insert(slots, {
			index           = i,
			name            = def.label:upper(),
			cost            = def.cost,
			color           = def.color,
			locked          = onCooldown,
			enabled         = afford,
			icon            = def.icon,
			viewportKey     = "blobprod:" .. key,
			viewportFactory = function() return prodViewport(key) end,
			badge           = badge,
			desc            = onCooldown and "On cooldown" or ("Evolve into " .. def.label),
			onClick         = function()
				if not activeBlobId or onCooldown or not afford then return end
				local ids = getMultiIdsFn and getMultiIdsFn() or { activeBlobId }
				networkRef.blobProduce(ids, key)
				if key == "CreepySoldier" then
					soldierCooldownExpiry = os.clock() + Config.BLOB_SOLDIER_COOLDOWN
				end
			end,
		})
	end
	return { header = "CREEPY BLOB", slots = slots }
end

local function renderIfActive()
	if activeBlobId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- Heartbeat refresh loop (runs while the blob is selected, for the cooldown timer).
local refreshConn: RBXScriptConnection?
local function startRefreshLoop()
	if refreshConn then refreshConn:Disconnect() end
	refreshConn = RunService.Heartbeat:Connect(function()
		if not (activeBlobId and CommandCard.isOwner(OWNER)) then
			if refreshConn then refreshConn:Disconnect(); refreshConn = nil end
			return
		end
		renderIfActive()
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function BlobPanel.init(network: any, getResourcesFn: () -> number, _hasResearch: any, getMultiIds: (() -> {string})?)
	networkRef    = network
	getResources  = getResourcesFn
	getMultiIdsFn = getMultiIds

	-- Server confirms cooldown state (authoritative)
	network.onBlobUpdate(function(blobId: string, cooldownRemaining: number)
		if blobId ~= activeBlobId then return end
		soldierCooldownExpiry = cooldownRemaining > 0 and (os.clock() + cooldownRemaining) or 0
		renderIfActive()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────
function BlobPanel.show(blobId: string)
	activeBlobId          = blobId
	soldierCooldownExpiry = 0
	CommandCard.show(OWNER, buildPage())
	startRefreshLoop()

	-- Auto-close if the blob is destroyed (worm/turret evolution or killed)
	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(blobId, 10)
		if not model then return end
		local base = model:FindFirstChild("Base") :: BasePart?
		if not base then return end
		local conn: RBXScriptConnection
		conn = base.Destroying:Connect(function()
			conn:Disconnect()
			if activeBlobId == blobId then
				BlobPanel.hide()
			end
		end)
	end)
end

function BlobPanel.hide()
	activeBlobId = nil
	CommandCard.hide(OWNER)
end

function BlobPanel.refreshIfVisible()
	renderIfActive()
end

return BlobPanel
