// Finding out which toolchains exist, and where each one's archive is.
//
// **There is no JSON here, and that is the point.** The obvious way to list
// releases is the forge's REST API, which answers in JSON -- and W# has no JSON
// reader. Writing one would be a few hundred lines standing between sharpie and
// its first useful act.
//
// It is not needed. A release is attached to a *tag*, tags are git refs, and
// `ingot/git.ws` already speaks git's smart HTTP transport well enough to ask a
// remote for its refs -- it was written to fetch packages and answers this
// question on the way past. So the list of versions comes from `ls-refs`, and
// the archive comes from a URL that can be spelled from the version and the
// triple without asking anybody. Two plain HTTP conversations, no new parser.
//
// The byte-level half is separated from the network for the reason `git.ws`
// separates its own: everything below takes refs and returns versions, so the
// whole of it can be tested against recorded output on a machine with no
// network. Only `available` opens a socket.
const array = @import("std/array");
const bytes = @import("std/bytes");
const fault = @import("ingot/fault");
const fetch = @import("./fetch.ws");
const fs = @import("std/fs");
const git = @import("ingot/git");
const hash = @import("std/hash");
const io = @import("std/io");
const list = @import("std/list");
const path = @import("std/path");
const os = @import("std/os");
const semver = @import("ingot/semver");
const text = @import("std/str");
const tls = @import("std/tls");

/// Where W# is published.
///
/// The GitHub mirror rather than the Forgejo the work is actually done on:
/// releases are built by GitHub's runners, so this is where the artifacts are.
pub const REPO = "https://github.com/sinisterMage/WSharp";

/// The prefix a version tag carries. `v0.1.0`, not `0.1.0`.
const TAG_PREFIX = "refs/tags/v";

/// Where a release may be read from instead, with no network at all.
///
/// **A release source is a directory, and publishing one over HTTPS is only how
/// the directory usually arrives.** `SHARPIE_RELEASE_DIR` naming an existing
/// directory is used where it lies: no socket is opened, no certificate store is
/// read, and the archives are found by the same names [`archive_name`] spells
/// for the published ones. The shape is `INGOT_REGISTRY`'s and it is here for
/// the same reason -- a test that has to stand up a peer is a test that does not
/// get run, and the three ways an install can go wrong on the way in
/// (a short archive, a digest that does not match, an extraction that stops part
/// way) are exactly the ones worth being able to inject.
///
/// It is not a mirror list and not a fallback: set, it is the only place looked
/// at, so a rung that should have refused cannot quietly succeed against the
/// real releases instead.
pub const DIR_VAR = "SHARPIE_RELEASE_DIR";

/// The local release directory, or null.
///
/// An empty value counts as unset, for `home.root`'s reason: a release source
/// rooted at `""` is one rooted at the working directory, which is much worse
/// than not having one.
pub fn local() ?str {
    const at = os.get(DIR_VAR) orelse return null;
    if (text.len(at) == 0) { return null; }
    return at;
}

/// Every version that can be installed, newest first.
///
/// Opens a socket, unless [`local`] says where to look instead; everything else
/// in this module does not.
pub fn available(f: fault.Fault, cfg: tls.Config) []semver.Version {
    if (local()) |at| { return published_in(f, at, os.target()); }
    const refs = git.discover(f, git.Remote{ .url = REPO, .cfg = cfg }) orelse {
        return []semver.Version{};
    };
    return versions_of(refs);
}

/// Every version a local release directory holds an archive for, newest first.
fn published_in(f: fault.Fault, at: str, triple: str) []semver.Version {
    const names = fs.read_dir(at) catch {
        fault.fail(f, text.concat("cannot read the release directory at ", at));
        return []semver.Version{};
    };
    return versions_in(names, triple);
}

/// The versions among a directory's file names, newest first.
///
/// [`archive_name`] read backwards, which is what makes a local directory answer
/// the same question the remote's tags do without being able to lie about it: a
/// version is advertised only when *its own* archive for *this* triple is there,
/// so nothing can be offered that then cannot be fetched. A remote's tag list
/// has no such property, which is why [`download`] has a paragraph about a tag
/// existing before its release does and this does not need one.
pub fn versions_in(names: []str, triple: str) []semver.Version {
    const head = "wsharp-";
    const tail = text.concat(text.concat("-", triple), ".tar.gz");
    var out = []semver.Version{};
    var i = 0;
    while (i < array.len(names)) : (i += 1) {
        const name = names[i];
        if (!text.starts_with(name, head)) { continue; }
        if (!ends_with(name, tail)) { continue; }
        // Both ends are known, so the middle is the version. A name that is
        // only the two ends leaves nothing, and `semver.parse` refuses it.
        const cut = text.len(name) - text.len(tail);
        if (cut <= text.len(head)) { continue; }
        const spelled = text.substr(name, text.len(head), cut);
        const v = semver.parse(spelled) orelse continue;
        out = array.push(out, v);
    }
    return sorted(out);
}

/// The versions among a remote's refs, newest first.
///
/// Two things get dropped, and both would otherwise show up as duplicates or
/// as nonsense:
///
///   - Anything that is not `refs/tags/v...`. Branches are refs too.
///   - The `^{}` entries. An *annotated* tag is an object of its own, so a
///     remote advertises both `refs/tags/v1.0.0` -- the tag object -- and
///     `refs/tags/v1.0.0^{}`, the commit it points at. Every release tag here
///     is annotated, so without this every version would appear twice.
///
/// A tag that is not a version is skipped rather than raising: a repository is
/// allowed to have tags that are not releases.
pub fn versions_of(refs: list.List[git.Ref]) []semver.Version {
    var out = []semver.Version{};
    var i = 0;
    while (i < list.len(refs)) : (i += 1) {
        const name = list.get(refs, i).name;
        if (!text.starts_with(name, TAG_PREFIX)) { continue; }
        if (ends_with(name, "^{}")) { continue; }
        const spelled = text.substr(name, text.len(TAG_PREFIX), text.len(name));
        const v = semver.parse(spelled) orelse continue;
        out = array.push(out, v);
    }
    return sorted(out);
}

/// Newest first, by an insertion sort.
///
/// Insertion because a project has tens of releases, not thousands, and the
/// same reasoning `ingot/store.sorted` gives for its own: a sort whose cost is
/// invisible does not need to be clever.
fn sorted(vs: []semver.Version) []semver.Version {
    var out = []semver.Version{};
    var i = 0;
    while (i < array.len(vs)) : (i += 1) {
        const v = vs[i];
        var at = 0;
        while (at < array.len(out)) : (at += 1) {
            // Strictly greater, so equal versions keep the order they arrived
            // in rather than being shuffled.
            if (semver.less(out[at], v)) { break; }
        }
        out = insert_at(out, at, v);
    }
    return out;
}

fn insert_at(vs: []semver.Version, at: i64, v: semver.Version) []semver.Version {
    var out = []semver.Version{};
    var i = 0;
    while (i < at) : (i += 1) { out = array.push(out, vs[i]); }
    out = array.push(out, v);
    while (i < array.len(vs)) : (i += 1) { out = array.push(out, vs[i]); }
    return out;
}

// ---------------------------------------------------------------------------
// Channels
// ---------------------------------------------------------------------------

/// The newest release that is not a pre-release, or null.
///
/// What `stable` means. Semver already says which versions those are: a
/// pre-release is exactly one with something after the `-`, and it sorts below
/// the release it precedes -- so this is a filter and not a second opinion.
pub fn stable(vs: []semver.Version) ?semver.Version {
    var i = 0;
    while (i < array.len(vs)) : (i += 1) {
        if (text.len(vs[i].pre) == 0) { return vs[i]; }
    }
    return null;
}

/// The newest release of any kind, or null. What `latest` means.
pub fn latest(vs: []semver.Version) ?semver.Version {
    if (array.len(vs) == 0) { return null; }
    return vs[0];
}

/// The exact version among `vs`, or null.
pub fn exact(vs: []semver.Version, want: str) ?semver.Version {
    const asked = semver.parse(want) orelse return null;
    var i = 0;
    while (i < array.len(vs)) : (i += 1) {
        if (semver.eq(vs[i], asked)) { return vs[i]; }
    }
    return null;
}

/// What a channel name or a version string picks out of `vs`.
///
/// The three names are reserved and cannot be versions -- `stable` does not
/// parse as one -- so there is no ambiguity to resolve and no order to get
/// right.
pub fn resolve(vs: []semver.Version, spec: str) ?semver.Version {
    if (text.eq(spec, "stable")) { return stable(vs); }
    if (text.eq(spec, "latest")) { return latest(vs); }
    return exact(vs, spec);
}

/// Whether a spec names a channel rather than a version.
///
/// The distinction matters after the install, not during it: a channel is a
/// standing request that `update` should re-ask, and a version is a one-off.
pub fn is_channel(spec: str) bool {
    return text.eq(spec, "stable") or text.eq(spec, "latest");
}

// ---------------------------------------------------------------------------
// Where an archive is
// ---------------------------------------------------------------------------

/// The archive holding a toolchain, as the release workflow names it.
///
/// Spelled rather than looked up, which is what makes the whole module
/// API-free. The shape is the workflow's `Package` step and the two have to
/// agree: `wsharp-<version>-<triple>.tar.gz`.
pub fn archive_name(v: semver.Version, triple: str) str {
    return text.concat(text.concat(text.concat("wsharp-", semver.render(v)),
        text.concat("-", triple)), ".tar.gz");
}

/// Where that archive is published.
pub fn archive_url(v: semver.Version, triple: str) str {
    return text.concat(download_prefix(v), archive_name(v, triple));
}

/// Where its checksum is. A sidecar per target rather than one shared
/// `SHA256SUMS`, because four matrix jobs writing one file would each overwrite
/// the others -- and an installer wants one tarball and one digest anyway.
pub fn checksum_url(v: semver.Version, triple: str) str {
    return text.concat(archive_url(v, triple), ".sha256");
}

fn download_prefix(v: semver.Version) str {
    return text.concat(text.concat(REPO, "/releases/download/v"),
        text.concat(semver.render(v), "/"));
}

/// The digest out of a `.sha256` file.
///
/// `sha256sum` and `shasum -a 256` both write `<hex>  <name>`, which is why the
/// workflow may use either -- whatever reads it should not have to know which
/// machine wrote it. Only the first field is taken, and it is checked for being
/// the right length and being hex, because a truncated download of a *checksum*
/// would otherwise be compared against happily.
pub fn digest_of(sidecar: str) !{BadFormat}str {
    const cut = text.find(sidecar, " ");
    var hex = sidecar;
    if (cut >= 0) { hex = text.substr(sidecar, 0, cut); }
    hex = text.trim(hex);
    if (text.len(hex) != 64) { return error.BadFormat; }
    var i = 0;
    while (i < 64) : (i += 1) {
        const b = text.byte_at(hex, i);
        const digit = b >= 48 and b <= 57;
        const lower = b >= 97 and b <= 102;
        const upper = b >= 65 and b <= 70;
        if (!digit and !lower and !upper) { return error.BadFormat; }
    }
    return text.to_lower(hex);
}

/// Fetch the archive and its checksum, and answer with the archive.
///
/// Takes a `Fault` and answers with null, as `git.discover` does, rather than
/// raising. That is not a stylistic echo: `fetch.get` can raise everything a
/// socket and a TLS handshake can, which is three dozen names, and a function
/// propagating that set would force every caller above it to carry the same
/// list or throw it away. A `Fault` keeps the *reason* -- which is the thing a
/// user needs when a download fails -- without putting it in the type.
///
/// The checksum is fetched **first**, so a mismatch is measured against
/// something published rather than against whatever happened to arrive
/// alongside. Both go through `fetch.get`, because a release download is a
/// redirect to another host.
pub fn download(f: fault.Fault, v: semver.Version, triple: str, cfg: tls.Config) ?str {
    if (local()) |at| { return read_local(f, at, v, triple); }
    const url = archive_url(v, triple);
    const sidecar = fetch.get(checksum_url(v, triple), cfg) catch {
        // **A tag exists before its release does.** Versions are discovered by
        // asking the remote for its tags, and a tag is pushed *first* -- the
        // archives appear minutes later when the build that the tag started
        // finishes, and one that fails never publishes for that platform at
        // all. So the newest version is routinely the one that cannot be
        // installed yet, and "cannot reach the checksum" is a confusing way to
        // say that.
        //
        // The two cases are not told apart here, because doing so means asking
        // the forge's API what a release holds, and its answer is JSON -- which
        // is the dependency this whole module is written to avoid. Naming both
        // is honest and costs nothing.
        fault.fail(f, text.concat(text.concat("no archive published for ", triple),
            text.concat(text.concat(" at ", semver.render(v)),
                " -- its release may still be building, or may have failed for this platform")));
        return null;
    };
    const want = digest_of(sidecar) catch {
        fault.fail(f, text.concat("the published checksum is not a digest: ", url));
        return null;
    };
    const archive = fetch.get(url, cfg) catch {
        fault.fail(f, text.concat("cannot download ", url));
        return null;
    };
    const ok = verified(archive, want) catch {
        fault.fail(f, text.concat("what was downloaded is not what was published: ", url));
        return null;
    };
    return ok;
}

/// The same two files out of a local release directory.
///
/// **The digest is checked here exactly as a download's is, by the same two
/// functions and in the same order.** That is the whole point of the offline
/// path: a directory standing in for a published release has to be able to be
/// wrong in the ways a network can be wrong, or the checking that catches those
/// has nothing driving it. A short archive and a substituted one both fail
/// [`verified`], and a truncated sidecar fails [`digest_of`] -- which is what its
/// length-and-hex check was written for and what nothing exercised until now.
///
/// A missing sidecar reads the same way the network's missing one does. The
/// remote's reason ("the release may still be building") does not apply to a
/// directory, so the wording says what is true of a directory instead.
fn read_local(f: fault.Fault, at: str, v: semver.Version, triple: str) ?str {
    const name = archive_name(v, triple);
    const beside = path.join(at, text.concat(name, ".sha256"));
    const sidecar = io.read_file(beside) catch {
        fault.fail(f, text.concat(text.concat("no archive published for ", triple),
            text.concat(text.concat(" at ", semver.render(v)),
                text.concat(" -- nothing is beside it at ", beside))));
        return null;
    };
    const want = digest_of(sidecar) catch {
        fault.fail(f, text.concat("the published checksum is not a digest: ", beside));
        return null;
    };
    const whole = path.join(at, name);
    const archive = io.read_file(whole) catch {
        fault.fail(f, text.concat("cannot download ", whole));
        return null;
    };
    const ok = verified(archive, want) catch {
        fault.fail(f, text.concat("what was downloaded is not what was published: ", whole));
        return null;
    };
    return ok;
}

/// The archive, if it hashes to `want`.
///
/// Split out so the checking can be tested without a network: it is the step
/// that decides whether a downloaded compiler is the published one, and it
/// should be possible to prove it says no.
pub fn verified(archive: str, want: str) !{BadFormat}str {
    const got = bytes.to_hex(hash.sha256(bytes.of(archive)));
    if (!text.eq(got, want)) { return error.BadFormat; }
    return archive;
}

/// Whether `s` ends with `suffix`.
///
/// `std/str` has `starts_with` and not this one, and one caller does not make a
/// library function -- so it is here, where the caller is.
fn ends_with(s: str, suffix: str) bool {
    const n = text.len(s);
    const m = text.len(suffix);
    if (m > n) { return false; }
    return text.eq(text.substr(s, n - m, n), suffix);
}
