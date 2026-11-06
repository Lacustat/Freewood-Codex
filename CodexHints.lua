-- Freewood-Codex: Lern-Hinweise
-- Nach einem Stufenaufstieg (ausserhalb des Kampfes) oder einer neuen Berufsstufe zeigt ein kurzer Hinweis
-- in der Bildschirmmitte, was man jetzt beim Lehrer lernen kann. Grundlage: Lernplan (Lehrer-Daten).

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
local MAX_ROWS = 5
local ROW_H = 24
local WIDTH = 380

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

local function Build()
    local f = CreateFrame("Button", nil, UIParent)
    f:SetSize(WIDTH, 80)
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
    local bg = UI.CreatePanel(f, "bgDeep", "gold")
    bg:SetAllPoints(f)
    -- Inhalt auf eigener Ebene ueber dem Hintergrund (ein Kindfenster zeichnet sonst ueber den Texten des Eltern-Fensters)
    local c = CreateFrame("Frame", nil, f)
    c:SetAllPoints(f)
    c:SetFrameLevel((bg:GetFrameLevel() or 1) + 2)
    f.title = UI.CreateLabel(c, "", { font = "heading", size = 14, color = "goldLight" })
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
    f.title:SetWordWrap(false)
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = {}
        row.icon = c:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 4, ROW_H - 4)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(34 + (i - 1) * ROW_H))
        row.text = UI.CreateLabel(c, "", { size = 12 })
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetWidth(WIDTH - 150)
        row.text:SetWordWrap(false)
        row.cost = UI.CreateLabel(c, "", { size = 11, color = "textDim", justify = "RIGHT" })
        row.cost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
        row.cost:SetPoint("TOP", row.icon, "TOP", 0, 0)
        row.cost:SetPoint("BOTTOM", row.icon, "BOTTOM", 0, 0)
        row.cost:SetWidth(120)
        f.rows[i] = row
    end
    f.more = UI.CreateLabel(c, "", { size = 11, color = "textDim" })
    f.foot = UI.CreateLabel(c, "", { size = 10, color = "textDim" })
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

local function Display(h)
    frame = frame or Build()
    ApplyPos(frame)
    local L = FW.L
    frame.title:SetText(h.title)
    local n = math.min(#h.entries, MAX_ROWS)
    local total = 0
    local money = _G.GetMoney and _G.GetMoney() or nil
    for i = 1, MAX_ROWS do
        local row, e = frame.rows[i], h.entries[i]
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
    for _, e in ipairs(h.entries) do total = total + (e.cost or 0) end
    local y = 34 + n * ROW_H + 4
    local more = #h.entries - n
    frame.more:ClearAllPoints()
    frame.more:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -y)
    frame.more:SetText(more > 0 and string.format(L.CODEX_HINT_MORE, more) or "")
    if more > 0 then y = y + 16 end
    local foot = Hints.editing and L.CODEX_HINT_DRAG or L.CODEX_HINT_CLICK
    if total > 0 and Codex.FormatMoney and not Hints.editing then
        foot = string.format(L.CODEX_HINT_COST, Codex.FormatMoney(total))
        if money and money < total then
            foot = foot .. "  |  " .. string.format(L.CODEX_HINT_MISSING, Codex.FormatMoney(total - money))
        end
        foot = foot .. "  |  " .. L.CODEX_HINT_CLICK
    end
    frame.foot:ClearAllPoints()
    frame.foot:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -y)
    frame.foot:SetText(foot)
    frame:SetHeight(y + 26)
    frame.onClick = h.onClick
    frame.age = 0
    frame:SetAlpha(1)
    frame:Show()
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
    if not h or #h.entries == 0 then return false end
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

function Hints.OnLevelUp(level)
    level = tonumber(level)
    if not level or not Hints.ClassOn() or not Codex.db.settings.enabled then return false end
    local entries = Hints.ClassEntries(level)
    return Hints.Push({ title = string.format(FW.L.CODEX_HINT_CLASS_TITLE, level), entries = entries, onClick = OpenPlan(level) })
end

local prevSkill = {}
function Hints.OnSkill(skill, value)
    value = tonumber(value)
    if not skill or not value then return false end
    local from = prevSkill[skill] or (value - 1)
    prevSkill[skill] = value
    if not Hints.ProfOn() or not Codex.db.settings.enabled then return false end
    local entries = Hints.ProfEntries(skill, from, value)
    return Hints.Push({ title = string.format(FW.L.CODEX_HINT_PROF_TITLE, skill, value), entries = entries, onClick = function() UI:Show("codex") end })
end

-- Test aus den Einstellungen: letzte Stufe mit Daten, sonst eine Beispielzeile
function Hints.Demo()
    local pl = _G.UnitLevel and _G.UnitLevel("player") or 1
    local entries
    for lv = pl, 1, -1 do
        entries = Hints.ClassEntries(lv)
        if #entries > 0 then
            pl = lv
            break
        end
    end
    if not entries or #entries == 0 then
        entries = { { nm = FW.L.CODEX_HINT_DEMO, rk = "1", cost = 10000 } }
    end
    Hints.queue = {}
    Hints.showing = false
    if frame then frame:Hide() end
    Hints.Push({ title = string.format(FW.L.CODEX_HINT_CLASS_TITLE, pl), entries = entries, onClick = OpenPlan(pl) })
end

-- Verschieben: der Hinweis bleibt stehen, bis der Modus beendet wird; Position wird beim Loslassen gespeichert
function Hints.SetEditMode(on)
    on = on and true or false
    if on == (Hints.editing == true) then return end
    if on then
        Hints.queue, Hints.showing = {}, false
        if frame then frame:Hide() end
        local pl = _G.UnitLevel and _G.UnitLevel("player") or 1
        local entries = { { nm = FW.L.CODEX_HINT_DEMO, rk = "1", cost = 10000 }, { nm = FW.L.CODEX_HINT_DEMO, rk = "2", cost = 25000 } }
        Hints.editing = true
        Display({ title = string.format(FW.L.CODEX_HINT_CLASS_TITLE, pl), entries = entries })
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
        category = "quest",
        order = 106,
        height = 300,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_HINT_HEADER)
            local note = UI.CreateLabel(f, L.CODEX_HINT_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
            stack:Add(note, { fit = true, gap = 8 })
            local classBox = UI.CreateCheckbox(f, L.CODEX_HINT_CLASS_SWITCH, function() return Hints.ClassOn() end,
                function(on) Codex.db.settings.hintClass = on and true or false end)
            stack:Add(classBox, { fit = true, gap = 10 })
            local profBox = UI.CreateCheckbox(f, L.CODEX_HINT_PROF_SWITCH, function() return Hints.ProfOn() end,
                function(on) Codex.db.settings.hintProf = on and true or false end)
            stack:Add(profBox, { fit = true, gap = 4 })
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
        end,
    })
end
