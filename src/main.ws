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
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
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

/// This sharpie's version.
///
/// Written down here rather than injected at build time, so that a source
/// checkout answers the same as a released binary and neither has to be
/// believed over the other. The release workflow checks it against the tag and
/// refuses to publish a disagreement -- which turns forgetting to bump it into
/// a failed release rather than a binary that lies about what it is.
pub const VERSION = "0.1.2";

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
    // Every spelling somebody might try, because the one thing worse than a
    // program that will not say its version is one that has an opinion about
    // how it should be asked.
    if (text.eq(name, "--version") or text.eq(name, "-V") or text.eq(name, "version")) {
        print(text.concat("sharpie ", VERSION));
        return OK;
    }
    if (text.eq(name, "show")) { return show(f); }
    if (text.eq(name, "which")) { return which(f, rest); }
    if (text.eq(name, "default")) { return set_default(f, rest); }
    if (text.eq(name, "toolchain")) { return toolchain_verb(f, rest); }
    if (text.eq(name, "init")) { return init_verb(f); }
    if (text.eq(name, "install")) { return install_verb(f, rest); }
    if (text.eq(name, "uninstall")) { return uninstall_verb(f, rest); }
    if (text.eq(name, "update")) { return update_verb(f); }
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
        print(text.concat("toolchain\t-\t", toolchain.why_nothing(s, []str{}, cwd)));
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
        fault.fail(f, toolchain.why_nothing(s, []str{}, cwd));
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

/// Make the directories, and the proxies.
///
/// A proxy is a **copy of this binary** under another name, not a script and
/// not a symlink. A copy because `src/proxy.ws` reads which program to be from
/// `self_exe`, and on Linux that follows a symlink to its target -- so a
/// symlinked `wsharp` would see itself as `sharpie` and print a usage message.
/// The cost is three copies of one binary, which is the same trade rustup
/// makes.
///
/// Idempotent, and that is what makes it the way to upgrade sharpie itself:
/// re-running `install.sh` puts a new binary in `bin/`, and running `init` from
/// it rewrites the proxies as copies of the new one. There is no `self update`
/// verb -- a program replacing its own running image is a trick worth avoiding
/// when the installer is already there and already does it.
fn init_verb(f: fault.Fault) i64 {
    const h = opened(f) orelse return FAILED;
    const me = os.self_exe() catch {
        fault.fail(f, "cannot find this program on disk, so cannot copy it");
        return FAILED;
    };
    const image = io.read_file(me) catch {
        fault.fail(f, text.concat("cannot read ", me));
        return FAILED;
    };

    // Every directory sharpie owns, so that nothing later has to check.
    if (!made(f, home.bin(h)) or !made(f, home.toolchains(h))) { return FAILED; }
    if (!made(f, home.downloads(h)) or !made(f, home.scratch(h))) { return FAILED; }

    if (!proxy_at(f, h, "sharpie", image)) { return FAILED; }
    if (!proxy_at(f, h, "wsharp", image)) { return FAILED; }
    if (!proxy_at(f, h, "ingot", image)) { return FAILED; }

    print(text.concat("home\t", h));
    print(text.concat("bin\t", home.bin(h)));
    return OK;
}

fn made(f: fault.Fault, dir: str) bool {
    fs.mkdir_all(dir) catch {
        fault.fail(f, text.concat("cannot create ", dir));
        return false;
    };
    return true;
}

/// One proxy: this binary's bytes under `name`, and runnable.
///
/// `.exe` where the platform wants one.
///
/// **Staged beside the target and `rename`d over it, never opened for writing
/// in place.** A running executable cannot be written to -- Linux answers
/// `ETXTBSY`, "text file busy" -- and `bin/sharpie` writing `bin/sharpie` is
/// not a hypothetical: it is exactly what happens on a first install, because
/// `install.sh` copies this binary into `bin/` and then runs *that copy* to
/// make the proxies. Writing in place failed on the first of the three and
/// left an installation with no `wsharp` and no `ingot` in it.
///
/// `rename` has no such objection on Unix: it replaces the directory entry and
/// leaves the running image alone, which is also what makes upgrading work.
/// Being atomic is the bonus -- an interrupted `init` leaves the old proxy
/// rather than half of a new one. [`published`] has what Windows does instead.
fn proxy_at(f: fault.Fault, h: str, name: str, image: str) bool {
    var spelled = name;
    if (home.on_windows()) { spelled = text.concat(name, ".exe"); }
    const at = path.join(home.bin(h), spelled);

    // In the same directory, so the `rename` cannot cross a filesystem; random,
    // so two `init` runs cannot stage into one file.
    const tag = crypto.random(8) catch {
        fault.fail(f, "cannot name a temporary file");
        return false;
    };
    const staged = text.concat(at, text.concat(".", bytes.to_hex(tag)));

    io.write_file(staged, image) catch {
        fault.fail(f, text.concat("cannot write ", staged));
        return false;
    };
    // Runnable before it is published, so the name never exists as a file that
    // cannot be run.
    fs.chmod(staged, 0o755) catch {
        fault.fail(f, text.concat("cannot make ", text.concat(staged, " runnable")));
        drop(staged);
        return false;
    };
    if (!published(f, staged, at)) {
        drop(staged);
        return false;
    }
    print(text.concat("proxy\t", at));
    return true;
}

/// Move `staged` on to `at`, whatever is already there.
///
/// **Windows will not replace a file that is being run, and `rename` is where
/// that shows up.** The loader opens an image `FILE_SHARE_READ |
/// FILE_SHARE_DELETE`, so the running `bin\sharpie.exe` can be *renamed* but
/// cannot be deleted -- and `MoveFileEx(..., MOVEFILE_REPLACE_EXISTING)`, which
/// is what `fs.rename` is here, has to delete the destination to replace it. So
/// the one step that works everywhere else is the one that fails on the first
/// of the three proxies, and for the same reason `ETXTBSY` used to: `init` is
/// running from the file it is writing.
///
/// The way out is the direction Windows *does* allow. Move the old file aside,
/// which leaves the running image reachable under another name and the wanted
/// name free, and then move the new one in. rustup does this and calls the
/// leftover `.old`; so does this, and for the same reason -- a fixed name means
/// `bin/` collects one stale file per proxy rather than one per upgrade, and
/// the next `init` clears it before making its own.
///
/// Tried in that order rather than switched on the platform, because a plain
/// `rename` is atomic and this is not: there is a moment with no `sharpie.exe`
/// in `bin`. Unix never reaches the second half, and Windows only reaches it
/// for the proxy that is actually running.
fn published(f: fault.Fault, staged: str, at: str) bool {
    if (moved(staged, at)) { return true; }
    if (!displaced(at)) {
        fault.fail(f, text.concat("cannot put a proxy at ", at));
        return false;
    }
    if (moved(staged, at)) { return true; }
    fault.fail(f, text.concat("cannot put a proxy at ", at));
    return false;
}

/// Get `at` out of the way, and say whether the name is now free.
///
/// False when there was nothing there to move, because then the caller's
/// `rename` failed for some other reason and retrying it would fail the same
/// way -- reporting the first failure is more useful than reporting it twice.
fn displaced(at: str) bool {
    if (!io.exists(at)) { return false; }
    const old = text.concat(at, ".old");
    // The previous upgrade's leftover, if this is not the first. It is gone
    // by now on any machine that has restarted the program since, and if it is
    // not, the rename below says so rather than this line.
    drop(old);
    return moved(at, old);
}

/// `rename`, as a question rather than as an error.
///
/// A caught error does not compare against anything here, so which of the
/// dozen filesystem reasons it was is not a question that can be put. What the
/// caller needs is whether the file arrived.
fn moved(from: str, to: str) bool {
    fs.rename(from, to) catch { return false; };
    return true;
}

/// Throw away a staged proxy, saying nothing if that fails too.
///
/// The failure being cleaned up after is the one worth reporting; a second
/// message about the leftovers would replace it with a less useful one.
fn drop(at: str) void {
    fs.remove(at) catch { return; };
    return;
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
        if (release.is_channel(args[0])) { settings.set_channel(s, args[0]); }
        return adopt(f, h, s, name);
    }

    // The archive is written down before it is unpacked, so a failure part way
    // through leaves something a retry can use rather than a hole.
    const archive = release.download(f, want, triple, cfg) orelse return FAILED;
    if (!keep(f, h, release.archive_name(want, triple), archive)) { return FAILED; }
    if (!install.unpack(f, h, name, archive)) { return FAILED; }

    print(text.concat("installed\t", name));
    if (release.is_channel(args[0])) { settings.set_channel(s, args[0]); }
    return adopt(f, h, s, name);
}

/// Make a freshly installed toolchain the default when there is not one yet.
///
/// Only when there is not one: installing a second toolchain should not quietly
/// move somebody off the one they were using.
fn adopt(f: fault.Fault, h: str, s: settings.Settings, name: str) i64 {
    // Saved either way, and that matters: the caller may have just recorded a
    // channel, and returning early because a default already exists would
    // throw that away -- so `update` would then say nothing was installed from
    // a channel, having just installed one.
    var chose = false;
    if (settings.default_toolchain(s)) |already| {
    } else {
        settings.set_default(s, name);
        chose = true;
    }
    settings.save(h, s) catch {
        fault.fail(f, text.concat("installed, but cannot write ", home.settings(h)));
        return FAILED;
    };
    if (chose) { print(text.concat("default\t", name)); }
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

/// Re-ask the channel the default came from, and install what it says now.
///
/// Only a channel is re-asked. Somebody who installed `0.1.8` asked for
/// `0.1.8`, and moving them off it because something newer exists would be
/// answering a question they did not put -- which is why `install` records
/// whether the request was standing.
fn update_verb(f: fault.Fault) i64 {
    const h = opened(f) orelse return FAILED;
    const s = read_settings(f, h) orelse return FAILED;

    const chan = settings.channel(s) orelse {
        fault.fail(f, "nothing was installed from a channel; `sharpie install stable` starts one");
        return NOTHING;
    };
    const cfg = fetch.anchors() catch {
        fault.fail(f, "cannot read this machine's certificate store");
        return FAILED;
    };
    const versions = release.available(f, cfg);
    if (!f.ok) { return FAILED; }
    const want = release.resolve(versions, chan) orelse {
        fault.fail(f, text.concat(text.concat("`", chan), "` names no release"));
        return FAILED;
    };

    const triple = os.target();
    const name = home.spell(semver.render(want), triple);
    if (fs.is_dir(home.toolchain(h, name))) {
        print(text.concat(text.concat("current\t", chan), text.concat("\t", name)));
        return OK;
    }

    const archive = release.download(f, want, triple, cfg) orelse return FAILED;
    if (!keep(f, h, release.archive_name(want, triple), archive)) { return FAILED; }
    if (!install.unpack(f, h, name, archive)) { return FAILED; }
    print(text.concat("installed\t", name));

    // The channel moved, so what it points at moves with it. This is the one
    // place a default is changed without being asked for by name, and it is
    // what "install stable" meant in the first place.
    settings.set_default(s, name);
    if (!saved(f, h, s)) { return FAILED; }
    print(text.concat("default\t", name));
    return OK;
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

    // Removing what the default names leaves an installation where nothing
    // runs. Said here rather than left for the next command to discover,
    // because here it is still obvious which act caused it -- and the settings
    // are deliberately not rewritten, since picking a replacement is a choice
    // and guessing one is how somebody ends up on a compiler they did not ask
    // for.
    if (settings.default_toolchain(s)) |named| {
        if (text.eq(named, found.name)) {
            print("warning\tthat was the default; `sharpie default <toolchain>` picks another");
        }
    }
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
    print("  init                          make ~/.sharpie and its proxies");
    print("  install <version|channel>     fetch a toolchain and keep it");
    print("  uninstall <toolchain>         take one away");
    print("  update                        re-ask the channel and follow it");
    print("  show                          what would run here, and why");
    print("  which <command>               where that command actually is");
    print("  default <toolchain>           use this one when nothing else says");
    print("  toolchain list                what is installed and what is linked");
    print("  toolchain link <name> <dir>   name a directory that holds a toolchain");
    print("  override set <toolchain>      pin this directory to one");
    print("  override unset | list         drop one, or show them all");
    print("  version                       which sharpie this is");
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
