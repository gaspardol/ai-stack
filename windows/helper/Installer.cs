using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace AIStack;

/// Interactive setup on Windows (double-click "Install AI Stack.cmd").
static class Installer
{
    public const string HostName = "com.aistack.helper";
    public const string ExtensionId = "mpmhghloimnhohlponihpanbbmcbadnm";

    static void Step(int n, string text)
    {
        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine($"\n[{n}/6] {text}");
        Console.ResetColor();
    }

    static void Ok(string text) { Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine($"   ✓ {text}"); Console.ResetColor(); }
    static void Warn(string text) { Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine($"   ! {text}"); Console.ResetColor(); }
    static void Info(string text) => Console.WriteLine($"   {text}");

    static bool Ask(string question)
    {
        Console.Write($"   {question} [Y/n] ");
        var answer = Console.ReadLine()?.Trim().ToLowerInvariant();
        return answer is null or "" or "y" or "yes" or "o" or "oui";
    }

    public static async Task RunAsync()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.WriteLine("The installer runs on Windows. On other systems use --register-test <chrome-user-data-dir>.");
            return;
        }
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.Title = "AI Stack setup";
        Console.WriteLine("AI Stack for Windows — writing assistant + meeting notes, powered by your Claude subscription.");

        var installRoot = Paths.Root;
        var helperDir = Path.Combine(installRoot, "helper");
        var extensionDir = Path.Combine(installRoot, "extension");
        var packageDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));

        Step(1, "Installing files");
        try
        {
            foreach (var other in Process.GetProcessesByName("AIStackHelper").Where(p => p.Id != Environment.ProcessId))
            {
                try { other.Kill(); other.WaitForExit(3000); } catch { }
            }
            var runningFromInstall = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\')
                .Equals(Path.GetFullPath(helperDir).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            if (!runningFromInstall)
            {
                CopyDirectory(AppContext.BaseDirectory, helperDir);
                var packagedExtension = Path.Combine(packageDir, "extension");
                if (Directory.Exists(packagedExtension)) CopyDirectory(packagedExtension, extensionDir);
            }
            Ok($"Installed to {installRoot}");
        }
        catch (Exception ex)
        {
            Warn($"Could not copy files ({ex.Message}). Close Chrome and run the installer again.");
            Pause();
            return;
        }

        Step(2, "Connecting the helper to Chrome");
        var exePath = Path.Combine(helperDir, "AIStackHelper.exe");
        var manifestPath = Path.Combine(installRoot, $"{HostName}.json");
        WriteHostManifest(manifestPath, exePath);
        using (var key = Registry.CurrentUser.CreateSubKey($@"Software\Google\Chrome\NativeMessagingHosts\{HostName}"))
            key.SetValue("", manifestPath);
        Ok("Chrome can now start the AI Stack helper");

        Step(3, "Checking the Microsoft Visual C++ runtime (needed for on-device transcription)");
        await EnsureVcRuntimeAsync();

        Step(4, "Claude Code (uses your Claude subscription)");
        await EnsureClaudeAsync();

        Step(5, "Downloading the speech recognition model (~180 MB, one time)");
        if (WhisperEngine.ModelReady)
        {
            Ok("Already downloaded");
        }
        else
        {
            try
            {
                var last = -1;
                await WhisperEngine.DownloadModelAsync(p =>
                {
                    var pct = (int)(p * 100);
                    if (pct == last) return;
                    last = pct;
                    Console.Write($"\r   {new string('█', pct / 4)}{new string('░', 25 - pct / 4)} {pct}%  ");
                });
                Console.WriteLine();
                Ok("Model ready");
            }
            catch (Exception ex)
            {
                Warn($"Download failed ({ex.Message}). It will retry automatically at your first call.");
            }
        }

        Step(6, "Add the extension to Chrome (one time)");
        Info("Chrome is opening its Extensions page. There:");
        Info("  1. Turn on \"Developer mode\" (top-right switch)");
        Info("  2. Click \"Load unpacked\"");
        Info($"  3. Pick this folder (its path is in your clipboard):  {extensionDir}");
        Info("  4. Pin AI Stack (puzzle icon → pin) so its button stays visible.");
        CopyToClipboard(extensionDir);
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{installRoot}\"") { UseShellExecute = true }); } catch { }
        OpenChromeExtensionsPage();

        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine("\nAll set. Underlines appear as you type in Chrome; calls in Meet / Teams / Zoom get notes automatically.");
        Console.ResetColor();
        Console.WriteLine($"Notes are saved in {Paths.NotesFolder}. Logs: {Log.FilePath}");
        Pause();
    }

    static void Pause()
    {
        Console.Write("\nPress Enter to close.");
        Console.ReadLine();
    }

    public static void WriteHostManifest(string manifestPath, string exePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(manifestPath)!);
        var manifest = new JsonObject
        {
            ["name"] = HostName,
            ["description"] = "AI Stack helper (Claude + meeting transcription)",
            ["path"] = exePath,
            ["type"] = "stdio",
            ["allowed_origins"] = new JsonArray($"chrome-extension://{ExtensionId}/"),
        };
        File.WriteAllText(manifestPath, manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    /// Registers the native host for a Chrome profile directory (macOS/Linux testing).
    public static void RegisterForChromeDir(string userDataDir)
    {
        var exe = Environment.ProcessPath!;
        var path = Path.Combine(userDataDir, "NativeMessagingHosts", $"{HostName}.json");
        WriteHostManifest(path, exe);
        Console.WriteLine($"Registered {exe} in {path}");
    }

    public static void Uninstall()
    {
        if (!OperatingSystem.IsWindows()) return;
        Registry.CurrentUser.DeleteSubKeyTree($@"Software\Google\Chrome\NativeMessagingHosts\{HostName}", throwOnMissingSubKey: false);
        Console.WriteLine($"Removed the Chrome registration. Delete {Paths.Root} to remove all files (your notes stay in {Paths.NotesFolder}).");
    }

    static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var dir in Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dir.Replace(source.TrimEnd('\\', '/'), destination));
        foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = file.Replace(source.TrimEnd('\\', '/'), destination);
            File.Copy(file, target, overwrite: true);
            // Drop the "downloaded from the internet" mark copied along from the zip.
            try { File.Delete(target + ":Zone.Identifier"); } catch { }
        }
    }

    static async Task EnsureVcRuntimeAsync()
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var needed = new[] { "vcruntime140.dll", "msvcp140.dll", "vcomp140.dll" };
        if (needed.All(f => File.Exists(Path.Combine(system, f))))
        {
            Ok("Installed");
            return;
        }
        var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
        Info("Downloading the Visual C++ runtime from Microsoft…");
        var file = Path.Combine(Path.GetTempPath(), $"vc_redist.{arch}.exe");
        try
        {
            using var http = new HttpClient();
            await File.WriteAllBytesAsync(file, await http.GetByteArrayAsync($"https://aka.ms/vs/17/release/vc_redist.{arch}.exe"));
            Info("Installing (Windows may ask for permission)…");
            using var process = Process.Start(new ProcessStartInfo(file, "/install /passive /norestart") { UseShellExecute = true, Verb = "runas" });
            process?.WaitForExit();
            Ok("Visual C++ runtime installed");
        }
        catch (Exception ex)
        {
            Warn($"Could not install it automatically ({ex.Message}). Install \"Microsoft Visual C++ Redistributable\" from microsoft.com, then run this installer again.");
        }
    }

    static async Task EnsureClaudeAsync()
    {
        var cli = ClaudeCli.Shared;
        if (cli.FindBinary() == null)
        {
            Warn("Claude Code is not installed.");
            if (Ask("Install it now with the official installer from claude.ai?"))
            {
                using var install = Process.Start(new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -Command \"irm https://claude.ai/install.ps1 | iex\"") { UseShellExecute = false });
                install?.WaitForExit();
                cli.ResetBinaryCache();
            }
        }
        var binary = cli.FindBinary();
        if (binary == null)
        {
            Warn("Claude Code still not found. Install it from https://claude.com/claude-code, then run this installer again.");
            return;
        }
        Ok($"Found {binary}");

        var (loggedIn, summary) = await cli.AuthStatusAsync();
        if (!loggedIn)
        {
            Info("Log in with your Claude account (the one with your subscription). A browser window will open.");
            using var login = Process.Start(new ProcessStartInfo(binary, "auth login") { UseShellExecute = false });
            login?.WaitForExit();
            (loggedIn, summary) = await cli.AuthStatusAsync();
        }
        if (!loggedIn)
        {
            Warn($"Not logged in ({summary}). Open a terminal, run `claude`, log in, then run this installer again.");
            return;
        }
        Ok($"Logged in: {summary}");

        try
        {
            var started = DateTime.UtcNow;
            var reply = await cli.CompleteAsync("Reply with exactly: OK",
                new ClaudeConfig("haiku", "You are a connectivity test.", "low", NoThinking: true), TimeSpan.FromSeconds(90));
            Ok($"Test request answered “{reply.Trim()}” in {(DateTime.UtcNow - started).TotalSeconds:F1}s");
        }
        catch (Exception ex)
        {
            Warn($"Test request failed: {ex.Message}");
            if (ex.Message.Contains("git", StringComparison.OrdinalIgnoreCase) && Ask("Claude Code needs Git for Windows. Install it now (winget)?"))
            {
                using var git = Process.Start(new ProcessStartInfo("winget", "install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements") { UseShellExecute = false });
                git?.WaitForExit();
                Info("Git installed. Run this installer again to finish the check.");
            }
        }
    }

    static void CopyToClipboard(string text)
    {
        try
        {
            using var clip = Process.Start(new ProcessStartInfo("cmd.exe", "/c clip") { RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true });
            clip!.StandardInput.Write(text);
            clip.StandardInput.Close();
            clip.WaitForExit(2000);
        }
        catch { }
    }

    static void OpenChromeExtensionsPage()
    {
        var candidates = new List<string>();
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe");
            if (key?.GetValue("") is string path) candidates.Add(path);
        }
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Google\Chrome\Application\chrome.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Google\Chrome\Application\chrome.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Google\Chrome\Application\chrome.exe"));
        var chrome = candidates.FirstOrDefault(File.Exists);
        if (chrome == null)
        {
            Warn("Chrome not found — open chrome://extensions yourself.");
            return;
        }
        try { Process.Start(new ProcessStartInfo(chrome, "chrome://extensions") { UseShellExecute = false }); }
        catch (Exception ex) { Warn($"Could not open Chrome ({ex.Message}) — open chrome://extensions yourself."); }
    }
}
