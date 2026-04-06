local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Components = script.Parent.Components
local Packages = script.Parent.Packages

local PluginComponents = Components:FindFirstChild("PluginComponents")
local Widget = require(PluginComponents.Widget)
local Toolbar = require(PluginComponents.Toolbar)
local ToolbarButton = require(PluginComponents.ToolbarButton)
local UpdateBanner = require(PluginComponents.UpdateBanner)

local StudioComponents = Components:FindFirstChild("StudioComponents")
local ScrollFrame = require(StudioComponents.ScrollFrame)
local MainButton = require(StudioComponents.MainButton)
local Button = require(StudioComponents.Button)
local Checkbox = require(StudioComponents.Checkbox)
local Dropdown = require(StudioComponents.Dropdown)
local Label = require(StudioComponents.Label)
local LimitedTextInput = require(StudioComponents.LimitedTextInput)
local Title = require(StudioComponents.Title)

local Fusion = require(Packages.Fusion)
local Janitor = require(Packages.Janitor)

local RoundifyOperations = require(script.RoundifyOperations)

local New = Fusion.New
local Value = Fusion.Value
local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent
local Observer = Fusion.Observer
local Computed = Fusion.Computed

local widgetsEnabled = Value(false)
local roundifyRadius = Value(0.5)
local roundingMode = Value("3D")
local unionOnBake = Value(false)
local selectedParts = Value({}) -- raw BaseParts
local selectedRoundified = Value({}) -- existing rounded Models
local pluginJanitor = Janitor.new()

local ROUNDIFY_ATTRIBUTES = { "RoundifyRadius", "RoundifyMode", "RoundifySourceSize", "RoundifySourceCFrame" }

local function isRoundifyModel(item: Instance): boolean
	return item:IsA("Model") and item:GetAttribute("RoundifyRadius") ~= nil
end

local function isRoundifyChild(item: Instance): boolean
	local parent = item.Parent
	return parent and isRoundifyModel(parent)
end

local function isRoundifyPrimaryPart(item: Instance): boolean
	local parent = item.Parent
	return parent and isRoundifyModel(parent) and parent.PrimaryPart == item
end

local function updateSelection()
	local newSelection = Selection:Get()
	local parts, roundified = {}, {}
	local hasInvalidSelection = false

	for _, item in ipairs(newSelection) do
		if isRoundifyModel(item) then
			table.insert(roundified, item)
		elseif item:IsA("BasePart") and isRoundifyPrimaryPart(item) then
			-- Primary part of a roundify model — treat as selecting the model
			local parent = item.Parent
			local alreadyAdded = false
			for _, b in ipairs(roundified) do
				if b == parent then
					alreadyAdded = true
					break
				end
			end
			if not alreadyAdded then
				table.insert(roundified, parent)
			end
		elseif isRoundifyChild(item) then
			hasInvalidSelection = true
		elseif item:IsA("BasePart") then
			table.insert(parts, item)
		end
	end

	if hasInvalidSelection then
		selectedParts:set({})
		selectedRoundified:set({})
		return
	end

	selectedParts:set(parts)
	selectedRoundified:set(roundified)

	-- Pre-fill radius and mode from the first selected roundify model
	if #roundified > 0 and #parts == 0 then
		local existingRadius = roundified[1]:GetAttribute("RoundifyRadius")
		if existingRadius then
			roundifyRadius:set(existingRadius)
		end
		local existingMode = roundified[1]:GetAttribute("RoundifyMode")
		local Constants = require(script.Constants)
		roundingMode:set(Constants.AxisToMode[existingMode or "3D"] or "3D")
	end
end

local function doRoundify()
	local parts = selectedParts:get()
	local roundified = selectedRoundified:get()
	local radius = roundifyRadius:get()
	local Constants = require(script.Constants)
	local mode = Constants.ModeToAxis[roundingMode:get()] or "3D"

	if #parts == 0 and #roundified == 0 then
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("Roundify", "Roundify Parts")
	if not recording then
		warn("RoundifyPart: Could not begin ChangeHistory recording")
		return
	end

	local results = {}

	-- Roundify raw parts
	for _, part in ipairs(parts) do
		local model = RoundifyOperations.roundify(part, radius, mode)
		if model then
			table.insert(results, model)
		end
	end

	-- Re-roundify existing rounded models
	for _, roundifyModel in ipairs(roundified) do
		local sourceCFrame = roundifyModel:GetAttribute("RoundifySourceCFrame")
		if not sourceCFrame then
			continue
		end

		local sample = roundifyModel:FindFirstChildWhichIsA("BasePart")
		if not sample then
			continue
		end

		-- Use stored RoundifySourceSize so user edits to the attribute are respected.
		-- Fall back to bounding box if the attribute is missing.
		local sourceSize = roundifyModel:GetAttribute("RoundifySourceSize")
		local originalPrimarySize = roundifyModel:GetAttribute("RoundifyPrimaryPartSize")
		local modelCFrame, modelSize = roundifyModel:GetBoundingBox()

		local effectiveSize
		local scale = 1
		pcall(function()
			scale = roundifyModel:GetScale()
		end)

		local primaryPart = roundifyModel.PrimaryPart
		if sourceSize and originalPrimarySize and primaryPart then
			-- Start from the stored source size, scaled by any model Scale tool usage
			local scaledSource = sourceSize * scale
			local scaledPrimary = originalPrimarySize * scale
			-- Delta = how much the user resized the primary part beyond the scale
			local delta = primaryPart.Size - scaledPrimary
			effectiveSize = scaledSource + delta
			-- Clamp each axis to a minimum so we never produce a zero/negative size
			effectiveSize = Vector3.new(
				math.max(effectiveSize.X, 0.05),
				math.max(effectiveSize.Y, 0.05),
				math.max(effectiveSize.Z, 0.05)
			)
		elseif sourceSize then
			effectiveSize = sourceSize * scale
		else
			effectiveSize = modelSize
		end

		local tempPart = Instance.new("Part")
		tempPart.Size = effectiveSize

		tempPart.CFrame = roundifyModel:GetPivot()
		for _, prop in RoundifyOperations.COPY_PROPERTIES do
			tempPart[prop] = sample[prop]
		end
		tempPart.Parent = roundifyModel.Parent

		roundifyModel.Parent = nil

		local newModel = RoundifyOperations.roundify(tempPart, radius, mode)
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
	local roundified = selectedRoundified:get()
	if #roundified == 0 then
		return
	end

	local shouldUnion = unionOnBake:get()

	local recording = ChangeHistoryService:TryBeginRecording("Bake", "Bake Rounded Parts")
	if not recording then
		warn("RoundifyPart: Could not begin ChangeHistory recording")
		return
	end

	local results = {}

	for _, roundifyModel in ipairs(roundified) do
		for _, attr in ipairs(ROUNDIFY_ATTRIBUTES) do
			roundifyModel:SetAttribute(attr, nil)
		end

		if shouldUnion then
			local parts = {}
			for _, child in ipairs(roundifyModel:GetChildren()) do
				if child:IsA("BasePart") then
					table.insert(parts, child)
				end
			end

			if #parts >= 2 then
				local primary = table.remove(parts, 1)
				local ok, unionPart = pcall(function()
					return primary:UnionAsync(parts)
				end)

				if ok and unionPart then
					unionPart.Name = roundifyModel.Name
					unionPart.Parent = roundifyModel.Parent
					roundifyModel.Parent = nil
					table.insert(results, unionPart)
				else
					warn("RoundifyPart: UnionAsync failed for " .. roundifyModel.Name)
					table.insert(results, roundifyModel)
				end
			elseif #parts == 1 then
				local single = parts[1]
				single.Name = roundifyModel.Name
				single.Parent = roundifyModel.Parent
				roundifyModel.Parent = nil
				table.insert(results, single)
			else
				table.insert(results, roundifyModel)
			end
		else
			table.insert(results, roundifyModel)
		end
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)

	if #results > 0 then
		Selection:Set(results)
	end

	updateSelection()
end

local hasSelection = Computed(function()
	return #selectedParts:get() > 0 or #selectedRoundified:get() > 0
end)

local statusText = Computed(function()
	local partCount = #selectedParts:get()
	local roundifyCount = #selectedRoundified:get()
	if partCount == 0 and roundifyCount == 0 then
		return "No parts selected"
	end
	local segments = {}
	if partCount > 0 then
		table.insert(segments, partCount .. (partCount == 1 and " part" or " parts"))
	end
	if roundifyCount > 0 then
		table.insert(segments, roundifyCount .. (roundifyCount == 1 and " rounded" or " rounded"))
	end
	return table.concat(segments, ", ") .. " selected"
end)

do
	local pluginToolbar = Toolbar({
		Name = "RoundifyPart",
	})

	ToolbarButton({
		Toolbar = pluginToolbar,
		ClickableWhenViewportHidden = true,
		Name = "RoundifyPart",
		ToolTip = "Open RoundifyPart widget",
		Image = "rbxassetid://114446350843586",

		[OnEvent("Click")] = function()
			widgetsEnabled:set(not widgetsEnabled:get())
		end,
	})

	local Constants = require(script.Constants)

	Widget({
		Id = "RoundifyPartWidget",
		Name = "RoundifyPart v" .. Constants.Version,

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
				-- UpdateBanner({
				-- 	AssetId = Constants.PluginAssetId,
				-- 	CurrentVersion = Constants.Version,
				-- 	Enabled = widgetsEnabled,
				-- 	LayoutOrder = 0,
				-- }),

				Title({
					Text = "Radius",
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
							roundifyRadius:set(num)
						end
					end,
				}),

				Title({
					Text = "Rounding Mode",
					LayoutOrder = 3,
				}),

				Dropdown({
					Options = Constants.RoundingModes,
					Value = roundingMode,
					OnSelected = function(selected)
						roundingMode:set(selected)
					end,
					Size = UDim2.new(1, 0, 0, 25),
					LayoutOrder = 4,
				}),

				Label({
					Text = statusText,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 5,
				}),

				MainButton({
					Text = "Roundify Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 6,
					Enabled = hasSelection,
					Activated = doRoundify,
				}),

				Title({
					Text = "Baking",
					LayoutOrder = 7,
				}),

				Checkbox({
					Text = "Union result",
					Value = unionOnBake,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 8,
				}),

				Button({
					Text = "Bake Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 9,
					Enabled = Computed(function()
						return #selectedRoundified:get() > 0
					end),
					Activated = doBake,
				}),

				Label({
					Text = "Bake removes roundify attributes placed by the plugin.",
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 10,
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
