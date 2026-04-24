local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if _G.ServerTipBroadcasterStarted then
	return
end
_G.ServerTipBroadcasterStarted = true

local Events = ReplicatedStorage:WaitForChild("Events")
local TipEvent = Events:FindFirstChild("ServerTipBroadcast")
if not TipEvent then
	TipEvent = Instance.new("RemoteEvent")
	TipEvent.Name = "ServerTipBroadcast"
	TipEvent.Parent = Events
end

local TIPS = {
	-- 1-10
	"Use /ws <number> in chat to change your walkspeed, and /ws default to reset it.",
	"Found a bug? Report it using the bottom left button!",
	"Hold Shift while moving to sprint faster.",
	"Build food buildings so hungry guests do not leave unhappy.",
	"Build hotels so tired guests can recover energy.",
	"Guests need rental access before they can ski.",
	"Lifts are strongest when they serve at least one skiable slope.",
	"Place lift unload areas near good downhill slope entries.",
	"Keep load and unload station zones clear of obstacles.",
	"Adding a second lift can dramatically reduce long queue times.",

	-- 11-20
	"Spread guests across multiple lifts to avoid one overloaded queue.",
	"Lift staff can improve service quality and rider satisfaction.",
	"Mechanic support helps keep busy lifts reliable.",
	"Chef-staffed food buildings improve guest experience.",
	"Rental tech support can improve rental performance and safety.",
	"Groomed slopes usually give guests a better ride experience.",
	"Use snowmaking to maintain ski coverage during weak snowfall.",
	"Season and weather shifts can change how many guests show up.",
	"If ticket prices get too high, some guests may skip lifts.",
	"Watch queue pressure and adjust capacity before lines explode.",

	-- 21-30
	"Start with beginner-friendly slopes so more guests can ski early.",
	"Add slope difficulty variety as your resort grows.",
	"Name important lifts clearly so management is easier.",
	"Use Edit Mode to fine-tune lift pole placement after building.",
	"Press V in pole edit mode to switch Vertical and Slide movement.",
	"Use U and J while editing poles for precise up/down adjustments.",
	"Build extra station space to reduce crowding at lift bases.",
	"Avoid routing lift lines directly through heavy ski traffic zones.",
	"Decor and polish can support rating and overall resort feel.",
	"Research unlocks and improvements can raise long-term performance.",

	-- 31-40
	"Spend research points on bottlenecks first, not random upgrades.",
	"Track upkeep costs so growth does not outpace income.",
	"High upkeep with low traffic can drain profits quickly.",
	"Guest thought bubbles often point to your next best fix.",
	"If guests complain about rentals, add or improve rental access.",
	"If guests are tired often, add hotels closer to activity hubs.",
	"If guests are hungry often, add food near lift bases.",
	"Keep pedestrian routes clear so guests can path efficiently.",
	"Do not block queue entry areas with decor or props.",
	"Use operations panels to monitor resort health continuously.",

	-- 41-50
	"Test weather and time scenarios in Studio before live balancing.",
	"Use the in-game bug report UI when you can reproduce issues.",
	"A clear bug report title and steps can cut fix time massively.",
	"A stable starter setup is one reliable lift plus multiple slopes.",
	"Lower ticket prices when demand drops to keep lift usage up.",
	"Raise ticket prices slowly when queues are consistently overloaded.",
	"Too many advanced runs early can hurt beginner guest satisfaction.",
	"Give every unload area a clear downhill route for smooth flow.",
	"Multiple slope exits reduce clumping and collisions.",
	"Station access should be simple and walkable from guest spawn paths.",

	-- 51-60
	"Use Paint Mode to improve readability and visual quality.",
	"Use Removal Mode to clear objects that break guest pathing.",
	"Queue performance improves when entry paths are wide and direct.",
	"Place food and hotels near high-traffic areas for better utility.",
	"Distribute services across the mountain, not only at one base.",
	"Use Freecam when checking visibility and route readability.",
	"Repair or replace problem lifts quickly to protect rating.",
	"Higher satisfaction generally supports stronger overall resort ratings.",
	"Slope crashes can increase on poor layouts or harsh transitions.",
	"Beginner guests usually prefer easier slope difficulties.",

	-- 61-70
	"Instructor coverage can help low-skill guests progress safely.",
	"Add easier lesson-friendly terrain near beginner access points.",
	"Coverage consistency matters more than one perfect slope section.",
	"Slope variety improves perceived resort quality.",
	"A balanced lift-to-slope ratio improves guest throughput.",
	"Watch queue overflow early and scale before guests stall.",
	"When one lift is always full, add parallel capacity.",
	"Choose lift types based on traffic and terrain needs.",
	"Keep hotel exits clear so guests do not get stuck near spawn areas.",
	"If guests loop idle, check missing services or blocked paths.",

	-- 71-80
	"Use sandbox/testing workflows to validate risky layout changes.",
	"Rename major placed objects so future edits are faster.",
	"Use top-bar shortcuts to move faster between economy panels.",
	"Treat admin/dev controls as testing tools, not default gameplay.",
	"/walkspeed <number> works as an alias for /ws.",
	"Use /ws reset (or /ws default) to restore default movement speed.",
	"Mobile players can use the RUN button to toggle sprint behavior.",
	"Shift sprint only helps when your character is actually moving.",
	"Build queue-friendly approaches to reduce boarding delays.",
	"Avoid placing static decor inside active queue lanes.",

	-- 81-90
	"Track rating trends over time to catch hidden issues early.",
	"Use pricing and staffing together to stabilize demand.",
	"Upgrade staff where queues are worst for the best ROI.",
	"Prioritize mechanic coverage on your busiest lifts.",
	"Always keep at least one gentle green route available.",
	"Every major lift should connect to usable ski terrain.",
	"If a tip seems wrong for your build, share feedback in our communications.",
	"Bug reports with exact repro steps are the fastest to fix.",
	"Invite friends to stress-test queue flow and layout bottlenecks.",
	"Small iterative tuning beats giant risky rebuilds.",

	-- 91-100
	"Keep enough capacity near spawn so new guests engage quickly.",
	"Place services where guests already travel, not where they never go.",
	"Check both queue length and wait time before changing prices.",
	"When guests avoid a lift, verify it serves valid downhill routes.",
	"Use station spacing and approach lanes to prevent crowd jams.",
	"Too many disconnected slopes can hurt practical ski flow.",
	"A clear resort core often outperforms over-spread early layouts.",
	"If lift usage is low, inspect ticket price, pathing, and slope links.",
	"Review complaints in context; one message is less important than trends.",
	"Build, test, tune, repeat: consistent iteration wins in the long run.",
}

local PRIORITY_COUNT = 8
local INITIAL_DELAY = RunService:IsStudio() and 10 or 30
local TIP_INTERVAL = RunService:IsStudio() and 25 or 95

if #TIPS < 100 then
	warn(string.format("[ChatTipBroadcaster] Expected 100 tips, found %d", #TIPS))
end

local priorityTips = {}
for i = 1, math.min(PRIORITY_COUNT, #TIPS) do
	table.insert(priorityTips, TIPS[i])
end

local rotatingTips = {}
for i = PRIORITY_COUNT + 1, #TIPS do
	table.insert(rotatingTips, TIPS[i])
end

local activeRotation = {}
local priorityIndex = 1
local rotationIndex = 1

local function shuffleRotation()
	activeRotation = table.clone(rotatingTips)
	for i = #activeRotation, 2, -1 do
		local j = math.random(1, i)
		activeRotation[i], activeRotation[j] = activeRotation[j], activeRotation[i]
	end
	rotationIndex = 1
end

if #rotatingTips > 0 then
	shuffleRotation()
end

local function nextTip()
	if priorityIndex <= #priorityTips then
		local tip = priorityTips[priorityIndex]
		priorityIndex += 1
		return tip
	end

	if #activeRotation == 0 then
		return nil
	end

	if rotationIndex > #activeRotation then
		shuffleRotation()
	end

	local tip = activeRotation[rotationIndex]
	rotationIndex += 1
	return tip
end

local function broadcastTip(tip)
	if not tip or tip == "" then
		return
	end
	TipEvent:FireAllClients(tip)
end

task.spawn(function()
	task.wait(INITIAL_DELAY)
	while true do
		local tip = nextTip()
		if tip then
			broadcastTip(tip)
		end
		task.wait(TIP_INTERVAL)
	end
end)
