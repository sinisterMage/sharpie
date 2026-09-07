// Resolving a `Location` against the URL it came from.
//
// The half of `src/fetch.ws` that is arithmetic rather than a socket, which is
// the half worth testing here: whether a redirect is followed at all needs a
// server, but *where it points* is a function of two strings and is where the
// mistakes live.
//
// The first case is the one that matters in practice -- GitHub answers a
// release-asset URL with an absolute redirect to a different host, and getting
// that wrong is the difference between a downloaded toolchain and a downloaded
// HTML error page.
//
// expect: absolute stays: https://objects.githubusercontent.com/x?token=1
// expect: cross-host absolute stays: http://elsewhere.example/a
// expect: rooted keeps the origin: https://github.com/other
// expect: rooted keeps a port: https://host.example:8443/other
// expect: relative is against the directory: https://h.example/a/b/next
// expect: relative at the root: https://h.example/next
// expect: relative with no path at all: https://h.example/next
// expect: a query is not a directory: https://h.example/a/next
// expect: unreadable base leaves it alone: /somewhere
// expect: 301 302 303 307 308 all move: true
// expect: 200 and 404 do not move: true
const fetch = @import("../src/fetch.ws");
const text = @import("std/str");

fn main() i64 {
    // Absolute wins outright, whatever the base said.
    show("absolute stays", fetch.resolve(
        "https://github.com/o/r/releases/download/v1/a.tar.gz",
        "https://objects.githubusercontent.com/x?token=1"));
    show("cross-host absolute stays", fetch.resolve(
        "https://h.example/a", "http://elsewhere.example/a"));

    // A rooted location keeps scheme, host and port and replaces the rest.
    show("rooted keeps the origin", fetch.resolve(
        "https://github.com/o/r/releases", "/other"));
    show("rooted keeps a port", fetch.resolve(
        "https://host.example:8443/a/b", "/other"));

    // A bare name is relative to the directory the path names, not to the path.
    show("relative is against the directory", fetch.resolve(
        "https://h.example/a/b/c", "next"));
    show("relative at the root", fetch.resolve("https://h.example/c", "next"));
    // No path at all: the origin is the whole URL, so a separator is needed.
    show("relative with no path at all", fetch.resolve("https://h.example", "next"));
    // `?` does not open a directory -- everything after the last `/` goes.
    show("a query is not a directory", fetch.resolve(
        "https://h.example/a/b?x=1", "next"));

    // A base this cannot read is not worth guessing about.
    show("unreadable base leaves it alone", fetch.resolve("ftp://h/a", "/somewhere"));

    print(text.concat("301 302 303 307 308 all move: ", yes(
        fetch.moved(301) and fetch.moved(302) and fetch.moved(303)
        and fetch.moved(307) and fetch.moved(308))));
    print(text.concat("200 and 404 do not move: ", yes(
        !fetch.moved(200) and !fetch.moved(404))));
    return 0;
}

fn show(label: str, got: str) void {
    print(text.concat(text.concat(label, ": "), got));
    return;
}

fn yes(b: bool) str {
    if (b) { return "true"; }
    return "false";
}
