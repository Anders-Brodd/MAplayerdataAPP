--[[
    ROBLOX BACKGROUND MUSIC SYSTEM
    Features: Crossfading, "Now Playing" UI Notification, Playlist Looping, Settings Integration
    Location: Put this LocalScript inside StarterPlayer > StarterPlayerScripts
]]

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local FADE_TIME = 2
local VOLUME_MAX = 0.5

local PLAYLIST = {
	{Id = "rbxassetid://1839971194", Title = "Chill Synthwave"},
	{Id = "rbxassetid://95821807101604", Title = "Alpine Breeze"}, 
	{Id = "rbxassetid://107216484154712", Title = "Slope Serenity"},
	{Id = "rbxassetid://138970888652749", Title = "Winter Lo-Fi"}
}

--------------------------------------------------------------------------------
-- UI GENERATION
--------------------------------------------------------------------------------

local screenGui = playerGui:WaitForChild("MusicHUD")
local notificationFrame = screenGui:WaitForChild("NotificationFrame")
local labelTitle = notificationFrame:WaitForChild("labelTitle")

--------------------------------------------------------------------------------
-- MUSIC LOGIC
--------------------------------------------------------------------------------

local currentSound = nil
local currentIndex = 0
local isMusicEnabled = true  -- Track music state

local function showNotification(songName)
	labelTitle.Text = songName

	local tweenInfoIn = TweenInfo.new(0.8, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	local goalIn = {Position = UDim2.new(1, -20, 1, -20), BackgroundTransparency = 0.3}
	TweenService:Create(notificationFrame, tweenInfoIn, goalIn):Play()

	task.delay(5, function()
		if labelTitle.Text == songName then
			local tweenInfoOut = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local goalOut = {Position = UDim2.new(1, -20, 1, 80), BackgroundTransparency = 1}
			TweenService:Create(notificationFrame, tweenInfoOut, goalOut):Play()
		end
	end)
end

local function playTrack(index)
	-- Don't play if music is disabled
	if not isMusicEnabled then return end

	local trackData = PLAYLIST[index]
	if not trackData then return end

	local newSound = Instance.new("Sound")
	newSound.Name = "Music_" .. trackData.Title
	newSound.SoundId = trackData.Id
	newSound.Volume = 0
	newSound.Looped = false
	newSound.Parent = SoundService

	if currentSound then
		local oldSound = currentSound
		local fadeOutTween = TweenService:Create(oldSound, TweenInfo.new(FADE_TIME), {Volume = 0})
		fadeOutTween:Play()
		fadeOutTween.Completed:Connect(function()
			oldSound:Destroy()
		end)
	end

	currentSound = newSound
	currentIndex = index

	newSound:Play()
	local fadeInTween = TweenService:Create(newSound, TweenInfo.new(FADE_TIME), {Volume = VOLUME_MAX})
	fadeInTween:Play()

	showNotification(trackData.Title)

	newSound.Ended:Connect(function()
		-- Only continue if music is still enabled
		if not isMusicEnabled then return end

		local nextIndex = index + 1
		if nextIndex > #PLAYLIST then
			nextIndex = 1
		end
		playTrack(nextIndex)
	end)
end

--------------------------------------------------------------------------------
-- SETTINGS INTEGRATION (THE FIX!)
--------------------------------------------------------------------------------

local function setMusicEnabled(enabled)
	isMusicEnabled = enabled

	if enabled then
		-- Resume music from where we left off (or start fresh)
		if not currentSound or not currentSound.IsPlaying then
			playTrack(currentIndex > 0 and currentIndex or 1)
		end
	else
		-- Fade out and stop current music
		if currentSound then
			local fadeOutTween = TweenService:Create(currentSound, TweenInfo.new(FADE_TIME), {Volume = 0})
			fadeOutTween:Play()
			fadeOutTween.Completed:Connect(function()
				if currentSound then
					currentSound:Stop()
					currentSound:Destroy()
					currentSound = nil
				end
			end)
		end

		-- Hide notification
		local tweenInfoOut = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(notificationFrame, tweenInfoOut, {Position = UDim2.new(1, -20, 1, 80), BackgroundTransparency = 1}):Play()
	end
end

-- Listen for the attribute change from SettingsController
player:GetAttributeChangedSignal("MusicEnabled"):Connect(function()
	local enabled = player:GetAttribute("MusicEnabled")
	if enabled ~= nil then
		setMusicEnabled(enabled)
	end
end)

-- Check initial state (in case attribute was set before this script ran)
local initialState = player:GetAttribute("MusicEnabled")
if initialState ~= nil then
	isMusicEnabled = initialState
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

task.wait(1)
if isMusicEnabled then
	currentIndex = 1
	playTrack(currentIndex)
end