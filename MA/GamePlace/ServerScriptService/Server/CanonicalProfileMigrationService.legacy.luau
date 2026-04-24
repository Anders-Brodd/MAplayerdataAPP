local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local serverFolder = ServerScriptService:FindFirstChild("Server")
if not serverFolder then
	warn("[CanonicalProfileMigration] Server folder not found; migration disabled.")
	return
end

local profileModuleScript = serverFolder:FindFirstChild("CanonicalPlayerProfile")
if not profileModuleScript or not profileModuleScript:IsA("ModuleScript") then
	warn("[CanonicalProfileMigration] CanonicalPlayerProfile module missing; migration disabled.")
	return
end

local CanonicalProfile = require(profileModuleScript)

local function migratePlayer(player)
	if not player then
		return
	end
	task.spawn(function()
		local ok, result = CanonicalProfile.MigrateUserFromLegacy(player.UserId)
		if not ok then
			warn("[CanonicalProfileMigration] Migration failed for user " .. tostring(player.UserId) .. ": " .. tostring(result))
		end
	end)
end

Players.PlayerAdded:Connect(migratePlayer)
for _, player in ipairs(Players:GetPlayers()) do
	migratePlayer(player)
end

print("[CanonicalProfileMigration] Legacy-to-canonical migration bridge active.")
