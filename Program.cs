using Crest.Global;
using System.Text.Json;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

// Local dev config (autosetup tenant, admin credentials, Kestrel port) lives in
// dev/appsettings.Development.json rather than the content root, so it stays out of the
// app's own config and out of publish output. Environment variables and command-line args
// are re-added after it so they still win, as they do over the default appsettings files.
if (builder.Environment.IsDevelopment())
{
    builder.Configuration
        .AddJsonFile(Path.Combine(builder.Environment.ContentRootPath, "dev", "appsettings.Development.json"), optional: true, reloadOnChange: true)
        .AddEnvironmentVariables()
        .AddCommandLine(args);
}

builder.Host.UseSerilog((context, logger) =>
{
    logger.ReadFrom.Configuration(context.Configuration);
});

var setupFeatures = new List<string>();

if (IsAutoSetupRecipeAvailable(builder))
{
    setupFeatures.Add("Crest.AutoSetup");
}
else
{
    Console.WriteLine("AutoSetup recipe is not available; Crest.AutoSetup will not be enabled. Existing tenants can run normally, and new tenants can be set up manually.");
}

// Crest's own features are enabled by the setup recipe's own "feature" step (see
// Recipes/crest.dev.recipe.json) once the tenant is provisioned, not here.
// AddSetupFeatures loads its features into the Uninitialized/setup shell descriptor
// itself - Crest transitively depends on Crest.Contents (via
// Crest.Menu), which registers a DB-backed IPermissionProvider
// (ContentTypePermissions). PlatformBuilderExtensions.ValidatePermissionsAsync
// unconditionally calls GetPermissionsAsync() on every registered IPermissionProvider
// during shell pipeline construction, including for Uninitialized shells - but an
// Uninitialized shell has no IStore/ISession yet (Crest.Data.YesSql returns null
// for both until after setup), so this NRE's on every request before setup can even run.
builder.Services
    .AddPlatformCms()
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

app.UseStaticFiles();
app.UsePlatform();

await app.RunAsync();

static bool IsAutoSetupRecipeAvailable(WebApplicationBuilder builder)
{
    var recipeName = builder.Configuration
        .GetSection("Crest:Crest_AutoSetup:Tenants")
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
