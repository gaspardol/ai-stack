using System.Text;

namespace AIStack;

static class Paths
{
    static string Ensure(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }

    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// %LOCALAPPDATA%\AIStack on Windows; ~/Library/Application Support/AIStackHelper elsewhere (testing).
    public static string Root => OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIStack")
        : Path.Combine(Home, "Library", "Application Support", "AIStackHelper");

    public static string Meetings => Ensure(Path.Combine(Root, "data", "Meetings"));
    public static string Models => Ensure(Path.Combine(Root, "models"));
    public static string Logs => Ensure(Path.Combine(Root, "logs"));
    public static string ClaudeWorkDir => Ensure(Path.Combine(Root, "claude-workdir"));
    public static string NotesFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Meeting Notes");
}

static class Log
{
    static readonly object Gate = new();
    public static bool EchoToConsole;
    public static string FilePath => Path.Combine(Paths.Logs, "helper.log");

    public static void Info(string message) => Write("INFO", message);
    public static void Error(string message) => Write("ERROR", message);

    static void Write(string level, string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {message}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 5_000_000) info.Delete();
                File.AppendAllText(FilePath, line, Encoding.UTF8);
            }
            catch { /* logging must never break the helper */ }
        }
        // Never write to stdout in host mode: it carries the native messaging protocol.
        if (EchoToConsole) Console.Error.Write(line);
    }
}
