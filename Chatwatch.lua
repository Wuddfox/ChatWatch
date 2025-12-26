-- ChatWatch - Classic Era
-- Watches chat for user-defined phrases. On match: play sound + flash the phrase row.

local ADDON_NAME = ...
local CW = {}
_G.ChatWatch = CW

-- ======================
-- SavedVariables
-- ======================
local defaults = {
  phrases = {},      -- array of strings
  sound = "Interface\\AddOns\\ChatWatch\\media\\alert.ogg",
  enabled = true,
  minTokenLen = 2,   -- minimum token length for matching (numbers always allowed)

  button = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 260,
    y = 0,
  },
  frame = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    width = 420,
    height = 320,
    scale = 1.0,
  },
}

local function CopyDefaults(src, dst)
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

-- ======================
-- Utilities
-- ======================
local function Trim(s)
  return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or ""
end

local function SafePlaySound(path)
  if not path or path == "" then return end
  pcall(function() PlaySoundFile(path, "Master") end)
end

-- ========= Chat cleanup (strip WoW formatting) =========
local function stripWowChatDecorations(msg)
  if not msg or msg == "" then return "" end

  -- Remove color codes: |cAARRGGBB ... |r
  msg = msg:gsub("|c%x%x%x%x%x%x%x%x", "")
  msg = msg:gsub("|r", "")

  -- Replace hyperlinks with their visible link text:
  -- |H...|h[Visible Text]|h  -> Visible Text
  msg = msg:gsub("|H[^|]+|h%[([^%]]+)%]|h", "%1")
  -- Fallback: |H...|hVisible|h -> Visible
  msg = msg:gsub("|H[^|]+|h([^|]*)|h", "%1")

  -- Remove textures like |T...:..|t
  msg = msg:gsub("|T[^|]+|t", "")

  -- Rare: double-pipe escaping
  msg = msg:gsub("||", "|")

  return msg
end

-- ========= Pattern helpers =========
local function escapePattern(text)
  return text:gsub("([^%w])", "%%%1")
end

-- ======================
-- Manual abbreviation aliases (edit this table)
-- Canonical token -> list of accepted prefixes/aliases
-- Example: if the watched phrase contains "enchanter", then "ench"/"enchant"/"enchan" also match.
-- ======================
local TOKEN_ALIASES = {
  enchanter = { "enchan", "enchant", "ench" },
  -- scarlet = { "sc", "sm" },
  -- stratholme = { "strat", "st" },
}

-- Whole-word match using frontier patterns (prevents bar->bargain)
local function hasWholeWord(messageLowerPadded, word)
  word = word:lower()
  local escaped = escapePattern(word)
  local pattern = "%f[%w]" .. escaped .. "%f[%W]"
  return messageLowerPadded:find(pattern) ~= nil
end

-- Check for either a whole-word token, or any of its configured aliases as a word-prefix
local function tokenOrAliasMatch(messageLowerPadded, token)
  token = token:lower()

  -- Exact whole word always allowed
  if hasWholeWord(messageLowerPadded, token) then
    return true
  end

  -- If token has aliases, allow those as PREFIX word matches (whole word start)
  local aliases = TOKEN_ALIASES[token]
  if aliases then
    for _, a in ipairs(aliases) do
      a = a:lower()
      -- prefix match at word boundary: "ench" matches "enchanter"
      local pattern = "%f[%w]" .. escapePattern(a) .. "[%w_]*%f[%W]"
      if messageLowerPadded:find(pattern) then
        return true
      end
    end
  end

  return false
end

-- ========= Tokenization with abbreviation-merge + min token length =========
-- minLen: ignore tokens shorter than this (default 2), except pure numbers.
local function tokenizeSmart(phrase, minLen)
  minLen = minLen or 2
  phrase = Trim(phrase or "")
  if phrase == "" then return {} end

  -- base tokens: letters/digits/underscore
  local raw = {}
  for tok in phrase:lower():gmatch("[%w]+") do
    table.insert(raw, tok)
  end
  if #raw == 0 then return {} end

  -- merge consecutive single-letter tokens: "s f k boost" => "sfk", "boost"
  local merged = {}
  local i = 1
  while i <= #raw do
    if #raw[i] == 1 then
      local j = i
      local acc = raw[i]
      while j + 1 <= #raw and #raw[j + 1] == 1 do
        j = j + 1
        acc = acc .. raw[j]
      end
      table.insert(merged, acc)
      i = j + 1
    else
      table.insert(merged, raw[i])
      i = i + 1
    end
  end

  -- apply min token length (numbers always allowed)
  local out = {}
  for _, t in ipairs(merged) do
    local isNumber = t:match("^%d+$") ~= nil
    if isNumber or #t >= minLen then
      table.insert(out, t)
    end
  end

  return out
end

-- ========= Smart phrase match =========
-- Matching rules:
--  - Optional power-user contains mode: %...% (literal substring)
--  - Else => tokenize phrase and require all tokens (alias-aware) to exist as words, any order
local function smartPhraseMatch(message, phrase, minTokenLen)
  if not message or message == "" or not phrase or phrase == "" then return false end

  local cleaned = stripWowChatDecorations(message)
  local msgLowerPadded = " " .. cleaned:lower() .. " "

  local p = Trim(phrase)
  if p == "" then return false end

  -- contains mode: %...%
  if p:sub(1, 1) == "%" and p:sub(-1) == "%" and #p >= 3 then
    local sub = p:sub(2, -2):lower()
    return msgLowerPadded:find(sub, 1, true) ~= nil
  end

  local tokens = tokenizeSmart(p, minTokenLen or 2)
  if #tokens == 0 then return false end

  -- Single token: alias-aware
  if #tokens == 1 then
    return tokenOrAliasMatch(msgLowerPadded, tokens[1])
  end

  -- Multi token: all tokens must be present (alias-aware), any order
  for i = 1, #tokens do
    if not tokenOrAliasMatch(msgLowerPadded, tokens[i]) then
      return false
    end
  end

  return true
end

-- ======================
-- Chat events to watch
-- ======================
local CHAT_EVENTS = {
  "CHAT_MSG_SAY",
  "CHAT_MSG_YELL",
  "CHAT_MSG_EMOTE",
  "CHAT_MSG_TEXT_EMOTE",
  "CHAT_MSG_GUILD",
  "CHAT_MSG_OFFICER",
  "CHAT_MSG_PARTY",
  "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID",
  "CHAT_MSG_RAID_LEADER",
  "CHAT_MSG_RAID_WARNING",
  "CHAT_MSG_INSTANCE_CHAT",
  "CHAT_MSG_INSTANCE_CHAT_LEADER",
  "CHAT_MSG_WHISPER",
  "CHAT_MSG_CHANNEL",
}

-- ======================
-- UI constants
-- ======================
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 10

-- Runtime UI state
CW.rows = {}
CW.flashUntil = {}   -- phraseIndex -> endTime
CW.selectedIndex = nil

-- forward declaration for layout updater (defined later)
local UpdateFontAndLayout

-- ======================
-- Frame creation
-- ======================
local f = CreateFrame("Frame", "ChatWatchFrame", UIParent, "BackdropTemplate")
CW.frame = f


f:SetSize(420, 320)
-- Restore saved frame position/size if present (defaults applied on ADDON_LOADED)
f:SetPoint("CENTER")
-- Some WoW Classic builds may not provide SetMinResize/SetResizable; guard calls
if f.SetResizable then
  f:SetResizable(true)
end
if f.SetMinResize then
  f:SetMinResize(300, 180)
end
-- Ensure keyboard input not accidentally enabled
if f.EnableKeyboard then
  f:EnableKeyboard(false)
end

-- We'll set the actual point/size on PLAYER_LOGIN once ChatWatchDB is loaded.
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

f:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
f:SetBackdropColor(0, 0, 0, 0.95)

-- Title
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -12)
title:SetText("ChatWatch")
title:SetJustifyH("CENTER")

-- Make title draggable as a handle (dragging frame already allowed)
title:EnableMouse(true)
title:SetScript("OnMouseDown", function(self, button)
  if button == "LeftButton" then f:StartMoving() end
end)
title:SetScript("OnMouseUp", function(self)
  f:StopMovingOrSizing()
  -- Save position
  local point, _, relativePoint, x, y = f:GetPoint(1)
  ChatWatchDB = ChatWatchDB or {}
  ChatWatchDB.frame = ChatWatchDB.frame or {}
  ChatWatchDB.frame.point = point
  ChatWatchDB.frame.relativePoint = relativePoint
  ChatWatchDB.frame.x = x
  ChatWatchDB.frame.y = y
end)

-- Close button
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

-- ======================
-- Floating toggle button (show / hide ChatWatch)
-- ======================
local btn = CreateFrame("Button", "ChatWatchToggleButton", UIParent, "BackdropTemplate")
CW.toggleButton = btn

btn:SetSize(34, 34)
btn:SetMovable(true)
btn:EnableMouse(true)
btn:RegisterForDrag("LeftButton")
btn:SetClampedToScreen(true)

btn:SetBackdrop({
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = false,
  edgeSize = 12,
  insets = { left = 2, right = 2, top = 2, bottom = 2 }
})
btn:SetBackdropColor(0, 0, 0, 0.7)

-- Icon (safe built-in icon)
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints()
icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
btn.icon = icon

-- Tooltip
btn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("ChatWatch", 1, 0.82, 0)
  GameTooltip:AddLine("Left-click: Toggle window", 1, 1, 1)
  GameTooltip:AddLine("Drag: Move button", 1, 1, 1)
  GameTooltip:Show()
end)
btn:SetScript("OnLeave", GameTooltip_Hide)

-- Toggle window
btn:SetScript("OnClick", function()
  if ChatWatchFrame:IsShown() then
    ChatWatchFrame:Hide()
  else
    ChatWatchFrame:Show()
  end
end)

-- Dragging saves position
btn:SetScript("OnDragStart", function(self)
  self:StartMoving()
end)

btn:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()

  local point, _, relativePoint, x, y = self:GetPoint(1)
  ChatWatchDB.button = ChatWatchDB.button or {}
  ChatWatchDB.button.point = point
  ChatWatchDB.button.relativePoint = relativePoint
  ChatWatchDB.button.x = x
  ChatWatchDB.button.y = y
end)

-- Resize grip (bottom-right) - only create if sizing is supported
if f.StartSizing or (f.SetResizable and f.SetResizable ~= nil) then
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -6, 6)
  grip.texture = grip:CreateTexture(nil, "ARTWORK")
  grip.texture:SetAllPoints()
  grip.texture:SetTexture("Interface\\Buttons\\UI-SizeHandle")
  grip:EnableMouse(true)
  grip:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and f.StartSizing then f:StartSizing() end
  end)
  grip:SetScript("OnMouseUp", function(self)
    if f.StopMovingOrSizing then f:StopMovingOrSizing() end
    -- Save size and position
    local point, _, relativePoint, x, y = f:GetPoint(1)
    ChatWatchDB = ChatWatchDB or {}
    ChatWatchDB.frame = ChatWatchDB.frame or {}
    ChatWatchDB.frame.point = point
    ChatWatchDB.frame.relativePoint = relativePoint
    ChatWatchDB.frame.x = x
    ChatWatchDB.frame.y = y
    ChatWatchDB.frame.width = f:GetWidth()
    ChatWatchDB.frame.height = f:GetHeight()
    -- Update fonts/rows immediately
    if UpdateFontAndLayout then UpdateFontAndLayout() end
  end)
end

-- Frame scale control (Classic Era: resizing is unreliable across builds)
local function SetFrameScale(scale)
  scale = tonumber(scale) or 1.0
  scale = math.max(0.6, math.min(1.5, scale))
  f:SetScale(scale)
  ChatWatchDB = ChatWatchDB or {}
  ChatWatchDB.frame = ChatWatchDB.frame or {}
  ChatWatchDB.frame.scale = scale
end

local scaleDown = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
scaleDown:SetSize(20, 20)
-- place scale controls top-left to avoid overlap with close button
scaleDown:SetPoint("TOPLEFT", 12, -12)
scaleDown:SetText("-")
scaleDown:SetScript("OnClick", function()
  local cur = (ChatWatchDB and ChatWatchDB.frame and ChatWatchDB.frame.scale) or defaults.frame.scale or 1.0
  SetFrameScale(cur - 0.05)
end)
scaleDown:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Scale down"); GameTooltip:Show() end)
scaleDown:SetScript("OnLeave", function() GameTooltip:Hide() end)

local scaleUp = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
scaleUp:SetSize(20, 20)
scaleUp:SetPoint("LEFT", scaleDown, "RIGHT", 6, 0)
scaleUp:SetText("+")
scaleUp:SetScript("OnClick", function()
  local cur = (ChatWatchDB and ChatWatchDB.frame and ChatWatchDB.frame.scale) or defaults.frame.scale or 1.0
  SetFrameScale(cur + 0.05)
end)
scaleUp:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Scale up"); GameTooltip:Show() end)
scaleUp:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Input box
local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
CW.input = input
input:SetSize(260, 24)
input:SetPoint("TOPLEFT", 18, -44)
input:SetAutoFocus(false)
input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local inputLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
inputLabel:SetPoint("BOTTOMLEFT", input, "TOPLEFT", 2, 2)
inputLabel:SetText("Add phrase:")

-- ======================
-- Prevent ChatWatch input from hijacking /whisper inserts
-- ======================
local function ClearAddonInputFocus()
  if CW and CW.input and CW.input:HasFocus() then
    CW.input:ClearFocus()
  end
end

-- Hook once (no duplicates)
if ChatEdit_ActivateChat then
  hooksecurefunc("ChatEdit_ActivateChat", ClearAddonInputFocus)
end
if ChatFrame_SendTell then
  hooksecurefunc("ChatFrame_SendTell", ClearAddonInputFocus)
end
if ChatFrame_ReplyTell then
  hooksecurefunc("ChatFrame_ReplyTell", ClearAddonInputFocus)
end

-- Clicking anywhere on the addon frame drops focus
f:HookScript("OnMouseDown", function()
  ClearAddonInputFocus()
end)

-- Add button
local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
CW.addBtn = addBtn
addBtn:SetSize(110, 24)
addBtn:SetPoint("LEFT", input, "RIGHT", 10, 0)
addBtn:SetText("Add")

-- Enabled checkbox
local enabled = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
CW.enabled = enabled
enabled:SetPoint("LEFT", addBtn, "RIGHT", 14, 0)
enabled.text:SetText("Enabled")

-- Scroll area background
local listBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
listBg:SetPoint("TOPLEFT", 18, -78)
listBg:SetPoint("BOTTOMRIGHT", -18, 58)
listBg:SetBackdrop({
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
listBg:SetBackdropColor(0.05, 0.05, 0.05, 0.9)

-- Faux scroll frame
local scroll = CreateFrame("ScrollFrame", "ChatWatchScrollFrame", listBg, "FauxScrollFrameTemplate")
CW.scroll = scroll
scroll:SetPoint("TOPLEFT", 6, -6)
scroll:SetPoint("BOTTOMRIGHT", -28, 6)

-- Create row buttons
for i = 1, VISIBLE_ROWS do
  local row = CreateFrame("Button", nil, listBg, "BackdropTemplate")
  CW.rows[i] = row

  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("LEFT", 8, 0)
  row:SetPoint("RIGHT", -30, 0)
  if i == 1 then
    row:SetPoint("TOP", listBg, "TOP", 0, -8)
  else
    row:SetPoint("TOP", CW.rows[i-1], "BOTTOM", 0, -2)
  end

  row:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    tile = false,
  })
  row:SetBackdropColor(0, 0, 0, 0.2)

  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.text:SetPoint("LEFT", 8, 0)
  row.text:SetJustifyH("LEFT")

  -- initial font sizing will be applied on PLAYER_LOGIN or OnSizeChanged

  row.index = nil

  row:SetScript("OnClick", function(self)
    if not self.index then return end
    CW.selectedIndex = self.index
    CW:UpdateList()
  end)
end

-- Delete button
local delBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
CW.delBtn = delBtn
delBtn:SetSize(140, 26)
delBtn:SetPoint("BOTTOMLEFT", 18, 18)
delBtn:SetText("Delete Selected")

-- Clear All button
local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
CW.clearBtn = clearBtn
clearBtn:SetSize(110, 26)
clearBtn:SetPoint("LEFT", delBtn, "RIGHT", 10, 0)
clearBtn:SetText("Clear All")


-- ======================
-- List logic
-- ======================
function CW:UpdateList()
  local phrases = ChatWatchDB.phrases or {}
  local numItems = #phrases

  FauxScrollFrame_Update(self.scroll, numItems, VISIBLE_ROWS, ROW_HEIGHT + 2)

  local offset = FauxScrollFrame_GetOffset(self.scroll)

  for i = 1, VISIBLE_ROWS do
    local row = self.rows[i]
    local idx = i + offset
    local value = phrases[idx]

    row.index = idx

    if value then
      row:Show()
      row.text:SetText(value)

      -- selection highlight
      if self.selectedIndex == idx then
        row:SetBackdropColor(0.2, 0.5, 0.9, 0.35)
      else
        row:SetBackdropColor(0, 0, 0, 0.2)
      end

      -- flash highlight
      local untilT = self.flashUntil[idx]
      if untilT and untilT > GetTime() then
        local phase = (untilT - GetTime())
        local alpha = 0.35 + 0.25 * math.abs(math.sin(phase * 8))
        row:SetBackdropColor(1.0, 0.85, 0.1, alpha)
      end
    else
      row:Hide()
      row.index = nil
    end
  end
end

function CW:AddPhrase(text)
  text = Trim(text)
  if text == "" then return end

  -- prevent duplicates (case-insensitive exact phrase)
  local norm = text:lower()
  for _, p in ipairs(ChatWatchDB.phrases) do
    if (p or ""):lower() == norm then
      return
    end
  end

  table.insert(ChatWatchDB.phrases, text)
  self.selectedIndex = #ChatWatchDB.phrases
  self:UpdateList()
end

function CW:DeleteSelected()
  local idx = self.selectedIndex
  if not idx then return end

  local phrases = ChatWatchDB.phrases
  if idx < 1 or idx > #phrases then return end

  table.remove(phrases, idx)
  self.flashUntil[idx] = nil

  if #phrases == 0 then
    self.selectedIndex = nil
  else
    self.selectedIndex = math.min(idx, #phrases)
  end

  self:UpdateList()
end

function CW:ClearAll()
  ChatWatchDB.phrases = {}
  self.flashUntil = {}
  self.selectedIndex = nil
  self:UpdateList()
end

-- ======================
-- Chat matching
-- ======================
function CW:OnChatMessage(msg)
  if not ChatWatchDB.enabled then return end
  if not msg or msg == "" then return end

  local phrases = ChatWatchDB.phrases
  if not phrases or #phrases == 0 then return end

  local minLen = ChatWatchDB.minTokenLen or 2

  for i = 1, #phrases do
    local needle = phrases[i]
    if needle and needle ~= "" then
      if smartPhraseMatch(msg, needle, minLen) then
        self.flashUntil[i] = GetTime() + 3.0
        SafePlaySound(ChatWatchDB.sound)
        self:UpdateList()
      end
    end
  end
end

-- ======================
-- UI Wiring
-- ======================
addBtn:SetScript("OnClick", function()
  CW:AddPhrase(input:GetText() or "")
  input:SetText("")
  input:ClearFocus()
end)

input:SetScript("OnEnterPressed", function(self)
  CW:AddPhrase(self:GetText() or "")
  self:SetText("")
  self:ClearFocus()
end)

enabled:SetScript("OnClick", function(self)
  ChatWatchDB.enabled = self:GetChecked() and true or false
end)

delBtn:SetScript("OnClick", function() CW:DeleteSelected() end)
clearBtn:SetScript("OnClick", function() CW:ClearAll() end)

scroll:SetScript("OnVerticalScroll", function(self, offset)
  FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT + 2, function() CW:UpdateList() end)
end)

-- Keep flashing responsive over time
f:SetScript("OnUpdate", function()
  local now = GetTime()
  for _, untilT in pairs(CW.flashUntil) do
    if untilT and untilT > now then
      CW:UpdateList()
      return
    end
  end
end)

-- ======================
-- Event bootstrap
-- ======================
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")

for _, eName in ipairs(CHAT_EVENTS) do
  ev:RegisterEvent(eName)
end

ev:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name ~= "ChatWatch" then return end

    if not ChatWatchDB then ChatWatchDB = {} end
    ChatWatchDB = CopyDefaults(defaults, ChatWatchDB)

  elseif event == "PLAYER_LOGIN" then
    enabled:SetChecked(ChatWatchDB.enabled and true or false)
    CW:UpdateList()

    -- Restore main frame position/size from saved vars
    if ChatWatchDB.frame then
      local fdb = ChatWatchDB.frame
      f:ClearAllPoints()
      f:SetPoint(
        fdb.point or "CENTER",
        UIParent,
        fdb.relativePoint or "CENTER",
        fdb.x or 0,
        fdb.y or 0
      )
      if fdb.width and fdb.height then
        f:SetSize(fdb.width, fdb.height)
      end
    end

    -- Apply initial scale (no dynamic resizing available on some Classic builds)
    if SetFrameScale then
      local s = (ChatWatchDB.frame and ChatWatchDB.frame.scale) or (defaults.frame and defaults.frame.scale) or 1.0
      SetFrameScale(s)
    end

    -- Position the floating button from saved vars
    if CW.toggleButton then
      local b = ChatWatchDB.button or defaults.button
      -- validate saved coords
      local bx = (type(b.x) == "number") and b.x or defaults.button.x
      local by = (type(b.y) == "number") and b.y or defaults.button.y
      local bpoint = b.point or defaults.button.point
      local brel = b.relativePoint or defaults.button.relativePoint

      CW.toggleButton:ClearAllPoints()
      CW.toggleButton:SetPoint(bpoint, UIParent, brel, bx, by)
      CW.toggleButton:SetClampedToScreen(true)
      CW.toggleButton:Show()
    end

  else
    -- Chat message events: first arg is the message text
    local msg = ...
    CW:OnChatMessage(msg)
  end
end)
