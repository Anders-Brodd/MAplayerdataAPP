local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")

local SLOT_STORE_NAME = "TycoonSlotsData"
local SLOT_LIST_PAGE_SIZE = 100
local BETWEEN_USER_DELAY_SECONDS = 0.2
local MIN_GET_BUDGET = 20
local MIN_UPDATE_BUDGET = 1
local BUDGET_WAIT_TIMEOUT_SECONDS = 20

local SlotStore = DataStoreService:GetDataStore(SLOT_STORE_NAME)

local function resolveModuleScript(candidates)
	for _, candidate in ipairs(candidates) do
		if candidate and candidate:IsA("ModuleScript") then
			return candidate
		end
	end
	return nil
end

local canonicalModuleScript = ServerScriptService:WaitForChild("Server"):WaitForChild("CanonicalPlayerProfile")

if not canonicalModuleScript then
	warn("[CanonicalBulkMigration] CanonicalPlayerProfile module missing. Command service disabled.")
	return
end

local canonicalRequireOk, CanonicalProfile = pcall(require, canonicalModuleScript)
if not canonicalRequireOk or type(CanonicalProfile) ~= "table" or type(CanonicalProfile.MigrateUserFromLegacy) ~= "function" then
	warn("[CanonicalBulkMigration] Failed to load CanonicalPlayerProfile module. Command service disabled.")
	return
end

local giveawayAccessModuleScript = resolveModuleScript({
	ServerScriptService:FindFirstChild("Server") and ServerScriptService.Server:FindFirstChild("GiveawayAccess"),
	ServerScriptService:FindFirstChild("GiveawayAccess"),
	script.Parent.Parent and script.Parent.Parent:FindFirstChild("GiveawayAccess"),
})

local GiveawayAccess = nil
if giveawayAccessModuleScript then
	local accessOk, accessResult = pcall(require, giveawayAccessModuleScript)
	if accessOk then
		GiveawayAccess = accessResult
	end
end

local GROUP_ID = 398051359
local MIN_RANK = 200
local ADMIN_USERS = {
	[8843215003] = true,
	[game.CreatorId] = true,
}

local function isAdmin(player)
	if not player then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if ADMIN_USERS[player.UserId] then
		return true
	end
	if GiveawayAccess and GiveawayAccess.HasAdminAccess then
		local ok, result = pcall(function()
			return GiveawayAccess.HasAdminAccess(player.UserId)
		end)
		if ok and result == true then
			return true
		end
	end
	local rankOk, rank = pcall(function()
		return player:GetRankInGroup(GROUP_ID)
	end)
	return rankOk and rank and rank >= MIN_RANK
end

local Events = ReplicatedStorage:FindFirstChild("Events")
local NotificationEvent = Events and Events:FindFirstChild("NotificationEvent")

local function notify(player, category, title, message, duration)
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") and player then
		NotificationEvent:FireClient(player, category, title, message, duration or 6)
	end
end

local function getRequestBudget(requestTypeName)
	local requestType = Enum.DataStoreRequestType[requestTypeName]
	if not requestType then
		return nil
	end
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	if ok then
		return tonumber(budget)
	end
	return nil
end

local function waitForBudget(requestTypeName, minimum, timeoutSeconds)
	local startedAt = os.clock()
	while true do
		local budget = getRequestBudget(requestTypeName)
		if budget == nil or budget >= minimum then
			return true
		end
		if os.clock() - startedAt > timeoutSeconds then
			return false
		end
		task.wait(0.25)
	end
end

local function waitForMigrationBudget()
	waitForBudget("GetAsync", MIN_GET_BUDGET, BUDGET_WAIT_TIMEOUT_SECONDS)
	waitForBudget("UpdateAsync", MIN_UPDATE_BUDGET, BUDGET_WAIT_TIMEOUT_SECONDS)
end

local function discoverAllUserIds(maxUsers)
	local userIds = {}
	local seen = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if not seen[player.UserId] then
			seen[player.UserId] = true
			table.insert(userIds, player.UserId)
		end
	end

	local ok, pagesOrErr = pcall(function()
		return SlotStore:ListKeysAsync("User_", SLOT_LIST_PAGE_SIZE)
	end)
	if not ok or not pagesOrErr then
		warn("[CanonicalBulkMigration] ListKeysAsync failed: " .. tostring(pagesOrErr))
		return userIds
	end

	local pages = pagesOrErr
	while true do
		for _, keyInfo in ipairs(pages:GetCurrentPage()) do
			local keyName = keyInfo.KeyName or keyInfo.Key or keyInfo.name
			local userId = keyName and tonumber(string.match(tostring(keyName), "^User_(%d+)$"))
			if userId and not seen[userId] then
				seen[userId] = true
				table.insert(userIds, userId)
				if maxUsers and #userIds >= maxUsers then
					return userIds
				end
			end
		end

		if pages.IsFinished then
			break
		end

		local advanceOk, advanceErr = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			warn("[CanonicalBulkMigration] Failed to advance key pages: " .. tostring(advanceErr))
			break
		end

		task.wait(0.15)
	end

	return userIds
end

local job = {
	Running = false,
	StopRequested = false,
	Mode = "idle",
	Total = 0,
	Processed = 0,
	Succeeded = 0,
	Failed = 0,
	CurrentUserId = nil,
	StartedAt = 0,
	EndedAt = 0,
	LastError = nil,
	LastResult = nil,
}

local function summarizeJob()
	local elapsed = 0
	if job.StartedAt > 0 then
		local stopAt = job.Running and os.clock() or job.EndedAt
		elapsed = math.max(0, stopAt - job.StartedAt)
	end
	return string.format(
		"mode=%s running=%s total=%d processed=%d ok=%d failed=%d current=%s elapsed=%.1fs",
		tostring(job.Mode),
		tostring(job.Running),
		job.Total,
		job.Processed,
		job.Succeeded,
		job.Failed,
		tostring(job.CurrentUserId or "none"),
		elapsed
	)
end

local function resetJob(mode, total)
	job.Running = true
	job.StopRequested = false
	job.Mode = mode
	job.Total = total
	job.Processed = 0
	job.Succeeded = 0
	job.Failed = 0
	job.CurrentUserId = nil
	job.StartedAt = os.clock()
	job.EndedAt = 0
	job.LastError = nil
	job.LastResult = nil
end

local function finalizeJob(result)
	job.Running = false
	job.EndedAt = os.clock()
	job.CurrentUserId = nil
	job.LastResult = result
end

local function migrateSingleUser(userId)
	local retries = 3
	local backoff = 0.8
	local lastErr = nil

	for attempt = 1, retries do
		waitForMigrationBudget()

		local callOk, migrateOk, details = pcall(function()
			return CanonicalProfile.MigrateUserFromLegacy(userId)
		end)

		if callOk and migrateOk then
			return true, details
		end

		if callOk then
			lastErr = details or "migration returned false"
		else
			lastErr = migrateOk
		end

		if attempt < retries then
			task.wait(backoff)
			backoff = math.min(3, backoff * 1.75)
		end
	end

	return false, lastErr
end

local function startBulkMigration(invoker, mode, maxUsers)
	if job.Running then
		notify(invoker, "Negative", "Migration Busy", "A migration job is already running.", 6)
		return
	end

	local userIds
	if mode == "online" then
		userIds = {}
		for _, player in ipairs(Players:GetPlayers()) do
			table.insert(userIds, player.UserId)
		end
	else
		userIds = discoverAllUserIds(maxUsers)
	end

	if maxUsers and #userIds > maxUsers then
		while #userIds > maxUsers do
			table.remove(userIds)
		end
	end

	if #userIds == 0 then
		notify(invoker, "Negative", "Migration", "No users found to migrate.", 6)
		return
	end

	resetJob(mode, #userIds)
	notify(invoker, "Info", "Migration Started", string.format("Queued %d users (%s mode).", #userIds, mode), 6)

	task.spawn(function()
		for _, userId in ipairs(userIds) do
			if job.StopRequested then
				break
			end

			job.CurrentUserId = userId
			local ok, result = migrateSingleUser(userId)
			job.Processed += 1
			if ok then
				job.Succeeded += 1
			else
				job.Failed += 1
				job.LastError = tostring(result)
				warn("[CanonicalBulkMigration] User " .. tostring(userId) .. " failed: " .. tostring(result))
			end

			if job.Processed % 25 == 0 or job.Processed == job.Total then
				print("[CanonicalBulkMigration] Progress: " .. summarizeJob())
			end

			task.wait(BETWEEN_USER_DELAY_SECONDS)
		end

		if job.StopRequested then
			finalizeJob("stopped")
		else
			finalizeJob("completed")
		end

		local summary = summarizeJob()
		print("[CanonicalBulkMigration] Finished: " .. summary)
		notify(invoker, "Positive", "Migration Finished", summary, 8)
	end)
end

local function migrateTargetUser(invoker, userId)
	if type(userId) ~= "number" or userId < 1 then
		notify(invoker, "Negative", "Migration", "Invalid user id.", 6)
		return
	end

	task.spawn(function()
		notify(invoker, "Info", "Migration", "Migrating user " .. tostring(userId) .. "...", 4)
		local ok, err = migrateSingleUser(userId)
		if ok then
			notify(invoker, "Positive", "Migration", "User " .. tostring(userId) .. " migrated.", 5)
		else
			notify(invoker, "Negative", "Migration", "Failed for user " .. tostring(userId) .. ": " .. tostring(err), 8)
		end
	end)
end

local function ensureTextCommand(name, alias)
	local chatCommands = TextChatService:FindFirstChild("TextChatCommands")
	if not chatCommands then
		chatCommands = Instance.new("Folder")
		chatCommands.Name = "TextChatCommands"
		chatCommands.Parent = TextChatService
	end

	local existing = chatCommands:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local cmd = Instance.new("TextChatCommand")
	cmd.Name = name
	cmd.PrimaryAlias = alias
	cmd.SecondaryAlias = alias
	cmd.Parent = chatCommands
	return cmd
end

local migrateCommand = ensureTextCommand("MigrateProfiles", "/migrateprofiles")

migrateCommand.Triggered:Connect(function(origin, message)
	local player = Players:GetPlayerByUserId(origin.UserId)
	if not isAdmin(player) then
		return
	end

	local args = {}
	for token in string.gmatch(tostring(message or ""), "%S+") do
		table.insert(args, token)
	end

	local action = string.lower(tostring(args[2] or "status"))

	if action == "status" then
		notify(player, "Info", "Migration Status", summarizeJob(), 8)
		return
	end

	if action == "stop" or action == "cancel" then
		if job.Running then
			job.StopRequested = true
			notify(player, "Info", "Migration", "Stop requested. Finishing current user then exiting.", 6)
		else
			notify(player, "Info", "Migration", "No migration job is currently running.", 6)
		end
		return
	end

	if action == "user" then
		local userId = tonumber(args[3])
		migrateTargetUser(player, userId)
		return
	end

	if action == "start" then
		local mode = string.lower(tostring(args[3] or "all"))
		local maxUsers = tonumber(args[4])
		if mode ~= "all" and mode ~= "online" then
			local modeAsNumber = tonumber(mode)
			if modeAsNumber then
				maxUsers = modeAsNumber
				mode = "all"
			else
				mode = "all"
			end
		end
		if maxUsers then
			maxUsers = math.max(1, math.floor(maxUsers + 0.5))
		end
		startBulkMigration(player, mode, maxUsers)
		return
	end

	notify(player, "Info", "Migration Command", "Use /migrateprofiles start [all|online] [maxUsers], /migrateprofiles status, /migrateprofiles stop, or /migrateprofiles user <userId>", 10)
end)

print("[CanonicalBulkMigration] Command ready: /migrateprofiles")
