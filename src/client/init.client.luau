local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local SoundService      = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local PerfProbe = require(Shared:WaitForChild("PerfProbe"))
local Config            = require(Shared:WaitForChild("Config"))
local UnitVisuals       = require(Shared:WaitForChild("UnitVisuals"))
local InjectPlants      = require(Shared:WaitForChild("InjectPlants"))

local Network        = require(script:WaitForChild("Network"))
local CameraModule   = require(script:WaitForChild("Camera"))
local BuildingPlacer = require(script:WaitForChild("BuildingPlacer"))
local UnitController = require(script:WaitForChild("UnitController"))
local MinePanel      = require(script:WaitForChild("MinePanel"))
local WorkshopPanel          = require(script:WaitForChild("WorkshopPanel"))
local UnlockNotification     = require(script:WaitForChild("UnlockNotification"))
local HUD            = require(script:WaitForChild("HUD"))
local FogManager     = require(script:WaitForChild("FogManager"))
local SpiderLegs     = require(script:WaitForChild("SpiderLegs"))
local CreepyLegs     = require(script:WaitForChild("CreepyLegs"))
local WalkerLegs     = require(script:WaitForChild("WalkerLegs"))
local LampreyBody    = require(script:WaitForChild("LampreyBody"))
local HagfishBody    = require(script:WaitForChild("HagfishBody"))
local BroodmotherBody = require(script:WaitForChild("BroodmotherBody"))
local LeechBody      = require(script:WaitForChild("LeechBody"))
local RollerBody     = require(script:WaitForChild("RollerBody"))
local WatcherBody    = require(script:WaitForChild("WatcherBody"))
local NeedlerBody    = require(script:WaitForChild("NeedlerBody"))
local MotherEggBody  = require(script:WaitForChild("MotherEggBody"))
local FabricatorArms = require(script:WaitForChild("FabricatorArms"))
local FoundryRotor   = require(script:WaitForChild("FoundryRotor"))
local TurretPanel    = require(script:WaitForChild("TurretPanel"))
local BlobPanel      = require(script:WaitForChild("BlobPanel"))
local LampreyNestPanel = require(script:WaitForChild("LampreyNestPanel"))
local EngineeringPanel = require(script:WaitForChild("EngineeringPanel"))
local DeployerPanel  = require(script:WaitForChild("DeployerPanel"))
local TestPanel      = require(script:WaitForChild("TestPanel"))
local SurvivorPanel  = require(script:WaitForChild("SurvivorPanel"))
local MotherPanel    = require(script:WaitForChild("MotherPanel"))
local MotherInject   = require(script:WaitForChild("MotherInject"))
local InjectParasite = require(script:WaitForChild("InjectParasite"))
local BodyLOD        = require(script:WaitForChild("BodyLOD"))
local PerfHUD        = require(script:WaitForChild("PerfHUD"))
local LeechPanel     = require(script:WaitForChild("LeechPanel"))
local EmbryoPanel    = require(script:WaitForChild("EmbryoPanel"))
local EggPanel       = require(script:WaitForChild("EggPanel"))
local RollerPanel    = require(script:WaitForChild("RollerPanel"))
local NeedlerPanel   = require(script:WaitForChild("NeedlerPanel"))
local CCMobilePanel  = require(script:WaitForChild("CCMobilePanel"))
local CommandCard    = require(script:WaitForChild("CommandCard"))
local Jumpscare      = require(script:WaitForChild("Jumpscare"))
local MechLegs       = require(script:WaitForChild("MechLegs"))
local MotherLegs     = require(script:WaitForChild("MotherLegs"))
local MiniMap        = require(script:WaitForChild("MiniMap"))
local QuickSelect    = require(script:WaitForChild("QuickSelect"))
local ScoutManager   = require(script:WaitForChild("ScoutManager"))
local Tutorial       = require(script:WaitForChild("Tutorial"))
local CometManager    = require(script:WaitForChild("CometManager"))
local DepositFX       = require(script:WaitForChild("DepositFX"))
local EggReadyIcon    = require(script:WaitForChild("EggReadyIcon"))
local ForestFade      = require(script:WaitForChild("ForestFade"))
local LobbyUI         = require(script:WaitForChild("LobbyUI"))
local MainMenu        = require(script:WaitForChild("MainMenu"))
local ShaderManager   = require(script:WaitForChild("ShaderManager"))
local ViewportPreview = require(script:WaitForChild("ViewportPreview"))
local AmbientAudio    = require(script:WaitForChild("AmbientAudio"))
-- Every one-shot combat effect the client draws (shots, impacts, their sounds). Lifted out
-- of this script: it is scenery with no knowledge of the match, and 1.8k lines of it was
-- both noise here and real weight against Luau's ceiling of 200 locals per chunk.
local CombatFX        = require(script:WaitForChild("CombatFX"))

-- Disable default character controls so WASD only moves the RTS camera.
-- The ControlModule re-enables itself every time the character (re)spawns and, in the
-- frame before the new character exists, calls the deprecated Player:Move(), which logs
-- "Player:Move called, but player currently has no character." So we re-disable on each
-- CharacterAdded (once the character is present) rather than only at startup.
task.spawn(function()
	local player           = Players.LocalPlayer
	local ok, PlayerModule = pcall(require,
		player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	if not ok then return end

	local function disableControls()
		pcall(function() PlayerModule:GetControls():Disable() end)
	end

	-- Disable now (character may already exist) and again whenever one spawns, waiting
	-- until the character is actually parented so the ControlModule has something to act on.
	if player.Character then disableControls() end
	player.CharacterAdded:Connect(function()
		task.defer(disableControls)
	end)
end)

-- Hide the default Roblox leaderboard / player list (it sits top-right, where the
-- minimap now lives). Retried because SetCoreGuiEnabled can no-op if the CoreGui
-- isn't ready yet on the first frame.
task.spawn(function()
	local StarterGui = game:GetService("StarterGui")
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if ok then break end
		task.wait(0.5)
	end
end)

-- Global UI click + hover sounds: every GuiButton (anywhere in PlayerGui, lobby or
-- in-game) plays a click on activation and a soft two-layer cue on hover. Hooking
-- PlayerGui descendants covers buttons made by any module, including ones created
-- later, without touching each call site.
do
	local clickSound       = Instance.new("Sound")
	clickSound.Name        = "UIClick"
	clickSound.SoundId     = "rbxassetid://87204053561751"
	clickSound.Volume      = 0.5
	clickSound.Parent      = SoundService

	-- Hover: a pebble tap leads, and a ceramic tick follows 0.25 s later. The ceramic
	-- gets a random pitch so sweeping a row of buttons never sounds like the same sample;
	-- the pebble stays at its natural pitch.
	local HOVER_CERAMIC = "rbxassetid://132354646581778"
	local HOVER_PEBBLE  = "rbxassetid://9117267146"
	local function playHoverClip(id: string, vary: boolean)
		local s           = Instance.new("Sound")
		s.SoundId         = id
		s.Volume          = 0.35
		if vary then
			s.PlaybackSpeed = 0.85 + math.random() * 0.4   -- ~0.85×–1.25× random pitch
		end
		s.Parent          = SoundService
		s:Play()
		s.Ended:Once(function() s:Destroy() end)
	end
	local function playHover()
		playHoverClip(HOVER_PEBBLE, false)                                    -- pebble leads, fixed pitch
		task.delay(0.25, function() playHoverClip(HOVER_CERAMIC, true) end)   -- ceramic 0.25 s behind, varied
	end

	local playerGui        = Players.LocalPlayer:WaitForChild("PlayerGui")
	local function hook(inst: Instance)
		if inst:IsA("GuiButton") then
			-- Click SFX only on the lobby READY button and the radial menu nodes.
			if inst.Name == "ReadyButton" or inst.Name == "NodeBtn" then
				inst.Activated:Connect(function() clickSound:Play() end)
			end
			inst.MouseEnter:Connect(playHover)
		end
	end
	for _, d in playerGui:GetDescendants() do hook(d) end
	playerGui.DescendantAdded:Connect(hook)
end

local localUserId = Players.LocalPlayer.UserId

-- The Hollowed race drives everything from the Mother's option grid instead of the
-- Human build tray, so selection/[Space] branch on this.
local function isHollowedLocal(): boolean
	return Players.LocalPlayer:GetAttribute("Faction") == "Hollowed"
end

-- Client-side deposit resource tracking for hover health bars (posKey → remaining)
local depositClientRes: { [string]: number } = {}
local function posKeyC(v: Vector3): string
	return math.round(v.X) .. "," .. math.round(v.Z)
end

-- Current resource amount (tracked for MinePanel affordability checks)
local currentResources = 0

-- The local player's own CC building id (needed to open WorkshopPanel via the HUD button)
local ownCCId: string? = nil
local placedFirstBonfire = false   -- upgrades button stays hidden until the first Bonfire

-- Win/lose overlay (forward-declared so enterCCMode can hide it on reset)
local winOverlay: Frame?

-- Multiplayer surrender-vote popup (built once inside startGame; forward-declared so the
-- return-to-lobby handler can close it and the network handlers can drive it).
local showSurrenderVote: (requesterName: string) -> () = function(_) end
local hideSurrenderVote: () -> () = function() end

-- Monument tracking
local monumentBuildingId: { [number]: string }       = {}  -- ownerUserId → buildingId
local monumentBillboards: { [number]: BillboardGui } = {}  -- ownerUserId → floating timer

-- Research state (replicated from server)
local researchedTechs:  { [string]: boolean } = {}
local localKillCount:   number                = 0
local localTrainCounts: { [string]: number }  = {}
local localBuildCounts: { [string]: number }  = {}

-- Evolved turret client state
type TentacleParts = { joints: {Part}, connectors: {Part}, teeth: {Part} }
type EvolvedData = {
	targets:    { Vector3? },
	lastTarget: number,
	tentacles:  { TentacleParts },
	tipPos:     { Vector3 },   -- smoothed tip position per tentacle (avoids snapping)
	sound:      Sound?,
}
local evolvedTurrets: { [string]: EvolvedData } = {}

-- buildingType → count of owned (non-CC) buildings for requirement system
local ownedBuildingCounts: { [string]: number } = {}

local function clearMineData()
	depositClientRes  = {}
	HUD.setIncome(0)
end

local function refreshRequirements()
	HUD.refreshTrayState(ownedBuildingCounts)
end

-- Rough income-per-minute readout: the Command Center plus every Foundry's base output.
-- Deposit boosts aren't reflected here (the server-side per-Foundry label shows those);
-- this is just a baseline so the HUD income row stays meaningful.
local function updateIncomeReadout()
	local perMin = 0
	if ownCCId then
		perMin += Config.CC_PASSIVE_INCOME * (60 / Config.CC_PASSIVE_INTERVAL)
	end
	local foundries = ownedBuildingCounts["Foundry"] or 0
	perMin += foundries * Config.FOUNDRY_BASE_INCOME * (60 / Config.FOUNDRY_INCOME_INTERVAL)
	HUD.setIncome(perMin)
end

-- Whether the local player's CC is currently in mobile (walking) state
local ccIsMobile = false
-- Which Command Center is currently selected (nil = none). A right-click is only a move
-- order for a CC that is actually selected; without this the Mother, who is mobile for
-- most of a match, walked off after EVERY right-click on the map -- including the ones
-- meant to move units or to dismiss a selection.
local ccSelectedId: string? = nil

-- Core deploy flow: the local player's Core unit id (pre-CC), and a guard so the
-- DEPLOY button can only be pressed once per Core.

-- Transparent CC+legs preview shown at cursor while CC is in move mode
local ccMoveGhost:  Model?   = nil
local ccMoveTarget: Vector3? = nil   -- last snapped ground target for the ghost

local function destroyCCMoveGhost()
	if ccMoveGhost then ccMoveGhost:Destroy(); ccMoveGhost = nil end
	ccMoveTarget = nil
end

local function buildCCMoveGhost()
	destroyCCMoveGhost()
	-- The Hollowed Mother walks as a creature under her own power, so she gets no
	-- placement hologram trailing the cursor — you order her around, you don't
	-- re-site a structure.
	if isHollowedLocal() then return end
	local color = Players.LocalPlayer.TeamColor
	local ccSz  = Config.COMMAND_CENTER_SIZE
	local halfH = ccSz.Y / 2

	local m    = Instance.new("Model")
	m.Name     = "__CCMoveGhost"

	-- Transparent base block
	local base          = Instance.new("Part")
	base.Name           = "Base"
	base.Size           = ccSz
	base.Position       = Vector3.new(0, halfH, 0)
	base.BrickColor     = color
	base.Material       = Enum.Material.SmoothPlastic
	base.Transparency   = 0.5
	base.Anchored       = true
	base.CanCollide     = false
	base.CanQuery       = false
	base.CanTouch       = false
	base.CastShadow     = false
	base.Parent         = m
	m.PrimaryPart       = base

	-- Fabricator Core decor (shared with the live CC), made ghostly
	UnitVisuals.buildCommandCenterDecor(m, CFrame.new(0, 0, 0), color, false)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= base then
			d.Transparency = math.max(d.Transparency, 0.5)
			d.CanQuery     = false
			d.CanTouch     = false
		end
	end

	-- Static leg stubs (matching MechLegs geometry constants)
	local HIP_X,  HIP_Y,  HIP_Z  = 5,  2,  5
	local FOOT_X, FOOT_Y, FOOT_Z = 12, -5, 12
	local LEG_W                   = 2.2
	for _, c in { {1, 1}, {-1, -1}, {1, -1}, {-1, 1} } do
		local xs, zs = c[1], c[2]
		local hipL   = Vector3.new(xs * HIP_X,  halfH + HIP_Y,  zs * HIP_Z)
		local footL  = Vector3.new(xs * FOOT_X, halfH + FOOT_Y, zs * FOOT_Z)
		local mid    = (hipL + footL) * 0.5
		local len    = (hipL - footL).Magnitude

		local leg           = Instance.new("Part")
		leg.Name            = "Leg"
		leg.Size            = Vector3.new(LEG_W, len, LEG_W)
		leg.Color           = Color3.fromRGB(50, 55, 70)
		leg.Material        = Enum.Material.Metal
		leg.Transparency    = 0.4
		leg.Anchored        = true
		leg.CanCollide      = false
		leg.CanQuery        = false
		leg.CanTouch        = false
		leg.CastShadow      = false
		leg.CFrame          = CFrame.lookAt(mid, footL) * CFrame.Angles(math.pi * 0.5, 0, 0)
		leg.Parent          = m
	end

	m.Parent    = workspace
	ccMoveGhost = m
end

-- Selection/drag-select is off while a ghost is being placed, and while the Mother is
-- waiting for the player to click the ground for an injection, since that click belongs to
-- the injection, not to the selection box.
local function isBlocked(): boolean
	return BuildingPlacer.isActive() or MotherInject.isAiming()
end

local function startGame(gamemode: string?)

local isLane = gamemode == "Lane"

CameraModule.init()
-- Shared pose budget for every procedural rig below. Must be initialised before
-- them: they all ask it how much of this frame they are allowed to spend.
BodyLOD.init(workspace.CurrentCamera)

-- ── Performance overlay ───────────────────────────────────────────────────────
-- F3 shows where the frame is going, F4 prints the same table to the console (F9).
-- Sampling only runs while it is up, so this costs nothing in a normal session.
PerfHUD.init()
do
	local RemoteHandler = require(Shared:WaitForChild("RemoteHandler"))
	RemoteHandler.get(Config.REMOTES.PerfSync).OnClientEvent:Connect(function(frameMs, rows)
		PerfHUD.setServerReport(tonumber(frameMs) or 0, rows)
	end)
end
DepositFX.start()
SpiderLegs.init(workspace.CurrentCamera)
CreepyLegs.init(workspace.CurrentCamera)
WalkerLegs.init(workspace.CurrentCamera)
LampreyBody.init(workspace.CurrentCamera)
HagfishBody.init(workspace.CurrentCamera)
BroodmotherBody.init(workspace.CurrentCamera)
LeechBody.init(workspace.CurrentCamera)
RollerBody.init(workspace.CurrentCamera)
WatcherBody.init(workspace.CurrentCamera)
NeedlerBody.init(workspace.CurrentCamera)
MotherEggBody.init(workspace.CurrentCamera)
InjectParasite.init(workspace.CurrentCamera)
FabricatorArms.init(workspace.CurrentCamera)
FoundryRotor.init(workspace.CurrentCamera)
BuildingPlacer.init(Network, CameraModule)
BuildingPlacer.setResourceGetter(function() return currentResources end)
BuildingPlacer.setNotEnoughResourcesFn(function()
	HUD.playErrorSound()
	HUD.showNotification("⚠  Not enough resources", Color3.fromRGB(230, 60, 60))
end)

-- ── Horror ambience ───────────────────────────────────────────────────────────
-- A continuous eerie bed under the whole match, plus a one-shot "song" the FIRST
-- time the player is ever attacked. Both are 2D (parented to SoundService) so they
-- play at full volume regardless of where the camera is.
local AMBIENCE_VOLUME    = 0.245   -- eerie bed, -30%
local FIRST_ATTACK_VOLUME = 0.49   -- first-attack song, -30%

-- Clear any leftover audio from a previous match in the same session before
-- (re)creating it, so replays don't stack duplicate loops.
for _, leftoverName in { "HorrorAmbience", "FirstAttackStinger" } do
	local old = SoundService:FindFirstChild(leftoverName)
	if old then old:Destroy() end
end

local horrorAmbience      = Instance.new("Sound")
horrorAmbience.Name       = "HorrorAmbience"
horrorAmbience.SoundId    = "rbxassetid://9112775414"
horrorAmbience.Looped     = true
horrorAmbience.Volume     = AMBIENCE_VOLUME
horrorAmbience.Parent     = SoundService
horrorAmbience:Play()

-- Environmental bed: a constant 2D wind loop + a 3D field of cricket/cicada emitters
-- across the map (see AmbientAudio). Started here so it shares the match's lifetime.
AmbientAudio.start()

local firstAttackSongPlayed = false

-- ── In-flight placement tracking (live cost scaling) ──────────────────────────
-- A placed building doesn't enter the count until its drop pod lands (BuildingPlaced
-- fires). To make the displayed price climb the instant you place one, we track
-- per-type "pending" tokens here: pushed when a placement is sent, popped when the
-- matching BuildingPlaced arrives, and expiring on a TTL so a server-rejected
-- placement self-heals. These feed the HUD's COST only (not requirement gating).
-- Must safely outlast the slowest placement: pod flight + the longest Config.BUILD_TIME
-- (Foundry = 20s). If this expires before BuildingPlaced lands, the scaled price sags
-- back down mid-construction (the Foundry-price bug) until the build finishes.
local PENDING_TTL = 30   -- seconds (pod flight + max build time, with margin)
local pendingPlace: { [string]: { number } } = {}

local function buildPendingCounts(): { [string]: number }
	local now = os.clock()
	local out: { [string]: number } = {}
	for btype, list in pendingPlace do
		local i = 1
		while i <= #list do
			if list[i] <= now then table.remove(list, i) else i += 1 end
		end
		if #list > 0 then out[btype] = #list else pendingPlace[btype] = nil end
	end
	return out
end

local function pushPending(btype: string)
	local list = pendingPlace[btype]
	if not list then list = {}; pendingPlace[btype] = list end
	table.insert(list, os.clock() + PENDING_TTL)
	HUD.setPendingCounts(buildPendingCounts())
end

local function popPending(btype: string)
	local list = pendingPlace[btype]
	if list and #list > 0 then table.remove(list, 1) end   -- the matching build landed
	HUD.setPendingCounts(buildPendingCounts())
end

BuildingPlacer.onPlaceSent(function(btype: string) pushPending(btype) end)
BuildingPlacer.setCostGetter(function(btype: string) return HUD.getBuildCost(btype) end)

-- Periodic sweep so expired (rejected) tokens drop and the price corrects on its own.
task.spawn(function()
	while true do
		task.wait(1)
		if next(pendingPlace) then HUD.setPendingCounts(buildPendingCounts()) end
	end
end)

local dragFrame, ccBtn = HUD.create()
CommandCard.init(Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui)
Jumpscare.init(Players.LocalPlayer:WaitForChild("PlayerGui"))
if isLane then HUD.setLaneMode(true) end
Tutorial.init(Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui)

UnitController.init(Network, CameraModule, dragFrame, isBlocked)
UnitController.onMoveIssued(function(ids: { string })
	Tutorial.notify("move_issued")
	ScoutManager.releaseUnits(ids)   -- hand-ordered units leave their army assignment
end)
MinePanel.init(Network,
	function() return currentResources end,
	function(techName) return researchedTechs[techName] == true end)
WorkshopPanel.init(Network,
	function(techName) return researchedTechs[techName] == true end,
	function() return currentResources end,
	function(techName: string): { current: number, needed: number, label: string }
		local unlock = (Config.UNLOCKS :: any)[techName]
		if not unlock then return { current = 0, needed = 1, label = "" } end
		local cond    = (unlock.cond :: any)
		local label   = (unlock.condText :: string?) or ""
		local needed  = (cond.count :: number)
		local t       = cond.type :: string
		local current = 0
		if t == "building" then
			local name = cond.name :: string
			if name == "any" then
				for _, v in localBuildCounts do current += v end
			else
				current = localBuildCounts[name] or 0
			end
		elseif t == "kill" then
			current = localKillCount
		elseif t == "train" then
			current = localTrainCounts[cond.name :: string] or 0
		end
		return { current = current, needed = needed, label = label }
	end)
TurretPanel.init(Network,
	function() return currentResources end,
	function(techName) return researchedTechs[techName] == true end,
	function() return UnitController.getSelectedBuildingIds() end)
BlobPanel.init(Network,
	function() return currentResources end,
	function(techName) return researchedTechs[techName] == true end,
	function() return UnitController.getSelectedBuildingIds() end)
LampreyNestPanel.init(Network,
	function() return currentResources end,
	function() return UnitController.getSelectedBuildingIds() end)
EngineeringPanel.init(Network)
CCMobilePanel.init(Network,
	function() return currentResources end,
	function(techName) return researchedTechs[techName] == true end)
MotherPanel.init(Network, function() return currentResources end)
LeechPanel.init(Network)
EmbryoPanel.init(Network)
EggPanel.init(Network, function() return currentResources end)
RollerPanel.init(Network)
NeedlerPanel.init(Network)
DeployerPanel.init(Network,
	function() return currentResources end,
	function() return UnitController.getSelectedBuildingIds() end)
-- TEST building: STRUCTURES tab reuses the CC build page, with a BACK slot wired to
-- return to the TEST menu; hide tears that build page back down.
TestPanel.init(Network,
	function() return currentResources end,
	function(backFn: () -> ())
		HUD.showBuildPage({
			{ name = "BACK", color = Color3.fromRGB(150, 160, 178), icon = "←",
			  desc = "Return to the TEST menu", onClick = backFn },
		})
	end,
	function() HUD.hideBuildPage() end)
SurvivorPanel.init(Network, function() return currentResources end)
MechLegs.init(workspace.CurrentCamera)
MotherLegs.init(workspace.CurrentCamera)
FogManager.init(localUserId)
MiniMap.init(CameraModule, localUserId)
ScoutManager.init(Network, CameraModule, FogManager, MiniMap)

-- ── Return-to-Command-Center button ───────────────────────────────────────────
-- The minimap button flies the camera back to our CC (default rotation + zoom).
-- It only appears after the camera first loses sight of the CC.
local function ownCCBase(): BasePart?
	if not ownCCId then return nil end
	local bf = workspace:FindFirstChild("Buildings") :: Folder?
	local model = bf and bf:FindFirstChild(ownCCId)
	return model and model:FindFirstChild("Base") :: BasePart? or nil
end

-- INJECT: the card hands the press to MotherInject, which runs the ground-targeting
-- mode and fires the request; the card flips to its "pick a spot" face while it's up.
-- It reads the Mother's base off ownCCBase to strike each queued mark as she reaches it,
-- which is why this wiring sits below that helper rather than up with the other panels.
MotherInject.init(Network, CameraModule, function(aiming: boolean)
	MotherPanel.setAiming(aiming)
end, ownCCBase, function() return currentResources end, function(preview: string?)
	-- The sight moved onto (or off) one of her plants: the tile's 3D face follows, so it
	-- shows what that plant would become instead of her own head.
	MotherPanel.setHover(preview)
end)
MotherPanel.onInject(function(ccId: string)
	MotherInject.begin(ccId)
end)

-- The quick-select bar above the minimap: one button per group the player owns (the
-- Mother, the egg clutch, the Leeches, the army). Tap takes the group, tap again flies
-- the camera to it. Its Mother slot is what the minimap's old [1] button became.
QuickSelect.init(UnitController, CameraModule)

-- ── /xray chat command ────────────────────────────────────────────────────────
do
	local xrayOn = false
	Players.LocalPlayer.Chatted:Connect(function(msg)
		if msg:lower():match("^%s*/xray%s*$") then
			xrayOn = not xrayOn
			FogManager.setXray(xrayOn)
		end
	end)
end

-- ── /shader chat command ──────────────────────────────────────────────────────
-- /shader 1  → enable Gloomy Atmosphere preset
-- /shader 2  → enable 60·30·10 cinematic tri-tone grade
-- /shader 0  → disable and restore original lighting
do
	Players.LocalPlayer.Chatted:Connect(function(msg)
		local arg = msg:match("^%s*/shader%s+(.+)$")
		if arg then ShaderManager.handleCommand(arg) end
	end)
end

-- ── /debug sound chat command ─────────────────────────────────────────────────
-- Toggles glowing neon markers at every ambient sound emitter so their spatial
-- distribution is visible in-world (crickets = dark blue).
do
	local soundDebugOn = false
	Players.LocalPlayer.Chatted:Connect(function(msg)
		if msg:lower():match("^%s*/debug%s+sound%s*$") then
			soundDebugOn = not soundDebugOn
			AmbientAudio.setDebugVisible(soundDebugOn)
		end
	end)
end

-- ── Deposit hover health bar ──────────────────────────────────────────────────
-- A single screen-space bar that follows the cursor when hovering near a crystal.
do
	local sg                       = Instance.new("ScreenGui")
	sg.Name                        = "DepositHoverUI"
	sg.IgnoreGuiInset              = true
	sg.ResetOnSpawn                = false
	sg.ZIndexBehavior              = Enum.ZIndexBehavior.Sibling
	sg.Parent                      = Players.LocalPlayer.PlayerGui

	local bar                      = Instance.new("Frame")
	bar.Name                       = "DepositHealthBar"
	bar.Size                       = UDim2.fromOffset(80, 5)
	bar.AnchorPoint                = Vector2.new(0.5, 1)
	bar.BackgroundColor3           = Color3.fromRGB(15, 15, 18)
	bar.BackgroundTransparency     = 0.22
	bar.BorderSizePixel            = 0
	bar.Visible                    = false
	bar.ZIndex                     = 25
	bar.Parent                     = sg
	local _bc                      = Instance.new("UICorner")
	_bc.CornerRadius               = UDim.new(1, 0)
	_bc.Parent                     = bar
	local _bs                      = Instance.new("UIStroke")
	_bs.Color                      = Color3.fromRGB(0, 0, 0)
	_bs.Thickness                  = 1
	_bs.Transparency               = 0.35
	_bs.Parent                     = bar

	local fill                     = Instance.new("Frame")
	fill.Name                      = "Fill"
	fill.Size                      = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3          = Color3.fromRGB(255, 215, 0)
	fill.BackgroundTransparency    = 0
	fill.BorderSizePixel           = 0
	fill.Parent                    = bar
	local _fc                      = Instance.new("UICorner")
	_fc.CornerRadius               = UDim.new(1, 0)
	_fc.Parent                     = fill

	PerfProbe.onRender("ClientFX", function()
		local mousePos  = UserInputService:GetMouseLocation()
		local cam       = workspace.CurrentCamera
		local depositsF = workspace:FindFirstChild("Deposits") :: Folder?

		local bestKey:  string?  = nil
		local bestDist           = 52      -- pixel proximity threshold
		local bestSV:   Vector3? = nil

		if depositsF then
			for k, res in depositClientRes do
				if res <= 0 then continue end
				local model = depositsF:FindFirstChild(k) :: Model?
				if not model then continue end
				local primary = model.PrimaryPart
				if not primary then continue end
				local sv, _on = cam:WorldToViewportPoint(primary.Position + Vector3.new(0, 6, 0))
				if sv.Z <= 0 then continue end
				local dx = sv.X - mousePos.X
				local dy = sv.Y - mousePos.Y
				local d  = math.sqrt(dx * dx + dy * dy)
				if d < bestDist then
					bestDist = d
					bestKey  = k
					bestSV   = sv
				end
			end
		end

		if bestKey and bestSV then
			local res  = depositClientRes[bestKey] or 0
			local frac = math.clamp(res / Config.DEPOSIT_TOTAL_RESOURCES, 0, 1)
			bar.Position              = UDim2.fromOffset((bestSV :: Vector3).X, (bestSV :: Vector3).Y - 14)
			fill.Size                 = UDim2.new(frac, 0, 1, 0)
			fill.BackgroundColor3     = Color3.fromRGB(255, math.floor(frac * 180), 0)
			bar.Visible               = true
		else
			bar.Visible = false
		end
	end)
end

-- ── Hide building panels when entering placement mode ─────────────────────────
-- Called by HUD when a build node is clicked, and also wired to the CC button.
-- Prevents open panels from intercepting placement clicks (they consume the click
-- through GPE = true, leaving isPlacing stuck until Escape / right-click).
local workshopBtnOpen = false  -- tracks whether the HUD upgrades button opened the workshop

local function hideBuildingPanels()
	workshopBtnOpen = false
	MinePanel.hide()
	WorkshopPanel.hide()
	TurretPanel.hide()
	BlobPanel.hide()
	LampreyNestPanel.hide()
	CCMobilePanel.hide()
	TestPanel.hide()
	MotherPanel.hide()
end

HUD.wire(Network, UnitController, BuildingPlacer, hideBuildingPanels, function()
	if not ownCCId then return end
	if workshopBtnOpen then
		workshopBtnOpen = false
		WorkshopPanel.hide()
	else
		workshopBtnOpen = true
		MinePanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		LampreyNestPanel.hide()
		CCMobilePanel.hide()
		WorkshopPanel.show(ownCCId)
	end
end)
HUD.setHasResearch(function(techName: string) return researchedTechs[techName] == true end)
ccBtn.MouseButton1Click:Connect(hideBuildingPanels)
if isLane then
	HUD.wireLane(function(unitType: string)
		Network.spawnLaneUnit(unitType)
	end)
end

-- ── Command Center build page (command-card grid) ─────────────────────────────
-- Build options live on the CC's command-card page, shown when the player selects
-- their CC. Humans also toggle it with [Space]; the Hollowed Mother's card is their
-- default card instead (see the fallback below), so it needs no key.
local ccPageId: string? = nil

local function showCCBuildPage(ccId: string?)
	if not ownCCId then return end
	ccPageId = ccId or ownCCId
	if isHollowedLocal() then
		-- Hollowed: the CC is the Mother, so show her single INJECT button instead of the
		-- Human build page.
		MotherPanel.show(ccPageId :: string)
	else
		HUD.showBuildPage()
	end
end

local function hideCCBuildPage()
	ccPageId = nil
	if isHollowedLocal() then
		MotherPanel.hide()
	else
		HUD.hideBuildPage()
	end
end

-- The Mother's card is the Hollowed player's resting state: whenever the command grid
-- falls empty (nothing selected), it fills back in with her INJECT button instead of
-- the "[Space] for menu" prompt. Humans keep the prompt and the [Space] toggle.
local function showDefaultCommandCard()
	if not ownCCId or not isHollowedLocal() then return end
	if #UnitController.getSelected() > 0 then return end
	if #UnitController.getSelectedBuildingIds() > 0 then return end
	MotherPanel.show(ownCCId :: string)
end
CommandCard.setFallback(showDefaultCommandCard)

-- [Space]: toggle the Human Command Center's build options on the command card.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.Space then return end
	if isHollowedLocal() then return end   -- the Mother's card is always up
	if HUD.isBuildPageShown() then
		hideCCBuildPage()
	else
		hideBuildingPanels()
		showCCBuildPage(ownCCId)
	end
end)

-- [F]: lamprey jumpscare — it lunges out of the dark and swallows the camera.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.F then Jumpscare.trigger() end
end)

-- [1] recenter the camera on the Command Center (the map's [1] button).
-- [1][1] in quick succession LOCKS the camera to it, so it trails the Mother as she
-- walks instead of needing to be chased. The lock releases the moment the player
-- steers for themselves — WASD, screen-edge scroll, rotate, middle-drag, or a
-- minimap click (which jumps focus and drops any follow).
-- While the build page is open the number row belongs to its build slots, so the
-- recenter stands down and lets HUD's [1] place the first building instead.
local HOME_DOUBLE_TAP = 0.4
local lastHomeTap     = 0
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.One then return end
	if CommandCard.isOwner("build") then return end
	local base = ownCCBase()
	if not base then return end
	local now = os.clock()
	if now - lastHomeTap <= HOME_DOUBLE_TAP then
		lastHomeTap = 0   -- consumed, so a third tap starts a fresh pair
		CameraModule.followPart(base, true)
	else
		lastHomeTap = now
		CameraModule.returnToBase(base.Position)
	end
end)

-- [R] INJECT: same action as the Mother card's tile, so the ground-targeting mode can
-- be armed without reaching for the card. Only while her card is the one on screen.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.R then return end
	if not MotherPanel.isVisible() then return end
	if MotherInject.isAiming() then return end
	MotherPanel.triggerInject()
end)

-- ── Command Center mode ───────────────────────────────────────────────────────

local function enterCCMode()
	BuildingPlacer.exitPlacementMode()
	BuildingPlacer.clearRelayPositions()
	clearMineData()
	destroyCCMoveGhost()
	ScoutManager.reset()
	ownCCId             = nil
	workshopBtnOpen     = false
	ccIsMobile          = false
	pendingPlace        = {}
	HUD.setPendingCounts({})
	CameraModule.stopFollow()
	ownedBuildingCounts = {}
	researchedTechs     = {}
	localKillCount      = 0
	localTrainCounts    = {}
	localBuildCounts    = {}
	refreshRequirements()
	updateIncomeReadout()
	HUD.setCommandCenterMode(true)
	MinePanel.hide()
	WorkshopPanel.hide()
	TurretPanel.hide()
	BlobPanel.hide()
	LampreyNestPanel.hide()
	CCMobilePanel.hide()
	MotherInject.cancel()
	MotherPanel.hide()
	LeechPanel.hide()
	EmbryoPanel.hide()
	EggPanel.hide()
	RollerPanel.hide()
	NeedlerPanel.hide()
	WorkshopPanel.resetMonument()
	WorkshopPanel.resetPlayer()
	HUD.setUpgradesVisible(false)
	placedFirstBonfire = false
	if winOverlay then winOverlay.Visible = false end
	monumentBuildingId = {}
	monumentBillboards = {}
end

Network.onNeedCommandCenter(function()
	enterCCMode()
end)

-- ── Return to the ready-up menu ─────────────────────────────────────────────────
-- Find one of the HUD's floating ScreenGuis by name (used to hide the top-right system
-- menu button while the lobby is up, since it renders above the lobby backdrop).
local function playerGuiScreen(name: string): ScreenGui?
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local g  = pg and pg:FindFirstChild(name)
	return (g and g:IsA("ScreenGui")) and g or nil
end

Network.onReturnToLobby(function()
	-- The server reset the match → drop everyone back onto the ready-up menu. The match
	-- systems from the first startGame keep running; readying up delivers a fresh base
	-- (which reveals the HUD + refocuses the camera) via the normal placement flow.
	if winOverlay then winOverlay.Visible = false end
	hideSurrenderVote()
	enterCCMode()                                   -- reset local match state
	local sm = playerGuiScreen("RTSSystemMenu")
	if sm then sm.Enabled = false end               -- hide the ☰ button behind the lobby
	LobbyUI.reopen(function()
		-- Resume into gameplay: restore the system menu button; the delivered base
		-- drives the rest through onOwnCCPlaced.
		local sm2 = playerGuiScreen("RTSSystemMenu")
		if sm2 then sm2.Enabled = true end
	end)
end)

-- A teammate wants to surrender + restart → show the yes/no vote popup.
Network.onSurrenderVote(function(requesterName: string)
	showSurrenderVote(requesterName)
end)

-- The pending vote was declined or cancelled → close the popup (message optional).
Network.onSurrenderCancel(function(message: string)
	hideSurrenderVote()
	if message and message ~= "" then
		HUD.showNotification(message, Color3.fromRGB(230, 180, 90))
	end
end)

-- Shared handling for "our Command Center is up": reveals the build/research tray
-- and focuses the camera. Called from the BuildingPlaced event AND from a polling
-- reconcile (below), since the event can fire during the lobby transition before
-- this handler is connected and the queued delivery isn't guaranteed.
local function onOwnCCPlaced(id: string, pos: Vector3)
	if ownCCId == id then return end
	ownCCId = id
	updateIncomeReadout()
	-- The Hollowed Mother spawns uprooted, and that CCMobileSync can land before this
	-- handler exists, so read the state off the model rather than trusting the event.
	do
		local bf    = workspace:FindFirstChild("Buildings")
		local model = bf and bf:FindFirstChild(id)
		local mv    = model and model:FindFirstChild("IsMobile") :: BoolValue?
		if mv and mv.Value then
			ccIsMobile = true
			BuildingPlacer.setCCMobile(true)
			buildCCMoveGhost()
			if isHollowedLocal() and model and model:IsA("Model") then
				MotherLegs.attach(id, model)
			end
		end
	end
	-- CC is up: reveal the build + research tray.
	HUD.setCommandCenterMode(false)
	Tutorial.notify("cc_placed")
	CameraModule.setFocus(pos)
	-- The game opens locked onto our Command Center, so a walking Hollowed Mother is
	-- trailed by default instead of having to be chased. Same lock as [1][1]: it
	-- releases the first time the player steers (WASD / QE / middle-drag / edge pan).
	-- The base is resolved off the model because the placement event can beat the
	-- model's replication, and setFocus's teleport hold keeps the camera from
	-- snapping early once the follow is set.
	task.spawn(function()
		local bf    = workspace:FindFirstChild("Buildings") or workspace:WaitForChild("Buildings", 10)
		local model = bf and bf:WaitForChild(id, 10)
		local base  = model and model:WaitForChild("Base", 5) :: BasePart?
		if base and ownCCId == id then
			CameraModule.followPart(base, true)
		end
	end)
	FogManager.forceRefresh()
	-- Hollowed: the Mother's card is the resting state of the command grid, so put it up
	-- the moment she exists rather than waiting for a selection to come and go.
	showDefaultCommandCard()
	-- Upgrades button stays hidden until the player places their first Barracks.
end

-- Recover a missed CommandCenter placement: scan the replicated workspace for our
-- own CC and run the same setup. Retries briefly while the model replicates.
task.spawn(function()
	local bf = workspace:WaitForChild("Buildings", 20) :: Folder?
	if not bf then return end
	local myStr   = tostring(localUserId)
	local deadline = os.clock() + 15
	while os.clock() < deadline and not ownCCId do
		for _, model in bf:GetChildren() do
			local ov  = model:FindFirstChild("OwnerId")      :: StringValue?
			local btv = model:FindFirstChild("BuildingType") :: StringValue?
			if ov and btv and btv.Value == "CommandCenter" and ov.Value == myStr then
				local base = model:FindFirstChild("Base") :: BasePart?
				onOwnCCPlaced(model.Name, base and base.Position or Vector3.zero)
				break
			end
		end
		if not ownCCId then task.wait(0.25) end
	end
end)

Network.onBuildingPlaced(function(id: string, ownerId: number, pos: Vector3, buildingType: string)
	if buildingType == "CommandCenter" and ownerId == localUserId then
		onOwnCCPlaced(id, pos)
	end

	if buildingType == "Monument" then
		monumentBuildingId[ownerId] = id
	end

	-- Track this player's non-CC buildings for the requirement system
	if ownerId == localUserId and buildingType ~= "CommandCenter" then
		ownedBuildingCounts[buildingType] = (ownedBuildingCounts[buildingType] or 0) + 1
		popPending(buildingType)   -- this placement landed; release its in-flight token
		refreshRequirements()
		updateIncomeReadout()
		if buildingType == "Foundry"  then Tutorial.notify("mine_placed")     end
		if buildingType == "Deployer" then
			Tutorial.notify("barracks_placed")
			-- First Bonfire unlocks the upgrades menu.
			if not placedFirstBonfire then
				placedFirstBonfire = true
				HUD.setUpgradesVisible(true)
			end
		end

		-- Decrement when the building is destroyed.
		task.spawn(function()
			local buildingsFolder = workspace:FindFirstChild("Buildings")
				or workspace:WaitForChild("Buildings", 10) :: Folder?
			if not buildingsFolder then return end
			local model = buildingsFolder:WaitForChild(id, 15)
			if not model then return end
			local base = model:WaitForChild("Base", 5) :: BasePart?
			if not base then return end
			local conn: RBXScriptConnection
			conn = base.Destroying:Connect(function()
				conn:Disconnect()
				ownedBuildingCounts[buildingType] =
					math.max(0, (ownedBuildingCounts[buildingType] or 1) - 1)
				refreshRequirements()
				updateIncomeReadout()
			end)
		end)
	end
end)

-- ── Unit command cards (Survivor upgrade + Hollowed units) ─────────────────────
-- Selecting owned units opens that unit's option grid: Survivor → Upgrade to Sniper;
-- Leech → Burrow/Unburrow; Embryo → evolve (once the Mother's Evolve unlock is bought,
-- else an empty grid). Any selection lacking a given type hides its panel (a building
-- selection clears the unit selection first, so this fires with an empty list then).
UnitController.onUnitsSelected(function(ids: { string })
	local survivorIds: { string } = {}
	local leechIds:    { string } = {}
	local embryoIds:   { string } = {}
	local rollerIds:   { string } = {}
	local needlerIds:  { string } = {}
	for _, id in ids do
		local t = UnitController.getUnitType(id)
		if     t == "Survivor" then table.insert(survivorIds, id)
		elseif t == "Leech"    then table.insert(leechIds, id)
		elseif t == "Embryo"   then table.insert(embryoIds, id)
		elseif t == "Roller"   then table.insert(rollerIds, id)
		elseif t == "Needler"  then table.insert(needlerIds, id)
		end
	end

	if #survivorIds > 0 then SurvivorPanel.show(survivorIds) else SurvivorPanel.hide() end
	if #leechIds    > 0 then LeechPanel.show(leechIds)       else LeechPanel.hide()    end
	if #embryoIds   > 0 then EmbryoPanel.show(embryoIds)     else EmbryoPanel.hide()   end
	if #rollerIds   > 0 then RollerPanel.show(rollerIds)     else RollerPanel.hide()   end
	if #needlerIds  > 0 then NeedlerPanel.show(needlerIds)   else NeedlerPanel.hide()  end
end)

-- ── Bonfire panel ──────────────────────────────────────────────────────────────
UnitController.onDeployerSelected(function(deployerId: string?)
	if deployerId then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		CCMobilePanel.hide()
		TestPanel.hide()
		DeployerPanel.show(deployerId)
	else
		DeployerPanel.hide()
	end
end)

-- ── TEST building panel ─────────────────────────────────────────────────────────
UnitController.onTestSelected(function(testId: string?)
	if testId then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		CCMobilePanel.hide()
		LampreyNestPanel.hide()
		EngineeringPanel.hide()
		DeployerPanel.hide()
		TestPanel.show(testId)
	else
		TestPanel.hide()
	end
end)

-- ── Mine panel ────────────────────────────────────────────────────────────────
UnitController.onMineSelected(function(mineId: string?)
	if mineId then
		DeployerPanel.hide()
		WorkshopPanel.hide()
		MinePanel.show(mineId)
	else
		MinePanel.hide()
	end
end)

-- ── Command Center mobility panel ─────────────────────────────────────────────
UnitController.onCCSelected(function(ccId: string?)
	ccSelectedId = ccId
	if ccId then
		MinePanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		LampreyNestPanel.hide()
		DeployerPanel.hide()
		WorkshopPanel.hide()
		-- Selecting the CC shows its build options on the command-card grid.
		showCCBuildPage(ccId)
		Tutorial.notify("cc_selected")
	else
		hideCCBuildPage()
	end
end)

-- ── Turret upgrade panel ──────────────────────────────────────────────────────
UnitController.onTurretSelected(function(turretId: string?)
	if turretId then
		MinePanel.hide()
		WorkshopPanel.hide()
		BlobPanel.hide()
		TurretPanel.show(turretId)
	else
		TurretPanel.hide()
	end
end)

-- ── Blob evolution panel ──────────────────────────────────────────────────────
UnitController.onBlobSelected(function(blobId: string?)
	if blobId then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.show(blobId)
	else
		BlobPanel.hide()
	end
end)

-- ── Lamprey Nest panel ─────────────────────────────────────────────────────────
local selectedNestId: string? = nil
local rallyMarker:    Part?   = nil

local function nestModel(nestId: string): Instance?
	local bf = workspace:FindFirstChild("Buildings") :: Folder?
	return bf and bf:FindFirstChild(nestId)
end

UnitController.onLampreyNestSelected(function(nestId: string?)
	selectedNestId = nestId
	if nestId then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		DeployerPanel.hide()
		CCMobilePanel.hide()
		EngineeringPanel.hide()
		LampreyNestPanel.show(nestId)
	else
		LampreyNestPanel.hide()
	end
end)

UnitController.onEngineeringSelected(function(postId: string?)
	if postId then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		DeployerPanel.hide()
		CCMobilePanel.hide()
		LampreyNestPanel.hide()
		EngineeringPanel.show(postId)
	else
		EngineeringPanel.hide()
	end
end)

-- ── Generic structure card ────────────────────────────────────────────────────
-- Selecting any owned building that has no dedicated panel still pops the command
-- card, with a friendly "upgrades coming soon" message.
local OTHER_STRUCT_NAME: { [string]: string } = {
	Relay = "RELAY", Monument = "MONUMENT",
}
UnitController.onOtherBuildingSelected(function(bid: string?, btype: string?)
	if bid then
		local name = (btype and (OTHER_STRUCT_NAME[btype] or btype) or "STRUCTURE"):upper()
		CommandCard.showMessage("other", name, "Upgrades coming soon!")
	else
		CommandCard.hide("other")
	end
end)

-- ── Wild plant card ───────────────────────────────────────────────────────────
-- The Mother's growths are scenery, not property, so clicking one has nothing to press:
-- it names the plant and says the one thing that can be done with it.
UnitController.onPlantSelected(function(plant: Model?)
	if plant then
		local info = InjectPlants.injectInfo(plant)
		CommandCard.showMessage("plant",
			((info and info.label) or "GROWTH"):upper(),
			"Can be injected to evolve")
	else
		CommandCard.hide("plant")
	end
end)

-- ── Egg-Sac egg panel ───────────────────────────────────────────────────────────
-- Clicking one of the Mother's eggs opens a 2×2 grid to choose which unit it hatches.
UnitController.onEggSelected(function(eggIds: { string }?)
	if eggIds and #eggIds > 0 then
		MinePanel.hide()
		WorkshopPanel.hide()
		TurretPanel.hide()
		BlobPanel.hide()
		DeployerPanel.hide()
		CCMobilePanel.hide()
		LampreyNestPanel.hide()
		EngineeringPanel.hide()
		EggPanel.show(eggIds)
	else
		EggPanel.hide()
	end
end)

Network.onEngineeringSync(function(buildingId: string, payload: any)
	EngineeringPanel.applySync(buildingId, payload)
end)

-- A flat ground disc showing where an upgraded nest will launch its eggs.
local function ensureRallyMarker(): Part
	if rallyMarker and rallyMarker.Parent then return rallyMarker end
	local p        = Instance.new("Part")
	p.Name         = "_NestRallyMarker"
	p.Shape        = Enum.PartType.Cylinder
	p.Size         = Vector3.new(0.4, 8, 8)   -- thin disc (cylinder axis = local X → laid flat)
	p.Color        = Color3.fromRGB(220, 150, 60)
	p.Material     = Enum.Material.Neon
	p.Transparency = 0.55
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CanTouch     = false
	p.CastShadow   = false
	p.Parent       = workspace
	rallyMarker    = p
	return p
end

-- Show/track the rally marker while an upgraded nest is selected; follows the
-- replicated RallyPoint attribute (so it reflects the server's clamped value).
PerfProbe.onRender("ClientFX", function()
	local show = selectedNestId ~= nil and LampreyNestPanel.nestHasRally(selectedNestId)
	if not show then
		if rallyMarker then rallyMarker.Parent = nil end
		return
	end
	local model = selectedNestId and nestModel(selectedNestId)
	local rp    = model and model:GetAttribute("RallyPoint")
	if typeof(rp) ~= "Vector3" then
		-- No rally set yet: park the marker on the nest itself.
		local base = model and model:FindFirstChild("Base") :: BasePart?
		rp = base and Vector3.new(base.Position.X, 0, base.Position.Z) or nil
	end
	if typeof(rp) == "Vector3" then
		local m  = ensureRallyMarker()
		local t  = tick() * 2
		m.Transparency = 0.5 + math.sin(t) * 0.12
		local ry = CameraModule.terrainHeightAt((rp :: Vector3).X, (rp :: Vector3).Z) + 0.2
		m.CFrame = CFrame.new((rp :: Vector3).X, ry, (rp :: Vector3).Z) * CFrame.Angles(0, 0, math.rad(90))
	end
end)

-- Right-click while a launcher-upgraded nest is selected: set the egg-launch rally
-- point on EVERY selected nest that has the upgrade. Each nest clamps the point to
-- its own range relative to its own position, so they all aim at the same spot.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	if not selectedNestId or not LampreyNestPanel.nestHasRally(selectedNestId) then return end
	local target = CameraModule.getGroundPosition()
	if not target then return end
	target = Vector3.new(target.X, 0, target.Z)

	local sent: { [string]: boolean } = {}
	for _, bid in UnitController.getSelectedBuildingIds() do
		if not sent[bid] and LampreyNestPanel.nestHasRally(bid) then
			sent[bid] = true
			Network.setNestRally(bid, target)
		end
	end
end)

-- ── Mobile CC sync ────────────────────────────────────────────────────────────
Network.onCCMobileSync(function(ccId: string, isUnlocked: boolean, isMobile: boolean)
	if ccId ~= ownCCId then return end
	ccIsMobile = isMobile
	CCMobilePanel.setMobileState(isUnlocked, isMobile)
	BuildingPlacer.setCCMobile(isMobile)
	if isMobile then
		buildCCMoveGhost()
		task.spawn(function()
			local bf = workspace:WaitForChild("Buildings", 10) :: Folder?
			if not bf then return end
			local model = bf:WaitForChild(ccId, 10) :: Model?
			if not model then return end
			-- The Mother walks on her own grown legs, so those get animated in place;
			-- the Human core sprouts a mechanical rig it doesn't otherwise have.
			if isHollowedLocal() then
				MotherLegs.attach(ccId, model)
			else
				local base = model:FindFirstChild("Base") :: BasePart?
				if base then MechLegs.attach(ccId, base) end
			end
		end)
	else
		destroyCCMoveGhost()
		MechLegs.detach(ccId)
		MotherLegs.detach(ccId)
	end
end)

-- Update CC move ghost position every frame. The ghost is the visible half of the move
-- order, so it follows the same rule: on screen only while the CC is selected.
PerfProbe.onRender("ClientFX", function()
	if not ccMoveGhost then return end
	local ghost = ccMoveGhost :: Model
	if not (ccIsMobile and ccSelectedId == ownCCId) then
		if ghost.Parent then ghost.Parent = nil end
		return
	end
	if not ghost.Parent then ghost.Parent = workspace end
	local halfH = Config.COMMAND_CENTER_SIZE.Y / 2
	local pos   = CameraModule.getPositionAtHeight(halfH)
	if pos then
		local G       = Config.BUILDING_GRID
		local snapped = Vector3.new(
			math.round(pos.X / G) * G,
			pos.Y,
			math.round(pos.Z / G) * G
		)
		ccMoveTarget = Vector3.new(snapped.X, 0, snapped.Z)
		ccMoveGhost:PivotTo(CFrame.new(snapped))
	end
end)

-- Right-click while the CC is SELECTED and mobile: issue a move-to command at the ghost's
-- snapped position. The selection check is what keeps her still: she is mobile nearly all
-- the time, so without it every right-click aimed at anything else was also an order to
-- get up and walk there.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	if not ccIsMobile or not ownCCId then return end
	if ccSelectedId ~= ownCCId then return end   -- not selected: this right-click is not hers
	if MotherInject.isAiming() then return end   -- that right-click called off the injection
	local target = ccMoveTarget or CameraModule.getGroundPosition()
	if target then
		MotherInject.clearQueue()   -- a hand-issued move calls off the queued injections
		Network.moveMobileCC(ownCCId, target)
		UnitController.playMotherVoice()
	end
end)

-- ── Mineral / income wiring ───────────────────────────────────────────────────

-- UnitsOrderedMove is fired by the server whenever any player issues a move
-- command (including AI bots).  Connect a no-op to prevent the event queue
-- from filling up with dropped messages.
Network.onUnitsOrderedMove(function(_ids: {string}, _targetPos: Vector3) end)

Network.onSyncDeposits(function(positions: {Vector3})
	BuildingPlacer.setDepositPositions(positions)
	-- Sync client-side deposit resource tracking for health bars
	local newKeys: { [string]: boolean } = {}
	for _, pos in positions do
		local k = posKeyC(pos)
		newKeys[k] = true
		if not depositClientRes[k] then
			depositClientRes[k] = Config.DEPOSIT_TOTAL_RESOURCES
		end
	end
	local toRemove: { string } = {}
	for k, _ in depositClientRes do
		if not newKeys[k] then table.insert(toRemove, k) end
	end
	for _, k in toRemove do depositClientRes[k] = nil end
end)

-- ── Tank Concussion Shells visual upgrade ────────────────────────────────────
-- Adds a glowing orange neon orb + two top-surface stripes to a tank body part.
-- Parts are unanchored + WeldConstrained so they follow the moving tank.
local function applyTankConcussionVisual(body: BasePart)
	-- Guard: don't add twice
	if body:FindFirstChild("_ConcussionOrb") then return end

	local halfY = body.Size.Y / 2

	local function weld(p: BasePart)
		local w   = Instance.new("WeldConstraint")
		w.Part0   = body
		w.Part1   = p
		w.Parent  = body
	end

	-- Glowing orb floating just above the top centre
	local orb        = Instance.new("Part")
	orb.Name         = "_ConcussionOrb"
	orb.Shape        = Enum.PartType.Ball
	orb.Size         = Vector3.new(1.6, 1.6, 1.6)
	orb.BrickColor   = BrickColor.new("Bright orange")
	orb.Material     = Enum.Material.Metal
	orb.Anchored     = false
	orb.CanCollide   = false
	orb.CanQuery     = false
	orb.CanTouch     = false
	orb.CastShadow   = false
	orb.CFrame       = body.CFrame * CFrame.new(0, halfY + 1.1, 0)
	orb.Parent       = body
	weld(orb)

	-- Two lengthwise neon stripes along the top edges
	for _, sideX in { -(body.Size.X / 2 - 0.6), (body.Size.X / 2 - 0.6) } do
		local stripe       = Instance.new("Part")
		stripe.Name        = "_ConcussionStripe"
		stripe.Size        = Vector3.new(0.55, 0.3, body.Size.Z + 0.5)
		stripe.BrickColor  = BrickColor.new("Bright orange")
		stripe.Material    = Enum.Material.Metal
		stripe.Anchored    = false
		stripe.CanCollide  = false
		stripe.CanQuery    = false
		stripe.CanTouch    = false
		stripe.CastShadow  = false
		stripe.CFrame      = body.CFrame * CFrame.new(sideX, halfY + 0.15, 0)
		stripe.Parent      = body
		weld(stripe)
	end
end

-- ── Trapper visual upgrade ────────────────────────────────────────────────────
-- Adds a harpoon rack on top of the tank and a BillboardGui with 5 white squares
-- showing the current harpoon count. The squares go dark as harpoons are consumed.
local function applyTrapperVisual(body: BasePart)
	if body:FindFirstChild("_HarpoonRack") then return end

	local halfY = body.Size.Y / 2

	local function weld(p: BasePart)
		local w   = Instance.new("WeldConstraint")
		w.Part0   = body
		w.Part1   = p
		w.Parent  = body
	end

	-- Rack base plate centered on top of the tank
	local rack         = Instance.new("Part")
	rack.Name          = "_HarpoonRack"
	rack.Size          = Vector3.new(4.8, 0.35, 1.8)
	rack.Color         = Color3.fromRGB(50, 52, 58)
	rack.Material      = Enum.Material.Metal
	rack.Anchored      = false
	rack.CanCollide    = false
	rack.CanQuery      = false
	rack.CanTouch      = false
	rack.CastShadow    = false
	rack.CFrame        = body.CFrame * CFrame.new(0, halfY + 0.18, 0)
	rack.Parent        = body
	weld(rack)

	-- Two side rails of the rack
	for _, sideZ in { -0.7, 0.7 } do
		local rail        = Instance.new("Part")
		rail.Name         = "_HarpoonRail"
		rail.Size         = Vector3.new(4.8, 0.3, 0.2)
		rail.Color        = Color3.fromRGB(80, 82, 90)
		rail.Material     = Enum.Material.Metal
		rail.Anchored     = false
		rail.CanCollide   = false
		rail.CanQuery     = false
		rail.CanTouch     = false
		rail.CastShadow   = false
		rail.CFrame       = body.CFrame * CFrame.new(0, halfY + 0.55, sideZ)
		rail.Parent       = body
		weld(rail)
	end

	-- 5 harpoon bolts resting in the rack (thin silver rods pointing forward)
	for i = 1, 5 do
		local xOff       = -1.8 + (i - 1) * 0.9
		local bolt       = Instance.new("Part")
		bolt.Name        = "_HarpoonBolt"
		bolt.Size        = Vector3.new(0.25, 0.25, 2.0)
		bolt.Color       = Color3.fromRGB(185, 188, 195)
		bolt.Material    = Enum.Material.Metal
		bolt.Anchored    = false
		bolt.CanCollide  = false
		bolt.CanQuery    = false
		bolt.CanTouch    = false
		bolt.CastShadow  = false
		bolt.CFrame      = body.CFrame * CFrame.new(xOff, halfY + 0.52, 0)
		bolt.Parent      = body
		weld(bolt)
	end

	-- BillboardGui: 5 small squares showing harpoon count (compact, 30% of original)
	local bb               = Instance.new("BillboardGui")
	bb.Name                = "_HarpoonCountBB"
	bb.Size                = UDim2.fromOffset(30, 6)
	bb.StudsOffset         = Vector3.new(0, body.Size.Y / 2 + 1.8, 0)
	bb.AlwaysOnTop         = false
	bb.MaxDistance         = 80
	bb.LightInfluence      = 0
	bb.Parent              = body

	local squares: { Frame } = {}
	for i = 1, 5 do
		local sq                   = Instance.new("Frame")
		sq.Name                    = "HarpoonSq" .. i
		sq.Size                    = UDim2.fromOffset(4, 4)
		sq.Position                = UDim2.fromOffset((i - 1) * 6, 1)
		sq.BackgroundColor3        = Color3.fromRGB(255, 255, 255)
		sq.BackgroundTransparency  = 0.08
		sq.BorderSizePixel         = 0
		sq.Parent                  = bb
		local corner               = Instance.new("UICorner")
		corner.CornerRadius        = UDim.new(0, 1)
		corner.Parent              = sq
		squares[i] = sq
	end

	local function updateSquares(count: number)
		for i = 1, 5 do
			if i <= count then
				squares[i].BackgroundColor3       = Color3.fromRGB(255, 255, 255)
				squares[i].BackgroundTransparency = 0.08
			else
				squares[i].BackgroundColor3       = Color3.fromRGB(55, 55, 60)
				squares[i].BackgroundTransparency = 0.35
			end
		end
	end

	local hv = body:FindFirstChild("HarpoonCount") :: NumberValue?
	if hv then
		updateSquares(hv.Value)
		hv.Changed:Connect(updateSquares)
	end
end

-- ── Survivor upgrade visuals ───────────────────────────────────────────────────
-- CombatStims: two small green cylinders on the back (stim injectors)
local function applySoldierStimVisual(body: BasePart)
	if body:FindFirstChild("_StimInjector") then return end
	local halfY = body.Size.Y / 2
	local halfZ = body.Size.Z / 2

	local function weld(p: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = body
		w.Part1 = p
		w.Parent = body
	end

	for _, sideX in { -0.8, 0.8 } do
		local inj           = Instance.new("Part")
		inj.Name            = "_StimInjector"
		inj.Shape           = Enum.PartType.Cylinder
		inj.Size            = Vector3.new(1.4, 0.45, 0.45)
		inj.BrickColor      = BrickColor.new("Bright green")
		inj.Material        = Enum.Material.Metal
		inj.Anchored        = false
		inj.CanCollide      = false
		inj.CanQuery        = false
		inj.CanTouch        = false
		inj.CastShadow      = false
		-- Position on the back-upper area, rotated so the cylinder stands upright
		inj.CFrame          = body.CFrame
			* CFrame.new(sideX, halfY - 0.5, halfZ - 0.25)
			* CFrame.Angles(0, 0, math.rad(90))
		inj.Parent          = body
		weld(inj)

		-- Green tip cap
		local cap           = Instance.new("Part")
		cap.Name            = "_StimCap"
		cap.Shape           = Enum.PartType.Ball
		cap.Size            = Vector3.new(0.5, 0.5, 0.5)
		cap.BrickColor      = BrickColor.new("Lime green")
		cap.Material        = Enum.Material.Neon
		cap.Anchored        = false
		cap.CanCollide      = false
		cap.CanQuery        = false
		cap.CanTouch        = false
		cap.CastShadow      = false
		cap.CFrame          = body.CFrame * CFrame.new(sideX, halfY + 0.25, halfZ - 0.25)
		cap.Parent          = body
		weld(cap)
	end
end

-- HardenedArmor: flat grey plate on the front face of the soldier
local function applySoldierArmorVisual(body: BasePart)
	if body:FindFirstChild("_ArmorPlate") then return end
	local halfY = body.Size.Y / 2
	local halfZ = body.Size.Z / 2

	local function weld(p: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = body
		w.Part1 = p
		w.Parent = body
	end

	-- Main chest plate
	local plate           = Instance.new("Part")
	plate.Name            = "_ArmorPlate"
	plate.Size            = Vector3.new(body.Size.X - 0.6, body.Size.Y * 0.55, 0.3)
	plate.BrickColor      = BrickColor.new("Medium stone grey")
	plate.Material        = Enum.Material.Metal
	plate.Anchored        = false
	plate.CanCollide      = false
	plate.CanQuery        = false
	plate.CanTouch        = false
	plate.CastShadow      = false
	plate.CFrame          = body.CFrame * CFrame.new(0, halfY * 0.1, -(halfZ + 0.15))
	plate.Parent          = body
	weld(plate)

	-- Rivet-strip accent across the top of the plate
	local strip           = Instance.new("Part")
	strip.Name            = "_ArmorStrip"
	strip.Size            = Vector3.new(body.Size.X - 0.6, 0.25, 0.32)
	strip.BrickColor      = BrickColor.new("Dark stone grey")
	strip.Material        = Enum.Material.Metal
	strip.Anchored        = false
	strip.CanCollide      = false
	strip.CanQuery        = false
	strip.CanTouch        = false
	strip.CastShadow      = false
	strip.CFrame          = body.CFrame * CFrame.new(0, halfY * 0.1 + plate.Size.Y / 2 - 0.12, -(halfZ + 0.16))
	strip.Parent          = body
	weld(strip)
end

-- ── Spider legs for Elite units ───────────────────────────────────────────────

Network.onUnitSpawned(function(unitId: string, _ownerId: number, _pos: Vector3)
	if _ownerId == localUserId then Tutorial.notify("unit_trained") end
	task.spawn(function()
		local unitsFolder = workspace:WaitForChild("Units", 10) :: Folder?
		if not unitsFolder then return end
		local part = unitsFolder:WaitForChild(unitId, 10) :: BasePart?
		if not part then return end
		local tv = part:FindFirstChild("UnitType") :: StringValue?
		if tv and tv.Value == "Elite" then
			SpiderLegs.attach(unitId, part)
		elseif tv and tv.Value == "CreepySoldier" then
			CreepyLegs.attach(unitId, part)
		elseif tv and tv.Value == "Howitzer" then
			WalkerLegs.attach(unitId, part)
		elseif tv and tv.Value == "Lamprey" then
			LampreyBody.attach(unitId, part)
		elseif tv and tv.Value == "Hagfish" then
			HagfishBody.attach(unitId, part)
		elseif tv and tv.Value == "Broodmother" then
			BroodmotherBody.attach(unitId, part)
		elseif tv and tv.Value == "Leech" then
			LeechBody.attach(unitId, part)
		elseif tv and tv.Value == "Roller" then
			RollerBody.attach(unitId, part)
		elseif tv and tv.Value == "Watcher" then
			WatcherBody.attach(unitId, part)
		elseif tv and tv.Value == "Needler" then
			NeedlerBody.attach(unitId, part)
		end
		-- Apply upgrade visuals if already researched
		if _ownerId == localUserId then
			local p = part :: BasePart
			if tv and tv.Value == "Tank" and researchedTechs["ConcussionShells"] then
				applyTankConcussionVisual(p)
			end
			if tv and tv.Value == "Tank" and researchedTechs["Trapper"] then
				applyTrapperVisual(p)
			end
			if tv and tv.Value == "Survivor" then
				if researchedTechs["CombatStims"]   then applySoldierStimVisual(p)  end
				if researchedTechs["HardenedArmor"] then applySoldierArmorVisual(p) end
			end
		end
	end)
end)

Network.onResourceSync(function(amount: number)
	-- A drop in the balance means the server just charged for a purchase (the only path
	-- that lowers resources is a successful spend) — chime the shared purchase-confirm
	-- cue. Skip the match-start / play-again reset, which snaps back to whichever race's
	-- opening wallet this player has (both are checked; the race isn't tracked here).
	if amount < currentResources
		and amount ~= Config.STARTING_RESOURCES
		and amount ~= Config.STARTING_RESOURCES_HUMANS then
		HUD.playSuccessSound()
	end
	currentResources = amount
	-- Re-render every command-card page whose tiles/tooltip depend on affordability,
	-- so purchasable/insufficient states update live (not only on next interaction).
	MinePanel.refreshIfVisible()
	BlobPanel.refreshIfVisible()
	CCMobilePanel.refreshIfVisible()
	TurretPanel.refreshIfVisible()
	LampreyNestPanel.refreshIfVisible()
	DeployerPanel.refreshIfVisible()
	TestPanel.refreshIfVisible()
	SurvivorPanel.refreshIfVisible()
	EggPanel.refreshIfVisible()
	MotherPanel.refreshIfVisible()
	LeechPanel.refreshIfVisible()
end)

-- Floating "+N" income popup over your own Foundry each income tick.
Network.onFoundryIncome(function(foundryId: string, income: number)
	if income <= 0 then return end
	local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
	if not buildingsF then return end
	local model = buildingsF:FindFirstChild(foundryId) :: Instance?
	if not model then return end
	local anchor = model:FindFirstChild("Base") :: BasePart?
	if not anchor then return end

	local xOff               = (math.random() - 0.5) * 6
	local bb                 = Instance.new("BillboardGui")
	bb.Name                  = "_FoundryIncome"
	bb.Size                  = UDim2.fromOffset(70, 22)
	bb.StudsOffset           = Vector3.new(xOff, anchor.Size.Y / 2 + 4, 0)
	bb.AlwaysOnTop           = true
	bb.MaxDistance           = 220
	bb.Parent                = anchor

	local lbl                  = Instance.new("TextLabel")
	lbl.Size                   = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font                   = Enum.Font.GothamBold
	lbl.TextSize               = 16
	lbl.TextColor3             = Color3.fromRGB(120, 255, 140)
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3       = Color3.new(0, 0, 0)
	lbl.Text                   = "+" .. income
	lbl.Parent                 = bb

	local e = 0
	local lc: RBXScriptConnection
	lc = PerfProbe.onRender("ClientFX", function(idt)
		e += idt
		if bb.Parent then
			local t = math.min(e / 1.3, 1)
			bb.StudsOffset       = Vector3.new(xOff, anchor.Size.Y / 2 + 4 + t * 6, 0)
			lbl.TextTransparency = math.clamp((t - 0.4) / 0.6, 0, 1)
		end
		if e >= 1.3 then lc:Disconnect(); if bb.Parent then bb:Destroy() end end
	end)
end)

-- ── Unlock events ─────────────────────────────────────────────────────────────

local function applyUnlockVisuals(techName: string)
	if techName == "ConcussionShells" or techName == "CombatStims"
		or techName == "HardenedArmor" or techName == "Trapper" then
		local unitsFolder = workspace:FindFirstChild("Units") :: Folder?
		if unitsFolder then
			for _, child in unitsFolder:GetChildren() do
				if not child:IsA("BasePart") then continue end
				local ov = child:FindFirstChild("OwnerId") :: StringValue?
				if not ov or ov.Value ~= tostring(localUserId) then continue end
				local tv = child:FindFirstChild("UnitType") :: StringValue?
				if not tv then continue end
				if tv.Value == "Tank" and techName == "ConcussionShells" then
					applyTankConcussionVisual(child :: BasePart)
				elseif tv.Value == "Tank" and techName == "Trapper" then
					applyTrapperVisual(child :: BasePart)
				elseif tv.Value == "Survivor" then
					if techName == "CombatStims"   then applySoldierStimVisual(child :: BasePart)  end
					if techName == "HardenedArmor" then applySoldierArmorVisual(child :: BasePart) end
				end
			end
		end
	end
end

Network.onCondProgressSync(function(stats: any)
	localKillCount   = stats.kills   or 0
	localBuildCounts = stats.builds  or {}
	localTrainCounts = stats.trained or {}
	WorkshopPanel.refreshIfVisible()
	WorkshopPanel.runAutoUpgrade()  -- newly-met requirements may auto-start
end)

Network.onUnlockGranted(function(techName: string)
	local isFirst = not next(researchedTechs)
	researchedTechs[techName] = true
	if isFirst then HUD.setUpgradesVisible(true) end
	WorkshopPanel.refreshIfVisible()
	MinePanel.refreshIfVisible()
	DeployerPanel.refreshIfVisible()
	TestPanel.refreshIfVisible()
	TurretPanel.refreshIfVisible()
	BlobPanel.refreshIfVisible()
	CCMobilePanel.refreshIfVisible()
	HUD.refreshTrayState(ownedBuildingCounts)
	applyUnlockVisuals(techName)
	UnlockNotification.showUnlock(techName)
	WorkshopPanel.runAutoUpgrade()  -- a slot freed / a prereq unlocked
end)

Network.onUnlockChoice(function(group: string, options: {string})
	UnlockNotification.showChoice(group, options, function(chosen: string)
		Network.sendUnlockChoose(chosen)
		-- Optimistically mark it; server will also send UnlockGranted
		researchedTechs[chosen] = true
	end)
end)

-- A research timer has begun on the server (techName, server-clock end time)
Network.onUpgradeStarted(function(techName: string, endTime: number)
	WorkshopPanel.onUpgradeStarted(techName, endTime)
end)

-- ── Monument & win condition ──────────────────────────────────────────────────

-- ── Toast notification helper ─────────────────────────────────────────────────
local function showNotification(text: string, color: Color3?)
	local sg      = Players.LocalPlayer.PlayerGui:WaitForChild("RTSHUD") :: ScreenGui
	HUD.playNotificationSound()
	local lbl     = Instance.new("TextLabel")
	lbl.Size      = UDim2.fromOffset(460, 44)
	lbl.Position  = UDim2.new(0.5, -230, 0, 72)
	lbl.BackgroundColor3 = Color3.fromRGB(8, 12, 26)
	lbl.BackgroundTransparency = 0.08
	lbl.BorderSizePixel = 0
	lbl.Font      = Enum.Font.GothamBold
	lbl.TextSize  = 16
	lbl.TextColor3 = color or Color3.fromRGB(255, 215, 0)
	lbl.Text      = text
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.ZIndex    = 50
	lbl.Parent    = sg
	local stroke  = Instance.new("UIStroke"); stroke.Color = color or Color3.fromRGB(255, 215, 0)
	stroke.Thickness = 1; stroke.Parent = lbl
	local corner  = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = lbl
	task.delay(4.5, function()
		for i = 1, 15 do
			task.wait(0.05)
			lbl.BackgroundTransparency = 0.08 + i / 15 * 0.92
			lbl.TextTransparency       = i / 15
		end
		lbl:Destroy()
	end)
end

-- ── Monument timer billboard ──────────────────────────────────────────────────
local function getOrCreateMonumentBillboard(ownerUserId: number): BillboardGui?
	if monumentBillboards[ownerUserId] and monumentBillboards[ownerUserId].Parent then
		return monumentBillboards[ownerUserId]
	end
	local bid = monumentBuildingId[ownerUserId]
	if not bid then return nil end
	local buildingsF = workspace:FindFirstChild("Buildings") :: Folder?
	if not buildingsF then return nil end
	local model = buildingsF:FindFirstChild(bid)
	if not model then return nil end
	local base = model:FindFirstChild("Base") :: BasePart?
	if not base then return nil end

	local bb             = Instance.new("BillboardGui")
	bb.Name              = "MonumentTimer"
	bb.Size              = UDim2.fromOffset(160, 26)
	bb.StudsOffset       = Vector3.new(0, 16, 0)
	bb.MaxDistance       = 600
	bb.AlwaysOnTop       = false
	bb.Parent            = base

	local bg             = Instance.new("Frame")
	bg.Size              = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3  = Color3.fromRGB(8, 12, 26)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel   = 0
	bg.Parent            = bb
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = bg

	local lbl            = Instance.new("TextLabel")
	lbl.Name             = "TimerLabel"
	lbl.Size             = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font             = Enum.Font.GothamBold
	lbl.TextSize         = 13
	lbl.TextColor3       = Color3.fromRGB(255, 215, 0)
	lbl.Text             = "Monument Rising..."
	lbl.Parent           = bb

	monumentBillboards[ownerUserId] = bb
	return bb
end

local function updateMonumentBillboard(ownerUserId: number, timeRemaining: number?)
	local bb  = getOrCreateMonumentBillboard(ownerUserId)
	if not bb then return end
	local lbl = bb:FindFirstChild("TimerLabel") :: TextLabel?
	if not lbl then return end

	if timeRemaining == nil or timeRemaining == -1 then
		lbl.Text = "Monument Rising..."
	else
		local mins = math.floor(timeRemaining / 60)
		local secs = math.floor(timeRemaining % 60)
		local player = Players:GetPlayerByUserId(ownerUserId)
		local name   = player and player.DisplayName or "???"
		lbl.Text     = string.format("%s  —  Win in %d:%02d", name, mins, secs)
	end
end

Network.onMonumentProgress(function(ownerUserId: number, timeRemaining: number?)
	-- Update local player's workshop panel
	if ownerUserId == localUserId then
		WorkshopPanel.onMonumentProgress(timeRemaining)
	end

	-- Update floating timer billboard
	if timeRemaining == nil then
		-- Monument destroyed — clear stale refs (the model/billboard is already gone)
		monumentBillboards[ownerUserId] = nil
		monumentBuildingId[ownerUserId] = nil

		if ownerUserId ~= localUserId then
			local p    = Players:GetPlayerByUserId(ownerUserId)
			local name = p and p.Name or "Enemy"
			showNotification(name .. "'s Monument was destroyed!", Color3.fromRGB(50, 200, 80))
		end
	elseif timeRemaining == -1 then
		-- Construction just started
		updateMonumentBillboard(ownerUserId, -1)

		local p    = Players:GetPlayerByUserId(ownerUserId)
		local name = p and p.Name or "Someone"
		if ownerUserId == localUserId then
			showNotification("Your Monument is rising! Defend it for 5 minutes to win!")
		else
			showNotification(name .. " is building a Monument! Destroy it to stop them!", Color3.fromRGB(255, 80, 60))
		end
	else
		-- Countdown tick
		updateMonumentBillboard(ownerUserId, timeRemaining)
	end
end)

-- End screen overlay
-- Lives in its OWN ScreenGui (not RTSHUD): the shared HUD carries a 2× cluster UIScale
-- meant for the small bottom cluster, which would inflate this full-screen modal to
-- ~2× its design size and overflow small displays. Here the card is authored at a fixed
-- DESIGN size and a single UIScale shrinks it to fit any viewport (never enlarging past
-- design), so it reads the same, centered and fully on-screen, across every device.
local END_CARD_W, END_CARD_H = 600, 748
do
	local sg               = Instance.new("ScreenGui")
	sg.Name                = "RTSEndScreen"
	sg.ResetOnSpawn        = false
	sg.IgnoreGuiInset      = true
	sg.DisplayOrder        = 250
	sg.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
	sg.Parent              = Players.LocalPlayer.PlayerGui

	local overlay = Instance.new("Frame")
	overlay.Name                   = "EndScreen"
	overlay.Size                   = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.45
	overlay.ZIndex                 = 100
	overlay.Visible                = false
	overlay.Parent                 = sg
	winOverlay = overlay

	local card = Instance.new("Frame")
	card.Name                   = "Card"
	card.Size                   = UDim2.fromOffset(END_CARD_W, END_CARD_H)
	card.AnchorPoint            = Vector2.new(0.5, 0.5)
	card.Position               = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3       = Color3.fromRGB(16, 18, 26)
	card.BorderSizePixel        = 0
	card.ZIndex                 = 101
	card.Parent                 = overlay
	local cardCorner            = Instance.new("UICorner")
	cardCorner.CornerRadius     = UDim.new(0, 10)
	cardCorner.Parent           = card

	-- Responsive fit: uniformly scale the whole card down to fit the viewport (with a
	-- small margin), never scaling above 1× so it stays crisp at design size on big
	-- screens. Keeps the fixed internal pixel layout intact while fitting every device.
	local cardScale             = Instance.new("UIScale")
	cardScale.Parent            = card
	local function fitEndCard()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		cardScale.Scale = math.min(1, vp.X * 0.94 / END_CARD_W, vp.Y * 0.94 / END_CARD_H)
	end
	fitEndCard()
	local function hookViewport(cam: Camera)
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitEndCard)
		fitEndCard()
	end
	if workspace.CurrentCamera then hookViewport(workspace.CurrentCamera) end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then hookViewport(workspace.CurrentCamera) end
	end)

	local topBar                = Instance.new("Frame")
	topBar.Name                 = "TopBar"
	topBar.Size                 = UDim2.new(1, 0, 0, 6)
	topBar.BackgroundColor3     = Color3.fromRGB(255, 215, 0)
	topBar.BorderSizePixel      = 0
	topBar.ZIndex               = 102
	topBar.Parent               = card
	local topCorner             = Instance.new("UICorner")
	topCorner.CornerRadius      = UDim.new(0, 10)
	topCorner.Parent            = topBar

	local heading               = Instance.new("TextLabel")
	heading.Name                = "Heading"
	heading.Size                = UDim2.new(1, 0, 0, 76)
	heading.Position            = UDim2.new(0, 0, 0, 12)
	heading.BackgroundTransparency = 1
	heading.Font                = Enum.Font.GothamBold
	heading.TextSize            = 64
	heading.Text                = "VICTORY!"
	heading.TextColor3          = Color3.fromRGB(255, 215, 0)
	heading.ZIndex              = 102
	heading.Parent              = card

	local sub                   = Instance.new("TextLabel")
	sub.Name                    = "Sub"
	sub.Size                    = UDim2.new(1, -60, 0, 26)
	sub.Position                = UDim2.new(0, 30, 0, 94)
	sub.BackgroundTransparency  = 1
	sub.Font                    = Enum.Font.Gotham
	sub.TextSize                = 16
	sub.Text                    = ""
	sub.TextColor3              = Color3.fromRGB(165, 180, 210)
	sub.ZIndex                  = 102
	sub.Parent                  = card

	-- Player avatar cards (populated dynamically in handler)
	local playersSection        = Instance.new("Frame")
	playersSection.Name         = "PlayersSection"
	playersSection.Size         = UDim2.new(1, -60, 0, 120)
	playersSection.Position     = UDim2.new(0, 30, 0, 130)
	playersSection.BackgroundTransparency = 1
	playersSection.ZIndex       = 102
	playersSection.Parent       = card

	local div1                  = Instance.new("Frame")
	div1.Name                   = "Div1"
	div1.Size                   = UDim2.new(1, -60, 0, 1)
	div1.Position               = UDim2.new(0, 30, 0, 260)
	div1.BackgroundColor3       = Color3.fromRGB(55, 62, 80)
	div1.BorderSizePixel        = 0
	div1.ZIndex                 = 102
	div1.Parent                 = card

	local statDefs = {
		{ id = "Kills",     label = "Enemy Units Destroyed" },
		{ id = "Trained",   label = "Units Trained"         },
		{ id = "Builds",    label = "Buildings Constructed" },
		{ id = "Resources", label = "Resources Gathered"    },
	}
	for i, def in statDefs do
		local row               = Instance.new("Frame")
		row.Name                = def.id .. "Row"
		row.Size                = UDim2.new(1, -60, 0, 34)
		row.Position            = UDim2.new(0, 30, 0, 270 + (i - 1) * 38)
		row.BackgroundTransparency = 1
		row.ZIndex              = 102
		row.Parent              = card

		local lbl               = Instance.new("TextLabel")
		lbl.Size                = UDim2.new(0.72, 0, 1, 0)
		lbl.BackgroundTransparency = 1
		lbl.Font                = Enum.Font.Gotham
		lbl.TextSize            = 16
		lbl.Text                = def.label
		lbl.TextColor3          = Color3.fromRGB(130, 145, 170)
		lbl.TextXAlignment      = Enum.TextXAlignment.Left
		lbl.ZIndex              = 103
		lbl.Parent              = row

		local val               = Instance.new("TextLabel")
		val.Name                = def.id .. "Value"
		val.Size                = UDim2.new(0.28, 0, 1, 0)
		val.Position            = UDim2.new(0.72, 0, 0, 0)
		val.BackgroundTransparency = 1
		val.Font                = Enum.Font.GothamBold
		val.TextSize            = 20
		val.Text                = "0"
		val.TextColor3          = Color3.fromRGB(235, 240, 255)
		val.TextXAlignment      = Enum.TextXAlignment.Right
		val.ZIndex              = 103
		val.Parent              = row
	end

	-- ── Performance graph (per-commander metric over match time; renderEndCard
	-- fills in the title and adds the metric tabs on this same line) ────────────
	local graphTitle            = Instance.new("TextLabel")
	graphTitle.Name             = "GraphTitle"
	graphTitle.Size             = UDim2.new(1, -60, 0, 18)
	graphTitle.Position         = UDim2.new(0, 30, 0, 436)
	graphTitle.BackgroundTransparency = 1
	graphTitle.Font             = Enum.Font.GothamBold
	graphTitle.TextSize         = 14
	graphTitle.Text             = "UNITS DESTROYED OVER TIME"
	graphTitle.TextColor3       = Color3.fromRGB(150, 165, 195)
	graphTitle.TextXAlignment   = Enum.TextXAlignment.Left
	graphTitle.ZIndex           = 102
	graphTitle.Parent           = card

	local graphFrame            = Instance.new("Frame")
	graphFrame.Name             = "GraphSection"
	graphFrame.Size             = UDim2.new(1, -60, 0, 150)
	graphFrame.Position         = UDim2.new(0, 30, 0, 458)
	graphFrame.BackgroundColor3 = Color3.fromRGB(11, 13, 20)
	graphFrame.BackgroundTransparency = 0.25
	graphFrame.BorderSizePixel  = 0
	graphFrame.ZIndex           = 102
	graphFrame.Parent           = card
	local gfCorner              = Instance.new("UICorner")
	gfCorner.CornerRadius       = UDim.new(0, 8)
	gfCorner.Parent             = graphFrame

	local div2                  = Instance.new("Frame")
	div2.Name                   = "Div2"
	div2.Size                   = UDim2.new(1, -60, 0, 1)
	div2.Position               = UDim2.new(0, 30, 0, 626)
	div2.BackgroundColor3       = Color3.fromRGB(55, 62, 80)
	div2.BorderSizePixel        = 0
	div2.ZIndex                 = 102
	div2.Parent                 = card

	local durationLbl           = Instance.new("TextLabel")
	durationLbl.Name            = "DurationLabel"
	durationLbl.Size            = UDim2.new(1, -60, 0, 22)
	durationLbl.Position        = UDim2.new(0, 30, 0, 636)
	durationLbl.BackgroundTransparency = 1
	durationLbl.Font            = Enum.Font.Gotham
	durationLbl.TextSize        = 14
	durationLbl.Text            = "Match duration: --"
	durationLbl.TextColor3      = Color3.fromRGB(100, 115, 140)
	durationLbl.TextXAlignment  = Enum.TextXAlignment.Left
	durationLbl.ZIndex          = 102
	durationLbl.Parent          = card

	-- Small status hint above the buttons (e.g. "Waiting for other players…" while a
	-- multiplayer surrender vote is out). Not a countdown — the screen waits for a click.
	local returnLbl             = Instance.new("TextLabel")
	returnLbl.Name              = "ReturnLabel"
	returnLbl.Size              = UDim2.new(1, -60, 0, 18)
	returnLbl.Position          = UDim2.new(0, 30, 0, 660)
	returnLbl.BackgroundTransparency = 1
	returnLbl.Font              = Enum.Font.Gotham
	returnLbl.TextSize          = 14
	returnLbl.Text              = ""
	returnLbl.TextColor3        = Color3.fromRGB(150, 165, 195)
	returnLbl.TextXAlignment    = Enum.TextXAlignment.Left
	returnLbl.ZIndex            = 102
	returnLbl.Parent            = card

	-- PLAY AGAIN — shown only on the mid-match defeat screen (respawns the player's base
	-- into the still-running match). Takes the left half when both buttons show.
	local playAgainBtn          = Instance.new("TextButton")
	playAgainBtn.Name           = "PlayAgainBtn"
	playAgainBtn.Size           = UDim2.new(0.5, -36, 0, 46)
	playAgainBtn.Position       = UDim2.new(0, 30, 0, 686)
	playAgainBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 70)
	playAgainBtn.BorderSizePixel  = 0
	playAgainBtn.AutoButtonColor  = true
	playAgainBtn.Font           = Enum.Font.GothamBold
	playAgainBtn.TextSize       = 18
	playAgainBtn.TextColor3     = Color3.fromRGB(235, 255, 240)
	playAgainBtn.Text           = "PLAY AGAIN"
	playAgainBtn.ZIndex         = 103
	playAgainBtn.Visible        = false
	playAgainBtn.Parent         = card
	local _pac = Instance.new("UICorner"); _pac.CornerRadius = UDim.new(0, 8); _pac.Parent = playAgainBtn
	playAgainBtn.MouseButton1Click:Connect(function()
		if winOverlay then winOverlay.Visible = false end
		Network.playAgain()
	end)

	-- RETURN TO MENU — always shown; sends the player back to the ready-up menu. On the
	-- endgame screen the match is already decided, so this resets straight away; from a
	-- mid-match defeat (with PLAY AGAIN alongside) it routes through the surrender flow.
	local returnBtn             = Instance.new("TextButton")
	returnBtn.Name              = "ReturnBtn"
	returnBtn.Size              = UDim2.new(1, -60, 0, 46)
	returnBtn.Position          = UDim2.new(0, 30, 0, 686)
	returnBtn.BackgroundColor3  = Color3.fromRGB(60, 74, 104)
	returnBtn.BorderSizePixel   = 0
	returnBtn.AutoButtonColor   = true
	returnBtn.Font              = Enum.Font.GothamBold
	returnBtn.TextSize          = 18
	returnBtn.TextColor3        = Color3.fromRGB(226, 234, 248)
	returnBtn.Text              = "RETURN TO MENU"
	returnBtn.ZIndex            = 103
	returnBtn.Visible           = false
	returnBtn.Parent            = card
	local _rbc = Instance.new("UICorner"); _rbc.CornerRadius = UDim.new(0, 8); _rbc.Parent = returnBtn
	returnBtn.MouseButton1Click:Connect(function()
		returnBtn.Active = false
		returnLbl.Text = "Returning to the ready-up menu…"
		Network.leaveToLobby()
	end)

	-- Tick sound played during stat counter animations
	local tickSnd               = Instance.new("Sound")
	tickSnd.Name                = "TickSound"
	tickSnd.SoundId             = "rbxassetid://9119739203"
	tickSnd.Volume              = 0.25
	tickSnd.RollOffMaxDistance  = 0
	tickSnd.Parent              = card
end

-- ── Surrender / restart vote popup (multiplayer) ────────────────────────────────
-- Shown on the OTHER players' screens when someone asks to return to the ready-up menu
-- mid-match: "<name> wants to surrender and restart the match." with YES / NO. In its
-- own ScreenGui with a fit-to-viewport UIScale, so it reads the same on every device.
do
	local VOTE_W, VOTE_H = 420, 200
	local sg               = Instance.new("ScreenGui")
	sg.Name                = "RTSSurrenderVote"
	sg.ResetOnSpawn        = false
	sg.IgnoreGuiInset      = true
	sg.DisplayOrder        = 260
	sg.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
	sg.Parent              = Players.LocalPlayer.PlayerGui

	local overlay = Instance.new("Frame")
	overlay.Size                   = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.Active                 = true    -- absorb clicks behind the popup
	overlay.ZIndex                 = 100
	overlay.Visible                = false
	overlay.Parent                 = sg

	local card = Instance.new("Frame")
	card.Size                   = UDim2.fromOffset(VOTE_W, VOTE_H)
	card.AnchorPoint            = Vector2.new(0.5, 0.5)
	card.Position               = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3       = Color3.fromRGB(16, 18, 26)
	card.BorderSizePixel        = 0
	card.ZIndex                 = 101
	card.Parent                 = overlay
	local vc = Instance.new("UICorner"); vc.CornerRadius = UDim.new(0, 10); vc.Parent = card
	local vst = Instance.new("UIStroke"); vst.Color = Color3.fromRGB(90, 108, 140); vst.Thickness = 1; vst.Parent = card

	local vScale = Instance.new("UIScale"); vScale.Parent = card
	local function fitVote()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X == 0 or vp.Y == 0 then return end
		vScale.Scale = math.min(1, vp.X * 0.9 / VOTE_W, vp.Y * 0.9 / VOTE_H)
	end
	fitVote()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitVote)
	end

	local topBar = Instance.new("Frame")
	topBar.Size = UDim2.new(1, 0, 0, 6); topBar.BackgroundColor3 = Color3.fromRGB(230, 180, 90)
	topBar.BorderSizePixel = 0; topBar.ZIndex = 102; topBar.Parent = card
	local tbc = Instance.new("UICorner"); tbc.CornerRadius = UDim.new(0, 10); tbc.Parent = topBar

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.new(1, -32, 0, 30); heading.Position = UDim2.new(0, 16, 0, 22)
	heading.BackgroundTransparency = 1; heading.Font = Enum.Font.GothamBold; heading.TextSize = 20
	heading.Text = "SURRENDER & RESTART?"; heading.TextColor3 = Color3.fromRGB(240, 210, 150)
	heading.ZIndex = 102; heading.Parent = card

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.Size = UDim2.new(1, -32, 0, 44); body.Position = UDim2.new(0, 16, 0, 58)
	body.BackgroundTransparency = 1; body.Font = Enum.Font.Gotham; body.TextSize = 15
	body.TextWrapped = true; body.Text = ""; body.TextColor3 = Color3.fromRGB(200, 210, 228)
	body.ZIndex = 102; body.Parent = card

	local function voteButton(text: string, x: number, col: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -24, 0, 46); b.Position = UDim2.new(x, x == 0 and 16 or 8, 1, -62)
		b.BackgroundColor3 = col; b.BorderSizePixel = 0; b.AutoButtonColor = true
		b.Font = Enum.Font.GothamBold; b.TextSize = 18; b.TextColor3 = Color3.fromRGB(240, 246, 255)
		b.Text = text; b.ZIndex = 103; b.Parent = card
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = b
		return b
	end
	local yesBtn = voteButton("YES", 0,   Color3.fromRGB(60, 150, 80))
	local noBtn  = voteButton("NO",  0.5, Color3.fromRGB(170, 70, 70))

	yesBtn.MouseButton1Click:Connect(function()
		overlay.Visible = false
		Network.surrenderVoteResult(true)
	end)
	noBtn.MouseButton1Click:Connect(function()
		overlay.Visible = false
		Network.surrenderVoteResult(false)
	end)

	showSurrenderVote = function(requesterName: string)
		body.Text = (requesterName or "A player") .. " wants to surrender and restart the match. Do you agree?"
		overlay.Visible = true
	end
	hideSurrenderVote = function()
		overlay.Visible = false
	end
end

Network.onCCAttacked(function()
	HUD.showNotification("⚠ Command Center is under attack!", Color3.fromRGB(230, 60, 60))
end)

-- Attack alerts: drop a pulsing ping on the minimap and, less often, a toast.
-- The server already throttles per region; the toast is throttled again per
-- category here so sustained fights don't stack toasts.
local ALERT_SOUND_ID       = "rbxassetid://140638438234714"
local lastAlertToast: { [string]: number } = { base = 0, army = 0 }
local ALERT_TOAST_THROTTLE = 8     -- seconds between toasts of the same category
local lastAlertSound       = 0
local ALERT_SOUND_THROTTLE = 2.5   -- seconds between alert sounds (any category)
Network.onAttackAlert(function(worldPos: Vector3, category: string)
	MiniMap.ping(worldPos, category)

	-- First time we're ever attacked: drop the dread "song" over the ambience,
	-- ducking the bed underneath it and restoring once the track finishes.
	if not firstAttackSongPlayed then
		firstAttackSongPlayed = true
		local stinger   = Instance.new("Sound")
		stinger.Name    = "FirstAttackStinger"
		stinger.SoundId = "rbxassetid://135010752626049"
		stinger.Volume  = FIRST_ATTACK_VOLUME
		stinger.Parent  = SoundService
		stinger:Play()
		horrorAmbience.Volume = AMBIENCE_VOLUME * 0.3
		stinger.Ended:Once(function()
			stinger:Destroy()
			horrorAmbience.Volume = AMBIENCE_VOLUME
		end)
	end

	local now = os.clock()

	-- Alert beep — global throttle so base+army hits don't double up.
	if now - lastAlertSound >= ALERT_SOUND_THROTTLE then
		lastAlertSound = now
		local s    = Instance.new("Sound")
		s.SoundId  = ALERT_SOUND_ID
		s.Volume   = 0.6
		s.Parent   = SoundService
		s:Play()
		s.Ended:Once(function() s:Destroy() end)
	end

	if now - (lastAlertToast[category] or 0) >= ALERT_TOAST_THROTTLE then
		lastAlertToast[category] = now
		if category == "army" then
			HUD.showNotification("⚔ Your army is under attack!", Color3.fromRGB(255, 195, 45))
		else
			HUD.showNotification("⚠ Your base is under attack!", Color3.fromRGB(255, 70, 55))
		end
	end
end)

-- Renders the end-of-match card. isDefeatRespawn = true is the mid-match defeat
-- screen (shows PLAY AGAIN, no lobby countdown); false is the real endgame
-- (auto-returns to lobby via the countdown).
local function renderEndCard(winnerUserId: number, reason: string, statsTable: any, duration: number, isDefeatRespawn: boolean)
	if not winOverlay then return end
	local card = winOverlay:FindFirstChild("Card")
	if not card then return end

	local isWinner = winnerUserId == localUserId

	-- Heading + colour strip
	local heading = card:FindFirstChild("Heading") :: TextLabel?
	local sub     = card:FindFirstChild("Sub")     :: TextLabel?
	local topBar  = card:FindFirstChild("TopBar")  :: Frame?
	local durLbl  = card:FindFirstChild("DurationLabel") :: TextLabel?
	local retLbl  = card:FindFirstChild("ReturnLabel")   :: TextLabel?
	local playAgainBtn = card:FindFirstChild("PlayAgainBtn") :: TextButton?
	local returnBtn    = card:FindFirstChild("ReturnBtn")    :: TextButton?

	if heading then
		heading.Text       = isWinner and "VICTORY!" or "DEFEAT"
		heading.TextColor3 = isWinner and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(220, 55, 55)
	end
	if topBar then
		topBar.BackgroundColor3 = isWinner and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(200, 40, 40)
	end
	if sub then
		if isWinner then
			sub.Text = reason == "monument"   and "Your monument stood for 5 minutes."
				or reason == "elimination" and "You are the last commander standing."
				or "Victory declared."
		else
			local winnerName = "Enemy"
			local wp = Players:GetPlayerByUserId(winnerUserId)
			if wp then winnerName = wp.Name end
			sub.Text = reason == "monument"   and (winnerName .. "'s monument completed its hold time.")
				or reason == "elimination" and "Your Command Center was destroyed."
				or "Defeat declared."
		end
	end

	if durLbl and duration then
		local m = math.floor(duration / 60)
		local s = math.floor(duration % 60)
		durLbl.Text = string.format("Match duration: %d:%02d", m, s)
	end

	-- ── Player avatar cards ───────────────────────────────────────────────────
	local playersSection = card:FindFirstChild("PlayersSection") :: Frame?
	if playersSection then
		for _, ch in playersSection:GetChildren() do ch:Destroy() end

		-- Collect real player IDs from stats table; always include local player
		local playerIds: { number } = {}
		local seen: { [number]: boolean } = {}
		if statsTable then
			for uidStr in statsTable do
				local uid = tonumber(uidStr)
				if uid and not seen[uid] then
					seen[uid] = true
					table.insert(playerIds, uid)
				end
			end
		end
		if not seen[localUserId] then
			table.insert(playerIds, localUserId)
		end
		-- Winner first, then local, then rest
		table.sort(playerIds, function(a, b)
			if a == winnerUserId then return true end
			if b == winnerUserId then return false end
			if a == localUserId  then return true end
			return a < b
		end)

		-- Horizontal layout with UIListLayout
		local layout                 = Instance.new("UIListLayout")
		layout.FillDirection         = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment   = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment     = Enum.VerticalAlignment.Center
		layout.SortOrder             = Enum.SortOrder.LayoutOrder
		layout.Padding               = UDim.new(0, 18)
		layout.Parent                = playersSection

		for idx, uid in playerIds do
			-- VS separator between cards
			if idx > 1 then
				local vs             = Instance.new("TextLabel")
				vs.Size              = UDim2.new(0, 28, 0, 120)
				vs.LayoutOrder       = idx * 2 - 1
				vs.BackgroundTransparency = 1
				vs.Font              = Enum.Font.GothamBold
				vs.TextSize          = 13
				vs.Text              = "VS"
				vs.TextColor3        = Color3.fromRGB(70, 80, 100)
				vs.ZIndex            = 103
				vs.Parent            = playersSection
			end

			local isThisWinner = uid == winnerUserId

			local pCard              = Instance.new("Frame")
			pCard.Name               = "PCard_" .. uid
			pCard.Size               = UDim2.new(0, 88, 0, 120)
			pCard.LayoutOrder        = idx * 2
			pCard.BackgroundTransparency = 1
			pCard.ZIndex             = 103
			pCard.Parent             = playersSection

			-- Avatar frame with winner/loser border tint
			local avatarFrame        = Instance.new("Frame")
			avatarFrame.Size         = UDim2.new(0, 72, 0, 72)
			avatarFrame.Position     = UDim2.new(0.5, -36, 0, 0)
			avatarFrame.BackgroundColor3 = isThisWinner
				and Color3.fromRGB(160, 130, 0)
				or  Color3.fromRGB(45, 50, 68)
			avatarFrame.BorderSizePixel = 0
			avatarFrame.ZIndex       = 103
			avatarFrame.Parent       = pCard
			local afCorner           = Instance.new("UICorner")
			afCorner.CornerRadius    = UDim.new(0, 8)
			afCorner.Parent          = avatarFrame

			local avatarImg          = Instance.new("ImageLabel")
			avatarImg.Name           = "AvatarImg"
			avatarImg.Size           = UDim2.new(1, -4, 1, -4)
			avatarImg.Position       = UDim2.new(0, 2, 0, 2)
			avatarImg.BackgroundColor3 = Color3.fromRGB(28, 31, 42)
			avatarImg.BorderSizePixel = 0
			avatarImg.Image          = ""
			avatarImg.ZIndex         = 104
			avatarImg.Parent         = avatarFrame
			local aiCorner           = Instance.new("UICorner")
			aiCorner.CornerRadius    = UDim.new(0, 6)
			aiCorner.Parent          = avatarImg

			local nameLabel          = Instance.new("TextLabel")
			nameLabel.Size           = UDim2.new(1, 0, 0, 18)
			nameLabel.Position       = UDim2.new(0, 0, 0, 76)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Font           = Enum.Font.GothamBold
			nameLabel.TextSize       = 12
			nameLabel.Text           = "..."
			nameLabel.TextTruncate   = Enum.TextTruncate.AtEnd
			nameLabel.TextColor3     = Color3.fromRGB(200, 215, 235)
			nameLabel.ZIndex         = 104
			nameLabel.Parent         = pCard

			local badgeLabel         = Instance.new("TextLabel")
			badgeLabel.Size          = UDim2.new(1, 0, 0, 16)
			badgeLabel.Position      = UDim2.new(0, 0, 0, 98)
			badgeLabel.BackgroundTransparency = 1
			badgeLabel.Font          = Enum.Font.GothamBold
			badgeLabel.TextSize      = 11
			badgeLabel.Text          = isThisWinner and "WINNER" or "DEFEATED"
			badgeLabel.TextColor3    = isThisWinner
				and Color3.fromRGB(255, 215, 0)
				or  Color3.fromRGB(180, 65, 65)
			badgeLabel.ZIndex        = 104
			badgeLabel.Parent        = pCard

			-- Load name + headshot asynchronously
			task.spawn(function()
				local p = Players:GetPlayerByUserId(uid)
				nameLabel.Text = p and p.Name or ("Player " .. uid)
				local ok, url = pcall(Players.GetUserThumbnailAsync, Players,
					uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
				if ok and url then avatarImg.Image = url end
			end)
		end
	end

	-- ── Animated stat counters ────────────────────────────────────────────────
	local tickSnd = card:FindFirstChild("TickSound") :: Sound?
	local myStats = statsTable and statsTable[tostring(localUserId)]

	local function animateStat(statId: string, target: number, delaySeconds: number)
		task.spawn(function()
			task.wait(delaySeconds)
			local row    = card:FindFirstChild(statId .. "Row")
			local valLbl = row and row:FindFirstChild(statId .. "Value") :: TextLabel?
			if not valLbl then return end
			if target == 0 then valLbl.Text = "0" return end

			local DURATION    = 1.3
			local elapsed     = 0
			local lastSndTime = -1
			while elapsed < DURATION do
				local dt  = task.wait()
				elapsed   = math.min(elapsed + dt, DURATION)
				local t   = elapsed / DURATION
				local ease = 1 - (1 - t) ^ 3   -- ease-out cubic
				valLbl.Text = tostring(math.floor(ease * target))
				if tickSnd and (elapsed - lastSndTime) >= 0.055 then
					tickSnd:Play()
					lastSndTime = elapsed
				end
			end
			valLbl.Text = tostring(target)
		end)
	end

	-- ── Sequential reveal ──────────────────────────────────────────────────────
	-- Everything on the card starts hidden and fades in section by section, so the
	-- outcome, roster, stats and graph land one after another instead of all at once.
	local Tween = game:GetService("TweenService")
	local function scheduleReveal(obj: Instance?, delay: number, deep: boolean?)
		if not obj then return end
		local targets: { { any } } = {}
		local function rec(o: Instance)
			if o:IsA("TextLabel") or o:IsA("TextButton") then
				targets[#targets + 1] = { o, "TextTransparency", (o :: any).TextTransparency }
				;(o :: any).TextTransparency = 1
			end
			if o:IsA("ImageLabel") then
				targets[#targets + 1] = { o, "ImageTransparency", o.ImageTransparency }
				o.ImageTransparency = 1
			end
			if o:IsA("GuiObject") and o.BackgroundTransparency < 1 then
				targets[#targets + 1] = { o, "BackgroundTransparency", o.BackgroundTransparency }
				o.BackgroundTransparency = 1
			end
			if deep then for _, c in o:GetChildren() do rec(c) end end
		end
		rec(obj)
		task.delay(delay, function()
			local ti = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			for _, t in targets do
				Tween:Create(t[1], ti, { [t[2]] = t[3] }):Play()
			end
		end)
	end

	-- Header / roster / divider.
	scheduleReveal(card:FindFirstChild("Heading"), 0.05)
	scheduleReveal(card:FindFirstChild("Sub"),     0.18)
	scheduleReveal(playersSection, 0.34, true)
	scheduleReveal(card:FindFirstChild("Div1"), 0.58)

	-- Stat rows reveal + count in sequence.
	local statOrder = { "Kills", "Trained", "Builds", "Resources" }
	local statVals  = {
		Kills     = myStats and myStats.kills           or 0,
		Trained   = myStats and myStats.unitsTrained    or 0,
		Builds    = myStats and myStats.buildingsBuilt  or 0,
		Resources = myStats and myStats.resourcesEarned or 0,
	}
	for i, id in statOrder do
		local d = 0.72 + (i - 1) * 0.2
		scheduleReveal(card:FindFirstChild(id .. "Row"), d, true)
		animateStat(id, statVals[id], d)
	end

	-- ── Performance graph: any tracked metric per commander over match time ─────
	-- The server ships every metric's timeline for every combatant; a row of tabs on
	-- the title line picks which one is plotted and redraws the plot in place.
	local graphFrame = card:FindFirstChild("GraphSection") :: Frame?
	local graphTitle = card:FindFirstChild("GraphTitle") :: TextLabel?
	do
		scheduleReveal(graphTitle, 1.62)
		local oldTabs = card:FindFirstChild("GraphTabs")
		if oldTabs then oldTabs:Destroy() end

		if graphFrame then
			local gf = graphFrame :: Frame

			-- Cumulative metrics only climb; the instantaneous ones (army/supply/base)
			-- dip whenever a fight or a raid goes badly, which is the interesting read.
			local METRICS = {
				{ key = "kills",     tab = "KILLS",  title = "UNITS DESTROYED OVER TIME" },
				{ key = "army",      tab = "ARMY",   title = "ARMY VALUE OVER TIME" },
				{ key = "resources", tab = "INCOME", title = "RESOURCES EARNED OVER TIME" },
				{ key = "units",     tab = "SUPPLY", title = "ARMY SIZE OVER TIME" },
				{ key = "buildings", tab = "BASE",   title = "STRUCTURES STANDING OVER TIME" },
			}

			local TAB_ON_BG, TAB_OFF_BG = Color3.fromRGB(58, 48, 24), Color3.fromRGB(24, 28, 38)
			local TAB_ON_TX, TAB_OFF_TX = Color3.fromRGB(255, 215, 120), Color3.fromRGB(120, 135, 160)

			local PADL, PADR, PADT, PADB = 40, 12, 20, 22
			local gw    = END_CARD_W - 60
			local gh    = 150
			local plotW = gw - PADL - PADR
			local plotH = gh - PADT - PADB
			local maxT  = math.max(duration, 1)

			-- Universal series from the server: one line per combatant (players AND AI).
			-- Winner gold, you cyan, everyone else cycles a palette. Colours are resolved
			-- once so a commander keeps the same line colour across metric switches.
			local PALETTE = {
				Color3.fromRGB(120, 230, 150), Color3.fromRGB(255, 170, 70),
				Color3.fromRGB(200, 130, 255), Color3.fromRGB(240, 90, 110),
				Color3.fromRGB(150, 200, 255), Color3.fromRGB(255, 130, 185),
			}
			local graph   = statsTable and (statsTable :: any)["__graph"]
			local gseries = (graph and graph.series) or {}
			local dt      = (graph and graph.dt) or 5

			local colors: { Color3 } = {}
			local names:  { string } = {}
			do
				local palIdx = 0
				for i, sd in gseries do
					if sd.isWinner then
						colors[i] = Color3.fromRGB(255, 215, 0)
					elseif sd.id == tostring(localUserId) then
						colors[i] = Color3.fromRGB(90, 200, 255)
					else
						palIdx += 1
						colors[i] = PALETTE[((palIdx - 1) % #PALETTE) + 1]
					end
					names[i] = sd.name or "Enemy"
				end
			end

			-- Resource totals run to five figures; keep the axis readable.
			local function fmtNum(v: number): string
				if v >= 1000 then return string.format("%.1fk", v / 1000) end
				return tostring(math.floor(v + 0.5))
			end

			local tabBtns: { TextButton } = {}
			local activeIdx = 1

			-- Rebuild the whole plot for one metric. `wipeDelay`/`wipeTime` drive the
			-- left-to-right reveal: the first draw waits for the card's reveal sequence,
			-- a tab switch snaps in quickly.
			local function drawMetric(mi: number, wipeDelay: number, wipeTime: number)
				activeIdx = mi
				local M = METRICS[mi]
				if graphTitle then graphTitle.Text = M.title end
				for i, b in tabBtns do
					local on = i == mi
					b.BackgroundColor3 = on and TAB_ON_BG or TAB_OFF_BG
					b.TextColor3       = on and TAB_ON_TX or TAB_OFF_TX
				end

				for _, ch in gf:GetChildren() do
					if not ch:IsA("UICorner") then ch:Destroy() end
				end

				local series: { { pts: { Vector2 }, color: Color3, name: string } } = {}
				local maxV = 1
				for i, sd in gseries do
					local md      = sd.metrics and (sd.metrics :: any)[M.key]
					local samples = (md and md.samples) or {}
					local finalV  = (md and md.final) or 0
					local pts: { Vector2 } = { Vector2.new(0, 0) }
					for k, v in samples do
						pts[#pts + 1] = Vector2.new(math.min(k * dt, maxT), v)
						if v > maxV then maxV = v end
					end
					pts[#pts + 1] = Vector2.new(maxT, finalV)
					if finalV > maxV then maxV = finalV end
					series[#series + 1] = { pts = pts, color = colors[i], name = names[i] }
				end

				local function axisLbl(txt: string, x: number, y: number, w: number, align: Enum.TextXAlignment)
					local l = Instance.new("TextLabel")
					l.Size = UDim2.fromOffset(w, 14)
					l.Position = UDim2.fromOffset(x, y)
					l.BackgroundTransparency = 1
					l.Font = Enum.Font.Gotham
					l.TextSize = 11
					l.Text = txt
					l.TextColor3 = Color3.fromRGB(110, 125, 150)
					l.TextXAlignment = align
					l.ZIndex = 104
					l.Parent = gf
				end

				-- Horizontal gridlines, each labelled so the scale is readable whichever
				-- metric is showing (kills count in tens, resources in thousands).
				for gi = 0, 3 do
					local y = PADT + plotH * (gi / 3)
					local gl = Instance.new("Frame")
					gl.Size = UDim2.fromOffset(plotW, 1)
					gl.Position = UDim2.fromOffset(PADL, y)
					gl.BackgroundColor3 = Color3.fromRGB(40, 46, 62)
					gl.BackgroundTransparency = 0.35
					gl.BorderSizePixel = 0
					gl.ZIndex = 103
					gl.Parent = gf
					axisLbl(fmtNum(maxV * (1 - gi / 3)), 0, y - 7, PADL - 6, Enum.TextXAlignment.Right)
				end

				axisLbl("0:00", PADL, gh - PADB + 4, 40, Enum.TextXAlignment.Left)
				axisLbl(string.format("%d:%02d", math.floor(maxT / 60), math.floor(maxT % 60)),
					gw - PADR - 44, gh - PADB + 4, 44, Enum.TextXAlignment.Right)

				-- Legend (only when more than one commander is charted).
				if #series > 1 then
					local legend = Instance.new("Frame")
					legend.Size = UDim2.fromOffset(plotW, 14)
					legend.Position = UDim2.fromOffset(PADL, 3)
					legend.BackgroundTransparency = 1
					legend.ZIndex = 106
					legend.Parent = gf
					local ll = Instance.new("UIListLayout")
					ll.FillDirection = Enum.FillDirection.Horizontal
					ll.HorizontalAlignment = Enum.HorizontalAlignment.Right
					ll.Padding = UDim.new(0, 10)
					ll.Parent = legend
					for _, ser in series do
						local chip = Instance.new("TextLabel")
						chip.AutomaticSize = Enum.AutomaticSize.X
						chip.Size = UDim2.fromOffset(0, 14)
						chip.BackgroundTransparency = 1
						chip.Font = Enum.Font.GothamBold
						chip.TextSize = 11
						chip.Text = "■ " .. ser.name
						chip.TextColor3 = ser.color
						chip.ZIndex = 106
						chip.Parent = legend
					end
				end

				-- Left-to-right wipe clip holding the plotted lines.
				local clip = Instance.new("Frame")
				clip.Name = "PlotClip"
				clip.Position = UDim2.fromOffset(PADL, PADT)
				clip.Size = UDim2.fromOffset(0, plotH)
				clip.BackgroundTransparency = 1
				clip.ClipsDescendants = true
				clip.ZIndex = 104
				clip.Parent = gf

				local function toPx(p: Vector2): (number, number)
					return (p.X / maxT) * plotW, plotH - (p.Y / maxV) * plotH
				end
				for _, ser in series do
					for pi = 1, #ser.pts - 1 do
						local x0, y0 = toPx(ser.pts[pi])
						local x1, y1 = toPx(ser.pts[pi + 1])
						local dx, dy = x1 - x0, y1 - y0
						local len = math.max(math.sqrt(dx * dx + dy * dy), 0.01)
						local seg = Instance.new("Frame")
						seg.Size = UDim2.fromOffset(len, 2)
						seg.AnchorPoint = Vector2.new(0.5, 0.5)
						seg.Position = UDim2.fromOffset((x0 + x1) / 2, (y0 + y1) / 2)
						seg.Rotation = math.deg(math.atan2(dy, dx))
						seg.BackgroundColor3 = ser.color
						seg.BorderSizePixel = 0
						seg.ZIndex = 105
						seg.Parent = clip
					end
					local ex, ey = toPx(ser.pts[#ser.pts])
					local dot = Instance.new("Frame")
					dot.Size = UDim2.fromOffset(7, 7)
					dot.AnchorPoint = Vector2.new(0.5, 0.5)
					dot.Position = UDim2.fromOffset(ex, ey)
					dot.BackgroundColor3 = ser.color
					dot.BorderSizePixel = 0
					dot.ZIndex = 106
					dot.Parent = clip
					local dc = Instance.new("UICorner"); dc.CornerRadius = UDim.new(1, 0); dc.Parent = dot
				end

				local function playWipe()
					if not clip.Parent then return end   -- switched away before the wipe fired
					Tween:Create(clip, TweenInfo.new(wipeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Size = UDim2.fromOffset(plotW, plotH) }):Play()
				end
				if wipeDelay > 0 then task.delay(wipeDelay, playWipe) else playWipe() end
			end

			-- Metric tabs, right-aligned on the graph's title line.
			if graphTitle then graphTitle.TextTruncate = Enum.TextTruncate.AtEnd end
			local tabRow = Instance.new("Frame")
			tabRow.Name = "GraphTabs"
			tabRow.Size = UDim2.new(1, -60, 0, 18)
			tabRow.Position = UDim2.new(0, 30, 0, 436)
			tabRow.BackgroundTransparency = 1
			tabRow.ZIndex = 103
			tabRow.Parent = card
			local tl = Instance.new("UIListLayout")
			tl.FillDirection = Enum.FillDirection.Horizontal
			tl.HorizontalAlignment = Enum.HorizontalAlignment.Right
			tl.VerticalAlignment = Enum.VerticalAlignment.Center
			tl.Padding = UDim.new(0, 4)
			tl.Parent = tabRow

			for i, M in METRICS do
				local b = Instance.new("TextButton")
				b.Name = "Tab_" .. M.key
				b.AutomaticSize = Enum.AutomaticSize.X
				b.Size = UDim2.fromOffset(0, 16)
				b.BackgroundColor3 = TAB_OFF_BG
				b.BorderSizePixel = 0
				b.AutoButtonColor = false
				b.Font = Enum.Font.GothamBold
				b.TextSize = 10
				b.Text = M.tab
				b.TextColor3 = TAB_OFF_TX
				b.LayoutOrder = i
				b.ZIndex = 104
				b.Parent = tabRow
				local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 4); bc.Parent = b
				local bp = Instance.new("UIPadding")
				bp.PaddingLeft = UDim.new(0, 7); bp.PaddingRight = UDim.new(0, 7)
				bp.Parent = b
				tabBtns[i] = b
				b.MouseButton1Click:Connect(function()
					if activeIdx ~= i then drawMetric(i, 0, 0.45) end
				end)
			end

			drawMetric(1, 1.85, 1.0)

			-- Reveal the frame + tabs; the plot then wipes in left-to-right.
			scheduleReveal(gf, 1.7, true)
			scheduleReveal(tabRow, 1.66, true)
		end
	end

	-- Footer: divider, duration, buttons.
	scheduleReveal(card:FindFirstChild("Div2"), 2.7)
	scheduleReveal(durLbl, 2.8)

	winOverlay.Visible = true

	-- RETURN TO MENU is always available and never auto-fires — the screen waits for a
	-- click. On a mid-match defeat it sits beside PLAY AGAIN (each takes half the row);
	-- on the real endgame it spans the full width on its own.
	if retLbl then retLbl.Text = "" end
	if returnBtn then
		returnBtn.Visible = true
		returnBtn.Active  = true
		if isDefeatRespawn then
			returnBtn.Size     = UDim2.new(0.5, -36, 0, 46)
			returnBtn.Position = UDim2.new(0.5, 6, 0, 686)
		else
			returnBtn.Size     = UDim2.new(1, -60, 0, 46)
			returnBtn.Position = UDim2.new(0, 30, 0, 686)
		end
		scheduleReveal(returnBtn, 2.95)
	end
	if playAgainBtn then
		playAgainBtn.Visible = isDefeatRespawn
		if isDefeatRespawn then scheduleReveal(playAgainBtn, 2.95) end
	end
end

-- ── The last Command Center falling ───────────────────────────────────────────
-- A commander is being eliminated, and the server is holding the verdict for it. The
-- camera is thrown to the spot so the death is WATCHED rather than reported: the loser
-- sees their own Centre come apart, the winner sees the one they just broke. The end card
-- arrives FINAL_BLOW_CAM_LEAD + FINAL_BLOW_DEATH_HOLD seconds later, which is why the
-- shake and the callout below are timed off those same two numbers instead of off a
-- second event -- one message, one clock, no way for the two sides to drift apart.
Network.onFinalBlow(function(ownerUserId: number, pos: Vector3, hollowed: boolean)
	local isMine = ownerUserId == localUserId

	-- A hard jump, not a pan: the death is about to happen and there is no time to fly.
	CameraModule.setFocus(pos)

	task.delay(Config.FINAL_BLOW_CAM_LEAD, function()
		CameraModule.shake(hollowed and 1.8 or 2.6)

		-- Name what just died while the wreck is still on screen, so the card that
		-- follows confirms something the player already watched happen.
		local what = hollowed and "Mother" or "Command Center"
		if isMine then
			HUD.showNotification("☠ YOUR " .. string.upper(what) .. " HAS FALLEN",
				Color3.fromRGB(220, 55, 55))
		else
			local who = Players:GetPlayerByUserId(ownerUserId)
			HUD.showNotification("☠ " .. ((who and who.Name) or "Enemy") .. "'s " .. what
				.. " has fallen", Color3.fromRGB(255, 215, 0))
		end
	end)
end)

Network.onShowEndScreen(function(winnerUserId: number, reason: string, statsTable: any, duration: number)
	renderEndCard(winnerUserId, reason, statsTable, duration, false)
end)

Network.onShowDefeatScreen(function(statsTable: any, duration: number)
	-- winnerUserId = -1 → local player is never the winner → renders as DEFEAT.
	renderEndCard(-1, "elimination", statsTable, duration, true)
end)

Network.onHealBeam(function(fromPos: Vector3, toPos: Vector3)
	CombatFX.healBeam(fromPos, toPos)
end)

-- Hagfish head-slap: rear the nearest hagfish down and erupt the ground tentacles
-- at every strike position the server resolved.
Network.onHagfishStrike(function(hagPos: Vector3, strikes: { Vector3 })
	HagfishBody.triggerAttackNear(hagPos)
	HagfishBody.spawnTentacles(strikes)
end)

-- A Mother egg just settled → sprout its enveloping, pulsing tentacles (client-side).
-- A planted Egg Sac egg survives its hatch, so it asks for them back off afterwards.
Network.onMotherEggLand(function(egg: BasePart, retract: boolean?)
	if retract then
		MotherEggBody.wither(egg)
	else
		MotherEggBody.sprout(egg)
	end
end)

-- A burrowed Leech just paid out income → play its feeding/harvest animation, and
-- float a rising "+income" above the player's OWN leeches (economy feedback).
Network.onLeechHarvest(function(unitId: string)
	LeechBody.triggerHarvest(unitId)

	local unitsF = workspace:FindFirstChild("Units") :: Folder?
	local part   = unitsF and unitsF:FindFirstChild(unitId) :: BasePart?
	if not part then return end
	local ov = part:FindFirstChild("OwnerId") :: StringValue?
	if not ov or ov.Value ~= tostring(localUserId) then return end

	local yBase              = part.Size.Y / 2 + 3
	local xOff               = (math.random() - 0.5) * 3
	local bb                 = Instance.new("BillboardGui")
	bb.Name                  = "_LeechIncome"
	bb.Size                  = UDim2.fromOffset(60, 20)
	bb.StudsOffset           = Vector3.new(xOff, yBase, 0)
	bb.AlwaysOnTop           = true
	bb.MaxDistance           = 200
	bb.Parent                = part

	local lbl                  = Instance.new("TextLabel")
	lbl.Size                   = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font                   = Enum.Font.GothamBold
	lbl.TextSize               = 15
	lbl.TextColor3             = Color3.fromRGB(120, 255, 140)
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3       = Color3.new(0, 0, 0)
	lbl.Text                   = "+" .. Config.LEECH_BURROW_INCOME
	lbl.Parent                 = bb

	local el = 0
	local lc: RBXScriptConnection
	lc = PerfProbe.onRender("ClientFX", function(idt)
		el += idt
		if bb.Parent then
			local t = math.min(el / 1.3, 1)
			bb.StudsOffset       = Vector3.new(xOff, yBase + t * 6, 0)
			lbl.TextTransparency = math.clamp((t - 0.4) / 0.6, 0, 1)
		end
		if el >= 1.3 then lc:Disconnect(); if bb.Parent then bb:Destroy() end end
	end)
end)

-- Broodmother death: the nearest one collapses, splits along its ribcage and drops
-- its egg sacs (drawn by the body module); a nearby camera gets a short shake.
Network.onBroodmotherDeath(function(deathPos: Vector3)
	BroodmotherBody.triggerDeathNear(deathPos)
	local camFocus = CameraModule.getFocus()
	local d = (Vector3.new(deathPos.X, 0, deathPos.Z) - camFocus).Magnitude
	if d < Config.BROODMOTHER_SHAKE_RADIUS then
		CameraModule.shake(1.7 * (1 - d / Config.BROODMOTHER_SHAKE_RADIUS))
	end
end)

Network.onUnitHit(function(fromPos: Vector3, toPos: Vector3, unitType: string)
	if unitType == "Elite" then
		CombatFX.eliteProjectile(fromPos, toPos)
		return
	end

	if unitType == "TankBarrage" then
		CombatFX.rocketBarrage(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.7)
		return
	end

	if unitType == "TankHarpoon" then
		CombatFX.trapperHarpoon(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.65)
		return
	end

	if unitType == "Tank" then
		CombatFX.tankShell(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.7)
		return
	end

	if unitType == "Howitzer" then
		CombatFX.howitzerShell(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.85)
		return
	end

	if unitType == "Lamprey" then
		LampreyBody.triggerAttackNear(fromPos)   -- mouth snaps open + head lunges
		CombatFX.lampreyBile(fromPos, toPos)
		return
	end

	if unitType == "Broodmother" then
		-- Tendrils glow + the orbiting glowing-orb swarm forms (all VFX on the body).
		BroodmotherBody.triggerAttackNear(fromPos)
		return
	end

	if unitType == "Roller" then
		-- Melee grinder — no projectile. The shell revs and throws sparks as it
		-- grinds the target (all VFX handled on the body).
		RollerBody.triggerAttackNear(fromPos)
		return
	end

	-- (A Watcher has no attack at all any more -- it is pure vision -- so no hit of its
	-- ever reaches here. WatcherBody keeps its gaze animation for whatever wants it next.)

	if unitType == "Needler" then
		-- Stationary melee — the nearest Needler cocks its long arm up and snaps it
		-- down at the target (mantis-shrimp strike; all VFX handled on the body).
		NeedlerBody.triggerAttackNear(fromPos, toPos)
		return
	end

	if unitType == "LampreyEggLand" then
		CombatFX.sound3D(fromPos, CombatFX.SND_LAMPREY_EGG_LAND, 0.8)
		return
	end

	if unitType == "LampreyEggHatch" then
		CombatFX.sound3D(fromPos, CombatFX.SND_LAMPREY_HATCH, 1.0)
		return
	end

	if unitType == "Foam" then
		-- White bubbly foam blob lobbed in an arc; impacts leave a foam splatter.
		local TRAVEL = 0.38
		local origin = fromPos + Vector3.new(0, 0.5, 0)
		local dest   = toPos   + Vector3.new(0, 0.8, 0)

		local blob          = Instance.new("Part")
		blob.Shape          = Enum.PartType.Ball
		blob.Size           = Vector3.new(1.3, 1.3, 1.3)
		blob.Color          = Color3.fromRGB(230, 248, 255)
		blob.Material       = Enum.Material.SmoothPlastic
		blob.Transparency   = 0.1
		blob.Anchored       = true
		blob.CanCollide     = false
		blob.CanQuery       = false
		blob.CanTouch       = false
		blob.CastShadow     = false
		blob.Position       = origin
		blob.Parent         = workspace

		local bElapsed = 0
		local bConn: RBXScriptConnection
		bConn = PerfProbe.onRender("ClientFX", function(bdt)
			bElapsed += bdt
			local bt  = math.min(bElapsed / TRAVEL, 1)
			-- Arc trajectory: foam is lobbed upward
			local arcH = math.sin(bt * math.pi) * 5
			local wobble = 1.3 + math.sin(bElapsed * 22) * 0.08
			blob.Size     = Vector3.new(wobble, wobble, wobble)
			blob.Position = origin:Lerp(dest, bt) + Vector3.new(0, arcH, 0)
			if bt >= 1 then
				bConn:Disconnect()
				blob:Destroy()
				-- Impact splatter: several white spheres that fade out
				for i = 1, 5 do
					local splat          = Instance.new("Part")
					splat.Shape          = Enum.PartType.Ball
					local sz             = 0.6 + math.random() * 0.8
					splat.Size           = Vector3.new(sz, sz, sz)
					splat.Color          = Color3.fromRGB(240, 252, 255)
					splat.Material       = Enum.Material.SmoothPlastic
					splat.Transparency   = 0.0
					splat.Anchored       = true
					splat.CanCollide     = false
					splat.CanQuery       = false
					splat.CanTouch       = false
					splat.CastShadow     = false
					local ox = (math.random() - 0.5) * 3.5
					local oz = (math.random() - 0.5) * 3.5
					splat.Position       = dest + Vector3.new(ox, 0, oz)
					splat.Parent         = workspace
					local sElapsed = 0
					local sConn: RBXScriptConnection
					sConn = PerfProbe.onRender("ClientFX", function(sdt)
						sElapsed += sdt
						local sp = math.min(sElapsed / 0.55, 1)
						splat.Transparency = sp
						if sp >= 1 then sConn:Disconnect(); splat:Destroy() end
					end)
				end
			end
		end)
		return
	end

	-- Sniper — a single heavy long-range shot: a long, bright, near-instant tracer
	-- with a big muzzle flash and a deep report (lower-pitched, louder gunshot).
	if unitType == "Sniper" then
		CombatFX.sound3D(fromPos, CombatFX.SND_SNIPER, 0.12)   -- dedicated rifle crack

		local origin = fromPos + Vector3.new(0, 1.6, 0)
		local dest   = toPos   + Vector3.new(0, 1.0, 0)
		local rawDir = dest - origin
		local dist   = rawDir.Magnitude
		local unit   = if dist > 0.01 then rawDir / dist else Vector3.new(0, 0, -1)

		-- Big muzzle flash at the barrel.
		local flash        = Instance.new("Part")
		flash.Name         = "_SniperMuzzle"
		flash.Shape        = Enum.PartType.Ball
		flash.Size         = Vector3.new(0.9, 0.9, 0.9)
		flash.Color        = Color3.fromRGB(255, 246, 205)
		flash.Material     = Enum.Material.Neon
		flash.Anchored     = true
		flash.CanCollide   = false
		flash.CanQuery     = false
		flash.CanTouch     = false
		flash.CastShadow   = false
		flash.Position     = origin
		flash.Parent       = workspace
		task.delay(0.06, function() if flash.Parent then flash:Destroy() end end)

		-- Full-length tracer struck across the whole line of fire at once, then fades.
		local mid          = origin:Lerp(dest, 0.5)
		local core         = Instance.new("Part")
		core.Name          = "_SniperTracer"
		core.Size          = Vector3.new(0.14, 0.14, math.max(dist, 0.1))
		core.Color         = Color3.fromRGB(255, 250, 220)
		core.Material      = Enum.Material.Neon
		core.Anchored      = true
		core.CanCollide    = false
		core.CanQuery      = false
		core.CanTouch      = false
		core.CastShadow    = false
		core.CFrame        = CFrame.lookAt(mid, mid + unit)
		core.Parent        = workspace

		local halo         = core:Clone()
		halo.Name          = "_SniperTracerGlow"
		halo.Size          = Vector3.new(0.34, 0.34, math.max(dist, 0.1))
		halo.Color         = Color3.fromRGB(255, 205, 120)
		halo.Transparency  = 0.45
		halo.Parent        = workspace

		-- Impact spark bloom at the target.
		local spark        = Instance.new("Part")
		spark.Shape        = Enum.PartType.Ball
		spark.Size         = Vector3.new(0.6, 0.6, 0.6)
		spark.Color        = Color3.fromRGB(255, 235, 180)
		spark.Material     = Enum.Material.Neon
		spark.Anchored     = true
		spark.CanCollide   = false
		spark.CanQuery     = false
		spark.CanTouch     = false
		spark.CastShadow   = false
		spark.Position     = dest
		spark.Parent       = workspace

		local elapsed = 0
		local conn: RBXScriptConnection
		conn = PerfProbe.onRender("ClientFX", function(dt)
			elapsed += dt
			local a = math.min(elapsed / 0.16, 1)
			core.Transparency  = a
			halo.Transparency  = 0.45 + a * 0.55
			local s = 0.6 + a * 2.2
			spark.Size         = Vector3.new(s, s, s)
			spark.Transparency = a
			if a >= 1 then
				conn:Disconnect()
				core:Destroy(); halo:Destroy(); spark:Destroy()
			end
		end)
		return
	end

	-- Survivor (and CreepySoldier) — quick gunshot
	CombatFX.sound3D(fromPos, CombatFX.SND_SOLDIER, 0.55)

	-- Survivor: oriented tracer streak — thin neon rod aimed at target,
	-- outer glow shell, muzzle flash at barrel, expanding impact bloom on hit.
	local TRAVEL     = 0.10   -- seconds; snappy and readable at RTS distances
	local STREAK_LEN = 2.4    -- stud length of the tracer body

	local origin = fromPos + Vector3.new(0, 1.5, 0)
	local dest   = toPos   + Vector3.new(0, 1.0, 0)

	local rawDir = dest - origin
	local dist   = rawDir.Magnitude
	-- Safe unit vector (guard against origin == dest edge case)
	local unit   = if dist > 0.01 then rawDir / dist else Vector3.new(0, 0, -1)

	-- ── Muzzle flash — brief bright point at the barrel ───────────────────────
	local muzzle          = Instance.new("Part")
	muzzle.Name           = "_MuzzleFlash"
	muzzle.Size           = Vector3.new(0.50, 0.50, 0.50)
	muzzle.Shape          = Enum.PartType.Ball
	muzzle.Color          = Color3.fromRGB(255, 250, 210)
	muzzle.Material       = Enum.Material.Neon
	muzzle.Anchored       = true
	muzzle.CanCollide     = false
	muzzle.CanQuery       = false
	muzzle.CanTouch       = false
	muzzle.CastShadow     = false
	muzzle.Position       = origin
	muzzle.Parent         = workspace
	task.delay(0.05, function() if muzzle.Parent then muzzle:Destroy() end end)

	-- ── Inner core — very thin, very bright tracer rod ────────────────────────
	-- CFrame.lookAt(center, center+unit): part's LookVector (−Z) faces unit dir,
	-- so the block's Z length runs along the travel axis.
	-- Center sits half a streak-length behind the leading edge so the tip lines
	-- up with the bullet's current world position each frame.
	local initCenter = origin - unit * (STREAK_LEN * 0.5)
	local initCF     = CFrame.lookAt(initCenter, initCenter + unit)

	local proj        = Instance.new("Part")
	proj.Name         = "_SoldierBullet"
	proj.Size         = Vector3.new(0.09, 0.09, STREAK_LEN)
	proj.Color        = Color3.fromRGB(255, 248, 185)   -- near-white hot yellow
	proj.Material     = Enum.Material.Neon
	proj.Anchored     = true
	proj.CanCollide   = false
	proj.CanQuery     = false
	proj.CanTouch     = false
	proj.CastShadow   = false
	proj.CFrame       = initCF
	proj.Parent       = workspace

	-- ── Outer glow — wider, semi-transparent shell around the core ───────────
	local glow        = Instance.new("Part")
	glow.Name         = "_SoldierBulletGlow"
	glow.Size         = Vector3.new(0.24, 0.24, STREAK_LEN + 0.5)
	glow.Color        = Color3.fromRGB(255, 210, 60)    -- warmer amber halo
	glow.Material     = Enum.Material.Neon
	glow.Transparency = 0.50
	glow.Anchored     = true
	glow.CanCollide   = false
	glow.CanQuery     = false
	glow.CanTouch     = false
	glow.CastShadow   = false
	glow.CFrame       = initCF
	glow.Parent       = workspace

	local elapsed = 0
	local conn: RBXScriptConnection
	conn = PerfProbe.onRender("ClientFX", function(dt)
		elapsed += dt
		local t = math.min(elapsed / TRAVEL, 1)

		-- Straight-line travel — no arc, bullets don't lob
		local tip    = origin + unit * (t * dist)
		local center = tip - unit * (STREAK_LEN * 0.5)
		local cf     = CFrame.lookAt(center, center + unit)
		proj.CFrame  = cf
		glow.CFrame  = cf

		if t >= 1 then
			conn:Disconnect()
			proj:Destroy()
			glow:Destroy()

			-- ── Impact bloom — small bright core that expands and fades ────────
			local flash        = Instance.new("Part")
			flash.Name         = "_BulletImpact"
			flash.Size         = Vector3.new(0.7, 0.7, 0.7)
			flash.Shape        = Enum.PartType.Ball
			flash.Color        = Color3.fromRGB(255, 238, 145)
			flash.Material     = Enum.Material.Neon
			flash.Transparency = 0
			flash.Anchored     = true
			flash.CanCollide   = false
			flash.CanQuery     = false
			flash.CanTouch     = false
			flash.CastShadow   = false
			flash.Position     = dest
			flash.Parent       = workspace

			local ft = 0
			local fconn: RBXScriptConnection
			fconn = PerfProbe.onRender("ClientFX", function(fdt)
				ft += fdt
				local p = math.min(ft / 0.11, 1)
				flash.Size         = Vector3.new(1, 1, 1) * (0.7 + p * 1.4)
				flash.Transparency = p
				if p >= 1 then
					fconn:Disconnect()
					flash:Destroy()
				end
			end)
		end
	end)
end)

Network.onTurretShot(function(fromPos: Vector3, toPos: Vector3, upgradeType: string?)
	if upgradeType == "Flamethrower" then
		CombatFX.flamethrowerShot(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_SOLDIER, 0.5)   -- lighter rapid burst
	elseif upgradeType == "RocketLauncher" then
		CombatFX.rocketShot(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.75)
	elseif upgradeType == "Artillery" then
		CombatFX.artilleryShot(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.95)
	else
		CombatFX.baseTurretShot(fromPos, toPos)
		CombatFX.sound3D(fromPos, CombatFX.SND_TANK, 0.65)
	end
end)

-- ── Evolved turret tentacle animation ────────────────────────────────────────

local TENT_PHASES = { 0, math.pi * 2 / 3, math.pi * 4 / 3 }
local JOINT_SIZES = { 2.0, 1.4, 0.9 }

local function bez3(u_: number, p0: Vector3, ctrl_: Vector3, p2: Vector3): Vector3
	local v = 1 - u_
	return v*v * p0 + 2*v*u_ * ctrl_ + u_*u_ * p2
end

local function createEvolvedTentacles(turretId: string): EvolvedData?
	local tentacles: { TentacleParts } = {}
	for t = 1, 3 do
		local joints:     { Part } = {}
		local connectors: { Part } = {}
		local teeth:      { Part } = {}

		for j = 1, 3 do
			local p = Instance.new("Part")
			p.Shape    = Enum.PartType.Ball
			p.Size     = Vector3.new(JOINT_SIZES[j], JOINT_SIZES[j], JOINT_SIZES[j])
			p.Color    = Color3.new(0.05, 0.05, 0.05)
			p.Material = Enum.Material.SmoothPlastic
			p.Anchored = true; p.CanCollide = false; p.CastShadow = false; p.CanQuery = false
			p.Parent   = workspace
			joints[j]  = p
		end

		for c = 1, 3 do
			local p = Instance.new("Part")
			p.Shape       = Enum.PartType.Cylinder
			p.Size        = Vector3.new(1, 0.75, 0.75)
			p.Color       = Color3.new(0.05, 0.05, 0.05)
			p.Material    = Enum.Material.SmoothPlastic
			p.Anchored    = true; p.CanCollide = false; p.CastShadow = false; p.CanQuery = false
			p.Parent      = workspace
			connectors[c] = p
		end

		-- 2 teeth per connector segment = 6 total (staggered alternating sides)
		for k = 1, 6 do
			local p = Instance.new("Part")
			p.Size     = Vector3.new(0.35, 1.3, 0.35)
			p.Color    = Color3.fromRGB(235, 235, 225)
			p.Material = Enum.Material.SmoothPlastic
			p.Anchored = true; p.CanCollide = false; p.CastShadow = false; p.CanQuery = false
			p.Parent   = workspace
			teeth[k]   = p
		end

		tentacles[t] = { joints = joints, connectors = connectors, teeth = teeth }
	end

	local data: EvolvedData = { targets = { nil, nil, nil }, lastTarget = 0, tentacles = tentacles, tipPos = {}, sound = nil }
	evolvedTurrets[turretId] = data
	return data
end

local function destroyEvolvedTentacles(turretId: string)
	local data = evolvedTurrets[turretId]
	if not data then return end
	for _, tp in data.tentacles do
		for _, p in tp.joints     do if p.Parent then p:Destroy() end end
		for _, p in tp.connectors do if p.Parent then p:Destroy() end end
		for _, p in tp.teeth      do if p.Parent then p:Destroy() end end
	end
	evolvedTurrets[turretId] = nil
end

PerfProbe.onRender("ClientFX", function(dt: number)
	local now = os.clock()
	local bf  = workspace:FindFirstChild("Buildings") :: Folder?
	for turretId, data in evolvedTurrets do
		if not bf then continue end
		local model = bf:FindFirstChild(turretId)
		if not model then destroyEvolvedTentacles(turretId); continue end
		local head = model:FindFirstChild("Head") :: BasePart?
		if not head then continue end
		local headPos = head.Position

		local TENTACLE_LEN = 14
		local isAttacking  = (now - data.lastTarget) < 0.75

		for t = 1, 3 do
			local phase = TENT_PHASES[t]
			local wT    = now * math.pi * 2 * 0.75 + phase

			-- Idle tip: slow organic wave
			local idleAngle = phase + math.sin(wT) * 0.32
			local idleTip   = headPos
				+ Vector3.new(math.cos(idleAngle), 0, math.sin(idleAngle)) * TENTACLE_LEN
				+ Vector3.new(0, math.sin(wT * 0.85) * 4 + 4, 0)

			-- Goal position: each tentacle spreads to its own approach angle
			-- so three tentacles targeting the same enemy never fully merge
			local goalTip: Vector3
			if isAttacking and data.targets[t] then
				local target    = data.targets[t] :: Vector3
				local spreadDir = Vector3.new(math.cos(phase), 0.12, math.sin(phase))
				goalTip = target + spreadDir * 3.0
			else
				goalTip = idleTip
			end

			-- Continuous per-frame lerp toward goal — no snapping when target refreshes
			local current = data.tipPos[t]
			local alpha   = math.min(dt * 6, 1)
			local tipPos: Vector3
			if current then
				tipPos = current:Lerp(goalTip, alpha)
			else
				tipPos = goalTip
			end
			data.tipPos[t] = tipPos

			local ctrl = (headPos + tipPos) * 0.5 + Vector3.new(0, 7, 0)
			local p1   = bez3(0.33, headPos, ctrl, tipPos)
			local p2   = bez3(0.67, headPos, ctrl, tipPos)
			local pts  = { headPos, p1, p2, tipPos }

			local tp = data.tentacles[t]
			tp.joints[1].Position = p1
			tp.joints[2].Position = p2
			tp.joints[3].Position = tipPos

			local TOOTH_LEN   = 1.3
			local CONN_RADIUS = 0.375
			local toothOffset = CONN_RADIUS + TOOTH_LEN * 0.5

			for c = 1, 3 do
				local A   = pts[c]
				local B   = pts[c + 1]
				local seg = B - A
				local len = seg.Magnitude
				if len < 0.01 then continue end
				local fwd = seg.Unit
				local mid = (A + B) * 0.5

				-- Connector cylinder: length along X axis
				tp.connectors[c].Size   = Vector3.new(len, 0.75, 0.75)
				tp.connectors[c].CFrame = CFrame.new(mid, B) * CFrame.Angles(0, math.pi / 2, 0)

				-- Perpendicular axis for tooth placement
				local upRef = Vector3.new(0, 1, 0)
				if math.abs(fwd:Dot(upRef)) > 0.9 then upRef = Vector3.new(1, 0, 0) end
				local perp  = fwd:Cross(upRef).Unit
				-- Alternate which side each connector's tooth pair emerges from
				local side1 = (c % 2 == 1) and perp or -perp
				local side2 = -side1

				-- Tooth at 1/3 of segment (side1) — Y axis points outward so spike faces away
				local tPos1 = A:Lerp(B, 0.33) + side1 * toothOffset
				local zV1   = fwd:Cross(side1); if zV1.Magnitude > 0.01 then zV1 = zV1.Unit end
				tp.teeth[(c - 1) * 2 + 1].CFrame = CFrame.fromMatrix(tPos1, fwd, side1, zV1)

				-- Tooth at 2/3 of segment (side2)
				local tPos2 = A:Lerp(B, 0.67) + side2 * toothOffset
				local zV2   = fwd:Cross(side2); if zV2.Magnitude > 0.01 then zV2 = zV2.Unit end
				tp.teeth[(c - 1) * 2 + 2].CFrame = CFrame.fromMatrix(tPos2, fwd, side2, zV2)
			end
		end
	end
end)

Network.onTentacleTargets(function(turretId: string, _headPos: Vector3, t1: Vector3?, t2: Vector3?, t3: Vector3?)
	local data = evolvedTurrets[turretId]
	if not data then
		data = createEvolvedTentacles(turretId) :: EvolvedData
		if not data then return end
	end
	data.targets    = { t1, t2, t3 }
	local hasTarget = t1 ~= nil or t2 ~= nil or t3 ~= nil
	data.lastTarget = if hasTarget then os.clock() else data.lastTarget

	if hasTarget then
		-- Lazy-create 3D positional attack sound on the turret head
		if not data.sound then
			local bf = workspace:FindFirstChild("Buildings") :: Folder?
			local model = bf and bf:FindFirstChild(turretId)
			local head  = model and model:FindFirstChild("Head") :: BasePart?
			if head then
				local snd            = Instance.new("Sound")
				snd.SoundId          = "rbxassetid://126493346091885"
				snd.Volume           = 0.9
				snd.RollOffMaxDistance = 80
				snd.Parent           = head
				data.sound           = snd
			end
		end
		if data.sound and not (data.sound :: Sound).IsPlaying then
			(data.sound :: Sound):Play()
		end
	end
end)

-- ── Signal flare building icon (ScreenGui overlay — same method as BarracksPanel unit icons) ──
-- ViewportFrame does not render inside BillboardGui (world-space GUI), so we
-- mirror the BarracksPanel approach: the preview lives in a ScreenGui and is
-- repositioned each frame using WorldToViewportPoint.
do
	type FlareEntry = { anchor: BasePart, frame: Frame }
	local flareEntries: { FlareEntry } = {}

	local flareSg              = Instance.new("ScreenGui")
	flareSg.Name               = "FlareIconOverlay"
	flareSg.IgnoreGuiInset     = true
	flareSg.ResetOnSpawn       = false
	flareSg.ZIndexBehavior     = Enum.ZIndexBehavior.Sibling
	flareSg.Parent             = Players.LocalPlayer.PlayerGui

	local function registerFlare(model: Model)
		local anchor = model:WaitForChild("Anchor", 5) :: BasePart?
		if not anchor or not model.Parent then return end
		local bt = model:GetAttribute("BuildingType") :: string?
		if not bt then return end

		local frame                  = Instance.new("Frame")
		frame.Size                   = UDim2.fromOffset(44, 44)
		frame.AnchorPoint            = Vector2.new(0.5, 1)
		frame.BackgroundTransparency = 1  -- transparent: never covers the BillboardGui progress bar
		frame.BorderSizePixel        = 0
		frame.ZIndex                 = 15
		frame.Visible                = false
		frame.Parent                 = flareSg

		-- 3D building preview — identical mechanism to BarracksPanel unit icons
		local vpf = ViewportPreview.forBuilding(bt, Vector2.new(38, 38))
		vpf.Position = UDim2.fromOffset(3, 3)
		vpf.Parent   = frame

		table.insert(flareEntries, { anchor = anchor, frame = frame })

		model.Destroying:Connect(function()
			frame:Destroy()
			for i, e in flareEntries do
				if e.anchor == anchor then table.remove(flareEntries, i); break end
			end
		end)
	end

	workspace.DescendantAdded:Connect(function(inst)
		if inst:IsA("Model") and inst.Name == "_SignalFlare" then
			task.spawn(registerFlare, inst :: Model)
		end
	end)
	for _, d in workspace:GetDescendants() do
		if d:IsA("Model") and d.Name == "_SignalFlare" then
			task.spawn(registerFlare, d :: Model)
		end
	end

	-- Reposition each icon every frame to track the flare's world position.
	-- The billboard's StudsOffset is (0,5,0), so its center in screen space is
	-- anchor + (0,5,0). The icon sits just above the progress bar: bottom of the
	-- 44px icon aligns with the top 44px slot of the 52px billboard (+18px below
	-- billboard center with AnchorPoint.Y = 1).
	PerfProbe.bindRender("FlareIconPositions", Enum.RenderPriority.Camera.Value + 1, "ClientFX", function()
		if #flareEntries == 0 then return end
		local cam = workspace.CurrentCamera
		for _, e in flareEntries do
			if not e.anchor.Parent then
				e.frame.Visible = false
				continue
			end
			local sv, onScreen = cam:WorldToViewportPoint(e.anchor.Position + Vector3.new(0, 5, 0))
			if onScreen and sv.Z > 0 then
				e.frame.Visible  = true
				e.frame.Position = UDim2.fromOffset(math.floor(sv.X), math.floor(sv.Y + 8))
			else
				e.frame.Visible = false
			end
		end
	end)
end

end -- startGame

CometManager.init()
EggReadyIcon.start()   -- mark over each Egg-Sac egg that has grown ripe and can be spent
ForestFade.start()   -- trees dissolve out of the middle of the view; watches for the forest itself

-- Main menu first: a tabbed shell. The READY UP tab reveals the Map/AI lobby (which
-- owns the game-start flow) beneath the persistent tab bar; the lobby only builds the
-- first time that tab is entered. When its countdown begins, the lobby fires the
-- start-transition hook so MainMenu drops its chrome for the full-screen sequence.
MainMenu.init({
	buildLobby = function() LobbyUI.init(startGame) end,
	setLobbyVisible = function(visible: boolean) LobbyUI.setVisible(visible) end,
})
LobbyUI.setOnStartTransition(function() MainMenu.close() end)
