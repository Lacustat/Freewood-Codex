-- Freewood-Codex: Namen von Kreaturen lernen
--
-- Forever gibt Kreaturennamen im Kampf als "geheime Werte" zurueck. In Instanzen ist fast alles Kampf,
-- darum kannte der Codex dort nur die IDs. Hier werden Namen auf mehreren Wegen gesammelt:
--   target / mouse  Ziel und Mouseover (auch Leichen und noch nicht bekannte Kreaturen)
--   scan            ausserhalb des Kampfes alle paar Sekunden: Ziel, Fokus, Gruppenziele, Namensplaketten
--   plate           Ereignis "Namensplakette erscheint" (falls das Spiel es erlaubt)
--   xp              XP-Meldung "X stirbt ..." mit passendem Ziel
--   pend            XP-Meldung ohne lesbares Ziel: Name wird dem naechsten frisch gelooteten Unbekannten zugeordnet,
--                   aber nur, wenn eindeutig (genau ein Name in den letzten 90 Sekunden)
--   quest           Kill-Ziele von Quests (eigene und fremde), die genau eine Kreatur-ID kennen
--   cache           Name war schon gesehen, bevor die Kreatur einen Datensatz hatte

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end
local Util = FW.Util

local Names = {
    stats = { target = 0, mouse = 0, scan = 0, plate = 0, xp = 0, pend = 0, quest = 0, cache = 0, tip = 0 },
    tipFail = { na = 0, err = 0, none = 0, secret = 0 },
    xpSeen = 0,
    kills = {}, evCount = {}, evSecret = 0, samples = {}, killEvents = {},
    reads = 0, secret = 0, sweeps = 0, plateEvents = 0,
    fail = { existSecret = 0, playerSecret = 0, guidSecret = 0, notNpc = 0, xpSecret = 0 },
    idName = {}, idCount = 0, pending = {}, running = false, plateOk = nil,
}
NS.Names = Names
Codex.Names = Names

local MAX_CACHE = 800
local PENDING_SECS = 90
local SCAN_SECS = 2.5
local QUEST_EVERY = 24   -- Durchlaeufe zwischen zwei Quest-Auswertungen (ca. eine Minute)
local TOKENS = { "target", "focus", "mouseover", "targettarget", "focustarget", "softenemy" }

local function ParseGUID(guid)
    local parse = Codex.ParseGUID
    if parse then
        return parse(guid)
    end
end

local function CleanName(v)
    if Util.IsSecret(v) or type(v) ~= "string" then
        return nil
    end
    v = v:gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then
        return nil
    end
    return v:sub(1, 60)
end

-- Kreatur kennt der Codex schon (eigene oder fremde Daten)?
local function Known(id)
    if Codex.db.units[id] then
        return true
    end
    local v = Codex.V and Codex.V()
    return v and v.units and v.units[id] ~= nil
end

-- Name zu einer Kreatur-ID eintragen. Gibt true zurueck, wenn ein neuer Name gespeichert wurde.
function Names:Learn(id, name, src)
    name = CleanName(name)
    if type(id) ~= "number" or not name then
        return false
    end
    local u = Codex.db.units[id]
    if u and u.n then
        return false
    end
    if not u and self.idName[id] then
        return false
    end
    if u or Known(id) then
        u = u or Codex:Unit(id, true)
        u.n = name
        self.idName[id] = nil
        if src and self.stats[src] then
            self.stats[src] = self.stats[src] + 1
        end
        FW:Fire("CODEX_CHANGED", "unit", id)
        return true
    end
    -- noch kein Datensatz: Name merken, bis die Kreatur gelootet wird
    if not self.idName[id] and self.idCount < MAX_CACHE then
        self.idName[id] = name
        self.idCount = self.idCount + 1
    end
    return false
end

-- Eine Einheit lesen: nur Kreaturen, nur wenn der Name lesbar ist.
-- fail[...] zaehlt, woran es scheitert (nur zur Diagnose): exist, player, guid, npc, name
function Names:Read(unit, src)
    local f = self.fail
    local existsRaw = UnitExists and UnitExists(unit)
    if Util.IsSecret(existsRaw) then
        f.existSecret = f.existSecret + 1
        return
    end
    if not existsRaw then
        return
    end
    local playerRaw = UnitIsPlayer and UnitIsPlayer(unit)
    if Util.IsSecret(playerRaw) then
        f.playerSecret = f.playerSecret + 1
        return
    end
    if playerRaw then
        return
    end
    local guidRaw = UnitGUID and UnitGUID(unit)
    if Util.IsSecret(guidRaw) then
        f.guidSecret = f.guidSecret + 1
        return
    end
    local kind, id = ParseGUID(guidRaw)
    if kind ~= "npc" then
        f.notNpc = f.notNpc + 1
        return
    end
    self.reads = self.reads + 1
    local raw = UnitName and UnitName(unit)
    if Util.IsSecret(raw) then
        self.secret = self.secret + 1
        return
    end
    self:Learn(id, raw, src)
end

local function GroupTokens()
    local list = {}
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if n > 1 then
        local raid = IsInRaid and IsInRaid()
        local prefix, count = raid and "raid" or "party", raid and math.min(n, 40) or math.min(n - 1, 4)
        for i = 1, count do
            list[#list + 1] = prefix .. i .. "target"
        end
    end
    return list
end

-- Alle bekannten Quellen einmal lesen. Im Kampf sind die Namen geheim, dann lohnt es nicht.
function Names:Scan(src)
    src = src or "scan"
    if UnitAffectingCombat and Util.Clean(UnitAffectingCombat("player")) then
        return
    end
    self.sweeps = self.sweeps + 1
    for _, unit in ipairs(TOKENS) do
        self:Read(unit, src)
    end
    for _, unit in ipairs(GroupTokens()) do
        self:Read(unit, src)
    end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists and Util.Clean(UnitExists(unit)) then
            self:Read(unit, "plate")
        end
    end
end

-- Kill-Ziele von Quests mit genau einer bekannten Kreatur-ID
function Names:FromQuests()
    local v = Codex.V and Codex.V()
    if not v or not v.quests then
        return 0
    end
    local learned = 0
    for _, q in pairs(v.quests) do
        for _, ob in ipairs(q.obj or {}) do
            if ob.ty == "monster" and ob.name and type(ob.ids) == "table" then
                local only, count
                count = 0
                for id in pairs(ob.ids) do
                    only = id
                    count = count + 1
                    if count > 1 then
                        break
                    end
                end
                if count == 1 and self:Learn(only, ob.name, "quest") then
                    learned = learned + 1
                end
            end
        end
    end
    return learned
end

-- XP-Meldung: Name einer getoeteten Kreatur ohne lesbares Ziel merken
function Names:NoteKill(name)
    name = CleanName(name)
    if not name then
        return
    end
    local list = self.pending
    list[#list + 1] = { name = name, t = time() }
    while #list > 20 do
        table.remove(list, 1)
    end
end

-- Versuch: Name ueber den Tooltip-Link der Beute-GUID ("unit:<GUID>"). Die GUID aus dem Beutefenster ist lesbar.
function Names:FromTooltip(guid)
    local api = _G.C_TooltipInfo and _G.C_TooltipInfo.GetHyperlink
    if type(api) ~= "function" or type(guid) ~= "string" then
        self.tipFail.na = self.tipFail.na + 1
        return nil
    end
    local ok, data = pcall(api, "unit:" .. guid)
    if not ok then
        self.tipFail.err = self.tipFail.err + 1
        return nil
    end
    if Util.IsSecret(data) then
        self.tipFail.secret = self.tipFail.secret + 1
        return nil
    end
    local line = type(data) == "table" and type(data.lines) == "table" and data.lines[1]
    local text = type(line) == "table" and line.leftText
    if Util.IsSecret(text) then
        self.tipFail.secret = self.tipFail.secret + 1
        return nil
    end
    local name = CleanName(text)
    if not name then
        self.tipFail.none = self.tipFail.none + 1
    end
    return name
end

-- Eine gelootete Kreatur mit bekanntem Namen hat ihre XP-Meldung "verbraucht"
function Names:Consume(name)
    local list = self.pending
    for i = #list, 1, -1 do
        if list[i].name == name then
            table.remove(list, i)
            return
        end
    end
end

-- Frisch gelootete Kreatur ohne Namen: aus Merkzettel oder XP-Meldungen auffuellen
function Names:Resolve(id, ent, guid)
    if type(id) ~= "number" or type(ent) ~= "table" or ent.n then
        return
    end
    local cached = self.idName[id]
    if cached then
        ent.n = cached
        self.idName[id] = nil
        self.stats.cache = self.stats.cache + 1
        return
    end
    local tip = guid and self:FromTooltip(guid)
    if tip then
        ent.n = tip
        self.stats.tip = self.stats.tip + 1
        return
    end
    if (ent.k or 0) > 1 then
        return
    end
    local now, list = time(), self.pending
    for i = #list, 1, -1 do
        if now - list[i].t > PENDING_SECS then
            table.remove(list, i)
        end
    end
    -- nur zuordnen, wenn in den letzten 90 Sekunden genau ein Name gemeldet wurde
    local only
    for _, p in ipairs(list) do
        if only and only ~= p.name then
            return
        end
        only = p.name
    end
    if not only then
        return
    end
    for i = #list, 1, -1 do
        if list[i].name == only then
            table.remove(list, i)
            break
        end
    end
    ent.n = only
    self.stats.pend = self.stats.pend + 1
end

-- Kampflog-Zeilen "Euer Charakter besiegt X." / "X stirbt." als Vorschlaege fuer Namen (nie automatisch zugeordnet)
local KILL_EVENTS = { "CHAT_MSG_COMBAT_HOSTILE_DEATH", "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_PARTY_HITS",
    "CHAT_MSG_COMBAT_MISC_INFO", "CHAT_MSG_COMBAT_PET_HITS" }
local KILL_PATTERNS = {
    "^Euer Charakter besiegt (.+)%.$", "besiegt (.+)%.$", "^Ihr habt (.+) get\195\182tet%.$", "^(.+) stirbt%.$",
    "^You have slain (.+)!$", "^You defeat (.+)%.$", "defeats (.+)%.$", "^(.+) dies%.$",
}

-- Zeile pruefen. Rueckgabe: Name oder nil
function Names.ParseKill(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    for _, pattern in ipairs(KILL_PATTERNS) do
        local name = text:match(pattern)
        if name then
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" and #name <= 80 then
                return name
            end
        end
    end
    return nil
end

function Names:OnKillLine(event, text)
    self.evCount[event] = (self.evCount[event] or 0) + 1
    if Util.IsSecret(text) then
        self.evSecret = self.evSecret + 1
        return
    end
    if type(text) ~= "string" then
        return
    end
    local sample = self.samples[event]
    if not sample then
        sample = {}
        self.samples[event] = sample
    end
    if #sample < 2 then
        sample[#sample + 1] = text:sub(1, 90)
    end
    local name = Names.ParseKill(text)
    if not name then
        return
    end
    local list, now = self.kills, time()
    local last = list[#list]
    if last and last.name == name and now - last.t < 2 then
        return
    end
    list[#list + 1] = { name = name, t = now }
    while #list > 40 do
        table.remove(list, 1)
    end
end

-- Zuletzt besiegte Gegner (neueste zuerst, ohne Doppelte). Pro Eintrag: name, alt (ohne letztes grossgeschriebenes Wort)
function Names:RecentKills(maxAge, limit)
    maxAge, limit = maxAge or 900, limit or 8
    local now, seen, out = time(), {}, {}
    for i = #self.kills, 1, -1 do
        local k = self.kills[i]
        if now - k.t <= maxAge and not seen[k.name] then
            seen[k.name] = true
            local alt
            local head, tail = k.name:match("^(.+)%s+(%S+)$")
            if head and tail:match("^%u") and #head >= 3 then
                alt = head
            end
            out[#out + 1] = { name = k.name, alt = alt, t = k.t }
            if #out >= limit then
                break
            end
        end
    end
    return out
end

local function Tick()
    if not Names.running then
        return
    end
    pcall(Names.Scan, Names, "scan")
    Names.tickCount = (Names.tickCount or 0) + 1
    if Names.tickCount % QUEST_EVERY == 0 then
        pcall(Names.FromQuests, Names)
    end
    C_Timer.After(SCAN_SECS, Tick)
end

function Names:OnRegen()
    C_Timer.After(0.5, function() pcall(Names.Scan, Names, "scan") end)
    C_Timer.After(2.5, function() pcall(Names.Scan, Names, "scan") end)
end

function Names:OnPlate(unit)
    self.plateEvents = self.plateEvents + 1
    if type(unit) == "string" then
        self:Read(unit, "plate")
    end
end

function Names:Start()
    if self.running then
        return
    end
    self.running = true
    FW:RegisterEvent("PLAYER_REGEN_ENABLED", self.OnRegen, self)
    -- das Ereignis kann in gesperrten Situationen verboten sein: Fehler abfangen
    self.plateOk = pcall(FW.RegisterEvent, FW, "NAME_PLATE_UNIT_ADDED", self.OnPlate, self)
    for _, event in ipairs(KILL_EVENTS) do
        self.killEvents[event] = pcall(FW.RegisterEvent, FW, event, function(owner, text)
            Names:OnKillLine(event, text)
        end, Names)
    end
    C_Timer.After(12, function()
        pcall(Names.FromQuests, Names)
    end)
    C_Timer.After(SCAN_SECS, Tick)
end

function Names:Stop()
    self.running = false
    FW:UnregisterEvent("PLAYER_REGEN_ENABLED", self)
    if self.plateOk then
        FW:UnregisterEvent("NAME_PLATE_UNIT_ADDED", self)
    end
    for event, ok in pairs(self.killEvents) do
        if ok then
            FW:UnregisterEvent(event, self)
        end
    end
end

function Names:Debug()
    local total, named = 0, 0
    local v = Codex.V and Codex.V() or Codex.db
    for _, u in pairs(v.units or {}) do
        total = total + 1
        if u.n then
            named = named + 1
        end
    end
    local st = self.stats
    FW:Print(string.format("Codex-Namen: %d Kreaturen, %d mit Namen, %d ohne", total, named, total - named))
    FW:Print(string.format("Neu gelernt ueber: Ziel %d, Mouseover %d, Suche %d, Namensplakette %d, XP-Meldung %d, XP-Zuordnung %d, Quest %d, Merkzettel %d, Tooltip %d",
        st.target, st.mouse, st.scan, st.plate, st.xp, st.pend, st.quest, st.cache, st.tip))
    local tf = self.tipFail
    FW:Print(string.format("XP-Meldungen gesehen %d (davon geheim %d); Tooltip-Weg: nicht vorhanden %d, Fehler %d, geheim %d, ohne Namen %d",
        self.xpSeen, self.fail.xpSecret, tf.na, tf.err, tf.secret, tf.none))
    local evs = {}
    for event, n in pairs(self.evCount) do
        evs[#evs + 1] = event:gsub("^CHAT_MSG_COMBAT_", "") .. "=" .. n
    end
    table.sort(evs)
    FW:Print(string.format("Kampflog-Zeilen: %s (geheim %d); gemerkte Kills %d", #evs > 0 and table.concat(evs, " ") or "keine", self.evSecret, #self.kills))
    for event, list in pairs(self.samples) do
        for _, text in ipairs(list) do
            FW:Print("  Beispiel " .. event:gsub("^CHAT_MSG_COMBAT_", "") .. ": " .. text:gsub("|", "||"))
        end
    end
    local f = self.fail
    FW:Print(string.format("Abbrueche vor dem Namen: Einheit geheim %d, Spieler-Angabe geheim %d, GUID geheim %d, keine Kreatur %d; Instanz: %s",
        f.existSecret, f.playerSecret, f.guidSecret, f.notNpc, tostring(IsInInstance and select(1, IsInInstance()))))
    FW:Print(string.format("Gelesen %d, davon im Kampf geheim %d; Suchdurchlaeufe %d; Namensplaketten-Ereignis %s (%d); Merkzettel %d, offene XP-Namen %d",
        self.reads, self.secret, self.sweeps, self.plateOk and "ok" or "nicht verfuegbar", self.plateEvents, self.idCount, #self.pending))
end
