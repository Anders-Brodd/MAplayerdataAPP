local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local STORE = DataStoreService:GetDataStore("AdminWalkSpeed_V1")
local ATTRIBUTE_NAME = "AdminWalkSpeed"

local CONFIG = {
	DEFAULT_WALKSPEED = 16,
	MIN_WALKSPEED = 1,
	MAX_WALKSPEED = 5000,
}

local function getStoreKey(player)
	return string.format("user_%d", player.UserId)
end

local function normalizeSpeed(value)
	local speed = tonumber(value)
	if not speed then
		return nil
	end
	speed = math.clamp(math.floor(speed + 0.5), CONFIG.MIN_WALKSPEED, CONFIG.MAX_WALKSPEED)
	if speed == CONFIG.DEFAULT_WALKSPEED then
		return nil
	end
	return speed
end

local function isAdmin(player)
	return player ~= nil
end

local function applyToHumanoid(player, speed)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed or CONFIG.DEFAULT_WALKSPEED
	end
end

local function saveSpeed(player, speed)
	task.spawn(function()
		local ok, err = pcall(function()
			if speed then
				STORE:SetAsync(getStoreKey(player), speed)
			else
				STORE:RemoveAsync(getStoreKey(player))
			end
		end)
		if not ok then
			warn(string.format("[AdminWalkSpeedPersistence] Failed to save for %s: %s", player.Name, tostring(err)))
		end
	end)
end

local function applyWalkSpeed(player, speed, shouldSave)
	local normalized = normalizeSpeed(speed)
	player:SetAttribute(ATTRIBUTE_NAME, normalized)
	applyToHumanoid(player, normalized)
	if shouldSave then
		saveSpeed(player, normalized)
	end
end

local function parseCommand(message)
	if type(message) ~= "string" then
		return nil
	end
	local normalized = string.lower(message):gsub("^%s+", ""):gsub("%s+$", "")
	local command, value = normalized:match("^/(%S+)%s*(.-)%s*$")
	if command ~= "ws" and command ~= "walkspeed" then
		return nil
	end
	if value == "" then
		return false
	end
	if value == "default" or value == "reset" then
		return true, CONFIG.DEFAULT_WALKSPEED
	end
	local numeric = tonumber(value)
	if not numeric then
		return false
	end
	return true, numeric
end

local function loadSavedSpeed(player)
	if not player then
		return
	end
	local ok, saved = pcall(function()
		return STORE:GetAsync(getStoreKey(player))
	end)
	if not ok then
		warn(string.format("[AdminWalkSpeedPersistence] Failed to load for %s: %s", player.Name, tostring(saved)))
		return
	end
	local normalized = normalizeSpeed(saved)
	if normalized then
		player:SetAttribute(ATTRIBUTE_NAME, normalized)
		applyToHumanoid(player, normalized)
	end
end

local function hookPlayer(player)
	loadSavedSpeed(player)

	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		local desired = normalizeSpeed(player:GetAttribute(ATTRIBUTE_NAME))
		if desired then
			applyToHumanoid(player, desired)
		end
	end)

	player.Chatted:Connect(function(message)
		if not player then
			return
		end
		local ok, speed = parseCommand(message)
		if ok == nil or ok == false then
			return
		end
		applyWalkSpeed(player, speed, true)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(hookPlayer, player)
end

Players.PlayerAdded:Connect(hookPlayer)
