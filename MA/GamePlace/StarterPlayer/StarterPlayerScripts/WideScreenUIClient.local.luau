--!strict
-- Prevent major HUD and modal panels from ballooning on ultrawide monitors.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")

local MAX_SUPPORTED_ASPECT = 2.05
local MAX_SIZE = Vector2.new(10000, 10000)
local TARGET_NAMES = {
	"Top",
	"Dock",
	"ResearchFrame",
	"CalendarFrame",
	"BuildFrame",
	"EmployeesFrame",
	"Rating",
	"ResortSettingsFrame",
}

local function getViewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function ensureWideConstraint(gui: GuiObject): UISizeConstraint
	local existing = gui:FindFirstChild("WideScreenSizeConstraint")
	if existing and existing:IsA("UISizeConstraint") then
		return existing
	end

	local constraint = Instance.new("UISizeConstraint")
	constraint.Name = "WideScreenSizeConstraint"
	constraint.MaxSize = MAX_SIZE
	constraint.MinSize = Vector2.zero
	constraint.Parent = gui
	return constraint
end

local function computeAxis(axis: UDim, referencePixels: number): number
	if axis.Scale ~= 0 then
		return math.max(1, math.floor(referencePixels * axis.Scale + axis.Offset + 0.5))
	end
	return math.max(1, axis.Offset)
end

local function refreshWideScreenLayout()
	local viewport = getViewportSize()
	local aspect = viewport.X / math.max(viewport.Y, 1)
	local shouldClamp = aspect > MAX_SUPPORTED_ASPECT
	local clampWidth = math.floor(viewport.Y * MAX_SUPPORTED_ASPECT + 0.5)

	for _, name in ipairs(TARGET_NAMES) do
		local gui = MainHUD:FindFirstChild(name)
		if gui and gui:IsA("GuiObject") then
			local constraint = ensureWideConstraint(gui)
			if shouldClamp then
				constraint.MaxSize = Vector2.new(
					computeAxis(gui.Size.X, clampWidth),
					computeAxis(gui.Size.Y, viewport.Y)
				)
				gui:SetAttribute("WideScreenClampAspect", MAX_SUPPORTED_ASPECT)
			else
				constraint.MaxSize = MAX_SIZE
				gui:SetAttribute("WideScreenClampAspect", nil)
			end
		end
	end
end

local function hookCamera(camera: Camera?)
	if not camera then
		return
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshWideScreenLayout)
end

MainHUD.ChildAdded:Connect(function(child)
	if table.find(TARGET_NAMES, child.Name) then
		task.defer(refreshWideScreenLayout)
	end
end)

hookCamera(Workspace.CurrentCamera)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	hookCamera(Workspace.CurrentCamera)
	task.defer(refreshWideScreenLayout)
end)

refreshWideScreenLayout()
