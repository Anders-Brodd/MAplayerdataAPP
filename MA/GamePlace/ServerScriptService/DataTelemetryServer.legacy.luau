local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local STORE_NAME = "MA_PlayerTelemetry_V2"
local EVENTS_FOLDER_NAME = "Events"
local CLIENT_REMOTE_NAME = "ClientTelemetryEvent"
local SERVER_BINDABLE_NAME = "ServerTelemetryLog"
local SNAPSHOT_REMOTE_NAME = "TelemetryGetSnapshot"

local FLUSH_INTERVAL_SECONDS = 75
local MIN_WRITE_INTERVAL_SECONDS = 20
local MAX_RECENT_PER_CATEGORY = 180
local MAX_PAYLOAD_KEYS = 28
local MAX_STRING_LENGTH = 320

local ALLOWED_CATEGORIES = {
	ui = true,
	menu = true,
	ad = true,
	building = true,
	money = true,
	purchase = true,
	session = true,
	bug_report = true,
	resort = true,
	error = true,
	action = true,
}

local DEFAULT_STATS = {
	TimesPlayed = 0,
	TotalPlaytimeSeconds = 0,
	UiInteractions = 0,
	RobuxSpent = 0,
	ButtonsClicked = 0,
	MenusOpened = 0,
	BuildingsPlaced = 0,
	BuildingCancellations = 0,
	AdRewardsGranted = 0,
	MoneyIn = 0,
	MoneyOut = 0,
	BugReports = 0,
	ResortsCreated = 0,
	ResortsDeleted = 0,
	ErrorsLogged = 0,
}

local PRIORITY_PAYLOAD_KEYS = {
	"interaction_id",
	"event_name",
	"path",
	"menu",
	"ui_id",
	"element_name",
	"button_name",
	"button_text",
	"input_type",
	"key_code",
	"text_length",
	"duration_seconds",
	"item_name",
	"item_type",
	"source",
	"reason",
	"slot",
	"delta",
	"amount",
	"balance",
	"robux",
	"session_token",
}

local store = DataStoreService:GetDataStore(STORE_NAME)
local sessions = {}
local moneyConnections = {}

local function nowTs()
	return os.time()
end

local function getPlaceLabel()
	local name = string.lower(tostring(game.Name or ""))
	if string.find(name, "lobby", 1, true) then
		return "lobby"
	end
	if string.find(name, "game", 1, true) or string.find(name, "resort", 1, true) then
		return "game"
	end
	return "unknown"
end

local PLACE_LABEL = getPlaceLabel()

local function trimText(value, maxLength)
	local text = tostring(value or "")
	if #text > maxLength then
		return string.sub(text, 1, maxLength)
	end
	return text
end

local function normalizeToken(value, fallback)
	local token = string.lower(trimText(value, 64))
	token = string.gsub(token, "[^%w_]+", "_")
	token = string.gsub(token, "_+", "_")
	token = string.gsub(token, "^_", "")
	token = string.gsub(token, "_$", "")
	if token == "" then
		return fallback
	end
	return token
end

local function cloneTable(source, depth)
	if type(source) ~= "table" then
		return source
	end
	if depth <= 0 then
		return {}
	end
	local out = {}
	for k, v in pairs(source) do
		if type(v) == "table" then
			out[k] = cloneTable(v, depth - 1)
		else
			out[k] = v
		end
	end
	return out
end

local function ensureFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemoteEvent(parent, name)
	local remote = parent:FindFirstChild(name)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	if remote then
		remote:Destroy()
	end
	remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureBindableEvent(parent, name)
	local bindable = parent:FindFirstChild(name)
	if bindable and bindable:IsA("BindableEvent") then
		return bindable
	end
	if bindable then
		bindable:Destroy()
	end
	bindable = Instance.new("BindableEvent")
	bindable.Name = name
	bindable.Parent = parent
	return bindable
end

local function ensureRemoteFunction(parent, name)
	local remote = parent:FindFirstChild(name)
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	if remote then
		remote:Destroy()
	end
	remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local eventsFolder = ensureFolder(ReplicatedStorage, EVENTS_FOLDER_NAME)
local clientTelemetryRemote = ensureRemoteEvent(eventsFolder, CLIENT_REMOTE_NAME)
local serverTelemetryBindable = ensureBindableEvent(ReplicatedStorage, SERVER_BINDABLE_NAME)
local snapshotRemote = ensureRemoteFunction(ReplicatedStorage, SNAPSHOT_REMOTE_NAME)

local function writePayloadValue(out, key, value)
	local valueType = type(value)
	if valueType == "string" then
		out[key] = trimText(value, MAX_STRING_LENGTH)
		return true
	elseif valueType == "number" then
		if value == value and value ~= math.huge and value ~= -math.huge then
			out[key] = math.floor(value * 1000 + 0.5) / 1000
			return true
		end
	elseif valueType == "boolean" then
		out[key] = value
		return true
	end
	return false
end

local function sanitizePayload(payload)
	if type(payload) ~= "table" then
		return {}
	end
	local out = {}
	local used = {}
	local written = 0

	for _, key in ipairs(PRIORITY_PAYLOAD_KEYS) do
		if written >= MAX_PAYLOAD_KEYS then
			break
		end
		local value = payload[key]
		if value ~= nil then
			local safeKey = normalizeToken(key, "field")
			if out[safeKey] == nil and writePayloadValue(out, safeKey, value) then
				written += 1
			end
			used[key] = true
		end
	end

	for key, value in pairs(payload) do
		if written >= MAX_PAYLOAD_KEYS then
			break
		end
		if not used[key] then
			local safeKey = normalizeToken(key, "field")
			if out[safeKey] == nil and writePayloadValue(out, safeKey, value) then
				written += 1
			end
		end
	end

	return out
end

local function ensureStoreShape(raw, userId, username)
	local data = type(raw) == "table" and cloneTable(raw, 4) or {}
	if type(data.Stats) ~= "table" then
		data.Stats = {}
	end
	for statName, defaultValue in pairs(DEFAULT_STATS) do
		if type(data.Stats[statName]) ~= "number" then
			data.Stats[statName] = defaultValue
		end
	end
	if type(data.CategoryCounts) ~= "table" then
		data.CategoryCounts = {}
	end
	if type(data.RecentEvents) ~= "table" then
		data.RecentEvents = {}
	end
	data.UserId = userId
	data.Username = trimText(username or data.Username or "Unknown", 32)
	data.Version = 2
	data.LastSeenAt = nowTs()
	data.LastPlaceId = game.PlaceId
	data.LastPlaceLabel = PLACE_LABEL
	data.LastJobId = game.JobId
	return data
end

local function makeFreshStats()
	local stats = {}
	for statName in pairs(DEFAULT_STATS) do
		stats[statName] = 0
	end
	return stats
end

local function ensureSession(userId)
	return sessions[userId]
end

local function bumpStat(session, statName, amount)
	if amount == 0 then
		return
	end
	session.DeltaStats[statName] = (session.DeltaStats[statName] or 0) + amount
end

local function toNumber(value)
	local n = tonumber(value)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

local function handleDerivedStats(session, category, action, payload)
	if category == "ui" then
		bumpStat(session, "UiInteractions", 1)
		if action == "button_click" then
			bumpStat(session, "ButtonsClicked", 1)
		end
	elseif category == "menu" and action == "open" then
		bumpStat(session, "MenusOpened", 1)
	elseif category == "building" and action == "placed" then
		bumpStat(session, "BuildingsPlaced", 1)
	elseif category == "building" and (action == "cancel" or action == "attempt_cancelled") then
		bumpStat(session, "BuildingCancellations", 1)
	elseif category == "ad" and action == "reward_granted" then
		bumpStat(session, "AdRewardsGranted", 1)
	elseif category == "bug_report" and action == "submitted" then
		bumpStat(session, "BugReports", 1)
	elseif category == "resort" and action == "create_success" then
		bumpStat(session, "ResortsCreated", 1)
	elseif category == "resort" and action == "delete_success" then
		bumpStat(session, "ResortsDeleted", 1)
	elseif category == "error" then
		bumpStat(session, "ErrorsLogged", 1)
	elseif category == "money" then
		local amount = toNumber(payload.amount) or toNumber(payload.delta) or 0
		if action == "income" or action == "balance_increase" then
			if amount > 0 then
				bumpStat(session, "MoneyIn", amount)
			end
		elseif action == "spend" or action == "balance_decrease" then
			if amount < 0 then
				amount = math.abs(amount)
			end
			if amount > 0 then
				bumpStat(session, "MoneyOut", amount)
			end
		end
	elseif category == "purchase" and action == "robux_spent" then
		local robux = toNumber(payload.robux) or toNumber(payload.price) or 0
		if robux > 0 then
			bumpStat(session, "RobuxSpent", robux)
		end
	end
end

local function recordEventForUserId(userId, categoryRaw, actionRaw, payloadRaw)
	local session = ensureSession(userId)
	if not session then
		return
	end

	local category = normalizeToken(categoryRaw, "action")
	if not ALLOWED_CATEGORIES[category] then
		category = "action"
	end
	local action = normalizeToken(actionRaw, "event")
	local payload = sanitizePayload(payloadRaw)

	local eventEntry = {
		ts = nowTs(),
		place_id = game.PlaceId,
		place_label = PLACE_LABEL,
		category = category,
		action = action,
		data = payload,
	}

	if type(session.DeltaRecent[category]) ~= "table" then
		session.DeltaRecent[category] = {}
	end
	local bucket = session.DeltaRecent[category]
	table.insert(bucket, eventEntry)
	while #bucket > MAX_RECENT_PER_CATEGORY do
		table.remove(bucket, 1)
	end

	table.insert(session.LiveRecentEvents, eventEntry)
	while #session.LiveRecentEvents > MAX_RECENT_PER_CATEGORY do
		table.remove(session.LiveRecentEvents, 1)
	end

	session.DeltaCategoryCounts[category] = (session.DeltaCategoryCounts[category] or 0) + 1
	handleDerivedStats(session, category, action, payload)
	session.Dirty = true
	session.LastTouchedClock = os.clock()
end

local function mergeNumberTable(target, source)
	for key, value in pairs(source) do
		if type(value) == "number" and value ~= 0 then
			target[key] = (target[key] or 0) + value
		end
	end
end

local function mergeRecentEvents(targetRecent, deltaRecent)
	for category, entries in pairs(deltaRecent) do
		if type(entries) == "table" and #entries > 0 then
			if type(targetRecent[category]) ~= "table" then
				targetRecent[category] = {}
			end
			for _, eventEntry in ipairs(entries) do
				table.insert(targetRecent[category], eventEntry)
			end
			while #targetRecent[category] > MAX_RECENT_PER_CATEGORY do
				table.remove(targetRecent[category], 1)
			end
		end
	end
end

local function accruePlaytime(session)
	local nowClock = os.clock()
	local elapsed = math.max(0, nowClock - session.LastPlaytimeClock)
	if elapsed > 0 then
		session.DeltaStats.TotalPlaytimeSeconds = (session.DeltaStats.TotalPlaytimeSeconds or 0) + elapsed
		session.LastPlaytimeClock = nowClock
	end
end

local function hasPendingDelta(session)
	if not session.Dirty then
		return false
	end
	for _, value in pairs(session.DeltaStats) do
		if type(value) == "number" and value ~= 0 then
			return true
		end
	end
	for _, value in pairs(session.DeltaCategoryCounts) do
		if type(value) == "number" and value ~= 0 then
			return true
		end
	end
	for _, list in pairs(session.DeltaRecent) do
		if type(list) == "table" and #list > 0 then
			return true
		end
	end
	return false
end

local function resetDelta(session)
	session.DeltaStats = makeFreshStats()
	session.DeltaCategoryCounts = {}
	session.DeltaRecent = {}
	session.Dirty = false
end

local function flushSession(userId, force)
	local session = sessions[userId]
	if not session then
		return true
	end

	accruePlaytime(session)
	if not hasPendingDelta(session) then
		return true
	end

	if not force and (os.clock() - session.LastWriteClock) < MIN_WRITE_INTERVAL_SECONDS then
		return false
	end

	local deltaStats = cloneTable(session.DeltaStats, 2)
	local deltaCounts = cloneTable(session.DeltaCategoryCounts, 2)
	local deltaRecent = cloneTable(session.DeltaRecent, 4)
	local key = "u_" .. tostring(userId)

	local ok, err = pcall(function()
		local updated = store:UpdateAsync(key, function(previous)
			local merged = ensureStoreShape(previous, userId, session.Username)
			mergeNumberTable(merged.Stats, deltaStats)
			mergeNumberTable(merged.CategoryCounts, deltaCounts)
			mergeRecentEvents(merged.RecentEvents, deltaRecent)
			merged.LastSession = {
				StartedAt = session.StartedAt,
				EndedAt = nowTs(),
				DurationSeconds = math.max(0, math.floor(os.clock() - session.StartedClock + 0.5)),
				PlaceId = game.PlaceId,
				PlaceLabel = PLACE_LABEL,
			}
			return merged
		end)
		session.CachedStore = updated
	end)

	if not ok then
		session.SaveFailures += 1
		warn("[DataTelemetry] Failed to flush user " .. tostring(userId) .. ": " .. tostring(err))
		return false
	end

	resetDelta(session)
	session.LastWriteClock = os.clock()
	return true
end

local function loadCachedStore(userId, username)
	local key = "u_" .. tostring(userId)
	local loaded = nil
	pcall(function()
		loaded = store:GetAsync(key)
	end)
	return ensureStoreShape(loaded, userId, username)
end

local function setupMoneyTracking(player)
	local userId = player.UserId
	local lastMoney = tonumber(player:GetAttribute("Money")) or 0
	moneyConnections[player] = player:GetAttributeChangedSignal("Money"):Connect(function()
		local current = tonumber(player:GetAttribute("Money")) or 0
		local delta = current - lastMoney
		if math.abs(delta) >= 1 then
			if delta > 0 then
				recordEventForUserId(userId, "money", "balance_increase", {
					delta = delta,
					balance = current,
				})
			else
				recordEventForUserId(userId, "money", "balance_decrease", {
					delta = math.abs(delta),
					balance = current,
				})
			end
		end
		lastMoney = current
	end)
end

local function newSession(player)
	local userId = player.UserId
	local session = {
		UserId = userId,
		Username = player.Name,
		StartedAt = nowTs(),
		StartedClock = os.clock(),
		LastPlaytimeClock = os.clock(),
		LastWriteClock = 0,
		LastTouchedClock = os.clock(),
		SaveFailures = 0,
		Dirty = true,
		DeltaStats = makeFreshStats(),
		DeltaCategoryCounts = {},
		DeltaRecent = {},
		LiveRecentEvents = {},
		CachedStore = loadCachedStore(userId, player.Name),
	}
	session.DeltaStats.TimesPlayed = 1
	sessions[userId] = session

	recordEventForUserId(userId, "session", "join", {
		username = player.Name,
		place_id = game.PlaceId,
		place_label = PLACE_LABEL,
	})

	setupMoneyTracking(player)
end

local function endSession(player)
	local userId = player.UserId
	recordEventForUserId(userId, "session", "leave", {
		username = player.Name,
		place_id = game.PlaceId,
		place_label = PLACE_LABEL,
	})
	flushSession(userId, true)
	sessions[userId] = nil

	local connection = moneyConnections[player]
	if connection then
		connection:Disconnect()
		moneyConnections[player] = nil
	end
end

local function resolvePlayer(anyPlayer)
	if typeof(anyPlayer) == "Instance" and anyPlayer:IsA("Player") then
		return anyPlayer
	end
	local userId = tonumber(anyPlayer)
	if userId then
		return Players:GetPlayerByUserId(userId)
	end
	return nil
end

clientTelemetryRemote.OnServerEvent:Connect(function(player, categoryOrPayload, actionOrPayload, payloadMaybe)
	if not player or not player:IsDescendantOf(game) then
		return
	end

	if type(categoryOrPayload) == "table" then
		local packet = categoryOrPayload
		recordEventForUserId(player.UserId, packet.category, packet.action, packet.data or packet.payload)
		return
	end

	if type(categoryOrPayload) == "string" and type(actionOrPayload) == "string" then
		recordEventForUserId(player.UserId, categoryOrPayload, actionOrPayload, payloadMaybe)
		return
	end

	if type(categoryOrPayload) == "string" then
		recordEventForUserId(player.UserId, "ui", "button_click", { event_name = categoryOrPayload })
	end
end)

serverTelemetryBindable.Event:Connect(function(playerOrUserId, category, action, payload)
	local player = resolvePlayer(playerOrUserId)
	if player then
		recordEventForUserId(player.UserId, category, action, payload)
		return
	end
	local userId = tonumber(playerOrUserId)
	if userId then
		recordEventForUserId(userId, category, action, payload)
	end
end)

snapshotRemote.OnServerInvoke = function(player, targetUserId)
	local requestedUserId = tonumber(targetUserId) or player.UserId
	if requestedUserId ~= player.UserId and not RunService:IsStudio() then
		return {
			Success = false,
			Error = "Unauthorized",
		}
	end

	local targetSession = sessions[requestedUserId]
	if targetSession then
		accruePlaytime(targetSession)
		local combined = ensureStoreShape(targetSession.CachedStore, requestedUserId, targetSession.Username)
		mergeNumberTable(combined.Stats, targetSession.DeltaStats)
		mergeNumberTable(combined.CategoryCounts, targetSession.DeltaCategoryCounts)
		mergeRecentEvents(combined.RecentEvents, targetSession.DeltaRecent)
		return {
			Success = true,
			Snapshot = {
				GeneratedAt = nowTs(),
				UserId = requestedUserId,
				Username = targetSession.Username,
				StoredAndPending = combined,
				Session = {
					StartedAt = targetSession.StartedAt,
					ElapsedSeconds = math.max(0, math.floor(os.clock() - targetSession.StartedClock + 0.5)),
					RecentEvents = cloneTable(targetSession.LiveRecentEvents, 3),
				},
			},
		}
	end

	local key = "u_" .. tostring(requestedUserId)
	local stored = nil
	local ok = pcall(function()
		stored = store:GetAsync(key)
	end)
	if not ok or type(stored) ~= "table" then
		return {
			Success = false,
			Error = "No telemetry data found for this user",
		}
	end

	return {
		Success = true,
		Snapshot = {
			GeneratedAt = nowTs(),
			UserId = requestedUserId,
			StoredAndPending = ensureStoreShape(stored, requestedUserId, nil),
			Offline = true,
		},
	}
end

Players.PlayerAdded:Connect(newSession)
Players.PlayerRemoving:Connect(endSession)
for _, player in ipairs(Players:GetPlayers()) do
	newSession(player)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if not player then
		return
	end
	recordEventForUserId(player.UserId, "purchase", "gamepass_prompt_result", {
		item_id = passId,
		purchased = wasPurchased == true,
	})
	if wasPurchased then
		recordEventForUserId(player.UserId, "purchase", "robux_spent", {
			item_type = "gamepass",
			item_id = passId,
		})
	end
end)

local productSignalOk, productSignal = pcall(function()
	return MarketplaceService.PromptProductPurchaseFinished
end)
if productSignalOk and typeof(productSignal) == "RBXScriptSignal" then
	productSignal:Connect(function(userIdOrPlayer, productId, wasPurchased)
		local player = resolvePlayer(userIdOrPlayer)
		if not player then
			return
		end
		recordEventForUserId(player.UserId, "purchase", "product_prompt_result", {
			item_id = productId,
			purchased = wasPurchased == true,
		})
		if wasPurchased then
			recordEventForUserId(player.UserId, "purchase", "robux_spent", {
				item_type = "product",
				item_id = productId,
			})
		end
	end)
end

task.spawn(function()
	while true do
		task.wait(FLUSH_INTERVAL_SECONDS)
		for userId in pairs(sessions) do
			flushSession(userId, false)
		end
	end
end)

game:BindToClose(function()
	for userId in pairs(sessions) do
		flushSession(userId, true)
	end
end)

print("[DataTelemetry] Game telemetry datastore pipeline active.")
