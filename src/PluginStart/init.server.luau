local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Components = script.Parent.Components
local Packages = script.Parent.Packages

local PluginComponents = Components:FindFirstChild("PluginComponents")
local Widget = require(PluginComponents.Widget)
local Toolbar = require(PluginComponents.Toolbar)
local ToolbarButton = require(PluginComponents.ToolbarButton)

local StudioComponents = Components:FindFirstChild("StudioComponents")
local ScrollFrame = require(StudioComponents.ScrollFrame)
local MainButton = require(StudioComponents.MainButton)
local Button = require(StudioComponents.Button)
local Label = require(StudioComponents.Label)
local LimitedTextInput = require(StudioComponents.LimitedTextInput)
local Title = require(StudioComponents.Title)

local Fusion = require(Packages.Fusion)
local Janitor = require(Packages.Janitor)

local BevelOperations = require(script.BevelOperations)

local New = Fusion.New
local Value = Fusion.Value
local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent
local Observer = Fusion.Observer
local Computed = Fusion.Computed

local widgetsEnabled = Value(false)
local bevelRadius = Value(0.5)
local selectedParts = Value({}) -- raw BaseParts
local selectedBevels = Value({}) -- existing bevelled Models
local pluginJanitor = Janitor.new()

local BEVEL_ATTRIBUTES = { "BevelRadius", "BevelSourceSize", "BevelSourceCFrame" }

local function isBevelModel(item: Instance): boolean
	return item:IsA("Model") and item:GetAttribute("BevelRadius") ~= nil
end

local function isBevelChild(item: Instance): boolean
	local parent = item.Parent
	return parent and isBevelModel(parent)
end

local function isBevelPrimaryPart(item: Instance): boolean
	local parent = item.Parent
	return parent and isBevelModel(parent) and parent.PrimaryPart == item
end

local function updateSelection()
	local newSelection = Selection:Get()
	local parts, bevels = {}, {}
	local hasInvalidSelection = false

	for _, item in ipairs(newSelection) do
		if isBevelModel(item) then
			table.insert(bevels, item)
		elseif item:IsA("BasePart") and isBevelPrimaryPart(item) then
			-- Primary part of a bevel model — treat as selecting the model
			local parent = item.Parent
			local alreadyAdded = false
			for _, b in ipairs(bevels) do
				if b == parent then
					alreadyAdded = true
					break
				end
			end
			if not alreadyAdded then
				table.insert(bevels, parent)
			end
		elseif isBevelChild(item) then
			hasInvalidSelection = true
		elseif item:IsA("BasePart") then
			table.insert(parts, item)
		end
	end

	if hasInvalidSelection then
		selectedParts:set({})
		selectedBevels:set({})
		return
	end

	selectedParts:set(parts)
	selectedBevels:set(bevels)

	-- Pre-fill radius from the first selected bevel model
	if #bevels > 0 and #parts == 0 then
		local existingRadius = bevels[1]:GetAttribute("BevelRadius")
		if existingRadius then
			bevelRadius:set(existingRadius)
		end
	end
end

local function doBevel()
	local parts = selectedParts:get()
	local bevels = selectedBevels:get()
	local radius = bevelRadius:get()

	if #parts == 0 and #bevels == 0 then
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("Bevel", "Bevel Parts")
	if not recording then
		warn("Beveller: Could not begin ChangeHistory recording")
		return
	end

	local results = {}

	-- Bevel raw parts
	for _, part in ipairs(parts) do
		local model = BevelOperations.bevel(part, radius)
		if model then
			table.insert(results, model)
		end
	end

	-- Re-bevel existing bevel models
	for _, bevelModel in ipairs(bevels) do
		local sourceCFrame = bevelModel:GetAttribute("BevelSourceCFrame")
		if not sourceCFrame then
			continue
		end

		local sample = bevelModel:FindFirstChildWhichIsA("BasePart")
		if not sample then
			continue
		end

		-- Recompute size from the model's current bounding box
		local modelCFrame, modelSize = bevelModel:GetBoundingBox()

		local tempPart = Instance.new("Part")
		tempPart.Size = modelSize
		tempPart.CFrame = modelCFrame
		for _, prop in ipairs({
			"Color",
			"Material",
			"MaterialVariant",
			"Transparency",
			"Reflectance",
			"Anchored",
			"CanCollide",
			"CanQuery",
			"CanTouch",
			"CastShadow",
			"CollisionGroup",
		}) do
			tempPart[prop] = sample[prop]
		end
		tempPart.Parent = bevelModel.Parent

		bevelModel.Parent = nil

		local newModel = BevelOperations.bevel(tempPart, radius)
		if newModel then
			table.insert(results, newModel)
		end
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)

	if #results > 0 then
		Selection:Set(results)
	end
end

local function doBake()
	local bevels = selectedBevels:get()
	if #bevels == 0 then
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("Bake", "Bake Bevels")
	if not recording then
		warn("Beveller: Could not begin ChangeHistory recording")
		return
	end

	for _, bevelModel in ipairs(bevels) do
		for _, attr in ipairs(BEVEL_ATTRIBUTES) do
			bevelModel:SetAttribute(attr, nil)
		end
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	updateSelection()
end

local hasSelection = Computed(function()
	return #selectedParts:get() > 0 or #selectedBevels:get() > 0
end)

local statusText = Computed(function()
	local partCount = #selectedParts:get()
	local bevelCount = #selectedBevels:get()
	if partCount == 0 and bevelCount == 0 then
		return "No parts selected"
	end
	local segments = {}
	if partCount > 0 then
		table.insert(segments, partCount .. (partCount == 1 and " part" or " parts"))
	end
	if bevelCount > 0 then
		table.insert(segments, bevelCount .. (bevelCount == 1 and " bevel" or " bevels"))
	end
	return table.concat(segments, ", ") .. " selected"
end)

do
	local pluginToolbar = Toolbar({
		Name = "Beveller",
	})

	ToolbarButton({
		Toolbar = pluginToolbar,
		ClickableWhenViewportHidden = true,
		Name = "Beveller",
		ToolTip = "Open Beveller widget",
		Image = "",

		[OnEvent("Click")] = function()
			widgetsEnabled:set(not widgetsEnabled:get())
		end,
	})

	Widget({
		Id = "BevellerWidget",
		Name = "Beveller",

		InitialDockTo = Enum.InitialDockState.Right,
		InitialEnabled = false,
		ForceInitialEnabled = false,
		FloatingSize = Vector2.new(250, 300),
		MinimumSize = Vector2.new(250, 250),

		Enabled = widgetsEnabled,
		[OnChange("Enabled")] = function(isEnabled)
			widgetsEnabled:set(isEnabled)
		end,

		[Children] = ScrollFrame({
			Size = UDim2.fromScale(1, 1),

			CanvasScaleConstraint = Enum.ScrollingDirection.X,

			UILayout = New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 7),
			}),

			UIPadding = New("UIPadding")({
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 10),
				PaddingTop = UDim.new(0, 10),
			}),

			[Children] = {
				Title({
					Text = "Beveller",
					LayoutOrder = 1,
				}),

				LimitedTextInput({
					PlaceholderText = "Radius (studs)",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 2,
					GraphemeLimit = 8,
					OnChange = function(newText)
						local num = tonumber(newText)
						if num and num > 0 then
							bevelRadius:set(num)
						end
					end,
				}),

				Label({
					Text = statusText,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 3,
				}),

				MainButton({
					Text = "Bevel Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 4,
					Enabled = hasSelection,
					Activated = doBevel,
				}),

				Button({
					Text = "Bake Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 5,
					Enabled = Computed(function()
						return #selectedBevels:get() > 0
					end),
					Activated = doBake,
				}),

				Label({
					Text = "Bake removes bevel attributes placed by the plugin.",
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 6,
				}),
			},
		}),
	})

	plugin.Unloading:Connect(Observer(widgetsEnabled):onChange(function()
		if widgetsEnabled:get() then
			task.spawn(updateSelection)
			pluginJanitor:Add(Selection.SelectionChanged:Connect(updateSelection))
		else
			pluginJanitor:Cleanup()
		end
	end))
end
