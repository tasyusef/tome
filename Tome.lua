-- Tome
--
-- One set of tabs for everything on the menu bar, plus your bags. The tabs run down the left
-- side and stay put. Whichever tab you pick opens right beside them at its usual size, so
-- only the window's far edges move. Drag a window by an empty spot, or drag the gear under
-- the tabs, to move them all.
--
-- Combat: in combat only Blizzard's own code may open these windows. So a tab never opens
-- anything itself. Each tab is a secure macro button that /clicks the close button of
-- whatever is open and then Blizzard's micro button for the target. A restricted snippet
-- writes that macro at click time; it tells which window is open from small protected
-- marker frames parented to each window. The same markers put a window beside the tabs
-- when it shows, and Blizzard's own layout is told the same spot, so that works in combat too.
--
-- Bags: the Bags tab is a window of Tome's own, opened and closed by restricted snippets so
-- it works in combat too. Blizzard's bag windows still open and close as always, so anything
-- that opens your bags (a vendor, the mailbox) still works, but they wait inside a hidden
-- frame and Tome's window shows in their place.

local ADDON_NAME = ...

-- `button` is the micro button the tab presses, `frames` the window(s) that button opens,
-- and `views` the children that tell apart tabs sharing one window (Spellbook and Talents
-- both live in PlayerSpellsFrame, hence the shared `family`).
-- In the menu bar's order. The shop, the game menu and Help aren't windows Tome can put tabs
-- on, so they stay on the menu bar only.
local TABS = {
	{ key = "character", label = "Character", button = "CharacterMicroButton", frames = { "CharacterFrame" } },
	{ key = "professions", label = "Professions", button = "ProfessionMicroButton", frames = { "ProfessionsFrame" },
		icon = "Interface\\Icons\\Trade_BlackSmithing" },
	{ key = "spellbook", label = "Spellbook", button = "SpellbookMicroButton", fallback = "PlayerSpellsMicroButton",
		frames = { "PlayerSpellsFrame" }, views = { "SpellBookFrame" }, family = "playerspells",
		icon = "Interface\\Icons\\INV_Misc_Book_09" },
	{ key = "talents", label = "Talents", button = "TalentMicroButton", fallback = "PlayerSpellsMicroButton",
		frames = { "PlayerSpellsFrame" }, views = { "TalentsFrame", "SpecFrame" }, family = "playerspells" },
	{ key = "legacy", label = "Legacy", button = "LegacyMicroButton", frames = { "LegacySystemFrame" },
		icon = "Interface\\Icons\\Achievement_General" },
	{ key = "quests", label = "Quest Log", button = "QuestLogMicroButton", frames = { "WorldMapFrame" },
		icon = "Interface\\Icons\\INV_Misc_Map_01" },
	{ key = "housing", label = "Housing", button = "HousingMicroButton", frames = { "HousingDashboardFrame" },
		icon = "Interface\\Icons\\INV_Misc_Rune_01" },
	{ key = "guild", label = "Guild", button = "GuildMicroButton", frames = { "CommunitiesFrame" },
		icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01" },
	{ key = "group", label = "Group Finder", button = "LFDMicroButton", frames = { "PVEFrame", "LFGParentFrame" },
		icon = "Interface\\Icons\\INV_Misc_GroupNeedMore" },
	{ key = "collections", label = "Collections", button = "CollectionsMicroButton", frames = { "CollectionsJournal" },
		icon = "Interface\\Icons\\Ability_Mount_RidingHorse" },
	{ key = "journal", label = "Adventure Guide", button = "EJMicroButton", frames = { "EncounterJournal" },
		icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
	{ key = "bags", label = "Bags", button = "TomeBagsOpenButton", frames = { "TomeBagsFrame" },
		icon = "Interface\\Icons\\INV_Misc_Bag_08" },
}

local DEFAULT_TAB = "character"
local RAIL_X = 1 -- the tabs tuck under the window's border by this much
local RAIL_TOP = 54 -- the first tab starts below the window's portrait
local GEAR_ROOM = 30 -- the settings gear below the tabs
local MAX_OVERHANG = 64 -- the most a window's own bits may stick out past its left edge
local MOVE_THRESHOLD = 3 -- a click that moves less than this isn't a drag

-- Left of a window's edge but not its content, so they don't push it away from the tabs.
local CHROME = { "NineSlice", "PortraitContainer", "TitleContainer", "TopTileStreaks", "CloseButton", "Bg" }

-- The Bags window: a grid of Blizzard's own bag slot buttons.
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or (NUM_BAG_SLOTS + (NUM_REAGENTBAG_SLOTS or 0))
local SLOT_SIZE = 37
local SLOT_GAP = 5
local MIN_COLUMNS = 10
local BAGS_TOP = 64 -- title, search box and sort button
local BAGS_SIDE = 12
local BAGS_BOTTOM = 36 -- your money
local BAG_ECHO = 0.3 -- seconds in which Blizzard's bags changing is just following Tome's

-- The bag buttons on the action bar open Tome's bags, in combat too.
local BAG_BUTTONS = { "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot", "CharacterBag2Slot",
	"CharacterBag3Slot", "CharacterReagentBag0Slot" }

local db
local ready = false
local pendingCombat = false
local settingsCategory, lockSetting
local anchor, rail -- the top left corner every window opens at, and the tabs beside it
local spotX, spotY = 0, 0 -- where the anchor is: from the screen's left and top, in UIParent's units
local railTabs = {} -- [tab] = button
local windows = {} -- [panel] = { panel, markers, ours, full, shownAt, left }
local ourFrames = {} -- frames we parent to Blizzard windows; skipped when measuring them
local shownCount = 0 -- counts windows opening, so the newest one can win
local wrappedBagButtons = {}

local bagsFrame -- the Bags window
local bagSlots = {} -- [bag] = { holder, buttons, size }
local bagsDirty = true
local blizzardBags = {} -- [Blizzard's bag window] = the parent it has when it's showing
local bagHolder -- hidden; Blizzard's bag windows wait in here
local bagKeyButton
local bagIntentAt = 0 -- when Tome's bags last opened or closed
local bagFollow = false -- Blizzard's bags changed on their own, so Tome's should follow

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

-- A window showed: the tabs show, and the window goes right beside them at its own size.
-- In combat Tome can't tidy up afterwards, so any other window that's open closes now. A full
-- screen map keeps Blizzard's own spot.
local SHOW = [[
	if self:GetAttribute("tome-full") then
		return
	end
	local anchor, panel = self:GetFrameRef("tome-anchor"), self:GetFrameRef("tome-panel")
	if PlayerInCombat() then
		local header = self:GetFrameRef("tome-header")
		for i = 1, header:GetAttribute("tome-views") do
			local marker = header:GetFrameRef("tome-view" .. i)
			if marker ~= self and marker:IsVisible() then
				local other = marker:GetFrameRef("tome-panel")
				if other ~= panel then
					other:Hide()
				end
			end
		end
	end
	anchor:Show()
	anchor:Raise()
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", anchor, "TOPLEFT", self:GetAttribute("tome-left") or 0, 0)
	panel:Raise()
]]

-- A window closed: the tabs hide too, unless another window is still up.
local HIDE = [[
	local header = self:GetFrameRef("tome-header")
	for i = 1, header:GetAttribute("tome-views") do
		local marker = header:GetFrameRef("tome-view" .. i)
		if marker:IsVisible() and not marker:GetAttribute("tome-full") then
			return
		end
	end
	self:GetFrameRef("tome-anchor"):Hide()
]]

-- A bag button on the action bar opens and closes Tome's bags. Blizzard's own click runs
-- after, so dropping an item on a bag still puts it in.
local BAG_BUTTON_CLICK = [[
	if button == "LeftButton" then
		local bags = owner:GetFrameRef("tome-bags")
		if bags:IsShown() then
			bags:Hide()
		else
			bags:Show()
		end
	end
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

local function VisibleMarker(window)
	for _, marker in ipairs(window.markers) do
		if marker:IsVisible() then
			return marker
		end
	end
end

-- The window beside the tabs: the newest one open.
local function ActiveWindow()
	local active
	for panel, window in pairs(windows) do
		if panel:IsVisible() and not window.full and VisibleMarker(window)
			and (not active or window.shownAt > active.shownAt) then
			active = window
		end
	end
	return active
end

local function Refresh()
	local active = ActiveWindow()
	for tab, button in pairs(railTabs) do
		if tab.key == "character" then
			SetTabIcon(button.Icon, tab)
		end
		button:SetChecked(active ~= nil and IsTabActive(tab, active.panel))
		button.Icon:SetDesaturated(IsTabOff(tab))
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
-- Putting windows beside the tabs

-- The world map can fill the screen. Then it keeps Blizzard's look and spot, without tabs.
local function IsFullScreen(panel)
	return panel == WorldMapFrame and panel.IsMaximized ~= nil and panel:IsMaximized()
end

local function ChromeOf(panel)
	local pieces = {}
	for _, owner in ipairs({ panel, panel.BorderFrame or false }) do
		if owner then
			for _, key in ipairs(CHROME) do
				if type(owner[key]) == "table" then
					pieces[owner[key]] = true
				end
			end
		end
	end
	return pieces
end

-- How far a window's own tabs and buttons stick out past its left edge, in its own units,
-- so they don't cover Tome's tabs. Anything big is the window's content, not a tab.
local function MeasureLeft(window)
	local panel = window.panel
	local left = panel:GetLeft()
	if not left then
		return 0
	end
	local chrome = ChromeOf(panel)
	local scale = panel:GetEffectiveScale()
	local out = 0
	local function consider(frame)
		if ourFrames[frame] or chrome[frame] or not frame:IsVisible() or frame:GetAlpha() == 0 then
			return
		end
		local x, _, w, h = frame:GetRect()
		if not x or w > 150 and h > 150 then
			return
		end
		out = math.max(out, left - x * frame:GetEffectiveScale() / scale)
	end
	for _, child in ipairs({ panel:GetChildren() }) do
		consider(child)
		if not ourFrames[child] and not chrome[child] then
			for _, grandchild in ipairs({ child:GetChildren() }) do
				consider(grandchild)
			end
		end
	end
	return math.min(MAX_OVERHANG, math.ceil(out))
end

-- Blizzard puts its windows back in their own spot whenever it lays them out, in combat too.
-- So each window's layout settings point at the spot beside the tabs, and Blizzard's own
-- layout lands it there as well. This works before a window has ever opened.
local function SyncLayout(window)
	local panel = window.panel
	local name = panel:GetName()
	local defined = panel:GetAttribute("UIPanelLayout-defined")
	if window.ours or not defined and not (name and UIPanelWindows[name]) then
		return -- Blizzard doesn't lay this one out
	end
	local ratio = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local left = spotX + (window.left or 0) * ratio
	local width = panel:GetWidth() * ratio
	local values = {
		xoffset = left - (GetUIPanelLayoutAttribute("LEFT_OFFSET") or 16),
		yoffset = -spotY - (GetUIPanelLayoutAttribute("TOP_OFFSET") or -116),
		centerXOffset = (left + width / 2 - UIParent:GetWidth() / 2) / ratio,
		bottomClampOverride = -10000,
		minYOffset = 0,
	}
	if not defined then
		SetUIPanelAttribute(panel, "xoffset", values.xoffset)
	end
	for key, value in pairs(values) do
		panel:SetAttributeNoHandler("UIPanelLayout-" .. key, value)
	end
end

-- Moving windows is blocked in combat. One that opens mid-fight is placed by its marker's
-- snippet and Blizzard's layout, and everything is checked again once combat ends.
local function Fit(window)
	local marker = VisibleMarker(window)
	if not marker then
		return
	end
	window.left = window.ours and 0 or MeasureLeft(window)
	for _, each in ipairs(window.markers) do
		each:SetAttribute("tome-left", window.left)
	end
	SyncLayout(window)
	marker:Execute(SHOW)
end

-- The map going full screen leaves the tabs, at Blizzard's spot. Shrunk back down, it goes
-- back beside them.
local function UpdateFullScreen(window)
	local full = IsFullScreen(window.panel)
	if full == window.full then
		return
	end
	window.full = full
	for _, marker in ipairs(window.markers) do
		marker:SetAttribute("tome-full", full or nil)
	end
	if full then
		local panel = window.panel
		local point = panel:GetAttribute("UIPanelLayout-maximizePoint")
		if point then
			panel:ClearAllPoints()
			panel:SetPoint(point)
		end
		if window.markers[1] then
			window.markers[1]:Execute(HIDE)
		end
	end
	QueueRefresh()
end

local function PlaceAll()
	if not ready then
		return
	end
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	for panel, window in pairs(windows) do
		UpdateFullScreen(window)
		if window.full then
			-- stays where Blizzard put it
		elseif panel:IsShown() then
			Fit(window)
		else
			SyncLayout(window)
		end
	end
	QueueRefresh()
end

local fitQueued = false
local function QueueFit()
	if not fitQueued then
		fitQueued = true
		C_Timer.After(0, function()
			fitQueued = false
			PlaceAll()
		end)
	end
end

-- Tome is one window, so when one opens the rest close. Closing them is blocked in combat,
-- where the markers close them instead; this catches anything left once combat ends.
local function Tidy()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	local newest
	for panel, window in pairs(windows) do
		if panel:IsShown() and (not newest or window.shownAt > newest.shownAt) then
			newest = window
		end
	end
	for panel, window in pairs(windows) do
		if window ~= newest and panel:IsShown() then
			if window.ours then
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
-- Where the tabs are, and moving them

-- Where Blizzard opens its windows, with the tabs to their left.
local function DefaultSpot()
	local x = GetUIPanelLayoutAttribute("LEFT_OFFSET") or 16
	local y = -(GetUIPanelLayoutAttribute("TOP_OFFSET") or -116)
	return x + (rail and rail:GetWidth() or 0) - RAIL_X, y
end

local function ApplySpot()
	local x, y
	if db.spot then
		x, y = db.spot.x, db.spot.y
	else
		x, y = DefaultSpot()
	end
	local railWidth = rail:GetWidth() - RAIL_X
	local railBottom = RAIL_TOP + rail:GetHeight()
	spotX = math.max(railWidth, math.min(x, UIParent:GetWidth() - 100))
	spotY = math.max(0, math.min(y, UIParent:GetHeight() - railBottom))
	anchor:ClearAllPoints()
	anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", spotX, -spotY)
end

local function SaveSpot()
	db.spot = {
		point = "TOPLEFT",
		x = math.floor(anchor:GetLeft() + 0.5),
		y = math.floor(UIParent:GetHeight() - anchor:GetTop() + 0.5),
	}
end

local function CursorPosition()
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	return x / scale, y / scale
end

-- Moving follows the cursor by hand rather than with StartMoving, so the game doesn't save
-- the tabs' spot in its own layout cache.
local mover = CreateFrame("Frame")
local moving
local movedAt = 0 -- letting go of a drag on the gear isn't a click on it

local function StopMove()
	if not moving then
		return
	end
	local moved = moving.moved
	moving = nil
	mover:SetScript("OnUpdate", nil)
	if moved then
		movedAt = GetTime()
	end
	if moved and not InCombatLockdown() then
		SaveSpot()
		ApplySpot()
		PlaceAll()
	end
end

-- `loud` says why it can't move. Clicking a window's empty space in combat stays quiet.
local function StartMove(loud)
	if InCombatLockdown() then
		if loud then
			UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.1, 0.1)
		end
		return
	end
	if db.locked or not anchor:IsShown() or not anchor:GetLeft() then
		return
	end
	PlaceAll() -- the open window follows the tabs
	local startX, startY = CursorPosition()
	moving = { x = anchor:GetLeft() - startX, y = anchor:GetTop() - startY, moved = false }
	mover:SetScript("OnUpdate", function()
		if InCombatLockdown() or not IsMouseButtonDown("LeftButton") then
			StopMove()
			return
		end
		local x, y = CursorPosition()
		if not moving.moved and math.abs(x - startX) < MOVE_THRESHOLD and math.abs(y - startY) < MOVE_THRESHOLD then
			return
		end
		moving.moved = true
		anchor:ClearAllPoints()
		anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + moving.x, y + moving.y)
	end)
end

-- Every window drags by its empty space, like BlizzMove does.
local function MakeDraggable(frame)
	frame:HookScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then
			StartMove(false)
		end
	end)
	frame:HookScript("OnMouseUp", StopMove)
end

local function SetLocked(locked)
	if lockSetting then
		lockSetting:SetValue(locked)
	else
		db.locked = locked
	end
end

local function ResetSpot()
	if InCombatLockdown() then
		UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.1, 0.1)
		return
	end
	db.spot = nil
	ApplySpot()
	PlaceAll()
end

local function OpenSettingsMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Tome")
		root:CreateCheckbox("Lock position", function()
			return db.locked
		end, function()
			SetLocked(not db.locked)
		end)
		root:CreateButton("Reset position", ResetSpot)
	end)
end

-- Explicitly protected, so the markers' snippets can show it, hide it and put Blizzard's
-- windows beside it in combat. It's a dot at the windows' top left corner.
local function CreateAnchor()
	anchor = CreateFrame("Frame", "TomeAnchor", UIParent, "SecureFrameTemplate")
	anchor:Hide()
	anchor:SetSize(1, 1)
	anchor:SetFrameStrata("MEDIUM")
	anchor:SetClampedToScreen(true)
end

----------------------------------------------------------------------------------------------
-- Tabs

local function SetupTabAction(button, tab)
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("type", "macro")
	button:SetAttribute("tome-key", tab.key)
	button:SetAttribute("tome-family", tab.family or tab.key)
	button:SetAttribute("tome-open", MicroButtonFor(tab))
	header:WrapScript(button, "OnClick", TAB_CLICK)
end

-- Blizzard's side tab art faces right. Tome's tabs are on the left, so it's flipped.
local function MirrorTexture(texture)
	local atlas = texture:GetAtlas()
	local info = atlas and C_Texture.GetAtlasInfo(atlas)
	if not info then
		return
	end
	local width, height = texture:GetSize()
	texture:SetTexture(info.file or info.filename)
	texture:SetTexCoord(info.rightTexCoord, info.leftTexCoord, info.topTexCoord, info.bottomTexCoord)
	texture:SetSize(width, height)
end

-- The icon moves to the flipped tab's middle. Its mask can't be flipped, so it moves with
-- the icon instead and the icon keeps Blizzard's exact shape.
local function CreateRailTab(parent, tab)
	local button = CreateFrame("Button", nil, parent, "LargeSideTabButtonTemplate, SecureActionButtonTemplate")
	for _, key in ipairs({ "Background", "SelectedTexture", "TabGlow", "HighlightTexture" }) do
		if button[key] then
			pcall(MirrorTexture, button[key])
		end
	end
	local x = -button:GetIconAnchorOffsetsForTabArt()
	function button:GetFinalIconAnchorOffsets()
		return x, 0
	end
	button:InitializeIconAnchoring()
	if button.Mask then
		button.Mask:ClearAllPoints()
		button.Mask:SetPoint("CENTER", button.Icon, "CENTER", x, 0)
	end
	SetTabIcon(button.Icon, tab)
	button:SetFillToInterior(true)
	button:SetChecked(false)
	SetupTabAction(button, tab)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT", 4, -4)
		SetTabTooltip(GameTooltip, tab)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	return button
end

local function CreateGearButton(parent)
	local gear = CreateFrame("Button", nil, parent)
	gear:SetSize(24, 24)
	gear:SetNormalAtlas("questlog-icon-setting")
	gear:SetHighlightAtlas("questlog-icon-setting", "ADD")
	gear:RegisterForDrag("LeftButton")
	gear:SetScript("OnClick", function(self)
		if not moving and GetTime() - movedAt > 0.2 then
			OpenSettingsMenu(self)
		end
	end)
	gear:SetScript("OnDragStart", function()
		StartMove(true)
	end)
	gear:SetScript("OnDragStop", StopMove)
	gear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Tome")
		GameTooltip:AddLine("Click for settings. Drag to move the tabs.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	gear:SetScript("OnLeave", GameTooltip_Hide)
	return gear
end

-- Down the left of whichever window is open, always in the same spot.
local function CreateRail()
	rail = CreateFrame("Frame", nil, anchor)
	local height, width, previous = 0, 0, nil
	for _, tab in ipairs(TABS) do
		if tab.available then
			local button = CreateRailTab(rail, tab)
			if previous then
				button:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT")
			else
				button:SetPoint("TOPRIGHT")
			end
			height = height + button:GetHeight()
			width = button:GetWidth()
			railTabs[tab] = button
			previous = button
		end
	end
	CreateGearButton(rail):SetPoint("TOP", previous, "BOTTOM", 3, -6)
	rail:SetSize(width, height + GEAR_ROOM)
	rail:SetPoint("TOPRIGHT", anchor, "TOPLEFT", RAIL_X, -RAIL_TOP)
	-- The tabs stay on screen, and so does a bit of the window.
	anchor:SetClampRectInsets(-(width - RAIL_X), -100, 0, -(RAIL_TOP + height + GEAR_ROOM))
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

	-- Blizzard's bags open and close with Tome's, out of sight, so the game and other addons
	-- know your bags are open. In combat they catch up once it ends.
	frame:HookScript("OnShow", function()
		bagIntentAt = GetTime()
		PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)
		if InCombatLockdown() then
			pendingCombat = true
		else
			OpenAllBags()
		end
		UpdateBags()
	end)
	frame:HookScript("OnHide", function()
		bagIntentAt = GetTime()
		PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE)
		if InCombatLockdown() then
			pendingCombat = true
		elseif IsAnyBagOpen() then
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

-- Ours wait in the holder. The bank's go back where Blizzard had them.
local function PlaceBagWindow(frame)
	local parent = frame:GetParent()
	if parent ~= bagHolder then
		blizzardBags[frame] = parent -- Blizzard moves them for full-screen views
	end
	local wanted = IsOurBag(frame) and bagHolder or blizzardBags[frame]
	if parent ~= wanted and not (InCombatLockdown() and frame:IsProtected()) then
		if FrameUtil and FrameUtil.SetParentMaintainRenderLayering then
			FrameUtil.SetParentMaintainRenderLayering(frame, wanted)
		else
			frame:SetParent(wanted)
		end
	end
end

local function AnyBlizzardBagOpen()
	for frame in pairs(blizzardBags) do
		if frame:IsShown() and IsOurBag(frame) then
			return true
		end
	end
	return false
end

-- Whichever changed last wins. Blizzard's bags opening or closing on their own (a vendor, the
-- mailbox) opens or closes Tome's. Tome's can't open or close outside a snippet in combat, so
-- that waits until combat ends.
local function SyncBags()
	local open = AnyBlizzardBagOpen()
	if bagFollow then
		if InCombatLockdown() then
			pendingCombat = true
		else
			bagFollow = false
			if open ~= bagsFrame:IsShown() then
				bagsFrame:SetShown(open)
			end
		end
	elseif bagsFrame:IsShown() ~= open then
		if InCombatLockdown() then
			pendingCombat = true
		elseif bagsFrame:IsShown() then
			OpenAllBags()
		else
			CloseAllBags()
		end
	end
	for frame in pairs(blizzardBags) do
		PlaceBagWindow(frame)
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

local function OnBagWindowChanged()
	if GetTime() - bagIntentAt > BAG_ECHO then
		bagFollow = true
	end
	QueueBagSync()
end

-- Blizzard reuses its bag windows for the bank too, so each one is moved the moment it
-- shows, before it's drawn.
local function OnBagWindowShown(frame)
	PlaceBagWindow(frame)
	OnBagWindowChanged()
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
		hooksecurefunc(frame, "Hide", OnBagWindowChanged)
		hooksecurefunc(frame, "SetShown", function(self, shown)
			if shown then
				OnBagWindowShown(self)
			else
				OnBagWindowChanged()
			end
		end)
	end
	for _, name in ipairs({ "ContainerFrame_SetFullScreenFrame", "ContainerFrame_ClearFullScreenFrame" }) do
		if _G[name] then
			hooksecurefunc(name, QueueBagSync)
		end
	end
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

-- A wrapped click only runs its snippet in combat if the button is protected, so each bag
-- button gets a small protected child, which makes it protected too.
local function WrapBagButtons()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end
	for _, name in ipairs(BAG_BUTTONS) do
		local button = _G[name]
		if button and not wrappedBagButtons[button] and button:GetScript("OnClick") then
			wrappedBagButtons[button] = true
			local lock = CreateFrame("Frame", nil, button, "SecureFrameTemplate")
			lock:SetSize(1, 1)
			lock:SetPoint("CENTER")
			header:WrapScript(button, "OnClick", BAG_BUTTON_CLICK)
		end
	end
end

----------------------------------------------------------------------------------------------
-- Blizzard's windows

-- A marker is a small protected frame inside a window, so snippets can tell it's open and
-- put it beside the tabs when it shows.
local function AddView(tab, parent, closer, window)
	local marker = CreateFrame("Frame", nil, parent, "SecureHandlerShowHideTemplate")
	marker:SetSize(1, 1)
	marker:SetPoint("TOPLEFT")
	marker:SetFrameRef("tome-header", header)
	marker:SetFrameRef("tome-anchor", anchor)
	marker:SetFrameRef("tome-panel", window.panel)
	marker:SetAttribute("_onshow", SHOW)
	marker:SetAttribute("_onhide", HIDE)
	marker:HookScript("OnShow", QueueRefresh)
	marker:HookScript("OnHide", QueueRefresh)
	ourFrames[marker] = true
	window.markers[#window.markers + 1] = marker

	local count = header:GetAttribute("tome-views") + 1
	local view = "tome-view" .. count
	header:SetFrameRef(view, marker)
	header:SetAttribute(view .. "-key", tab.key)
	header:SetAttribute(view .. "-family", tab.family or tab.key)
	header:SetAttribute(view .. "-close", closer)
	header:SetAttribute("tome-views", count) -- last, so a snippet never sees half a view
end

local function MarkShown(window)
	shownCount = shownCount + 1
	window.shownAt = shownCount
	QueueTidy()
end

local function Attach(panelName)
	local panel = _G[panelName]
	if not panel or windows[panel] then
		return
	end
	local window = { panel = panel, markers = {}, ours = panel == bagsFrame, full = false, shownAt = 0, left = 0 }
	windows[panel] = window

	for _, tab in ipairs(TABS) do
		if tab.available and tab.frames and tContains(tab.frames, panelName) then
			local closer = CloserFor(panel, tab)
			if tab.views then
				for _, key in ipairs(tab.views) do
					if panel[key] then
						AddView(tab, panel[key], closer, window)
					end
				end
			else
				AddView(tab, panel, closer, window)
			end
		end
	end

	MakeDraggable(panel)
	if panel.BorderFrame then
		MakeDraggable(panel.BorderFrame)
	end

	-- Blizzard's own tabs settle a frame after the window shows, and the Spellbook changes
	-- width when it switches between its small and full views.
	panel:HookScript("OnShow", function()
		MarkShown(window)
		QueueRefresh()
		QueueFit()
	end)
	panel:HookScript("OnHide", QueueRefresh)
	panel:HookScript("OnSizeChanged", QueueFit)
	SyncLayout(window)
	if panel:IsShown() then
		MarkShown(window) -- a window that loads the first time it opens is already up
		PlaceAll()
	end
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
	lockSetting = Settings.RegisterAddOnSetting(settingsCategory, "TOME_LOCKED", "locked", db,
		Settings.VarType.Boolean, "Lock position", false)
	Settings.CreateCheckbox(settingsCategory, lockSetting, "Stops Tome's tabs and windows from being moved.")
	Settings.RegisterAddOnCategory(settingsCategory)
end

SLASH_TOME1 = "/tome"
SlashCmdList.TOME = function(message)
	message = strtrim(message or ""):lower()
	if message == "lock" then
		SetLocked(true)
	elseif message == "unlock" then
		SetLocked(false)
	elseif message == "reset" then
		ResetSpot()
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

	CreateAnchor()
	CreateBagsWindow() -- before the tabs, since the Bags tab presses its open button
	header:SetFrameRef("tome-bags", bagsFrame)

	-- A micro button the game leaves off the menu bar (for a feature switched off in this
	-- game mode) still exists, but the menu bar never gave it a layoutIndex.
	for _, tab in ipairs(TABS) do
		local button = MicroButtonFor(tab)
		tab.available = button ~= nil and (tab.key == "bags" or _G[button].layoutIndex ~= nil)
		if tab.available then
			header:SetAttribute("tome-open-" .. tab.key, button)
		end
	end
	if db.last and header:GetAttribute("tome-open-" .. db.last) then
		header:SetAttribute("tome-last", db.last)
	end

	CreateRail()
	ApplySpot()

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
		"MaximizeUIPanel", "RestoreUIPanelArea" }) do
		if _G[name] then
			hooksecurefunc(name, PlaceAll)
		end
	end

	ready = true
	AttachAll()
	WrapBagButtons()
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
			db.position, db.width, db.height, db.devlog = nil, nil, nil, nil -- from older versions
			local spot = db.spot
			if type(spot) ~= "table" or spot.point ~= "TOPLEFT" or type(spot.x) ~= "number" or type(spot.y) ~= "number" then
				db.spot = nil
			end
			db.locked = db.locked == true
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
			WrapBagButtons()
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
		if ready and not InCombatLockdown() then
			ApplySpot()
			PlaceAll()
		elseif ready then
			pendingCombat = true
		end
	elseif event == "PLAYER_LOGOUT" then
		db.last = header:GetAttribute("tome-last")
	end
end)
