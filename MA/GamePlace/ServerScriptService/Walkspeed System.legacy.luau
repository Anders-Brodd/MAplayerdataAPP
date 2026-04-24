if true then
	return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ATTRIBUTE_NAME = "AdminWalkSpeed"
local DEFAULT_WALK_SPEED = 16
local MAX_WALK_SPEED = 500

local function isAuthorized(player)
	if RunService:IsStudio() then
		return true
	end

	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end

	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		if ok and rank >= 250 then
			return true
		end
	end

	return false
end

local function applyWalkSpeed(player, speed)
	if speed ~= nil then
		speed = math.clamp(math.floor(speed + 0.5), 1, MAX_WALK_SPEED)
	end

	player:SetAttribute(ATTRIBUTE_NAME, speed)

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed or DEFAULT_WALK_SPEED
	end
end

local function parseCommand(message)
	if type(message) ~= "string" then
		return nil
	end

	local trimmed = string.lower(message):gsub("^%s+", ""):gsub("%s+$", "")
	local command, value = trimmed:match("^/(%S+)%s*(.-)%s*$")
	if not command then
		return nil
	end

	if command ~= "ws" and command ~= "walkspeed" then
		return nil
	end

	if value == "" then
		return false
	end

	if value == "reset" or value == "default" then
		return true, nil
	end

	local numeric = tonumber(value)
	if not numeric then
		return false
	end

	return true, numeric
end

local function hookPlayer(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			local override = player:GetAttribute(ATTRIBUTE_NAME)
			if type(override) == "number" and override > 0 then
				humanoid.WalkSpeed = math.clamp(override, 1, MAX_WALK_SPEED)
			end
		end
	end)

	player.Chatted:Connect(function(message)
		if not isAuthorized(player) then
			return
		end

		local ok, speed = parseCommand(message)
		if ok == nil or ok == false then
			return
		end

		applyWalkSpeed(player, speed)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	hookPlayer(player)
end

Players.PlayerAdded:Connect(hookPlayer)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ATTRIBUTE_NAME = "AdminWalkSpeed"
local DEFAULT_WALK_SPEED = 16
local MAX_WALK_SPEED = 500

local function isAuthorized(player)
	if RunService:IsStudio() then
		return true
	end

	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end

	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		if ok and rank >= 250 then
			return true
		end
	end

	return false
end

local function applyWalkSpeed(player, speed)
	if speed ~= nil then
		speed = math.clamp(math.floor(speed + 0.5), 1, MAX_WALK_SPEED)
	end

	player:SetAttribute(ATTRIBUTE_NAME, speed)

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed or DEFAULT_WALK_SPEED
	end
end

local function parseCommand(message)
	if type(message) ~= "string" then
		return nil
	end

	local trimmed = string.lower(message):gsub("^%s+", ""):gsub("%s+$", "")
	local command, value = trimmed:match("^/(%S+)%s*(.-)%s*$")
	if not command then
		return nil
	end

	if command ~= "ws" and command ~= "walkspeed" then
		return nil
	end

	if value == "" then
		return false
	end

	if value == "reset" or value == "default" then
		return true, nil
	end

	local numeric = tonumber(value)
	if not numeric then
		return false
	end

	return true, numeric
end

local function hookPlayer(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			local override = player:GetAttribute(ATTRIBUTE_NAME)
			if type(override) == "number" and override > 0 then
				humanoid.WalkSpeed = math.clamp(override, 1, MAX_WALK_SPEED)
			end
		end
	end)

	player.Chatted:Connect(function(message)
		if not isAuthorized(player) then
			return
		end

		local ok, speed = parseCommand(message)
		if ok == nil or ok == false then
			return
		end

		applyWalkSpeed(player, speed)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	hookPlayer(player)
end

Players.PlayerAdded:Connect(hookPlayer)
