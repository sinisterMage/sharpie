// A toolchain name is never a path, at any rung of the ladder or in any verb.
//
// **The case this exists for is a repository somebody has just cloned.** A name
// becomes `toolchains/<name>`, and `path.join` answers an absolute second
// argument with itself while `..` climbs straight out of `toolchains/` -- so a
// `wsharp-toolchain.toml` saying `toolchain = "../../../../proc/self/cwd/.tools"`
// made the proxied `wsharp build` run the repository's own `.tools/wsharp`, and
// `sharpie show` reported it as an ordinary pin. The same arithmetic made
// `sharpie uninstall /any/dir` delete `/any/dir`.
//
// So every rung here names a directory that *is* there and holds a `wsharp`,
// which is what made the old answer a toolchain rather than nothing, and each
// home also has an installed default that falling through would reach. Only
// what already existed is called -- `located`, `choose`, `why_nothing`,
// `install.remove`, `install.unpack` -- so this case says what the unfixed code
// did rather than failing to compile against it. What a name *is* is tabled in
// `home.ws`; `SHARPIE_TOOLCHAIN` is in `names_env.ws`, for `toolchain_env.ws`'s
// reason.
//
// expect: a relative path locates nothing, though it is a directory: true
// expect: nor does an absolute one: true
// expect: nor does an empty name, which is `toolchains/` itself: true
// expect: an ordinary name still locates: 0.1.0-here
// expect: `+` naming a path chooses nothing: true
// expect: `+` says: `../escaped` is not a toolchain name (the `+` argument); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: a pin naming a path chooses nothing: true
// expect: the pin says: `../escaped` is not a toolchain name (wsharp-toolchain.toml); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: an absolute pin chooses nothing: true
// expect: and says it is not a name: true
// expect: an empty pin chooses nothing: true
// expect: the empty pin says: the wsharp-toolchain.toml names no toolchain: it needs `toolchain = "<version>"`, or a `[toolchain]` table with a `channel`
// expect: a malformed pin chooses nothing: true
// expect: and names its file: true
// expect: a pin without `toolchain` chooses nothing: true
// expect: an override naming a path chooses nothing: true
// expect: the override says: `../escaped` is not a toolchain name (a directory override); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: a default naming a path chooses nothing: true
// expect: the default says: `../escaped` is not a toolchain name (the default); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: a link written under a path's name is not reached: true
// expect: a pin smuggling a record is spelled out: `x\x0adirectory\x09/evil` is not a toolchain name (wsharp-toolchain.toml); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: unpack refuses a path and writes nothing: true
// expect: remove refuses a relative path and deletes nothing: true
// expect: it says: `../victim` is not a toolchain name; a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: remove refuses an absolute path and deletes nothing: true
// expect: remove refuses an empty name and every toolchain survives: true
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fault = @import("ingot/fault");
const fs = @import("std/fs");
const home = @import("../src/home.ws");
const install = @import("../src/install.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const settings = @import("../src/settings.ws");
const text = @import("std/str");
const toolchain = @import("../src/toolchain.ws");

const A = "0.1.0-here";

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-names-", tag));
    try install_at(home.toolchain(h, A));

    // Beside `toolchains/`, so `../escaped` reaches it from inside -- and with
    // a `wsharp` in it, so that finding it would have been a toolchain.
    const escaped = path.join(h, "escaped");
    try install_at(escaped);

    const s = try settings.read(h);
    settings.set_default(s, A);

    print(text.concat("a relative path locates nothing, though it is a directory: ",
        yes(nothing_at(h, s, "../escaped"))));
    print(text.concat("nor does an absolute one: ", yes(nothing_at(h, s, escaped))));
    print(text.concat("nor does an empty name, which is `toolchains/` itself: ",
        yes(nothing_at(h, s, ""))));
    const fine = toolchain.located(h, s, A, "asked for") orelse {
        print("an ordinary name still locates: nothing");
        return;
    };
    print(text.concat("an ordinary name still locates: ", fine.name));

    // Rung one. The default is installed, so a ladder that fell through would
    // answer with it; nothing at all is the only right answer.
    const plus = []str{ "+../escaped", "build" };
    const nowhere = path.join(h, "nowhere");
    try fs.mkdir_all(nowhere);
    print(text.concat("`+` naming a path chooses nothing: ", yes(unchosen(h, s, plus, nowhere))));
    print(text.concat("`+` says: ", toolchain.why_nothing(s, plus, nowhere)));

    // Rung three, which is the one a stranger writes.
    const repo = path.join(h, "repo");
    try fs.mkdir_all(repo);
    const pin = path.join(repo, toolchain.PIN_FILE);
    try io.write_file(pin, "toolchain = \"../escaped\"\n");
    print(text.concat("a pin naming a path chooses nothing: ", yes(unchosen(h, s, []str{}, repo))));
    print(text.concat("the pin says: ", toolchain.why_nothing(s, []str{}, repo)));

    // Spelled with `/`: on Windows the temporary directory arrives as
    // `C:\Users\...`, and a `\U` in a TOML string is an escape, so the raw
    // spelling would make this a malformed pin rather than an absolute one.
    try io.write_file(pin, text.concat(text.concat("toolchain = \"", path.normalise(escaped)), "\"\n"));
    print(text.concat("an absolute pin chooses nothing: ", yes(unchosen(h, s, []str{}, repo))));
    print(text.concat("and says it is not a name: ",
        yes(text.find(toolchain.why_nothing(s, []str{}, repo), "is not a toolchain name") >= 0)));

    try io.write_file(pin, "toolchain = \"\"\n");
    print(text.concat("an empty pin chooses nothing: ", yes(unchosen(h, s, []str{}, repo))));
    print(text.concat("the empty pin says: ", toolchain.why_nothing(s, []str{}, repo)));

    // A pin that is not TOML at all, and one that is and names nothing, decide
    // the ladder too. The default is installed, so one that fell through --
    // which both did -- would have answered with it.
    try io.write_file(pin, "toolchain = 0.2.3 is not a string\n");
    print(text.concat("a malformed pin chooses nothing: ", yes(unchosen(h, s, []str{}, repo))));
    const said = toolchain.why_nothing(s, []str{}, repo);
    print(text.concat("and names its file: ",
        yes(text.find(said, "names no toolchain") >= 0 and text.find(said, path.normalise(pin)) >= 0)));
    try io.write_file(pin, "channel = \"stable\"\n");
    print(text.concat("a pin without `toolchain` chooses nothing: ", yes(unchosen(h, s, []str{}, repo))));

    // Rung four, in a directory with no pin above it.
    const spot = path.join(h, "spot");
    try fs.mkdir_all(spot);
    const o = try settings.read(path.join(h, "unwritten"));
    settings.set_default(o, A);
    settings.set_override(o, spot, "../escaped");
    print(text.concat("an override naming a path chooses nothing: ", yes(unchosen(h, o, []str{}, spot))));
    print(text.concat("the override says: ", toolchain.why_nothing(o, []str{}, spot)));

    // Rung five, which has nothing below it to fall to -- but the home is still
    // the one the path was relative to.
    const d = try settings.read(path.join(h, "unwritten"));
    settings.set_default(d, "../escaped");
    print(text.concat("a default naming a path chooses nothing: ", yes(unchosen(h, d, []str{}, nowhere))));
    print(text.concat("the default says: ", toolchain.why_nothing(d, []str{}, nowhere)));

    // `toolchain link` refuses such a name now; one written by hand into the
    // settings is still not reachable through a pin that happens to spell it.
    const l = try settings.read(path.join(h, "unwritten"));
    settings.set_link(l, "../elsewhere", escaped);
    print(text.concat("a link written under a path's name is not reached: ",
        yes(nothing_at(h, l, "../elsewhere"))));

    // A name is echoed back when it is refused, into a tab-separated record.
    try io.write_file(pin, "toolchain = \"x\\ndirectory\\t/evil\"\n");
    print(text.concat("a pin smuggling a record is spelled out: ",
        toolchain.why_nothing(s, []str{}, repo)));

    // And the two verbs that write and delete trees, which are where a path
    // posing as a name stops being a wrong answer and starts being lost data.
    const archive = try io.read_file("tests/fixtures/release.tar.gz");
    const u = fault.none();
    const planted = install.unpack(u, h, "../planted", archive);
    print(text.concat("unpack refuses a path and writes nothing: ",
        yes(!planted and !fs.is_dir(path.join(h, "planted")))));

    const victim = path.join(h, "victim");
    try install_at(victim);
    const r = fault.none();
    const gone = install.remove(r, h, "../victim");
    print(text.concat("remove refuses a relative path and deletes nothing: ",
        yes(!gone and fs.is_dir(victim))));
    print(text.concat("it says: ", r.message));

    const a = fault.none();
    const gone_too = install.remove(a, h, victim);
    print(text.concat("remove refuses an absolute path and deletes nothing: ",
        yes(!gone_too and fs.is_dir(victim))));

    // Last, because the unfixed code answered it by removing `toolchains/`.
    const e = fault.none();
    const all_gone = install.remove(e, h, "");
    print(text.concat("remove refuses an empty name and every toolchain survives: ",
        yes(!all_gone and fs.is_dir(home.toolchain(h, A)))));

    try fs.remove_tree(h);
    return;
}

/// A directory with something in it that a proxy would exec.
fn install_at(dir: str) !void {
    try fs.mkdir_all(path.join(dir, "lib"));
    try io.write_file(path.join(dir, "wsharp"), "not really a compiler\n");
    return;
}

fn nothing_at(h: str, s: settings.Settings, name: str) bool {
    const got = toolchain.located(h, s, name, "asked for") orelse return true;
    return false;
}

fn unchosen(h: str, s: settings.Settings, args: []str, cwd: str) bool {
    const got = toolchain.choose(h, s, args, cwd) orelse return true;
    return false;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
