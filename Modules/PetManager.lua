--[[
  Pet Manager
  Lists every demon summon, shows which ones you have learned, and gives a
  one-click button for each, including the Infernal (Inferno) and Doomguard
  (Ritual of Doom) rituals.

  Also has a Demonic Sacrifice button and tracks the buff you get from
  sacrificing your demon (Burning Wish, Fel Stamina, Touch of Shadow or
  Fel Energy) with its remaining time.

  /wf pets    toggle window
]]

local WF = WarlockFamiliar

local SHARD_ID = 6265
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local SAC_SPELL = "Demonic Sacrifice"

local PETS = {
  { spell = "Summon Imp", label = "Imp", family = "Imp" },
  { spell = "Summon Voidwalker", label = "Voidwalker", family = "Voidwalker", shard = true },
  { spell = "Summon Succubus", label = "Succubus", family = "Succubus", shard = true },
  { spell = "Summon Felhunter", label = "Felhunter", family = "Felhunter", shard = true },
  { spell = "Inferno", label = "Infernal", reagent = "Infernal Stone", reagentId = 5565,
    tip = "Inferno: summons an Infernal. Needs an Infernal Stone." },
  { spell = "Ritual of Doom", label = "Doomguard", reagent = "Demonic Figurine", reagentId = 16583,
    tip = "Ritual of Doom: summons a Doomguard. Needs a Demonic Figurine and party members to help channel." },
}

-- Buffs granted by Demonic Sacrifice, by the demon that was sacrificed.
-- If your server uses different buff names, edit them here.
local SAC_BUFFS = {
  { buff = "Burning Wish",    from = "Imp" },
  { buff = "Fel Stamina",     from = "Voidwalker" },
  { buff = "Touch of Shadow", from = "Succubus" },
  { buff = "Fel Energy",      from = "Felhunter" },
}

local ROW_TOP = 40    -- y offset of the first row, inside the module content area
local ROW_STEP = 34

local M = WF:RegisterModule("pets", {
  title = "Pet Manager",
  short = "Pets",
  minLevel = 1,
  interval = 1,
})

M.rows = {}

----------------------------------------------------------------------
-- sacrifice buff tracking
----------------------------------------------------------------------
-- returns the SAC_BUFFS entry, seconds left, icon  (or nil when none)
function M:ScanSacrifice()
  if not self.tip then return nil end
  for i = 0, 63 do
    local idx = GetPlayerBuff(i, "HELPFUL")
    if not idx or idx < 0 then break end
    self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    self.tip:SetPlayerBuff(idx)
    local fs = getglobal("WarlockFamiliarPetTipTextLeft1")
    local name = fs and fs:GetText()
    if name then
      for k = 1, table.getn(SAC_BUFFS) do
        if name == SAC_BUFFS[k].buff then
          return SAC_BUFFS[k], GetPlayerBuffTimeLeft(idx) or 0, GetPlayerBuffTexture(idx)
        end
      end
    end
  end
  return nil
end

----------------------------------------------------------------------
-- mana cost (1.12 has no spell cost API, so the spellbook tooltip is read)
----------------------------------------------------------------------
-- returns the mana cost of the spell at spellbook index `idx`, or 0
function M:ReadManaCost(idx)
  if not self.tip then return 0 end
  self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
  self.tip:SetSpell(idx, BOOKTYPE_SPELL)
  for line = 2, 4 do
    local fs = getglobal("WarlockFamiliarPetTipTextLeft" .. line)
    local text = fs and fs:GetText()
    if text then
      local _, _, cost = string.find(text, "^(%d+) Mana")
      if cost then return tonumber(cost) end
    end
  end
  return 0
end

----------------------------------------------------------------------
-- refresh
----------------------------------------------------------------------
-- draws from the cached scan data (see M:Scan); no API scanning in here
function M:Draw()
  if not self.frame or not self.counts then return end
  self.cost = self.cost or {}
  self.noMana = self.noMana or {}

  local petName, petFamily = self.petName, self.petFamily
  local sac = self.sac
  local sacLeft = 0
  if sac and self.sacEnd then sacLeft = self.sacEnd - GetTime() end

  -- current pet header
  if petName then
    local text = petName
    if petFamily and petFamily ~= text then text = text .. " (" .. petFamily .. ")" end
    self.petText:SetText("Demon: |cffffffff" .. text .. "|r")
  else
    self.petText:SetText("Demon: |cff999999none|r")
  end

  -- sacrifice buff header
  if sac then
    local t = ""
    if sacLeft > 0 then t = " " .. WF.FormatTime(sacLeft) end
    self.sacText:SetText("Sacrifice buff: |cff00ccff" .. sac.buff .. "|r (" .. sac.from .. ")" .. t)
  else
    self.sacText:SetText("Sacrifice buff: |cff999999none|r")
  end

  local shards = self.counts[SHARD_ID] or 0

  for i = 1, table.getn(PETS) do
    local p = PETS[i]
    local row = self.rows[i]
    local idx = WF:GetSpellIndex(p.spell)

    if not idx then
      row.icon:SetTexture(UNKNOWN_ICON)
      row.icon:SetVertexColor(0.4, 0.4, 0.4)
      row.name:SetTextColor(0.5, 0.5, 0.5)
      row.status:SetText("|cff999999Not learned|r")
    else
      row.icon:SetTexture(GetSpellTexture(idx, BOOKTYPE_SPELL))
      row.icon:SetVertexColor(1, 1, 1)
      row.name:SetTextColor(1, 0.82, 0)

      local cd = (self.cdEnd[p.spell] or 0) - GetTime()   -- counts down from the cached end time
      if cd > 0 then
        row.status:SetText("|cffff4040CD " .. WF.FormatTime(cd) .. "|r")
      elseif self.noMana[p.spell] or (not self.usableApi and (self.cost[p.spell] or 0) > (self.mana or 0)) then
        row.icon:SetVertexColor(0.45, 0.55, 1)
        row.name:SetTextColor(0.45, 0.55, 1)
        row.status:SetText("|cff5080ffNo mana|r")
      elseif p.reagentId and (self.counts[p.reagentId] or 0) == 0 then
        row.status:SetText("|cffff8800No " .. p.reagent .. "|r")
      elseif p.shard and shards == 0 then
        row.status:SetText("|cffff8800No Soul Shard|r")
      elseif petFamily and p.family and petFamily == p.family then
        row.status:SetText("|cff00ccffActive|r")
      else
        row.status:SetText("|cff40ff40Ready|r")
      end
    end
  end

  -- Demonic Sacrifice row
  local srow = self.sacRow
  local sidx = WF:GetSpellIndex(SAC_SPELL)
  if not sidx then
    srow.icon:SetTexture(UNKNOWN_ICON)
    srow.icon:SetVertexColor(0.4, 0.4, 0.4)
    srow.name:SetTextColor(0.5, 0.5, 0.5)
    srow.status:SetText("|cff999999Not learned|r")
  else
    srow.icon:SetTexture(GetSpellTexture(sidx, BOOKTYPE_SPELL))
    srow.icon:SetVertexColor(1, 1, 1)
    srow.name:SetTextColor(1, 0.82, 0)

    local cd = (self.cdEnd[SAC_SPELL] or 0) - GetTime()
    if cd > 0 then
      srow.status:SetText("|cffff4040CD " .. WF.FormatTime(cd) .. "|r")
    elseif sac then
      srow.status:SetText("|cff00ccffActive|r")
    elseif not petName then
      srow.status:SetText("|cffff8800No demon|r")
    else
      srow.status:SetText("|cff40ff40Ready|r")
    end
  end
end

----------------------------------------------------------------------
-- scanning (rate limited; Draw only reads what is cached here)
--   once every 2 seconds : bags (one pass) and spell cooldowns
--   once a second        : the sacrifice buff and the current pet
----------------------------------------------------------------------
function M:Scan()
  if WF:Due(self, "tSlow", 2) or not self.counts then
    self.counts = WF:CountItemIds(self.itemIds)

    -- cooldowns as absolute end times, so timers stay exact between scans
    local now = GetTime()
    self.cdEnd = {}
    for i = 1, table.getn(PETS) do
      self.cdEnd[PETS[i].spell] = now + WF:GetSpellCooldownLeft(PETS[i].spell)
    end
    self.cdEnd[SAC_SPELL] = now + WF:GetSpellCooldownLeft(SAC_SPELL)

    -- mana costs (they only change with talents/ranks); skipped when
    -- Nampower can answer "out of mana?" directly
    self.usableApi = WF.HasNampower()
    self.cost = {}
    if not self.usableApi then
      for i = 1, table.getn(PETS) do
        local idx = WF:GetSpellIndex(PETS[i].spell)
        if idx then self.cost[PETS[i].spell] = self:ReadManaCost(idx) end
      end
    end
  end

  if WF:Due(self, "tFast", 1) or not self.fastDone then
    self.fastDone = true

    self.mana = UnitMana("player")

    -- Nampower: IsSpellUsable(spell) returns usable, outOfMana
    self.noMana = {}
    if self.usableApi then
      for i = 1, table.getn(PETS) do
        local _, oom = IsSpellUsable(PETS[i].spell)
        if oom == 1 then self.noMana[PETS[i].spell] = true end
      end
    end

    local sac, left = self:ScanSacrifice()
    self.sac = sac
    if sac then self.sacEnd = GetTime() + (left or 0) else self.sacEnd = nil end

    if UnitExists("pet") then
      self.petName = UnitName("pet")
      self.petFamily = UnitCreatureFamily("pet")
    else
      self.petName = nil
      self.petFamily = nil
    end
  end
end

-- scan what is due, then draw
function M:Refresh()
  if not self.frame then return end
  self:Scan()
  self:Draw()
end

----------------------------------------------------------------------
-- window
----------------------------------------------------------------------
-- builds one clickable spell row; `index` is its 1-based position
local function MakeRow(parent, index, label, spell, tip)
  local row = CreateFrame("Button", nil, parent)
  row:SetWidth(230)
  row:SetHeight(30)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 35, -ROW_TOP - (index - 1) * ROW_STEP)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetWidth(26)
  row.icon:SetHeight(26)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

  row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
  row.name:SetText(label)

  row.status = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  row.status:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.status:SetJustifyH("RIGHT")

  row.spell = spell
  row:SetScript("OnClick", function()
    if WF:GetSpellIndex(this.spell) then
      CastSpellByName(this.spell)
    else
      WF:Print("You have not learned " .. this.spell .. " yet.")
    end
  end)
  WF:SetTooltip(row, tip or (spell .. "\nClick to cast"))

  return row
end

function M:OnLoad()
  self.itemIds = { SHARD_ID }
  for i = 1, table.getn(PETS) do
    if PETS[i].reagentId then table.insert(self.itemIds, PETS[i].reagentId) end
  end

  local count = table.getn(PETS)
  local f = WF:CreateWindow(self, 0, ROW_TOP + (count + 1) * ROW_STEP + 20)

  -- hidden tooltip used to read buff names (1.12 has no buff-name API)
  self.tip = CreateFrame("GameTooltip", "WarlockFamiliarPetTip", nil, "GameTooltipTemplate")
  self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")

  self.petText = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  self.petText:SetPoint("TOP", f, "TOP", 0, -4)

  self.sacText = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  self.sacText:SetPoint("TOP", f, "TOP", 0, -20)

  for i = 1, count do
    local p = PETS[i]
    self.rows[i] = MakeRow(f, i, p.label, p.spell, p.tip)
  end

  self.sacRow = MakeRow(f, count + 1, "Demonic Sacrifice", SAC_SPELL,
    "Demonic Sacrifice: sacrifice your current demon for a buff.\nThe buff you get is shown at the top.")

  f:SetScript("OnShow", function() M:Refresh() end)
end

function M:OnUpdate()
  if self.frame and self.frame:IsVisible() then
    self:Refresh()
  end
end
