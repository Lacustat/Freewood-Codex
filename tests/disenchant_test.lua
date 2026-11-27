-- Test 0.56.0: Entzaubern (Regel aus CMaNGOS, Tooltip, Auktionswert, eigene Messung)
-- texlua tests/disenchant_test.lua
local itemLines, options, events = {}, {}, {}
local tips = { tipDisenchant = true, tipDisenchantAH = false }
local L = setmetatable({ CODEX_TIP_DE = "Entzaubern:", CODEX_TIP_DE_MEASURED = "Entzaubern (gemessen, %dx):" },
    { __index = function(_, k) return k end })
local FW = { L = L, Tooltips = {
    Get = function(k) return tips[k] end,
    AddItemLine = function(fn) itemLines[#itemLines + 1] = fn end,
    RegisterOption = function(k, _, def) options[k] = def end,
    Money = function(v) return v .. "c" end } }
function FW:RegisterEvent(ev, fn) events[ev] = fn end
_G.Freewood = FW
_G.GetLocale = function() return "deDE" end
local now = 100
_G.GetTime = function() return now end
-- Items: id -> { q, il, classID, equipLoc, name }
local items = {
    [1] = { 2, 22, 4, "INVTYPE_CHEST", "Grüne Brust" },
    [2] = { 2, 22, 2, "INVTYPE_WEAPON", "Grünes Schwert" },
    [3] = { 2, 22, 4, "INVTYPE_SHIELD", "Grüner Schild" },
    [4] = { 3, 18, 2, "INVTYPE_WEAPON", "Blauer Dolch (Forever aufgewertet)" },
    [5] = { 3, 72, 4, "INVTYPE_HEAD", "Blauer Helm 72" },
    [6] = { 4, 62, 4, "INVTYPE_LEGS", "Epische Beine" },
    [7] = { 1, 30, 4, "INVTYPE_CHEST", "Weiße Brust" },
    [8] = { 2, 30, 4, "INVTYPE_TABARD", "Wappenrock" },
    [9] = { 2, 30, 15, "", "Rezept" },
    [10] = { 2, 12, 4, "INVTYPE_HOLDABLE", "Grüne Kugel" },
}
local function ID(link) return tonumber(tostring(link):match("item:(%d+)")) or tonumber(link) end
_G.C_Item = {
    GetItemInfoInstant = function(link) local x = items[ID(link)] return ID(link), "", "", x[4], 0, x[3] end,
    GetItemInfo = function(link) local x = items[ID(link)] if not x then return nil end return x[5], "item:" .. ID(link), x[1], x[2] end,
    GetItemNameByID = function() return nil end,
    RequestLoadItemDataByID = function() end,
}
local Codex = { db = {} }
local NS = { Codex = Codex }
assert(loadfile("CodexDisenchant.lua"))("Freewood-Codex", NS)
local DE = Codex.Disenchant
assert(DE and #itemLines == 1 and options.tipDisenchant and options.tipDisenchantAH, "geladen, Optionen")

-- Regel
assert(DE.Group(2, 10, false) == 1 and DE.Group(2, 3, false) == 1, "grün sehr niedrig -> 1")
assert(DE.Group(2, 22, false) == 3 and DE.Group(2, 22, true) == 23, "Rüstung/Waffe")
assert(DE.Group(2, 70, false) == 11, "grün über 65 -> 11")
assert(DE.Group(3, 18) == 41 and DE.Group(3, 60) == 48 and DE.Group(3, 72) == 49, "blau")
assert(DE.Group(4, 30) == 61 and DE.Group(4, 58) == 64 and DE.Group(4, 80) == 65, "episch")
assert(DE.Group(1, 30) == nil, "weiß nicht")
-- Chancen je Gruppe ergeben 100 %
for k, g in pairs(DE.GROUPS) do
    local sum = 0
    for _, r in ipairs(g) do sum = sum + r[2] end
    assert(math.abs(sum - 100) < 0.01, "Gruppe " .. k .. " = " .. sum)
end
-- Item-Fakten
local q, il, w = DE.ItemFacts("item:3")
assert(q == 2 and il == 22 and w == true, "Schild zählt als Waffe")
q, il, w = DE.ItemFacts("item:10")
assert(w == true, "In Nebenhand gehalten zählt als Waffe")
assert(DE.ItemFacts("item:7") == nil and DE.ItemFacts("item:8") == nil and DE.ItemFacts("item:9") == nil, "nicht entzauberbar")
assert(DE.Predict("item:4").group == 41, "Forever-Aufwertung: blau Itemlevel 18 -> Splitter")
assert(DE.Predict("item:5").group == 49, "blau 72 korrigiert")

-- Tooltip
local lines = {}
local tt = { AddLine = function(_, t) lines[#lines + 1] = t end,
    AddDoubleLine = function(_, a, b) lines[#lines + 1] = a .. " | " .. b end }
itemLines[1](tt, "item:1")
assert(lines[1] == "Entzaubern:", lines[1])
assert(lines[2] == "  75 %  Seltsamer Staub (4–6)", lines[2])
assert(lines[3] == "  15 %  Geringe Astralessenz (1–2)", lines[3])
assert(lines[4] == "  10 %  Kleiner gleißender Splitter (1)", lines[4])
lines = {}
itemLines[1](tt, "item:5")
assert(lines[3] == "  0,5 %  Nexuskristall (1)", tostring(lines[3]))
lines = {}
itemLines[1](tt, "item:7")
assert(#lines == 0, "weiß: keine Zeilen")
tips.tipDisenchant = false
itemLines[1](tt, "item:1")
assert(#lines == 0, "abgeschaltet")
tips.tipDisenchant = true

-- Auktionswert
local prices = { [10940] = 100, [10998] = 1000, [10978] = 2000 }
Codex.AuctionPrice = function(id) return prices[id] end
Codex.AuctionProvider = function() end
tips.tipDisenchantAH = true
local v, missing = DE.Value(DE.Predict("item:1"))
-- 0.75*5*100 + 0.15*1.5*1000 + 0.10*1*2000 = 375 + 225 + 200 = 800
assert(v == 800 and not missing, "Wert " .. tostring(v))
lines = {}
itemLines[1](tt, "item:1")
assert(lines[1] == "Entzaubern: | ≈ 800c" and lines[2] == "  75 %  Seltsamer Staub (4–6) | 100c", lines[1] .. " / " .. lines[2])
prices[10978] = nil
local _, miss = DE.Value(DE.Predict("item:1"))
assert(miss, "fehlender Preis markiert")

-- Messung: Zauber gesendet, dann Beutefenster
_G.C_Container = {
    GetContainerNumSlots = function(b) return b == 0 and 2 or 0 end,
    GetContainerItemInfo = function(b, s) if b == 0 and s == 2 then return { hyperlink = "item:1", itemName = "Grüne Brust" } end end,
}
local loot = { { "item:10940", 5 }, { "item:10998", 1 } }
_G.GetNumLootItems = function() return #loot end
_G.GetLootSlotLink = function(i) return loot[i] and loot[i][1] end
_G.GetLootSlotInfo = function(i) return "icon", "name", loot[i][2] end
events.UNIT_SPELLCAST_SENT("player", "Grüne Brust", "guid", 13262)
assert(DE.pending and DE.pending.group == 3, "Entzaubern erkannt")
events.LOOT_OPENED()
assert(Codex.db.de[3].n == 1 and Codex.db.de[3].m[10940].q == 5, "gemessen")
-- anderer Zauber: nichts
events.UNIT_SPELLCAST_SENT("player", "Grüne Brust", "guid", 12345)
events.LOOT_OPENED()
assert(Codex.db.de[3].n == 1, "andere Zauber zählen nicht")
-- zu spät: nichts
events.UNIT_SPELLCAST_SENT("player", "Grüne Brust", "guid", 13262)
now = now + 10
events.LOOT_OPENED()
assert(Codex.db.de[3].n == 1, "zu spät")
-- ab 20 Messungen ersetzen eigene Werte die Grundwerte
for i = 2, 20 do
    DE.Record(3, i % 4 == 0 and { [10998] = 2 } or { [10940] = 4 })
end
local pred = DE.Predict("item:1")
assert(pred.measured and pred.n == 20, "gemessen ab 20")
lines = {}
tips.tipDisenchantAH = false
itemLines[1](tt, "item:1")
assert(lines[1] == "Entzaubern (gemessen, 20x):", lines[1])
assert(lines[2]:find("Seltsamer Staub (Ø", 1, true), lines[2])
-- /fwde
local out = {}
_G.print = function(s) out[#out + 1] = s end
_G.SlashCmdList.FREEWOODDE()
assert(#out == 1, "eine Gruppe gemessen")
io.write("disenchant_test: ok\n")
