local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
Events.Name = "Events"
Events.Parent = ReplicatedStorage

-- // HELPER: Force Create Instances (and fix wrong types) //
local function ensure(name, className)
	local existing = Events:FindFirstChild(name)

	if existing and existing.ClassName ~= className then
		existing:Destroy()
		existing = nil
	end

	if not existing then
		local obj = Instance.new(className)
		obj.Name = name
		obj.Parent = Events
	end
end

-- // 1. CRITICAL UI DEPENDENCIES //
ensure("PlaceItem", "RemoteEvent")
ensure("DeleteRequest", "RemoteEvent")
ensure("MoneyUpdate", "RemoteEvent")
ensure("RatingUpdate", "RemoteEvent")
ensure("SetTicketPrice", "RemoteEvent")
ensure("NotificationEvent", "RemoteEvent")

ensure("HireEmployee", "RemoteFunction")
ensure("UpgradeEmployee", "RemoteFunction")
ensure("StartResearch", "RemoteFunction")
ensure("GetDecorMilestoneState", "RemoteFunction")

ensure("ResearchUpdate", "RemoteEvent")
ensure("DecorMilestoneUpdate", "RemoteEvent")
ensure("AdvanceTutorial", "RemoteEvent")

-- ✅ GuestManager owns GuestCount updates, so this MUST be a RemoteEvent
ensure("GuestCount", "RemoteEvent")

-- Removal remote (your RemovalServer expects this)
ensure("RequestRemoveItem", "RemoteFunction")

-- Placement remote (your PlacementServer expects this)
ensure("RequestPlaceItem", "RemoteFunction")

-- Ad boost remotes (AdBoostServer expects these)
ensure("RequestAdBoost", "RemoteEvent")
ensure("AdBoostResult", "RemoteEvent")

-- // 2. ENSURE BUILD FOLDER //
if not workspace:FindFirstChild("PlacedObjects") then
	local f = Instance.new("Folder")
	f.Name = "PlacedObjects"
	f.Parent = workspace
end

-- Tutorial progression is owned by TutorialSaveServer.
-- Keep this loader limited to shared remote/bootstrap setup only.
