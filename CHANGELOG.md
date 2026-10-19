# Changelog

## v3.0.0

### New
- **Lobby settings by the host:** the installer can create a lobby (you choose
  the rules) or join one (just enter the code). Everyone in the lobby uses the
  host's settings. Only the host can change them.
- **Flicker and sound:** the lights flicker and a power-down sound plays before the blackout.
- **Cooldown** between blackouts and an optional **maximum blackout duration**.
- **F5** reloads `config.txt` without restarting the game.
- New `config.txt` format (`Key=Value`). Old configs keep working.
- Installer: finds the game in every Steam library, can keep existing settings,
  generates random lobby codes, and can uninstall the mod.

### Fixed
- Possible crashes: game objects were accessed from a background thread.
- Short freeze when pressing O (network requests now run in the background).
- Light components were never found. The darkness came only from exposure and gamma.
- After a blackout, brightness/gamma was reset to fixed values instead of the player's own settings.
- Death detection now also works on clients (not only on the host).
- A blackout left on the server (e.g. after a crash) no longer keeps lobbies dark (needs a max duration).
- An empty lobby code in the installer was never detected.
- Clicking into the UE4SS console could freeze the game (QuickEdit is now turned off for that console window).

### Changed
- **P (manual repair) is disabled.** It let any player end a blackout.
- Short lobby codes (4-5 characters) still work but show a warning. New lobbies need 6-8 characters.
- Server: the list of lobby codes can no longer be read, and only valid blackout and settings data can be written.
- TLS certificates are verified again (`curl -k` removed).
