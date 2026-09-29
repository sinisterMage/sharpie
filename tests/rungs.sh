#!/bin/sh
# Every resolution rung, driven through a *built* sharpie, one line each.
#
# `tests/run.sh` runs the `.ws` cases, which reach into `src/` and ask each
# function what it answers. That is the right shape for a ladder's arithmetic and
# it cannot reach the thing a user meets: a binary, a `~/.sharpie` with real
# toolchains unpacked into it, three proxies that are copies of that binary, and
# an `exec` into whichever toolchain the ladder chose. Nothing below this line
# imports anything -- it runs the program.
#
# **No network peer, and no network.** A rung that fetched from GitHub would be a
# rung that fails when a release is being cut, and the three fault injections
# cannot be driven over a real transport at all: there is no way to ask
# `objects.githubusercontent.com` for half a tarball. So the releases are a
# directory -- `SHARPIE_RELEASE_DIR`, which `src/release.ws` reads instead of
# opening a socket -- and the archives in it are made here, from a stub compiled
# by the same `wsharp` that built sharpie. The digest is checked out of that
# directory by the same two functions that check a download's, so a short archive
# and a substituted one fail where they would have failed on the wire.
#
# What each rung asserts, beyond exiting 0: **`sharpie show` names the rung that
# answered.** That is the first question anybody asks when the answer surprises
# them, and it is the one thing a test of a five-rung ladder can get vacuously
# right -- every rung resolving to the same toolchain would pass a test that only
# looked at which toolchain ran.
#
# Two environment variables, both the ones `tests/run.sh` and CI already use:
#
#   WSHARP   the compiler, which builds the stub. Also needs a C compiler on
#            `PATH` (or `CC`), because `wsharp build` links.
#   SHARPIE  the built sharpie. `./sharpie` or `./sharpie.exe`, whichever is
#            there, so `wsharp build src/main.ws -o sharpie` and then this is
#            the whole sequence.
#
# Run from anywhere; everything is resolved against the repository root.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

WSHARP=${WSHARP:-../WSharp/target/debug/wsharp}
if ! [ -x "$WSHARP" ] && ! command -v "$WSHARP" >/dev/null 2>&1; then
    echo "no compiler at \`$WSHARP\`; set WSHARP to one" >&2
    exit 2
fi

# Whichever was built. Named rather than guessed when `SHARPIE` is set, because
# CI builds to a name it chose.
if [ -z "${SHARPIE:-}" ]; then
    if [ -x ./sharpie.exe ]; then SHARPIE=./sharpie.exe
    elif [ -x ./sharpie ]; then SHARPIE=./sharpie
    else
        echo "no sharpie here; \`$WSHARP build src/main.ws -o sharpie\` first" >&2
        exit 2
    fi
fi
case "$SHARPIE" in
    /*|./*|../*) ;;
    *) SHARPIE="./$SHARPIE" ;;
esac
# The suffix every program in this test is spelled with, taken from the one
# name that is already known rather than from a guess about the platform --
# which is the question `toolchain.program` answers by looking, for the same
# reason.
case "$SHARPIE" in
    *.exe) EXE=.exe ;;
    *) EXE= ;;
esac
SHARPIE=$(CDPATH= cd -- "$(dirname -- "$SHARPIE")" && pwd)/$(basename "$SHARPIE")

# `sha256sum` on Linux and Windows, `shasum -a 256` on macOS. Both write
# `<hex>  <name>`, which is the whole of what `release.digest_of` reads.
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1"; }
else
    echo "no sha256sum and no shasum; cannot write a checksum sidecar" >&2
    exit 2
fi

# **Under the repository, not under `/tmp`, and a native path on Windows.**
# `/tmp` in Git Bash is an MSYS mount that resolves to the current drive's root,
# which need not exist -- `tests/io.ws` upstream learned that the hard way. And
# `$PWD` there is `/d/a/sharpie/sharpie`, which a native program reads as a path
# on whatever drive it happens to be on, so `pwd -W` is what sharpie can be
# handed.
native=$PWD
[ -z "$EXE" ] || native=$(pwd -W)

# One directory under two spellings, and the split is deliberate: `$mine` is how
# this shell reaches it and `$work` is how a native program reads it. They are
# the same string everywhere except Git Bash, where the first is `/d/a/...` and
# the second is `D:/a/...`. Anything handed to sharpie uses `$work`; every
# redirect, `mkdir` and `rm` in this file uses `$mine`.
mine="$root/.rungs"
work="$native/.rungs"
rm -rf "$mine"
mkdir -p "$work"

# The two sharpie reads, so both are `$work`. **Everything a shell tool is
# handed below is `$mine`**, and one of them is the reason the rule is written
# down: GNU tar reads `D:/a/x.tar.gz` as `host:path` and tries to reach a machine
# called `D`, so `-f` with the native spelling fails with
# `Cannot connect to D: resolve failed`. `tar --force-local` would silence that
# one; keeping the two spellings apart fixes the whole class.
export SHARPIE_HOME="$work/home"
export SHARPIE_RELEASE_DIR="$work/releases"
# The same directory as `$SHARPIE_RELEASE_DIR`, spelled for this shell.
releases="$mine/releases"
mkdir -p "$releases"
# Nothing here may read the machine's real installation, and nothing may inherit
# a toolchain from the environment that runs this.
unset SHARPIE_TOOLCHAIN || true

triple=$("$SHARPIE" show | awk -F'\t' '$1 == "target" { print $2 }')
[ -n "$triple" ] || { echo "sharpie will not say what it was built for" >&2; exit 2; }

bin="$SHARPIE_HOME/bin"

# ---------------------------------------------------------------------------
# The fixtures: a stub, and archives that hold it
# ---------------------------------------------------------------------------

# Built with `$work`, because `wsharp` is a native program; copied with `$mine`,
# because `cp` is not.
"$WSHARP" build tests/fixtures/toolchain-stub.ws -o "$work/toolchain-stub$EXE" >/dev/null
stub="$mine/toolchain-stub$EXE"

# One release archive, laid out exactly as `release.archive_name` spells it and
# with everything under one directory named for the version and the triple --
# which is the shape `install.write_all` strips a component off.
#
# `hold` is what goes in as `wsharp`: the stub for a version that is meant to be
# installed and run, and a line of text for the ones that exist only to fail --
# which keeps a fault-injection rung a few hundred bytes rather than a compiler.
archive() {
    version=$1
    hold=${2:-stub}
    name="wsharp-$version-$triple"
    stage="$mine/stage/$name"
    rm -rf "$mine/stage"
    mkdir -p "$stage"
    if [ "$hold" = "stub" ]; then
        cp "$stub" "$stage/wsharp$EXE"
    else
        printf 'not a compiler\n' > "$stage/wsharp$EXE"
    fi
    ( cd "$mine/stage" && tar -czf "$releases/$name.tar.gz" "$name" )
    sha256 "$releases/$name.tar.gz" > "$releases/$name.tar.gz.sha256"
    rm -rf "$mine/stage"
}

forget() {
    name="wsharp-$1-$triple"
    rm -f "$releases/$name.tar.gz" "$releases/$name.tar.gz.sha256"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

problems=""
note() { problems="$problems
    $1"; }

# Run sharpie somewhere, and keep what it said and how it ended.
#
# `where` and `env_line` are set by the caller. Every rung reads the working
# directory or the environment, so being able to vary both is the whole
# apparatus.
where=""
env_line=""
say() {
    where=${where:-$work}
    if [ -n "$env_line" ]; then
        # Unquoted on purpose: `env_line` is a list of assignments, not one
        # word. Nothing here puts a space in one.
        out=$(cd "$where" && env $env_line "$@" 2>&1) && status=0 || status=$?
    else
        out=$(cd "$where" && "$@" 2>&1) && status=0 || status=$?
    fi
    where=""
    env_line=""
}

sharpie() { say "$SHARPIE" "$@"; }

says() {
    case "$out" in
        *"$1"*) return 0 ;;
    esac
    note "expected to say: $1"
    note "  said: $(printf '%s' "$out" | tr '\n' '|')"
    return 1
}

denies() {
    case "$out" in
        *"$1"*)
            note "should not have said: $1"
            note "  said: $(printf '%s' "$out" | tr '\n' '|')"
            return 1 ;;
    esac
    return 0
}

exited() {
    if [ "$status" -eq "$1" ]; then return 0; fi
    note "exited $status, wanted $1"
    note "  said: $(printf '%s' "$out" | tr '\n' '|')"
    return 1
}

# `[ ... ] && { ...; }` is the shape this file deliberately never uses: under
# `set -e` an AND-OR list whose last command did not run still fails, so a false
# test would end the run rather than the rung. Everything below is `if`.
absent_dir() {
    if [ -d "$1" ]; then
        note "$1 is still there"
        return 1
    fi
    return 0
}

# **The assertion the criterion is about.** `sharpie show` prints
# `toolchain<TAB><name><TAB><why>`, and `why` is the rung of the ladder that
# answered. Asserting the name alone would pass for a ladder that always used the
# default, which is exactly the bug a resolution test exists to find.
attributed() {
    want_name=$1
    want_why=$2
    line=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "toolchain" { print $2 "\t" $3 }')
    got_name=$(printf '%s' "$line" | cut -f1)
    got_why=$(printf '%s' "$line" | cut -f2)
    ok=0
    [ "$got_name" = "$want_name" ] || { note "chose \`$got_name\`, wanted \`$want_name\`"; ok=1; }
    case "$got_why" in
        *"$want_why"*) ;;
        *) note "credited \`$got_why\`, wanted \`$want_why\`"; ok=1 ;;
    esac
    return $ok
}

# `show` somewhere, and what it named.
shown() {
    where=$1
    shift
    sharpie show
    attributed "$@"
}

full() { printf '%s-%s' "$1" "$triple"; }

# ---------------------------------------------------------------------------
# The rungs
# ---------------------------------------------------------------------------

# A fresh install: a home that does not exist, made and filled by `init` and
# `install`, and a default adopted because there was not one.
rung_fresh_install() {
    sharpie init
    exited 0 || return 1
    says "bin	$bin" || return 1
    [ -x "$bin/sharpie$EXE" ] || { note "no sharpie proxy at $bin"; return 1; }
    [ -x "$bin/wsharp$EXE" ] || { note "no wsharp proxy at $bin"; return 1; }
    [ -x "$bin/ingot$EXE" ] || { note "no ingot proxy at $bin"; return 1; }

    archive 0.9.0
    archive 0.9.1

    sharpie install 0.9.0
    exited 0 || return 1
    says "installed	$(full 0.9.0)" || return 1
    # Adopted, because a home with nothing in it has no default to displace.
    says "default	$(full 0.9.0)" || return 1

    shown "$work" "$(full 0.9.0)" "the default" || return 1

    # A toolchain is only installed if something in it can be run.
    sharpie which wsharp
    exited 0 || return 1
    says "toolchains/$(full 0.9.0)/wsharp" || return 1
    return 0
}

# An upgrade: a second toolchain arrives and does *not* quietly move anybody off
# the one they were using. Moving is a separate, named act.
rung_upgrade() {
    sharpie install 0.9.1
    exited 0 || return 1
    says "installed	$(full 0.9.1)" || return 1
    denies "default	$(full 0.9.1)" || return 1

    shown "$work" "$(full 0.9.0)" "the default" || return 1

    sharpie default 0.9.1
    exited 0 || return 1
    says "default	$(full 0.9.1)" || return 1
    shown "$work" "$(full 0.9.1)" "the default" || return 1

    # Both, and only both.
    sharpie toolchain list
    exited 0 || return 1
    says "installed	$(full 0.9.0)" || return 1
    says "installed	$(full 0.9.1)	default" || return 1
    return 0
}

# `+toolchain` in front of a proxied command: the top rung, and the only one
# that is spelled on the command line.
rung_plus_argument() {
    # The proxy really execs, and what it execs says where it is. The default is
    # 0.9.1, so naming 0.9.0 proves the argument was read rather than ignored.
    say "$bin/wsharp$EXE" +0.9.0 --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.0)/wsharp" || return 1
    # Forwarded untouched...
    says "arg	--version" || return 1
    # ...and the `+` eaten, because handing `+0.9.0` to a compiler is handing it
    # a file name it cannot open.
    denies "arg	+0.9.0" || return 1

    # And it can be explained without being run, which is what `show` is for.
    sharpie +0.9.0 show
    exited 0 || return 1
    attributed "$(full 0.9.0)" "the \`+\` argument" || return 1

    sharpie +0.9.0 which wsharp
    exited 0 || return 1
    says "toolchains/$(full 0.9.0)/wsharp" || return 1

    # A verb that cannot honour one refuses it rather than dropping it.
    sharpie +0.9.0 toolchain list
    exited 2 || return 1
    says "belongs in front of a proxied command" || return 1
    return 0
}

# `SHARPIE_TOOLCHAIN`: below the command line and above everything written down.
rung_sharpie_toolchain() {
    env_line="SHARPIE_TOOLCHAIN=0.9.0"
    sharpie show
    exited 0 || return 1
    attributed "$(full 0.9.0)" "SHARPIE_TOOLCHAIN" || return 1

    # The command line still wins.
    env_line="SHARPIE_TOOLCHAIN=0.9.0"
    sharpie +0.9.1 show
    exited 0 || return 1
    attributed "$(full 0.9.1)" "the \`+\` argument" || return 1

    # An empty value is not an answer, so the rung below it gets the question.
    env_line="SHARPIE_TOOLCHAIN="
    sharpie show
    exited 0 || return 1
    attributed "$(full 0.9.1)" "the default" || return 1

    # And it reaches a proxy, which is where it matters.
    env_line="SHARPIE_TOOLCHAIN=0.9.0"
    say "$bin/wsharp$EXE" --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.0)/wsharp" || return 1
    return 0
}

# `wsharp-toolchain.toml`, looked for from here upwards: a *project's* pin, which
# is what makes one file at the root of a tree cover every directory in it.
rung_pin_file() {
    proj="$work/project"
    deep="$proj/src/deep/deeper"
    mkdir -p "$mine/project/src/deep/deeper"
    printf 'toolchain = "0.9.0"\n' > "$mine/project/wsharp-toolchain.toml"

    shown "$deep" "$(full 0.9.0)" "wsharp-toolchain.toml" || return 1
    # At the root of the project as well as four directories down it.
    shown "$proj" "$(full 0.9.0)" "wsharp-toolchain.toml" || return 1
    # And nowhere outside it.
    shown "$work" "$(full 0.9.1)" "the default" || return 1

    # The other spelling, which is `rust-toolchain.toml`'s.
    printf '[toolchain]\nchannel = "0.9.1"\n' > "$mine/project/wsharp-toolchain.toml"
    shown "$deep" "$(full 0.9.1)" "wsharp-toolchain.toml" || return 1
    printf 'toolchain = "0.9.0"\n' > "$mine/project/wsharp-toolchain.toml"

    # The environment beats a project's file, which is how somebody tries a
    # different compiler on a tree without editing it.
    where=$deep
    env_line="SHARPIE_TOOLCHAIN=0.9.1"
    sharpie show
    exited 0 || return 1
    attributed "$(full 0.9.1)" "SHARPIE_TOOLCHAIN" || return 1

    # A nearer file wins, because the walk stops at the first one it meets.
    printf 'toolchain = "0.9.1"\n' > "$mine/project/src/wsharp-toolchain.toml"
    shown "$deep" "$(full 0.9.1)" "wsharp-toolchain.toml" || return 1
    rm -f "$mine/project/src/wsharp-toolchain.toml"
    return 0
}

# A directory override: written down in `settings.toml` rather than in the tree,
# and below a file in the tree for that reason.
rung_directory_override() {
    over="$work/elsewhere"
    mkdir -p "$mine/elsewhere"

    where=$over
    sharpie override set 0.9.0
    exited 0 || return 1
    says "override	$over	$(full 0.9.0)" || return 1

    shown "$over" "$(full 0.9.0)" "a directory override" || return 1
    # Only there.
    shown "$work" "$(full 0.9.1)" "the default" || return 1

    # A project's own file beats an override on the same directory, which is the
    # rung order the ladder promises.
    proj="$work/project"
    where=$proj
    sharpie override set 0.9.1
    exited 0 || return 1
    shown "$proj" "$(full 0.9.0)" "wsharp-toolchain.toml" || return 1
    where=$proj
    sharpie override unset
    exited 0 || return 1

    sharpie override list
    exited 0 || return 1
    says "override	$over	$(full 0.9.0)" || return 1
    denies "$(full 0.9.1)" || return 1
    return 0
}

# The default: the bottom rung, and the one every other rung has been beating.
rung_the_default() {
    shown "$work" "$(full 0.9.1)" "the default" || return 1

    sharpie which wsharp
    exited 0 || return 1
    says "toolchains/$(full 0.9.1)/wsharp" || return 1

    say "$bin/wsharp$EXE" --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.1)/wsharp" || return 1
    return 0
}

# `update` follows a channel, and leaves a pin alone.
#
# Two halves, and the second is the one worth having: somebody who asked for
# `0.9.0` asked for `0.9.0`, and a project that pinned one pinned it.
rung_channel_update() {
    # Nothing was installed from a channel yet -- both installs above named a
    # version, and `sharpie default` pinned the second -- so there is nothing
    # standing to re-ask.
    sharpie update
    exited 1 || return 1
    says "the default follows no channel" || return 1

    # `stable` is the newest release that is not a prerelease, which is 0.9.1
    # and is already here. The channel is recorded anyway, which is the whole
    # point of `adopt` saving either way.
    sharpie install stable
    exited 0 || return 1
    says "already	$(full 0.9.1)" || return 1

    # Nothing new published, so nothing to do and the default stays.
    sharpie update
    exited 0 || return 1
    says "current	stable	$(full 0.9.1)" || return 1

    # Now the channel moves.
    archive 0.9.2
    sharpie update
    exited 0 || return 1
    says "installed	$(full 0.9.2)" || return 1
    says "default	$(full 0.9.2)" || return 1
    shown "$work" "$(full 0.9.2)" "the default" || return 1

    # **And the project that pinned 0.9.0 is still on 0.9.0.** A channel is a
    # standing request about the *default*; a pin is a statement about a tree.
    shown "$work/project/src/deep/deeper" "$(full 0.9.0)" "wsharp-toolchain.toml" || return 1
    shown "$work/elsewhere" "$(full 0.9.0)" "a directory override" || return 1

    # **Following is where the default goes, not whether something was
    # fetched.** The channel's newest may already be here, installed by its
    # number -- which leaves the default alone, as any install does -- and
    # `update` still moves the default on to it. It used to print `current`
    # and leave the default on the release before.
    archive 0.9.6
    sharpie install 0.9.6
    exited 0 || return 1
    says "installed	$(full 0.9.6)" || return 1
    denies "default	" || return 1
    shown "$work" "$(full 0.9.2)" "the default" || return 1

    sharpie update
    exited 0 || return 1
    says "current	stable	$(full 0.9.6)" || return 1
    says "default	$(full 0.9.6)" || return 1
    shown "$work" "$(full 0.9.6)" "the default" || return 1
    return 0
}

# Rollback: `sharpie default <previous>`, and no new verb for it.
#
# Johnny's ruling, and it is the right one: every toolchain an update installed
# is still on disk under its own name, so going back is choosing one of them --
# which the verb that chooses one already does.
rung_rollback() {
    sharpie default 0.9.1
    exited 0 || return 1
    says "default	$(full 0.9.1)" || return 1
    shown "$work" "$(full 0.9.1)" "the default" || return 1

    say "$bin/wsharp$EXE" --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.1)/wsharp" || return 1

    # The one it rolled back from is still installed, which is what made the
    # rollback possible and what makes rolling forward again the same act.
    sharpie toolchain list
    exited 0 || return 1
    says "installed	$(full 0.9.2)" || return 1
    says "installed	$(full 0.9.6)" || return 1

    # **And it survives the next `update`,** with the channel moving on in the
    # meantime. A default chosen by name is pinned, so `update` has nothing to
    # follow and says so; the release it would have moved to is not fetched.
    # This used to install 0.9.7 and make it the default, undoing the rollback
    # the first time anybody ran the verb that is supposed to be safe to run.
    archive 0.9.7
    sharpie update
    exited 1 || return 1
    says "the default follows no channel" || return 1
    denies "default	" || return 1
    shown "$work" "$(full 0.9.1)" "the default" || return 1
    absent_dir "$mine/home/toolchains/$(full 0.9.7)" || return 1
    say "$bin/wsharp$EXE" --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.1)/wsharp" || return 1
    forget 0.9.7

    # There is no `rollback`, and the message says what there is.
    sharpie rollback
    exited 2 || return 1
    says "no such verb: \`rollback\`" || return 1
    return 0
}

# Uninstall, including the case that leaves nothing runnable -- which is said at
# the moment it is caused rather than left for the next command to discover.
rung_uninstall() {
    sharpie uninstall 0.9.2
    exited 0 || return 1
    says "removed	$(full 0.9.2)" || return 1
    denies "warning" || return 1

    sharpie toolchain list
    exited 0 || return 1
    denies "installed	$(full 0.9.2)" || return 1

    # Gone from the disk, not merely from the listing.
    absent_dir "$mine/home/toolchains/$(full 0.9.2)" || return 1

    # Removing the default is allowed and is *reported*, and the settings are
    # deliberately not rewritten: picking a replacement is a choice.
    sharpie uninstall 0.9.1
    exited 0 || return 1
    says "removed	$(full 0.9.1)" || return 1
    says "warning	that was the default" || return 1

    sharpie show
    exited 1 || return 1
    says "is not installed (the default)" || return 1

    # Something that is not installed cannot become the default either.
    sharpie default 0.9.1
    exited 2 || return 1
    says "is not installed" || return 1

    # Put the home back on its feet for the rungs below, which are about what
    # survives a failed install.
    sharpie default 0.9.0
    exited 0 || return 1
    shown "$work" "$(full 0.9.0)" "the default" || return 1
    return 0
}

# A rung that names a toolchain which is not installed **refuses**, rather than
# falling through to the rung below it.
#
# Falling through is the tempting behaviour and the wrong one: a pin file exists
# to say "this tree needs this compiler", and quietly building it with a
# different one is worse than not building it.
rung_refuses_the_missing() {
    for rung in argument environment pin override; do
        case $rung in
            argument)
                sharpie +9.9.9 show
                why="the \`+\` argument" ;;
            environment)
                env_line="SHARPIE_TOOLCHAIN=9.9.9"
                sharpie show
                why="SHARPIE_TOOLCHAIN" ;;
            pin)
                gone="$work/gone"
                mkdir -p "$mine/gone"
                printf 'toolchain = "9.9.9"\n' > "$mine/gone/wsharp-toolchain.toml"
                where=$gone
                sharpie show
                why="wsharp-toolchain.toml" ;;
            override)
                spot="$work/spot"
                mkdir -p "$mine/spot"
                # Written by hand, because `override set` refuses a name that is
                # not installed -- which is the earlier half of the same rule.
                printf '\n[[override]]\npath = "%s"\ntoolchain = "9.9.9"\n' "$spot" \
                    >> "$mine/home/settings.toml"
                where=$spot
                sharpie show
                why="a directory override" ;;
        esac
        exited 1 || return 1
        says "\`9.9.9\` is not installed ($why)" || return 1
        # Not the default, which is installed and would have run.
        denies "$(full 0.9.0)	" || return 1
    done

    # `override set` refuses it up front rather than writing a setting every
    # later command would trip over.
    where="$work/spot2"
    mkdir -p "$mine/spot2"
    sharpie override set 9.9.9
    exited 2 || return 1
    says "is not installed" || return 1

    # And a proxy refuses to run anything at all, rather than running the
    # default's compiler under a name it was told not to use.
    env_line="SHARPIE_TOOLCHAIN=9.9.9"
    say "$bin/wsharp$EXE" --version
    if [ "$status" -eq 0 ]; then
        note "the proxy ran something"
        return 1
    fi
    says "\`9.9.9\` is not installed (SHARPIE_TOOLCHAIN)" || return 1
    denies "toolchains/$(full 0.9.0)" || return 1
    return 0
}

# A rung naming a *path* refuses too, and so does every verb that takes a
# toolchain.
#
# The ladder is where the danger comes from: a `wsharp-toolchain.toml` in a
# repository somebody has just cloned is a file a stranger wrote, and a name used
# to be joined on to `toolchains/` as it came -- so `../../trap`, or an absolute
# path, was a toolchain wherever it pointed, `show` called it an ordinary pin, and
# the proxy ran whatever was there. The verbs are where it cost data: `uninstall`
# renamed the path into `tmp/` and deleted it, and `uninstall ""` deleted
# `toolchains/` itself.
#
# `trap` holds a working stub, so each refusal below had something runnable on
# the far side of it; and the default is installed, so falling through would have
# found something too.
rung_refuses_a_path() {
    mkdir -p "$mine/trap"
    cp "$stub" "$mine/trap/wsharp$EXE"
    # Relative to `$SHARPIE_HOME/toolchains`, which is what a name is joined on to.
    up="../../trap"

    for rung in argument environment pin absolute override default; do
        named=$up
        case $rung in
            argument)
                sharpie "+$up" show
                why="the \`+\` argument" ;;
            environment)
                env_line="SHARPIE_TOOLCHAIN=$up"
                sharpie show
                why="SHARPIE_TOOLCHAIN" ;;
            pin)
                mkdir -p "$mine/cloned"
                printf 'toolchain = "%s"\n' "$up" > "$mine/cloned/wsharp-toolchain.toml"
                where="$work/cloned"
                sharpie show
                why="wsharp-toolchain.toml" ;;
            absolute)
                named="$work/trap"
                printf 'toolchain = "%s"\n' "$named" > "$mine/cloned/wsharp-toolchain.toml"
                where="$work/cloned"
                sharpie show
                why="wsharp-toolchain.toml" ;;
            override)
                mkdir -p "$mine/spot3"
                # By hand, because `override set` refuses it -- which is below.
                printf '\n[[override]]\npath = "%s"\ntoolchain = "%s"\n' "$work/spot3" "$up" \
                    >> "$mine/home/settings.toml"
                where="$work/spot3"
                sharpie show
                why="a directory override" ;;
            default)
                # Rewritten rather than appended, because a second `default`
                # key is a TOML error and would test the parser instead.
                cp "$mine/home/settings.toml" "$mine/settings.keep"
                sed "s|^default = .*|default = \"$up\"|" "$mine/settings.keep" \
                    > "$mine/home/settings.toml"
                sharpie show
                cp "$mine/settings.keep" "$mine/home/settings.toml"
                why="the default" ;;
        esac
        exited 1 || return 1
        says "\`$named\` is not a toolchain name ($why)" || return 1
        # `directory` is printed only for something chosen.
        denies "directory	" || return 1
    done

    # The attack itself: a proxied command run inside the cloned tree.
    printf 'toolchain = "%s"\n' "$up" > "$mine/cloned/wsharp-toolchain.toml"
    where="$work/cloned"
    say "$bin/wsharp$EXE" build x.ws
    if [ "$status" -eq 0 ]; then
        note "the proxy ran something"
        return 1
    fi
    says "is not a toolchain name (wsharp-toolchain.toml)" || return 1
    denies "trap/wsharp" || return 1

    # Every verb that takes a toolchain refuses one that is a path, and says so
    # in the same words.
    sharpie default "$up"
    exited 2 || return 1
    says "\`$up\` is not a toolchain name" || return 1
    sharpie default "$work/trap"
    exited 2 || return 1
    says "is not a toolchain name" || return 1
    shown "$work" "$(full 0.9.0)" "the default" || return 1

    where="$work/spot3"
    sharpie override set "$up"
    exited 2 || return 1
    says "is not a toolchain name" || return 1

    sharpie toolchain link "$up" "$work/trap"
    exited 2 || return 1
    says "is not a toolchain name" || return 1

    sharpie install "$up"
    exited 2 || return 1
    says "is not a toolchain name" || return 1

    # And the one that deletes: nothing it was pointed at is gone afterwards.
    sharpie uninstall "$up"
    exited 2 || return 1
    says "is not a toolchain name" || return 1
    sharpie uninstall "$work/trap"
    exited 2 || return 1
    says "is not a toolchain name" || return 1
    [ -x "$mine/trap/wsharp$EXE" ] || { note "uninstall deleted $mine/trap"; return 1; }
    sharpie uninstall ""
    exited 2 || return 1
    says "is not a toolchain name" || return 1
    [ -d "$mine/home/toolchains/$(full 0.9.0)" ] || { note "uninstall \"\" deleted toolchains/"; return 1; }

    sharpie override unset "$work/spot3"
    exited 0 || return 1
    rm -rf "$mine/trap" "$mine/cloned" "$mine/settings.keep"
    return 0
}

# Fault injection one: a download that arrives short.
#
# On the wire this is a connection that closed early. Here the archive in the
# release directory is cut off with its published digest left alone, which is the
# same bytes arriving at `release.verified` -- and the same refusal.
rung_truncated_download() {
    archive 0.9.3 paper
    name="wsharp-0.9.3-$triple"
    whole="$releases/$name.tar.gz"
    # Half of it, rounded down, and never zero: an empty file is a different
    # failure and gets its own rung below.
    size=$(wc -c < "$whole" | tr -d ' ')
    dd if="$whole" of="$whole.part" bs=1 count=$((size / 2)) 2>/dev/null
    mv "$whole.part" "$whole"

    sharpie install 0.9.3
    exited 2 || return 1
    says "what was downloaded is not what was published" || return 1
    survived 0.9.3 || return 1

    # A truncated *sidecar* is the other half of the same accident, and it is
    # what `digest_of`'s length-and-hex check was written for: a short digest
    # compared happily against a short hash would accept anything.
    printf '2efc18e07a58' > "$releases/$name.tar.gz.sha256"
    sharpie install 0.9.3
    exited 2 || return 1
    says "the published checksum is not a digest" || return 1
    survived 0.9.3 || return 1

    forget 0.9.3
    return 0
}

# Fault injection two: a complete archive that is not the published one.
#
# The digest is a well-formed digest and simply names something else, which is
# what a substituted or corrupted-in-transit archive looks like. Distinct from
# the rung above in what reaches the checker, identical in what must not happen.
rung_digest_mismatch() {
    archive 0.9.4 paper
    name="wsharp-0.9.4-$triple"
    printf '%s  %s\n' \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "$name.tar.gz" > "$releases/$name.tar.gz.sha256"

    sharpie install 0.9.4
    exited 2 || return 1
    says "what was downloaded is not what was published" || return 1
    survived 0.9.4 || return 1

    # An archive replaced wholesale by something that is not even a gzip stream
    # still cannot get past the digest, which is the order `download` puts the
    # two checks in and the reason it does.
    printf 'this is not a tarball\n' > "$releases/$name.tar.gz"
    sharpie install 0.9.4
    exited 2 || return 1
    says "what was downloaded is not what was published" || return 1
    survived 0.9.4 || return 1

    forget 0.9.4
    return 0
}

# Fault injection three: an install that stops part way through the extraction.
#
# **Injected as an archive that cannot be written out, not as a signal.** A
# signal at an arbitrary instant is not a reproducible test -- what makes it one
# is that the extraction is *definitely* part way through when it stops, and this
# archive guarantees it: `wsharp` is written, then `lib` is written as a file,
# then `lib/extra` needs `lib` to be a directory and it is not. So `write_all`
# fails after having written real files, which is exactly the state an interrupt
# leaves, and the assertion is the same one: nothing under `toolchains/`, and the
# toolchain that was there still runs.
rung_interrupted_extract() {
    version=0.9.5
    name="wsharp-$version-$triple"
    a="$mine/stage-a/$name"
    b="$mine/stage-b/$name"
    rm -rf "$mine/stage-a" "$mine/stage-b"
    mkdir -p "$a" "$b/lib"
    printf 'not a compiler\n' > "$a/wsharp$EXE"
    printf 'and not a directory\n' > "$a/lib"
    printf 'so this cannot be written\n' > "$b/lib/extra"

    # Two source trees in one archive, because one filesystem cannot hold `lib`
    # as both. `tar` takes its arguments in order, which is what puts the file
    # before the thing that needs it to be a directory.
    tar -czf "$releases/$name.tar.gz" \
        -C "$mine/stage-a" "$name" \
        -C "$mine/stage-b" "$name/lib/extra"
    sha256 "$releases/$name.tar.gz" > "$releases/$name.tar.gz.sha256"

    # The order is the whole fixture, so it is asserted rather than assumed: a
    # `tar` that sorted its members would make this rung pass for no reason.
    members=$(tar -tzf "$releases/$name.tar.gz")
    first=$(printf '%s\n' "$members" | grep -n "^$name/lib\$" | head -1 | cut -d: -f1)
    second=$(printf '%s\n' "$members" | grep -n "^$name/lib/extra\$" | head -1 | cut -d: -f1)
    if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
        note "this tar did not write the members in the order the fixture needs"
        note "  members: $(printf '%s' "$members" | tr '\n' ' ')"
        return 1
    fi

    sharpie install "$version"
    exited 2 || return 1
    # Whichever of the two filesystem calls refuses first, it is a failure to
    # create or to write something under the staging tree.
    says "cannot " || return 1
    survived "$version" || return 1

    # And the staging tree it was building was thrown away, so `tmp/` is not
    # collecting half-installed compilers.
    left=$(ls "$mine/home/tmp" 2>/dev/null | wc -l | tr -d ' ')
    [ "$left" = "0" ] || { note "$left directories left under tmp/"; return 1; }

    rm -rf "$mine/stage-a" "$mine/stage-b"
    forget "$version"
    return 0
}

# What every fault injection has to leave behind: nothing new, and everything
# that was working still working.
survived() {
    # `broken` rather than `failed`: a shell has one namespace, and the driver
    # below accumulates the rungs that failed in a variable of that name.
    broken=$1
    sharpie toolchain list
    exited 0 || return 1
    denies "$(full "$broken")" || return 1
    absent_dir "$mine/home/toolchains/$(full "$broken")" || return 1

    shown "$work" "$(full 0.9.0)" "the default" || return 1
    say "$bin/wsharp$EXE" --version
    exited 0 || return 1
    says "toolchains/$(full 0.9.0)/wsharp" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Drive them
# ---------------------------------------------------------------------------

# In order, because the state each leaves is what the next one is about: a home
# that has just been installed into, then upgraded, then updated along a channel,
# then rolled back, then emptied, then failed into.
rungs="fresh_install:a fresh install
upgrade:an upgrade
plus_argument:\`+toolchain\` on a proxied command
sharpie_toolchain:SHARPIE_TOOLCHAIN
pin_file:a wsharp-toolchain.toml found by walking upwards
directory_override:a directory override
the_default:the default
channel_update:update follows a channel and leaves a pin alone
rollback:rollback is \`sharpie default <previous>\`
uninstall:uninstall
refuses_the_missing:a rung naming what is not installed refuses
refuses_a_path:a rung or a verb naming a path refuses
truncated_download:a truncated download
digest_mismatch:a digest mismatch
interrupted_extract:an install interrupted mid-extract"

pass=0
fail=0
failed=""

printf 'sharpie %s on %s\n\n' "$("$SHARPIE" version | cut -d' ' -f2)" "$triple"

# Walked with the shell's own field splitting rather than with `read` in a
# pipeline, which runs in a subshell on some shells and would lose the counters.
# One rung a line, and a newline is the separator.
old_ifs=$IFS
IFS='
'
for row in $rungs; do
    IFS=$old_ifs
    fn=${row%%:*}
    label=${row#*:}
    problems=""
    if rung_"$fn"; then
        pass=$((pass + 1))
        printf '%s ... ok\n' "$label"
    else
        fail=$((fail + 1))
        failed="$failed
    $label"
        printf '%s ... FAILED%s\n' "$label" "$problems"
    fi
    IFS='
'
done
IFS=$old_ifs

printf '\n%s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    printf 'failed:%s\n' "$failed"
    exit 1
fi

# Only on the way out, and only when everything passed: a failure's home is the
# most useful thing left to look at.
rm -rf "$mine"
