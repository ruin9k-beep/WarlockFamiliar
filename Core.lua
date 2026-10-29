--[[
  WarlockFamiliar - core (vanilla 1.12 / Lua 5.0)

  The core owns everything shared between modules:
    * module registry + lifecycle (a module only runs for a Warlock whose
      level meets the module's minLevel and which has not been disabled)
    * one event frame and one update frame that dispatch to running modules
    * ONE main window: a row of module buttons at the top, and below it the
      content of the selected module. Only one module is shown at a time;
      clicking a module button swaps the content inside the same window.
      While you are in combat the window collapses to the module buttons and
      status icons, and expands again when combat ends (unless you had
      collapsed it yourself). This is an option (cog button, default on).
      A second option hides the whole window in combat instead (default off).
    * an Options panel (cog button, bottom-right) that exposes every text
      command as a control
    * helpers: buttons, tooltips, bag scanning, spellbook lookup
    * the /wf slash command

  Writing a module (see Modules\*.lua for real examples):

    local WF = WarlockFamiliar
    local M = WF:RegisterModule("key", {
      title    = "My Module",   -- full name, used in chat messages
      short    = "Mine",        -- label of the module button
      minLevel = 1,             -- module stays off below this level
      events   = { "BAG_UPDATE" },  -- events delivered to M:OnEvent
      interval = 1,             -- seconds between M:OnUpdate calls (minimum 1)
    })
    function M:OnLoad()
      -- build the UI once. This returns the module's CONTENT frame (a child
      -- of the main window, below the module buttons); position widgets
      -- relative to its top-left corner. The width is fixed by the core.
      local f = WF:CreateWindow(self, 0, 100)   -- (mod, ignored, height)
      ...
    end
    function M:OnEnable() ... end
    function M:OnDisable() ... end
    function M:OnEvent(event, a1, a2, a3) ... end
    function M:OnUpdate() ... end           -- self.frame:IsVisible() is true
                                            -- only while this module is shown
    function M:OnSlash(args) ... end        -- /wf key <args>
    function M:OptionsTabs()
        -- optional: adds tabs to the Options panel. Return a list of
        -- { name = "Tab", build = function(page, y) ... return y end }.
        -- Inside build use WF:AddCheck / AddButton / AddEditBox / AddHeading
        -- and return the new y (pixels from the top of the page).
        -- (A module may instead define a single M:OptionsBuild(page, y).)

    -- if the content height changes later, call:
    WF:SetModuleHeight(self, newHeight)

    -- API monitoring (buff / bag / spell scans) is rate limited: use
    -- WF:Due(owner, key, seconds) and cache the results. Time-critical data
    -- (buffs) at most once a second, the rest at most once every two seconds.

    -- to keep the window from collapsing for a combat that should not count
    -- (it ends with the combat, or after the given seconds):
    WF:SetCombatExempt(seconds)

    -- status icons sit in a row under the module buttons and stay visible
    -- even when the window is collapsed: a small icon with short text next to it, the
    -- text green when "active" and red when not. A module creates one in
    -- OnLoad and drives it:
    local ind = WF:CreateStatusIcon("key")
    WF:SetStatusIconShown(ind, true)
    ind:Set(isActive, "DA", iconTexture, "tooltip text")
    ind.onClick = function(mouse) ... end   -- optional; mouse = "LeftButton" / "RightButton"

  Then add the file to WarlockFamiliar.toc.
]]

WarlockFamiliar = { modules = {}, order = {}, version = "1.0" }
local WF = WarlockFamiliar

local evRef = {}
local announced = false

local MAIN_W = 300    -- width of the main window
local HEADER_H = 62   -- module buttons (with the close/collapse buttons) + status icon row, above the module content
local COLLAPSED_PAD = 4  -- extra height under the header when collapsed
local ICON_H = 18         -- height of the status icon row
local SLOT_W = 62         -- width of one status icon slot
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
-- the Engineering profession icon (a cog); it ships with every 1.12 client
local OPTIONS_ICON = "Interface\\Icons\\Trade_Engineering"
local headerH = HEADER_H  -- header height (fixed)

----------------------------------------------------------------------
-- small utilities
----------------------------------------------------------------------
function WF:Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff9370dbWarlockFamiliar:|r " .. msg)
end

function WF.FormatTime(sec)
  if not sec or sec <= 0 then return "0s" end
  sec = math.floor(sec + 0.5)
  if sec >= 3600 then
    local h = math.floor(sec / 3600)
    local m = math.floor((sec - h * 3600) / 60)
    return h .. "h " .. m .. "m"
  elseif sec >= 60 then
    local m = math.floor(sec / 60)
    local s = sec - m * 60
    return m .. "m " .. s .. "s"
  end
  return sec .. "s"
end

function WF.ItemIdFromLink(link)
  local _, _, id = string.find(link, "item:(%d+)")
  return tonumber(id)
end

function WF.ItemNameFromLink(link)
  local _, _, name = string.find(link, "%[(.-)%]")
  return name
end

-- fn(bag, slot, link, count) is called for every item in the player's bags
function WF:ForEachBagItem(fn)
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local _, count = GetContainerItemInfo(bag, slot)
        fn(bag, slot, link, count or 1)
      end
    end
  end
end

-- Rate limiter. Returns true at most once per `seconds` for a given
-- owner/key (and records the time); otherwise false.
--   if WF:Due(self, "tBags", 2) then ...scan the bags... end
function WF:Due(owner, key, seconds)
  local now = GetTime()
  local last = owner[key]
  if last and (now - last) < seconds then return false end
  owner[key] = now
  return true
end

-- counts several items in ONE pass over the bags: { [itemId] = count }
function WF:CountItemIds(ids)
  local counts = {}
  for i = 1, table.getn(ids) do counts[ids[i]] = 0 end
  self:ForEachBagItem(function(bag, slot, link, count)
    local id = WF.ItemIdFromLink(link)
    if id and counts[id] then counts[id] = counts[id] + count end
  end)
  return counts
end

function WF:CountItemId(id)
  local total = 0
  self:ForEachBagItem(function(bag, slot, link, count)
    if WF.ItemIdFromLink(link) == id then
      total = total + count
    end
  end)
  return total
end

----------------------------------------------------------------------
-- spellbook lookup (cached, invalidated when the spellbook changes)
----------------------------------------------------------------------
local spellList = nil   -- array of spell names, index = spellbook index
local spellIndex = nil  -- name -> highest spellbook index

local function BuildSpells()
  spellList = {}
  spellIndex = {}
  local i = 1
  while true do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    spellList[i] = name
    spellIndex[name] = i
    i = i + 1
  end
end

function WF:InvalidateSpells()
  spellList = nil
  spellIndex = nil
end

function WF:GetSpellIndex(name)
  if not spellIndex then BuildSpells() end
  return spellIndex[name]
end

-- returns an array of every spellbook spell name that starts with prefix,
-- in spellbook order. Choosing between matches is the caller's job.
function WF:FindSpellsByPrefix(prefix)
  if not spellList then BuildSpells() end
  local len = string.len(prefix)
  local matches = {}
  for i = 1, table.getn(spellList) do
    local n = spellList[i]
    if string.sub(n, 1, len) == prefix then
      table.insert(matches, n)
    end
  end
  return matches
end

function WF:GetSpellCooldownLeft(name)
  local idx = self:GetSpellIndex(name)
  if not idx then return 0 end
  local start, duration = GetSpellCooldown(idx, BOOKTYPE_SPELL)
  if start and start > 0 and duration and duration > 1.5 then
    local left = start + duration - GetTime()
    if left > 0 then return left end
  end
  return 0
end

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------
local function SavePosition(frame, key)
  WF.db.pos[key] = { x = frame:GetLeft(), y = frame:GetTop() }
end

local function RestorePosition(frame, key)
  local p = WF.db and WF.db.pos[key]
  if p and p.x and p.y then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
  end
end

function WF:CreateButton(parent, label, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(height)
  b:SetText(label)
  return b
end

function WF:SetTooltip(frame, text)
  frame.tooltipText = text
  frame:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(this.tooltipText, 1, 1, 1, 1, 1)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
end

----------------------------------------------------------------------
-- main window
----------------------------------------------------------------------
function WF:BuildMain()
  local f = CreateFrame("Frame", "WarlockFamiliarFrame", UIParent)
  f:SetWidth(MAIN_W)
  f:SetHeight(HEADER_H + 60)
  f:SetPoint("CENTER", UIParent, "CENTER", -250, 60)
  f:SetFrameStrata("MEDIUM")
  -- background only, no border
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    tile = true, tileSize = 32,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
  })
  -- the fixed header (module buttons + status icons) gets its own darker,
  -- tinted panel so it reads as separate from the content below it
  local head = f:CreateTexture(nil, "BORDER")
  head:SetTexture(0.16, 0.08, 0.24, 0.95)
  head:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  head:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  head:SetHeight(HEADER_H)

  -- bright top edge and a divider line along the bottom of the header
  local topEdge = f:CreateTexture(nil, "ARTWORK")
  topEdge:SetTexture(0.62, 0.35, 0.85, 0.9)
  topEdge:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  topEdge:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  topEdge:SetHeight(2)

  local divider = f:CreateTexture(nil, "ARTWORK")
  divider:SetTexture(0.62, 0.35, 0.85, 0.9)
  divider:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER_H)
  divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -HEADER_H)
  divider:SetHeight(2)

  -- a soft dark shadow just under the divider
  local shade = f:CreateTexture(nil, "ARTWORK")
  shade:SetTexture(0, 0, 0, 0.35)
  shade:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER_H - 2)
  shade:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -HEADER_H - 2)
  shade:SetHeight(3)

  -- thin border around the whole window (follows the frame as it resizes)
  local function Edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetTexture(0.62, 0.35, 0.85, 0.9)
    t:SetPoint(p1, f, p1, 0, 0)
    t:SetPoint(p2, f, p2, 0, 0)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
  end
  Edge("TOPLEFT", "TOPRIGHT", nil, 1)
  Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
  Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
  Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)

  f.head, f.divider, f.shade = head, divider, shade

  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() this:StartMoving() end)
  f:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    SavePosition(this, "main")
  end)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() WF:SetMainShown(false) end)

  -- collapse / expand button, just left of the close button
  local collapse = CreateFrame("Button", nil, f)
  collapse:SetWidth(20)
  collapse:SetHeight(20)
  collapse:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -12)
  collapse:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
  collapse:SetScript("OnClick", function()
    if WF:CombatLocked() then return end   -- the window is held collapsed in combat
    WF:SetCollapsed(not WF.db.collapsed)
  end)
  WF:SetTooltip(collapse, "Collapse")
  f.collapse = collapse

  -- options button (a cog icon): right end of the status icon row, in the
  -- fixed header, so it stays put when the window expands or collapses
  local optBtn = CreateFrame("Button", nil, f)
  optBtn:SetWidth(20)
  optBtn:SetHeight(20)
  optBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -37)
  optBtn:SetNormalTexture(OPTIONS_ICON)
  optBtn:SetPushedTexture(OPTIONS_ICON)
  optBtn:GetPushedTexture():SetVertexColor(0.6, 0.6, 0.6)
  optBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  optBtn:SetScript("OnClick", function() WF:ToggleOptions() end)
  WF:SetTooltip(optBtn, "Options")
  f.optBtn = optBtn

  f.tabs = {}   -- module key -> module button
  RestorePosition(f, "main")
  f:Hide()
  self.main = f
  self.statusIcons = {}
  self:UpdateCollapseButton()
end

-- minus = click to collapse, plus = click to expand
-- true while in combat AND the "collapse in combat" option is on (default on),
-- unless a module has exempted this combat (see WF:SetCombatExempt)
function WF:CombatLocked()
  return self:CombatActive() and self.db.combatCollapse ~= false
end

-- true while in combat and no module has exempted this combat
-- (see WF:SetCombatExempt)
function WF:CombatActive()
  if not self.inCombat then return false end
  if self.exemptUntil and GetTime() < self.exemptUntil then return false end
  return true
end

-- true while the whole window is hidden by the "hide in combat" option
-- (default off)
function WF:CombatHidden()
  return self:CombatActive() and self.db.combatHide == true
end

-- A module calls this when the combat you are in (or about to be in) should
-- NOT collapse the window, e.g. the brief combat from sacrificing your own
-- demon. The exemption ends when combat ends or after `seconds`, whichever
-- comes first.
function WF:SetCombatExempt(seconds)
  self.exemptUntil = GetTime() + seconds
  if self.inCombat then self:RefreshCombat() end
end

-- collapsed by the user's choice, or automatically while in combat
function WF:IsCollapsed()
  return self.db.collapsed or self:CombatLocked()
end

function WF:UpdateCollapseButton()
  local b = self.main and self.main.collapse
  if not b then return end
  if self:IsCollapsed() then
    b:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
    if self:CombatLocked() then
      b.tooltipText = "Collapsed during combat"
    else
      b.tooltipText = "Expand"
    end
  else
    b:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
    b.tooltipText = "Collapse to the module bar"
  end
end

-- collapsed: only the module buttons are shown
-- re-applies the effective collapsed state (used when combat starts/ends)
-- re-applies everything combat can change: collapsed state and visibility
function WF:RefreshCombat()
  self:RefreshCollapse()
  self:ApplyMainVisibility()
end

function WF:RefreshCollapse()
  self:UpdateCollapseButton()
  if self.activeMod then
    self:SelectModule(self.activeMod)   -- re-applies content visibility and size
  else
    self:ResizeMain()
  end
end

function WF:SetCollapsed(collapsed)
  self.db.collapsed = collapsed
  self.optReturnCollapsed = nil
  self:UpdateCollapseButton()
  if self.activeMod then
    self:SelectModule(self.activeMod)   -- re-applies content visibility and size
  else
    self:ResizeMain()
  end
end

-- Creates the content frame of a module inside the main window.
-- (width is ignored: every module uses the main window's width)
function WF:CreateWindow(mod, width, height)
  local f = CreateFrame("Frame", "WarlockFamiliar" .. mod.key .. "Frame", self.main)
  f:SetWidth(MAIN_W)
  f:SetHeight(height)
  f:SetPoint("TOPLEFT", self.main, "TOPLEFT", 0, -headerH)
  f:Hide()
  mod.frame = f
  return f
end

function WF:ResizeMain()
  if not self.main then return end
  local m = self.main
  if self:IsCollapsed() then
    -- collapsed: the header fills the window, so no divider (the outer
    -- border is the only bottom edge)
    m.head:SetHeight(headerH + COLLAPSED_PAD)
    m.divider:Hide()
    m.shade:Hide()
    m:SetHeight(headerH + COLLAPSED_PAD)
    return
  end
  m.head:SetHeight(HEADER_H)
  m.divider:Show()
  m.shade:Show()
  local mod = self.activeMod
  if mod and mod.frame then
    self.main:SetHeight(headerH + mod.frame:GetHeight())
  end
end

----------------------------------------------------------------------
-- status icons (header of the main window)
----------------------------------------------------------------------
local function IconSet(ind, active, text, tex, tip)
  ind.icon:SetTexture(tex or UNKNOWN_ICON)
  ind.text:SetText(text or "")
  if active then
    ind.text:SetTextColor(0.25, 1, 0.25)   -- green
  else
    ind.text:SetTextColor(1, 0.25, 0.25)   -- red
  end
  ind.holder.tooltipText = tip or text or ind.key
end

-- Creates a status icon (hidden until WF:SetStatusIconShown). Update it with
-- ind:Set(active, text, iconTexture, tooltip)
function WF:CreateStatusIcon(key)
  -- a Button so the icon and its text can be clicked (left and right)
  local holder = CreateFrame("Button", nil, self.main)
  holder:SetWidth(SLOT_W)
  holder:SetHeight(ICON_H)
  holder:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  holder:Hide()

  local icon = holder:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(ICON_H - 2)
  icon:SetHeight(ICON_H - 2)
  icon:SetPoint("LEFT", holder, "LEFT", 4, 0)

  local text = holder:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  text:SetPoint("LEFT", icon, "RIGHT", 4, 0)

  WF:SetTooltip(holder, key)

  local ind = { key = key, holder = holder, icon = icon, text = text, shown = false, Set = IconSet }
  holder.ind = ind
  holder:SetScript("OnClick", function()
    local i = this.ind
    -- ind.onClick(mouseButton) is set by the module that owns the icon
    if i and i.onClick then i.onClick(arg1) end
  end)
  table.insert(self.statusIcons, ind)
  return ind
end

function WF:SetStatusIconShown(ind, shown)
  if ind.shown == shown then return end
  ind.shown = shown
  if shown then ind.holder:Show() else ind.holder:Hide() end
  self:LayoutHeader()
end

-- lays the visible status icons out in one row directly under the module
-- buttons
function WF:LayoutHeader()
  local main = self.main
  if not main then return end

  local n = 0
  for i = 1, table.getn(self.statusIcons) do
    local ind = self.statusIcons[i]
    if ind.shown then
      ind.holder:ClearAllPoints()
      ind.holder:SetPoint("TOPLEFT", main, "TOPLEFT", 12 + n * SLOT_W, -38)
      n = n + 1
    end
  end
end

-- changes a module's content height (and the window's, if it is shown)
function WF:SetModuleHeight(mod, height)
  if not mod.frame then return end
  mod.frame:SetHeight(height)
  if self.activeMod == mod then self:ResizeMain() end
end

-- swaps the window content to `mod` (does not change whether the window
-- itself is open). Only one module's content is shown at a time.
function WF:SelectModule(mod)
  if not self.main then return end

  for i = 1, table.getn(self.order) do
    local m = self.modules[self.order[i]]
    if m.frame then
      if m == mod and not self:IsCollapsed() then m.frame:Show() else m.frame:Hide() end
    end
  end

  -- the options panel is a content frame owned by the core
  local opt = self.optionsMod
  if opt and opt.frame then
    if mod == opt and not self:IsCollapsed() then opt.frame:Show() else opt.frame:Hide() end
  end

  self.activeMod = mod
  if mod ~= opt then
    self.db.active = mod.key
    self.optReturnCollapsed = nil
  end

  for key, btn in pairs(self.main.tabs) do
    if key == mod.key then btn:LockHighlight() else btn:UnlockHighlight() end
  end

  if self.main.optBtn then
    if mod == opt then self.main.optBtn:LockHighlight() else self.main.optBtn:UnlockHighlight() end
  end

  self:ResizeMain()
end

----------------------------------------------------------------------
-- options panel (content of the main window, opened by the cog button)
-- It exposes every text command as a control. Modules add their own
-- section by defining  M:OptionsBuild(parent, y)  which returns the new y.
----------------------------------------------------------------------
local optCount = 0

function WF:AddHeading(parent, y, text)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -y)
  fs:SetText(text)
  return y + 22
end

-- check box; get() returns its state, set(on) applies a change
function WF:AddCheck(parent, y, label, get, set)
  optCount = optCount + 1
  local name = "WarlockFamiliarOptCheck" .. optCount
  local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  cb:SetWidth(24)
  cb:SetHeight(24)
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -y)
  getglobal(name .. "Text"):SetText(label)
  cb.get = get
  cb:SetScript("OnClick", function()
    set(this:GetChecked() ~= nil)
    WF:RefreshOptions()
  end)
  table.insert(self.optChecks, cb)
  return y + 24
end

function WF:AddButton(parent, x, y, width, label, onClick)
  local b = self:CreateButton(parent, label, width, 22)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  b:SetScript("OnClick", onClick)
  return b
end

function WF:AddEditBox(parent, x, y, width)
  optCount = optCount + 1
  local eb = CreateFrame("EditBox", "WarlockFamiliarOptEdit" .. optCount, parent, "InputBoxTemplate")
  eb:SetWidth(width)
  eb:SetHeight(20)
  eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(60)
  eb:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  eb:SetScript("OnEnterPressed", function() this:ClearFocus() end)
  return eb
end

function WF:RefreshOptions()
  if not self.optChecks then return end
  for i = 1, table.getn(self.optChecks) do
    local cb = self.optChecks[i]
    if cb.get() then cb:SetChecked(1) else cb:SetChecked(nil) end
  end
end

local OPT_TAB_H = 28   -- height of the options tab row

-- shows one options tab (page) and sizes the window to it
function WF:SelectOptionsTab(index)
  local tabs = self.optTabs
  local sel = tabs and tabs[index]
  if not sel then return end

  for i = 1, table.getn(tabs) do
    if i == index then
      tabs[i].page:Show()
      tabs[i].btn:LockHighlight()
    else
      tabs[i].page:Hide()
      tabs[i].btn:UnlockHighlight()
    end
  end

  self.db.optTab = sel.name
  self.optionsMod.frame:SetHeight(OPT_TAB_H + sel.page:GetHeight())
  if self.activeMod == self.optionsMod then self:ResizeMain() end
end

function WF:BuildOptions()
  if self.optionsMod then return end

  local f = CreateFrame("Frame", "WarlockFamiliarOptionsFrame", self.main)
  f:SetWidth(MAIN_W)
  f:SetPoint("TOPLEFT", self.main, "TOPLEFT", 0, -headerH)
  f:Hide()

  self.optionsMod = { key = "options", title = "Options", running = true, frame = f }
  self.optChecks = {}
  self.optTabs = {}

  -- one tab = one page; build(page, y) fills the page and returns the new y
  local function AddTab(name, build)
    local page = CreateFrame("Frame", nil, f)
    page:SetWidth(MAIN_W)
    page:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -OPT_TAB_H)
    local y = build(page, 6)
    page:SetHeight(y + 30)
    page:Hide()

    local index = table.getn(WF.optTabs) + 1
    local btn = WF:CreateButton(f, name, 60, 20)
    btn:SetScript("OnClick", function() WF:SelectOptionsTab(index) end)
    table.insert(WF.optTabs, { name = name, page = page, btn = btn })
  end

  -- General: window behaviour (/wf show, hide, help) and the module switches
  -- (/wf enable <module> | /wf disable <module>)
  AddTab("General", function(page, y)
    y = WF:AddHeading(page, y, "Window")
    y = WF:AddCheck(page, y, "Collapse in combat",
      function() return WF.db.combatCollapse ~= false end,
      function(on)
        WF.db.combatCollapse = on
        WF:RefreshCombat()
      end)
    y = WF:AddCheck(page, y, "Hide the window in combat",
      function() return WF.db.combatHide == true end,
      function(on)
        WF.db.combatHide = on
        WF:RefreshCombat()
      end)
    y = WF:AddCheck(page, y, "Hide the window on login",
      function() return WF.db.hideOnLogin == true end,
      function(on) WF.db.hideOnLogin = on end)
    WF:AddButton(page, 18, y + 2, 116, "Hide window", function() WF:SetMainShown(false) end)
    WF:AddButton(page, 140, y + 2, 116, "Help in chat", function() WF:PrintHelp() end)
    y = y + 30
    local note = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -y)
    note:SetText("Reopen a hidden window with /wf")
    y = y + 22

    y = WF:AddHeading(page, y + 4, "Modules")
    for i = 1, table.getn(WF.order) do
      local mod = WF.modules[WF.order[i]]
      y = WF:AddCheck(page, y, mod.title,
        function() return mod.db.enabled end,
        function(on)
          mod.db.enabled = on
          WF:Refresh()
        end)
    end
    return y
  end)

  -- each module adds its own tabs: M:OptionsTabs() returns
  -- { { name = "Tab", build = function(page, y) ... return y end }, ... }
  -- (a module with only M:OptionsBuild(page, y) gets one tab of its own)
  for i = 1, table.getn(self.order) do
    local mod = self.modules[self.order[i]]
    if mod.OptionsTabs then
      local list = mod:OptionsTabs()
      for k = 1, table.getn(list) do
        AddTab(list[k].name, list[k].build)
      end
    elseif mod.OptionsBuild then
      AddTab(mod.short or mod.title, function(page, y)
        y = WF:AddHeading(page, y, mod.title)
        return mod:OptionsBuild(page, y)
      end)
    end
  end

  -- lay the tab buttons out in one row
  local n = table.getn(self.optTabs)
  local bw = math.floor((MAIN_W - 24) / n) - 2
  if bw > 90 then bw = 90 end
  if bw < 44 then bw = 44 end
  for i = 1, n do
    local btn = self.optTabs[i].btn
    btn:SetWidth(bw)
    btn:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * (bw + 2), -4)
  end

  -- open on the tab you used last
  local want = 1
  for i = 1, n do
    if self.optTabs[i].name == self.db.optTab then want = i end
  end
  self:SelectOptionsTab(want)
end

-- opens the options panel in the window (expanding the window if needed)
function WF:ShowOptions()
  if not self.main then return end
  self:BuildOptions()
  local opt = self.optionsMod

  if self.activeMod ~= opt then
    self.prevMod = self.activeMod
    self.optReturnCollapsed = self.db.collapsed and true or nil   -- recollapse when options close
  end
  if self.db.collapsed then
    self.db.collapsed = false
    self:UpdateCollapseButton()
  end
  self:RefreshOptions()
  self:SelectModule(opt)
end

-- cog button: shows the options in the window; click again to go back
function WF:ToggleOptions()
  if not self.main then return end
  self:BuildOptions()
  local opt = self.optionsMod

  if self.activeMod == opt and not self:IsCollapsed() then
    local back = self.prevMod
    if not (back and back.running and back.frame) then
      back = nil
      for i = 1, table.getn(self.order) do
        local m = self.modules[self.order[i]]
        if not back and m.running and m.frame then back = m end
      end
    end
    local recollapse = self.optReturnCollapsed
    if back then self:SelectModule(back) end
    if recollapse then self:SetCollapsed(true) end
    return
  end

  self:ShowOptions()
end

-- The window is shown unless the user has closed it, or it is hidden by the
-- "hide in combat" option.
function WF:ApplyMainVisibility()
  local main = self.main
  if not main then return end
  if self.db.mainShown ~= false and not self:CombatHidden() then
    main:Show()
  else
    main:Hide()
  end
end

function WF:SetMainShown(show)
  if not self.main then return end
  self.db.mainShown = show
  self:ApplyMainVisibility()
  if show and self:CombatHidden() then
    self:Print("the window is hidden during combat and will show when it ends.")
  end
end

-- select the module and open the window
function WF:ShowModule(mod)
  if not self.main then return end
  if self.db.collapsed then
    self.db.collapsed = false
    self:UpdateCollapseButton()
  end
  self:SelectModule(mod)
  self:SetMainShown(true)
end

-- /wf <module>: open it, or close the window if it is already the one shown
function WF:ToggleModule(mod)
  if not self.main then return end
  if self.db.mainShown ~= false and self.activeMod == mod and not self.db.collapsed then
    self:SetMainShown(false)
  else
    self:ShowModule(mod)
  end
end

-- rebuilds the module buttons, keeps a valid module selected
function WF:UpdateMain()
  local main = self.main
  if not main then return end

  local running = {}
  for i = 1, table.getn(self.order) do
    local mod = self.modules[self.order[i]]
    local btn = main.tabs[mod.key]
    if not btn then
      btn = self:CreateButton(main, mod.short or mod.title, 80, 22)
      btn:SetScript("OnClick", function()
        -- in combat the window stays collapsed: only switch the selection
        if WF:CombatLocked() then
          WF:SelectModule(mod)
          return
        end
        -- clicking the module that is already showing collapses the window
        if WF.activeMod == mod and not WF.db.collapsed then
          WF:SetCollapsed(true)
          return
        end
        -- otherwise expand if needed and show this module
        if WF.db.collapsed then
          WF.db.collapsed = false
          WF:UpdateCollapseButton()
        end
        WF:SelectModule(mod)
      end)
      main.tabs[mod.key] = btn
    end
    if mod.running and mod.frame then
      table.insert(running, mod)
    else
      btn:Hide()
    end
  end

  local n = table.getn(running)
  if n == 0 then
    self.activeMod = nil
    main:Hide()
    return
  end

  -- lay the buttons out in one row at the top of the window, to the left
  -- of the collapse/close buttons
  local bw = math.floor((MAIN_W - 72) / n) - 2
  if bw > 110 then bw = 110 end
  if bw < 56 then bw = 56 end
  for i = 1, n do
    local btn = main.tabs[running[i].key]
    btn:SetWidth(bw)
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", main, "TOPLEFT", 12 + (i - 1) * (bw + 2), -12)
    btn:Show()
  end

  -- keep a running module selected: current, else last used, else first
  local active = self.activeMod
  if not (active and active.running and active.frame) then
    active = nil
    local saved = self.db.active and self.modules[self.db.active]
    if saved and saved.running and saved.frame then active = saved end
    if not active then active = running[1] end
  end
  self:SelectModule(active)

  self:ApplyMainVisibility()
end

----------------------------------------------------------------------
-- event frame / update frame
----------------------------------------------------------------------
local ev = CreateFrame("Frame", "WarlockFamiliarEvents")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEVEL_UP")

local updater = CreateFrame("Frame", "WarlockFamiliarUpdater")
updater:Hide()

local function RefEvent(name)
  evRef[name] = (evRef[name] or 0) + 1
  if evRef[name] == 1 then ev:RegisterEvent(name) end
end

local function UnrefEvent(name)
  local c = evRef[name]
  if not c then return end
  c = c - 1
  if c <= 0 then
    evRef[name] = nil
    ev:UnregisterEvent(name)
  else
    evRef[name] = c
  end
end

ev:SetScript("OnEvent", function()
  local e, a1, a2, a3 = event, arg1, arg2, arg3

  if e == "VARIABLES_LOADED" then
    WF:InitDB()
    WF.loaded = true
    WF:Refresh()
  elseif e == "PLAYER_ENTERING_WORLD" then
    WF:Refresh()
  elseif e == "PLAYER_LEVEL_UP" then
    WF:Refresh(a1) -- a1 = new level
  elseif e == "SPELLS_CHANGED" or e == "LEARNED_SPELL_IN_TAB" then
    WF:InvalidateSpells()
  elseif e == "PLAYER_REGEN_DISABLED" then
    -- entered combat: collapse the window to the module bar + status icons
    WF.inCombat = true
    WF:RefreshCombat()
  elseif e == "PLAYER_REGEN_ENABLED" then
    -- left combat: restore the window to the state the user left it in
    WF.inCombat = false
    WF.exemptUntil = nil
    WF:RefreshCombat()
  end

  for i = 1, table.getn(WF.order) do
    local mod = WF.modules[WF.order[i]]
    if mod.running and mod.eventSet[e] and mod.OnEvent then
      mod:OnEvent(e, a1, a2, a3)
    end
  end
end)

updater:SetScript("OnUpdate", function()
  local elapsed = arg1

  -- once a second at most: a combat exemption ran out? if combat is still
  -- on, collapse now
  WF.tickAcc = (WF.tickAcc or 0) + elapsed
  if WF.tickAcc >= 1 then
    WF.tickAcc = 0
    if WF.exemptUntil and GetTime() >= WF.exemptUntil then
      WF.exemptUntil = nil
      if WF.inCombat then WF:RefreshCombat() end
    end
  end

  for i = 1, table.getn(WF.order) do
    local mod = WF.modules[WF.order[i]]
    if mod.running and mod.OnUpdate then
      mod.acc = (mod.acc or 0) + elapsed
      -- never more often than once a second, whatever the module asks for
      local interval = mod.interval or 1
      if interval < 1 then interval = 1 end
      if mod.acc >= interval then
        mod.acc = 0
        mod:OnUpdate()
      end
    end
  end
end)

----------------------------------------------------------------------
-- module registry / lifecycle
----------------------------------------------------------------------
function WF:RegisterModule(key, mod)
  mod.key = key
  mod.events = mod.events or {}
  mod.eventSet = {}
  for i = 1, table.getn(mod.events) do
    mod.eventSet[mod.events[i]] = true
  end
  mod.running = false
  self.modules[key] = mod
  table.insert(self.order, key)
  return mod
end

function WF:InitDB()
  if not WarlockFamiliarDB then WarlockFamiliarDB = {} end
  local db = WarlockFamiliarDB
  if not db.mod then db.mod = {} end
  if not db.pos then db.pos = {} end
  self.db = db

  for i = 1, table.getn(self.order) do
    local key = self.order[i]
    if not db.mod[key] then db.mod[key] = {} end
    if db.mod[key].enabled == nil then db.mod[key].enabled = true end
    self.modules[key].db = db.mod[key]
  end
end

function WF:IsWarlock()
  local localized, token = UnitClass("player")
  return (token == "WARLOCK") or (localized == "Warlock")
end

function WF:StartModule(mod)
  if mod.running then return end
  if not mod.loaded then
    mod.loaded = true
    if mod.OnLoad then mod:OnLoad() end
  end
  mod.running = true
  mod.acc = 0
  for i = 1, table.getn(mod.events) do
    RefEvent(mod.events[i])
  end
  if mod.OnEnable then mod:OnEnable() end
end

function WF:StopModule(mod)
  if not mod.running then return end
  mod.running = false
  for i = 1, table.getn(mod.events) do
    UnrefEvent(mod.events[i])
  end
  if mod.OnDisable then mod:OnDisable() end
  if mod.frame then mod.frame:Hide() end
end

-- Re-evaluates what should be running. Non-warlocks: everything stays off,
-- the update frame is hidden and no game events are registered.
function WF:Refresh(newLevel)
  if not self.loaded then return end

  local active = self:IsWarlock()
  self.active = active

  if active then
    updater:Show()
    if not self.coreEvents then
      self.coreEvents = true
      RefEvent("SPELLS_CHANGED")
      RefEvent("LEARNED_SPELL_IN_TAB")
      RefEvent("PLAYER_REGEN_DISABLED")
      RefEvent("PLAYER_REGEN_ENABLED")
    end
    self.inCombat = (UnitAffectingCombat("player") ~= nil)
    if not self.main then self:BuildMain() end
  else
    updater:Hide()
    if self.coreEvents then
      self.coreEvents = false
      UnrefEvent("SPELLS_CHANGED")
      UnrefEvent("LEARNED_SPELL_IN_TAB")
      UnrefEvent("PLAYER_REGEN_DISABLED")
      UnrefEvent("PLAYER_REGEN_ENABLED")
    end
  end

  local level = newLevel or UnitLevel("player") or 0
  for i = 1, table.getn(self.order) do
    local mod = self.modules[self.order[i]]
    local should = active and mod.db.enabled and (level >= (mod.minLevel or 1))
    if should then self:StartModule(mod) else self:StopModule(mod) end
  end

  -- "hide the window on login" (once per session; closing it is remembered)
  if active and not self.loginHandled then
    self.loginHandled = true
    if self.db.hideOnLogin then self.db.mainShown = false end
  end

  self:UpdateMain()

  if active and not announced then
    announced = true
    self:Print("loaded. Type /wf for commands.")
  end
end

----------------------------------------------------------------------
-- slash commands
----------------------------------------------------------------------
function WF:ModuleStatus(mod)
  if not mod.db.enabled then return "|cff999999disabled|r" end
  if mod.running then return "|cff40ff40on|r" end
  return "|cffffd100locked (needs level " .. (mod.minLevel or 1) .. ")|r"
end

function WF:PrintHelp()
  self:Print("modules (/wf <module> opens it in the main window):")
  for i = 1, table.getn(self.order) do
    local mod = self.modules[self.order[i]]
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff" .. mod.key .. "|r - " .. mod.title .. " [" .. self:ModuleStatus(mod) .. "]")
  end
  DEFAULT_CHAT_FRAME:AddMessage("  /wf   (alone)   shows the window and opens the options")
  DEFAULT_CHAT_FRAME:AddMessage("  /wf show | hide | toggle   (the main window)")
  DEFAULT_CHAT_FRAME:AddMessage("  /wf <module> show | hide | <module commands>")
  DEFAULT_CHAT_FRAME:AddMessage("  /wf enable <module> | disable <module>")
end

function WF:RunModuleCommand(key, args)
  local mod = self.modules[key]
  if not self.loaded or not mod then return end

  if not mod.running then
    self:Print(mod.title .. " is not active (disabled, not a Warlock, or below level " .. (mod.minLevel or 1) .. ").")
    return
  end

  args = args or ""
  local lower = string.lower(args)
  if lower == "" or lower == "toggle" then
    self:ToggleModule(mod)
  elseif lower == "show" then
    self:ShowModule(mod)
  elseif lower == "hide" then
    if self.activeMod == mod then self:SetMainShown(false) end
  elseif mod.OnSlash then
    mod:OnSlash(args)
  else
    self:Print(mod.title .. " has no extra commands.")
  end
end

function WF:HandleSlash(msg)
  if not self.loaded then return end
  local _, _, cmd, rest = string.find(msg or "", "^%s*(%S+)%s*(.*)$")

  if not self.active then
    self:Print("inactive: WarlockFamiliar only runs on Warlock characters.")
    return
  end

  if not cmd then
    -- just "/wf": unhide the window and open the options
    self:SetMainShown(true)
    self:ShowOptions()
    return
  end
  cmd = string.lower(cmd)

  if cmd == "help" or cmd == "status" then
    self:PrintHelp()
  elseif cmd == "show" then
    self:SetMainShown(true)
  elseif cmd == "hide" then
    self:SetMainShown(false)
  elseif cmd == "toggle" then
    if self.main and self.db.mainShown ~= false then
      self:SetMainShown(false)
    else
      self:SetMainShown(true)
    end
  elseif cmd == "enable" or cmd == "disable" then
    local key = string.lower(rest or "")
    local mod = self.modules[key]
    if not mod then
      self:Print("unknown module '" .. key .. "'.")
      return
    end
    mod.db.enabled = (cmd == "enable")
    self:Refresh()
    self:Print(mod.title .. " " .. self:ModuleStatus(mod) .. ".")
  elseif self.modules[cmd] then
    self:RunModuleCommand(cmd, rest)
  else
    self:PrintHelp()
  end
end

SLASH_WARLOCKFAMILIAR1 = "/wf"
SLASH_WARLOCKFAMILIAR2 = "/warlockfamiliar"
SlashCmdList["WARLOCKFAMILIAR"] = function(msg)
  WF:HandleSlash(msg)
end
