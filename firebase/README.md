# Firebase-Regeln für BlackoutMod

`database.rules.json` sind die Security Rules für die Realtime Database
`blackoutmod-shared-default-rtdb`.

## Was sie bewirken

- Niemand kann mehr `/.json` oder `/lobbies.json` lesen, also keine Liste aller Lobby-Codes.
- Lesen und Schreiben geht nur noch auf `/lobbies/<code>/blackout`, genau das, was die Mod nutzt.
- Der Code muss 4–8 Zeichen lang sein (Buchstaben, Ziffern, `_`, `-`), wie in der Mod.
- Es dürfen nur `isBlackout` (Boolean) und `timestamp` (Zahl) gespeichert werden. Fremde Daten
  oder das Löschen anderer Lobbys sind nicht mehr möglich.

Kompatibel mit v2.5: Die alte Mod nutzt dieselben Pfade und Felder.

Ohne Login bleibt eine Grenze: Wer einen Code kennt oder errät, kann in dieser Lobby den Blackout
an- und ausschalten. Dagegen helfen nur längere Codes (6–8 Zeichen).

## Einspielen

1. https://console.firebase.google.com → Projekt `blackoutmod-shared` öffnen
2. **Realtime Database → Regeln (Rules)**
3. Die aktuellen Regeln als Backup kopieren, dann den Inhalt von `database.rules.json` einfügen
4. **Veröffentlichen**

## Prüfen

```powershell
# Muss jetzt "Permission denied" liefern:
Invoke-RestMethod "https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies.json?shallow=true"

# Muss weiter funktionieren:
Invoke-RestMethod "https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies/test1234/blackout.json"
```
