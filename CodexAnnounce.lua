-- Freewood-Codex: Ankuendigungen (Fenster bei den Spielern) und Versionspruefung. UNGEPRUEFT im Spiel.
--
-- Senden duerfen Eigentuemer und Moderatoren (Rolle in Codex.Trust, gepflegt im Modul Freewood-Rechte).
-- Uebertragung wie beim Teilen nur ueber Gilde, Gruppe und Schlachtzug (Addon-Nachrichten, Praefix des Teilens).
-- Nachrichten:
--   N|id|i|n|stueck   Ankuendigung in Stuecken. Inhalt: zeit;ablauf;von;module;text
--   G|id,id,...       diese Ankuendigungen kenne ich (mit dem Hallo): wer mehr hat, reicht sie nach (zufaellig verzoegert)
--   P|nonce           Versionsabfrage eines Berechtigten
--   W|nonce|module    Antwort: Core=0.6.0,Codex=0.44.2,...
-- Ein Fenster oeffnet sich nur, wenn mindestens ein genanntes Modul bei uns aelter ist (Ankuendigungen ohne Modulliste
-- gehen an alle), nur ausserhalb des Kampfes, hoechstens einmal in 24 Stunden je Ankuendigung. "Verstanden" beendet sie.
-- Weitergeleitete Ankuendigungen (Absender ist nicht der Verfasser) gelten als "nicht bestaetigt", bis der Verfasser selbst
-- sie schickt. Der Text ist reiner Text: Links, Farbcodes und Adressen werden entfernt.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Ann = { buf = {}, heard = {}, relayed = {}, probe = nil }
NS.Announce = Ann
Codex.Announce = Ann

local DAY = 86400
local MAX_AGE = 7 * DAY            -- Ablauf: hoechstens 7 Tage
local MAX_TEXT = 400
local PIECE = 190
local MAX_PIECES = 5
local MAX_MSGS = 20
local MAX_BUF = 8
local MAX_MODS = 15
local BUF_TTL = 180
local HEARD_WINDOW = 40            -- hat jemand anderes dieselbe Ankuendigung gerade verbreitet, schweigen wir
local RELAY_COOLDOWN = 600

local function Now()
    if _G.GetServerTime then
        local ok, v = pcall(_G.GetServerTime)
        if ok and type(v) == "number" then return v end
    end
    return (_G.time and _G.time()) or 0
end
Ann.Now = Now

local function Clock() return (_G.GetTime and _G.GetTime()) or 0 end

local function DB()
    local db = Codex.db
    if not db then return nil end
    db.announce = db.announce or {}
    local a = db.announce
    a.msgs = a.msgs or {}   -- [id] = { id, ts, exp, by, mods = "Core=0.6.0,...", text, direct, mine, raw }
    a.seen = a.seen or {}   -- [id] = { shown = Zeit, done = true }
    return a
end

local function Trust() return Codex.Trust end

------------------------------------------------------------------------
-- Text und Versionen
------------------------------------------------------------------------

local TLDS = { "com", "net", "org", "de", "gg", "io", "tv", "eu", "info", "me", "to" }

-- Reiner Text: Itemlinks -> Name, Farbcodes, Texturen, Steuerzeichen, Adressen raus
function Ann.Clean(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|H.-|h(.-)|h", "%1")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|n", " ")
    text = text:gsub("%c", " ")
    text = text:gsub("[Hh][Tt][Tt][Pp][Ss]?://%S*", "")
    text = text:gsub("[Ww][Ww][Ww]%.%S*", "")
    for _, tld in ipairs(TLDS) do
        local pat = "%S+%." .. tld:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end) .. "%f[%W]%S*"
        text = text:gsub(pat, "")
    end
    text = text:gsub("|", "")
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    return text
end

local function VerNum(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- a ist aelter als b
function Ann.Older(a, b)
    local x, y = VerNum(a), VerNum(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p < q end
    end
    return false
end

-- Geladene Freewood-Addons { Name = Version } (Name ohne "Freewood-")
function Ann.LocalVersions()
    local out = {}
    local api = _G.C_AddOns
    local num = (api and api.GetNumAddOns and api.GetNumAddOns()) or (_G.GetNumAddOns and _G.GetNumAddOns()) or 0
    for i = 1, num do
        local name
        if api and api.GetAddOnInfo then
            local ok, info = pcall(api.GetAddOnInfo, i)
            if ok then name = type(info) == "table" and info.name or info end
        elseif _G.GetAddOnInfo then
            local ok, n = pcall(_G.GetAddOnInfo, i)
            if ok then name = n end
        end
        if type(name) == "string" and name:find("^Freewood%-") then
            local loaded = (api and api.IsAddOnLoaded and api.IsAddOnLoaded(name)) or (_G.IsAddOnLoaded and _G.IsAddOnLoaded(name))
            if loaded then
                local getMeta = (api and api.GetAddOnMetadata) or _G.GetAddOnMetadata
                local ok, ver = pcall(getMeta, name, "Version")
                if ok and type(ver) == "string" and ver:match("^[%d%.]+$") then
                    out[name:sub(10)] = ver
                end
            end
        end
    end
    return out
end

local function EncodeMods(map)
    local names = {}
    for n in pairs(map) do names[#names + 1] = n end
    table.sort(names)
    local parts = {}
    for i = 1, math.min(#names, MAX_MODS) do
        parts[#parts + 1] = names[i] .. "=" .. map[names[i]]
    end
    return table.concat(parts, ",")
end
Ann.EncodeMods = EncodeMods

local function DecodeMods(str)
    local out = {}
    if type(str) ~= "string" then return out end
    local n = 0
    for name, ver in str:gmatch("(%w+)=([%d%.]+)") do
        n = n + 1
        if n > MAX_MODS then break end
        out[name] = ver
    end
    return out
end
Ann.DecodeMods = DecodeMods

-- Module, bei denen wir aelter sind als verlangt: Liste { name, ich, soll }
function Ann.Outdated(modsStr, mine)
    mine = mine or Ann.LocalVersions()
    local out = {}
    for name, want in pairs(DecodeMods(modsStr)) do
        local have = mine[name]
        if have and Ann.Older(have, want) then
            out[#out + 1] = { name = name, have = have, want = want }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

------------------------------------------------------------------------
-- Berechtigung
------------------------------------------------------------------------

local function RoleOf(name)
    local t = Trust()
    return t and t.RoleOf and t.RoleOf(name) or nil
end

local function IsPrivileged(name)
    local r = RoleOf(name)
    return r == "owner" or r == "moderator"
end

function Ann.CanSend()
    local t = Trust()
    if not t then return false end
    local r = t.SelfRole and t.SelfRole()
    return r == "owner" or r == "moderator"
end

local function SelfKey()
    local t = Trust()
    return t and t.SelfKey and t.SelfKey() or nil
end

------------------------------------------------------------------------
-- Senden
------------------------------------------------------------------------

local function Broadcast(text)
    local sync = Codex.Sync
    if not (sync and sync.Broadcast and sync:IsEnabled()) then return 0 end
    return sync.Broadcast(text)
end

local function Payload(m)
    return string.format("%d;%d;%s;%s;%s", m.ts, m.exp, m.by, m.mods or "", m.text)
end

local function SendPieces(m)
    local raw = m.raw or Payload(m)
    local n = math.ceil(#raw / PIECE)
    if n < 1 or n > MAX_PIECES then return 0 end
    local sent = 0
    for i = 1, n do
        sent = sent + Broadcast(string.format("N|%s|%d|%d|%s", m.id, i, n, raw:sub((i - 1) * PIECE + 1, i * PIECE)))
    end
    return sent
end

local function NewId()
    return string.format("%x%03x", Now() % 0xffffff, math.random(0, 0xfff))
end

-- text: eigener Text; versions = true: Standardnachricht "Neue Version" mit den Versionen aller eigenen Module
-- Rueckgabe: ok, Nachricht oder Fehlertext
function Ann.Send(text, versions)
    if not Ann.CanSend() then return false, FW.L.ANN_ERR_RIGHTS end
    local a = DB()
    if not a then return false, "db" end
    local by = SelfKey()
    if not by then return false, "name" end
    local mods = ""
    if versions then
        text = "@VER"
        mods = EncodeMods(Ann.LocalVersions())
        if mods == "" then return false, FW.L.ANN_ERR_NOMODS end
    else
        text = Ann.Clean(text)
        if text == "" then return false, FW.L.ANN_ERR_EMPTY end
    end
    local ts = Now()
    local m = { id = NewId(), ts = ts, exp = ts + MAX_AGE, by = by, mods = mods, text = text, direct = true, mine = true,
        name = _G.UnitName and (_G.UnitName("player")) or nil }
    m.raw = Payload(m)
    if #m.raw > PIECE * MAX_PIECES then return false, FW.L.ANN_ERR_LONG end
    a.msgs[m.id] = m
    local sent = SendPieces(m)
    if sent == 0 then
        return true, m, FW.L.ANN_NOT_SENT
    end
    return true, m
end

------------------------------------------------------------------------
-- Empfangen
------------------------------------------------------------------------

local function Prune()
    local a = DB()
    if not a then return end
    local now = Now()
    for id, m in pairs(a.msgs) do
        if m.exp <= now then
            a.msgs[id] = nil
            a.seen[id] = nil
        end
    end
    local count, oldest, oid = 0, nil, nil
    for id, m in pairs(a.msgs) do
        count = count + 1
        if not oldest or m.ts < oldest then oldest, oid = m.ts, id end
    end
    if count > MAX_MSGS and oid then
        a.msgs[oid] = nil
        a.seen[oid] = nil
    end
end

local function ShortName(sender)
    local n = Ambiguate and Ambiguate(sender, "none") or sender
    return (tostring(n):gsub("%-.*$", ""))
end

local function Accept(id, raw, sender)
    local a = DB()
    if not a then return false end
    local ts, exp, by, mods, text = raw:match("^(%d+);(%d+);([^;]*);([^;]*);(.*)$")
    ts, exp = tonumber(ts), tonumber(exp)
    if not ts or not exp or by == "" then return false end
    local now = Now()
    if ts > now + 600 then return false end
    if exp > ts + MAX_AGE then exp = ts + MAX_AGE end
    if exp <= now then return false end
    if not IsPrivileged(by) then return false end
    if RoleOf(sender) == "blocked" then return false end
    local t = Trust()
    local direct = t.Key(sender) ~= nil and t.Key(sender) == t.Key(by)
    local mine = t.Key(by) ~= nil and t.Key(by) == t.Key(SelfKey())
    if text ~= "@VER" then text = Ann.Clean(text) end
    if text == "" then return false end
    mods = EncodeMods(DecodeMods(mods))
    local m = a.msgs[id]
    if m then
        if direct and not m.direct then m.direct = true; m.name = ShortName(sender) end
        return true
    end
    a.msgs[id] = { id = id, ts = ts, exp = exp, by = by, mods = mods, text = text, direct = direct, mine = mine, raw = raw,
        name = direct and ShortName(sender) or nil }
    Prune()
    return true
end

local function Piece(sender, body)
    local id, i, n, piece = body:match("^(%w+)|(%d+)|(%d+)|(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not id or not i or not n or n < 1 or n > MAX_PIECES or i < 1 or i > n then return false end
    Ann.heard[id] = Clock()
    local a = DB()
    if a and a.msgs[id] then
        -- schon bekannt: nur eine direkte Bestaetigung zaehlt noch
        if i == 1 and not a.msgs[id].direct then
            local t = Trust()
            local by = a.msgs[id].by
            if t and t.Key(sender) == t.Key(by) then a.msgs[id].direct = true; a.msgs[id].name = ShortName(sender) end
        end
        return true
    end
    local key = id .. ":" .. tostring(sender)
    local b = Ann.buf[key]
    if not b or b.n ~= n then
        local count = 0
        for _ in pairs(Ann.buf) do count = count + 1 end
        if count >= MAX_BUF then return false end
        b = { n = n, parts = {}, got = 0, t = Clock() }
        Ann.buf[key] = b
    end
    if not b.parts[i] then
        b.parts[i] = piece
        b.got = b.got + 1
    end
    if b.got == n then
        Ann.buf[key] = nil
        local ok = Accept(id, table.concat(b.parts), sender)
        if ok then Ann.Check() end
        return ok
    end
    return true
end

-- Neuling meldet, welche Ankuendigungen er kennt: Fehlendes nach zufaelliger Wartezeit nachreichen
local function Digest(sender, body)
    local a = DB()
    if not a then return false end
    local known = {}
    for id in body:gmatch("%w+") do known[id] = true end
    local scheduled = 0
    local now = Now()
    for id, m in pairs(a.msgs) do
        if not known[id] and m.exp > now and m.raw and scheduled < 2 and (Ann.relayed[id] == nil or Clock() - Ann.relayed[id] > RELAY_COOLDOWN) then
            scheduled = scheduled + 1
            local asked = Clock()
            local delay = 4 + math.random() * 20
            local function fire()
                local mm = a.msgs[id]
                if not mm or mm.exp <= Now() then return end
                if (Ann.heard[id] or 0) > asked then return end   -- hat schon jemand anderes verbreitet
                Ann.relayed[id] = Clock()
                SendPieces(mm)
            end
            if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(delay, fire) else fire() end
        end
    end
    return true
end

function Ann.SendDigest()
    local a = DB()
    if not a then return false end
    Prune()
    local ids = {}
    for id, m in pairs(a.msgs) do
        if #ids < 16 then ids[#ids + 1] = id end
    end
    if #ids == 0 then return false end
    return Broadcast("G|" .. table.concat(ids, ",")) > 0
end

------------------------------------------------------------------------
-- Versionsabfrage
------------------------------------------------------------------------

-- Berechtigter fragt nach: wir antworten einmal je Abfrage nach zufaelliger Wartezeit
local function Probe(sender, nonce)
    if not IsPrivileged(sender) then return false end
    if not nonce:match("^%w+$") or #nonce > 12 then return false end
    if Ann.answered == nonce then return true end
    Ann.answered = nonce
    local function reply()
        Broadcast("W|" .. nonce .. "|" .. EncodeMods(Ann.LocalVersions()))
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(2 + math.random() * 20, reply) else reply() end
    return true
end

local function Answer(sender, body)
    local p = Ann.probe
    if not p then return false end
    local nonce, mods = body:match("^(%w+)|(.*)$")
    if nonce ~= p.nonce then return false end
    p.replies[ShortName(sender)] = DecodeMods(mods)
    FW:Fire("CODEX_ANNOUNCE_PROBE")
    return true
end

-- Eigentuemer/Moderator: nach den Versionen fragen
function Ann.StartProbe()
    if not Ann.CanSend() then return false, FW.L.ANN_ERR_RIGHTS end
    local nonce = string.format("%x", math.random(0x1000, 0xffffff))
    Ann.probe = { nonce = nonce, t = Clock(), replies = {} }
    if Broadcast("P|" .. nonce) == 0 then return false, FW.L.ANN_NOT_SENT end
    if _G.C_GuildInfo and _G.C_GuildInfo.GuildRoster and _G.IsInGuild and _G.IsInGuild() then pcall(_G.C_GuildInfo.GuildRoster) end
    return true
end

local function GuildOnline()
    local out = {}
    if _G.IsInGuild and _G.IsInGuild() and _G.GetNumGuildMembers then
        local n = _G.GetNumGuildMembers() or 0
        for i = 1, n do
            local name, _, _, _, _, _, _, _, online = _G.GetGuildRosterInfo(i)
            if type(name) == "string" and online then out[#out + 1] = (name:gsub("%-.*$", "")) end
        end
    end
    return out
end

-- Ergebnis der Abfrage gegen die Zielversionen (Text "Core=0.6.0,..." oder die eigenen Versionen)
-- Rueckgabe: { outdated = { {name, list} }, current = { name }, silent = { name } }
function Ann.ProbeReport(targetMods)
    local p = Ann.probe
    if not p then return nil end
    local want = DecodeMods(targetMods or EncodeMods(Ann.LocalVersions()))
    local rep = { outdated = {}, current = {}, silent = {} }
    for name, mods in pairs(p.replies) do
        local old = {}
        for mod, ver in pairs(want) do
            local have = mods[mod]
            if have and Ann.Older(have, ver) then old[#old + 1] = mod .. " " .. have .. "<" .. ver end
        end
        table.sort(old)
        if #old > 0 then rep.outdated[#rep.outdated + 1] = { name = name, list = old } else rep.current[#rep.current + 1] = name end
    end
    local function byName(a, b) return (a.name or a) < (b.name or b) end
    table.sort(rep.outdated, byName)
    table.sort(rep.current)
    local seen = {}
    for name in pairs(p.replies) do seen[name:lower()] = true end
    for _, name in ipairs(GuildOnline()) do
        if not seen[name:lower()] then rep.silent[#rep.silent + 1] = name end
    end
    table.sort(rep.silent)
    return rep
end

------------------------------------------------------------------------
-- Eingang aus dem Teilen (CodexSync)
------------------------------------------------------------------------

function Ann.Receive(t, sender, body, kind)
    if type(body) ~= "string" then return false end
    if t == "N" then return Piece(sender, body)
    elseif t == "G" then return Digest(sender, body)
    elseif t == "P" then return Probe(sender, body)
    elseif t == "W" then return Answer(sender, body) end
    return false
end

------------------------------------------------------------------------
-- Fenster
------------------------------------------------------------------------

local function InCombat()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return true end
    if _G.UnitAffectingCombat and _G.UnitAffectingCombat("player") then return true end
    return false
end

local function BodyText(m, outdated)
    local L = FW.L
    if m.text == "@VER" then
        local lines = { L.ANN_VERSION_HEAD }
        for _, o in ipairs(outdated or {}) do
            lines[#lines + 1] = string.format("%s: %s  ->  %s", o.name, o.have, o.want)
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = L.ANN_VERSION_TAIL
        return table.concat(lines, "\n")
    end
    return m.text
end

local win
local function EnsureWindow()
    if win then return win end
    local UI = FW.UI
    win = UI.CreatePanel(UIParent, "bg", "bronze")
    win:SetSize(420, 240)
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    win.title = UI.CreateLabel(win, FW.L.ANN_TITLE, { font = "heading", size = 16, color = "goldLight" })
    win.title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    win.from = UI.CreateLabel(win, "", { size = 11, color = "textDim" })
    win.from:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -38)
    win.from:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -38)
    win.from:SetWordWrap(false)
    win.body = UI.CreateLabel(win, "", { size = 13, justifyV = "TOP" })
    win.body:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -62)
    win.body:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 52)
    win.body:SetWordWrap(true)
    win.ok = UI.CreateButton(win, FW.L.ANN_OK, 140, 30, function()
        local a = DB()
        if a and win.id then
            a.seen[win.id] = a.seen[win.id] or {}
            a.seen[win.id].done = true
        end
        win:Hide()
        Ann.Check()
    end, "primary")
    win.ok:SetPoint("BOTTOM", win, "BOTTOM", 0, 14)
    win:Hide()
    return win
end

function Ann.Show(m, outdated)
    local w = EnsureWindow()
    w.id = m.id
    w.body:SetText(BodyText(m, outdated))
    local who = m.name or FW.L.ANN_PRIVILEGED
    w.from:SetText(string.format(m.direct and FW.L.ANN_FROM or FW.L.ANN_FROM_RELAY, who))
    w:Show()
end

function Ann.Window() return win end

-- Naechste faellige Ankuendigung anzeigen (nur ausserhalb des Kampfes, eine nach der anderen)
function Ann.Check()
    local a = DB()
    if not a then return false end
    if win and win:IsShown() then return false end
    if InCombat() then return false end
    Prune()
    for key, b in pairs(Ann.buf) do
        if Clock() - (b.t or 0) > BUF_TTL then Ann.buf[key] = nil end
    end
    local now = Now()
    local list = {}
    for id, m in pairs(a.msgs) do list[#list + 1] = m end
    table.sort(list, function(x, y) return x.ts < y.ts end)
    local mine = Ann.LocalVersions()
    for _, m in ipairs(list) do
        local s = a.seen[m.id]
        if not m.mine and not (s and s.done) and not (s and s.shown and now - s.shown < DAY) then
            local show, outdated = false, nil
            if m.mods == "" then
                show = m.text ~= "@VER"
            else
                outdated = Ann.Outdated(m.mods, mine)
                show = #outdated > 0
            end
            if show then
                a.seen[m.id] = a.seen[m.id] or {}
                a.seen[m.id].shown = now
                Ann.Show(m, outdated)
                return true
            end
        end
    end
    return false
end

local function Loop()
    pcall(Ann.Check)
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(10, Loop) end
end

FW:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(3, function() pcall(Ann.Check) end) end
end)
FW:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if not Ann.started then
        Ann.started = true
        if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(15, Loop) end
    end
end)
