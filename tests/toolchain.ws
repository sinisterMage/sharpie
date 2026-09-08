// The resolution ladder, rung by rung.
//
// Five things can decide which toolchain applies, and the order between them is
// the whole design. So the case builds a home with two toolchains in it and
// then walks *down* the ladder: assert the top rung wins, take it away, assert
// the next one does, and so on to the bottom. Anything that quietly reordered
// them would have to break one of these.
//
// The directories are empty except for a file standing in for `wsharp` --
// nothing here runs a compiler, it only decides which one it *would* run, and
// keeping those two apart is why `src/toolchain.ws` opens no sockets and
// unpacks nothing.
//
// expect: nothing chosen on an empty home: true
// expect: the default answers: 0.1.0-here	the default
// expect: an override beats the default: 0.2.0-here	a directory override
// expect: a deeper override beats a shallower one: 0.1.0-here	a directory override
// expect: a pin file beats an override: 0.2.0-here	wsharp-toolchain.toml
// expect: a table-spelled pin is read too: 0.1.0-here	wsharp-toolchain.toml
// expect: a pin is found from a subdirectory: 0.2.0-here	wsharp-toolchain.toml
// expect: `+name` beats everything: 0.2.0-here	the `+` argument
// expect: plus is read only in front: true
// expect: plus is stripped before forwarding: run	x.ws
// expect: a bare version finds this machine's triple: true
// expect: an uninstalled name resolves to nothing: true
// expect: installed lists both: 0.1.0-here 0.2.0-here
// expect: a program that is there: wsharp
// expect: a program that is not: true
// expect: why nothing, on an empty home: nothing is chosen; `sharpie install stable` gets a toolchain and makes it the default
// expect: why nothing, when a pin names what is not installed: `0.9.9` is not installed (wsharp-toolchain.toml); `sharpie toolchain list` says what is
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
const toolchain = @import("../src/toolchain.ws");

/// The triple is written into the names so the case does not depend on the
/// machine running it; `native` is checked separately, where it belongs.
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
    const h = path.join(os.temp_dir(), text.concat("sharpie-tc-", tag));
    const work = path.join(h, "work");
    const deep = path.join(work, "src");
    try fs.mkdir_all(deep);

    // Two toolchains, each with something that looks like a compiler in it.
    try install(h, A);
    try install(h, B);

    var s = try settings.read(h);
    print(text.concat("nothing chosen on an empty home: ",
        yes(unchosen(h, s, []str{}, work))));

    settings.set_default(s, A);
    say("the default answers", h, s, []str{}, work);

    // Rung four: a directory override.
    settings.set_override(s, work, B);
    say("an override beats the default", h, s, []str{}, work);
    settings.set_override(s, deep, A);
    say("a deeper override beats a shallower one", h, s, []str{}, deep);

    // Rung three: a file in the project.
    try io.write_file(path.join(work, toolchain.PIN_FILE),
        text.concat(text.concat("toolchain = \"", B), "\"\n"));
    say("a pin file beats an override", h, s, []str{}, work);

    // The other spelling of the same thing, which is what rustup writes.
    try io.write_file(path.join(work, toolchain.PIN_FILE),
        text.concat(text.concat("[toolchain]\nchannel = \"", A), "\"\n"));
    say("a table-spelled pin is read too", h, s, []str{}, work);

    // Found by walking up, which is what makes it the *project's* pin.
    try io.write_file(path.join(work, toolchain.PIN_FILE),
        text.concat(text.concat("toolchain = \"", B), "\"\n"));
    say("a pin is found from a subdirectory", h, s, []str{}, deep);

    // Rung two needs an environment variable, and there is no `setenv` here --
    // so it lives in `toolchain_env.ws`, which is the same arrangement with the
    // variable set. Setting it for *this* case would win over every rung below
    // and there would be no ladder left to walk.
    say("`+name` beats everything", h, s, []str{ text.concat("+", B) }, work);

    // `+` is positional: after the verb it belongs to the program, not to us.
    const late = []str{ "run", "+nope" };
    print(text.concat("plus is read only in front: ", yes(no_plus(late))));
    const stripped = toolchain.without_plus([]str{ text.concat("+", A), "run", "x.ws" });
    print(text.concat("plus is stripped before forwarding: ",
        text.join(stripped, "\t")));

    // A bare version means this machine's triple, which is how a user types one.
    try install(h, home.native("9.9.9"));
    const found = toolchain.located(h, s, "9.9.9", "asked for") orelse {
        print("a bare version finds this machine's triple: false");
        return;
    };
    print(text.concat("a bare version finds this machine's triple: ",
        yes(text.eq(found.name, home.native("9.9.9")))));

    print(text.concat("an uninstalled name resolves to nothing: ",
        yes(nothing_at(h, s, "4.5.6"))));

    // `installed` sees directories and nothing else.
    var names = toolchain.installed(h);
    print(text.concat("installed lists both: ", text.join(only_here(names), " ")));

    const dir = home.toolchain(h, A);
    const prog = toolchain.program(dir, "wsharp") orelse "none";
    print(text.concat("a program that is there: ", path.basename(prog)));
    print(text.concat("a program that is not: ", yes(no_program(dir, "cargo"))));

    // *Why* nothing was chosen, which is a different question from which
    // toolchain applies and has to be asked separately: by the time `choose`
    // has answered null it has thrown away the name it could not find.
    const empty = path.join(os.temp_dir(), text.concat("sharpie-tcnone-", tag));
    try fs.mkdir_all(empty);
    const none = try settings.read(empty);
    print(text.concat("why nothing, on an empty home: ",
        toolchain.why_nothing(none, []str{}, empty)));

    // A pin naming an uninstalled version, in a home whose *default* is
    // installed and fine. The message has to name `0.9.9` and the file that
    // asked for it. Naming the default instead is the bug this guards: it
    // reported a working toolchain as broken and sent the reader to the one
    // place the problem was not.
    try io.write_file(path.join(work, toolchain.PIN_FILE), "toolchain = \"0.9.9\"\n");
    print(text.concat("why nothing, when a pin names what is not installed: ",
        toolchain.why_nothing(s, []str{}, work)));

    try fs.remove_tree(empty);
    try fs.remove_tree(h);
    return;
}

/// A toolchain directory with something in it that a proxy would exec.
fn install(h: str, name: str) !void {
    const dir = home.toolchain(h, name);
    try fs.mkdir_all(path.join(dir, "lib"));
    try io.write_file(path.join(dir, "wsharp"), "not really a compiler\n");
    return;
}

/// Print which toolchain answers and which rung answered.
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

fn nothing_at(h: str, s: settings.Settings, name: str) bool {
    const got = toolchain.located(h, s, name, "asked for") orelse return true;
    return false;
}

fn no_plus(args: []str) bool {
    const got = toolchain.plus_toolchain(args) orelse return true;
    return false;
}

fn no_program(dir: str, name: str) bool {
    const got = toolchain.program(dir, name) orelse return true;
    return false;
}

/// The two named toolchains, so a machine-specific one does not appear.
fn only_here(names: []str) []str {
    var out = []str{};
    var i = 0;
    while (i < array.len(names)) : (i += 1) {
        if (text.eq(names[i], A) or text.eq(names[i], B)) {
            out = array.push(out, names[i]);
        }
    }
    return sorted(out);
}

/// `read_dir` answers in the filesystem's order, which is nobody's order.
fn sorted(names: []str) []str {
    var out = []str{};
    var i = 0;
    while (i < array.len(names)) : (i += 1) {
        var at = 0;
        while (at < array.len(out)) : (at += 1) {
            if (bigger(out[at], names[i])) { break; }
        }
        var next = []str{};
        var j = 0;
        while (j < at) : (j += 1) { next = array.push(next, out[j]); }
        next = array.push(next, names[i]);
        while (j < array.len(out)) : (j += 1) { next = array.push(next, out[j]); }
        out = next;
    }
    return out;
}

fn bigger(a: str, b: str) bool {
    var i = 0;
    while (i < text.len(a) and i < text.len(b)) : (i += 1) {
        if (text.byte_at(a, i) != text.byte_at(b, i)) {
            return text.byte_at(a, i) > text.byte_at(b, i);
        }
    }
    return text.len(a) > text.len(b);
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
