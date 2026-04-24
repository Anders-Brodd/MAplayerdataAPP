--[[
	🛠️ NATIVE ADMIN COMMANDS V3.4 (Season Reset Logic)
	ServerScriptService/NativeCommands
]]

local TextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GiveawayAccessModule = nil
local accessModuleScript = ServerScriptService:FindFirstChild("Server") and ServerScriptService.Server:FindFirstChild("GiveawayAccess")
if accessModuleScript and accessModuleScript:IsA("ModuleScript") then
	local ok, result = pcall(require, accessModuleScript)
	if ok then
		GiveawayAccessModule = result
	end
end

-- // 👮 PERMISSIONS //
local GROUP_ID = 398051359
local MIN_RANK = 200
local DEV_PANEL_MIN_RANK = 240
local ADMIN_USERS = { 
	[8843215003] = true, -- AndersBrodd
	[game.CreatorId] = true 
}

local function IsAdmin(player)
	if not player then return false end
	if RunService:IsStudio() then return true end
	if ADMIN_USERS[player.UserId] then return true end

	if GiveawayAccessModule and GiveawayAccessModule.HasAdminAccess then
		local ok, result = pcall(function()
			return GiveawayAccessModule.HasAdminAccess(player.UserId)
		end)
		if ok and result == true then
			return true
		end
	end

	local success, rank = pcall(function() return player:GetRankInGroup(GROUP_ID) end)
	if success and rank and rank >= MIN_RANK then return true end
	return false
end

local function IsDevPanelAdmin(player)
	if not player then return false end
	if RunService:IsStudio() then return true end
	if ADMIN_USERS[player.UserId] then return true end

	if GiveawayAccessModule and GiveawayAccessModule.HasAdminAccess then
		local ok, result = pcall(function()
			return GiveawayAccessModule.HasAdminAccess(player.UserId)
		end)
		if ok and result == true then
			return true
		end
	end

	local success, rank = pcall(function() return player:GetRankInGroup(GROUP_ID) end)
	if success and rank and rank >= DEV_PANEL_MIN_RANK then return true end
	return false
end

-- // ⚙️ COMMAND DATA //
local COMMANDS = {
	{ Name = "SetWeather", Alias = "/weather", Args = {"Clear", "PartlyCloudy", "Overcast", "LightSnow", "HeavySnow", "Blizzard"} },
	{ Name = "SetSeason",  Alias = "/season",  Args = {"Spring", "Summer", "Autumn", "Winter"} },
	{ Name = "SetTime",    Alias = "/time",    Args = {} },
	{ Name = "SetTemp",    Alias = "/temp",    Args = {} },
	{ Name = "ResetWeather",Alias = "/reset",   Args = {} }
}

-- // 🏗️ INIT //
task.wait(2) 
local ChatCommands = TextChatService:FindFirstChild("TextChatCommands")
if not ChatCommands then
	ChatCommands = Instance.new("Folder")
	ChatCommands.Name = "TextChatCommands"
	ChatCommands.Parent = TextChatService
end

-- // 🔧 REGISTER COMMANDS //
for _, cmdData in ipairs(COMMANDS) do
	if ChatCommands:FindFirstChild(cmdData.Name) then ChatCommands[cmdData.Name]:Destroy() end

	local newCmd = Instance.new("TextChatCommand")
	newCmd.Name = cmdData.Name
	newCmd.PrimaryAlias = cmdData.Alias
	newCmd.SecondaryAlias = cmdData.Alias 
	newCmd.Parent = ChatCommands

	newCmd.Triggered:Connect(function(origin, message)
		local player = Players:GetPlayerByUserId(origin.UserId)
		if not IsAdmin(player) then return end

		local args = message:split(" ")
		local arg1 = args[2]

		-- ROUTER
		if cmdData.Name == "SetWeather" then
			for _, w in ipairs(cmdData.Args) do
				if arg1 and w:lower() == arg1:lower() then
					Lighting:SetAttribute("ManualWeather", true)
					Lighting:SetAttribute("ManualTemp", false)
					Lighting:SetAttribute("Weather", w)
					return
				end
			end

		elseif cmdData.Name == "SetSeason" then
			for _, s in ipairs(cmdData.Args) do
				if arg1 and s:lower() == arg1:lower() then
					Lighting:SetAttribute("Season", s)
					Lighting:SetAttribute("Day", 1)
					Lighting:SetAttribute("ManualTemp", false)
					Lighting:SetAttribute("ManualWeather", false)
					return
				end
			end

		elseif cmdData.Name == "SetTime" then
			local val = tonumber(arg1)
			if val then
				Lighting:SetAttribute("ManualTime", true)
				Lighting.ClockTime = val % 24
			end

		elseif cmdData.Name == "SetTemp" then
			local val = tonumber(arg1)
			if val then
				Lighting:SetAttribute("ManualTemp", true)
				Lighting:SetAttribute("Temperature", val)
				Lighting:SetAttribute("IsFreezing", val <= 32)
			end

		elseif cmdData.Name == "ResetWeather" then
			Lighting:SetAttribute("ManualTemp", false)
			Lighting:SetAttribute("ManualWeather", false)
			Lighting:SetAttribute("ManualTime", false)
		end
	end)
end

-- // 🔧 REGISTER /dev COMMAND //
do
	local devPanelEvents = ReplicatedStorage:WaitForChild("DevPanelEvents", 10)
	local toggleRemote = devPanelEvents and devPanelEvents:FindFirstChild("ToggleDevPanel")

	if ChatCommands and toggleRemote then
		if ChatCommands:FindFirstChild("OpenDevPanel") then ChatCommands.OpenDevPanel:Destroy() end

		local devCmd = Instance.new("TextChatCommand")
		devCmd.Name = "OpenDevPanel"
		devCmd.PrimaryAlias = "/dev"
		devCmd.SecondaryAlias = "/devmenu"
		devCmd.Parent = ChatCommands

		devCmd.Triggered:Connect(function(origin)
			local player = Players:GetPlayerByUserId(origin.UserId)
			if not IsDevPanelAdmin(player) then return end
			toggleRemote:FireClient(player)
		end)
	end
end