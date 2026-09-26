// Turning a remote's refs into a list of versions, and spelling an archive's
// URL from one.
//
// Everything here is the half of `src/release.ws` that takes bytes and returns
// values, so it runs with no network -- the split `ingot/git.ws` made for its
// own protocol, and the reason this module was written the same way.
//
// The refs below are the shape a real `ls-refs` answers with, including the two
// things that have to be dropped: branches, and the `^{}` entries an
// *annotated* tag produces. Every release tag on W# is annotated, so without
// that second filter every version would be listed twice.
//
// expect: 5 versions found
// expect: newest first: 1.0.0 0.2.0 0.2.0-rc2 0.2.0-rc1 0.1.0
// expect: latest is: 1.0.0
// expect: stable skips prereleases: 1.0.0
// expect: stable of prereleases only: none
// expect: latest of prereleases only: 0.2.0-rc2
// expect: exact hit: 0.2.0-rc1
// expect: exact miss: none
// expect: resolve stable: 1.0.0
// expect: resolve latest: 1.0.0
// expect: resolve a version: 0.1.0
// expect: resolve nonsense: none
// expect: nothing at all resolves to nothing: true
// expect: a directory advertises: 0.2.0 0.2.0-rc2 0.1.0
// expect: for another triple: 0.9.0
// expect: for a triple it holds nothing for: -
// expect: an empty directory advertises nothing: true
// expect: archive name: wsharp-0.1.0-x86_64-unknown-linux-gnu.tar.gz
// expect: archive url: https://github.com/sinisterMage/WSharp/releases/download/v0.1.0/wsharp-0.1.0-x86_64-unknown-linux-gnu.tar.gz
// expect: checksum url ends in .sha256: true
// expect: a prerelease keeps its suffix: wsharp-0.2.0-rc1-aarch64-apple-darwin.tar.gz
// expect: digest from a sha256sum line: 2efc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890
// expect: digest from a bare digest: 2efc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890
// expect: uppercase is accepted and lowered: 2efc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890
// expect: a short digest is refused: true
// expect: a non-hex digest is refused: true
// expect: an empty sidecar is refused: true
// expect: the right archive verifies: true
// expect: the wrong archive is refused: true
const array = @import("std/array");
const bytes = @import("std/bytes");
const git = @import("ingot/git");
const hash = @import("std/hash");
const list = @import("std/list");
const release = @import("../src/release.ws");
const semver = @import("ingot/semver");
const text = @import("std/str");

fn main() i64 {
    // What a remote advertises: tags, their peeled forms, and a branch.
    var refs: list.List[git.Ref] = list.new();
    add(refs, "refs/heads/main");
    add(refs, "refs/tags/v0.1.0");
    add(refs, "refs/tags/v0.1.0^{}");
    add(refs, "refs/tags/v1.0.0");
    add(refs, "refs/tags/v1.0.0^{}");
    add(refs, "refs/tags/v0.2.0-rc1");
    add(refs, "refs/tags/v0.2.0-rc1^{}");
    add(refs, "refs/tags/v0.2.0-rc2");
    add(refs, "refs/tags/v0.2.0");
    // Tags that are not releases, which a repository is allowed to have.
    add(refs, "refs/tags/nightly");
    add(refs, "refs/tags/v-not-a-version");

    const vs = release.versions_of(refs);
    print(text.concat(text.from_int(array.len(vs)), " versions found"));
    print(text.concat("newest first: ", spell(vs)));

    show("latest is", release.latest(vs));
    show("stable skips prereleases", release.stable(vs));

    // A project that has only ever cut release candidates has no stable.
    var pre: list.List[git.Ref] = list.new();
    add(pre, "refs/tags/v0.2.0-rc1");
    add(pre, "refs/tags/v0.2.0-rc2");
    const only_pre = release.versions_of(pre);
    show("stable of prereleases only", release.stable(only_pre));
    show("latest of prereleases only", release.latest(only_pre));

    show("exact hit", release.exact(vs, "0.2.0-rc1"));
    show("exact miss", release.exact(vs, "9.9.9"));

    show("resolve stable", release.resolve(vs, "stable"));
    show("resolve latest", release.resolve(vs, "latest"));
    show("resolve a version", release.resolve(vs, "0.1.0"));
    show("resolve nonsense", release.resolve(vs, "banana"));

    var none: list.List[git.Ref] = list.new();
    const empty = release.versions_of(none);
    print(text.concat("nothing at all resolves to nothing: ",
        yes(array.len(empty) == 0 and absent(release.latest(empty)))));

    // What a local release directory advertises, which is `archive_name` read
    // backwards. Everything here is a name a real directory can hold: two
    // triples' archives side by side, the sidecars beside them, and the files a
    // person left in the way.
    const room = []str{
        "wsharp-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
        "wsharp-0.1.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
        "wsharp-0.2.0-rc2-x86_64-unknown-linux-gnu.tar.gz",
        "wsharp-0.2.0-x86_64-unknown-linux-gnu.tar.gz",
        "wsharp-0.9.0-aarch64-apple-darwin.tar.gz",
        // Neither of these is a version, and neither may be offered as one.
        "wsharp--x86_64-unknown-linux-gnu.tar.gz",
        "wsharp-banana-x86_64-unknown-linux-gnu.tar.gz",
        "notes.txt",
    };
    print(text.concat("a directory advertises: ",
        spelled(release.versions_in(room, "x86_64-unknown-linux-gnu"))));
    // The triple is part of the question, so a machine cannot be offered a
    // version whose archive is for another one.
    print(text.concat("for another triple: ",
        spelled(release.versions_in(room, "aarch64-apple-darwin"))));
    print(text.concat("for a triple it holds nothing for: ",
        spelled(release.versions_in(room, "x86_64-pc-windows-msvc"))));
    print(text.concat("an empty directory advertises nothing: ",
        yes(array.len(release.versions_in([]str{}, "x86_64-unknown-linux-gnu")) == 0)));

    const v = semver.parse("0.1.0") orelse semver.zero();
    print(text.concat("archive name: ",
        release.archive_name(v, "x86_64-unknown-linux-gnu")));
    print(text.concat("archive url: ",
        release.archive_url(v, "x86_64-unknown-linux-gnu")));
    const sums = release.checksum_url(v, "x86_64-unknown-linux-gnu");
    print(text.concat("checksum url ends in .sha256: ",
        yes(text.find(sums, ".tar.gz.sha256") > 0)));

    const rc = semver.parse("0.2.0-rc1") orelse semver.zero();
    print(text.concat("a prerelease keeps its suffix: ",
        release.archive_name(rc, "aarch64-apple-darwin")));

    // Exactly what the release workflow writes, from a real sidecar.
    const line = "2efc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890  wsharp-0.1.0-x86_64-unknown-linux-gnu.tar.gz\n";
    print(text.concat("digest from a sha256sum line: ", digest(line)));
    print(text.concat("digest from a bare digest: ",
        digest("2efc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890")));
    print(text.concat("uppercase is accepted and lowered: ",
        digest("2EFC18E07A582B14AB51A52B23EC6D0FECB97BCBD33B6DC82D7E98DBE2B9C890  x")));

    // A truncated or corrupted *checksum* must not be compared against happily.
    print(text.concat("a short digest is refused: ", yes(refused("abc123  x"))));
    print(text.concat("a non-hex digest is refused: ",
        yes(refused("zzfc18e07a582b14ab51a52b23ec6d0fecb97bcbd33b6dc82d7e98dbe2b9c890  x"))));
    print(text.concat("an empty sidecar is refused: ", yes(refused(""))));

    // And the check the whole download hangs on.
    const payload = "a toolchain, pretend";
    const good = bytes.to_hex(hash.sha256(bytes.of(payload)));
    const ok = release.verified(payload, good) catch "";
    print(text.concat("the right archive verifies: ", yes(text.eq(ok, payload))));
    const bad = release.verified(payload,
        "0000000000000000000000000000000000000000000000000000000000000000") catch "no";
    print(text.concat("the wrong archive is refused: ", yes(text.eq(bad, "no"))));
    return 0;
}

fn add(refs: list.List[git.Ref], name: str) void {
    list.push(refs, git.Ref{ .id = "0000000000000000000000000000000000000000", .name = name });
    return;
}

fn spell(vs: []semver.Version) str {
    var out = "";
    var i = 0;
    while (i < array.len(vs)) : (i += 1) {
        if (i > 0) { out = text.concat(out, " "); }
        out = text.concat(out, semver.render(vs[i]));
    }
    return out;
}

/// [`spell`], with `-` for none.
///
/// A case cannot expect a trailing space -- `tests/run.sh` trims each `expect`
/// line -- so an empty answer has to print something, which is the rule
/// `ingot_manifest.ws` follows upstream and the character it uses.
fn spelled(vs: []semver.Version) str {
    if (array.len(vs) == 0) { return "-"; }
    return spell(vs);
}

fn show(label: str, v: ?semver.Version) void {
    const got = v orelse {
        print(text.concat(text.concat(label, ": "), "none"));
        return;
    };
    print(text.concat(text.concat(label, ": "), semver.render(got)));
    return;
}

fn digest(s: str) str {
    return release.digest_of(s) catch "refused";
}

fn refused(s: str) bool {
    const got = release.digest_of(s) catch { return true; };
    return false;
}

fn absent(v: ?semver.Version) bool {
    const got = v orelse return true;
    return false;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
