-- Test: Item-Filter im Codex fuer ungeladene Items (Auktionshaus, Typ/Untertyp ohne Laden, gezieltes Nachladen)
-- texlua tests/itemfilter_test.lua   (Daten erfunden)
local src = assert(io.open("CodexUI.lua")):read("*a")
local cut = assert(src:find("\n%-%- Tab\n"))
local seg = src:sub(1, cut) .. "\nreturn BuildEntries"
_G.CreateFrame = function() return setmetatable({}, { __index = function() return function() end end }) end
local cached = {}
_G.Freewood = { UI = { RarityHex = function() return "ffffff" end }, L = setmetatable({}, { __index = function(_, k) return k end }),
    Util = { GetItem = function(id) return cached[id] end } }
local instant = {
    [9001] = { "Waffe", "Bögen", "INVTYPE_RANGED" },      -- epischer Bogen, nur aus dem Auktionshaus
    [9002] = { "Waffe", "Bögen", "INVTYPE_RANGED" },      -- gruener Bogen
    [9003] = { "Waffe", "Schwerter", "INVTYPE_WEAPON" },  -- Schwert mit "bogen" im Namen
}
_G.C_Item = { GetItemInfoInstant = function(id) local t = instant[id] if t then return id, t[1], t[2], t[3], 1, 2, 2 end end }
local db = {
    units = { [1] = { d = { [9002] = { n = 1 } }, k = 1 } }, objects = {}, quests = {},
    names = { [9001] = "Bogen der Probe", [9002] = "Grüner Bogen", [9003] = "Krummbogenschwert", [9004] = "Unbekannter Bogen" },
    iq = { [9001] = 4, [9002] = 2, [9003] = 4 },
    istats = {},
}
local Codex = { db = db, V = function() return db end, GRID = 100,
    ExtraItems = function() return { [9001] = true, [9003] = true, [9004] = true } end,
    Seed = { Ready = function() return false end, Available = function() return false end },
    Catalog = { GetItem = function() return nil end },
    MainMap = function() return nil end, MapName = function() return nil end }
function Codex:ItemName(id) return self.db.names[id] end
function Codex:GetStats(id) return self.db.istats[id] end
setmetatable(Codex, { __index = function() return function() end end })
local BuildEntries = assert(load(seg))("Freewood-Codex", { Codex = Codex })

local function Run(flt)
    flt.q = flt.q or {}
    local list, missing = BuildEntries("items", "bogen", flt, {})
    local ids, miss = {}, {}
    for _, e in ipairs(list) do ids[e.id] = true end
    for _, id in ipairs(missing or {}) do miss[id] = true end
    return ids, miss, #list
end

-- ohne Filter: alle vier
local ids, _, n = Run({})
assert(n == 4, "ohne Filter alle: " .. n)
-- nur episch: Bogen und Schwert (Qualitaet aus dem Merker)
ids = Run({ q = { [4] = true } })
assert(ids[9001] and ids[9003] and not ids[9002], "episch")
-- episch + Waffe + Bogen, nichts geladen: der Auktionshaus-Bogen ist dabei (frueher fehlte er)
local miss
ids, miss, n = Run({ q = { [4] = true }, type = "Waffe", sub = "Bögen" })
assert(n == 1 and ids[9001], "epischer Bogen ungeladen gefunden: " .. n)
-- 9004 hat keine Qualitaet und keinen Typ: nicht entscheidbar -> wird nachgeladen, nicht stillschweigend verworfen
assert(miss[9004] and not miss[9003] and not miss[9002], "nur unklare Items werden angefragt")
-- geladen: echte Daten gehen vor
cached[9001] = { id = 9001, name = "Bogen der Probe", quality = 4, type = "Waffe", subType = "Bögen", equipLoc = "INVTYPE_RANGED", itemLevel = 50 }
ids = Run({ q = { [4] = true }, type = "Waffe", sub = "Bögen" })
assert(ids[9001], "geladen gefunden")
-- Stufenfilter: ungeladen ohne Stufe = unklar, geladen mit Stufe = echter Vergleich
ids, miss = Run({ ilMin = 40 })
assert(ids[9001] and miss[9002] and miss[9003], "Stufe unbekannt -> nachladen")
ids = Run({ ilMin = 60 })
assert(not ids[9001], "Stufe 50 < 60")
-- Werte: ungeladen ohne gespeicherte Werte = unklar
ids, miss = Run({ stats = { { key = "ITEM_MOD_AGILITY_SHORT", min = 1 } } })
assert(miss[9002], "Werte fehlen -> nachladen")
-- ohne GetItemInfoInstant: Typfilter laesst ungeladene Items nachladen statt sie zu verwerfen
_G.C_Item = nil
cached[9001] = nil
ids, miss = Run({ type = "Waffe", sub = "Bögen" })
assert(not ids[9001] and miss[9001] and miss[9002], "ohne Sofort-Abfrage: nachladen")
-- Merkliste ohne Obergrenze
local csrc = assert(io.open("Codex.lua")):read("*a")
assert(not csrc:find("n >= 8000", 1, true), "Obergrenze der Qualitaets-Merkliste entfernt")
print("itemfilter_test OK")
