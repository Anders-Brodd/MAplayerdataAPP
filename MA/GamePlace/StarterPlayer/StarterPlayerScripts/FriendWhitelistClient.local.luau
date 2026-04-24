-- DEPRECATED: Friend whitelist UI is now integrated into SettingsController (Multiplayer tab).
-- This file is no longer used and can be safely deleted.
if true then
	return
end

local ADD_FRIEND_SLOT_PRODUCT_ID = 3575008862

-- ── GUI REFS ──────────────────────────────────────────────────────────
local gui = PlayerGui:WaitForChild("FriendWhitelistGui", 10)
if not gui then
	warn("[FriendWhitelistClient] FriendWhitelistGui not found. Run FriendWhitelistCMDBar first.")
	return
end

local bg        = gui:WaitForChild("BG")
local panel     = bg:WaitForChild("Panel")
local slotsLbl  = panel:FindFirstChild("SlotsLabel")
local friendList= panel:FindFirstChild("FriendList")
local emptyLbl  = friendList and friendList:FindFirstChild("EmptyLabel")
local addSection= panel:FindFirstChild("AddSection")
local inputBox  = addSection and addSection:FindFirstChild("UsernameInput")
local addBtn    = addSection and addSection:FindFirstChild("AddBtn")
local buyBtn    = panel:FindFirstChild("BuyBtn")
local closeBtn  = panel:FindFirstChild("Close")

-- ── STATE ─────────────────────────────────────────────────────────────
local currentFriends: {number} = {}
local totalSlots = 0

-- ── HELPERS ───────────────────────────────────────────────────────────

local function setVisible(show: boolean)
	gui.Enabled = show
end

local function clearList()
	if not friendList then return end
	for _, child in ipairs(friendList:GetChildren()) do
		if child:IsA("Frame") and child.Name:match("^FriendEntry_") then
			child:Destroy()
		end
	end
end

local function buildEntry(userId: number, index: number)
	if not friendList then return end
	local entry = Instance.new("Frame")
	entry.Name             = "FriendEntry_" .. userId
	entry.Size             = UDim2.new(1, 0, 0, 40)
	entry.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
	entry.BorderSizePixel  = 0
	entry.LayoutOrder      = index
	entry.Parent           = friendList
	Instance.new("UICorner", entry).CornerRadius = UDim.new(0, 6)

	-- Try to resolve username asynchronously
	local nameLabel = Instance.new("TextLabel", entry)
	nameLabel.Name             = "Name"
	nameLabel.Text             = "UserId: " .. userId
	nameLabel.Size             = UDim2.new(1, -80, 1, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3       = Color3.fromRGB(220, 220, 240)
	nameLabel.TextSize         = 13
	nameLabel.Font             = Enum.Font.Gotham
	nameLabel.TextXAlignment   = Enum.TextXAlignment.Left
	Instance.new("UIPadding", nameLabel).PaddingLeft = UDim.new(0, 10)

	task.spawn(function()
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and name and nameLabel and nameLabel.Parent then
			nameLabel.Text = "@" .. name
		end
	end)

	-- Remove button
	local removeBtn = Instance.new("TextButton", entry)
	removeBtn.Name             = "Remove"
	removeBtn.Text             = "Remove"
	removeBtn.Size             = UDim2.new(0, 68, 0, 28)
	removeBtn.Position         = UDim2.new(1, -76, 0.5, -14)
	removeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	removeBtn.BorderSizePixel  = 0
	removeBtn.TextColor3       = Color3.new(1, 1, 1)
	removeBtn.TextSize         = 12
	removeBtn.Font             = Enum.Font.GothamBold
	Instance.new("UICorner", removeBtn).CornerRadius = UDim.new(0, 6)

	removeBtn.MouseButton1Click:Connect(function()
		UpdateFriendWhitelist:FireServer("remove", userId)
		entry:Destroy()
		-- Refresh
		task.delay(0.5, function()
			RequestFriendWhitelist:FireServer()
		end)
	end)
end

local function applyWhitelistData(data)
	if type(data) ~= "table" then return end
	totalSlots = tonumber(data.slots) or 0
	currentFriends = {}
	for _, uid in ipairs(data.friends or {}) do
		table.insert(currentFriends, uid)
	end

	if slotsLbl then
		slotsLbl.Text = string.format("%d / %d friend slots used", #currentFriends, totalSlots)
	end

	clearList()
	if emptyLbl then
		emptyLbl.Visible = #currentFriends == 0
	end
	for i, uid in ipairs(currentFriends) do
		buildEntry(uid, i)
	end
end

-- ── REMOTE BINDINGS ───────────────────────────────────────────────────

-- Note: server fires SlotPurchaseUpdate which we piggyback for auto-refresh
SlotPurchaseUpdate.OnClientEvent:Connect(function(data)
	if type(data) == "table" then
		-- Re-request whitelist to get fresh friend list + updated slot count
		task.spawn(function()
			RequestFriendWhitelist:FireServer()
		end)
	end
end)

-- Server sends whitelist data in response to RequestFriendWhitelist
-- (Reusing the same BindableEvent response; SlotPurchaseHandler fires back to client)
-- The server sends via player:FireClient which maps to SlotPurchaseUpdate.
-- (If the server is sending via a different remote, just adjust the event name here.)

-- Add friend
if addBtn and inputBox then
	addBtn.MouseButton1Click:Connect(function()
		local raw = inputBox.Text:match("^%s*(.-)%s*$")
		if raw == "" then return end
		local uid = tonumber(raw)
		if uid then
			UpdateFriendWhitelist:FireServer("add", uid)
		else
			-- Try to resolve username
			task.spawn(function()
				local ok, resolved = pcall(function()
					return Players:GetUserIdFromNameAsync(raw)
				end)
				if ok and resolved then
					UpdateFriendWhitelist:FireServer("add", resolved)
				else
					-- Show error via attribute notification
					warn("[FriendWhitelistClient] Could not resolve player:", raw)
				end
			end)
		end
		inputBox.Text = ""
		task.delay(0.8, function() RequestFriendWhitelist:FireServer() end)
	end)
end

-- Buy more slots
if buyBtn then
	buyBtn.MouseButton1Click:Connect(function()
		MarketplaceService:PromptProductPurchase(player, ADD_FRIEND_SLOT_PRODUCT_ID)
	end)
end

-- Close
if closeBtn then
	closeBtn.MouseButton1Click:Connect(function()
		setVisible(false)
	end)
end

bg.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		setVisible(false)
	end
end)

-- ── OPEN TRIGGER ──────────────────────────────────────────────────────
local openBind = Events:FindFirstChild("OpenFriendWhitelist")
if openBind and openBind:IsA("BindableEvent") then
	openBind.Event:Connect(function()
		RequestFriendWhitelist:FireServer()
		setVisible(true)
	end)
end
