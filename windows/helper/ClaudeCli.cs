using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AIStack;

public sealed record ClaudeConfig(string Model, string System, string? Effort = null, bool NoThinking = false, bool KeepWarm = false);

public sealed class ClaudeException(string message) : Exception(message);

/// Runs prompts through the `claude` CLI in print mode, so requests use the user's Claude
/// subscription login. One fresh process per request; latency-sensitive configs keep a
/// pre-started process waiting on stdin.
public sealed class ClaudeCli
{
    public static readonly ClaudeCli Shared = new();

    readonly object gate = new();
    readonly Dictionary<ClaudeConfig, ClaudeProcess> warm = new();
    string? cachedBinary;

    public string? FindBinary()
    {
        lock (gate)
        {
            if (cachedBinary != null && File.Exists(cachedBinary)) return cachedBinary;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new List<string>();
        if (OperatingSystem.IsWindows())
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            candidates.AddRange([
                Path.Combine(home, ".local", "bin", "claude.exe"),
                Path.Combine(local, "Programs", "claude", "claude.exe"),
                Path.Combine(local, "AnthropicClaude", "claude.exe"),
                Path.Combine(roaming, "npm", "node_modules", "@anthropic-ai", "claude-code", "cli.js"),
            ]);
        }
        else
        {
            candidates.AddRange([
                Path.Combine(home, ".local", "bin", "claude"), Path.Combine(home, ".claude", "local", "claude"),
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            ]);
        }
        var found = candidates.FirstOrDefault(File.Exists) ?? SearchPath();
        lock (gate) cachedBinary = found;
        return found;
    }

    static string? SearchPath()
    {
        var names = OperatingSystem.IsWindows() ? new[] { "claude.exe" } : new[] { "claude" };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            foreach (var name in names)
            {
                try
                {
                    var path = Path.Combine(dir.Trim('"'), name);
                    if (File.Exists(path)) return path;
                }
                catch { }
            }
        }
        return null;
    }

    public void ResetBinaryCache()
    {
        lock (gate) cachedBinary = null;
    }

    public async Task<string> CompleteAsync(string prompt, ClaudeConfig config, TimeSpan timeout, CancellationToken cancel = default)
    {
        var binary = FindBinary() ?? throw new ClaudeException("Claude Code isn't installed on this computer. Run the AI Stack installer again.");
        ClaudeProcess? process = null;
        lock (gate)
        {
            if (warm.Remove(config, out var ready))
            {
                if (ready.IsFresh) process = ready; else ready.Kill();
            }
        }
        process ??= new ClaudeProcess(binary, config);
        if (config.KeepWarm) Prewarm(config);
        return await process.SendAsync(prompt, timeout, cancel);
    }

    public void Prewarm(ClaudeConfig config)
    {
        var binary = FindBinary();
        if (binary == null) return;
        lock (gate)
        {
            if (warm.TryGetValue(config, out var existing) && existing.IsFresh) return;
            existing?.Kill();
            try { warm[config] = new ClaudeProcess(binary, config); }
            catch (Exception ex) { Log.Error($"prewarm failed: {ex.Message}"); }
        }
    }

    public void Shutdown()
    {
        List<ClaudeProcess> all;
        lock (gate)
        {
            all = warm.Values.ToList();
            warm.Clear();
        }
        foreach (var process in all) process.Kill();
    }

    /// Runs `claude <args>` and returns stdout (used for `auth status`).
    public async Task<string?> RunAsync(params string[] args)
    {
        var binary = FindBinary();
        if (binary == null) return null;
        var info = ClaudeProcess.StartInfo(binary, args);
        using var process = Process.Start(info)!;
        process.StandardInput.Close();
        var output = await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        return output;
    }

    public async Task<(bool ok, string summary)> AuthStatusAsync()
    {
        try
        {
            var output = await RunAsync("auth", "status");
            if (output == null) return (false, "Claude Code is not installed");
            var start = output.IndexOf('{');
            var end = output.LastIndexOf('}');
            if (start < 0 || end <= start) return (false, "Could not read Claude login status");
            using var doc = JsonDocument.Parse(output[start..(end + 1)]);
            var root = doc.RootElement;
            if (!root.TryGetProperty("loggedIn", out var logged) || logged.ValueKind != JsonValueKind.True)
                return (false, "Not logged in to Claude");
            var email = root.TryGetProperty("email", out var e) ? e.GetString() : "logged in";
            var plan = root.TryGetProperty("subscriptionType", out var p) ? p.GetString() : null;
            return (true, plan != null ? $"{email} · {plan} plan" : email ?? "logged in");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }
}

sealed class ClaudeProcess
{
    readonly Process process;
    readonly TaskCompletionSource<string> result = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly StringBuilder stderr = new();
    readonly DateTime created = DateTime.UtcNow;
    volatile bool exited;

    public bool IsFresh => !exited && !result.Task.IsCompleted && DateTime.UtcNow - created < TimeSpan.FromMinutes(20);

    public static ProcessStartInfo StartInfo(string binary, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.ClaudeWorkDir,
        };
        if (binary.EndsWith(".js", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = "node";
            info.ArgumentList.Add(binary);
        }
        else
        {
            info.FileName = binary;
        }
        foreach (var arg in args) info.ArgumentList.Add(arg);
        info.Environment.Remove("CLAUDECODE");
        return info;
    }

    public ClaudeProcess(string binary, ClaudeConfig config)
    {
        var args = new List<string>
        {
            "-p", "--model", config.Model,
            "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--no-chrome",
            "--setting-sources", "", "--disable-slash-commands",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--system-prompt", config.System,
        };
        if (config.Effort != null) { args.Add("--effort"); args.Add(config.Effort); }
        var info = StartInfo(binary, args);
        if (config.NoThinking) info.Environment["MAX_THINKING_TOKENS"] = "0";

        process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => OnLine(e.Data);
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (stderr) { if (stderr.Length < 20_000) stderr.AppendLine(e.Data); }
        };
        process.Exited += (_, _) =>
        {
            exited = true;
            // Let stdout drain before deciding the process died without answering.
            Task.Delay(400).ContinueWith(_ =>
            {
                string tail;
                lock (stderr) tail = stderr.ToString().Trim();
                if (tail.Length > 400) tail = tail[^400..];
                int code;
                try { code = process.ExitCode; } catch { code = -1; }
                if (result.TrySetException(new ClaudeException($"Claude CLI exited (code {code}). {tail}")))
                    Log.Error($"claude exited {code}: {tail}");
            });
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    void OnLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line) || line[0] != '{') return;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("type", out var type) || type.GetString() != "result") return;
            var text = root.TryGetProperty("result", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() ?? "" : "";
            var isError = root.TryGetProperty("is_error", out var e) && e.ValueKind == JsonValueKind.True;
            if (isError) result.TrySetException(new ClaudeException(text.Length > 0 ? text : "Claude returned an error"));
            else result.TrySetResult(text);
            try { process.StandardInput.Close(); } catch { }
        }
        catch (JsonException) { }
    }

    public async Task<string> SendAsync(string prompt, TimeSpan timeout, CancellationToken cancel)
    {
        var message = JsonSerializer.Serialize(new { type = "user", message = new { role = "user", content = prompt } });
        try
        {
            await process.StandardInput.WriteLineAsync(message);
            await process.StandardInput.FlushAsync(cancel);
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        {
            // The process died while waiting; its exit handler sets the real error.
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        linked.CancelAfter(timeout);
        try
        {
            return await result.Task.WaitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            Kill();
            throw new ClaudeException("Claude took too long to respond.");
        }
    }

    public void Kill()
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }
}
