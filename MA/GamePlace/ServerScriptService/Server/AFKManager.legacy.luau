-- DEPRECATED: AFK limits removed
if true then
	return
end

--[=[ PATH: ServerScriptService/Server/AFKManager | TYPE: Server Script ]=]--
-- ════════════════════════════════════════════════════════════════════
--  AFK MANAGER
--  Detects when the resort owner has been AFK for too long and gates
--  the GlobalLeaderboardPublisher accordingly.
--
--  Rules:
--    • Owner idle > AFK_THRESHOLD_SECS (10 min) → IsAFK = true → leaderboard
--      publishing is suppressed UNLESS one of the following is true:
--        a) Owner has "AFK Leaderboard Exemption" pass (1792990026)
--        b) Owner has Resort Pass subscription (Sub_ResortPass attribute)
--        c) AfkAdBoostActive attribute is true (watched an ad → 30 min grace)
--
--    • Client fires "PlayerActivity" RemoteEvent on any input.
--      Server resets the idle timer for that player.
--
--  The leaderboard gate is implemented here via a BindableFunction
--  "IsOwnerAFK" that GlobalLeaderboardPublisher calls before publishing.
-- ════════════════════════════════════════════════════════════════════

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ── CONFIGURATION ────────────────────────────────────────────────────
local AFK_THRESHOLD_SECS = 600   -- 10 minutes of no input = AFK
local AFK_PASS_ID        = 1792990026

-- ── REMOTE / BINDABLE SETUP ──────────────────────────────────────────
local Events = ReplicatedStorage:WaitForChild("Events")

local function getOrCreateRemote(className, name, parent)
	local obj = parent:FindFirstChild(name)
	if obj and obj:IsA(className) then return obj end
	if obj then obj:Destroy() end
	obj = Instance.new(className)
	obj.Name = name
	obj.Parent = parent
	return obj
end

-- Client fires this RemoteEvent on any meaningful input (keyboard/mouse/touch/gamepad).
local PlayerActivity = getOrCreateRemote("RemoteEvent", "PlayerActivity", Events)

-- GlobalLeaderboardPublisher invokes this to check if publishing should be skipped.
local IsOwnerAFKFunc = getOrCreateRemote("BindableFunction", "IsOwnerAFK", Events)

-- ── STATE ────────────────────────────────────────────────────────────
local lastActivityTime: {[number]: number} = {}  -- [userId] = os.time()

-- ── HELPERS ─────────────────────────────────────────────────────────

local function getResortOwnerPlayer(): Player?
	-- _G.GetSessionOwnerUserId is set by SlotDataLoader; fall back to first player.
	local getOwner = rawget(_G, "GetSessionOwnerUserId")
	local ownerId = type(getOwner) == "function" and getOwner() or nil
	if ownerId then
		return Players:GetPlayerByUserId(ownerId)
	end
	-- Fallback: use SlotData IntValue in ReplicatedStorage
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	local userIdVal = slotData and slotData:FindFirstChild("UserId")
	local id = userIdVal and tonumber(userIdVal.Value)
	if id and id > 0 then
		return Players:GetPlayerByUserId(id)
	end
	return Players:GetPlayers()[1] or nil
end

local function isExempt(player: Player): boolean
	-- Pass ownership
	local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
	if EntitlementManager.HasAccess(player, AFK_PASS_ID) then return true end
	-- Resort Pass subscription
	if player:GetAttribute("Sub_ResortPass") == true then return true end
	if player:GetAttribute("ResortPassGrant_" .. tostring(AFK_PASS_ID)) == true then return true end
	-- Ad-granted temporary exemption
	if player:GetAttribute("AfkAdBoostActive") == true then return true end
	return false
end

local function isOwnerAFK(): boolean
	local owner = getResortOwnerPlayer()
	if not owner then return false end  -- no owner in server = not AFK from our perspective
	if isExempt(owner) then return false end

	local last = lastActivityTime[owner.UserId]
	if not last then return false end  -- no data yet, assume active
	return (os.time() - last) >= AFK_THRESHOLD_SECS
end

-- ── BINDABLE HANDLER ─────────────────────────────────────────────────
IsOwnerAFKFunc.OnInvoke = function(): boolean
	return isOwnerAFK()
end

-- ── CLIENT ACTIVITY RECEIVER ─────────────────────────────────────────
PlayerActivity.OnServerEvent:Connect(function(player: Player)
	lastActivityTime[player.UserId] = os.time()
	-- Clear AFK flag only if it was set
	if player:GetAttribute("IsAFK") == true then
		player:SetAttribute("IsAFK", nil)
	end
end)

-- ── IDLE TICKER ──────────────────────────────────────────────────────
task.spawn(function()
	while true do
		task.wait(30)
		local now = os.time()
		local owner = getResortOwnerPlayer()
		if owner then
			local last = lastActivityTime[owner.UserId]
			if last and (now - last) >= AFK_THRESHOLD_SECS then
				if owner:GetAttribute("IsAFK") ~= true then
					owner:SetAttribute("IsAFK", true)
				end
			else
				if owner:GetAttribute("IsAFK") == true then
					owner:SetAttribute("IsAFK", nil)
				end
			end
		end
	end
end)

-- ── PLAYER LIFECYCLE ─────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player: Player)
	lastActivityTime[player.UserId] = os.time()  -- joining counts as activity
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastActivityTime[player.UserId] = nil
	player:SetAttribute("IsAFK", nil)
end)
