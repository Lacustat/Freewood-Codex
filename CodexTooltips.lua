-- Freewood-Codex: Beutewert-Zeilen im Gegner-Tooltip (Einstellungen -> Tooltips)
-- Die Zeilen brauchen die Kill-Daten des Codex; die Schalter erscheinen im Core-Reiter "Tooltips", solange der Codex laeuft.
--   tipDropGold, tipDropVendor, tipDropAH (nur mit Auktionsmodul), tipDropHour, tipDropBest (+ tipDropBestN), tipDropKills

local FW = _G.Freewood
local T = FW and FW.Tooltips
if not FW or not T or not T.AddUnitLine or not T.RegisterOption then
    return
end

local Tip = { Money = T.Money }
local function On(key) return T.Get(key) == true end

-- Kampfdauer einer Kreatur in Sekunden: eigene Klasse, sonst Durchschnitt aller Klassen
local function UnitSecs(u)
    local CT = FW.Codex and FW.Codex.Time
    if not (CT and CT.UnitAverage) then return nil end
    local own = CT.UnitAverage(u)
    if own and own > 0 then return own end
    local list = CT.UnitClasses and CT.UnitClasses(u) or {}
    if #list == 0 then return nil end
    local sum = 0
    for _, c in ipairs(list) do sum = sum + c.secs end
    local avg = sum / #list
    return avg > 0 and avg or nil
end

-- Durchschnittliche Beute je Leiche (Gold plus Items nach Drop-Chance), eigene und geteilte Daten.
-- Alle Zeilen einzeln schaltbar: tipDropGold, tipDropVendor, tipDropAH, tipDropHour, tipDropBest (+ tipDropBestN), tipDropKills
local function AddDrops(tt, name, npcID)
    if not npcID or tt.fwDropID == npcID then return end
    local wantG, wantV, wantA = On("tipDropGold"), On("tipDropVendor"), On("tipDropAH")
    local wantH, wantB, wantK = On("tipDropHour"), On("tipDropBest"), On("tipDropKills")
    if not (wantG or wantV or wantA or wantH or wantB or wantK) then return end
    local C = FW.Codex
    if not C or not C.V or not C.KillValue then return end
    local ok, V = pcall(C.V)
    local u = ok and V and V.units and V.units[npcID]
    if not u or (u.k or 0) < 1 then return end
    tt.fwDropID = npcID
    local L = FW.L
    local hasAH = C.AuctionProvider ~= nil
    local vTotal, vCoin, _, vMissing = C.KillValue(u, false)
    local aTotal, _, _, aMissing
    if hasAH and (wantA or wantH) then aTotal, _, _, aMissing = C.KillValue(u, true) end
    local star = function(m) return (m or 0) > 0 and "*" or "" end
    if wantG and vCoin and vCoin > 0 then
        tt:AddLine(string.format(L.CODEX_TIP_DROP_GOLD, Tip.Money(math.floor(vCoin + 0.5))), 1, 0.82, 0)
    end
    if wantV and vTotal and vTotal > 0 then
        tt:AddLine(string.format(L.CODEX_TIP_DROP_VENDOR, Tip.Money(math.floor(vTotal + 0.5)) .. star(vMissing)), 1, 0.82, 0)
    end
    if wantA and hasAH and aTotal and aTotal > 0 then
        tt:AddLine(string.format(L.CODEX_TIP_DROP_AH, Tip.Money(math.floor(aTotal + 0.5)) .. star(aMissing)), 0.6, 0.85, 1)
    end
    if wantH then
        local secs = UnitSecs(u)
        local val = (hasAH and aTotal and aTotal > 0) and aTotal or vTotal
        if secs and secs > 0 and val and val > 0 then
            tt:AddLine(string.format(L.CODEX_TIP_DROP_HOUR, Tip.Money(math.floor(val / secs * 3600 + 0.5)), secs), 0.7, 1, 0.7)
        end
    end
    if wantB then
        local n = tonumber(T.Get("tipDropBestN")) or 3
        local rows, k = {}, u.k
        for id, d in pairs(u.d or {}) do
            if not d.qi then
                local info = FW.Util.GetItem(id)
                if info then
                    local v = info.sellPrice or 0
                    if hasAH then
                        local ah = C.AuctionPrice(id)
                        if ah and ah > v then v = ah end
                    end
                    local chance = (d.q or 0) / k
                    if v > 0 and chance > 0 then
                        rows[#rows + 1] = { name = info.name, quality = info.quality, chance = chance, value = chance * v }
                    end
                end
            end
        end
        table.sort(rows, function(x, y) return x.value > y.value end)
        for i = 1, math.min(n, #rows) do
            local r = rows[i]
            local pct = r.chance * 100
            local ptxt = pct >= 10 and string.format("%.0f%%", pct) or string.format("%.1f%%", pct)
            tt:AddLine(string.format(L.CODEX_TIP_DROP_BEST, r.name or "?", ptxt, Tip.Money(math.floor(r.value + 0.5))), 0.9, 0.9, 0.9)
        end
    end
    if wantK then
        tt:AddLine(string.format(L.CODEX_TIP_DROP_KILLS, u.k), 0.6, 0.6, 0.6)
    end
end


T.AddUnitLine(AddDrops)

T.RegisterOption("tipDropGold", "CODEX_OPT_TIPDROPG", { order = 38, default = false })
T.RegisterOption("tipDropVendor", "CODEX_OPT_TIPDROPV", { order = 40 })
T.RegisterOption("tipDropAH", "CODEX_OPT_TIPDROPA", { order = 50, available = function() return FW.Codex and FW.Codex.AuctionProvider ~= nil end })
T.RegisterOption("tipDropHour", "CODEX_OPT_TIPDROPH", { order = 60, default = false })
T.RegisterOption("tipDropBest", "CODEX_OPT_TIPDROPB", { order = 70, default = false })
T.RegisterOption("tipDropBestN", "CODEX_OPT_TIPDROPBN", { order = 71, default = 3, min = 1, max = 5, step = 1 })
T.RegisterOption("tipDropKills", "CODEX_OPT_TIPDROPK", { order = 80, default = false })
