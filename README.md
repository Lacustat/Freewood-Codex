# Freewood-Codex

**Deutsch & English · German & English.** Autor · Author: Lacustat. Version 0.47.5 · Interface 16001 (World of Warcraft: Forever).

![Codex_Items](https://github.com/Lacustat/Freewood-OctoWoW-Bilder/blob/main/database-item.jpg)

## Inhalt · Contents
- [Deutsch](#deutsch)
- [English](#english)
- [Tastenbelegung · Key bindings](#tastenbelegung--key-bindings)

## Deutsch

### Was ist das?
Die Datenbank der Freewood-Familie. Sie lernt beim Spielen Quests, Kreaturen, Objekte, Items und Gebiete und zeigt sie mit Suche, Filtern und Karte. Eigene Beobachtungen gehen den mitgelieferten Startdaten immer vor.

### Funktionen
- Lokale Vorquest-Ueberlagerung `Codex.ExtPre` für andere Freewood-Addons (ersetzt Vorquests einer Quest, wird nie gespeichert und nie geteilt).
- Lernt automatisch: Quest-Geber und Abgabe, Belohnungen, Ziele, Beute mit Drop-Chancen, Händlerwaren und Preise, Rollen (Händler, Flugmeister, Lehrer, Gastwirt …), Fundorte, Kampfdauer, Erfahrung.
- Bereiche: Quests, Kreaturen, Objekte, Items, Gebiete, Lernplan. Suche, Filter, Sortierung, Favoriten, Anzeige auf der Weltkarte.
- Teilen: neue Daten gehen automatisch an andere Spieler mit dem Addon (abschaltbar). Änderungen von Berechtigten haben Vorrang.
- Wegenetz: zeichnet auf, wo man zu Fuß gelaufen ist; der Levelplan rechnet damit Laufzeiten und Laufwege.
- Verbindungen: Schiffe, Zeppeline, U-Bahnen und Portale (von Berechtigten erfasst).
- Flüge: liest die Flugkarte, misst jeden Flug (Dauer, Preis) und teilt die Strecken. Es gibt keine mitgelieferten Flugdaten; alles stammt aus eigenen Flügen oder von anderen Spielern. Ungeprüft im Spiel. Ab 0.46.0 mit Flugfenster: beim Flug öffnet sich ein kleines Fenster mit dem Ziel und der Flugzeit. Ist die Dauer bekannt, läuft ein Balken leer; sonst wird die Zeit gemessen, hochgezählt und für das nächste Mal gespeichert. Das Fenster ist verschiebbar und in den Einstellungen (Datenbank > Flüge) abschaltbar. Ab 0.47.0 zeigt der Tooltip eines Flugpunkts auf der Flugkarte außerdem „Flugzeit: m:ss“ (gemessen, von anderen oder aus Teilstrecken geschätzt) oder „noch unbekannt“. Ab 0.47.1: Erfahrungs- und Kampfdauer-Daten von Mitspielern lösen keinen kompletten Neuaufbau der Sicht mehr aus (verursachte Ruckler von ca. 200 ms). Ab 0.47.2 wird die Gesamtsicht der Daten schon beim Anmelden (Ladebildschirm) aufgebaut, nicht erst beim ersten Tooltip im Spiel (sparte einen Ruckler von ca. 240 ms). Ab 0.47.4: Eine Schätzung aus Teilstrecken zählt nur noch Zwischenstationen, die ungefähr auf dem Weg liegen (höchstens das 1,3-fache der Luftlinie auf der Flugkarte); ein Umweg über eine ferne Stadt (z. B. Zoram'gar → Orgrimmar → Splintertree statt direkt) ergibt "noch unbekannt" statt einer falschen Zeit. Weicht ein neu gemessener Flug um mehr als 15 % von der gespeicherten Zeit ab, ersetzt er sie (Zähler wieder 1) und der Chat meldet die Korrektur (abschaltbar unter Datenbank > Flüge); kleinere Abweichungen werden wie bisher gemittelt. Im Spiel ungeprüft.
- Item-Gedächtnis: Name, Qualität und Symbol bleiben nach einem Neustart erhalten, damit die Listen nicht wieder „#1234“ zeigen. Ungeprüft im Spiel.

### Abhängigkeiten
- Benötigt: `Freewood-Core`
- Optional: `Freewood-CodexData`, `Freewood-ForeverData`

### Befehle
- `/fwcodex`: Reiter öffnen, Diagnose
- `/fwcodex share`: Teilen prüfen (Wege, Zähler, bekannte Spieler); `/fwcodex share log`: gesendete und empfangene Nachrichten im Chat; `/fwcodex share channel on|off`: Test des geheimen Kanals mit Protokoll
- `/fwflight`: Stand der Flugerfassung und ob die Flug-Funktionen des Spiels da sind
- `/fwwege`: Wegenetz auf der Karte
- `/fwpos`, `/fwrolle`, `/fwkatalog q|i|n|s`, `/fwblock`: Diagnose und Werkzeuge. Neu: `s` liest alle Zauber-IDs (Name, Rang, Symbol) im Hintergrund in den Katalog, als Grundlage für Gegner-Fähigkeiten. / New: `s` scans all spell IDs (name, rank, icon) into the catalog.

### Installation
Den Ordner `Freewood-Codex` nach `World of Warcraft\_forever_\Interface\AddOns\` kopieren. Neue Dateien lädt das Spiel erst nach einem kompletten Neustart; ein `/reload` genügt nur, wenn sich bestehende Dateien geändert haben. Fehler sichtbar machen: `/console scriptErrors 1`, danach `/reload`.

### Hinweise

- Datenbank-Liste: Wie viele Datensätze die Liste zeigt, stellst du in den Einstellungen unter „Datenbank“ ein (10 bis 100, Standard 20; vorher fest 300). Gibt es mehr Treffer, steht über der Liste, wie viele sichtbar sind; Suche oder Filter eingrenzen oder die Zahl erhöhen. Ungeprüft im Spiel.
- Daten werden in `FreewoodDB` gespeichert. Aus der OctoWoW-Version wurden nur Code und Funktionen übernommen, keine Daten.

### Lizenz
GPL-3.0, siehe `LICENSE`.

---

## English

### What is it?
The database of the Freewood family. It learns quests, creatures, objects, items and zones while you play and shows them with search, filters and a map. Your own observations always win over the bundled starter data.

### Features
- Local prerequisite overlay `Codex.ExtPre` for other Freewood addons (replaces a quest's prerequisites, is never saved and never shared).
- Learns automatically: quest givers and turn-ins, rewards, objectives, loot with drop chances, vendor wares and prices, roles (vendor, flight master, trainer, innkeeper …), locations, kill time, experience.
- Sections: quests, creatures, objects, items, zones, learning plan. Search, filters, sorting, favourites, display on the world map.
- Sharing: new data goes to other players with the addon automatically (can be switched off). Changes by authorised editors take priority.
- Path network: records where you walked on foot; the level plan uses it for walking times and routes.
- Connections: ships, zeppelins, subways and portals (recorded by authorised editors).
- Flights: reads the flight map, measures every flight (duration, price) and shares the routes. There is no bundled flight data; everything comes from your own flights or from other players. Not verified in game. Since 0.46.0 with a flight window: a small window shows the destination and the flight time while you fly. If the duration is known a bar runs down; otherwise the time is measured, counted up and saved for next time. The window is movable and can be switched off in the settings (Database > Flights). Since 0.47.0 the tooltip of a flight point on the flight map also shows "Flight time: m:ss" (measured, from others or estimated from legs) or "not known yet". Since 0.47.1: experience and fight-duration data from other players no longer trigger a full rebuild of the view (it caused hitches of about 200 ms). From 0.47.2 the combined data view is built at login (loading screen) instead of at the first tooltip in play (saved a hitch of about 240 ms). Since 0.47.4: an estimate from legs only counts intermediate stops that lie roughly on the way (at most 1.3 times the straight line on the flight map); a detour via a distant city (e.g. Zoram'gar → Orgrimmar → Splintertree instead of direct) shows "not known yet" instead of a wrong time. If a newly measured flight differs from the saved time by more than 15 %, it replaces it (counter back to 1) and the chat reports the correction (can be switched off under Database > Flights); smaller differences are averaged as before. Not verified in game.
- Item memory: name, quality and icon survive a restart so lists do not show “#1234” again. Not verified in game.

### Dependencies
- Required: `Freewood-Core`
- Optional: `Freewood-CodexData`, `Freewood-ForeverData`

### Commands
- `/fwcodex`: Reiter öffnen, Diagnose
- `/fwcodex share`: Teilen prüfen (Wege, Zähler, bekannte Spieler); `/fwcodex share log`: gesendete und empfangene Nachrichten im Chat; `/fwcodex share channel on|off`: Test des geheimen Kanals mit Protokoll
- `/fwflight`: Stand der Flugerfassung und ob die Flug-Funktionen des Spiels da sind
- `/fwwege`: Wegenetz auf der Karte
- `/fwpos`, `/fwrolle`, `/fwkatalog`, `/fwblock`: Diagnose und Werkzeuge

### Installation
Copy the folder `Freewood-Codex` to `World of Warcraft\_forever_\Interface\AddOns\`. New files only load after a full game restart; a `/reload` is enough only when existing files changed. To see errors: `/console scriptErrors 1`, then `/reload`.

### Notes

- Database list: the number of entries the list shows is set in Settings under "Database" (10 to 100, default 20; before: fixed 300). If more entries match, the line above the list says how many are visible; narrow the search or filters or raise the number. Unchecked in game.
- Data is stored in `FreewoodDB`. Only code and functions were taken over from the OctoWoW version, no data.

### License
GPL-3.0, see `LICENSE`.

## Tastenbelegung · Key bindings
**DE:** Unter Optionen > Tastaturbelegung gibt es einen eigenen Abschnitt für dieses Modul. Dort lässt sich eine Taste zum Öffnen und Schließen des Reiters belegen (zum Beispiel J für die Gilde). Ist der Reiter schon offen, schließt dieselbe Taste das Fenster. Nach der Installation einmal das Spiel neu starten, damit die neue Datei Bindings.xml gelesen wird.
**EN:** Options > Key Bindings has its own section for this module. Bind a key to open and close the tab (for example J for the guild). If the tab is already open, the same key closes the window. Restart the game once after installing so the new Bindings.xml file is read.
