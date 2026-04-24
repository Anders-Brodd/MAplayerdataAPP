local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local GiveawayAccess = {}

local IS_SERVER = RunService:IsServer()
local ADMIN_STORE_NAME = "DiscordGiveawayAdminAccessV1"
local CACHE_TTL_SECONDS = 45

local AdminStore = if IS_SERVER then DataStoreService:GetDataStore(ADMIN_STORE_NAME) else nil
local Cache = {}

local function writeCache(userId, hasAccess)
	Cache[userId] = {
		hasAccess = hasAccess == true,
		checkedAt = os.clock(),
	}
end

local function readCache(userId)
	local cached = Cache[userId]
	if not cached then
		return nil
	end
	if (os.clock() - (cached.checkedAt or 0)) > CACHE_TTL_SECONDS then
		return nil
	end
	return cached.hasAccess == true
end

function GiveawayAccess.HasAdminAccess(userId)
	userId = tonumber(userId)
	if not userId or userId <= 0 then
		return false
	end

	local cached = readCache(userId)
	if cached ~= nil then
		return cached
	end

	if not IS_SERVER or not AdminStore then
		return false
	end

	local ok, data = pcall(function()
		return AdminStore:GetAsync(tostring(userId))
	end)
	if not ok then
		writeCache(userId, false)
		return false
	end

	local hasAccess = false
	if data == true then
		hasAccess = true
	elseif type(data) == "table" then
		hasAccess = data.enabled == true or data.admin == true
	end

	writeCache(userId, hasAccess)
	return hasAccess
end

function GiveawayAccess.GrantAdminAccess(userId, source)
	if not IS_SERVER or not AdminStore then
		return false, "server_only"
	end

	userId = tonumber(userId)
	if not userId or userId <= 0 then
		return false, "invalid_user"
	end

	local payload = {
		enabled = true,
		admin = true,
		grantedAt = os.time(),
		source = source,
	}

	local ok, err = pcall(function()
		AdminStore:UpdateAsync(tostring(userId), function(existing)
			if existing == true then
				return existing
			end
			if type(existing) == "table" and (existing.enabled == true or existing.admin == true) then
				return existing
			end
			return payload
		end)
	end)

	if not ok then
		return false, tostring(err)
	end

	writeCache(userId, true)
	return true, nil
end

return GiveawayAccess