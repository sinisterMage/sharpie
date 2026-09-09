# sharpie

A version manager for [W#](https://github.com/sinisterMage/WSharp), in the mould
of `rustup` and `juliaup`: install toolchains, keep several side by side, put
proxies on `PATH`, and let a directory pin the version it wants.

**Written in W#.** That is the point rather than a constraint. `ingot` was the
first real program in the language; this is the second, and it leans on
`std/http`, `std/tls`, `std/toml` and `std/inflate` hard enough to find out
where they bend.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/sinisterMage/sharpie/main/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/sinisterMage/sharpie/main/install.ps1 | iex
```

Then put the proxies on `PATH` -- the installer prints this line with the right
directory in it:

```sh
export PATH="$HOME/.sharpie/bin:$PATH"
```

`SHARPIE_HOME` says where to install; `SHARPIE_VERSION` pins a version rather
than taking the newest. Both installers read both.

The shell script assumes only `uname`, `tar` and one of `curl`/`wget`; the
PowerShell one assumes `tar`, which Windows has shipped since Windows 10 1803.
Each checks what it downloaded against a published digest and hands over to
`sharpie init` for everything after that. Upgrading sharpie is running it again:
it drops a new binary in and `init` rewrites the proxies as copies of it, which
is why there is no `self update` verb.

`install.sh` runs on Windows too, under Git Bash or MSYS -- `install.ps1` is
there for the machine that has neither, and is otherwise the same script.
Neither one edits `PATH` for you; they print the line to run.

Builds exist for the platforms W# itself is published for -- x86\_64 Linux,
x86\_64 Windows, and both Darwins. sharpie is built *by* `wsharp`, so it cannot
get ahead of that list.

## Using it

```sh
sharpie install stable      # fetch a toolchain and make it the default
wsharp build hello.ws       # through the proxy, into that toolchain
sharpie show                # what would run here, and why
sharpie update              # re-ask the channel and follow it
```

`stable` and `latest` are channels and are re-asked by `update`; an exact
version is a one-off and is left alone. That distinction is recorded at install
time, so somebody who asked for `0.1.0` is never quietly moved off it.

Output is tab-separated, one record a line, as `ingot`'s is -- so it composes
with `cut` instead of needing a `--json` that would have to be kept in step
with it.

## Which toolchain runs

Five things can decide, and the first that answers wins:

1. `+name` in front of a proxied command -- `wsharp +0.1.0 build x.ws`
2. `SHARPIE_TOOLCHAIN`
3. `wsharp-toolchain.toml`, looked for from the working directory upwards
4. a directory override -- `sharpie override set 0.1.0`
5. the default -- `sharpie default 0.1.0`

The order is rustup's, and each rung is more specific and more deliberate than
the one below it. `sharpie show` prints which one answered, because that is the
first question when the answer surprises somebody.

A rung naming a toolchain that is not installed **stops there** rather than
falling through to the next one: quietly running a different compiler than the
one that was asked for, and saying nothing about it, is worse than refusing.

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

The proxies are *copies* of the one binary rather than symlinks, because sharpie
reads which program to be from `self_exe` -- and on Linux that follows a symlink
to its target, so a symlinked `wsharp` would see itself as `sharpie`. Three
copies of one binary is the same trade rustup makes.

On Windows everything above is spelled with `.exe`, and one thing is done
differently. `init` writes a proxy by staging it beside its name and renaming it
over, which on Unix replaces the file even while it is being run -- and Windows
will not, because replacing means deleting and a running image cannot be
deleted. So the old file is moved aside to `<name>.exe.old` first and the new
one takes the name; the next `init` clears the leftover. That is the file
`bin/` collects one of, and it is rustup's answer to the same rule.

## Building

```sh
wsharp build src/main.ws -o sharpie      # -o sharpie.exe on Windows
```

The result is a self-contained native executable: the runtime archive is a
link-time input, so a built `sharpie` needs no W# installation to run. That is
what makes it a bootstrap -- one file, and it can go and get the rest.

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

CI runs the same script against a *released* `wsharp` rather than one built from
a WSharp working tree, which keeps a standing check on the thing that would
otherwise rot silently: sharpie has to keep compiling with the compiler its
users actually have.

## Licence

MIT, as W# is.
