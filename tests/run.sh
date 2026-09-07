#!/bin/sh
# Run every case in this directory and compare it against what it declares.
#
# The same contract `crates/wsharp-cli/tests/cases.rs` uses upstream: a case is
# a `.ws` program whose header comment holds one `// expect:` line per line it
# should print, in order. There is no Rust here to hang a harness off, so this
# is the harness -- and it stays a POSIX shell script for the same reason
# sharpie has an `install.sh`: it has to run before there is a W# toolchain to
# run anything else with.
#
# `WSHARP` names the compiler. A checkout builds one at
# `../WSharp/target/debug/wsharp`, which is the default because that is where
# somebody working on both at once already has it.
#
# Run from anywhere; paths are resolved against the repository root, because a
# case reads its fixtures relative to the working directory.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

WSHARP=${WSHARP:-../WSharp/target/debug/wsharp}
if ! [ -x "$WSHARP" ] && ! command -v "$WSHARP" >/dev/null 2>&1; then
    echo "no compiler at \`$WSHARP\`; set WSHARP to one" >&2
    exit 2
fi

pass=0
fail=0
failed=""

for case in tests/*.ws; do
    [ -e "$case" ] || continue
    name=${case#tests/}

    # Every `// expect:` line, in the order written, with the marker removed.
    want=$(sed -n 's|^// expect: \{0,1\}||p' "$case")

    # `// env: NAME=value`, one per line, set for this case only. A case about
    # where sharpie keeps its files has to be able to say where that is, or it
    # would read whatever the machine running it happens to have installed.
    env_args=""
    while IFS= read -r assignment; do
        [ -n "$assignment" ] || continue
        env_args="$env_args $assignment"
    done <<EOF
$(sed -n 's|^// env: \{0,1\}||p' "$case")
EOF

    # Unquoted on purpose: `env_args` is a list of assignments, not one word.
    # Nothing in this repository puts a space in one.
    if got=$(env $env_args "$WSHARP" run "$case" 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ]; then
        fail=$((fail + 1))
        failed="$failed $name"
        printf '%s ... FAILED (exit %s)\n' "$name" "$status"
        printf '%s\n' "$got" | sed 's/^/    /'
        continue
    fi

    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        printf '%s ... ok\n' "$name"
    else
        fail=$((fail + 1))
        failed="$failed $name"
        printf '%s ... FAILED\n' "$name"
        # Both sides, because which line drifted is the whole question.
        printf '%s\n' "$want" > "${TMPDIR:-/tmp}/sharpie-want.$$"
        printf '%s\n' "$got" > "${TMPDIR:-/tmp}/sharpie-got.$$"
        diff -u "${TMPDIR:-/tmp}/sharpie-want.$$" "${TMPDIR:-/tmp}/sharpie-got.$$" \
            | sed 's/^/    /' || true
        rm -f "${TMPDIR:-/tmp}/sharpie-want.$$" "${TMPDIR:-/tmp}/sharpie-got.$$"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'failed:%s\n' "$failed"; exit 1; }
