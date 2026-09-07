// Which toolchain a command should run, and where its programs are.
//
// The resolution order is rustup's, and the order is the whole design: a
// command line beats an environment variable, an environment variable beats a
// file in the project, a file in the project beats a directory override, and a
// directory override beats the default. Each rung is more specific and more
// deliberate than the one below it.
//
// Nothing here opens a socket or unpacks anything. It answers *which* and
// *where*, so that installing and proxying can each be about one thing.
const array = @import("std/array");
const fs = @import("std/fs");
const home = @import("./home.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const settings = @import("./settings.ws");
const text = @import("std/str");
const toml = @import("std/toml");

/// The file a project uses to pin its toolchain.
///
/// Named for W# rather than for sharpie, deliberately: it belongs to the
/// project and says which *compiler* the project needs, which is true whatever
/// installs it. `rust-toolchain.toml` is the same idea and the same spelling.
pub const PIN_FILE = "wsharp-toolchain.toml";

/// Where a toolchain's programs are, and how it was chosen.
///
/// `dir` is what a proxy `exec`s into. `name` is what `sharpie show` prints.
/// `why` is the rung of the ladder that answered, which is the first thing
/// somebody asks when the answer surprises them.
pub const Choice = struct { name: str, dir: str, why: str };

/// Which toolchain applies, given a command line and a working directory.
///
/// `args` is the whole command line, so that a leading `+name` can be seen. The
/// caller strips it -- this only reports that it is there, because a proxy has
/// to remove it before handing the rest on and only it knows the shape of what
/// it is handing.
pub fn choose(h: str, s: settings.Settings, args: []str, cwd: str) ?Choice {
    if (plus_toolchain(args)) |named| { return located(h, s, named, "the `+` argument"); }
    if (os.get("SHARPIE_TOOLCHAIN")) |named| {
        if (text.len(named) > 0) { return located(h, s, named, "SHARPIE_TOOLCHAIN"); }
    }
    if (pinned_above(cwd)) |named| { return located(h, s, named, PIN_FILE); }
    if (settings.override_for(s, cwd)) |named| {
        return located(h, s, named, "a directory override");
    }
    if (settings.default_toolchain(s)) |named| { return located(h, s, named, "the default"); }
    return null;
}

/// `+name` as the first argument, or null.
///
/// Only in front, unlike `ingot`'s `--gc-stress` which is removed wherever it
/// appears. The difference is that this one is *positional* by convention:
/// `wsharp run x.ws -- +nightly` passes `+nightly` to the program, and reading
/// it here would steal an argument that was not ours.
pub fn plus_toolchain(args: []str) ?str {
    if (array.len(args) == 0) { return null; }
    const first = args[0];
    if (text.len(first) < 2) { return null; }
    if (text.byte_at(first, 0) != 43) { return null; }
    return text.substr(first, 1, text.len(first));
}

/// `args` with a leading `+name` removed, if there was one.
pub fn without_plus(args: []str) []str {
    const named = plus_toolchain(args) orelse return args;
    return array.slice(args, 1, array.len(args));
}

/// The toolchain a `wsharp-toolchain.toml` names, looked for from `dir` upwards.
///
/// Upwards, so a file at the root of a project covers every directory in it --
/// which is what makes it a *project's* pin rather than one directory's. The
/// walk stops at the filesystem root.
pub fn pinned_above(dir: str) ?str {
    var at = path.normalise(dir);
    while (true) {
        const file = path.join(at, PIN_FILE);
        if (io.exists(file)) {
            if (pinned_in(file)) |named| { return named; }
            // A file that is there and says nothing usable stops the walk
            // rather than being stepped over: it was put there on purpose, and
            // silently using a parent's pin instead would be worse than saying
            // nothing.
            return null;
        }
        const up = path.dirname(at);
        if (text.eq(up, at)) { return null; }
        at = up;
    }
    return null;
}

/// The `toolchain` a pin file names.
///
/// Two spellings, because both read naturally and neither costs anything:
///
///     toolchain = "0.1.0"
///
///     [toolchain]
///     channel = "stable"
///
/// The second is what `rust-toolchain.toml` uses, and a table leaves room for
/// a project to say more later without changing what it already says.
pub fn pinned_in(file: str) ?str {
    const src = io.read_file(file) catch { return null; };
    const doc = toml.parse(src);
    if (!doc.ok) { return null; }
    const v = toml.get(doc.root, "toolchain") orelse return null;
    // Asked with `kind` rather than by trying `as_str` and recovering, because
    // a `catch` that means "it was the other spelling" reads like a failure and
    // is not one.
    if (toml.kind(v) == toml.KIND_STR) {
        return toml.as_str(v) catch { return null; };
    }
    const t = toml.as_table(v) catch { return null; };
    const channel = toml.get(t, "channel") orelse return null;
    return toml.as_str(channel) catch { return null; };
}

/// Where a named toolchain's programs are.
///
/// Three kinds of name, tried in this order:
///
///   1. A linked directory, which is a compiler checkout rather than an
///      installation. First, so that linking `stable` to a working tree does
///      what somebody linking it plainly meant.
///   2. An installed toolchain by its full name, triple and all.
///   3. A bare version, which means this machine's triple.
///
/// Null when the name resolves to nothing installed. A *channel* name reaching
/// here is not resolved -- `stable` is a question for the network, and this
/// module does not ask the network. Whatever installs a channel writes the
/// version it chose into the settings, so by the time anything is run the
/// answer is a version.
pub fn located(h: str, s: settings.Settings, name: str, why: str) ?Choice {
    if (settings.link_dir(s, name)) |dir| {
        return Choice{ .name = name, .dir = dir, .why = text.concat(why, ", linked") };
    }
    const full = home.toolchain(h, name);
    if (fs.is_dir(full)) { return Choice{ .name = name, .dir = full, .why = why }; }

    const native = home.native(name);
    const guessed = home.toolchain(h, native);
    if (fs.is_dir(guessed)) { return Choice{ .name = native, .dir = guessed, .why = why }; }
    return null;
}

/// Every installed toolchain, by directory name.
pub fn installed(h: str) []str {
    const names = fs.read_dir(home.toolchains(h)) catch { return []str{}; };
    var out = []str{};
    var i = 0;
    while (i < array.len(names)) : (i += 1) {
        if (fs.is_dir(home.toolchain(h, names[i]))) { out = array.push(out, names[i]); }
    }
    return out;
}

/// A program inside a toolchain, with `.exe` where the platform wants one.
///
/// Asked by looking rather than by knowing the platform, which is what
/// `ingot`'s own `compiler()` does and for the same reason: this language has
/// no way to ask which system it is on beyond `os.target()`, and a file that is
/// there is a better answer than a guess about a name.
pub fn program(dir: str, name: str) ?str {
    const exe = path.join(dir, text.concat(name, ".exe"));
    if (io.exists(exe)) { return exe; }
    const plain = path.join(dir, name);
    if (io.exists(plain)) { return plain; }
    return null;
}
