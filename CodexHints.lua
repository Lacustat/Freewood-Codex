-- Freewood-Codex: Lern-Hinweise
-- Nach einem Stufenaufstieg auf eine gerade Stufe (ausserhalb des Kampfes) oder einer neuen Berufsstufe zeigt ein
-- Gratulationsfenster im Blizzard-Stil in der Bildschirmmitte das grosse Klassen- bzw. Berufs-Icon (Freewood-Design),
-- "Gratulation" und was man jetzt beim Lehrer lernen kann (0.55.0). Grundlage: Lernplan (Lehrer-Daten).
-- Dazu ein Blizzard-Sound aus dem Spiel (Auswahl in den Einstellungen, nichts mitgeliefert).

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS.Codex
if not FW or not Codex or not FW.UI then
    return
end

local UI = FW.UI
local Hints = { queue = {}, showing = false, shown = 0 }
NS.Hints = Hints
Codex.Hints = Hints

local DURATION = 5
local FADE = 0.6
local MAX_ROWS = 6
local ROW_H = 24
local WIDTH = 440
local ICON = 112

------------------------------------------------------------------------
-- Einstellungen
------------------------------------------------------------------------

function Hints.ClassOn()
    return Codex.db.settings.hintClass ~= false
end
function Hints.ProfOn()
    return Codex.db.settings.hintProf ~= false
end

------------------------------------------------------------------------
-- Inhalt
------------------------------------------------------------------------

local function SpellKnown(id)
    if not id then return false end
    local SB = _G.C_SpellBook
    local fn = (SB and SB.IsSpellKnown) or _G.IsSpellKnown or (_G.C_Spell and _G.C_Spell.IsSpellKnown)
    if type(fn) ~= "function" then return false end
    local ok, known = pcall(fn, id)
    return ok and known == true
end

local function Entry(r)
    local cost = Codex.ModePrice(r.pr)
    return { nm = r.nm or "?", sp = r.sp, rk = r.rk or (r.sp and Codex.SpellRank(r.sp)) or nil, cost = cost }
end

-- Fähigkeiten deiner Klasse, die auf dieser Stufe beim Lehrer dazukommen
function Hints.ClassEntries(level)
    local token = Codex.Time and Codex.Time.PlayerToken()
    if not token then return {} end
    local plan = Codex.LearnPlan(token)
    local g = plan.levels[level]
    local list = {}
    if g then
        for _, sp in ipairs(g.spells) do
            if not SpellKnown(sp.sp) then
                list[#list + 1] = { nm = sp.nm or "?", sp = sp.sp, rk = sp.rk or (sp.sp and Codex.SpellRank(sp.sp)) or nil, cost = sp.cost }
            end
        end
    end
    return list
end

-- Berufslehrer-Fähigkeiten, deren Fertigkeitswert in (von, bis] liegt
function Hints.ProfEntries(skill, from, to)
    local list, seen = {}, {}
    for _, u in pairs(Codex.V().units) do
        if u.tr and u.ro and (u.ro.proftrainer or 0) > 0 then
            for key, r in pairs(u.tr) do
                if r.sn == skill and r.sr and r.sr > from and r.sr <= to then
                    local k = r.sp and ("s" .. r.sp) or key
                    if not seen[k] then
                        seen[k] = true
                        list[#list + 1] = Entry(r)
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.nm ~= b.nm then return a.nm < b.nm end
        return (a.rk or "") < (b.rk or "")
    end)
    return list
end

------------------------------------------------------------------------
-- Berufe: Name aus dem Chat -> Icon-Schlüssel, Stufengrenzen beim Lehrer
------------------------------------------------------------------------

Hints.CRAFT_NAMES = {
    alchemie = "alchemy", alchemy = "alchemy", schmiedekunst = "blacksmithing", blacksmithing = "blacksmithing",
    kochkunst = "cooking", kochen = "cooking", cooking = "cooking", verzauberkunst = "enchanting", enchanting = "enchanting",
    ingenieurskunst = "engineering", engineering = "engineering", ["erste hilfe"] = "firstaid", ["first aid"] = "firstaid",
    angeln = "fishing", fishing = "fishing", ["kräuterkunde"] = "herbalism", herbalism = "herbalism",
    lederverarbeitung = "leatherworking", leatherworking = "leatherworking", bergbau = "mining", mining = "mining",
    ["kürschnerei"] = "skinning", skinning = "skinning", schneiderei = "tailoring", tailoring = "tailoring",
    juwelierskunst = "jewelcrafting", jewelcrafting = "jewelcrafting", inschriftenkunde = "inscription", inscription = "inscription",
}
-- Fertigkeit, an der die Stufe voll ist -> nächste Stufe beim Lehrer (Name, nötige Charakterstufe)
Hints.CAPS = { { at = 75, rank = "CODEX_HINT_RANK_2", level = 10 }, { at = 150, rank = "CODEX_HINT_RANK_3", level = 20 },
    { at = 225, rank = "CODEX_HINT_RANK_4", level = 35 } }

function Hints.CraftKey(skill)
    if type(skill) ~= "string" then return nil end
    return Hints.CRAFT_NAMES[skill:lower()]
end

-- Stufengrenze im Sprung (von, bis] überschritten?
function Hints.CapReached(from, to)
    for _, c in ipairs(Hints.CAPS) do
        if from < c.at and to >= c.at then return c end
    end
end

local function Design() return _G.FreewoodDesign end
function Hints.ClassIcon(token)
    local D = Design()
    return D and D.ClassTex and token and D.ClassTex(token) or nil
end
function Hints.CraftIcon(key)
    local D = Design()
    return D and D.CraftTex and key and D.CraftTex(key) or nil
end

------------------------------------------------------------------------
-- Sound: eingebaute Blizzard-Sounds (Name aus SOUNDKIT, sonst Nummer); fehlt einer, bleibt es still
------------------------------------------------------------------------

Hints.SOUNDS = {
    { id = "quest", kit = "IG_QUEST_LIST_COMPLETE", num = 878 },
    { id = "ready", kit = "READY_CHECK", num = 8960 },
    { id = "warning", kit = "RAID_WARNING", num = 8959 },
    { id = "queue", kit = "PVP_THROUGH_QUEUE", num = 8459 },
    { id = "levelup", kit = "LEVELUPSOUND", num = 888 },
    { id = "none" },
}

function Hints.SoundId()
    local v = Codex.db.settings.hintSound
    for _, s in ipairs(Hints.SOUNDS) do if s.id == v then return v end end
    return "quest"
end

function Hints.PlaySound(id)
    id = id or Hints.SoundId()
    for _, s in ipairs(Hints.SOUNDS) do
        if s.id == id then
            if not s.num then return false end
            local kit = _G.SOUNDKIT and s.kit and _G.SOUNDKIT[s.kit]
            local n = type(kit) == "number" and kit or s.num
            if type(_G.PlaySound) ~= "function" then return false end
            local ok = pcall(_G.PlaySound, n, "Master")
            return ok
        end
    end
    return false
end

------------------------------------------------------------------------
-- Anzeige
------------------------------------------------------------------------

local frame

-- gespeicherte Position (verschoben in den Einstellungen) oder Standard: Bildschirmmitte, etwas hoeher
local function ApplyPos(f)
    f:ClearAllPoints()
    local p = Codex.db.settings.hintPos
    if type(p) == "table" and p.point and p.x and p.y then
        f:SetPoint(p.point, UIParent, p.rel or p.point, p.x, p.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    end
end

function Hints.SavePos()
    if not frame or not frame.GetPoint then return false end
    local point, _, rel, x, y = frame:GetPoint(1)
    if not point then return false end
    Codex.db.settings.hintPos = { point = point, rel = rel, x = x, y = y }
    return true
end

function Hints.ResetPos()
    Codex.db.settings.hintPos = nil
    if frame then ApplyPos(frame) end
end

local function Font(parent, obj, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", obj)
    fs:SetJustifyH(justify or "CENTER")
    return fs
end

-- Gratulationsfenster im Blizzard-Stil: Dialograhmen, Blizzard-Schriften, oben das grosse Icon
local function Build()
    local f
    local ok, b = pcall(CreateFrame, "Button", nil, UIParent, "BackdropTemplate")
    f = ok and b or CreateFrame("Button", nil, UIParent)
    f:SetSize(WIDTH, 160)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if Hints.editing then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if Hints.editing then Hints.SavePos() end
    end)
    ApplyPos(f)
    f:Hide()
    if f.SetBackdrop then
        pcall(f.SetBackdrop, f, {
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    local c = CreateFrame("Frame", nil, f)
    c:SetAllPoints(f)
    c:SetFrameLevel((f:GetFrameLevel() or 1) + 2)
    -- grosses Icon halb über dem oberen Rand, mit Leuchten
    f.glow = c:CreateTexture(nil, "BACKGROUND")
    f.glow:SetTexture("Interface\\Cooldown\\star4")
    f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.82, 0.3, 0.7)
    f.glow:SetSize(ICON * 1.9, ICON * 1.9)
    f.glow:SetPoint("CENTER", f, "TOP", 0, 4)
    f.icon = c:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(ICON, ICON)
    f.icon:SetPoint("CENTER", f, "TOP", 0, 4)
    f.title = Font(c, "GameFontNormalHuge")
    f.title:SetPoint("TOP", f, "TOP", 0, -(ICON / 2 + 14))
    f.sub = Font(c, "GameFontHighlightLarge")
    f.sub:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
    f.sub:SetWidth(WIDTH - 40)
    f.lead = Font(c, "GameFontNormal")
    f.lead:SetWidth(WIDTH - 40)
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = {}
        row.icon = c:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 4, ROW_H - 4)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.text = Font(c, "GameFontHighlight", "LEFT")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetWidth(WIDTH - 180)
        row.text:SetWordWrap(false)
        row.cost = Font(c, "GameFontHighlightSmall", "RIGHT")
        row.cost:SetPoint("RIGHT", f, "RIGHT", -24, 0)
        row.cost:SetPoint("TOP", row.icon, "TOP", 0, 0)
        row.cost:SetPoint("BOTTOM", row.icon, "BOTTOM", 0, 0)
        row.cost:SetWidth(120)
        f.rows[i] = row
    end
    f.more = Font(c, "GameFontDisableSmall")
    f.foot = Font(c, "GameFontDisableSmall")
    f.foot:SetWidth(WIDTH - 40)
    -- Aufploppen des Icons (Animation, falls vorhanden)
    if f.icon.CreateAnimationGroup then
        local okA, ag = pcall(f.icon.CreateAnimationGroup, f.icon)
        if okA and ag then
            local sc = ag:CreateAnimation("Scale")
            if sc then
                if sc.SetScaleFrom then sc:SetScaleFrom(0.4, 0.4) sc:SetScaleTo(1, 1) elseif sc.SetScale then sc:SetScale(1, 1) end
                sc:SetDuration(0.35)
                if sc.SetSmoothing then sc:SetSmoothing("OUT") end
            end
            f.pop = ag
        end
    end
    f:SetScript("OnClick", function()
        if Hints.editing then return end
        Hints.Dismiss()
        if f.onClick then f.onClick() end
    end)
    f:SetScript("OnUpdate", function(self, elapsed)
        if Hints.editing then
            self.age = 0
            self:SetAlpha(1)
            return
        end
        self.age = (self.age or 0) + (elapsed or 0)
        if self.age >= DURATION then
            Hints.Dismiss()
        elseif self.age > DURATION - FADE then
            self:SetAlpha(math.max(0, (DURATION - self.age) / FADE))
        end
    end)
    return f
end

local function InCombat()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return true end
    return _G.UnitAffectingCombat and _G.UnitAffectingCombat("player") or false
end

-- h = { icon, title, sub, lead, entries, note, onClick, sound }
local function Display(h)
    frame = frame or Build()
    ApplyPos(frame)
    local L = FW.L
    frame.icon:SetTexture(h.icon)
    frame.icon:SetShown(h.icon ~= nil)
    frame.glow:SetShown(h.icon ~= nil)
    frame.title:SetText(h.title or "")
    frame.sub:SetText(h.sub or "")
    local y = ICON / 2 + 14 + 30 + 6 + 22 + 10
    frame.lead:ClearAllPoints()
    frame.lead:SetPoint("TOP", frame, "TOP", 0, -y)
    frame.lead:SetText(h.lead or "")
    if h.lead and h.lead ~= "" then
        local lh = (frame.lead.GetStringHeight and frame.lead:GetStringHeight()) or 14
        y = y + math.max(14, lh) + 8
    end
    local entries = h.entries or {}
    local n = math.min(#entries, MAX_ROWS)
    local total = 0
    local money = _G.GetMoney and _G.GetMoney() or nil
    for i = 1, MAX_ROWS do
        local row, e = frame.rows[i], entries[i]
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, -(y + (i - 1) * ROW_H))
        if e and i <= n then
            local icon = e.sp and Codex.SpellIcon(e.sp) or nil
            row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.icon:Show()
            row.text:SetText(e.nm .. (e.rk and ("  |cff9a9aa3(" .. e.rk .. ")|r") or ""))
            row.cost:SetText((e.cost and e.cost > 0 and Codex.FormatMoney) and Codex.FormatMoney(e.cost) or "")
        else
            row.icon:Hide()
            row.text:SetText("")
            row.cost:SetText("")
        end
    end
    for _, e in ipairs(entries) do total = total + (e.cost or 0) end
    y = y + n * ROW_H + 4
    local more = #entries - n
    frame.more:ClearAllPoints()
    frame.more:SetPoint("TOP", frame, "TOP", 0, -y)
    frame.more:SetText(more > 0 and string.format(L.CODEX_HINT_MORE, more) or "")
    if more > 0 then y = y + 16 end
    local foot
    if h.note then
        foot = h.note
    elseif Hints.editing then
        foot = L.CODEX_HINT_DRAG
    else
        foot = h.onClick and L.CODEX_HINT_CLICK or ""
        if total > 0 and Codex.FormatMoney then
            local cost = string.format(L.CODEX_HINT_COST, Codex.FormatMoney(total))
            if money and money < total then
                cost = cost .. "  |  " .. string.format(L.CODEX_HINT_MISSING, Codex.FormatMoney(total - money))
            end
            foot = cost .. (foot ~= "" and ("  |  " .. foot) or "")
        end
    end
    frame.foot:ClearAllPoints()
    frame.foot:SetPoint("TOP", frame, "TOP", 0, -(y + 4))
    frame.foot:SetText(foot)
    local fh = (frame.foot.GetStringHeight and frame.foot:GetStringHeight()) or 14
    frame:SetHeight(y + 4 + math.max(14, fh) + 22)
    frame.onClick = h.onClick
    frame.age = 0
    frame:SetAlpha(1)
    frame:Show()
    if frame.pop and h.icon then pcall(frame.pop.Play, frame.pop) end
    if h.sound and not Hints.editing then Hints.PlaySound() end
    Hints.showing = true
    Hints.shown = Hints.shown + 1
    Hints.last = h
end

function Hints.Dismiss()
    if Hints.editing then return end
    if frame then frame:Hide() end
    Hints.showing = false
    Hints.Flush()
end

-- naechsten wartenden Hinweis zeigen, wenn kein Kampf ist und keiner laeuft
function Hints.Flush()
    if Hints.showing or Hints.editing or InCombat() then return end
    local h = table.remove(Hints.queue, 1)
    if h then Display(h) end
end

function Hints.Push(h)
    if not h or (#(h.entries or {}) == 0 and not h.always) then return false end
    Hints.queue[#Hints.queue + 1] = h
    Hints.Flush()
    return true
end

local function OpenPlan(level)
    return function()
        UI:Show("codex")
        if Codex.ui and Codex.ui.Go then Codex.ui.Go("learn", level) end
    end
end

-- Gratulation auf geraden Stufen: Klassen-Icon, Text, was beim Klassenlehrer dazukommt
function Hints.ClassHint(level)
    local L = FW.L
    local token = Codex.Time and Codex.Time.PlayerToken()
    local entries = Hints.ClassEntries(level)
    local h = {
        icon = Hints.ClassIcon(token), title = L.CODEX_HINT_CONGRATS,
        sub = string.format(L.CODEX_HINT_LEVEL, level), entries = entries, always = true, sound = true,
        onClick = OpenPlan(level),
    }
    if #entries > 0 then h.lead = L.CODEX_HINT_CLASS_LEAD else h.note = L.CODEX_HINT_NODATA_CLASS end
    return h
end

function Hints.OnLevelUp(level)
    level = tonumber(level)
    if not level or not Hints.ClassOn() or not Codex.db.settings.enabled then return false end
    if level % 2 ~= 0 then return false end              -- nur gerade Stufen (0.55.0)
    return Hints.Push(Hints.ClassHint(level))
end

local prevSkill = {}
function Hints.OnSkill(skill, value)
    value = tonumber(value)
    if not skill or not value then return false end
    local from = prevSkill[skill] or (value - 1)
    prevSkill[skill] = value
    if not Hints.ProfOn() or not Codex.db.settings.enabled then return false end
    local L = FW.L
    local entries = Hints.ProfEntries(skill, from, value)
    local key = Hints.CraftKey(skill)
    local cap = key and Hints.CapReached(from, value)
    if #entries == 0 and not cap then return false end
    local h = {
        icon = Hints.CraftIcon(key), title = L.CODEX_HINT_CONGRATS,
        sub = string.format(L.CODEX_HINT_SKILL, skill, value), entries = entries, always = true, sound = true,
        onClick = function() UI:Show("codex") end,
    }
    if cap then
        h.lead = string.format(L.CODEX_HINT_RANK_LEAD, L[cap.rank] or cap.rank, cap.level)
    elseif #entries > 0 then
        h.lead = L.CODEX_HINT_PROF_LEAD
    end
    return Hints.Push(h)
end

-- Test aus den Einstellungen: letzte gerade Stufe mit Daten, sonst eine Beispielzeile
function Hints.Demo()
    local pl = _G.UnitLevel and _G.UnitLevel("player") or 2
    local found
    for lv = pl, 1, -1 do
        if #Hints.ClassEntries(lv) > 0 then found = lv break end
    end
    local h = Hints.ClassHint(found or math.max(2, pl - pl % 2))
    if #h.entries == 0 then
        h.entries = { { nm = FW.L.CODEX_HINT_DEMO, rk = "1", cost = 10000 } }
        h.lead, h.note = FW.L.CODEX_HINT_CLASS_LEAD, nil
    end
    Hints.queue = {}
    Hints.showing = false
    if frame then frame:Hide() end
    Hints.Push(h)
end

-- Verschieben: der Hinweis bleibt stehen, bis der Modus beendet wird; Position wird beim Loslassen gespeichert
function Hints.SetEditMode(on)
    on = on and true or false
    if on == (Hints.editing == true) then return end
    if on then
        Hints.queue, Hints.showing = {}, false
        if frame then frame:Hide() end
        local pl = _G.UnitLevel and _G.UnitLevel("player") or 2
        local h = Hints.ClassHint(math.max(2, pl - pl % 2))
        h.entries = { { nm = FW.L.CODEX_HINT_DEMO, rk = "1", cost = 10000 }, { nm = FW.L.CODEX_HINT_DEMO, rk = "2", cost = 25000 } }
        h.lead, h.note, h.sound = FW.L.CODEX_HINT_CLASS_LEAD, nil, false
        Hints.editing = true
        Display(h)
    else
        Hints.SavePos()
        Hints.editing = false
        Hints.showing = false
        if frame then frame:Hide() end
        Hints.Flush()
    end
    FW:Fire("CODEX_HINT_EDIT")
end

------------------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------------------

-- Muster aus dem Textbaustein des Spiels ("... %s ... %d" oder mit Stellen "%1$s ... %2$d"). Rueckgabe: Muster, Reihenfolge
-- der Platzhalter (Stelle -> Rang in der Fundstelle), sonst nil
local function SkillPattern(fmt)
    fmt = fmt or _G.SKILL_RANK_UP
    if type(fmt) ~= "string" then return nil end
    local out, order, i = { "^" }, {}, 1
    while i <= #fmt do
        local pos, kind, len = fmt:match("^%%(%d+)%$([sd])()", i)
        if pos then
            i = len
        else
            kind, len = fmt:match("^%%([sd])()", i)
            pos = #order + 1
            if kind then i = len end
        end
        if kind then
            out[#out + 1] = kind == "s" and "(.+)" or "(%d+)"
            order[#order + 1] = tonumber(pos)
        else
            local ch = fmt:sub(i, i)
            out[#out + 1] = ch:match("%w") and ch or ("%" .. ch)
            i = i + 1
        end
    end
    out[#out + 1] = "$"
    return table.concat(out), order
end
Hints.SkillPattern = SkillPattern

FW:RegisterEvent("PLAYER_LEVEL_UP", function(_, level)
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function() Hints.OnLevelUp(level) end)
    else
        Hints.OnLevelUp(level)
    end
end, Hints)
FW:RegisterEvent("PLAYER_REGEN_ENABLED", function() Hints.Flush() end, Hints)
FW:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    if Hints.editing then Hints.SetEditMode(false) end
end, Hints)
FW:RegisterEvent("CHAT_MSG_SKILL", function(_, text)
    local pat, order = SkillPattern()
    if type(text) ~= "string" or not pat then return end
    if FW.Util and FW.Util.IsSecret and FW.Util.IsSecret(text) then return end   -- geheime Chattexte (Sperre) nicht anfassen
    local caps = { text:match(pat) }
    if #caps == 0 then return end
    local skill, value = caps[1], caps[2]
    if order and order[1] == 2 then skill, value = caps[2], caps[1] end   -- Fertigkeit steht an Stelle 2
    if skill then Hints.OnSkill(skill, value) end
end, Hints)

------------------------------------------------------------------------
-- Einstellungen: Abschnitt
------------------------------------------------------------------------

if UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-hints", {
        module = "codex",       -- Einstellungen im Modul (Core 0.54.0)
        category = "quest",
        order = 106,
        height = 400,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_HINT_HEADER)
            if f.AddInfo then f:AddInfo(L.CODEX_HINT_NOTE) end
            local classBox = UI.CreateCheckbox(f, L.CODEX_HINT_CLASS_SWITCH, function() return Hints.ClassOn() end,
                function(on) Codex.db.settings.hintClass = on and true or false end)
            stack:Add(classBox, { fit = true, gap = 10 })
            local profBox = UI.CreateCheckbox(f, L.CODEX_HINT_PROF_SWITCH, function() return Hints.ProfOn() end,
                function(on) Codex.db.settings.hintProf = on and true or false end)
            stack:Add(profBox, { fit = true, gap = 4 })
            local soundLabel = UI.CreateLabel(f, L.CODEX_HINT_SOUND, { size = 12, color = "gold" })
            stack:Add(soundLabel, { height = 16, gap = 10 })
            local soundDD = UI.CreateDropdown(f, 220, 24, {
                getOptions = function()
                    local list = {}
                    for _, snd in ipairs(Hints.SOUNDS) do list[#list + 1] = { value = snd.id, text = L["CODEX_HINT_SOUND_" .. snd.id] or snd.id } end
                    return list
                end,
                textOf = function(v) return L["CODEX_HINT_SOUND_" .. tostring(v)] or tostring(v) end,
                onChange = function(v) Codex.db.settings.hintSound = v Hints.PlaySound(v) end,
            })
            soundDD:SetValue(Hints.SoundId())
            stack:Add(soundDD, { height = 24, gap = 4 })
            local probe = UI.CreateButton(f, L.CODEX_HINT_SOUND_TEST, 200, 26, function() Hints.PlaySound() end, "default")
            stack:Add(probe, { height = 26, gap = 6 })
            f.soundDD = soundDD
            local test = UI.CreateButton(f, L.CODEX_HINT_TEST, 200, 26, function() Hints.Demo() end, "default")
            stack:Add(test, { height = 26, gap = 12 })
            local move
            move = UI.CreateButton(f, L.CODEX_HINT_MOVE, 200, 26, function()
                Hints.SetEditMode(not Hints.editing)
            end, "default")
            stack:Add(move, { height = 26, gap = 6 })
            local reset = UI.CreateButton(f, L.CODEX_HINT_RESET, 200, 26, function() Hints.ResetPos() end, "default")
            stack:Add(reset, { height = 26, gap = 6 })
            stack:Layout()
            f.classBox, f.profBox, f.move = classBox, profBox, move
            FW:On("CODEX_HINT_EDIT", function()
                move:SetLabel(Hints.editing and L.CODEX_HINT_MOVE_DONE or L.CODEX_HINT_MOVE)
                move:SetStyle(Hints.editing and "primary" or "default")
            end, f)
            return f
        end,
        refresh = function(frame)
            frame.classBox:Refresh()
            frame.profBox:Refresh()
            if frame.soundDD then frame.soundDD:SetValue(Hints.SoundId()) end
        end,
    })
end
