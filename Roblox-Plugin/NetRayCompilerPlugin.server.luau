--!strict
-- Name: NetRayCompilerPlugin
-- Purpose: Studio plugin UI for local NetRay IDL compilation

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")

local pluginObject = plugin
if pluginObject == nil then
	error("NetRayCompilerPlugin must run with Plugin run context")
end

local Compiler = require(script:WaitForChild("Compiler"):WaitForChild("Compiler"))

local TOOLBAR_ID = "NetRay"
local BUTTON_ID = "NetRayCompiler"
local BUTTON_TOOLTIP = "Open NetRay local IDL compiler"
local BUTTON_ICON = "rbxassetid://15765304310"

local WIDGET_ID = "NetRayCompilerWidget"
local WIDGET_TITLE = "NetRay Compiler"

local SETTING_SCHEMA_TEXT = "NetRayCompiler.SchemaText"
local SETTING_SCOPE_NAME = "NetRayCompiler.ScopeName"

local STATUS_INFO = Color3.fromRGB(116, 206, 145)
local STATUS_ERROR = Color3.fromRGB(235, 124, 124)

local SCHEMA_TOP_OFFSET = 124
local SCHEMA_BOTTOM_GAP = 8

local DEFAULT_SCHEMA = [[
struct PingData {
	id: u16,
	latency: u16,
}

event Ping {
	From: Client,
	Type: Reliable,
	Call: ManySync,
	Data: PingData,
}
]]

local function trim(value: string): string
	return (string.gsub(string.gsub(value, "^%s+", ""), "%s+$", ""))
end

local function getSettingString(key: string, fallback: string): string
	local ok, value = pcall(function()
		return pluginObject:GetSetting(key)
	end)
	if ok and type(value) == "string" then
		return value
	end
	return fallback
end

local function setSettingString(key: string, value: string)
	pcall(function()
		pluginObject:SetSetting(key, value)
	end)
end

local toolbar = pluginObject:CreateToolbar(TOOLBAR_ID)
local toggleButton = toolbar:CreateButton(BUTTON_ID, BUTTON_TOOLTIP, BUTTON_ICON)

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, false, false, 540, 620, 360, 400)
local widget = pluginObject:CreateDockWidgetPluginGuiAsync(WIDGET_ID, widgetInfo)
widget.Title = WIDGET_TITLE

local root = Instance.new("Frame")
root.Name = "Root"
root.BackgroundColor3 = Color3.fromRGB(23, 26, 30)
root.BorderSizePixel = 0
root.ClipsDescendants = true
root.Size = UDim2.fromScale(1, 1)
root.Parent = widget

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = root

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.BackgroundTransparency = 1
titleLabel.Size = UDim2.new(1, 0, 0, 24)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Text = "NetRay IDL Compiler"
titleLabel.TextSize = 17
titleLabel.TextColor3 = Color3.fromRGB(236, 241, 248)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = root

local scopeLabel = Instance.new("TextLabel")
scopeLabel.Name = "ScopeLabel"
scopeLabel.BackgroundTransparency = 1
scopeLabel.Position = UDim2.new(0, 0, 0, 30)
scopeLabel.Size = UDim2.new(1, 0, 0, 18)
scopeLabel.Font = Enum.Font.Gotham
scopeLabel.Text = "Remote Scope Name"
scopeLabel.TextSize = 13
scopeLabel.TextColor3 = Color3.fromRGB(191, 201, 212)
scopeLabel.TextXAlignment = Enum.TextXAlignment.Left
scopeLabel.Parent = root

local scopeBox = Instance.new("TextBox")
scopeBox.Name = "ScopeBox"
scopeBox.BackgroundColor3 = Color3.fromRGB(31, 37, 43)
scopeBox.BorderSizePixel = 0
scopeBox.ClearTextOnFocus = false
scopeBox.Font = Enum.Font.Code
scopeBox.PlaceholderColor3 = Color3.fromRGB(128, 136, 147)
scopeBox.PlaceholderText = "NetRay"
scopeBox.Position = UDim2.new(0, 0, 0, 50)
scopeBox.Size = UDim2.new(1, 0, 0, 28)
scopeBox.Text = ""
scopeBox.TextColor3 = Color3.fromRGB(234, 242, 252)
scopeBox.TextSize = 14
scopeBox.TextXAlignment = Enum.TextXAlignment.Left
scopeBox.Parent = root

local scopeCorner = Instance.new("UICorner")
scopeCorner.CornerRadius = UDim.new(0, 6)
scopeCorner.Parent = scopeBox

local helpLabel = Instance.new("TextLabel")
helpLabel.Name = "Help"
helpLabel.BackgroundTransparency = 1
helpLabel.Position = UDim2.new(0, 0, 0, 82)
helpLabel.Size = UDim2.new(1, 0, 0, 16)
helpLabel.Font = Enum.Font.Gotham
helpLabel.Text = "Compiles locally and writes ModuleScripts to ReplicatedStorage/NetRay."
helpLabel.TextSize = 12
helpLabel.TextColor3 = Color3.fromRGB(147, 159, 171)
helpLabel.TextXAlignment = Enum.TextXAlignment.Left
helpLabel.Parent = root

local schemaLabel = Instance.new("TextLabel")
schemaLabel.Name = "SchemaLabel"
schemaLabel.BackgroundTransparency = 1
schemaLabel.Position = UDim2.new(0, 0, 0, 102)
schemaLabel.Size = UDim2.new(1, 0, 0, 18)
schemaLabel.Font = Enum.Font.Gotham
schemaLabel.Text = "IDL Schema"
schemaLabel.TextSize = 13
schemaLabel.TextColor3 = Color3.fromRGB(191, 201, 212)
schemaLabel.TextXAlignment = Enum.TextXAlignment.Left
schemaLabel.Parent = root

local schemaBox = Instance.new("TextBox")
schemaBox.Name = "SchemaBox"
schemaBox.BackgroundColor3 = Color3.fromRGB(18, 22, 26)
schemaBox.BorderSizePixel = 0
schemaBox.ClearTextOnFocus = false
schemaBox.Font = Enum.Font.Code
schemaBox.MultiLine = true
schemaBox.Position = UDim2.new(0, 0, 0, SCHEMA_TOP_OFFSET)
schemaBox.Size = UDim2.new(1, 0, 0, 180)
schemaBox.Text = ""
schemaBox.TextColor3 = Color3.fromRGB(225, 237, 251)
schemaBox.TextSize = 14
schemaBox.TextWrapped = false
schemaBox.TextXAlignment = Enum.TextXAlignment.Left
schemaBox.TextYAlignment = Enum.TextYAlignment.Top
schemaBox.ClipsDescendants = true
schemaBox.Parent = root

local schemaCorner = Instance.new("UICorner")
schemaCorner.CornerRadius = UDim.new(0, 6)
schemaCorner.Parent = schemaBox

local buttons = Instance.new("Frame")
buttons.Name = "Buttons"
buttons.BackgroundTransparency = 1
buttons.Position = UDim2.new(0, 0, 1, -82)
buttons.Size = UDim2.new(1, 0, 0, 32)
buttons.Parent = root

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = buttons

local function createButton(name: string, text: string, color: Color3, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Size = size
	button.ZIndex = 2
	button.Text = text
	button.TextColor3 = Color3.fromRGB(247, 250, 255)
	button.TextSize = 13

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button
	return button
end

local compileButton =
	createButton("Compile", "Compile to ReplicatedStorage", Color3.fromRGB(52, 122, 88), UDim2.new(0.5, -6, 1, 0))
compileButton.Parent = buttons

local loadSelectionButton =
	createButton("LoadSelection", "Load Selection", Color3.fromRGB(57, 92, 148), UDim2.new(0.25, -6, 1, 0))
loadSelectionButton.Parent = buttons

local clearButton = createButton("Clear", "Clear", Color3.fromRGB(69, 74, 84), UDim2.new(0.25, -6, 1, 0))
clearButton.Parent = buttons

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 0, 1, -40)
statusLabel.Size = UDim2.new(1, 0, 0, 20)
statusLabel.Font = Enum.Font.Gotham
statusLabel.ZIndex = 2
statusLabel.Text = ""
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = root

local function updateSchemaEditorLayout()
	local rootTop = root.AbsolutePosition.Y
	local buttonsTop = buttons.AbsolutePosition.Y - rootTop
	local schemaHeight = math.max(0, buttonsTop - SCHEMA_BOTTOM_GAP - SCHEMA_TOP_OFFSET)
	schemaBox.Size = UDim2.new(1, 0, 0, schemaHeight)
end

local function setStatus(message: string, isError: boolean)
	statusLabel.Text = message
	statusLabel.TextColor3 = if isError then STATUS_ERROR else STATUS_INFO
end

local function ensureOutputFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("NetRay")
	if existing ~= nil and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end

	if existing == nil then
		local folder = Instance.new("Folder")
		folder.Name = "NetRay"
		folder.Parent = ReplicatedStorage
		return folder
	end

	return existing :: Folder
end

local function upsertModule(parent: Instance, moduleName: string, sourceText: string)
	local existing = parent:FindFirstChild(moduleName)
	if existing ~= nil and not existing:IsA("ModuleScript") then
		existing:Destroy()
		existing = nil
	end

	if existing == nil then
		local module = Instance.new("ModuleScript")
		module.Name = moduleName
		module.Parent = parent
		existing = module
	end

	(existing :: ModuleScript).Source = sourceText
end

local function persistEditorState()
	setSettingString(SETTING_SCHEMA_TEXT, schemaBox.Text)
	setSettingString(SETTING_SCOPE_NAME, scopeBox.Text)
end

local function setActionButtonsEnabled(enabled: boolean)
	compileButton.Active = enabled
	loadSelectionButton.Active = enabled
	clearButton.Active = enabled
	compileButton.AutoButtonColor = enabled
	loadSelectionButton.AutoButtonColor = enabled
	clearButton.AutoButtonColor = enabled
end

local function compileToReplicatedStorage()
	local schemaText = schemaBox.Text
	if trim(schemaText) == "" then
		setStatus("Schema is empty. Paste IDL text or load from a selected script.", true)
		return
	end

	local scopeName = trim(scopeBox.Text)
	if scopeName == "" then
		scopeName = "NetRay"
		scopeBox.Text = scopeName
	end

	setActionButtonsEnabled(false)
	setStatus("Compiling schema...", false)

	local ok, compiledOrError = pcall(function()
		return Compiler.compile(schemaText, scopeName)
	end)

	if not ok then
		setStatus("Compile failed: " .. tostring(compiledOrError), true)
		setActionButtonsEnabled(true)
		return
	end

	local compiled = compiledOrError :: {
		server: string,
		client: string,
		types: string,
	}

	local wrote, writeError = pcall(function()
		local outputFolder = ensureOutputFolder()
		upsertModule(outputFolder, "Server", compiled.server)
		upsertModule(outputFolder, "Client", compiled.client)
		upsertModule(outputFolder, "Types", compiled.types)
	end)
	if not wrote then
		setStatus("Compiled, but write failed: " .. tostring(writeError), true)
		setActionButtonsEnabled(true)
		return
	end

	persistEditorState()
	setStatus("Success. Wrote Server, Client, Types to ReplicatedStorage/NetRay.", false)
	setActionButtonsEnabled(true)
end

local function loadSourceFromSelection()
	local selected = Selection:Get()
	if #selected ~= 1 then
		setStatus("Select exactly one Script or ModuleScript to load IDL source.", true)
		return
	end

	local item = selected[1]
	if not item:IsA("LuaSourceContainer") then
		setStatus("Selection must be a Script, LocalScript, or ModuleScript.", true)
		return
	end

	local sourceContainer = item :: LuaSourceContainer
	local ok, sourceOrError = pcall(function()
		return sourceContainer.Source
	end)

	if not ok then
		setStatus("Could not read selected source. Paste IDL manually.", true)
		return
	end

	schemaBox.Text = sourceOrError :: string
	persistEditorState()
	setStatus(("Loaded source from %s."):format(item:GetFullName()), false)
end

scopeBox.Text = getSettingString(SETTING_SCOPE_NAME, "NetRay")
schemaBox.Text = getSettingString(SETTING_SCHEMA_TEXT, DEFAULT_SCHEMA)
if trim(scopeBox.Text) == "" then
	scopeBox.Text = "NetRay"
end

compileButton.MouseButton1Click:Connect(compileToReplicatedStorage)
loadSelectionButton.MouseButton1Click:Connect(loadSourceFromSelection)
clearButton.MouseButton1Click:Connect(function()
	schemaBox.Text = ""
	persistEditorState()
	setStatus("Cleared schema editor.", false)
end)

scopeBox.FocusLost:Connect(function()
	scopeBox.Text = trim(scopeBox.Text)
	if scopeBox.Text == "" then
		scopeBox.Text = "NetRay"
	end
	persistEditorState()
end)

schemaBox.FocusLost:Connect(function()
	persistEditorState()
end)

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

pluginObject.Unloading:Connect(function()
	persistEditorState()
end)

root:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateSchemaEditorLayout)
buttons:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateSchemaEditorLayout)
updateSchemaEditorLayout()

setStatus("Ready. Compile writes to ReplicatedStorage/NetRay.", false)
toggleButton:SetActive(widget.Enabled)
