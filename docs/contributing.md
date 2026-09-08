# Contribute

```bash
lune run scripts/run.luau setup     # pinned tools through rokit
lune run scripts/run.luau verify    # toolchain, formatting, width, layers, types, suite
lune run scripts/run.luau test 7 set.   # the suite at a seed, filtered by name
lune run scripts/run.luau check     # index.d.ts under tsc, then compiled by roblox-ts
lune run scripts/run.luau bench
lune run scripts/run.luau build
```

```bash
pip install mkdocs-material
mkdocs serve                        # these pages, live at localhost:8000
```

The site publishes from the `Docs` workflow on every push to `main` that touches `docs/` or
`mkdocs.yml`.
