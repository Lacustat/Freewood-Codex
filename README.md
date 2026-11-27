# Freewood Codex

**English · Deutsch** — Author: Lacustat · Version 0.56.0 · Interface 16001 (World of Warcraft: Forever)

## Contents · Inhalt
- [English](#english)
  - [What is Freewood Codex?](#what-is-freewood-codex)
  - [What it learns](#what-it-learns)
  - [Database tab](#database-tab)
  - [Flights, paths and connections](#flights-paths-and-connections)
  - [Learning plan and congratulations](#learning-plan-and-congratulations)
  - [Rare mob tracker](#rare-mob-tracker)
  - [Sharing](#sharing)
  - [Commands](#commands)
  - [Requirements and installation](#requirements-and-installation)
- [Deutsch](#deutsch)
  - [Was ist Freewood Codex?](#was-ist-freewood-codex)
  - [Was er lernt](#was-er-lernt)
  - [Reiter Datenbank](#reiter-datenbank)
  - [Flüge, Wege und Verbindungen](#flüge-wege-und-verbindungen)
  - [Lernplan und Gratulation](#lernplan-und-gratulation)
  - [Rare-Tracker](#rare-tracker)
  - [Teilen](#teilen)
  - [Befehle](#befehle)
  - [Voraussetzungen und Installation](#voraussetzungen-und-installation)
- [Changelog · Änderungen](CHANGELOG.md)

---

## English

### What is Freewood Codex?
The Codex is the database of the Freewood family. It learns quests, creatures, objects, items and zones while you play and shows everything with search, filters and the world map. Your own observations always win over the bundled starter data. Many other Freewood modules (Quest, Creator, Brett) build on it.

### What it learns
- Quest givers and turn-ins, objectives, rewards, chains and experience.
- Creatures: levels, locations, loot with drop chances, kill time and experience per kill.
- Vendors with wares and prices, trainers with what they teach, flight masters, innkeepers and other roles.
- Objects, items (name, quality, icon, stats) and zones.
- What an item is used for ("material for" recipes) and where to buy it.

### Database tab
- Sections for quests, creatures, objects, items, zones and the learning plan.
- Search, filters (for example weapon + bow + epic), sorting and favourites.
- Locations on the world map; open the Codex directly on an item with a modifier click in bags, chat or the auction house.
- Extra tooltip lines: drops, vendors, quest use.

### Flights, paths and connections
- Records where you walked on foot (path network) – the level planner uses it for routes and walking times.
- Reads the flight map, measures every flight (time, price) and shows the flight time on the flight map.
- Small flight window while flying: destination and remaining time.
- Ships, zeppelins, subways and portals as connections.

### Learning plan and congratulations
- Learning plan: what your class trainer and profession trainers teach, by level, with rank and price.
- Congratulation in Blizzard style on every even level: your large class icon, "Congratulations! You have reached level XY" and what you can now learn, with total price and missing gold.
- The same for professions with the profession icon: new recipes and the rank limits 75, 150 and 225 (journeyman, expert, artisan), gathering professions included.
- Fades after 5 seconds, a click opens the learning plan, waits until combat is over, with a selectable Blizzard sound.

### Rare mob tracker
- Announces rare mobs nearby (nameplate, target, mouse-over, minimap markers) with name, level, coordinates, 3D model and known loot.
- Hint "possible spawn" near known spawn points.
- Optional skulls for rare spawns on the world map and minimap.
- Left-click targets the rare, right-click closes. Off by default.

### Sharing
- New data goes to other players with the Codex automatically (can be switched off), so the database grows for everyone.
- Data from other players never overwrites what you saw yourself.

### Commands
- `/fwcodex` – open the tab; `/fwcodex share` – check sharing
- `/fwflight` – state of the flight recording
- `/fwwege` – path network on the map
- `/fwrare` – test window of the rare tracker

### Requirements and installation
- Required: **Freewood Core**. Optional: **Freewood CodexData** and **Freewood ForeverData** (starter data), **Freewood Design** (icons for the congratulation).
- Copy the folder `Freewood-Codex` into `World of Warcraft\_forever_\Interface\AddOns\`. Full game restart for new files.
- Licence: GPL-3.0.

---

## Deutsch

### Was ist Freewood Codex?
Der Codex ist die Datenbank der Freewood-Familie. Er lernt beim Spielen Quests, Kreaturen, Objekte, Gegenstände und Zonen und zeigt alles mit Suche, Filtern und auf der Weltkarte. Eigene Beobachtungen haben immer Vorrang vor den mitgelieferten Startdaten. Viele andere Freewood-Module (Quest, Creator, Brett) bauen darauf auf.

### Was er lernt
- Questgeber und Abgabe, Ziele, Belohnungen, Ketten und Erfahrung.
- Kreaturen: Stufen, Fundorte, Beute mit Dropchancen, Kampfdauer und Erfahrung je Kill.
- Händler mit Ware und Preisen, Lehrer mit ihrem Lehrstoff, Flugmeister, Gastwirte und andere Rollen.
- Objekte, Gegenstände (Name, Qualität, Symbol, Werte) und Zonen.
- Wofür ein Gegenstand gebraucht wird („Material für“ Rezepte) und wo man ihn kaufen kann.

### Reiter Datenbank
- Bereiche für Quests, Kreaturen, Objekte, Gegenstände, Zonen und den Lernplan.
- Suche, Filter (zum Beispiel Waffe + Bogen + episch), Sortierung und Favoriten.
- Fundorte auf der Weltkarte; den Codex per Tastenkombination und Klick direkt auf einem Gegenstand öffnen (Taschen, Chat, Auktionshaus).
- Zusätzliche Tooltip-Zeilen: Beute, Händler, Questverwendung.

### Flüge, Wege und Verbindungen
- Merkt sich, wo du zu Fuß gelaufen bist (Wegenetz) – der Levelplaner nutzt es für Routen und Laufzeiten.
- Liest die Flugkarte, misst jeden Flug (Dauer, Preis) und zeigt die Flugzeit auf der Flugkarte.
- Kleines Flugfenster während des Flugs: Ziel und Restzeit.
- Schiffe, Zeppeline, U-Bahn und Portale als Verbindungen.

### Lernplan und Gratulation
- Lernplan: was dein Klassenlehrer und die Berufslehrer beibringen, nach Stufe, mit Rang und Preis.
- Gratulation im Blizzard-Stil auf jeder geraden Stufe: dein großes Klassen-Icon, „Gratulation! Du hast Level XY erreicht“ und was du jetzt lernen kannst, mit Gesamtpreis und fehlendem Gold.
- Dasselbe für Berufe mit dem Berufs-Icon: neue Rezepte und die Stufengrenzen 75, 150 und 225 (Geselle, Experte, Fachmann), auch für Sammelberufe.
- Blendet nach 5 Sekunden aus, ein Klick öffnet den Lernplan, wartet bis nach dem Kampf, mit wählbarem Blizzard-Sound.

### Rare-Tracker
- Meldet seltene Gegner in der Nähe (Namensplakette, Ziel, Maus, Minimap-Markierungen) mit Name, Stufe, Koordinaten, 3D-Modell und bekannter Beute.
- Hinweis „möglicher Spawn“ in der Nähe bekannter Fundorte.
- Auf Wunsch Totenköpfe für Rare-Fundorte auf Weltkarte und Minimap.
- Linksklick nimmt den Rare ins Ziel, Rechtsklick schließt. Standardmäßig aus.

### Teilen
- Neue Daten gehen automatisch an andere Spieler mit dem Codex (abschaltbar), so wächst die Datenbank für alle.
- Daten anderer Spieler überschreiben nie, was du selbst gesehen hast.

### Befehle
- `/fwcodex` – Reiter öffnen; `/fwcodex share` – Teilen prüfen
- `/fwflight` – Stand der Flugerfassung
- `/fwwege` – Wegenetz auf der Karte
- `/fwrare` – Testfenster des Rare-Trackers

### Voraussetzungen und Installation
- Benötigt: **Freewood Core**. Optional: **Freewood CodexData** und **Freewood ForeverData** (Startdaten), **Freewood Design** (Icons für die Gratulation).
- Den Ordner `Freewood-Codex` nach `World of Warcraft\_forever_\Interface\AddOns\` kopieren. Bei neuen Dateien das Spiel komplett neu starten.
- Lizenz: GPL-3.0.
