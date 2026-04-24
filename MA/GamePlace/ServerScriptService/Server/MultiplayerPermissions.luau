local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SlotData = ReplicatedStorage:WaitForChild("SlotData")
local UserIdValue = SlotData:WaitForChild("UserId")

local TrustedIdsValue = SlotData:FindFirstChild("TrustedUserIdsJson")
if not TrustedIdsValue or not TrustedIdsValue:IsA("StringValue") then
	if TrustedIdsValue then
		TrustedIdsValue:Destroy()
	end
	TrustedIdsValue = Instance.new("StringValue")
	TrustedIdsValue.Name = "TrustedUserIdsJson"
	TrustedIdsValue.Value = "[]"
	TrustedIdsValue.Parent = SlotData
end

local DEFAULTS = {
	TrustedBuild = true,
	TrustedDelete = true,
	TrustedUseOwnerResearch = true,
	VisitorBuild = false,
	VisitorDelete = false,
}

local cachedTrustedIds = {}
local cachedTrustedJson = nil

local MultiplayerPermissions = {}

local function getBooleanAttr(name, defaultValue)
	local value = SlotData:GetAttribute(name)
	if type(value) == "boolean" then
		return value
	end
	return defaultValue
end

local function decodeTrustedIds()
	local rawJson = TrustedIdsValue.Value or "[]"
	if rawJson == cachedTrustedJson then
		return cachedTrustedIds
	end

	local decoded = {}
	local ok, data = pcall(function()
		return HttpService:JSONDecode(rawJson)
	end)
	if ok and type(data) == "table" then
		for _, rawUserId in ipairs(data) do
			local userId = tonumber(rawUserId)
			if userId and userId > 0 then
				decoded[userId] = true
			end
		end
	end

	cachedTrustedJson = rawJson
	cachedTrustedIds = decoded
	return cachedTrustedIds
end

function MultiplayerPermissions.GetOwnerUserId()
	return tonumber(UserIdValue.Value) or 0
end

function MultiplayerPermissions.GetOwnerPlayer()
	local ownerUserId = MultiplayerPermissions.GetOwnerUserId()
	if ownerUserId <= 0 then
		return nil
	end
	return Players:GetPlayerByUserId(ownerUserId)
end

function MultiplayerPermissions.IsOwner(player)
	return player ~= nil and player.UserId == MultiplayerPermissions.GetOwnerUserId()
end

function MultiplayerPermissions.IsTrusted(player)
	if not player then
		return false
	end
	if MultiplayerPermissions.IsOwner(player) then
		return true
	end
	return decodeTrustedIds()[player.UserId] == true
end

function MultiplayerPermissions.GetTrustedUserIds()
	local out = {}
	for userId in pairs(decodeTrustedIds()) do
		table.insert(out, userId)
	end
	table.sort(out)
	return out
end

function MultiplayerPermissions.GetSettings()
	return {
		TrustedBuild = getBooleanAttr("Multiplayer_TrustedBuild", DEFAULTS.TrustedBuild),
		TrustedDelete = getBooleanAttr("Multiplayer_TrustedDelete", DEFAULTS.TrustedDelete),
		TrustedUseOwnerResearch = getBooleanAttr("Multiplayer_TrustedUseOwnerResearch", DEFAULTS.TrustedUseOwnerResearch),
		VisitorBuild = getBooleanAttr("Multiplayer_VisitorBuild", DEFAULTS.VisitorBuild),
		VisitorDelete = getBooleanAttr("Multiplayer_VisitorDelete", DEFAULTS.VisitorDelete),
	}
end

function MultiplayerPermissions.CanBuild(player)
	if not player then
		return false
	end
	if MultiplayerPermissions.IsOwner(player) then
		return true
	end

	local settings = MultiplayerPermissions.GetSettings()
	if settings.VisitorBuild then
		return true
	end
	if MultiplayerPermissions.IsTrusted(player) and settings.TrustedBuild then
		return true
	end
	return false
end

local function getTargetOwnerUserId(targetModel)
	if not targetModel then
		return nil
	end
	return tonumber(targetModel:GetAttribute("Owner"))
		or tonumber(targetModel:GetAttribute("OwnerId"))
		or tonumber(targetModel:GetAttribute("PlacedByUserId"))
end

function MultiplayerPermissions.CanDelete(player, targetModel)
	if not player then
		return false
	end
	if MultiplayerPermissions.IsOwner(player) then
		return true
	end

	local targetOwnerId = getTargetOwnerUserId(targetModel)
	if targetOwnerId and targetOwnerId == player.UserId then
		return true
	end

	local settings = MultiplayerPermissions.GetSettings()
	if settings.VisitorDelete then
		return true
	end
	if MultiplayerPermissions.IsTrusted(player) and settings.TrustedDelete then
		return true
	end

	local ownerUserId = MultiplayerPermissions.GetOwnerUserId()
	local ownerPlayer = MultiplayerPermissions.GetOwnerPlayer()
	if ownerUserId > 0 and ownerPlayer == nil and #Players:GetPlayers() <= 1 then
		if not targetOwnerId or targetOwnerId == ownerUserId then
			return true
		end
	end

	return false
end

function MultiplayerPermissions.CanUseOwnerResearch(player)
	if not player or MultiplayerPermissions.IsOwner(player) then
		return false
	end
	local settings = MultiplayerPermissions.GetSettings()
	if not settings.TrustedUseOwnerResearch then
		return false
	end
	return MultiplayerPermissions.IsTrusted(player)
end

function MultiplayerPermissions.GetResearchProxyPlayer(player)
	if not MultiplayerPermissions.CanUseOwnerResearch(player) then
		return nil
	end
	local ownerPlayer = MultiplayerPermissions.GetOwnerPlayer()
	if ownerPlayer and ownerPlayer ~= player then
		return ownerPlayer
	end
	return nil
end

return MultiplayerPermissions
