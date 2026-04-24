local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local SAMPLE_INTERVAL = 2
local STUCK_THRESHOLD = 8
local MIN_PROGRESS_DELTA = 0.001
local RECOVERY_STEP = 0.04

local lastClockTime = Lighting.ClockTime
local lastProgressAt = os.clock()

local function normalizeClockTime(value)
	local wrapped = tonumber(value) or 0
	wrapped = wrapped % 24
	if wrapped < 0 then
		wrapped += 24
	end
	return wrapped
end

local function shortestClockDelta(current, previous)
	local delta = math.abs(current - previous)
	return math.min(delta, math.abs((current + 24) - previous), math.abs(current - (previous + 24)))
end

task.spawn(function()
	while true do
		task.wait(SAMPLE_INTERVAL)
		if not RunService:IsRunning() then
			continue
		end

		local currentClockTime = normalizeClockTime(Lighting.ClockTime)
		local delta = shortestClockDelta(currentClockTime, lastClockTime)
		local now = os.clock()
		local sandboxMultiplier = tonumber(_G.SandboxTimeMultiplier)
		if Lighting:GetAttribute("ManualTime") == true or sandboxMultiplier == 0 then
			lastClockTime = currentClockTime
			lastProgressAt = now
			continue
		end

		if delta > MIN_PROGRESS_DELTA then
			lastProgressAt = now
		else
			local stuckFor = now - lastProgressAt
			if stuckFor >= STUCK_THRESHOLD then
				local recovered = normalizeClockTime(currentClockTime + RECOVERY_STEP)
				Lighting.ClockTime = recovered
				lastProgressAt = now
				currentClockTime = recovered
			end
		end

		lastClockTime = currentClockTime
	end
end)