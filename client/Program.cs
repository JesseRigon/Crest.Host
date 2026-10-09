// The WASM boot path is Crest's; the module manifest (CrestLazyModulesManifest) is generated
// into this project at build time by Crest.LazyModules from the libraries referenced above.
await Crest.AdminTheme.CrestWebAssemblyHost.RunAsync(args, Crest.Host.Client.CrestLazyModulesManifest.Create());
