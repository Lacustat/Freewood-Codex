-- Freewood-Codex: Namen von Hand eintragen (Deutsch / Englisch)
-- Zwei Fenster im Tab "Datenbank":
--   "Name bearbeiten"  fuer den gewaehlten Eintrag (Kreatur, Objekt, Quest, Item), mit Vorschlaegen aus dem Kampflog
--   "Namen einfuegen"  mehrere Zeilen "ID Name" auf einmal fuer die aktuelle Liste

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex or not FW.UI then
    return
end

local UI = FW.UI
local Util = FW.Util

local NameUI = {}
NS.NameUI = NameUI
Codex.NameUI = NameUI

local EDITABLE = { units = true, objects = true, quests = true, items = true }
local KIND_LABEL = { units = "CODEX_KIND_UNITS", objects = "CODEX_KIND_OBJECTS", quests = "CODEX_KIND_QUESTS", items = "CODEX_KIND_ITEMS" }
local MAX_SUGGEST = 6

local function MakeInput(parent, width)
    local box = UI.CreatePanel(parent, "bgDeep", "bronze")
    box:SetSize(width, 26)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetAutoFocus(false)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -2)
    edit:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 2)
    edit:SetMaxLetters(100)
    if not edit:SetFont(UI.GetFontPath("body"), 12, "") then
        edit:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    end
    edit:SetTextColor(UI.Color("text"))
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box.edit = edit
    return box
end

-- Wowhead-Adresse fuer Nachschlagen (an einer Stelle, falls sich die Domain aendert)
local WOWHEAD_BASE = "https://www.wowhead.com/forever/"
local WOWHEAD_PATH = { units = "npc", objects = "object", quests = "quest", items = "item" }
function NameUI.LookupURL(kind, id, lang)
    local path = WOWHEAD_PATH[kind]
    if not path or not id then return nil end
    return WOWHEAD_BASE .. (lang == "de" and "de/" or "") .. path .. "=" .. tostring(id)
end

-- Schreibgeschuetztes Feld: Klick markiert alles, dann Strg+C
local function MakeLink(parent, width)
    local box = MakeInput(parent, width)
    box:SetHeight(22)
    local edit = box.edit
    edit:SetMaxLetters(0)
    edit:SetTextColor(UI.Color("goldLight"))
    local function Select(self) self:HighlightText() end
    edit:SetScript("OnEditFocusGained", Select)
    edit:SetScript("OnMouseUp", function(self) self:SetFocus(); self:HighlightText() end)
    edit:SetScript("OnTextChanged", function(self, user)
        if user and box.fwUrl and self:GetText() ~= box.fwUrl then
            self:SetText(box.fwUrl)
            self:HighlightText()
        end
    end)
    function box.SetURL(url)
        box.fwUrl = url or ""
        edit:SetText(url or "")
        edit:SetCursorPosition(0)
    end
    return box
end

local function MakeWindow(parent, width, height)
    local w = UI.CreatePanel(parent, "bg", "gold")
    w:SetSize(width, height)
    w:SetPoint("CENTER", parent, "CENTER", 0, 0)
    w:SetFrameStrata("DIALOG")
    w:EnableMouse(true)
    w:Hide()
    return w
end

local function GameName(kind, id)
    local v = Codex.V()
    if kind == "units" then
        local e = v.units[id]
        return e and e.n
    elseif kind == "objects" then
        local e = v.objects[id]
        return e and e.n
    elseif kind == "quests" then
        local q = v.quests[id]
        return q and q.t
    end
    local info = Util.GetItem and Util.GetItem(id)
    return (info and info.name) or Codex.db.names[id]
end

------------------------------------------------------------------------
-- Fenster "Name bearbeiten"
------------------------------------------------------------------------

local function BuildEdit(parent, onChanged)
    local L = FW.L
    local win = MakeWindow(parent, 480, 520)
    local state = {}

    local title = UI.CreateLabel(win, "", { font = "heading", size = 14, color = "goldLight" })
    title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    local game = UI.CreateLabel(win, "", { size = 11, color = "textDim" })
    game:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -40)
    game:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -40)
    game:SetWordWrap(false)

    local deLabel = UI.CreateLabel(win, L.CODEX_NAME_DE, { size = 12 })
    deLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -68)
    local deBox = MakeInput(win, 448)
    deBox:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -86)
    local deLink = MakeLink(win, 448)
    deLink:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -114)
    local enLabel = UI.CreateLabel(win, L.CODEX_NAME_EN, { size = 12 })
    enLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -146)
    local enBox = MakeInput(win, 448)
    enBox:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -164)
    local enLink = MakeLink(win, 448)
    enLink:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -192)

    local hint = UI.CreateLabel(win, "", { size = 11, color = "textDim", justifyV = "TOP" })
    hint:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -222)
    hint:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -222)
    hint:SetHeight(32)
    hint:SetWordWrap(true)

    local sugTitle = UI.CreateLabel(win, L.CODEX_NAME_KILLS, { size = 12, color = "goldLight" })
    sugTitle:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -260)
    local sugNone = UI.CreateLabel(win, L.CODEX_NAME_NOKILLS, { size = 11, color = "textDim", justifyV = "TOP" })
    sugNone:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -284)
    sugNone:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -284)
    sugNone:SetHeight(32)
    sugNone:SetWordWrap(true)

    local function Fill(text)
        local box = Codex.Lang() == "en" and enBox or deBox
        box.edit:SetText(text or "")
        box.edit:SetFocus()
    end
    local sugButtons = {}
    for i = 1, MAX_SUGGEST do
        local b = UI.CreateButton(win, "", 448, 24, function(self)
            if self.fwText then Fill(self.fwText) end
        end, "default")
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -284 - (i - 1) * 28)
        b:Hide()
        sugButtons[i] = b
    end

    local function Save()
        if state.kind and state.id then
            Codex:SetCustom(state.kind, state.id, deBox.edit:GetText(), enBox.edit:GetText())
            if onChanged then onChanged() end
        end
        win:Hide()
    end
    local save = UI.CreateButton(win, L.CODEX_NAME_SAVE, 140, 28, Save, "primary")
    save:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    local clear = UI.CreateButton(win, L.CODEX_NAME_CLEAR, 140, 28, function()
        deBox.edit:SetText("")
        enBox.edit:SetText("")
        Save()
    end, "default")
    clear:SetPoint("LEFT", save, "RIGHT", 8, 0)
    local cancel = UI.CreateButton(win, L.CODEX_NAME_CANCEL, 140, 28, function() win:Hide() end, "default")
    cancel:SetPoint("LEFT", clear, "RIGHT", 8, 0)

    function win.Open(kind, id)
        state.kind, state.id = kind, id
        local label = L[KIND_LABEL[kind]] or kind
        title:SetText(string.format("%s  #%s", label, tostring(id)))
        local gn = GameName(kind, id)
        game:SetText(gn and string.format(L.CODEX_NAME_GAME, gn) or "")
        local de, en = Codex:GetCustom(kind, id)
        deBox.edit:SetText(de or "")
        enBox.edit:SetText(en or "")
        hint:SetText((kind == "items" and L.CODEX_NAME_HINT_LOCAL or L.CODEX_NAME_HINT) .. "\n" .. (L.CODEX_NAME_LINK or ""))
        deLink.SetURL(NameUI.LookupURL(kind, id, "de"))
        enLink.SetURL(NameUI.LookupURL(kind, id, "en"))
        local names = {}
        if kind == "units" and Codex.Names and Codex.Names.RecentKills then
            for _, k in ipairs(Codex.Names:RecentKills(900, MAX_SUGGEST)) do
                names[#names + 1] = k.name
                if k.alt then names[#names + 1] = k.alt end
            end
        end
        local showSug = kind == "units"
        if showSug then sugTitle:Show() else sugTitle:Hide() end
        if showSug and #names == 0 then sugNone:Show() else sugNone:Hide() end
        for i, b in ipairs(sugButtons) do
            local text = names[i]
            if text then
                b.fwText = text
                b:SetLabel(text)
                b:Show()
            else
                b.fwText = nil
                b:Hide()
            end
        end
        win.fwKey = kind .. ":" .. tostring(id)
        win:Show()
        win:Raise()
    end
    return win
end

------------------------------------------------------------------------
-- Fenster "Eigenschaften bearbeiten": Zone(n), Dungeon, Klasse, Stufen
-- (Blizzard liefert aus Instanzen keine Orte und oft keine Klasse; hier koennen Berechtigte sie nachtragen)
------------------------------------------------------------------------

local mapIndex

-- Alle Karten des Spiels (Name -> ID), einmal gelesen
local function MapIndex()
    if mapIndex then return mapIndex end
    mapIndex = {}
    if C_Map and C_Map.GetMapInfo then
        for id = 1, 3000 do
            local ok, info = pcall(C_Map.GetMapInfo, id)
            if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
                mapIndex[#mapIndex + 1] = { id = id, name = info.name, lower = info.name:lower() }
            end
        end
    end
    return mapIndex
end

-- Karten, deren Name den Text enthaelt (oder deren ID passt). Rueckgabe: Liste { id, name }
function NameUI.FindMaps(text, limit)
    local out = {}
    text = type(text) == "string" and text:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if text == "" then return out end
    local num = tonumber(text)
    if num and num >= 1 and num == math.floor(num) then
        out[1] = { id = num, name = Codex.MapName(num) }
    end
    -- eingebaute Instanzen (Dungeons, Schlachtfelder): negative ID
    local ids = {}
    for id in pairs(Codex.INSTANCES) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if #out >= (limit or 6) then break end
        local b = Codex.INSTANCES[id]
        if b[1]:lower():find(text, 1, true) or b[2]:lower():find(text, 1, true) then
            out[#out + 1] = { id = -id, name = Codex.InstanceName(id) }
        end
    end
    for _, m in ipairs(MapIndex()) do
        if #out >= (limit or 6) then break end
        if m.lower:find(text, 1, true) and m.id ~= num then
            out[#out + 1] = { id = m.id, name = m.name }
        end
    end
    return out
end

local CLASS_CYCLE = { false, "normal", "elite", "rare", "rareelite", "worldboss" }

local function ClassLabel(cl)
    local L = FW.L
    if not cl then return L.CODEX_PROPS_AUTO end
    return L["CODEX_PROPS_CLASS_" .. cl] or cl
end

local function BuildProps(parent, onChanged)
    local L = FW.L
    local win = MakeWindow(parent, 520, 650)
    local state = { z = {} }
    local MAXZ = Codex.MAX_ED_ZONES

    local title = UI.CreateLabel(win, "", { font = "heading", size = 14, color = "goldLight" })
    title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    local game = UI.CreateLabel(win, "", { size = 11, color = "textDim" })
    game:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -40)
    game:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -40)
    game:SetWordWrap(false)

    -- Zonen
    local zoneTitle = UI.CreateLabel(win, L.CODEX_PROPS_ZONES, { size = 12, color = "goldLight" })
    zoneTitle:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -68)
    local zoneRows = {}
    for i = 1, MAXZ do
        local lbl = UI.CreateLabel(win, "", { size = 12 })
        lbl:SetPoint("TOPLEFT", win, "TOPLEFT", 24, -92 - (i - 1) * 24)
        lbl:SetWidth(400)
        lbl:SetWordWrap(false)
        local rm = UI.CreateButton(win, "x", 24, 20, function()
            table.remove(state.z, i)
            win.Refresh()
        end, "default")
        rm:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -90 - (i - 1) * 24)
        zoneRows[i] = { lbl = lbl, rm = rm }
    end
    local zoneNone = UI.CreateLabel(win, L.CODEX_PROPS_ZONES_NONE, { size = 11, color = "textDim" })
    zoneNone:SetPoint("TOPLEFT", win, "TOPLEFT", 24, -92)

    local zoneInput = MakeInput(win, 300)
    zoneInput:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -92 - MAXZ * 24 - 8)
    local sugBtns = {}
    local function AddZone(id)
        if id and #state.z < MAXZ then
            for _, z in ipairs(state.z) do if z == id then return end end
            state.z[#state.z + 1] = id
        end
        zoneInput.edit:SetText("")
        win.Refresh()
    end
    local function Suggest()
        local found = NameUI.FindMaps(zoneInput.edit:GetText(), #sugBtns)
        for i, b in ipairs(sugBtns) do
            local m = found[i]
            if m then
                b.fwId = m.id
                b:SetLabel(string.format("%s  (#%d)", m.name, m.id < 0 and -m.id or m.id))
                b:Show()
            else
                b.fwId = nil
                b:Hide()
            end
        end
    end
    zoneInput.edit:SetScript("OnTextChanged", function(_, user) if user then Suggest() end end)
    local here = UI.CreateButton(win, L.CODEX_PROPS_HERE, 170, 26, function()
        local inst = Codex.CurrentInstance and Codex.CurrentInstance()
        if inst then
            AddZone(-inst)
            return
        end
        local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        if m then AddZone(m) end
    end, "default")
    here:SetPoint("LEFT", zoneInput, "RIGHT", 8, 0)
    for i = 1, 5 do
        local b = UI.CreateButton(win, "", 488, 22, function(self)
            if self.fwId then AddZone(self.fwId) end
        end, "default")
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -92 - MAXZ * 24 - 40 - (i - 1) * 24)
        b:Hide()
        sugBtns[i] = b
    end
    local zoneHint = UI.CreateLabel(win, L.CODEX_PROPS_ZONE_HINT, { size = 11, color = "textDim", justifyV = "TOP" })
    zoneHint:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -92 - MAXZ * 24 - 40 - 5 * 24 - 2)
    zoneHint:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -92 - MAXZ * 24 - 40 - 5 * 24 - 2)
    zoneHint:SetHeight(30)
    zoneHint:SetWordWrap(true)

    -- Dungeon / Klasse / Stufen
    local baseY = 92 + MAXZ * 24 + 40 + 5 * 24 + 36
    local dgLabel = UI.CreateLabel(win, L.CODEX_PROPS_DUNGEON, { size = 12 })
    dgLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - 4)
    local dgBtn = UI.CreateButton(win, "", 200, 24, function()
        if state.dg == nil then state.dg = true elseif state.dg == true then state.dg = false else state.dg = nil end
        win.Refresh()
    end, "default")
    dgBtn:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -baseY)
    local clLabel = UI.CreateLabel(win, L.CODEX_PROPS_CLASS, { size = 12 })
    clLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - 36)
    local clBtn = UI.CreateButton(win, "", 200, 24, function()
        local idx = 1
        for i, c in ipairs(CLASS_CYCLE) do if c == (state.cl or false) then idx = i end end
        state.cl = CLASS_CYCLE[idx % #CLASS_CYCLE + 1] or nil
        if state.cl == false then state.cl = nil end
        win.Refresh()
    end, "default")
    clBtn:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -baseY - 32)
    local lvLabel = UI.CreateLabel(win, L.CODEX_PROPS_LEVELS, { size = 12 })
    lvLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - 72)
    local l1Box = MakeInput(win, 70)
    l1Box:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -baseY - 68)
    l1Box.edit:SetMaxLetters(3)
    local lvDash = UI.CreateLabel(win, "-", { size = 12 })
    lvDash:SetPoint("LEFT", l1Box, "RIGHT", 6, 0)
    local l2Box = MakeInput(win, 70)
    l2Box:SetPoint("LEFT", l1Box, "RIGHT", 20, 0)
    l2Box.edit:SetMaxLetters(3)
    -- Quests: Vorquests (an der Stelle der Stufen)
    local preLabel = UI.CreateLabel(win, L.CODEX_PROPS_PRE, { size = 12 })
    preLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - 72)
    local preBox = MakeInput(win, 300)
    preBox:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -baseY - 68)
    preBox.edit:SetMaxLetters(60)

    -- Quests: Folgequests, davor, danach, Stufe, Questtext (Dev)
    local QROW = { nx = 36, bf = 108, af = 140, ql = 172, tx = 204, si = 236 }
    local qLabels, qBoxes = {}, {}
    local function QField(key, label, width, letters, y)
        local lbl = UI.CreateLabel(win, label, { size = 12 })
        lbl:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - y - 4)
        local box = MakeInput(win, width)
        box:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -baseY - y)
        box.edit:SetMaxLetters(letters)
        qLabels[key], qBoxes[key] = lbl, box
    end
    QField("nx", L.CODEX_PROPS_NEXT, 300, 60, QROW.nx)
    QField("bf", L.CODEX_PROPS_BEFORE, 300, 60, QROW.bf)
    QField("af", L.CODEX_PROPS_AFTER, 300, 60, QROW.af)
    QField("ql", L.CODEX_PROPS_QLEVEL, 70, 3, QROW.ql)
    QField("tx", L.CODEX_PROPS_TEXT, 300, 600, QROW.tx)
    QField("si", L.CODEX_PROPS_STARTITEM, 120, 9, QROW.si)

    local hint = UI.CreateLabel(win, L.CODEX_PROPS_HINT, { size = 11, color = "textDim", justifyV = "TOP" })
    hint:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - 104)
    hint:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -baseY - 104)
    hint:SetHeight(58)
    hint:SetWordWrap(true)

    function win.Refresh()
        for i = 1, MAXZ do
            local row = zoneRows[i]
            local id = state.z[i]
            if id then
                row.lbl:SetText(string.format("%s  |cff9a978c#%d|r", Codex.MapName(id), id < 0 and -id or id))
                row.lbl:Show()
                row.rm:Show()
            else
                row.lbl:Hide()
                row.rm:Hide()
            end
        end
        if #state.z == 0 then zoneNone:Show() else zoneNone:Hide() end
        dgBtn:SetLabel(state.dg == nil and L.CODEX_PROPS_UNKNOWN or (state.dg and L.CODEX_PROPS_YES or L.CODEX_PROPS_NO))
        local isUnit = state.kind == "units"
        local hasDungeon = state.kind ~= nil
        if hasDungeon then dgLabel:Show(); dgBtn:Show() end
        if isUnit then
            clLabel:Show(); clBtn:Show(); lvLabel:Show(); l1Box:Show(); l2Box:Show(); lvDash:Show()
            clBtn:SetLabel(ClassLabel(state.cl))
        else
            clLabel:Hide(); clBtn:Hide(); lvLabel:Hide(); l1Box:Hide(); l2Box:Hide(); lvDash:Hide()
        end
        if state.kind == "quests" or state.kind == "items" then
            preLabel:SetText(state.kind == "items" and L.CODEX_PROPS_KEY or L.CODEX_PROPS_PRE)
            preLabel:Show(); preBox:Show()
        else
            preLabel:Hide(); preBox:Hide()
        end
        local isQuest = state.kind == "quests"
        for key, lbl in pairs(qLabels) do
            if isQuest then lbl:Show(); qBoxes[key]:Show() else lbl:Hide(); qBoxes[key]:Hide() end
        end
        -- fuer Quests ist das Fenster hoeher, der Hinweis rutscht nach unten
        win:SetHeight(isQuest and (baseY + 392) or 650)
        hint:ClearAllPoints()
        local hy = isQuest and (QROW.si + 40) or 104
        hint:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -baseY - hy)
        hint:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -baseY - hy)
    end

    local function Collect()
        local ed = { z = {}, dg = state.dg, cl = state.cl }
        for i, z in ipairs(state.z) do ed.z[i] = z end
        if state.kind == "units" then
            ed.l1, ed.l2 = tonumber(l1Box.edit:GetText()), tonumber(l2Box.edit:GetText())
        elseif state.kind == "quests" then
            local pre = {}
            for n in (preBox.edit:GetText() or ""):gmatch("%d+") do pre[#pre + 1] = tonumber(n) end
            if #pre > 0 then ed.pre = pre end
            for _, key in ipairs({ "nx", "bf", "af" }) do
                local list = {}
                for n in (qBoxes[key].edit:GetText() or ""):gmatch("%d+") do list[#list + 1] = tonumber(n) end
                if #list > 0 then ed[key] = list end
            end
            ed.ql = tonumber(qBoxes.ql.edit:GetText())
            local tx = qBoxes.tx.edit:GetText()
            if tx and tx:find("%S") then ed.tx = tx end
            ed.si = tonumber((qBoxes.si.edit:GetText() or ""):match("%d+"))
        elseif state.kind == "items" then
            ed.key = tonumber((preBox.edit:GetText() or ""):match("%d+"))
        end
        return ed
    end
    local function Save()
        if state.kind and state.id then
            Codex:SetEd(state.kind, state.id, Collect())
            if onChanged then onChanged() end
        end
        win:Hide()
    end
    local save = UI.CreateButton(win, L.CODEX_NAME_SAVE, 140, 28, Save, "primary")
    save:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    local clear = UI.CreateButton(win, L.CODEX_NAME_CLEAR, 140, 28, function()
        state.z, state.dg, state.cl = {}, nil, nil
        l1Box.edit:SetText("")
        l2Box.edit:SetText("")
        preBox.edit:SetText("")
        for _, b in pairs(qBoxes) do b.edit:SetText("") end
        Save()
    end, "default")
    clear:SetPoint("LEFT", save, "RIGHT", 8, 0)
    local cancel = UI.CreateButton(win, L.CODEX_NAME_CANCEL, 140, 28, function() win:Hide() end, "default")
    cancel:SetPoint("LEFT", clear, "RIGHT", 8, 0)

    function win.Open(kind, id)
        state.kind, state.id = kind, id
        local ed = Codex:GetEd(kind, id) or {}
        state.z = {}
        for i, z in ipairs(ed.z or {}) do state.z[i] = z end
        state.dg, state.cl = ed.dg, ed.cl
        l1Box.edit:SetText(ed.l1 and tostring(ed.l1) or "")
        l2Box.edit:SetText(ed.l2 and tostring(ed.l2) or "")
        preBox.edit:SetText(kind == "items" and (ed.key and tostring(ed.key) or "") or (ed.pre and table.concat(ed.pre, ", ") or ""))
        hint:SetText(kind == "quests" and (L.CODEX_PROPS_PRE_HINT .. "\n" .. L.CODEX_PROPS_HINT)
            or (kind == "items" and (L.CODEX_PROPS_KEY_HINT .. "\n" .. L.CODEX_PROPS_HINT)) or L.CODEX_PROPS_HINT)
        for _, key in ipairs({ "nx", "bf", "af" }) do
            qBoxes[key].edit:SetText(ed[key] and table.concat(ed[key], ", ") or "")
        end
        qBoxes.ql.edit:SetText(ed.ql and tostring(ed.ql) or "")
        qBoxes.tx.edit:SetText(ed.tx or "")
        qBoxes.si.edit:SetText(ed.si and tostring(ed.si) or "")
        zoneInput.edit:SetText("")
        Suggest()
        title:SetText(string.format("%s  #%s", L[KIND_LABEL[kind]] or kind, tostring(id)))
        local gn = GameName(kind, id)
        game:SetText(gn and string.format(L.CODEX_NAME_GAME, gn) or "")
        win.fwKey = kind .. ":" .. tostring(id)
        win.Refresh()
        win:Show()
        win:Raise()
    end
    return win
end

-- Stufenspanne eines Gebiets von Hand setzen (nur Berechtigte): geht wie alle Eigenschaften ueber die Vorschau im Dev-Reiter
local function BuildZoneProps(parent, onChanged)
    local L = FW.L
    local win = MakeWindow(parent, 420, 210)
    local state = {}
    local title = UI.CreateLabel(win, "", { font = "heading", size = 14, color = "goldLight" })
    title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    local lvLabel = UI.CreateLabel(win, L.CODEX_PROPS_LEVELS, { size = 12 })
    lvLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -52)
    local l1Box = MakeInput(win, 70)
    l1Box:SetPoint("TOPLEFT", win, "TOPLEFT", 190, -48)
    l1Box.edit:SetMaxLetters(3)
    local dash = UI.CreateLabel(win, "-", { size = 12 })
    dash:SetPoint("LEFT", l1Box, "RIGHT", 6, 0)
    local l2Box = MakeInput(win, 70)
    l2Box:SetPoint("LEFT", l1Box, "RIGHT", 20, 0)
    l2Box.edit:SetMaxLetters(3)
    local hint = UI.CreateLabel(win, L.CODEX_ZONE_EDIT_HINT, { size = 11, color = "textDim", justifyV = "TOP" })
    hint:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -86)
    hint:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -86)
    hint:SetHeight(60)
    hint:SetWordWrap(true)
    local function Save(clear)
        if state.key then
            local ed
            if not clear then ed = { l1 = tonumber(l1Box.edit:GetText()), l2 = tonumber(l2Box.edit:GetText()) } end
            Codex:SetEd("zones", Codex.ZoneEdID(state.key), ed)
            if onChanged then onChanged() end
        end
        win:Hide()
    end
    local save = UI.CreateButton(win, L.CODEX_NAME_SAVE, 120, 28, function() Save(false) end, "primary")
    save:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    local clear = UI.CreateButton(win, L.CODEX_NAME_CLEAR, 120, 28, function() Save(true) end, "default")
    clear:SetPoint("LEFT", save, "RIGHT", 8, 0)
    local cancel = UI.CreateButton(win, L.CODEX_NAME_CANCEL, 120, 28, function() win:Hide() end, "default")
    cancel:SetPoint("LEFT", clear, "RIGHT", 8, 0)
    function win.Open(key)
        state.key = key
        local ed = Codex:GetEd("zones", Codex.ZoneEdID(key)) or {}
        l1Box.edit:SetText(ed.l1 and tostring(ed.l1) or "")
        l2Box.edit:SetText(ed.l2 and tostring(ed.l2) or "")
        title:SetText(string.format("%s: %s", L.CODEX_KIND_ZONES, Codex.MapName(key)))
        win.fwKey = "zones:" .. tostring(key)
        win:Show()
        win:Raise()
    end
    return win
end

------------------------------------------------------------------------
-- Fenster "Namen einfuegen"
------------------------------------------------------------------------

local function BuildImport(parent, onChanged)
    local L = FW.L
    local win = MakeWindow(parent, 560, 440)
    local state = { lang = Codex.Lang() }

    local title = UI.CreateLabel(win, L.CODEX_NAME_IMPORT, { font = "heading", size = 14, color = "goldLight" })
    title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    local help = UI.CreateLabel(win, "", { size = 11, color = "textDim", justifyV = "TOP" })
    help:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -40)
    help:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -40)
    help:SetHeight(32)
    help:SetWordWrap(true)

    local deButton, enButton
    local function Sync()
        deButton:SetStyle(state.lang == "de" and "primary" or "default")
        enButton:SetStyle(state.lang == "en" and "primary" or "default")
    end
    deButton = UI.CreateButton(win, L.CODEX_NAME_DE, 140, 26, function() state.lang = "de"; Sync() end, "default")
    deButton:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -78)
    enButton = UI.CreateButton(win, L.CODEX_NAME_EN, 140, 26, function() state.lang = "en"; Sync() end, "default")
    enButton:SetPoint("LEFT", deButton, "RIGHT", 8, 0)

    local area = UI.CreateTextArea(win, 528, 220)
    area:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -112)

    local result = UI.CreateLabel(win, "", { size = 12, color = "goldLight" })
    result:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -344)
    result:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -344)

    local go = UI.CreateButton(win, L.CODEX_NAME_IMPORT_GO, 140, 28, function()
        local done, skipped = Codex:ImportNames(state.kind, state.lang, area:GetText())
        result:SetText(string.format(L.CODEX_NAME_IMPORT_RESULT, done, skipped))
        if onChanged then onChanged() end
    end, "primary")
    go:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    local close = UI.CreateButton(win, L.CODEX_NAME_CLOSE, 140, 28, function() win:Hide() end, "default")
    close:SetPoint("LEFT", go, "RIGHT", 8, 0)

    function win.Open(kind)
        state.kind = kind
        state.lang = Codex.Lang()
        Sync()
        help:SetText(string.format(L.CODEX_NAME_IMPORT_HELP, L[KIND_LABEL[kind]] or kind))
        result:SetText("")
        area:SetText("")
        win:Show()
        win:Raise()
    end
    return win
end

------------------------------------------------------------------------
-- Knoepfe im Tab
-- getSel() gibt art, auswahl zurueck; onChanged() aktualisiert Liste und Detail
------------------------------------------------------------------------

function NameUI.Attach(f, getSel, onChanged, origin)
    local L = FW.L
    local ctl = { height = 0 }
    origin = origin or { x = 0, y = 0 }
    local editWin, importWin, propsWin, zoneWin
    function NameUI.OpenZone(key)
        if not (Codex.Trust and Codex.Trust.CanEdit()) then return end
        zoneWin = zoneWin or BuildZoneProps(f, onChanged)
        zoneWin.Open(key)
    end

    local editButton = UI.CreateButton(f, L.CODEX_NAME_EDIT, 150, 26, function()
        local kind, id = getSel()
        if EDITABLE[kind] and id then
            editWin = editWin or BuildEdit(f, onChanged)
            editWin.Open(kind, id)
        end
    end, "default")
    editButton:Hide()

    local importButton = UI.CreateButton(f, L.CODEX_NAME_IMPORT, 150, 26, function()
        local kind = getSel()
        if EDITABLE[kind] then
            importWin = importWin or BuildImport(f, onChanged)
            importWin.Open(kind)
        end
    end, "default")
    importButton:Hide()

    local propsButton = UI.CreateButton(f, L.CODEX_PROPS_BTN, 150, 26, function()
        local kind, id = getSel()
        if EDITABLE[kind] and id then
            propsWin = propsWin or BuildProps(f, onChanged)
            propsWin.Open(kind, id)
        end
    end, "default")
    propsButton:Hide()

    -- "Fehlerhaft markieren" (nur Berechtigte): blendet den Datensatz bei allen Spielern aus
    local function BadNow(kind, id)
        local hook = Codex.DevHook
        local staged = hook and hook.StagedBad and hook.StagedBad(kind, id)
        if staged ~= nil then return staged end
        return Codex:IsBad(kind, id)
    end
    local badButton = UI.CreateButton(f, L.CODEX_BAD_MARK, 170, 26, function()
        local kind, id = getSel()
        if kind and id and kind ~= "items" then
            Codex:SetBad(kind, id, not BadNow(kind, id))
            if onChanged then onChanged() end
            ctl.Update()
        end
    end, "default")
    badButton:Hide()

    -- Die Knoepfe stehen in einer eigenen Reihe unter "Zurueck/Favorit", von links nach rechts;
    -- ist der Platz zu knapp, laufen sie in die naechste Reihe. ctl.height ist die belegte Hoehe.
    local strip = { propsButton, badButton, importButton, editButton }
    function ctl.Layout()
        local avail = (f:GetWidth() or 0) - origin.x
        if avail < 240 then avail = 640 end
        local x, y, any = 0, 0, false
        for _, b in ipairs(strip) do
            if b:IsShown() then
                local w = b:GetWidth() or 150
                if x > 0 and x + w > avail then
                    x = 0
                    y = y + 32
                end
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", f, "TOPLEFT", origin.x + x, -(origin.y + y))
                x = x + w + 8
                any = true
            end
        end
        local h = any and (y + 32) or 0
        if h ~= ctl.height then
            ctl.height = h
            if origin.relayout then origin.relayout() end
        end
    end
    ctl.strip = strip

    function ctl.Update()
        local kind, id = getSel()
        if EDITABLE[kind] and kind ~= "items" and id and Codex.Trust then
            local bad = BadNow(kind, id)
            if Codex.Trust.Can(bad and "unbad" or "bad") then
                badButton:SetLabel(bad and L.CODEX_BAD_UNMARK or L.CODEX_BAD_MARK)
                badButton:SetStyle(bad and "primary" or "default")
                badButton:Show()
            else
                badButton:Hide()
            end
        else
            badButton:Hide()
        end
        -- Namen bearbeiten: nur berechtigte Charaktere mit dem Modul Freewood-Dev
        local can = Codex.Trust ~= nil and Codex.Trust.CanEdit()
        if can and EDITABLE[kind] and id then editButton:Show() else editButton:Hide() end
        if can and EDITABLE[kind] then importButton:Show() else importButton:Hide() end
        if can and EDITABLE[kind] and id then propsButton:Show() else propsButton:Hide() end
        if propsWin and propsWin:IsShown() and propsWin.fwKey ~= (tostring(kind) .. ":" .. tostring(id)) then propsWin:Hide() end
        if editWin and editWin:IsShown() and editWin.fwKey ~= (tostring(kind) .. ":" .. tostring(id)) then editWin:Hide() end
        if importWin and importWin:IsShown() and not EDITABLE[kind] then importWin:Hide() end
        ctl.Layout()
    end
    ctl.editButton, ctl.importButton, ctl.propsButton = editButton, importButton, propsButton
    return ctl
end
