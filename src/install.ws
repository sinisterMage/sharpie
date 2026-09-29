// Putting an unpacked toolchain where a proxy can find it.
//
// **Nothing is ever built in place under `toolchains/`.** A tree is assembled
// in `tmp/` and then `rename`d, so an interrupted install leaves rubbish
// somewhere nobody looks rather than a half-written toolchain that
// `sharpie toolchain list` would report as installed and a proxy would try to
// `exec`. The same discipline as `ingot/store.install`, for the same reason.
//
// The modes come out of the archive. `wsharp` and `ingot` are recorded 0755
// and everything beside them 0644, so applying what each header holds is the
// whole of making a downloaded compiler runnable -- no list of names in here to
// keep in step with a release workflow over there.
const array = @import("std/array");
const bytes = @import("std/bytes");
const crypto = @import("std/crypto");
const fault = @import("ingot/fault");
const fs = @import("std/fs");
const home = @import("./home.ws");
const io = @import("std/io");
const path = @import("std/path");
const targz = @import("./targz.ws");
const text = @import("std/str");
const toolchain = @import("./toolchain.ws");

/// Unpack `archive` and publish it as the toolchain called `name`.
///
/// Answers whether it worked; the reason for a failure is in the `Fault`, for
/// `release.download`'s reason -- unpacking can fail in a dozen filesystem
/// ways and none of them belong in a caller's error set.
///
/// Already installed is success and does nothing. A toolchain is named by its
/// version and its triple, so a directory that is there is the one that would
/// have been written -- which is what makes `sharpie install` safe to run
/// twice, and what a retry after a failed download depends on.
pub fn unpack(f: fault.Fault, h: str, name: str, archive: str) bool {
    // Every caller hands over a name it spelled from a version and a triple, so
    // this is not the check that matters -- it is the one that is still here if
    // a caller stops doing that. Writing a tree is the other half of what a path
    // posing as a name could do.
    if (!toolchain.named(f, name)) { return false; }
    const at = home.toolchain(h, name);
    if (fs.is_dir(at)) { return true; }

    const members = read(f, archive) orelse return false;
    if (array.len(members) == 0) {
        fault.fail(f, "the archive holds nothing");
        return false;
    }

    const staging = scratch(f, h) orelse return false;
    if (!write_all(f, staging, members)) {
        discard(staging);
        return false;
    }

    fs.mkdir_all(home.toolchains(h)) catch {
        fault.fail(f, text.concat("cannot create ", home.toolchains(h)));
        discard(staging);
        return false;
    };
    // The one step that makes it visible, and it is atomic.
    fs.rename(staging, at) catch {
        fault.fail(f, text.concat("cannot publish the toolchain at ", at));
        discard(staging);
        return false;
    };
    return true;
}

/// Throw away a half-built tree, saying nothing if that fails too.
///
/// A `catch` that swallows deserves a name. The failure being cleaned up after
/// is the one worth reporting; a `remove_tree` that also fails would replace a
/// useful message with a less useful one, and the leftovers are under `tmp/`
/// where nothing looks for them.
fn discard(dir: str) void {
    fs.remove_tree(dir) catch { return; };
    return;
}

/// The archive's members, or null with a reason.
fn read(f: fault.Fault, archive: str) ?[]targz.Entry {
    const tar = targz.gunzip(bytes.of(archive)) catch {
        fault.fail(f, "the archive is not a gzip stream, or does not match its checksum");
        return null;
    };
    const members = targz.untar(tar) catch {
        fault.fail(f, "the archive is not a tar this can read");
        return null;
    };
    return members;
}

/// An empty directory under `tmp/` that nothing else is using.
fn scratch(f: fault.Fault, h: str) ?str {
    const room = home.scratch(h);
    fs.mkdir_all(room) catch {
        fault.fail(f, text.concat("cannot create ", room));
        return null;
    };
    // Random rather than the version's name: two `sharpie install` runs of the
    // same version must not assemble into one directory, and a process id is
    // not enough on a machine that reuses them.
    const tag = crypto.random(8) catch {
        fault.fail(f, "cannot name a temporary directory");
        return null;
    };
    const dir = path.join(room, bytes.to_hex(tag));
    fs.mkdir_all(dir) catch {
        fault.fail(f, text.concat("cannot create ", dir));
        return null;
    };
    return dir;
}

/// Write every member under `root`, with the mode the archive recorded.
fn write_all(f: fault.Fault, root: str, members: []targz.Entry) bool {
    var i = 0;
    while (i < array.len(members)) : (i += 1) {
        const e = members[i];
        // Everything in a release archive is under one directory named for the
        // version and the triple; an installation wants what is *inside* it,
        // and that enclosing directory itself strips to nothing.
        const inside = targz.strip_prefix(e.name);
        if (text.len(inside) == 0) { continue; }
        if (!safe(inside)) {
            fault.fail(f, text.concat("the archive names a path outside itself: ", e.name));
            return false;
        }
        const to = path.join(root, inside);

        if (e.kind == targz.DIRECTORY) {
            fs.mkdir_all(to) catch {
                fault.fail(f, text.concat("cannot create ", to));
                return false;
            };
        } else {
            // A tar need not list a directory before a file in it, and a
            // release archive written by a different `tar` may not.
            fs.mkdir_all(path.dirname(to)) catch {
                fault.fail(f, text.concat("cannot create ", path.dirname(to)));
                return false;
            };
            io.write_file(to, bytes.to_str(e.data)) catch {
                fault.fail(f, text.concat("cannot write ", to));
                return false;
            };
        }
        // **This is the line the whole `fs.chmod` builtin exists for.** Windows
        // has no permission bits and its arm does nothing, which is right:
        // there is nothing there to make a file runnable.
        fs.chmod(to, e.mode & 0o777) catch {
            fault.fail(f, text.concat("cannot set the mode of ", to));
            return false;
        };
    }
    return true;
}

/// Whether a member's path stays inside the directory it is unpacked into.
///
/// An archive is a thing downloaded from the network, and a member named
/// `../../.bashrc` is the oldest trick there is. Absolute paths and any `..`
/// component are refused rather than normalised away: a release archive has
/// neither, so anything that does is not a release archive.
pub fn safe(name: str) bool {
    if (path.is_absolute(name)) { return false; }
    const parts = text.split(path.normalise(name), "/");
    var i = 0;
    while (i < array.len(parts)) : (i += 1) {
        if (text.eq(parts[i], "..")) { return false; }
    }
    return true;
}

/// Remove an installed toolchain.
///
/// The directory is renamed out of the way first and then removed, so a
/// half-finished removal cannot leave something `toolchain list` still reports
/// -- the same trick as installing, in the other direction.
///
/// **Only ever something under `toolchains/`.** `uninstall /any/dir` used to
/// reach here with the directory as the name, and `path.join` answers an
/// absolute path with itself -- so it was renamed into `tmp/` and deleted, and
/// `uninstall ""` took `toolchains/` itself. The verb refuses such a name first;
/// this refuses it again, because a recursive delete is the one step whose
/// mistakes cannot be taken back.
pub fn remove(f: fault.Fault, h: str, name: str) bool {
    if (!toolchain.named(f, name)) { return false; }
    const at = home.toolchain(h, name);
    if (!fs.is_dir(at)) {
        fault.fail(f, text.concat(text.concat("`", name), "` is not installed"));
        return false;
    }
    const going = scratch(f, h) orelse return false;
    // `scratch` made it; `rename` on to an existing directory is what this
    // needs to avoid, so it goes away first.
    discard(going);
    fs.rename(at, going) catch {
        fault.fail(f, text.concat("cannot remove the toolchain at ", at));
        return false;
    };
    fs.remove_tree(going) catch {
        // It is out of the way and no longer reachable; failing to delete the
        // bytes is worth saying and is not a failed removal.
        fault.fail(f, text.concat("removed, but could not clear ", going));
        return true;
    };
    return true;
}
