-- Freewood-Codex: Eigentuemer der Datenbank
--
-- Hier stehen die Charaktere (Name-Realm), die DEV-Rechte vergeben duerfen. Nur Listen, die von einem dieser
-- Charaktere kommen, werden von anderen Spielern uebernommen. Der Absender einer Addon-Nachricht wird vom
-- Spiel gesetzt und kann nicht gefaelscht werden.
--
-- Eintrag zum Beispiel:   "Lacustat-Everlook",
-- (genau so geschrieben, wie der Charakter im Spiel heisst. Charaktere haben Vor- und Nachnamen: "Aroki Steel".
--  Ein Bindestrich gilt nur als Realm-Trenner, wenn dahinter ClassicBetaPvP2 steht.)
--
-- Ist die Liste leer, gibt es niemanden mit DEV-Rechten: Namen koennen dann nicht bearbeitet werden.

local ADDON, NS = ...
if not NS then
    return
end

-- Seit 0.57.0 dieselbe Liste wie die Admin-Charaktere im Core (Freewood.Net.ADMINS, Net.lua); hier nur der Rueckfall
-- fuer einen aelteren Core und Zusatznamen, die nur Eigentuemer sein sollen (nicht Empfaenger der Daten).
local FALLBACK = {
    "Pinky Freewood",
    "Pinky Silberrücken",
    "Aroki Freewood",
    "Dr Freewood",
    "Greeny Freewood",
    "Reddy Freewood",
    "Aroki Steel",
    "Lujinja Steel",
}
local EXTRA = {
    "Aroki Silberrücken",
}

local function BuildOwners()
    local out, seen = {}, {}
    local FW = _G.Freewood
    local Net = type(FW) == "table" and rawget(FW, "Net") or nil
    local base = (type(Net) == "table" and type(Net.Admins) == "function" and Net.Admins()) or FALLBACK
    for _, list in ipairs({ base, EXTRA }) do
        for _, n in ipairs(list) do
            local k = n:lower()
            if not seen[k] then seen[k] = true; out[#out + 1] = n end
        end
    end
    return out
end
NS.BuildOwners = BuildOwners
NS.Owners = BuildOwners()

-- Feste Moderatoren: immer Moderator, auch ohne die Liste eines Eigentuemers (ausser ausdruecklich gesperrt)
NS.Moderators = {
    "Jinxer Darktide",
}
