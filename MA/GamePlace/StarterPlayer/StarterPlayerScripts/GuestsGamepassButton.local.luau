-- DEPRECATED: Replaced by ShopClient.local.luau (unified shop)
if true then
	return
end

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")
local GAMEPASS_ID = 1708162428 -- 2x Guests gamepass

task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
	if not MainHUD then return end
	local Top = MainHUD:WaitForChild("Top", 10)
	if not Top then return end
	local TopBar = Top:WaitForChild("TopBar", 10)
	if not TopBar then return end
	local Guests = TopBar:WaitForChild("Guests", 10)
	if not Guests then return end
	
	local moreBtn = Guests:WaitForChild("More", 10)
	
	if moreBtn then
		if moreBtn:IsA("GuiButton") then
			moreBtn.MouseButton1Click:Connect(function()
				MarketplaceService:PromptGamePassPurchase(player, GAMEPASS_ID)
			end)
		else
			moreBtn.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					MarketplaceService:PromptGamePassPurchase(player, GAMEPASS_ID)
				end
			end)
		end
		print("[GuestsGamepassButton] Hooked to TopBar > Guests > More button")
	end
end)