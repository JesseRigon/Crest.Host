using Crest.Global;
using System.Text.Json;
using Microsoft.Extensions.FileProviders;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog((context, logger) =>
{
    logger.ReadFrom.Configuration(context.Configuration);
});

var setupFeatures = new List<string>();

if (IsAutoSetupRecipeAvailable(builder))
{
    setupFeatures.Add("OrchardCore.AutoSetup");
}
else
{
    Console.WriteLine("AutoSetup recipe is not available; OrchardCore.AutoSetup will not be enabled. Existing tenants can run normally, and new tenants can be set up manually.");
}

// Crest's own features are enabled by the setup recipe's own "feature" step (see
// Recipes/orchardcore.crest.dev.recipe.json) once the tenant is provisioned, not here.
// AddSetupFeatures loads its features into the Uninitialized/setup shell descriptor
// itself - OrchardCore.Crest transitively depends on OrchardCore.Contents (via
// OrchardCore.Menu), which registers a DB-backed IPermissionProvider
// (ContentTypePermissions). OrchardCoreBuilderExtensions.ValidatePermissionsAsync
// unconditionally calls GetPermissionsAsync() on every registered IPermissionProvider
// during shell pipeline construction, including for Uninitialized shells - but an
// Uninitialized shell has no IStore/ISession yet (OrchardCore.Data.YesSql returns null
// for both until after setup), so this NRE's on every request before setup can even run.
builder.Services
    .AddOrchardCms()
    .AddSetupFeatures([.. setupFeatures])
    // The tenant-less global store is a host-level service (it is one database shared by
    // every tenant), so the host wires it rather than the feature: Crest.Global's
    // ICrestGlobalStore, and anything that reads it - Crest.Regions' geo tree,
    // Crest.Money's currency table - needs this call.
    .AddCrestGlobalStore();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
}

// blazor.web.js (needed by any @rendermode interactive island, e.g. OrchardCore.Crest's
// Components/Pages/BlazorCounter.razor) ships via the microsoft.aspnetcore.app.internal.assets
// SDK package's own static-web-assets target, but that target only fires when
// OutputType=Exe AND UsingMicrosoftNETSdkWeb=true - neither is true for
// OrchardCore.Crest.csproj, a Sdk="Microsoft.NET.Sdk.Razor" module library (Orchard's
// module convention), so the file never reaches this app's static web assets manifest
// and 404s. Forcing OutputType=Exe on a module library risked breaking
// OrchardCore.Module.Targets' embedded-resource assumptions, so instead: serve it
// directly from the same physical file the SDK target would have picked up, scoped to
// exactly this one path. This also serves dotnet.js/dotnet.native.*.wasm and the rest of
// the framework's own runtime files - MapStaticAssets correctly serves everything that
// OrchardCore.Crest.Client's own manifest DOES declare (dotnet.js is not one of them; it's
// SDK-internal, same gate as blazor.web.js), as long as ASPNETCORE_ENVIRONMENT is actually
// Development (see docs/BlazorWeb.md) - don't reintroduce a second, redundant
// PhysicalFileProvider over the client project's own build output for this path; that was
// tried and reverted (it served a different, stale dotnet.js than the manifest-resolved
// one and broke the WASM runtime's own dynamic resource-collection.*.js import).
//
// TODO(.NET 11 / OrchardCore.Crest on .NET 11): .NET 11 adds a <BasePath /> component that
// generates <base href> from the current request's PathBase, meant to make framework-asset
// resolution under a non-root base href (and possibly this SDK-gating gap itself) work
// without hand-rolled workarounds like this one (see dotnet/aspnetcore#66388). Once
// OrchardCore.Crest itself targets .NET 11, re-evaluate whether this block can be retired.
var frameworkAssetsRoot = Directory
    .EnumerateDirectories(Path.Combine(
        Environment.GetEnvironmentVariable("NUGET_PACKAGES")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".nuget", "packages"),
        "microsoft.aspnetcore.app.internal.assets"))
    .OrderByDescending(path => path)
    .Select(path => Path.Combine(path, "_framework"))
    .FirstOrDefault(Directory.Exists);

if (frameworkAssetsRoot is not null)
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new PhysicalFileProvider(frameworkAssetsRoot),
        RequestPath = "/_framework",
    });
}

app.UseStaticFiles();
app.UseOrchardCore();

await app.RunAsync();

static bool IsAutoSetupRecipeAvailable(WebApplicationBuilder builder)
{
    var recipeName = builder.Configuration
        .GetSection("OrchardCore:OrchardCore_AutoSetup:Tenants")
        .GetChildren()
        .Select(section => section["RecipeName"])
        .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

    if (string.IsNullOrWhiteSpace(recipeName))
    {
        return false;
    }

    var recipesPath = Path.Combine(builder.Environment.ContentRootPath, "Recipes");
    if (!Directory.Exists(recipesPath))
    {
        return false;
    }

    foreach (var recipePath in Directory.EnumerateFiles(recipesPath, "*.json", SearchOption.AllDirectories))
    {
        try
        {
            using var stream = File.OpenRead(recipePath);
            using var document = JsonDocument.Parse(stream);
            if (document.RootElement.TryGetProperty("name", out var name) &&
                string.Equals(name.GetString(), recipeName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        catch (JsonException)
        {
            // Ignore unrelated or malformed JSON files. If no matching recipe is found, AutoSetup remains disabled.
        }
    }

    return false;
}
