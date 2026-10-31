--[[
  Buff Manager
  Lines are split into two lists: the main list (always visible) and the
  extras (hidden behind the "Show extras" button at the bottom of the
  window). By default Demon Armor, Healthstone and Soulstone are in the main
  list and everything else is in the extras.

  SHIFT-CLICK any line (icon or text) to move it between the main list and
  the extras. The choice is saved.

  Clicking an icon:
    * Healthstone  - left-click uses it (if you have one off cooldown),
                     otherwise creates one. Right-click casts Ritual of Souls.
    * Soulstone    - left-click uses it on your friendly target. It NEVER
                     targets yourself: with no friendly player target (or with
                     yourself targeted) nothing is used. There is no way to
                     soulstone yourself from this addon. A drop-down on the
                     line picks a group member; right-click uses the stone
                     on that player. If you have none, left-click creates one.
    * Spellstone / Firestone - creates one if missing
    * Voidstone / Felstone   - left-click casts the Create spell, right-click
                     uses the item from your bags
    * buffs        - casts the buff on yourself if it is missing
  Clicking the TEXT of a line does exactly the same as clicking its icon
  (left-click, right-click and shift-click).

  When you start casting Ritual of Summoning, the addon says a line in /say
  and whispers your target (each can be switched off; both messages are
  editable in the Options panel, with %t = target name and %z = zone).

  When you start casting Ritual of Souls, the addon says a line in /say
  (default: asking people to click the portal for healthstones). The line, and
  turning it off, are in the Options panel.

  Right-clicking the Unending Breath or Detect Invisibility icon casts that
  buff on the next in-range raid/party member who does not have it yet. Keep
  right-clicking to work through the group. When every online, living member
  has both buffs, "RAID BUFFED" is printed in your chat window.

  /wf buffs                  toggle window
  /wf buffs more             show/hide the extras (same as the button)
  /wf buffs item <name>      also track any bag item whose name contains <name>
                             (e.g. /wf buffs item voidstone)
  /wf buffs buff <name>      also track any buff by its exact name
  /wf buffs remove <name>    stop tracking a custom item/buff
  /wf buffs list             list custom entries
]]

local WF = WarlockFamiliar

local GREEN  = "|cff40ff40"
local RED    = "|cffff4040"
local YELLOW = "|cffffd100"
local GRAY   = "|cff999999"

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MAXROWS = 18
local ROWH = 20
local ICONSIZE = 16
local BUTTON_SPACE = 28 -- extra window height when the extras button is shown

-- Self buffs. Spell lists are ordered best-first (used for the click cast).
-- The first entry (Demon Armor) is one of the three always-visible lines;
-- the rest are "extras".
local BUFFS = {
  { label = "Demon Armor", recast = true,
    buffs  = { "Demon Armor", "Demon Skin" },
    spells = { "Demon Armor", "Demon Skin" } },
  { label = "Unending Breath", optional = true, raid = true, key = "breath",
    buffs  = { "Unending Breath" },
    spells = { "Unending Breath" } },
  { label = "Detect Invisibility", optional = true, raid = true, key = "detect",
    buffs  = { "Detect Greater Invisibility", "Detect Invisibility", "Detect Lesser Invisibility" },
    spells = { "Detect Greater Invisibility", "Detect Invisibility", "Detect Lesser Invisibility" } },
  { label = "Sacrifice", optional = true,
    buffs  = { "Sacrifice" },
    spells = { "Sacrifice" } },
  { label = "Shadow Ward", optional = true,
    buffs  = { "Shadow Ward" },
    spells = { "Shadow Ward" } },
}

-- Warlock stones. match = lowercase text found in the item name.
-- use         = clicking the icon uses the stone from your bags
-- soul        = use on the friendly target if there is one
-- rightSpell  = spell cast on right-click (if known)
-- (Soulstone: a click needs a friendly player target and never targets
--  yourself; there is no self-soulstone option.)
-- Healthstone (1) and Soulstone (2) start in the main list; the rest in the extras.
local STONES = {
  { label = "Healthstone", match = "healthstone", create = "Create Healthstone",
    use = true, rightSpell = "Ritual of Souls" },
  { label = "Soulstone",   match = "soulstone",   create = "Create Soulstone",
    use = true, soul = true, trackCd = true, buffs = { "Soulstone Resurrection" },
    -- exact item names (lowercase), best rank first; avoids matching
    -- unrelated items that merely contain the word "soulstone"
    names = { "major soulstone", "greater soulstone", "soulstone",
              "lesser soulstone", "minor soulstone" } },
  { label = "Spellstone",  match = "spellstone",  create = "Create Spellstone" },
  { label = "Firestone",   match = "firestone",   create = "Create Firestone" },
  -- splitClick = left-click casts the Create spell, right-click uses the item
  -- plainUse   = use the item with no self-cast flag (it may need a target)
  { label = "Voidstone",   match = "voidstone",   create = "Create Voidstone",
    splitClick = true, plainUse = true, buffs = { "Voidstone" } },
  { label = "Felstone",    match = "felstone",    create = "Create Felstone",
    splitClick = true, plainUse = true, buffs = { "Felstone" } },
}

-- Ritual of Souls announcement (in /say when the cast starts)
local ROS_SPELL = "Ritual of Souls"
local ROS_DEFAULT_LINE = "Ritual of Souls! Click the portal for free healthstones!"

-- Ritual of Summoning announcements: a /say line and a whisper to the target.
-- In both messages  %t  is replaced by the target's name and  %z  by the zone.
local SUM_SPELL = "Ritual of Summoning"
local SUM_COOLDOWN = 30   -- seconds before the same target is announced again
local SUM_DEFAULT_SAY = "Summoning %t! I need 2 more people to click the portal!"
local SUM_DEFAULT_WHISPER = "I'm summoning you to %z! Accept the summon when the portal is ready."

-- fills in %t (target) and %z (zone)
local function FillSummonText(line, name, zone)
  line = string.gsub(line, "%%t", function() return name end)
  line = string.gsub(line, "%%z", function() return zone end)
  return line
end

local M = WF:RegisterModule("buffs", {
  title = "Buff Manager",
  short = "Buffs",
  minLevel = 1,
  interval = 1,
  events = { "PLAYER_AURAS_CHANGED", "SPELLCAST_START", "SPELLCAST_CHANNEL_START" },
})

M.rows = {}

----------------------------------------------------------------------
-- scanning
----------------------------------------------------------------------
-- returns table: lowercase buff name -> { left = seconds (0 if none), tex = icon }
function M:ScanBuffs()
  local found = {}
  if not self.tip then return found end
  local superwow = WF.HasSuperWoW() and GetPlayerBuffID ~= nil
  for i = 0, 63 do
    local idx = GetPlayerBuff(i, "HELPFUL")
    if not idx or idx < 0 then break end
    local name
    if superwow then
      -- SuperWoW: the aura id gives the name directly, no tooltip needed
      local id = GetPlayerBuffID(idx)
      if id and id > 0 then name = SpellInfo(id) end
    end
    if not name then
      self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
      self.tip:SetPlayerBuff(idx)
      local fs = getglobal("WarlockFamiliarBuffTipTextLeft1")
      name = fs and fs:GetText()
    end
    if name then
      found[string.lower(name)] = {
        left = GetPlayerBuffTimeLeft(idx) or 0,
        tex = GetPlayerBuffTexture(idx)
      }
    end
  end
  return found
end

-- d.names (exact lowercase item names) wins over d.match (substring)
local function ItemMatches(d, lname)
  if d.names then
    for k = 1, table.getn(d.names) do
      if lname == d.names[k] then return true end
    end
    return false
  end
  return string.find(lname, d.match, 1, true) ~= nil
end

-- defs: array of { match = lowercase text } or { names = {...} }.
-- returns array of { count, cd, tex }
function M:ScanItems(defs)
  local res = {}
  local n = table.getn(defs)
  for i = 1, n do res[i] = { count = 0, cd = 0, slots = 0 } end

  WF:ForEachBagItem(function(bag, slot, link, count)
    local name = WF.ItemNameFromLink(link)
    if name then
      local lname = string.lower(name)
      for i = 1, n do
        if ItemMatches(defs[i], lname) then
          local r = res[i]
          r.count = r.count + count
          r.slots = r.slots + 1
          if not r.tex then
            r.tex = GetContainerItemInfo(bag, slot)
          end
          if r.cd == 0 then
            local start, dur = GetContainerItemCooldown(bag, slot)
            if start and start > 0 and dur and dur > 0 then
              local left = start + dur - GetTime()
              if left > 0 then
                r.cd = left
                r.cdEnd = GetTime() + left   -- absolute, so timers stay exact between scans
              end
            end
          end
        end
      end
    end
  end)

  return res
end

-- Ranks of the Create spells ("Create Healthstone (Major)") are part of the
-- NAME and the spellbook order is not reliable, so the rank is scored from
-- the name: Minor < Lesser < (no suffix) < Greater < Major.
local RANK_ORDER = { minor = 1, lesser = 2, greater = 4, major = 5 }

local function RankScore(name)
  local _, _, tag = string.find(name, "%((%a+)%)%s*$")
  if tag then
    local s = RANK_ORDER[string.lower(tag)]
    if s then return s end
  end
  return 3
end

-- highest-ranked known spell whose name starts with prefix, or nil
local function BestSpell(prefix)
  local matches = WF:FindSpellsByPrefix(prefix)
  local best, bestScore
  for i = 1, table.getn(matches) do
    local score = RankScore(matches[i])
    if not bestScore or score >= bestScore then
      best = matches[i]
      bestScore = score
    end
  end
  return best
end

local function FirstKnownSpell(names)
  for i = 1, table.getn(names) do
    if WF:GetSpellIndex(names[i]) then return names[i] end
  end
  return nil
end

-- returns the first active buff entry ({ left, tex }) among names, or nil
local function FirstActiveBuff(names, active)
  for i = 1, table.getn(names) do
    local a = active[string.lower(names[i])]
    if a then return a end
  end
  return nil
end

local function SpellIcon(spellName)
  if not spellName then return nil end
  local idx = WF:GetSpellIndex(spellName)
  if idx then return GetSpellTexture(idx, BOOKTYPE_SPELL) end
  return nil
end

local function TimeSuffix(left)
  if left and left > 0 then return " " .. WF.FormatTime(left) end
  return ""
end

-- Finds the bag slot to use. With `names` (exact lowercase names, best
-- first) the best-ranked match wins; otherwise the first item whose name
-- contains `match`.
local function FindBagItem(match, names)
  local fb, fs, best
  WF:ForEachBagItem(function(bag, slot, link, count)
    local name = WF.ItemNameFromLink(link)
    if name then
      local lname = string.lower(name)
      if names then
        for k = 1, table.getn(names) do
          if lname == names[k] then
            if not best or k < best then
              best = k
              fb = bag
              fs = slot
            end
            break
          end
        end
      elseif not fb and string.find(lname, match, 1, true) then
        fb = bag
        fs = slot
      end
    end
  end)
  return fb, fs
end

----------------------------------------------------------------------
-- icon click actions
----------------------------------------------------------------------
-- CastSpellByName reads "(...)" in a name as a spell RANK, which breaks
-- ranked-by-name spells such as "Create Soulstone (Major)". Names with
-- parentheses are therefore cast by spellbook index instead.
local function CastKnown(name, onSelf)
  if not name then return end
  if string.find(name, "(", 1, true) then
    local idx = WF:GetSpellIndex(name)
    if idx then
      CastSpell(idx, BOOKTYPE_SPELL)
    else
      WF:Print("You have not learned " .. name .. ".")
    end
  else
    CastSpellByName(name, onSelf)
  end
end

----------------------------------------------------------------------
-- raid buffing: Unending Breath / Detect Invisibility on group members
----------------------------------------------------------------------
local RECENT_SECS = 6  -- don't re-target a member while our cast is landing
local CHECK_DELAY = 4  -- seconds after a raid-buff cast before checking for "RAID BUFFED"

-- Casts `spell` on a specific unit without permanently changing your
-- target: target it, cast, answer a pending target cursor, restore target.
local function CastOnUnit(spell, unit)
  -- SuperWoW: cast straight at the unit, your target is never touched
  if WF.HasSuperWoW() and not string.find(spell, "(", 1, true) then
    CastSpellByName(spell, unit)
    return
  end
  local hadTarget = UnitExists("target")
  local sameTarget = hadTarget and UnitIsUnit("target", unit)

  if not sameTarget then TargetUnit(unit) end
  CastKnown(spell)
  if SpellIsTargeting() then SpellTargetUnit(unit) end

  if not sameTarget then
    if hadTarget then TargetLastTarget() else ClearTarget() end
  end
end

local function GroupUnits()
  local units = {}
  if GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      table.insert(units, "raid" .. i)
    end
  else
    table.insert(units, "player")
    for i = 1, GetNumPartyMembers() do
      table.insert(units, "party" .. i)
    end
  end
  return units
end

-- sorted names of the other players in your group (never yourself)
local function GroupNames()
  local names = {}
  local units = GroupUnits()
  for i = 1, table.getn(units) do
    local u = units[i]
    if not UnitIsUnit(u, "player") then
      local n = UnitName(u)
      if n then table.insert(names, n) end
    end
  end
  table.sort(names)
  return names
end

-- the unit id of a group member by name (never yourself), or nil
local function FindGroupUnit(name)
  local units = GroupUnits()
  for i = 1, table.getn(units) do
    local u = units[i]
    if not UnitIsUnit(u, "player") and UnitName(u) == name then return u end
  end
  return nil
end

local function PrintRaidBuffed()
  DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40RAID BUFFED|r")
end

-- everything on a unit: set of lowercase buff names and set of icon paths
-- (names come from a hidden tooltip; icons are a fallback)
function M:ScanUnitBuffs(unit)
  local names, texs = {}, {}
  local superwow = WF.HasSuperWoW()
  for i = 1, 32 do
    local tex, _, id = UnitBuff(unit, i)   -- SuperWoW adds the aura id as 3rd value
    if not tex then break end
    texs[tex] = true
    local n
    if superwow and id and id > 0 then n = SpellInfo(id) end
    if not n then
      self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
      self.tip:SetUnitBuff(unit, i)
      local fs = getglobal("WarlockFamiliarBuffTipTextLeft1")
      n = fs and fs:GetText()
    end
    if n then names[string.lower(n)] = true end
  end
  return names, texs
end

-- one entry per group member:
-- { unit, name, valid (online and alive), inRange, has = { [key] = bool } }
function M:ScanRaid()
  -- icons of the spells you know, as a fallback way to recognise the buffs
  local icons = {}
  for i = 1, table.getn(BUFFS) do
    local b = BUFFS[i]
    if b.raid then
      icons[b.key] = {}
      for k = 1, table.getn(b.spells) do
        local tex = SpellIcon(b.spells[k])
        if tex then icons[b.key][tex] = true end
      end
    end
  end

  local out = {}
  local units = GroupUnits()
  for u = 1, table.getn(units) do
    local unit = units[u]
    if UnitExists(unit) then
      local e = { unit = unit, name = UnitName(unit), has = {} }
      e.valid = UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit)
      e.inRange = UnitIsUnit(unit, "player")
                  or (UnitIsVisible(unit) and CheckInteractDistance(unit, 4))

      if e.valid then
        local names, texs = self:ScanUnitBuffs(unit)
        for i = 1, table.getn(BUFFS) do
          local b = BUFFS[i]
          if b.raid then
            local has = false
            for k = 1, table.getn(b.buffs) do
              if names[string.lower(b.buffs[k])] then has = true end
            end
            if not has then
              for tex, _ in pairs(icons[b.key]) do
                if texs[tex] then has = true end
              end
            end
            e.has[b.key] = has
          end
        end
      end

      table.insert(out, e)
    end
  end
  return out
end

-- true when every online, living group member has every raid buff
-- (offline and dead members are ignored since they can't be buffed)
function M:AllBuffed(members)
  if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then return false end
  local any = false
  for i = 1, table.getn(members) do
    local e = members[i]
    if e.valid then
      any = true
      for j = 1, table.getn(BUFFS) do
        local b = BUFFS[j]
        if b.raid and not e.has[b.key] then return false end
      end
    end
  end
  return any
end

-- Casts buff `b` on the first in-range group member who lacks it.
function M:BuffRaid(b)
  -- group scans read every member's buffs: at most once a second
  if not WF:Due(self, "tRaid", 1) then return end

  local castName = FirstKnownSpell(b.spells)
  if not castName then
    WF:Print("You have not learned " .. b.label .. ".")
    return
  end

  local members = self:ScanRaid()
  local now = GetTime()
  local lacking, outOfRange = 0, 0
  local target = nil

  for i = 1, table.getn(members) do
    local e = members[i]
    if e.valid and not e.has[b.key] then
      lacking = lacking + 1
      local last = self.recent[e.name .. ":" .. b.key]
      if last and (now - last) < RECENT_SECS then
        -- a cast on this member was just sent; wait for it to land
      elseif not e.inRange then
        outOfRange = outOfRange + 1
      elseif not target then
        target = e
      end
    end
  end

  if target then
    self.recent[target.name .. ":" .. b.key] = now
    CastOnUnit(castName, target.unit)
    WF:Print(b.label .. " -> " .. target.name)
    self.checkAt = now + CHECK_DELAY
    return
  end

  if lacking == 0 then
    if self:AllBuffed(members) then
      PrintRaidBuffed()
    else
      WF:Print("Everyone has " .. b.label .. ".")
    end
  elseif outOfRange > 0 then
    if outOfRange == 1 then
      WF:Print("1 member still needs " .. b.label .. " but is out of range.")
    else
      WF:Print(outOfRange .. " members still need " .. b.label .. " but are out of range.")
    end
  else
    WF:Print("Waiting for the " .. b.label .. " casts to land.")
  end
end

-- btn is the clicked icon button (btn.action, btn.rightRaid, btn.rightSpell,
-- btn.rightAction, btn.key, btn.isTop); mouse is "LeftButton" or "RightButton"
function M:IconClick(btn, mouse)
  -- shift-click: move this line between the main list and the extras
  if IsShiftKeyDown() then
    if btn.key then self:TogglePin(btn.key, btn.isTop) end
    return
  end

  if mouse == "RightButton" then
    if btn.rightRaid then
      -- Unending Breath / Detect Invisibility: buff the group
      self:BuffRaid(btn.rightRaid)
    elseif btn.rightSpell then
      -- Healthstone line: Ritual of Souls
      CastKnown(btn.rightSpell)
    elseif btn.rightAction then
      -- Voidstone / Felstone: use the item
      self:RunAction(btn.rightAction)
    end
    return
  end

  self:RunAction(btn.action)
end

-- moves a line between the main list and the extras (saved in db.pin)
function M:TogglePin(key, isTop)
  self.db.pin[key] = not isTop
  self:Draw()   -- cache only: no scanning
end

function M:RunAction(action)
  if not action then return end

  if action.kind == "cast" then
    CastKnown(action.spell, 1)
  elseif action.kind == "use" then
    local bag, slot = FindBagItem(action.match, action.names)
    if not bag then
      WF:Print("Could not find that item in your bags.")
      return
    end

    if action.soul then
      if action.toSelected then
        -- right-click: use it on the player picked in the drop-down.
        -- Only group members other than yourself can ever be chosen.
        local name = M.db.soulTarget
        if not name or name == "" then
          WF:Print("Pick a player with the Soulstone arrow first.")
          return
        end
        local unit = FindGroupUnit(name)
        if not unit then
          WF:Print(name .. " is not in your group.")
        elseif not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then
          WF:Print(name .. " must be online and alive to be soulstoned.")
        else
          local hadTarget = UnitExists("target")
          local sameTarget = hadTarget and UnitIsUnit("target", unit)
          if not sameTarget then TargetUnit(unit) end
          if UnitIsUnit("target", unit) and not UnitIsUnit("target", "player") then
            UseContainerItem(bag, slot)
          end
          -- answer / cancel a pending target cursor, never onto yourself
          if SpellIsTargeting() then
            if UnitIsUnit(unit, "player") then SpellStopTargeting() else SpellTargetUnit(unit) end
          end
          if not sameTarget then
            if hadTarget then TargetLastTarget() else ClearTarget() end
          end
        end
      elseif UnitExists("target") and UnitIsPlayer("target")
             and UnitIsFriend("player", "target")
             and not UnitIsUnit("target", "player") then
        UseContainerItem(bag, slot)
        -- never leave a target cursor hanging that could be clicked onto yourself
        if SpellIsTargeting() then SpellStopTargeting() end
      else
        -- safety: never falls back to yourself
        WF:Print("Target a friendly player other than yourself first.")
      end
    elseif action.plain then
      UseContainerItem(bag, slot)
    else
      UseContainerItem(bag, slot, 1)
    end
  end
end

----------------------------------------------------------------------
-- remembered Soulstone cooldown
-- A Soulstone is used up when cast, so once it has been used there is no
-- bag item to read a cooldown from. The cooldown is therefore remembered
-- (as a real-world end time, so it survives relogs):
--   * an item in your bags with a cooldown is the authoritative reading
--   * an item in your bags with no cooldown means the cooldown is over
--   * a Soulstone vanishing from your bags means it was used, so the
--     cooldown has just started
----------------------------------------------------------------------
local SOUL_CD = 1800  -- seconds (30 minutes)

function M:SoulCooldownLeft()
  local e = self.db.soulEnd
  if not e then return 0 end
  local left = e - time()
  if left <= 0 then
    self.db.soulEnd = nil
    return 0
  end
  return left
end

function M:TrackSoulstone()
  local r = self.res and self.res[2]   -- from the shared two-second bag scan
  if not r then return end

  if r.count > 0 then
    if r.cd > 0 then
      self.db.soulEnd = time() + r.cd
    else
      self.db.soulEnd = nil
    end
  elseif self.lastSoulCount and self.lastSoulCount > 0 then
    self.db.soulEnd = time() + SOUL_CD
  end

  self.lastSoulCount = r.count
end

----------------------------------------------------------------------
-- status icons (shown in the core window header)
--   DA   = Demon Armor
--   BW / FS / TS / FE = the Demonic Sacrifice buff: Burning Wish (Imp), Fel
--   Stamina (Voidwalker), Touch of Shadow (Succubus), Fel Energy (Felhunter)
--   last = the most recently applied stone effect: the Felstone / Voidstone
--          buffs, or a Firestone / Spellstone weapon enchant
-- Green text = active, red text = not active.
----------------------------------------------------------------------
-- The permanent demons. The one you most recently had out is remembered, so
-- the sacrifice icon can summon it again after a Demonic Sacrifice.
local DEMONS = {
  { family = "Imp",        spell = "Summon Imp",        label = "IMP",
    icon = "Interface\\Icons\\Spell_Shadow_SummonImp" },
  { family = "Voidwalker", spell = "Summon Voidwalker", label = "VW",
    icon = "Interface\\Icons\\Spell_Shadow_SummonVoidWalker" },
  { family = "Succubus",   spell = "Summon Succubus",   label = "SUC",
    icon = "Interface\\Icons\\Spell_Shadow_SummonSuccubus" },
  { family = "Felhunter",  spell = "Summon Felhunter",  label = "FH",
    icon = "Interface\\Icons\\Spell_Shadow_SummonFelHunter" },
}

-- Soul Shards (item 6265)
local SHARD_ID = 6265
local SHARD_ICON = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02"

-- The buff from Demonic Sacrifice depends on the demon that was sacrificed.
-- The icon shows the abbreviation of whichever one is active.
local SAC_FX = {
  { key = "bw", label = "BW", name = "Burning Wish",    match = "burning wish" },    -- Imp
  { key = "fs", label = "FS", name = "Fel Stamina",     match = "fel stamina" },     -- Voidwalker
  { key = "ts", label = "TS", name = "Touch of Shadow", match = "touch of shadow" }, -- Succubus
  { key = "fe", label = "FE", name = "Fel Energy",      match = "fel energy" },      -- Felhunter
}

-- Any active buff whose name contains `text` (lowercase) counts, so every
-- version of a buff is recognised, not just one exact name. If several are
-- active, the one with the most time left is used.
local function FindBuffContaining(active, text)
  local best
  for name, a in pairs(active) do
    if string.find(name, text, 1, true) then
      if not best or (a.left or 0) > (best.left or 0) then best = a end
    end
  end
  return best
end

local STONE_FX = {
  { key = "felstone",   label = "Fel",   name = "Felstone",   buff = "felstone" },
  { key = "voidstone",  label = "Void",  name = "Voidstone",  buff = "voidstone" },
  { key = "firestone",  label = "Fire",  name = "Firestone",  weapon = "firestone" },
  { key = "spellstone", label = "Spell", name = "Spellstone", weapon = "spellstone" },
}

-- Firestone / Spellstone are temporary weapon enchants. The weapon's tooltip
-- names the enchant, which tells them apart.
-- returns { [key] = { left = seconds } }
function M:ScanWeaponStones()
  local found = {}
  local hasMain, mainExp, _, hasOff, offExp = GetWeaponEnchantInfo()
  if not hasMain and not hasOff then return found end

  local slots = { { 16, hasMain, mainExp }, { 17, hasOff, offExp } }
  for s = 1, 2 do
    local slot = slots[s][1]
    local has = slots[s][2]
    local exp = slots[s][3]
    if has then
      self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
      self.tip:SetInventoryItem("player", slot)
      for i = 1, self.tip:NumLines() do
        local fs = getglobal("WarlockFamiliarBuffTipTextLeft" .. i)
        local line = fs and fs:GetText()
        if line then
          local l = string.lower(line)
          for k = 1, table.getn(STONE_FX) do
            local fx = STONE_FX[k]
            if fx.weapon and string.find(l, fx.weapon, 1, true) then
              found[fx.key] = { left = (exp or 0) / 1000 }
            end
          end
        end
      end
    end
  end
  return found
end

local function StatusTip(name, a)
  if not a then return name .. ": not active" end
  if a.left and a.left > 0 then
    return name .. ": " .. WF.FormatTime(a.left) .. " left"
  end
  return name .. ": active"
end

-- adds the matching list line's click hints to a status icon tooltip
local function WithHint(tip, entry)
  if entry and entry.tip then return tip .. "\n" .. entry.tip end
  return tip
end

-- Casting Demonic Sacrifice puts you in combat for a few seconds with your own
-- dying demon. When a sacrifice buff newly appears, tell the core not to
-- collapse the window for that combat.
local SAC_EXEMPT_SECS = 15

function M:DetectSacrifice(active)
  active = active or self:GetActive()
  local found = false
  for k = 1, table.getn(SAC_FX) do
    if FindBuffContaining(active, SAC_FX[k].match) then found = true end
  end

  -- sacWas == false means "seen without it before"; nil is the first reading
  -- after login, which is not a new sacrifice
  if found and self.sacWas == false then
    WF:SetCombatExempt(SAC_EXEMPT_SECS)
  end
  self.sacWas = found
end

function M:UpdateStatusIcons(active)
  if not self.indDA then return end
  active = active or self:GetActive()
  self:DetectSacrifice(active)

  -- Demon Armor (spell icon)
  local b = BUFFS[1]
  local castName = FirstKnownSpell(b.spells)
  local act = FirstActiveBuff(b.buffs, active)
  if not act and not castName then
    WF:SetStatusIconShown(self.indDA, false)
  else
    WF:SetStatusIconShown(self.indDA, true)
    self.indDA:Set(act ~= nil, "DA", SpellIcon(castName) or (act and act.tex),
                   WithHint(StatusTip("Demon Armor", act),
                            self.entries and self.entries["Demon Armor"]))
  end

  -- the demon you have out (and remember it: this survives a Demonic Sacrifice)
  local aliveDemon = nil
  if UnitExists("pet") and not UnitIsDead("pet") then
    local fam = UnitCreatureFamily("pet")
    for k = 1, table.getn(DEMONS) do
      if DEMONS[k].family == fam then
        aliveDemon = DEMONS[k]
        self.db.lastDemon = fam
      end
    end
  end

  -- Demonic Sacrifice buff: BW (Imp), FS (Voidwalker), TS (Succubus) or FE
  -- (Felhunter)
  local sacFx, sacBuff
  for k = 1, table.getn(SAC_FX) do
    local a = FindBuffContaining(active, SAC_FX[k].match)
    if a and (not sacBuff or (a.left or 0) > (sacBuff.left or 0)) then
      sacFx = SAC_FX[k]
      sacBuff = a
    end
  end

  local sacKnown = WF:GetSpellIndex("Demonic Sacrifice")
  local anySummon = false
  for k = 1, table.getn(DEMONS) do
    if WF:GetSpellIndex(DEMONS[k].spell) then anySummon = true end
  end

  if not (aliveDemon or sacBuff or sacKnown or anySummon) then
    WF:SetStatusIconShown(self.indSac, false)
  else
    WF:SetStatusIconShown(self.indSac, true)

    -- the demon a click would summon: the last one you had out, else an Imp
    local nextFam = self.db.lastDemon or "Imp"
    local nextDemon = DEMONS[1]
    for k = 1, table.getn(DEMONS) do
      if DEMONS[k].family == nextFam then nextDemon = DEMONS[k] end
    end

    local label, tex, isActive, tip
    if aliveDemon then
      -- a demon is out: its icon and an abbreviation of its name (green)
      label = aliveDemon.label
      tex = SpellIcon(aliveDemon.spell) or aliveDemon.icon
      isActive = true
      tip = aliveDemon.family .. " is out"
    elseif sacBuff then
      -- sacrificed: the buff you got (green)
      label = sacFx.label
      tex = sacBuff.tex or SpellIcon("Demonic Sacrifice")
      isActive = true
      tip = StatusTip(sacFx.name, sacBuff)
    else
      -- no demon and no sacrifice buff: shows what a click would summon (red)
      label = nextDemon.label
      tex = SpellIcon(nextDemon.spell) or nextDemon.icon
      isActive = false
      tip = "No demon out"
    end

    if not aliveDemon then
      tip = tip .. "\nClick to summon " .. nextDemon.family
    end
    if sacKnown then
      tip = tip .. "\nRight-click to cast Demonic Sacrifice"
    end
    self.indSac:Set(isActive, label, tex, tip)
  end

  -- most recently applied stone effect
  local now = {}
  for k = 1, table.getn(STONE_FX) do
    local fx = STONE_FX[k]
    if fx.buff and active[fx.buff] then now[fx.key] = active[fx.buff] end
  end
  local weapons = self.weapons or {}   -- from the two-second scan
  for key, a in pairs(weapons) do now[key] = a end

  local last = self.db.lastStone
  if not self.prevStone then
    -- first reading after login: keep the remembered stone if it is still
    -- active, otherwise take the active one with the most time left
    local pick, pickLeft
    for key, a in pairs(now) do
      if last and last.key == key then
        pick = key
        break
      end
      if not pickLeft or (a.left or 0) > pickLeft then
        pick = key
        pickLeft = a.left or 0
      end
    end
    if pick and not (last and last.key == pick) then
      last = { key = pick }
      self.db.lastStone = last
    end
  else
    -- an effect that was not active before and is now: newly applied
    for key, a in pairs(now) do
      if not self.prevStone[key] then
        last = { key = key }
        self.db.lastStone = last
      end
    end
  end
  self.prevStone = {}
  for key, a in pairs(now) do self.prevStone[key] = true end

  local fx = nil
  if last then
    for k = 1, table.getn(STONE_FX) do
      if STONE_FX[k].key == last.key then fx = STONE_FX[k] end
    end
  end

  if not fx then
    self.stoneKey = nil
    WF:SetStatusIconShown(self.indStone, false)
  else
    self.stoneKey = fx.name
    WF:SetStatusIconShown(self.indStone, true)
    local a = now[fx.key]
    if a and a.tex then last.tex = a.tex end   -- remember the icon
    local tex = last.tex
    if not tex then tex = SpellIcon(BestSpell("Create " .. fx.name)) end
    self.indStone:Set(a ~= nil, fx.label, tex,
                      WithHint(StatusTip(fx.name, a), self.entries and self.entries[fx.name]))
  end

  -- Soul Shards in your bags (green when you have any, red when you have none)
  local sr = self.shardRes or { count = 0, slots = 0 }   -- from the two-second bag scan
  local shards, shardSlots, shardTex = sr.count, sr.slots or 0, sr.tex
  if shards == 0 and UnitLevel("player") < 10 then
    WF:SetStatusIconShown(self.indShard, false)
  else
    WF:SetStatusIconShown(self.indShard, true)
    if shardTex then self.db.shardIcon = shardTex end   -- remember the icon
    local tex = shardTex or self.db.shardIcon or SHARD_ICON
    local tip = "Soul Shards: " .. shards
    if shardSlots > 0 then
      if shardSlots == 1 then tip = tip .. " in 1 slot" else tip = tip .. " in " .. shardSlots .. " slots" end
    end
    if shards > 0 then tip = tip .. "\nRight-click to delete a stack (outside soul bags first, smallest first)" end
    self.indShard:Set(shards > 0, tostring(shards), tex, tip)
  end
end

----------------------------------------------------------------------
-- refresh
----------------------------------------------------------------------
-- Shared data is scanned on a schedule and cached; building and drawing only
-- read the caches.
--   once a second at most : player buffs (and the pet / icon updates)
--   once every 2 seconds  : bags (stones, shards, custom items) and the weapon
----------------------------------------------------------------------
function M:GetActive()
  if WF:Due(self, "tBuff", 1) or not self.activeCache then
    self.activeCache = self:ScanBuffs()
  end
  return self.activeCache
end

-- bag and weapon scans: ONE pass over the bags for everything
function M:ScanSlow()
  local defs = {}
  local nStones = table.getn(STONES)
  for i = 1, nStones do defs[i] = STONES[i] end

  local items = self.db.items
  for i = 1, table.getn(items) do
    defs[nStones + i] = { match = string.lower(items[i]) }
  end

  local shardIdx = table.getn(defs) + 1
  defs[shardIdx] = { names = { "soul shard" } }

  local r = self:ScanItems(defs)
  self.res = {}
  for i = 1, nStones do self.res[i] = r[i] end
  self.cres = {}
  for i = 1, table.getn(items) do self.cres[i] = r[nStones + i] end
  self.shardRes = r[shardIdx]

  self.weapons = self:ScanWeaponStones()
  self:TrackSoulstone()
end

-- builds the lines from the caches (no API scans in here)
function M:Build(active)
  local res = self.res
  local all = {}   -- every line, in display order
  local curKey, curDefault = nil, false

  -- the key and default list of the next line(s); the user's pin choice
  -- (shift-click) is applied later, in Draw
  local function Group(key, defaultTop)
    curKey = key
    curDefault = defaultTop
  end

  -- tex: icon, action: icon left-click action, tip: icon tooltip,
  -- rowSpell: (unused now: the text line follows the icon), rightSpell: icon right-click cast,
  -- rightRaid: icon right-click raid buff, rightAction: icon right-click action
  local function Add(label, status, tex, action, tip, rowSpell, rightSpell, rightRaid, rightAction)
    table.insert(all, {
      label = label, status = status, tex = tex, action = action, tip = tip,
      rowSpell = rowSpell, rightSpell = rightSpell, rightRaid = rightRaid,
      rightAction = rightAction, key = curKey, defaultTop = curDefault
    })
  end

  -- item cooldowns count down from their absolute end time
  local now = GetTime()
  for i = 1, table.getn(res) do
    local r = res[i]
    if r.cdEnd then
      r.cd = r.cdEnd - now
      if r.cd < 0 then r.cd = 0 end
    end
  end
  if self.cres then
    for i = 1, table.getn(self.cres) do
      local r = self.cres[i]
      if r.cdEnd then
        r.cd = r.cdEnd - now
        if r.cd < 0 then r.cd = 0 end
      end
    end
  end

  local function AddBuff(b)
    local castName = FirstKnownSpell(b.spells)
    local act = FirstActiveBuff(b.buffs, active)
    local tex = SpellIcon(castName)

    -- right-click buffs a group member (only for buffs flagged raid = true)
    local rightRaid = nil
    local rightTip = ""
    if b.raid and castName then
      rightRaid = b
      rightTip = "\nRight-click to buff the next group member who lacks it"
    end

    if act then
      local status = GREEN .. "Active" .. TimeSuffix(act.left) .. "|r"
      if b.recast and castName then
        -- clicking recasts the buff to refresh its duration
        Add(b.label, status, tex or act.tex, { kind = "cast", spell = castName },
            "Click to recast " .. castName .. " (refreshes duration)" .. rightTip,
            castName, nil, rightRaid)
      else
        Add(b.label, status, tex or act.tex, nil, b.label .. rightTip, nil, nil, rightRaid)
      end
    elseif castName then
      local status
      if b.optional then status = GRAY .. "Off|r" else status = RED .. "Missing|r" end
      Add(b.label, status, tex, { kind = "cast", spell = castName },
          "Click to cast " .. castName .. rightTip, castName, nil, rightRaid)
    end
  end

  local function AddStone(i)
    local d = STONES[i]
    local r = res[i]
    local createName = BestSpell(d.create)
    local createTex = SpellIcon(createName)
    local buffAct = nil
    if d.buffs then buffAct = FirstActiveBuff(d.buffs, active) end

    -- right-click spell (only offered if you have learned it)
    local rightSpell = nil
    local rightTip = ""
    if d.rightSpell and WF:GetSpellIndex(d.rightSpell) then
      rightSpell = d.rightSpell
      rightTip = "\nRight-click: " .. d.rightSpell
    end

    if not (r.count > 0 or createName or buffAct) then return end

    local suffix = ""
    if r.count > 1 then suffix = " x" .. r.count end

    ------------------------------------------------------------------
    -- stones whose buff is tracked while the click actions stay available
    -- (Voidstone / Felstone): left-click creates, right-click uses
    ------------------------------------------------------------------
    if d.splitClick then
      local status
      if buffAct then
        status = GREEN .. "Active" .. TimeSuffix(buffAct.left) .. "|r"
      elseif r.count > 0 then
        if r.cd > 0 then
          status = YELLOW .. "CD " .. WF.FormatTime(r.cd) .. suffix .. "|r"
        else
          status = GREEN .. "Ready" .. suffix .. "|r"
        end
      else
        status = RED .. "Missing|r"
      end

      local tex = r.tex
      if not tex and buffAct then tex = buffAct.tex end
      if not tex then tex = createTex end

      local action = nil
      local rightAction = nil
      local tip = d.label
      if createName then
        action = { kind = "cast", spell = createName }
        tip = "Click to create: " .. createName
      end
      if r.count > 0 and r.cd <= 0 then
        rightAction = { kind = "use", match = d.match, names = d.names, plain = d.plainUse }
        tip = tip .. "\nRight-click to use"
      end

      Add(d.label, status, tex, action, tip .. rightTip, nil, rightSpell, nil, rightAction)
      return
    end

    ------------------------------------------------------------------
    -- all other stones
    ------------------------------------------------------------------
    if buffAct then
      Add(d.label, GREEN .. "Active" .. TimeSuffix(buffAct.left) .. "|r",
          r.tex or buffAct.tex or createTex, nil,
          d.label .. " is active" .. rightTip, nil, rightSpell)
    elseif r.count > 0 then
      local status
      local action = nil
      local rightAction = nil
      local tip = d.label
      if r.cd > 0 then
        status = YELLOW .. "CD " .. WF.FormatTime(r.cd) .. suffix .. "|r"
      else
        status = GREEN .. "Ready" .. suffix .. "|r"
        if d.use then
          action = { kind = "use", match = d.match, names = d.names, soul = d.soul }
          if d.soul then
            rightAction = { kind = "use", match = d.match, names = d.names,
                            soul = true, toSelected = true }
            local sel = M.db.soulTarget
            if sel and sel ~= "" then
              tip = "Click to use on your friendly target\nRight-click to use on " .. sel
            else
              tip = "Click to use on your friendly target\nRight-click: pick a player with the arrow first"
            end
          else
            tip = "Click to use"
          end
        end
      end
      Add(d.label, status, r.tex or createTex, action, tip .. rightTip, nil, rightSpell,
          nil, rightAction)
    else
      -- no item in your bags: show a remembered cooldown instead of Missing
      local trackedCd = 0
      if d.trackCd then trackedCd = self:SoulCooldownLeft() end

      local status
      local action = nil
      local tip
      if trackedCd > 0 then
        status = YELLOW .. "CD " .. WF.FormatTime(trackedCd) .. "|r"
        tip = d.label .. " on cooldown"
      else
        status = RED .. "Missing|r"
        tip = d.label .. " missing"
      end
      if createName then
        action = { kind = "cast", spell = createName }
        tip = tip .. "\nClick to create: " .. createName
      end
      Add(d.label, status, createTex, action, tip .. rightTip, nil, rightSpell)
    end
  end

  -- build the lines. Demon Armor, Healthstone and Soulstone default to the
  -- main list; everything else defaults to the extras.
  for i = 1, table.getn(BUFFS) do
    local b = BUFFS[i]
    Group(b.label, i == 1)
    AddBuff(b)
  end
  for i = 1, table.getn(STONES) do
    Group(STONES[i].label, i <= 2)
    AddStone(i)
  end

  -- custom items
  local items = self.db.items
  if table.getn(items) > 0 then
    local cres = self.cres or {}
    for i = 1, table.getn(items) do
      Group("item:" .. string.lower(items[i]), false)
      local r = cres[i] or { count = 0, cd = 0 }
      if r.count > 0 then
        local suffix = ""
        if r.count > 1 then suffix = " x" .. r.count end
        if r.cd > 0 then
          Add(items[i], YELLOW .. "CD " .. WF.FormatTime(r.cd) .. suffix .. "|r",
              r.tex, nil, items[i], nil, nil)
        else
          Add(items[i], GREEN .. "In bags" .. suffix .. "|r", r.tex, nil, items[i], nil, nil)
        end
      else
        Add(items[i], RED .. "Missing|r", nil, nil, items[i] .. " missing", nil, nil)
      end
    end
  end

  -- custom buffs
  local cbuffs = self.db.cbuffs
  for i = 1, table.getn(cbuffs) do
    Group("buff:" .. string.lower(cbuffs[i]), false)
    local act = active[string.lower(cbuffs[i])]
    if act then
      Add(cbuffs[i], GREEN .. "Active" .. TimeSuffix(act.left) .. "|r",
          act.tex, nil, cbuffs[i], nil, nil)
    else
      Add(cbuffs[i], RED .. "Missing|r", nil, nil, cbuffs[i] .. " missing", nil, nil)
    end
  end

  self.all = all
  self.entries = {}
  for i = 1, table.getn(all) do self.entries[all[i].key] = all[i] end
end

-- draws the lines (reads the cache only)
-- Soulstone player drop-down: the group members (never yourself)
function M:SoulMenuInit()
  local info = {}
  info.text = "(none)"
  info.value = ""
  info.checked = (not self.db.soulTarget or self.db.soulTarget == "")
  info.func = M.SoulMenuPick
  UIDropDownMenu_AddButton(info)

  local names = GroupNames()
  for i = 1, table.getn(names) do
    local item = {}
    item.text = names[i]
    item.value = names[i]
    item.checked = (names[i] == self.db.soulTarget)
    item.func = M.SoulMenuPick
    UIDropDownMenu_AddButton(item)
  end
end

function M.SoulMenuPick()
  if this.value == "" then M.db.soulTarget = nil else M.db.soulTarget = this.value end
  M:UpdateSoulDD()
  M:Build(M:GetActive())   -- refresh the tooltip text from cached data
  M:Draw()
end

function M:UpdateSoulDD()
  if not self.soulBtn then return end
  local sel = self.db.soulTarget
  if sel and sel ~= "" then
    self.soulBtn.tooltipText = "Soulstone target: " .. sel .. "\nClick to choose another player"
  else
    self.soulBtn.tooltipText = "Click to choose the player to soulstone"
  end
end

function M:Draw()
  if not self.frame or not self.all then return end

  -- split into the main list and the extras: the user's pin choice wins over
  -- each line's default
  local pin = self.db.pin
  local top, more = {}, {}
  for i = 1, table.getn(self.all) do
    local d = self.all[i]
    local isTop = d.defaultTop
    if pin[d.key] ~= nil then isTop = pin[d.key] end
    d.isTop = isTop
    if isTop then table.insert(top, d) else table.insert(more, d) end
  end

  -- combine: top always, extras only when expanded
  local data = {}
  for i = 1, table.getn(top) do table.insert(data, top[i]) end
  local moreCount = table.getn(more)
  if self.db.showMore then
    for i = 1, moreCount do table.insert(data, more[i]) end
  end

  -- draw
  local n = table.getn(data)
  if n > MAXROWS then n = MAXROWS end
  local soulRow = nil
  for i = 1, MAXROWS do
    local row = self.rows[i]
    local d = data[i]
    if d and i <= n then
      row.label:SetText(d.label)
      row.status:SetText(d.status)
      row.spell = d.rowSpell
      row.key = d.key
      row.isTop = d.isTop
      if d.label == "Soulstone" then soulRow = row end

      local ib = row.iconBtn
      ib.tex:SetTexture(d.tex or UNKNOWN_ICON)
      ib.action = d.action
      ib.rightSpell = d.rightSpell
      ib.rightRaid = d.rightRaid
      ib.rightAction = d.rightAction
      ib.key = d.key
      ib.isTop = d.isTop

      local hint
      if d.isTop then
        hint = "\nShift-click: move to the extras"
      else
        hint = "\nShift-click: always show"
      end
      ib.tooltipText = (d.tip or d.label) .. hint
      row:Show()
    else
      row.spell = nil
      row.key = nil
      local ib = row.iconBtn
      ib.action = nil
      ib.rightSpell = nil
      ib.rightRaid = nil
      ib.rightAction = nil
      ib.key = nil
      row:Hide()
    end
  end

  -- the Soulstone player drop-down sits on the Soulstone line (if shown)
  if self.soulBtn then
    if soulRow then
      self.soulBtn:ClearAllPoints()
      self.soulBtn:SetPoint("LEFT", soulRow.label, "RIGHT", 2, 0)
      self:UpdateSoulDD()
      self.soulBtn:Show()
    else
      self.soulBtn:Hide()
    end
  end

  -- extras toggle button
  local extra = 0
  if moreCount > 0 then
    extra = BUTTON_SPACE
    if self.db.showMore then
      self.moreBtn:SetText("Hide extras")
    else
      self.moreBtn:SetText("Show extras (" .. moreCount .. ")")
    end
    self.moreBtn:Show()
  else
    self.moreBtn:Hide()
  end

  if n == 0 then
    self.emptyText:Show()
    WF:SetModuleHeight(self, 54 + extra)
  else
    self.emptyText:Hide()
    WF:SetModuleHeight(self, 28 + n * ROWH + extra)
  end
end

-- refresh the cached data when it is due, and rebuild the lines
function M:Scan()
  if not self.frame then return end

  -- bags and weapon: every two seconds (and the first time)
  if WF:Due(self, "tSlow", 2) or not self.res then
    self:ScanSlow()
  end

  -- buffs: at most once a second, shared with everything else that needs them
  local active = self:GetActive()
  self:Build(active)

  -- header icons (pet, demon, buffs, shards): at most once a second
  if WF:Due(self, "tIcons", 1) then
    self:UpdateStatusIcons(active)
  end
end

-- scan what is due, then draw if the window is showing this module
function M:Refresh()
  self:Scan()
  if self.frame and self.frame:IsVisible() then
    self:Draw()
  end
end

function M:ToggleExtras()
  self.db.showMore = not self.db.showMore
  self:Draw()   -- cache only: no scanning
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------
function M:OnLoad()
  if not self.db.items then self.db.items = {} end
  if not self.db.cbuffs then self.db.cbuffs = {} end
  if not self.db.pin then self.db.pin = {} end   -- key -> true (main list) / false (extras)
  self.recent = {}   -- "name:key" -> time of the last raid-buff cast sent

  -- hidden tooltip used to read buff names (1.12 has no buff-name API)
  self.tip = CreateFrame("GameTooltip", "WarlockFamiliarBuffTip", nil, "GameTooltipTemplate")
  self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")

  -- status icons in the core window header, in this order
  self.indDA = WF:CreateStatusIcon("Demon Armor")
  self.indSac = WF:CreateStatusIcon("Sacrifice")
  self.indStone = WF:CreateStatusIcon("Stone")
  self.indShard = WF:CreateStatusIcon("Soul Shards")

  -- Demon Armor and the latest stone act like their lines in the list.
  -- the sacrifice icon has no line in the list: left-click summons your most
  -- recent demon, right-click casts Demonic Sacrifice.
  self.indSac.onClick = function(mouse) M:SacClick(mouse) end
  self.indDA.onClick = function(mouse) M:IndicatorClick("Demon Armor", mouse) end
  self.indStone.onClick = function(mouse) M:IndicatorClick(M.stoneKey, mouse) end

  -- right-click the Soul Shard icon to delete a stack of shards
  self.indShard.onClick = function(mouse)
    if mouse == "RightButton" then M:DeleteShardStack() end
  end

  local f = WF:CreateWindow(self, 0, 54)

  self.emptyText = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  self.emptyText:SetPoint("TOP", f, "TOP", 0, -10)
  self.emptyText:SetText("Nothing to track. Add entries in Options.")

  for i = 1, MAXROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(254)
    row:SetHeight(ROWH)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 23, -4 - (i - 1) * ROWH)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.label:SetPoint("LEFT", row, "LEFT", ICONSIZE + 10, 0)
    row.label:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.status:SetJustifyH("RIGHT")

    -- the text of a line does exactly what its icon does: left-click,
    -- right-click and shift-click are all passed to the icon's handler
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      M:IconClick(this.iconBtn, arg1)
    end)

    -- clickable icon at the left of the line
    local ib = CreateFrame("Button", nil, row)
    ib:SetWidth(ICONSIZE)
    ib:SetHeight(ICONSIZE)
    ib:SetPoint("LEFT", row, "LEFT", 3, 0)
    ib.tex = ib:CreateTexture(nil, "ARTWORK")
    ib.tex:SetAllPoints(ib)
    ib:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    ib:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    ib:SetScript("OnClick", function() M:IconClick(this, arg1) end)
    WF:SetTooltip(ib, "")
    row.iconBtn = ib

    row:Hide()
    self.rows[i] = row
  end

  -- player picker for the Soulstone line (right-click uses the stone on them)
  -- the menu itself is never shown as a frame ("MENU" style); a small
  -- down-arrow button opens it
  local dd = CreateFrame("Frame", "WarlockFamiliarSoulDropDown", UIParent, "UIDropDownMenuTemplate")
  UIDropDownMenu_Initialize(dd, function() M:SoulMenuInit() end, "MENU")
  dd:Hide()
  self.soulDD = dd

  local arrow = CreateFrame("Button", nil, f)
  arrow:SetWidth(18)
  arrow:SetHeight(18)
  arrow:SetFrameLevel(f:GetFrameLevel() + 8)
  arrow:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
  arrow:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
  arrow:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight", "ADD")
  arrow:SetScript("OnClick", function()
    ToggleDropDownMenu(1, nil, M.soulDD, this, 0, 0)
  end)
  WF:SetTooltip(arrow, "")
  arrow:Hide()
  self.soulBtn = arrow

  -- show/hide the rarely used lines
  self.moreBtn = WF:CreateButton(f, "Show extras", 130, 20)
  self.moreBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
  self.moreBtn:SetScript("OnClick", function() M:ToggleExtras() end)
  self.moreBtn:Hide()

  f:SetScript("OnShow", function() M:Draw() end)   -- cache only: no scanning
end

-- Controls for the Options panel: the /wf buffs commands.
function M:OptionsTabs()
  return {
    { name = "Buffs",    build = function(p, y) return M:OptionsTracking(p, y) end },
    { name = "Announce", build = function(p, y) return M:OptionsAnnounce(p, y) end },
  }
end

-- Buffs tab: the list and custom tracking
function M:OptionsTracking(parent, y)
  y = WF:AddHeading(parent, y, "Tracking")
  -- /wf buffs more
  y = WF:AddCheck(parent, y, "Show the extra lines  (/wf buffs more)",
    function() return M.db.showMore end,
    function(on)
      M.db.showMore = on
      if M.running then M:Draw() end
    end)

  -- /wf buffs item <name> | buff <name> | remove <name> | list
  local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  label:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  label:SetText("Track a custom item or buff (type its exact name):")
  y = y + 22

  local box = WF:AddEditBox(parent, 20, y, 236)
  y = y + 28

  local function Run(sub)
    if not M.running then
      WF:Print("Buff Manager is not active.")
      return
    end
    local text = box:GetText() or ""
    if text == "" then
      WF:Print("Type a name in the box first.")
      return
    end
    M:OnSlash(sub .. " " .. text)
  end

  WF:AddButton(parent, 18, y, 58, "Item", function() Run("item") end)
  WF:AddButton(parent, 80, y, 58, "Buff", function() Run("buff") end)
  WF:AddButton(parent, 142, y, 62, "Remove", function() Run("remove") end)
  WF:AddButton(parent, 208, y, 50, "List", function()
    if not M.running then
      WF:Print("Buff Manager is not active.")
      return
    end
    M:OnSlash("list")
  end)
  return y + 8
end

-- Announce tab: what is said when you start a ritual
function M:OptionsAnnounce(parent, y)
  y = WF:AddHeading(parent, y, "Ritual of Souls")

  y = WF:AddCheck(parent, y, "Announce Ritual of Souls in /say",
    function() return M.db.rosAnnounce ~= false end,
    function(on) M.db.rosAnnounce = on end)

  local rosLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  rosLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  rosLabel:SetText("Message in /say when the cast starts:")
  y = y + 22

  local rosBox = WF:AddEditBox(parent, 20, y, 256)
  rosBox:SetMaxLetters(200)
  rosBox:SetText(M.db.rosLine or ROS_DEFAULT_LINE)
  -- the line is saved as you type
  rosBox:SetScript("OnTextChanged", function() M.db.rosLine = this:GetText() end)
  y = y + 28

  WF:AddButton(parent, 18, y, 80, "Reset", function()
    M.db.rosLine = nil
    rosBox:SetText(ROS_DEFAULT_LINE)
  end)
  WF:AddButton(parent, 102, y, 80, "Test", function()
    local line = rosBox:GetText()
    if line and line ~= "" then SendChatMessage(line, "SAY") end
  end)
  y = y + 30

  y = WF:AddHeading(parent, y, "Ritual of Summoning")
  y = WF:AddCheck(parent, y, "Announce Ritual of Summoning in /say",
    function() return M.db.sumSay ~= false end,
    function(on) M.db.sumSay = on end)
  y = WF:AddCheck(parent, y, "Whisper the summon target",
    function() return M.db.sumWhisper ~= false end,
    function(on) M.db.sumWhisper = on end)

  local sumHelp = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  sumHelp:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 2))
  sumHelp:SetText("Placeholders: %t = target's name, %z = zone")
  y = y + 20

  local sayLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  sayLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  sayLabel:SetText("Message in /say:")
  y = y + 22
  local sayBox = WF:AddEditBox(parent, 20, y, 256)
  sayBox:SetMaxLetters(200)
  sayBox:SetText(M.db.sumSayLine or SUM_DEFAULT_SAY)
  sayBox:SetScript("OnTextChanged", function() M.db.sumSayLine = this:GetText() end)
  y = y + 28

  local whLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  whLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -(y + 4))
  whLabel:SetText("Whisper to the summon target:")
  y = y + 22
  local whBox = WF:AddEditBox(parent, 20, y, 256)
  whBox:SetMaxLetters(200)
  whBox:SetText(M.db.sumWhisperLine or SUM_DEFAULT_WHISPER)
  whBox:SetScript("OnTextChanged", function() M.db.sumWhisperLine = this:GetText() end)
  y = y + 28

  WF:AddButton(parent, 18, y, 80, "Reset", function()
    M.db.sumSayLine = nil
    M.db.sumWhisperLine = nil
    sayBox:SetText(SUM_DEFAULT_SAY)
    whBox:SetText(SUM_DEFAULT_WHISPER)
  end)
  WF:AddButton(parent, 102, y, 80, "Test /say", function()
    local line = sayBox:GetText()
    if line and line ~= "" then
      SendChatMessage(FillSummonText(line, "Friend", GetRealZoneText() or ""), "SAY")
    end
  end)

  return y + 28
end

-- A header status icon behaves like the matching line in the list: the same
-- left-click and right-click actions. Shift-click is not forwarded, so
-- shift-clicking a header icon never moves a line between the lists.
function M:IndicatorClick(key, mouse)
  local e = key and self.entries and self.entries[key]
  if not e then return end
  self:IconClick({
    action = e.action,
    rightRaid = e.rightRaid,
    rightSpell = e.rightSpell,
    rightAction = e.rightAction
  }, mouse)
end

-- true if `bag` is a soul bag (a container that only holds soul shards)
local function IsSoulBag(bag)
  if bag == 0 then return false end   -- the backpack
  local invSlot = ContainerIDToInventoryID(bag)
  local link = invSlot and GetInventoryItemLink("player", invSlot)
  if not link then return false end

  -- soul bags have the item subtype "Soul Bag"
  local id = WF.ItemIdFromLink(link)
  if id then
    local _, _, _, _, _, subType = GetItemInfo(id)
    if subType and string.find(string.lower(subType), "soul", 1, true) then
      return true
    end
  end

  -- fallback: recognise the usual soul bag names
  local name = string.lower(WF.ItemNameFromLink(link) or "")
  return (string.find(name, "soul", 1, true)
          or string.find(name, "felcloth", 1, true)
          or string.find(name, "shadowbag", 1, true)) ~= nil
end

-- Right-click on the Soul Shard icon: deletes ONE whole stack from your bags.
-- Order: shards OUTSIDE soul bags go first, then the smallest stacks first
-- (so stacks of 1 or 2 shards go before stacks of 3, then anything larger).
function M:DeleteShardStack()
  if CursorHasItem() then
    WF:Print("Your cursor is holding something. Put it down first.")
    return
  end

  local soulBag = {}   -- bag -> true/false, looked up once per bag
  local stacks = {}
  WF:ForEachBagItem(function(bag, slot, link, count)
    if WF.ItemIdFromLink(link) == SHARD_ID then
      if soulBag[bag] == nil then soulBag[bag] = IsSoulBag(bag) end
      table.insert(stacks, { bag = bag, slot = slot, count = count, soul = soulBag[bag] })
    end
  end)

  if table.getn(stacks) == 0 then
    WF:Print("You have no Soul Shards.")
    return
  end

  table.sort(stacks, function(a, b)
    if a.soul ~= b.soul then return not a.soul end          -- outside soul bags first
    if a.count ~= b.count then return a.count < b.count end -- smallest stack first
    if a.bag ~= b.bag then return a.bag > b.bag end
    return a.slot > b.slot
  end)

  local s = stacks[1]
  PickupContainerItem(s.bag, s.slot)
  DeleteCursorItem()

  local where = ""
  if s.soul then where = " (from a soul bag)" end
  if s.count == 1 then
    WF:Print("Deleted a stack of 1 Soul Shard" .. where .. ".")
  else
    WF:Print("Deleted a stack of " .. s.count .. " Soul Shards" .. where .. ".")
  end
end

-- Summons the demon you most recently had out. It refuses while a living
-- demon is already out, so a click can't waste a Soul Shard on a re-summon.
function M:ResummonDemon()
  local fam = self.db.lastDemon or "Imp"   -- default: an Imp

  if UnitExists("pet") and not UnitIsDead("pet") then
    WF:Print("Your " .. (UnitCreatureFamily("pet") or "demon") .. " is already out.")
    return
  end

  for k = 1, table.getn(DEMONS) do
    if DEMONS[k].family == fam then
      if WF:GetSpellIndex(DEMONS[k].spell) then
        CastKnown(DEMONS[k].spell)
      else
        WF:Print("You have not learned " .. DEMONS[k].spell .. ".")
      end
      return
    end
  end
end

-- Sacrifice icon: left-click summons your most recent demon,
-- right-click casts Demonic Sacrifice (which sacrifices your current demon).
function M:SacClick(mouse)
  if mouse == "RightButton" then
    if not WF:GetSpellIndex("Demonic Sacrifice") then
      WF:Print("You have not learned Demonic Sacrifice.")
      return
    end
    CastKnown("Demonic Sacrifice")
  else
    self:ResummonDemon()
  end
end

function M:OnEnable()
  self:Refresh()
end

-- Says the configured line in /say when you start casting Ritual of Souls.
-- A restarted cast within 10 seconds is not announced a second time.
function M:AnnounceRitual()
  if self.db.rosAnnounce == false then return end

  local line = self.db.rosLine
  if line == nil then line = ROS_DEFAULT_LINE end
  if line == "" then return end

  if not WF:Due(self, "tRos", 10) then return end
  SendChatMessage(line, "SAY")
end

-- Ritual of Summoning started: /say and/or whisper the summon target.
-- The same target is not announced again within SUM_COOLDOWN seconds.
-- Nothing happens without a living player target other than yourself.
function M:AnnounceSummon()
  local doSay = self.db.sumSay ~= false
  local doWhisper = self.db.sumWhisper ~= false
  if not doSay and not doWhisper then return end

  -- the target of the ritual is whoever you have targeted when it starts;
  -- no target, a non-player, yourself or a dead target: do nothing at all
  if not UnitExists("target") or not UnitIsPlayer("target") then return end
  if UnitIsUnit("target", "player") or UnitIsDeadOrGhost("target") then return end
  local name = UnitName("target")
  if not name then return end

  -- 30 second cooldown per target: summoning the same player again inside
  -- it is not announced; a different target is announced right away
  local now = GetTime()
  self.sumLast = self.sumLast or {}
  local last = self.sumLast[name]
  if last and now - last < SUM_COOLDOWN then return end
  for k, t in pairs(self.sumLast) do
    if now - t >= SUM_COOLDOWN then self.sumLast[k] = nil end
  end
  self.sumLast[name] = now

  local zone = GetRealZoneText() or ""

  if doSay then
    local line = self.db.sumSayLine
    if line == nil then line = SUM_DEFAULT_SAY end
    if line ~= "" then
      SendChatMessage(FillSummonText(line, name, zone), "SAY")
    end
  end

  if doWhisper then
    local line = self.db.sumWhisperLine
    if line == nil then line = SUM_DEFAULT_WHISPER end
    if line ~= "" then
      SendChatMessage(FillSummonText(line, name, zone), "WHISPER", nil, name)
    end
  end
end

function M:OnEvent(event, a1, a2)
  if event == "PLAYER_AURAS_CHANGED" then
    -- look for a freshly applied sacrifice buff (only while none is known to
    -- be active). The buff scan behind this is limited to once a second.
    if self.sacWas ~= true then
      self:DetectSacrifice()
    end
  elseif event == "SPELLCAST_START" then
    if a1 == ROS_SPELL then
      self:AnnounceRitual()
    elseif a1 == SUM_SPELL then
      self:AnnounceSummon()
    end
  elseif event == "SPELLCAST_CHANNEL_START" then
    if a2 == ROS_SPELL then
      self:AnnounceRitual()
    elseif a2 == SUM_SPELL then
      self:AnnounceSummon()
    end
  end
end

function M:OnDisable()
  self.sacWas = nil
  self.prevStone = nil
  if self.indDA then
    WF:SetStatusIconShown(self.indDA, false)
    WF:SetStatusIconShown(self.indSac, false)
    WF:SetStatusIconShown(self.indStone, false)
    WF:SetStatusIconShown(self.indShard, false)
  end
end

function M:OnUpdate()
  -- a short while after a raid-buff cast, see whether everyone is buffed now
  if self.checkAt and GetTime() >= self.checkAt then
    self.checkAt = nil
    if self:AllBuffed(self:ScanRaid()) then
      PrintRaidBuffed()
    end
  end

  -- scan what is due (buffs every second, bags every two) and rebuild the
  -- cached lines: this also updates the header status icons and their click
  -- actions, even while the window shows another module
  self:Refresh()
end

----------------------------------------------------------------------
-- commands for custom tracking (e.g. a server-specific "Voidstone")
----------------------------------------------------------------------
local function IndexOfNoCase(list, name)
  local lname = string.lower(name)
  for i = 1, table.getn(list) do
    if string.lower(list[i]) == lname then return i end
  end
  return nil
end

function M:OnSlash(args)
  local _, _, sub, rest = string.find(args, "^(%S+)%s*(.*)$")
  sub = sub and string.lower(sub) or ""

  if sub == "more" then
    self:ToggleExtras()
  elseif sub == "item" and rest ~= "" then
    if not IndexOfNoCase(self.db.items, rest) then
      table.insert(self.db.items, rest)
    end
    WF:Print("Buff Manager now tracks item: " .. rest .. " (shown under extras).")
    self.tSlow = nil   -- one bag scan now, so the new item appears
    self:Refresh()
  elseif sub == "buff" and rest ~= "" then
    if not IndexOfNoCase(self.db.cbuffs, rest) then
      table.insert(self.db.cbuffs, rest)
    end
    WF:Print("Buff Manager now tracks buff: " .. rest .. " (shown under extras).")
    self:Refresh()
  elseif sub == "remove" and rest ~= "" then
    local i = IndexOfNoCase(self.db.items, rest)
    if i then
      table.remove(self.db.items, i)
      WF:Print("Stopped tracking item: " .. rest)
    else
      i = IndexOfNoCase(self.db.cbuffs, rest)
      if i then
        table.remove(self.db.cbuffs, i)
        WF:Print("Stopped tracking buff: " .. rest)
      else
        WF:Print("No custom entry named '" .. rest .. "'.")
      end
    end
    self.tSlow = nil   -- one bag scan now, so the list is right
    self:Refresh()
  elseif sub == "list" then
    local any = false
    for i = 1, table.getn(self.db.items) do
      WF:Print("item: " .. self.db.items[i])
      any = true
    end
    for i = 1, table.getn(self.db.cbuffs) do
      WF:Print("buff: " .. self.db.cbuffs[i])
      any = true
    end
    if not any then WF:Print("No custom entries.") end
  else
    WF:Print("Buff Manager: show | hide | more | item <name> | buff <name> | remove <name> | list")
  end
end
