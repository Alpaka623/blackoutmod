# BlackoutMod v3.0 for LOCKDOWN Protocol

The Dissident can sabotage a defibrillator and cut the power: the lights flicker,
a power-down sound plays and the whole facility goes dark for every player in
your group.

## Features

- **Sabotage** as Dissident at any defibrillator (press **O**)
- **Lights flicker and a sound plays** before the power goes out
- **Lobby settings by the host**: one player creates the lobby and chooses the
  rules, everyone else just enters the code
- **Limits**: sabotages per round, cooldown between blackouts, maximum blackout duration
- Lights come back when someone dies, batteries are inserted, players return to
  the lobby, or the maximum duration is reached

## Installation

1. **Close the game** and extract this whole package (e.g. to your Desktop).
2. Double-click **`install.bat`**. If Windows SmartScreen warns you, click
   *More info* > *Run anyway*. The script is not signed.
3. The installer finds your game through Steam automatically. If it can't, enter the
   game folder (Steam: right-click the game > *Manage* > *Browse local files*).
4. Choose your role:
   - **Create a new lobby** (one person per group, the "host"):
     press Enter for a random code, then choose the settings. Share the code with your friends.
   - **Join a lobby** (everyone else): enter the code from your host.
     The installer shows the host's settings.
5. Start the game. The UE4SS console should show `BlackoutMod v3.0 LOADED`.

UE4SS (the mod loader) is included and installed automatically.

### Updating from v2.5

Run `install.bat` again and choose **Keep these settings**. Your old config is
converted automatically.

If your group uses a **short code (4-5 characters)**, it keeps working, but short
codes are easy to guess and can't have host settings. The host should
**create a new lobby** and send everyone the new code.

## In-game keys

| Key | Action |
|-----|--------|
| **O** | Sabotage (Dissident only, near a defibrillator) |
| **L** | Show lobby code and settings |
| **I** | Debug info (role, lobby code, sync status) |
| **F5** | Reload `config.txt` without restarting the game |

## Settings

The installer writes `config.txt` here:

```
LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64\ue4ss\Mods\BlackoutMod\config.txt
```

```
LobbyCode=k4m9x2ab

# Lobby host only:
OwnerKey=...
MaxSabotagesPerRound=1
Cooldown=0
MaxBlackoutDuration=0
```

| Setting | Meaning |
|---------|---------|
| `LobbyCode` | Same code for everyone in the group (4-8 letters/digits, `-` and `_`) |
| `OwnerKey` | Only in the host's config. Allows changing the lobby settings. **Keep it secret.** |
| `MaxSabotagesPerRound` | Sabotages per Dissident per round, `0` = unlimited |
| `Cooldown` | Seconds after the lights come back before the next sabotage, `0` = off |
| `MaxBlackoutDuration` | Seconds until the lights come back by themselves, `0` = off |
| `Helper` | Optional. `false` turns off the background helper (see *Antivirus warning*). Restart the game after changing it. |

**Shared settings:** `MaxSabotagesPerRound`, `Cooldown` and `MaxBlackoutDuration` come from the **host**. When the game
starts (or on F5), the host's mod uploads them and everyone else's mod downloads
them. In a player's config they are only used if the lobby has no host settings
(older lobbies).

To **change the lobby settings**, the host edits their `config.txt` and presses
**F5** (or runs the installer again and keeps the settings). The other players get
the new settings on their next game start or when they press F5.

## Uninstall

Run `install.bat` and choose **2 = Uninstall**. It removes BlackoutMod and asks
whether to remove UE4SS as well. Only remove UE4SS if no other mods use it.

## Troubleshooting

**Blackout doesn't sync between players**
- Press **I** in-game on every PC: the lobby code must be exactly the same (case-sensitive).
- Everyone needs an internet connection. `curl` (included in Windows 10/11) is used to talk to the server.

**"OwnerKey doesn't match this lobby" in the console**
- The `OwnerKey` in your config belongs to a different lobby. Create a new lobby with the installer.

**No sound**
- The sound is played by the mod's helper program (`BlackoutHelper.exe`) through
  Windows, so the in-game volume doesn't affect it. Check the Windows volume mixer.
- With `Helper=false` there is no sound.

**Antivirus warning**
- BlackoutMod starts a small helper program, `BlackoutHelper.exe` (in the mod's
  `Scripts` folder). It keeps one connection to the lobby server open and plays the sound.
  Its source code is in the mod's GitHub repository (`tools/helper`).
- Some antivirus programs warn about unknown programs started by a game. If yours does,
  allow `BlackoutHelper.exe`. **Never** move Windows files like `cmd.exe` to quarantine.
- Or add `Helper=false` to `config.txt`: the mod then works without the helper
  (sync through curl, no sound).

**Game freezes**
- Clicking into the UE4SS console window starts a text selection, which pauses all
  console output and freezes the game. BlackoutMod turns this off (QuickEdit) for the
  console while the game runs. If it still happens, click the console and press **Esc**.

**Mod doesn't load**
- The UE4SS console opens with the game and should show `BlackoutMod v3.0 LOADED`.
- Run `install.bat` again. If you get "Access denied", run it as administrator.

**Sabotage doesn't work**
- You must be the Dissident and stand close to a defibrillator.
- Check the limits with **L**: sabotages per round used up, or the cooldown is still running.

## Server and privacy

The blackout state and lobby settings are synchronized through a shared Firebase
database run by the mod author. Stored per lobby code: the blackout state with a
timestamp, the lobby settings, and the host key. No personal data is stored. The list
of lobby codes can't be read, and only the host can change lobby settings.
Anyone who knows a lobby code can still trigger a blackout in that lobby, so use
long codes.

## Credits

- **Created by:** Novvyy
- UE4SS (MIT License): https://github.com/UE4SS-RE/RE-UE4SS
- BPModLoaderMod (included with UE4SS)

Questions and bug reports: Nexus Mods page (POSTS / BUGS tab).
