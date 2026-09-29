// gzip and tar, against archives GNU tar wrote.
//
// Two fixtures. `sample.tar.gz` is small and fully controlled, so the exact
// names, sizes, kinds and modes can be asserted -- including the one that this
// whole file exists for, that `runme` came out 0755 and `notes.txt` 0644.
// The other is shaped exactly like a released toolchain, with a 300 000-byte
// member of incompressible filler, which is the case that says the reader
// survives a multi-block member and a deflate stream long enough to use more
// than one Huffman block.
//
// No network and no filesystem writing: bytes in, entries out. That is the
// split `ingot/git.ws` made between its protocol and its transport, and it is
// what lets this run anywhere.
//
// expect: crc32 of "123456789": cbf43926
// expect: sample inflates to 10240 bytes
// expect: sample holds 5 members
// expect: toolchain/ dir 0755
// expect: toolchain/notes.txt file 0644 15 bytes
// expect: toolchain/lib/ dir 0755
// expect: toolchain/lib/libthing.a file 0644 14 bytes
// expect: toolchain/runme file 0755 21 bytes
// expect: runme reads: #!/bin/sh echo hello
// expect: strip_prefix drops the first component: lib/libthing.a
// expect: strip_prefix of a bare name is empty: true
// expect: a truncated member is refused: true
// expect: a corrupted crc is refused: true
// expect: not gzip at all is refused: true
// expect: release holds wsharp 0755 and ingot 0755
// expect: release holds lib/libwsharp_start.a 0644
// expect: the big member survives whole: true
const array = @import("std/array");
const bytes = @import("std/bytes");
const io = @import("std/io");
const targz = @import("../src/targz.ws");
const text = @import("std/str");

fn main() i64 {
    run() catch {
        print("something raised");
        return 1;
    };
    return 0;
}

fn run() !void {
    // The check value every CRC-32 implementation is measured against.
    const digits = bytes.of("123456789");
    print(text.concat("crc32 of \"123456789\": ", hex32(targz.crc32(digits, 0, 9))));

    const gz = bytes.of(try io.read_file("tests/fixtures/sample.tar.gz"));
    const tar = try targz.gunzip(gz);
    print(text.concat(text.concat("sample inflates to ", text.from_int(array.len(tar))), " bytes"));

    const entries = try targz.untar(tar);
    print(text.concat(text.concat("sample holds ", text.from_int(array.len(entries))), " members"));

    var i = 0;
    while (i < array.len(entries)) : (i += 1) {
        const e = entries[i];
        var line = text.concat(e.name, " ");
        if (e.kind == targz.DIRECTORY) {
            line = text.concat(line, "dir ");
            line = text.concat(line, octal(e.mode));
        } else {
            line = text.concat(line, "file ");
            line = text.concat(line, octal(e.mode));
            line = text.concat(line, " ");
            line = text.concat(line, text.from_int(array.len(e.data)));
            line = text.concat(line, " bytes");
        }
        print(line);
    }

    // The contents come back whole, not just the sizes.
    print(text.concat("runme reads: ", oneline(find(entries, "toolchain/runme"))));

    print(text.concat("strip_prefix drops the first component: ",
        targz.strip_prefix("toolchain/lib/libthing.a")));
    print(text.concat("strip_prefix of a bare name is empty: ",
        show(text.len(targz.strip_prefix("toolchain")) == 0)));

    // Three ways of being wrong, each of which a half-finished download can
    // actually produce.
    print(text.concat("a truncated member is refused: ",
        show(refused(bytes.slice(gz, 0, array.len(gz) - 3)))));
    print(text.concat("a corrupted crc is refused: ", show(refused(flipped(gz)))));
    print(text.concat("not gzip at all is refused: ",
        show(refused(bytes.of("<!DOCTYPE html><html>404</html>")))));

    // An archive shaped exactly like a release, holding a member of 300 000
    // incompressible bytes: many tar blocks, and a deflate stream long enough
    // to change Huffman tables part way through. Named by what an installer
    // would name -- the path *inside* the enclosing directory.
    const rel = bytes.of(try io.read_file("tests/fixtures/release.tar.gz"));
    const members = try targz.untar(try targz.gunzip(rel));
    print(text.concat(text.concat("release holds wsharp ", mode_of(members, "wsharp")),
        text.concat(" and ingot ", mode_of(members, "ingot"))));
    print(text.concat("release holds lib/libwsharp_start.a ",
        mode_of(members, "lib/libwsharp_start.a")));
    print(text.concat("the big member survives whole: ",
        show(array.len(find(members, "wsharp-9.9.9-x86_64-unknown-linux-gnu/lib/libwsharp_start.a")) == 300000)));
    return;
}

/// The mode of a member named by its path *inside* the enclosing directory,
/// which is how an installer names one.
fn mode_of(entries: []targz.Entry, want: str) str {
    var i = 0;
    while (i < array.len(entries)) : (i += 1) {
        if (text.eq(targz.strip_prefix(entries[i].name), want)) {
            return octal(entries[i].mode);
        }
    }
    return "missing";
}

fn find(entries: []targz.Entry, want: str) []u8 {
    var i = 0;
    while (i < array.len(entries)) : (i += 1) {
        if (text.eq(entries[i].name, want)) { return entries[i].data; }
    }
    return []u8{};
}

/// Whether `gunzip` refused, rather than what it raised.
fn refused(b: []u8) bool {
    const out = targz.gunzip(b) catch { return true; };
    return false;
}

/// The same bytes with one byte of the compressed body altered, which the
/// trailer's CRC is there to notice.
fn flipped(b: []u8) []u8 {
    const copy = bytes.slice(b, 0, array.len(b));
    copy[20] = copy[20] ^ 255;
    return copy;
}

/// A file's contents on one line, so a shebang can be printed.
fn oneline(b: []u8) str {
    var out = "";
    var i = 0;
    while (i < array.len(b)) : (i += 1) {
        if (b[i] == 10) {
            if (i + 1 < array.len(b)) { out = text.concat(out, " "); }
        } else {
            out = text.concat(out, bytes.slice_str(b, i, i + 1));
        }
    }
    return out;
}

/// A mode as tar wrote it, so an expectation reads like `chmod` does.
fn octal(v: i64) str {
    if (v == 0) { return "0"; }
    var out = "";
    var n = v;
    while (n > 0) {
        out = text.concat(text.from_int(n % 8), out);
        n = n / 8;
    }
    return text.concat("0", out);
}

fn hex32(v: u32) str {
    return bytes.to_hex(be32(v));
}

fn be32(v: u32) []u8 {
    const b = bytes.new(4);
    bytes.put_be32(b, 0, v);
    return b;
}

fn show(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
