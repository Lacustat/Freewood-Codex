# Freewood-Codex

**Deutsch & English · German & English.** Autor · Author: Lacustat. Version 0.43.2 · Interface 16001 (World of Warcraft: Forever).

![Codex_Items](https://github.com/Lacustat/Freewood-OctoWoW-Bilder/blob/main/database-item.jpg)

## Inhalt · Contents
- [Deutsch](#deutsch)
- [English](#english)

## Deutsch

### Was ist das?
Die Datenbank der Freewood-Familie. Sie lernt beim Spielen Quests, Kreaturen, Objekte, Items und Gebiete und zeigt sie mit Suche, Filtern und Karte. Eigene Beobachtungen gehen den mitgelieferten Startdaten immer vor.

### Funktionen
- Lernt automatisch: Quest-Geber und Abgabe, Belohnungen, Ziele, Beute mit Drop-Chancen, Händlerwaren und Preise, Rollen (Händler, Flugmeister, Lehrer, Gastwirt …), Fundorte, Kampfdauer, Erfahrung.
- Bereiche: Quests, Kreaturen, Objekte, Items, Gebiete, Lernplan. Suche, Filter, Sortierung, Favoriten, Anzeige auf der Weltkarte.
- Teilen: neue Daten gehen automatisch an andere Spieler mit dem Addon (abschaltbar). Änderungen von Berechtigten haben Vorrang.
- Wegenetz: zeichnet auf, wo man zu Fuß gelaufen ist; der Levelplan rechnet damit Laufzeiten und Laufwege.
- Verbindungen: Schiffe, Zeppeline, U-Bahnen und Portale (von Berechtigten erfasst).
- Flüge: liest die Flugkarte, misst jeden Flug (Dauer, Preis) und teilt die Strecken. Es gibt keine mitgelieferten Flugdaten; alles stammt aus eigenen Flügen oder von anderen Spielern. Ungeprüft im Spiel.
- Item-Gedächtnis: Name, Qualität und Symbol bleiben nach einem Neustart erhalten, damit die Listen nicht wieder „#1234“ zeigen. Ungeprüft im Spiel.

### Abhängigkeiten
- Benötigt: `Freewood-Core`
- Optional: `Freewood-CodexData`, `Freewood-ForeverData`

### Befehle
- `/fwcodex`: Reiter öffnen, Diagnose
- `/fwcodex share`: Teilen prüfen (Wege, Zähler, bekannte Spieler); `/fwcodex share log`: gesendete und empfangene Nachrichten im Chat; `/fwcodex share channel on|off`: Test des geheimen Kanals mit Protokoll
- `/fwflight`: Stand der Flugerfassung und ob die Flug-Funktionen des Spiels da sind
- `/fwwege`: Wegenetz auf der Karte
- `/fwpos`, `/fwrolle`, `/fwkatalog`, `/fwblock`: Diagnose und Werkzeuge

### Installation
Den Ordner `Freewood-Codex` nach `World of Warcraft\_forever_\Interface\AddOns\` kopieren. Neue Dateien lädt das Spiel erst nach einem kompletten Neustart; ein `/reload` genügt nur, wenn sich bestehende Dateien geändert haben. Fehler sichtbar machen: `/console scriptErrors 1`, danach `/reload`.

### Hinweise

- Daten werden in `FreewoodDB` gespeichert. Aus der OctoWoW-Version wurden nur Code und Funktionen übernommen, keine Daten.

### Lizenz
GPL-3.0, siehe `LICENSE`.

---

## English

### What is it?
The database of the Freewood family. It learns quests, creatures, objects, items and zones while you play and shows them with search, filters and a map. Your own observations always win over the bundled starter data.

### Features
- Learns automatically: quest givers and turn-ins, rewards, objectives, loot with drop chances, vendor wares and prices, roles (vendor, flight master, trainer, innkeeper …), locations, kill time, experience.
- Sections: quests, creatures, objects, items, zones, learning plan. Search, filters, sorting, favourites, display on the world map.
- Sharing: new data goes to other players with the addon automatically (can be switched off). Changes by authorised editors take priority.
- Path network: records where you walked on foot; the level plan uses it for walking times and routes.
- Connections: ships, zeppelins, subways and portals (recorded by authorised editors).
- Flights: reads the flight map, measures every flight (duration, price) and shares the routes. There is no bundled flight data; everything comes from your own flights or from other players. Not verified in game.
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

- Data is stored in `FreewoodDB`. Only code and functions were taken over from the OctoWoW version, no data.

### License
GPL-3.0, see `LICENSE`.
