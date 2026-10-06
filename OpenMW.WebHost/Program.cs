using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var repoRoot = Path.GetFullPath(Path.Combine(app.Environment.ContentRootPath, ".."));
var playRoot = Path.Combine(repoRoot, "play");
var rendererRoot = Path.Combine(repoRoot, "render", "webgpu");
var manager = new EngineManager(repoRoot, builder.Configuration, app.Logger);
var gameData = new GameDataManager(repoRoot, builder.Configuration, app.Logger);
gameData.Detect();
// Bump whenever local file-serving semantics change. The browser StreamFS
// persists chunks by URL + size, so a bad development response would otherwise
// survive every server restart and continue corrupting ESM/BSA reads.
const string localAssetRevision = "asp-range-v2";
var contentTypes = new FileExtensionContentTypeProvider();
contentTypes.Mappings[".wasm"] = "application/wasm";
contentTypes.Mappings[".data"] = "application/octet-stream";
contentTypes.Mappings[".wgsl"] = "text/plain; charset=utf-8";
contentTypes.Mappings[".esm"] = "application/octet-stream";
contentTypes.Mappings[".esp"] = "application/octet-stream";
contentTypes.Mappings[".bsa"] = "application/octet-stream";

app.Use(async (context, next) =>
{
    // OpenMW's pthread-enabled WebAssembly build requires cross-origin isolation.
    context.Response.Headers["Cross-Origin-Opener-Policy"] = "same-origin";
    context.Response.Headers["Cross-Origin-Embedder-Policy"] = "require-corp";
    context.Response.Headers["Cross-Origin-Resource-Policy"] = "same-origin";
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    await next();
});

// /index.html is the URL used by the launcher. Intercept it before
// StaticFileMiddleware so the raw authored page cannot bypass engine selection
// and renderer stamping. "/" is handled by the endpoint below.
app.Use(async (context, next) =>
{
    if (!String.Equals(context.Request.Path.Value, "/index.html", StringComparison.OrdinalIgnoreCase))
    {
        await next();
        return;
    }

    var engine = manager.Current;
    if (engine is null)
    {
        context.Response.ContentType = "text/html; charset=utf-8";
        context.Response.StatusCode = manager.BuildFailed ? 500 : 503;
        await context.Response.WriteAsync(manager.StartupPage());
        return;
    }

    var source = Path.Combine(playRoot, "index.html");
    if (!File.Exists(source))
    {
        context.Response.StatusCode = 500;
        await context.Response.WriteAsync("play/index.html is missing.");
        return;
    }

    var page = await File.ReadAllTextAsync(source, context.RequestAborted);
    const string rendererMarker = "const rendererDirectory = './' + __ENGINE_DIR + 'webgpu/';";
    page = page.Replace("__ENGINE_VERSION__", engine.Version, StringComparison.Ordinal)
               .Replace(rendererMarker, "const rendererDirectory = './webgpu/';", StringComparison.Ordinal)
               .Replace("StreamFS.mount('/mwdata/' + f.p, 'mwdata/' + f.p, f.s);",
                        "StreamFS.mount('/mwdata/' + f.p, 'mwdata/' + f.p + '?rev=" + localAssetRevision + "', f.s);",
                        StringComparison.Ordinal);
    context.Response.ContentType = "text/html; charset=utf-8";
    context.Response.Headers["Cache-Control"] = "no-store";
    await context.Response.WriteAsync(page);
});

if (Directory.Exists(playRoot))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider(playRoot),
        ContentTypeProvider = contentTypes,
        ServeUnknownFileTypes = true,
        DefaultContentType = "application/octet-stream"
    });
}

if (Directory.Exists(rendererRoot))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider(rendererRoot),
        RequestPath = "/webgpu",
        ContentTypeProvider = contentTypes,
        ServeUnknownFileTypes = false,
        OnPrepareResponse = context =>
        {
            // Renderer/WGSL edits are the normal development loop. Never let a
            // browser 304 hide a newly pulled shader or host fix.
            context.Context.Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate";
            context.Context.Response.Headers["Pragma"] = "no-cache";
            context.Context.Response.Headers["Expires"] = "0";
        }
    });
}

app.MapGet("/", async context =>
{
    var engine = manager.Current;
    if (engine is null)
    {
        context.Response.ContentType = "text/html; charset=utf-8";
        context.Response.StatusCode = manager.BuildFailed ? 500 : 503;
        await context.Response.WriteAsync(manager.StartupPage());
        return;
    }

    var source = Path.Combine(playRoot, "index.html");
    if (!File.Exists(source))
    {
        context.Response.StatusCode = 500;
        await context.Response.WriteAsync("play/index.html is missing.");
        return;
    }

    var page = await File.ReadAllTextAsync(source, context.RequestAborted);
    const string rendererMarker = "const rendererDirectory = './' + __ENGINE_DIR + 'webgpu/';";
    page = page.Replace("__ENGINE_VERSION__", engine.Version, StringComparison.Ordinal)
               .Replace(rendererMarker, "const rendererDirectory = './webgpu/';", StringComparison.Ordinal)
               .Replace("StreamFS.mount('/mwdata/' + f.p, 'mwdata/' + f.p, f.s);",
                        "StreamFS.mount('/mwdata/' + f.p, 'mwdata/' + f.p + '?rev=" + localAssetRevision + "', f.s);",
                        StringComparison.Ordinal);
    context.Response.ContentType = "text/html; charset=utf-8";
    context.Response.Headers["Cache-Control"] = "no-store";
    await context.Response.WriteAsync(page);
});

app.MapGet("/status", () => Results.Json(new { engine = manager.Status, gameData = gameData.Status }));

// Optional local asset pack. The browser probes both URLs with a Range
// request and simply continues without the pack when it is absent.
app.MapGet("/moddata/{**asset}", async (HttpContext context, string asset) =>
{
    await SendRepositoryFile(context, Path.Combine(playRoot, "moddata"), asset, contentTypes);
});
app.MapGet("/data/{**asset}", async (HttpContext context, string asset) =>
{
    // Development checkouts have historically placed this optional pack under
    // either repo/data or play/data. Accept both without copying it.
    var first = Path.Combine(repoRoot, "data");
    var candidate = Path.Combine(first, asset.Replace('/', Path.DirectorySeparatorChar));
    var root = File.Exists(candidate) ? first : Path.Combine(playRoot, "data");
    await SendRepositoryFile(context, root, asset, contentTypes);
});

// A plain local Steam install has no dashboard-managed mod manifest. Return the
// valid empty v2 document instead of a 404 so local boot is deterministic.
app.MapGet("/mwdata-mods.json", () => Results.Json(new
{
    v = 2,
    disabled = Array.Empty<string>(),
    swaps = Array.Empty<object>(),
    mods = Array.Empty<object>(),
    content = Array.Empty<string>(),
    groundcover = Array.Empty<string>()
}));

// Keep browser diagnostics visible in the VS Output window. The old Python
// server forwarded this route to the multiplayer gateway; a local renderer run
// has no gateway and should not turn every diagnostic post into a 404.
app.MapPost("/clientlog", async (HttpContext context) =>
{
    using var reader = new StreamReader(context.Request.Body, Encoding.UTF8);
    var body = await reader.ReadToEndAsync(context.RequestAborted);
    app.Logger.LogInformation("Browser clientlog: {ClientLog}", body);
    return Results.NoContent();
});

app.MapPost("/dev/clear-cache", () => Results.Json(new
{
    ok = true,
    revision = localAssetRevision,
    message = "Reload the game page. Local StreamFS URLs use this revision and no longer reuse older cached chunks."
}));

app.MapGet("/dev/assets", () =>
{
    var root = gameData.Current;
    var checks = new[] { "Morrowind.esm", "Morrowind.bsa", "Tribunal.esm", "Tribunal.bsa", "Bloodmoon.esm", "Bloodmoon.bsa" }
        .Select(name =>
        {
            var path = root is null ? null : Path.Combine(root, name);
            return new { name, exists = path is not null && File.Exists(path), bytes = path is not null && File.Exists(path) ? new FileInfo(path).Length : 0 };
        }).ToArray();
    return Results.Json(new { root, files = checks,
        optionalAssetPack = new[] { Path.Combine(playRoot, "moddata", "openmw-web-assets.bsa"), Path.Combine(repoRoot, "data", "openmw-web-assets.bsa"), Path.Combine(playRoot, "data", "openmw-web-assets.bsa") }
            .Where(File.Exists).ToArray() });
});

app.MapGet("/mwdata-manifest.json", () =>
{
    var root = gameData.Current;
    if (root is null)
        return Results.Json(Array.Empty<object>());

    var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
        .Where(path =>
        {
            var name = Path.GetFileName(path);
            return !name.StartsWith(".", StringComparison.Ordinal) &&
                   !name.EndsWith(".br", StringComparison.OrdinalIgnoreCase);
        })
        .Select(path => new
        {
            p = Path.GetRelativePath(root, path).Replace('\\', '/'),
            s = new FileInfo(path).Length
        })
        .OrderBy(file => file.p, StringComparer.OrdinalIgnoreCase)
        .ToArray();
    return Results.Json(files);
});

app.MapGet("/mwdata/{**asset}", async (HttpContext context, string asset) =>
{
    var root = gameData.Current;
    if (root is null || String.IsNullOrWhiteSpace(asset))
    {
        context.Response.StatusCode = 404;
        return;
    }

    var canonicalRoot = Path.GetFullPath(root);
    var path = Path.GetFullPath(Path.Combine(canonicalRoot, asset.Replace('/', Path.DirectorySeparatorChar)));
    if (!path.StartsWith(canonicalRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
    {
        context.Response.StatusCode = 404;
        return;
    }

    await SendBinaryFile(context, path, contentTypes);
});

app.MapGet("/e/{version}/{**asset}", async (HttpContext context, string version, string asset) =>
{
    var engine = manager.Current;
    if (engine is null || !String.Equals(version, engine.Version, StringComparison.Ordinal) ||
        String.IsNullOrWhiteSpace(asset))
    {
        context.Response.StatusCode = 404;
        return;
    }

    var root = Path.GetFullPath(engine.Directory);
    var path = Path.GetFullPath(Path.Combine(root, asset.Replace('/', Path.DirectorySeparatorChar)));
    if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
    {
        context.Response.StatusCode = 404;
        return;
    }

    await SendBinaryFile(context, path, contentTypes);
});

_ = manager.EnsureEngineAsync();

app.Logger.LogInformation("Repository root: {Root}", repoRoot);
app.Logger.LogInformation("WebGPU renderer: {Renderer}", rendererRoot);
app.Logger.LogInformation("Morrowind Data Files: {GameData}", gameData.Current ?? "(not found)");
app.Run();

static async Task SendBinaryFile(HttpContext context, string path, FileExtensionContentTypeProvider contentTypes)
{
    if (!contentTypes.TryGetContentType(path, out var type)) type = "application/octet-stream";
    var info = new FileInfo(path);
    var size = info.Length;
    context.Response.ContentType = type;
    context.Response.Headers["Accept-Ranges"] = "bytes";
    context.Response.Headers["Cache-Control"] = "no-cache";

    var range = context.Request.Headers.Range.ToString();
    if (!String.IsNullOrWhiteSpace(range))
    {
        var match = System.Text.RegularExpressions.Regex.Match(range, @"^bytes=(\d*)-(\d*)$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);
        if (!match.Success || (match.Groups[1].Length == 0 && match.Groups[2].Length == 0))
        {
            context.Response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
            context.Response.Headers["Content-Range"] = $"bytes */{size}";
            return;
        }

        long start, end;
        if (match.Groups[1].Length == 0)
        {
            if (!Int64.TryParse(match.Groups[2].Value, out var suffix) || suffix <= 0)
            {
                context.Response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
                context.Response.Headers["Content-Range"] = $"bytes */{size}";
                return;
            }
            start = Math.Max(0, size - suffix);
            end = size - 1;
        }
        else
        {
            if (!Int64.TryParse(match.Groups[1].Value, out start))
            {
                context.Response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
                context.Response.Headers["Content-Range"] = $"bytes */{size}";
                return;
            }
            if (match.Groups[2].Length != 0 && Int64.TryParse(match.Groups[2].Value, out var requestedEnd))
                end = Math.Min(requestedEnd, size - 1);
            else
                end = size - 1;
        }

        if (size <= 0 || start < 0 || start >= size || end < start)
        {
            context.Response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
            context.Response.Headers["Content-Range"] = $"bytes */{size}";
            return;
        }

        var length = end - start + 1;
        context.Response.StatusCode = StatusCodes.Status206PartialContent;
        context.Response.ContentLength = length;
        context.Response.Headers["Content-Range"] = $"bytes {start}-{end}/{size}";
        if (!HttpMethods.IsHead(context.Request.Method))
            await context.Response.SendFileAsync(path, start, length, context.RequestAborted);
        return;
    }

    context.Response.ContentLength = size;
    if (!HttpMethods.IsHead(context.Request.Method))
        await context.Response.SendFileAsync(path, 0, size, context.RequestAborted);
}

static async Task SendRepositoryFile(HttpContext context, string root, string asset, FileExtensionContentTypeProvider contentTypes)
{
    if (String.IsNullOrWhiteSpace(asset) || !Directory.Exists(root))
    {
        context.Response.StatusCode = 404;
        return;
    }
    var canonicalRoot = Path.GetFullPath(root);
    var path = Path.GetFullPath(Path.Combine(canonicalRoot, asset.Replace('/', Path.DirectorySeparatorChar)));
    if (!path.StartsWith(canonicalRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
    {
        context.Response.StatusCode = 404;
        return;
    }
    await SendBinaryFile(context, path, contentTypes);
}

sealed record EngineBundle(string Version, string Directory, string Source);

sealed class EngineManager
{
    private readonly string _root;
    private readonly IConfiguration _configuration;
    private readonly ILogger _log;
    private readonly object _sync = new();
    private readonly List<string> _buildLog = new();
    private volatile EngineBundle? _current;
    private volatile string _state = "starting";
    private volatile bool _buildFailed;
    private volatile string? _sourceFingerprint;

    public EngineManager(string root, IConfiguration configuration, ILogger log)
    {
        _root = root;
        _configuration = configuration;
        _log = log;
    }

    public EngineBundle? Current => _current;
    public bool BuildFailed => _buildFailed;

    public object Status
    {
        get
        {
            lock (_sync)
            {
                return new
                {
                    state = _state,
                    engine = _current,
                    buildFailed = _buildFailed,
                    sourceFingerprint = _sourceFingerprint,
                    log = _buildLog.TakeLast(80).ToArray()
                };
            }
        }
    }

    public async Task EnsureEngineAsync()
    {
        try
        {
            _state = "checking";
            _sourceFingerprint = ComputeSourceFingerprint();
            AddLog($"Engine source fingerprint: {_sourceFingerprint}");

            _current = FindFreshEngine(_sourceFingerprint);
            if (_current is not null)
            {
                _state = "ready";
                _log.LogInformation("Using current OpenMW engine {Version} from {Directory}", _current.Version, _current.Directory);
                return;
            }

            if (!_configuration.GetValue("OpenMW:BuildEngineWhenMissing", true))
            {
                Fail("No current OpenMW WASM build was found and automatic engine building is disabled.");
                return;
            }

            _state = "building";
            AddLog("OpenMW WASM is missing or stale. Running the incremental engine build...");
            var exitCode = await BuildEngineAsync();
            if (exitCode != 0)
            {
                Fail($"Engine build exited with code {exitCode}. See /status for build output.");
                return;
            }

            var buildDirectory = Path.Combine(_root, "build-wasm64");
            if (!Complete(buildDirectory))
            {
                Fail("The engine build completed but build-wasm64/openmw.js, openmw.wasm and openmw.data were not produced.");
                return;
            }

            File.WriteAllText(StampPath(buildDirectory), _sourceFingerprint);
            _current = BundleForDirectory(buildDirectory, "build-wasm64");
            _buildFailed = false;
            _state = "ready";
            AddLog($"Engine ready: {_current.Version}");
            _log.LogInformation("Built and mounted OpenMW engine {Version} directly from {Directory}", _current.Version, _current.Directory);
        }
        catch (Exception ex)
        {
            Fail(ex.ToString());
        }
    }

    private EngineBundle? FindFreshEngine(string fingerprint)
    {
        var requested = _configuration["OpenMW:EngineVersion"]?.Trim();

        // Explicit versions are an escape hatch for reproducing an old bundle.
        if (!String.IsNullOrWhiteSpace(requested) &&
            !String.Equals(requested, "auto", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var parent in new[] { Path.Combine(_root, ".local-runtime", "e"), Path.Combine(_root, "play", "e") })
            {
                var directory = Path.Combine(parent, requested);
                if (Complete(directory))
                    return new EngineBundle(requested, directory, parent.Contains(".local-runtime") ? ".local-runtime" : "play/e");
            }
            return null;
        }

        // Prefer the live build tree. It avoids a staging/copy step entirely.
        var build = Path.Combine(_root, "build-wasm64");
        if (Complete(build) && StampMatches(build, fingerprint))
            return BundleForDirectory(build, "build-wasm64");

        // A staged bundle is only considered current when it carries the same
        // source fingerprint. Old pre-WebHost bundles intentionally do not.
        foreach (var parent in new[] { Path.Combine(_root, ".local-runtime", "e"), Path.Combine(_root, "play", "e") })
        {
            if (!Directory.Exists(parent)) continue;
            foreach (var directory in Directory.GetDirectories(parent).OrderByDescending(Directory.GetLastWriteTimeUtc))
            {
                if (Complete(directory) && StampMatches(directory, fingerprint))
                    return new EngineBundle(Path.GetFileName(directory), directory,
                        parent.Contains(".local-runtime") ? ".local-runtime" : "play/e");
            }
        }

        return null;
    }

    private async Task<int> BuildEngineAsync()
    {
        ProcessStartInfo psi;
        if (OperatingSystem.IsWindows())
        {
            var script = Path.Combine(_root, "wasm-build", "build-local-windows.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Windows WASM build wrapper is missing.", script);

            psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                WorkingDirectory = _root,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(script);

            var toolsRoot = _configuration["OpenMW:ToolsRoot"]?.Trim();
            if (!String.IsNullOrWhiteSpace(toolsRoot))
            {
                psi.ArgumentList.Add("-ToolsRoot");
                psi.ArgumentList.Add(Environment.ExpandEnvironmentVariables(toolsRoot));
            }
        }
        else
        {
            var script = Path.Combine(_root, "wasm-build", "link-openmw.sh");
            if (!File.Exists(script)) throw new FileNotFoundException("WASM link script is missing.", script);
            psi = new ProcessStartInfo
            {
                FileName = "/bin/bash",
                WorkingDirectory = _root,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add(script);
            psi.Environment["ROOT"] = _root;
        }

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) AddLog(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AddLog(e.Data); };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private string ComputeSourceFingerprint()
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var files = new List<string>();

        void AddTree(string directory)
        {
            if (!Directory.Exists(directory)) return;
            files.AddRange(Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)
                .Where(path =>
                {
                    var extension = Path.GetExtension(path);
                    return extension.Equals(".cpp", StringComparison.OrdinalIgnoreCase) ||
                           extension.Equals(".hpp", StringComparison.OrdinalIgnoreCase) ||
                           extension.Equals(".h", StringComparison.OrdinalIgnoreCase) ||
                           extension.Equals(".c", StringComparison.OrdinalIgnoreCase);
                }));
        }

        // These are the C++ pieces that define the browser capture ABI and the
        // viewer selection/frame loop. JS/WGSL changes do not require WASM relink.
        AddTree(Path.Combine(_root, "openmw", "components", "webcuda"));
        foreach (var file in new[]
        {
            Path.Combine(_root, "openmw", "apps", "openmw", "engine.cpp"),
            Path.Combine(_root, "openmw", "apps", "openmw", "engine.hpp"),
            Path.Combine(_root, "openmw", "apps", "openmw", "main.cpp"),
            Path.Combine(_root, "wasm-build", "link-openmw.sh")
        })
            if (File.Exists(file)) files.Add(file);

        foreach (var path in files.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
        {
            var relative = Path.GetRelativePath(_root, path).Replace('\\', '/');
            var nameBytes = Encoding.UTF8.GetBytes(relative + "\n");
            hash.AppendData(nameBytes);
            using var stream = File.OpenRead(path);
            var buffer = new byte[128 * 1024];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                hash.AppendData(buffer, 0, read);
        }

        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()[..16];
    }

    private EngineBundle BundleForDirectory(string directory, string source)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var name in new[] { "openmw.js", "openmw.wasm", "openmw.data" })
        {
            using var stream = File.OpenRead(Path.Combine(directory, name));
            var buffer = new byte[256 * 1024];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                hash.AppendData(buffer, 0, read);
        }
        var version = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()[..12];
        return new EngineBundle(version, directory, source);
    }

    private static string StampPath(string directory) => Path.Combine(directory, ".webhost-engine-fingerprint");

    private static bool StampMatches(string directory, string fingerprint)
    {
        var path = StampPath(directory);
        if (!File.Exists(path)) return false;
        try { return String.Equals(File.ReadAllText(path).Trim(), fingerprint, StringComparison.Ordinal); }
        catch (IOException) { return false; }
    }

    private static bool Complete(string directory) =>
        Directory.Exists(directory) &&
        File.Exists(Path.Combine(directory, "openmw.js")) &&
        File.Exists(Path.Combine(directory, "openmw.wasm")) &&
        File.Exists(Path.Combine(directory, "openmw.data"));

    private void AddLog(string message)
    {
        lock (_sync)
        {
            _buildLog.Add(message);
            if (_buildLog.Count > 500) _buildLog.RemoveRange(0, _buildLog.Count - 500);
        }
        _log.LogInformation("{BuildMessage}", message);
    }

    private void Fail(string message)
    {
        _buildFailed = true;
        _state = "failed";
        AddLog(message);
        _log.LogError("{BuildError}", message);
    }

    public string StartupPage()
    {
        string[] lines;
        lock (_sync) lines = _buildLog.TakeLast(30).ToArray();
        var escaped = String.Join("\n", lines.Select(System.Net.WebUtility.HtmlEncode));
        var title = _buildFailed ? "OpenMW engine build failed" : "Building OpenMW";
        var refresh = _buildFailed ? "" : "<meta http-equiv=\"refresh\" content=\"2\">";
        return $@"<!doctype html>
<html><head><meta charset=""utf-8"">{refresh}<title>{title}</title>
<style>body{{font-family:Segoe UI,Arial;background:#111;color:#eee;margin:40px}}main{{max-width:1000px;margin:auto}}pre{{background:#1b1b1b;padding:20px;white-space:pre-wrap;border-radius:6px}}a{{color:#d6ad55}}</style>
</head><body><main><h1>{title}</h1>
<p>{(_buildFailed ? "The ASP.NET host is still running. Fix the build error below and restart F5." : "The C# host detected that the WASM engine is missing or stale. Ninja is rebuilding only what changed, then the game will reload automatically.")}</p>
<pre>{escaped}</pre><p><a href=""/status"">Build/status JSON</a></p></main></body></html>";
    }
}


sealed class GameDataManager
{
    private readonly string _root;
    private readonly IConfiguration _configuration;
    private readonly ILogger _log;
    public string? Current { get; private set; }
    public IReadOnlyList<string> CheckedPaths { get; private set; } = Array.Empty<string>();
    public object Status => new { path = Current, found = Current is not null, checkedPaths = CheckedPaths };

    public GameDataManager(string root, IConfiguration configuration, ILogger log)
    {
        _root = root; _configuration = configuration; _log = log;
    }

    public void Detect()
    {
        var checkedPaths = new List<string>();
        var configured = _configuration["OpenMW:GameDataPath"]?.Trim();
        if (!String.IsNullOrWhiteSpace(configured) &&
            !String.Equals(configured, "auto", StringComparison.OrdinalIgnoreCase))
        {
            var candidate = Normalize(configured);
            checkedPaths.Add(candidate);
            if (Valid(candidate)) { Set(candidate, checkedPaths); return; }
        }

        // A repo-local play/mwdata remains useful, but a normal Windows dev
        // checkout can point straight at the installed Steam Data Files.
        Add(Path.Combine(_root, "play", "mwdata"));
        foreach (var library in _configuration.GetSection("OpenMW:SteamLibraryPaths").Get<string[]>() ?? Array.Empty<string>())
            Add(Path.Combine(Environment.ExpandEnvironmentVariables(library), "steamapps", "common", "Morrowind", "Data Files"));

        if (OperatingSystem.IsWindows())
        {
            Add(@"C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files");
            Add(@"C:\Program Files\Steam\steamapps\common\Morrowind\Data Files");

            // Discover additional Steam libraries from libraryfolders.vdf.
            foreach (var steamRoot in new[] { @"C:\Program Files (x86)\Steam", @"C:\Program Files\Steam" })
            {
                var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
                if (!File.Exists(vdf)) continue;
                try
                {
                    foreach (var line in File.ReadLines(vdf))
                    {
                        var match = System.Text.RegularExpressions.Regex.Match(line, "^\\s*\\\"path\\\"\\s+\\\"(.+)\\\"\\s*$");
                        if (!match.Success) continue;
                        var library = match.Groups[1].Value.Replace(@"\\", @"\");
                        Add(Path.Combine(library, "steamapps", "common", "Morrowind", "Data Files"));
                    }
                }
                catch (IOException) { }
            }

            // Common custom-library drive roots, including D:\SteamLibrary.
            foreach (var drive in DriveInfo.GetDrives().Where(d => d.IsReady))
            {
                Add(Path.Combine(drive.RootDirectory.FullName, "SteamLibrary", "steamapps", "common", "Morrowind", "Data Files"));
                Add(Path.Combine(drive.RootDirectory.FullName, "Steam", "steamapps", "common", "Morrowind", "Data Files"));
            }
        }

        void Add(string path)
        {
            var candidate = Normalize(path);
            if (checkedPaths.Contains(candidate, StringComparer.OrdinalIgnoreCase)) return;
            checkedPaths.Add(candidate);
            if (Current is null && Valid(candidate)) Current = candidate;
        }

        CheckedPaths = checkedPaths;
        if (Current is not null)
            _log.LogInformation("Detected Morrowind Data Files at {Path}", Current);
        else
            _log.LogWarning("Morrowind Data Files were not found. Set OpenMW:GameDataPath in appsettings.json.");
    }

    private void Set(string path, List<string> checkedPaths)
    {
        Current = path; CheckedPaths = checkedPaths;
        _log.LogInformation("Using configured Morrowind Data Files at {Path}", path);
    }

    private static string Normalize(string path) => Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')));
    private static bool Valid(string path) =>
        Directory.Exists(path) &&
        File.Exists(Path.Combine(path, "Morrowind.esm")) &&
        File.Exists(Path.Combine(path, "Morrowind.bsa"));
}
