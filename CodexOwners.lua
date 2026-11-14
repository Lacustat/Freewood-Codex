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

NS.Owners = {
    "Aroki Steel",
    "Lujinja Steel",
    "Pinky Freewood",
    "Dr Freewood",
    "Aroki Silberrücken",
}

-- Feste Moderatoren: immer Moderator, auch ohne die Liste eines Eigentuemers (ausser ausdruecklich gesperrt)
NS.Moderators = {
    "Jinxer Darktide",
}
