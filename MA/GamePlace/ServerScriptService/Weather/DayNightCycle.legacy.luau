--[[
	☀️ DAY/NIGHT CYCLE V5.2 (Moonlight & Shadows Update)
	ServerScriptService/DayNightCycle
]]

local Lighting = game:GetService("Lighting")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

-- // POST-PROCESSING SETUP //
local gameBloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect", Lighting)
local gameColorMod = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect", Lighting)
local gameDoF = Lighting:FindFirstChildOfClass("DepthOfFieldEffect") or Instance.new("DepthOfFieldEffect", Lighting)

-- // CONFIGURATION //
local CONFIG = {
	StartHour = 8,
	-- Slower resort pacing. A full in-game day now takes roughly 25 real minutes.
	DaySpeed = 24 / 1800,
	NightSpeed = 24 / 1200,

	OpenHour = 6,
	CloseHour = 19,

	-- Lighting & Ambient (Lightened up the night so it's not a pitch-black void)
	DayAmbient = Color3.fromRGB(100, 100, 100),
	DayOutdoorAmbient = Color3.fromRGB(130, 130, 130),

	NightAmbient = Color3.fromRGB(82, 88, 100), -- Keep nights readable without crushing the whole map into gray shadows
	NightOutdoorAmbient = Color3.fromRGB(70, 76, 88),

	-- PBR Reflections
	DayDiffuse = 1,
	DaySpecular = 1,

	NightDiffuse = 0.55,
	NightSpecular = 1.05,

	-- Brightness & Exposure (THE FIX: Brightness > 0 creates moon shadows!)
	DayBrightness = 2,
	NightBrightness = 1.45,

	DayExposure = 0,
	NightExposure = -0.01,

	-- Post-Processing: Bloom
	DayBloomIntensity = 0.1,
	DayBloomThreshold = 2,

	NightBloomIntensity = 0.14,
	NightBloomThreshold = 1.8,

	-- Post-Processing: Depth of Field
	DayDoFIntensity = 0,
	NightDoFIntensity = 0.02,
	NightDoFFocusDistance = 150,
	NightDoFInFocusRadius = 50,

	-- Post-Processing: Color Correction
	DayContrast = 0,
	NightContrast = 0.03,
	DaySaturation = 0.02,
	NightSaturation = 0.06,
	DayColorBrightness = 0,
	NightColorBrightness = 0.015,
	DayTintColor = Color3.fromRGB(255, 255, 255),
	NightTintColor = Color3.fromRGB(236, 244, 255),

	-- Atmosphere & Subtle Haze
	DayAtmoColor = Color3.fromRGB(199, 199, 199),
	DayAtmoDecay = Color3.fromRGB(106, 112, 125),
	DayAtmoDensity = 0.25,
	DayAtmoHaze = 0,

	NightAtmoColor = Color3.fromRGB(120, 132, 152),
	NightAtmoDecay = Color3.fromRGB(88, 96, 110),
	NightAtmoDensity = 0.18,
	NightAtmoHaze = 0.52,
	DayAtmoGlare = 0,
	NightAtmoGlare = 0.07,
	DayAtmoOffset = 0,
	NightAtmoOffset = 0.08,
}

-- // STATE //
local function NormalizeDay(dayValue)
	return math.max(1, math.floor(tonumber(dayValue) or 1))
end

local InternalTime = CONFIG.StartHour
local CurrentDay = NormalizeDay(Lighting:GetAttribute("Day"))
local gameAtmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

local daySky = Lighting:FindFirstChildOfClass("Sky")
local nightSky = ServerStorage:FindFirstChild("Night")
local isCurrentlyNight = false

if nightSky then
	nightSky.StarCount = 5000 
	nightSky.MoonAngularSize = 15
end

Lighting.ClockTime = InternalTime
Lighting:SetAttribute("Day", CurrentDay)
Lighting:GetAttributeChangedSignal("Day"):Connect(function()
	local syncedDay = NormalizeDay(Lighting:GetAttribute("Day"))
	if syncedDay ~= CurrentDay then
		CurrentDay = syncedDay
	end
	if Lighting:GetAttribute("Day") ~= syncedDay then
		Lighting:SetAttribute("Day", syncedDay)
	end
end)

-- // TRUE DARKNESS LOGIC //
local function getDarknessAlpha(time)
	local sunriseStart = CONFIG.OpenHour - 1 
	local sunsetStart = CONFIG.CloseHour - 1

	if time > CONFIG.OpenHour and time < sunsetStart then
		return 0
	elseif time >= sunsetStart and time <= CONFIG.CloseHour then
		return (time - sunsetStart) / (CONFIG.CloseHour - sunsetStart)
	elseif time > CONFIG.CloseHour or time < sunriseStart then
		return 1
	elseif time >= sunriseStart and time <= CONFIG.OpenHour then
		return 1 - ((time - sunriseStart) / (CONFIG.OpenHour - sunriseStart))
	end
	return 0
end

local function UpdateTrueDarkness(time)
	local alpha = getDarknessAlpha(time)

	local shouldBeNight = (alpha > 0.5)
	if shouldBeNight ~= isCurrentlyNight then
		isCurrentlyNight = shouldBeNight
		if isCurrentlyNight then
			if daySky then daySky.Parent = ServerStorage end
			if nightSky then nightSky.Parent = Lighting end
		else
			if nightSky then nightSky.Parent = ServerStorage end
			if daySky then daySky.Parent = Lighting end
		end
	end

	Lighting.Ambient = CONFIG.DayAmbient:Lerp(CONFIG.NightAmbient, alpha)
	Lighting.OutdoorAmbient = CONFIG.DayOutdoorAmbient:Lerp(CONFIG.NightOutdoorAmbient, alpha)
	Lighting.EnvironmentDiffuseScale = CONFIG.DayDiffuse + ((CONFIG.NightDiffuse - CONFIG.DayDiffuse) * alpha)
	Lighting.EnvironmentSpecularScale = CONFIG.DaySpecular + ((CONFIG.NightSpecular - CONFIG.DaySpecular) * alpha)

	Lighting.Brightness = CONFIG.DayBrightness + ((CONFIG.NightBrightness - CONFIG.DayBrightness) * alpha)
	Lighting.ExposureCompensation = CONFIG.DayExposure + ((CONFIG.NightExposure - CONFIG.DayExposure) * alpha)

	gameBloom.Intensity = CONFIG.DayBloomIntensity + ((CONFIG.NightBloomIntensity - CONFIG.DayBloomIntensity) * alpha)
	gameBloom.Threshold = CONFIG.DayBloomThreshold + ((CONFIG.NightBloomThreshold - CONFIG.DayBloomThreshold) * alpha)
	gameColorMod.Contrast = CONFIG.DayContrast + ((CONFIG.NightContrast - CONFIG.DayContrast) * alpha)
	gameColorMod.Saturation = CONFIG.DaySaturation + ((CONFIG.NightSaturation - CONFIG.DaySaturation) * alpha)
	gameColorMod.Brightness = CONFIG.DayColorBrightness + ((CONFIG.NightColorBrightness - CONFIG.DayColorBrightness) * alpha)
	gameColorMod.TintColor = CONFIG.DayTintColor:Lerp(CONFIG.NightTintColor, alpha)

	gameDoF.FarIntensity = CONFIG.DayDoFIntensity + ((CONFIG.NightDoFIntensity - CONFIG.DayDoFIntensity) * alpha)
	gameDoF.FocusDistance = CONFIG.NightDoFFocusDistance
	gameDoF.InFocusRadius = CONFIG.NightDoFInFocusRadius

	if gameAtmosphere then
		gameAtmosphere.Color = CONFIG.DayAtmoColor:Lerp(CONFIG.NightAtmoColor, alpha)
		gameAtmosphere.Decay = CONFIG.DayAtmoDecay:Lerp(CONFIG.NightAtmoDecay, alpha)
		gameAtmosphere.Density = CONFIG.DayAtmoDensity + ((CONFIG.NightAtmoDensity - CONFIG.DayAtmoDensity) * alpha)
		gameAtmosphere.Haze = CONFIG.DayAtmoHaze + ((CONFIG.NightAtmoHaze - CONFIG.DayAtmoHaze) * alpha)
		gameAtmosphere.Glare = CONFIG.DayAtmoGlare + ((CONFIG.NightAtmoGlare - CONFIG.DayAtmoGlare) * alpha)
		gameAtmosphere.Offset = CONFIG.DayAtmoOffset + ((CONFIG.NightAtmoOffset - CONFIG.DayAtmoOffset) * alpha)
	end
end

local function NormalizeClockTime(hour)
	hour = tonumber(hour) or CONFIG.StartHour
	hour = hour % 24
	if hour < 0 then
		hour += 24
	end
	return hour
end

-- // LOOP //
RunService.Heartbeat:Connect(function(dt)
	if math.abs(Lighting.ClockTime - InternalTime) > 0.1 then
		if math.abs(Lighting.ClockTime - InternalTime) < 23 then
			InternalTime = NormalizeClockTime(Lighting.ClockTime)
		end
	end

	local sandboxMultiplier = tonumber(_G.SandboxTimeMultiplier)
	if sandboxMultiplier == 0 then
		Lighting.ClockTime = NormalizeClockTime(InternalTime)
		UpdateTrueDarkness(InternalTime)
		return
	end

	if Lighting:GetAttribute("ManualTime") == true then
		InternalTime = NormalizeClockTime(Lighting.ClockTime)
		UpdateTrueDarkness(InternalTime)
		return
	end

	local speed = CONFIG.DaySpeed
	if InternalTime < CONFIG.OpenHour or InternalTime >= CONFIG.CloseHour then
		speed = CONFIG.NightSpeed
	end
	if sandboxMultiplier and sandboxMultiplier > 0 then
		speed *= sandboxMultiplier
	end

	InternalTime = InternalTime + (speed * dt)

	if InternalTime >= 24 then
		InternalTime = InternalTime - 24
		CurrentDay = CurrentDay + 1
		Lighting:SetAttribute("Day", CurrentDay)
	end

	Lighting.ClockTime = InternalTime
	UpdateTrueDarkness(InternalTime)
end)

UpdateTrueDarkness(InternalTime)