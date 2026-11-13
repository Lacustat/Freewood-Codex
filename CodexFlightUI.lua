-- Freewood-Codex: Flugfenster
--
-- Waehrend eines Fluges mit dem Flugmeister: kleines Fenster mit Zielname, Flugzeit und einem Balken.
--   * Ist die Dauer der Strecke bekannt (selbst geflogen, von anderen gemeldet oder aus Teilstrecken geschaetzt): verbleibende Zeit,
--     der Balken laeuft leer.
--   * Ist sie unbekannt: das Fenster misst die Zeit und zaehlt sie hoch, der Balken laeuft voll (und wieder von vorn); die Messung wird
--     am Ende des Fluges gespeichert (CodexFlight.lua).
-- Das Fenster ist verschiebbar, die Lage wird gemerkt. Einstellung: db.settings.flightWindow (an/aus).
-- UNGEPRUEFT im Spiel.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
local Flight = NS and NS.Flight
if not FW or not Codex or not Flight or not FW.UI then
    return
end
local UI = FW.UI

local WIDTH, HEIGHT, BAR_H = 260, 52, 8
local win

local function Settings()
    local db = Codex.db
    if not db then return {} end
    db.settings = db.settings or {}
    return db.settings
end

function Flight.WindowOn()
    return Settings().flightWindow ~= false
end

local function SavePos()
    if not win then return end
    local point, _, rel, x, y = win:GetPoint(1)
    if point then Settings().flightWinPos = { point = point, rel = rel, x = x, y = y } end
end

local function ApplyPos()
    win:ClearAllPoints()
    local p = Settings().flightWinPos
    if type(p) == "table" and p.point and p.x and p.y then
        win:SetPoint(p.point, UIParent, p.rel or p.point, p.x, p.y)
    else
        win:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
end

-- Anzeige fuer eine Zeit: gibt Text, Anteil (0..1) und Farbschluessel zurueck. Rein, daher einzeln pruefbar.
function Flight.WindowState(fl, elapsed, L)
    if fl.exp and fl.exp > 0 then
        local left = fl.exp - elapsed
        if left > 0 then
            return string.format(L.CODEX_TAXI_LEFT, Flight.Duration(math.ceil(left))), left / fl.exp, "gold"
        end
        return L.CODEX_TAXI_ARRIVING, 0, "success"
    end
    return string.format(L.CODEX_TAXI_UNKNOWN, Flight.Duration(elapsed)), (elapsed % 30) / 30, "bronze"
end

local function Build()
    local f = UI.CreatePanel(UIParent, "bg", "gold")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
    win = f
    ApplyPos()

    f.title = UI.CreateLabel(f, "", { size = 12, color = "goldLight" })
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -7)
    f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -7)
    f.title:SetHeight(14)

    f.time = UI.CreateLabel(f, "", { size = 11, color = "text" })
    f.time:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
    f.time:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -2)
    f.time:SetHeight(13)

    f.barBg = f:CreateTexture(nil, "ARTWORK")
    f.barBg:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
    f.barBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    f.barBg:SetHeight(BAR_H)
    f.barBg:SetColorTexture(UI.Color("card"))

    f.fill = f:CreateTexture(nil, "OVERLAY")
    f.fill:SetPoint("BOTTOMLEFT", f.barBg, "BOTTOMLEFT", 0, 0)
    f.fill:SetHeight(BAR_H)
    f.fill:SetColorTexture(UI.Color("gold"))

    f.acc = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.acc = self.acc + (elapsed or 0)
        if self.acc < 0.1 then return end
        self.acc = 0
        local fl = Flight.flight
        if not fl or not Flight.WindowOn() then self:Hide() return end
        local L = FW.L
        local el = (_G.GetTime and _G.GetTime() or 0) - fl.t0
        if self.shownName ~= (fl.name or "") then
            self.shownName = fl.name or ""
            self.title:SetText(fl.name and string.format(L.CODEX_TAXI_TITLE, fl.name) or L.CODEX_TAXI_TITLE_UNKNOWN)
        end
        local full = self.barBg:GetWidth() or (WIDTH - 20)
        local text, frac, color = Flight.WindowState(fl, el, L)
        self.time:SetText(text)
        self.fill:SetColorTexture(UI.Color(color))
        self.fill:SetWidth(math.max(1, full * math.max(0, math.min(1, frac))))
    end)
    f:Hide()
    return f
end

-- Das Fenster zeigt sich, sobald ein Flug laeuft
local watch = _G.CreateFrame("Frame")
local acc = 0
watch:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < 0.25 then return end
    acc = 0
    if Flight.flight and Flight.WindowOn() then
        if not win then win = Build() end
        if not win:IsShown() then win.shownName = nil; win:Show() end
    end
end)

if UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-flight", {
        category = "database",
        order = 108,
        height = 150,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_TAXI_HEADER)
            local note = UI.CreateLabel(f, L.CODEX_TAXI_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
            stack:Add(note, { fit = true, gap = 8 })
            local cb = UI.CreateCheckbox(f, L.CODEX_TAXI_SWITCH, function() return Flight.WindowOn() end,
                function(on) Settings().flightWindow = on and true or false end)
            stack:Add(cb, { fit = true, gap = 6 })
            local cb2 = UI.CreateCheckbox(f, L.CODEX_TAXI_FIXMSG, function() return Flight.FixMsgOn() end,
                function(on) Settings().flightFixMsg = on and true or false end)
            stack:Add(cb2, { fit = true, gap = 6 })
            function f.Refresh() cb:Refresh(); cb2:Refresh(); stack:Layout() end
            stack:Layout()
            return f
        end,
        refresh = function(frame) frame.Refresh() end,
    })
end
