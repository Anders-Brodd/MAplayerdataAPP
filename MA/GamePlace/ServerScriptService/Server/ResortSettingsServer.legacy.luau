local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SlotData = ReplicatedStorage:WaitForChild("SlotData")

local LIGHT_BASE_ATTR = "ResortBaseEnabled"
local trackedLights = setmetatable({}, { __mode = "k" })

local function shouldManageLight(instance)
	return instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight")
end

local function captureBaseLightState(light)
	if light:GetAttribute(LIGHT_BASE_ATTR) == nil then
		light:SetAttribute(LIGHT_BASE_ATTR, light.Enabled)
	end
end

local function applyLightState(light, allLightsEnabled)
	if not shouldManageLight(light) then
		return
	end
	captureBaseLightState(light)
	if allLightsEnabled == false then
		light.Enabled = false
	else
		light.Enabled = light:GetAttribute(LIGHT_BASE_ATTR) ~= false
	end
end

local function trackLight(instance)
	if not shouldManageLight(instance) then
		return
	end
	captureBaseLightState(instance)
	trackedLights[instance] = true
end

local function untrackLight(instance)
	trackedLights[instance] = nil
end

for _, instance in ipairs(Workspace:GetDescendants()) do
	trackLight(instance)
end

local function applyAllLightsState()
	local allLightsEnabled = SlotData:GetAttribute("ResortAllLights") ~= false
	Workspace:SetAttribute("ResortAllLights", allLightsEnabled)
	Workspace:SetAttribute("ResortOpen", SlotData:GetAttribute("ResortOpen") ~= false)
	for light in pairs(trackedLights) do
		if light and light.Parent then
			applyLightState(light, allLightsEnabled)
		end
	end
end

Workspace.DescendantAdded:Connect(function(instance)
	if shouldManageLight(instance) then
		trackLight(instance)
		task.defer(function()
			if instance and instance.Parent then
				applyLightState(instance, SlotData:GetAttribute("ResortAllLights") ~= false)
			end
		end)
	end
end)

Workspace.DescendantRemoving:Connect(untrackLight)

SlotData:GetAttributeChangedSignal("ResortAllLights"):Connect(applyAllLightsState)
SlotData:GetAttributeChangedSignal("ResortOpen"):Connect(function()
	Workspace:SetAttribute("ResortOpen", SlotData:GetAttribute("ResortOpen") ~= false)
end)

applyAllLightsState()