-- Script Description:
-- Validates manual Weather Controller overrides from CalendarFrame and applies them securely.
-- A single Weather Controller entitlement now governs season, weather, and time changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Remote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("AdminWeatherUpdate")

local EntitlementManager = nil
local entitlementModule = ReplicatedStorage:FindFirstChild("EntitlementManager")
if entitlementModule then
	local ok, result = pcall(require, entitlementModule)
	if ok then
		EntitlementManager = result
	else
	end
end

local WEATHER_CONTROLLER_PASS = 1707796502

local OwnershipCache = {}
local VALID_SEASONS = {
	Spring = true,
	Summer = true,
	Autumn = true,
	Fall = true,
	Winter = true,
}
local VALID_WEATHER = {
	Clear = true,
	PartlyCloudy = true,
	Overcast = true,
	LightSnow = true,
	HeavySnow = true,
	Blizzard = true,
}

local function hasPass(player, passId)
	if RunService:IsStudio() then
		return true
	end

	if EntitlementManager and EntitlementManager.HasAccess then
		local ok, result = pcall(function()
			return EntitlementManager.HasAccess(player, passId)
		end)
		if ok then
			return result == true
		end
	end

	local userId = player.UserId
	if OwnershipCache[userId] and OwnershipCache[userId][passId] then
		return true
	end

	local owns = false
	local success = pcall(function()
		owns = MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end)

	if success and owns then
		OwnershipCache[userId] = OwnershipCache[userId] or {}
		OwnershipCache[userId][passId] = true
	end

	return owns
end

local function normalizeSeasonName(value)
	if value == "Fall" then
		return "Autumn"
	end
	return value
end

local function normalizeClockTime(value)
	local hour = tonumber(value)
	if not hour then
		return nil
	end
	hour = hour % 24
	if hour < 0 then
		hour += 24
	end
	return hour
end

Remote.OnServerEvent:Connect(function(player, actionType, value)
	if actionType ~= "Season" and actionType ~= "Weather" and actionType ~= "Time" then
		return
	end

	if not hasPass(player, WEATHER_CONTROLLER_PASS) then
		return
	end

	if actionType == "Season" then
		local normalizedValue = normalizeSeasonName(tostring(value))
		if not VALID_SEASONS[normalizedValue] then
			return
		end
		Lighting:SetAttribute("ManualWeather", false)
		Lighting:SetAttribute("ManualTemp", false)
		Lighting:SetAttribute("Season", normalizedValue)
		Lighting:SetAttribute("Day", 1)
		return
	end

	if actionType == "Weather" then
		local weatherValue = tostring(value)
		if not VALID_WEATHER[weatherValue] then
			return
		end
		Lighting:SetAttribute("ManualWeather", true)
		Lighting:SetAttribute("ManualTemp", false)
		Lighting:SetAttribute("Weather", weatherValue)
		return
	end

	local hour = normalizeClockTime(value)
	if hour == nil then
		return
	end

	Lighting:SetAttribute("ManualTime", true)
	Lighting.ClockTime = hour
end)
