#!/bin/sh
# Get sharpie onto a machine that has nothing.
#
# This is the one piece that cannot be written in W#, and the reason is the
# whole bootstrap: it runs *before* there is a W# toolchain to run anything
# else with. So it is POSIX shell, it assumes only `uname`, `tar` and one of
# `curl`/`wget`, and it does exactly as much as it must -- work out which
# build belongs to this machine, fetch it, check it, and hand over to sharpie
# for everything after that.
#
#   curl -fsSL https://raw.githubusercontent.com/sinisterMage/sharpie/main/install.sh | sh
#
# `SHARPIE_HOME` says where to install; `SHARPIE_VERSION` pins a version rather
# than taking the newest.
set -eu

REPO=${SHARPIE_REPO:-sinisterMage/sharpie}
HOME_DIR=${SHARPIE_HOME:-${HOME}/.sharpie}

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Which build belongs here
# ---------------------------------------------------------------------------
#
# The same triples the release workflow builds, spelled the way cargo spells
# them -- `sharpie` itself answers with `os.target()`, and the two have to
# agree or an installed sharpie would look for a different archive than the one
# that installed it.
detect_triple() {
    kernel=$(uname -s)
    machine=$(uname -m)
    case "$machine" in
        x86_64 | amd64) arch=x86_64 ;;
        arm64 | aarch64) arch=aarch64 ;;
        *) die "no build for $machine" ;;
    esac
    case "$kernel" in
        Linux) echo "${arch}-unknown-linux-gnu" ;;
        Darwin) echo "${arch}-apple-darwin" ;;
        # Git Bash and MSYS report these. Windows is x86_64 only for now.
        MINGW* | MSYS* | CYGWIN*) echo "x86_64-pc-windows-msvc" ;;
        *) die "no build for $kernel" ;;
    esac
}

# `curl` or `wget`, whichever is here. Both are told to fail loudly on an HTTP
# error rather than writing the error page to the file, which is the failure
# mode that produces a "corrupt archive" three steps later.
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget is here"
    fi
}

# ---------------------------------------------------------------------------
# What to install
# ---------------------------------------------------------------------------

triple=$(detect_triple)

if [ "${SHARPIE_VERSION:-}" = "" ]; then
    # The newest release, asked for by following the `latest` redirect rather
    # than by reading the API: the answer is a URL with the tag in it, and a
    # URL needs no JSON parser. `-o /dev/null -w` prints where it landed.
    if command -v curl >/dev/null 2>&1; then
        latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest") || die "cannot ask for the latest release"
        version=${latest##*/tag/}
    else
        die "set SHARPIE_VERSION, or install curl"
    fi
    [ "$version" != "$latest" ] || die "cannot read a version out of $latest"
else
    version=$SHARPIE_VERSION
fi
version=${version#v}

stage="sharpie-${version}-${triple}"
base="https://github.com/${REPO}/releases/download/v${version}"

say "sharpie ${version} for ${triple}"

# ---------------------------------------------------------------------------
# Fetch, check, unpack
# ---------------------------------------------------------------------------

work=$(mktemp -d)
# `trap` rather than a tidy-up at the end: this exits early in a dozen places
# and every one of them should leave nothing behind.
trap 'rm -rf "$work"' EXIT INT TERM

fetch "${base}/${stage}.tar.gz" "${work}/${stage}.tar.gz"
fetch "${base}/${stage}.tar.gz.sha256" "${work}/${stage}.tar.gz.sha256"

# The published digest is the first field; the name beside it is whatever the
# machine that wrote it called the file, which is not necessarily where it has
# been put here.
want=$(cut -d' ' -f1 < "${work}/${stage}.tar.gz.sha256")
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "${work}/${stage}.tar.gz" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "${work}/${stage}.tar.gz" | cut -d' ' -f1)
else
    die "neither sha256sum nor shasum is here, and an unchecked download is not worth having"
fi
[ "$want" = "$got" ] || die "what was downloaded is not what was published"

tar -xzf "${work}/${stage}.tar.gz" -C "$work"

mkdir -p "${HOME_DIR}/bin"
# One binary. `sharpie init` makes the proxies out of it, because deciding what
# to proxy is sharpie's business and not this script's.
cp "${work}/${stage}/sharpie" "${HOME_DIR}/bin/sharpie"
chmod 0755 "${HOME_DIR}/bin/sharpie"

"${HOME_DIR}/bin/sharpie" init

say ""
say "Add this to your shell's profile:"
say ""
say "    export PATH=\"${HOME_DIR}/bin:\$PATH\""
say ""
say "Then \`sharpie install stable\` gets a W# toolchain."
