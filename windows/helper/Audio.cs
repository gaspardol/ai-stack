using System.Text.RegularExpressions;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Whisper.net;

namespace AIStack;

/// Mono float audio at the source's sample rate.
interface IAudioSource : IDisposable
{
    event Action<float[], int>? Samples;
    void Start();
    void Stop();
}

/// Windows microphone or speaker loopback (WASAPI, shared mode). Follows default-device changes.
sealed class WasapiSource(bool loopback) : IAudioSource
{
    public event Action<float[], int>? Samples;
    WasapiCapture? capture;
    string? deviceId;
    Timer? watchdog;
    volatile bool running;
    readonly object gate = new();

    string Name => loopback ? "speakers" : "microphone";

    public void Start()
    {
        running = true;
        Open();
        watchdog = new Timer(_ => CheckDefaultDevice(), null, 5000, 5000);
    }

    void Open()
    {
        lock (gate)
        {
            if (!running) return;
            try
            {
                using var enumerator = new MMDeviceEnumerator();
                var device = loopback
                    ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console)
                    : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
                deviceId = device.ID;
                capture = loopback ? new WasapiLoopbackCapture(device) : new WasapiCapture(device);
                capture.DataAvailable += OnData;
                capture.RecordingStopped += (_, e) =>
                {
                    if (e.Exception != null) Log.Error($"{Name} capture stopped: {e.Exception.Message}");
                    if (running) Task.Delay(1000).ContinueWith(_ => Reopen());
                };
                capture.StartRecording();
                Log.Info($"Capturing {Name}: {device.FriendlyName} ({capture.WaveFormat})");
            }
            catch (Exception ex)
            {
                Log.Error($"Could not capture {Name}: {ex.Message}");
            }
        }
    }

    void Reopen()
    {
        lock (gate)
        {
            if (capture != null)
            {
                capture.DataAvailable -= OnData;
                try { capture.StopRecording(); } catch { }
                capture.Dispose();
                capture = null;
            }
        }
        Open();
    }

    void CheckDefaultDevice()
    {
        if (!running) return;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var current = loopback
                ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console).ID
                : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console).ID;
            if (current != deviceId)
            {
                Log.Info($"Default {Name} changed; switching");
                Reopen();
            }
        }
        catch { }
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        var format = capture?.WaveFormat;
        if (format == null || e.BytesRecorded == 0) return;
        var mono = AudioMath.ToMono(e.Buffer, e.BytesRecorded, format);
        if (mono.Length > 0) Samples?.Invoke(mono, format.SampleRate);
    }

    public void Stop()
    {
        running = false;
        watchdog?.Dispose();
        lock (gate)
        {
            if (capture == null) return;
            capture.DataAvailable -= OnData;
            try { capture.StopRecording(); } catch { }
            capture.Dispose();
            capture = null;
        }
    }

    public void Dispose() => Stop();
}

/// Plays a 16-bit PCM WAV file in (accelerated) real time — used to test the pipeline off Windows.
sealed class FileSource(string path, double speed = 4) : IAudioSource
{
    public event Action<float[], int>? Samples;
    CancellationTokenSource? cancel;

    public void Start()
    {
        cancel = new CancellationTokenSource();
        var token = cancel.Token;
        Task.Run(async () =>
        {
            using var reader = new WaveFileReader(path);
            var format = reader.WaveFormat;
            var chunk = new byte[format.AverageBytesPerSecond / 10];
            int read;
            while (!token.IsCancellationRequested && (read = reader.Read(chunk, 0, chunk.Length)) > 0)
            {
                Samples?.Invoke(AudioMath.ToMono(chunk, read, format), format.SampleRate);
                await Task.Delay(TimeSpan.FromMilliseconds(100 / speed));
            }
            // Trailing silence so the transcriber flushes like a real call.
            for (var i = 0; i < 10 && !token.IsCancellationRequested; i++)
            {
                Samples?.Invoke(new float[format.SampleRate / 10], format.SampleRate);
                await Task.Delay(TimeSpan.FromMilliseconds(100 / speed));
            }
        });
    }

    public void Stop() => cancel?.Cancel();
    public void Dispose() => Stop();
}

static class AudioMath
{
    static readonly Guid FloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");

    public static float[] ToMono(byte[] buffer, int bytes, WaveFormat format)
    {
        var channels = Math.Max(1, format.Channels);
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
                      || (format is WaveFormatExtensible ext && ext.SubFormat == FloatSubFormat);
        var bytesPerSample = format.BitsPerSample / 8;
        if (bytesPerSample == 0) return [];
        var frames = bytes / (bytesPerSample * channels);
        var mono = new float[frames];
        for (var f = 0; f < frames; f++)
        {
            double sum = 0;
            for (var c = 0; c < channels; c++)
            {
                var offset = (f * channels + c) * bytesPerSample;
                sum += isFloat && bytesPerSample == 4 ? BitConverter.ToSingle(buffer, offset)
                    : bytesPerSample switch
                    {
                        2 => BitConverter.ToInt16(buffer, offset) / 32768.0,
                        3 => ((buffer[offset] << 8 | buffer[offset + 1] << 16 | buffer[offset + 2] << 24) >> 8) / 8388608.0,
                        4 => BitConverter.ToInt32(buffer, offset) / 2147483648.0,
                        _ => 0,
                    };
            }
            mono[f] = (float)(sum / channels);
        }
        return mono;
    }

    public static double Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (var s in samples) sum += s * s;
        return Math.Sqrt(sum / samples.Length);
    }
}

/// Streaming box-filter resampler to 16 kHz (good enough for speech recognition).
sealed class Resampler16k
{
    int inputRate;
    double step, phase, accumulator;

    public float[] Process(float[] input, int rate)
    {
        if (rate != inputRate)
        {
            inputRate = rate;
            step = rate / 16000.0;
            phase = 0;
            accumulator = 0;
        }
        if (rate == 16000) return input;
        var output = new List<float>((int)(input.Length / step) + 2);
        foreach (var x in input)
        {
            var remaining = 1.0;
            while (remaining > 1e-9)
            {
                var take = Math.Min(step - phase, remaining);
                accumulator += x * take;
                phase += take;
                remaining -= take;
                if (phase >= step - 1e-9)
                {
                    output.Add((float)(accumulator / step));
                    accumulator = 0;
                    phase = 0;
                }
            }
        }
        return output.ToArray();
    }
}

static class WhisperEngine
{
    public const string ModelFile = "ggml-small-q5_1.bin";
    public const string ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin";
    public static string ModelPath => Path.Combine(Paths.Models, ModelFile);
    public static bool ModelReady => File.Exists(ModelPath) && new FileInfo(ModelPath).Length > 50_000_000;

    static WhisperFactory? factory;
    static readonly object FactoryGate = new();
    /// One transcription at a time: whisper already uses every core it is given.
    public static readonly SemaphoreSlim Gate = new(1, 1);

    public static async Task DownloadModelAsync(Action<double>? progress = null)
    {
        if (ModelReady) return;
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        using var response = await http.GetAsync(ModelUrl, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? 190_000_000;
        var temp = ModelPath + ".download";
        await using (var input = await response.Content.ReadAsStreamAsync())
        await using (var output = File.Create(temp))
        {
            var buffer = new byte[1 << 20];
            long done = 0;
            int read;
            while ((read = await input.ReadAsync(buffer)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read));
                done += read;
                progress?.Invoke((double)done / total);
            }
        }
        File.Move(temp, ModelPath, overwrite: true);
    }

    public static WhisperProcessor CreateProcessor(string language)
    {
        lock (FactoryGate)
        {
            factory ??= WhisperFactory.FromPath(ModelPath);
            var threads = Math.Clamp(Environment.ProcessorCount - 1, 2, 8);
            var builder = factory.CreateBuilder().WithThreads(threads).WithNoContext();
            builder = language is "auto" or "" ? builder.WithLanguage("auto") : builder.WithLanguage(language);
            return builder.Build();
        }
    }
}

/// Buffers one speaker's 16 kHz audio, cuts it into ~12–20 s chunks at quiet points and transcribes them.
sealed class StreamTranscriber
{
    const int Rate = 16000;
    static readonly Regex Hallucination = new(
        @"^[\s\.\,!?…-]*$|^\s*[\[\(].*[\]\)]\s*$|sous-titr|subtitles by|amara\.org|thank you for watching|merci d'avoir regardé|^\s*(thank you|thanks|merci|you)[\s\.!]*$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    readonly string speaker;
    readonly string language;
    readonly Action<Segment> onSegment;
    readonly Resampler16k resampler = new();
    readonly List<float> buffer = [];
    readonly Channel<(float[] samples, double offset)> chunks = Channel.CreateUnbounded<(float[], double)>();
    readonly Task worker;
    readonly object gate = new();
    DateTime? streamStart;
    long emittedSamples;

    public StreamTranscriber(string speaker, string language, Action<Segment> onSegment)
    {
        this.speaker = speaker;
        this.language = language;
        this.onSegment = onSegment;
        worker = Task.Run(WorkAsync);
    }

    public void Append(float[] samples, int rate)
    {
        var resampled = resampler.Process(samples, rate);
        lock (gate)
        {
            streamStart ??= DateTime.UtcNow - TimeSpan.FromSeconds((double)resampled.Length / Rate);
            buffer.AddRange(resampled);
            if (buffer.Count < 12 * Rate) return;
            var cut = FindCut();
            if (cut > 0) Emit(cut);
        }
    }

    /// Quietest 0.3 s window between 12 s and 20 s; forced cut at 20 s.
    int FindCut()
    {
        const int window = Rate * 3 / 10;
        var span = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(buffer);
        var best = -1;
        var bestRms = double.MaxValue;
        for (var start = 12 * Rate; start + window <= span.Length && start < 20 * Rate; start += window / 2)
        {
            var rms = AudioMath.Rms(span.Slice(start, window));
            if (rms < bestRms) { bestRms = rms; best = start + window / 2; }
        }
        if (bestRms < 0.004) return best;
        return buffer.Count >= 20 * Rate ? best : -1;
    }

    void Emit(int count)
    {
        var chunk = buffer.GetRange(0, count).ToArray();
        buffer.RemoveRange(0, count);
        var offset = (double)emittedSamples / Rate;
        emittedSamples += count;
        chunks.Writer.TryWrite((chunk, offset));
    }

    public async Task FlushAsync()
    {
        lock (gate)
        {
            if (buffer.Count > Rate / 2) Emit(buffer.Count);
            buffer.Clear();
        }
        chunks.Writer.TryComplete();
        await worker;
    }

    async Task WorkAsync()
    {
        WhisperProcessor? processor = null;
        try
        {
            await foreach (var (samples, offset) in chunks.Reader.ReadAllAsync())
            {
                if (AudioMath.Rms(samples) < 0.0025) continue; // silence: skip (and avoid whisper hallucinations)
                await WhisperEngine.Gate.WaitAsync();
                try
                {
                    processor ??= WhisperEngine.CreateProcessor(language);
                    var started = DateTime.UtcNow;
                    var origin = streamStart ?? DateTime.UtcNow;
                    await foreach (var segment in processor.ProcessAsync(samples))
                    {
                        var text = segment.Text.Trim();
                        if (text.Length == 0 || Hallucination.IsMatch(text)) continue;
                        onSegment(new Segment
                        {
                            Speaker = speaker,
                            Start = origin + TimeSpan.FromSeconds(offset) + segment.Start,
                            End = origin + TimeSpan.FromSeconds(offset) + segment.End,
                            Text = text,
                        });
                    }
                    Log.Info($"{speaker}: transcribed {samples.Length / (double)Rate:F1}s in {(DateTime.UtcNow - started).TotalSeconds:F1}s");
                }
                catch (Exception ex)
                {
                    Log.Error($"Transcription failed ({speaker}): {ex.Message}");
                }
                finally
                {
                    WhisperEngine.Gate.Release();
                }
            }
        }
        finally
        {
            if (processor != null) await processor.DisposeAsync();
        }
    }
}

/// One live meeting: mic ("me") + speakers ("them") → transcribers → segments on the meeting.
sealed class MeetingSession
{
    public Meeting Meeting { get; }
    readonly List<IAudioSource> sources = [];
    readonly StreamTranscriber me;
    readonly StreamTranscriber them;

    public MeetingSession(Meeting meeting, Action<Segment> onSegment)
    {
        Meeting = meeting;
        me = new StreamTranscriber("me", meeting.Language, onSegment);
        them = new StreamTranscriber("them", meeting.Language, onSegment);
    }

    public void Start()
    {
        IAudioSource? mic = null, speakers = null;
        var fakeMe = Environment.GetEnvironmentVariable("AISTACK_FAKE_AUDIO_ME");
        var fakeThem = Environment.GetEnvironmentVariable("AISTACK_FAKE_AUDIO_THEM");
        if (fakeMe != null || fakeThem != null)
        {
            if (fakeMe != null) mic = new FileSource(fakeMe);
            if (fakeThem != null) speakers = new FileSource(fakeThem);
        }
        else if (OperatingSystem.IsWindows())
        {
            mic = new WasapiSource(loopback: false);
            speakers = new WasapiSource(loopback: true);
        }
        else
        {
            Log.Error("No audio capture on this platform (set AISTACK_FAKE_AUDIO_* to test)");
        }
        if (mic != null) { mic.Samples += me.Append; sources.Add(mic); }
        if (speakers != null) { speakers.Samples += them.Append; sources.Add(speakers); }
        foreach (var source in sources) source.Start();
    }

    public async Task StopAsync()
    {
        foreach (var source in sources) source.Stop();
        await Task.WhenAll(me.FlushAsync(), them.FlushAsync());
        foreach (var source in sources) source.Dispose();
    }
}
