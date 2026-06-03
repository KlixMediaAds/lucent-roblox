--[[
	ShaderManager — Client-side post-processing preset system.

	Chat commands:
	  /shader 1   → enable preset "1" (Gloomy Atmosphere)
	  /shader 0   → disable; restore all original values

	Architecture:
	  • Presets are plain tables under PRESETS.  Add a new key to add a preset.
	  • On enable:  snapshot every affected property, then apply preset values.
	  • On disable: restore snapshot, destroy any effects this module created.
	  • Safe against duplicate calls: enabling while already active re-snapshots
	    cleanly by disabling first.

	Post-processing stack used:
	  • Lighting properties   (Ambient, OutdoorAmbient, ColorShift_*, ExposureCompensation)
	  • ColorCorrectionEffect  (Saturation, TintColor, Contrast, Brightness)
	  • BloomEffect            (Threshold, Intensity, Size)
	  • Atmosphere             (Density, Color, Decay, Haze, Glare, Offset)
--]]

local Lighting = game:GetService("Lighting")

local ShaderManager = {}

-- ── Preset definitions ────────────────────────────────────────────────────────
--[[
  "1" — Gloomy Atmosphere
  Desaturated, eerie, hand-painted moodscape.  Colors mute toward gray so
  neon, team-tinted, and emissive objects stand out as vivid focal points.
  The atmosphere adds cool blue-gray depth haze without obscuring gameplay.
  Bloom activates only on genuinely bright surfaces (neon materials, fires,
  explosions) to keep the world feeling lived-in rather than simply dark.
--]]

type LightingPreset = {
	lighting:        { [string]: any },
	colorCorrection: { [string]: any },
	bloom:           { [string]: any },
	atmosphere:      { [string]: any },
}

local PRESETS: { [string]: LightingPreset } = {
	["1"] = {
		-- ── Lighting service ──────────────────────────────────────────────────
		lighting = {
			-- Cool blue-gray ambient keeps shadows muted and desaturated
			Ambient              = Color3.fromRGB(68,  80, 108),
			-- Heavy overcast sky tone for outdoor diffuse
			OutdoorAmbient       = Color3.fromRGB(92, 106, 130),
			-- Very subtle cool tint from above — keeps geometry reading clearly
			ColorShift_Top       = Color3.fromRGB(12,  16,  30),
			-- Gentle cool fill from below — no warm ground bounce
			ColorShift_Bottom    = Color3.fromRGB( 4,   6,  16),
			-- Mild compression only — do NOT dim neon below bloom threshold
			ExposureCompensation = -0.15,
		},
		-- ── ColorCorrectionEffect ─────────────────────────────────────────────
		colorCorrection = {
			-- Moderate desaturation: world looks muted but neon/emissive
			-- objects retain most of their chroma since they are very high
			-- luminance — desaturation has diminishing effect near white.
			-- (was -0.62 which killed neon color through the bloom pass)
			Saturation = -0.45,
			-- Much more neutral tint: barely perceptible cool shift.
			-- A strong tint was grey-washing neon halos after bloom compositing.
			TintColor  = Color3.fromRGB(210, 218, 232),
			-- Higher contrast pushes the dark world darker while bright
			-- neon surfaces stay bright — widens the perceptual gap.
			Contrast   = 0.14,
			-- Leave Brightness neutral; saturation + contrast do the mood work.
			Brightness = -0.02,
		},
		-- ── BloomEffect ───────────────────────────────────────────────────────
		bloom = {
			-- Low threshold: fires on all Neon material parts, team-colored
			-- building accents, explosions, particles, and UI elements.
			-- (was 0.88 — too high, blocked most emissive surfaces entirely)
			Threshold = 0.68,
			-- Strong intensity: the bloom halo is what makes neon beautiful
			-- against the desaturated grey world. Go big here.
			-- (was 0.45 — barely visible)
			Intensity = 1.1,
			-- Wide spread: large soft halo around every light source creates
			-- the "painting" effect where glowing things feel warm and alive.
			-- (was 24 — too narrow to be noticeable at gameplay distances)
			Size      = 56,
		},
		-- ── Atmosphere ────────────────────────────────────────────────────────
		atmosphere = {
			-- Blue-gray scatter: overcast, diffuse, heavy-sky feel
			Color   = Color3.fromRGB(105, 120, 148),
			-- Cooler shadow decay into distance
			Decay   = Color3.fromRGB(70,  80, 104),
			-- Moderate depth haze for dreamlike softness and distance cuing
			Density = 0.22,
			-- Substantial haze diffuses the sky into the scene
			Haze    = 1.6,
			-- No sun glare — overcast sky, fully diffuse lighting
			Glare   = 0,
			-- Low offset: mist starts close to viewer for atmospheric depth
			Offset  = 0.10,
		},
	},
}

-- ── Property lists (used for snapshot iteration) ──────────────────────────────

local LIGHTING_PROPS = {
	"Ambient", "OutdoorAmbient",
	"ColorShift_Top", "ColorShift_Bottom",
	"ExposureCompensation",
}

local CC_PROPS      = { "Brightness", "Contrast", "Saturation", "TintColor" }
local BLOOM_PROPS   = { "Intensity", "Size", "Threshold" }
local ATMO_PROPS    = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }

-- ── Module state ──────────────────────────────────────────────────────────────

local isActive        = false
local activePresetKey: string? = nil

-- Cached effect references
local ccEffect:    ColorCorrectionEffect?
local bloomEffect: BloomEffect?
local atmoEffect:  Atmosphere?

-- Which effects did WE create (so we destroy them on disable, not just restore)
local createdCC    = false
local createdBloom = false
local createdAtmo  = false

-- Snapshots filled on enable; used to restore on disable
local snapLighting:        { [string]: any } = {}
local snapCC:              { [string]: any } = {}
local snapBloom:           { [string]: any } = {}
local snapAtmo:            { [string]: any } = {}

-- ── Snapshot helpers ──────────────────────────────────────────────────────────

local function snapshotObject(obj: any, props: { string }, out: { [string]: any })
	for _, prop in props do
		out[prop] = (obj :: any)[prop]
	end
end

local function applyToObject(obj: any, values: { [string]: any })
	for prop, val in values do
		(obj :: any)[prop] = val
	end
end

local function restoreToObject(obj: any, snap: { [string]: any })
	for prop, val in snap do
		(obj :: any)[prop] = val
	end
end

-- ── Internal enable / disable ─────────────────────────────────────────────────

local function disable()
	if not isActive then
		print("[ShaderManager] Shader already off — nothing to restore.")
		return
	end

	-- Restore Lighting service properties
	restoreToObject(Lighting, snapLighting)

	-- Restore or destroy ColorCorrectionEffect
	if ccEffect then
		if createdCC then
			ccEffect:Destroy()
		else
			restoreToObject(ccEffect, snapCC)
		end
		ccEffect  = nil
		createdCC = false
	end

	-- Restore or destroy BloomEffect
	if bloomEffect then
		if createdBloom then
			bloomEffect:Destroy()
		else
			restoreToObject(bloomEffect, snapBloom)
		end
		bloomEffect  = nil
		createdBloom = false
	end

	-- Restore or destroy Atmosphere
	if atmoEffect then
		if createdAtmo then
			atmoEffect:Destroy()
		else
			restoreToObject(atmoEffect, snapAtmo)
		end
		atmoEffect  = nil
		createdAtmo = false
	end

	table.clear(snapLighting)
	table.clear(snapCC)
	table.clear(snapBloom)
	table.clear(snapAtmo)

	isActive        = false
	activePresetKey = nil
	print("[ShaderManager] Shader disabled — original settings restored.")
end

local function enable(key: string)
	local preset = PRESETS[key]
	if not preset then
		warn("[ShaderManager] Unknown preset key:", key)
		return
	end

	-- Re-enable cleanly if already active
	if isActive then disable() end

	-- ── Snapshot Lighting service ─────────────────────────────────────────────
	snapshotObject(Lighting, LIGHTING_PROPS, snapLighting)

	-- ── ColorCorrectionEffect ─────────────────────────────────────────────────
	ccEffect = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if ccEffect then
		createdCC = false
		snapshotObject(ccEffect, CC_PROPS, snapCC)
	else
		ccEffect         = Instance.new("ColorCorrectionEffect")
		ccEffect.Name    = "_ShaderCC"
		ccEffect.Parent  = Lighting
		createdCC        = true
		-- Safe default snapshot (what a freshly created CCE looks like)
		snapCC = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) }
	end

	-- ── BloomEffect ───────────────────────────────────────────────────────────
	bloomEffect = Lighting:FindFirstChildOfClass("BloomEffect")
	if bloomEffect then
		createdBloom = false
		snapshotObject(bloomEffect, BLOOM_PROPS, snapBloom)
	else
		bloomEffect        = Instance.new("BloomEffect")
		bloomEffect.Name   = "_ShaderBloom"
		bloomEffect.Parent = Lighting
		createdBloom       = true
		snapBloom = { Intensity = 0.9, Size = 24, Threshold = 1 }
	end

	-- ── Atmosphere ────────────────────────────────────────────────────────────
	atmoEffect = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmoEffect then
		createdAtmo = false
		snapshotObject(atmoEffect, ATMO_PROPS, snapAtmo)
	else
		atmoEffect        = Instance.new("Atmosphere")
		atmoEffect.Name   = "_ShaderAtmo"
		atmoEffect.Parent = Lighting
		createdAtmo       = true
		snapAtmo = {
			Density = 0,
			Offset  = 0,
			Color   = Color3.new(1, 1, 1),
			Decay   = Color3.new(1, 1, 1),
			Glare   = 0,
			Haze    = 0,
		}
	end

	-- ── Apply preset values ───────────────────────────────────────────────────
	applyToObject(Lighting,    preset.lighting)
	applyToObject(ccEffect,    preset.colorCorrection)
	applyToObject(bloomEffect, preset.bloom)
	applyToObject(atmoEffect,  preset.atmosphere)

	isActive        = true
	activePresetKey = key
	print(string.format("[ShaderManager] Preset '%s' enabled.", key))
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Called from the chat command handler in init.client.luau.
-- arg is the text after "/shader " (e.g. "1" or "0").
function ShaderManager.handleCommand(arg: string)
	local trimmed = arg:match("^%s*(.-)%s*$") or arg
	if trimmed == "0" then
		disable()
	elseif PRESETS[trimmed] then
		enable(trimmed)
	else
		warn(string.format(
			"[ShaderManager] Unknown arg '%s'. Usage: /shader 1  (enable)  |  /shader 0  (disable)",
			trimmed
		))
	end
end

-- Returns whether a shader is currently active (and which key).
function ShaderManager.isEnabled(): (boolean, string?)
	return isActive, activePresetKey
end

return ShaderManager
