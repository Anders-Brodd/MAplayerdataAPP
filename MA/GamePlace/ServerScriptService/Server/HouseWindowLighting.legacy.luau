local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local UPDATE_INTERVAL = 0.75
local REGISTRY_REFRESH_INTERVAL = 3
local WINDOW_LIGHT_NAME = "HouseNightWindowPointLight"
local WARM_WINDOW_COLOR = Color3.fromRGB(255, 214, 142)
local MIN_ACTIVE_BLEND = 0.04

local registeredHouses = {}
local registryDirty = true
local registryRefreshElapsed = 0

local function lerpNumber(a, b, t)
	return a + ((b - a) * t)
end

local function lerpColor(a, b, t)
	return Color3.new(
		lerpNumber(a.R, b.R, t),
		lerpNumber(a.G, b.G, t),
		lerpNumber(a.B, b.B, t)
	)
end

local function clamp01(value)
	return math.clamp(value, 0, 1)
end

local function getGlowBlend(clockTime)
	if clockTime >= 21.0 or clockTime <= 4.75 then
		return 1
	end
	if clockTime >= 18.5 and clockTime < 21.0 then
		return clamp01((clockTime - 18.5) / 2.5)
	end
	if clockTime > 4.75 and clockTime <= 6.75 then
		return clamp01(1 - ((clockTime - 4.75) / 2.0))
	end
	return 0
end

local function resolveConfigForModel(model)
	if not model then
		return nil, nil
	end

	local direct = Config.Items[model.Name]
	if direct then
		return model.Name, direct
	end

	local resolvedName, resolvedConfig = Config.GetItemById(model:GetAttribute("ID"))
	if resolvedConfig then
		return resolvedName, resolvedConfig
	end

	return nil, nil
end

local function isWindowPane(inst)
	if not (inst and inst:IsA("BasePart") and inst.Parent) then
		return false
	end
	local cur = inst.Parent
	while cur do
		if cur:IsA("Model") and (cur.Name == "Windows" or cur.Name == "Window") then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function resolveHouseForWindowPane(inst)
	if not (inst and inst:IsA("BasePart")) then
		return nil
	end
	local cur = inst.Parent
	while cur do
		if cur:IsA("Model") and cur.Name == "Windows" then
			return cur.Parent
		end
		if cur:IsA("Model") and cur.Name == "Window" then
			return cur.Parent
		end
		cur = cur.Parent
	end
	return nil
end

local function collectNightWindowPanes(model)
	local seen = {}
	local out = {}

	local function pushContainer(container)
		if not container then
			return
		end
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("BasePart") and not seen[desc] then
				seen[desc] = true
				table.insert(out, desc)
			end
		end
	end

	local windowsModel = model:FindFirstChild("Windows")
	if windowsModel and windowsModel:IsA("Model") then
		pushContainer(windowsModel)
	end

	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") and child.Name == "Window" then
			pushContainer(child)
		end
	end

	return out
end

local function ensurePaneLight(pane)
	local light = pane:FindFirstChild(WINDOW_LIGHT_NAME)
	if light and not light:IsA("PointLight") then
		light:Destroy()
		light = nil
	end
	if not light then
		light = Instance.new("PointLight")
		light.Name = WINDOW_LIGHT_NAME
		light.Color = WARM_WINDOW_COLOR
		light.Shadows = false
		light.Enabled = false
		light.Parent = pane
	end

	local dominantSize = math.max(pane.Size.X, pane.Size.Y, pane.Size.Z)
	light.Brightness = math.clamp((dominantSize / 9), 0.65, 1.55)
	light.Range = math.clamp(dominantSize * 1.2, 8, 18)
	return light
end

local function buildWindowEntry(pane)
	local light = ensurePaneLight(pane)
	-- Persist original state so re-registration during night doesn't capture warm colors
	if not pane:GetAttribute("_WinBaseColor") then
		pane:SetAttribute("_WinBaseColor", pane.Color)
		pane:SetAttribute("_WinBaseMaterial", pane.Material.Name)
		pane:SetAttribute("_WinBaseTransparency", pane.Transparency)
	end
	local storedColor = pane:GetAttribute("_WinBaseColor")
	local storedMatName = pane:GetAttribute("_WinBaseMaterial")
	local storedTransparency = pane:GetAttribute("_WinBaseTransparency")
	local safeMat = (type(storedMatName) == "string" and Enum.Material[storedMatName]) or pane.Material
	return {
		Pane = pane,
		Light = light,
		BaseColor = typeof(storedColor) == "Color3" and storedColor or pane.Color,
		BaseMaterial = safeMat,
		BaseTransparency = type(storedTransparency) == "number" and storedTransparency or pane.Transparency,
	}
end

local function registerHouseModel(model)
	if not model or not model.Parent or registeredHouses[model] then
		return
	end

	local itemName, itemConfig = resolveConfigForModel(model)
	if not itemConfig or not Config.ShouldUseNightWindows(itemName, itemConfig) then
		return
	end

	local paneParts = collectNightWindowPanes(model)
	if #paneParts == 0 then
		return
	end

	local panes = {}
	for _, desc in ipairs(paneParts) do
		table.insert(panes, buildWindowEntry(desc))
	end

	registeredHouses[model] = {
		Model = model,
		Panes = panes,
		NightWindowMaterial = Config.GetNightWindowMaterial(itemName, itemConfig),
	}
	registryDirty = true
end

local function refreshRegistry()
	for model, entry in pairs(registeredHouses) do
		if not model or not model.Parent then
			registeredHouses[model] = nil
		else
			local validPanes = {}
			for _, paneEntry in ipairs(entry.Panes) do
				if paneEntry.Pane and paneEntry.Pane.Parent then
					if not paneEntry.Light or not paneEntry.Light.Parent then
						paneEntry.Light = ensurePaneLight(paneEntry.Pane)
					end
					table.insert(validPanes, paneEntry)
				end
			end
			entry.Panes = validPanes
			if #validPanes == 0 then
				registeredHouses[model] = nil
			end
		end
	end
end

local function applyWindowGlow(entry, glowBlend)
	local enableLights = glowBlend > MIN_ACTIVE_BLEND
	for _, paneEntry in ipairs(entry.Panes) do
		local pane = paneEntry.Pane
		if pane and pane.Parent then
			pane.Color = lerpColor(paneEntry.BaseColor, WARM_WINDOW_COLOR, glowBlend * 0.85)
			local forcedNightMaterial = entry.NightWindowMaterial and Enum.Material[entry.NightWindowMaterial] or nil
			if forcedNightMaterial then
				pane.Material = (glowBlend > 0.1) and forcedNightMaterial or paneEntry.BaseMaterial
			elseif paneEntry.BaseMaterial == Enum.Material.Glass then
				pane.Material = Enum.Material.Glass
			else
				pane.Material = (glowBlend > 0.1) and Enum.Material.Neon or paneEntry.BaseMaterial
			end
			pane.Transparency = lerpNumber(paneEntry.BaseTransparency, math.max(0, paneEntry.BaseTransparency - 0.08), glowBlend)
		end
		local light = paneEntry.Light
		if light and light.Parent then
			light.Color = WARM_WINDOW_COLOR
			light.Enabled = enableLights
		end
	end
end

for _, inst in ipairs(Workspace:GetDescendants()) do
	if inst:IsA("Model") then
		registerHouseModel(inst)
	end
end

Workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Model") then
		task.defer(registerHouseModel, inst)
	elseif isWindowPane(inst) then
		local houseModel = resolveHouseForWindowPane(inst)
		if houseModel and registeredHouses[houseModel] then
			table.insert(registeredHouses[houseModel].Panes, buildWindowEntry(inst))
			registryDirty = true
		end
	end
end)

Workspace.DescendantRemoving:Connect(function(inst)
	if inst:IsA("Model") then
		if registeredHouses[inst] then
			registeredHouses[inst] = nil
			registryDirty = true
		end
		return
	end

	if not isWindowPane(inst) then
		return
	end

	local houseModel = resolveHouseForWindowPane(inst)
	local entry = houseModel and registeredHouses[houseModel]
	if not entry then
		return
	end

	for i = #entry.Panes, 1, -1 do
		if entry.Panes[i].Pane == inst then
			table.remove(entry.Panes, i)
		end
	end
	if #entry.Panes == 0 then
		registeredHouses[houseModel] = nil
	end
	registryDirty = true
end)

local elapsed = 0
local lastGlowBlend = -1

RunService.Heartbeat:Connect(function(dt)
	elapsed += dt
	registryRefreshElapsed += dt
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0

	local shouldRefreshRegistry = registryDirty or (registryRefreshElapsed >= REGISTRY_REFRESH_INTERVAL)
	if shouldRefreshRegistry then
		refreshRegistry()
		registryRefreshElapsed = 0
	end

	local glowBlend = getGlowBlend(Lighting.ClockTime)
	if math.abs(glowBlend - lastGlowBlend) < 0.01 and not registryDirty then
		return
	end
	lastGlowBlend = glowBlend

	for _, entry in pairs(registeredHouses) do
		applyWindowGlow(entry, glowBlend)
	end
	registryDirty = false
end)
