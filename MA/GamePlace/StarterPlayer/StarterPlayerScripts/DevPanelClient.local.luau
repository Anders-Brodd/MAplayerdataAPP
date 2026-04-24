--[[
    [MODERN DEV PANEL - CLIENT CONTROLLER V3.2]
    > Server Browser Tab with FIXED teleportation
    > Ban/Unban System
    > Proper handling of reserved/private servers
    > Toggle via /dev command or server event
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- // ASSETS & CONFIG //
local THEME = {
	Background = Color3.fromRGB(20, 20, 25),
	Sidebar = Color3.fromRGB(28, 28, 35),
	Card = Color3.fromRGB(35, 35, 42),
	Accent = Color3.fromRGB(114, 137, 218),
	Destructive = Color3.fromRGB(240, 71, 71),
	Success = Color3.fromRGB(67, 181, 129),
	Warning = Color3.fromRGB(250, 166, 26),
	TextMain = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(160, 160, 160),
	Input = Color3.fromRGB(15, 15, 20),
	Online = Color3.fromRGB(67, 181, 129),
	CurrentServer = Color3.fromRGB(114, 137, 218)
}

local FONTS = {
	Header = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Light = Enum.Font.Gotham
}

local GAMEPASS_PRESETS = {
	{Name = "Sandbox Mode", Id = 1733258476},
	{Name = "Extra Slots", Id = 1724355823},
	{Name = "More Employees", Id = 1708600326},
	{Name = "Time Setter", Id = 1705719197},
	{Name = "Weather Controler", Id = 1707796502},
	{Name = "2x Money", Id = 1708924275},
	{Name = "2x Guests", Id = 1708162428},
	{Name = "Controller+", Id = 1704778044},
	{Name = "Freecam+", Id = 1705274438},
	{Name = "Pre-Order", Id = 1683937935},
}

-- // UI STATE //
local UI_STATE = {
	CurrentPage = "Overview",
	IsVisible = false,
	Inputs = {
		Target = "",
		Reason = "",
		Amount = "0",
		PassId = "",
		DataSlot = "1",
		DataMoney = "",
		DataTickets = "",
		DataResearchRP = "",
		DataResearchMaxRP = "",
		DataBuildingJson = "",
		DataTerrainJson = ""
	},
	ServerList = {},
	Datastore = {
		ResolvedUserId = nil,
		ResolvedName = nil,
		DiscoveredSlots = {},
		Loaded = nil,
		BuildingObjects = {},
		SelectedBuildingIndex = nil,
	}
}

-- Ensure Remotes Exist
local Events = ReplicatedStorage:WaitForChild("DevPanelEvents", 10)
if not Events then
end

local ActionRemote = Events and Events:FindFirstChild("ActionRequest") or nil
local ToastRemote = Events and Events:FindFirstChild("ToastNotification") or nil
local GetServersRemote = Events and Events:FindFirstChild("GetServerList") or nil
local TeleportRemote = Events and Events:FindFirstChild("TeleportToServer") or nil
local ShutdownRemote = Events and Events:FindFirstChild("ShutdownServer") or nil
local CheckAdminRemote = Events and Events:FindFirstChild("CheckAdmin") or nil
local CheckDatastoreAccessRemote = Events and Events:FindFirstChild("CheckDatastoreManagerAccess") or nil
local DatastoreRequestRemote = Events and Events:FindFirstChild("DatastoreRequest") or nil
local ToggleDevPanelRemote = Events and Events:FindFirstChild("ToggleDevPanel") or nil
local LeaderboardRemote = Events and Events:FindFirstChild("LeaderboardRequest") or nil

local function EnsureDatastoreRemotes()
	if not Events then
		return false, "DevPanelEvents folder unavailable"
	end
	if not CheckDatastoreAccessRemote then
		local ok, result = pcall(function()
			return Events:WaitForChild("CheckDatastoreManagerAccess", 10)
		end)
		if ok and result and result:IsA("RemoteFunction") then
			CheckDatastoreAccessRemote = result
		end
	end
	if not DatastoreRequestRemote then
		local ok, result = pcall(function()
			return Events:WaitForChild("DatastoreRequest", 10)
		end)
		if ok and result and result:IsA("RemoteFunction") then
			DatastoreRequestRemote = result
		end
	end
	if not DatastoreRequestRemote then
		return false, "DatastoreRequest remote not found"
	end
	return true
end

-- // ADMIN GATE: Check if the local player is an admin before building any UI //
local IS_ADMIN = false
if CheckAdminRemote then
	local ok, result = pcall(function()
		return CheckAdminRemote:InvokeServer()
	end)
	IS_ADMIN = ok and result == true
end

local IS_DATASTORE_ADMIN = false
if IS_ADMIN and CheckDatastoreAccessRemote then
	local ok, result = pcall(function()
		return CheckDatastoreAccessRemote:InvokeServer()
	end)
	IS_DATASTORE_ADMIN = ok and result == true
elseif IS_ADMIN then
	local okRemotes = EnsureDatastoreRemotes()
	if okRemotes and CheckDatastoreAccessRemote then
		local ok, result = pcall(function()
			return CheckDatastoreAccessRemote:InvokeServer()
		end)
		IS_DATASTORE_ADMIN = ok and result == true
	end
end

if not IS_ADMIN then
	return -- Non-admins: exit immediately, no UI created, no keybind registered
end

local MainEvents = ReplicatedStorage:WaitForChild("Events", 10)
local ClosePanels = MainEvents and MainEvents:FindFirstChild("ClosePanels")
if MainEvents and not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = MainEvents
end

local function FireAction(category, action, payload)
	if not ActionRemote then
		return false
	end
	ActionRemote:FireServer(category, action, payload)
	return true
end

local function DatastoreInvoke(action, payload)
	local remotesOk, remotesErr = EnsureDatastoreRemotes()
	if not remotesOk then
		return {
			Success = false,
			Error = tostring(remotesErr or "Datastore remotes unavailable"),
		}
	end
	if not DatastoreRequestRemote then
		return {
			Success = false,
			Error = "Datastore request remote is unavailable",
		}
	end
	local ok, result = pcall(function()
		return DatastoreRequestRemote:InvokeServer(action, payload)
	end)
	if not ok then
		return {
			Success = false,
			Error = tostring(result),
		}
	end
	if type(result) ~= "table" then
		return {
			Success = false,
			Error = "Unexpected datastore response",
		}
	end
	return result
end

local function LeaderboardInvoke(action, payload)
	if not LeaderboardRemote then
		if Events then
			local ok, result = pcall(function()
				return Events:WaitForChild("LeaderboardRequest", 5)
			end)
			if ok and result and result:IsA("RemoteFunction") then
				LeaderboardRemote = result
			end
		end
	end
	if not LeaderboardRemote then
		return { Success = false, Error = "Leaderboard remote unavailable" }
	end
	local ok, result = pcall(function()
		return LeaderboardRemote:InvokeServer(action, payload)
	end)
	if not ok then
		return { Success = false, Error = tostring(result) }
	end
	if type(result) ~= "table" then
		return { Success = false, Error = "Unexpected response" }
	end
	return result
end

-- // UI BUILDER HELPERS //
local function Create(className, props, children)
	local inst = Instance.new(className)
	for k, v in pairs(props) do inst[k] = v end
	if children then for _, child in pairs(children) do child.Parent = inst end end
	return inst
end

local function Round(radius)
	return Create("UICorner", {CornerRadius = UDim.new(0, radius)})
end

local function Pad(px)
	return Create("UIPadding", {
		PaddingTop = UDim.new(0, px), PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px), PaddingRight = UDim.new(0, px)
	})
end

local function Stroke(color, thickness)
	return Create("UIStroke", {
		Color = color or Color3.fromRGB(50,50,50),
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	})
end

-- // MAIN UI CONSTRUCTION //
local ScreenGui = Create("ScreenGui", {
	Name = "DevPanel_V3",
	Parent = PlayerGui,
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	Enabled = false
})

local MainFrame = Create("Frame", {
	Name = "Main",
	Size = UDim2.new(0, 900, 0, 550),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = THEME.Background,
	BorderSizePixel = 0,
	Parent = ScreenGui
}, {
	Round(12),
	Stroke(Color3.fromRGB(45,45,55), 2),
	Create("UIScale", {Scale = 1})
})

-- Shadow
Create("ImageLabel", {
	Name = "Shadow",
	Parent = MainFrame,
	BackgroundTransparency = 1,
	Position = UDim2.new(0, -30, 0, -30),
	Size = UDim2.new(1, 60, 1, 60),
	ZIndex = 0,
	Image = "rbxassetid://6015897843",
	ImageColor3 = Color3.new(0,0,0),
	ImageTransparency = 0.4,
	ScaleType = Enum.ScaleType.Slice,
	SliceCenter = Rect.new(49, 49, 450, 450)
})

-- Sidebar
local Sidebar = Create("Frame", {
	Name = "Sidebar",
	Parent = MainFrame,
	BackgroundColor3 = THEME.Sidebar,
	Size = UDim2.new(0, 200, 1, 0),
	BorderSizePixel = 0
}, {
	Round(12),
	Create("Frame", {
		BackgroundColor3 = THEME.Sidebar,
		Size = UDim2.new(0, 10, 1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		BorderSizePixel = 0
	})
})

-- Profile Section
local ProfileFrame = Create("Frame", {
	Parent = Sidebar,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 80)
}, {
	Create("ImageLabel", {
		Name = "Avatar",
		Image = "rbxasset://textures/ui/GuiImagePlaceholder.png",
		BackgroundColor3 = THEME.Card,
		Size = UDim2.new(0, 40, 0, 40),
		Position = UDim2.new(0, 20, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5)
	}, {Round(20)}),
	Create("TextLabel", {
		Text = "Dev Panel",
		TextColor3 = THEME.TextMain,
		Font = FONTS.Header,
		TextSize = 16,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 70, 0.35, 0),
		Size = UDim2.new(0, 100, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left
	}),
	Create("TextLabel", {
		Text = "V3.2 + Fixed TP",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Light,
		TextSize = 12,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 70, 0.65, 0),
		Size = UDim2.new(0, 100, 0, 15),
		TextXAlignment = Enum.TextXAlignment.Left
	})
})

-- Load Avatar
task.spawn(function()
	local content = Players:GetUserThumbnailAsync(Player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	ProfileFrame.Avatar.Image = content
end)

local NavContainer = Create("Frame", {
	Parent = Sidebar,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 1, -100),
	Position = UDim2.new(0, 0, 0, 90)
}, {
	Create("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}),
	Pad(15)
})

-- Content Area
local ContentArea = Create("Frame", {
	Name = "Content",
	Parent = MainFrame,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, -200, 1, 0),
	Position = UDim2.new(0, 200, 0, 0),
	ClipsDescendants = true
}, {
	Pad(25)
})

-- // COMPONENT CREATORS //

local function CreateNavButton(name, icon, pageId)
	local btn = Create("TextButton", {
		Name = pageId,
		Parent = NavContainer,
		BackgroundColor3 = THEME.Sidebar,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		Text = "",
		AutoButtonColor = false,
		Active = true,
		Selectable = true
	}, {
		Round(6),
		Create("TextLabel", {
			Text = icon .. "    " .. name,
			TextColor3 = THEME.TextDim,
			Font = FONTS.Body,
			TextSize = 14,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -20, 1, 0),
			Position = UDim2.new(0, 15, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Left
		})
	})

	btn.MouseEnter:Connect(function()
		if UI_STATE.CurrentPage ~= pageId then
			TweenService:Create(btn.TextLabel, TweenInfo.new(0.2), {TextColor3 = THEME.TextMain}):Play()
		end
	end)
	btn.MouseLeave:Connect(function()
		if UI_STATE.CurrentPage ~= pageId then
			TweenService:Create(btn.TextLabel, TweenInfo.new(0.2), {TextColor3 = THEME.TextDim}):Play()
		end
	end)

	return btn
end

local function CreateInput(parent, title, placeholder, onChanged)
	local container = Create("Frame", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 60)
	})

	Create("TextLabel", {
		Parent = container,
		Text = string.upper(title),
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	local boxContainer = Create("Frame", {
		Parent = container,
		BackgroundColor3 = THEME.Input,
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.new(0, 0, 0, 22)
	}, {Round(6), Stroke(Color3.fromRGB(60,60,70))})

	local box = Create("TextBox", {
		Parent = boxContainer,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		Font = FONTS.Body,
		TextSize = 14,
		TextColor3 = THEME.TextMain,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Color3.fromRGB(80,80,90),
		Text = "",
		ClearTextOnFocus = false
	})

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if onChanged then onChanged(box.Text) end
	end)

	box.FocusLost:Connect(function()
		TweenService:Create(boxContainer.UIStroke, TweenInfo.new(0.2), {Color = Color3.fromRGB(60,60,70)}):Play()
	end)

	box.Focused:Connect(function()
		TweenService:Create(boxContainer.UIStroke, TweenInfo.new(0.2), {Color = THEME.Accent}):Play()
	end)

	return box
end

local function CreateActionButton(parent, text, color, callback)
	local btn = Create("TextButton", {
		Parent = parent,
		BackgroundColor3 = color or THEME.Card,
		Size = UDim2.new(1, 0, 0, 45),
		Text = "",
		AutoButtonColor = false,
		Active = true,
		Selectable = true
	}, {Round(6)})

	Create("TextLabel", {
		Parent = btn,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Text = text,
		TextColor3 = THEME.TextMain,
		Font = FONTS.Header,
		TextSize = 14
	})

	btn.Activated:Connect(function()
		local originalSize = btn.Size
		TweenService:Create(btn, TweenInfo.new(0.05), {Size = UDim2.new(originalSize.X.Scale, originalSize.X.Offset - 4, originalSize.Y.Scale, originalSize.Y.Offset - 4)}):Play()
		task.wait(0.05)
		TweenService:Create(btn, TweenInfo.new(0.1), {Size = originalSize}):Play()
		if callback then callback() end
	end)

	return btn
end

local function CreateStatCard(parent, title, icon, valueGen)
	local card = Create("Frame", {
		Parent = parent,
		BackgroundColor3 = THEME.Card,
	}, {Round(8)})

	Create("TextLabel", {
		Parent = card,
		Text = icon,
		TextSize = 24,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 15, 0, 15),
		Size = UDim2.new(0, 30, 0, 30),
		TextColor3 = THEME.Accent
	})

	Create("TextLabel", {
		Parent = card,
		Text = title,
		Font = FONTS.Light,
		TextSize = 12,
		TextColor3 = THEME.TextDim,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 15, 0, 50),
		Size = UDim2.new(1, -30, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	local valLabel = Create("TextLabel", {
		Parent = card,
		Text = "...",
		Font = FONTS.Header,
		TextSize = 28,
		TextColor3 = THEME.TextMain,
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 15, 0, 70),
		Size = UDim2.new(1, -30, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	task.spawn(function()
		while card.Parent do
			valLabel.Text = valueGen()
			task.wait(1)
		end
	end)
end

-- // PAGES //
local Pages = {}
local PageContainer = Create("Frame", {
	Parent = ContentArea,
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1
})

-- 1. OVERVIEW
Pages.Overview = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
})
Create("UIGridLayout", {
	Parent = Pages.Overview, CellSize = UDim2.new(0.48, 0, 0, 120), CellPadding = UDim2.new(0, 15, 0, 15)
})

CreateStatCard(Pages.Overview, "ACTIVE PLAYERS", "👥", function() return #Players:GetPlayers() end)
CreateStatCard(Pages.Overview, "SERVER FPS", "⚡", function() return math.floor(1 / RunService.Heartbeat:Wait()) end)
CreateStatCard(Pages.Overview, "UPTIME", "⏱️", function() 
	local t = Workspace.DistributedGameTime
	return string.format("%02d:%02d:%02d", math.floor(t/3600), math.floor((t%3600)/60), math.floor(t%60))
end)
CreateStatCard(Pages.Overview, "SERVER ID", "🆔", function() 
	return string.sub(game.JobId, 1, 8) .. "..."
end)

-- 2. MODERATION
Pages.Moderation = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
}, {Create("UIListLayout", {Padding = UDim.new(0, 10)})})

CreateInput(Pages.Moderation, "Target Player", "Username (works for offline unban too)...", function(t) UI_STATE.Inputs.Target = t end)
CreateInput(Pages.Moderation, "Reason / Message", "Reason for action...", function(t) UI_STATE.Inputs.Reason = t end)

local ModGridFrame = Create("Frame", {
	Parent = Pages.Moderation, BackgroundTransparency = 1, Size = UDim2.new(1,0,1,-140)
}, {Create("UIGridLayout", {CellSize = UDim2.new(0.24, 0, 0, 50), CellPadding = UDim2.new(0, 8, 0, 8)})})

local function Act(cat, act)
	FireAction(cat, act, {
		Target = UI_STATE.Inputs.Target, 
		Reason = UI_STATE.Inputs.Reason, 
		Amount = UI_STATE.Inputs.Amount,
		PassId = UI_STATE.Inputs.PassId
	})
end

CreateActionButton(ModGridFrame, "Kick", THEME.Destructive, function() Act("Moderation", "Kick") end)
CreateActionButton(ModGridFrame, "Ban", THEME.Destructive, function() Act("Moderation", "Ban") end)
CreateActionButton(ModGridFrame, "Unban", THEME.Success, function() Act("Moderation", "Unban") end)
CreateActionButton(ModGridFrame, "Teleport To", THEME.Card, function() Act("Moderation", "TeleportTo") end)
CreateActionButton(ModGridFrame, "Bring", THEME.Card, function() Act("Moderation", "Bring") end)
CreateActionButton(ModGridFrame, "Kill", THEME.Destructive, function() Act("Moderation", "Kill") end)
CreateActionButton(ModGridFrame, "Freeze", THEME.Card, function() Act("Moderation", "Freeze") end)
CreateActionButton(ModGridFrame, "Thaw", THEME.Card, function() Act("Moderation", "Thaw") end)

-- 3. ECONOMY
Pages.Economy = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
}, {Create("UIListLayout", {Padding = UDim.new(0, 10)})})

CreateInput(Pages.Economy, "Target Player", "Username...", function(t) UI_STATE.Inputs.Target = t end)
CreateInput(Pages.Economy, "Amount", "Numeric Value (e.g. 1000)...", function(t) UI_STATE.Inputs.Amount = t end)

local EcoGrid = Create("Frame", {
	Parent = Pages.Economy, BackgroundTransparency = 1, Size = UDim2.new(1,0,0,100)
}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 0, 50), CellPadding = UDim2.new(0, 10, 0, 10)})})

CreateActionButton(EcoGrid, "Add Funds (+)", THEME.Success, function() Act("Economy", "Add") end)
CreateActionButton(EcoGrid, "Set Funds (=)", THEME.Card, function() Act("Economy", "Set") end)

-- 4. GAMEPASSES
Pages.Gamepasses = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
}, {Create("UIListLayout", {Padding = UDim.new(0, 10)})})

CreateInput(Pages.Gamepasses, "Target Player", "Username (online or offline)...", function(t) UI_STATE.Inputs.Target = t end)
local PassIdInput = CreateInput(Pages.Gamepasses, "Gamepass ID", "Example: 1733258476", function(t) UI_STATE.Inputs.PassId = t end)

Create("TextLabel", {
	Parent = Pages.Gamepasses,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 20),
	Text = "QUICK SELECT",
	Font = FONTS.Header,
	TextSize = 11,
	TextColor3 = THEME.TextDim,
	TextXAlignment = Enum.TextXAlignment.Left
})

local PassPresetGrid = Create("Frame", {
	Parent = Pages.Gamepasses,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 230)
}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 0, 40), CellPadding = UDim2.new(0, 10, 0, 8)})})

for _, passInfo in ipairs(GAMEPASS_PRESETS) do
	CreateActionButton(PassPresetGrid, passInfo.Name .. " (" .. passInfo.Id .. ")", THEME.Card, function()
		local passText = tostring(passInfo.Id)
		UI_STATE.Inputs.PassId = passText
		PassIdInput.Text = passText
	end)
end

local GamepassActionGrid = Create("Frame", {
	Parent = Pages.Gamepasses,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 155)
}, {Create("UIGridLayout", {CellSize = UDim2.new(0.32, 0, 0, 45), CellPadding = UDim2.new(0, 10, 0, 10)})})

CreateActionButton(GamepassActionGrid, "Grant Pass", THEME.Success, function() Act("Gamepass", "Grant") end)
CreateActionButton(GamepassActionGrid, "Revoke Pass", THEME.Destructive, function() Act("Gamepass", "Revoke") end)
CreateActionButton(GamepassActionGrid, "Grant Founder", THEME.Warning, function() Act("Gamepass", "GrantFounder") end)
CreateActionButton(GamepassActionGrid, "Grant All Passes", THEME.Accent, function() Act("Gamepass", "GrantAllPasses") end)
CreateActionButton(GamepassActionGrid, "Unlock All Research", THEME.Accent, function() FireAction("ResearchAdmin", "UnlockAll", {Target = UI_STATE.Inputs.Target}) end)
CreateActionButton(GamepassActionGrid, "Fill Research RP", THEME.Card, function() FireAction("ResearchAdmin", "MaxRP", {Target = UI_STATE.Inputs.Target}) end)
CreateActionButton(GamepassActionGrid, "Grant Dev Bundle", THEME.Success, function() Act("Gamepass", "GrantDevBundle") end)

-- 5. SERVER CONTROLS
Pages.Server = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
}, {Create("UIListLayout", {Padding = UDim.new(0, 10)})})

CreateInput(Pages.Server, "Broadcast Message", "Announcement text...", function(t) UI_STATE.Inputs.Reason = t end)

CreateActionButton(Pages.Server, "Global Announcement", THEME.Accent, function() 
	FireAction("Server", "Announce", {Message = UI_STATE.Inputs.Reason}) 
end)

CreateActionButton(Pages.Server, "Shutdown This Server", THEME.Destructive, function() 
	FireAction("Server", "Shutdown", {Message = UI_STATE.Inputs.Reason}) 
end)

-- 5.5 LEADERBOARD MANAGER
Pages.Leaderboard = Create("ScrollingFrame", {
	Parent = PageContainer,
	Size = UDim2.new(1, 0, 1, 0),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = THEME.Accent,
	BorderSizePixel = 0,
	BackgroundTransparency = 1,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Visible = false,
}, {Create("UIListLayout", {Padding = UDim.new(0, 8)})})

do
	local BOARD_NAMES = {"Richest", "BiggestResort", "MostLifts", "MostSlopes", "MostGuests", "BestRating"}
	local BOARD_LABELS = {
		Richest = "Richest (Cash)",
		BiggestResort = "Biggest Resort (Objects)",
		MostLifts = "Most Lifts",
		MostSlopes = "Most Slopes",
		MostGuests = "Most Guests",
		BestRating = "Best Rating",
	}

	local lbSelectedBoard = BOARD_NAMES[1]
	local lbEntries = {}
	local lbSelectedIndex = nil
	local lbEntryListFrame
	local lbEditKeyInput
	local lbEditValueInput
	local lbAddUserInput
	local lbAddSlotInput
	local lbAddValueInput
	local lbStatusLabel

	local function setLbStatus(msg, isError)
		if lbStatusLabel then
			lbStatusLabel.Text = tostring(msg or "")
			lbStatusLabel.TextColor3 = isError and THEME.Destructive or THEME.TextDim
		end
	end

	lbStatusLabel = Create("TextLabel", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Text = "Select a board and load entries.",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Body,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	-- Board selector
	Create("TextLabel", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		Text = "LEADERBOARD",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local BoardSelectorGrid = Create("Frame", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 85),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.32, 0, 0, 38), CellPadding = UDim2.new(0, 8, 0, 6)})})

	local boardButtons = {}
	local function updateBoardButtonColors()
		for name, btn in pairs(boardButtons) do
			local isActive = (name == lbSelectedBoard)
			TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = isActive and THEME.Accent or THEME.Card}):Play()
		end
	end

	for _, boardName in ipairs(BOARD_NAMES) do
		local btn = CreateActionButton(BoardSelectorGrid, BOARD_LABELS[boardName], THEME.Card, function()
			lbSelectedBoard = boardName
			updateBoardButtonColors()
		end)
		boardButtons[boardName] = btn
	end
	updateBoardButtonColors()

	local refreshLbList

	-- Load button
	local LbTopActions = Create("Frame", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 1, 0), CellPadding = UDim2.new(0, 10, 0, 0)})})

	CreateActionButton(LbTopActions, "Load Top Entries", THEME.Accent, function()
		setLbStatus("Loading " .. lbSelectedBoard .. "...", false)
		local result = LeaderboardInvoke("GetTopEntries", {Board = lbSelectedBoard, Count = 50})
		if not result.Success then
			setLbStatus("Load failed: " .. tostring(result.Error), true)
			return
		end
		lbEntries = result.Entries or {}
		lbSelectedIndex = nil
		refreshLbList()
		setLbStatus("Loaded " .. #lbEntries .. " entries from " .. lbSelectedBoard, false)
	end)

	CreateActionButton(LbTopActions, "Remove From ALL Boards", THEME.Destructive, function()
		local key = lbEditKeyInput and lbEditKeyInput.Text or ""
		if key == "" then
			setLbStatus("Select or enter a key first.", true)
			return
		end
		local result = LeaderboardInvoke("RemoveAllBoards", {Key = key})
		if not result.Success then
			setLbStatus("Remove all failed: " .. tostring(result.Error), true)
			return
		end
		setLbStatus("Removed " .. key .. " from all boards + meta.", false)
	end)

	-- Entry list
	Create("TextLabel", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		Text = "ENTRIES",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	lbEntryListFrame = Create("ScrollingFrame", {
		Parent = Pages.Leaderboard,
		BackgroundColor3 = THEME.Input,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 180),
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, {Round(6), Stroke(Color3.fromRGB(60, 60, 70))})

	refreshLbList = function()
		if not lbEntryListFrame then return end
		for _, child in ipairs(lbEntryListFrame:GetChildren()) do
			if child:IsA("TextButton") then child:Destroy() end
		end
		for index, entry in ipairs(lbEntries) do
			local resortName = (entry.Meta and entry.Meta.ResortName) or ""
			local ownerName = (entry.Meta and (entry.Meta.OwnerDisplayName or entry.Meta.OwnerName)) or ""
			local displayText = string.format("#%d  %s = %s", index, entry.Key or "?", tostring(entry.Value or "?"))
			if resortName ~= "" then
				displayText = displayText .. "  (" .. resortName .. ")"
			elseif ownerName ~= "" then
				displayText = displayText .. "  (" .. ownerName .. ")"
			end
			local btn = Create("TextButton", {
				Parent = lbEntryListFrame,
				Size = UDim2.new(1, -6, 0, 26),
				Position = UDim2.new(0, 3, 0, (index - 1) * 28),
				Text = displayText,
				Font = FONTS.Light,
				TextSize = 12,
				BackgroundColor3 = (lbSelectedIndex == index) and THEME.Accent or THEME.Input,
				TextColor3 = THEME.TextMain,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, {Round(4)})
			btn.Activated:Connect(function()
				lbSelectedIndex = index
				local selected = lbEntries[index]
				if lbEditKeyInput then lbEditKeyInput.Text = selected.Key or "" end
				if lbEditValueInput then lbEditValueInput.Text = tostring(selected.Value or "") end
				refreshLbList()
			end)
		end
		lbEntryListFrame.CanvasSize = UDim2.new(0, 0, 0, #lbEntries * 28)
	end

	-- Edit section
	Create("TextLabel", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		Text = "EDIT / REMOVE ENTRY",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	lbEditKeyInput = CreateInput(Pages.Leaderboard, "Key", "Resort_12345_1", function() end)
	lbEditValueInput = CreateInput(Pages.Leaderboard, "Value", "Numeric value", function() end)

	local LbEditActions = Create("Frame", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 1, 0), CellPadding = UDim2.new(0, 10, 0, 0)})})

	CreateActionButton(LbEditActions, "Save Value", THEME.Success, function()
		local key = lbEditKeyInput.Text
		local value = lbEditValueInput.Text
		if key == "" then setLbStatus("Enter a key.", true) return end
		local result = LeaderboardInvoke("EditEntry", {Board = lbSelectedBoard, Key = key, Value = tonumber(value)})
		if not result.Success then
			setLbStatus("Edit failed: " .. tostring(result.Error), true)
			return
		end
		setLbStatus("Saved " .. key .. " = " .. value .. " on " .. lbSelectedBoard, false)
	end)

	CreateActionButton(LbEditActions, "Remove Entry", THEME.Destructive, function()
		local key = lbEditKeyInput.Text
		if key == "" then setLbStatus("Enter a key.", true) return end
		local result = LeaderboardInvoke("RemoveEntry", {Board = lbSelectedBoard, Key = key})
		if not result.Success then
			setLbStatus("Remove failed: " .. tostring(result.Error), true)
			return
		end
		setLbStatus("Removed " .. key .. " from " .. lbSelectedBoard, false)
		for i, entry in ipairs(lbEntries) do
			if entry.Key == key then
				table.remove(lbEntries, i)
				break
			end
		end
		lbSelectedIndex = nil
		refreshLbList()
	end)

	-- Add new entry
	Create("TextLabel", {
		Parent = Pages.Leaderboard,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		Text = "ADD NEW ENTRY",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	lbAddUserInput = CreateInput(Pages.Leaderboard, "Username", "Player username", function() end)
	lbAddSlotInput = CreateInput(Pages.Leaderboard, "Slot Number", "1", function() end)
	lbAddValueInput = CreateInput(Pages.Leaderboard, "Value", "Numeric value", function() end)

	CreateActionButton(Pages.Leaderboard, "Add Entry", THEME.Success, function()
		local username = lbAddUserInput.Text
		if username == "" then setLbStatus("Enter a username.", true) return end
		setLbStatus("Resolving user...", false)
		local resolveResult = DatastoreInvoke("ResolveUser", {Target = username})
		if not resolveResult.Success then
			setLbStatus("Could not resolve user: " .. tostring(resolveResult.Error), true)
			return
		end
		local userId = resolveResult.UserId
		local slotNum = tonumber(lbAddSlotInput.Text) or 1
		local value = tonumber(lbAddValueInput.Text)
		if not value then setLbStatus("Enter a numeric value.", true) return end
		local result = LeaderboardInvoke("AddEntry", {
			Board = lbSelectedBoard,
			UserId = userId,
			SlotNum = slotNum,
			Value = value,
		})
		if not result.Success then
			setLbStatus("Add failed: " .. tostring(result.Error), true)
			return
		end
		setLbStatus("Added " .. (result.Key or "?") .. " = " .. tostring(value) .. " to " .. lbSelectedBoard, false)
	end)
end

-- 6. SERVER BROWSER (FIXED!)
Pages.Servers = Create("Frame", {
	Parent = PageContainer, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false
})

-- Header with refresh button
local ServersHeader = Create("Frame", {
	Parent = Pages.Servers,
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1
})

Create("TextLabel", {
	Parent = ServersHeader,
	Text = "🌐 SERVER BROWSER",
	Font = FONTS.Header,
	TextSize = 18,
	TextColor3 = THEME.TextMain,
	BackgroundTransparency = 1,
	Size = UDim2.new(0.5, 0, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Left
})

local RefreshBtn = Create("TextButton", {
	Parent = ServersHeader,
	Text = "🔄 Refresh",
	Font = FONTS.Body,
	TextSize = 14,
	TextColor3 = THEME.TextMain,
	BackgroundColor3 = THEME.Accent,
	Size = UDim2.new(0, 100, 0, 35),
	Position = UDim2.new(1, -100, 0.5, -17),
	AutoButtonColor = false
}, {Round(6)})

-- Server List Container
local ServerListContainer = Create("ScrollingFrame", {
	Parent = Pages.Servers,
	Size = UDim2.new(1, 0, 1, -60),
	Position = UDim2.new(0, 0, 0, 55),
	BackgroundColor3 = THEME.Card,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = THEME.Accent,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y
}, {
	Round(8),
	Pad(10),
	Create("UIListLayout", {Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder})
})

-- Loading indicator
local LoadingLabel = Create("TextLabel", {
	Parent = ServerListContainer,
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = "Loading servers...",
	TextColor3 = THEME.TextDim,
	Font = FONTS.Body,
	TextSize = 14
})

-- Function to create a server card
local function CreateServerCard(serverInfo, isCurrentServer)
	local card = Create("Frame", {
		Parent = ServerListContainer,
		Size = UDim2.new(1, 0, 0, 110),
		BackgroundColor3 = isCurrentServer and THEME.CurrentServer or THEME.Card,
		BorderSizePixel = 0,
		LayoutOrder = isCurrentServer and -1 or 0
	}, {Round(8)})

	if isCurrentServer then
		Create("UIStroke", {
			Parent = card,
			Color = THEME.Online,
			Thickness = 2
		})
	end

	-- Server ID
	local serverIdShort = string.sub(serverInfo.JobId or "Unknown", 1, 12) .. "..."
	Create("TextLabel", {
		Parent = card,
		Text = isCurrentServer and "📍 CURRENT SERVER" or "🖥️ " .. serverIdShort,
		Font = FONTS.Header,
		TextSize = 14,
		TextColor3 = THEME.TextMain,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.6, 0, 0, 25),
		Position = UDim2.new(0, 15, 0, 10),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	-- Server type indicator
	local serverType = "Public"
	if serverInfo.PrivateServerId and serverInfo.PrivateServerId ~= "" then
		serverType = serverInfo.AccessCode and "Reserved (Joinable)" or "Private"
	end

	Create("TextLabel", {
		Parent = card,
		Text = "🔒 " .. serverType,
		Font = FONTS.Light,
		TextSize = 11,
		TextColor3 = serverInfo.AccessCode and THEME.Success or THEME.TextDim,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.3, 0, 0, 20),
		Position = UDim2.new(0.35, 0, 0, 10),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	-- Player count
	local playerCount = serverInfo.PlayerCount or 0
	local maxPlayers = serverInfo.MaxPlayers or 0
	Create("TextLabel", {
		Parent = card,
		Text = "👥 " .. playerCount .. "/" .. maxPlayers .. " Players",
		Font = FONTS.Body,
		TextSize = 13,
		TextColor3 = THEME.TextDim,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.5, 0, 0, 20),
		Position = UDim2.new(0, 15, 0, 35),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	-- Uptime
	local uptime = serverInfo.Uptime or 0
	local uptimeStr = string.format("%02d:%02d:%02d", math.floor(uptime/3600), math.floor((uptime%3600)/60), math.floor(uptime%60))
	Create("TextLabel", {
		Parent = card,
		Text = "⏱️ Uptime: " .. uptimeStr,
		Font = FONTS.Body,
		TextSize = 13,
		TextColor3 = THEME.TextDim,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.5, 0, 0, 20),
		Position = UDim2.new(0, 15, 0, 55),
		TextXAlignment = Enum.TextXAlignment.Left
	})

	-- Player list
	local playerNames = {}
	if serverInfo.Players then
		for i, p in ipairs(serverInfo.Players) do
			if i <= 5 then
				table.insert(playerNames, p.Name or p.DisplayName or "Unknown")
			end
		end
	end
	local playerListStr = #playerNames > 0 and table.concat(playerNames, ", ") or "No players"
	if #(serverInfo.Players or {}) > 5 then
		playerListStr = playerListStr .. " +" .. (#serverInfo.Players - 5) .. " more"
	end

	Create("TextLabel", {
		Parent = card,
		Text = playerListStr,
		Font = FONTS.Light,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(120, 120, 120),
		BackgroundTransparency = 1,
		Size = UDim2.new(0.6, 0, 0, 15),
		Position = UDim2.new(0, 15, 0, 75),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd
	})

	-- Buttons (only for non-current servers)
	if not isCurrentServer then
		-- Join Button
		local joinBtn = Create("TextButton", {
			Parent = card,
			Text = "Join",
			Font = FONTS.Header,
			TextSize = 13,
			TextColor3 = THEME.TextMain,
			BackgroundColor3 = THEME.Success,
			Size = UDim2.new(0, 70, 0, 35),
			Position = UDim2.new(1, -160, 0.5, -17),
			AutoButtonColor = false
		}, {Round(6)})

		joinBtn.Activated:Connect(function()
			joinBtn.Text = "..."
			joinBtn.BackgroundColor3 = THEME.Warning

			if TeleportRemote then
				-- Just pass the JobId - server handles the teleport
				local result = TeleportRemote:InvokeServer(serverInfo.JobId)

				if result then
					if result.Success then
						joinBtn.Text = "Joining..."
						joinBtn.BackgroundColor3 = THEME.Success
					else
						joinBtn.Text = "Failed"
						joinBtn.BackgroundColor3 = THEME.Destructive

						-- Show error in a tooltip-like label
						local errorLabel = Create("TextLabel", {
							Parent = card,
							Text = result.Error or "Unknown error",
							Font = FONTS.Light,
							TextSize = 10,
							TextColor3 = THEME.Destructive,
							BackgroundTransparency = 1,
							Size = UDim2.new(0.5, 0, 0, 15),
							Position = UDim2.new(0, 15, 0, 90),
							TextXAlignment = Enum.TextXAlignment.Left
						})

						task.delay(3, function()
							if errorLabel.Parent then errorLabel:Destroy() end
							joinBtn.Text = "Join"
							joinBtn.BackgroundColor3 = THEME.Success
						end)
					end
				end
			end
		end)

		-- Shutdown Button
		local shutdownBtn = Create("TextButton", {
			Parent = card,
			Text = "Stop",
			Font = FONTS.Header,
			TextSize = 13,
			TextColor3 = THEME.TextMain,
			BackgroundColor3 = THEME.Destructive,
			Size = UDim2.new(0, 70, 0, 35),
			Position = UDim2.new(1, -80, 0.5, -17),
			AutoButtonColor = false
		}, {Round(6)})

		shutdownBtn.Activated:Connect(function()
			shutdownBtn.Text = "..."
			if ShutdownRemote then
				ShutdownRemote:FireServer(serverInfo.JobId, "Shutdown by admin")
				shutdownBtn.Text = "Sent"
				task.wait(1)
				shutdownBtn.Text = "Stop"
			end
		end)
	else
		-- Status indicator for current server
		Create("TextLabel", {
			Parent = card,
			Text = "✅ You are here",
			Font = FONTS.Body,
			TextSize = 13,
			TextColor3 = THEME.Online,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 120, 0, 35),
			Position = UDim2.new(1, -130, 0.5, -17),
			TextXAlignment = Enum.TextXAlignment.Center
		})
	end

	return card
end

-- Function to refresh server list
local function RefreshServerList()
	-- Clear existing cards
	for _, child in pairs(ServerListContainer:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	LoadingLabel.Visible = true
	LoadingLabel.Text = "Loading servers..."

	if not GetServersRemote then
		LoadingLabel.Text = "Server browser unavailable"
		return
	end

	local success, result = pcall(function()
		return GetServersRemote:InvokeServer()
	end)

	if not success then
		LoadingLabel.Text = "Failed to connect: " .. tostring(result)
		return
	end

	LoadingLabel.Visible = false

	if result and result.Error then
		LoadingLabel.Visible = true
		LoadingLabel.Text = "Error: " .. result.Error
		return
	end

	if result and result.Servers then
		local currentServerId = result.CurrentServer

		if #result.Servers == 0 then
			LoadingLabel.Visible = true
			LoadingLabel.Text = "No servers found"
			return
		end

		for _, serverInfo in ipairs(result.Servers) do
			local isCurrentServer = (serverInfo.JobId == currentServerId)
			CreateServerCard(serverInfo, isCurrentServer)
		end
	else
		LoadingLabel.Visible = true
		LoadingLabel.Text = "Failed to load servers"
	end
end

-- Refresh button handler
RefreshBtn.Activated:Connect(function()
	RefreshBtn.Text = "..."
	RefreshServerList()
	RefreshBtn.Text = "🔄 Refresh"
end)

-- 7. DATASTORE MANAGER
if IS_DATASTORE_ADMIN then
	Pages.Datastore = Create("ScrollingFrame", {
		Parent = PageContainer,
		Size = UDim2.new(1, 0, 1, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = THEME.Accent,
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, {Create("UIListLayout", {Padding = UDim.new(0, 8)})})

	local DataStatus = Create("TextLabel", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Resolve a player, then discover and load a slot.",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Body,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local function SetDataStatus(message, isError)
		DataStatus.Text = tostring(message or "")
		DataStatus.TextColor3 = isError and THEME.Destructive or THEME.TextDim
	end

	local DataMoneyInput
	local DataTicketsInput
	local DataResearchRpInput
	local DataResearchMaxRpInput
	local TerrainJsonInput
	local BuildingListFrame
	local BuildingDetailTypeInput
	local BuildingDetailItemInput
	local BuildingDetailUuidInput
	local BuildingDetailPriceInput
	local BuildingDetailCfInput
	local SlotDropdownButton
	local SlotDropdownLabel
	local SlotOptionsFrame
	local SlotOptionsLayout
	local refreshBuildingList

	local function ShowToast(kind, title, message)
		local bindable = ReplicatedStorage:FindFirstChild("ClientNotification")
		if bindable then
			bindable:Fire(kind, title, message, 5)
		end
	end

	CreateInput(Pages.Datastore, "Target Player", "Username", function(t)
		UI_STATE.Inputs.Target = t
		UI_STATE.Datastore.ResolvedUserId = nil
		UI_STATE.Datastore.ResolvedName = nil
		UI_STATE.Datastore.DiscoveredSlots = {}
		UI_STATE.Datastore.BuildingObjects = {}
		UI_STATE.Datastore.SelectedBuildingIndex = nil
		if SlotDropdownLabel then
			SlotDropdownLabel.Text = "Select slot"
		end
		if SlotOptionsFrame then
			SlotOptionsFrame.Visible = false
		end
	end)

	local TopButtons = Create("Frame", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 1, 0), CellPadding = UDim2.new(0, 10, 0, 0)})})

	local function buildEditableTerrainPayload(terrainMetaData)
		if type(terrainMetaData) ~= "table" then
			return ""
		end
		local source = terrainMetaData.TerrainMeta
		if type(source) ~= "table" then
			source = terrainMetaData
		end
		local editable = {}
		for key, value in pairs(source) do
			if key ~= "Heightmap" and type(value) ~= "table" then
				editable[key] = value
			end
		end
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(editable)
		end)
		if not ok then
			return ""
		end
		if #encoded >= 180000 then
			return ""
		end
		return encoded
	end

	local function loadSelectedSlot(slotNum)
		if not UI_STATE.Datastore.ResolvedUserId then
			SetDataStatus("Resolve user first.", true)
			ShowToast("Warning", "Resolve Required", "Resolve a user before loading a slot.")
			return
		end
		local slot = tonumber(slotNum)
		if not slot then
			SetDataStatus("Enter a valid slot number.", true)
			ShowToast("Error", "Invalid Slot", "Enter a numeric slot value.")
			return
		end

		local result = DatastoreInvoke("LoadSlot", {
			UserId = UI_STATE.Datastore.ResolvedUserId,
			SlotNum = slot,
		})
		if not result.Success then
			SetDataStatus("Load failed: " .. tostring(result.Error), true)
			ShowToast("Error", "Load Failed", tostring(result.Error))
			return
		end

		UI_STATE.Datastore.Loaded = result.Data
		local gameData = result.Data and result.Data.GameData or {}
		local research = result.Data and result.Data.Research or {}
		UI_STATE.Inputs.DataMoney = tostring((type(gameData) == "table" and gameData.Money) or "")
		UI_STATE.Inputs.DataTickets = tostring((type(gameData) == "table" and gameData.Tickets) or "")
		UI_STATE.Inputs.DataResearchRP = tostring((type(research) == "table" and research.RP) or "")
		UI_STATE.Inputs.DataResearchMaxRP = tostring((type(research) == "table" and research.MaxRP) or "")
		DataMoneyInput.Text = UI_STATE.Inputs.DataMoney
		DataTicketsInput.Text = UI_STATE.Inputs.DataTickets
		DataResearchRpInput.Text = UI_STATE.Inputs.DataResearchRP
		DataResearchMaxRpInput.Text = UI_STATE.Inputs.DataResearchMaxRP

		if type(result.Data.Buildings) == "table" then
			UI_STATE.Datastore.BuildingObjects = table.clone(result.Data.Buildings)
		else
			UI_STATE.Datastore.BuildingObjects = {}
		end

		UI_STATE.Inputs.DataTerrainJson = buildEditableTerrainPayload(result.Data.TerrainMeta)
		TerrainJsonInput.Text = UI_STATE.Inputs.DataTerrainJson
		UI_STATE.Inputs.DataSlot = tostring(slot)
		if SlotDropdownLabel then
			SlotDropdownLabel.Text = "Slot " .. tostring(slot)
		end
		UI_STATE.Datastore.SelectedBuildingIndex = nil
		refreshBuildingList()
		SetDataStatus("Slot loaded. Edit values and save.", false)
		ShowToast("Success", "Slot Loaded", "Loaded slot " .. tostring(slot))
	end

	local function rebuildSlotOptions()
		if not SlotOptionsFrame then
			return
		end
		for _, child in ipairs(SlotOptionsFrame:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		local y = 1
		for _, slot in ipairs(UI_STATE.Datastore.DiscoveredSlots or {}) do
			local btn = Create("TextButton", {
				Parent = SlotOptionsFrame,
				Size = UDim2.new(1, -8, 0, 28),
				Position = UDim2.new(0, 4, 0, 0),
				LayoutOrder = y,
				Text = "Slot " .. tostring(slot),
				Font = FONTS.Body,
				TextSize = 13,
				TextColor3 = THEME.TextMain,
				BackgroundColor3 = THEME.Input,
				ZIndex = 32,
				AutoButtonColor = false,
			}, {Round(4)})
			btn.Activated:Connect(function()
				SlotOptionsFrame.Visible = false
				loadSelectedSlot(slot)
			end)
			y += 1
		end
		local optionCount = #UI_STATE.Datastore.DiscoveredSlots
		SlotOptionsFrame.CanvasSize = UDim2.new(0, 0, 0, math.max(0, (optionCount * 30) + 6))
		if SlotOptionsLayout then
			SlotOptionsFrame.Size = UDim2.new(1, 0, 0, math.min(160, math.max(36, (optionCount * 30) + 8)))
		end
		SlotOptionsFrame.Visible = optionCount > 0
	end

	CreateActionButton(TopButtons, "Resolve User", THEME.Accent, function()
		local result = DatastoreInvoke("ResolveUser", {Target = UI_STATE.Inputs.Target})
		if not result.Success then
			SetDataStatus("Resolve failed: " .. tostring(result.Error), true)
			ShowToast("Error", "Resolve Failed", tostring(result.Error))
			return
		end
		UI_STATE.Datastore.ResolvedUserId = result.UserId
		UI_STATE.Datastore.ResolvedName = result.Name
		SetDataStatus(("Resolved %s (%s)"):format(tostring(result.Name), tostring(result.UserId)), false)
		ShowToast("Success", "Resolved", tostring(result.Name) .. " (" .. tostring(result.UserId) .. ")")
		local discovered = DatastoreInvoke("DiscoverSlots", {UserId = UI_STATE.Datastore.ResolvedUserId})
		if discovered.Success then
			UI_STATE.Datastore.DiscoveredSlots = discovered.Slots or {}
			rebuildSlotOptions()
			if #UI_STATE.Datastore.DiscoveredSlots > 0 then
				loadSelectedSlot(UI_STATE.Datastore.DiscoveredSlots[1])
			end
		end
	end)

	CreateActionButton(TopButtons, "Discover Slots", THEME.Card, function()
		if not UI_STATE.Datastore.ResolvedUserId then
			SetDataStatus("Resolve user first.", true)
			ShowToast("Warning", "Resolve Required", "Resolve a user before discovering slots.")
			return
		end
		local result = DatastoreInvoke("DiscoverSlots", {UserId = UI_STATE.Datastore.ResolvedUserId})
		if not result.Success then
			SetDataStatus("Slot discovery failed: " .. tostring(result.Error), true)
			ShowToast("Error", "Discover Failed", tostring(result.Error))
			return
		end
		UI_STATE.Datastore.DiscoveredSlots = result.Slots or {}
		rebuildSlotOptions()
		if #UI_STATE.Datastore.DiscoveredSlots == 0 then
			SetDataStatus("No populated slots found (scan range 1-8).", false)
			if SlotDropdownLabel then
				SlotDropdownLabel.Text = "No slots"
			end
			if SlotOptionsFrame then
				SlotOptionsFrame.Visible = false
			end
			ShowToast("Info", "No Slots", "No populated slots found for this user.")
		else
			SetDataStatus("Found slots: " .. table.concat(UI_STATE.Datastore.DiscoveredSlots, ", "), false)
			if SlotDropdownLabel then
				SlotDropdownLabel.Text = "Slot " .. tostring(UI_STATE.Datastore.DiscoveredSlots[1])
			end
			ShowToast("Success", "Slots Found", table.concat(UI_STATE.Datastore.DiscoveredSlots, ", "))
			loadSelectedSlot(UI_STATE.Datastore.DiscoveredSlots[1])
		end
	end)

	local SlotDropdownWrap = Create("Frame", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 38),
		ZIndex = 30,
	})

	SlotDropdownButton = Create("TextButton", {
		Parent = SlotDropdownWrap,
		BackgroundColor3 = THEME.Input,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 31,
		Text = "",
		AutoButtonColor = false,
	}, {Round(6), Stroke(Color3.fromRGB(60, 60, 70))})

	SlotDropdownLabel = Create("TextLabel", {
		Parent = SlotDropdownButton,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		Text = "Select slot",
		ZIndex = 32,
		TextColor3 = THEME.TextMain,
		Font = FONTS.Body,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	Create("TextLabel", {
		Parent = SlotDropdownButton,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 20, 1, 0),
		Position = UDim2.new(1, -22, 0, 0),
		Text = "v",
		ZIndex = 32,
		TextColor3 = THEME.TextDim,
		Font = FONTS.Body,
		TextSize = 13,
	})

	SlotOptionsFrame = Create("ScrollingFrame", {
		Parent = SlotDropdownWrap,
		BackgroundColor3 = THEME.Card,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.new(0, 0, 1, 2),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 6,
		Active = true,
		ZIndex = 31,
		Visible = false,
	}, {Round(6), Stroke(Color3.fromRGB(60, 60, 70))})

	SlotOptionsLayout = Create("UIListLayout", {
		Parent = SlotOptionsFrame,
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	SlotDropdownButton.Activated:Connect(function()
		if #UI_STATE.Datastore.DiscoveredSlots == 0 then
			SetDataStatus("No discovered slots yet. Click Discover Slots.", true)
			return
		end
		if SlotOptionsFrame.Visible then
			SlotOptionsFrame.Visible = false
			return
		end
		rebuildSlotOptions()
	end)

	DataMoneyInput = CreateInput(Pages.Datastore, "Money", "integer", function(t)
		UI_STATE.Inputs.DataMoney = t
	end)
	DataTicketsInput = CreateInput(Pages.Datastore, "Tickets", "integer", function(t)
		UI_STATE.Inputs.DataTickets = t
	end)
	DataResearchRpInput = CreateInput(Pages.Datastore, "Research RP", "integer", function(t)
		UI_STATE.Inputs.DataResearchRP = t
	end)
	DataResearchMaxRpInput = CreateInput(Pages.Datastore, "Research Max RP", "integer", function(t)
		UI_STATE.Inputs.DataResearchMaxRP = t
	end)

	local function decodeOptionalJson(raw, fieldName)
		local text = tostring(raw or "")
		if text == "" then
			return nil, nil
		end
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(text)
		end)
		if not ok or type(decoded) ~= "table" then
			return nil, fieldName .. " JSON is invalid"
		end
		return decoded, nil
	end

	refreshBuildingList = function()
		if not BuildingListFrame then
			return
		end
		for _, child in ipairs(BuildingListFrame:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		for index, obj in ipairs(UI_STATE.Datastore.BuildingObjects) do
			local kind = tostring(obj.Type or "Unknown")
			local label = tostring(obj.Item or obj.ID or obj.UUID or ("Object " .. index))
			local btn = Create("TextButton", {
				Parent = BuildingListFrame,
				Size = UDim2.new(1, -6, 0, 28),
				Position = UDim2.new(0, 3, 0, (index - 1) * 30),
				Text = string.format("%d) %s - %s", index, kind, label),
				Font = FONTS.Light,
				TextSize = 12,
				BackgroundColor3 = (UI_STATE.Datastore.SelectedBuildingIndex == index) and THEME.Accent or THEME.Input,
				TextColor3 = THEME.TextMain,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
			}, {Round(4)})
			btn.Activated:Connect(function()
				UI_STATE.Datastore.SelectedBuildingIndex = index
				local selected = UI_STATE.Datastore.BuildingObjects[index]
				BuildingDetailTypeInput.Text = tostring(selected.Type or "")
				BuildingDetailItemInput.Text = tostring(selected.Item or "")
				BuildingDetailUuidInput.Text = tostring(selected.UUID or "")
				BuildingDetailPriceInput.Text = tostring(selected.Price or "")
				if type(selected.CF) == "table" then
					BuildingDetailCfInput.Text = table.concat(selected.CF, ",")
				else
					BuildingDetailCfInput.Text = ""
				end
				refreshBuildingList()
			end)
		end
		BuildingListFrame.CanvasSize = UDim2.new(0, 0, 0, #UI_STATE.Datastore.BuildingObjects * 30)
	end

	local function askConfirmation(title, body, onDecision)
		local modal = Create("Frame", {
			Parent = ScreenGui,
			BackgroundColor3 = THEME.Card,
			Size = UDim2.new(0, 420, 0, 180),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0,
			ZIndex = 50,
		}, {Round(8), Stroke(Color3.fromRGB(60, 60, 75), 1)})

		Create("TextLabel", {
			Parent = modal,
			BackgroundTransparency = 1,
			Text = title,
			Font = FONTS.Header,
			TextSize = 16,
			TextColor3 = THEME.TextMain,
			Size = UDim2.new(1, -20, 0, 30),
			Position = UDim2.new(0, 10, 0, 10),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 51,
		})

		Create("TextLabel", {
			Parent = modal,
			BackgroundTransparency = 1,
			Text = body,
			Font = FONTS.Body,
			TextWrapped = true,
			TextSize = 13,
			TextColor3 = THEME.TextDim,
			Size = UDim2.new(1, -20, 0, 78),
			Position = UDim2.new(0, 10, 0, 45),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 51,
		})

		local buttonRow = Create("Frame", {
			Parent = modal,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -20, 0, 36),
			Position = UDim2.new(0, 10, 1, -46),
			ZIndex = 51,
		}, {Create("UIGridLayout", {CellSize = UDim2.new(0.48, 0, 1, 0), CellPadding = UDim2.new(0, 10, 0, 0)})})

		CreateActionButton(buttonRow, "Save + Refresh", THEME.Warning, function()
			if modal and modal.Parent then
				modal:Destroy()
			end
			onDecision(true)
		end)
		CreateActionButton(buttonRow, "Save Only", THEME.Card, function()
			if modal and modal.Parent then
				modal:Destroy()
			end
			onDecision(false)
		end)
	end

	local function saveCurrentSlot()
		if not UI_STATE.Datastore.ResolvedUserId then
			SetDataStatus("Resolve user first.", true)
			return
		end
		local slot = tonumber(UI_STATE.Inputs.DataSlot)
		if not slot then
			SetDataStatus("Enter a valid slot number.", true)
			return
		end

		local terrainData, terrainErr = decodeOptionalJson(UI_STATE.Inputs.DataTerrainJson, "Terrain")
		if terrainErr then
			SetDataStatus(terrainErr, true)
			return
		end

		local patch = {
			GameData = {
				Money = tonumber(UI_STATE.Inputs.DataMoney),
				Tickets = tonumber(UI_STATE.Inputs.DataTickets),
			},
			Research = {
				RP = tonumber(UI_STATE.Inputs.DataResearchRP),
				MaxRP = tonumber(UI_STATE.Inputs.DataResearchMaxRP),
			},
			Buildings = UI_STATE.Datastore.BuildingObjects,
			TerrainMeta = terrainData,
		}

		local function runSave(applyRefresh)
			local result = DatastoreInvoke("SaveSlot", {
				UserId = UI_STATE.Datastore.ResolvedUserId,
				SlotNum = slot,
				Patch = patch,
				ApplyOnlineRefresh = applyRefresh == true,
			})
			if not result.Success then
				SetDataStatus("Save failed: " .. tostring(result.Error), true)
				return
			end
			SetDataStatus("Save succeeded.", false)
			if result.OnlineRefreshApplied then
				ShowToast("Warning", "World Refreshed", "Target slot was reloaded in-place with the new save data.")
			end
		end

		local preview = DatastoreInvoke("SaveSlot", {
			UserId = UI_STATE.Datastore.ResolvedUserId,
			SlotNum = slot,
			Patch = patch,
			PreviewOnly = true,
			ApplyOnlineRefresh = false,
		})
		if not preview.Success then
			SetDataStatus("Save failed: " .. tostring(preview.Error), true)
			return
		end

		if preview.OnlineRefreshAvailable then
			askConfirmation(
				"Online Player In Edited Slot",
				"The player is currently using this slot in this server. Choose whether to apply changes now with an in-place world refresh or keep changes for next load.",
				function(apply)
					if apply then
						runSave(true)
					else
						runSave(false)
					end
				end
			)
		else
			runSave(false)
		end
	end

	local function wipeCurrentSlot()
		if not UI_STATE.Datastore.ResolvedUserId then
			SetDataStatus("Resolve user first.", true)
			return
		end
		local slot = tonumber(UI_STATE.Inputs.DataSlot)
		if not slot then
			SetDataStatus("Enter a valid slot number.", true)
			return
		end
		local result = DatastoreInvoke("WipeSlot", {
			UserId = UI_STATE.Datastore.ResolvedUserId,
			SlotNum = slot,
		})
		if not result.Success then
			SetDataStatus("Wipe failed: " .. tostring(result.Error), true)
			return
		end
		SetDataStatus("Slot wiped successfully.", false)
	end

	Create("TextLabel", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Text = "BUILDINGS VISUAL EDITOR",
		TextColor3 = THEME.TextDim,
		Font = FONTS.Header,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local BuildingEditorRow = Create("Frame", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 390),
	})

	BuildingListFrame = Create("ScrollingFrame", {
		Parent = BuildingEditorRow,
		BackgroundColor3 = THEME.Input,
		BorderSizePixel = 0,
		Size = UDim2.new(0.42, -6, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, {Round(6), Stroke(Color3.fromRGB(60, 60, 70))})

	local BuildingDetail = Create("Frame", {
		Parent = BuildingEditorRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.58, 0, 1, 0),
		Position = UDim2.new(0.42, 6, 0, 0),
	}, {Create("UIListLayout", {Padding = UDim.new(0, 6)})})

	BuildingDetailTypeInput = CreateInput(BuildingDetail, "Type", "Static / Slope / TwoPoint", function() end)
	BuildingDetailItemInput = CreateInput(BuildingDetail, "Item", "Display item name", function() end)
	BuildingDetailUuidInput = CreateInput(BuildingDetail, "UUID", "Unique id", function() end)
	BuildingDetailPriceInput = CreateInput(BuildingDetail, "Price", "integer", function() end)
	BuildingDetailCfInput = CreateInput(BuildingDetail, "CF components", "12 comma-separated numbers", function() end)

	local BuildingDetailButtons = Create("Frame", {
		Parent = BuildingDetail,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.32, 0, 1, 0), CellPadding = UDim2.new(0, 8, 0, 0)})})

	CreateActionButton(BuildingDetailButtons, "Apply", THEME.Success, function()
		local idx = UI_STATE.Datastore.SelectedBuildingIndex
		if not idx or not UI_STATE.Datastore.BuildingObjects[idx] then
			SetDataStatus("Select a building row first.", true)
			return
		end
		local entry = UI_STATE.Datastore.BuildingObjects[idx]
		entry.Type = BuildingDetailTypeInput.Text
		entry.Item = BuildingDetailItemInput.Text
		entry.UUID = BuildingDetailUuidInput.Text
		entry.Price = tonumber(BuildingDetailPriceInput.Text) or entry.Price
		if BuildingDetailCfInput.Text ~= "" then
			local cf = {}
			for token in string.gmatch(BuildingDetailCfInput.Text, "[^,]+") do
				table.insert(cf, tonumber((token:gsub("%s+", ""))) or 0)
			end
			if #cf == 12 then
				entry.CF = cf
			else
				SetDataStatus("CF requires exactly 12 numbers.", true)
				return
			end
		end
		refreshBuildingList()
		SetDataStatus("Building row updated.", false)
	end)

	CreateActionButton(BuildingDetailButtons, "Add", THEME.Accent, function()
		table.insert(UI_STATE.Datastore.BuildingObjects, {
			Type = "Static",
			Item = "NewObject",
			UUID = HttpService:GenerateGUID(false),
			CF = {1,0,0,0,1,0,0,0,1,0,10,0},
		})
		UI_STATE.Datastore.SelectedBuildingIndex = #UI_STATE.Datastore.BuildingObjects
		refreshBuildingList()
	end)

	CreateActionButton(BuildingDetailButtons, "Remove", THEME.Destructive, function()
		local idx = UI_STATE.Datastore.SelectedBuildingIndex
		if not idx or not UI_STATE.Datastore.BuildingObjects[idx] then
			SetDataStatus("Select a building row first.", true)
			return
		end
		table.remove(UI_STATE.Datastore.BuildingObjects, idx)
		UI_STATE.Datastore.SelectedBuildingIndex = nil
		BuildingDetailTypeInput.Text = ""
		BuildingDetailItemInput.Text = ""
		BuildingDetailUuidInput.Text = ""
		BuildingDetailPriceInput.Text = ""
		BuildingDetailCfInput.Text = ""
		refreshBuildingList()
		SetDataStatus("Building row removed.", false)
	end)

	TerrainJsonInput = CreateInput(Pages.Datastore, "Terrain Meta JSON", "Paste JSON object from loaded data", function(t)
		UI_STATE.Inputs.DataTerrainJson = t
	end)

	local BottomActionBar = Create("Frame", {
		Parent = Pages.Datastore,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
	}, {Create("UIGridLayout", {CellSize = UDim2.new(0.32, 0, 1, 0), CellPadding = UDim2.new(0, 10, 0, 0)})})

	CreateActionButton(BottomActionBar, "Save Slot", THEME.Success, function()
		saveCurrentSlot()
	end)

	CreateActionButton(BottomActionBar, "Wipe Slot", THEME.Destructive, function()
		wipeCurrentSlot()
	end)

	CreateActionButton(BottomActionBar, "Cancel", THEME.Card, function()
		local slot = tonumber(UI_STATE.Inputs.DataSlot)
		if not slot then
			SetDataStatus("No loaded slot to reset.", true)
			return
		end
		loadSelectedSlot(slot)
		SetDataStatus("Changes canceled. Reloaded slot from datastore.", false)
	end)
end

-- // NAVIGATION //
local NavButtons = {}
NavButtons["Overview"] = CreateNavButton("Overview", "📊", "Overview")
NavButtons["Moderation"] = CreateNavButton("Moderation", "🛡️", "Moderation")
NavButtons["Economy"] = CreateNavButton("Economy", "💰", "Economy")
NavButtons["Gamepasses"] = CreateNavButton("Gamepasses", "🎟️", "Gamepasses")
NavButtons["Server"] = CreateNavButton("Server", "📡", "Server")
NavButtons["Leaderboard"] = CreateNavButton("Leaderboard", "🏆", "Leaderboard")
NavButtons["Servers"] = CreateNavButton("Servers", "🌐", "Servers")
if IS_DATASTORE_ADMIN then
	NavButtons["Datastore"] = CreateNavButton("Datastore", "🗄️", "Datastore")
end

local function SwitchPage(pageName)
	UI_STATE.CurrentPage = pageName

	for name, btn in pairs(NavButtons) do
		local active = (name == pageName)
		TweenService:Create(btn, TweenInfo.new(0.3), {BackgroundColor3 = active and THEME.Card or THEME.Sidebar}):Play()
		TweenService:Create(btn.TextLabel, TweenInfo.new(0.3), {TextColor3 = active and THEME.TextMain or THEME.TextDim}):Play()
	end

	for name, frame in pairs(Pages) do
		frame.Visible = false
	end
	if Pages[pageName] then
		Pages[pageName].Visible = true

		-- Auto-refresh server list when switching to Servers page
		if pageName == "Servers" then
			RefreshServerList()
		end
	end
end

for name, btn in pairs(NavButtons) do
	btn.Activated:Connect(function() SwitchPage(name) end)
end

SwitchPage("Overview")

-- // DRAG //
local dragging, dragInput, dragStart, startPos
MainFrame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = MainFrame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end
end)

MainFrame.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

-- // TOAST NOTIFICATIONS //
if ToastRemote then
	ToastRemote.OnClientEvent:Connect(function(toastType, title, message)
		local Bindable = ReplicatedStorage:FindFirstChild("ClientNotification")
		if Bindable then
			Bindable:Fire(toastType, title, message, 5)
		else
		
		end
	end)
end

-- // TOGGLE //
local function Toggle()
	UI_STATE.IsVisible = not UI_STATE.IsVisible
	if UI_STATE.IsVisible and ClosePanels then ClosePanels:Fire("DevPanel") end
	ScreenGui.Enabled = UI_STATE.IsVisible

	if UI_STATE.IsVisible then
		MainFrame.UIScale.Scale = 0.8
		TweenService:Create(MainFrame.UIScale, TweenInfo.new(0.3, Enum.EasingStyle.Back), {Scale = 1}):Play()
	end
end


if ClosePanels then
	ClosePanels.Event:Connect(function(source)
		if source == "DevPanel" then return end
		if UI_STATE.IsVisible then Toggle() end
	end)
end

-- // /dev COMMAND LISTENER //
if ToggleDevPanelRemote then
	ToggleDevPanelRemote.OnClientEvent:Connect(function()
		if IS_ADMIN then
			Toggle()
		end
	end)
end
