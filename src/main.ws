// sharpie: a version manager for W#.
//
// One binary with two jobs, told apart by the name it was invoked under.
// Copied into `~/.sharpie/bin` as `wsharp` or `ingot` it is a proxy and becomes
// the real program; called as `sharpie` it is the manager. `src/proxy.ws` has
// the reasoning for reading that name from `self_exe` rather than `argv[0]`.
//
// Output is tab-separated and one record a line, as `ingot`'s is, so that
// `sharpie toolchain list` composes with `cut` instead of needing a `--json`
// that would have to be kept in step with it.
const array = @import("std/array");
const fault = @import("ingot/fault");
const fetch = @import("./fetch.ws");
const fs = @import("std/fs");
const home = @import("./home.ws");
const install = @import("./install.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const proxy = @import("./proxy.ws");
const release = @import("./release.ws");
const semver = @import("ingot/semver");
const settings = @import("./settings.ws");
const text = @import("std/str");
const toolchain = @import("./toolchain.ws");

pub const OK = 0;
/// Nothing is wrong; the answer is just no. `sharpie which` when there is no
/// toolchain, and `sharpie show` when nothing has been chosen.
pub const NOTHING = 1;
pub const FAILED = 2;

fn main() i64 {
    const f = fault.none();
    const args = os.args();

    // The proxy path first, and it never returns on success.
    const me = proxy.invoked_as();
    if (proxy.is_proxied(me)) {
        const code = proxy.run(f, me, args);
        report(f);
        return code;
    }

    const code = verb(f, args);
    report(f);
    if (!f.ok and code == OK) { return FAILED; }
    return code;
}

fn report(f: fault.Fault) void {
    if (!f.ok) { print_err(text.concat("sharpie: ", f.message)); }
    return;
}

fn verb(f: fault.Fault, args: []str) i64 {
    if (array.len(args) == 0) { usage(); return FAILED; }
    const name = args[0];
    const rest = array.slice(args, 1, array.len(args));

    if (text.eq(name, "help") or text.eq(name, "--help") or text.eq(name, "-h")) {
        usage();
        return OK;
    }
    if (text.eq(name, "show")) { return show(f); }
    if (text.eq(name, "which")) { return which(f, rest); }
    if (text.eq(name, "default")) { return set_default(f, rest); }
    if (text.eq(name, "toolchain")) { return toolchain_verb(f, rest); }
    if (text.eq(name, "install")) { return install_verb(f, rest); }
    if (text.eq(name, "uninstall")) { return uninstall_verb(f, rest); }
    if (text.eq(name, "override")) { return override_verb(f, rest); }

    fault.fail(f, text.concat(text.concat("no such verb: `", name), "`"));
    return FAILED;
}

// ---------------------------------------------------------------------------
// The verbs that need no network
// ---------------------------------------------------------------------------

/// What would run here, and why.
///
/// The *why* is the point. Five things can decide which toolchain applies, and
/// when the answer surprises somebody the first question is always which of
/// them answered.
fn show(f: fault.Fault) i64 {
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const cwd = os.cwd() catch ".";

    print(text.concat("home\t", h));
    print(text.concat("target\t", os.target()));

    const chosen = toolchain.choose(h, s, []str{}, cwd) orelse {
        print("toolchain\t-\tnothing is chosen");
        return NOTHING;
    };
    print(text.concat(text.concat("toolchain\t", chosen.name),
        text.concat("\t", chosen.why)));
    print(text.concat("directory\t", chosen.dir));
    return OK;
}

/// Where the program that would run actually lives.
fn which(f: fault.Fault, args: []str) i64 {
    if (array.len(args) != 1) {
        fault.fail(f, "`which` takes one command, such as `sharpie which wsharp`");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const cwd = os.cwd() catch ".";
    const chosen = toolchain.choose(h, s, []str{}, cwd) orelse {
        fault.fail(f, "no toolchain is chosen; `sharpie default <version>` picks one");
        return FAILED;
    };
    const at = toolchain.program(chosen.dir, args[0]) orelse {
        fault.fail(f, text.concat(text.concat("`", args[0]),
            text.concat("` is not in ", chosen.dir)));
        return NOTHING;
    };
    print(at);
    return OK;
}

/// Choose the toolchain used when nothing more specific applies.
fn set_default(f: fault.Fault, args: []str) i64 {
    if (array.len(args) != 1) {
        fault.fail(f, "`default` takes one toolchain, such as `sharpie default 0.1.0`");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;

    // Refuse a name that is not installed, rather than writing a default that
    // every later command would trip over. A channel is not checked here --
    // resolving one is a question for the network, and `install` writes the
    // version it chose.
    const found = toolchain.located(h, s, args[0], "asked for") orelse {
        fault.fail(f, text.concat(text.concat("`", args[0]),
            "` is not installed; `sharpie toolchain list` says what is"));
        return FAILED;
    };
    settings.set_default(s, found.name);
    settings.save(h, s) catch {
        fault.fail(f, text.concat("cannot write ", home.settings(h)));
        return FAILED;
    };
    print(text.concat("default\t", found.name));
    return OK;
}

fn toolchain_verb(f: fault.Fault, args: []str) i64 {
    if (array.len(args) == 0) {
        fault.fail(f, "`toolchain` needs `list` or `link`");
        return FAILED;
    }
    if (text.eq(args[0], "list")) { return toolchain_list(f); }
    if (text.eq(args[0], "link")) {
        return toolchain_link(f, array.slice(args, 1, array.len(args)));
    }
    fault.fail(f, text.concat(text.concat("no such `toolchain` verb: `", args[0]), "`"));
    return FAILED;
}

/// Everything installed, and everything linked, one a line.
fn toolchain_list(f: fault.Fault) i64 {
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const chosen = settings.default_toolchain(s) orelse "";

    const names = toolchain.installed(h);
    var i = 0;
    while (i < array.len(names)) : (i += 1) {
        var mark = "";
        if (text.eq(names[i], chosen)) { mark = "\tdefault"; }
        print(text.concat(text.concat("installed\t", names[i]), mark));
    }
    const linked = settings.links(s);
    i = 0;
    while (i < array.len(linked)) : (i += 1) {
        print(text.concat(text.concat("linked\t", linked[i].toolchain),
            text.concat("\t", linked[i].dir)));
    }
    if (array.len(names) == 0 and array.len(linked) == 0) { return NOTHING; }
    return OK;
}

/// Point a name at a directory that already holds a toolchain.
///
/// How a compiler checkout becomes usable: `target/release` already has
/// `wsharp` beside its runtime archive, which is where `wsharp` looks, so this
/// copies nothing.
fn toolchain_link(f: fault.Fault, args: []str) i64 {
    if (array.len(args) != 2) {
        fault.fail(f, "`toolchain link` takes a name and a directory");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const dir = args[1];
    // Refused now rather than at the first `wsharp` run through it: a link is
    // recorded once and used for ever, so a typo should cost this command
    // rather than every command after it.
    const found = toolchain.program(dir, "wsharp") orelse {
        fault.fail(f, text.concat("no `wsharp` in ", dir));
        return FAILED;
    };
    settings.set_link(s, args[0], dir);
    settings.save(h, s) catch {
        fault.fail(f, text.concat("cannot write ", home.settings(h)));
        return FAILED;
    };
    print(text.concat(text.concat("linked\t", args[0]), text.concat("\t", dir)));
    return OK;
}

// ---------------------------------------------------------------------------
// The verbs that reach the network
// ---------------------------------------------------------------------------

/// Fetch a toolchain and put it where a proxy can find it.
///
/// Takes a version or a channel. A channel is resolved *here* and the version
/// it chose is what gets written down, so nothing below this ever has to ask
/// the network what `stable` means -- which is what lets `src/toolchain.ws`
/// open no sockets at all.
fn install_verb(f: fault.Fault, args: []str) i64 {
    if (array.len(args) != 1) {
        fault.fail(f, "`install` takes one version or channel, such as `sharpie install stable`");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;

    const cfg = fetch.anchors() catch {
        fault.fail(f, "cannot read this machine's certificate store");
        return FAILED;
    };
    const versions = release.available(f, cfg);
    if (!f.ok) { return FAILED; }
    if (array.len(versions) == 0) {
        fault.fail(f, text.concat("no releases are published at ", release.REPO));
        return FAILED;
    }
    const want = release.resolve(versions, args[0]) orelse {
        fault.fail(f, text.concat(text.concat("no release matches `", args[0]),
            "`; `stable`, `latest` or an exact version"));
        return FAILED;
    };

    const triple = os.target();
    const name = home.spell(semver.render(want), triple);
    if (fs.is_dir(home.toolchain(h, name))) {
        print(text.concat("already\t", name));
        return adopt(f, h, s, name);
    }

    // The archive is written down before it is unpacked, so a failure part way
    // through leaves something a retry can use rather than a hole.
    const archive = release.download(f, want, triple, cfg) orelse return FAILED;
    if (!keep(f, h, release.archive_name(want, triple), archive)) { return FAILED; }
    if (!install.unpack(f, h, name, archive)) { return FAILED; }

    print(text.concat("installed\t", name));
    return adopt(f, h, s, name);
}

/// Make a freshly installed toolchain the default when there is not one yet.
///
/// Only when there is not one: installing a second toolchain should not quietly
/// move somebody off the one they were using.
fn adopt(f: fault.Fault, h: str, s: settings.Settings, name: str) i64 {
    if (settings.default_toolchain(s)) |already| { return OK; }
    settings.set_default(s, name);
    settings.save(h, s) catch {
        fault.fail(f, text.concat("installed, but cannot write ", home.settings(h)));
        return FAILED;
    };
    print(text.concat("default\t", name));
    return OK;
}

/// Keep the downloaded archive, so a failed unpack need not fetch it again.
///
/// A failure here is worth reporting and is not worth stopping for -- the
/// bytes are in hand either way, and refusing to install because a *cache*
/// could not be written would be the wrong trade.
fn keep(f: fault.Fault, h: str, name: str, archive: str) bool {
    const room = home.downloads(h);
    fs.mkdir_all(room) catch { return true; };
    io.write_file(path.join(room, name), archive) catch { return true; };
    return true;
}

fn uninstall_verb(f: fault.Fault, args: []str) i64 {
    if (array.len(args) != 1) {
        fault.fail(f, "`uninstall` takes one toolchain");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const found = toolchain.located(h, s, args[0], "asked for") orelse {
        fault.fail(f, text.concat(text.concat("`", args[0]), "` is not installed"));
        return FAILED;
    };
    if (!install.remove(f, h, found.name)) { return FAILED; }
    print(text.concat("removed\t", found.name));
    return OK;
}

// ---------------------------------------------------------------------------
// Directory overrides
// ---------------------------------------------------------------------------

fn override_verb(f: fault.Fault, args: []str) i64 {
    if (array.len(args) == 0) {
        fault.fail(f, "`override` needs `set`, `unset` or `list`");
        return FAILED;
    }
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;
    const rest = array.slice(args, 1, array.len(args));

    if (text.eq(args[0], "list")) {
        const rows = settings.overrides(s);
        var i = 0;
        while (i < array.len(rows)) : (i += 1) {
            print(text.concat(text.concat("override\t", rows[i].dir),
                text.concat("\t", rows[i].toolchain)));
        }
        if (array.len(rows) == 0) { return NOTHING; }
        return OK;
    }

    // Both of the others act on the working directory unless told otherwise,
    // because that is what somebody standing in a project means.
    const cwd = os.cwd() catch ".";

    if (text.eq(args[0], "set")) {
        if (array.len(rest) < 1 or array.len(rest) > 2) {
            fault.fail(f, "`override set <toolchain> [directory]`");
            return FAILED;
        }
        var dir = cwd;
        if (array.len(rest) == 2) { dir = rest[1]; }
        const found = toolchain.located(h, s, rest[0], "asked for") orelse {
            fault.fail(f, text.concat(text.concat("`", rest[0]), "` is not installed"));
            return FAILED;
        };
        settings.set_override(s, dir, found.name);
        if (!saved(f, h, s)) { return FAILED; }
        print(text.concat(text.concat("override\t", path.normalise(dir)),
            text.concat("\t", found.name)));
        return OK;
    }

    if (text.eq(args[0], "unset")) {
        var dir = cwd;
        if (array.len(rest) == 1) { dir = rest[0]; }
        if (!settings.unset_override(s, dir)) {
            fault.fail(f, text.concat("no override on ", path.normalise(dir)));
            return NOTHING;
        }
        if (!saved(f, h, s)) { return FAILED; }
        print(text.concat("unset\t", path.normalise(dir)));
        return OK;
    }

    fault.fail(f, text.concat(text.concat("no such `override` verb: `", args[0]), "`"));
    return FAILED;
}

fn saved(f: fault.Fault, h: str, s: settings.Settings) bool {
    settings.save(h, s) catch {
        fault.fail(f, text.concat("cannot write ", home.settings(h)));
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Shared openings
// ---------------------------------------------------------------------------

fn opened(f: fault.Fault) ?str {
    const h = home.root() catch {
        fault.fail(f, "cannot find a home directory; set SHARPIE_HOME");
        return null;
    };
    return h;
}

fn read_settings(f: fault.Fault, h: str) ?settings.Settings {
    const s = settings.read(h) catch {
        fault.fail(f, text.concat(text.concat("cannot read ", home.settings(h)),
            " -- it is not valid TOML"));
        return null;
    };
    return s;
}

fn usage() void {
    print("sharpie -- the W# version manager");
    print("");
    print("  install <version|channel>     fetch a toolchain and keep it");
    print("  uninstall <toolchain>         take one away");
    print("  show                          what would run here, and why");
    print("  which <command>               where that command actually is");
    print("  default <toolchain>           use this one when nothing else says");
    print("  toolchain list                what is installed and what is linked");
    print("  toolchain link <name> <dir>   name a directory that holds a toolchain");
    print("  override set <toolchain>      pin this directory to one");
    print("  override unset | list         drop one, or show them all");
    print("  help                          this");
    print("");
    print("A toolchain is chosen by the first of these that answers:");
    print("  1. `+name` in front of a proxied command");
    print("  2. SHARPIE_TOOLCHAIN");
    print("  3. wsharp-toolchain.toml, looked for from here upwards");
    print("  4. a directory override");
    print("  5. the default");
    print("");
    print("SHARPIE_HOME says where toolchains live; it is not WSHARP_HOME,");
    print("which is where `ingot` keeps packages. Output is tab-separated.");
    return;
}
