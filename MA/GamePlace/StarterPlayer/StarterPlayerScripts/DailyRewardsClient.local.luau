--[=[ PATH: StarterPlayer/StarterPlayerScripts/DailyRewardsClient | TYPE: LocalScript ]=]--
-- ════════════════════════════════════════════════════════════════════
--  DAILY REWARDS CLIENT
--  Connects the DailyRewardsGui (built by DailyRewardsCMDBar) to the
--  DailyRewardsServer via remote events.
--
--  Remotes used:
--    RequestDailyInfo  (fire → server sends back DailyRewardInfo)
--    DailyRewardInfo   (server → client; payload table)
--    ClaimDailyReward  (fire → server processes and sends back updated info)
--
--  Entry-point: auto-opens if player.canClaim == true on join after 5s.
--  Can also be opened from a button / chat command via BindableEvent "OpenDailyRewards".
-- ════════════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local player      = Players.LocalPlayer
local PlayerGui   = player:WaitForChild("PlayerGui")

local Events          = ReplicatedStorage:WaitForChild("Events")
local RequestDailyInfo = Events:WaitForChild("RequestDailyInfo")
local DailyRewardInfo  = Events:WaitForChild("DailyRewardInfo")
local ClaimDailyReward = Events:WaitForChild("ClaimDailyReward")

-- ── STATE ─────────────────────────────────────────────────────────────
local cachedPayload = nil
local countdownConn = nil

-- ── GUI REFERENCES ────────────────────────────────────────────────────
local gui = PlayerGui:WaitForChild("DailyRewardsGui", 10)
if not gui then
	warn("[DailyRewardsClient] DailyRewardsGui not found. Run DailyRewardsCMDBar first.")
	return
end

local bg        = gui:WaitForChild("BG")
local panel     = bg:WaitForChild("Panel")
local title     = panel:FindFirstChild("Title")
local streak    = panel:FindFirstChild("StreakLabel")
local strip     = panel:FindFirstChild("DayStrip")
local claimBtn  = panel:FindFirstChild("ClaimBtn")
local nextLabel = panel:FindFirstChild("NextLabel")
local premBadge = panel:FindFirstChild("PremiumBadge")
local closeBtn  = panel:FindFirstChild("Close")

-- BASE colours (copy from CMDBar palette for client use)
local CLR_DAY_BASE   = Color3.fromRGB(28,  32,  45)
local CLR_DAY_ACTIVE = Color3.fromRGB(40,  80, 160)
local CLR_CLAIM_ON   = Color3.fromRGB(60, 190, 80)
local CLR_CLAIM_OFF  = Color3.fromRGB(60,  65,  80)

-- ── HELPERS ───────────────────────────────────────────────────────────

local function fmtCountdown(secs: number): string
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	return string.format("%dh %dm", h, m)
end

local function fmtMoney(n: number): string
	if n >= 1e6 then return string.format("$%.1fM", n / 1e6)
	elseif n >= 1000 then return string.format("$%.0fK", n / 1000)
	end
	return "$" .. tostring(n)
end

local function setVisible(show: boolean)
	gui.Enabled = show
	if show then
		panel.Size = UDim2.new(0, 10, 0, 10)
		TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Size = UDim2.new(0, 560, 0, 360)
		}):Play()
	end
end

-- ── APPLY PAYLOAD ─────────────────────────────────────────────────────

local function applyPayload(payload)
	if not payload then return end
	cachedPayload = payload

	-- Streak label
	local dayIndex = ((payload.streak - 1) % 7) + 1
	if streak then
		streak.Text = string.format("Day %d of 7 — Keep your streak!", dayIndex)
	end

	-- Premium badge
	if premBadge then
		premBadge.Visible = payload.premium == true
	end

	-- Day strip highlighting
	if strip then
		for i = 1, 7 do
			local dayFrame = strip:FindFirstChild("Day" .. i)
			if dayFrame then
				local checkmark = dayFrame:FindFirstChild("Checkmark")
				-- Days before current streak index = done; current = active; future = base
				if i < dayIndex then
					dayFrame.BackgroundColor3 = CLR_DAY_BASE
					if checkmark then checkmark.Visible = true end
				elseif i == dayIndex then
					dayFrame.BackgroundColor3 = CLR_DAY_ACTIVE
					if checkmark then checkmark.Visible = false end
				else
					dayFrame.BackgroundColor3 = CLR_DAY_BASE
					if checkmark then checkmark.Visible = false end
				end

				-- Update reward text with premium multiplier
				local rewardLabel = dayFrame:FindFirstChild("Reward")
				if rewardLabel then
					local baseValues = { 5000, 10000, 15000, 25000, 35000, 50000, 100000 }
					local baseAmt = baseValues[i] or 0
					local finalAmt = payload.premium and (baseAmt * 2) or baseAmt
					rewardLabel.Text = fmtMoney(finalAmt)
					rewardLabel.TextColor3 = payload.premium
						and Color3.fromRGB(255, 215, 30)
						or Color3.fromRGB(200, 165, 30)
				end
			end
		end
	end

	-- Claim button state
	if claimBtn then
		if payload.canClaim then
			claimBtn.BackgroundColor3 = CLR_CLAIM_ON
			claimBtn.Text = "CLAIM  " .. fmtMoney(payload.reward)
			claimBtn.Active = true
		else
			claimBtn.BackgroundColor3 = CLR_CLAIM_OFF
			claimBtn.Text = "ALREADY CLAIMED"
			claimBtn.Active = false
		end
	end

	-- Countdown label
	if nextLabel then
		if payload.canClaim then
			nextLabel.Text = payload.premium and "2× Premium Rewards Active!" or "Your reward is ready!"
		else
			nextLabel.Text = "Next reward in " .. fmtCountdown(payload.nextIn)
		end
	end

	-- Live countdown ticker
	if countdownConn then countdownConn:Disconnect() end
	if not payload.canClaim and payload.nextIn > 0 then
		local remaining = payload.nextIn
		countdownConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
			remaining = remaining - dt
			if remaining <= 0 then
				countdownConn:Disconnect()
				countdownConn = nil
				if nextLabel then nextLabel.Text = "Your reward is ready! Claim now." end
				if claimBtn then
					claimBtn.BackgroundColor3 = CLR_CLAIM_ON
					claimBtn.Text = fmtMoney(payload.reward) .. " — CLAIM"
					claimBtn.Active = true
				end
			else
				if nextLabel then
					nextLabel.Text = "Next reward in " .. fmtCountdown(math.ceil(remaining))
				end
			end
		end)
	end
end

-- ── REMOTE BINDINGS ───────────────────────────────────────────────────

DailyRewardInfo.OnClientEvent:Connect(applyPayload)

if claimBtn then
	claimBtn.MouseButton1Click:Connect(function()
		if cachedPayload and cachedPayload.canClaim then
			ClaimDailyReward:FireServer()
		end
	end)
end

if closeBtn then
	closeBtn.MouseButton1Click:Connect(function()
		setVisible(false)
	end)
end

-- Close on overlay click
bg.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- Only close if clicking the bg (not the panel)
		setVisible(false)
	end
end)

-- ── OPEN TRIGGERS ─────────────────────────────────────────────────────

local function openGui()
	RequestDailyInfo:FireServer()
	setVisible(true)
end

-- BindableEvent so other scripts / hotbar can open the daily rewards panel
local Events2 = ReplicatedStorage:WaitForChild("Events")
local openBind = Events2:FindFirstChild("OpenDailyRewards")
if openBind and openBind:IsA("BindableEvent") then
	openBind.Event:Connect(openGui)
end

-- Auto-open if reward is available on join
task.delay(6, function()
	RequestDailyInfo:FireServer()
	-- Wait for server response
	local conn; conn = DailyRewardInfo.OnClientEvent:Connect(function(payload)
		conn:Disconnect()
		if payload and payload.canClaim then
			setVisible(true)
		end
	end)
end)
