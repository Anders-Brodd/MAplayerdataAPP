-- DEPRECATED: AFK limits removed
if true then
	return
end

--[=[ PATH: StarterPlayer/StarterPlayerScripts/AFKReporter | TYPE: LocalScript ]=]--
-- ════════════════════════════════════════════════════════════════════
--  AFK REPORTER  (Client)
--  Fires "PlayerActivity" RemoteEvent to the server on any meaningful
--  input so AFKManager can reset the idle timer.
--  Throttled to at most once every REPORT_INTERVAL seconds.
-- ════════════════════════════════════════════════════════════════════

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REPORT_INTERVAL = 30  -- seconds between activity pings

local Events = ReplicatedStorage:WaitForChild("Events")
local PlayerActivity = Events:WaitForChild("PlayerActivity")

local lastReported = 0

local function reportActivity()
	local now = tick()
	if now - lastReported >= REPORT_INTERVAL then
		lastReported = now
		PlayerActivity:FireServer()
	end
end

-- ── INPUT LISTENERS ──────────────────────────────────────────────────
UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseButton2
		or t == Enum.UserInputType.MouseButton3
		or t == Enum.UserInputType.Touch
		or t == Enum.UserInputType.Gamepad1
	then
		reportActivity()
	end
end)

UserInputService.InputChanged:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
	then
		reportActivity()
	end
end)

-- Also send a heartbeat every REPORT_INTERVAL seconds so the timer doesn't
-- expire just because the player is watching their resort without touching input.
-- (Remove this if you want strict input-only AFK detection.)
task.spawn(function()
	while true do
		task.wait(REPORT_INTERVAL)
		reportActivity()
	end
end)
