// What each release archive hashed to the first time this home installed it.
//
// **A published release never changes, and this is how sharpie holds it to
// that.** The digest beside an archive says the archive arrived intact; it
// cannot say the archive is the one that was there last week, because whoever
// can replace the one can replace the other. W#'s release workflow could once
// be re-run for a tag that was already public, rebuilding every archive -- not
// bit for bit -- and publishing a new digest beside each, and a toolchain
// removed and installed again would then have been a different compiler under
// the same version with nothing anywhere saying so. So the first digest seen
// for an archive is written down here, and a later install of the same archive
// that is offered a different one refuses. It is trust on first use, which is
// less than a signature and much more than nothing; signing is 1.1's.
//
// One line per archive: its name, a tab, its SHA-256 in lower-case hex. A name
// is `release.archive_name`'s spelling, which carries the version and the
// triple, so two platforms never share a line.
const array = @import("std/array");
const fs = @import("std/fs");
const home = @import("./home.ws");
const io = @import("std/io");
const text = @import("std/str");

/// The digest this home first saw `name` hash to, or null if it has not.
///
/// A ledger that cannot be read is treated as empty rather than as a failure:
/// it only ever makes an install *stricter*, so losing it loses protection for
/// what was installed before and blocks nothing.
pub fn remembered(h: str, name: str) ?str {
    const all = io.read_file(home.ledger(h)) catch return null;
    for (text.split(all, "\n")) |line| {
        const tab = text.find(line, "\t");
        if (tab < 0) { continue; }
        if (text.eq(text.substr(line, 0, tab), name)) {
            return text.substr(line, tab + 1, text.len(line));
        }
    }
    return null;
}

/// Write down that `name` hashed to `digest`, unless it already is.
///
/// Staged and renamed, as `settings.save` is, so an interrupted write leaves
/// the ledger as it was rather than half of it.
pub fn remember(h: str, name: str, digest: str) !void {
    if (remembered(h, name)) |known| { return; }
    const at = home.ledger(h);
    const before = io.read_file(at) catch "";
    var all = before;
    if (text.len(all) > 0 and text.byte_at(all, text.len(all) - 1) != 10) {
        all = text.concat(all, "\n");
    }
    all = text.concat(all, text.concat(text.concat(name, "\t"), text.concat(digest, "\n")));
    try fs.mkdir_all(h);
    const staging = text.concat(at, ".new");
    try io.write_file(staging, all);
    try fs.rename(staging, at);
    return;
}
