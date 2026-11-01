-- Freewood-Codex: Berechtigungen (wer darf Daten fuer alle bearbeiten?)
--
-- Rollen:
--   owner      steht in CodexOwners.lua, darf die Liste veroeffentlichen
--   moderator  darf Namen aendern, Datensaetze als fehlerhaft markieren und fremde Markierungen aufheben
--   editor     darf Namen aendern und Datensaetze als fehlerhaft markieren
--   blocked    gesperrt: nichts wird mehr von diesem Charakter uebernommen
--
-- Die Liste (Charakter -> Rolle) kommt von einem Eigentuemer ueber den Kanal (Nachricht "T"). Der Absender einer
-- Addon-Nachricht wird vom Spiel gesetzt; Listen anderer Absender werden ignoriert.
-- Battle.net-Namen und Notizen bleiben beim Eigentuemer (Modul Freewood-Rechte) und werden nie verschickt.
-- Bearbeiten (Namen, Markierungen) geht nur, wenn zusaetzlich das Modul Freewood-Dev vorhanden ist.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Trust = { buffers = {} }
NS.Trust = Trust
Codex.Trust = Trust

local MAX_ENTRIES = 150
local ROLE_CODE = { editor = "e", moderator = "m", blocked = "b" }
local CODE_ROLE = { e = "editor", m = "moderator", b = "blocked" }
Trust.ROLES = { "editor", "moderator", "blocked" }

local ACTIONS = {
    editor = { name = true, bad = true, export = true },
    moderator = { name = true, bad = true, unbad = true, export = true },
}

------------------------------------------------------------------------
-- Namen
------------------------------------------------------------------------

local function Core(name)
    if type(name) ~= "string" then return "" end
    local n = name:gsub("\194\160", " "):match("^([^%-]*)") or ""
    return (n:gsub("%s", ""):lower())
end

local function RealmPart(name)
    local r = type(name) == "string" and name:match("%-(.+)$")
    if r then
        r = r:gsub("[%s%-]", ""):lower()
        if r ~= "" then return r end
    end
    return nil
end

local function OwnRealm()
    local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or ""
    return (tostring(r):gsub("[%s%-]", ""):lower())
end

-- Der eigene Realm hat im Spiel mehrere Schreibweisen (z.B. GetNormalizedRealmName = "ClassicBetaPvP2",
-- UnitFullName liefert "Steel"). Alle gelten als derselbe Realm und werden auf OwnRealm() vereinheitlicht.
local function IsOwnRealmVariant(r)
    if r == OwnRealm() then return true end
    local variants = {}
    if GetRealmName then variants[#variants + 1] = GetRealmName() end
    if UnitFullName then
        local ok, _, ur = pcall(UnitFullName, "player")
        if ok then variants[#variants + 1] = ur end
    end
    for _, v in ipairs(variants) do
        if type(v) == "string" and v:gsub("[%s%-]", ""):lower() == r then return true end
    end
    return false
end

-- "name-realm" in Kleinschreibung; ohne Realm gilt der eigene
function Trust.Key(name)
    local core = Core(name)
    if core == "" then return nil end
    local realm = RealmPart(name)
    if not realm or IsOwnRealmVariant(realm) then realm = OwnRealm() end
    return core .. "-" .. realm
end

-- Eintrag aus einer Liste oder von Hand getippt ("Speedtest-Timerun", "Aroki Steel", "Yuto-ClassicBetaPvP2").
-- In Forever haben Charaktere Vor- und Nachnamen ("Aroki Steel"); ein Bindestrich gilt nur dann als Realm-Trenner,
-- wenn dahinter der eigene Realm steht. Sonst ist es der Nachname (Bindestrich = Leerzeichen).
function Trust.EntryKey(name)
    if type(name) ~= "string" then return nil end
    local clean = name:gsub("\194\160", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local base, realm = clean:match("^(.*)%-([^%-]+)$")
    if base and realm:gsub("[%s%-]", ""):lower() == OwnRealm() then
        return Trust.Key(clean)
    end
    return Trust.Key((clean:gsub("%-", " ")))
end

-- Eigener voller Name. UnitFullName liefert in Forever Vorname und Nachname ("Aroki", "Steel"); die anderen
-- sehen uns als "Aroki Steel-ClassicBetaPvP2". Weicht der zweite Teil vom eigenen Realm ab, ist es der Nachname.
function Trust.SelfKey()
    local name, second
    if UnitFullName then
        local ok, n, r = pcall(UnitFullName, "player")
        if ok then name, second = n, r end
    end
    if not name and UnitName then name = (UnitName("player")) end
    if not name then return nil end
    if second and second ~= "" and second:gsub("[%s%-]", ""):lower() ~= OwnRealm() then
        name = name .. " " .. second
    end
    return Trust.Key(name)
end

local function Data()
    local db = Codex.db
    if not db then return { rev = 0, list = {} } end
    db.trust = db.trust or { rev = 0, list = {} }
    db.trust.list = db.trust.list or {}
    return db.trust
end

local function OwnerKeys()
    local set = {}
    for _, n in ipairs(NS.Owners or {}) do
        local k = Trust.EntryKey(n)
        if k then set[k] = true end
    end
    return set
end

------------------------------------------------------------------------
-- Abfragen
------------------------------------------------------------------------

function Trust.IsOwner(name)
    local k = Trust.Key(name)
    return k ~= nil and OwnerKeys()[k] == true
end

function Trust.IsSelfOwner()
    return Trust.IsOwner(Trust.SelfKey())
end

-- Rolle: "owner", "moderator", "editor", "blocked" oder nil
function Trust.RoleOf(name)
    local k = Trust.Key(name)
    if not k then return nil end
    local entry = Data().list[k]
    if entry and entry.role == "blocked" then return "blocked" end
    if OwnerKeys()[k] then return "owner" end
    return entry and entry.role or nil
end

function Trust.IsDev(name)
    local r = Trust.RoleOf(name)
    return r == "owner" or r == "moderator" or r == "editor"
end

function Trust.SelfRole()
    return Trust.RoleOf(Trust.SelfKey())
end

-- Darf dieser Charakter eine Aktion ausfuehren? Aktion: name, bad, unbad, export. Braucht das Modul Freewood-Dev.
function Trust.Can(action)
    if not Codex.DevModule then return false end
    local role = Trust.SelfRole()
    if role == "owner" then return true end
    local a = role and ACTIONS[role]
    return a ~= nil and a[action] == true
end

function Trust.CanEdit()
    return Trust.Can("name")
end

function Trust.Revision()
    return Data().rev or 0
end

function Trust.Entries()
    local out = {}
    for key, e in pairs(Data().list) do
        out[#out + 1] = { key = key, role = e.role }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

------------------------------------------------------------------------
-- Liste setzen und verschicken
------------------------------------------------------------------------

local function Changed()
    if Codex.Share and Codex.Share.TrustChanged then Codex.Share.TrustChanged() end
    FW:Fire("CODEX_TRUST_CHANGED")
    FW:Fire("CODEX_CHANGED", "trust")
end

-- entries: Liste { key, role }
function Trust.SetList(entries, rev)
    local d = Data()
    local list = {}
    local n = 0
    for _, e in ipairs(entries or {}) do
        local key = Trust.Key(e.key)
        if key and ROLE_CODE[e.role] and n < MAX_ENTRIES then
            list[key] = { role = e.role }
            n = n + 1
        end
    end
    d.list = list
    d.rev = rev or math.max((d.rev or 0) + 1, time and time() or 1)   -- Zeitstempel: bleibt auch nach einem Zuruecksetzen steigend
    d.stamp = time and time() or 0
    Changed()
    return d.rev
end

-- Nachrichten "T|rev|i/n|text" (Eintraege "name-realm,e;name-realm,m;...")
function Trust.Chunks()
    local d = Data()
    local parts = {}
    for _, e in ipairs(Trust.Entries()) do
        local key = e.key:gsub("[;,|]", "")
        parts[#parts + 1] = key .. "," .. ROLE_CODE[e.role]
    end
    local chunks, cur = {}, ""
    for _, p in ipairs(parts) do
        if #cur + #p + 1 > 190 then
            chunks[#chunks + 1] = cur
            cur = ""
        end
        cur = cur .. (cur ~= "" and ";" or "") .. p
    end
    chunks[#chunks + 1] = cur
    local out = {}
    for i, c in ipairs(chunks) do
        out[i] = string.format("T|%d|%d/%d|%s", d.rev or 0, i, #chunks, c)
    end
    return out
end

local function Parse(payload)
    local list = {}
    for item in (payload .. ";"):gmatch("([^;]*);") do
        local key, code = item:match("^(.-),([emb])$")
        if key and key ~= "" then
            list[#list + 1] = { key = key, role = CODE_ROLE[code] }
        end
    end
    return list
end

-- Empfang: nur von Eigentuemern. body = "rev|i/n|text". Rueckgabe: true, wenn eine neue Liste uebernommen wurde
function Trust.Receive(sender, body)
    if not Trust.IsOwner(sender) then return false end
    local rev, i, n, payload = tostring(body):match("^(%d+)|(%d+)/(%d+)|(.*)$")
    rev, i, n = tonumber(rev), tonumber(i), tonumber(n)
    if not rev or not i or not n or n < 1 or n > 12 or i < 1 or i > n then return false end
    local d = Data()
    if rev <= (d.rev or 0) then return false end   -- aelter oder schon vorhanden
    local key = Trust.Key(sender)
    local buf = Trust.buffers[key]
    if not buf or buf.rev ~= rev or buf.n ~= n then
        buf = { rev = rev, n = n, parts = {}, got = 0 }
        Trust.buffers[key] = buf
    end
    if not buf.parts[i] then
        buf.parts[i] = payload
        buf.got = buf.got + 1
    end
    if buf.got < n then return false end
    Trust.buffers[key] = nil
    local all = {}
    for idx = 1, n do all[#all + 1] = buf.parts[idx] end
    Trust.SetList(Parse(table.concat(all, ";")), rev)
    return true
end

------------------------------------------------------------------------
-- Diagnose: /fwrolle
------------------------------------------------------------------------

SLASH_FREEWOODROLE1 = "/fwrolle"
SlashCmdList["FREEWOODROLE"] = function()
    local d = Data()
    local n = 0
    for _ in pairs(d.list) do n = n + 1 end
    local L = FW.L
    FW:Print(string.format(L.CODEX_ROLE_INFO, tostring(Trust.SelfKey()), tostring(Trust.SelfRole() or "-"),
        Codex.DevModule and L.CODEX_YES or L.CODEX_NO, n, d.rev or 0))
    -- Ausfuehrliche Diagnose: was liefert das Spiel, und welche Schluessel stehen in der Eigentuemer-Liste?
    local ok, un, ur = false, nil, nil
    if UnitFullName then ok, un, ur = pcall(UnitFullName, "player") end
    FW:Print(string.format("Rolle: UnitFullName = %s | %s, UnitName = %s, GetRealmName = %s, GetNormalizedRealmName = %s, eigener Realm = %s",
        tostring(un), tostring(ur), tostring(UnitName and UnitName("player")), tostring(GetRealmName and GetRealmName()),
        tostring(GetNormalizedRealmName and GetNormalizedRealmName()), OwnRealm()))
    local self = Trust.SelfKey()
    local found = false
    for _, entry in ipairs(NS.Owners or {}) do
        local k = Trust.EntryKey(entry)
        if k == self then found = true end
        FW:Print(string.format("Rolle: Eigentuemer \"%s\" -> %s%s", tostring(entry), tostring(k), k == self and "  <== du" or ""))
    end
    FW:Print(string.format("Rolle: dein Schluessel %s steht %s in der Eigentuemer-Liste", tostring(self), found and "" or "NICHT"))
end
