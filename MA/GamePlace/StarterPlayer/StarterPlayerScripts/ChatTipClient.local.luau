local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Events = ReplicatedStorage:WaitForChild("Events")
local TipEvent = Events:WaitForChild("ServerTipBroadcast")

local PREFIX_PLAIN = "[SERVER TIP]"
local PREFIX_RICH = "<font color='#59D7FF'><b>[SERVER TIP]</b></font>"

local function escapeRichText(text)
	text = tostring(text or "")
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	return text
end

local function showLegacySystemMessage(rawTip)
	pcall(function()
		StarterGui:SetCore("ChatMakeSystemMessage", {
			Text = string.format("%s %s", PREFIX_PLAIN, tostring(rawTip)),
			Color = Color3.fromRGB(89, 215, 255),
			Font = Enum.Font.GothamBold,
			TextSize = 18,
		})
	end)
end

local function showTextChatMessage(rawTip)
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	local generalChannel = textChannels and textChannels:FindFirstChild("RBXGeneral")
	if not generalChannel then
		return false
	end

	local richTip = string.format("%s <font color='#FFF2B2'>%s</font>", PREFIX_RICH, escapeRichText(rawTip))
	local ok = pcall(function()
		generalChannel:DisplaySystemMessage(richTip)
	end)
	return ok
end

local function onTipReceived(rawTip)
	if type(rawTip) ~= "string" or rawTip == "" then
		return
	end
	if not showTextChatMessage(rawTip) then
		showLegacySystemMessage(rawTip)
	end
end

TipEvent.OnClientEvent:Connect(onTipReceived)
