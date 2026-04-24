--[=[ PATH: ServerScriptService/Server/CodeRedeemServer | TYPE: Script ]=]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
Events.Name = "Events"
Events.Parent = ReplicatedStorage

local RedeemCode = Events:FindFirstChild("RedeemCode")
if RedeemCode and not RedeemCode:IsA("RemoteFunction") then
	RedeemCode:Destroy()
	RedeemCode = nil
end
if not RedeemCode then
	RedeemCode = Instance.new("RemoteFunction")
	RedeemCode.Name = "RedeemCode"
	RedeemCode.Parent = Events
end

local NotificationEvent = Events:FindFirstChild("NotificationEvent")
local CodesConfig = require(ReplicatedStorage:WaitForChild("CodesConfig"))

local CLAIM_STORE_NAME = "CodeClaims_v1"
local ClaimStore = nil
if not RunService:IsStudio() then
	ClaimStore = DataStoreService:GetDataStore(CLAIM_STORE_NAME)
end

local UserClaimsCache = {}

local function getClaimLimit(codeDef)
	if type(codeDef) ~= "table" then
		return 1
	end
	local limit = tonumber(codeDef.MaxClaimsPerPlayer)
		or tonumber(codeDef.UsesPerPlayer)
		or tonumber(codeDef.MaxUsesPerPlayer)
	if not limit then
		return 1
	end
	limit = math.floor(limit + 0.5)
	if limit < 1 then
		return 1
	end
	return limit
end

local function normalizeClaimRecord(record)
	if type(record) == "table" then
		local count = tonumber(record.Count) or tonumber(record.Uses) or tonumber(record.Claims) or 1
		local claimedAt = tonumber(record.LastClaimedAt) or tonumber(record.ClaimedAt) or tonumber(record.Time) or os.time()
		return {
			Count = math.max(1, math.floor(count + 0.5)),
			LastClaimedAt = claimedAt,
		}
	end
	if record ~= nil then
		return {
			Count = 1,
			LastClaimedAt = tonumber(record) or os.time(),
		}
	end
	return nil
end

local function getClaimCount(record)
	if type(record) == "table" then
		return math.max(0, math.floor((tonumber(record.Count) or 0) + 0.5))
	end
	if record ~= nil then
		return 1
	end
	return 0
end

local function notify(player, category, title, message, duration)
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent:FireClient(player, category, title, message, duration or 4)
	end
end

local function normalizeCode(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local cleaned = string.upper(raw):gsub("%s+", ""):gsub("[^A-Z0-9_%-]", "")
	if cleaned == "" then
		return nil
	end
	return cleaned
end

local function getMoneyIncomeEvent()
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local moneyServer = serverFolder and serverFolder:FindFirstChild("MoneyServer")
	if not moneyServer then
		return nil
	end
	local addIncome = moneyServer:FindFirstChild("AddIncome")
	if addIncome and addIncome:IsA("BindableEvent") then
		return addIncome
	end
	return nil
end

local function getClaimKey(userId)
	return string.format("U_%d", userId)
end

local function getPlayerClaims(userId)
	local cached = UserClaimsCache[userId]
	if cached then
		return cached
	end
	local claims = {}
	if ClaimStore then
		local ok, result = pcall(function()
			return ClaimStore:GetAsync(getClaimKey(userId))
		end)
		if ok and type(result) == "table" and type(result.Claims) == "table" then
			for code, claimRecord in pairs(result.Claims) do
				if type(code) == "string" then
					local normalized = normalizeClaimRecord(claimRecord)
					if normalized then
						claims[code] = normalized
					end
				end
			end
		end
	end
	UserClaimsCache[userId] = claims
	return claims
end

local function markClaimed(userId, code, codeDef)
	local claims = getPlayerClaims(userId)
	local claimLimit = getClaimLimit(codeDef)
	local existing = normalizeClaimRecord(claims[code])
	local existingCount = getClaimCount(existing)
	if existingCount >= claimLimit then
		claims[code] = existing or claims[code]
		return false, "ALREADY_REDEEMED"
	end

	local now = os.time()
	local nextRecord = {
		Count = existingCount + 1,
		LastClaimedAt = now,
	}

	if ClaimStore then
		local wasClaimed = false
		local ok, err = pcall(function()
			ClaimStore:UpdateAsync(getClaimKey(userId), function(old)
				local data = (type(old) == "table") and old or {}
				data.Claims = (type(data.Claims) == "table") and data.Claims or {}
				local currentRecord = normalizeClaimRecord(data.Claims[code])
				local currentCount = getClaimCount(currentRecord)
				if currentCount >= claimLimit then
					wasClaimed = true
					data.Claims[code] = currentRecord or data.Claims[code]
					return data
				end
				data.Claims[code] = {
					Count = currentCount + 1,
					LastClaimedAt = now,
				}
				return data
			end)
		end)
		if not ok then
			warn("[CodeRedeemServer] Failed to save claim: " .. tostring(err))
			return false, "DATASTORE_ERROR"
		end
		if wasClaimed then
			claims[code] = existing or claims[code]
			return false, "ALREADY_REDEEMED"
		end
	end

	claims[code] = nextRecord
	return true, nil
end

local function getCodeDef(code)
	local codeTable = CodesConfig and CodesConfig.Codes
	if type(codeTable) ~= "table" then
		return nil
	end
	for rawCode, def in pairs(codeTable) do
		if normalizeCode(rawCode) == code then
			return def
		end
	end
	return nil
end

local function applyTimedBoost(player, boostPrefix, durationMinutes, multiplier)
	local now = os.time()
	local durationSeconds = math.max(1, math.floor((tonumber(durationMinutes) or 0) * 60 + 0.5))
	local endAttr = boostPrefix .. "EndTime"
	local activeAttr = boostPrefix .. "Active"
	local multAttr = boostPrefix .. "Multiplier"

	local currentEnd = tonumber(player:GetAttribute(endAttr)) or 0
	if currentEnd < now then
		currentEnd = now
	end

	local newEnd = currentEnd + durationSeconds
	player:SetAttribute(activeAttr, true)
	player:SetAttribute(endAttr, newEnd)
	if multiplier ~= nil then
		local currentMult = tonumber(player:GetAttribute(multAttr)) or 1
		local nextMult = math.max(currentMult, tonumber(multiplier) or 1)
		player:SetAttribute(multAttr, nextMult)
	end
	return newEnd
end

local function applyReward(player, reward)
	if type(reward) ~= "table" then
		return false, "INVALID_REWARD"
	end
	local rewardType = string.upper(tostring(reward.Type or ""))

	if rewardType == "MONEY" or rewardType == "CASH" then
		local amount = math.max(0, math.floor((tonumber(reward.Amount) or 0) + 0.5))
		if amount <= 0 then
			return false, "INVALID_MONEY"
		end
		local incomeEvent = getMoneyIncomeEvent()
		if not incomeEvent then
			return false, "MONEY_OFFLINE"
		end
		incomeEvent:Fire(player, amount, "CodeRedeem", Enum.AnalyticsEconomyTransactionType.Gameplay)
		return true, string.format("+$%d", amount)
	end

	if rewardType == "RESEARCHPOINTS" or rewardType == "RP" or rewardType == "RESEARCH" then
		local amount = math.max(0, math.floor((tonumber(reward.Amount) or 0) + 0.5))
		if amount <= 0 then
			return false, "INVALID_RP"
		end
		local pending = tonumber(player:GetAttribute("PendingRPGrant")) or 0
		player:SetAttribute("PendingRPGrant", pending + amount)
		return true, string.format("+%d RP", amount)
	end

	if rewardType == "MONEYBOOST" then
		local mult = tonumber(reward.Multiplier) or tonumber(CodesConfig.DefaultMoneyBoostMultiplier) or 2
		local endTime = applyTimedBoost(player, "CodeMoneyBoost", reward.DurationMinutes or 15, mult)
		return true, string.format("Money x%.2g (%dm)", mult, math.max(1, math.floor((endTime - os.time()) / 60 + 0.5)))
	end

	if rewardType == "RESEARCHBOOST" then
		local mult = tonumber(reward.Multiplier) or tonumber(CodesConfig.DefaultResearchBoostMultiplier) or 2
		local endTime = applyTimedBoost(player, "CodeResearchBoost", reward.DurationMinutes or 15, mult)
		return true, string.format("Research x%.2g (%dm)", mult, math.max(1, math.floor((endTime - os.time()) / 60 + 0.5)))
	end

	if rewardType == "GUESTBOOST" then
		local mult = tonumber(reward.Multiplier) or tonumber(CodesConfig.DefaultGuestBoostMultiplier) or 1.6
		local endTime = applyTimedBoost(player, "CodeGuestBoost", reward.DurationMinutes or 15, mult)
		return true, string.format("Guests x%.2g (%dm)", mult, math.max(1, math.floor((endTime - os.time()) / 60 + 0.5)))
	end

	if rewardType == "ATTRIBUTE" then
		local attrName = tostring(reward.Name or "")
		if attrName == "" then
			return false, "INVALID_ATTRIBUTE"
		end
		player:SetAttribute(attrName, reward.Value)
		return true, string.format("Set %s", attrName)
	end

	return false, "UNKNOWN_REWARD"
end

local function isCodeExpired(codeDef)
	if type(codeDef) ~= "table" then
		return true
	end
	local expiresAt = tonumber(codeDef.ExpiresAtUnix) or tonumber(codeDef.ExpiresAt)
	if not expiresAt then
		return false
	end
	return os.time() > math.floor(expiresAt)
end

local function redeemCodeForPlayer(player, rawCode)
	if player:GetAttribute("WorldLoadLocked") == true then
		return false, "WORLD_LOADING", nil
	end

	local code = normalizeCode(rawCode)
	if not code then
		return false, "INVALID_CODE", nil
	end

	local codeDef = getCodeDef(code)
	if type(codeDef) ~= "table" then
		return false, "INVALID_CODE", nil
	end
	if codeDef.Enabled == false then
		return false, "CODE_DISABLED", nil
	end
	if isCodeExpired(codeDef) then
		return false, "CODE_EXPIRED", nil
	end

	local claimedOk, claimedErr = markClaimed(player.UserId, code, codeDef)
	if not claimedOk then
		return false, claimedErr or "ALREADY_REDEEMED", nil
	end

	local rewards = type(codeDef.Rewards) == "table" and codeDef.Rewards or {}
	local appliedSummary = {}
	for _, reward in ipairs(rewards) do
		local ok, summary = applyReward(player, reward)
		if ok and summary then
			table.insert(appliedSummary, summary)
		end
	end

	return true, "REDEEMED", appliedSummary
end

local function expireBoostsForPlayer(player)
	local now = os.time()
	local boostPrefixes = {
		"CodeMoneyBoost",
		"CodeResearchBoost",
		"CodeGuestBoost",
	}
	for _, prefix in ipairs(boostPrefixes) do
		local endAttr = prefix .. "EndTime"
		local activeAttr = prefix .. "Active"
		local multAttr = prefix .. "Multiplier"
		local active = player:GetAttribute(activeAttr) == true
		local endsAt = tonumber(player:GetAttribute(endAttr)) or 0
		if active and endsAt > 0 and now >= endsAt then
			player:SetAttribute(activeAttr, nil)
			player:SetAttribute(endAttr, nil)
			player:SetAttribute(multAttr, nil)
		end
	end
end

RedeemCode.OnServerInvoke = function(player, codeText)
	local ok, status, applied = redeemCodeForPlayer(player, codeText)
	if ok then
		local message = (#applied > 0) and table.concat(applied, " | ") or "Code redeemed"
		notify(player, "Positive", "CODE REDEEMED", message, 5)
		return {
			Success = true,
			Status = status,
			Applied = applied,
		}
	end

	local failText = status or "FAILED"
	local uiText = {
		ALREADY_REDEEMED = "You already redeemed this code.",
		INVALID_CODE = "Invalid code.",
		CODE_DISABLED = "This code is disabled.",
		CODE_EXPIRED = "This code expired.",
		WORLD_LOADING = "Wait for world load, then try again.",
		DATASTORE_ERROR = "Save service unavailable. Try again.",
	}
	notify(player, "Negative", "CODE FAILED", uiText[failText] or failText, 4)
	return {
		Success = false,
		Status = failText,
	}
end

Players.PlayerAdded:Connect(function(player)
	getPlayerClaims(player.UserId)
end)

Players.PlayerRemoving:Connect(function(player)
	UserClaimsCache[player.UserId] = nil
end)

task.spawn(function()
	while true do
		for _, player in ipairs(Players:GetPlayers()) do
			expireBoostsForPlayer(player)
		end
		task.wait(1)
	end
end)

print("[CodeRedeemServer] Online")
