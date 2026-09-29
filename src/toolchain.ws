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
const fault = @import("ingot/fault");
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

/// A toolchain the ladder named, and the rung that named it.
///
/// Separate from [`Choice`] because it is the answer to a different question.
/// A `Choice` is something that can be run; an `Ask` is only what was asked
/// for, and may name nothing installed at all.
pub const Ask = struct { name: str, why: str };

/// Which toolchain the ladder names, installed or not.
///
/// **The rungs live here rather than in [`choose`], and that split is what
/// makes a failure explicable.** `choose` answering null says "nothing
/// runnable", which is one symptom covering two situations with opposite
/// fixes: a home with no default at all, and a pin file naming a version that
/// was never installed. Only the name that was *asked for* tells them apart,
/// and by the time `choose` has failed it has been discarded.
///
/// `args` is the whole command line, so that a leading `+name` can be seen. The
/// caller strips it -- this only reports that it is there, because a proxy has
/// to remove it before handing the rest on and only it knows the shape of what
/// it is handing.
///
/// What a rung names is answered whether or not it is a name at all. The first
/// rung that says anything is the one that decides, so a pin file naming a path
/// is not stepped over on the way to the default: [`located`] refuses it, and
/// [`why_nothing`] says which rung it was.
pub fn asked(s: settings.Settings, args: []str, cwd: str) ?Ask {
    if (plus_toolchain(args)) |named| {
        return Ask{ .name = named, .why = "the `+` argument" };
    }
    if (os.get("SHARPIE_TOOLCHAIN")) |named| {
        if (text.len(named) > 0) { return Ask{ .name = named, .why = "SHARPIE_TOOLCHAIN" }; }
    }
    if (pinned_above(cwd)) |named| { return Ask{ .name = named, .why = PIN_FILE }; }
    if (settings.override_for(s, cwd)) |named| {
        return Ask{ .name = named, .why = "a directory override" };
    }
    if (settings.default_toolchain(s)) |named| {
        return Ask{ .name = named, .why = "the default" };
    }
    return null;
}

/// Which toolchain applies, given a command line and a working directory.
///
/// The ladder, and then the question of whether what it named is on disk.
/// Null when either half has no answer; [`why_nothing`] says which.
pub fn choose(h: str, s: settings.Settings, args: []str, cwd: str) ?Choice {
    const a = asked(s, args, cwd) orelse return null;
    return located(h, s, a.name, a.why);
}

/// Why [`choose`] answered null, in a sentence.
///
/// One place for the wording because three callers say it -- the proxy, `show`
/// and `which` -- and somebody comparing two of them should not have to work
/// out whether they mean the same thing.
///
/// The rung is named because it is the question that follows. `0.9.9 is not
/// installed` invites "I never asked for that"; `(wsharp-toolchain.toml)` is
/// the answer, and it points at the file to edit.
pub fn why_nothing(s: settings.Settings, args: []str, cwd: str) str {
    const a = asked(s, args, cwd) orelse {
        return "nothing is chosen; `sharpie install stable` gets a toolchain and makes it the default";
    };
    // Before "not installed", which would be true and would send the reader to
    // `toolchain list` looking for a directory that must never be there.
    if (!home.is_name(a.name)) {
        return text.concat(text.concat(text.concat(quoted(a.name), " is not a toolchain name ("),
            a.why), text.concat("); ", WHAT_A_NAME_IS));
    }
    return text.concat(text.concat(text.concat("`", a.name), "` is not installed ("),
        text.concat(a.why, "); `sharpie toolchain list` says what is"));
}

/// The second half of every refusal of a name, so they all say the same thing.
pub const WHAT_A_NAME_IS = "a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path";

/// Whether `name` can name a toolchain; when it cannot, the reason is in `f`.
///
/// Asked first by every verb that takes a toolchain on its command line --
/// `default`, `uninstall`, `override set`, `toolchain link` and `install` --
/// and again by the two steps that write and delete a tree, so all of them
/// refuse a path in the same words. The ladder says the same through
/// [`why_nothing`], with the rung added.
pub fn named(f: fault.Fault, name: str) bool {
    if (home.is_name(name)) { return true; }
    fault.fail(f, not_a_name(name));
    return false;
}

/// Why a verb given `name` will not use it.
pub fn not_a_name(name: str) str {
    return text.concat(text.concat(quoted(name), " is not a toolchain name; "), WHAT_A_NAME_IS);
}

/// `name` in backticks, with every control character spelled `\xNN`.
///
/// A name that has just been refused came from somewhere untrusted, and `show`
/// prints the refusal as a field of a tab-separated record. A pin file that
/// said `toolchain = "x\ndirectory\t/somewhere"` would otherwise write a second
/// record of its own choosing into the answer to "what would run here", and a
/// terminal escape in one would be read by the terminal rather than by the user.
fn quoted(name: str) str {
    const digits = "0123456789abcdef";
    var out = "`";
    var i = 0;
    while (i < text.len(name)) : (i += 1) {
        const b = text.byte_at(name, i);
        if (b < 32 or b == 127) {
            out = text.concat(out, "\\x");
            out = text.concat(out, text.from_byte(text.byte_at(digits, (b >> 4) & 15)));
            out = text.concat(out, text.from_byte(text.byte_at(digits, b & 15)));
        } else {
            out = text.concat(out, text.from_byte(b));
        }
    }
    return text.concat(out, "`");
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
///
/// Null, too, for anything that is not a name ([`home.is_name`]), and before
/// any of the three lookups: every rung of the ladder and every verb that takes
/// a toolchain comes through here, so this is the one place a path cannot get
/// past. A link is not an exception. `toolchain link` refuses to make one under
/// such a name, and one written into `settings.toml` by hand is still not
/// something a pin file in a stranger's repository should be able to reach.
pub fn located(h: str, s: settings.Settings, name: str, why: str) ?Choice {
    if (!home.is_name(name)) { return null; }
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
