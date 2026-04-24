local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local placedObjects = Workspace:WaitForChild("PlacedObjects")

local NIGHT_START = 18.25
local NIGHT_END = 5.75
local REFRESH_INTERVAL = 2
local LIGHT_NAME = "NightWindowLight"
local WARM_COLOR = Color3.fromRGB(255, 224, 170)
local cache = {}

local function isNight()
	local clockTime = Lighting.ClockTime
	return clockTime >= NIGHT_START or clockTime <= NIGHT_END
end

local function shouldEmitLights()
	return Workspace:GetAttribute("ResortAllLights") ~= false and isNight()
end

local function resolveItemConfig(model)
	local itemConfig = Config.Items[model.Name]
	if itemConfig then
		return model.Name, itemConfig
	end

	local id = model:GetAttribute("ID")
	if id ~= nil and Config.GetItemById then
		local foundName, foundConfig = Config.GetItemById(id)
		if foundName and foundConfig then
			return foundName, foundConfig
		end
	end

	return model.Name, nil
end

local function isLiftModel(model, itemConfig)
	if not model then
		return false
	end
	if type(itemConfig) == "table" then
		if tostring(itemConfig.Category or "") == "Lifts" then
			return true
		end
		local typeName = tostring(itemConfig.Type or "")
		if typeName == "TwoPoint" or typeName == "Carpet" then
			return true
		end
	end
	if model:FindFirstChild("StartStation") and model:FindFirstChild("EndStation") then
		return true
	end
	return false
end

local function shouldTrackModel(model)
	if not model:IsA("Model") then
		return false
	end
	if model.Parent ~= placedObjects then
		return false
	end

	local itemName, itemConfig = resolveItemConfig(model)
	if itemConfig and itemConfig.NightWindows == true then
		return false
	end
	if isLiftModel(model, itemConfig) then
		return false
	end
	if itemConfig and itemConfig.NightWindows == false then
		return false
	end

	if itemConfig and Config.ShouldUseNightWindows and Config.ShouldUseNightWindows(itemName, itemConfig) then
		return true
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Glass and descendant.Transparency < 0.95 then
			return true
		end
	end

	return false
end

local function getNightMaterial(itemName, itemConfig)
	if Config.GetNightWindowMaterial then
		local materialName = Config.GetNightWindowMaterial(itemName, itemConfig)
		if type(materialName) == "string" and materialName ~= "" then
			local enumMaterial = Enum.Material[materialName]
			if enumMaterial then
				return enumMaterial
			end
		end
	end
	return nil
end

local function captureGlassParts(model)
	local itemName, itemConfig = resolveItemConfig(model)
	local nightMaterial = getNightMaterial(itemName, itemConfig)
	local panes = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Glass and descendant.Transparency < 0.95 then
			if descendant:FindFirstChild("HouseNightWindowPointLight") then
				continue
			end
			local light = descendant:FindFirstChild(LIGHT_NAME)
			if not light then
				light = Instance.new("PointLight")
				light.Name = LIGHT_NAME
				light.Enabled = false
				light.Shadows = false
				light.Color = WARM_COLOR
				light.Parent = descendant
			end

			light.Range = math.clamp(math.max(descendant.Size.X, descendant.Size.Y, descendant.Size.Z) * 3, 8, 18)
			light.Brightness = 1.2

			-- Persist base state as attributes to survive re-tracking during night
			if not descendant:GetAttribute("_GlassBaseColor") then
				descendant:SetAttribute("_GlassBaseColor", descendant.Color)
				descendant:SetAttribute("_GlassBaseMaterial", descendant.Material.Name)
				descendant:SetAttribute("_GlassBaseTransparency", descendant.Transparency)
			end
			local storedColor = descendant:GetAttribute("_GlassBaseColor")
			local storedMatName = descendant:GetAttribute("_GlassBaseMaterial")
			local storedTransparency = descendant:GetAttribute("_GlassBaseTransparency")
			local safeMat = (type(storedMatName) == "string" and Enum.Material[storedMatName]) or descendant.Material
			table.insert(panes, {
				part = descendant,
				light = light,
				baseColor = typeof(storedColor) == "Color3" and storedColor or descendant.Color,
				baseMaterial = safeMat,
				baseTransparency = type(storedTransparency) == "number" and storedTransparency or descendant.Transparency,
				nightMaterial = nightMaterial,
			})
		end
	end

	if #panes == 0 then
		return nil
	end

	return {
		model = model,
		itemName = itemName,
		itemConfig = itemConfig,
		panes = panes,
	}
end

local function restorePane(pane)
	if pane.part and pane.part.Parent then
		pane.part.Color = pane.baseColor
		pane.part.Material = pane.baseMaterial
		pane.part.Transparency = pane.baseTransparency
	end
	if pane.light and pane.light.Parent then
		pane.light.Enabled = false
	end
end

local function applyPaneState(pane, enabled)
	if not pane.part or not pane.part.Parent then
		return
	end

	if enabled then
		pane.part.Color = WARM_COLOR
		pane.part.Transparency = math.min(pane.baseTransparency, 0.15)
		pane.part.Material = pane.nightMaterial or pane.baseMaterial
		if pane.light and pane.light.Parent then
			pane.light.Enabled = true
			pane.light.Color = WARM_COLOR
		end
	else
		restorePane(pane)
	end
end

local function untrackModel(model)
	local entry = cache[model]
	if not entry then
		return
	end
	for _, pane in ipairs(entry.panes) do
		restorePane(pane)
	end
	cache[model] = nil
end

local function trackModel(model)
	untrackModel(model)
	if not shouldTrackModel(model) then
		return
	end
	local entry = captureGlassParts(model)
	if entry then
		cache[model] = entry
	end
end

local function applyAll()
	local enabled = shouldEmitLights()
	for model, entry in pairs(cache) do
		if not model.Parent then
			cache[model] = nil
		else
			for _, pane in ipairs(entry.panes) do
				applyPaneState(pane, enabled)
			end
		end
	end
end

for _, child in ipairs(placedObjects:GetChildren()) do
	trackModel(child)
end
applyAll()

placedObjects.ChildAdded:Connect(function(child)
	task.defer(function()
		trackModel(child)
		applyAll()
	end)
end)

placedObjects.ChildRemoved:Connect(function(child)
	untrackModel(child)
end)

Lighting:GetPropertyChangedSignal("ClockTime"):Connect(applyAll)
Workspace:GetAttributeChangedSignal("ResortAllLights"):Connect(applyAll)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		applyAll()
	end
end)
