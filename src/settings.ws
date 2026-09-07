// `settings.toml`: the default toolchain, the per-directory overrides, and any
// directory that has been linked in as a toolchain of its own.
//
// **The parsed table is kept, not copied out of.** Reading into a struct and
// writing a fresh file back would silently drop anything this version does not
// know about -- so a newer sharpie's settings would be quietly truncated by an
// older one, which is the sort of thing nobody notices until a rollback. Every
// accessor here reads and writes the table in place, and `save` renders what it
// was given.
//
// Overrides are an **array of tables** rather than keys, and that is not a
// style choice. A filesystem path as a TOML key would need quoting and would
// make `[overrides]` a table whose keys are absolute paths -- readable, but
// `toml.Table` is a `List` of keys with a linear scan rather than a map, so it
// buys nothing, and a path containing a `.` would be read back as a nested
// table. `[[override]]` with a `path` field has neither problem.
const array = @import("std/array");
const fs = @import("std/fs");
const home = @import("./home.ws");
const io = @import("std/io");
const list = @import("std/list");
const path = @import("std/path");
const text = @import("std/str");
const toml = @import("std/toml");

/// What sharpie has been told, as a document it can write back out.
pub const Settings = struct { root: toml.Table };

/// One directory and the toolchain it pins.
pub const Override = struct { dir: str, toolchain: str };

/// The schema this file is written in.
///
/// Written on save and never read back on purpose -- it is there so that a
/// future version *can* branch on it, which is only possible if today's version
/// writes it. Nothing checks it yet, because there is nothing to be compatible
/// with.
pub const VERSION = "1";

/// Read `settings.toml`, or start an empty one.
///
/// A file that is not there is not an error: it is a sharpie that has not been
/// told anything yet, which is the state every installation starts in. A file
/// that is there and is *malformed* is an error, because guessing at it would
/// discard whatever it says.
pub fn read(h: str) !{BadFormat}Settings {
    const at = home.settings(h);
    if (!io.exists(at)) { return Settings{ .root = toml.table() }; }
    const src = io.read_file(at) catch { return error.BadFormat; };
    const doc = toml.parse(src);
    if (!doc.ok) { return error.BadFormat; }
    return Settings{ .root = doc.root };
}

/// Write `settings.toml`, creating the directory above it if it is new.
///
/// Written through a temporary file and `rename`d, so an interrupted save
/// leaves the previous settings rather than half of the new ones. Same reason
/// a toolchain is unpacked into `tmp` and renamed.
pub fn save(h: str, s: Settings) !void {
    toml.set(s.root, "version", toml.of_str(VERSION));
    try fs.mkdir_all(h);
    const at = home.settings(h);
    const staging = text.concat(at, ".new");
    try io.write_file(staging, toml.write(s.root));
    try fs.rename(staging, at);
    return;
}

// ---------------------------------------------------------------------------
// The default
// ---------------------------------------------------------------------------

/// The toolchain used when nothing else says otherwise, or null.
pub fn default_toolchain(s: Settings) ?str {
    return string_at(s.root, "default");
}

pub fn set_default(s: Settings, name: str) void {
    toml.set(s.root, "default", toml.of_str(name));
    return;
}

// ---------------------------------------------------------------------------
// Directory overrides
// ---------------------------------------------------------------------------

/// Every override, in the order written.
///
/// A row missing either field is skipped rather than raising: this file is
/// edited by hand, and a half-written entry should cost that entry rather than
/// every entry.
pub fn overrides(s: Settings) []Override {
    var out = []Override{};
    const rows = tables_at(s.root, "override");
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = as_table(list.get(rows, i));
        const dir = string_at(row, "path") orelse "";
        const name = string_at(row, "toolchain") orelse "";
        if (text.len(dir) > 0 and text.len(name) > 0) {
            out = array.push(out, Override{ .dir = dir, .toolchain = name });
        }
    }
    return out;
}

/// The toolchain pinned for `dir`, or for the nearest directory above it.
///
/// **The longest match wins**, so an override on a subdirectory beats one on
/// its parent -- which is the only ordering that lets a project inside an
/// overridden tree pin something else.
///
/// A match is on whole components: `/a/b` covers `/a/b` and `/a/b/c` and does
/// *not* cover `/a/bc`. Comparing strings without that test is the bug this
/// note exists to prevent.
pub fn override_for(s: Settings, dir: str) ?str {
    const want = path.normalise(dir);
    const rows = overrides(s);
    var best = "";
    var found = "";
    var i = 0;
    while (i < array.len(rows)) : (i += 1) {
        const at = path.normalise(rows[i].dir);
        if (!covers(at, want)) { continue; }
        if (text.len(at) < text.len(best)) { continue; }
        best = at;
        found = rows[i].toolchain;
    }
    if (text.len(found) == 0) { return null; }
    return found;
}

/// Whether `dir` is `under`, or is `under` itself.
fn covers(under: str, dir: str) bool {
    if (text.eq(under, dir)) { return true; }
    // The separator is what makes this a component test rather than a prefix
    // test. A root of `/` already ends in one.
    var stem = under;
    if (!text.eq(under, "/")) { stem = text.concat(under, "/"); }
    return text.starts_with(dir, stem);
}

/// Pin `dir` to `name`, replacing any override already on that directory.
pub fn set_override(s: Settings, dir: str, name: str) void {
    const want = path.normalise(dir);
    const rows = tables_at(s.root, "override");
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = as_table(list.get(rows, i));
        const at = string_at(row, "path") orelse "";
        if (text.eq(path.normalise(at), want)) {
            toml.set(row, "toolchain", toml.of_str(name));
            return;
        }
    }
    const row = toml.table();
    toml.set(row, "path", toml.of_str(want));
    toml.set(row, "toolchain", toml.of_str(name));
    list.push(rows, toml.of_table(row));
    put_tables(s.root, "override", rows);
    return;
}

/// Drop the override on `dir`. Answers whether there was one.
pub fn unset_override(s: Settings, dir: str) bool {
    const want = path.normalise(dir);
    const rows = tables_at(s.root, "override");
    var kept: list.List[toml.Value] = list.new();
    var dropped = false;
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = list.get(rows, i);
        const named = string_at(as_table(row), "path") orelse "";
        if (text.eq(path.normalise(named), want)) {
            dropped = true;
        } else {
            list.push(kept, row);
        }
    }
    put_tables(s.root, "override", kept);
    return dropped;
}

// ---------------------------------------------------------------------------
// Linked directories
// ---------------------------------------------------------------------------

/// The directory a linked toolchain name points at, or null.
///
/// A link is how a compiler *checkout* becomes a toolchain: nothing is copied,
/// and `target/release` already holds `wsharp` beside its runtime archive,
/// which is the fourth place `wsharp` looks. So a link costs a line in this
/// file and works with no further arrangement.
pub fn link_dir(s: Settings, name: str) ?str {
    const rows = tables_at(s.root, "link");
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = as_table(list.get(rows, i));
        const named = string_at(row, "name") orelse "";
        if (text.eq(named, name)) { return string_at(row, "dir"); }
    }
    return null;
}

/// Every linked name, in the order written.
pub fn links(s: Settings) []Override {
    var out = []Override{};
    const rows = tables_at(s.root, "link");
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = as_table(list.get(rows, i));
        const name = string_at(row, "name") orelse "";
        const dir = string_at(row, "dir") orelse "";
        // `dir` here is the directory and `toolchain` the name, which is the
        // same pair the other way round; the struct is shared rather than
        // duplicated for two fields.
        if (text.len(name) > 0 and text.len(dir) > 0) {
            out = array.push(out, Override{ .dir = dir, .toolchain = name });
        }
    }
    return out;
}

pub fn set_link(s: Settings, name: str, dir: str) void {
    const rows = tables_at(s.root, "link");
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = as_table(list.get(rows, i));
        const named = string_at(row, "name") orelse "";
        if (text.eq(named, name)) {
            toml.set(row, "dir", toml.of_str(dir));
            return;
        }
    }
    const row = toml.table();
    toml.set(row, "name", toml.of_str(name));
    toml.set(row, "dir", toml.of_str(dir));
    list.push(rows, toml.of_table(row));
    put_tables(s.root, "link", rows);
    return;
}

/// Drop a linked name. Answers whether there was one.
pub fn unset_link(s: Settings, name: str) bool {
    const rows = tables_at(s.root, "link");
    var kept: list.List[toml.Value] = list.new();
    var dropped = false;
    var i = 0;
    while (i < list.len(rows)) : (i += 1) {
        const row = list.get(rows, i);
        const named = string_at(as_table(row), "name") orelse "";
        if (text.eq(named, name)) {
            dropped = true;
        } else {
            list.push(kept, row);
        }
    }
    put_tables(s.root, "link", kept);
    return dropped;
}

// ---------------------------------------------------------------------------
// Reading a document that may be anything
// ---------------------------------------------------------------------------
//
// Everything below treats a wrong type as an absent value rather than raising.
// This file is edited by hand -- that is the point of it being TOML -- so a
// key holding the wrong kind of thing is a typo, and the useful answer to a
// typo is the same as to an omission: sharpie carries on with its default and
// the user can see what they wrote.

/// A string-valued key, or null when it is missing or is not a string.
fn string_at(t: toml.Table, key: str) ?str {
    const v = toml.get(t, key) orelse return null;
    const s = toml.as_str(v) catch { return null; };
    return s;
}

/// The array of tables at `key`, or a new empty one.
///
/// Answers with a list that can be pushed to and then handed back to
/// [`put_tables`], so a caller adding a row does not have to know whether the
/// key was there.
fn tables_at(t: toml.Table, key: str) list.List[toml.Value] {
    var empty: list.List[toml.Value] = list.new();
    const v = toml.get(t, key) orelse return empty;
    const items = toml.as_array(v) catch { return empty; };
    return items;
}

/// Store an array of tables, as `[[key]]` rather than as an inline array.
///
/// `literal = false` is what makes `toml.write` give each member its own
/// `[[header]]` -- an array set `literal` is written inline, and a settings
/// file full of `override = [{path = "...", ...}]` would be legal TOML and
/// horrible to edit by hand, which is the only reason this file is TOML.
///
/// An empty array writes nothing at all, because the writer emits one header
/// per member and there are none. So dropping the last override leaves no stub
/// behind, without this needing a way to remove a key -- which `std/toml` does
/// not have.
fn put_tables(t: toml.Table, key: str, rows: list.List[toml.Value]) void {
    toml.set(t, key, toml.of_array(rows, false));
    return;
}

/// A value that ought to be a table, as one.
fn as_table(v: toml.Value) toml.Table {
    return toml.as_table(v) catch toml.table();
}
