// Unpacking an archive into a toolchain, and what that has to get right.
//
// The whole download half is absent on purpose: `unpack` takes the archive's
// *bytes*, so everything from there down runs against a fixture with no
// network. What is checked is the part that would be hardest to notice going
// wrong -- that `wsharp` comes out runnable and `README.md` does not.
//
// `fs.is_executable` is what makes that assertable at all. Windows has no
// permission bits, so there it answers "is it there", and this case is written
// to be true on both: a file that came out 0755 is runnable everywhere, and
// nothing asserts that a 0644 file is *not*.
//
// expect: installed: true
// Byte order, so `README.md` comes before `ingot`: `R` is 82 and `i` is 105.
// expect: layout: README.md ingot lib wsharp
// expect: wsharp is runnable: true
// expect: ingot is runnable: true
// expect: the archive is under lib: true
// expect: the enclosing directory was stripped: true
// expect: contents survived: 300000
// expect: installing again is a no-op that succeeds: true
// expect: nothing is left in tmp: true
// expect: a corrupt archive fails and leaves nothing: true
// expect: `..` in a member is refused: true
// expect: an absolute member is refused: true
// expect: an ordinary member is allowed: true
// expect: remove takes it away: true
// expect: removing what is not there fails: true
const array = @import("std/array");
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fault = @import("ingot/fault");
const fs = @import("std/fs");
const home = @import("../src/home.ws");
const install = @import("../src/install.ws");
const io = @import("std/io");
const os = @import("std/os");
const path = @import("std/path");
const text = @import("std/str");

const NAME = "9.9.9-x86_64-unknown-linux-gnu";

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    const tag = bytes.to_hex(try crypto.random(8));
    const h = path.join(os.temp_dir(), text.concat("sharpie-install-", tag));
    try fs.mkdir_all(h);

    // The fixture is shaped exactly like a release: one enclosing directory,
    // `wsharp` and `ingot` at 0755, everything else at 0644.
    const archive = try io.read_file("tests/fixtures/release.tar.gz");

    const f = fault.none();
    print(text.concat("installed: ", yes(install.unpack(f, h, NAME, archive))));

    const at = home.toolchain(h, NAME);
    print(text.concat("layout: ", text.join(sorted(try fs.read_dir(at)), " ")));

    // The reason `fs.chmod` was added to the language at all.
    print(text.concat("wsharp is runnable: ", yes(fs.is_executable(path.join(at, "wsharp")))));
    print(text.concat("ingot is runnable: ", yes(fs.is_executable(path.join(at, "ingot")))));
    print(text.concat("the archive is under lib: ",
        yes(io.exists(path.join(at, "lib/libwsharp_start.a")))));

    // `wsharp-9.9.9-.../wsharp` became `wsharp`, not a nested directory.
    print(text.concat("the enclosing directory was stripped: ",
        yes(!fs.is_dir(path.join(at, "wsharp-9.9.9-x86_64-unknown-linux-gnu")))));
    print(text.concat("contents survived: ",
        text.from_int(try fs.size(path.join(at, "lib/libwsharp_start.a")))));

    // Installed already is success and does nothing, which is what makes
    // `install` safe to run twice and a retry after a failed download cheap.
    print(text.concat("installing again is a no-op that succeeds: ",
        yes(install.unpack(f, h, NAME, archive))));

    // Nothing assembled is left lying about.
    print(text.concat("nothing is left in tmp: ", yes(empty(home.scratch(h)))));

    // A failed unpack must not leave a partial toolchain that `toolchain list`
    // would report and a proxy would try to run.
    const g = fault.none();
    const broke = install.unpack(g, h, "0.0.0-broken", "not a gzip stream at all");
    print(text.concat("a corrupt archive fails and leaves nothing: ",
        yes(!broke and !fs.is_dir(home.toolchain(h, "0.0.0-broken")) and empty(home.scratch(h)))));

    // An archive comes off the network, and `../../.bashrc` is the oldest
    // trick there is.
    print(text.concat("`..` in a member is refused: ", yes(!install.safe("../outside"))));
    print(text.concat("an absolute member is refused: ", yes(!install.safe("/etc/passwd"))));
    print(text.concat("an ordinary member is allowed: ", yes(install.safe("lib/libwsharp_start.a"))));

    const r = fault.none();
    print(text.concat("remove takes it away: ",
        yes(install.remove(r, h, NAME) and !fs.is_dir(at))));
    const missing = fault.none();
    print(text.concat("removing what is not there fails: ",
        yes(!install.remove(missing, h, "0.0.0-never"))));

    try fs.remove_tree(h);
    return;
}

/// Whether a directory holds nothing, treating "not there" as empty.
fn empty(dir: str) bool {
    const names = fs.read_dir(dir) catch { return true; };
    return array.len(names) == 0;
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
