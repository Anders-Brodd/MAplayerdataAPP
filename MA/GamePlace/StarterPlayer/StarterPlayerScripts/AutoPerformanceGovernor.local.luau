-- Runtime-only performance governor for heavy resorts.
-- It never saves preferences; it only overrides local attributes while FPS is low.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

-- SettingsController already runs the active runtime perf tier system.
-- Keep this legacy governor disabled to avoid duplicate loops and invalid Terrain property writes.
local ENABLE_LEGACY_RUNTIME_GOVERNOR = false
if not ENABLE_LEGACY_RUNTIME_GOVERNOR then
	return
end

local terrain = Workspace:FindFirstChildOfClass("Terrain")

local SETTINGS_PREFIX = "Settings_"
local TRACKED_SETTING_KEYS = {
	"GraphicsPreset",
	"BuildingRenderDistance",
	"LiftRenderDistance",
	"NPCRenderDistance",
	"WeatherQuality",
	"ParticleQuality",
	"ParticleDensity",
	"RealisticParticles",
	"AdaptiveParticles",
	"FogEdgeBlend",
	"FogEdgeIntensity",
}

local baseSettings = {}
for _, key in ipairs(TRACKED_SETTING_KEYS) do
	baseSettings[key] = player:GetAttribute(SETTINGS_PREFIX .. key)
end

local baseGuestModelsVisible = player:GetAttribute("GuestModelsVisible")
local baseGuestLODEnabled = player:GetAttribute("GuestLODEnabled")
local baseParticlesEnabled = player:GetAttribute("ParticlesEnabled")

local baseGlobalShadows = Lighting.GlobalShadows
local baseTerrainDecoration = terrain and terrain.Decoration

local postEffects = {}
for _, effect in ipairs(Lighting:GetChildren()) do
	if effect:IsA("BloomEffect") or effect:IsA("SunRaysEffect") or effect:IsA("ColorCorrectionEffect") then
		postEffects[effect] = effect.Enabled
	end
end

local atmospheres = {}
for _, atm in ipairs(Lighting:GetChildren()) do
	if atm:IsA("Atmosphere") then
		atmospheres[atm] = {
			Density = atm.Density,
			Haze = atm.Haze,
		}
	end
end

local qualityWasApplied = false

local function setQualityLevel(level)
	pcall(function()
		settings().Rendering.QualityLevel = level
		qualityWasApplied = true
	end)
end

local function restoreQualityLevel()
	if not qualityWasApplied then
		return
	end
	pcall(function()
		settings().Rendering.QualityLevel = 0
	end)
end

local function setSetting(key, value)
	player:SetAttribute(SETTINGS_PREFIX .. key, value)
end

local function restoreBaseSettings()
	for _, key in ipairs(TRACKED_SETTING_KEYS) do
		setSetting(key, baseSettings[key])
	end

	player:SetAttribute("GuestModelsVisible", baseGuestModelsVisible)
	player:SetAttribute("GuestLODEnabled", baseGuestLODEnabled)
	player:SetAttribute("ParticlesEnabled", baseParticlesEnabled)

	Lighting.GlobalShadows = baseGlobalShadows
	if terrain and baseTerrainDecoration ~= nil then
		terrain.Decoration = baseTerrainDecoration
	end

	for effect, enabled in pairs(postEffects) do
		if effect and effect.Parent then
			effect.Enabled = enabled
		end
	end

	for atm, values in pairs(atmospheres) do
		if atm and atm.Parent then
			atm.Density = values.Density
			atm.Haze = values.Haze
		end
	end

	restoreQualityLevel()
end

local function applyLevel(level)
	if level <= 0 then
		restoreBaseSettings()
		return
	end

	setSetting("GraphicsPreset", "Low")
	setSetting("BuildingRenderDistance", "Near")
	setSetting("LiftRenderDistance", "Near")
	setSetting("NPCRenderDistance", "Near")
	setSetting("WeatherQuality", "Low")
	setSetting("ParticleQuality", "Low")
	setSetting("ParticleDensity", "Low")
	setSetting("RealisticParticles", false)
	setSetting("AdaptiveParticles", true)
	setSetting("FogEdgeBlend", false)
	setSetting("FogEdgeIntensity", "Low")

	player:SetAttribute("GuestLODEnabled", true)
	player:SetAttribute("GuestModelsVisible", level < 3)
	player:SetAttribute("ParticlesEnabled", level < 2)

	Lighting.GlobalShadows = false
	if terrain then
		terrain.Decoration = false
	end

	for effect in pairs(postEffects) do
		if effect and effect.Parent then
			effect.Enabled = (level < 2)
		end
	end

	for atm in pairs(atmospheres) do
		if atm and atm.Parent then
			if level >= 2 then
				atm.Density = 0
				atm.Haze = 0
			else
				local values = atmospheres[atm]
				atm.Density = values and values.Density or atm.Density
				atm.Haze = values and values.Haze or atm.Haze
			end
		end
	end

	if level == 1 then
		setQualityLevel(3)
	elseif level == 2 then
		setQualityLevel(2)
	else
		setQualityLevel(1)
	end
end

local currentLevel = 0
local emaFps = 60
local lowTimer = 0
local highTimer = 0
local lastLevelChangeAt = os.clock()

local DOWN_THRESHOLDS = {57, 50, 42}
local DOWN_DURATIONS = {2.8, 2.2, 1.8}
local UP_THRESHOLDS = {nil, 62, 58, 52}
local UP_DURATIONS = {nil, 14, 16, 18}
local MIN_LEVEL_HOLD_SECONDS = 8

player:SetAttribute("Runtime_PerfGovernorLevel", currentLevel)

RunService.RenderStepped:Connect(function(dt)
	if dt <= 0 then
		return
	end

	if player:GetAttribute("DisableRuntimePerfGovernor") == true then
		if currentLevel ~= 0 then
			currentLevel = 0
			applyLevel(0)
			player:SetAttribute("Runtime_PerfGovernorLevel", 0)
		end
		return
	end

	local fps = math.clamp(1 / dt, 1, 240)
	emaFps = emaFps + ((fps - emaFps) * 0.09)

	local downThreshold = DOWN_THRESHOLDS[currentLevel + 1]
	if downThreshold and emaFps < downThreshold then
		lowTimer += dt
	else
		lowTimer = math.max(0, lowTimer - (dt * 0.75))
	end

	local upThreshold = UP_THRESHOLDS[currentLevel + 1]
	if upThreshold and emaFps > upThreshold then
		highTimer += dt
	else
		highTimer = math.max(0, highTimer - (dt * 0.5))
	end

	local now = os.clock()
	if now - lastLevelChangeAt < MIN_LEVEL_HOLD_SECONDS then
		return
	end

	if downThreshold and lowTimer >= (DOWN_DURATIONS[currentLevel + 1] or 2.5) and currentLevel < 3 then
		currentLevel += 1
		lowTimer = 0
		highTimer = 0
		lastLevelChangeAt = now
		applyLevel(currentLevel)
		player:SetAttribute("Runtime_PerfGovernorLevel", currentLevel)
		return
	end

	if currentLevel > 0 and upThreshold and highTimer >= (UP_DURATIONS[currentLevel + 1] or 15) then
		currentLevel -= 1
		lowTimer = 0
		highTimer = 0
		lastLevelChangeAt = now
		applyLevel(currentLevel)
		player:SetAttribute("Runtime_PerfGovernorLevel", currentLevel)
	end
end)
