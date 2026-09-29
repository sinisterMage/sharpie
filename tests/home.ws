// The store's layout, and taking a toolchain name apart.
//
// `SHARPIE_HOME` is set by this case, which is the whole reason it exists as an
// environment variable: a case that read a real installation would depend on
// whatever the machine running it happens to have installed.
//
// The splitting cases are the ones with teeth. A version can contain a hyphen
// -- `0.2.0-rc1` is one semver calls a pre-release -- so a name cannot be cut
// at its first `-`, and the obvious implementation gets
// `0.2.0-rc1-x86_64-unknown-linux-gnu` wrong in a way that only shows up on a
// release candidate.
//
// env: SHARPIE_HOME=/tmp/sharpie-case
//
// expect: root honours SHARPIE_HOME: /tmp/sharpie-case
// expect: bin: /tmp/sharpie-case/bin
// expect: toolchains: /tmp/sharpie-case/toolchains
// expect: one toolchain: /tmp/sharpie-case/toolchains/0.1.1-x86_64-unknown-linux-gnu
// expect: downloads: /tmp/sharpie-case/downloads
// expect: scratch: /tmp/sharpie-case/tmp
// expect: settings: /tmp/sharpie-case/settings.toml
// expect: spell: 0.1.1-aarch64-apple-darwin
// expect: native ends with this machine's triple: true
// expect: version of a plain name: 0.1.1
// expect: triple of a plain name: x86_64-unknown-linux-gnu
// expect: version of a prerelease name: 0.2.0-rc1
// expect: triple of a prerelease name: aarch64-apple-darwin
// expect: version of a windows name: 1.0.0
// expect: triple of a windows name: x86_64-pc-windows-msvc
// expect: a bare version is all version: 0.1.1
// expect: a bare version has no triple: true
// expect: a channel name is left alone: stable
// expect: names: stable latest 0.2.3 0.2.0-rc1 1.0.0+build.5 0.2.3-x86_64-unknown-linux-gnu 0.2.0-rc1-aarch64-apple-darwin 1.0.0-x86_64-pc-windows-msvc dev my_checkout W2
// expect: refused: empty
// expect: refused: .
// expect: refused: ..
// expect: refused: .tools, which is hidden
// expect: refused: ../x
// expect: refused: ..\x
// expect: refused: a/b
// expect: refused: a\b
// expect: refused: /abs
// expect: refused: \abs
// expect: refused: C:
// expect: refused: C:/x
// expect: refused: c:x
// expect: refused: 1..2
// expect: refused: -rf
// expect: refused: +stable
// expect: refused: a space
// expect: refused: a newline
// expect: refused: a tab
// expect: refused: DEL
// expect: refused: a NUL
// expect: refused: non-ASCII
const home = @import("../src/home.ws");
const os = @import("std/os");
const text = @import("std/str");

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const h = try home.root();
    show("root honours SHARPIE_HOME", h);
    show("bin", home.bin(h));
    show("toolchains", home.toolchains(h));
    show("one toolchain", home.toolchain(h, "0.1.1-x86_64-unknown-linux-gnu"));
    show("downloads", home.downloads(h));
    show("scratch", home.scratch(h));
    show("settings", home.settings(h));

    show("spell", home.spell("0.1.1", "aarch64-apple-darwin"));
    // The value differs per machine, so only the shape can be asserted.
    const mine = home.native("0.1.1");
    print(text.concat("native ends with this machine's triple: ",
        yes(text.eq(home.triple_of(mine), os.target()))));

    show("version of a plain name", home.version_of("0.1.1-x86_64-unknown-linux-gnu"));
    show("triple of a plain name", home.triple_of("0.1.1-x86_64-unknown-linux-gnu"));

    // The one the obvious implementation gets wrong.
    show("version of a prerelease name", home.version_of("0.2.0-rc1-aarch64-apple-darwin"));
    show("triple of a prerelease name", home.triple_of("0.2.0-rc1-aarch64-apple-darwin"));

    show("version of a windows name", home.version_of("1.0.0-x86_64-pc-windows-msvc"));
    show("triple of a windows name", home.triple_of("1.0.0-x86_64-pc-windows-msvc"));

    // A name with no triple in it is all version, which is what a user typed.
    show("a bare version is all version", home.version_of("0.1.1"));
    print(text.concat("a bare version has no triple: ",
        yes(text.len(home.triple_of("0.1.1")) == 0)));
    show("a channel name is left alone", home.version_of("stable"));

    // What a toolchain can be called. Every spelling `install` writes and a
    // user types is in the first list, so tightening the rule cannot quietly
    // refuse a real toolchain; the second list is every way a name could be a
    // path, or could be printed as something other than itself.
    const good = []str{ "stable", "latest", "0.2.3", "0.2.0-rc1", "1.0.0+build.5",
        "0.2.3-x86_64-unknown-linux-gnu", "0.2.0-rc1-aarch64-apple-darwin",
        "1.0.0-x86_64-pc-windows-msvc", "dev", "my_checkout", "W2" };
    var named = "";
    var i = 0;
    while (i < 11) : (i += 1) {
        if (home.is_name(good[i])) { named = text.concat(named, text.concat(" ", good[i])); }
    }
    print(text.concat("names:", named));

    refused("empty", "");
    refused(".", ".");
    refused("..", "..");
    refused(".tools, which is hidden", ".tools");
    refused("../x", "../x");
    refused("..\\x", "..\\x");
    refused("a/b", "a/b");
    refused("a\\b", "a\\b");
    refused("/abs", "/abs");
    refused("\\abs", "\\abs");
    refused("C:", "C:");
    refused("C:/x", "C:/x");
    refused("c:x", "c:x");
    refused("1..2", "1..2");
    refused("-rf", "-rf");
    refused("+stable", "+stable");
    refused("a space", "0.2.3 x");
    refused("a newline", "0.2.3\n");
    refused("a tab", "0.2.3\tx");
    refused("DEL", text.concat("0.2.3", text.from_byte(127)));
    refused("a NUL", "0.2.3\0");
    refused("non-ASCII", "0.2.3-é");
    return;
}

fn refused(label: str, name: str) void {
    if (home.is_name(name)) {
        print(text.concat("ACCEPTED: ", label));
        return;
    }
    print(text.concat("refused: ", label));
    return;
}

fn show(label: str, got: str) void {
    print(text.concat(text.concat(label, ": "), got));
    return;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
