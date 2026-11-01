--[[
  Summon Manager
  A paged list (10 per page) of your party / raid, showing where each member
  is, plus two buttons:

    Summon target  - casts Ritual of Summoning on your current target
    Auto summon    - picks the member who most needs a summon and casts it

  Clicking a member in the list targets them; right-clicking summons them.

  Auto summon skips: offline members, members already inside an instance,
  members who are near you, members you summoned a moment ago and (unless
  switched on in the options) dead members. It prefers living members in
  another zone, then living members who are far away in your zone.

  When a Ritual of Summoning starts, the addon can say a line in /say and
  whisper the target (both editable in the Options panel, with
  %t = target name and %z = zone). Nothing is announced for a dead target, a
  non-player, yourself, or when there is no target.

  Client mods (optional, used automatically when present):
    SuperWoW  - UnitPosition gives exact distances; CastSpellByName(spell,
                unit) summons without changing your target
    Nampower  - IsSpellUsable tells whether you are out of mana

  /wf summon                 show / hide the window
  /wf summon auto            summon the member who most needs it
  /wf summon target          summon your current target
  /wf summon ignore <zone>   treat a zone as an instance (members there are skipped)
  /wf summon unignore <zone>
  /wf summon list            show the ignored zones
]]

local WF = WarlockFamiliar

local SUM_SPELL = "Ritual of Summoning"
local SHARD_ID = 6265
local PAGE_SIZE = 10
local ROW_TOP = 4
local ROW_H = 18
local NEAR_YARDS = 40       -- closer than this: no summon needed
local RECENT_SECS = 90      -- a member summoned this recently is skipped by Auto summon
local SUM_COOLDOWN = 30     -- seconds before the same target is announced again

local DEFAULT_SAY = "Summoning %t! I need 2 more people to click the portal!"
local DEFAULT_WHISPER = "I'm summoning you to %z! Accept the summon when the portal is ready."

-- Zone names that count as "instanced" (lowercase). Members whose zone is in
-- here are skipped by Auto summon. Add more with /wf summon ignore <zone>.
local INSTANCES = {
  -- vanilla dungeons
  ["ragefire chasm"] = true, ["wailing caverns"] = true, ["the deadmines"] = true,
  ["deadmines"] = true, ["shadowfang keep"] = true, ["blackfathom deeps"] = true,
  ["the stockade"] = true, ["gnomeregan"] = true, ["razorfen kraul"] = true,
  ["scarlet monastery"] = true, ["razorfen downs"] = true, ["uldaman"] = true,
  ["zul'farrak"] = true, ["maraudon"] = true, ["the temple of atal'hakkar"] = true,
  ["sunken temple"] = true, ["blackrock depths"] = true, ["blackrock spire"] = true,
  ["lower blackrock spire"] = true, ["upper blackrock spire"] = true,
  ["dire maul"] = true, ["scholomance"] = true, ["stratholme"] = true,
  -- vanilla raids
  ["molten core"] = true, ["onyxia's lair"] = true, ["blackwing lair"] = true,
  ["zul'gurub"] = true, ["ruins of ahn'qiraj"] = true, ["temple of ahn'qiraj"] = true,
  ["naxxramas"] = true,
  -- battlegrounds
  ["warsong gulch"] = true, ["arathi basin"] = true, ["alterac valley"] = true,
  -- Turtle WoW custom instances (check the names against your server)
  ["dragonmaw retreat"] = true, ["stormwind vault"] = true, ["hateforge quarry"] = true,
  ["lower karazhan halls"] = true, ["karazhan"] = true, ["gilneas city"] = true,
  ["the crescent grove"] = true, ["crescent grove"] = true, ["emerald sanctum"] = true,
  ["black morass"] = true, ["the black morass"] = true
}

-- display order of the list (smaller first) and the status text of each state
local STATE_ORDER = { away = 1, far = 2, summoning = 3, dead = 4, near = 5, instance = 6, offline = 7 }

local M = WF:RegisterModule("summon", {
  title = "Summon Manager",
  short = "Summon",
  minLevel = 20,
  interval = 0.5,
  events = { "SPELLCAST_START", "SPELLCAST_CHANNEL_START", "SPELLCAST_CHANNEL_STOP",
             "SPELLCAST_FAILED", "SPELLCAST_INTERRUPTED" },
})

M.rows = {}
M.page = 1
M.summoned = {}   -- name -> GetTime() of the last summon cast on them

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function IsInstanceZone(zone)
  if not zone or zone == "" then return false end
  local z = string.lower(zone)
  if INSTANCES[z] then return true end
  local ignore = M.db and M.db.ignore
  if ignore and ignore[z] then return true end
  return false
end

-- fills in %t (target) and %z (zone)
local function FillText(line, name, zone)
  line = string.gsub(line, "%%t", function() return name end)
  line = string.gsub(line, "%%z", function() return zone end)
  return line
end

-- exact distance in yards (SuperWoW's UnitPosition), or nil
local function ExactYards(unit)
  if not (WF.HasSuperWoW() and UnitPosition) then return nil end
  local px, py = UnitPosition("player")
  local ux, uy = UnitPosition(unit)
  if not (px and py and ux and uy) then return nil end
  -- map fractions (0..1) are not yards: refuse to use them
  if math.abs(px) <= 1.5 and math.abs(py) <= 1.5
     and math.abs(ux) <= 1.5 and math.abs(uy) <= 1.5 then
    return nil
  end
  local dx, dy = px - ux, py - uy
  return math.sqrt(dx * dx + dy * dy)
end

-- the unit id ("raidN" / "partyN") of a group member by name, or nil
local function FindUnit(name)
  if GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      if UnitName("raid" .. i) == name then return "raid" .. i end
    end
  else
    for i = 1, GetNumPartyMembers() do
      if UnitName("party" .. i) == name then return "party" .. i end
    end
  end
  return nil
end

local function Short(text, n)
  if not text then return "" end
  if string.len(text) > n then return string.sub(text, 1, n - 1) .. "." end
  return text
end

----------------------------------------------------------------------
-- scanning (rate limited: the group once a second, bags every 2 seconds)
----------------------------------------------------------------------
-- builds one list entry and works out its state
function M:MakeMember(name, unit, fileName, level, zone, online, dead, myZone)
  local m = {
    name = name, unit = unit, class = fileName, level = level,
    zone = zone or "", online = online and true or false, dead = dead and true or false
  }
  m.sameZone = (m.zone ~= "" and m.zone == myZone)
  m.instance = (not m.sameZone) and IsInstanceZone(m.zone)

  if m.online and m.sameZone then
    local yards = ExactYards(unit)
    if yards then
      m.yards = yards
      m.near = (yards <= NEAR_YARDS)
    else
      m.near = CheckInteractDistance(unit, 4) and true or false   -- about 28 yards
    end
    m.visible = UnitIsVisible(unit) and true or false
  end

  local t = self.summoned[name]
  m.recent = (t and GetTime() - t < RECENT_SECS) and true or false

  if not m.online then
    m.state = "offline"
  elseif m.instance then
    m.state = "instance"
  elseif m.dead then
    m.state = "dead"
  elseif m.sameZone and m.near then
    m.state = "near"
  elseif m.recent then
    m.state = "summoning"
  elseif m.sameZone then
    m.state = "far"
  else
    m.state = "away"
  end
  return m
end

function M:ScanGroup()
  local list = {}
  local myName = UnitName("player")
  local myZone = GetRealZoneText() or ""
  local nRaid = GetNumRaidMembers()

  if nRaid > 0 then
    for i = 1, nRaid do
      local name, rank, subgroup, level, class, fileName, zone, online, isDead = GetRaidRosterInfo(i)
      if name and name ~= myName then
        local unit = "raid" .. i
        if not zone or zone == "" then
          -- no roster zone: a visible member must be in your zone
          if UnitIsVisible(unit) then zone = myZone else zone = "" end
        end
        local dead = isDead or UnitIsDeadOrGhost(unit)
        table.insert(list, self:MakeMember(name, unit, fileName, level, zone, online, dead, myZone))
      end
    end
  else
    -- 1.12 has no zone name for party members. A member who is visible, or who
    -- shows on the map of your current zone, is in your zone.
    local mapOK = false
    if not (WorldMapFrame and WorldMapFrame:IsVisible()) and not IsInstanceZone(myZone) then
      SetMapToCurrentZone()
      mapOK = true
    end
    for i = 1, GetNumPartyMembers() do
      local unit = "party" .. i
      local name = UnitName(unit)
      if name then
        local _, fileName = UnitClass(unit)
        local here = UnitIsVisible(unit)
        if not here and mapOK then
          local x, y = GetPlayerMapPosition(unit)
          here = (x and y and (x ~= 0 or y ~= 0)) and true or false
        end
        local zone = ""
        if here then zone = myZone end
        table.insert(list, self:MakeMember(name, unit, fileName, UnitLevel(unit), zone,
                                           UnitIsConnected(unit), UnitIsDeadOrGhost(unit), myZone))
      end
    end
  end

  -- members who need a summon first, then by name
  table.sort(list, function(a, b)
    local oa, ob = STATE_ORDER[a.state], STATE_ORDER[b.state]
    if oa ~= ob then return oa < ob end
    return a.name < b.name
  end)
  return list
end

function M:Scan()
  if WF:Due(self, "tSlow", 2) or not self.shards then
    self.shards = WF:CountItemId(SHARD_ID)
  end
  if WF:Due(self, "tGroup", 1) or not self.members then
    self.members = self:ScanGroup()
  end
end

----------------------------------------------------------------------
-- summoning
----------------------------------------------------------------------
-- true while a Ritual of Summoning is being cast or is being channelled
function M:Busy()
  local now = GetTime()
  if self.channeling and now - self.channeling < 120 then return true end
  if self.castingAt and now - self.castingAt < 6 then return true end
  return false
end

-- Casts Ritual of Summoning on the member `m`. `token` is "target" when the
-- member is already your target.
function M:CastSummon(m, token)
  if not WF:GetSpellIndex(SUM_SPELL) then
    WF:Print("You have not learned " .. SUM_SPELL .. ".")
    return false
  end
  if not m.online then
    WF:Print(m.name .. " is offline.")
    return false
  end
  if self:Busy() then
    WF:Print("A summoning ritual is already in progress.")
    return false
  end
  if WF:CountItemId(SHARD_ID) == 0 then
    WF:Print("You need a Soul Shard to summon.")
    return false
  end
  if WF.HasNampower() then
    local _, oom = IsSpellUsable(SUM_SPELL)
    if oom == 1 then
      WF:Print("Not enough mana for " .. SUM_SPELL .. ".")
      return false
    end
  end

  -- remember who this cast is for (the announcement reads it)
  self.pending = { name = m.name, t = GetTime() }

  if WF.HasSuperWoW() then
    -- SuperWoW: cast straight at the member, your target is never touched
    CastSpellByName(SUM_SPELL, token or m.unit)
  else
    local hadTarget = UnitExists("target")
    local sameTarget = (token == "target") or (hadTarget and UnitIsUnit("target", m.unit))
    if not sameTarget then TargetUnit(m.unit) end
    CastSpellByName(SUM_SPELL)
    if SpellIsTargeting() then SpellTargetUnit(m.unit) end
    if not sameTarget then
      if hadTarget then TargetLastTarget() else ClearTarget() end
    end
  end
  return true
end

-- "Summon target" button: Ritual of Summoning on your current target
function M:SummonTarget()
  if not UnitExists("target") or not UnitIsPlayer("target") or UnitIsUnit("target", "player") then
    WF:Print("Target a party or raid member first.")
    return
  end
  local name = UnitName("target")
  self.members = self:ScanGroup()
  for i = 1, table.getn(self.members) do
    if self.members[i].name == name then
      self:CastSummon(self.members[i], "target")
      return
    end
  end
  WF:Print(name .. " is not in your group.")
end

-- who should Auto summon pick? nil when nobody needs a summon.
-- 1. living members in another zone   2. living members far away in your zone
-- 3. dead members (only when the option is on). Never offline members, members
--    inside an instance, near members or members summoned a moment ago.
function M:PickAuto()
  local best, bestKey
  for i = 1, table.getn(self.members) do
    local m = self.members[i]
    local tier = nil
    if not m.recent then
      if m.state == "away" then
        tier = 1
      elseif m.state == "far" then
        tier = 2
      elseif m.state == "dead" and self.db.autoDead and not (m.sameZone and m.near) then
        tier = 3
      end
    end
    if tier then
      -- farthest first inside a tier (exact distance if known; otherwise a
      -- member you cannot see counts as farther than one you can)
      local far = m.yards
      if not far then
        if m.visible then far = 60 else far = 1000 end
      end
      local key = tier * 100000 - far
      if not bestKey or key < bestKey then
        best, bestKey = m, key
      end
    end
  end
  return best
end

-- "Auto summon" button
function M:AutoSummon()
  self.members = self:ScanGroup()
  local m = self:PickAuto()
  if not m then
    WF:Print("Nobody needs a summon.")
    return
  end
  local where = m.zone
  if where == "" then where = "elsewhere" end
  if self:CastSummon(m) then
    WF:Print("Summoning " .. m.name .. " (" .. where .. ").")
  end
end

----------------------------------------------------------------------
-- announcements (Ritual of Summoning started)
----------------------------------------------------------------------
function M:Announce()
  local doSay = self.db.say ~= false
  local doWhisper = self.db.whisper ~= false

  -- who is it for: the member a click here aimed at, else your player target
  local name
  local p = self.pending
  if p and GetTime() - p.t < 8 then
    name = p.name
  elseif UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
    name = UnitName("target")
  end
  self.pending = nil
  if not name then return end

  local unit = FindUnit(name)
  if not unit then return end            -- not in your group: not a summon target
  self.summoned[name] = GetTime()        -- Auto summon leaves them alone for a while

  if not doSay and not doWhisper then return end
  if UnitIsDeadOrGhost(unit) then return end   -- nothing is announced for the dead

  -- 30 second cooldown per target; a different target is announced right away
  local now = GetTime()
  self.lastAnnounce = self.lastAnnounce or {}
  local last = self.lastAnnounce[name]
  if last and now - last < SUM_COOLDOWN then return end
  for k, t in pairs(self.lastAnnounce) do
    if now - t >= SUM_COOLDOWN then self.lastAnnounce[k] = nil end
  end
  self.lastAnnounce[name] = now

  local zone = GetRealZoneText() or ""

  if doSay then
    local line = self.db.sayLine
    if line == nil then line = DEFAULT_SAY end
    if line ~= "" then
      SendChatMessage(FillText(line, name, zone), "SAY")
    end
  end

  if doWhisper then
    local line = self.db.whisperLine
    if line == nil then line = DEFAULT_WHISPER end
    if line ~= "" then
      SendChatMessage(FillText(line, name, zone), "WHISPER", nil, name)
    end
  end
end

function M:OnEvent(event, a1, a2)
  if event == "SPELLCAST_START" then
    if a1 == SUM_SPELL then
      self.castingAt = GetTime()
      self:Announce()
    end
  elseif event == "SPELLCAST_CHANNEL_START" then
    if a2 == SUM_SPELL then
      self.channeling = GetTime()
      self:Announce()
    end
  elseif event == "SPELLCAST_CHANNEL_STOP" then
    self.channeling = nil
    self.castingAt = nil
  elseif event == "SPELLCAST_INTERRUPTED" then
    self.channeling = nil
    self.castingAt = nil
  elseif event == "SPELLCAST_FAILED" then
    self.castingAt = nil
  end
end

----------------------------------------------------------------------
-- drawing (cache only: no scanning in here)
----------------------------------------------------------------------
local function StateText(m)
  local s = m.state
  if s == "away" then return "|cffff8800Away|r" end
  if s == "far" then
    if m.yards then return "|cffffd100Far " .. math.floor(m.yards + 0.5) .. "y|r" end
    return "|cffffd100Far|r"
  end
  if s == "summoning" then return "|cff00ccffSummoning|r" end
  if s == "dead" then return "|cffff4040Dead|r" end
  if s == "near" then
    if m.yards then return "|cff40ff40Near " .. math.floor(m.yards + 0.5) .. "y|r" end
    return "|cff40ff40Near|r"
  end
  if s == "instance" then return "|cff999999Instance|r" end
  return "|cff999999Offline|r"
end

function M:Draw()
  if not self.frame or not self.members then return end

  local list = self.members
  local n = table.getn(list)
  local pages = math.ceil(n / PAGE_SIZE)
  if pages < 1 then pages = 1 end
  if self.page > pages then self.page = pages end
  if self.page < 1 then self.page = 1 end

  local first = (self.page - 1) * PAGE_SIZE
  for i = 1, PAGE_SIZE do
    local row = self.rows[i]
    local m = list[first + i]
    if m then
      row.unit = m.unit
      row.member = m
      local c = m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
      if c then
        row.name:SetTextColor(c.r, c.g, c.b)
      else
        row.name:SetTextColor(1, 0.82, 0)
      end
      row.name:SetText(Short(m.name, 12))
      local zone = m.zone
      if zone == "" then zone = "Elsewhere" end
      row.zone:SetText(Short(zone, 17))
      row.status:SetText(StateText(m))
      if UnitExists("target") and UnitIsUnit("target", m.unit) then
        row.sel:Show()
      else
        row.sel:Hide()
      end
      row:Show()
    else
      row.unit = nil
      row.member = nil
      row:Hide()
    end
  end

  if n == 0 then
    self.emptyText:Show()
  else
    self.emptyText:Hide()
  end

  self.pageText:SetText("Page " .. self.page .. "/" .. pages .. "  (" .. n .. ")")
  if self.page > 1 then self.prevBtn:Enable() else self.prevBtn:Disable() end
  if self.page < pages then self.nextBtn:Enable() else self.nextBtn:Disable() end

  -- one-line summary: who needs a summon, shards
  local need = 0
  for i = 1, n do
    if list[i].state == "away" or list[i].state == "far" then need = need + 1 end
  end
  local shards = self.shards or 0
  local shardText = tostring(shards)
  if shards == 0 then shardText = "|cffff4040" .. shardText .. "|r" end
  self.info:SetText("Need a summon: |cffffffff" .. need .. "|r    Soul Shards: " .. shardText)
end

function M:Refresh()
  if not self.frame then return end
  self:Scan()
  self:Draw()
end

----------------------------------------------------------------------
-- window
----------------------------------------------------------------------
function M:OnLoad()
  -- the summon announcement settings used to live in the Buff Manager
  local old = WarlockFamiliarDB and WarlockFamiliarDB.mod and WarlockFamiliarDB.mod.buffs
  if old then
    local moves = { sumSay = "say", sumWhisper = "whisper",
                    sumSayLine = "sayLine", sumWhisperLine = "whisperLine" }
    for from, to in pairs(moves) do
      if old[from] ~= nil then
        if self.db[to] == nil then self.db[to] = old[from] end
        old[from] = nil
      end
    end
  end

  local height = ROW_TOP + PAGE_SIZE * ROW_H + 82
  local f = WF:CreateWindow(self, 0, height)

  self.emptyText = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  self.emptyText:SetPoint("TOP", f, "TOP", 0, -14)
  self.emptyText:SetText("Join a party or raid to see members here.")

  for i = 1, PAGE_SIZE do
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(254)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 23, -ROW_TOP - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    -- marks the member you have targeted
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints(row)
    row.sel:SetTexture(1, 1, 1, 0.12)
    row.sel:Hide()

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.name:SetJustifyH("LEFT")

    row.zone = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.zone:SetPoint("LEFT", row, "LEFT", 82, 0)
    row.zone:SetJustifyH("LEFT")
    row.zone:SetTextColor(0.7, 0.7, 0.7)

    row.status = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.status:SetJustifyH("RIGHT")

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      local r = this
      if not r.unit then return end
      if arg1 == "RightButton" then
        if r.member then M:CastSummon(r.member) end
      else
        TargetUnit(r.unit)
      end
    end)
    WF:SetTooltip(row, "Left-click: target\nRight-click: summon")

    row:Hide()
    self.rows[i] = row
  end

  -- pager
  local pagerY = ROW_TOP + PAGE_SIZE * ROW_H + 6
  self.prevBtn = WF:CreateButton(f, "<", 30, 20)
  self.prevBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 23, -pagerY)
  self.prevBtn:SetScript("OnClick", function()
    M.page = M.page - 1
    M:Draw()
  end)

  self.nextBtn = WF:CreateButton(f, ">", 30, 20)
  self.nextBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -23, -pagerY)
  self.nextBtn:SetScript("OnClick", function()
    M.page = M.page + 1
    M:Draw()
  end)

  self.pageText = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  self.pageText:SetPoint("TOP", f, "TOP", 0, -(pagerY + 4))

  -- action buttons
  local btnY = pagerY + 26
  local targetBtn = WF:CreateButton(f, "Summon target", 124, 22)
  targetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 23, -btnY)
  targetBtn:SetScript("OnClick", function() M:SummonTarget() end)
  WF:SetTooltip(targetBtn, "Cast Ritual of Summoning on your current target")

  local autoBtn = WF:CreateButton(f, "Auto summon", 124, 22)
  autoBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -23, -btnY)
  autoBtn:SetScript("OnClick", function() M:AutoSummon() end)
  WF:SetTooltip(autoBtn, "Summon the member who most needs it: living members in another zone first, then far away members in your zone.\nSkips offline members, members in instances, near members and members summoned a moment ago.")

  self.info = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  self.info:SetPoint("TOP", f, "TOP", 0, -(btnY + 28))

  f:SetScript("OnShow", function() M:Refresh() end)
end

function M:OnUpdate()
  if self.frame and self.frame:IsVisible() then
    self:Refresh()
  end
end

function M:OnDisable()
  self.channeling = nil
  self.castingAt = nil
  self.pending = nil
end

----------------------------------------------------------------------
-- options: the Summon tab
----------------------------------------------------------------------
function M:OptionsTabs()
  return {
    { name = "Summon", build = function(p, y) return M:OptionsSummon(p, y) end },
  }
end

function M:OptionsSummon(parent, y)
  y = WF:AddHeading(parent, y, "Auto summon")
  y = WF:AddCheck(parent, y, "Also auto-summon dead members (last)",
    function() return M.db.autoDead == true end,
    function(on) M.db.autoDead = on end)

  y = WF:AddHeading(parent, y + 4, "Announcements")
  y = WF:AddCheck(parent, y, "Announce Ritual of Summoning in /say",
    function() return M.db.say ~= false end,
    function(on) M.db.say = on end)
  y = WF:AddCheck(parent, y, "Whisper the summon target",
    function() return M.db.whisper ~= false end,
    function(on) M.db.whisper = on end)

  local help = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  help:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 2))
  help:SetText("Placeholders: %t = target's name, %z = zone")
  y = y + 20

  local sayLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  sayLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  sayLabel:SetText("Message in /say:")
  y = y + 22
  local sayBox = WF:AddEditBox(parent, 20, y, 256)
  sayBox:SetMaxLetters(200)
  sayBox:SetText(M.db.sayLine or DEFAULT_SAY)
  sayBox:SetScript("OnTextChanged", function() M.db.sayLine = this:GetText() end)
  y = y + 28

  local whLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  whLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  whLabel:SetText("Whisper to the summon target:")
  y = y + 22
  local whBox = WF:AddEditBox(parent, 20, y, 256)
  whBox:SetMaxLetters(200)
  whBox:SetText(M.db.whisperLine or DEFAULT_WHISPER)
  whBox:SetScript("OnTextChanged", function() M.db.whisperLine = this:GetText() end)
  y = y + 28

  WF:AddButton(parent, 18, y, 80, "Reset", function()
    M.db.sayLine = nil
    M.db.whisperLine = nil
    sayBox:SetText(DEFAULT_SAY)
    whBox:SetText(DEFAULT_WHISPER)
  end)
  WF:AddButton(parent, 102, y, 80, "Test /say", function()
    local line = sayBox:GetText()
    if line and line ~= "" then
      SendChatMessage(FillText(line, "Friend", GetRealZoneText() or ""), "SAY")
    end
  end)

  return y + 28
end

----------------------------------------------------------------------
-- /wf summon ...
----------------------------------------------------------------------
function M:OnSlash(args)
  local _, _, cmd, rest = string.find(args or "", "^%s*(%S+)%s*(.*)$")
  cmd = string.lower(cmd or "")

  if cmd == "auto" then
    self:AutoSummon()
  elseif cmd == "target" or cmd == "summon" then
    self:SummonTarget()
  elseif cmd == "ignore" and rest ~= "" then
    self.db.ignore = self.db.ignore or {}
    self.db.ignore[string.lower(rest)] = true
    WF:Print("Treating '" .. rest .. "' as an instance: members there are skipped.")
  elseif cmd == "unignore" and rest ~= "" then
    if self.db.ignore then self.db.ignore[string.lower(rest)] = nil end
    WF:Print("No longer ignoring '" .. rest .. "'.")
  elseif cmd == "list" then
    local any = false
    if self.db.ignore then
      for z in pairs(self.db.ignore) do
        WF:Print("ignored zone: " .. z)
        any = true
      end
    end
    if not any then WF:Print("No custom ignored zones.") end
  else
    WF:Print("Summon Manager: auto | target | ignore <zone> | unignore <zone> | list")
  end
end
