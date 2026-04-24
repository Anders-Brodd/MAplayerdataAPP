local GraphicsProfile = {}

local SETTINGS_PREFIX = "Settings_"

local MAX_RUNTIME_PERF_TIER = 3
local RUNTIME_PERF_DISTANCE_SCALE = {1.0, 0.82, 0.62, 0.46}
local RUNTIME_PERF_PARTICLE_SCALE = {1.0, 0.78, 0.52, 0.32}
local RUNTIME_PERF_WEATHER_SCALE = {1.0, 0.85, 0.55, 0.35}

local PRESET_SCALE = {
	Low = 0.52,
	Medium = 0.74,
	High = 1.0,
	Ultra = 1.15,
}

local DISTANCE_SCALE = {
	Near = 0.24,
	Medium = 0.58,
	Far = 1.0,
	Off = 1.0,
}

local WEATHER_SCALE = {
	Low = 0.45,
	Medium = 0.75,
	High = 1.0,
	Ultra = 1.3,
}

local PARTICLE_SCALE = {
	Low = 0.4,
	Medium = 0.7,
	High = 1.0,
	Ultra = 1.25,
}

local PARTICLE_DENSITY_SCALE = {
	Low = 0.45,
	Medium = 0.75,
	High = 1.0,
	Ultra = 1.25,
}

local FOG_START_RATIO = {
	Low = 0.35,
	Medium = 0.55,
	High = 0.72,
}

local FOG_END_SCALE = {
	Low = 1.35,
	Medium = 1.0,
	High = 0.6,
}

local function normalizeChoice(value, allowed, defaultValue)
	if type(value) ~= "string" then
		return defaultValue
	end
	for _, allowedValue in ipairs(allowed) do
		if value == allowedValue then
			return value
		end
	end
	return defaultValue
end

local function getSetting(player, key)
	if not player then
		return nil
	end
	return player:GetAttribute(SETTINGS_PREFIX .. key)
end

local function getRuntimePerfTier(player)
	local rawTier = tonumber(getSetting(player, "RuntimePerfTier"))
	if rawTier == nil then
		return 0
	end
	return math.clamp(math.floor(rawTier + 0.5), 0, MAX_RUNTIME_PERF_TIER)
end

function GraphicsProfile.GetPreset(player)
	local preset = normalizeChoice(getSetting(player, "GraphicsPreset"), {"Low", "Medium", "High", "Ultra"}, "Medium")
	local runtimeTier = getRuntimePerfTier(player)
	if runtimeTier >= 2 then
		return "Low"
	end
	if runtimeTier == 1 and preset == "Ultra" then
		return "High"
	end
	return preset
end

function GraphicsProfile.GetPresetScale(player)
	return PRESET_SCALE[GraphicsProfile.GetPreset(player)] or 1.0
end

function GraphicsProfile.GetDistanceChoice(player, key)
	if key == "LiftRenderDistance" or key == "BuildingRenderDistance" or key == "NPCRenderDistance" then
		return normalizeChoice(getSetting(player, key), {"Near", "Medium", "Far", "Off"}, "Medium")
	end
	return normalizeChoice(getSetting(player, key), {"Near", "Medium", "Far"}, "Medium")
end

function GraphicsProfile.GetDistanceScale(player, key)
	local distance = GraphicsProfile.GetDistanceChoice(player, key)
	if distance == "Off" then
		-- Disable distance culling/throttling for this category.
		return 1000000
	end
	local distanceScale = DISTANCE_SCALE[distance] or 1.0
	local runtimeTier = getRuntimePerfTier(player)
	local runtimeScale = RUNTIME_PERF_DISTANCE_SCALE[runtimeTier + 1] or 1.0
	return distanceScale * GraphicsProfile.GetPresetScale(player) * runtimeScale
end

function GraphicsProfile.GetWeatherQuality(player)
	return normalizeChoice(getSetting(player, "WeatherQuality"), {"Low", "Medium", "High", "Ultra"}, "High")
end

function GraphicsProfile.GetWeatherScale(player)
	local runtimeTier = getRuntimePerfTier(player)
	local runtimeScale = RUNTIME_PERF_WEATHER_SCALE[runtimeTier + 1] or 1.0
	return (WEATHER_SCALE[GraphicsProfile.GetWeatherQuality(player)] or 1.0) * runtimeScale
end

function GraphicsProfile.GetParticleQuality(player)
	return normalizeChoice(getSetting(player, "ParticleQuality"), {"Low", "Medium", "High", "Ultra"}, "High")
end

function GraphicsProfile.GetParticleScale(player)
	local runtimeTier = getRuntimePerfTier(player)
	local runtimeScale = RUNTIME_PERF_PARTICLE_SCALE[runtimeTier + 1] or 1.0
	return (PARTICLE_SCALE[GraphicsProfile.GetParticleQuality(player)] or 1.0) * runtimeScale
end

function GraphicsProfile.GetParticleDensity(player)
	return normalizeChoice(getSetting(player, "ParticleDensity"), {"Low", "Medium", "High", "Ultra"}, "Medium")
end

function GraphicsProfile.GetParticleDensityScale(player)
	return PARTICLE_DENSITY_SCALE[GraphicsProfile.GetParticleDensity(player)] or 1.0
end

function GraphicsProfile.IsRealisticParticlesEnabled(player)
	local runtimeTier = getRuntimePerfTier(player)
	if runtimeTier >= 2 then
		return false
	end
	local value = getSetting(player, "RealisticParticles")
	if type(value) == "boolean" then
		return value
	end
	return true
end

function GraphicsProfile.IsAdaptiveParticlesEnabled(player)
	local runtimeTier = getRuntimePerfTier(player)
	if runtimeTier >= 1 then
		return true
	end
	local value = getSetting(player, "AdaptiveParticles")
	if type(value) == "boolean" then
		return value
	end
	return true
end

function GraphicsProfile.IsFogEdgeBlendEnabled(player)
	local runtimeTier = getRuntimePerfTier(player)
	if runtimeTier >= 2 then
		return false
	end
	local value = getSetting(player, "FogEdgeBlend")
	if type(value) == "boolean" then
		return value
	end
	return true
end

function GraphicsProfile.GetFogEdgeIntensity(player)
	return normalizeChoice(getSetting(player, "FogEdgeIntensity"), {"Low", "Medium", "High"}, "Medium")
end

function GraphicsProfile.GetFogStartRatio(player)
	return FOG_START_RATIO[GraphicsProfile.GetFogEdgeIntensity(player)] or 0.55
end

function GraphicsProfile.GetFogEndScale(player)
	return FOG_END_SCALE[GraphicsProfile.GetFogEdgeIntensity(player)] or 1.0
end

return GraphicsProfile
