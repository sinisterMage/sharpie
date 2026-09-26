// A stand-in for a toolchain's `wsharp`, which answers with where it is.
//
// `tests/rungs.sh` builds this once and copies it into every toolchain it makes,
// because a rung that execs a proxied command has to be able to say *which*
// toolchain answered. A copy of the real compiler would run on every platform
// too, and would print the same version whichever toolchain it came out of --
// which is the one thing a resolution test has to distinguish.
//
// Two things are printed and both are assertions:
//
//   - Its own path, normalised, so the toolchain directory is named with `/` on
//     Windows as well and the assertion is one string on all four triples.
//   - Its arguments, one a line, because a proxy is meant to pass them on
//     untouched *and* to have eaten the leading `+toolchain`. `os.args()` never
//     holds the program's own name in W#, so every line here is something the
//     proxy chose to forward.
//
// Not a case: `tests/run.sh` runs `tests/*.ws` and does not look in here.
const array = @import("std/array");
const os = @import("std/os");
const path = @import("std/path");
const text = @import("std/str");

fn main() void {
    print(path.normalise(os.self_exe() catch "?"));
    const args = os.args();
    var i = 0;
    while (i < array.len(args)) : (i += 1) {
        print(text.concat("arg\t", args[i]));
    }
    return;
}
