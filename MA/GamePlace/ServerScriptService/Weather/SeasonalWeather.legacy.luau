--[[
	📅 SEASONAL WEATHER SYSTEM V8.0 (Manual Override Fix)
	ServerScriptService/SeasonalWeather
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CONFIG = {
	DaysPerSeason = 3,
	StartingSeason = "Winter",

	BaseTemps = {
		Spring = 50, Summer = 85, Autumn = 45, Fall = 45, Winter = 15
	},
	Seasons = {
		Spring = { SnowChance = 15, FogColor = Color3.fromRGB(190, 200, 210) },
		Summer = { SnowChance = 0,  FogColor = Color3.fromRGB(255, 255, 220) },
		Autumn = { SnowChance = 20, FogColor = Color3.fromRGB(210, 200, 190) },
		Fall = { SnowChance = 20, FogColor = Color3.fromRGB(210, 200, 190) },
		Winter = { SnowChance = 60, FogColor = Color3.fromRGB(200, 210, 255) }
	}
}

local function NormalizeSeasonName(season)
	if season == "Fall" then
		return "Autumn"
	end
	if CONFIG.Seasons[season] then
		return season
	end
	return CONFIG.StartingSeason
end

-- State
-- PATCHED: Always start with CONFIG.StartingSeason (Winter). The Lighting attribute
-- may have a stale value baked into the place file from a previous session.
-- On fresh saves or new joins, we want Winter, not whatever was last saved.
local CurrentSeason = CONFIG.StartingSeason
local DaysInCurrentSeason = 1
local LastObservedDay = tonumber(Lighting:GetAttribute("Day")) or 1

-- // TEMPERATURE UPDATE //
local function UpdateTemperature()
	-- 🛑 CRITICAL FIX: If ManualTemp is ON, do NOT change the temp.
	if Lighting:GetAttribute("ManualTemp") == true then return end

	local hour = tonumber(Lighting.ClockTime) or 12
	local base = tonumber(CONFIG.BaseTemps[CurrentSeason]) or 30

	-- Temp Fluctuation (Coldest at 3 AM, Hottest at 3 PM)
	local phase = math.cos((hour - 15) / 12 * math.pi)
	local temp = base + (phase * 12)

	-- Drop temp if it's snowing
	if Lighting:GetAttribute("Weather") and string.find(Lighting:GetAttribute("Weather"), "Snow") then
		temp = temp - 5
	end

	local final = math.floor(temp)
	Lighting:SetAttribute("Temperature", final)
	Lighting:SetAttribute("IsFreezing", final <= 32)
end

-- // WEATHER PICKER //
local function PickWeather()
	if Lighting:GetAttribute("ManualTemp") == true then return end
	if Lighting:GetAttribute("ManualWeather") == true then return end

	local data = CONFIG.Seasons[NormalizeSeasonName(CurrentSeason)] or CONFIG.Seasons[CONFIG.StartingSeason]
	local roll = math.random(1, 100)

	if roll <= data.SnowChance then
		-- Pick intensity
		if roll < (data.SnowChance/3) then Lighting:SetAttribute("Weather", "HeavySnow")
		else Lighting:SetAttribute("Weather", "LightSnow") end
	else
		Lighting:SetAttribute("Weather", "Clear")
	end
end

-- // SEASON CHANGE //
local function SetSeason(newSeason)
	CurrentSeason = NormalizeSeasonName(newSeason)
	Lighting:SetAttribute("Season", CurrentSeason)

	-- Reset manual overrides so the new season can drive weather and temperature again.
	Lighting:SetAttribute("ManualTemp", false)
	Lighting:SetAttribute("ManualWeather", false)

	-- Update Fog Visuals
	local col = CONFIG.Seasons[CurrentSeason].FogColor
	TweenService:Create(Lighting, TweenInfo.new(10), {FogColor = col}):Play()

	PickWeather()
end

local function OnNewDay()
	DaysInCurrentSeason = DaysInCurrentSeason + 1
	if DaysInCurrentSeason > CONFIG.DaysPerSeason then
		DaysInCurrentSeason = 1
		local nextSeason = "Spring"
		if CurrentSeason == "Spring" then nextSeason = "Summer"
		elseif CurrentSeason == "Summer" then nextSeason = "Autumn"
		elseif CurrentSeason == "Autumn" then nextSeason = "Winter"
		elseif CurrentSeason == "Winter" then nextSeason = "Spring"
		end
		SetSeason(nextSeason)
	else
		PickWeather()
	end
end

-- // LISTENERS //
Lighting:GetAttributeChangedSignal("Day"):Connect(function()
	local observedDay = tonumber(Lighting:GetAttribute("Day")) or LastObservedDay
	if observedDay == LastObservedDay then
		return
	end
	LastObservedDay = observedDay
	OnNewDay()
end)

-- Detect if Admin changed season manually
Lighting:GetAttributeChangedSignal("Season"):Connect(function()
	local rawSeason = Lighting:GetAttribute("Season")
	local normalizedSeason = NormalizeSeasonName(rawSeason)
	if rawSeason ~= normalizedSeason then
		Lighting:SetAttribute("Season", normalizedSeason)
		return
	end
	if normalizedSeason ~= CurrentSeason then
		CurrentSeason = normalizedSeason
		-- Reset manual overrides so the new season feels right immediately.
		Lighting:SetAttribute("ManualTemp", false)
		Lighting:SetAttribute("ManualWeather", false)
		PickWeather()
	end
end)

-- FORCE season attribute on startup so every system (GuestServer, etc.) reads
-- the correct value immediately, even on brand-new saves where the attribute
-- has never been set before.
Lighting:SetAttribute("Season", CurrentSeason)

RunService.Heartbeat:Connect(UpdateTemperature)
UpdateTemperature()
PickWeather()