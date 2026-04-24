--[[
    ROBLOX BACKGROUND MUSIC SYSTEM
    Features: Crossfading, "Now Playing" UI Notification, Playlist Looping
    Location: Put this LocalScript inside StarterPlayer > StarterPlayerScripts
]]

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local FADE_TIME = 2 -- Seconds to fade between songs
local VOLUME_MAX = 0.5 -- Max volume for music (0 to 1)

-- REAL Asset IDs provided below. Replace with your own if needed.
local PLAYLIST = {
	{Id = "rbxassetid://1839971194", Title = "Chill Synthwave"},
	{Id = "rbxassetid://95821807101604", Title = "Alpine Breeze"}, 
	{Id = "rbxassetid://107216484154712", Title = "Slope Serenity"},
	{Id = "rbxassetid://138970888652749", Title = "Winter Lo-Fi"}
}

--------------------------------------------------------------------------------
-- UI GENERATION (Creates the UI automatically)
--------------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MusicHUD"
screenGui.ResetOnSpawn = false -- Keep music UI alive on respawn
screenGui.Parent = playerGui

-- Container for the toast notification
local notificationFrame = Instance.new("Frame")
notificationFrame.Name = "NotificationFrame"
notificationFrame.Size = UDim2.new(0, 250, 0, 60)
-- Positioned bottom right (off screen initially for animation)
notificationFrame.AnchorPoint = Vector2.new(1, 1) 
notificationFrame.Position = UDim2.new(1, -20, 1, 50) -- Start hidden below screen
notificationFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
notificationFrame.BackgroundTransparency = 0.3
notificationFrame.BorderSizePixel = 0
notificationFrame.Parent = screenGui

-- Glass/Rounded look
local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 12)
uiCorner.Parent = notificationFrame

local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(255, 255, 255)
uiStroke.Transparency = 0.8
uiStroke.Thickness = 1
uiStroke.Parent = notificationFrame

-- Icon
local icon = Instance.new("ImageLabel")
icon.Size = UDim2.new(0, 30, 0, 30)
icon.Position = UDim2.new(0, 15, 0.5, 0)
icon.AnchorPoint = Vector2.new(0, 0.5)
icon.BackgroundTransparency = 1
icon.Image = "rbxassetid://7072721682" -- Generic music note icon
icon.ImageColor3 = Color3.fromRGB(200, 230, 255)
icon.Parent = notificationFrame

-- "Now Playing" Label
local labelHeader = Instance.new("TextLabel")
labelHeader.Text = "NOW PLAYING"
labelHeader.Size = UDim2.new(1, -60, 0, 15)
labelHeader.Position = UDim2.new(0, 55, 0, 12)
labelHeader.BackgroundTransparency = 1
labelHeader.TextSize = 10
labelHeader.Font = Enum.Font.GothamBold
labelHeader.TextColor3 = Color3.fromRGB(150, 200, 255)
labelHeader.TextXAlignment = Enum.TextXAlignment.Left
labelHeader.Parent = notificationFrame

-- Song Title Label
local labelTitle = Instance.new("TextLabel")
labelTitle.Text = "Loading..."
labelTitle.Size = UDim2.new(1, -60, 0, 20)
labelTitle.Position = UDim2.new(0, 55, 0, 28)
labelTitle.BackgroundTransparency = 1
labelTitle.TextSize = 14
labelTitle.Font = Enum.Font.GothamMedium
labelTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
labelTitle.TextXAlignment = Enum.TextXAlignment.Left
labelTitle.TextTruncate = Enum.TextTruncate.AtEnd
labelTitle.Parent = notificationFrame

--------------------------------------------------------------------------------
-- MUSIC LOGIC
--------------------------------------------------------------------------------

local currentSound = nil
local currentIndex = 0
local isNotificationVisible = false

-- Function to show the UI toast
local function showNotification(songName)
	labelTitle.Text = songName

	-- Animation: Slide Up
	local tweenInfoIn = TweenInfo.new(0.8, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	local goalIn = {Position = UDim2.new(1, -20, 1, -20), BackgroundTransparency = 0.3}
	TweenService:Create(notificationFrame, tweenInfoIn, goalIn):Play()

	-- Wait then hide
	task.delay(5, function()
		-- Check if title hasn't changed (prevent hiding if a new song started rapidly)
		if labelTitle.Text == songName then
			local tweenInfoOut = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local goalOut = {Position = UDim2.new(1, -20, 1, 80), BackgroundTransparency = 1} -- Slide down
			TweenService:Create(notificationFrame, tweenInfoOut, goalOut):Play()
		end
	end)
end

-- Function to play a track
local function playTrack(index)
	local trackData = PLAYLIST[index]
	if not trackData then return end

	-- 1. Create new sound object
	local newSound = Instance.new("Sound")
	newSound.Name = "Music_" .. trackData.Title
	newSound.SoundId = trackData.Id
	newSound.Volume = 0 -- Start silent for fade-in
	newSound.Looped = false
	newSound.Parent = SoundService

	-- 2. Handle Old Sound (Fade Out)
	if currentSound then
		local oldSound = currentSound
		local fadeOutTween = TweenService:Create(oldSound, TweenInfo.new(FADE_TIME), {Volume = 0})
		fadeOutTween:Play()
		fadeOutTween.Completed:Connect(function()
			oldSound:Destroy()
		end)
	end

	currentSound = newSound

	-- 3. Play New Sound (Fade In)
	newSound:Play()
	local fadeInTween = TweenService:Create(newSound, TweenInfo.new(FADE_TIME), {Volume = VOLUME_MAX})
	fadeInTween:Play()

	-- 4. Show UI
	showNotification(trackData.Title)

	-- 5. Setup Next Track Event
	newSound.Ended:Connect(function()
		local nextIndex = index + 1
		if nextIndex > #PLAYLIST then
			nextIndex = 1 -- Loop back to start
		end
		playTrack(nextIndex)
	end)
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

-- Start the first track
task.wait(1) -- Short delay to ensure game loads
currentIndex = 1
playTrack(currentIndex)