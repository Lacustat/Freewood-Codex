-- Freewood-Codex: Fluege (Flugmeister)
--
-- Liest die Flugkarte, merkt sich, welche Flugpunkte der Charakter kennt, misst jeden Flug (Dauer, Preis) und teilt die
-- Strecken als Datensatz "f<ID>" ueber das normale Teilen. Keine mitgelieferten Daten: alles kommt aus dem eigenen Flug
-- oder von anderen Spielern.
--
--   db.flight.routes[id] = { a = Flugpunkt, b = Flugpunkt, t = Sekunden, c = Preis in Kupfer, n = Anzahl Fluege, f = "A" | "H" | nil, upd }
--   Flugpunkt = { n = Name, c = Kontinentkarte, tx, ty = Lage auf der Flugkarte (0..1000), m, x, y = Kartenort (UiMap), nur wenn bekannt }
--   db.flight.known[Charakter][punktID] = Flugpunkt   (nur lokal: welche Punkte dieser Charakter kennt)
--
-- Die Punkt-ID ist "Kontinentkarte:tx:ty", die Strecken-ID ein Pruefwert (1..99999988) aus beiden Punkt-IDs. Ungeprueft im Spiel:
-- TaxiNodePosition, TaxiNodeCost, TaxiNodeGetType, UnitOnTaxi.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Flight = { state = {}, rev = 0 }
Codex.Flight = Flight
NS.Flight = Flight

local MAX_ROUTES = 600
local MIN_SECS = 5
local PRICE_WINDOW = 10      -- Sekunden nach dem Start, in denen der Preis abgebucht wird
local state = Flight.state   -- slot = { [i] = { id, cost, kind } }, cur = Punkt-ID, pending

local function Now() return _G.time and _G.time() or 0 end
local function Clock() return _G.GetTime and _G.GetTime() or 0 end
local function Round(v) return math.floor((v or 0) + 0.5) end

local function DB()
    local db = Codex.db
    if not db then return nil end
    db.flight = db.flight or {}
    db.flight.routes = db.flight.routes or {}
    db.flight.known = db.flight.known or {}
    return db.flight
end

local function SelfKey()
    return Codex.Trust and Codex.Trust.SelfKey and Codex.Trust.SelfKey() or "?"
end

local function Known(create)
    local f = DB()
    if not f then return nil end
    local k = SelfKey()
    if create and not f.known[k] then f.known[k] = {} end
    return f.known[k]
end

local function Faction()
    local fac = _G.UnitFactionGroup and _G.UnitFactionGroup("player")
    return fac == "Alliance" and "A" or fac == "Horde" and "H" or nil
end

local function Hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 99999989 end
    return h
end

-- Punkt-ID aus Kontinentkarte und Lage auf der Flugkarte
function Flight.NodeId(c, tx, ty)
    if type(c) ~= "number" or type(tx) ~= "number" or type(ty) ~= "number" then return nil end
    return string.format("%d:%d:%d", c, tx, ty)
end

-- Strecken-ID (Zahl) aus beiden Punkt-IDs
function Flight.RouteId(a, b)
    if not a or not b then return nil end
    return Hash(a .. ">" .. b)
end

-- Kontinentkarte der gerade geoeffneten Flugkarte: ueber die Karte des Spielers nach oben bis zum Kontinent (ungeprueft)
local function ContinentMap()
    local CM = _G.C_Map
    if not (CM and CM.GetBestMapForUnit) then return 0 end
    local ok, m = pcall(CM.GetBestMapForUnit, "player")
    if not ok or type(m) ~= "number" then return 0 end
    for _ = 1, 8 do
        local ok2, info = pcall(CM.GetMapInfo, m)
        if not ok2 or type(info) ~= "table" then return m end
        if info.mapType == 2 or not info.parentMapID or info.parentMapID == 0 then return m end
        m = info.parentMapID
    end
    return m
end

local function Here()
    local loc = FW.Util and FW.Util.GetPlayerLocation and FW.Util.GetPlayerLocation()
    if loc and loc.mapID and loc.x and loc.y and loc.x > 0 and loc.y > 0 then
        return loc.mapID, loc.x, loc.y
    end
    return nil
end

------------------------------------------------------------------------
-- Flugkarte lesen
------------------------------------------------------------------------

function Flight.Scan()
    local count = _G.NumTaxiNodes and _G.NumTaxiNodes() or 0
    if type(count) ~= "number" or count <= 0 or not _G.TaxiNodePosition then return end
    local known = Known(true)
    if not known then return end
    local c = ContinentMap()
    state.slot, state.cur = {}, nil
    local changed = false
    for i = 1, math.min(count, 120) do
        local ok, px, py = pcall(_G.TaxiNodePosition, i)
        if ok and type(px) == "number" and type(py) == "number" then
            local tx, ty = Round(px * 1000), Round(py * 1000)
            local id = Flight.NodeId(c, tx, ty)
            local kind = _G.TaxiNodeGetType and _G.TaxiNodeGetType(i)
            local name = _G.TaxiNodeName and _G.TaxiNodeName(i)
            local cost = _G.TaxiNodeCost and tonumber(_G.TaxiNodeCost(i)) or nil
            if kind ~= "NONE" then
                local n = known[id]
                if not n then
                    n = { c = c, tx = tx, ty = ty }
                    known[id] = n
                    changed = true
                end
                if type(name) == "string" and name ~= "" then n.n = name:sub(1, 40) end
                if kind == "CURRENT" then
                    state.cur = id
                    local m, x, y = Here()
                    if m and (n.m ~= m or not n.x) then
                        n.m, n.x, n.y = m, x, y
                        changed = true
                    end
                end
            end
            state.slot[i] = { id = id, cost = cost and math.floor(cost) or nil, kind = kind }
        end
    end
    if changed then
        Flight.rev = Flight.rev + 1
        FW:Fire("CODEX_FLIGHT_CHANGED")
    end
    if Flight.OnOpen then pcall(Flight.OnOpen) end
end

-- Flugpunkt mit Namen, wie das Spiel ihn kennt; sonst nil
local function NodeOf(id)
    local known = Known(false)
    return known and known[id]
end

------------------------------------------------------------------------
-- Flug messen
------------------------------------------------------------------------

local function OnTake(slot)
    local s = state.slot and state.slot[slot]
    if not s or not state.cur then return end
    state.pending = { from = state.cur, to = s.id, quote = s.cost or 0, money0 = _G.GetMoney and _G.GetMoney() or 0, asked = Clock() }
end

local function Copy(n)
    return { n = n.n, c = n.c, tx = n.tx, ty = n.ty, m = n.m, x = n.x, y = n.y }
end

local function Finish(p, now)
    state.pending = nil
    local f = DB()
    if not f then return end
    local dur = now - p.t0
    if dur < MIN_SECS then return end
    local a, b = NodeOf(p.from), NodeOf(p.to)
    if not (a and b) then return end
    -- Landung: Ort des Ziels merken
    local m, x, y = Here()
    if m and (b.m ~= m or not b.x) then b.m, b.x, b.y = m, x, y end
    local paid = p.paid or 0
    if paid <= 0 or paid > p.quote * 3 + 100 then paid = p.quote or 0 end
    local id = Flight.RouteId(p.from, p.to)
    local r = f.routes[id]
    local isNew = not r
    if isNew then
        local count = 0
        for _ in pairs(f.routes) do count = count + 1 end
        if count >= MAX_ROUTES then return end
        r = { n = 0, t = Round(dur), c = paid }
        f.routes[id] = r
    end
    r.n = (r.n or 0) + 1
    r.t = Round(((r.t or dur) * (r.n - 1) + dur) / r.n)
    r.c = paid
    r.a, r.b, r.f = Copy(a), Copy(b), Faction()
    r.upd = math.max(Now(), (r.upd or 0) + 1)
    Flight.rev = Flight.rev + 1
    if Codex.Share and Codex.Share.InvalidateScan then Codex.Share.InvalidateScan() end
    if isNew then
        FW:Print(string.format(FW.L.CODEX_FLIGHT_SAVED, a.n or "?", b.n or "?", r.t, r.c))
    end
    FW:Fire("CODEX_FLIGHT_CHANGED")
    FW:Fire("CODEX_CHANGED", "flight", id)
end

local function Tick()
    local p = state.pending
    if not p then return end
    local now = Clock()
    local on = _G.UnitOnTaxi and _G.UnitOnTaxi("player") and true or false
    if on and not p.started then
        p.started, p.t0 = true, now
    end
    if p.started then
        if on then
            if now - p.t0 <= PRICE_WINDOW then
                local d = p.money0 - (_G.GetMoney and _G.GetMoney() or 0)
                if d > (p.paid or 0) then p.paid = d end
            end
        else
            Finish(p, now)
        end
    elseif now - p.asked > 15 then
        state.pending = nil      -- Flug nicht angetreten
    end
end

Flight.Tick = Tick
Flight.OnTake = OnTake
Flight.Finish = Finish

------------------------------------------------------------------------
-- Lesen: eigene und empfangene Strecken
------------------------------------------------------------------------

-- Liste { id, a, b, t, c, n, f, upd, own }. Eine eigene Messung geht der Meldung anderer vor.
function Flight.All()
    local best = {}
    local f = DB()
    if not f then return {} end
    for id, r in pairs(f.routes) do
        if type(r) == "table" and r.a and r.b then best[id] = { id = id, a = r.a, b = r.b, t = r.t, c = r.c, n = r.n, f = r.f, upd = r.upd, own = true } end
    end
    if Codex.Share and Codex.Share.RemoteRecords then
        for _, r in ipairs(Codex.Share.RemoteRecords("f")) do
            local cur = best[r.id]
            if not cur or (not cur.own and (r.upd or 0) > (cur.upd or 0)) then
                best[r.id] = { id = r.id, a = r.a, b = r.b, t = r.t, c = r.c, n = r.n, f = r.f, upd = r.upd }
            end
        end
    end
    local out = {}
    for _, e in pairs(best) do out[#out + 1] = e end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
end

function Flight.Count()
    return #Flight.All()
end

-- Fluege als gerichtete Kanten { id, k = "flight", t, wait, from = {m,x,y}, to = {m,x,y}, name, est }. Nur Punkte mit bekanntem Kartenort.
-- Gemessene Fluege gelten auch rueckwaerts (est = geschaetzt, bis dort selbst geflogen oder gemeldet). faction "A" | "H" | nil.
function Flight.Edges(faction)
    local out, have = {}, {}
    local all = Flight.All()
    local function Pos(n) return n and n.m and n.x and { m = n.m, x = n.x, y = n.y } end
    for _, r in ipairs(all) do
        have[Flight.NodeId(r.a.c, r.a.tx, r.a.ty) .. ">" .. Flight.NodeId(r.b.c, r.b.tx, r.b.ty)] = true
    end
    for _, r in ipairs(all) do
        if not (faction and r.f and r.f ~= faction) then
            local pa, pb = Pos(r.a), Pos(r.b)
            if pa and pb then
                out[#out + 1] = { id = "f" .. r.id, k = "flight", t = r.t, from = pa, to = pb, name = r.b.n, fn = r.a.n, cost = r.c }
                local back = Flight.NodeId(r.b.c, r.b.tx, r.b.ty) .. ">" .. Flight.NodeId(r.a.c, r.a.tx, r.a.ty)
                if not have[back] then
                    out[#out + 1] = { id = "f" .. r.id .. "r", k = "flight", t = r.t, from = pb, to = pa, name = r.a.n, fn = r.b.n, cost = r.c, est = true }
                end
            end
        end
    end
    return out
end

-- Kennt dieser Charakter den Flugpunkt (Punkt-ID)?
function Flight.IsKnown(id)
    local k = Known(false)
    return k ~= nil and k[id] ~= nil
end

function Flight.KnownNodes()
    local out = {}
    for id, n in pairs(Known(false) or {}) do out[#out + 1] = { id = id, n = n.n, m = n.m, x = n.x, y = n.y } end
    table.sort(out, function(p, q) return p.id < q.id end)
    return out
end

function Flight.ClearOwn()
    local f = DB()
    if f then f.routes = {} end
    Flight.rev = Flight.rev + 1
    if Codex.Share and Codex.Share.InvalidateScan then Codex.Share.InvalidateScan() end
end

------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------

local acc = 0
local frame

function Flight:Start()
    if self.started then return end
    self.started = true
    FW:RegisterEvent("TAXIMAP_OPENED", function()
        if not (Codex.db and Codex.db.settings and Codex.db.settings.enabled) then return end
        Codex.Safe(Flight.Scan)
    end, Flight)
    if not self.hooked and _G.hooksecurefunc and _G.TakeTaxiNode then
        if pcall(_G.hooksecurefunc, "TakeTaxiNode", function(slot) pcall(OnTake, slot) end) then self.hooked = true end
    end
    if not frame and _G.CreateFrame then
        frame = _G.CreateFrame("Frame")
        frame:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + (elapsed or 0)
            if acc < 1 then return end
            acc = 0
            if state.pending then pcall(Tick) end
        end)
    end
end

function Flight:Stop()
    FW:UnregisterEvent("TAXIMAP_OPENED", Flight)
    state.pending = nil
    self.started = false
end

_G.SLASH_FREEWOODFLIGHT1 = "/fwflight"
_G.SlashCmdList = _G.SlashCmdList or {}
_G.SlashCmdList["FREEWOODFLIGHT"] = function()
    local known = #Flight.KnownNodes()
    FW:Print(string.format(FW.L.CODEX_FLIGHT_STATUS, known, Flight.Count(), tostring(_G.TaxiNodePosition ~= nil), tostring(_G.UnitOnTaxi ~= nil)))
end
