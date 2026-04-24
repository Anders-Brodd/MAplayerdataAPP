--[[
	TEMP HUD CONTROLLER V3.2
	StarterPlayerScripts/TempHUD
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")

local TimeWeatherFrame = MainHUD:WaitForChild("TimeWeather")
local TimeContainer = TimeWeatherFrame:WaitForChild("Time")

local TimeLabel = TimeContainer:WaitForChild("Time")
local WeatherLabel = TimeContainer:WaitForChild("Weather")
local SeasonLabel = TimeContainer:WaitForChild("Season")
local TempLabel = TimeContainer:WaitForChild("Temp")

local SETTINGS_ATTR_PREFIX = "Settings_"

local SEASON_COLORS = {
	Spring = Color3.fromRGB(120, 255, 120),
	Summer = Color3.fromRGB(255, 220, 100),
	Autumn = Color3.fromRGB(255, 160, 80),
	Winter = Color3.fromRGB(150, 220, 255),
}

local function isMetricUnits()
	local unitSystem = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. "UnitSystem")
	return type(unitSystem) == "string" and string.lower(unitSystem) == "metric"
end

local function formatClockTime(clockTime)
	local hours = math.floor(clockTime) % 24
	local minutes = math.floor((clockTime - math.floor(clockTime)) * 60 + 0.5) % 60
	if isMetricUnits() then
		return string.format("%02d:%02d", hours, minutes)
	end
	local ampm = hours >= 12 and "PM" or "AM"
	local displayHour = hours % 12
	if displayHour == 0 then
		displayHour = 12
	end
	return string.format("%d:%02d %s", displayHour, minutes, ampm)
end

local function formatTemperature(tempF)
	if isMetricUnits() then
		local tempC = math.floor(((tempF - 32) * (5 / 9)) + 0.5)
		return string.format("%d°C", tempC)
	end
	return string.format("%d°F", math.floor(tempF + 0.5))
end

local function updateHUD()
	local season = Lighting:GetAttribute("Season") or "Winter"
	local weather = Lighting:GetAttribute("Weather") or "Clear"
	local temp = tonumber(Lighting:GetAttribute("Temperature")) or 32
	local clockTime = Lighting.ClockTime

	TimeLabel.Text = formatClockTime(clockTime)
	WeatherLabel.Text = string.upper(weather)
	SeasonLabel.Text = string.upper(season)
	SeasonLabel.TextColor3 = SEASON_COLORS[season] or Color3.new(1, 1, 1)
	TempLabel.Text = formatTemperature(temp)

	if temp <= 32 then
		TempLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
	elseif temp > 80 then
		TempLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
	else
		TempLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

Lighting.AttributeChanged:Connect(function(attr)
	if attr == "Season" or attr == "Day" or attr == "Temperature" or attr == "Weather" then
		updateHUD()
	end
end)

Lighting:GetPropertyChangedSignal("ClockTime"):Connect(updateHUD)
Player:GetAttributeChangedSignal(SETTINGS_ATTR_PREFIX .. "UnitSystem"):Connect(updateHUD)

task.wait(1)
updateHUD()

print("TempHUD Online")