// A channel at a rung of the ladder names the newest toolchain installed on it.
//
// `stable` and `latest` are toolchain names, and a pin file may spell one as
// `[toolchain] channel = "stable"` -- but nothing resolved them anywhere except
// `install` and `update`, so `wsharp +stable`, `SHARPIE_TOOLCHAIN=latest` and
// such a pin all failed with "`stable` is not installed". A rung now answers a
// channel from what is installed, for this machine's triple, without asking
// the network: `stable` the newest that is not a pre-release, `latest` the
// newest of all. A toolchain for another triple, and a damaged one, never count.
//
// expect: stable finds the newest release: 0.3.0
// expect: and says why: asked for, the newest installed stable
// expect: latest finds the newest of all: 0.4.0-rc1
// expect: a damaged newer one is passed over: 0.3.0
// expect: another triple's never counts: true
// expect: a pin naming the channel as a table is followed: 0.3.0
// expect: an empty home has no stable: true
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

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-channels-", tag));
    const here = os.target();
    try intact_at(h, home.spell("0.2.3", here));
    try intact_at(h, home.spell("0.3.0", here));
    try intact_at(h, home.spell("0.4.0-rc1", here));
    // Newer than anything above, and for somebody else's machine.
    const elsewhere = home.spell("9.9.9", other_triple(here));
    try intact_at(h, elsewhere);

    const s = try settings.read(path.join(h, "unwritten"));
    const stable = toolchain.located(h, s, "stable", "asked for") orelse {
        print("stable finds the newest release: nothing");
        return;
    };
    print(text.concat("stable finds the newest release: ", home.version_of(stable.name)));
    print(text.concat("and says why: ", stable.why));
    const latest = toolchain.located(h, s, "latest", "asked for") orelse {
        print("latest finds the newest of all: nothing");
        return;
    };
    print(text.concat("latest finds the newest of all: ", home.version_of(latest.name)));

    // 0.5.0 with its `wsharp` gone is damaged, not newest.
    const broken = home.spell("0.5.0", here);
    try fs.mkdir_all(home.toolchain(h, broken));
    const still = toolchain.located(h, s, "stable", "asked for") orelse {
        print("a damaged newer one is passed over: nothing");
        return;
    };
    print(text.concat("a damaged newer one is passed over: ", home.version_of(still.name)));
    print(text.concat("another triple's never counts: ", yes(!text.eq(latest.name, elsewhere))));

    const repo = path.join(h, "repo");
    try fs.mkdir_all(repo);
    try io.write_file(path.join(repo, toolchain.PIN_FILE), "[toolchain]\nchannel = \"stable\"\n");
    const pinned = toolchain.choose(h, s, []str{}, repo) orelse {
        print("a pin naming the channel as a table is followed: nothing");
        return;
    };
    print(text.concat("a pin naming the channel as a table is followed: ", home.version_of(pinned.name)));

    const empty = path.join(h, "empty-home");
    try fs.mkdir_all(empty);
    print(text.concat("an empty home has no stable: ", yes(nothing(empty, s, "stable"))));

    try fs.remove_tree(h);
    return;
}

/// A toolchain directory `install` would call intact: a runnable `wsharp` and
/// `ingot` in it.
fn intact_at(h: str, name: str) !void {
    const dir = home.toolchain(h, name);
    try fs.mkdir_all(dir);
    for ([]str{ "wsharp", "ingot" }) |program| {
        const at = path.join(dir, program);
        try io.write_file(at, "not really a compiler\n");
        try fs.chmod(at, 0o755);
    }
    return;
}

fn other_triple(here: str) str {
    if (text.eq(here, "x86_64-unknown-linux-gnu")) { return "aarch64-apple-darwin"; }
    return "x86_64-unknown-linux-gnu";
}

fn nothing(h: str, s: settings.Settings, name: str) bool {
    const got = toolchain.located(h, s, name, "asked for") orelse return true;
    return false;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
