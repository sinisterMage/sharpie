// `SHARPIE_TOOLCHAIN`, which is rung two of the ladder.
//
// A case of its own because there is no `setenv` here: the variable has to be
// set before the program starts, and setting it for `toolchain.ws` would win
// over every rung below it and leave no ladder to walk. So that case does the
// other four and this one does this.
//
// What it has to prove is not that the variable is read -- that is one line --
// but that it *beats a pin file*, which is the rung directly below it. A pin is
// checked into a project and applies to everyone; an environment variable is
// something a person typed for one command, and the more deliberate of the two
// wins.
//
// env: SHARPIE_TOOLCHAIN=0.2.0-here
//
// expect: the environment beats a pin file: 0.2.0-here	SHARPIE_TOOLCHAIN
// expect: and `+name` still beats the environment: 0.1.0-here	the `+` argument
// expect: an environment naming nothing installed chooses nothing: true
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fs = @import("std/fs");
const home = @import("../src/home.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const settings = @import("../src/settings.ws");
const text = @import("std/str");
const toolchain = @import("../src/toolchain.ws");

const A = "0.1.0-here";
const B = "0.2.0-here";

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-tcenv-", tag));
    const work = path.join(h, "work");
    try fs.mkdir_all(work);
    try install(h, A);
    try install(h, B);

    var s = try settings.read(h);
    // Everything below rung two says `A`, so anything answering `B` answered
    // from the environment and nowhere else.
    settings.set_default(s, A);
    settings.set_override(s, work, A);
    try io.write_file(path.join(work, toolchain.PIN_FILE),
        text.concat(text.concat("toolchain = \"", A), "\"\n"));

    say("the environment beats a pin file", h, s, []str{}, work);
    say("and `+name` still beats the environment", h, s,
        []str{ text.concat("+", A) }, work);

    // A variable naming something uninstalled is **not** quietly stepped over.
    // A second home where only `A` exists, with `A` as its default: the
    // variable still names `B`, so the honest answer is nothing at all. Falling
    // through to the default would run a different compiler than the one that
    // was asked for, and say nothing about having done so.
    const other = path.join(os.temp_dir(), text.concat("sharpie-tcenv2-", tag));
    try fs.mkdir_all(other);
    try install(other, A);
    const only_a = try settings.read(other);
    settings.set_default(only_a, A);
    print(text.concat("an environment naming nothing installed chooses nothing: ",
        yes(unchosen(other, only_a, []str{}, other))));

    try fs.remove_tree(h);
    try fs.remove_tree(other);
    return;
}

fn install(h: str, name: str) !void {
    const dir = home.toolchain(h, name);
    try fs.mkdir_all(path.join(dir, "lib"));
    try io.write_file(path.join(dir, "wsharp"), "not really a compiler\n");
    return;
}

fn say(label: str, h: str, s: settings.Settings, args: []str, cwd: str) void {
    const chosen = toolchain.choose(h, s, args, cwd) orelse {
        print(text.concat(text.concat(label, ": "), "nothing"));
        return;
    };
    print(text.concat(text.concat(label, ": "),
        text.concat(chosen.name, text.concat("\t", chosen.why))));
    return;
}

fn unchosen(h: str, s: settings.Settings, args: []str, cwd: str) bool {
    const got = toolchain.choose(h, s, args, cwd) orelse return true;
    return false;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
