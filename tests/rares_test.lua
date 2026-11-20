-- Test: Rare-Mob-Tracker (Codex.Rares)   texlua tests/rares_test.lua
local clock = 100
_G.GetTime = function() return clock end
local combat = false
_G.InCombatLockdown = function() return combat end
local hooks = {}
_G.hooksecurefunc = function(t, name, fn) hooks[name] = fn end
_G.C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return {} end }
_G.ITEM_QUALITY_COLORS = {}
_G.SlashCmdList = {}

-- Rahmen-Attrappe: Methoden aus einer Tabelle, unbekannte Methoden tun nichts
local made = {}
local function noop() end
local M = {}
M.__index = function(t, k) if M[k] then return M[k] end if type(k) == "string" and k:match("^%u") then return noop end end
function M.SetSize(f, w, h) f.w, f.h = w, h end
function M.SetHeight(f, h) f.h = h end
function M.SetWidth(f, w) f.w = w end
function M.GetWidth(f) return f.w or 300 end
function M.GetHeight(f) return f.h or 200 end
function M.Show(f) f.shown = true end
function M.Hide(f) f.shown = false end
function M.IsShown(f) return f.shown == true end
function M.SetAlpha(f, a) f.alpha = a end
function M.SetAttribute(f, k, v) f.attr = f.attr or {} f.attr[k] = v end
function M.SetScript(f, k, fn) f.scripts = f.scripts or {} f.scripts[k] = fn end
function M.HookScript(f, k, fn) f.hooked = f.hooked or {} f.hooked[k] = fn end
function M.SetText(f, t) f.text = t end
function M.GetText(f) return f.text end
function M.GetLeft() return 500 end
function M.GetBottom() return 400 end
function M.GetEffectiveScale() return 1 end
function M.GetFrameLevel() return 5 end
function M.GetPoint() return "TOP", nil, "TOP", 0, -140 end
function M.SetPoint(f, ...) f.points = f.points or {} f.points[#f.points + 1] = { ... } end
function M.ClearAllPoints(f) f.points = {} end
function M.SetTexture(f, t) f.tex = t end
function M.CreateTexture() return setmetatable({}, M) end
function M.CreateFontString() return setmetatable({}, M) end
function M.SetUnit(f, u) f.unit = u end
function M.SetCreature(f, id) f.creature = id end
function M.GetModelFileID() return 12345 end
_G.CreateFrame = function(kind, name, parent, tmpl)
    local f = setmetatable({ kind = kind, name = name, tmpl = tmpl }, M)
    made[#made + 1] = f
    return f
end
_G.UIParent = setmetatable({}, M)

-- Einheiten
local units = {}
_G.UnitExists = function(u) return units[u] ~= nil end
_G.UnitIsDead = function(u) return units[u] and units[u].dead end
_G.UnitIsPlayer = function() return false end
_G.UnitGUID = function(u) return units[u] and units[u].guid end
_G.UnitClassification = function(u) return units[u] and units[u].cls end
_G.UnitLevel = function(u) return units[u] and units[u].lvl end

local mapWorld = 2000
_G.C_Map = { GetMapWorldSize = function() return mapWorld end, GetBestMapForUnit = function() return 1411 end }

local sounds, fired, printed, sections = 0, {}, {}, {}
local L = setmetatable({}, { __index = function(_, k) return k end })
local UI = {}
function UI.CreatePanel() return CreateFrame("Frame") end
function UI.CreateLabel(p, t) local fs = setmetatable({}, M) fs.text = t return fs end
function UI.CreateButton(p, t, w, h, fn) local b = CreateFrame("Button") b.onClick = fn return b end
function UI.CreateCheckbox(p, t, g, s) local c = CreateFrame("Button") c.get, c.set = g, s return c end
function UI.CreateSection() local f = CreateFrame("Frame") return f, { Add = noop, Layout = noop } end
function UI:RegisterSettingsSection(id, def) sections[id] = def end
local events = {}
local FW = { L = L, UI = UI, Anim = { PlaySound = function() sounds = sounds + 1 end },
    Util = { GetPlayerLocation = function() return { mapID = 1411, x = 0.5, y = 0.5 } end } }
function FW:RegisterEvent(ev, fn) events[ev] = fn return true end
function FW:Fire(ev, ...) fired[#fired + 1] = { ev, ... } end
function FW:Print(t) printed[#printed + 1] = t end
_G.Freewood = FW

-- Daten: Rares 100 (Startdaten) und 200 (eigener Eintrag mit cl=rare), 300 normal
local GRID = 200
local function Cell(m, cx, cy) return m * GRID * GRID + cy * GRID + cx end
local quality = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 4, [6] = 2, [7] = 2, [8] = 2, [9] = 2, [10] = 2, [11] = 2, [12] = 2 }
local db = { settings = {}, iicon = { [3] = "icon3" } }
local view = { units = {
    [200] = { n = "Eigener Rare", ed = { cl = "rare" }, lvl = 30, k = 6, d = { [3] = { n = 6, q = 6 }, [4] = { n = 1, q = 1 } },
        cells = { [Cell(1411, 10, 10)] = 1 } },
    [100] = { n = "Seed Rare", k = 2, d = { [4] = { n = 2, q = 2 } } },
} }
local Seed
Seed = {
    Load = function() return true end,
    RoleIDs = function(r) return r == "rares" and { { kind = "units", id = 100 }, { kind = "objects", id = 9 } } or {} end,
    Entity = function(k, id) if id == 100 then return { l1 = 20, l2 = 22 } end end,
    Name = function(k, id) return id == 100 and "Seed Rare" or nil end,
    Drops = function(k, id)
        if id == 100 then
            local t = {}
            for i = 1, 12 do t[#t + 1] = { item = i, chance = i } end   -- Prozent
            return t
        end
        return {}
    end,
    Cells = function(k, id)
        if id == 100 then return { [Cell(1411, 100, 100)] = 1, [Cell(1411, 101, 100)] = 1, [Cell(1411, 150, 20)] = 1, [Cell(1429, 5, 5)] = 1 } end
        return {}
    end,
    near = nil,
    Nearest = function() return Seed.near or {} end,
}
local Codex = { db = db, GRID = GRID, Seed = Seed, V = function() return view end,
    NameOf = function(e) return e.n end, MapName = function(m) return m == 1411 and "Durotar" or "?" end,
    QualityOf = function(id) return quality[id] end,
    ItemName = function(_, id) return "Item" .. id end,
    DropList = function(ent)
        local out = {}
        for id, d in pairs(ent.d or {}) do out[#out + 1] = { id = id, chance = d.n / ent.k } end
        return out
    end }
local NS = { Codex = Codex }
assert(loadfile("CodexRares.lua"))("Freewood-Codex", NS)
local R = Codex.Rares
assert(R, "Modul geladen")

-- GUID
assert(R.NpcFromGUID("Creature-0-1-2-3-4567-0000ABCD") == 4567, "npcID aus GUID")
assert(R.NpcFromGUID("Player-1-0ABC") == nil, "Spieler: keine ID")
assert(R.NpcFromGUID(nil) == nil)

-- Bekannte Rares
local set = R.KnownSet()
assert(set[100] and set[200] and not set[9] and not set[300], "Startdaten-Rolle + eigener cl=rare, keine Objekte")

-- Beute: nur Qualitaet >= 2, hoechstens 8, nach Chance
local loot = R.Loot(100)
assert(#loot == 8, "hoechstens 8, war " .. #loot)
assert(loot[1].id == 12 and loot[1].chance == 0.12, "hoechste Chance zuerst")
for _, e in ipairs(loot) do assert(e.q >= 2, "kein Grau/Weiss: " .. e.id) end
local hasLow = false
for _, e in ipairs(loot) do if e.id <= 2 then hasLow = true end end
assert(not hasLow, "Item 1 (grau) und 2 (weiss) fehlen")
-- eigene Kills (ab 5) gehen vor
local own = R.Loot(200)
assert(#own == 2 and own[1].id == 3 and own[1].chance == 1 and own[1].icon == "icon3", "eigene Kills")
-- unter 5 Kills: nur Vorlage
assert(R.Loot(100)[1].chance == 0.12, "2 Kills zaehlen nicht")

-- Fundorte: gebuendelt je Karte
local spots = R.Spots(100, 1411)
assert(#spots == 2, "zwei Buendel auf 1411, war " .. #spots)
assert(#R.Spots(100, 1429) == 1 and #R.Spots(100, 9999) == 0)

-- Erkennen: Standard aus
units.target = { guid = "Creature-0-1-2-3-100-00AA", cls = "normal", lvl = 21 }
assert(R.TrackOn() == false and R.MapOn() == false, "Standard aus")
assert(R.CheckUnit("target") == false and sounds == 0, "aus: nichts")

db.settings.rareTrack = true
assert(R.CheckUnit("target") == true, "Startdaten-Rare erkannt (auch ohne Klassifizierung)")
assert(sounds == 1, "Weckerton")
local win = _G.FreewoodRareFrame
assert(win and win.shown, "Fenster sichtbar")
assert(win.title.text:find("Seed Rare", 1, true) and win.title.text:find("(21)", 1, true), "Titel mit Name und Stufe: " .. win.title.text)
assert(win.sub.text:find("Durotar", 1, true) and win.sub.text:find("50.0, 50.0", 1, true), "Koordinaten")
assert(win.model.unit == "target" and not win.skull.shown, "Modell der Einheit")
assert(fired[#fired][1] == "CODEX_RARE" and fired[#fired][2] == 100)

-- sicherer Knopf: /targetexact, an UIParent, nicht am Fenster
local secure = _G.FreewoodRareTarget
for _, f in ipairs(made) do if f.name == "FreewoodRareTarget" then secure = f end end
assert(secure and secure.tmpl == "SecureActionButtonTemplate", "sicherer Knopf")
assert(secure.attr.type1 == "macro" and secure.attr.macrotext1 == "/targetexact Seed Rare", "Makro")
assert(secure.shown and secure.points[1][2] == _G.UIParent, "an UIParent")

-- 10 Minuten Ruhe
assert(R.CheckUnit("target") == false and sounds == 1, "nicht erneut")
clock = clock + 599
assert(R.CheckUnit("target") == false)
clock = clock + 2
assert(R.CheckUnit("target") == true and sounds == 2, "nach 10 Minuten wieder")

-- normale Kreatur, tote Kreatur
units.mouseover = { guid = "Creature-0-1-2-3-300-00AA", cls = "normal" }
assert(R.CheckUnit("mouseover") == false, "normal: nichts")
units.mouseover = { guid = "Creature-0-1-2-3-555-00AA", cls = "rareelite", lvl = -1 }
assert(R.CheckUnit("mouseover") == true and win.title.text:find("(??)", 1, true), "Klassifizierung rareelite, Stufe ??")
units.mouseover = { guid = "Creature-0-1-2-3-556-00AA", cls = "rare", dead = true }
assert(R.CheckUnit("mouseover") == false, "tot: nichts")

-- Rechtsklick schliesst (ueber den sicheren Knopf)
secure.scripts.PostClick(secure, "RightButton")
assert(not win.shown and not secure.shown and R.current == nil, "Rechtsklick schliesst")

-- Im Kampf: Fenster ja, Knopf nicht bewegt; Schliessen nur unsichtbar, nach dem Kampf verborgen
clock = clock + 1000
R.Show(200, "seen")
assert(secure.attr.macrotext1 == "/targetexact Eigener Rare")
combat = true
secure.attr.macrotext1 = "unberuehrt"
units.nameplate1 = { guid = "Creature-0-1-2-3-777-00AA", cls = "rare", lvl = 25 }
assert(R.CheckUnit("nameplate1") == true, "im Kampf gemeldet")
assert(win.hint.text == "CODEX_RARE_HINT_COMBAT", "Kampf-Hinweis")
assert(secure.attr.macrotext1 == "unberuehrt", "im Kampf keine Attribute")
R.Close()
assert(secure.alpha == 0 and secure.shown, "im Kampf nur unsichtbar")
combat = false
events.PLAYER_REGEN_ENABLED()
assert(not secure.shown and secure.alpha == 1, "nach dem Kampf verborgen")

-- Kampfende mit offenem Fenster: Knopf wird nachgezogen
combat = true
clock = clock + 1000
R.Show(100, "seen")
combat = false
events.PLAYER_REGEN_ENABLED()
assert(secure.attr.macrotext1 == "/targetexact Seed Rare" and win.hint.text == "CODEX_RARE_HINT", "nach dem Kampf Ziel moeglich")
R.Close()

-- Moeglicher Fundort: ohne Ton, spaeter echte Sichtung erlaubt
local before = sounds
Seed.near = { { kind = "units", id = 200, dist = 0.05, m = 1411, x = 0.1, y = 0.2 } }   -- 0.05 * 2000 = 100 Yards
clock = clock + 1000
R.last[200] = nil
assert(R.CheckSpawns() == true and sounds == before, "Fundort: Hinweis ohne Ton")
assert(win.title.text:find("CODEX_RARE_SPAWN", 1, true) and win.sub.text:find("10.0, 20.0", 1, true), "Fundort-Titel und Koordinaten")
assert(R.CheckSpawns() == false, "Fundort nicht erneut")
units.target = { guid = "Creature-0-1-2-3-200-00AA", cls = "rare", lvl = 30 }
assert(R.CheckUnit("target") == true and sounds == before + 1, "aus Fundort wird Sichtung")
Seed.near = { { kind = "units", id = 100, dist = 0.2, m = 1411, x = 0.1, y = 0.2 } }   -- 400 Yards
R.last[100] = nil
assert(R.CheckSpawns() == false, "zu weit")
mapWorld = nil
Seed.near = { { kind = "units", id = 100, dist = 0.03, m = 1411 } }
assert(R.CheckSpawns() == true, "ohne Kartengroesse: Anteil")
combat = true
R.last[100] = nil
assert(R.CheckSpawns() == false, "im Kampf kein Fundort-Hinweis")
combat = false

-- Karte
local wm = setmetatable({ ScrollContainer = setmetatable({ Child = setmetatable({ w = 1000, h = 700 }, M) }, M) }, M)
function wm.GetMapID() return 1411 end
_G.WorldMapFrame = wm
assert(R.RefreshMap() == 0, "Karte aus")
db.settings.rareMap = true
assert(R.HookMap() == true and hooks.OnMapChanged, "Karte eingehakt")
local n = R.RefreshMap()
assert(n == 3, "3 Totenkoepfe (2 + 1), war " .. n)
local lines = {}
local tt = { SetText = function(_, t) lines[#lines + 1] = t end, AddLine = function(_, t) lines[#lines + 1] = t end,
    AddDoubleLine = function(_, a, b) lines[#lines + 1] = a .. "|" .. b end, Show = noop }
R.FillTooltip(tt, 100)
assert(lines[1] == "Seed Rare" and lines[2]:find("20-22", 1, true), "Tooltip: Name und Stufe")
assert(lines[3] == "CODEX_RARE_LOOT" and #lines == 3 + 8 and lines[4]:find("Item12", 1, true) and lines[4]:find("12 %", 1, true), "Tooltip: Beute")
db.settings.rareMap = false
assert(R.RefreshMap() == 0)

-- Einstellungen
local sec = sections["codex-rares"]
assert(sec and sec.category == "quest", "Abschnitt unter Quest & Hinweise")
local f = sec.build(CreateFrame("Frame"))
f.track.set(false)
assert(db.settings.rareTrack == false and f.track.get() == false)
f.map.set(true)
assert(db.settings.rareMap == true)

-- Befehl
clock = clock + 1000
Seed.near = { { kind = "units", id = 100, dist = 0.5, m = 1411, x = 0.3, y = 0.4 } }
local s0 = sounds
SlashCmdList.FWRARE("")
assert(win.shown and R.current.id == 100 and sounds == s0 + 1, "/fwrare zeigt Test")
SlashCmdList.FWRARE("probe")
assert(printed[#printed]:find("Rares bekannt", 1, true), "probe")

-- Minikarte (0.52.0)
local px, py = 0.5, 0.5
_G.CreateVector2D = function(x, y) return { x = x, y = y } end
local function Vec(x, y) return { GetXY = function() return x, y end } end
C_Map.GetPlayerMapPosition = function() return Vec(px, py) end
C_Map.GetWorldPosFromMapPos = function(m, v) if m == 1411 then return 1, Vec(v.x * 1000, v.y * 1000) end end
local radius = 200
_G.C_Minimap = { GetViewRadius = function() return radius end }
_G.Minimap = setmetatable({ w = 140 }, M)
R.hot = nil
assert(R.UpdateMinimap() == 0, "Minikarte aus")
db.settings.rareMini = true
assert(R.UpdateMinimap() == 1, "nur der nahe Fundort sichtbar")
local mp = R.miniPins[1]
assert(mp.shown and mp.rare == 100 and mp.w == R.MINI_SIZE, "normaler Totenkopf")
local pt = mp.points[1]
assert(pt[1] == "CENTER" and pt[3] == "CENTER" and pt[4] > 0 and pt[5] < 0, "Ost positiv, Sued nach unten")
-- hervorgehoben: zuletzt gemeldet, 10 Minuten
R.hot = { id = 100, t = clock }
R.UpdateMinimap()
assert(mp.w == R.MINI_HOT, "zuletzt gemeldet: groesser")
clock = clock + 601
R.UpdateMinimap()
assert(mp.w == R.MINI_SIZE, "nach 10 Minuten wieder normal")
-- weiter weg zoomen: mehr Fundorte sichtbar, nichts am Rand
radius = 800
assert(R.UpdateMinimap() == 3, "alle drei im Ausschnitt")
radius = 550
assert(R.UpdateMinimap() == 2, "der 633 Yards entfernte (Rare 200) nicht, 471 Yards ja")
radius = 450
assert(R.UpdateMinimap() == 1, "knapp ausserhalb: nicht am Rand")
radius = 200
-- drehende Minikarte
_G.GetCVar = function(k) return k == "rotateMinimap" and "1" or nil end
_G.GetPlayerFacing = function() return math.pi end   -- Blick nach Sueden
R.UpdateMinimap()
pt = mp.points[1]
assert(pt[4] < 0 and pt[5] > 0, "gedreht: Suedost liegt vorne links")
_G.GetCVar = nil
-- Tooltip: nur Name und Stufe
local ml = {}
R.FillMiniTooltip({ SetText = function(_, t) ml[#ml + 1] = t end, AddLine = function(_, t) ml[#ml + 1] = t end, Show = noop }, 100)
assert(#ml == 2 and ml[1] == "Seed Rare" and ml[2]:find("20-22", 1, true), "Minikarte-Tooltip ohne Beute")
-- anderer Kontinent / keine Weltposition
C_Map.GetBestMapForUnit = function() return 1429 end
assert(R.UpdateMinimap() == 0 and not mp.shown, "andere Karte: nichts")
C_Map.GetBestMapForUnit = function() return 1411 end
-- Haken in den Einstellungen
local f2 = sections["codex-rares"].build(CreateFrame("Frame"))
f2.mini.set(false)
assert(db.settings.rareMini == false and R.UpdateMinimap() == 0, "Haken aus")

print("rares_test: ok")
