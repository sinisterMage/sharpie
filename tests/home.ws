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
