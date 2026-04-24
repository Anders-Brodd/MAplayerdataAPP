--[[
    [MODERN DEV PANEL - SERVER KERNEL]
    > Handles security, admin actions, and replication.
    > Logic only. No UI.
    > UPDATED: Added Ban/Unban system with DataStore persistence
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")

-- Ban DataStore
local BanStore = DataStoreService:GetDataStore("DevPanel_Bans_V1")
-- Server Code DataStore (same as TeleportHandler uses)
local ServerCodeStore = DataStoreService:GetDataStore("TycoonServerCodesData")
-- Leaderboard DataStores
local LeaderboardMetaStore = DataStoreService:GetDataStore("LobbyLeaderboardMeta_v1")
local LeaderboardOrderedStores = {
	Richest = DataStoreService:GetOrderedDataStore("LobbyRichest_v1"),
	BiggestResort = DataStoreService:GetOrderedDataStore("LobbyBiggestResort_v1"),
	MostLifts = DataStoreService:GetOrderedDataStore("LobbyMostLifts_v1"),
	MostSlopes = DataStoreService:GetOrderedDataStore("LobbyMostSlopes_v1"),
	MostGuests = DataStoreService:GetOrderedDataStore("LobbyMostGuests_v1"),
	BestRating = DataStoreService:GetOrderedDataStore("LobbyBestRating_v1"),
}
local MessagingService = game:GetService("MessagingService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local GiveawayAccess = require(script.Parent:WaitForChild("GiveawayAccess"))
local DatastoreManagerService = require(script.Parent:WaitForChild("DatastoreManagerService"))

-- // CONFIGURATION //
local CONFIG = {
	GROUP_ID = 398051359,
	MIN_RANK = 240,
	SUPER_ADMINS = {
		[8843215003] = true, 
		[1090907828] = true,
		[1624020068] = true, 
		[389306460] = true,
		-- [1306183746] = true,
		[1215727369] = true,
		[2257761857] = true,
		[1903168889] = true,
		[game.CreatorId] = true
	}
}

local ALL_USEFUL_PASS_IDS = {
	1733258476,
	1724355823,
	1708600326,
	1705719197,
	1707796502,
	1708924275,
	1708162428,
	1704778044,
	1705274438,
	1683937935,
}

-- // SETUP REMOTES //
-- Use FindFirstChild to avoid conflict with ServerBrowser.lua
local Events = ReplicatedStorage:FindFirstChild("DevPanelEvents")
if not Events then
	Events = Instance.new("Folder")
	Events.Name = "DevPanelEvents"
	Events.Parent = ReplicatedStorage
end

local ActionRemote = Events:FindFirstChild("ActionRequest") or Instance.new("RemoteEvent", Events)
ActionRemote.Name = "ActionRequest"

local ToastRemote = Events:FindFirstChild("ToastNotification") or Instance.new("RemoteEvent", Events)
ToastRemote.Name = "ToastNotification"

local GetServerList = Events:FindFirstChild("GetServerList") or Instance.new("RemoteFunction", Events)
GetServerList.Name = "GetServerList"

local TeleportToServer = Events:FindFirstChild("TeleportToServer") or Instance.new("RemoteFunction", Events)
TeleportToServer.Name = "TeleportToServer"

local ShutdownServer = Events:FindFirstChild("ShutdownServer") or Instance.new("RemoteEvent", Events)
ShutdownServer.Name = "ShutdownServer"

local GetErrorLogs = Events:FindFirstChild("GetErrorLogs") or Instance.new("RemoteFunction", Events)
GetErrorLogs.Name = "GetErrorLogs"

local CheckAdmin = Events:FindFirstChild("CheckAdmin") or Instance.new("RemoteFunction", Events)
CheckAdmin.Name = "CheckAdmin"

local CheckDatastoreManagerAccess = Events:FindFirstChild("CheckDatastoreManagerAccess") or Instance.new("RemoteFunction", Events)
CheckDatastoreManagerAccess.Name = "CheckDatastoreManagerAccess"

local DatastoreRequest = Events:FindFirstChild("DatastoreRequest") or Instance.new("RemoteFunction", Events)
DatastoreRequest.Name = "DatastoreRequest"

local ToggleDevPanel = Events:FindFirstChild("ToggleDevPanel") or Instance.new("RemoteEvent", Events)
ToggleDevPanel.Name = "ToggleDevPanel"

local LeaderboardRequest = Events:FindFirstChild("LeaderboardRequest") or Instance.new("RemoteFunction", Events)
LeaderboardRequest.Name = "LeaderboardRequest"

local ResolveTargetUser
local GetEntitlementManager

-- // SECURITY & HELPERS //
local function IsAdmin(player)
	if CONFIG.SUPER_ADMINS[player.UserId] then return true end

	local hasGiveawayAdmin = false
	local accessOk, accessResult = pcall(function()
		return GiveawayAccess.HasAdminAccess(player.UserId)
	end)
	if accessOk and accessResult == true then
		hasGiveawayAdmin = true
	end
	if hasGiveawayAdmin then
		return true
	end

	local s, r = pcall(function() return player:GetRankInGroup(CONFIG.GROUP_ID) end)
	return (s and r >= CONFIG.MIN_RANK)
end

local function IsSuperAdmin(player)
	return player and CONFIG.SUPER_ADMINS[player.UserId] == true
end

CheckAdmin.OnServerInvoke = function(player)
	return IsAdmin(player) == true
end

CheckDatastoreManagerAccess.OnServerInvoke = function(player)
	return IsSuperAdmin(player)
end

DatastoreRequest.OnServerInvoke = function(player, action, payload)
	if not IsSuperAdmin(player) then
		return {
			Success = false,
			Error = "Unauthorized",
		}
	end

	payload = payload or {}
	action = tostring(action or "")

	if action == "ResolveUser" then
		local targetName = tostring(payload.Target or "")
		local targetUserId, targetDisplayName, targetPlayer = nil, nil, nil
		if type(ResolveTargetUser) == "function" then
			targetUserId, targetDisplayName, targetPlayer = ResolveTargetUser(targetName)
		end
		if not targetUserId and targetName ~= "" then
			local directPlayer = Players:FindFirstChild(targetName)
			if directPlayer and directPlayer:IsA("Player") then
				targetUserId = directPlayer.UserId
				targetDisplayName = directPlayer.Name
				targetPlayer = directPlayer
			end
		end
		if not targetUserId then
			return {
				Success = false,
				Error = "Unable to resolve user",
			}
		end
		return {
			Success = true,
			UserId = targetUserId,
			Name = targetDisplayName,
			Online = targetPlayer ~= nil,
		}
	end

	if action == "DiscoverSlots" then
		local ok, slotsOrErr = DatastoreManagerService.DiscoverSlots(payload.UserId)
		if not ok then
			return { Success = false, Error = tostring(slotsOrErr) }
		end
		return {
			Success = true,
			Slots = slotsOrErr,
		}
	end

	if action == "LoadSlot" then
		local ok, dataOrErr = DatastoreManagerService.LoadSlot(payload.UserId, payload.SlotNum)
		if not ok then
			return { Success = false, Error = tostring(dataOrErr) }
		end
		return {
			Success = true,
			Data = dataOrErr,
		}
	end

	if action == "SaveSlot" then
		local targetPlayer = Players:GetPlayerByUserId(tonumber(payload.UserId) or -1)
		local activeOwner = type(_G.GetSessionOwnerUserId) == "function" and _G.GetSessionOwnerUserId() or nil
		local activeSlot = type(_G.GetSessionSlotNum) == "function" and _G.GetSessionSlotNum() or nil
		local shouldOfferRefresh = targetPlayer ~= nil
			and tonumber(activeOwner) == tonumber(payload.UserId)
			and tonumber(activeSlot) == tonumber(payload.SlotNum)

		if payload.PreviewOnly == true then
			return {
				Success = true,
				OnlineRefreshAvailable = shouldOfferRefresh,
				PreviewOnly = true,
			}
		end

		local ok, err = DatastoreManagerService.SaveSlot(payload.UserId, payload.SlotNum, payload.Patch)
		if not ok then
			DatastoreManagerService.AppendAudit({
				Action = "SaveSlot",
				ActorUserId = player.UserId,
				TargetUserId = payload.UserId,
				SlotNum = payload.SlotNum,
				Success = false,
				Summary = tostring(err),
			})
			return { Success = false, Error = tostring(err) }
		end

		local refreshApplied = false
		if shouldOfferRefresh and payload.ApplyOnlineRefresh == true then
			local mainEvents = ReplicatedStorage:FindFirstChild("Events")
			local refreshBindable = mainEvents and mainEvents:FindFirstChild("AdminRefreshWorld")
			if refreshBindable and refreshBindable:IsA("BindableFunction") then
				local refreshOk, refreshResult = pcall(function()
					return refreshBindable:Invoke(player, payload.UserId, payload.SlotNum)
				end)
				refreshApplied = refreshOk and refreshResult == true
			end
			if not refreshApplied then
				DatastoreManagerService.AppendAudit({
					Action = "SaveSlot",
					ActorUserId = player.UserId,
					TargetUserId = payload.UserId,
					SlotNum = payload.SlotNum,
					Success = false,
					Summary = "saved_but_refresh_failed",
				})
				return {
					Success = false,
					Error = "Save succeeded, but live world refresh failed.",
					Saved = true,
				}
			end
		end

		DatastoreManagerService.AppendAudit({
			Action = "SaveSlot",
			ActorUserId = player.UserId,
			TargetUserId = payload.UserId,
			SlotNum = payload.SlotNum,
			Success = true,
			Summary = refreshApplied and "saved+refreshed" or "saved",
		})

		return {
			Success = true,
			OnlineRefreshAvailable = shouldOfferRefresh,
			OnlineRefreshApplied = refreshApplied,
		}
	end

	if action == "WipeSlot" then
		local ok, err = DatastoreManagerService.WipeSlot(payload.UserId, payload.SlotNum)
		if not ok then
			DatastoreManagerService.AppendAudit({
				Action = "WipeSlot",
				ActorUserId = player.UserId,
				TargetUserId = payload.UserId,
				SlotNum = payload.SlotNum,
				Success = false,
				Summary = tostring(err),
			})
			return { Success = false, Error = tostring(err) }
		end
		DatastoreManagerService.AppendAudit({
			Action = "WipeSlot",
			ActorUserId = player.UserId,
			TargetUserId = payload.UserId,
			SlotNum = payload.SlotNum,
			Success = true,
			Summary = "wiped",
		})
		return { Success = true }
	end

	return {
		Success = false,
		Error = "Unknown action",
	}
end

local function SendToast(player, toastType, title, message)
	ToastRemote:FireClient(player, toastType, title, message)
end

local function getResearchAdminRequest()
	local events = ReplicatedStorage:FindFirstChild("Events")
	local bindable = events and events:FindFirstChild("AdminResearchRequest")
	if bindable and bindable:IsA("BindableFunction") then
		return bindable
	end
	return nil
end

local function runResearchAdminAction(targetPlayer, action)
	local bindable = getResearchAdminRequest()
	if not bindable then
		return false, "Research admin bridge unavailable"
	end
	local ok, success, err = pcall(function()
		return bindable:Invoke(targetPlayer, action)
	end)
	if not ok then
		return false, tostring(success)
	end
	if success ~= true then
		return false, tostring(err or "Research admin action failed")
	end
	return true, nil
end

local function grantAllUsefulPasses(targetUserId)
	local entitlement = GetEntitlementManager()
	if not entitlement then
		return false, "EntitlementManager failed to load."
	end
	for _, passId in ipairs(ALL_USEFUL_PASS_IDS) do
		local ok, err = entitlement.GrantPass(targetUserId, passId)
		if not ok then
			return false, tostring(err or ("Failed to grant pass " .. tostring(passId)))
		end
	end
	return true, nil
end

local function GetTarget(nameString)
	if not nameString or nameString == "" then return nil end
	nameString = string.lower(nameString)
	for _, p in ipairs(Players:GetPlayers()) do
		if string.lower(p.Name):sub(1, #nameString) == nameString or 
			string.lower(p.DisplayName):sub(1, #nameString) == nameString then
			return p
		end
	end
	return nil
end

local GetUserIdFromName

ResolveTargetUser = function(nameString)
	local targetPlayer = GetTarget(nameString)
	if targetPlayer then
		return targetPlayer.UserId, targetPlayer.Name, targetPlayer
	end

	if not nameString or nameString == "" then
		return nil, nil, nil
	end

	local userId = GetUserIdFromName(nameString)
	if userId then
		return userId, nameString, nil
	end

	return nil, nil, nil
end

local CachedEntitlementManager = nil
GetEntitlementManager = function()
	if CachedEntitlementManager then
		return CachedEntitlementManager
	end

	local moduleScript = ReplicatedStorage:FindFirstChild("EntitlementManager")
	if not moduleScript then
		return nil
	end

	local success, result = pcall(require, moduleScript)
	if success then
		CachedEntitlementManager = result
		return CachedEntitlementManager
	end

	return nil
end

-- // BAN SYSTEM FUNCTIONS //
GetUserIdFromName = function(name)
	local success, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if success then
		return userId
	end
	return nil
end

local function IsPlayerBanned(userId)
	local success, banData = pcall(function()
		return BanStore:GetAsync("Ban_" .. tostring(userId))
	end)
	if success and banData then
		return true, banData
	end
	return false, nil
end

local function BanPlayer(userId, reason, bannedBy)
	local banData = {
		Reason = reason or "No reason provided",
		BannedBy = bannedBy,
		BannedAt = os.time()
	}
	local success, err = pcall(function()
		BanStore:SetAsync("Ban_" .. tostring(userId), banData)
	end)
	return success, err
end

local function UnbanPlayer(userId)
	local success, err = pcall(function()
		BanStore:RemoveAsync("Ban_" .. tostring(userId))
	end)
	return success, err
end

-- // CHECK BANS ON JOIN //
Players.PlayerAdded:Connect(function(player)
	local isBanned, banData = IsPlayerBanned(player.UserId)
	if isBanned then
		local reason = banData and banData.Reason or "You are banned from this game."
		player:Kick("[BANNED] " .. reason)
	end
end)

-- // MAIN HANDLER //
ActionRemote.OnServerEvent:Connect(function(player, category, action, data)
	if not IsAdmin(player) then 
		return 
	end
	data = data or {}

	local targetPlayer = GetTarget(data.Target)

	-- :: MODERATION ::
	if category == "Moderation" then
		local reason = data.Reason or "No reason provided."

		-- UNBAN doesn't need online target - uses username to find UserId
		if action == "Unban" then
			local targetName = data.Target
			if not targetName or targetName == "" then
				SendToast(player, "Error", "Target Required", "Please enter a username to unban.")
				return
			end

			-- Get UserId from username
			local targetUserId = GetUserIdFromName(targetName)
			if not targetUserId then
				SendToast(player, "Error", "User Not Found", "Could not find user: " .. targetName)
				return
			end

			-- Check if they're actually banned
			local isBanned, _ = IsPlayerBanned(targetUserId)
			if not isBanned then
				SendToast(player, "Warning", "Not Banned", targetName .. " is not currently banned.")
				return
			end

			-- Unban them
			local success, err = UnbanPlayer(targetUserId)
			if success then
				SendToast(player, "Success", "Unbanned", "Successfully unbanned " .. targetName)
			else
				SendToast(player, "Error", "Unban Failed", "DataStore error: " .. tostring(err))
			end
			return
		end

		-- All other moderation actions need an online target
		if not targetPlayer then 
			SendToast(player, "Error", "Target Not Found", "Could not find online player: " .. (data.Target or "nil"))
			return 
		end

		if action == "Kick" then
			targetPlayer:Kick(reason)
			SendToast(player, "Success", "Kicked", "Kicked " .. targetPlayer.Name)

		elseif action == "Ban" then
			-- Save to DataStore for persistence
			local success, err = BanPlayer(targetPlayer.UserId, reason, player.Name)
			if success then
				targetPlayer:Kick("[BANNED] " .. reason)
				SendToast(player, "Success", "Banned", "Permanently banned " .. targetPlayer.Name)
			else
				-- Still kick them even if DataStore fails
				targetPlayer:Kick("[BANNED] " .. reason)
				SendToast(player, "Warning", "Partial Ban", "Kicked " .. targetPlayer.Name .. " but DataStore failed: " .. tostring(err))
			end

		elseif action == "TeleportTo" then
			if player.Character and targetPlayer.Character then
				player.Character:PivotTo(targetPlayer.Character:GetPivot() * CFrame.new(0, 0, 5))
			end

		elseif action == "Bring" then
			if player.Character and targetPlayer.Character then
				targetPlayer.Character:PivotTo(player.Character:GetPivot() * CFrame.new(0, 0, -5))
			end

		elseif action == "Kill" then
			if targetPlayer.Character then targetPlayer.Character:BreakJoints() end
			SendToast(player, "Info", "Action", "Killed " .. targetPlayer.Name)

		elseif action == "Freeze" then
			if targetPlayer.Character then
				for _, part in ipairs(targetPlayer.Character:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = true end
				end
			end
			SendToast(player, "Info", "Action", "Frozen " .. targetPlayer.Name)

		elseif action == "Thaw" then
			if targetPlayer.Character then
				for _, part in ipairs(targetPlayer.Character:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = false end
				end
			end
			SendToast(player, "Info", "Action", "Thawed " .. targetPlayer.Name)
		end

		-- :: ECONOMY ::
	elseif category == "Economy" then
		local amount = tonumber(data.Amount)

		if not amount or amount == 0 then
			SendToast(player, "Error", "Invalid Amount", "Please enter a valid number (received: " .. tostring(data.Amount) .. ")")
			return
		end

		local MoneyServer = ServerScriptService.Server:FindFirstChild("MoneyServer")

		if not MoneyServer then
			SendToast(player, "Error", "System Error", "MoneyServer script not found in ServerScriptService")
			return
		end

		local AddIncome = MoneyServer:FindFirstChild("AddIncome")
		local SetSharedMoney = MoneyServer:FindFirstChild("SetSharedMoney")

		if AddIncome and SetSharedMoney then
			if action == "Add" then
				AddIncome:Fire(player, amount, "AdminPanel", Enum.AnalyticsEconomyTransactionType.Gameplay)
				SendToast(player, "Success", "Economy", "Added $" .. tostring(amount) .. " to Shared Bank")

			elseif action == "Set" then
				local currentTickets = ServerScriptService:GetAttribute("ServerTickets") or 0
				SetSharedMoney:Fire(amount, currentTickets)
				SendToast(player, "Success", "Economy", "Set Shared Bank to $" .. tostring(amount))
			end
		else
			SendToast(player, "Error", "System Error", "MoneyServer BindableEvents not found")
		end

		-- :: SERVER ::
	elseif category == "Server" then
		if action == "Shutdown" then
			local msg = data.Message or "Server Restarting..."
			SendToast(player, "Warning", "Shutdown", "Server is shutting down...")
			task.wait(2)
			for _, p in ipairs(Players:GetPlayers()) do
				p:Kick(msg)
			end

		elseif action == "Announce" then
			for _, p in ipairs(Players:GetPlayers()) do
				ToastRemote:FireClient(p, "Info", "ANNOUNCEMENT", data.Message or "Alert")
			end
		end

		-- :: SCIENCE ::
	elseif category == "Science" then
		if action == "Add" then
			local amount = tonumber(data.Amount) or 0
			ServerScriptService:SetAttribute("ServerScience", (ServerScriptService:GetAttribute("ServerScience") or 0) + amount)
			SendToast(player, "Success", "Science", "Added " .. amount .. " Science")
		elseif action == "Set" then
			local amount = tonumber(data.Amount) or 0
			ServerScriptService:SetAttribute("ServerScience", amount)
			SendToast(player, "Success", "Science", "Set Science to " .. amount)
		elseif action == "GrantAccolade" then
			SendToast(player, "Info", "Accolade", "Granted " .. (data.Name or "Unknown") .. " to server")
		end

		-- :: GAMEPASSES ::
	elseif category == "Gamepass" then
		local targetUserId, targetName, targetPlayer = ResolveTargetUser(data.Target)
		if not targetUserId then
			SendToast(player, "Error", "Target Required", "Enter a valid username.")
			return
		end

		local entitlement = GetEntitlementManager()
		if not entitlement then
			SendToast(player, "Error", "System Error", "EntitlementManager failed to load.")
			return
		end

		if action == "GrantFounder" then
			local ok, err = entitlement.GrantFounder(targetUserId)
			if ok then
				SendToast(player, "Success", "Founder Granted", "Granted founder status to " .. targetName)
				if targetPlayer then
					SendToast(targetPlayer, "Info", "Founder Status", "You were granted founder status by a developer.")
				end
			else
				SendToast(player, "Error", "Founder Grant Failed", tostring(err or "Unknown error"))
			end
			return
		elseif action == "GrantAllPasses" then
			local ok, err = grantAllUsefulPasses(targetUserId)
			if ok then
				SendToast(player, "Success", "Pass Bundle Granted", "Granted all useful passes to " .. targetName)
				if targetPlayer then
					SendToast(targetPlayer, "Info", "Developer Bundle", "A developer granted you the full pass bundle.")
				end
			else
				SendToast(player, "Error", "Bundle Grant Failed", tostring(err or "Unknown error"))
			end
			return
		elseif action == "GrantDevBundle" then
			local bundleOk, bundleErr = grantAllUsefulPasses(targetUserId)
			if not bundleOk then
				SendToast(player, "Error", "Bundle Grant Failed", tostring(bundleErr or "Unknown error"))
				return
			end
			if not targetPlayer then
				SendToast(player, "Warning", "Player Offline", "Passes were granted, but research unlock requires the player to be online in this server.")
				return
			end
			local researchOk, researchErr = runResearchAdminAction(targetPlayer, "UnlockAll")
			if researchOk then
				SendToast(player, "Success", "Dev Bundle Granted", "Granted passes and unlocked all research for " .. targetName)
				SendToast(targetPlayer, "Info", "Developer Bundle", "A developer granted you passes and all research.")
			else
				SendToast(player, "Warning", "Partial Bundle", "Passes granted, but research unlock failed: " .. tostring(researchErr))
			end
			return
		end

		local passId = tonumber(data.PassId)
		if not passId or passId <= 0 then
			SendToast(player, "Error", "Invalid Pass ID", "Enter a numeric gamepass ID.")
			return
		end

		if action == "Grant" then
			local ok, err = entitlement.GrantPass(targetUserId, passId)
			if ok then
				SendToast(player, "Success", "Gamepass Granted", ("Granted %d to %s"):format(passId, targetName))
				if targetPlayer then
					SendToast(targetPlayer, "Info", "Gamepass Granted", ("A developer granted you pass %d."):format(passId))
				end
			else
				SendToast(player, "Error", "Grant Failed", tostring(err or "Unknown error"))
			end
		elseif action == "Revoke" then
			local ok, err = entitlement.RevokePass(targetUserId, passId)
			if ok then
				SendToast(player, "Success", "Gamepass Revoked", ("Revoked %d from %s"):format(passId, targetName))
				if targetPlayer then
					SendToast(targetPlayer, "Warning", "Gamepass Revoked", ("A developer revoked pass %d."):format(passId))
				end
			else
				SendToast(player, "Error", "Revoke Failed", tostring(err or "Unknown error"))
			end
		end

	elseif category == "ResearchAdmin" then
		if not targetPlayer then
			SendToast(player, "Error", "Target Must Be Online", "Research admin tools only work for players currently in this server.")
			return
		end
		if action == "UnlockAll" then
			local ok, err = runResearchAdminAction(targetPlayer, "UnlockAll")
			if ok then
				SendToast(player, "Success", "Research Unlocked", "Unlocked all research for " .. targetPlayer.Name)
				SendToast(targetPlayer, "Info", "Developer Unlock", "All research was unlocked by a developer.")
			else
				SendToast(player, "Error", "Research Unlock Failed", tostring(err or "Unknown error"))
			end
		elseif action == "MaxRP" then
			local ok, err = runResearchAdminAction(targetPlayer, "MaxRP")
			if ok then
				SendToast(player, "Success", "Research Points Filled", "Set research points to max for " .. targetPlayer.Name)
				SendToast(targetPlayer, "Info", "Developer RP", "Your research points were filled by a developer.")
			else
				SendToast(player, "Error", "RP Fill Failed", tostring(err or "Unknown error"))
			end
		end
	end
end)

-- ============================================================
-- LEADERBOARD MANAGEMENT
-- ============================================================

LeaderboardRequest.OnServerInvoke = function(player, action, payload)
	if not IsAdmin(player) then
		return { Success = false, Error = "Unauthorized" }
	end
	payload = payload or {}
	action = tostring(action or "")

	if action == "GetTopEntries" then
		local boardName = tostring(payload.Board or "")
		local store = LeaderboardOrderedStores[boardName]
		if not store then
			return { Success = false, Error = "Invalid board: " .. boardName }
		end
		local count = math.clamp(tonumber(payload.Count) or 25, 1, 100)
		local ok, pages = pcall(function()
			return store:GetSortedAsync(false, count)
		end)
		if not ok then
			return { Success = false, Error = "DataStore error: " .. tostring(pages) }
		end
		local entries = {}
		local pageOk, pageData = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not pageOk or type(pageData) ~= "table" then
			return { Success = false, Error = "Failed to read page data" }
		end
		for _, entry in ipairs(pageData) do
			local meta = nil
			local metaOk, metaResult = pcall(function()
				return LeaderboardMetaStore:GetAsync(entry.key)
			end)
			if metaOk and type(metaResult) == "table" then
				meta = metaResult
			end
			table.insert(entries, {
				Key = entry.key,
				Value = entry.value,
				Meta = meta,
			})
		end
		return { Success = true, Entries = entries }
	end

	if action == "EditEntry" then
		local boardName = tostring(payload.Board or "")
		local key = tostring(payload.Key or "")
		local value = tonumber(payload.Value)
		local store = LeaderboardOrderedStores[boardName]
		if not store then
			return { Success = false, Error = "Invalid board" }
		end
		if key == "" then
			return { Success = false, Error = "Key required" }
		end
		if not value then
			return { Success = false, Error = "Numeric value required" }
		end
		local ok, err = pcall(function()
			store:SetAsync(key, value)
		end)
		if not ok then
			return { Success = false, Error = tostring(err) }
		end
		SendToast(player, "Success", "Leaderboard", "Updated " .. boardName .. " entry for " .. key)
		return { Success = true }
	end

	if action == "RemoveEntry" then
		local boardName = tostring(payload.Board or "")
		local key = tostring(payload.Key or "")
		local store = LeaderboardOrderedStores[boardName]
		if not store then
			return { Success = false, Error = "Invalid board" }
		end
		if key == "" then
			return { Success = false, Error = "Key required" }
		end
		local ok, err = pcall(function()
			store:RemoveAsync(key)
		end)
		if not ok then
			return { Success = false, Error = tostring(err) }
		end
		SendToast(player, "Success", "Leaderboard", "Removed " .. boardName .. " entry for " .. key)
		return { Success = true }
	end

	if action == "RemoveAllBoards" then
		local key = tostring(payload.Key or "")
		if key == "" then
			return { Success = false, Error = "Key required" }
		end
		local errors = {}
		for boardName, store in pairs(LeaderboardOrderedStores) do
			local ok, err = pcall(function()
				store:RemoveAsync(key)
			end)
			if not ok then
				table.insert(errors, boardName .. ": " .. tostring(err))
			end
		end
		pcall(function()
			LeaderboardMetaStore:RemoveAsync(key)
		end)
		if #errors > 0 then
			return { Success = false, Error = table.concat(errors, "; ") }
		end
		SendToast(player, "Success", "Leaderboard", "Removed all entries + meta for " .. key)
		return { Success = true }
	end

	if action == "AddEntry" then
		local boardName = tostring(payload.Board or "")
		local store = LeaderboardOrderedStores[boardName]
		if not store then
			return { Success = false, Error = "Invalid board" }
		end
		local userId = tonumber(payload.UserId)
		local slotNum = tonumber(payload.SlotNum) or 1
		local value = tonumber(payload.Value)
		if not userId then
			return { Success = false, Error = "UserId required" }
		end
		if not value then
			return { Success = false, Error = "Numeric value required" }
		end
		local key = string.format("Resort_%d_%d", userId, slotNum)
		local ok, err = pcall(function()
			store:SetAsync(key, value)
		end)
		if not ok then
			return { Success = false, Error = tostring(err) }
		end
		SendToast(player, "Success", "Leaderboard", "Added " .. boardName .. " entry: " .. key .. " = " .. tostring(value))
		return { Success = true, Key = key }
	end

	return { Success = false, Error = "Unknown leaderboard action" }
end

-- ============================================================
-- 1. ERROR LOGGING SYSTEM
-- ============================================================

local ErrorLogs = {}
local MAX_LOGS = 50

local function LogError(message, trace, type)
	table.insert(ErrorLogs, 1, {
		Message = message,
		Trace = trace or "",
		Type = type or "Error",
		Time = os.time()
	})
	if #ErrorLogs > MAX_LOGS then
		table.remove(ErrorLogs, #ErrorLogs)
	end
end

ScriptContext.Error:Connect(function(message, trace, script)
	local scriptName = script and script.Name or "Unknown"
	LogError(message, trace, "Error")
end)

LogService.MessageOut:Connect(function(message, type)
	if type == Enum.MessageType.MessageError then
		-- Handled by ScriptContext usually, but good fallback
	elseif type == Enum.MessageType.MessageWarning then
		LogError(message, nil, "Warning")
	end
end)

GetErrorLogs.OnServerInvoke = function(player)
	if not IsAdmin(player) then return nil end
	return ErrorLogs
end

-- ============================================================
-- 2. SERVER BROWSER (MessagingService)
-- ============================================================

local ActiveServers = {}
local SERVER_TOPIC = "DevPanel_ServerHeartbeat"

-- Subscribe to heartbeats
pcall(function()
	MessagingService:SubscribeAsync(SERVER_TOPIC, function(message)
		local data = message.Data
		if data and data.JobId then
			ActiveServers[data.JobId] = {
				JobId = data.JobId,
				PlaceId = data.PlaceId,
				PlayerCount = data.PlayerCount,
				MaxPlayers = data.MaxPlayers,
				Uptime = data.Uptime,
				Players = data.Players, -- List of names
				AccessCode = data.AccessCode, -- Reserved server access code
				OwnerId = data.OwnerId, -- For DataStore lookup
				SlotNum = data.SlotNum, -- For DataStore lookup
				IsReserved = data.IsReserved,
				LastUpdate = os.time()
			}
		end
	end)
end)

-- Get this server's reserved access code if available (from TeleportData)
local ThisServerAccessCode = nil
local ThisServerOwnerId = nil
local ThisServerSlotNum = nil

-- Function to try to get access code from a player's join data
local function TryGetAccessCode(player)
	if ThisServerAccessCode then return end -- Already have it

	local success, joinData = pcall(function()
		return player:GetJoinData()
	end)

	if success and joinData then
		if joinData.TeleportData then
			if joinData.TeleportData.JoinCode then
				ThisServerAccessCode = joinData.TeleportData.JoinCode
			end
			-- Also capture UserId and SlotNum for lookup purposes
			if joinData.TeleportData.UserId then
				ThisServerOwnerId = joinData.TeleportData.UserId
			end
			if joinData.TeleportData.SlotNum then
				ThisServerSlotNum = joinData.TeleportData.SlotNum
			end
		end
	end
end

-- Check existing players
for _, player in ipairs(Players:GetPlayers()) do
	TryGetAccessCode(player)
end

-- Also check any new players that join (in case we missed it)
Players.PlayerAdded:Connect(function(player)
	task.wait(1) -- Give time for join data to populate
	TryGetAccessCode(player)
end)

-- Publish heartbeat
task.spawn(function()
	while true do
		local success, err = pcall(function()
			local playerNames = {}
			for _, p in ipairs(Players:GetPlayers()) do
				table.insert(playerNames, {Name = p.Name, DisplayName = p.DisplayName})
			end

			-- Check if this is a reserved/private server
			local isReserved = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil

			local data = {
				JobId = game.JobId,
				PlaceId = game.PlaceId,
				PlayerCount = #Players:GetPlayers(),
				MaxPlayers = Players.MaxPlayers,
				Uptime = Workspace.DistributedGameTime,
				Players = playerNames,
				AccessCode = ThisServerAccessCode, -- Include access code for reserved server teleports
				OwnerId = ThisServerOwnerId, -- Include for DataStore lookup
				SlotNum = ThisServerSlotNum, -- Include for DataStore lookup
				IsReserved = isReserved
			}
			MessagingService:PublishAsync(SERVER_TOPIC, data)
		end)
		task.wait(10) -- Updates every 10s
	end
end)

GetServerList.OnServerInvoke = function(player)
	if not IsAdmin(player) then return nil end
	-- Clean up old servers (stale > 30s)
	local now = os.time()
	local freshList = {}
	for jobId, data in pairs(ActiveServers) do
		if now - data.LastUpdate < 30 then
			table.insert(freshList, data)
		else
			ActiveServers[jobId] = nil
		end
	end

	-- Sort by player count
	table.sort(freshList, function(a, b) return a.PlayerCount > b.PlayerCount end)

	return {
		CurrentServer = game.JobId,
		Servers = freshList
	}
end

local TeleportService = game:GetService("TeleportService")

-- Helper function to look up access code from DataStore
local function LookupAccessCodeFromDataStore(ownerId, slotNum)
	if not ownerId or not slotNum then return nil end

	local success, codeData = pcall(function()
		return ServerCodeStore:GetAsync("User_" .. ownerId .. "_Slot" .. slotNum)
	end)

	if success and codeData and codeData.Code then
		return codeData.Code
	end

	return nil
end

TeleportToServer.OnServerInvoke = function(player, targetJobId)
	if not IsAdmin(player) then return {Success = false, Error = "Unauthorized"} end

	if targetJobId == game.JobId then
		return {Success = false, Error = "Already in this server"}
	end

	-- Check if we have info about this server from heartbeats
	local serverInfo = ActiveServers[targetJobId]

	-- Try multiple teleport methods
	local success, err
	local accessCode = nil

	-- METHOD 1: Use access code from heartbeat broadcast
	if serverInfo and serverInfo.AccessCode then
		accessCode = serverInfo.AccessCode
	end

	-- METHOD 2: Look up access code from DataStore using OwnerId/SlotNum
	if not accessCode and serverInfo and serverInfo.OwnerId and serverInfo.SlotNum then
		accessCode = LookupAccessCodeFromDataStore(serverInfo.OwnerId, serverInfo.SlotNum)
		if accessCode then
		end
	end

	-- Try teleport with access code if we have it
	if accessCode then
		success, err = pcall(function()
			local teleportOptions = Instance.new("TeleportOptions")
			teleportOptions.ReservedServerAccessCode = accessCode
			TeleportService:TeleportAsync(serverInfo.PlaceId or game.PlaceId, {player}, teleportOptions)
		end)
		if success then
			return {Success = true}
		end
	end

	-- METHOD 3: Try TeleportToPlaceInstance for public servers
	success, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(serverInfo.PlaceId or game.PlaceId, targetJobId, player)
	end)

	if success then
		return {Success = true}
	end

	-- METHOD 4: Try TeleportAsync with ServerInstanceId (works for some server types)
	success, err = pcall(function()
		local teleportOptions = Instance.new("TeleportOptions")
		teleportOptions.ServerInstanceId = targetJobId
		TeleportService:TeleportAsync(serverInfo.PlaceId or game.PlaceId, {player}, teleportOptions)
	end)

	if success then
		return {Success = true}
	end

	return {Success = false, Error = "Server is a private/reserved server. Could not obtain access code. Error: " .. tostring(err)}
end

ShutdownServer.OnServerEvent:Connect(function(player, targetJobId, reason)
	if not IsAdmin(player) then return end
	if targetJobId == game.JobId then
		-- Local shutdown
		for _, p in ipairs(Players:GetPlayers()) do p:Kick("Server Shutdown: " .. (reason or "Maintenance")) end
	else
		-- Global shutdown request? (Requires PubSub to tell that server to die)
		-- For now, we only support local shutdown via this, or we'd need another Topic.
		-- Let's stick to local shutdown for "Shutdown This Server" button.
	end
end)
