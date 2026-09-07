# sharpie

A version manager for [W#](https://github.com/sinisterMage/WSharp), in the mould
of `rustup` and `juliaup`: install toolchains, keep several side by side, put
proxies on `PATH`, and let a directory pin the version it wants.

**Written in W#.** That is the point rather than a constraint. `ingot` was the
first real program in the language; this is the second, and it leans on
`std/http`, `std/tls`, `std/toml` and `std/inflate` hard enough to find out
where they bend.

## Status

Early. `src/targz.ws` reads a release archive; the rest is being written.

## What a toolchain is

Not one binary. `wsharp` needs something to link against, so an installation is
a directory:

```
~/.sharpie/
├── bin/{sharpie,wsharp,ingot}     proxies, dispatching on their own name
├── toolchains/<version>-<triple>/ wsharp, ingot, lib/libwsharp_start.a
├── downloads/                     tarballs, kept so a retry need not refetch
├── tmp/                           staging, renamed into place atomically
└── settings.toml
```

`SHARPIE_HOME` moves all of it. It is deliberately **not** `WSHARP_HOME`, which
is `ingot`'s content-addressed package store and a different thing -- the split
is `RUSTUP_HOME` and `CARGO_HOME`'s.

Two existing rules make this work with no changes to either program: `wsharp`
looks for its runtime archive beside itself and under `../lib`, and `ingot`
looks for `wsharp` beside itself before `PATH`. A toolchain directory satisfies
both, so a proxy can `exec` straight into one.

## Building

```sh
wsharp build src/main.ws -o sharpie
```

The result is a self-contained native executable: the runtime archive is a
link-time input, so a built `sharpie` needs no W# installation to run.

## Tests

```sh
./tests/run.sh                        # uses ../WSharp/target/debug/wsharp
WSHARP=/path/to/wsharp ./tests/run.sh
```

Each case is a `.ws` program whose header holds one `// expect:` line per line
it prints, which is the contract the compiler's own case suite uses. They run
without a network: `tests/fixtures/` holds a real released tarball and a small
one whose every member is known, and the archive reader is written against
bytes rather than against a socket so that both halves can be checked here.

## Licence

MIT, as W# is.
