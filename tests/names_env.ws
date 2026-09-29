// `SHARPIE_TOOLCHAIN` naming a path, which is rung two of `names.ws`.
//
// A case of its own for `toolchain_env.ws`'s reason: there is no `setenv`, so
// the variable is set before the program starts, and set for `names.ws` it
// would win over every rung that case walks.
//
// The path is relative, and that is deliberate rather than the easy half: an
// absolute one is what MSYS rewrites on its way into a native program, so on
// the Windows runner the case would be testing the shell. `names.ws` has the
// absolute spelling at the rungs no shell touches.
//
// env: SHARPIE_TOOLCHAIN=../escaped
//
// expect: the environment naming a path chooses nothing: true
// expect: it says: `../escaped` is not a toolchain name (SHARPIE_TOOLCHAIN); a toolchain is named by a version, a channel or `sharpie toolchain link`, and never by a path
// expect: and `+name` still beats it: 0.1.0-here	the `+` argument
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

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-namesenv-", tag));
    const work = path.join(h, "work");
    try fs.mkdir_all(work);
    try install_at(home.toolchain(h, A));
    // What `toolchains/../escaped` reaches, holding something a proxy would run.
    try install_at(path.join(h, "escaped"));

    // Installed and the default, so that stepping over the variable would find
    // something to run -- which is exactly what must not happen.
    const s = try settings.read(h);
    settings.set_default(s, A);

    print(text.concat("the environment naming a path chooses nothing: ",
        yes(unchosen(h, s, []str{}, work))));
    print(text.concat("it says: ", toolchain.why_nothing(s, []str{}, work)));

    const plus = []str{ text.concat("+", A) };
    const chosen = toolchain.choose(h, s, plus, work) orelse {
        print("and `+name` still beats it: nothing");
        return;
    };
    print(text.concat("and `+name` still beats it: ",
        text.concat(chosen.name, text.concat("\t", chosen.why))));

    try fs.remove_tree(h);
    return;
}

fn install_at(dir: str) !void {
    try fs.mkdir_all(path.join(dir, "lib"));
    try io.write_file(path.join(dir, "wsharp"), "not really a compiler\n");
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
