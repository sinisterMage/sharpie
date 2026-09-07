// Where sharpie keeps things, and what a toolchain is called.
//
// **`SHARPIE_HOME`, not `WSHARP_HOME`.** The second one already exists and
// means something else: it is `ingot`'s content-addressed package store, the
// place downloaded *packages* live. Toolchains are a different kind of thing
// with a different lifetime, and putting them in the same tree would make
// `ingot gc` and `sharpie uninstall` two programs with an opinion about the
// same directory. The split is `RUSTUP_HOME` and `CARGO_HOME`'s, for the same
// reason.
//
// A toolchain is a *directory*, not a file, because `wsharp` links and a
// compiler that links needs something to link against. Two rules that already
// exist make the layout below work with no change to either program:
// `wsharp` looks for its runtime archive beside itself and under `../lib`
// (`wsharp-cli/src/link.rs`), and `ingot` looks for `wsharp` beside itself
// before it looks on `PATH` (`ingot/main.ws`). So a proxy can `exec` into a
// toolchain directory and everything inside it finds everything else.
const os = @import("std/os");
const path = @import("std/path");
const text = @import("std/str");

/// The root of everything sharpie owns.
///
/// `SHARPIE_HOME` first, so a test can point at a directory of its own and a
/// shared machine can say where it wants one -- which is what `ingot/store.ws`
/// does with `WSHARP_HOME`, and is the only way the cases below can run without
/// touching a real installation.
///
/// An empty value counts as unset, for `os.home`'s reason: a store rooted at
/// `""` is a store rooted at the working directory, which is much worse than
/// an error.
pub fn root() !str {
    if (os.get("SHARPIE_HOME")) |h| {
        if (text.len(h) > 0) { return h; }
    }
    return path.join(try os.home(), ".sharpie");
}

/// The proxies: `sharpie` itself, and one per program it stands in front of.
/// This is the directory a user puts on `PATH`, and the only one.
pub fn bin(h: str) str { return path.join(h, "bin"); }

/// Installed toolchains, one directory each, named by [`spell`].
pub fn toolchains(h: str) str { return path.join(h, "toolchains"); }

/// Where a named toolchain lives, whether or not it is there.
pub fn toolchain(h: str, name: str) str { return path.join(toolchains(h), name); }

/// Downloaded archives, kept after unpacking.
///
/// Kept on purpose: a release tarball is megabytes and an interrupted install
/// is the common failure, so a retry should not fetch it again. They are
/// content-checked before use, so a half-written one cannot be mistaken for a
/// whole one.
pub fn downloads(h: str) str { return path.join(h, "downloads"); }

/// Where a toolchain is unpacked before it is published.
///
/// Nothing is ever built in place under `toolchains/`: a tree is assembled here
/// and then `rename`d, so an interrupted install leaves rubbish in `tmp` rather
/// than a half-written toolchain that `sharpie toolchain list` would report as
/// installed. Same discipline as `ingot/store.install`.
pub fn scratch(h: str) str { return path.join(h, "tmp"); }

/// The one file sharpie writes about itself: the default, the overrides and
/// the linked directories.
pub fn settings(h: str) str { return path.join(h, "settings.toml"); }

// ---------------------------------------------------------------------------
// What a toolchain is called
// ---------------------------------------------------------------------------

/// A toolchain's directory name: its version and the triple it was built for.
///
/// The triple is in the name rather than assumed, because a home directory can
/// be shared between machines -- an NFS mount, a synced dotfiles repository, a
/// container bind-mounting the host's home. Two machines installing "0.1.1"
/// into the same `SHARPIE_HOME` must not land on the same directory, and with
/// the triple in the name they cannot.
pub fn spell(version: str, triple: str) str {
    return text.concat(text.concat(version, "-"), triple);
}

/// A name for this machine, which is the one a bare version means.
pub fn native(version: str) str {
    return spell(version, os.target());
}

/// The version half of a name, or the whole of it if there is no triple in it.
///
/// Split from the *right* at the first component that looks like a triple
/// rather than at the first `-`, because a version legitimately holds one:
/// `0.2.0-rc1-x86_64-unknown-linux-gnu` is version `0.2.0-rc1`. What makes a
/// triple recognisable is that it has at least two `-` of its own and starts
/// with an architecture, so the split point is found by looking for the
/// architecture rather than by counting separators.
pub fn version_of(name: str) str {
    const cut = triple_at(name);
    if (cut < 0) { return name; }
    return text.substr(name, 0, cut - 1);
}

/// The triple half of a name, or empty when it carries none.
pub fn triple_of(name: str) str {
    const cut = triple_at(name);
    if (cut < 0) { return ""; }
    return text.substr(name, cut, text.len(name));
}

/// Where the triple starts in `name`, or -1.
///
/// The architectures are written out rather than held in a table, because a
/// top-level `const` array lives in the data section the collector never
/// traces and so may hold only numbers -- which is why `std/hash` spells its
/// SHA-256 constants `[]u32` and why there is no `[]str` beside them. Seven
/// `if`s is what that costs here, and the list is short because it is not
/// trying to be exhaustive: an unrecognised name is treated as all-version,
/// which is exactly what a user typed if they typed one.
fn triple_at(name: str) i64 {
    var at = starts("x86_64-", name);
    if (at < 0) { at = starts("aarch64-", name); }
    if (at < 0) { at = starts("i686-", name); }
    if (at < 0) { at = starts("armv7-", name); }
    if (at < 0) { at = starts("riscv64-", name); }
    if (at < 0) { at = starts("powerpc64-", name); }
    if (at < 0) { at = starts("s390x-", name); }
    return at;
}

/// Where `arch` begins in `name` when a `-` comes before it, or -1.
///
/// The leading `-` is what makes this a *component* boundary rather than a
/// substring: without it a version somehow containing `x86_64-` would split in
/// the middle of itself.
fn starts(arch: str, name: str) i64 {
    const at = text.find(name, text.concat("-", arch));
    if (at < 0) { return -1; }
    return at + 1;
}
