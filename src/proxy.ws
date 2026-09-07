// Standing in front of `wsharp` and `ingot`.
//
// `~/.sharpie/bin` holds copies of this one binary under three names, and that
// directory is the only thing on `PATH`. Running `wsharp` runs sharpie, which
// works out which toolchain applies and *becomes* the real compiler. Nothing is
// wrapped and no output is filtered: after `os.exec` there is no sharpie left
// in the process at all.
//
// **The name is read from `self_exe`, not from `argv[0]`.** W# never puts the
// program's own name in `os.args()` -- `std/os` says so and means it -- so the
// usual trick is unavailable. That turns out to be the better answer anyway:
// `argv[0]` is whatever the caller chose to write, and `/proc/self/exe` is
// where the kernel says this process came from.
//
// `os.exec` is `execvp` and does not come back, which is exactly the shape a
// proxy wants: no second process, no signal forwarding to get wrong, and the
// exit status is the real program's because it *is* the process. `ingot run`
// already leans on this.
const array = @import("std/array");
const fault = @import("ingot/fault");
const home = @import("./home.ws");
const os = @import("std/os");
const path = @import("std/path");
const settings = @import("./settings.ws");
const text = @import("std/str");
const toolchain = @import("./toolchain.ws");

/// The programs sharpie stands in front of.
///
/// Two, and both come out of the same tarball. `ingot` is here as well as
/// `wsharp` because it is the other half of a toolchain and a user should not
/// have to know that one of them is a W# program and the other is Rust.
pub fn is_proxied(name: str) bool {
    return text.eq(name, "wsharp") or text.eq(name, "ingot");
}

/// What this binary was invoked as, with any `.exe` taken off.
///
/// `sharpie` when it is itself, `wsharp` or `ingot` when it is a proxy. Falls
/// back to `sharpie` when the platform will not say -- OpenBSD does not keep
/// the path -- because being wrong in that direction prints a usage message
/// rather than exec'ing something unexpected.
pub fn invoked_as() str {
    const me = os.self_exe() catch { return "sharpie"; };
    var name = path.basename(path.normalise(me));
    if (ends_with_exe(name)) { name = text.substr(name, 0, text.len(name) - 4); }
    return name;
}

fn ends_with_exe(name: str) bool {
    const n = text.len(name);
    if (n < 4) { return false; }
    return text.eq(text.to_lower(text.substr(name, n - 4, n)), ".exe");
}

/// Become `name` from whichever toolchain applies. Does not return on success.
///
/// The `+toolchain` argument is consumed here rather than passed on: it is
/// sharpie's, and handing `+stable` to the compiler would be handing it a file
/// name it cannot open.
pub fn run(f: fault.Fault, name: str, args: []str) i64 {
    const h = home.root() catch {
        fault.fail(f, "cannot find a home directory to keep toolchains in");
        return 1;
    };
    const s = settings.read(h) catch {
        fault.fail(f, text.concat("cannot read ", home.settings(h)));
        return 1;
    };
    const cwd = os.cwd() catch ".";

    const chosen = toolchain.choose(h, s, args, cwd) orelse {
        fault.fail(f, no_toolchain(s));
        return 1;
    };
    const program = toolchain.program(chosen.dir, name) orelse {
        fault.fail(f, text.concat(text.concat("`", name),
            text.concat("` is not in the toolchain at ", chosen.dir)));
        return 1;
    };

    const forward = toolchain.without_plus(args);
    os.exec(program, forward) catch {
        fault.fail(f, text.concat("cannot run ", program));
        return 1;
    };
    // `exec` does not come back, so reaching here is itself the failure.
    fault.fail(f, text.concat("cannot run ", program));
    return 1;
}

/// What to say when nothing has been chosen.
///
/// Two different situations wearing one symptom, and telling them apart is the
/// difference between a useful message and a shrug: a sharpie with toolchains
/// installed and no default has a different fix from one with nothing at all.
fn no_toolchain(s: settings.Settings) str {
    const named = settings.default_toolchain(s) orelse {
        return "no toolchain is set; `sharpie install stable` gets one and makes it the default";
    };
    return text.concat(text.concat("the default toolchain `", named),
        "` is not installed; `sharpie toolchain list` says what is");
}
