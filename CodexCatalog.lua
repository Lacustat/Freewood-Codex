-- Freewood-Codex: Quest-Katalog (Titel und Stufe aller Quest-IDs, die der Server kennt)
--
-- Der Server liefert zu jeder Quest-ID auf Anfrage (C_QuestLog.RequestLoadQuestByID) den Titel und die Stufe
-- (GetTitleForQuestID, GetQuestDifficultyLevel), auch fuer Quests, die man nie gesehen hat. Der Katalog fragt die IDs
-- gedrosselt ab und merkt sich nur "ID gibt es" mit Titel und Stufe. Geber, Ort, Ziele und Vorquests liefert er nicht;
-- die lernt der Codex weiter beim Spielen.
--
--   /fwquestkatalog              setzt den Lauf dort fort, wo er aufgehoert hat (Quest-IDs 1 bis 120000)
--   /fwquestkatalog <von> <bis>  nur diesen Bereich
--   /fwquestkatalog stop|status|neu
--   /fwkatalog <q|i|n> [von bis | stop | status | neu | test <id>]   dasselbe fuer Quests (q), Items (i) und NPCs (n)
--
-- Items: C_Item.RequestLoadItemDataByID, danach GetItemInfo (Qualitaet, Stufe, Mindeststufe, Verkaufspreis, Name).
-- NPCs: es gibt keine Abfrage nur mit ID; der Name kommt aus dem Tooltip eines Kreatur-Links (C_TooltipInfo.GetHyperlink).
--
-- Ablage: db.cat = { loc = Sprache, pos/posi/posn = naechste ID, q = { [id] = "Stufe|Titel" }, i = { [id] = "Qualitaet|Stufe|Mindeststufe|Preis|Name" }, n = { [id] = "Name" } }. Die Startdaten (Freewood-ForeverData)
-- bringen einen fertigen Katalog mit (extra.cat); der eigene geht vor.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Cat = { rev = 0 }
Codex.Catalog = Cat
NS.Catalog = Cat

local MAX_ID = 250000   -- Quests (Standard, wenn kein Bereich angegeben ist)
local BATCH = 20        -- Anfragen je Schub
local PAUSE = 0.5       -- Sekunden zwischen den Schueben
local HARVEST = 4       -- Sekunden bis zum Einsammeln der Antworten eines Schubs

local function Now() return _G.GetTime and _G.GetTime() or 0 end

local function Store()
    local db = Codex.db
    if not db then return nil end
    db.cat = db.cat or {}
    local c = db.cat
    c.q = c.q or {}
    c.i = c.i or {}
    c.n = c.n or {}
    if not c.loc then c.loc = _G.GetLocale and _G.GetLocale() or nil end
    return c
end

local function Parse(s)
    if type(s) ~= "string" then return nil end
    local lv, t = s:match("^(%d+)|(.+)$")
    if not t then return nil end
    lv = tonumber(lv)
    return t, (lv and lv > 0) and lv or nil
end

-- Mitgelieferter Katalog (Startdaten)
local function Builtin()
    local f = Codex.Forever
    if f and f.Disabled and f.Disabled() then return nil end
    local g = _G.FreewoodForeverData
    local ex = g and g.ready and type(g.extra) == "table" and g.extra.cat
    if type(ex) == "table" and type(ex.q) == "table" then return ex end
    return nil
end

-- Titel, Stufe der Quest aus dem Katalog (eigener zuerst, dann die Startdaten)
function Cat.Get(id)
    if type(id) ~= "number" then return nil end
    local db = Codex.db
    local own = db and db.cat and db.cat.q and db.cat.q[id]
    local t, lv = Parse(own)
    if t then return t, lv end
    local b = Builtin()
    if b then
        t, lv = Parse(b.q[id])
        if t then return t, lv end
    end
    return nil
end

-- Stand des Katalogs (aendert sich mit neuen eigenen Titeln und mit dem Laden oder Abschalten der Startdaten)
function Cat.Rev()
    local b = Builtin()
    return Cat.rev .. ":" .. (b and tostring(b) or "-")
end

-- Alle IDs des Katalogs (eigene und mitgelieferte), sortiert
local idCache, idRev
function Cat.IDs()
    local rev = Cat.Rev()
    if idCache and idRev == rev then return idCache end
    local seen, out = {}, {}
    local db = Codex.db
    for id in pairs(db and db.cat and db.cat.q or {}) do
        if type(id) == "number" then seen[id] = true out[#out + 1] = id end
    end
    local b = Builtin()
    if b then
        for id in pairs(b.q) do
            if type(id) == "number" and not seen[id] then seen[id] = true out[#out + 1] = id end
        end
    end
    table.sort(out)
    idCache, idRev = out, rev
    return out
end

function Cat.Count()
    local db = Codex.db
    local own = 0
    for _ in pairs(db and db.cat and db.cat.q or {}) do own = own + 1 end
    return own, #Cat.IDs()
end

------------------------------------------------------------------------
-- Arten: q = Quests, i = Items, n = NPCs
------------------------------------------------------------------------

local function CleanName(t)
    t = tostring(t):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "/")
    return t
end

local function ReqQuest(id)
    local QL = _G.C_QuestLog
    pcall(QL.RequestLoadQuestByID, id)
end

local function ReadQuest(id)
    local QL = _G.C_QuestLog
    local ok, t = pcall(QL.GetTitleForQuestID, id)
    if not (ok and type(t) == "string" and t ~= "") then return nil end
    local lv = 0
    if QL.GetQuestDifficultyLevel then
        local ok2, v = pcall(QL.GetQuestDifficultyLevel, id)
        if ok2 and type(v) == "number" and v > 0 and v < 200 then lv = math.floor(v) end
    end
    return lv .. "|" .. CleanName(t)
end

local function ItemInfo(id)
    local CI = _G.C_Item
    local get = (CI and CI.GetItemInfo) or _G.GetItemInfo
    if not get then return nil end
    return get(id)
end

local function ReqItem(id)
    local CI = _G.C_Item
    if CI and CI.RequestLoadItemDataByID then pcall(CI.RequestLoadItemDataByID, id)
    else pcall(ItemInfo, id) end
end

local function ReadItem(id)
    local ok, name, _, quality, ilvl, minLvl, _, _, _, _, _, sell = pcall(ItemInfo, id)
    if not (ok and type(name) == "string" and name ~= "") then return nil end
    local function N(v) return math.floor(tonumber(v) or 0) end
    return string.format("%d|%d|%d|%d|%s", N(quality), N(ilvl), N(minLvl), N(sell), CleanName(name))
end

local function UnitLink(id)
    return "unit:Creature-0-0-0-0-" .. id .. "-0000000000"
end

local function NpcData(id)
    local TI = _G.C_TooltipInfo
    if not (TI and TI.GetHyperlink) then return nil end
    local ok, data = pcall(TI.GetHyperlink, UnitLink(id))
    if ok and type(data) == "table" then return data end
    return nil
end

local function ReqNpc(id) NpcData(id) end

local function ReadNpc(id)
    local data = NpcData(id)
    local line = data and data.lines and data.lines[1]
    local name = line and line.leftText
    if type(name) ~= "string" or name == "" then return nil end
    return CleanName(name)
end

local KINDS = {
    q = { store = "q", pos = "pos", max = MAX_ID, req = ReqQuest, read = ReadQuest, label = "Quests",
        ready = function() local QL = _G.C_QuestLog return QL and QL.RequestLoadQuestByID and QL.GetTitleForQuestID end },
    i = { store = "i", pos = "posi", max = 250000, req = ReqItem, read = ReadItem, label = "Items",
        ready = function() return (_G.C_Item and (_G.C_Item.GetItemInfo or _G.C_Item.RequestLoadItemDataByID)) or _G.GetItemInfo end },
    n = { store = "n", pos = "posn", max = 250000, req = ReqNpc, read = ReadNpc, label = "NPCs",
        ready = function() return _G.C_TooltipInfo and _G.C_TooltipInfo.GetHyperlink end },
}
Cat.KINDS = KINDS

-- Item aus dem Katalog: Qualitaet, Stufe, Mindeststufe, Verkaufspreis, Name
function Cat.GetItem(id)
    local function P(s)
        if type(s) ~= "string" then return nil end
        local q, il, ml, sp, nm = s:match("^(%d+)|(%d+)|(%d+)|(%d+)|(.+)$")
        if not nm then return nil end
        return nm, tonumber(q), tonumber(il), tonumber(ml), tonumber(sp)
    end
    local db = Codex.db
    local r = { P(db and db.cat and db.cat.i and db.cat.i[id]) }
    if r[1] then return unpack(r) end
    local b = Builtin()
    return P(b and b.i and b.i[id])
end

-- NPC-Name aus dem Katalog
function Cat.GetNpc(id)
    local db = Codex.db
    local own = db and db.cat and db.cat.n and db.cat.n[id]
    if type(own) == "string" then return own end
    local b = Builtin()
    local v = b and b.n and b.n[id]
    return type(v) == "string" and v or nil
end

------------------------------------------------------------------------
-- Lauf
------------------------------------------------------------------------

local function Say(text) FW:Print("Katalog: " .. text) end

local function CountOf(kind)
    local c = Codex.db and Codex.db.cat
    local n = 0
    for _ in pairs(c and c[KINDS[kind].store] or {}) do n = n + 1 end
    return n
end

local function Harvest(job, a, b)
    local K = KINDS[job.kind]
    local c = Store()
    if c then
        local tbl = c[K.store]
        for id = a, b do
            local entry = K.read(id)
            if entry and tbl[id] ~= entry then
                if not tbl[id] then job.found = job.found + 1 end
                tbl[id] = entry
                Cat.rev = Cat.rev + 1
            end
        end
    end
    job.pending = job.pending - 1
    if job.nextID > job.hi and job.pending <= 0 and Cat.job == job then
        Cat.job = nil
        Say(string.format("%s fertig mit %d-%d: %d neue Eintraege, insgesamt %d eigene (%d Sekunden).", K.label, job.lo, job.hi, job.found, CountOf(job.kind), math.floor(Now() - job.t0)))
        FW:Fire("CODEX_CHANGED", "catalog")
    end
end

local function Step(job)
    if Cat.job ~= job then return end
    if job.stop then
        if job.pending <= 0 then Cat.job = nil end
        return
    end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        C_Timer.After(2, function() Step(job) end)
        return
    end
    local K = KINDS[job.kind]
    local a = job.nextID
    local b = math.min(a + BATCH - 1, job.hi)
    for id = a, b do K.req(id) end
    job.nextID = b + 1
    job.pending = job.pending + 1
    local c = Store()
    if job.resume and c then c[K.pos] = job.nextID end
    C_Timer.After(HARVEST, function() Harvest(job, a, b) end)
    -- Fortschritt alle 10000 IDs
    if math.floor(a / 10000) ~= math.floor(b / 10000) then
        Say(string.format("%s: ID %d von %d ...", K.label, b, job.hi))
    end
    if job.nextID <= job.hi then
        C_Timer.After(PAUSE, function() Step(job) end)
    end
end

-- Rueckgabe: true oder false, Grund ("api", "busy", "range")
function Cat.Start(lo, hi, resume, kind)
    kind = kind or "q"
    local K = KINDS[kind]
    if not K then return false, "kind" end
    if not K.ready() then return false, "api" end
    if Cat.job then return false, "busy" end
    if not Store() then return false, "db" end
    lo = math.max(1, math.floor(tonumber(lo) or 1))
    hi = math.min(K.max, math.floor(tonumber(hi) or K.max))
    if hi < lo then return false, "range" end
    local job = { kind = kind, lo = lo, hi = hi, nextID = lo, found = 0, pending = 0, t0 = Now(), resume = resume }
    Cat.job = job
    Step(job)
    return true, lo, hi
end

function Cat.Stop()
    if Cat.job then Cat.job.stop = true end
end

-- Lauf dort fortsetzen, wo er aufgehoert hat (fuer Befehl und Dev-Knopf). Rueckgabe wie Start; "done", wenn alles durch ist
function Cat.Resume(restart, kind)
    kind = kind or "q"
    local K = KINDS[kind]
    local c = Store()
    if restart and c then c[K.pos] = 1 end
    local pos = c and c[K.pos] or 1
    if pos > K.max then return false, "done" end
    return Cat.Start(pos, K.max, true, kind)
end

-- Stand fuer die Anzeige: laeuft, naechste ID, letzte ID, eigene Eintraege, gesamt (nur Quests mit Startdaten)
function Cat.Progress(kind)
    kind = kind or "q"
    local K = KINDS[kind]
    local c = Codex.db and Codex.db.cat
    local own, all = CountOf(kind), CountOf(kind)
    if kind == "q" then own, all = Cat.Count() end
    local running = Cat.job ~= nil and not Cat.job.stop and Cat.job.kind == kind
    return running, (Cat.job and Cat.job.kind == kind and Cat.job.nextID) or (c and c[K.pos]) or 1, K.max, own, all
end

local function Status(kind)
    local K = KINDS[kind]
    local c = Codex.db and Codex.db.cat
    local pos = c and c[K.pos] or 1
    local own, all = CountOf(kind), nil
    if kind == "q" then own, all = Cat.Count() end
    local line = string.format("%s: %d eigene Eintraege%s. Lauf bis ID %d von %d.", K.label, own, all and (", " .. all .. " im Katalog (mit Startdaten)") or "", math.min(pos, K.max), K.max)
    if Cat.job then line = line .. " Laeuft: " .. KINDS[Cat.job.kind].label .. " (ID " .. Cat.job.nextID .. ")." end
    Say(line)
end

-- Einzelne ID pruefen (zeigt die Rohantwort, speichert nichts)
local function Test(kind, id)
    local K = KINDS[kind]
    if not K.ready() then Say(K.label .. ": diese Abfrage bietet das Spiel nicht an.") return end
    K.req(id)
    C_Timer.After(2, function()
        local entry = K.read(id)
        Say(string.format("%s-Test ID %d: %s", K.label, id, entry or "keine Antwort (unbekannt oder noch nicht geladen)"))
    end)
    Say(string.format("%s-Test ID %d: Antwort in 2 Sekunden ...", K.label, id))
end

local function Handle(kind, msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local K = KINDS[kind]
    if msg == "stop" then
        if Cat.job then Cat.Stop() Say("wird angehalten (der Stand bleibt erhalten).") else Say("es laeuft nichts.") end
        return
    elseif msg == "status" then
        Status(kind)
        return
    end
    local tid = msg:match("^test%s+(%d+)$")
    if tid then Test(kind, tonumber(tid)) return end
    local lo, hi = msg:match("^(%d+)%D+(%d+)$")
    local ok, a, b
    if lo then
        ok, a, b = Cat.Start(tonumber(lo), tonumber(hi), false, kind)
    else
        ok, a, b = Cat.Resume(msg == "neu", kind)
        if a == "done" then
            Say(K.label .. ": bis ID " .. K.max .. " durchgelaufen. Mit neu beginnt ein neuer Lauf von vorn (vorhandene Eintraege bleiben).")
            return
        end
    end
    if ok then
        Say(string.format("%s: Lauf %d-%d gestartet (gedrosselt, ca. %d Anfragen pro Sekunde). Anhalten: stop. Du kannst weiterspielen.",
            K.label, a, b, math.floor(BATCH / PAUSE)))
    elseif a == "busy" then
        Say("es laeuft schon ein Lauf (stop zum Anhalten).")
    elseif a == "api" then
        Say(K.label .. ": diese Abfrage bietet diese Version von Forever nicht an.")
    else
        Say("Bereich nicht moeglich.")
    end
end

SLASH_FREEWOODQUESTCAT1 = "/fwquestkatalog"
SlashCmdList["FREEWOODQUESTCAT"] = function(msg) Handle("q", msg) end

SLASH_FREEWOODCAT1 = "/fwkatalog"
SlashCmdList["FREEWOODCAT"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", "")
    local k, rest = msg:match("^(%a)%s*(.*)$")
    if k == "q" or k == "i" or k == "n" then Handle(k, rest) return end
    Say("benutze /fwkatalog q|i|n [von bis | stop | status | neu | test <id>]  (q = Quests, i = Items, n = NPCs)")
end
