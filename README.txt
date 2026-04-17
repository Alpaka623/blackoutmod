# BlackoutMod - Installation Package

## Quick Installation (Recommended)

1. **Extract this entire folder** to your Desktop or Downloads
2. **Double-click `install.hta`**
3. If Windows shows a security warning:
   - Click "Run"
4. Follow the on-screen instructions
5. The installer will:
   - Automatically install UE4SS (included in this package)
   - Find your LOCKDOWN Protocol installation
   - Copy all files to the correct locations
   - Ask for your lobby code (simple 4-8 digit code)
   - Configure everything automatically

**Can't find your game folder?**
Open Steam → Right-click LOCKDOWN Protocol → Manage → Browse local files

## Windows SmartScreen Warning

When you run `install.hta`, Windows may show a security warning. This is normal for unsigned scripts.

This happens because the files aren't digitally signed (which costs $300-500/year). The mod is safe.

## Alternative: Manual Launcher

If you don't trust the automatic installers:
1. Rename `install.bat.txt` to `install.bat`
2. Run `install.bat`
3. Follow the prompts

## Package Contents

```
BlackoutMod/
├── install.hta              <- Run this!
├── install.bat.txt          <- Manual option (rename to .bat)
├── README.md                <- You are here
├── Dependencies/
│   └── UE4SS/               <- UE4SS Experimental (included!)
│       ├── dwmapi.dll
│       └── ue4ss/
│           └── Mods/
│               └── BPModLoaderMod/  <- Also included!
├── Mods/
│   └── BlackoutMod/
│       ├── Scripts/
│       │   └── main.lua     (Lua mod)
│       ├── enabled.txt
│       └── config.txt       (Created by installer)
└── LogicMods/
    ├── BlackoutMod.pak      (Blueprint HUD)
    ├── BlackoutMod.ucas
    └── BlackoutMod.utoc
```

## How Lobby Codes Work

**No complex setup required!** This mod uses a shared server (hosted by me) with simple lobby codes.

### For Hosts:
1. Run installer
2. Choose a unique lobby code (e.g., `1234`, `5678`, `mygroup`)
3. Share the code with your friends
4. Play!

### For Players:
1. Run installer
2. Enter the SAME code your host gave you
3. Play!

**That's it!** Everyone with the same code will be synchronized.

### Lobby Code Tips:
- Use unique codes like `8472`, `test`, `mygroup`
- 4-8 characters: Letters and numbers OK
- Case-sensitive: `Test` ≠ `test`

### Changing Your Lobby Code:

Location: LOCKDOWN Protocol\...\ue4ss\Mods\BlackoutMod\config.txt
Change the code, save, restart game

**Note:** Always restart the game after changing your lobby code!

## Manual Installation (If installer doesn't work)

### Step 1: Install UE4SS

Copy everything from `Dependencies\UE4SS\` to:
```
LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64\
```

You should have:
- `...\Win64\dwmapi.dll`
- `...\Win64\ue4ss\` (folder)

### Step 2: Copy Lua Mod

Copy the `Mods\BlackoutMod` folder to:
```
LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64\ue4ss\Mods\
```

Final path should be:
```
...\Win64\ue4ss\Mods\BlackoutMod\Scripts\main.lua
```

**Can't find your game folder?**
Open Steam → Right-click LOCKDOWN Protocol → Manage → Browse local files

### Step 3: Copy Blueprint Mod

Copy the 3 files from `LogicMods\` to:
```
LOCKDOWN Protocol\LockdownProtocol\Content\Paks\LogicMods\
```

(Create the `LogicMods` folder if it doesn't exist)

### Step 4: Create config.txt

Create a file named `config.txt` in:
```
...\Win64\ue4ss\Mods\BlackoutMod\config.txt
```

Content of config.txt (just the code, nothing else):
```
1234
```

Replace `1234` with your chosen lobby code.

## How to Use In-Game

**Keybinds:**
- **O** - Sabotage (Dissident only, when near defibrillator)
- **P** - Manual Repair (emergency)
- **L** - Show how to change lobby code
- **I** - Debug Info (check code & sync status)

**How it works:**
1. Join a game as DISSIDENT
2. Walk to a defibrillator
3. Press **O** to sabotage
4. All lights turn off for everyone (with same lobby code)
5. Lights come back on when:
   - Someone dies
   - Batteries are inserted
   - Players return to lobby

## Playing With Friends

### Setup (One Time):

**Host:**
1. Choose a unique lobby code (e.g., `5678`)
2. Run installer, enter `5678`
3. Tell friends: "Lobby code is 5678"

**Friends:**
1. Run installer
2. Enter `5678` (the same code!)
3. Done!

### Every Game Session:

Everyone just starts the game - no setup needed!

**To verify everyone is synced:**
- Press **I** in-game
- Check "Lobby Code" matches
- Should all show the same code

## Troubleshooting

**Installer can't find the game:**
- Enter the path manually when prompted
- Example: `D:\Steam\steamapps\common\LOCKDOWN Protocol`

**"Access Denied" error:**
- The installer needs write permissions
- Try running as Administrator
- Or use manual installation

**Mod doesn't load in-game:**
- Check UE4SS console (opens with the game)
- Should say "BlackoutMod LOADED"
- Should show "Loaded Lobby Code: XXXX"
- If not, verify file paths above

**Widget doesn't appear:**
- Make sure you're playing as Dissident
- Stand near a defibrillator
- Check that BPModLoaderMod is loaded (press I in-game)

**Lights don't turn off:**
- Press **I** to check lobby code
- Make sure curl is working (usually pre-installed on Windows 10/11)
- Check UE4SS console for error messages

**Blackout not syncing between players:**
- **Most common issue**: Different lobby codes!
  - Everyone press **I** in-game
  - Compare lobby codes
  - Must be EXACTLY the same (case-sensitive!)
- Make sure everyone restarted game after setting code
- Codes like `0000` are public - everyone using it will sync

**"Server Response: null":**
- This is normal on first sabotage
- The server creates data on first write
- If it persists after sabotage, check your internet connection

**Sabotage doesn't work at all:**
- Check you're Dissident (press I)
- Stand close to defibrillator
- If you already sabotaged this round, you can't do it again (by default)

## Configuration Options

Edit `main.lua` to customize:

**Unlimited sabotage:**
```lua
local EnableOneTimePerRound = false  -- Change true to false
```

**Interaction range:**
```lua
local InteractionDistance = 300.0  -- Increase for longer range
```

**Server sync speed:**
```lua
local PollInterval = 500  -- Lower = faster sync (more requests)
                         -- 500ms = 2 checks per second (recommended)
                         -- 200ms = 5 checks per second (faster but more traffic)
```

**Note:** Restart game after changing settings.

## Privacy & Server

**Your data:**
- Only your lobby code and blackout state are stored
- No personal information is collected

**Server:**
- Hosted by me using Firebase
- Free for everyone
- Handles 100+ concurrent players easily

## Uninstalling

**Remove BlackoutMod only:**
Delete these folders/files:
```
...\Win64\ue4ss\Mods\BlackoutMod
...\Content\Paks\LogicMods\BlackoutMod.*
```

**Remove everything (including UE4SS):**
Delete:
```
...\Win64\dwmapi.dll
...\Win64\ue4ss\
...\Content\Paks\LogicMods\BlackoutMod.*
```

## Technical Details

**How it works:**
- Shared Firebase Realtime Database (hosted by mod creator)
- Each lobby code gets its own isolated data path
- 500ms polling interval (2 checks per second)
- Automatic sync when lights are toggled
- No authentication required

**Performance:**
- Minimal impact on game FPS
- Lights toggle in batches (smooth transitions)
- Low bandwidth usage (~1-2 KB per check)
- Scales well with many players

## Credits

**Includes:**
- UE4SS (MIT License) - https://github.com/UE4SS-RE/RE-UE4SS
- BPModLoaderMod (included with UE4SS)
- Firebase Realtime Database (for sync)

**Created by:** Novvyy

## Support

For help, visit the Nexus Mods page:
- POSTS tab for questions
- BUGS tab for issues
- Check if others have the same problem

**Common issues are usually:**
1. Lobby codes don't match (press I to check)
2. Game not restarted after changing code
3. UE4SS not installed correctly

Enjoy sabotaging!