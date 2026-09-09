<h1 align="center">Lync</h1>

<p align="center">Typed buffer networking for Roblox: packets, queries, and replicated sets.</p>

Write the schema once. Both sides require it, the Luau types fall out of it, and every value packs
into bit level buffers that batch into one frame per client on flush.

Documentation: [axp3cter.github.io/Lync](https://axp3cter.github.io/Lync/)

## Install

```toml
[dependencies]
Lync = "axp3cter/lync@4.0.1"
```

```bash
npm install @axpecter/lync
```

Or drop `Lync.rbxm` from the latest release into `ReplicatedStorage`.

## License

MIT
