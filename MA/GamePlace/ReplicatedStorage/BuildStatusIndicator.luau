local module = {}

function module.show(playerGui, text)
	module.hide(playerGui)
	local sg = Instance.new("ScreenGui")
	sg.Name = "BuildDeleteStatusLabel"
	sg.DisplayOrder = 100
	sg.IgnoreGuiInset = true
	local lbl = Instance.new("TextLabel")
	lbl.Name = "StatusLabel"
	lbl.Size = UDim2.new(0, 260, 0, 44)
	lbl.Position = UDim2.new(0.5, -130, 0, 40)
	lbl.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	lbl.BackgroundTransparency = 0.25
	lbl.TextColor3 = Color3.fromRGB(255, 200, 60)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 18
	lbl.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = lbl
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 200, 60)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.4
	stroke.Parent = lbl
	lbl.Parent = sg
	sg.Parent = playerGui
end

function module.hide(playerGui)
	local existing = playerGui:FindFirstChild("BuildDeleteStatusLabel")
	if existing then existing:Destroy() end
end

return module