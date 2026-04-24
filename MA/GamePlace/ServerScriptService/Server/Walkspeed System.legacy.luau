if true then
	return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GiveawayAccess = require(script.Parent:WaitForChild("GiveawayAccess"))

local CONFIG = {
	GROUP_ID = 398051359,
	MIN_RANK = 250,
	SUPER_ADMINS = {
		[8843215003] = true,
		[1090907828] = true,
		[1624020068] = true,
		[389306460] = true,
		-- [1306183746] = true,
		[1215727369] = true,
		[game.CreatorId] = true,
	},
	DEFAULT_WALKSPEED = 16,
	MIN_WALKSPEED = 0,
	MAX_WALKSPEED = 5000,
}

local function IsAdmin(player)
	if not player then
		return false
	end
	if CONFIG.SUPER_ADMINS[player.UserId] then
		return true
	end

	local accessOk, accessResult = pcall(function()
		return GiveawayAccess.HasAdminAccess(player.UserId)
	end)
	if accessOk and accessResult == true then
		return true
	end

	local ok, rank = pcall(function()
		return player:GetRankInGroup(CONFIG.GROUP_ID)
	end)
	return ok and rank >= CONFIG.MIN_RANK
end

local function ApplyWalkSpeed(player, speed)
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	player:SetAttribute("AdminWalkSpeed", speed)
	humanoid.WalkSpeed = speed
	return true
end

local function ParseWalkSpeedCommand(message)
	if type(message) ~= "string" then
		return nil
	end
	local normalized = message:gsub("^%s+", ""):gsub("%s+$", "")
	local amountText = normalized:match("^/ws%s+(.+)$")
	if not amountText then
		return nil
	end
	amountText = amountText:gsub("^%s+", ""):gsub("%s+$", "")
	if amountText == "default" or amountText == "reset" then
		return CONFIG.DEFAULT_WALKSPEED
	end
	local amount = tonumber(amountText)
	if not amount then
		return false
	end
	return math.clamp(math.floor(amount + 0.5), CONFIG.MIN_WALKSPEED, CONFIG.MAX_WALKSPEED)
end

local function HookPlayer(player)
	player.CharacterAdded:Connect(function(character)
		local desired = tonumber(player:GetAttribute("AdminWalkSpeed"))
		if not desired then
			return
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			humanoid.WalkSpeed = desired
		end
	end)

	player.Chatted:Connect(function(message)
		if not IsAdmin(player) then
			return
		end
		local desired = ParseWalkSpeedCommand(message)
		if desired == nil or desired == false then
			return
		end
		ApplyWalkSpeed(player, desired)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(HookPlayer, player)
end

Players.PlayerAdded:Connect(HookPlayer)