--[=[ PATH: ServerScriptService/Server/DailyRewardsServer | TYPE: Server Script ]=]--
-- ════════════════════════════════════════════════════════════════════
--  DAILY REWARDS SERVER
--
--  Day 1–7 base payouts:
--    $5K / $10K / $15K / $25K / $35K / $50K / $100K  → then loops at day 7
--  Premium Rewards subscription (Sub_PremiumRewards) = 2× the above.
--
--  DataStore schema per userId ("DailyRewards_v1"):
--    {
--      streak     = N,           -- current consecutive-day streak (1–7 cap for reward tier)
--      lastClaim  = unix_ts,     -- os.time() of last successful claim
--    }
--
--  A new claim is valid if at least 20 hours have passed since the last
--  claim AND no more than 48 hours have passed (else streak resets to 1).
-- ════════════════════════════════════════════════════════════════════

local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CanonicalProfile = nil
do
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local profileModule = serverFolder and serverFolder:FindFirstChild("CanonicalPlayerProfile")
	if profileModule and profileModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, profileModule)
		if ok and type(loaded) == "table" then
			CanonicalProfile = loaded
		end
	end
end

-- ── CONFIGURATION ────────────────────────────────────────────────────
local DATASTORE_NAME     = "DailyRewards_v1"
local MIN_CLAIM_SECS     = 72000   -- 20 hours
local MAX_STREAK_SECS    = 172800  -- 48 hours (miss this → streak breaks)

local BASE_REWARDS = { 5000, 10000, 15000, 25000, 35000, 50000, 100000 }

local LegacyDailyStore = DataStoreService:GetDataStore(DATASTORE_NAME)
local DailyStore = if CanonicalProfile
	then CanonicalProfile.CreateUserStoreProxy(LegacyDailyStore, DATASTORE_NAME, "DailyRewards")
	else LegacyDailyStore

-- ── REMOTE SETUP ─────────────────────────────────────────────────────
local Events = ReplicatedStorage:WaitForChild("Events")

local function getOrCreate(className, name, parent)
	local obj = parent:FindFirstChild(name)
	if obj and obj:IsA(className) then return obj end
	if obj then obj:Destroy() end
	obj = Instance.new(className)
	obj.Name = name
	obj.Parent = parent
	return obj
end

-- Client opens the Daily Rewards UI → server sends current state
local RequestDailyInfo = getOrCreate("RemoteEvent", "RequestDailyInfo", Events)
-- Server pushes state to client (on join and after claim)
local DailyRewardInfo  = getOrCreate("RemoteEvent", "DailyRewardInfo",  Events)
-- Client claims their reward
local ClaimDailyReward = getOrCreate("RemoteEvent", "ClaimDailyReward", Events)
-- Notification for existing system
local NotificationEvent = Events:FindFirstChild("NotificationEvent")

-- ── HELPERS ─────────────────────────────────────────────────────────

local function notify(player, category, title, message, duration)
	if NotificationEvent then
		NotificationEvent:FireClient(player, category, title, message, duration or 4)
	end
end

local function grantMoney(player: Player, amount: number)
	local sss = game:GetService("ServerScriptService")
	local MoneyServer = sss:FindFirstChild("Server") and sss.Server:FindFirstChild("MoneyServer")
	if MoneyServer then
		local ev = MoneyServer:FindFirstChild("AddIncome")
		if ev and ev:IsA("BindableEvent") then
			ev:Fire(player, amount, "DailyReward", Enum.AnalyticsEconomyTransactionType.IAP)
			return true
		end
	end
	return false
end

local function fmtMoney(n: number): string
	if n >= 1e6 then return string.format("$%.1fM", n / 1e6)
	elseif n >= 1000 then return string.format("$%.0fK", n / 1000)
	end
	return "$" .. tostring(n)
end

local function loadRewardData(userId: number): {streak: number, lastClaim: number}
	local ok, data = pcall(function()
		return DailyStore:GetAsync(tostring(userId))
	end)
	if ok and type(data) == "table" then
		return {
			streak    = tonumber(data.streak) or 1,
			lastClaim = tonumber(data.lastClaim) or 0,
		}
	end
	return { streak = 1, lastClaim = 0 }
end

local function saveRewardData(userId: number, data: {streak: number, lastClaim: number})
	pcall(function()
		DailyStore:SetAsync(tostring(userId), data)
	end)
end

-- Returns the payout for a given streak day (1-indexed, loops at 7)
local function getBaseReward(streak: number): number
	local index = ((streak - 1) % #BASE_REWARDS) + 1
	return BASE_REWARDS[index]
end

-- Returns the second-level reward details table sent to the client
local function buildInfoPayload(player: Player, data: {streak: number, lastClaim: number})
	local now     = os.time()
	local elapsed = now - data.lastClaim
	local base    = getBaseReward(data.streak)
	local premium = player:GetAttribute("Sub_PremiumRewards") == true
	local reward  = premium and (base * 2) or base
	local canClaim = elapsed >= MIN_CLAIM_SECS
	local nextIn   = canClaim and 0 or (MIN_CLAIM_SECS - elapsed)
	local streakBroken = elapsed > MAX_STREAK_SECS and data.lastClaim > 0

	return {
		streak      = data.streak,
		reward      = reward,
		base        = base,
		premium     = premium,
		canClaim    = canClaim,
		nextIn      = nextIn,           -- seconds until next claim available
		streakBroken = streakBroken,    -- for client to show "streak reset" notice
	}
end

-- ── SERVER HANDLERS ──────────────────────────────────────────────────

RequestDailyInfo.OnServerEvent:Connect(function(player: Player)
	local data    = loadRewardData(player.UserId)
	local payload = buildInfoPayload(player, data)
	DailyRewardInfo:FireClient(player, payload)
end)

ClaimDailyReward.OnServerEvent:Connect(function(player: Player)
	local now  = os.time()
	local data = loadRewardData(player.UserId)
	local elapsed = now - data.lastClaim

	if elapsed < MIN_CLAIM_SECS then
		local remaining = MIN_CLAIM_SECS - elapsed
		local hrs  = math.floor(remaining / 3600)
		local mins = math.floor((remaining % 3600) / 60)
		notify(player, "Negative", "ALREADY CLAIMED",
			string.format("Next reward available in %dh %dm.", hrs, mins), 4)
		return
	end

	-- Streak logic
	if data.lastClaim > 0 and elapsed > MAX_STREAK_SECS then
		data.streak = 1  -- missed a day → reset
	end

	local base    = getBaseReward(data.streak)
	local premium = player:GetAttribute("Sub_PremiumRewards") == true
	local reward  = premium and (base * 2) or base

	local granted = grantMoney(player, reward)
	if not granted then
		notify(player, "Negative", "REWARD FAILED", "Could not deliver reward. Try again.", 4)
		return
	end

	local prevStreak = data.streak
	data.lastClaim = now
	data.streak    = data.streak + 1  -- advance for next day

	saveRewardData(player.UserId, data)

	local suffix = premium and " (2× Premium!)" or ""
	notify(player, "Money",
		string.format("DAY %d REWARD CLAIMED!", prevStreak),
		string.format("%s%s — Come back tomorrow for Day %d!", fmtMoney(reward), suffix, math.min(prevStreak + 1, #BASE_REWARDS)), 6)

	-- Push updated state to client
	local payload = buildInfoPayload(player, data)
	DailyRewardInfo:FireClient(player, payload)
end)

-- ── SEND STATE ON JOIN ───────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player: Player)
	task.delay(5, function()
		if not player:IsDescendantOf(game) then return end
		local data    = loadRewardData(player.UserId)
		local payload = buildInfoPayload(player, data)
		DailyRewardInfo:FireClient(player, payload)
	end)
end)
