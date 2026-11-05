-- Tome
--
-- Puts the same set of tabs on each Blizzard window it manages, so Character, Spellbook,
-- Talents, Guild, Collections and Group Finder work like one window, with your bags as one
-- more tab. They all open bottom right, where Blizzard opens the bags, one at a time.
--
-- Combat: in combat only Blizzard's own code may open these windows. So a tab never opens
-- anything itself. Each tab is a secure macro button that /clicks the close button of
-- whatever is open and then Blizzard's micro button for the target. A restricted snippet
-- writes that macro at click time; it tells which window is open from small protected
-- marker frames parented to each window.
--
-- Bags: the Bags tab is a window of Tome's own, opened and closed by restricted snippets so
-- it works in combat too. Blizzard's bag windows still open and close as always, so anything
-- that opens your bags (a vendor, the mailbox, the backpack button) still works, but they
-- wait inside a hidden frame and Tome's window shows in their place.

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
	{ key = "bags", label = "Bags", button = "TomeBagsOpenButton", frames = { "TomeBagsFrame" },
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
local TOP_ROW_LEFT = 58 -- the row starts right of the window's portrait
local TOP_TAB_GAP = 2
local COMPACT_TAB_WIDTH = 38 -- a top tab with just its icon
local GEAR_ROOM = 30 -- the settings gear at the end of the row or column

-- The Bags window: a grid of Blizzard's own bag slot buttons.
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or (NUM_BAG_SLOTS + (NUM_REAGENTBAG_SLOTS or 0))
local SLOT_SIZE = 37
local SLOT_GAP = 5
local MIN_COLUMNS = 10
local BAGS_TOP = 64 -- title, search box and sort button
local BAGS_SIDE = 12
local BAGS_BOTTOM = 36 -- your money

local db
local ready = false
local pendingCombat = false
local positionSetting, settingsCategory
local bars = {} -- [window] = { panel, row, column, topTabs, sideTabs, rowWidth, columnHeight, sideX, sideY, shownAt }
local ourFrames = {} -- frames we parent to Blizzard windows; skipped when measuring their tabs
local shownCount = 0 -- counts windows opening, so the newest one can win

local bagsFrame -- the Bags window
local bagSlots = {} -- [bag] = { holder, buttons, size }
local bagsDirty = true
local blizzardBags = {} -- [Blizzard's bag window] = the parent it has when it's showing
local bagHolder -- hidden; Blizzard's bag windows wait in here
local bagKeyButton

BINDING_HEADER_TOME = "Tome"
_G["BINDING_NAME_CLICK TomeToggleButton:LeftButton"] = "Open or close Tome"

----------------------------------------------------------------------------------------------
-- Secure side

local header = CreateFrame("Frame", "TomeHeader", UIParent, "SecureHandlerBaseTemplate")
header:SetAttribute("tome-views", 0)
header:SetAttribute("tome-last", DEFAULT_TAB)

-- Before a tab's click: close every other open window, then press the target's micro
-- button, unless the target is already the one showing. A tab whose micro button is off
-- does nothing, so it doesn't close the window you're on and then open nothing. The bags
-- key sets `tome-toggle`, so pressing it on the Bags tab closes it again.
local TAB_CLICK = [[
	local want, family = self:GetAttribute("tome-key"), self:GetAttribute("tome-family")
	if owner:GetAttribute("tome-off-" .. want) then
		return false
	end
	local text, closer = "", nil
	for i = 1, owner:GetAttribute("tome-views") do
		local view = "tome-view" .. i
		local marker = owner:GetFrameRef(view)
		if marker and marker:IsVisible() then
			if owner:GetAttribute(view .. "-key") == want then
				closer = owner:GetAttribute(view .. "-close")
			elseif owner:GetAttribute(view .. "-family") ~= family then
				text = text .. "/click " .. owner:GetAttribute(view .. "-close") .. "\n"
			end
		end
	end
	if not closer then
		text = text .. "/click " .. self:GetAttribute("tome-open")
	elseif self:GetAttribute("tome-toggle") then
		text = text .. "/click " .. closer
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
		local last = owner:GetAttribute("tome-last")
		if owner:GetAttribute("tome-off-" .. last) then
			last = "character" -- DEFAULT_TAB
		end
		if owner:GetAttribute("tome-off-" .. last) then
			return false
		end
		text = "/click " .. owner:GetAttribute("tome-open-" .. last)
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

local function IsTabActive(tab, panel)
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

-- Blizzard switches a micro button off until you've earned what it opens (Talents until
-- your first talent point, Group Finder until its level) or while a service is down, and
-- pressing it then does nothing. Its tab greys out to match.
local function IsTabOff(tab)
	return tab.enabled == false
end

-- The same reason the micro button's own tooltip gives.
local function OffReason(tab)
	local button = _G[MicroButtonFor(tab)]
	if button.factionGroup == "Neutral" then
		return FEATURE_NOT_AVAILBLE_PANDAREN
	elseif button.minLevel then
		return format(FEATURE_BECOMES_AVAILABLE_AT_LEVEL, button.minLevel)
	end
	return button.disabledTooltip and GetValueOrCallFunction(button, "disabledTooltip")
end

local function SetTabTooltip(tooltip, tab)
	tooltip:SetText(tab.label)
	local reason = IsTabOff(tab) and OffReason(tab)
	if reason then
		tooltip:AddLine(reason, RED_FONT_COLOR.r, RED_FONT_COLOR.g, RED_FONT_COLOR.b, true)
	end
end

local function SetTopTabSelected(button, selected, off)
	for _, piece in ipairs(button.active) do
		piece:SetShown(selected)
	end
	for _, piece in ipairs(button.inactive) do
		piece:SetShown(not selected)
	end
	button.Icon:SetDesaturated(off)
	button.Text:SetFontObject(off and GameFontDisableSmall or selected and GameFontHighlightSmall or GameFontNormalSmall)
end

local function Refresh()
	for panel, bar in pairs(bars) do
		if panel:IsVisible() then
			for tab, button in pairs(bar.topTabs) do
				if tab.key == "character" then
					SetTabIcon(button.Icon, tab)
				end
				SetTopTabSelected(button, IsTabActive(tab, panel), IsTabOff(tab))
			end
			for tab, button in pairs(bar.sideTabs) do
				if tab.key == "character" then
					SetTabIcon(button.Icon, tab)
				end
				button:SetChecked(IsTabActive(tab, panel))
				button.Icon:SetDesaturated(IsTabOff(tab))
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

-- The tabs' click snippets read which micro buttons are off from the header, and the
-- header can't change in combat, so a button switching mid-fight is caught up afterwards.
local function SyncEnabled()
	for _, tab in ipairs(TABS) do
		if tab.available then
			tab.enabled = _G[MicroButtonFor(tab)]:IsEnabled()
		end
	end
	if InCombatLockdown() then
		pendingCombat = true
	else
		for _, tab in ipairs(TABS) do
			if tab.available then
				header:SetAttribute("tome-off-" .. tab.key, IsTabOff(tab) or nil)
			end
		end
	end
	Refresh()
end

local syncQueued = false
local function QueueSync()
	if not syncQueued then
		syncQueued = true
		C_Timer.After(0, function()
			syncQueued = false
			SyncEnabled()
		end)
	end
end

----------------------------------------------------------------------------------------------
-- Tab position

-- Labels and icons where the window is wide enough for the whole row, otherwise just the
-- icons, with each label in its tooltip.
local function FitRow(bar)
	local compact = bar.rowWidth > bar.panel:GetWidth() - TOP_ROW_LEFT
	local width = 0
	for _, tab in ipairs(TABS) do
		local button = bar.topTabs[tab]
		if button then
			button.Text:SetShown(not compact)
			button:SetWidth(compact and COMPACT_TAB_WIDTH or button.fullWidth)
			width = width + button:GetWidth() + TOP_TAB_GAP
		end
	end
	bar.row:SetSize(width + GEAR_ROOM, TOP_TAB_HEIGHT)
end

-- Forever's windows keep Blizzard's own tabs down their right edge (Character, Collections,
-- Group Finder). The side column goes beside those, level with the first one, and shrinks
-- to fit a short window.
local function PlaceColumn(bar)
	local panel = bar.panel
	local right, top = panel:GetRight(), panel:GetTop()
	if panel:IsVisible() and right and top then
		local edge, highest
		local function consider(frame)
			if ourFrames[frame] or not frame:IsShown() then
				return
			end
			local left, bottom = frame:GetLeft(), frame:GetBottom()
			if left and bottom and math.abs(left - right) < 8 and bottom < top and frame:GetWidth() < 100 then
				edge = math.max(edge or right, frame:GetRight())
				highest = math.max(highest or bottom, frame:GetTop())
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
		bar.sideX = edge and math.ceil(edge - right) + 2 or 0
		bar.sideY = highest and math.max(0, math.floor(top - highest)) or 30
	end
	local room = panel:GetHeight() - bar.sideY - 8
	local scale = math.max(0.5, math.min(1, room / bar.columnHeight))
	bar.column:SetScale(scale)
	bar.column:ClearAllPoints()
	bar.column:SetPoint("TOPLEFT", panel, "TOPRIGHT", bar.sideX / scale, -bar.sideY / scale)
end

-- Where Blizzard opens the bags: bottom right, clear of the action bars on the right.
local function BagSpot()
	local x = 10
	if EditModeUtil and EditModeUtil.GetRightActionBarWidth then
		x = x + EditModeUtil:GetRightActionBarWidth()
	end
	return x, CONTAINER_OFFSET_Y or 85
end

-- Every Tome window sits in the bag spot, tabs included, and never past the top of the
-- screen. Blizzard's windows go back to their own spot whenever Blizzard lays them out, so
-- this runs again after that.
local function PlaceWindow(bar)
	local panel = bar.panel
	if not panel:IsShown() and panel ~= bagsFrame then
		return
	end
	local scale = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local x, y = BagSpot()
	local right = x / scale
	local top = 0
	if db.position == "side" then
		right = right + bar.sideX + bar.column:GetWidth() * bar.column:GetScale()
	else
		top = TOP_TAB_HEIGHT
	end
	local bottom = math.max(0, math.min(y / scale, UIParent:GetHeight() / scale - panel:GetHeight() - top))
	panel:ClearAllPoints()
	panel:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -right, bottom)
end

-- Moving a window is blocked in combat, so one that opens mid-fight opens in Blizzard's
-- spot and moves when combat ends.
local function PlaceAll()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	for _, bar in pairs(bars) do
		PlaceWindow(bar)
	end
end

local function ApplyPosition(bar)
	local onTop = db.position ~= "side"
	bar.row:SetShown(onTop)
	bar.column:SetShown(not onTop)
	if onTop then
		FitRow(bar)
	else
		PlaceColumn(bar)
	end
	PlaceWindow(bar)
end

-- Moving or resizing the tabs is blocked in combat, so a window that opens or changes size
-- mid-fight gets its tabs laid out when combat ends.
local function Layout(bar)
	if InCombatLockdown() then
		pendingCombat = true
	else
		ApplyPosition(bar)
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

-- Tome is one window, so when one opens the rest close. Closing them is blocked in combat,
-- so whatever opened mid-fight is tidied up when combat ends, keeping the newest.
local function Tidy()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	local newest
	for panel, bar in pairs(bars) do
		if panel:IsShown() and (not newest or bar.shownAt > newest.shownAt) then
			newest = bar
		end
	end
	for panel, bar in pairs(bars) do
		if bar ~= newest and panel:IsShown() then
			if panel == bagsFrame then
				panel:Hide()
			else
				HideUIPanel(panel)
			end
		end
	end
	PlaceAll()
end

local tidyQueued = false
local function QueueTidy()
	if not tidyQueued then
		tidyQueued = true
		C_Timer.After(0, function()
			tidyQueued = false
			Tidy()
		end)
	end
end

----------------------------------------------------------------------------------------------
-- Bags window

local function BagSize(bag)
	if ContainerFrame_GetContainerNumSlots then
		return (ContainerFrame_GetContainerNumSlots(bag)) -- counts the locked slots too
	end
	return C_Container.GetContainerNumSlots(bag)
end

local function BagSizesChanged()
	for bag = 0, LAST_BAG do
		if BagSize(bag) ~= bagSlots[bag].size then
			return true
		end
	end
	return false
end

-- The same steps Blizzard's bag windows take for each slot. Each button's bag is its
-- holder's ID, so the slot's click stays Blizzard's own and works in combat.
local function UpdateSlot(button, tooltipOwner)
	local bag, slot = button:GetBagID(), button:GetID()
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local questInfo = C_Container.GetContainerItemQuestInfo(bag, slot)
	local texture = info and info.iconFileID
	local quality = info and info.quality

	ClearItemButtonOverlay(button)
	button:SetHasItem(texture)
	button:SetItemButtonTexture(texture)
	button:SyncAppearanceWithHasItem()
	SetItemButtonQuality(button, quality, info and info.hyperlink, false, info and info.isBound)
	SetItemButtonCount(button, info and info.stackCount)
	SetItemButtonDesaturated(button, info and info.isLocked)
	button:UpdateExtended()
	button:UpdateQuestItem(questInfo.isQuestItem, questInfo.questID, questInfo.isActive)
	button:UpdateNewItem(quality)
	button:UpdateJunkItem(quality, info and info.hasNoValue)
	button:UpdateItemContextMatching()
	button:UpdateCooldown(texture)
	button:SetReadable(info and info.isReadable)
	button:CheckUpdateTooltip(tooltipOwner)
	button:SetMatchesSearch(not (info and info.isFiltered))
end

-- Every bag in one grid, backpack first, with the reagent bag on a row of its own.
-- The window's size can't change in combat, so a bag swapped mid-fight shows afterwards.
local function LayoutBags()
	if InCombatLockdown() then
		bagsDirty = true
		pendingCombat = true
		return
	end
	bagsDirty = false
	local total = 0
	for bag = 0, LAST_BAG do
		total = total + BagSize(bag)
	end
	local columns = math.max(MIN_COLUMNS, math.ceil(math.sqrt(total)))
	local step = SLOT_SIZE + SLOT_GAP
	local column, row = 0, 0
	for bag = 0, LAST_BAG do
		local slots, size = bagSlots[bag], BagSize(bag)
		if bag > NUM_BAG_SLOTS and size > 0 and column > 0 then
			column, row = 0, row + 1
		end
		for slot = 1, size do
			local button = slots.buttons[slot]
			if not button then
				button = CreateFrame("ItemButton", nil, slots.holder, "ContainerFrameItemButtonTemplate")
				button:SetID(slot)
				slots.buttons[slot] = button
			end
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", bagsFrame, "TOPLEFT", BAGS_SIDE + column * step, -BAGS_TOP - row * step)
			button:Show()
			column = column + 1
			if column == columns then
				column, row = 0, row + 1
			end
		end
		for slot = size + 1, #slots.buttons do
			slots.buttons[slot]:Hide()
		end
		slots.size = size
	end
	local rows = math.max(1, row + (column > 0 and 1 or 0))
	bagsFrame:SetSize(BAGS_SIDE * 2 + columns * step - SLOT_GAP, BAGS_TOP + rows * step - SLOT_GAP + BAGS_BOTTOM)
end

local function UpdateBags()
	if bagsDirty or BagSizesChanged() then
		LayoutBags()
	end
	local tooltipOwner = GameTooltip:GetOwner()
	for bag = 0, LAST_BAG do
		for _, button in ipairs(bagSlots[bag].buttons) do
			if button:IsShown() then
				UpdateSlot(button, tooltipOwner)
			end
		end
	end
end

local bagUpdateQueued = false
local function QueueBagUpdate()
	if bagsFrame and bagsFrame:IsShown() and not bagUpdateQueued then
		bagUpdateQueued = true
		C_Timer.After(0, function()
			bagUpdateQueued = false
			if bagsFrame:IsShown() then
				UpdateBags()
			end
		end)
	end
end

local function CreateSortButton(parent)
	local sort = CreateFrame("Button", nil, parent)
	sort:SetSize(28, 26)
	sort:SetNormalAtlas("bags-button-autosort-up")
	sort:SetPushedAtlas("bags-button-autosort-down")
	sort:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local highlight = sort:GetHighlightTexture()
	highlight:ClearAllPoints()
	highlight:SetSize(24, 23)
	highlight:SetPoint("CENTER")
	sort:SetScript("OnClick", function()
		PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
		C_Container.SortBags()
	end)
	sort:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self)
		GameTooltip_SetTitle(GameTooltip, BAG_CLEANUP_BAGS, HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, BAG_CLEANUP_BAGS_DESCRIPTION)
		GameTooltip:Show()
	end)
	sort:SetScript("OnLeave", GameTooltip_Hide)
	return sort
end

-- The window and the two buttons the tabs and keys /click to open and close it. Both are
-- restricted snippets, so they work in combat. While it's up, Escape closes it.
local function CreateBagsWindow()
	local frame = CreateFrame("Frame", "TomeBagsFrame", UIParent,
		"PortraitFrameTemplateNoCloseButton, SecureHandlerShowHideTemplate")
	frame:Hide()
	bagsFrame = frame
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetTitle("Bags")
	frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Bag_08")
	frame:SetAttribute("_onshow", [[ self:SetBindingClick(true, "ESCAPE", "TomeBagsCloseButton") ]])
	frame:SetAttribute("_onhide", [[ self:ClearBindings() ]])

	local close = CreateFrame("Button", "TomeBagsCloseButton", frame,
		"UIPanelCloseButtonNoScripts, SecureHandlerClickTemplate")
	close:SetSize(24, 24)
	close:SetPoint("TOPRIGHT", 1, 0)
	close:SetFrameRef("bags", frame)
	close:SetAttribute("_onclick", [[ self:GetFrameRef("bags"):Hide() ]])
	frame.CloseButton = close

	local open = CreateFrame("Button", "TomeBagsOpenButton", UIParent, "SecureHandlerClickTemplate")
	open:SetFrameRef("bags", frame)
	open:SetAttribute("_onclick", [[ self:GetFrameRef("bags"):Show() ]])

	local sort = CreateSortButton(frame)
	sort:SetPoint("TOPRIGHT", -9, -34)

	local search = CreateFrame("EditBox", "TomeBagsSearchBox", frame, "BagSearchBoxTemplate")
	search:SetHeight(20)
	search:SetMaxLetters(15)
	search:SetPoint("TOPLEFT", 66, -35)
	search:SetPoint("RIGHT", sort, "LEFT", -8, 0)

	local money = CreateFrame("Frame", "TomeBagsMoneyFrame", frame, "ContainerMoneyFrameTemplate")
	money:SetHeight(16)
	money:SetPoint("BOTTOMLEFT", 8, 8)
	money:SetPoint("BOTTOMRIGHT", -8, 8)

	for bag = 0, LAST_BAG do
		local holder = CreateFrame("Frame", nil, frame)
		holder:SetAllPoints()
		holder:SetID(bag)
		bagSlots[bag] = { holder = holder, buttons = {} }
	end
	LayoutBags()

	frame:HookScript("OnShow", function()
		PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)
		OpenAllBags()
		UpdateBags()
	end)
	frame:HookScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE)
		if IsAnyBagOpen() then
			CloseAllBags()
		end
		for bag = 0, LAST_BAG do
			for slot = 1, bagSlots[bag].size or 0 do
				C_NewItems.RemoveNewItem(bag, slot)
			end
		end
	end)

	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN",
		"INVENTORY_SEARCH_UPDATE", "BAG_NEW_ITEMS_UPDATED", "QUEST_ACCEPTED", "UNIT_QUEST_LOG_CHANGED",
		"MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_ENTERING_WORLD" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", QueueBagUpdate)
end

----------------------------------------------------------------------------------------------
-- Blizzard's bag windows

local function IsOurBag(frame)
	if frame == ContainerFrameCombinedBags then
		return true
	end
	local id = frame:GetID()
	return id >= 0 and id <= LAST_BAG
end

-- Ours wait in the holder unless `fallback` says they have to show as Blizzard's.
local function PlaceBagWindow(frame, fallback)
	local parent = frame:GetParent()
	if parent ~= bagHolder then
		blizzardBags[frame] = parent -- Blizzard moves them for full-screen views
	end
	local wanted = IsOurBag(frame) and not fallback and bagHolder or blizzardBags[frame]
	if parent ~= wanted and not (InCombatLockdown() and frame:IsProtected()) then
		if FrameUtil and FrameUtil.SetParentMaintainRenderLayering then
			FrameUtil.SetParentMaintainRenderLayering(frame, wanted)
		else
			frame:SetParent(wanted)
		end
	end
end

-- Blizzard's bags open, Tome's window opens. Blizzard's close, Tome's closes. Showing Tome's
-- window is blocked in combat, so bags opened mid-fight some other way than a Tome tab (the
-- backpack button, say) come out of hiding and show as Blizzard's until combat ends.
local backpackWasOpen = false
local function SyncBags()
	local open, backpackOpen = false, false
	for frame in pairs(blizzardBags) do
		if frame:IsShown() and IsOurBag(frame) then
			open = true
			if frame == ContainerFrameCombinedBags or frame:GetID() == 0 then
				backpackOpen = true
			end
		end
	end
	-- The backpack button only closes the backpack, and in one window that should be all of it.
	if backpackWasOpen and not backpackOpen and open then
		CloseAllBags()
		open = false
	end
	backpackWasOpen = backpackOpen

	if open ~= bagsFrame:IsShown() then
		if InCombatLockdown() then
			pendingCombat = true
		else
			bagsFrame:SetShown(open)
		end
	end

	local fallback = open and not bagsFrame:IsShown()
	for frame in pairs(blizzardBags) do
		PlaceBagWindow(frame, fallback)
	end
end

local bagSyncQueued = false
local function QueueBagSync()
	if not bagSyncQueued then
		bagSyncQueued = true
		C_Timer.After(0, function()
			bagSyncQueued = false
			SyncBags()
		end)
	end
end

-- Blizzard reuses its bag windows for the bank too, so each one is moved the moment it
-- shows, before it's drawn.
local function OnBagWindowShown(frame)
	PlaceBagWindow(frame, InCombatLockdown() and not bagsFrame:IsShown())
	QueueBagSync()
end

-- Their OnShow and OnHide don't run while they're hidden away, so watch Show and Hide.
local function HideBlizzardBags()
	bagHolder = CreateFrame("Frame", nil, UIParent)
	bagHolder:SetAllPoints()
	bagHolder:Hide()
	local frames = { ContainerFrameCombinedBags }
	for i = 1, NUM_CONTAINER_FRAMES or 0 do
		frames[#frames + 1] = _G["ContainerFrame" .. i]
	end
	for _, frame in pairs(frames) do
		blizzardBags[frame] = frame:GetParent()
		hooksecurefunc(frame, "Show", OnBagWindowShown)
		hooksecurefunc(frame, "Hide", QueueBagSync)
		hooksecurefunc(frame, "SetShown", function(self, shown)
			if shown then
				OnBagWindowShown(self)
			else
				QueueBagSync()
			end
		end)
	end
	for _, name in ipairs({ "ContainerFrame_SetFullScreenFrame", "ContainerFrame_ClearFullScreenFrame" }) do
		if _G[name] then
			hooksecurefunc(name, QueueBagSync)
		end
	end
	bagsFrame:HookScript("OnShow", QueueBagSync)
	bagsFrame:HookScript("OnHide", QueueBagSync)
end

-- Your bag keys open the Bags tab. Override bindings can't change in combat.
local boundKeys
local function BindBagKeys()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	local keys = {}
	for _, action in ipairs({ "OPENALLBAGS", "TOGGLEBACKPACK" }) do
		for _, key in ipairs({ GetBindingKey(action) }) do
			keys[#keys + 1] = key
		end
	end
	local list = table.concat(keys, " ")
	if list == boundKeys then
		return -- setting them fires UPDATE_BINDINGS again
	end
	boundKeys = list
	ClearOverrideBindings(bagKeyButton)
	for _, key in ipairs(keys) do
		SetOverrideBindingClick(bagKeyButton, false, key, "TomeBagsKeyButton", "LeftButton")
	end
end

----------------------------------------------------------------------------------------------
-- Building the tabs

local function SetupTabAction(button, tab)
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("type", "macro")
	button:SetAttribute("tome-key", tab.key)
	button:SetAttribute("tome-family", tab.family or tab.key)
	button:SetAttribute("tome-open", MicroButtonFor(tab))
	header:WrapScript(button, "OnClick", TAB_CLICK)
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

	button.fullWidth = math.ceil(button.Text:GetStringWidth()) + 42
	button:SetSize(button.fullWidth, TOP_TAB_HEIGHT)
	SetTopTabSelected(button, false, false)
	SetupTabAction(button, tab)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		SetTabTooltip(GameTooltip, tab)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	return button
end

local function CreateSideTab(column, tab)
	local button = CreateFrame("Button", nil, column, "LargeSideTabButtonTemplate, SecureActionButtonTemplate")
	button.tooltipText = tab.label
	function button:GetTooltipTextSetupFunction()
		return function(tooltip)
			SetTabTooltip(tooltip, tab)
			return true
		end
	end
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
	local bar = { panel = panel, topTabs = {}, sideTabs = {}, sideX = 0, sideY = 30, shownAt = 0 }

	-- Along the top, starting right of the portrait; FitRow sets its width.
	local row = CreateFrame("Frame", nil, panel)
	row:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", TOP_ROW_LEFT, -2)
	row:SetClampedToScreen(true)
	local width, previous = 0, nil
	for _, tab in ipairs(TABS) do
		if tab.available then
			local button = CreateTopTab(row, tab)
			if previous then
				button:SetPoint("BOTTOMLEFT", previous, "BOTTOMRIGHT", TOP_TAB_GAP, 0)
			else
				button:SetPoint("BOTTOMLEFT")
			end
			width = width + button:GetWidth() + TOP_TAB_GAP
			bar.topTabs[tab] = button
			previous = button
		end
	end
	CreateGearButton(row):SetPoint("LEFT", previous, "RIGHT", 6, 0)
	bar.rowWidth = width + GEAR_ROOM
	row:SetSize(bar.rowWidth, TOP_TAB_HEIGHT)

	-- Down the right edge; PlaceColumn sets its spot and scale.
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
	bar.columnHeight = height + GEAR_ROOM
	column:SetSize(tabWidth, bar.columnHeight)

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

local function MarkShown(bar)
	shownCount = shownCount + 1
	bar.shownAt = shownCount
	QueueTidy()
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
	Layout(bar)
	if panel:IsShown() then
		MarkShown(bar) -- a window that loads the first time it opens is already up
	end
	-- Blizzard's own side tabs settle a frame after the window shows, and the Spellbook
	-- changes width when it switches between its small and full views.
	panel:HookScript("OnShow", function()
		MarkShown(bar)
		QueueRefresh()
		if not InCombatLockdown() then
			PlaceWindow(bar)
		end
		C_Timer.After(0, function()
			Layout(bar)
		end)
	end)
	panel:HookScript("OnSizeChanged", function()
		Layout(bar)
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

	CreateBagsWindow() -- first, since the Bags tab presses its open button

	for _, tab in ipairs(TABS) do
		local button = MicroButtonFor(tab)
		tab.available = button ~= nil
		if button then
			header:SetAttribute("tome-open-" .. tab.key, button)
		end
	end
	if db.last and header:GetAttribute("tome-open-" .. db.last) then
		header:SetAttribute("tome-last", db.last)
	end

	for _, tab in ipairs(TABS) do
		if tab.available then
			local button = _G[MicroButtonFor(tab)]
			hooksecurefunc(button, "Enable", QueueSync)
			hooksecurefunc(button, "Disable", QueueSync)
		end
	end
	SyncEnabled()

	local toggle = CreateFrame("Button", "TomeToggleButton", UIParent, "SecureActionButtonTemplate")
	toggle:SetAttribute("type", "macro")
	toggle:RegisterForClicks("AnyUp", "AnyDown")
	header:WrapScript(toggle, "OnClick", TOGGLE_CLICK)

	for _, tab in ipairs(TABS) do
		if tab.key == "bags" then
			bagKeyButton = CreateFrame("Button", "TomeBagsKeyButton", UIParent, "SecureActionButtonTemplate")
			bagKeyButton:SetAttribute("tome-toggle", true)
			SetupTabAction(bagKeyButton, tab)
		end
	end

	HideBlizzardBags()
	for _, name in ipairs({ "ShowUIPanel", "HideUIPanel", "UpdateUIPanelPositions", "UpdateScaleForFitForOpenPanels",
		"MaximizeUIPanel", "RestoreUIPanelArea", "UpdateContainerFrameAnchors" }) do
		if _G[name] then
			hooksecurefunc(name, PlaceAll)
		end
	end

	ready = true
	AttachAll()
	BindBagKeys()
	SyncBags()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("UPDATE_BINDINGS")
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
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
			SyncEnabled()
			AttachAll()
			ApplyAllPositions()
			if bagsDirty then
				LayoutBags()
			end
			SyncBags()
			Tidy()
			BindBagKeys()
		end
	elseif event == "UPDATE_BINDINGS" then
		if ready then
			BindBagKeys()
		end
	elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
		if ready then
			PlaceAll()
		end
	elseif event == "PLAYER_LOGOUT" then
		db.last = header:GetAttribute("tome-last")
	end
end)
