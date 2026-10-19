# BlackoutMod sound player, started once by main.lua.
#
# - Preloads the WAV and plays it for every line written to stdin
#   (game sound assets stay silent when played through UE4SS).
# - Turns off QuickEdit for the UE4SS console this process shares with the game:
#   a click into the console starts a selection, which pauses all console output
#   and freezes the game at the mod's next print().
# Exits when the game closes (stdin closes).

param([string]$SoundFile)

try {
    Add-Type -Namespace BlackoutMod -Name Console -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr handle, uint mode);
'@
    # stdin is the pipe from the game, so open the console input directly
    # 3221225472 = GENERIC_READ | GENERIC_WRITE (0xC0000000 would be read as a negative Int32)
    $consoleInput = [BlackoutMod.Console]::CreateFile('CONIN$', 3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $mode = 0
    if ([BlackoutMod.Console]::GetConsoleMode($consoleInput, [ref]$mode)) {
        $ENABLE_QUICK_EDIT_MODE = 0x40
        $ENABLE_EXTENDED_FLAGS = 0x80  # required for the QuickEdit flag to apply
        [void][BlackoutMod.Console]::SetConsoleMode($consoleInput, ($mode -band (-bnot $ENABLE_QUICK_EDIT_MODE)) -bor $ENABLE_EXTENDED_FLAGS)
    }
} catch {
    # No console (UE4SS console disabled): nothing to fix
}

$player = New-Object Media.SoundPlayer $SoundFile
$player.Load()

while (($line = [Console]::In.ReadLine()) -ne $null) {
    $player.Play()
}
