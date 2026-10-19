# BlackoutMod helper process, started once by main.lua and running until the game closes.
#
# - Polls the lobby's blackout state over ONE kept-alive HTTPS connection and writes it
#   to a state file for the mod. Starting curl every second costs a full TLS handshake
#   per request (~5 KB, most of the Firebase download quota); reusing the connection
#   only sends the request itself.
# - Sends the mod's blackout writes over the same connection.
# - Plays the power-down WAV (game sound assets stay silent when played through UE4SS).
# - Turns off QuickEdit for the UE4SS console this process shares with the game:
#   a click into the console starts a selection, which pauses all console output
#   and freezes the game at the mod's next print().
#
# Commands from the mod, one per line on stdin:
#   lobby <code>                 poll this lobby
#   put <true|false> <unixtime>  write the blackout state
#   play                         play the sound
# State file (one line): 1;<lobby>;<true|false|null>;<timestamp|null>;<written at, unix seconds>;end
# Exits when stdin closes (game closed).

param(
    [string]$SoundFile,
    [string]$ServerUrl,
    [string]$StateFile
)

$PollIntervalMs = 1000

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

$player = $null
try {
    $player = New-Object Media.SoundPlayer $SoundFile
    $player.Load()
} catch {
    $player = $null
}

# Windows PowerShell 5.1 may not offer TLS 1.2 by default
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(5)

# Console.In.ReadLineAsync runs synchronously in .NET Framework, a StreamReader doesn't block the loop
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
$lineTask = $stdin.ReadLineAsync()

$lobby = $null
$pollTask = $null
$pollLobby = $null
$pollClock = [Diagnostics.Stopwatch]::StartNew()
$pollNow = $false
$writeTasks = New-Object System.Collections.ArrayList

function Write-State($lobbyCode, $json) {
    $isBlackout = 'null'
    $timestamp = 'null'
    if ($json -match '"isBlackout"\s*:\s*(true|false)') { $isBlackout = $Matches[1] }
    if ($json -match '"timestamp"\s*:\s*(\d+)') { $timestamp = $Matches[1] }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [IO.File]::WriteAllText($StateFile, "1;$lobbyCode;$isBlackout;$timestamp;$now;end")
}

while ($true) {
    # Commands from the mod
    if ($lineTask.IsCompleted) {
        $line = $null
        if (-not $lineTask.IsFaulted) { $line = $lineTask.Result }
        if ($null -eq $line) { break }  # game closed

        $parts = $line.Trim().Split(' ')
        switch ($parts[0]) {
            'play' {
                if ($player) { $player.Play() }
            }
            'lobby' {
                if ($parts.Count -ge 2 -and $parts[1] -match '^[A-Za-z0-9_-]{4,8}$') {
                    $lobby = $parts[1]
                    $pollNow = $true
                }
            }
            'put' {
                if ($lobby -and $parts.Count -ge 3 -and $parts[1] -match '^(true|false)$' -and $parts[2] -match '^\d+$') {
                    $body = '{"isBlackout":' + $parts[1] + ',"timestamp":' + $parts[2] + '}'
                    $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
                    [void]$writeTasks.Add($http.PutAsync("$ServerUrl/$lobby/blackout.json", $content))
                }
            }
        }
        $lineTask = $stdin.ReadLineAsync()
        continue
    }

    # Poll the blackout state
    if ($lobby -and $null -eq $pollTask -and ($pollNow -or $pollClock.ElapsedMilliseconds -ge $PollIntervalMs)) {
        $pollNow = $false
        $pollClock.Restart()
        $pollLobby = $lobby
        $pollTask = $http.GetStringAsync("$ServerUrl/$lobby/blackout.json")
    }
    if ($pollTask -and $pollTask.IsCompleted) {
        if ($pollTask.Status -eq 'RanToCompletion' -and $pollLobby -eq $lobby) {
            try { Write-State $pollLobby $pollTask.Result } catch { }
        }
        # On errors the state file gets old and the mod falls back to curl
        $pollTask = $null
    }

    for ($i = $writeTasks.Count - 1; $i -ge 0; $i--) {
        if ($writeTasks[$i].IsCompleted) { $writeTasks.RemoveAt($i) }
    }

    Start-Sleep -Milliseconds 15
}

$http.Dispose()
