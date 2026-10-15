# Contribute

All commands go through one script.

```bash
lune run scripts/run.luau <command>
```

| Command | Runs |
| --- | --- |
| `setup` | The pinned tools, through rokit. |
| `verify` | Toolchain, formatting, line width, the layer stack, the types of every tree, and the suite. |
| `test` | The suite. A seed and a name filter may follow, as in `test 7 set.`. |
| `check` | `index.d.ts` under tsc, then a compile of its use under the roblox-ts compiler. |
| `bench` | Every bench row. |
| `build` | The library model. |

The documentation is the `docs` folder. To preview it locally with live reload:

```bash
pip install mkdocs-material
mkdocs serve
```

The site publishes from the `Docs` workflow on every push to `main` that touches `docs/` or
`mkdocs.yml`.
