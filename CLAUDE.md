# terrain-generator

Procedural terrain for Roblox, written to `workspace.Terrain` with `WriteVoxelChannels`.
It is a single place, with the server generating terrain in Parallel Luau.

## Rules

1. **Rojo serves `out/`, not `src/`.** darklua transpiles `src` → `out` and turns string
   requires (`@generation/...`) into instance paths through `sourcemap.json`. Edit `src/` only.
2. **Keep `src/shared/Generation/` free of Roblox APIs** (no Instances, Enums, Vector3,
   `Random`). This keeps it loadable in Lune for tests. Materials are names; the worker maps them through a palette.
3. **Inside Generation, require siblings with `./Name`**, and don't use `init.luau`.
   The worker script uses `@generation/...` aliases, which darklua rewrites to absolute
   `ReplicatedStorage` paths so they keep working after the Actor is cloned.
4. **New tunables go in `Config.FIELDS`.** That schema drives server sanitising and the Iris panel.

## Commands

```bash
pesde run sync      # install, transpile, then watch + rojo serve out.project.json
pesde run build     # build/terrain-generator.rbxl (add -- --prod for the prod darklua config)
pesde run test      # headless Lune specs in tests/ (pass a filter: -- noise)
pesde run verify    # sourcemap, darklua, selene, stylua --check, luau-lsp analyze, tests
pesde run publish   # prod build + rbxcloud upload; env RBXCLOUD_API_KEY, UNIVERSE_ID, PLACE_ID (-- --saved = don't go live)
```

CI (`.github/workflows/ci.yml`) runs `verify` on every push/PR and `publish` on `main` only after verify passes.

`verify` only proves that the code builds, type-checks, and that the pure generator behaves.
Terrain writes, Actors and the Iris panel run only in Studio, so say "verified" for those
only after a Studio run.

## Layout

| Path | What |
|---|---|
| `src/shared/Generation/` | Pure core: `Noise` (seeded 2D/3D simplex, eroded fractals), `Sampler` (fills a `Column`: terrain first — coast, eroded hills, mountain ranges — then Minecraft-style biome tables picked by temperature, humidity and terrain band, rivers; `occupancy` adds optional 3D caves and overhangs per voxel, plain heightmap when both are Off; `ChunkBuilder` interpolates the 3D noise from an 8×16×8-stud lattice), `ChunkBuilder` (voxel channels), `Config`, `Biomes`, `ChunkGrid` |
| `src/worker/Worker.server.luau` | Actor worker. Builds in parallel, then `task.synchronize()`, epoch check, write |
| `src/server/Terrain/` | `WorkerPool`, `ChunkManager` (Stream / Pregenerate), `Spawning`, `DebugBridge` |
| `src/client/DebugPanel.client.luau` | Iris tuning panel (F4); Studio or place owner only |
| `tests/` | Lune specs plus `expect.luau` |
