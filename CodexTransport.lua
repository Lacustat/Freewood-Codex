-- Freewood-Codex: Verkehrsverbindungen (Schiff, Zeppelin, U-Bahn, Portal)
--
-- Berechtigte (Modul Freewood-Dev, Rolle Bearbeiter oder hoeher) erfassen Verbindungen: Start hier, Fahrt, Ziel hier,
-- die Fahrzeit wird gemessen. Gespeichert wird in db.transport[id] und ueber das normale Teilen als Datensatz "g<ID>"
-- verschickt; angenommen werden sie nur von Absendern, die selbst berechtigt sind.
--
--   db.transport[id] = { k = Art, f = "A" | "H" | nil, n = Name, t = Sekunden, a = { m, x, y }, b = { m, x, y },
--                        two = Rueckfahrt moeglich, del = geloescht, upd = Stand }
-- Die ID ist ein Pruefwert aus Art, Fraktion und beiden Orten: derselbe Weg, von zwei Berechtigten erfasst, ergibt denselben Datensatz.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Transport = { draft = {} }
Codex.Transport = Transport
NS.Transport = Transport

Transport.KINDS = { "boat", "zeppelin", "subway", "portal" }
local KIND_OK = {}
for _, k in ipairs(Transport.KINDS) do KIND_OK[k] = true end

local function Now() return _G.time and _G.time() or 0 end

local function DB()
    local db = Codex.db
    if not db then return nil end
    db.transport = db.transport or {}
    return db
end

local function CanEdit()
    return Codex.Trust ~= nil and Codex.Trust.CanEdit()
end

local function Round(v, f) return math.floor(v * f + 0.5) end

local function Hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 99999989 end
    return h
end

-- Pruefwert (0..99999988) aus Art, Fraktion und den auf etwa 0,5 % gerundeten Orten
function Transport.Id(rec)
    local a, b = rec.a or {}, rec.b or {}
    return Hash(table.concat({ tostring(rec.k), tostring(rec.f or "-"), tostring(a.m), Round(a.x or 0, 200), Round(a.y or 0, 200),
        tostring(b.m), Round(b.x or 0, 200), Round(b.y or 0, 200) }, "|"))
end

-- Aktueller Ort { m, x, y } oder nil
function Transport.Here()
    local loc = FW.Util and FW.Util.GetPlayerLocation and FW.Util.GetPlayerLocation()
    if loc and loc.mapID and loc.x and loc.y then
        return { m = loc.mapID, x = math.floor(loc.x * 10000 + 0.5) / 10000, y = math.floor(loc.y * 10000 + 0.5) / 10000 }
    end
    return nil
end

local function Clock() return _G.GetTime and _G.GetTime() or 0 end

------------------------------------------------------------------------
-- Erfassen (Entwurf)
------------------------------------------------------------------------

function Transport.Draft()
    return Transport.draft
end

function Transport.Reset()
    local d = Transport.draft
    d.a, d.b, d.t0, d.t = nil, nil, nil, nil
    FW:Fire("CODEX_TRANSPORT_DRAFT")
end

function Transport.Start()
    local here = Transport.Here()
    if not here then return false end
    local d = Transport.draft
    d.a, d.b, d.t = here, nil, nil
    d.t0 = Clock()
    FW:Fire("CODEX_TRANSPORT_DRAFT")
    return true
end

function Transport.Finish()
    local d = Transport.draft
    if not d.a or not d.t0 then return false end
    local here = Transport.Here()
    if not here then return false end
    d.b = here
    d.t = math.max(1, math.floor(Clock() - d.t0 + 0.5))
    FW:Fire("CODEX_TRANSPORT_DRAFT")
    return true
end

-- Laeuft gerade eine Aufnahme (Start gesetzt, Ziel noch nicht)? Dann zeichnet das Wegenetz nicht mit.
function Transport.Recording()
    local d = Transport.draft
    return d.a ~= nil and d.b == nil and d.t0 ~= nil
end

function Transport.SetDraft(key, value)
    Transport.draft[key] = value
end

-- Entwurf pruefen. Rueckgabe: true oder false, Grund
function Transport.CheckDraft()
    local d = Transport.draft
    if not d.a then return false, "start" end
    if not d.b or not d.t then return false, "finish" end
    if not KIND_OK[d.kind or "boat"] then return false, "kind" end
    if d.a.m == d.b.m and math.abs(d.a.x - d.b.x) < 0.005 and math.abs(d.a.y - d.b.y) < 0.005 then return false, "same" end
    return true
end

------------------------------------------------------------------------
-- Speichern und Loeschen
------------------------------------------------------------------------

local function Touch(id)
    if Codex.Share and Codex.Share.InvalidateScan then Codex.Share.InvalidateScan() end
    Transport.rev = (Transport.rev or 0) + 1
    FW:Fire("CODEX_TRANSPORT_CHANGED", id)
    FW:Fire("CODEX_CHANGED", "transport", id)
end

local function Log(id, field, old, new)
    if Codex.DevLog then
        pcall(Codex.DevLog, { who = Codex.Trust and Codex.Trust.SelfKey() or "?", kind = "g", id = id, field = field, old = old, new = new })
    end
end

local function Describe(rec)
    local M = Codex.MapName
    return string.format("%s: %s -> %s (%ds)", tostring(rec.k), M and M(rec.a.m) or rec.a.m, M and M(rec.b.m) or rec.b.m, rec.t or 0)
end

-- Speichert den Entwurf. Rueckgabe: id oder nil, Grund
function Transport.Save()
    if not CanEdit() then return nil, "rights" end
    local ok, why = Transport.CheckDraft()
    if not ok then return nil, why end
    local d = Transport.draft
    local rec = {
        k = d.kind or "boat", f = (d.faction == "A" or d.faction == "H") and d.faction or nil,
        n = type(d.name) == "string" and d.name:sub(1, 40) ~= "" and d.name:sub(1, 40) or nil,
        t = d.t, a = { m = d.a.m, x = d.a.x, y = d.a.y }, b = { m = d.b.m, x = d.b.x, y = d.b.y },
        two = d.two ~= false, upd = Now(),
    }
    local db = DB()
    local id = Transport.Id(rec)
    local old = db.transport[id]
    rec.upd = math.max(rec.upd, (old and old.upd or 0) + 1)
    db.transport[id] = rec
    Log(id, "add", old and not old.del and Describe(old) or nil, Describe(rec))
    Touch(id)
    Transport.Reset()
    return id
end

function Transport.Delete(id)
    if not CanEdit() then return false end
    local db = DB()
    local own = db.transport[id]
    local rec = own
    if not rec then
        for _, r in ipairs(Transport.All(true)) do
            if r.id == id then rec = r break end
        end
    end
    if not rec then return false end
    local del = { k = rec.k, f = rec.f, n = rec.n, t = rec.t, a = rec.a, b = rec.b, two = rec.two, del = true,
        upd = math.max(Now(), (rec.upd or 0) + 1) }
    db.transport[id] = del
    Log(id, "del", Describe(rec), nil)
    Touch(id)
    return true
end

------------------------------------------------------------------------
-- Lesen: eigene und empfangene Verbindungen
------------------------------------------------------------------------

-- Liste { id, k, f, n, t, a, b, two, upd }, je ID der neueste Stand; geloeschte nur mit withDeleted
function Transport.All(withDeleted)
    local best = {}
    local db = DB()
    if not db then return {} end
    for id, rec in pairs(db.transport) do
        if type(rec) == "table" and rec.a and rec.b then best[id] = rec end
    end
    if Codex.Share and Codex.Share.RemoteRecords then
        for _, rec in ipairs(Codex.Share.RemoteRecords("g")) do
            local cur = best[rec.id]
            if not cur or (rec.upd or 0) > (cur.upd or 0) then best[rec.id] = rec end
        end
    end
    local out = {}
    for id, rec in pairs(best) do
        if withDeleted or not rec.del then
            out[#out + 1] = { id = id, k = rec.k, f = rec.f, n = rec.n, t = rec.t, a = rec.a, b = rec.b, two = rec.two ~= false, upd = rec.upd, del = rec.del }
        end
    end
    table.sort(out, function(x, y)
        if x.k ~= y.k then return x.k < y.k end
        return x.id < y.id
    end)
    return out
end

-- Fahrten als gerichtete Kanten { id, k, t, from = { m, x, y }, to = { m, x, y } }; faction = "A" | "H" | nil (alle)
function Transport.Edges(faction)
    local out = {}
    for _, r in ipairs(Transport.All()) do
        if not (faction and r.f and r.f ~= faction) then
            out[#out + 1] = { id = r.id, k = r.k, t = r.t, from = r.a, to = r.b, name = r.n }
            if r.two then out[#out + 1] = { id = r.id, k = r.k, t = r.t, from = r.b, to = r.a, name = r.n } end
        end
    end
    return out
end

function Transport.Count()
    return #Transport.All()
end
