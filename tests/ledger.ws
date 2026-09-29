// The ledger of digests, written and read back.
//
// First seen wins: `remember` is called on every install, and a later call for
// the same archive must not overwrite what the first one recorded -- the whole
// point is to be able to say "this is not what it was". And one line per
// archive, so a second archive is added beside the first rather than replacing
// the file.
//
// expect: a new home remembers nothing: true
// expect: remembered after writing: aaaa
// expect: a second digest for the same archive does not replace the first: aaaa
// expect: another archive is kept beside it: bbbb
// expect: and the first is still there: aaaa
// expect: one line each: 2
// expect: an archive whose name is a prefix of another's is its own: true
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fs = @import("std/fs");
const home = @import("../src/home.ws");
const io = @import("std/io");
const ledger = @import("../src/ledger.ws");
const os = @import("std/os");
const path = @import("std/path");
const text = @import("std/str");

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-ledger-", tag));
    try fs.mkdir_all(h);

    const a = "wsharp-0.2.3-x86_64-unknown-linux-gnu.tar.gz";
    const b = "wsharp-0.2.4-x86_64-unknown-linux-gnu.tar.gz";
    print(text.concat("a new home remembers nothing: ", yes(absent(ledger.remembered(h, a)))));

    try ledger.remember(h, a, "aaaa");
    print(text.concat("remembered after writing: ", ledger.remembered(h, a) orelse "none"));

    try ledger.remember(h, a, "cccc");
    print(text.concat("a second digest for the same archive does not replace the first: ",
        ledger.remembered(h, a) orelse "none"));

    try ledger.remember(h, b, "bbbb");
    print(text.concat("another archive is kept beside it: ", ledger.remembered(h, b) orelse "none"));
    print(text.concat("and the first is still there: ", ledger.remembered(h, a) orelse "none"));

    const all = try io.read_file(home.ledger(h));
    var lines = 0;
    var i = 0;
    while (i < text.len(all)) : (i += 1) {
        if (text.byte_at(all, i) == 10) { lines += 1; }
    }
    print(text.concat("one line each: ", text.from_int(lines)));

    // `...0.2.3-...` must not answer for `...0.2.3-...tar.gz.sig`: the name is
    // compared whole, up to the tab.
    print(text.concat("an archive whose name is a prefix of another's is its own: ",
        yes(absent(ledger.remembered(h, text.concat(a, ".sig"))))));
    try fs.remove_tree(h);
    return;
}

fn absent(s: ?str) bool {
    const v = s orelse return true;
    return false;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
