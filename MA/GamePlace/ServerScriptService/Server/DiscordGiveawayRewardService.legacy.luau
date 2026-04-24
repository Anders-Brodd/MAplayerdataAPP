--[[
	DiscordGiveawayRewardService

	Flow:
	- Discord bot writes winner reward records to DataStore mailbox key: user:<robloxUserId>
	- This script reads and grants rewards automatically on join
	- Optional MessagingService topic triggers live refresh for online players
	- Winners always get an in-game notification, including on next join
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	return
end

local MAILBOX_STORE_NAME = "DiscordGiveawayMailboxV1"
local GRANT_LOG_STORE_NAME = "DiscordGiveawayGrantLogV1"
local WIN_NOTICE_STORE_NAME = "DiscordGiveawayWinNoticeV1"
local LIVE_SYNC_TOPIC = "DiscordGiveawayRewardGrantedV1"

local MailboxStore = DataStoreService:GetDataStore(MAILBOX_STORE_NAME)
local GrantLogStore = DataStoreService:GetDataStore(GRANT_LOG_STORE_NAME)
local WinNoticeStore = DataStoreService:GetDataStore(WIN_NOTICE_STORE_NAME)

local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local RewardConfig = require(ReplicatedStorage:WaitForChild("GiveawayRewardsConfig"))
local GiveawayAccess = require(script.Parent:WaitForChild("GiveawayAccess"))

local function getNotificationEvent()
	local events = ReplicatedStorage:FindFirstChild("Events")
	if not events then
		return nil
	end
	local remote = events:FindFirstChild("NotificationEvent")
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

local function getMailboxKey(userId)
	return "user:" .. tostring(userId)
end

local function getGrantLogKey(grantId)
	local raw = tostring(grantId or "")
	local hash = 2166136261
	for i = 1, #raw do
		hash = bit32.bxor(hash, string.byte(raw, i))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("g:%08x", hash)
end

local function getWinNoticeKey(userId)
	return "user:" .. tostring(userId)
end

local function makeGrantId(userId, rewardKey, giveawayId)
	return string.format("%s:%d:%s", tostring(giveawayId or "unknown"), userId, rewardKey)
end

local function normalizeRecord(rawRecord, userId)
	if type(rawRecord) ~= "table" then
		return nil
	end

	local recordUserId = tonumber(rawRecord.robloxUserId or rawRecord.userId or rawRecord.playerUserId or userId)
	if not recordUserId or recordUserId ~= userId then
		return nil
	end

	local rawReward = rawRecord.reward or rawRecord.rewardKey or rawRecord.rewardId
	if type(rawReward) ~= "string" then
		return nil
	end

	local rewardKey = RewardConfig.NormalizeRewardKey(rawReward)
	if rewardKey == "" then
		return nil
	end

	local giveawayId = tostring(rawRecord.giveawayId or rawRecord.giveaway_id or "unknown")
	local grantId = tostring(rawRecord.grantId or rawRecord.grant_id or makeGrantId(userId, rewardKey, giveawayId))

	return {
		robloxUserId = userId,
		reward = rawReward,
		rewardKey = rewardKey,
		giveawayId = giveawayId,
		grantId = grantId,
		source = tostring(rawRecord.source or "discord"),
		createdAt = tonumber(rawRecord.createdAt or rawRecord.awardedAt) or os.time(),
	}
end

local function collectRawRecords(mailboxPayload)
	local out = {}

	if type(mailboxPayload) ~= "table" then
		return out
	end

	if type(mailboxPayload.reward) == "string" then
		table.insert(out, mailboxPayload)
	end

	if type(mailboxPayload.entries) == "table" then
		for _, entry in ipairs(mailboxPayload.entries) do
			table.insert(out, entry)
		end
	end

	if type(mailboxPayload.rewards) == "table" then
		for _, entry in ipairs(mailboxPayload.rewards) do
			table.insert(out, entry)
		end
	end

	if type(mailboxPayload[1]) ~= "nil" then
		for _, entry in ipairs(mailboxPayload) do
			table.insert(out, entry)
		end
	end

	return out
end

local function wasGrantProcessed(grantId)
	local ok, data = pcall(function()
		return GrantLogStore:GetAsync(getGrantLogKey(grantId))
	end)
	if not ok then
		return false
	end
	return data ~= nil
end

local function markGrantProcessed(record)
	local payload = {
		robloxUserId = record.robloxUserId,
		reward = record.rewardKey,
		giveawayId = record.giveawayId,
		source = record.source,
		processedAt = os.time(),
	}

	local ok, err = pcall(function()
		GrantLogStore:SetAsync(getGrantLogKey(record.grantId), payload)
	end)

	if not ok then
	end

	return ok
end

local function applyReward(record)
	local _, rewardDef = RewardConfig.Resolve(record.rewardKey)
	if not rewardDef then
		return false, "unknown_reward"
	end

	if rewardDef.kind == "pass" then
		if type(rewardDef.passId) ~= "number" or rewardDef.passId <= 0 then
			return false, "invalid_pass_id"
		end
		return EntitlementManager.GrantPass(record.robloxUserId, rewardDef.passId)
	end

	if rewardDef.kind == "founder" then
		return EntitlementManager.GrantFounder(record.robloxUserId)
	end

	if rewardDef.kind == "admin" then
		return GiveawayAccess.GrantAdminAccess(record.robloxUserId, {
			source = record.source,
			giveawayId = record.giveawayId,
			grantId = record.grantId,
		})
	end

	return false, "unsupported_reward_kind"
end

local function queueWinnerNotice(record)
	local notice = {
		grantId = record.grantId,
		rewardKey = record.rewardKey,
		giveawayId = record.giveawayId,
		createdAt = os.time(),
	}

	local ok, err = pcall(function()
		WinNoticeStore:UpdateAsync(getWinNoticeKey(record.robloxUserId), function(existing)
			local payload = type(existing) == "table" and existing or {}
			local entries = type(payload.entries) == "table" and payload.entries or {}
			for _, entry in ipairs(entries) do
				if type(entry) == "table" and tostring(entry.grantId or "") == notice.grantId then
					return payload
				end
			end
			table.insert(entries, notice)
			payload.entries = entries
			payload.updatedAt = os.time()
			return payload
		end)
	end)

	if not ok then
	end
end

local function drainWinnerNotices(userId)
	local notices = {}

	local ok, err = pcall(function()
		WinNoticeStore:UpdateAsync(getWinNoticeKey(userId), function(existing)
			if type(existing) == "table" and type(existing.entries) == "table" then
				for _, entry in ipairs(existing.entries) do
					if type(entry) == "table" then
						table.insert(notices, entry)
					end
				end
			end
			return nil
		end)
	end)

	if not ok then
	end

	return notices
end

local function restoreWinnerNotices(userId, notices)
	if #notices == 0 then
		return
	end

	pcall(function()
		WinNoticeStore:UpdateAsync(getWinNoticeKey(userId), function(existing)
			local payload = type(existing) == "table" and existing or {}
			local entries = type(payload.entries) == "table" and payload.entries or {}
			local seenGrantIds = {}
			for _, entry in ipairs(entries) do
				if type(entry) == "table" then
					local grantId = tostring(entry.grantId or "")
					if grantId ~= "" then
						seenGrantIds[grantId] = true
					end
				end
			end
			for _, entry in ipairs(notices) do
				if type(entry) == "table" then
					local grantId = tostring(entry.grantId or "")
					if grantId == "" or not seenGrantIds[grantId] then
						table.insert(entries, entry)
						if grantId ~= "" then
							seenGrantIds[grantId] = true
						end
					end
				end
			end
			payload.entries = entries
			payload.updatedAt = os.time()
			return payload
		end)
	end)
end

local function sendWinnerNoticeToPlayer(player, rewardKey)
	if not player then
		return false
	end

	local notificationEvent = getNotificationEvent()
	if not notificationEvent then
		return false
	end

	local _, rewardDef = RewardConfig.Resolve(rewardKey)
	local rewardLabel = (rewardDef and rewardDef.label) or tostring(rewardKey)

	notificationEvent:FireClient(
		player,
		"Success",
		"Giveaway Winner",
		("You won %s from a Discord giveaway."):format(rewardLabel),
		6
	)

	return true
end

local function flushWinnerNoticesForUser(userId, preferredPlayer)
	local player = preferredPlayer or Players:GetPlayerByUserId(userId)
	if not player then
		return
	end

	local notices = drainWinnerNotices(userId)
	if #notices == 0 then
		return
	end

	local unsent = {}
	for _, notice in ipairs(notices) do
		local rewardKey = RewardConfig.NormalizeRewardKey(notice.rewardKey or notice.reward or "")
		if rewardKey == "" or not sendWinnerNoticeToPlayer(player, rewardKey) then
			table.insert(unsent, notice)
		end
	end

	if #unsent > 0 then
		restoreWinnerNotices(userId, unsent)
	end
end

local function writeMailbox(userId, remainingRecords)
	local mailboxKey = getMailboxKey(userId)

	if #remainingRecords == 0 then
		pcall(function()
			MailboxStore:RemoveAsync(mailboxKey)
		end)
		return
	end

	local payload = {
		robloxUserId = userId,
		entries = remainingRecords,
		updatedAt = os.time(),
	}

	local ok, err = pcall(function()
		MailboxStore:SetAsync(mailboxKey, payload)
	end)

	if not ok then
	end
end

local function processMailboxForUser(userId)
	userId = tonumber(userId)
	if not userId or userId <= 0 then
		return
	end

	local mailboxKey = getMailboxKey(userId)
	local ok, mailboxPayload = pcall(function()
		return MailboxStore:GetAsync(mailboxKey)
	end)

	if not ok then
		return
	end

	if mailboxPayload == nil then
		return
	end

	local rawRecords = collectRawRecords(mailboxPayload)
	local normalized = {}
	local seenGrantIds = {}

	for _, rawRecord in ipairs(rawRecords) do
		local record = normalizeRecord(rawRecord, userId)
		if record and not seenGrantIds[record.grantId] then
			seenGrantIds[record.grantId] = true
			table.insert(normalized, record)
		end
	end

	if #normalized == 0 then
		pcall(function()
			MailboxStore:RemoveAsync(mailboxKey)
		end)
		return
	end

	local remaining = {}

	for _, record in ipairs(normalized) do
		if wasGrantProcessed(record.grantId) then
			queueWinnerNotice(record)
			flushWinnerNoticesForUser(record.robloxUserId)
			continue
		end

		local granted, err = applyReward(record)
		if granted then
			markGrantProcessed(record)
			queueWinnerNotice(record)
			flushWinnerNoticesForUser(record.robloxUserId)
		else
			table.insert(remaining, record)
		end
	end

	writeMailbox(userId, remaining)
end

local function normalizeLiveSyncData(rawData)
	if type(rawData) == "table" then
		return rawData
	end

	if type(rawData) == "string" and rawData ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(rawData)
		end)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end

	return nil
end

local function processMailboxForPlayer(player)
	if not player then
		return
	end
	task.spawn(function()
		task.wait(1)
		flushWinnerNoticesForUser(player.UserId, player)
		processMailboxForUser(player.UserId)
		flushWinnerNoticesForUser(player.UserId, player)
	end)
end

Players.PlayerAdded:Connect(processMailboxForPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	processMailboxForPlayer(player)
end

pcall(function()
	MessagingService:SubscribeAsync(LIVE_SYNC_TOPIC, function(message)
		local data = normalizeLiveSyncData(message and message.Data)
		if not data then
			return
		end

		local userId = tonumber(data.robloxUserId or data.userId)
		if not userId then
			return
		end

		if Players:GetPlayerByUserId(userId) then
			task.delay(0.5, function()
				processMailboxForUser(userId)
				flushWinnerNoticesForUser(userId)
			end)
		end
	end)
end)