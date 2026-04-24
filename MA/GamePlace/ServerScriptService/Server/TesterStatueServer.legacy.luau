--[=[ PATH: ServerScriptService/Server/TesterStatueServer.legacy.luau | TYPE: Script ]=]--
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local GROUP_ID = 398051359
local ROLE_NAME = "Tester"
local DECOR_ID = 130000000090
local ITEM_NAME = "Tester Statues"

local Events = ReplicatedStorage:FindFirstChild("Events")
if not Events then
	Events = Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
end

local Remote = Events:FindFirstChild("TesterStatuesReady")
if not Remote then
	Remote = Instance.new("RemoteEvent")
	Remote.Name = "TesterStatuesReady"
	Remote.Parent = Events
end

local generatedItems = {}

local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
if not assetsFolder then
	assetsFolder = Instance.new("Folder")
	assetsFolder.Name = "Assets"
	assetsFolder.Parent = ReplicatedStorage
end

local decorFolder = assetsFolder:FindFirstChild("Decor")
if not decorFolder then
	decorFolder = Instance.new("Folder")
	decorFolder.Name = "Decor"
	decorFolder.Parent = assetsFolder
end

-- Create the master model synchronously so it's always available for loading
local masterModel = Instance.new("Model")
masterModel.Name = ITEM_NAME
local base = Instance.new("Part")
base.Name = "Base"
base.Size = Vector3.new(10, 2.0, 4.0)
base.CFrame = CFrame.new(0, 0, 0)
base.Anchored = true
base.CanCollide = true
base.Transparency = 0
base.Color = Color3.fromRGB(60, 65, 70)
base.Material = Enum.Material.Slate
base.Parent = masterModel
masterModel.PrimaryPart = base
masterModel:SetAttribute("ID", DECOR_ID)
masterModel.Parent = decorFolder

-- Register synchronously but hidden from menu initially
local itemData = { ID = DECOR_ID, ShowInMenu = false, Loadable = true, Category = "Decor", Price = 50000000000, Type = "Static" }
Config.Items[ITEM_NAME] = itemData
Config.ValidateUniqueItemIds()

local function fetchTesters()
	local rolesUrl = "https://groups.roproxy.com/v1/groups/" .. GROUP_ID .. "/roles"
	local s1, r1 = pcall(function() return HttpService:GetAsync(rolesUrl) end)
	if not s1 then return nil end
	
	local rolesData = HttpService:JSONDecode(r1)
	local roleId = nil
	for _, role in ipairs(rolesData.roles) do
		if string.find(string.lower(role.name), string.lower(ROLE_NAME)) then
			roleId = role.id
			break
		end
	end
	if not roleId then return nil end
	
	local usersUrl = "https://groups.roproxy.com/v1/groups/" .. GROUP_ID .. "/roles/" .. roleId .. "/users?limit=100"
	local s2, r2 = pcall(function() return HttpService:GetAsync(usersUrl) end)
	if not s2 then return nil end
	
	local usersData = HttpService:JSONDecode(r2)
	return usersData.data
end

task.spawn(function()
	local users = fetchTesters()
	if not users or #users == 0 then return end
	
	-- Build into a temporary model first
	local tempModel = Instance.new("Model")
	tempModel.Name = ITEM_NAME
	
	-- Scale and positioning constants
	local SCALE = 1.0
	local SPACING = 4.5 * SCALE
	local PEDESTAL_HEIGHT = 2.0
	local PEDESTAL_TOP = PEDESTAL_HEIGHT / 2
	local BASE_DEPTH = 4.0
	
	local numUsers = #users
	local startX = -((numUsers - 1) * SPACING) / 2
	
	for i, user in ipairs(users) do
		local s3, charModel = pcall(function() 
			-- Force an R6 Rig generation
			local desc = Players:GetHumanoidDescriptionFromUserId(user.userId)
			return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)
		end)
		
		if s3 and charModel then
			charModel.Name = user.username
			
			-- Snap accessories to their exact correct positions BEFORE scaling
			for _, acc in ipairs(charModel:GetChildren()) do
				if acc:IsA("Accessory") then
					local handle = acc:FindFirstChild("Handle")
					if handle then
						local accAtt = handle:FindFirstChildOfClass("Attachment")
						if accAtt then
							local charAtt = charModel:FindFirstChild(accAtt.Name, true)
							if charAtt and charAtt:IsA("Attachment") then
								handle.CFrame = charAtt.WorldCFrame * accAtt.CFrame:Inverse()
							end
						end
					end
				end
			end
			
			-- Instantly scale the character down
			charModel:ScaleTo(SCALE)
			
			-- Dynamically measure where the bottom of the legs actually are after scaling
			local lowestLegY = charModel:GetPivot().Y
			local foundLeg = false
			for _, part in ipairs(charModel:GetChildren()) do
				if part:IsA("BasePart") and (string.find(part.Name, "Leg") or string.find(part.Name, "Foot")) then
					local bottomY = part.Position.Y - (part.Size.Y / 2)
					if bottomY < lowestLegY then
						lowestLegY = bottomY
						foundLeg = true
					end
				end
			end
			
			local rootOffset = 3.0 * SCALE -- Safe fallback
			if foundLeg then
				rootOffset = charModel:GetPivot().Y - lowestLegY
			end
			
			-- Pivot to its exact spot on the pedestal so the feet perfectly touch the top surface
			local currentX = startX + ((i - 1) * SPACING)
			charModel:PivotTo(CFrame.new(currentX, PEDESTAL_TOP + rootOffset, 0))
			
			for _, desc in ipairs(charModel:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.Anchored = true
					desc.CanCollide = false
					desc.Material = Enum.Material.Ice
					desc.Color = Color3.fromRGB(200, 240, 255)
				elseif desc:IsA("Script") or desc:IsA("LocalScript") then
					desc:Destroy()
				elseif desc:IsA("Humanoid") then
					desc.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				end
			end
			
			charModel.Parent = tempModel
			
			-- Add golden name plate
			local plate = Instance.new("Part")
			plate.Name = "NamePlate_" .. user.username
			plate.Size = Vector3.new(3, 0.8, 0.2)
			plate.Color = Color3.fromRGB(212, 175, 55) -- Gold
			plate.Material = Enum.Material.Metal
			plate.Anchored = true
			plate.CanCollide = false
			plate.CFrame = CFrame.new(currentX, PEDESTAL_TOP - 0.6, -(BASE_DEPTH / 2))
			plate.Parent = tempModel
			
			local surfaceGui = Instance.new("SurfaceGui")
			surfaceGui.Face = Enum.NormalId.Front
			surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			surfaceGui.PixelsPerStud = 50
			surfaceGui.Parent = plate
			
			local textLabel = Instance.new("TextLabel")
			textLabel.Size = UDim2.fromScale(1, 1)
			textLabel.BackgroundTransparency = 1
			textLabel.Text = user.username
			textLabel.Font = Enum.Font.GothamBold
			textLabel.TextColor3 = Color3.fromRGB(0, 0, 0)
			textLabel.TextScaled = true
			textLabel.Parent = surfaceGui
			
			local uiPadding = Instance.new("UIPadding")
			uiPadding.PaddingTop = UDim.new(0.15, 0)
			uiPadding.PaddingBottom = UDim.new(0.15, 0)
			uiPadding.Parent = textLabel
		end
		task.wait(0.2) -- Stagger requests to prevent API rate limits
	end
	
	-- Create the physical pedestal underneath the group
	local baseWidth = math.max(2, (numUsers * SPACING) + (4 * SCALE))
	local finalBase = Instance.new("Part")
	finalBase.Name = "Base"
	finalBase.Size = Vector3.new(baseWidth, PEDESTAL_HEIGHT, BASE_DEPTH)
	finalBase.CFrame = CFrame.new(0, 0, 0)
	finalBase.Anchored = true
	finalBase.CanCollide = true
	finalBase.Transparency = 0
	finalBase.Color = Color3.fromRGB(60, 65, 70) -- Slate gray
	finalBase.Material = Enum.Material.Slate
	finalBase.Parent = tempModel
	
	tempModel.PrimaryPart = finalBase
	
	-- Update the synchronous master model
	masterModel:ClearAllChildren()
	for _, child in ipairs(tempModel:GetChildren()) do
		child.Parent = masterModel
	end
	masterModel.PrimaryPart = masterModel:FindFirstChild("Base")
	tempModel:Destroy()
	
	-- Make it visible in the menu
	Config.Items[ITEM_NAME].ShowInMenu = true
	generatedItems[ITEM_NAME] = Config.Items[ITEM_NAME]
	
	-- Refresh internal catalog IDs and send to clients
	Config.ValidateUniqueItemIds()
	Remote:FireAllClients(generatedItems)
	
	-- Update any already-placed instances
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, placed in ipairs(placedObjects:GetChildren()) do
			if placed.Name == ITEM_NAME and placed:IsA("Model") then
				local pivot = placed:GetPivot()
				placed:ClearAllChildren()
				for _, child in ipairs(masterModel:GetChildren()) do
					child:Clone().Parent = placed
				end
				placed.PrimaryPart = placed:FindFirstChild("Base")
				placed:PivotTo(pivot)
			end
		end
	end
end)

local function checkTesterRole(player)
	local success, role = pcall(function() return player:GetRoleInGroup(GROUP_ID) end)
	if success and role and string.find(string.lower(role), string.lower(ROLE_NAME)) then
		player:SetAttribute("IsTester", true)
	end
end

-- Send the data to anyone who connects after generation finishes
Players.PlayerAdded:Connect(function(player)
	task.spawn(checkTesterRole, player)
	task.delay(5, function()
		if next(generatedItems) ~= nil then
			Remote:FireClient(player, generatedItems)
		end
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(checkTesterRole, player)
end
