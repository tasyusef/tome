-- Tome
--
-- Puts the same set of tabs on each Blizzard window it manages, so Character, Spellbook,
-- Talents, Guild, Collections and Group Finder work like one window. The Bags tab opens
-- your bags beside whichever window is up.
--
-- Combat: in combat only Blizzard's own code may open these windows. So a tab never opens
-- anything itself. Each tab is a secure macro button that /clicks the close button of
-- whatever is open and then Blizzard's micro button for the target. A restricted snippet
-- writes that macro at click time; it tells which window is open from small protected
-- marker frames parented to each window.

local ADDON_NAME = ...

-- `button` is the micro button the tab presses, `frames` the window(s) that button opens,
-- and `views` the children that tell apart tabs sharing one window (Spellbook and Talents
-- both live in PlayerSpellsFrame, hence the shared `family`).
local TABS = {
	{ key = "character", label = "Character", button = "CharacterMicroButton", frames = { "CharacterFrame" } },
	{ key = "spellbook", label = "Spellbook", button = "SpellbookMicroButton", fallback = "PlayerSpellsMicroButton",
		frames = { "PlayerSpellsFrame" }, views = { "SpellBookFrame" }, family = "playerspells",
		icon = "Interface\\Icons\\INV_Misc_Book_09" },
	{ key = "talents", label = "Talents", button = "TalentMicroButton", fallback = "PlayerSpellsMicroButton",
		frames = { "PlayerSpellsFrame" }, views = { "TalentsFrame", "SpecFrame" }, family = "playerspells" },
	{ key = "bags", label = "Bags", button = "MainMenuBarBackpackButton", bags = true,
		icon = "Interface\\Icons\\INV_Misc_Bag_08" },
	{ key = "guild", label = "Guild", button = "GuildMicroButton", frames = { "CommunitiesFrame" },
		icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01" },
	{ key = "collections", label = "Collections", button = "CollectionsMicroButton", frames = { "CollectionsJournal" },
		icon = "Interface\\Icons\\Ability_Mount_RidingHorse" },
	{ key = "group", label = "Group Finder", button = "LFDMicroButton", frames = { "PVEFrame", "LFGParentFrame" },
		icon = "Interface\\Icons\\INV_Misc_GroupNeedMore" },
}

local POSITIONS = {
	{ "top", "Tabs along the top" },
	{ "side", "Tabs down the side" },
}

local DEFAULT_TAB = "character"
local TOP_TAB_HEIGHT = 26
local TOP_ART_SCALE = 0.75 -- Blizzard's top tabs reuse the bottom-tab art, flipped, at 75% height

local db
local ready = false
local pendingCombat = false
local positionSetting, settingsCategory
local bars = {} -- [window] = { panel, row, column, topTabs, sideTabs, sideOffset }
local ourFrames = {} -- frames we parent to Blizzard windows; skipped when measuring their tabs

BINDING_HEADER_TOME = "Tome"
_G["BINDING_NAME_CLICK TomeToggleButton:LeftButton"] = "Open or close Tome"

----------------------------------------------------------------------------------------------
-- Secure side

local header = CreateFrame("Frame", "TomeHeader", UIParent, "SecureHandlerBaseTemplate")
header:SetAttribute("tome-views", 0)
header:SetAttribute("tome-last", DEFAULT_TAB)

-- Before a tab's click: close every other open window, then press the target's micro
-- button, unless the target is already the one showing.
local TAB_CLICK = [[
	local want, family = self:GetAttribute("tome-key"), self:GetAttribute("tome-family")
	local text, isOpen = "", false
	for i = 1, owner:GetAttribute("tome-views") do
		local view = "tome-view" .. i
		local marker = owner:GetFrameRef(view)
		if marker and marker:IsVisible() then
			if owner:GetAttribute(view .. "-key") == want then
				isOpen = true
			elseif owner:GetAttribute(view .. "-family") ~= family then
				text = text .. "/click " .. owner:GetAttribute(view .. "-close") .. "\n"
			end
		end
	end
	if not isOpen then
		text = text .. "/click " .. self:GetAttribute("tome-open")
	end
	if text == "" then
		return false
	end
	owner:SetAttribute("tome-last", want)
	self:SetAttribute("macrotext", text)
]]

-- Before the keybind's click: close whatever is open, or reopen the last tab used.
local TOGGLE_CLICK = [[
	local text = ""
	for i = 1, owner:GetAttribute("tome-views") do
		local view = "tome-view" .. i
		local marker = owner:GetFrameRef(view)
		if marker and marker:IsVisible() then
			owner:SetAttribute("tome-last", owner:GetAttribute(view .. "-key"))
			text = text .. "/click " .. owner:GetAttribute(view .. "-close") .. "\n"
		end
	end
	if text == "" then
		text = "/click " .. owner:GetAttribute("tome-open-" .. owner:GetAttribute("tome-last"))
	end
	self:SetAttribute("macrotext", text)
]]

local function MicroButtonFor(tab)
	if _G[tab.button] then
		return tab.button
	end
	return tab.fallback and _G[tab.fallback] and tab.fallback or nil
end

-- A window's own close button only ever closes it. A micro button can switch tabs
-- instead (Character while on Reputation), so it is only the fallback.
local function CloserFor(panel, tab)
	local close = panel.CloseButton or _G[panel:GetName() .. "CloseButton"]
	local name = close and close:GetName()
	if name and _G[name] == close then
		return name
	end
	return MicroButtonFor(tab)
end

----------------------------------------------------------------------------------------------
-- Tab state

local function BagsOpen()
	if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
		return true
	end
	return IsBagOpen and IsBagOpen(0) or false
end

local function IsTabActive(tab, panel)
	if tab.bags then
		return BagsOpen()
	end
	if not tab.frames or not tContains(tab.frames, panel:GetName()) then
		return false
	end
	if not tab.views then
		return true
	end
	for _, key in ipairs(tab.views) do
		if panel[key] and panel[key]:IsShown() then
			return true
		end
	end
	return false
end

local function SetTabIcon(texture, tab)
	if tab.key == "character" then
		SetPortraitTexture(texture, "player")
	elseif tab.key == "talents" then
		local _, classFile = UnitClass("player")
		texture:SetTexture("Interface\\Icons\\ClassIcon_" .. classFile)
	else
		texture:SetTexture(tab.icon)
	end
end

local function SetTopTabSelected(button, selected)
	for _, piece in ipairs(button.active) do
		piece:SetShown(selected)
	end
	for _, piece in ipairs(button.inactive) do
		piece:SetShown(not selected)
	end
	button.Text:SetFontObject(selected and GameFontHighlightSmall or GameFontNormalSmall)
end

local function Refresh()
	for panel, bar in pairs(bars) do
		if panel:IsVisible() then
			for tab, button in pairs(bar.topTabs) do
				if tab.key == "character" then
					SetTabIcon(button.Icon, tab)
				end
				SetTopTabSelected(button, IsTabActive(tab, panel))
			end
			for tab, button in pairs(bar.sideTabs) do
				if tab.key == "character" then
					SetTabIcon(button.Icon, tab)
				end
				button:SetChecked(IsTabActive(tab, panel))
			end
		end
	end
end

local refreshQueued = false
local function QueueRefresh()
	if not refreshQueued then
		refreshQueued = true
		C_Timer.After(0, function()
			refreshQueued = false
			Refresh()
		end)
	end
end

----------------------------------------------------------------------------------------------
-- Tab position

-- Forever's windows keep Blizzard's own tabs down their right edge (Character, Collections,
-- Group Finder), so the side column starts below whatever is already there.
local function PlaceColumn(bar)
	if InCombatLockdown() then
		return
	end
	local panel = bar.panel
	local right, top = panel:GetRight(), panel:GetTop()
	if panel:IsVisible() and right and top then
		local lowest
		local function consider(frame)
			if ourFrames[frame] or not frame:IsShown() then
				return
			end
			local left, bottom = frame:GetLeft(), frame:GetBottom()
			if left and bottom and math.abs(left - right) < 8 and bottom < top then
				lowest = math.min(lowest or bottom, bottom)
			end
		end
		for _, child in ipairs({ panel:GetChildren() }) do
			consider(child)
			if not ourFrames[child] then
				for _, grandchild in ipairs({ child:GetChildren() }) do
					consider(grandchild)
				end
			end
		end
		bar.sideOffset = lowest and math.floor(top - lowest + 12) or 30
	end
	bar.column:ClearAllPoints()
	bar.column:SetPoint("TOPLEFT", panel, "TOPRIGHT", 0, -bar.sideOffset)
end

local function ApplyPosition(bar)
	local onTop = db.position ~= "side"
	bar.row:SetShown(onTop)
	bar.column:SetShown(not onTop)
	if not onTop then
		PlaceColumn(bar)
	end
end

local function ApplyAllPositions()
	if InCombatLockdown() then
		pendingCombat = true
		print("|cffffd100Tome:|r tabs will move when combat ends.")
		return
	end
	for _, bar in pairs(bars) do
		ApplyPosition(bar)
	end
	QueueRefresh()
end

local function SetPosition(position)
	if positionSetting then
		positionSetting:SetValue(position) -- saves it and calls ApplyAllPositions
	else
		db.position = position
		ApplyAllPositions()
	end
end

local function IsPosition(position)
	return db.position == position
end

local function OpenSettingsMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Tome")
		for _, option in ipairs(POSITIONS) do
			root:CreateRadio(option[2], IsPosition, SetPosition, option[1])
		end
	end)
end

----------------------------------------------------------------------------------------------
-- Building the tabs

local function SetupTabAction(button, tab)
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("type", "macro")
	if tab.bags then
		button:SetAttribute("macrotext", "/click " .. tab.button)
	else
		button:SetAttribute("tome-key", tab.key)
		button:SetAttribute("tome-family", tab.family or tab.key)
		button:SetAttribute("tome-open", MicroButtonFor(tab))
		header:WrapScript(button, "OnClick", TAB_CLICK)
	end
end

local function AddTopTabArt(button, layer, atlases, leftX, rightX, isHighlight)
	local pieces = {}
	for i, atlas in ipairs(atlases) do
		local texture = button:CreateTexture(nil, layer)
		texture:SetAtlas(atlas, true)
		texture:SetTexCoord(0, 1, 1, 1 - TOP_ART_SCALE)
		texture:SetHeight(texture:GetHeight() * TOP_ART_SCALE)
		if isHighlight then
			texture:SetBlendMode("ADD")
			texture:SetAlpha(0.4)
		end
		pieces[i] = texture
	end
	local left, middle, right = pieces[1], pieces[2], pieces[3]
	left:SetPoint("BOTTOMLEFT", leftX, 0)
	right:SetPoint("BOTTOMRIGHT", rightX, 0)
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
	middle:SetPoint("TOPRIGHT", right, "TOPLEFT")
	middle:SetHorizTile(true)
	return pieces
end

local TAB_ART = { "uiframe-tab-left", "_uiframe-tab-center", "uiframe-tab-right" }
local ACTIVE_TAB_ART = { "uiframe-activetab-left", "_uiframe-activetab-center", "uiframe-activetab-right" }

local function CreateTopTab(row, tab)
	local button = CreateFrame("Button", nil, row, "SecureActionButtonTemplate")
	button.inactive = AddTopTabArt(button, "BACKGROUND", TAB_ART, -3, 7)
	button.active = AddTopTabArt(button, "BACKGROUND", ACTIVE_TAB_ART, -1, 8)
	AddTopTabArt(button, "HIGHLIGHT", TAB_ART, -3, 7, true)

	button.Icon = button:CreateTexture(nil, "ARTWORK")
	button.Icon:SetSize(14, 14)
	button.Icon:SetPoint("LEFT", 12, 0)
	SetTabIcon(button.Icon, tab)
	button.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	button.Text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	button.Text:SetPoint("LEFT", button.Icon, "RIGHT", 4, 0)
	button.Text:SetText(tab.label)

	button:SetSize(math.ceil(button.Text:GetStringWidth()) + 42, TOP_TAB_HEIGHT)
	SetTopTabSelected(button, false)
	SetupTabAction(button, tab)
	return button
end

local function CreateSideTab(column, tab)
	local button = CreateFrame("Button", nil, column, "LargeSideTabButtonTemplate, SecureActionButtonTemplate")
	button.tooltipText = tab.label
	SetTabIcon(button.Icon, tab)
	button:SetFillToInterior(true)
	button:SetChecked(false)
	SetupTabAction(button, tab)
	return button
end

local function CreateGearButton(parent)
	local gear = CreateFrame("Button", nil, parent)
	gear:SetSize(24, 24)
	gear:SetNormalAtlas("questlog-icon-setting")
	gear:SetHighlightAtlas("questlog-icon-setting", "ADD")
	gear:SetScript("OnClick", OpenSettingsMenu)
	gear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Tome settings")
		GameTooltip:Show()
	end)
	gear:SetScript("OnLeave", GameTooltip_Hide)
	return gear
end

local function CreateBar(panel)
	local bar = { panel = panel, topTabs = {}, sideTabs = {}, sideOffset = 30 }

	-- Along the top, starting right of the portrait.
	local row = CreateFrame("Frame", nil, panel)
	row:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 58, -2)
	row:SetClampedToScreen(true)
	local width, previous = 0, nil
	for _, tab in ipairs(TABS) do
		if tab.available then
			local button = CreateTopTab(row, tab)
			if previous then
				button:SetPoint("BOTTOMLEFT", previous, "BOTTOMRIGHT", 2, 0)
			else
				button:SetPoint("BOTTOMLEFT")
			end
			width = width + button:GetWidth() + 2
			bar.topTabs[tab] = button
			previous = button
		end
	end
	CreateGearButton(row):SetPoint("LEFT", previous, "RIGHT", 6, 0)
	row:SetSize(width + 30, TOP_TAB_HEIGHT)

	-- Down the right edge; PlaceColumn sets its vertical spot.
	local column = CreateFrame("Frame", nil, panel)
	column:SetClampedToScreen(true)
	local height, tabWidth = 0, 0
	previous = nil
	for _, tab in ipairs(TABS) do
		if tab.available then
			local button = CreateSideTab(column, tab)
			if previous then
				button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT")
			else
				button:SetPoint("TOPLEFT")
			end
			height = height + button:GetHeight()
			tabWidth = button:GetWidth()
			bar.sideTabs[tab] = button
			previous = button
		end
	end
	CreateGearButton(column):SetPoint("TOP", previous, "BOTTOM", -3, -6)
	column:SetSize(tabWidth, height + 30)

	bar.row, bar.column = row, column
	ourFrames[row], ourFrames[column] = true, true
	return bar
end

local function AddView(tab, parent, closer)
	local marker = CreateFrame("Frame", nil, parent, "SecureFrameTemplate")
	marker:SetSize(1, 1)
	marker:SetPoint("TOPLEFT")
	marker:SetScript("OnShow", QueueRefresh)
	marker:SetScript("OnHide", QueueRefresh)
	ourFrames[marker] = true

	local count = header:GetAttribute("tome-views") + 1
	local view = "tome-view" .. count
	header:SetFrameRef(view, marker)
	header:SetAttribute(view .. "-key", tab.key)
	header:SetAttribute(view .. "-family", tab.family or tab.key)
	header:SetAttribute(view .. "-close", closer)
	header:SetAttribute("tome-views", count) -- last, so a snippet never sees half a view
end

local function Attach(panelName)
	local panel = _G[panelName]
	if not panel or bars[panel] then
		return
	end

	for _, tab in ipairs(TABS) do
		if tab.available and tab.frames and tContains(tab.frames, panelName) then
			local closer = CloserFor(panel, tab)
			if tab.views then
				for _, key in ipairs(tab.views) do
					if panel[key] then
						AddView(tab, panel[key], closer)
					end
				end
			else
				AddView(tab, panel, closer)
			end
		end
	end

	local bar = CreateBar(panel)
	bars[panel] = bar
	ApplyPosition(bar)
	panel:HookScript("OnShow", function()
		QueueRefresh()
		C_Timer.After(0, function()
			if db.position == "side" then
				PlaceColumn(bar)
			end
		end)
	end)
	QueueRefresh()
end

-- Most of these windows load the first time they open, so this runs again on ADDON_LOADED.
local function AttachAll()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	for _, tab in ipairs(TABS) do
		if tab.available and tab.frames then
			for _, name in ipairs(tab.frames) do
				Attach(name)
			end
		end
	end
end

----------------------------------------------------------------------------------------------
-- Settings

local function RegisterSettings()
	settingsCategory = Settings.RegisterVerticalLayoutCategory("Tome")
	positionSetting = Settings.RegisterAddOnSetting(settingsCategory, "TOME_TAB_POSITION", "position", db,
		Settings.VarType.String, "Tab position", "top")
	positionSetting:SetValueChangedCallback(ApplyAllPositions)
	Settings.CreateDropdown(settingsCategory, positionSetting, function()
		local container = Settings.CreateControlTextContainer()
		for _, option in ipairs(POSITIONS) do
			container:Add(option[1], option[2])
		end
		return container:GetData()
	end, "Where the Tome tabs sit on each window.")
	Settings.RegisterAddOnCategory(settingsCategory)
end

SLASH_TOME1 = "/tome"
SlashCmdList.TOME = function(message)
	message = strtrim(message or ""):lower()
	if message == "top" or message == "side" then
		SetPosition(message)
	elseif settingsCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	end
end

----------------------------------------------------------------------------------------------
-- Startup

local function Setup()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end

	for _, tab in ipairs(TABS) do
		local button = MicroButtonFor(tab)
		tab.available = button ~= nil
		if button and not tab.bags then
			header:SetAttribute("tome-open-" .. tab.key, button)
		end
	end
	if db.last and header:GetAttribute("tome-open-" .. db.last) then
		header:SetAttribute("tome-last", db.last)
	end

	local toggle = CreateFrame("Button", "TomeToggleButton", UIParent, "SecureActionButtonTemplate")
	toggle:SetAttribute("type", "macro")
	toggle:RegisterForClicks("AnyUp", "AnyDown")
	header:WrapScript(toggle, "OnClick", TOGGLE_CLICK)

	for _, name in ipairs({ "ContainerFrameCombinedBags", "ContainerFrame1" }) do
		local frame = _G[name]
		if frame then
			frame:HookScript("OnShow", QueueRefresh)
			frame:HookScript("OnHide", QueueRefresh)
		end
	end

	ready = true
	AttachAll()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" then
		if name == ADDON_NAME then
			TomeCharDB = TomeCharDB or {}
			db = TomeCharDB
			db.position = db.position == "side" and "side" or "top"
			RegisterSettings()
		elseif ready then
			C_Timer.After(0, AttachAll)
		end
	elseif event == "PLAYER_LOGIN" then
		Setup()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if not ready then
			Setup()
		elseif pendingCombat then
			pendingCombat = false
			AttachAll()
			ApplyAllPositions()
		end
	elseif event == "PLAYER_LOGOUT" then
		db.last = header:GetAttribute("tome-last")
	end
end)
