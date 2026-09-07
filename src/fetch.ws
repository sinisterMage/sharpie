// HTTP that follows redirects, which `std/http` deliberately does not.
//
// `http.get` makes one request and answers with whatever came back, and for a
// library that is the right shape: a 302 is an answer, and a client that
// silently went somewhere else would be hiding the one thing a caller might
// want to inspect. A downloader is the caller that always wants to follow.
//
// **This is not optional for us.** GitHub answers a release-asset URL with a
// 302 to `objects.githubusercontent.com` -- a *different host*, so each hop is
// a new connection, a new TLS handshake and a new certificate to check against
// a new name. `http.request_with` already does the last of those: it re-aims
// the configuration at the URL's own host on every call, so calling it once per
// hop is not just adequate, it is the only correct way to do it. Reusing one
// connection across hosts would be the bug.
//
// The trust store is threaded through rather than read per hop. Parsing it
// costs about as much as a handshake, which is why `http.request_with` exists
// at all.
const array = @import("std/array");
const http = @import("std/http");
const list = @import("std/list");
const text = @import("std/str");
const tls = @import("std/tls");
const x509 = @import("std/x509");

/// How many redirects to follow before giving up.
///
/// Five is what browsers settled on. A chain longer than that is a loop or a
/// misconfiguration, and following it for ever is how a downloader hangs
/// instead of failing.
pub const MAX_HOPS = 5;

/// A trust store, read once.
///
/// A caller making several requests should make one of these and pass it to
/// every `get`: `x509.system_roots` parses the platform's whole root store,
/// and doing that per download is most of the cost of a download.
pub fn anchors() !tls.Config {
    // The host is filled in per request by `http.request_with`, so the empty
    // name here is not a placeholder that might leak -- it is never read.
    return tls.roots_config("", try x509.system_roots());
}

/// `GET url`, following redirects, and answer with what finally replied.
///
/// The answer is the *last* response, so a caller still sees a 404 as a 404.
/// Only the hops are hidden, which is the whole difference from `http.get`.
pub fn get(url: str, cfg: tls.Config) !str {
    var at = url;
    var hop = 0;
    while (hop <= MAX_HOPS) : (hop += 1) {
        const answer = try http.request_with(at, "GET", "", cfg);
        if (!moved(answer.code)) {
            if (answer.code != 200) { return error.NotFound; }
            return answer.body;
        }
        const next = http.header(answer.headers, "location") orelse {
            // A redirect with nowhere to go. Not `BadFormat` on the body --
            // the body is fine and the header is missing.
            return error.NotFound;
        };
        at = resolve(at, next);
    }
    return error.NotFound;
}

/// Whether a status code means "ask somewhere else".
///
/// 303 turns a POST into a GET and 307/308 do not, which would matter if this
/// forwarded anything other than `GET` -- for a download all five are the same
/// instruction.
pub fn moved(code: i64) bool {
    return code == 301 or code == 302 or code == 303 or code == 307 or code == 308;
}

/// A `Location` against the URL it came from.
///
/// GitHub sends an absolute URL and so does almost everything else, but a
/// relative one is legal and has been since RFC 7231 allowed it. Two of the
/// three forms are cheap to get right, so they are:
///
///   - `https://elsewhere/x` stands alone.
///   - `/x` replaces the path, keeping scheme, host and port.
///   - anything else is relative to the directory the current path names.
pub fn resolve(base: str, location: str) str {
    if (text.starts_with(location, "http://")) { return location; }
    if (text.starts_with(location, "https://")) { return location; }

    const root = origin(base);
    if (text.len(root) == 0) { return location; }
    if (text.starts_with(location, "/")) { return text.concat(root, location); }

    const path = text.substr(base, text.len(root), text.len(base));
    const cut = last_slash(path);
    if (cut < 0) { return text.concat(text.concat(root, "/"), location); }
    return text.concat(text.concat(root, text.substr(path, 0, cut + 1)), location);
}

/// The scheme, host and port of a URL, with no trailing slash.
///
/// Empty for something this cannot read, which the caller treats as "leave the
/// location alone" rather than raising: a `Location` that is already absolute
/// does not need a base, and one that is not is beyond saving anyway.
fn origin(url: str) str {
    var skip = 0;
    if (text.starts_with(url, "https://")) { skip = 8; }
    else if (text.starts_with(url, "http://")) { skip = 7; }
    else { return ""; }

    const rest = text.substr(url, skip, text.len(url));
    const cut = text.find(rest, "/");
    if (cut < 0) { return url; }
    return text.substr(url, 0, skip + cut);
}

/// The offset of the last `/` in a path, or -1.
fn last_slash(path: str) i64 {
    var at = -1;
    var i = 0;
    while (i < text.len(path)) : (i += 1) {
        if (text.byte_at(path, i) == 47) { at = i; }
    }
    return at;
}
