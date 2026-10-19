# Firebase-Regeln für BlackoutMod

`database.rules.json` sind die Security Rules für die Realtime Database
`blackoutmod-shared-default-rtdb`.

## Datenmodell pro Lobby (`/lobbies/<code>`)

| Pfad | Lesen | Schreiben |
|------|-------|-----------|
| `blackout` (`isBlackout`, `timestamp`) | jeder mit Code | jeder mit Code (4–8 Zeichen) |
| `owner` (Host-Schlüssel) | niemand | nur einmal (beim Erstellen), nur Codes mit 6–8 Zeichen |
| `settings/key` | niemand | – |
| `settings/values` (`maxSabotages`, `cooldown`, `maxDuration`, `flicker`) | jeder mit Code | nur zusammen mit `key` == `owner` |

- `/.json` und `/lobbies.json` sind nicht lesbar, es gibt also keine Liste aller Codes.
- Der Installer erstellt eine Lobby mit einem PATCH auf `/lobbies/<code>.json` mit
  `owner` und `settings`. Ist `owner` schon vergeben, schlägt das fehl (401), der
  Code ist dann belegt.
- Die Mod des Hosts schreibt `settings` beim Start bzw. bei F5 mit ihrem `OwnerKey`.
  Alle anderen lesen nur `settings/values`.
- Abwärtskompatibel mit v2.5: `blackout` ist unverändert.

Ohne Login bleibt eine Grenze: Wer einen Code kennt oder errät, kann in dieser Lobby
den Blackout an- und ausschalten. Dagegen helfen nur lange Codes.

## Einspielen

Aus dem Repo-Root, mit eingeloggter Firebase CLI:

```powershell
npx firebase-tools deploy --only database --project blackoutmod-shared
```

`firebase.json` verweist auf `firebase/database.rules.json`. Die Regeln vor v3
liegen als Backup in `database.rules.backup-2026-10-19.json`.

## Test-Lobbys löschen

Lobbys mit `owner` lassen sich per REST nicht löschen, nur mit Admin-Rechten:

```powershell
npx firebase-tools database:remove /lobbies/<code> --project blackoutmod-shared
```
