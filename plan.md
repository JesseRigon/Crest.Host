# Orchard Crest UI Framework Remaining Work

This file tracks work that is not implemented yet. Architecture overviews live in:

- [`README.md`](README.md) - host setup and project overview.
- [`modules/Crest/README.md`](modules/Crest/README.md) - module repository architecture.
- [`modules/Crest/Crest.Server/README.md`](modules/Crest/Crest.Server/README.md) - Orchard-side runtime and API strategy.
- [`modules/Crest/Crest.Components/README.md`](modules/Crest/Crest.Components/README.md) - component library, admin WASM theme, and site theme overview.

## Current Repository Shape

```text
orchard-crest/
  OrchardCore.Crest.Host.csproj
  Program.cs
  appsettings.Development.json        # simple dotnet-run AutoSetup config
  App_Data/                           # generated Orchard tenant data (ignored)
  Recipes/crest.dev.recipe.json     # local SQLite dev recipe
  tests/playwright/                   # reusable browser validation scripts
  modules/Crest/
    Crest.Server/            # Orchard runtime module, adapters, middleware, legacy frame
    Crest.Components/        # shared Radzen-based component library
      Components/
      Models/
      Shapes/
    Crest.Admin/             # Orchard admin theme manifest
      wasm/                         # current Blazor WebAssembly admin shell
    Crest.Site/              # included Orchard site theme
```

## Neutral Client/Core Package

- [ ] Create a UI-library-neutral client package, likely:

  ```text
  modules/Crest/Crest.Client/
    Context/
    Display/
    LegacyFrame/
    Models/
    Routing/
  ```

- [ ] Move client-safe DTO contracts out of `Crest.Components` when they are not Radzen-specific.
- [ ] Move shared shape/model contracts into the neutral client package.
- [ ] Keep the neutral client package free of Radzen, Orchard server assemblies, MVC, Razor Pages, and `Microsoft.AspNetCore.App` server-only dependencies.
- [ ] Update `Crest.Components`, `Crest.Admin/wasm`, and module WASM projects to reference the neutral client package after extraction.

## Display Management

- [ ] Define the neutral display abstractions, for example:

  ```text
  Crest.Client/Display/ICrestDisplayManager.cs
  Crest.Client/Display/CrestDisplayManager.cs
  Crest.Client/Display/CrestDisplayDriver.cs
  Crest.Client/Display/CrestDisplayContext.cs
  Crest.Client/Display/CrestDisplayResult.cs
  Crest.Client/Display/CrestPlacementInfo.cs
  ```

- [ ] Decide whether the current admin WASM `DisplayManagement` code should be split into:
  - neutral display/rendering orchestration, and
  - admin-shell state/session/theme services.
- [ ] Move neutral display concepts out of `modules/Crest/Crest.Admin/wasm/DisplayManagement`.
- [ ] Keep Radzen renderers in `Crest.Components`, not in the neutral display package.
- [ ] Expand concrete Radzen field renderers in `Crest.Components/Components/Model` or a dedicated `Components/Display` area as needed.

## Legacy Frame Client Abstraction

The Orchard-side legacy frame selector/theme already exists in `Crest.Server`. Remaining work is to extract reusable client-side behavior from the current admin shell.

- [ ] Move iframe URL-building behavior out of the Radzen admin shell into the neutral client package.
- [ ] Create a reusable neutral component or service set, for example:

  ```text
  Crest.Client/Components/LegacyFrame.razor
  Crest.Client/LegacyFrame/LegacyFrameUrlBuilder.cs
  Crest.Client/LegacyFrame/LegacyFrameOptions.cs
  ```

- [ ] Keep `legacy-frame=1` / `legacy-frame=true` as the shared query convention.
- [ ] Allow `Crest.Components` to wrap or style the neutral legacy frame component with Radzen-specific chrome.
- [ ] Ensure future component systems can reuse the legacy frame selector, frame theme, URL convention, and client iframe behavior without copying Radzen admin-shell code.

## Module Discovery And Routing

The current system has build-time WASM project discovery in `Crest.Admin/wasm/Crest.Admin.Wasm.csproj` for module projects matching `modules/*/blazor-wasm/*.csproj`. Remaining work is to formalize this into an explicit extension model.

- [ ] Replace or supplement the current build-time WASM project glob with an explicit module registry/manifest model.
- [ ] Define how Orchard modules declare Crest-compatible routes, component assemblies, scripts, styles, and permissions.
- [ ] Define how module-contributed component assemblies are served to the WASM admin shell.
- [ ] Define route collision behavior and precedence.
- [ ] Define how module metadata is represented in the boot manifest returned by `api/crest/app`.
- [ ] Keep module discovery generic so future component systems can opt into the same conventions.

## API And Contract Cleanup

- [ ] Audit every `api/crest/*` endpoint against Orchard's native APIs.
- [ ] Replace custom content reads with Orchard Contents REST API or GraphQL where sufficient.
- [ ] Verify whether Orchard Core exposes suitable JSON APIs for:
  - content definitions,
  - roles,
  - site settings,
  - features.
- [ ] Add or verify explicit authorization checks for all admin-level reads and writes.
- [ ] Add antiforgery handling for state-changing Crest endpoints where needed.
- [ ] Keep `api/crest/*` endpoints thin: they should call Orchard services, enforce Orchard permissions, and return Blazor-friendly JSON without owning duplicate state.

## Packaging

- [ ] Decide final NuGet package boundaries:
  - `Crest.Server`
  - `Crest.Components`
  - `Crest.Client`
  - theme packages if needed
- [ ] Set `IsPackable=true` where packages are intended.
- [ ] Add package metadata, descriptions, icons/readmes, repository metadata, and license metadata.
- [ ] Verify package dependency boundaries so `Crest.Server` does not depend on Radzen.
- [ ] Verify component packages do not accidentally include generated `bin`/`obj` or unrelated theme source.
- [ ] Decide whether Orchard-loadable themes are packaged independently or bundled with the components package.

## Documentation

- [ ] Document how a third-party Orchard module contributes a `blazor-wasm` project.
- [ ] Document how a third-party Orchard module contributes Crest admin routes and menu entries.
- [ ] Document how a future non-Radzen component system should integrate.
- [ ] Document the legacy frame URL/query contract.
- [ ] Keep the expected API-selection order documented: Orchard native API, GraphQL, Query API, OpenID/JWT, then thin Crest adapter.

## Validation

- [ ] `dotnet build OrchardCore.Crest.Host.csproj --no-restore`
- [ ] `dotnet run --project OrchardCore.Crest.Host.csproj`
- [ ] `node tests/playwright/dev-setup-admin.js`
- [ ] Add Playwright coverage for legacy frame fallback routes.
- [ ] Add Playwright coverage for module-contributed Blazor routes when this host includes a sample module.

Browser validation should use reusable scripts under `tests/playwright`; avoid inline one-off Playwright scripts.
