--!strict
--[[
    TurretPanel — Turret upgrade actions for the command-card grid.

    Shown when a Turret is selected. Three mutually-exclusive upgrade paths
    (Flamethrower / Rocket Launcher / Artillery): choosing one permanently locks
    the others. All network calls and gating logic are preserved.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Config            = require(Shared:WaitForChild("Config"))
local UILib             = require(script.Parent:WaitForChild("UILib"))
local ViewportPreview   = require(script.Parent:WaitForChild("ViewportPreview"))
local CommandCard       = require(script.Parent:WaitForChild("CommandCard"))

local TurretPanel = {}
local C           = UILib.C
local OWNER       = "turret"

local FLAME_COLOR  = Color3.fromRGB(230, 90,  15)
local ROCKET_COLOR = Color3.fromRGB(55,  115, 225)
local ARTY_COLOR   = Color3.fromRGB(210, 165, 55)
local FLAME_COST   = (Config.TURRET_UPGRADE_COST :: any)["Flamethrower"]   or 200
local ROCKET_COST  = (Config.TURRET_UPGRADE_COST :: any)["RocketLauncher"] or 225
local ARTY_COST    = (Config.TURRET_UPGRADE_COST :: any)["Artillery"]      or 400

local UPGRADE_DEFS = {
	{ key = "Flamethrower",   icon = "◈", color = FLAME_COLOR,  cost = FLAME_COST  },
	{ key = "RocketLauncher", icon = "⊕", color = ROCKET_COLOR, cost = ROCKET_COST },
	{ key = "Artillery",      icon = "⊚", color = ARTY_COLOR,   cost = ARTY_COST   },
}

-- ── State ─────────────────────────────────────────────────────────────────────
local activeTurretId: string?
local networkRef:     any
local getResources:   (() -> number)?
local hasResearchFn:  ((string) -> boolean)?
local getMultiIdsFn:  (() -> {string})?

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getUpgradeState(turretId: string): string?
	local bf = workspace:FindFirstChild("Buildings")
	if not bf then return nil end
	local model = bf:FindFirstChild(turretId)
	if not model then return nil end
	local uv = model:FindFirstChild("Upgrade") :: StringValue?
	return uv and uv.Value or nil
end

-- ── Page builder ────────────────────────────────────────────────────────────────
local function buildPage(): CommandCard.Page
	local upgrade = activeTurretId and getUpgradeState(activeTurretId) or nil
	local res     = getResources and getResources() or 0
	local hasBase = hasResearchFn and hasResearchFn("TurretUpgrades") or false

	local slots: { CommandCard.Slot } = {}
	for i, def in UPGRADE_DEFS do
		local key     = def.key
		local locked  = true
		local enabled = true
		local color   = def.color
		local cost: number? = def.cost
		local desc    = ""
		local badge: string? = nil

		if upgrade == key then
			color, cost, badge, desc = C.GREEN, nil, "✓", "Active upgrade"
		elseif upgrade ~= nil then
			color, cost, desc = C.BORDER_LO, nil, "Locked — another path chosen"
		elseif not hasBase then
			color, cost, desc = C.BORDER_LO, nil, "Research 'Turret Upgrades' first"
		else
			locked  = false
			enabled = res >= def.cost
			desc    = "Permanent upgrade path"
		end

		table.insert(slots, {
			index           = i,
			name            = key:upper(),
			cost            = cost,
			color           = color,
			locked          = locked,
			enabled         = enabled,
			icon            = def.icon,
			viewportKey     = "turret:" .. key,
			viewportFactory = function() return ViewportPreview.forBuilding("Turret", Vector2.new(64, 64), nil, key) end,
			badge           = badge,
			desc            = desc,
			onClick         = function()
				if not activeTurretId or locked or not enabled then return end
				local ids = getMultiIdsFn and getMultiIdsFn() or { activeTurretId }
				networkRef.upgradeTurret(ids, key)
				task.delay(0.35, function()
					if activeTurretId and CommandCard.isOwner(OWNER) then
						CommandCard.update(OWNER, buildPage())
					end
				end)
			end,
		})
	end
	return { header = "TURRET", slots = slots }
end

local function renderIfActive()
	if activeTurretId and CommandCard.isOwner(OWNER) then
		CommandCard.update(OWNER, buildPage())
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function TurretPanel.init(network, getResourcesFn, hasResearchFn_, getMultiIds)
	networkRef    = network
	getResources  = getResourcesFn
	hasResearchFn = hasResearchFn_
	getMultiIdsFn = getMultiIds
end

-- ── Public API ────────────────────────────────────────────────────────────────
function TurretPanel.show(turretId: string)
	activeTurretId = turretId
	CommandCard.show(OWNER, buildPage())

	task.spawn(function()
		local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
		if not bf then return end
		local model = bf:WaitForChild(turretId, 10)
		if not model then return end
		model.ChildAdded:Connect(function(child)
			if child.Name == "Upgrade" and activeTurretId == turretId then renderIfActive() end
		end)
	end)
end

function TurretPanel.hide()
	activeTurretId = nil
	CommandCard.hide(OWNER)
end

function TurretPanel.refreshIfVisible()
	renderIfActive()
end

return TurretPanel
