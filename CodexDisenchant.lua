-- Freewood-Codex: Entzaubern – was herauskommt und mit welcher Chance (seit 0.56.0)
--   Codex.Disenchant.Group(quality, itemLevel, isWeapon)  Gruppennummer wie in CMaNGOS (1-11, 21-31, 41-49, 61-65)
--   Codex.Disenchant.Predict(link)                        { group, rows = { { id, chance, min, max } }, measured, n }
-- Grundwerte: CMaNGOS Classic DB (Patch 1.12, GPL v3), Tabelle disenchant_loot_template. Ausgewertet am 27.11.2026:
--   * Das Ergebnis haengt nur von Qualitaet, Itemlevel (5er-Stufen) und bei Gruen von Ruestung/Waffe ab
--     (Schilde und "In Nebenhand gehalten" zaehlen als Waffe). Deshalb als Regel eingetragen, nicht als Liste je Item:
--     Forever hat bei rund 180 Items das Itemlevel und bei 137 die Qualitaet geaendert, die Regel nimmt die Werte live
--     aus dem Spiel. Chance 0 in CMaNGOS = Rest auf 100 % (z. B. Splitter 5 %).
--   * Korrekturen: Blau ab Itemlevel 71 (CMaNGOS: nur 0,5 % Nexus) wie 66-70; Blau unter 20 (in Forever durch
--     Aufwertung moeglich) wie 20-25; Gruen ueber 65 wie 61-65; Episch unter 40 wie 40-45.
-- Eigene Messung: jede eigene Entzauberung (Zauber 13262) wird je Gruppe gezaehlt (Codex.db.de). Ab MEASURED_MIN
-- Entzauberungen einer Gruppe zeigt der Tooltip die gemessenen Werte statt der Grundwerte.
-- Tooltip-Zeilen: tipDisenchant (Standard an), tipDisenchantAH (Auktionswert, nur mit Auktionsmodul).
-- Im Spiel ungeprueft.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local G = _G
local DE = {}
Codex.Disenchant = DE

DE.SPELL = 13262
DE.MEASURED_MIN = 20
DE.WINDOW = 6          -- Sekunden zwischen Zauber und Beutefenster

-- { Itemlevel von, bis, { Material, Chance %, Menge min, max } ... }
DE.GROUPS = {
    [1] = { lo = 5, hi = 15, { 10940, 80, 1, 2 }, { 10938, 20, 1, 2 } },
    [2] = { lo = 16, hi = 20, { 10940, 75, 2, 3 }, { 10939, 20, 1, 2 }, { 10978, 5, 1, 1 } },
    [3] = { lo = 21, hi = 25, { 10940, 75, 4, 6 }, { 10998, 15, 1, 2 }, { 10978, 10, 1, 1 } },
    [4] = { lo = 26, hi = 30, { 11083, 75, 1, 2 }, { 11082, 20, 1, 2 }, { 11084, 5, 1, 1 } },
    [5] = { lo = 31, hi = 35, { 11083, 75, 2, 5 }, { 11134, 20, 1, 2 }, { 11138, 5, 1, 1 } },
    [6] = { lo = 36, hi = 40, { 11137, 75, 1, 2 }, { 11135, 20, 1, 2 }, { 11139, 5, 1, 1 } },
    [7] = { lo = 41, hi = 45, { 11137, 75, 2, 5 }, { 11174, 20, 1, 2 }, { 11177, 5, 1, 1 } },
    [8] = { lo = 46, hi = 50, { 11176, 75, 1, 2 }, { 11175, 20, 1, 2 }, { 11178, 5, 1, 1 } },
    [9] = { lo = 51, hi = 55, { 11176, 75, 2, 5 }, { 16202, 20, 1, 2 }, { 14343, 5, 1, 1 } },
    [10] = { lo = 56, hi = 60, { 16204, 75, 1, 2 }, { 16203, 20, 1, 2 }, { 14344, 5, 1, 1 } },
    [11] = { lo = 61, hi = 65, { 16204, 75, 2, 5 }, { 16203, 20, 2, 2 }, { 14344, 5, 1, 1 } },
    [21] = { lo = 5, hi = 15, { 10938, 80, 1, 2 }, { 10940, 20, 1, 2 } },
    [22] = { lo = 16, hi = 20, { 10939, 75, 1, 2 }, { 10940, 20, 2, 3 }, { 10978, 5, 1, 1 } },
    [23] = { lo = 21, hi = 25, { 10998, 75, 1, 2 }, { 10940, 15, 4, 6 }, { 10978, 10, 1, 1 } },
    [24] = { lo = 26, hi = 30, { 11082, 75, 1, 2 }, { 11083, 20, 1, 2 }, { 11084, 5, 1, 1 } },
    [25] = { lo = 31, hi = 35, { 11134, 75, 1, 2 }, { 11083, 20, 2, 5 }, { 11138, 5, 1, 1 } },
    [26] = { lo = 36, hi = 40, { 11135, 75, 1, 2 }, { 11137, 20, 1, 2 }, { 11139, 5, 1, 1 } },
    [27] = { lo = 41, hi = 45, { 11174, 75, 1, 2 }, { 11137, 20, 2, 5 }, { 11177, 5, 1, 1 } },
    [28] = { lo = 46, hi = 50, { 11175, 75, 1, 2 }, { 11176, 20, 1, 2 }, { 11178, 5, 1, 1 } },
    [29] = { lo = 51, hi = 55, { 16202, 75, 1, 2 }, { 11176, 22, 2, 5 }, { 14343, 3, 1, 1 } },
    [30] = { lo = 56, hi = 60, { 16203, 75, 1, 2 }, { 16204, 22, 1, 2 }, { 14344, 3, 1, 1 } },
    [31] = { lo = 61, hi = 65, { 16203, 75, 2, 2 }, { 16204, 22, 2, 5 }, { 14344, 3, 1, 1 } },
    [41] = { lo = 1, hi = 25, { 10978, 100, 1, 1 } },
    [42] = { lo = 26, hi = 30, { 11084, 100, 1, 1 } },
    [43] = { lo = 31, hi = 35, { 11138, 100, 1, 1 } },
    [44] = { lo = 36, hi = 40, { 11139, 100, 1, 1 } },
    [45] = { lo = 41, hi = 45, { 11177, 100, 1, 1 } },
    [46] = { lo = 46, hi = 50, { 11178, 100, 1, 1 } },
    [47] = { lo = 51, hi = 55, { 14343, 100, 1, 1 } },
    [48] = { lo = 56, hi = 65, { 14344, 100, 1, 1 } },
    [49] = { lo = 66, hi = 999, { 14344, 99.5, 1, 1 }, { 20725, 0.5, 1, 1 } },
    [61] = { lo = 1, hi = 45, { 11177, 100, 2, 4 } },
    [62] = { lo = 46, hi = 50, { 11178, 100, 2, 4 } },
    [63] = { lo = 51, hi = 55, { 14343, 100, 2, 4 } },
    [64] = { lo = 56, hi = 60, { 20725, 100, 1, 1 } },
    [65] = { lo = 61, hi = 999, { 20725, 100, 1, 2 } },
}

-- Namen, solange das Spiel das Material noch nicht geladen hat
DE.NAMES = {
    deDE = { [10940] = "Seltsamer Staub", [10938] = "Geringe Magieessenz", [10939] = "Große Magieessenz",
        [10998] = "Geringe Astralessenz", [11082] = "Große Astralessenz", [11083] = "Seelenstaub",
        [11134] = "Geringe Mystikeressenz", [11135] = "Große Mystikeressenz", [11137] = "Visionenstaub",
        [11174] = "Geringe Netheressenz", [11175] = "Große Netheressenz", [11176] = "Traumstaub",
        [16202] = "Geringe ewige Essenz", [16203] = "Große ewige Essenz", [16204] = "Illusionsstaub",
        [10978] = "Kleiner gleißender Splitter", [11084] = "Großer gleißender Splitter", [11138] = "Kleiner leuchtender Splitter",
        [11139] = "Großer leuchtender Splitter", [11177] = "Kleiner strahlender Splitter", [11178] = "Großer strahlender Splitter",
        [14343] = "Kleiner glänzender Splitter", [14344] = "Großer glänzender Splitter", [20725] = "Nexuskristall" },
    enUS = { [10940] = "Strange Dust", [10938] = "Lesser Magic Essence", [10939] = "Greater Magic Essence",
        [10998] = "Lesser Astral Essence", [11082] = "Greater Astral Essence", [11083] = "Soul Dust",
        [11134] = "Lesser Mystic Essence", [11135] = "Greater Mystic Essence", [11137] = "Vision Dust",
        [11174] = "Lesser Nether Essence", [11175] = "Greater Nether Essence", [11176] = "Dream Dust",
        [16202] = "Lesser Eternal Essence", [16203] = "Greater Eternal Essence", [16204] = "Illusion Dust",
        [10978] = "Small Glimmering Shard", [11084] = "Large Glimmering Shard", [11138] = "Small Glowing Shard",
        [11139] = "Large Glowing Shard", [11177] = "Small Radiant Shard", [11178] = "Large Radiant Shard",
        [14343] = "Small Brilliant Shard", [14344] = "Large Brilliant Shard", [20725] = "Nexus Crystal" },
}

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d, e, f, g, h, i, j, k, l
end

local function InGroups(from, to, il)
    for n = from, to do
        local g = DE.GROUPS[n]
        if g and il >= g.lo and il <= g.hi then return n end
    end
end

-- Gruppe nach Regel; nil = nicht entzauberbar (Qualitaet)
function DE.Group(q, il, weapon)
    q, il = tonumber(q), tonumber(il)
    if not q or not il then return nil end
    if q == 2 then
        local base = weapon and 20 or 0
        if il < 16 then return base + 1 end
        if il > 65 then return base + 11 end
        return InGroups(base + 1, base + 11, il)
    elseif q == 3 then
        return InGroups(41, 49, math.max(1, il))
    elseif q == 4 then
        return InGroups(61, 65, math.max(1, il))
    end
    return nil
end

-- Kann das Item entzaubert werden? Rueckgabe: Qualitaet, Itemlevel, Waffe (oder nil)
local NO_SLOT = { INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_AMMO = true, [""] = true }
local WEAPON_SLOT = { INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true }
function DE.ItemFacts(link)
    if not link then return nil end
    local CI = G.C_Item
    local instant = (CI and CI.GetItemInfoInstant) or G.GetItemInfoInstant
    local _, _, _, equipLoc, _, classID = Call(instant, link)
    if classID ~= 2 and classID ~= 4 then return nil end
    if NO_SLOT[equipLoc or ""] then return nil end
    local info = (CI and CI.GetItemInfo) or G.GetItemInfo
    local _, _, q, il = Call(info, link)
    if not q and CI and CI.GetItemQualityByID then q = Call(CI.GetItemQualityByID, link) end
    if CI and CI.GetDetailedItemLevelInfo then
        local d = Call(CI.GetDetailedItemLevelInfo, link)
        if type(d) == "number" and d > 0 then il = d end
    end
    if type(q) ~= "number" or type(il) ~= "number" or q < 2 or q > 4 then return nil end
    return q, il, (classID == 2 or WEAPON_SLOT[equipLoc]) and true or false
end

------------------------------------------------------------------------
-- Eigene Messung: Codex.db.de[Gruppe] = { n = Entzauberungen, m = { [Material] = { c = wie oft, q = Menge gesamt } } }
------------------------------------------------------------------------

local function Store()
    Codex.db.de = Codex.db.de or {}
    return Codex.db.de
end

function DE.Record(group, loot)
    if not group or type(loot) ~= "table" then return false end
    local st = Store()
    local g = st[group] or { n = 0, m = {} }
    st[group] = g
    g.n = g.n + 1
    for id, qty in pairs(loot) do
        local m = g.m[id] or { c = 0, q = 0 }
        g.m[id] = m
        m.c = m.c + 1
        m.q = m.q + (qty or 1)
    end
    return true
end

-- gemessene Zeilen einer Gruppe (Chance in %, Menge als Durchschnitt)
function DE.Measured(group)
    local g = Store()[group]
    if not g or (g.n or 0) < DE.MEASURED_MIN then return nil, g and g.n or 0 end
    local rows = {}
    for id, m in pairs(g.m) do
        local avg = m.c > 0 and m.q / m.c or 1
        rows[#rows + 1] = { id, m.c / g.n * 100, avg, avg, avg = true }
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    return rows, g.n
end

function DE.Predict(link)
    local q, il, weapon = DE.ItemFacts(link)
    if not q then return nil end
    local group = DE.Group(q, il, weapon)
    local base = group and DE.GROUPS[group]
    if not base then return nil end
    local measured, n = DE.Measured(group)
    if measured then return { group = group, rows = measured, measured = true, n = n } end
    local rows = {}
    for _, r in ipairs(base) do rows[#rows + 1] = { r[1], r[2], r[3], r[4] } end
    return { group = group, rows = rows, measured = false, n = n or 0 }
end

-- Erwarteter Auktionswert (Kupfer); fehlt ein Preis, zaehlt er als 0 und missing wird gesetzt
function DE.Value(pred)
    if not pred or not Codex.AuctionPrice then return nil end
    local sum, missing = 0, false
    for _, r in ipairs(pred.rows) do
        local p = Codex.AuctionPrice(r[1])
        if p then sum = sum + r[2] / 100 * (r[3] + r[4]) / 2 * p else missing = true end
    end
    return math.floor(sum + 0.5), missing
end

function DE.Name(id)
    local CI = G.C_Item
    local n = CI and CI.GetItemNameByID and Call(CI.GetItemNameByID, id)
    if not n and G.GetItemInfo then n = Call(G.GetItemInfo, id) end
    if type(n) == "string" and n ~= "" then return n end
    if CI and CI.RequestLoadItemDataByID then Call(CI.RequestLoadItemDataByID, id) end
    local loc = G.GetLocale and G.GetLocale() or "enUS"
    return (DE.NAMES[loc] or DE.NAMES.enUS)[id] or ("#" .. id)
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

local T = FW.Tooltips
local function On(key) return T and T.Get and T.Get(key) == true end

local function Pct(v)
    if v >= 10 or v == math.floor(v) then return string.format("%d %%", math.floor(v + 0.5)) end
    return string.format("%.1f %%", v):gsub("%.", ",", 1)
end

local function Qty(r)
    if r.avg then
        local a = math.floor(r[3] * 10 + 0.5) / 10
        return (a == math.floor(a)) and string.format("Ø %d", a) or (string.format("Ø %.1f", a):gsub("%.", ",", 1))
    end
    if r[3] == r[4] then return tostring(r[3]) end
    return r[3] .. "–" .. r[4]
end

function DE.AddTooltipLines(tt, link)
    if not On("tipDisenchant") then return 0 end
    local pred = DE.Predict(link)
    if not pred then return 0 end
    local L = FW.L
    local head = pred.measured and string.format(L.CODEX_TIP_DE_MEASURED, pred.n) or L.CODEX_TIP_DE
    local wantAH = On("tipDisenchantAH") and Codex.AuctionProvider ~= nil
    local money = (T and T.Money) or function(v) return tostring(v) end
    if wantAH then
        local v, missing = DE.Value(pred)
        if v and v > 0 and tt.AddDoubleLine then
            tt:AddDoubleLine(head, "≈ " .. money(v) .. (missing and "*" or ""), 0.6, 0.8, 1, 0.6, 0.85, 1)
        else
            tt:AddLine(head, 0.6, 0.8, 1)
        end
    else
        tt:AddLine(head, 0.6, 0.8, 1)
    end
    for _, r in ipairs(pred.rows) do
        local left = "  " .. Pct(r[2]) .. "  " .. DE.Name(r[1]) .. " (" .. Qty(r) .. ")"
        local p = wantAH and Codex.AuctionPrice(r[1])
        if p and tt.AddDoubleLine then
            tt:AddDoubleLine(left, money(p), 0.9, 0.9, 0.9, 0.8, 0.8, 0.8)
        else
            tt:AddLine(left, 0.9, 0.9, 0.9)
        end
    end
    return #pred.rows
end

if T and T.AddItemLine then T.AddItemLine(function(tt, link) DE.AddTooltipLines(tt, link) end) end
if T and T.RegisterOption then
    T.RegisterOption("tipDisenchant", "CODEX_OPT_TIPDE", { order = 92 })
    T.RegisterOption("tipDisenchantAH", "CODEX_OPT_TIPDEAH", { order = 93,
        available = function() return Codex.AuctionProvider ~= nil end })
end

------------------------------------------------------------------------
-- Messung: Zauber "Entzaubern" -> Beutefenster
------------------------------------------------------------------------

-- Item in den Taschen nach Name finden (beim Wirken liegt es noch dort)
function DE.FindInBags(name)
    local C = G.C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) or type(name) ~= "string" then return nil end
    for bag = 0, 4 do
        for slot = 1, (Call(C.GetContainerNumSlots, bag) or 0) do
            local info = Call(C.GetContainerItemInfo, bag, slot)
            local link = type(info) == "table" and info.hyperlink
            if link then
                local n = info.itemName or Call(G.GetItemInfo, link)
                if n == name then return link end
            end
        end
    end
end

DE.pending = nil

function DE.OnSpellSent(unit, target, _, spellID)
    if unit ~= "player" or spellID ~= DE.SPELL then return end
    local link = DE.FindInBags(target)
    local q, il, weapon = DE.ItemFacts(link)
    local group = q and DE.Group(q, il, weapon)
    if not group then DE.pending = nil return end
    DE.pending = { group = group, t = Call(G.GetTime) or 0, link = link }
end

function DE.OnLootOpened()
    local p = DE.pending
    if not p then return end
    DE.pending = nil
    local now = Call(G.GetTime) or 0
    if now - p.t > DE.WINDOW then return end
    local loot = {}
    local found = false
    for slot = 1, (Call(G.GetNumLootItems) or 0) do
        local link = Call(G.GetLootSlotLink, slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local _, _, qty = Call(G.GetLootSlotInfo, slot)
            loot[id] = (loot[id] or 0) + (tonumber(qty) or 1)
            found = true
        end
    end
    if found then DE.Record(p.group, loot) end
end

FW:RegisterEvent("UNIT_SPELLCAST_SENT", function(...) pcall(DE.OnSpellSent, ...) end)
FW:RegisterEvent("LOOT_OPENED", function() pcall(DE.OnLootOpened) end)

-- /fwde: gemessene Gruppen kurz im Chat
G.SLASH_FREEWOODDE1 = "/fwde"
G.SlashCmdList = G.SlashCmdList or {}
G.SlashCmdList.FREEWOODDE = function()
    local L = FW.L
    local st = Store()
    local keys = {}
    for k in pairs(st) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then print(L.CODEX_DE_NONE) return end
    for _, k in ipairs(keys) do
        local g = DE.GROUPS[k]
        print(string.format(L.CODEX_DE_LINE, k, g and g.lo or 0, g and math.min(g.hi, 99) or 0, st[k].n or 0))
    end
end
