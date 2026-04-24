local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UPDATE_INTERVAL = 0.75
local LIGHT_ATTR_PREFIX = "NightVisualBase_"
local LIGHT_CLASSES = {
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
}
local trackedLights = setmetatable({}, { __mode = "k" })

local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
local colorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")

local baseLighting = {
	Brightness = Lighting.Brightness,
	ExposureCompensation = Lighting.ExposureCompensation,
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
	EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
	ShadowSoftness = Lighting.ShadowSoftness,
}

local baseBloom = bloom and {
	Intensity = bloom.Intensity,
	Size = bloom.Size,
	Threshold = bloom.Threshold,
} or nil

local baseColorCorrection = colorCorrection and {
	Brightness = colorCorrection.Brightness,
	Contrast = colorCorrection.Contrast,
	Saturation = colorCorrection.Saturation,
	TintColor = colorCorrection.TintColor,
} or nil

local baseAtmosphere = atmosphere and {
	Density = atmosphere.Density,
	Offset = atmosphere.Offset,
	Glare = atmosphere.Glare,
	Haze = atmosphere.Haze,
	Color = atmosphere.Color,
	Decay = atmosphere.Decay,
} or nil

local baseSunRays = sunRays and {
	Intensity = sunRays.Intensity,
	Spread = sunRays.Spread,
} or nil

local function lerpNumber(a, b, t)
	return a + (b - a) * t
end

local function lerpColor(a, b, t)
	return Color3.new(
		lerpNumber(a.R, b.R, t),
		lerpNumber(a.G, b.G, t),
		lerpNumber(a.B, b.B, t)
	)
end

local function clamp01(value)
	return math.clamp(value, 0, 1)
end

local function getNightBlend(clockTime)
	if clockTime >= 20.25 or clockTime <= 5.25 then
		return 1
	end
	if clockTime >= 17.75 and clockTime < 20.25 then
		return clamp01((clockTime - 17.75) / 2.5)
	end
	if clockTime > 5.25 and clockTime <= 7.25 then
		return clamp01(1 - ((clockTime - 5.25) / 2.0))
	end
	return 0
end

local function getGlowBlend(clockTime)
	if clockTime >= 21.0 or clockTime <= 4.75 then
		return 1
	end
	if clockTime >= 18.5 and clockTime < 21.0 then
		return clamp01((clockTime - 18.5) / 2.5)
	end
	if clockTime > 4.75 and clockTime <= 6.75 then
		return clamp01(1 - ((clockTime - 4.75) / 2.0))
	end
	return 0
end

local function captureLightBase(light)
	if not LIGHT_CLASSES[light.ClassName] then
		return
	end
	if light:GetAttribute(LIGHT_ATTR_PREFIX .. "Captured") then
		return
	end
	light:SetAttribute(LIGHT_ATTR_PREFIX .. "Captured", true)
	light:SetAttribute(LIGHT_ATTR_PREFIX .. "Brightness", light.Brightness)
	light:SetAttribute(LIGHT_ATTR_PREFIX .. "Range", light.Range)
	if light:IsA("SpotLight") then
		light:SetAttribute(LIGHT_ATTR_PREFIX .. "Angle", light.Angle)
	end
end

local function applyLightNightBoost(light, glowBlend)
	if not LIGHT_CLASSES[light.ClassName] then
		return
	end
	captureLightBase(light)

	local baseBrightness = light:GetAttribute(LIGHT_ATTR_PREFIX .. "Brightness") or light.Brightness
	local baseRange = light:GetAttribute(LIGHT_ATTR_PREFIX .. "Range") or light.Range
	light.Brightness = lerpNumber(baseBrightness, baseBrightness * 1.85 + 0.4, glowBlend)
	light.Range = lerpNumber(baseRange, baseRange * 1.2 + 2, glowBlend)

	if light:IsA("SpotLight") then
		local baseAngle = light:GetAttribute(LIGHT_ATTR_PREFIX .. "Angle") or light.Angle
		light.Angle = lerpNumber(baseAngle, math.min(140, baseAngle + 10), glowBlend)
	end
end

local function trackLight(inst)
	if not inst or not LIGHT_CLASSES[inst.ClassName] then
		return
	end
	captureLightBase(inst)
	trackedLights[inst] = true
end

local function untrackLight(inst)
	trackedLights[inst] = nil
end

for _, inst in ipairs(Workspace:GetDescendants()) do
	trackLight(inst)
end

Workspace.DescendantAdded:Connect(trackLight)
Workspace.DescendantRemoving:Connect(untrackLight)

local lastBlend = -1
local lastGlowBlend = -1
local elapsed = 0

local function applyNightLook()
	local clockTime = Lighting.ClockTime
	local nightBlend = getNightBlend(clockTime)
	local glowBlend = getGlowBlend(clockTime)

	if math.abs(nightBlend - lastBlend) < 0.01 and math.abs(glowBlend - lastGlowBlend) < 0.01 then
		return
	end

	lastBlend = nightBlend
	lastGlowBlend = glowBlend

	for inst in pairs(trackedLights) do
		if inst and inst.Parent and inst.Enabled then
			applyLightNightBoost(inst, glowBlend)
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	elapsed += dt
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0
	applyNightLook()
end)

applyNightLook()