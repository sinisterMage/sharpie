// `settings.toml`, written and read back.
//
// The round trip is the test, for the reason `std/toml`'s own writer says: a
// file the reader beside it cannot read back is a bug nobody finds until the
// day it matters.
//
// The override cases are the ones with teeth. Longest match must win, or a
// project inside an overridden tree could never pin something else; and the
// match must be on whole components, or `/a/b` would capture `/a/bc`.
//
// This case writes into a directory of its own under the temporary directory,
// named with random bytes because the suite may run twice at once -- the same
// arrangement `tests/cases/os_process.ws` uses upstream.
//
// expect: nothing is set to start with: true
// expect: default after setting: 0.1.1-x86_64-unknown-linux-gnu
// expect: default survives a round trip: 0.1.1-x86_64-unknown-linux-gnu
// expect: exact directory: 0.2.0-aarch64-apple-darwin
// expect: a directory below it inherits: 0.2.0-aarch64-apple-darwin
// expect: the longest override wins: 0.3.0-aarch64-apple-darwin
// expect: a sibling with a shared prefix does not match: true
// expect: an unrelated directory has no override: true
// expect: overrides recorded: 2
// expect: setting the same directory twice replaces: 0.9.9-aarch64-apple-darwin
// expect: still only two overrides: 2
// expect: unset reports it dropped one: true
// expect: unset again reports nothing: false
// expect: one override left: 1
// expect: link resolves: /home/somebody/WSharp/target/release
// expect: an unknown link is null: true
// expect: unknown keys survive a round trip: keep me
// expect: written as an array of tables: true
const array = @import("std/array");
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fs = @import("std/fs");
const home = @import("../src/home.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const settings = @import("../src/settings.ws");
const text = @import("std/str");
const toml = @import("std/toml");

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-settings-", tag));
    try fs.mkdir_all(h);

    // A home that has been told nothing is not an error, it is a new one.
    var s = try settings.read(h);
    print(text.concat("nothing is set to start with: ",
        yes(absent(settings.default_toolchain(s)))));

    settings.set_default(s, "0.1.1-x86_64-unknown-linux-gnu");
    show("default after setting", settings.default_toolchain(s) orelse "none");

    // A key this version does not know about, to prove `save` does not eat it.
    toml.set(s.root, "something_new", toml.of_str("keep me"));

    settings.set_override(s, "/work/project", "0.2.0-aarch64-apple-darwin");
    settings.set_override(s, "/work/project/vendor", "0.3.0-aarch64-apple-darwin");
    try settings.save(h, s);

    // Everything from here reads what was written, not what is in memory.
    s = try settings.read(h);
    show("default survives a round trip", settings.default_toolchain(s) orelse "none");

    show("exact directory", settings.override_for(s, "/work/project") orelse "none");
    show("a directory below it inherits",
        settings.override_for(s, "/work/project/src/deep") orelse "none");
    show("the longest override wins",
        settings.override_for(s, "/work/project/vendor/thing") orelse "none");

    // `/work/projector` shares a prefix with `/work/project` and is not under
    // it. Comparing strings without a separator test gets this wrong.
    print(text.concat("a sibling with a shared prefix does not match: ",
        yes(absent(settings.override_for(s, "/work/projector")))));
    print(text.concat("an unrelated directory has no override: ",
        yes(absent(settings.override_for(s, "/somewhere/else")))));
    print(text.concat("overrides recorded: ",
        text.from_int(array.len(settings.overrides(s)))));

    // Setting a directory that already has an override replaces it.
    settings.set_override(s, "/work/project", "0.9.9-aarch64-apple-darwin");
    show("setting the same directory twice replaces",
        settings.override_for(s, "/work/project") orelse "none");
    print(text.concat("still only two overrides: ",
        text.from_int(array.len(settings.overrides(s)))));

    print(text.concat("unset reports it dropped one: ",
        yes(settings.unset_override(s, "/work/project"))));
    print(text.concat("unset again reports nothing: ",
        yes(settings.unset_override(s, "/work/project"))));
    print(text.concat("one override left: ",
        text.from_int(array.len(settings.overrides(s)))));

    settings.set_link(s, "dev", "/home/somebody/WSharp/target/release");
    try settings.save(h, s);
    s = try settings.read(h);
    show("link resolves", settings.link_dir(s, "dev") orelse "none");
    print(text.concat("an unknown link is null: ", yes(absent(settings.link_dir(s, "nope")))));

    // The unknown key came back, which is what says an older sharpie will not
    // quietly truncate a newer one's settings.
    const kept = toml.get(s.root, "something_new") orelse toml.of_str("gone");
    show("unknown keys survive a round trip", toml.as_str(kept) catch "not a string");

    // And it really is `[[override]]` on disk, not an inline array -- which is
    // the whole reason the file is TOML rather than something terser.
    const src = try io.read_file(home.settings(h));
    print(text.concat("written as an array of tables: ",
        yes(text.find(src, "[[override]]") >= 0)));

    try fs.remove_tree(h);
    return;
}

/// Whether an optional holds nothing.
///
/// `== null` is not a comparison this language makes -- only numbers, `bool`,
/// `str` and `error` compare -- so absence is asked by trying to unwrap and
/// answering from which way that went.
fn absent(v: ?str) bool {
    const got = v orelse return true;
    return false;
}

fn show(label: str, got: str) void {
    print(text.concat(text.concat(label, ": "), got));
    return;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
