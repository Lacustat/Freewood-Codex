-- Freewood-Codex: Ortspunkte (Eingang zu Instanz oder Hoehle, Berg-Aufstieg, Engstelle, Zielpunkt)
--
-- Berechtigte (Modul Freewood-Dev, Rolle Bearbeiter oder hoeher) erfassen einzelne Punkte, an denen der Levelplan vorbeimuss:
-- zum Beispiel der Eingang einer Instanz fuer eine Dungeon-Quest. Ein Punkt gehoert zu einer oder mehreren Quests (q) und/oder
-- zu einem ganzen Gebiet (am = Karte; negativ = Instanz). Gespeichert wird in db.spots[id]; das normale Teilen verschickt sie als
-- Datensatz "h<ID>", angenommen nur von Absendern, die selbst berechtigt sind.
--
--   db.spots[id] = { k = Art, f = "A" | "H" | nil, n = Name, p = { m, x, y }, q = { Quest-IDs }, am = Gebiet, del, upd }
-- Die ID ist ein Pruefwert aus Fraktion und Ort (auf etwa 0,5 % gerundet): wer an derselben Stelle erneut speichert, aendert den Punkt.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Spots = { draft = { q = {} }, rev = 0 }
Codex.Spots = Spots
NS.Spots = Spots

Spots.KINDS = { "instance", "cave", "mountain", "pass", "point", "other" }
local KIND_OK = {}
for _, k in ipairs(Spots.KINDS) do KIND_OK[k] = true end
Spots.MAX_QUESTS = 20

local function Now() return _G.time and _G.time() or 0 end

local function DB()
    local db = Codex.db
    if not db then return nil end
    db.spots = db.spots or {}
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

function Spots.Id(rec)
    local p = rec.p or {}
    return Hash(table.concat({ "s", tostring(rec.f or "-"), tostring(p.m), Round(p.x or 0, 200), Round(p.y or 0, 200) }, "|"))
end

-- Aenderung melden (auch fuer empfangene Datensaetze: ruft CodexShare auf)
function Spots.Bump(id)
    Spots.rev = Spots.rev + 1
    Spots.index = nil
    FW:Fire("CODEX_SPOTS_CHANGED", id)
end

------------------------------------------------------------------------
-- Entwurf
------------------------------------------------------------------------

function Spots.Draft()
    return Spots.draft
end

function Spots.Reset()
    local d = Spots.draft
    d.p, d.am, d.kind, d.faction, d.name, d.editing = nil, nil, nil, nil, nil, nil
    d.q = {}
    FW:Fire("CODEX_SPOTS_DRAFT")
end

-- Ort des Spielers { m, x, y } oder nil
function Spots.Here()
    local T = Codex.Transport
    if T and T.Here then return T.Here() end
    return nil
end

function Spots.Capture()
    local here = Spots.Here()
    if not here then return false end
    Spots.draft.p = here
    FW:Fire("CODEX_SPOTS_DRAFT")
    return true
end

-- Gebiet, in dem der Spieler gerade steht: Instanz (negativ) oder Karte
function Spots.AreaHere()
    local inst = Codex.CurrentInstance and Codex.CurrentInstance()
    if inst then return -inst end
    local here = Spots.Here()
    return here and here.m or nil
end

function Spots.SetArea(am)
    Spots.draft.am = am
    FW:Fire("CODEX_SPOTS_DRAFT")
end

function Spots.AddQuest(id)
    id = tonumber(id)
    local d = Spots.draft
    if not id or id < 1 or id ~= math.floor(id) or #d.q >= Spots.MAX_QUESTS then return false end
    for _, v in ipairs(d.q) do if v == id then return true end end
    d.q[#d.q + 1] = id
    FW:Fire("CODEX_SPOTS_DRAFT")
    return true
end

function Spots.RemoveQuest(id)
    local d = Spots.draft
    for i, v in ipairs(d.q) do
        if v == id then table.remove(d.q, i) FW:Fire("CODEX_SPOTS_DRAFT") return true end
    end
    return false
end

-- Quests zu einem Suchtext (Nummer oder Teil des Namens): { { id, title } }, hoechstens limit
function Spots.FindQuests(text, limit)
    limit = limit or 8
    local out = {}
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return out end
    local num = tonumber(text)
    local seed = Codex.Seed and Codex.Seed.Ready and Codex.Seed.Ready() and Codex.Seed or nil
    local V = Codex.V and Codex.V()
    local function Title(id)
        return Codex.QuestTitle(V and V.quests[id], id)
    end
    if num then
        out[1] = { id = num, title = Title(num) }
        return out
    end
    local needle = text:lower()
    local seen = {}
    for id, q in pairs(V and V.quests or {}) do
        local t = Title(id)
        if t and t:lower():find(needle, 1, true) then
            seen[id] = true
            out[#out + 1] = { id = id, title = t }
        end
    end
    if seed and seed.IDs then
        for _, id in ipairs(seed.IDs("quests")) do
            if not seen[id] and seed.Haystack("quests", id):find(needle, 1, true) then
                out[#out + 1] = { id = id, title = Title(id) }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.title ~= b.title then return a.title < b.title end
        return a.id < b.id
    end)
    while #out > limit do out[#out] = nil end
    return out
end

-- Entwurf pruefen. Rueckgabe: true oder false, Grund
function Spots.CheckDraft()
    local d = Spots.draft
    if not d.p then return false, "pos" end
    if not KIND_OK[d.kind or "instance"] then return false, "kind" end
    if not d.am and #d.q == 0 then return false, "link" end
    return true
end

------------------------------------------------------------------------
-- Speichern, Bearbeiten, Loeschen
------------------------------------------------------------------------

local function Touch(id)
    if Codex.Share and Codex.Share.InvalidateScan then Codex.Share.InvalidateScan() end
    Spots.Bump(id)
    FW:Fire("CODEX_CHANGED", "spots", id)
end

local function Describe(rec)
    local M = Codex.MapName
    return string.format("%s: %s (%.1f / %.1f)%s", tostring(rec.k), M and M(rec.p.m) or rec.p.m, rec.p.x * 100, rec.p.y * 100,
        rec.am and (" > " .. (M and M(rec.am) or rec.am)) or "")
end

local function Log(id, field, old, new)
    if Codex.DevLog then
        pcall(Codex.DevLog, { who = Codex.Trust and Codex.Trust.SelfKey() or "?", kind = "h", id = id, field = field, old = old, new = new })
    end
end

-- Rueckgabe: id oder nil, Grund
function Spots.Save()
    if not CanEdit() then return nil, "rights" end
    local ok, why = Spots.CheckDraft()
    if not ok then return nil, why end
    local d = Spots.draft
    local q = {}
    for _, v in ipairs(d.q) do q[#q + 1] = v end
    table.sort(q)
    local name = type(d.name) == "string" and d.name:sub(1, 40) or ""
    local rec = {
        k = d.kind or "instance", f = (d.faction == "A" or d.faction == "H") and d.faction or nil,
        n = name ~= "" and name or nil, p = { m = d.p.m, x = d.p.x, y = d.p.y }, q = q, am = d.am, upd = Now(),
    }
    local db = DB()
    local id = Spots.Id(rec)
    local old = db.spots[id]
    rec.upd = math.max(rec.upd, (old and old.upd or 0) + 1)
    db.spots[id] = rec
    Log(id, "add", old and not old.del and Describe(old) or nil, Describe(rec))
    Touch(id)
    Spots.Reset()
    return id
end

-- Liste { id, k, f, n, p, q, am, upd, del }; je ID der neueste Stand; geloeschte nur mit withDeleted
function Spots.All(withDeleted)
    local best = {}
    local db = DB()
    if not db then return {} end
    for id, rec in pairs(db.spots) do
        if type(rec) == "table" and rec.p then best[id] = rec end
    end
    if Codex.Share and Codex.Share.RemoteRecords then
        for _, rec in ipairs(Codex.Share.RemoteRecords("h")) do
            local cur = best[rec.id]
            if not cur or (rec.upd or 0) > (cur.upd or 0) then best[rec.id] = rec end
        end
    end
    local out = {}
    for id, rec in pairs(best) do
        if withDeleted or not rec.del then
            out[#out + 1] = { id = id, k = rec.k, f = rec.f, n = rec.n, p = rec.p, q = rec.q or {}, am = rec.am, upd = rec.upd, del = rec.del }
        end
    end
    table.sort(out, function(x, y)
        if x.p.m ~= y.p.m then return x.p.m < y.p.m end
        return x.id < y.id
    end)
    return out
end

function Spots.Get(id)
    for _, r in ipairs(Spots.All(true)) do
        if r.id == id then return r end
    end
    return nil
end

-- Punkt in den Entwurf laden (zum Aendern); Speichern an derselben Stelle ersetzt ihn
function Spots.Edit(id)
    local r = Spots.Get(id)
    if not r or r.del then return false end
    local d = Spots.draft
    d.p = { m = r.p.m, x = r.p.x, y = r.p.y }
    d.kind, d.faction, d.name, d.am, d.editing = r.k, r.f, r.n, r.am, id
    d.q = {}
    for _, v in ipairs(r.q) do d.q[#d.q + 1] = v end
    FW:Fire("CODEX_SPOTS_DRAFT")
    return true
end

function Spots.Delete(id)
    if not CanEdit() then return false end
    local rec = Spots.Get(id)
    if not rec then return false end
    local db = DB()
    db.spots[id] = { k = rec.k, f = rec.f, n = rec.n, p = rec.p, q = rec.q, am = rec.am, del = true,
        upd = math.max(Now(), (rec.upd or 0) + 1) }
    Log(id, "del", Describe(rec), nil)
    Touch(id)
    return true
end

------------------------------------------------------------------------
-- Lesen fuer den Levelplan
------------------------------------------------------------------------

local EMPTY = {}

local function BuildIndex()
    local idx = { quest = {}, area = {} }
    for _, r in ipairs(Spots.All()) do
        local s = { id = r.id, k = r.k, f = r.f, n = r.n, m = r.p.m, x = r.p.x, y = r.p.y }
        for _, qid in ipairs(r.q) do
            idx.quest[qid] = idx.quest[qid] or {}
            table.insert(idx.quest[qid], s)
        end
        if r.am then
            idx.area[r.am] = idx.area[r.am] or {}
            table.insert(idx.area[r.am], s)
        end
    end
    idx.empty = next(idx.quest) == nil and next(idx.area) == nil
    return idx
end

-- Punkte, die fuer ein Ziel gelten: Quest-ID (oder nil) und Karte des Ziels (Instanzen negativ); faction = "A" | "H" | nil.
-- Rueckgabe: Liste { id, k, n, m, x, y } (leer, wenn nichts passt)
function Spots.For(questID, m, faction)
    if not Spots.index then Spots.index = BuildIndex() end
    local idx = Spots.index
    if idx.empty then return EMPTY end
    local out, seen = {}, {}
    local function Add(list)
        for _, s in ipairs(list or {}) do
            if not seen[s.id] and not (faction and s.f and s.f ~= faction) then
                seen[s.id] = true
                out[#out + 1] = s
            end
        end
    end
    if questID then Add(idx.quest[questID]) end
    if m then Add(idx.area[m]) end
    return out
end

function Spots.Count()
    return #Spots.All()
end
