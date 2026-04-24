local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))

local isFounder = false
for _ = 1, 16 do
	local ok, result = pcall(function()
		return EntitlementManager.HasFounderStatus(player.UserId)
	end)
	if ok and result == true then
		isFounder = true
		break
	end
	task.wait(0.25)
end

if not isFounder then
	return
end

local gui = playerGui:WaitForChild("FounderThankYouToast")

task.wait(1)
gui:Destroy()
