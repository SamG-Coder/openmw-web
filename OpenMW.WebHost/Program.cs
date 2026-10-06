using System.Diagnostics;
using System.Text;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.FileProviders;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var repoRoot = Path.GetFullPath(Path.Combine(app.Environment.ContentRootPath, ".."));
var playRoot = Path.Combine(repoRoot, "play");
var rendererRoot = Path.Combine(repoRoot, "render", "webgpu");
var manager = new EngineManager(repoRoot, builder.Configuration, app.Logger);
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
               .Replace(rendererMarker, "const rendererDirectory = './webgpu/';", StringComparison.Ordinal);
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
        ServeUnknownFileTypes = false
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
               .Replace(rendererMarker, "const rendererDirectory = './webgpu/';", StringComparison.Ordinal);
    context.Response.ContentType = "text/html; charset=utf-8";
    context.Response.Headers["Cache-Control"] = "no-store";
    await context.Response.WriteAsync(page);
});

app.MapGet("/status", () => Results.Json(manager.Status));

app.MapGet("/mwdata-manifest.json", () =>
{
    var root = Path.Combine(playRoot, "mwdata");
    if (!Directory.Exists(root))
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

    if (!contentTypes.TryGetContentType(path, out var type))
        type = "application/octet-stream";
    context.Response.ContentType = type;
    context.Response.Headers["Cache-Control"] = "no-cache";
    await context.Response.SendFileAsync(path, 0, null, context.RequestAborted);
});

_ = manager.EnsureEngineAsync();

app.Logger.LogInformation("Repository root: {Root}", repoRoot);
app.Logger.LogInformation("WebGPU renderer: {Renderer}", rendererRoot);
app.Run();

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
                    log = _buildLog.TakeLast(80).ToArray()
                };
            }
        }
    }

    public async Task EnsureEngineAsync()
    {
        try
        {
            _state = "searching";
            _current = FindEngine();
            if (_current is not null)
            {
                _state = "ready";
                _log.LogInformation("Using OpenMW engine {Version} from {Directory}", _current.Version, _current.Directory);
                return;
            }

            if (!_configuration.GetValue("OpenMW:BuildEngineWhenMissing", true))
            {
                Fail("No OpenMW engine bundle was found and automatic engine linking is disabled.");
                return;
            }

            _state = "building";
            AddLog("No complete engine bundle found. Running wasm-build/link-openmw.sh...");
            var script = Path.Combine(_root, "wasm-build", "link-openmw.sh");
            if (!File.Exists(script))
            {
                Fail("wasm-build/link-openmw.sh is missing.");
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = OperatingSystem.IsWindows() ? "bash.exe" : "/bin/bash",
                WorkingDirectory = _root,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add(script);
            psi.Environment["ROOT"] = _root;

            using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, e) => { if (e.Data is not null) AddLog(e.Data); };
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AddLog(e.Data); };

            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                Fail("Could not start the engine build: " + ex.Message);
                return;
            }

            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync();

            if (process.ExitCode != 0)
            {
                Fail($"Engine build exited with code {process.ExitCode}. See /status for its output.");
                return;
            }

            _current = FindEngine();
            if (_current is null)
            {
                Fail("The engine build completed but openmw.js, openmw.wasm and openmw.data were not found.");
                return;
            }

            _state = "ready";
            AddLog($"Engine ready: {_current.Version}");
            _log.LogInformation("OpenMW engine is ready: {Version}", _current.Version);
        }
        catch (Exception ex)
        {
            Fail(ex.ToString());
        }
    }

    private EngineBundle? FindEngine()
    {
        var requested = _configuration["OpenMW:EngineVersion"]?.Trim();
        foreach (var parent in new[]
        {
            Path.Combine(_root, ".local-runtime", "e"),
            Path.Combine(_root, "play", "e")
        })
        {
            if (!Directory.Exists(parent)) continue;
            var directories = Directory.GetDirectories(parent)
                .OrderByDescending(d => Directory.GetLastWriteTimeUtc(d));
            foreach (var directory in directories)
            {
                var version = Path.GetFileName(directory);
                if (!String.IsNullOrWhiteSpace(requested) &&
                    !String.Equals(requested, "auto", StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(requested, version, StringComparison.Ordinal))
                    continue;
                if (Complete(directory))
                    return new EngineBundle(version, directory, parent.Contains(".local-runtime") ? ".local-runtime" : "play/e");
            }
        }

        if (!String.IsNullOrWhiteSpace(requested) &&
            !String.Equals(requested, "auto", StringComparison.OrdinalIgnoreCase))
            return null;

        foreach (var candidate in new[]
        {
            (Directory: Path.Combine(_root, "build-wasm64"), Source: "build-wasm64"),
            (Directory: Path.Combine(_root, "play"), Source: "play")
        })
            if (Complete(candidate.Directory))
                return new EngineBundle("dev", candidate.Directory, candidate.Source);

        return null;
    }

    private static bool Complete(string directory) =>
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
        var title = _buildFailed ? "OpenMW engine is not ready" : "Preparing OpenMW";
        var refresh = _buildFailed ? "" : "<meta http-equiv=\"refresh\" content=\"2\">";
        return $@"<!doctype html>
<html><head><meta charset=""utf-8"">{refresh}<title>{title}</title>
<style>body{{font-family:Segoe UI,Arial;background:#111;color:#eee;margin:40px}}main{{max-width:1000px;margin:auto}}pre{{background:#1b1b1b;padding:20px;white-space:pre-wrap;border-radius:6px}}a{{color:#d6ad55}}</style>
</head><body><main><h1>{title}</h1>
<p>{(_buildFailed ? "The ASP.NET host is running, but the engine could not be prepared." : "The ASP.NET host is running. The game will open automatically when the engine is ready.")}</p>
<pre>{escaped}</pre><p><a href=""/status"">Build/status JSON</a></p></main></body></html>";
    }
}
