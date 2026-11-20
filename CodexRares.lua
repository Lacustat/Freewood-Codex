-- Freewood-Codex: Rare-Mob-Tracker (seit 0.51.0)
--
-- Inhalt
--   1. Daten: bekannte Rares (Startdaten-Rolle "rares" + eigene Daten), Beute (nur gruen, blau, lila)
--   2. Erkennen: Namensplaketten, Ziel, Mouseover, Minikarten-Markierungen (Vignetten); schwaecher: bekannter Fundort
--      in der Naehe. Derselbe Rare wird 10 Minuten nicht erneut gemeldet.
--   3. Fenster: "Rare: Name (Stufe)", Koordinaten, 3D-Modell, Beute; verschiebbar (Kopfzeile), Linksklick auf Modell
--      und Text = als Ziel (sicherer Knopf mit /targetexact, nur ausserhalb des Kampfes moeglich), Rechtsklick = zu.
--      Ton wie beim Postfach (Wecker, Ton-Einstellung der Animationen).
--   4. Karte: alle bekannten Rare-Fundorte als Totenkopf; Mouseover zeigt Name, Stufe und Beute.
--   5. Einstellungen ("Quest & Hinweise"): Tracker an/aus, Karte an/aus (beides Standard aus), Test
--   6. /fwrare (Test), /fwrare probe
--
-- Ungeprueft im Spiel: Vignetten fuer die alten Rares, PlayerModel:SetUnit/SetCreature, C_Map.GetMapWorldSize.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local G = _G
local R = {}
Codex.Rares = R

R.QUIET_SECS = 600        -- derselbe Rare 10 Minuten nicht erneut melden
R.SPAWN_YARDS = 120       -- schwacher Hinweis: so nah an einem bekannten Fundort
R.SPAWN_FRAC = 0.04       -- Ersatz ohne Kartengroesse: Anteil der Kartenbreite
R.SPAWN_TICK = 5
R.MAX_LOOT = 8
R.MIN_QUALITY = 2         -- gruen und besser
R.MAX_PINS_PER_RARE = 6

local function Now() return (G.GetTime and G.GetTime()) or 0 end
local function Secret(v) return FW.Util and FW.Util.IsSecret and FW.Util.IsSecret(v) or false end
local function InCombat() return G.InCombatLockdown and G.InCombatLockdown() and true or false end
local function L() return FW.L or {} end
local function Set() return Codex.db and Codex.db.settings or {} end

function R.TrackOn() return Set().rareTrack == true end
function R.MapOn() return Set().rareMap == true end

------------------------------------------------------------------------
-- 1. Daten
------------------------------------------------------------------------

local rareSet
-- Menge der bekannten Rare-IDs (Startdaten-Rolle "rares" + von Hand als rare markierte)
function R.KnownSet()
    if rareSet then return rareSet end
    rareSet = {}
    local S = Codex.Seed
    if S and S.Load and S.Load() and S.RoleIDs then
        for _, ref in ipairs(S.RoleIDs("rares")) do
            if ref.kind == "units" then rareSet[ref.id] = true end
        end
    end
    local V = Codex.V and Codex.V() or Codex.db
    for id, u in pairs(V and V.units or {}) do
        local cl = type(u.ed) == "table" and u.ed.cl
        if cl == "rare" or cl == "rareelite" then rareSet[id] = true end
    end
    return rareSet
end
function R.ResetCache() rareSet = nil end

function R.IsRareID(id) return id and R.KnownSet()[id] == true end

-- Name und Stufe aus Live-Daten oder Startdaten
function R.Info(id)
    local V = Codex.V and Codex.V() or Codex.db
    local ent = V and V.units and V.units[id]
    local name = ent and Codex.NameOf and Codex.NameOf(ent)
    local S = Codex.Seed
    local e = S and S.Entity and S.Entity("units", id)
    name = name or (S and S.Name and S.Name("units", id)) or ("#" .. tostring(id))
    local l1, l2 = e and e.l1, e and e.l2
    if ent and ent.lvl then l1, l2 = ent.lvl, ent.lvl end
    return name, l1, l2
end

local function Quality(id)
    local q = Codex.QualityOf and Codex.QualityOf(id)
    if q == nil and G.C_Item and G.C_Item.GetItemQualityByID then
        local ok, v = pcall(G.C_Item.GetItemQualityByID, id)
        if ok then q = v end
    end
    if q == nil and G.C_Item and G.C_Item.RequestLoadItemDataByID then pcall(G.C_Item.RequestLoadItemDataByID, id) end
    return q
end
local function Icon(id)
    local ic = Codex.db and Codex.db.iicon and Codex.db.iicon[id]
    if ic then return ic end
    if G.C_Item and G.C_Item.GetItemIconByID then
        local ok, v = pcall(G.C_Item.GetItemIconByID, id)
        if ok and v then return v end
    end
    if G.GetItemIcon then
        local ok, v = pcall(G.GetItemIcon, id)
        if ok and v then return v end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end
R.Quality, R.Icon = Quality, Icon

-- Beute: { { id, chance (0..1), q, name, icon } }, nur gruen und besser, hoechstens MAX_LOOT, nach Chance.
-- Eigene Kills gehen vor (ab 5 Kills), sonst die Vorlage (Prozent).
function R.Loot(id)
    local map = {}
    local S = Codex.Seed
    if S and S.Drops then
        for _, d in ipairs(S.Drops("units", id) or {}) do map[d.item] = (d.chance or 0) / 100 end
    end
    local V = Codex.V and Codex.V() or Codex.db
    local ent = V and V.units and V.units[id]
    if ent and Codex.DropList and (ent.k or 0) >= 5 then
        for _, d in ipairs(Codex.DropList(ent)) do map[d.id] = d.chance end
    end
    local out = {}
    for item, ch in pairs(map) do
        local q = Quality(item)
        if q and q >= R.MIN_QUALITY then
            out[#out + 1] = { id = item, chance = ch, q = q }
        end
    end
    table.sort(out, function(a, b)
        if a.chance ~= b.chance then return a.chance > b.chance end
        return a.id < b.id
    end)
    for i = #out, R.MAX_LOOT + 1, -1 do out[i] = nil end
    for _, e in ipairs(out) do
        e.name = (Codex.ItemName and Codex:ItemName(e.id)) or ("#" .. e.id)
        e.icon = Icon(e.id)
    end
    return out
end

-- Fundorte eines Rares auf einer Karte: { { x, y } } (gebuendelt, hoechstens MAX_PINS_PER_RARE)
function R.Spots(id, mapID)
    local GRID = Codex.GRID or 200
    local g2 = GRID * GRID
    local cells = {}
    local S = Codex.Seed
    if S and S.Cells then for k in pairs(S.Cells("units", id) or {}) do cells[k] = true end end
    local V = Codex.V and Codex.V() or Codex.db
    local ent = V and V.units and V.units[id]
    for k in pairs(ent and ent.cells or {}) do cells[k] = true end
    local bins, order = {}, {}
    local BIN = 6
    for key in pairs(cells) do
        if math.floor(key / g2) == mapID then
            local idx = key % g2
            local cx, cy = idx % GRID, math.floor(idx / GRID)
            local bk = math.floor(cx / BIN) * 1000 + math.floor(cy / BIN)
            local b = bins[bk]
            if not b then b = { sx = 0, sy = 0, n = 0 } bins[bk] = b order[#order + 1] = bk end
            b.sx, b.sy, b.n = b.sx + (cx + 0.5) / GRID, b.sy + (cy + 0.5) / GRID, b.n + 1
        end
    end
    table.sort(order)
    local out = {}
    for _, bk in ipairs(order) do
        local b = bins[bk]
        out[#out + 1] = { x = b.sx / b.n, y = b.sy / b.n, n = b.n }
        if #out >= R.MAX_PINS_PER_RARE then break end
    end
    return out
end

------------------------------------------------------------------------
-- 2. Erkennen
------------------------------------------------------------------------

R.last = {}   -- [npcID] = Zeit der letzten Meldung

-- Kreatur-ID aus der GUID ("Creature-0-...-<npcID>-<spawn>")
function R.NpcFromGUID(guid)
    if type(guid) ~= "string" or Secret(guid) then return nil end
    local parts = {}
    for p in string.gmatch(guid, "[^%-]+") do parts[#parts + 1] = p end
    local kind, id = parts[1], parts[6]
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end

local function UnitIsRare(unit)
    if not (G.UnitExists and G.UnitExists(unit)) then return nil end
    if G.UnitIsDead and G.UnitIsDead(unit) then return nil end
    if G.UnitIsPlayer and G.UnitIsPlayer(unit) then return nil end
    local id = R.NpcFromGUID(G.UnitGUID and G.UnitGUID(unit))
    if not id then return nil end
    local cls = G.UnitClassification and G.UnitClassification(unit)
    if Secret(cls) then cls = nil end
    if cls == "rare" or cls == "rareelite" or R.IsRareID(id) then return id end
    return nil
end
R.UnitIsRare = UnitIsRare

-- Eine Meldung: kind "seen" (gesehen) oder "spawn" (moeglicher Fundort). Rueckgabe true, wenn gemeldet
function R.Report(id, kind, unit, pos)
    if not id then return false end
    local t = Now()
    if R.last[id] and t - R.last[id] < R.QUIET_SECS then
        -- schon gemeldet: aus einem Fundort-Hinweis darf noch eine echte Sichtung werden
        if not (kind == "seen" and R.lastKind and R.lastKind[id] == "spawn") then return false end
    end
    R.last[id] = t
    R.lastKind = R.lastKind or {}
    R.lastKind[id] = kind
    R.Show(id, kind, unit, pos)
    return true
end

function R.CheckUnit(unit)
    if not R.TrackOn() then return false end
    local id = UnitIsRare(unit)
    if not id then return false end
    return R.Report(id, "seen", unit)
end

-- Vignetten (Rare-Markierungen auf der Minikarte), wenn Forever sie fuer die alten Rares liefert
function R.CheckVignette(guid)
    if not R.TrackOn() then return false end
    local V = G.C_VignetteInfo
    if not (V and V.GetVignetteInfo) then return false end
    local ok, info = pcall(V.GetVignetteInfo, guid)
    if not ok or type(info) ~= "table" then return false end
    local id = R.NpcFromGUID(info.objectGUID)
    local atlas = type(info.atlasName) == "string" and info.atlasName or ""
    local isKill = atlas:find("Kill") ~= nil or (id and R.IsRareID(id))
    if not (id and isKill) then return false end
    local pos
    local mapID = G.C_Map and G.C_Map.GetBestMapForUnit and G.C_Map.GetBestMapForUnit("player")
    if mapID and V.GetVignettePosition then
        local ok2, p = pcall(V.GetVignettePosition, guid, mapID)
        if ok2 and p and p.GetXY then pos = { m = mapID, x = select(1, p:GetXY()), y = select(2, p:GetXY()) } end
    end
    return R.Report(id, "seen", nil, pos)
end

-- Bekannter Fundort in der Naehe (ohne Sichtung): schwacher Hinweis
function R.WorldYards(mapID)
    local M = G.C_Map
    if M and M.GetMapWorldSize then
        local ok, w = pcall(M.GetMapWorldSize, mapID)
        if ok and type(w) == "number" and w > 0 then return w end
    end
    return nil
end
function R.CheckSpawns()
    if not R.TrackOn() or InCombat() then return false end
    local S = Codex.Seed
    if not (S and S.Nearest and S.Load and S.Load()) then return false end
    local list = S.Nearest("rares", 3)
    local e = list and list[1]
    if not e or not e.dist then return false end
    local w = e.m and R.WorldYards(e.m)
    local near = w and (e.dist * w <= R.SPAWN_YARDS) or (not w and e.dist <= R.SPAWN_FRAC)
    if not near then return false end
    return R.Report(e.id, "spawn", nil, { m = e.m, x = e.x, y = e.y })
end

------------------------------------------------------------------------
-- 3. Fenster
------------------------------------------------------------------------

local UI = FW.UI
local win, secure
local WIN_W, WIN_H, HEAD_H, BODY_H = 300, 0, 26, 92

local function DB()
    local db = Codex.db
    db.rarePos = db.rarePos or {}
    return db.rarePos
end

local function SavePos()
    if not win then return end
    local p, _, rp, x, y = win:GetPoint(1)
    if p then DB().p, DB().rp, DB().x, DB().y = p, rp, x, y end
end

-- Sicherer Knopf ueber Modell und Text: Linksklick = /targetexact Name. Er haengt NICHT am Fenster (sonst waere
-- das Fenster selbst geschuetzt und liesse sich im Kampf nicht zeigen/verbergen), sondern an UIParent und wird
-- ausserhalb des Kampfes deckungsgleich ueber den Kopf/Inhalt-Bereich gelegt.
local function PlaceSecure()
    if not (secure and win) or InCombat() then return end
    if not win:IsShown() or not R.current then secure:Hide() return end
    local l, b, w = win:GetLeft(), win:GetBottom(), win:GetWidth()
    if not (l and b) then secure:Hide() return end
    local s = (win:GetEffectiveScale() or 1) / ((G.UIParent and G.UIParent:GetEffectiveScale()) or 1)
    secure:ClearAllPoints()
    secure:SetPoint("TOPLEFT", G.UIParent, "BOTTOMLEFT", l * s, (b + win:GetHeight() - HEAD_H) * s)
    secure:SetSize(w * s, BODY_H * s)
    secure:SetAttribute("type1", "macro")
    secure:SetAttribute("macrotext1", "/targetexact " .. (R.current.name or ""))
    secure:Show()
end
R.PlaceSecure = PlaceSecure

local function Close()
    if win then win:Hide() end
    R.current = nil
    if secure then
        if InCombat() then secure:SetAlpha(0) R.secureHideLater = true else secure:Hide() end
    end
end
R.Close = Close

local function Build()
    if win then return win end
    local Lx = L()
    win = UI.CreatePanel(G.UIParent, "bgDeep", "gold")
    win:SetSize(WIN_W, 200)
    win:SetFrameStrata("HIGH")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:Hide()
    local d = DB()
    if d.p then win:SetPoint(d.p, G.UIParent, d.rp or d.p, d.x or 0, d.y or 0) else win:SetPoint("TOP", G.UIParent, "TOP", 0, -140) end
    -- Kopfzeile: ziehen
    local head = G.CreateFrame("Frame", nil, win)
    head:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    head:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    head:SetHeight(HEAD_H)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() if not InCombat() then win:StartMoving() if secure then secure:Hide() end end end)
    head:SetScript("OnDragStop", function() win:StopMovingOrSizing() SavePos() PlaceSecure() end)
    head:SetScript("OnMouseUp", function(_, btn) if btn == "RightButton" then Close() end end)
    win.title = UI.CreateLabel(head, "", { font = "heading", size = 13, color = "goldLight" })
    win.title:SetPoint("LEFT", head, "LEFT", 10, 0)
    win.title:SetPoint("RIGHT", head, "RIGHT", -10, 0)
    -- Modell links
    local model
    local ok, m = pcall(G.CreateFrame, "PlayerModel", nil, win)
    if ok and m then model = m end
    win.modelBg = win:CreateTexture(nil, "BACKGROUND", nil, 1)
    win.modelBg:SetColorTexture(0, 0, 0, 0.35)
    win.modelBg:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -HEAD_H)
    win.modelBg:SetSize(84, BODY_H - 6)
    if model then
        model:SetAllPoints(win.modelBg)
        win.model = model
    end
    win.skull = win:CreateTexture(nil, "ARTWORK")
    win.skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    win.skull:SetSize(40, 40)
    win.skull:SetPoint("CENTER", win.modelBg, "CENTER", 0, 0)
    -- Text rechts
    win.sub = UI.CreateLabel(win, "", { size = 12, color = "text", justifyV = "TOP" })
    win.sub:SetPoint("TOPLEFT", win.modelBg, "TOPRIGHT", 10, -2)
    win.sub:SetPoint("RIGHT", win, "RIGHT", -10, 0)
    win.sub:SetHeight(BODY_H - 30)
    win.sub:SetWordWrap(true)
    win.hint = UI.CreateLabel(win, "", { size = 10, color = "textDim", justifyV = "TOP" })
    win.hint:SetPoint("BOTTOMLEFT", win.modelBg, "BOTTOMRIGHT", 10, 2)
    win.hint:SetPoint("RIGHT", win, "RIGHT", -10, 0)
    win.hint:SetWordWrap(true)
    -- Beute
    win.lootHead = UI.CreateLabel(win, Lx.CODEX_RARE_LOOT or "Possible loot", { size = 11, color = "gold" })
    win.lootHead:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -(HEAD_H + BODY_H + 2))
    win.rows = {}
    win:SetScript("OnMouseUp", function(_, btn) if btn == "RightButton" then Close() end end)
    win:SetScript("OnHide", function() if secure and not InCombat() then secure:Hide() end end)
    -- sicherer Knopf
    local okS, s = pcall(G.CreateFrame, "Button", "FreewoodRareTarget", G.UIParent, "SecureActionButtonTemplate")
    if okS and s then
        secure = s
        secure:SetFrameStrata("HIGH")
        secure:SetFrameLevel(win:GetFrameLevel() + 20)
        secure:RegisterForClicks("AnyUp", "AnyDown")
        secure:SetAttribute("type2", nil)
        secure:SetScript("PostClick", function(_, btn) if btn == "RightButton" then Close() end end)
        secure:Hide()
    end
    G.FreewoodRareFrame = win
    return win
end

local function LootRow(i)
    local r = win.rows[i]
    if r then return r end
    r = G.CreateFrame("Frame", nil, win)
    r:SetSize(WIN_W - 20, 18)
    r:SetPoint("TOPLEFT", win.lootHead, "BOTTOMLEFT", 0, -2 - (i - 1) * 18)
    r:EnableMouse(true)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.name = UI.CreateLabel(r, "", { size = 12 })
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", -46, 0)
    r.name:SetWordWrap(false)
    r.pct = UI.CreateLabel(r, "", { size = 11, color = "textDim", justify = "RIGHT" })
    r.pct:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r:SetScript("OnEnter", function(self)
        if self.item and G.GameTooltip then
            G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            pcall(G.GameTooltip.SetItemByID, G.GameTooltip, self.item)
            G.GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function() if G.GameTooltip then G.GameTooltip:Hide() end end)
    r:SetScript("OnMouseUp", function(_, btn) if btn == "RightButton" then Close() end end)
    win.rows[i] = r
    return r
end

local function QColor(q)
    local c = G.ITEM_QUALITY_COLORS and G.ITEM_QUALITY_COLORS[q]
    if c and c.r then return c.r, c.g, c.b end
    if q == 2 then return 0.12, 1, 0 elseif q == 3 then return 0, 0.44, 0.87 elseif q == 4 then return 0.64, 0.21, 0.93 end
    return 1, 0.5, 0
end

-- Fenster fuellen und zeigen
function R.Show(id, kind, unit, pos)
    Build()
    local Lx = L()
    local name, l1, l2 = R.Info(id)
    R.current = { id = id, name = name, kind = kind }
    local lv = l1 and ((l2 and l2 ~= l1) and (l1 .. "-" .. l2) or tostring(l1)) or "?"
    if unit and G.UnitLevel then
        local ok, v = pcall(G.UnitLevel, unit)
        if ok and type(v) == "number" and not Secret(v) then lv = v > 0 and tostring(v) or "??" end
    end
    local head = kind == "spawn" and (Lx.CODEX_RARE_SPAWN or "Possible spawn") or (Lx.CODEX_RARE_SEEN or "Rare nearby")
    win.title:SetText(string.format("%s: %s (%s)", head, name, lv))
    -- Koordinaten: Vignette/Fundort, sonst eigene Position (der Mob ist ja in Sichtweite)
    if not pos and G.C_Map and FW.Util and FW.Util.GetPlayerLocation then pos = FW.Util.GetPlayerLocation() end
    local where = ""
    if pos and pos.x and pos.y then
        local zone = pos.m and Codex.MapName and Codex.MapName(pos.m) or (pos.mapID and Codex.MapName and Codex.MapName(pos.mapID)) or ""
        where = string.format("%s  %.1f, %.1f", zone or "", pos.x * 100, pos.y * 100)
    end
    win.sub:SetText(where)
    win.hint:SetText(InCombat() and (Lx.CODEX_RARE_HINT_COMBAT or "Target after combat. Right-click closes.")
        or (Lx.CODEX_RARE_HINT or "Left-click: target. Right-click: close."))
    -- Modell
    local shown = false
    if win.model then
        pcall(win.model.ClearModel, win.model)
        if unit and win.model.SetUnit then shown = pcall(win.model.SetUnit, win.model, unit) end
        if not shown and win.model.SetCreature then shown = pcall(win.model.SetCreature, win.model, id) end
        if shown and win.model.GetModelFileID then
            local ok, f = pcall(win.model.GetModelFileID, win.model)
            if ok and (f == nil or f == 0) then shown = false end
        end
        if shown then win.model:Show() else win.model:Hide() end
    end
    if shown then win.skull:Hide() else win.skull:Show() end
    -- Beute
    local loot = R.Loot(id)
    for i = 1, math.max(#loot, #win.rows) do
        local r = LootRow(i)
        local e = loot[i]
        r.item = e and e.id
        if e then
            r.icon:SetTexture(e.icon)
            r.name:SetText(e.name)
            r.name:SetTextColor(QColor(e.q))
            r.pct:SetText(e.chance >= 0.01 and string.format("%d %%", math.floor(e.chance * 100 + 0.5)) or "<1 %")
            r:Show()
        else
            r:Hide()
        end
    end
    if #loot == 0 then win.lootHead:SetText(Lx.CODEX_RARE_NOLOOT or "No known loot (green or better)")
    else win.lootHead:SetText(Lx.CODEX_RARE_LOOT or "Possible loot") end
    win:SetHeight(HEAD_H + BODY_H + 22 + #loot * 18 + 8)
    win:Show()
    PlaceSecure()
    if kind == "seen" and FW.Anim and FW.Anim.PlaySound then pcall(FW.Anim.PlaySound) end
    FW:Fire("CODEX_RARE", id, kind)
end

------------------------------------------------------------------------
-- 4. Karte
------------------------------------------------------------------------

local pinLayer, pins = nil, {}
local function Canvas()
    local wm = G.WorldMapFrame
    if not wm then return nil end
    if wm.GetCanvas then
        local ok, c = pcall(wm.GetCanvas, wm)
        if ok and c then return c end
    end
    return wm.ScrollContainer and wm.ScrollContainer.Child or nil
end
local function MapID()
    local wm = G.WorldMapFrame
    if wm and wm.GetMapID then
        local ok, id = pcall(wm.GetMapID, wm)
        if ok then return id end
    end
    return nil
end

-- Tooltip fuer einen Rare (Karte)
function R.FillTooltip(tt, id)
    local name, l1, l2 = R.Info(id)
    local lv = l1 and ((l2 and l2 ~= l1) and (l1 .. "-" .. l2) or tostring(l1)) or "?"
    tt:SetText(name, 1, 0.82, 0)
    tt:AddLine(string.format("%s %s  %s", (L().CODEX_RARE_LEVEL or "Level"), lv, "Rare"), 0.8, 0.8, 0.8)
    local loot = R.Loot(id)
    if #loot == 0 then
        tt:AddLine(L().CODEX_RARE_NOLOOT or "No known loot (green or better)", 0.6, 0.6, 0.6)
    else
        tt:AddLine(L().CODEX_RARE_LOOT or "Possible loot", 1, 0.82, 0)
        for _, e in ipairs(loot) do
            local r, g, b = QColor(e.q)
            tt:AddDoubleLine("|T" .. tostring(e.icon) .. ":14|t " .. e.name, string.format("%d %%", math.floor(e.chance * 100 + 0.5)), r, g, b, 0.8, 0.8, 0.8)
        end
    end
    tt:Show()
end

function R.RefreshMap()
    for _, p in ipairs(pins) do p:Hide() end
    if not R.MapOn() then return 0 end
    local canvas = Canvas()
    local mapID = MapID()
    if not (canvas and mapID) then return 0 end
    if not pinLayer then
        local wm = G.WorldMapFrame
        pinLayer = G.CreateFrame("Frame", nil, wm)
        pinLayer:SetAllPoints(wm.ScrollContainer or wm)
        pinLayer:SetFrameLevel((wm:GetFrameLevel() or 1) + 1400)
        if pinLayer.SetClipsChildren then pinLayer:SetClipsChildren(true) end
    end
    local w, h = canvas:GetWidth() or 1, canvas:GetHeight() or 1
    if w < 2 or h < 2 then return 0 end
    local cs, ls = 1, 1
    if canvas.GetEffectiveScale and pinLayer.GetEffectiveScale then
        local a, b = canvas:GetEffectiveScale(), pinLayer:GetEffectiveScale()
        if a and b and b > 0 then cs = a / b end
    end
    local n = 0
    for id in pairs(R.KnownSet()) do
        for _, s in ipairs(R.Spots(id, mapID)) do
            n = n + 1
            local p = pins[n]
            if not p then
                p = G.CreateFrame("Button", nil, pinLayer)
                p:SetSize(16, 16)
                p.t = p:CreateTexture(nil, "OVERLAY")
                p.t:SetAllPoints(p)
                p.t:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
                p:SetScript("OnEnter", function(self)
                    if G.GameTooltip then G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT") R.FillTooltip(G.GameTooltip, self.rare) end
                end)
                p:SetScript("OnLeave", function() if G.GameTooltip then G.GameTooltip:Hide() end end)
                pins[n] = p
            end
            p.rare = id
            p:ClearAllPoints()
            p:SetPoint("CENTER", canvas, "TOPLEFT", s.x * w * cs, -s.y * h * cs)
            p:Show()
        end
    end
    return n
end

local mapHooked = false
function R.HookMap()
    if mapHooked then return true end
    local wm = G.WorldMapFrame
    if not wm or not Canvas() then return false end
    mapHooked = true
    if wm.OnMapChanged and G.hooksecurefunc then pcall(G.hooksecurefunc, wm, "OnMapChanged", function() pcall(R.RefreshMap) end) end
    if wm.HookScript then wm:HookScript("OnShow", function() pcall(R.RefreshMap) end) end
    local canvas = Canvas()
    if canvas and canvas.HookScript then canvas:HookScript("OnSizeChanged", function() pcall(R.RefreshMap) end) end
    return true
end

------------------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------------------

FW:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit) pcall(R.CheckUnit, unit) end)
FW:RegisterEvent("PLAYER_TARGET_CHANGED", function() pcall(R.CheckUnit, "target") end)
FW:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() pcall(R.CheckUnit, "mouseover") end)
FW:RegisterEvent("VIGNETTE_MINIMAP_UPDATED", function(guid, onMinimap) if onMinimap ~= false then pcall(R.CheckVignette, guid) end end)
FW:RegisterEvent("VIGNETTES_UPDATED", function()
    local V = G.C_VignetteInfo
    if not (R.TrackOn() and V and V.GetVignettes) then return end
    local ok, list = pcall(V.GetVignettes)
    if ok and type(list) == "table" then for _, g in ipairs(list) do pcall(R.CheckVignette, g) end end
end)
FW:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if R.secureHideLater and secure then R.secureHideLater = false secure:SetAlpha(1) secure:Hide() end
    if win and win:IsShown() and R.current then
        win.hint:SetText(L().CODEX_RARE_HINT or "Left-click: target. Right-click: close.")
        PlaceSecure()
    end
end)
FW:RegisterEvent("PLAYER_LOGIN", function()
    R.ResetCache()
    if G.C_Timer and G.C_Timer.NewTicker then G.C_Timer.NewTicker(R.SPAWN_TICK, function() pcall(R.CheckSpawns) end) end
    if G.C_Timer then G.C_Timer.After(3, function() pcall(R.HookMap) end) end
end)
FW:RegisterEvent("ADDON_LOADED", function(name) if name == "Blizzard_WorldMap" then pcall(R.HookMap) end end)

------------------------------------------------------------------------
-- 5. Einstellungen ("Quest & Hinweise")
------------------------------------------------------------------------

if UI and UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-rares", {
        category = "quest",
        order = 108,
        height = 190,
        build = function(parent)
            local Lx = L()
            local f, stack = UI.CreateSection(parent, Lx.CODEX_RARE_HEADER)
            stack:Add(UI.CreateLabel(f, Lx.CODEX_RARE_NOTE, { size = 11, color = "textDim", justifyV = "TOP" }), { fit = true, gap = 8 })
            local track = UI.CreateCheckbox(f, Lx.CODEX_RARE_TRACK, function() return R.TrackOn() end,
                function(on) Set().rareTrack = on and true or false end)
            stack:Add(track, { fit = true, gap = 8 })
            local map = UI.CreateCheckbox(f, Lx.CODEX_RARE_MAP, function() return R.MapOn() end,
                function(on) Set().rareMap = on and true or false; R.HookMap(); pcall(R.RefreshMap) end)
            stack:Add(map, { fit = true, gap = 4 })
            stack:Add(UI.CreateButton(f, Lx.CODEX_RARE_TEST, 200, 26, function() R.Test() end, "default"), { height = 26, gap = 10 })
            stack:Layout()
            f.track, f.map = track, map
            return f
        end,
        refresh = function(frame) frame.track:Refresh() frame.map:Refresh() end,
    })
end

------------------------------------------------------------------------
-- 6. Befehle
------------------------------------------------------------------------

-- Test: der naechste bekannte Rare (oder irgendeiner) als Sichtung
function R.Test()
    local S = Codex.Seed
    local id
    local list = S and S.Nearest and S.Load and S.Load() and S.Nearest("rares", 1)
    if list and list[1] then id = list[1].id end
    if not id then for k in pairs(R.KnownSet()) do id = k break end end
    if not id then FW:Print(L().CODEX_RARE_NONE or "No rare known.") return end
    R.last[id] = nil
    R.Show(id, "seen", nil, list and list[1] and { m = list[1].m, x = list[1].x, y = list[1].y } or nil)
end

function R.Probe()
    local function Has(v) return v and "ja" or "nein" end
    local V, M = G.C_VignetteInfo, G.C_Map
    local n = 0
    for _ in pairs(R.KnownSet()) do n = n + 1 end
    local m = G.CreateFrame and select(2, pcall(G.CreateFrame, "PlayerModel"))
    FW:Print(string.format("Rares bekannt: %d, C_VignetteInfo: %s, GetMapWorldSize: %s, PlayerModel: %s (SetUnit %s, SetCreature %s), Tracker: %s, Karte: %s",
        n, Has(V and V.GetVignetteInfo), Has(M and M.GetMapWorldSize), Has(type(m) == "table"),
        Has(type(m) == "table" and m.SetUnit), Has(type(m) == "table" and m.SetCreature), tostring(R.TrackOn()), tostring(R.MapOn())))
end

G.SLASH_FWRARE1 = "/fwrare"
G.SlashCmdList = G.SlashCmdList or {}
G.SlashCmdList.FWRARE = function(msg)
    msg = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "probe" then R.Probe() else R.Test() end
end
