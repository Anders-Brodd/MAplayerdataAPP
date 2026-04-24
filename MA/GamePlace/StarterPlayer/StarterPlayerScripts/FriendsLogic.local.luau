local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Player = Players.LocalPlayer
local ScreenGui = Player:WaitForChild("PlayerGui"):WaitForChild("FriendsSystemUI")

-- // 1. GET UI OBJECTS //
local ToggleBtn = ScreenGui:WaitForChild("FriendsBtn")
local Panel = ScreenGui:WaitForChild("MainPanel")

if not ToggleBtn or not Panel then 
	warn("❌ UI elements not found!")
	return 
end

local Header = Panel:WaitForChild("Header", 5)
local CloseBtn = Header and Header:WaitForChild("CloseButton", 5)
local LeftSide = Panel.SplitContainer.LeftSide
local DisplayCode = LeftSide.DisplayCode
local CopyBtn = LeftSide.CopyBtn
local RightSide = Panel.SplitContainer.RightSide
local InputBox = RightSide.InputBox
local JoinBtn = RightSide.JoinBtn

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiButton")) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

-- // 2. CONNECT TO SERVER //
local Events = ReplicatedStorage:WaitForChild("Events")
local ResolvePinFunc = Events:WaitForChild("ResolveJoinPin")
local ServerCodeValue = Events:WaitForChild("ServerAccessCode")

-- // 3. LOGIC //
local function updateCode()
	if ServerCodeValue then
		local code = ServerCodeValue.Value
		if code ~= "" and code ~= "ERR" then
			DisplayCode.Text = code
		elseif code == "ERR" then
			DisplayCode.Text = "ERROR"
		else
			DisplayCode.Text = "LOADING..."
		end
	else
		DisplayCode.Text = "NO CONNECTION"
	end
end

local function showManualCopyField(code)
	local existing = LeftSide:FindFirstChild("ManualCopyInput")
	if existing and not existing:IsA("TextBox") then
		existing:Destroy()
		existing = nil
	end
	if not existing then
		existing = Instance.new("TextBox")
		existing.Name = "ManualCopyInput"
		existing.Size = DisplayCode.Size
		existing.Position = DisplayCode.Position
		existing.AnchorPoint = DisplayCode.AnchorPoint
		existing.BackgroundTransparency = 1
		existing.ClearTextOnFocus = false
		existing.MultiLine = false
		existing.TextXAlignment = Enum.TextXAlignment.Left
		existing.TextColor3 = DisplayCode.TextColor3
		existing.Font = DisplayCode.Font
		existing.TextSize = DisplayCode.TextSize
		existing.ZIndex = DisplayCode.ZIndex + 1
		existing.Parent = LeftSide
		local function restoreDisplay()
			if existing and existing.Parent then
				existing.Visible = false
			end
			DisplayCode.Visible = true
		end
		existing.FocusLost:Connect(function()
			task.defer(restoreDisplay)
		end)
	end
	DisplayCode.Visible = false
	existing.Visible = true
	existing.Active = true
	existing.TextEditable = true
	existing.Text = code
	task.defer(function()
		if existing and existing.Parent then
			existing:CaptureFocus()
			existing.CursorPosition = #code + 1
			existing.SelectionStart = 1
		end
	end)
	return existing
end

if ServerCodeValue then 
	ServerCodeValue.Changed:Connect(updateCode) 
end
updateCode()

-- Toggle Panel
local function toggleMenu() 
	Panel.Visible = not Panel.Visible 
end
bindGuiButton(ToggleBtn, toggleMenu)
if CloseBtn then
	bindGuiButton(CloseBtn, toggleMenu)
else
	warn("FriendsLogic: Close button not found!")
end

-- Copy Code to Clipboard
CopyBtn.MouseButton1Click:Connect(function()
	local code = DisplayCode.Text
	if code == "LOADING..." or code == "ERROR" or code == "NO CONNECTION" then
		return
	end

	local copiedToClipboard = false
	local clipboardFn = type(getfenv) == "function" and getfenv().setclipboard or nil
	if type(clipboardFn) == "function" then
		copiedToClipboard = pcall(function()
			clipboardFn(code)
		end)
	end
	if not copiedToClipboard then
		showManualCopyField(code)
	end

	local originalText = CopyBtn.Text
	local originalColor = CopyBtn.BackgroundColor3
	CopyBtn.Text = copiedToClipboard and "COPIED" or "PIN SELECTED"
	CopyBtn.BackgroundColor3 = Color3.fromRGB(76, 164, 90)
	task.delay(1.5, function()
		if CopyBtn and CopyBtn.Parent then
			CopyBtn.Text = originalText
			CopyBtn.BackgroundColor3 = originalColor
		end
	end)
end)

-- Join Server via PIN
local isProcessing = false
JoinBtn.MouseButton1Click:Connect(function()
	if isProcessing then return end  -- Prevent spam clicking
	
	local pin = string.upper(string.gsub(InputBox.Text, "%s+", ""))  -- Remove whitespace
	
	if string.len(pin) < 4 then
		JoinBtn.Text = "ENTER CODE"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		task.wait(1)
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
		return
	end
	
	isProcessing = true
	JoinBtn.Text = "SEARCHING..."
	JoinBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 40)
	
	-- Ask Server to look up PIN and teleport us
	local response = nil
	if ResolvePinFunc then
		local success, result = pcall(function()
			return ResolvePinFunc:InvokeServer(pin)
		end)
		if success then
			response = result
		else
			response = "CONNECTION_ERR"
			warn("❌ Failed to communicate with server:", result)
		end
	else
		response = "NO_REMOTE"
	end
	
	print("📥 Server Response:", response)
	
	-- Handle Response
	if response == "TELEPORTING" then
		JoinBtn.Text = "✈️ TELEPORTING..."
		JoinBtn.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
		-- Player will be teleported, no reset needed
	elseif response == "INVALID_PIN" then
		JoinBtn.Text = "❌ INVALID CODE"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	elseif response == "ALREADY_HERE" then
		JoinBtn.Text = "✓ ALREADY HERE"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(100, 150, 255)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	elseif response == "STUDIO_NO_TP" then
		JoinBtn.Text = "STUDIO MODE"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 200, 50)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	elseif response and string.match(tostring(response), "^TP_FAIL") then
		JoinBtn.Text = "TELEPORT FAILED"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		warn("❌ Teleport Error:", response)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	elseif response == "CONNECTION_ERR" or response == "NO_REMOTE" then
		JoinBtn.Text = "CONNECTION ERROR"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	else
		JoinBtn.Text = "UNKNOWN ERROR"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		warn("❌ Unexpected response:", response)
		task.wait(2)
		isProcessing = false
		JoinBtn.Text = "JOIN SERVER >"
		JoinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	end
end)