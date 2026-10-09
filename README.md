# Crest.Host

The starting point for running [Crest](https://github.com/JesseRigon/Crest): a minimal host
that runs the Crest platform and its application modules (Parties, Members, Workflows,
Money, the admin, site and member shells) with nothing else on top. Clone it to try Crest or
to start an application of your own.

> Crest is a personal, AI-assisted project and is not hardened or stable. Read the warning in
> [Crest's README](modules/Crest/README.md) before using it for anything that matters.

## Layout

```text
Crest.Host/
  modules/Crest/        the Crest repository, as a git submodule: the platform (src/) and
                        the application modules
  Crest.Host.csproj     the host web app
  client/               the host's Blazor WebAssembly entry project
  Recipes/              the setup recipe (CrestDev) and the admin menu layout
  dev/                  dev.sh, local dev configuration and the browser-suite runner
```

The host consumes Crest as **NuGet packages**, never as project references, the same way it
will once they are published to a feed. `dev/dev.sh` packs them from the submodule into its
git-ignored `output/` folder, first the platform (`modules/Crest/output/platform`, slow, first
run only), then Crest's modules (`modules/Crest/output/crest`, repacked whenever their source
changes). `NuGet.config` maps the `Crest.*` packages to those two folders.

## Getting started

```bash
git clone --recurse-submodules https://github.com/JesseRigon/Crest.Host.git
cd Crest.Host
bash dev/dev.sh up
```

`up` packs what is needed, restores, and runs the host under `dotnet watch` at
<http://crest.localhost:5014>. On the first start AutoSetup provisions a SQLite site from the
`CrestDev` recipe; the admin login is `admin` / `CrestRules1!` (see
`dev/appsettings.Development.json`). Tenant data lives in `App_Data/` (git-ignored).

Other commands:

```bash
bash dev/dev.sh build     # pack and build without running
bash dev/dev.sh stop      # stop a running dev server
bash dev/dev.sh down      # stop, shut down build servers, remove bin/obj
bash dev/dev.sh reset     # down + delete App_Data, so the next up provisions fresh
bash dev/dev.sh pack all  # repack the platform and Crest's modules
bash dev/dev.sh test      # build, start the server and run the C# tests and browser suites
```

## Building your own application

Add your own modules beside Crest (as projects in this repository or as further submodules
under `modules/`), reference them from `Crest.Host.csproj` and, for Blazor client libraries,
from `client/Crest.Host.Client.csproj`, and enable their features in
`Recipes/crest.dev.recipe.json`. Crest's design and the rules modules follow are in
[`modules/Crest/docs/architecture.md`](modules/Crest/docs/architecture.md).

## Licence

Crest is MIT, and the platform it forks from OrchardCore is BSD-3-Clause. See
[`modules/Crest/LICENSE`](modules/Crest/LICENSE) and
[`modules/Crest/NOTICE.md`](modules/Crest/NOTICE.md).
