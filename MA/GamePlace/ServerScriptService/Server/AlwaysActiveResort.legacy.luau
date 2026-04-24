--[=[ PATH: ServerScriptService/Server/AlwaysActiveResort | TYPE: Server Script ]=]--
-- ════════════════════════════════════════════════════════════════════
--  ALWAYS ACTIVE RESORT
--  When the resort owner has the "Always Active Resort" pass (1793522272)
--  or Resort Pass subscription, their current join code / job ID is
--  stored persistently in a DataStore under their UserId+SlotNum key.
--
--  Players who use the join code while the owner is offline are
--  teleported to any existing server running that slot's resort, or
--  receive a "resort is offline" message if no server is running.
--
--  JoinCodeSystem keeps the MemoryStore pin alive for EXPIRATION seconds
--  (40); this script extends that by writing a persistent DataStore
--  entry that the LobbyPlace / JoinCode UI can read to show "Always Open".
--
--  Schema stored per resort key ("userId_slotNum"):
--    {
--      JobId       = "...",    -- last known Roblox JobId
--      PlaceId     = 123,      -- game PlaceId
--      UpdatedAt   = 1234567,  -- os.time() of last write
--      ResortName  = "...",
--      OwnerName   = "...",
--    }
-- ════════════════════════════════════════════════════════════════════

local DataStoreService   = game:GetService("DataStoreService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")

-- ── CONFIGURATION ────────────────────────────────────────────────────
local ALWAYS_ACTIVE_PASS_ID  = 1793522272
local DATASTORE_NAME         = "AlwaysActiveResorts_v1"
local UPDATE_INTERVAL        = 60   -- re-write our JobId every 60 seconds
local STALE_THRESHOLD_SECS   = 180  -- entries older than 3 min are treated as offline

local AlwaysActiveStore = DataStoreService:GetDataStore(DATASTORE_NAME)

-- ── HELPERS ─────────────────────────────────────────────────────────

local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))

local function getResortKey(): string?
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	if not slotData then return nil end
	local userId  = tonumber((slotData:FindFirstChild("UserId") or {}).Value)
	local slotNum = tonumber((slotData:FindFirstChild("SlotNum") or {}).Value)
	if not userId or userId <= 0 then return nil end
	return tostring(userId) .. "_" .. tostring(slotNum or 1)
end

local function getResortName(): string
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	local nameVal  = slotData and slotData:FindFirstChild("ResortName")
	return (nameVal and nameVal.Value ~= "") and nameVal.Value or "Resort"
end

local function getOwner(): Player?
	local getOwnerFn = rawget(_G, "GetSessionOwnerUserId")
	local ownerId = type(getOwnerFn) == "function" and getOwnerFn() or nil
	if ownerId then
		return Players:GetPlayerByUserId(ownerId)
	end
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	local userId   = tonumber(slotData and slotData:FindFirstChild("UserId") and slotData.UserId.Value)
	return userId and Players:GetPlayerByUserId(userId) or Players:GetPlayers()[1]
end

local function ownerHasPass(): boolean
	local owner = getOwner()
	if not owner then return false end
	if EntitlementManager.HasAccess(owner, ALWAYS_ACTIVE_PASS_ID) then return true end
	if owner:GetAttribute("Sub_ResortPass") == true then return true end
	if owner:GetAttribute("ResortPassGrant_" .. tostring(ALWAYS_ACTIVE_PASS_ID)) == true then return true end
	return false
end

local function writeActiveEntry()
	if RunService:IsStudio() then return end  -- don't pollute DS in Studio
	local key = getResortKey()
	if not key then return end

	local owner = getOwner()
	local entry = {
		JobId      = game.JobId,
		PlaceId    = game.PlaceId,
		UpdatedAt  = os.time(),
		ResortName = getResortName(),
		OwnerName  = owner and owner.Name or "",
	}

	pcall(function()
		AlwaysActiveStore:SetAsync(key, entry)
	end)
end

local function clearActiveEntry()
	if RunService:IsStudio() then return end
	local key = getResortKey()
	if not key then return end
	pcall(function()
		AlwaysActiveStore:RemoveAsync(key)
	end)
end

-- ── HEARTBEAT LOOP ───────────────────────────────────────────────────
-- Continuously renew the persistent entry while the owner is online
-- and has the pass. Stops renewing (leaves entry to expire) if the
-- owner logs off, so a stale entry doesn't mislead players.

local heartbeatRunning = false

local function startHeartbeat()
	if heartbeatRunning then return end
	heartbeatRunning = true
	task.spawn(function()
		while true do
			task.wait(UPDATE_INTERVAL)
			if ownerHasPass() then
				writeActiveEntry()
			else
				-- Pass was revoked or owner left — stop heartbeat
				heartbeatRunning = false
				break
			end
		end
	end)
end

-- ── PLAYER / SLOT LIFECYCLE ──────────────────────────────────────────

Players.PlayerAdded:Connect(function(player: Player)
	-- Use attribute set by SubscriptionManager once it loads (~3s)
	task.delay(5, function()
		if not player:IsDescendantOf(game) then return end
		local owner = getOwner()
		if owner and owner == player and ownerHasPass() then
			writeActiveEntry()
			startHeartbeat()
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local owner = getOwner()
	-- If the owner is leaving and no other players remain, clear the entry
	-- (server will shut down; entry would be stale)
	if owner and owner == player then
		-- Give 5 second grace in case it's a rejoin
		task.delay(5, function()
			if #Players:GetPlayers() == 0 then
				clearActiveEntry()
			end
		end)
	end
end)

game:BindToClose(function()
	-- If owner has pass, write one final entry before shutdown so the entry
	-- reflects the very last known JobId (could help Lobby show "was recently active")
	-- Then clear it since the server is gone.
	clearActiveEntry()
end)

-- ── PUBLIC API (BindableFunction for LobbyPlace queries) ─────────────
-- Other scripts can invoke "QueryAlwaysActive" to read resort status.
local Events = ReplicatedStorage:WaitForChild("Events")
local query  = Events:FindFirstChild("QueryAlwaysActive")
if not query then
	query = Instance.new("BindableFunction")
	query.Name   = "QueryAlwaysActive"
	query.Parent = Events
end
local QueryAlwaysActive = query :: BindableFunction

QueryAlwaysActive.OnInvoke = function(userId: number, slotNum: number)
	local key   = tostring(userId) .. "_" .. tostring(slotNum or 1)
	local ok, data = pcall(function()
		return AlwaysActiveStore:GetAsync(key)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	-- Check freshness: entry older than STALE_THRESHOLD_SECS is treated as offline
	if (os.time() - (tonumber(data.UpdatedAt) or 0)) > STALE_THRESHOLD_SECS then
		return nil
	end
	return data
end
