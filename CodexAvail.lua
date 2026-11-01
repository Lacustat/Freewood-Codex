-- Freewood-Codex: Verfuegbarkeit von Quests (noch nicht annehmbar) und Voraussetzungen lernen
--
-- Der Server verraet nicht, welche Quests man jetzt annehmen koennte oder welche Vorquest fehlt. Das Spiel liefert nur:
--   * die Angebotsliste eines NPCs oder Objekts, waehrend man mit ihm spricht (GOSSIP_SHOW, QUEST_GREETING, QUEST_DETAIL)
--   * welche Quests der Charakter erledigt hat (IsQuestFlaggedCompleted / GetAllCompletedQuestIDs)
-- Daraus entsteht ein Vergleich zweier Zeitpunkte:
--   Negativ-Beobachtung: Eine Quest sollte hier angeboten werden, wird es aber nicht (oder der Spieler markiert sie als "noch nicht
--   moeglich"). Gemerkt werden Stufe und die Menge der erledigten Quests.
--   Positiv-Beobachtung: Spaeter wird sie angeboten oder angenommen. Die Vorquest muss unter den seither erledigten Quests liegen,
--   und hat sich nur die Stufe geaendert, ist das die Mindeststufe.
-- Die Markierung "noch nicht moeglich" gilt je Charakter (db.avail[Charakter]). Die gelernten Angaben stehen in den Quest-Daten
-- und werden geteilt: pi (Kandidat -> Anzahl), po (Beobachtungen), mi (Stufenbereich lo/hi/n). Als Vorquest gilt ein Kandidat, der in
-- allen Beobachtungen vorkam: fuer den eigenen Charakter sofort, fuer andere erst ab zwei Beobachtungen.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Avail = { probe = nil }
Codex.Avail = Avail
NS.Avail = Avail

local MAX_DELTA = 6          -- mehr neu erledigte Quests sind keine brauchbare Beobachtung
local MAX_PI = 8
local NEG_KEEP = 60 * 24 * 3600
local function Now() return _G.time and _G.time() or 0 end

local function SelfKey()
    return Codex.Trust and Codex.Trust.SelfKey and Codex.Trust.SelfKey() or nil
end

local function Char(create)
    local db = Codex.db
    if not db then return nil end
    local key = SelfKey()
    if not key then return nil end
    db.avail = db.avail or {}
    local c = db.avail[key]
    if not c and create then
        c = { blocked = {}, neg = {} }
        db.avail[key] = c
    end
    return c
end

local function PlayerLevel()
    local lv = _G.UnitLevel and _G.UnitLevel("player")
    return tonumber(lv) or 1
end

------------------------------------------------------------------------
-- Erledigte Quests
------------------------------------------------------------------------

-- Menge der erledigten Quest-IDs des Charakters; Ersatz: bekannte IDs einzeln abfragen
function Avail.Completed()
    local set = {}
    local QL = _G.C_QuestLog
    if QL and QL.GetAllCompletedQuestIDs then
        local ok, list = pcall(QL.GetAllCompletedQuestIDs)
        if ok and type(list) == "table" then
            for _, id in pairs(list) do set[id] = true end
            if next(set) ~= nil then return set, true end
        end
    end
    for id in pairs(Codex.V().quests) do
        if Codex.QuestStatus(id) == "done" then set[id] = true end
    end
    local c = Char(false)
    for id in pairs(c and c.neg or {}) do
        if Codex.QuestStatus(id) == "done" then set[id] = true end
    end
    return set, false
end

local function ToList(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end

------------------------------------------------------------------------
-- Markieren
------------------------------------------------------------------------

-- Eine Quest als "noch nicht annehmbar" merken (src: "manual" oder "scan"). Rueckgabe: true, wenn neu
function Avail.Block(id, src)
    id = tonumber(id)
    local c = Char(true)
    if not id or not c then return false end
    if Codex.QuestStatus(id) ~= nil then return false end
    local fresh = c.blocked[id] == nil
    local lv = PlayerLevel()
    local done = Avail.Completed()
    c.blocked[id] = { lv = lv, t = Now(), n = #ToList(done), src = src or "manual" }
    -- Schnappschuss fuer die spaetere Auswertung; die juengste Negativ-Beobachtung gilt (sie grenzt am engsten ein)
    c.neg[id] = { lv = lv, t = Now(), done = ToList(done) }
    FW:Fire("CODEX_AVAIL_CHANGED", id)
    return fresh
end

function Avail.Unblock(id)
    local c = Char(false)
    if c and c.blocked[id] then
        c.blocked[id] = nil
        FW:Fire("CODEX_AVAIL_CHANGED", id)
        return true
    end
    return false
end

function Avail.IsBlocked(id)
    local c = Char(false)
    return c ~= nil and c.blocked[id] ~= nil
end

function Avail.BlockedCount()
    local c = Char(false)
    local n = 0
    for _ in pairs(c and c.blocked or {}) do n = n + 1 end
    return n
end

-- Liste { id, lv, t, src, title }, sortiert nach Titel
function Avail.List()
    local out = {}
    local c = Char(false)
    local V = Codex.V()
    for id, b in pairs(c and c.blocked or {}) do
        out[#out + 1] = { id = id, lv = b.lv, t = b.t, src = b.src, title = Codex.QuestTitle(V.quests[id], id) }
    end
    table.sort(out, function(a, b)
        if a.title ~= b.title then return a.title < b.title end
        return a.id < b.id
    end)
    return out
end

function Avail.Count()
    local c = Char(false)
    local n = 0
    for _ in pairs(c and c.blocked or {}) do n = n + 1 end
    return n
end

function Avail.ClearAll()
    local c = Char(false)
    if c then c.blocked = {} FW:Fire("CODEX_AVAIL_CHANGED") end
end

-- Aenderung am Charakter (Stufe, abgegebene Quest): markierte Quests koennten jetzt frei sein und kommen zurueck
function Avail.Release()
    local c = Char(false)
    if not c or next(c.blocked) == nil then return 0 end
    local lv = PlayerLevel()
    local count = #ToList(Avail.Completed())
    local freed = 0
    for id, b in pairs(c.blocked) do
        if lv > (b.lv or 0) or count > (b.n or 0) or Codex.QuestStatus(id) ~= nil then
            c.blocked[id] = nil
            freed = freed + 1
        end
    end
    if freed > 0 then FW:Fire("CODEX_AVAIL_CHANGED") end
    return freed
end

------------------------------------------------------------------------
-- Auswerten (Positiv-Beobachtung)
------------------------------------------------------------------------

local function Bracket(q, lo, hi)
    local mi = q.mi
    if type(mi) == "table" and mi.lo and mi.hi then
        local nlo, nhi = math.max(mi.lo, lo), math.min(mi.hi, hi)
        if nhi > nlo then
            q.mi = { lo = nlo, hi = nhi, n = (mi.n or 1) + 1 }
            return
        end
    end
    q.mi = { lo = lo, hi = hi, n = 1 }
end

-- Die Quest ist jetzt verfuegbar (angeboten oder angenommen): Unterschied zum Zeitpunkt der Negativ-Beobachtung auswerten
function Avail.Observed(id)
    local c = Char(false)
    local neg = c and c.neg[id]
    if not neg then return false end
    c.neg[id] = nil
    local V = Codex.V()
    local q = Codex.db.quests[id]
    if not q then
        local title = V.quests[id] and V.quests[id].t
        if not title then return false end   -- ohne bekannten Titel laesst sich der Datensatz nicht teilen
        q = Codex:Quest(id, true)
        q.t = title
    end
    local now = Avail.Completed()
    local before = {}
    for _, p in ipairs(neg.done or {}) do before[p] = true end
    local delta = {}
    for p in pairs(now) do
        if not before[p] and p ~= id then delta[#delta + 1] = p end
    end
    table.sort(delta)
    local lv = PlayerLevel()
    local changed = false
    if #delta == 0 then
        if lv > (neg.lv or lv) then
            Bracket(q, neg.lv, lv)
            changed = true
        end
    elseif #delta <= MAX_DELTA then
        q.pi = q.pi or {}
        q.po = (q.po or 0) + 1
        local n = 0
        for _ in pairs(q.pi) do n = n + 1 end
        for _, p in ipairs(delta) do
            if q.pi[p] or n < MAX_PI then
                if not q.pi[p] then n = n + 1 end
                q.pi[p] = (q.pi[p] or 0) + 1
            end
        end
        changed = true
    end
    if changed then
        Codex.chainRev = (Codex.chainRev or 0) + 1
        FW:Fire("CODEX_CHANGED", "quest", id)
    end
    Avail.Unblock(id)
    return changed
end

-- Vorquests, die sich aus den Beobachtungen ergeben: Kandidaten, die in allen Beobachtungen vorkamen.
-- Fuer die eigene Beobachtung gilt schon eine, sonst braucht es zwei (own = true, wenn der Datensatz eigene Beobachtungen traegt)
function Avail.InferredPre(q, own)
    local out = {}
    if type(q) ~= "table" or type(q.pi) ~= "table" then return out end
    local po = q.po or 0
    if po < (own and 1 or 2) then return out end
    for p, n in pairs(q.pi) do
        if n >= po then out[#out + 1] = p end
    end
    table.sort(out)
    return out
end

-- Mindeststufe aus den Beobachtungen: nur wenn der Bereich genau eine Stufe breit ist (und zwei Beobachtungen oder eigene)
function Avail.InferredMin(q, own)
    local mi = type(q) == "table" and q.mi or nil
    if type(mi) ~= "table" or not mi.lo or not mi.hi then return nil end
    if mi.hi - mi.lo ~= 1 then return nil end
    if (mi.n or 1) < (own and 1 or 2) then return nil end
    return mi.hi
end

------------------------------------------------------------------------
-- Scan beim Geber
------------------------------------------------------------------------

-- Angebotene Quests des gerade angesprochenen NPCs oder Objekts: Menge von IDs und Menge von Titeln
local function ReadOffers()
    local ids, titles = {}, {}
    local any = false
    local G = _G.C_GossipInfo
    if G and G.GetAvailableQuests then
        local ok, list = pcall(G.GetAvailableQuests)
        if ok and type(list) == "table" then
            any = true
            for _, e in ipairs(list) do
                if type(e) == "table" then
                    if type(e.questID) == "number" then ids[e.questID] = true end
                    if type(e.title) == "string" then titles[e.title] = true end
                end
            end
        end
    end
    -- Quest-Begruessung (alte Form): nur Titel
    if _G.GetNumAvailableQuests and _G.GetAvailableTitle then
        local ok, n = pcall(_G.GetNumAvailableQuests)
        if ok and type(n) == "number" and n > 0 then
            any = true
            for i = 1, n do
                local ok2, t = pcall(_G.GetAvailableTitle, i)
                if ok2 and type(t) == "string" then titles[t] = true end
            end
        end
    end
    return ids, titles, any
end
Avail.ReadOffers = ReadOffers

-- Wer wird gerade angesprochen: kind ("npc"/"object"), id oder nil
local function Interaction()
    local guid = _G.UnitGUID and _G.UnitGUID("npc")
    if guid == nil then return nil end
    local ok, kind, id = pcall(Codex.ParseGUID, guid)
    if ok and kind then return kind, id end
    return nil
end

local function Probe(text)
    if Avail.probe and Now() < Avail.probe then FW:Print("Probe: " .. text) end
end

-- Angebotsliste ausgewertet: ids/titles = was angeboten wird
function Avail.ScanOffers(kind, npcID, ids, titles)
    local V = Codex.V()
    local scanned, blocked, seen = 0, 0, 0
    -- Positiv: angebotene Quests mit Negativ-Beobachtung
    for id in pairs(ids) do
        seen = seen + 1
        Avail.Observed(id)
        Avail.Unblock(id)
    end
    -- Negativ: Quests dieses Gebers, die nach den Daten annehmbar waeren, aber nicht angeboten werden
    if kind and npcID then
        for id, q in pairs(V.quests) do
            local g = q.give
            if type(g) == "table" and g.id == npcID and g.k == kind then
                scanned = scanned + 1
                local title = Codex.QuestTitle(q, id)
                if not ids[id] and not titles[title] and Codex.QuestStatus(id) == nil
                    and not Avail.IsBlocked(id) and Codex.QuestAvailable(id) then
                    if Avail.Block(id, "scan") then blocked = blocked + 1 end
                end
            end
        end
    end
    return seen, scanned, blocked
end

function Avail:OnGossip()
    local ok, err = pcall(function()
        local kind, id = Interaction()
        local ids, titles, any = ReadOffers()
        if not any then
            Probe("Gossip: keine Angebotsliste lesbar")
            return
        end
        local n = 0
        for _ in pairs(ids) do n = n + 1 end
        local t = 0
        for _ in pairs(titles) do t = t + 1 end
        local seen, scanned, blocked = Avail.ScanOffers(kind, id, ids, titles)
        Probe(string.format("Gossip: %s %s, angeboten %d (IDs) / %d (Titel), Quests dieses Gebers in den Daten %d, neu als 'noch nicht moeglich' %d",
            tostring(kind), tostring(id), n, t, scanned, blocked))
    end)
    if not ok then Probe("Fehler: " .. tostring(err)) end
end

function Avail:OnQuestDetail()
    pcall(function()
        local id = tonumber(_G.GetQuestID and _G.GetQuestID())
        if id then
            Avail.Observed(id)
            Avail.Unblock(id)
            Probe("Quest-Angebot " .. id)
        end
    end)
end

function Avail:OnQuestAccepted(a, b)
    pcall(function()
        local id = tonumber(b) or tonumber(a)
        if id then
            Avail.Observed(id)
            Avail.Unblock(id)
        end
    end)
end

function Avail:OnChange()
    pcall(Avail.Release)
end

function Avail.Prune()
    local c = Char(false)
    if not c then return end
    local now = Now()
    for id, neg in pairs(c.neg) do
        if now - (neg.t or 0) > NEG_KEEP then c.neg[id] = nil end
    end
end

function Avail:Start()
    FW:RegisterEvent("GOSSIP_SHOW", self.OnGossip, self)
    FW:RegisterEvent("QUEST_GREETING", self.OnGossip, self)
    FW:RegisterEvent("QUEST_DETAIL", self.OnQuestDetail, self)
    FW:RegisterEvent("QUEST_ACCEPTED", self.OnQuestAccepted, self)
    FW:RegisterEvent("PLAYER_LEVEL_UP", self.OnChange, self)
    FW:RegisterEvent("QUEST_TURNED_IN", self.OnChange, self)
    C_Timer.After(6, function() Avail.Prune() Avail.Release() end)
    -- Antworten auf RequestLoadQuestByID zaehlen (nur fuer den Titel-Test; Ereignis kann fehlen)
    pcall(FW.RegisterEvent, FW, "QUEST_DATA_LOAD_RESULT", function() Avail.loadEvents = (Avail.loadEvents or 0) + 1 end, Avail)
end

------------------------------------------------------------------------
-- Test-Befehl: /fwquestprobe [QuestID]  zeigt, was Forever liefert
------------------------------------------------------------------------

function Avail.RunProbe(id)
    local function Say(t) FW:Print("Probe: " .. t) end
    id = tonumber(id) or 96652
    local G, QL = _G.C_GossipInfo, _G.C_QuestLog
    Say("C_GossipInfo.GetAvailableQuests: " .. tostring(G and G.GetAvailableQuests ~= nil))
    Say("GetNumAvailableQuests / GetAvailableTitle (Begruessung): " .. tostring(_G.GetNumAvailableQuests ~= nil) .. " / " .. tostring(_G.GetAvailableTitle ~= nil))
    Say("C_QuestLog.GetAllCompletedQuestIDs: " .. tostring(QL and QL.GetAllCompletedQuestIDs ~= nil))
    if QL and QL.GetAllCompletedQuestIDs then
        local ok, list = pcall(QL.GetAllCompletedQuestIDs)
        Say("  erledigte Quests laut Spiel: " .. (ok and type(list) == "table" and #list or ("Fehler " .. tostring(list))))
    end
    Say("C_QuestLog.RequestLoadQuestByID: " .. tostring(QL and QL.RequestLoadQuestByID ~= nil) .. ", GetTitleForQuestID: " .. tostring(QL and QL.GetTitleForQuestID ~= nil))
    if QL and QL.GetTitleForQuestID then
        local ok, t = pcall(QL.GetTitleForQuestID, id)
        Say("  Titel zu " .. id .. " sofort: " .. tostring(ok and t))
    end
    if QL and QL.RequestLoadQuestByID then
        local ok, err = pcall(QL.RequestLoadQuestByID, id)
        Say("  RequestLoadQuestByID(" .. id .. "): " .. (ok and "aufgerufen" or tostring(err)))
        C_Timer.After(2, function()
            local ok2, t2 = pcall(QL.GetTitleForQuestID, id)
            Say("  Titel zu " .. id .. " nach 2 s: " .. tostring(ok2 and t2))
        end)
    end
    -- Was verraet das Spiel ueber eine geladene Quest-ID ausser dem Titel? Bekannte Abfragen einzeln versuchen.
    C_Timer.After(3, function()
        local found = 0
        local calls = {
            { "C_QuestLog", "GetQuestDifficultyLevel" }, { "C_QuestLog", "GetQuestTagInfo" }, { "C_QuestLog", "GetQuestType" },
            { "C_QuestLog", "GetSuggestedGroupSize" }, { "C_QuestLog", "IsQuestFlaggedCompleted" }, { "C_QuestLog", "GetQuestObjectives" },
            { "C_QuestLog", "GetLogIndexForQuestID" }, { "C_QuestLog", "IsOnQuest" }, { "C_QuestLog", "IsQuestReplayable" },
            { "C_QuestLog", "GetQuestInfo" }, { "C_QuestLog", "GetZoneStoryInfo" }, { "C_QuestLog", "GetQuestLogRewardMoney" },
            { "C_QuestLog", "GetRequiredMoney" }, { "C_QuestLog", "IsFailed" }, { "C_QuestLog", "ReadyForTurnIn" },
            { "C_QuestLog", "GetQuestDetailsTheme" }, { "C_QuestLog", "IsQuestCalling" }, { "C_QuestLog", "IsQuestTrivial" },
            { "C_QuestLog", "GetQuestLevel" }, { "C_QuestLog", "GetMinLevel" }, { "C_QuestLog", "GetMaxLevel" },
        }
        for _, c in ipairs(calls) do
            local tbl = _G[c[1]]
            local fn = tbl and tbl[c[2]]
            if type(fn) == "function" then
                local ok, a, b = pcall(fn, id)
                local function Str(v)
                    if type(v) == "table" then
                        local parts, n = {}, 0
                        for k, x in pairs(v) do
                            n = n + 1
                            if n > 6 then parts[#parts + 1] = "..." break end
                            parts[#parts + 1] = tostring(k) .. "=" .. tostring(x)
                        end
                        return "{" .. table.concat(parts, ", ") .. "}"
                    end
                    return tostring(v)
                end
                if ok and a ~= nil then
                    found = found + 1
                    Say("  " .. c[2] .. "(" .. id .. ") = " .. Str(a) .. (b ~= nil and (", " .. Str(b)) or ""))
                elseif not ok then
                    Say("  " .. c[2] .. " Fehler: " .. tostring(a))
                end
            end
        end
        Say("  weitere Angaben zur Quest " .. id .. ": " .. found .. " Abfragen mit Ergebnis")
    end)
    Avail.probe = Now() + 300
    Say("Die naechsten 5 Minuten wird bei jedem Gespraech mit einem NPC oder Objekt die Angebotsliste gemeldet.")
    local kind, nid = Interaction()
    if kind then Avail:OnGossip() end
end

------------------------------------------------------------------------
-- Titel-Test: /fwquesttitles [von] [bis]  fragt Quest-Titel beim Server ab (gedrosselt, nur Anzeige, nichts wird gespeichert)
------------------------------------------------------------------------

local SCAN_MAX = 500      -- IDs je Lauf
local SCAN_BATCH = 20     -- Anfragen je Schub
local SCAN_PAUSE = 0.5    -- Sekunden zwischen den Schueben

-- Rueckgabe: Liste { id, title } der gefundenen Titel (nach dem Lauf an callback(list, requested, events))
function Avail.TitleScan(lo, hi, callback)
    local QL = _G.C_QuestLog
    if not (QL and QL.RequestLoadQuestByID and QL.GetTitleForQuestID) then return false, "api" end
    lo, hi = tonumber(lo), tonumber(hi)
    if not (lo and hi) or lo < 1 then return false, "range" end
    if hi < lo then lo, hi = hi, lo end
    if hi - lo + 1 > SCAN_MAX then hi = lo + SCAN_MAX - 1 end
    if Avail.scanning then return false, "busy" end
    Avail.scanning = true
    local events0 = Avail.loadEvents or 0
    local before = {}
    for id = lo, hi do
        local ok, t = pcall(QL.GetTitleForQuestID, id)
        if ok and type(t) == "string" and t ~= "" then before[id] = true end
    end
    local nextID, requested = lo, 0
    local function Step()
        local stop = math.min(nextID + SCAN_BATCH - 1, hi)
        for id = nextID, stop do
            if pcall(QL.RequestLoadQuestByID, id) then requested = requested + 1 end
        end
        nextID = stop + 1
        if nextID <= hi then
            C_Timer.After(SCAN_PAUSE, Step)
        else
            C_Timer.After(3, function()
                local list = {}
                for id = lo, hi do
                    local ok, t = pcall(QL.GetTitleForQuestID, id)
                    if ok and type(t) == "string" and t ~= "" then list[#list + 1] = { id = id, title = t, cached = before[id] or nil } end
                end
                Avail.scanning = false
                Avail.lastScan = { lo = lo, hi = hi, list = list }
                if callback then callback(list, requested, (Avail.loadEvents or 0) - events0, lo, hi) end
            end)
        end
    end
    Step()
    return true, lo, hi
end

SLASH_FREEWOODQUESTTITLES1 = "/fwquesttitles"
SlashCmdList["FREEWOODQUESTTITLES"] = function(msg)
    local a, b = (msg or ""):match("(%d+)%D+(%d+)")
    a, b = tonumber(a), tonumber(b)
    if not a then
        a = tonumber((msg or ""):match("%d+")) or 96600
        b = a + 99
    end
    local ok, lo, hi = Avail.TitleScan(a, b, function(list, requested, events, l, h)
        local V = Codex.V()
        local known, new = 0, 0
        for _, e in ipairs(list) do
            if V.quests[e.id] then known = known + 1 else new = new + 1 end
        end
        FW:Print(string.format("Titel-Test %d-%d: %d Anfragen, %d Antworten (Ereignis %d), davon %d dem Codex schon bekannt, %d neu",
            l, h, requested, #list, events, known, new))
        for i = 1, math.min(#list, 12) do
            local e = list[i]
            FW:Print(string.format("  #%d %s%s", e.id, e.title, V.quests[e.id] and "" or "  (neu)"))
        end
        if #list > 12 then FW:Print("  ... und " .. (#list - 12) .. " weitere") end
    end)
    if not ok then
        FW:Print("Titel-Test nicht moeglich: " .. tostring(lo))
    else
        FW:Print(string.format("Titel-Test %d-%d laeuft (gedrosselt, dauert etwa %d s) ...", lo, hi, math.ceil((hi - lo + 1) / SCAN_BATCH * SCAN_PAUSE) + 3))
    end
end

SLASH_FREEWOODQUESTPROBE1 = "/fwquestprobe"
SlashCmdList["FREEWOODQUESTPROBE"] = function(msg)
    Avail.RunProbe((msg or ""):match("%d+"))
end

-- Markierungen verwalten: /fwblock (Liste), /fwblock <ID> (aufheben), /fwblock alle (alle aufheben)
SLASH_FREEWOODBLOCK1 = "/fwblock"
SlashCmdList["FREEWOODBLOCK"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local L = FW.L
    if msg == "alle" or msg == "all" then
        Avail.ClearAll()
        FW:Print(L.CODEX_AVAIL_CLEARED)
        return
    end
    local id = tonumber(msg:match("%d+"))
    if id then
        Avail.Unblock(id)
        FW:Print(string.format(L.CODEX_AVAIL_UNBLOCKED, id))
        return
    end
    local list = Avail.List()
    FW:Print(string.format(L.CODEX_AVAIL_LIST, #list))
    for _, e in ipairs(list) do
        FW:Print(string.format("  %s (#%d, Stufe %s)", e.title, e.id, tostring(e.lv)))
    end
end
