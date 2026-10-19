// BlackoutMod helper process, started once by main.lua and running until the game closes.
// Build: tools\build_helper.bat (uses the C# compiler that ships with .NET Framework 4.x).
//
// Replaces blackout_helper.ps1: Avast flagged the game starting PowerShell with
// "-ExecutionPolicy Bypass" (IDP.Generic). Same job, plain program:
// - Polls the lobby's blackout state over ONE kept-alive HTTPS connection and writes it
//   to a state file for the mod (a new curl per second cost a TLS handshake each time).
// - Sends the mod's blackout writes over the same connection.
// - Plays the power-down WAV (game sound assets stay silent when played through UE4SS).
// - Turns off QuickEdit for the UE4SS console: a click into it starts a selection,
//   which pauses console output and freezes the game at the mod's next print().
// - Exits when stdin closes or the game process is gone, and doesn't keep the game
//   folder as working directory (a leftover process locked it after a crash).
//
// Usage: BlackoutHelper.exe <sound.wav> <server url> <state file>
// Commands on stdin, one per line:
//   lobby <code>                 poll this lobby
//   put <true|false> <unixtime>  write the blackout state
//   play                         play the sound
// State file (one line): 1;<lobby>;<true|false|null>;<timestamp|null>;<written at, unix seconds>;end

using System;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class BlackoutHelper
{
    const int PollIntervalMs = 1000;
    const int GameCheckIntervalMs = 1000;

    static readonly object Lock = new object();
    static string lobby = null;
    static bool pollNow = false;

    static HttpClient http;
    static SoundPlayer player;
    static string serverUrl;
    static string stateFile;
    static StreamReader stdin;

    static int Main(string[] args)
    {
        if (args.Length < 3) return 1;

        // Resolve paths against the game folder before leaving it
        string soundFile = Path.GetFullPath(args[0]);
        serverUrl = args[1].TrimEnd('/');
        stateFile = Path.GetFullPath(args[2]);
        try { Environment.CurrentDirectory = Path.GetTempPath(); } catch { }

        // Open the stdin pipe before AttachConsole, which could otherwise replace the standard handles
        stdin = new StreamReader(Console.OpenStandardInput());
        DisableQuickEdit();

        try
        {
            player = new SoundPlayer(soundFile);
            player.Load();
        }
        catch { player = null; }

        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        http = new HttpClient();
        http.Timeout = TimeSpan.FromSeconds(5);

        Process game = FindGameProcess();

        Thread reader = new Thread(ReadCommands);
        reader.IsBackground = true;
        reader.Start();

        Stopwatch pollClock = Stopwatch.StartNew();
        Stopwatch gameClock = Stopwatch.StartNew();

        while (true)
        {
            if (game != null && gameClock.ElapsedMilliseconds >= GameCheckIntervalMs)
            {
                gameClock.Restart();
                bool exited = true;
                try { exited = game.HasExited; } catch { }
                if (exited) return 0;
            }

            string pollLobby = null;
            lock (Lock)
            {
                if (lobby != null && (pollNow || pollClock.ElapsedMilliseconds >= PollIntervalMs))
                {
                    pollNow = false;
                    pollClock.Restart();
                    pollLobby = lobby;
                }
            }

            if (pollLobby != null)
            {
                try
                {
                    string json = http.GetStringAsync(serverUrl + "/" + pollLobby + "/blackout.json").Result;
                    lock (Lock)
                    {
                        // Skip results for a lobby that was changed meanwhile
                        if (pollLobby == lobby) WriteState(pollLobby, json);
                    }
                }
                catch
                {
                    // On errors the state file gets old and the mod falls back to curl
                }
            }

            Thread.Sleep(15);
        }
    }

    static void ReadCommands()
    {
        string line;
        while ((line = stdin.ReadLine()) != null)
        {
            string[] parts = line.Trim().Split(' ');
            try
            {
                if (parts[0] == "play")
                {
                    if (player != null) player.Play();
                }
                else if (parts[0] == "lobby" && parts.Length >= 2 && Regex.IsMatch(parts[1], "^[A-Za-z0-9_-]{4,8}$"))
                {
                    lock (Lock)
                    {
                        lobby = parts[1];
                        pollNow = true;
                    }
                }
                else if (parts[0] == "put" && parts.Length >= 3
                    && (parts[1] == "true" || parts[1] == "false") && Regex.IsMatch(parts[2], "^[0-9]+$"))
                {
                    string target;
                    lock (Lock) { target = lobby; }
                    if (target != null)
                    {
                        string body = "{\"isBlackout\":" + parts[1] + ",\"timestamp\":" + parts[2] + "}";
                        StringContent content = new StringContent(body, Encoding.UTF8, "application/json");
                        http.PutAsync(serverUrl + "/" + target + "/blackout.json", content);  // fire and forget
                    }
                }
            }
            catch { }
        }

        // stdin closed: the game is gone
        Environment.Exit(0);
    }

    static void WriteState(string lobbyCode, string json)
    {
        string isBlackout = "null";
        string timestamp = "null";
        Match m = Regex.Match(json, "\"isBlackout\"\\s*:\\s*(true|false)");
        if (m.Success) isBlackout = m.Groups[1].Value;
        m = Regex.Match(json, "\"timestamp\"\\s*:\\s*([0-9]+)");
        if (m.Success) timestamp = m.Groups[1].Value;

        long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        try { File.WriteAllText(stateFile, "1;" + lobbyCode + ";" + isBlackout + ";" + timestamp + ";" + now + ";end"); }
        catch { }
    }

    // ------------------------------------------------------------ game process

    // The mod starts us through "cmd /c", so the game is the first ancestor that isn't cmd/conhost
    static Process FindGameProcess()
    {
        try
        {
            int pid = Process.GetCurrentProcess().Id;
            for (int depth = 0; depth < 4; depth++)
            {
                pid = GetParentProcessId(pid);
                if (pid <= 0) return null;
                Process parent = Process.GetProcessById(pid);
                string name = parent.ProcessName.ToLowerInvariant();
                if (name != "cmd" && name != "conhost") return parent;
            }
        }
        catch { }
        return null;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    const uint TH32CS_SNAPPROCESS = 0x2;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    static int GetParentProcessId(int pid)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return -1;
        try
        {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (!Process32FirstW(snapshot, ref entry)) return -1;
            do
            {
                if (entry.th32ProcessID == (uint)pid) return (int)entry.th32ParentProcessID;
            } while (Process32NextW(snapshot, ref entry));
        }
        finally { CloseHandle(snapshot); }
        return -1;
    }

    // ------------------------------------------------------------ console

    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll")]
    static extern bool GetConsoleMode(IntPtr handle, out uint mode);

    [DllImport("kernel32.dll")]
    static extern bool SetConsoleMode(IntPtr handle, uint mode);

    static void DisableQuickEdit()
    {
        try
        {
            // Built as a window-less program (never opens a console window of its own),
            // so attach to the console of the cmd.exe that started us: the UE4SS console
            AttachConsole(-1);  // ATTACH_PARENT_PROCESS

            const uint GENERIC_READ_WRITE = 0xC0000000;
            const uint OPEN_EXISTING = 3;
            IntPtr input = CreateFileW("CONIN$", GENERIC_READ_WRITE, 3, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            uint mode;
            if (GetConsoleMode(input, out mode))
            {
                const uint ENABLE_QUICK_EDIT_MODE = 0x40;
                const uint ENABLE_EXTENDED_FLAGS = 0x80;  // required for the QuickEdit flag to apply
                SetConsoleMode(input, (mode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS);
            }
        }
        catch { }
    }
}
