-- Freewood-Codex: Daten mit anderen Spielern teilen (Addon-Nachrichten)
--
-- EIN Schalter (db.settings.share). Eingeschaltet wird ueber Gilde, Gruppe, Schlachtzug und einen
-- geheimen Kanal ("FreewoodCodex", aus allen Chatfenstern ausgeblendet) gerufen und getauscht.
-- Gesendet werden nur eigene Beobachtungen, keine Charakternamen, keine persoenlichen Angaben.
--
-- Ablauf (alles "ziehen", nie ungefragt grosse Datenmengen schieben):
--   H  Hallo mit Anzahl und Pruefwert der eigenen Datensaetze (Kanal)
--   A  Ankuendigung geaenderter Datensaetze  schluessel:stand,... (Kanal)
--   Q  Anfrage nach dem Verzeichnis ab einem Stand (Fluestern)
--   V  Verzeichnis schluessel:stand,... in Stuecken (Fluestern)
--   R  Anfrage nach bestimmten Datensaetzen (Fluestern)
--   B  Datensatz in Stuecken (Fluestern)
-- Empfangenes wird streng geprueft (Share.Sanitize) und getrennt je Absender gespeichert.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
local Share = NS and NS.Share
if not FW or not Codex or not Share then
    return
end

local Sync = { started = false }
NS.Sync = Sync
Codex.Sync = Sync

local PREFIX = "FWCodex1"
local GLOBAL_CHANNEL = "FreewoodCodex"
local MAXLEN = 230
local SEND_INTERVAL = 0.25      -- Takt des Zeitgebers
local MIN_INTERVAL = 3          -- kleinster Abstand zwischen zwei Nachrichten (Sekunden)
local MAX_INTERVAL = 6
local GLOBAL_INTERVAL = 1.5
local MAX_QUEUE = 500
local MAX_CHUNKS = 40
local MAX_BUFFERS = 6
local SESSION_TTL = 600
local DIGEST_COOLDOWN = 60        -- ein Partner darf unser Verzeichnis jede Minute holen
local SERVE_WINDOW = 300
local MAX_SERVE = 150             -- Datensaetze je Partner und Zeitraum
local MAX_REQUEST = 50            -- Datensaetze je Abgleich
local MAX_DIGEST = 400
local MAX_SESSIONS_HOUR = 12
local MAX_RECEIVED_HOUR = 400
local ANNOUNCE_EVERY = 60
local ANNOUNCE_MIN = 300
local SCAN_EVERY = 300
local KINDS = { "guild", "party", "raid", "global" }

local state = {
    queue = {},
    peers = {},        -- [name] = { kind, t, hash, count, queried }
    sessions = {},     -- [name] = { t, digest, got }
    served = {},       -- [name] = { t, count, dirT }
    buffers = {},      -- [name:key] = { t, n, parts, got }
    received = {},     -- [name] = { t, count }
    pending = {},      -- [key] = true: zu verkuendende Datensaetze
    announced = {},    -- [key] = zeitpunkt
    sessionLog = {},
    lastGlobalSend = 0,
    rawNames = {},
    routes = {},            -- [name] = Art des Kanals, ueber den wir ihn zuletzt gehoert haben
    served_partners = {},   -- [name] = zeitpunkt der ersten Bedienung in der Stunde
    lastReply = 0,
    interval = MIN_INTERVAL,
    nextSend = 0,
    log = false,
    status = { global = "off" },
    stats = { txType = {}, rxType = {}, throttled = 0, fail = 0, lastResult = "-", rx = 0, tx = 0, hello = 0, helloIn = 0, queries = 0, served = 0, rejected = 0, byChannel = {} },
}
Sync.state = state

local function Now()
    return (GetTime and GetTime()) or time()
end

local function Store()
    return Share.Store()
end

function Sync:IsEnabled()
    return Codex.db ~= nil and Codex.db.settings ~= nil and Codex.db.settings.share == true
end

------------------------------------------------------------------------
-- Kleine Helfer
------------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function ToB36(n)
    n = math.floor(n or 0)
    if n <= 0 then
        return "0"
    end
    local out = ""
    while n > 0 do
        local r = n % 36
        out = B36:sub(r + 1, r + 1) .. out
        n = (n - r) / 36
    end
    return out
end

local function FromB36(s)
    if type(s) ~= "string" or s == "" or #s > 8 or s:find("[^0-9a-z]") then
        return nil
    end
    local n = 0
    for i = 1, #s do
        n = n * 36 + (B36:find(s:sub(i, i), 1, true) - 1)
    end
    return n
end

local function Clean(sender)
    if type(sender) ~= "string" then
        return nil
    end
    if Ambiguate then
        local ok, v = pcall(Ambiguate, sender, "none")
        if ok and v then
            return v
        end
    end
    return sender
end

local function KeyOf(sender)
    local c = Clean(sender)
    return c and c:lower() or nil
end

-- Name ohne Realm, ohne Leerzeichen (auch geschuetzte), kleingeschrieben; Namen koennen Leerzeichen enthalten
local function NameCore(s)
    if type(s) ~= "string" then
        return ""
    end
    s = s:gsub("\194\160", " "):match("^([^%-]*)") or s
    s = s:gsub("%s", ""):lower()
    return s
end

-- Eigene Namen: alle Schreibweisen, die das Spiel liefert, plus Namen, die wir als Echo unserer eigenen Nachrichten erkannt haben
local learnedSelf = {}
local SESSION_NONCE = string.format("%06d", math.random(0, 999999)) .. string.format("%03d", math.random(0, 999))
local function SelfCores()
    local out = {}
    local function add(v)
        local c = NameCore(v)
        if c ~= "" then
            out[c] = true
        end
    end
    if UnitName then
        add((UnitName("player")))
    end
    if UnitFullName then
        local ok, n = pcall(UnitFullName, "player")
        if ok then add(n) end
    end
    if GetUnitName then
        local ok, n = pcall(GetUnitName, "player", false)
        if ok then add(n) end
    end
    for c in pairs(learnedSelf) do
        out[c] = true
    end
    return out
end

local function IsSelf(sender)
    if type(sender) ~= "string" then
        return false
    end
    local c = NameCore(sender)
    return c ~= "" and SelfCores()[c] == true
end

local function GetEncoder()
    local E = _G.C_EncodingUtil
    if E and E.SerializeCBOR and E.DeserializeCBOR and E.CompressString
        and E.DecompressString and E.EncodeBase64 and E.DecodeBase64 then
        return E
    end
    return nil
end

local function EncodeRecord(rec)
    local E = GetEncoder()
    if not E then
        return nil
    end
    local ok, cbor = pcall(E.SerializeCBOR, rec)
    if not ok or type(cbor) ~= "string" then
        return nil
    end
    local ok2, packed = pcall(E.CompressString, cbor)
    if not ok2 or type(packed) ~= "string" then
        return nil
    end
    local ok3, body = pcall(E.EncodeBase64, packed)
    if not ok3 or type(body) ~= "string" then
        return nil
    end
    return body
end

local function DecodeRecord(body)
    local E = GetEncoder()
    if not E or type(body) ~= "string" or body:find("[^%w%+/=]") then
        return nil
    end
    local ok, packed = pcall(E.DecodeBase64, body)
    if not ok or type(packed) ~= "string" then
        return nil
    end
    local ok2, cbor = pcall(E.DecompressString, packed)
    if not ok2 or type(cbor) ~= "string" then
        return nil
    end
    local ok3, rec = pcall(E.DeserializeCBOR, cbor)
    if not ok3 or type(rec) ~= "table" then
        return nil
    end
    if FW.Export and FW.Export.CheckStructure and not FW.Export.CheckStructure(rec) then
        return nil
    end
    return rec
end

------------------------------------------------------------------------
-- Senden mit Warteschlange
------------------------------------------------------------------------

local function Log(arrow, where, who, text)
    if state.log then
        FW:Print(string.format("|cff88ccffCodex %s|r %s%s %s", arrow, where or "?", who and (" " .. tostring(who):gsub("|", "||")) or "", ((text or ""):sub(1, 110):gsub("|", "||"))))
    end
end

-- Rueckgabe: gesendet, gebremst (das Spiel hat die Nachricht wegen zu hoher Rate abgelehnt)
local function Raw(dist, target, text)
    local api = _G.C_ChatInfo
    if api and api.SendAddonMessage then
        local ok, res = pcall(api.SendAddonMessage, PREFIX, text, dist, target)
        state.stats.lastResult = tostring(ok and res or "Fehler")
        if ok and res ~= false and (type(res) ~= "number" or res == 0) then
            state.stats.tx = state.stats.tx + 1
            local t = text:sub(1, 1)
            state.stats.txType[t] = (state.stats.txType[t] or 0) + 1
            Log("->", dist .. (target and ("#" .. tostring(target)) or ""), nil, text)
            return true, false
        end
        if ok and (res == 3 or res == 8) then
            state.stats.throttled = state.stats.throttled + 1
            Log("!!", "gebremst", nil, text)
            return false, true
        end
        state.stats.fail = state.stats.fail + 1
        return false, false
    end
    return false, false
end

local function Enqueue(item)
    local q = state.queue
    if #q >= MAX_QUEUE then
        for i = 1, #q do
            local t = q[i].text:sub(1, 1)
            if t == "H" or t == "A" then
                table.remove(q, i)
                break
            end
        end
        if #q >= MAX_QUEUE then
            return false
        end
    end
    q[#q + 1] = item
    return true
end

function Sync:Pump()
    local q = state.queue
    if #q == 0 then
        return false
    end
    local now = Now()
    if now < state.nextSend then
        return false
    end
    for i = 1, #q do
        local item = q[i]
        if not (item.dist == "CHANNEL" and now - state.lastGlobalSend < GLOBAL_INTERVAL) then
            table.remove(q, i)
            if item.dist == "CHANNEL" then
                state.lastGlobalSend = now
            end
            local sent, throttled = Raw(item.dist, item.target, item.text)
            if throttled then
                -- zu schnell: Nachricht behalten, Abstand vergroessern
                item.tries = (item.tries or 0) + 1
                if item.tries <= 8 then
                    table.insert(q, 1, item)
                end
                state.interval = math.min(MAX_INTERVAL, state.interval * 1.6)
            else
                state.interval = math.max(MIN_INTERVAL, state.interval * 0.95)
            end
            state.nextSend = now + state.interval
            return true
        end
    end
    return false
end

-- Antwort an einen Spieler: ueber denselben Kanal, auf dem wir ihn gehoert haben, mit seinem Namen
-- als Empfaenger in der Nachricht (andere ignorieren sie). Fluestern gibt es bewusst nicht.
local function Reply(key, text)
    local kind = state.routes[key] or (state.peers[key] and state.peers[key].kind)
    if not kind then
        return false
    end
    local dist, target = Sync:Distribution(kind)
    if not dist then
        return false
    end
    local who = state.rawNames[key] or key
    return Enqueue({ dist = dist, target = target, text = text:sub(1, 1) .. "|" .. who .. text:sub(2) })
end

local function InstanceGroup()
    return _G.LE_PARTY_CATEGORY_INSTANCE and IsInGroup and IsInGroup(_G.LE_PARTY_CATEGORY_INSTANCE)
end

function Sync:Distribution(kind)
    if kind == "guild" then
        if IsInGuild and IsInGuild() then
            return "GUILD"
        end
    elseif kind == "party" then
        if InstanceGroup() then
            return "INSTANCE_CHAT"
        end
        if IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid()) then
            return "PARTY"
        end
    elseif kind == "raid" then
        if IsInRaid and IsInRaid() then
            if InstanceGroup() then
                return "INSTANCE_CHAT"
            end
            return "RAID"
        end
    elseif kind == "global" then
        if GetChannelName then
            local id = GetChannelName(GLOBAL_CHANNEL)
            if type(id) == "number" and id > 0 then
                return "CHANNEL", id
            end
        end
    end
    return nil
end

local function Broadcast(text)
    local used, sent = {}, 0
    for _, kind in ipairs(KINDS) do
        local dist, target = Sync:Distribution(kind)
        if dist then
            local key = dist .. tostring(target or "")
            if not used[key] then
                used[key] = true
                Enqueue({ dist = dist, target = target, text = text })
                sent = sent + 1
            end
        end
    end
    return sent
end

------------------------------------------------------------------------
-- Hallo und Ankuendigungen
------------------------------------------------------------------------

-- Eigentuemer: Berechtigungsliste an alle schicken (hoechstens alle 5 Minuten, force = sofort)
local lastTrustSend = 0
function Sync:SendTrust(force)
    if not self:IsEnabled() or not Codex.Trust or not Codex.Trust.IsSelfOwner() then
        return false
    end
    if not force and Now() - lastTrustSend < 300 then
        return false
    end
    lastTrustSend = Now()
    local sent = 0
    for _, line in ipairs(Codex.Trust.Chunks()) do
        sent = sent + Broadcast(line)
    end
    return sent > 0
end

function Sync:SendHello()
    if not self:IsEnabled() then
        return false
    end
    local n, h = Share.Summary()
    state.stats.hello = state.stats.hello + 1
    if next(learnedSelf) == nil then
        Broadcast("E|" .. SESSION_NONCE)
    end
    return Broadcast(string.format("H|%d|%d", h, n)) > 0
end

local function SessionAllowed()
    local now = Now()
    local log = state.sessionLog
    for i = #log, 1, -1 do
        if now - log[i] > 3600 then
            table.remove(log, i)
        end
    end
    return #log < MAX_SESSIONS_HOUR
end

function Sync:QueueAnnounce(key)
    if self:IsEnabled() and type(key) == "string" then
        state.pending[key] = true
    end
end

function Sync:OnChanged(kind, id)
    if not self:IsEnabled() then
        return
    end
    local key, _, changed = Share.StampOne(kind, id)
    if key and changed then
        self:QueueAnnounce(key)
    end
end

function Sync:FlushAnnounce()
    if not self:IsEnabled() then
        state.pending = {}
        return 0
    end
    local now = Now()
    local keys = {}
    for key in pairs(state.pending) do
        if now - (state.announced[key] or 0) >= ANNOUNCE_MIN then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    local parts, count = {}, 0
    local function flush()
        if #parts > 0 then
            Broadcast("A|" .. table.concat(parts, ","))
            parts = {}
        end
    end
    for _, key in ipairs(keys) do
        state.pending[key] = nil
        local upd = Share.OwnUpd(key)
        if upd then
            state.announced[key] = now
            parts[#parts + 1] = string.format("%s:%s", key, ToB36(upd))
            count = count + 1
            if #parts >= 12 then
                flush()
            end
        end
    end
    flush()
    return count
end

-- Eigene Daten in Abstaenden durchsehen (erfasst auch Aenderungen ohne Ereignis)
function Sync:ScanOwn()
    if not self:IsEnabled() then
        return
    end
    local _, _, _, changed = Share.Scan(true)
    for _, key in ipairs(changed) do
        state.pending[key] = true
    end
end

------------------------------------------------------------------------
-- Verzeichnis und Datensaetze
------------------------------------------------------------------------

local function PackList(prefix, entries)
    local msgs, current, len = {}, {}, 0
    for _, e in ipairs(entries) do
        local add = #e + 1
        if len + add > MAXLEN - 12 and #current > 0 then
            msgs[#msgs + 1] = table.concat(current, ",")
            current, len = {}, 0
        end
        current[#current + 1] = e
        len = len + add
    end
    if #current > 0 then
        msgs[#msgs + 1] = table.concat(current, ",")
    end
    local out = {}
    for i, body in ipairs(msgs) do
        out[i] = string.format("%s|%d/%d|%s", prefix, i, #msgs, body)
    end
    return out
end

local function ParseEntries(body)
    local out = {}
    if type(body) ~= "string" then
        return out
    end
    for key, upd in body:gmatch("([uoqixtpzgh]%d+):([0-9a-z]+)") do
        local nupd = FromB36(upd)
        if nupd and nupd > 0 and #key <= 12 and #out < MAX_DIGEST then
            out[#out + 1] = { key = key, upd = nupd }
        end
    end
    return out
end

-- Jeder darf Daten holen (es sind nur oeffentliche Spieldaten), aber nur wenige Partner je Stunde
function Sync:MayServe(name)
    local now = Now()
    local list = state.served_partners
    if list[name] and now - list[name] < 3600 then
        return true
    end
    local count = 0
    for key, t in pairs(list) do
        if now - t >= 3600 then
            list[key] = nil
        else
            count = count + 1
        end
    end
    if count >= 30 then
        state.stats.rejected = state.stats.rejected + 1
        return false
    end
    list[name] = now
    return true
end

function Sync:SendDigest(name, since)
    local dir = Share.Directory(since, MAX_DIGEST)
    local flat = {}
    for _, e in ipairs(dir) do
        flat[#flat + 1] = string.format("%s:%s", e.key, ToB36(e.upd))
    end
    for _, msg in ipairs(PackList("V", flat)) do
        Reply(name, msg)
    end
    if #flat == 0 then
        Reply(name, "V|1/1|")
    end
    return #flat
end

-- Welche Datensaetze aus einer Liste fehlen uns (neuer Stand)? Aelteste zuerst.
local function Missing(name, entries)
    local need = {}
    for _, e in ipairs(entries) do
        local have = Share.HaveRemote(name, e.key)
        if not have or have < e.upd then
            need[#need + 1] = e
        end
    end
    table.sort(need, function(a, b)
        if a.upd ~= b.upd then
            return a.upd < b.upd
        end
        return a.key < b.key
    end)
    return need
end

function Sync:SendRequest(name, need)
    local ids = {}
    for i, e in ipairs(need) do
        if i > MAX_REQUEST then
            break
        end
        ids[#ids + 1] = string.format("%s:%s", e.key, ToB36(e.upd))
    end
    if #ids == 0 then
        return 0
    end
    for _, msg in ipairs(PackList("R", ids)) do
        Reply(name, msg)
    end
    state.sessions[name] = state.sessions[name] or { t = Now() }
    state.sessions[name].t = Now()
    return #ids
end

function Sync:ServeRecords(name, entries)
    local now = Now()
    local s = state.served[name]
    if not s then
        s = { t = now, count = 0 }
        state.served[name] = s
    elseif now - s.t > SERVE_WINDOW then
        s.t, s.count = now, 0
    end
    local sent = 0
    for _, e in ipairs(entries) do
        if s.count >= MAX_SERVE then
            break
        end
        local rec, upd = Share.OwnRecord(e.key)
        if rec then
            local body = EncodeRecord(rec)
            local who = state.rawNames[name] or name
            local size = MAXLEN - (2 + #who + 1 + #e.key + 1 + 8 + 1 + 8)
            local n = body and math.ceil(#body / size) or 0
            -- zu grosse Datensaetze (viele Waren/Lehrstoff) schrittweise verkleinern, statt sie zu verlieren
            local tries = 0
            while body and n > MAX_CHUNKS and tries < 5 do
                tries = tries + 1
                rec = Share.Shrink(rec)
                body = rec and EncodeRecord(rec) or nil
                n = body and math.ceil(#body / size) or 0
            end
            if body and n >= 1 and n <= MAX_CHUNKS then
                for i = 1, n do
                    local piece = body:sub((i - 1) * size + 1, i * size)
                    Reply(name, string.format("B|%s|%s|%d/%d|%s", e.key, ToB36(upd), i, n, piece))
                end
                s.count = s.count + 1
                sent = sent + 1
                Store().sent = (Store().sent or 0) + 1
            end
        end
    end
    return sent
end

local function ReceivedAllowed(name)
    local now = Now()
    local r = state.received[name]
    if not r or now - r.t > 3600 then
        r = { t = now, count = 0 }
        state.received[name] = r
    end
    return r.count < MAX_RECEIVED_HOUR, r
end

function Sync:ReceiveChunk(name, key, upd, i, n, piece)
    local sess = state.sessions[name]
    if not sess or Now() - sess.t > SESSION_TTL then
        return false
    end
    if not key or not upd or not i or not n or n < 1 or n > MAX_CHUNKS or i < 1 or i > n or #piece > MAXLEN then
        return false
    end
    local bkey = name .. ":" .. key
    local buf = state.buffers[bkey]
    if not buf then
        local count = 0
        for _ in pairs(state.buffers) do
            count = count + 1
        end
        if count >= MAX_BUFFERS then
            return false
        end
        buf = { t = Now(), n = n, parts = {}, got = 0 }
        state.buffers[bkey] = buf
    end
    if buf.n ~= n then
        state.buffers[bkey] = nil
        return false
    end
    if not buf.parts[i] then
        buf.parts[i] = piece
        buf.got = buf.got + 1
    end
    if buf.got < n then
        return true
    end
    state.buffers[bkey] = nil
    local ok, r = ReceivedAllowed(name)
    if not ok then
        return false
    end
    r.count = r.count + 1
    local raw = DecodeRecord(table.concat(buf.parts))
    local rec = raw and Share.Sanitize(key, raw, upd)
    if not rec then
        return false
    end
    if Share.StoreRecord(name, rec) then
        local store = Store()
        store.received = (store.received or 0) + 1
        store.lastReceived = time()
        FW:Fire("CODEX_SYNC_CHANGED")
    end
    return true
end

------------------------------------------------------------------------
-- Empfang
------------------------------------------------------------------------

local function KindOf(channel)
    if channel == "GUILD" then
        return "guild"
    elseif channel == "PARTY" then
        return "party"
    elseif channel == "RAID" then
        return "raid"
    elseif channel == "INSTANCE_CHAT" then
        return "party"
    elseif channel == "CHANNEL" then
        return "global"
    end
    return nil
end

function Sync:HandleMessage(channel, sender, text)
    if not self:IsEnabled() then
        return false
    end
    if type(text) ~= "string" or #text < 3 or #text > 255 then
        return false
    end
    if type(sender) ~= "string" or sender == "" or IsSelf(sender) then
        return false
    end
    local name = KeyOf(sender)
    if not name or name == "" or name:sub(1, 1) == "~" then
        return false
    end
    state.stats.rx = state.stats.rx + 1
    state.stats.byChannel[channel] = (state.stats.byChannel[channel] or 0) + 1
    state.rawNames[name] = sender
    local t = text:sub(1, 1)
    local body = text:sub(3)
    local kind = KindOf(channel)
    if kind and (t == "H" or t == "A") then
        state.routes[name] = kind
    end

    -- Berechtigungsliste vom Eigentuemer (wird nur von Eigentuemern uebernommen)
    if t == "T" and kind then
        if Codex.Trust then Codex.Trust.Receive(sender, body) end
        return true
    end
    if kind then
        if t == "H" then
            local h, n = body:match("^(%d+)|(%d+)$")
            h, n = tonumber(h), tonumber(n)
            if not h or not n then
                return false
            end
            state.stats.helloIn = state.stats.helloIn + 1
            local peer = state.peers[name] or {}
            local newcomer = not state.peers[name] or Now() - state.peers[name].t > 600
            local known = Share.Sender(name, false)
            state.peers[name] = { kind = kind, t = Now(), hash = h, count = n, queried = peer.queried }
            -- Neuling gruesst zurueck: einmal antworten, damit er unsere Daten auch bekommt
            if newcomer and Codex.Trust and Codex.Trust.IsSelfOwner() then
                C_Timer.After(5 + math.random() * 10, function() Sync:SendTrust() end)
            end
            if newcomer and Now() - state.lastReply > 60 then
                state.lastReply = Now()
                C_Timer.After(3 + math.random() * 5, function()
                    Sync:SendHello()
                end)
            end
            -- eine Anfrage gilt 10 Minuten, ohne Antwort schon nach 90 Sekunden nicht mehr
            local sess = state.sessions[name]
            local window = (sess and (sess.got or 0) == 0) and 90 or 600
            if n > 0 and not (known and known.hash == h) and not (peer.queried and Now() - peer.queried < window) and SessionAllowed() then
                local active = 0
                for _, s in pairs(state.sessions) do
                    if Now() - s.t < 120 and s.digest then
                        active = active + 1
                    end
                end
                if active < 2 then
                    state.peers[name].queried = Now()
                    state.sessionLog[#state.sessionLog + 1] = Now()
                    state.sessions[name] = { t = Now(), digest = {}, got = 0 }
                    local since = known and known.cursor or 0
                    Reply(name, "Q|" .. ToB36(since))
                end
            end
            return true
        elseif t == "A" then
            state.peers[name] = {
                kind = kind, t = Now(), hash = (state.peers[name] or {}).hash, queried = (state.peers[name] or {}).queried,
            }
            local need = Missing(name, ParseEntries(body))
            if #need > 0 and #need <= 12 then
                self:SendRequest(name, need)
            end
            return true
        elseif t == "Q" or t == "V" or t == "R" or t == "B" then
            local target, rest = body:match("^([^|]+)|(.*)$")
            if not target or not IsSelf(target) then
                return false
            end
            state.routes[name] = kind
            return self:HandleDirect(name, t, rest)
        end
        return false
    end
    return false
end

-- Nachrichten an uns persoenlich (Q, V, R, B): name = Absender, t = Art, body = Inhalt
function Sync:HandleDirect(name, t, body)
    if t == "Q" then
        -- nur Partner bedienen, die uns ueber einen Kanal gerufen haben
        if not self:MayServe(name) then
            return false
        end
        state.stats.queries = state.stats.queries + 1
        local s = state.served[name]
        if s and s.dirT and Now() - s.dirT < DIGEST_COOLDOWN then
            return false
        end
        if not s then
            s = { t = Now(), count = 0 }
            state.served[name] = s
        end
        s.dirT = Now()
        self:SendDigest(name, FromB36(body) or 0)
        return true
    elseif t == "V" then
        local sess = state.sessions[name]
        if not sess or not sess.digest or Now() - sess.t > SESSION_TTL then
            return false
        end
        local i, n, list = body:match("^(%d+)/(%d+)|(.*)$")
        i, n = tonumber(i), tonumber(n)
        if not i or not n or n < 1 or n > 30 or i < 1 or i > n then
            return false
        end
        for _, e in ipairs(ParseEntries(list)) do
            if #sess.digest < MAX_DIGEST then
                sess.digest[#sess.digest + 1] = e
            end
        end
        sess.got = (sess.got or 0) + 1
        if sess.got >= n then
            local digest = sess.digest
            sess.digest = nil
            table.sort(digest, function(a, b)
                if a.upd ~= b.upd then return a.upd < b.upd end
                return a.key < b.key
            end)
            local need = Missing(name, digest)
            local first = {}
            for idx = 1, math.min(#need, MAX_REQUEST) do
                first[idx] = need[idx]
            end
            self:SendRequest(name, first)
            -- Fortschritt merken: alles bis zum letzten angefragten Stand gilt als abgeholt
            local sender = Share.Sender(name, true)
            local mark
            if #need > MAX_REQUEST then
                mark = first[#first].upd
            elseif #digest >= MAX_DIGEST then
                mark = digest[#digest].upd
            else
                mark = nil
            end
            if mark then
                sender.cursor = math.max(sender.cursor or 0, mark)
                -- der Rest wird beim naechsten Hallo geholt
                if state.peers[name] then
                    state.peers[name].queried = nil
                end
            else
                if #digest > 0 then
                    sender.cursor = math.max(sender.cursor or 0, digest[#digest].upd)
                end
                sender.hash = state.peers[name] and state.peers[name].hash or sender.hash
            end
        end
        return true
    elseif t == "R" then
        if not self:MayServe(name) then
            return false
        end
        local _, _, list = body:match("^(%d+)/(%d+)|(.*)$")
        self:ServeRecords(name, ParseEntries(list))
        return true
    elseif t == "B" then
        local key, upd, i, n, piece = body:match("^([uoqixtpzgh]%d+)|([0-9a-z]+)|(%d+)/(%d+)|(.+)$")
        return self:ReceiveChunk(name, key, FromB36(upd), tonumber(i), tonumber(n), piece)
    end
    return false
end

------------------------------------------------------------------------
-- Geheimer Kanal
------------------------------------------------------------------------

function Sync:JoinGlobal()
    if not self:IsEnabled() then
        return
    end
    local id = GetChannelName and GetChannelName(GLOBAL_CHANNEL)
    if type(id) == "number" and id > 0 then
        state.status.global = "ok"
        return
    end
    if type(JoinChannelByName) ~= "function" then
        state.status.global = "unavailable"
        return
    end
    local ok = pcall(JoinChannelByName, GLOBAL_CHANNEL)
    if not ok then
        state.status.global = "failed"
        return
    end
    if type(ChatFrame_RemoveChannel) == "function" then
        for i = 1, (_G.NUM_CHAT_WINDOWS or 10) do
            local frame = _G["ChatFrame" .. i]
            if frame then
                pcall(ChatFrame_RemoveChannel, frame, GLOBAL_CHANNEL)
            end
        end
    end
    state.status.global = "joining"
    C_Timer.After(3, function()
        local cid = GetChannelName and GetChannelName(GLOBAL_CHANNEL)
        state.status.global = (type(cid) == "number" and cid > 0) and "ok" or "failed"
        if state.status.global == "ok" and Sync:IsEnabled() then
            Sync:SendHello()
        end
        FW:Fire("CODEX_SYNC_CHANGED")
    end)
end

function Sync:LeaveGlobal()
    if type(LeaveChannelByName) == "function" then
        pcall(LeaveChannelByName, GLOBAL_CHANNEL)
    end
    state.status.global = "off"
end

function Sync:SetEnabled(on)
    Codex.db.settings.share = on and true or false
    if on then
        self:Start()
        self:JoinGlobal()
        C_Timer.After(2 + math.random() * 3, function()
            Sync:ScanOwn()
            Sync:SendHello()
        end)
    else
        self:LeaveGlobal()
        self:Stop()
    end
    FW:Fire("CODEX_SYNC_CHANGED")
end

------------------------------------------------------------------------
-- Start / Stopp und Zeitgeber
------------------------------------------------------------------------

local generation = 0

local function Loop(gen, delay, fn)
    C_Timer.After(delay, function()
        if not Sync.started or gen ~= generation then
            return
        end
        fn()
        Loop(gen, delay, fn)
    end)
end

function Sync:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX then
        return
    end
    if type(text) == "string" then
        local t = text:sub(1, 1)
        state.stats.rxType[t] = (state.stats.rxType[t] or 0) + 1
    end
    Log("<-", tostring(channel), tostring(sender), tostring(text))
    -- Probe: "E|<Nummer>" mit unserer Sitzungsnummer. Kommt sie zurueck, ist der Absender wir selbst
    -- (so erfahren wir, unter welchem Namen uns die anderen sehen, auch mit Nachnamen)
    if type(text) == "string" and text:sub(1, 2) == "E|" then
        if text == "E|" .. SESSION_NONCE and type(sender) == "string" then
            local c = NameCore(sender)
            if c ~= "" and not learnedSelf[c] then
                learnedSelf[c] = true
                Log("ii", "eigener Name erkannt", sender, "")
            end
        end
        return
    end
    self:HandleMessage(channel, sender, text)
end

local groupHelloAt = 0
function Sync:OnGroupChanged()
    if not self:IsEnabled() or Now() - groupHelloAt < 120 then
        return
    end
    groupHelloAt = Now()
    C_Timer.After(8, function()
        Sync:SendHello()
    end)
end

function Sync:Start()
    if self.started or not self:IsEnabled() then
        return
    end
    self.started = true
    generation = generation + 1
    local gen = generation
    local api = _G.C_ChatInfo
    if api and api.RegisterAddonMessagePrefix then
        pcall(api.RegisterAddonMessagePrefix, PREFIX)
    end
    FW:RegisterEvent("CHAT_MSG_ADDON", self.OnAddonMessage, self)
    FW:RegisterEvent("GROUP_ROSTER_UPDATE", self.OnGroupChanged, self)
    FW:On("CODEX_CHANGED", function(_, kind, id)
        Sync:OnChanged(kind, id)
    end, self)
    Loop(gen, SEND_INTERVAL, function()
        Sync:Pump()
        local now = Now()
        for key, buf in pairs(state.buffers) do
            if now - buf.t > 60 then
                state.buffers[key] = nil
            end
        end
    end)
    Loop(gen, ANNOUNCE_EVERY, function()
        Sync:FlushAnnounce()
    end)
    Loop(gen, SCAN_EVERY, function()
        Sync:ScanOwn()
    end)
    -- erstes Hallo nach dem Einloggen, verteilt, damit nicht alle gleichzeitig rufen
    C_Timer.After(5, function()
        if Sync.started and gen == generation then
            Sync:JoinGlobal()
        end
    end)
    C_Timer.After(10 + math.random() * 15, function()
        if Sync.started and gen == generation then
            Sync:JoinGlobal()
            Share.Scan(true)
            Sync:SendHello()
            Loop(gen, 2700, function()
                Sync:SendHello()
            end)
        end
    end)
end

function Sync:Stop()
    self.started = false
    generation = generation + 1
    FW:UnregisterEvent("CHAT_MSG_ADDON", self)
    FW:UnregisterEvent("GROUP_ROSTER_UPDATE", self)
    FW:Off("CODEX_CHANGED", self)
    state.queue = {}
    state.pending = {}
end

function Sync:SetLog(on)
    state.log = on and true or false
    FW:Print("Codex-Protokoll: " .. (state.log and "an (-> gesendet, <- empfangen)" or "aus"))
    FW:Fire("CODEX_SYNC_CHANGED")
end

function Sync:HeardCount()
    local n, now = 0, Now()
    for _, p in pairs(state.peers) do
        if now - p.t < 3600 then
            n = n + 1
        end
    end
    return n
end

function Sync:Debug()
    local st = state.stats
    local parts = {}
    for ch, n in pairs(st.byChannel) do
        parts[#parts + 1] = ch .. "=" .. n
    end
    table.sort(parts)
    local dist = {}
    for _, kind in ipairs(KINDS) do
        dist[#dist + 1] = kind .. "=" .. tostring((self:Distribution(kind)) or "-")
    end
    local own = Share.Summary()
    local ver = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("Freewood-Codex", "Version")) or "?"
    local me = {}
    for c in pairs(SelfCores()) do me[#me + 1] = c end
    table.sort(me)
    FW:Print(string.format("Codex %s, ich bin: %s (erkannt als: %s)", tostring(ver), tostring(UnitName and UnitName("player")), table.concat(me, ", ")))
    FW:Print(string.format("Codex-Teilen: %s, gestartet %s, Kanal %s, eigene Datensaetze %d",
        self:IsEnabled() and "an" or "aus", tostring(self.started), tostring(state.status.global), own or 0))
    FW:Print("Wege: " .. table.concat(dist, " "))
    FW:Print(string.format("Gesendet %d (gebremst %d, fehlgeschlagen %d, Abstand %.1fs, letzte Antwort %s), empfangen %d (%s), Hallo aus %d, Hallo ein %d, Anfragen %d, abgelehnt %d, Warteschlange %d",
        st.tx, st.throttled, st.fail, state.interval, st.lastResult, st.rx, table.concat(parts, " "), st.hello, st.helloIn, st.queries, st.rejected, #state.queue))
    local function Types(t)
        local out = {}
        for _, k in ipairs({ "H", "A", "Q", "V", "R", "B" }) do
            out[#out + 1] = k .. "=" .. (t[k] or 0)
        end
        return table.concat(out, " ")
    end
    FW:Print("Gesendet nach Art: " .. Types(st.txType))
    FW:Print("Empfangen nach Art: " .. Types(st.rxType))
    FW:Print(string.format("Bekannte Spieler (letzte Stunde): %d", self:HeardCount()))
end

function Sync:Stats()
    local store = Store()
    local senders, records = Share.RemoteStats()
    return {
        sent = store.sent or 0,
        received = store.received or 0,
        lastReceived = store.lastReceived,
        queue = #state.queue,
        global = state.status.global,
        senders = senders,
        records = records,
        heard = Sync:HeardCount(),
    }
end

-- Wird vom Codex nach dem Laden der Daten aufgerufen. Ist der Schalter gesetzt, verbindet sich das
-- Teilen von selbst (auch nach /reload), ohne dass man den Haken neu setzen muss.
function Sync:Init()
    if self:IsEnabled() then
        self:Start()
    end
end

function Sync:OnEnteringWorld()
    if self:IsEnabled() and C_Timer and C_Timer.After then
        C_Timer.After(30, function() Sync:SendTrust() end)
    end
    if self:IsEnabled() then
        if not self.started then
            self:Start()
        elseif state.status.global ~= "ok" then
            C_Timer.After(5, function()
                if Sync.started then
                    Sync:JoinGlobal()
                end
            end)
        end
    end
end

FW:RegisterEvent("PLAYER_ENTERING_WORLD", Sync.OnEnteringWorld, Sync)
