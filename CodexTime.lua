-- Freewood-Codex: Zeitmessung
--   Kampfdauer (Time to kill): wie lange dauert ein Solo-Kampf gegen einen einzelnen Gegner,
--   je Klasse, Spielerstufe und Stufenabstand (Gegner minus Spieler, -5 bis +5).
--   Quest-Zeit: aktive Spielzeit vom ersten Fortschritt bis zur Abgabebereitschaft, bei mehreren
--   gleichzeitig laufenden Quests gleichmaessig aufgeteilt.
-- Zeiten werden als ganze Zehntelsekunden gespeichert.
--
-- Gespeichert:
--   db.ttk[Klasse][Spielerstufe][Abstand] = { n, sum, min, max }   (Klasse zum Beispiel "WARRIOR")
--   units[npcID].tt[Klasse][Spielerstufe] = { n, sum, min, max }   (nur lokal)
--   quests[id].tm  aufgeteilte aktive Zeit bis fertig, .tr  aktive Zeit bis fertig ohne Aufteilen,
--   quests[id].ta  aktive Zeit bis zur Abgabe
--   db.qtimer[questID] = laufende Zeitnehmer (ueberleben Neustart des Spiels)

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Util = FW.Util

local Time = {}
NS.Time = Time
Codex.Time = Time

local MAX_DELTA = 5
local MIN_KILL, MAX_KILL = 0.5, 120      -- Sekunden
local KILL_END_WINDOW = 8                -- Kampf muss kurz nach dem Kill enden
local MAX_QUEST_SECONDS = 4 * 3600
local TICK = 1

Time.stats = { fights = 0, ok = 0, skip = {}, quests = 0 }

local function Now()
    return GetTime and GetTime() or time()
end

local function Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and FW.Debug then
        FW:Debug("Codex.Time: " .. tostring(err))
    end
    return ok
end

local function Skip(reason)
    Time.stats.skip[reason] = (Time.stats.skip[reason] or 0) + 1
end

local function Sample(tbl, key, value)
    local s = tbl[key]
    if not s then
        s = { n = 0, sum = 0 }
        tbl[key] = s
    end
    s.n = s.n + 1
    s.sum = s.sum + value
    s.min = s.min and math.min(s.min, value) or value
    s.max = s.max and math.max(s.max, value) or value
    return s
end

function Time.PlayerToken()
    local token
    if UnitClass then
        local _, t = UnitClass("player")
        token = t
    end
    if type(token) == "string" and token:match("^%u+$") then
        return token
    end
    return nil
end

-- Klassenname des Spielers in der Spielsprache (fuer Anzeigen)
function Time.ClassName()
    if UnitClass then
        local name = UnitClass("player")
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return Time.PlayerToken() or "?"
end

------------------------------------------------------------------------
-- Kampfdauer
------------------------------------------------------------------------

local fight = nil

local function InGroup()
    return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 1) or false
end

local function InInstance()
    if IsInInstance then
        local inside = IsInInstance()
        return inside and true or false
    end
    return false
end

function Time:NoteTarget()
    if not fight or not fight.ok then
        return
    end
    if not (UnitExists and UnitExists("target")) then
        return
    end
    if UnitCanAttack and not UnitCanAttack("player", "target") then
        return
    end
    local guid = UnitGUID and UnitGUID("target")
    if guid == nil or Util.IsSecret(guid) then
        fight.ok, fight.why = false, "secret"
        return
    end
    if not fight.targets[guid] then
        fight.targets[guid] = true
        fight.nTargets = fight.nTargets + 1
        if fight.nTargets > 1 then
            fight.ok, fight.why = false, "multi"
            return
        end
        local classification = UnitClassification and UnitClassification("target")
        if classification and classification ~= "normal" then
            fight.ok, fight.why = false, "elite"
        end
        local level = UnitLevel and tonumber(UnitLevel("target"))
        if level and level > 0 then
            fight.tl = level   -- Stufe des Gegners, falls der Erfahrungs-Hook sie nicht kennt
        end
    end
end

function Time:OnRegenDisabled()
    Safe(function()
        fight = { start = Now(), targets = {}, nTargets = 0, kills = 0, ok = true }
        if InGroup() then
            fight.ok, fight.why = false, "group"
        elseif InInstance() then
            fight.ok, fight.why = false, "instance"
        end
        Time:NoteTarget()
    end)
end

function Time:OnTargetChanged()
    Safe(Time.NoteTarget, Time)
end

-- vom Erfahrungs-Hook aufgerufen: ein Gegner ist gestorben (pl, ml: Stufen, id: NPC-ID oder nil)
function Time:OnKill(pl, ml, id, classification)
    if not fight then
        return
    end
    fight.kills = fight.kills + 1
    fight.killAt = Now()
    fight.pl, fight.ml, fight.id = pl, ml or fight.ml, id or fight.id
    if classification and classification ~= "normal" and fight.ok then
        fight.ok, fight.why = false, "elite"
    end
end

function Time:Record(token, pl, delta, seconds, id)
    local ds = math.floor(seconds * 10 + 0.5)
    local db = Codex.db
    db.ttk = db.ttk or {}
    db.ttk[token] = db.ttk[token] or {}
    db.ttk[token][pl] = db.ttk[token][pl] or {}
    Sample(db.ttk[token][pl], delta, ds)
    if id then
        local u = Codex:Unit(id, true)
        u.tt = u.tt or {}
        u.tt[token] = u.tt[token] or {}
        Sample(u.tt[token], pl, ds)
    end
    FW:Fire("CODEX_CHANGED", "ttk", pl)
end

function Time:OnRegenEnabled()
    Safe(function()
        local f = fight
        fight = nil
        if not f then
            return
        end
        local st = Time.stats
        st.fights = st.fights + 1
        if not f.ok then
            return Skip(f.why or "other")
        end
        if f.kills ~= 1 then
            return Skip(f.kills == 0 and "nokill" or "kills")
        end
        local seconds = f.killAt - f.start
        if seconds < MIN_KILL then
            return Skip("short")
        end
        if seconds > MAX_KILL then
            return Skip("long")
        end
        if Now() - f.killAt > KILL_END_WINDOW then
            return Skip("late")
        end
        local pl = f.pl or (UnitLevel and tonumber(UnitLevel("player")))
        local ml = f.ml or f.tl
        local delta = ml and pl and (ml - pl)
        if not delta or math.abs(delta) > MAX_DELTA then
            return Skip("range")
        end
        local token = Time.PlayerToken()
        if not token then
            return Skip("class")
        end
        st.ok = st.ok + 1
        Time:Record(token, pl, delta, seconds, f.id)
    end)
end

-- Klassenname zu einem Klassenschluessel ("WARRIOR" -> "Krieger"), sonst der Schluessel selbst
function Time.ClassLabel(token)
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    if type(names) == "table" and type(names[token]) == "string" then
        return names[token]
    end
    return tostring(token)
end

-- Kampfdauer einer Kreatur je Klasse (eigene und geteilte Messungen):
-- Liste { cls, secs, n, own } nach Dauer sortiert, Durchschnitt ueber alle Spielerstufen
function Time.UnitClasses(u)
    local list = {}
    local mine = Time.PlayerToken()
    for cls, byPl in pairs(u and u.tt or {}) do
        local n, sum = 0, 0
        for _, s in pairs(byPl) do
            n = n + (s.n or 0)
            sum = sum + (s.sum or 0)
        end
        if n > 0 then
            list[#list + 1] = { cls = cls, secs = sum / n / 10, n = n, own = cls == mine }
        end
    end
    table.sort(list, function(a, b)
        if a.secs ~= b.secs then return a.secs < b.secs end
        return a.cls < b.cls
    end)
    return list
end

-- Durchschnittliche Kampfdauer (Sekunden, Anzahl) einer Kreatur fuer die eigene Klasse
function Time.UnitAverage(u)
    local token = Time.PlayerToken()
    local byPl = u and u.tt and token and u.tt[token]
    if not byPl then
        return nil
    end
    local n, sum = 0, 0
    for _, s in pairs(byPl) do
        n = n + (s.n or 0)
        sum = sum + (s.sum or 0)
    end
    if n < 1 then
        return nil
    end
    return sum / n / 10, n
end

------------------------------------------------------------------------
-- Quest-Zeit
------------------------------------------------------------------------

local lastTick = nil
local ticker = nil

local function QTimers()
    Codex.db.qtimer = Codex.db.qtimer or {}
    return Codex.db.qtimer
end

local function LogEntries()
    local list = {}
    local count
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        count = C_QuestLog.GetNumQuestLogEntries()
    elseif GetNumQuestLogEntries then
        count = GetNumQuestLogEntries()
    end
    for i = 1, tonumber(count) or 0 do
        local questID, isHeader
        if C_QuestLog and C_QuestLog.GetInfo then
            local info = C_QuestLog.GetInfo(i)
            if type(info) == "table" then
                questID, isHeader = info.questID, info.isHeader
            end
        elseif GetQuestLogTitle then
            local _, _, _, h, _, _, _, id = GetQuestLogTitle(i)
            questID, isHeader = id, h
        end
        if type(questID) == "number" and questID > 0 and not isHeader then
            list[#list + 1] = questID
        end
    end
    return list
end

-- Fortschritt (Summe der erfuellten Ziele) und ob alles erledigt ist
local function Progress(questID)
    local have, finished, count = 0, true, 0
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local objs = C_QuestLog.GetQuestObjectives(questID)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" then
                    count = count + 1
                    have = have + (tonumber(o.numFulfilled) or 0)
                    if not o.finished then finished = false end
                end
            end
        end
    end
    if count == 0 then
        finished = false
    end
    if not finished and C_QuestLog and C_QuestLog.IsComplete then
        local ok, done = pcall(C_QuestLog.IsComplete, questID)
        if ok and done and count > 0 then finished = true end
    end
    return have, finished
end

function Time:ScanQuests()
    Safe(function()
        local timers = QTimers()
        local seen = {}
        for _, questID in ipairs(LogEntries()) do
            seen[questID] = true
            local have, finished = Progress(questID)
            local t = timers[questID]
            if not t then
                -- neu im Log: nur ohne vorhandenen Fortschritt kennen wir den Beginn
                t = { eff = 0, raw = 0, all = 0, have = have, started = false, skip = have > 0 or finished }
                timers[questID] = t
            end
            if not t.skip then
                if have > (t.have or 0) and not t.started then
                    t.started = true
                end
                if finished and t.started and not t.done then
                    t.done = true
                end
            end
            t.have = have
        end
        for questID, t in pairs(timers) do
            if not seen[questID] then
                if t.done then
                    -- fertige Quests kurz behalten: die Abgabe kann nach dem Verlassen des Logs eintreffen
                    t.goneAt = t.goneAt or Now()
                    if Now() - t.goneAt > 60 then timers[questID] = nil end
                else
                    timers[questID] = nil
                end
            end
        end
    end)
end

function Time:Tick()
    Safe(function()
        local now = Now()
        local dt = lastTick and (now - lastTick) or 0
        lastTick = now
        if dt <= 0 or dt > 3 then
            return
        end
        if UnitIsAFK and UnitIsAFK("player") then
            return
        end
        local timers = QTimers()
        local active = 0
        for _, t in pairs(timers) do
            if t.started and not t.done and not t.skip then
                active = active + 1
            end
        end
        for _, t in pairs(timers) do
            if t.started and not t.skip then
                t.all = (t.all or 0) + dt
                if not t.done then
                    t.eff = t.eff + dt / math.max(1, active)
                    t.raw = t.raw + dt
                end
            end
        end
    end)
end

-- Quest abgegeben: Zeiten in die Quest schreiben
function Time:OnTurnedIn(questID)
    Safe(function()
        questID = tonumber(questID)
        local t = questID and QTimers()[questID]
        if not t or t.skip or not t.started then
            if questID then QTimers()[questID] = nil end
            return
        end
        QTimers()[questID] = nil
        if not t.done or t.raw < 1 or t.all > MAX_QUEST_SECONDS then
            return
        end
        local q = Codex:Quest(questID, true)
        local function Add(field, seconds)
            local ds = math.floor(seconds * 10 + 0.5)
            q[field] = q[field] or { n = 0, sum = 0 }
            local s = q[field]
            s.n = s.n + 1
            s.sum = s.sum + ds
            s.min = s.min and math.min(s.min, ds) or ds
            s.max = s.max and math.max(s.max, ds) or ds
        end
        Add("tm", t.eff)
        Add("tr", t.raw)
        Add("ta", t.all)
        Time.stats.quests = Time.stats.quests + 1
        FW:Fire("CODEX_CHANGED", "quest", questID)
    end)
end

function Time:OnQuestLog()
    if self.scanPending then
        return
    end
    self.scanPending = true
    C_Timer.After(0.5, function()
        Time.scanPending = nil
        Time:ScanQuests()
    end)
end

------------------------------------------------------------------------
-- Start / Stop
------------------------------------------------------------------------

function Time:Start()
    FW:RegisterEvent("PLAYER_REGEN_DISABLED", self.OnRegenDisabled, self)
    FW:RegisterEvent("PLAYER_REGEN_ENABLED", self.OnRegenEnabled, self)
    FW:RegisterEvent("PLAYER_TARGET_CHANGED", self.OnTargetChanged, self)
    FW:RegisterEvent("QUEST_LOG_UPDATE", self.OnQuestLog, self)
    FW:RegisterEvent("UNIT_QUEST_LOG_CHANGED", self.OnQuestLog, self)
    FW:RegisterEvent("QUEST_ACCEPTED", self.OnQuestLog, self)
    FW:RegisterEvent("QUEST_TURNED_IN", self.OnTurnedIn, self)
    if not ticker and C_Timer and C_Timer.NewTicker then
        lastTick = Now()
        ticker = C_Timer.NewTicker(TICK, function() Time:Tick() end)
    end
    C_Timer.After(4, function() Time:ScanQuests() end)
end

function Time:Stop()
    for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED",
        "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "QUEST_ACCEPTED", "QUEST_TURNED_IN" }) do
        FW:UnregisterEvent(event, self)
    end
    if ticker and ticker.Cancel then
        ticker:Cancel()
    end
    ticker = nil
    fight = nil
end

function Time:Debug()
    local st = self.stats
    local n = 0
    for _, byPl in pairs(Codex.db.ttk or {}) do
        for _, byDelta in pairs(byPl) do
            for _ in pairs(byDelta) do n = n + 1 end
        end
    end
    local reasons = {}
    for k, v in pairs(st.skip) do reasons[#reasons + 1] = k .. "=" .. v end
    table.sort(reasons)
    local active, running = 0, 0
    for _, t in pairs(QTimers()) do
        running = running + 1
        if t.started and not t.done and not t.skip then active = active + 1 end
    end
    FW:Print(string.format("Zeit: Kaempfe %d, gewertet %d, Messreihen %d, uebersprungen: %s", st.fights, st.ok, n,
        #reasons > 0 and table.concat(reasons, " ") or "-"))
    FW:Print(string.format("Quest-Zeit: Zeitnehmer %d, davon aktiv %d, gespeicherte Abgaben %d", running, active, st.quests))
end
