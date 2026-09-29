# Get sharpie onto a Windows machine that has nothing.
#
# `install.sh` is the same script for everything else, and it runs here too --
# under Git Bash or MSYS, which is what a developer machine usually has. This
# one is for the machine that has neither: PowerShell, `tar` and nothing else
# that had to be installed first. It does exactly as much as it must -- work out
# which build belongs here, fetch it, check it, and hand over to sharpie for
# everything after that.
#
#   irm https://raw.githubusercontent.com/sinisterMage/sharpie/main/install.ps1 | iex
#
# `SHARPIE_HOME` says where to install; `SHARPIE_VERSION` pins a version rather
# than taking the newest. Environment variables and not parameters, because
# `iex` has no way to pass one -- and because `install.sh` reads the same three,
# and two installers for one program should not be configured two ways.
#
# Everything is inside a script block on purpose. Piped into `iex` this runs in
# the caller's own session, so a bare `$ErrorActionPreference = 'Stop'` and the
# functions below would stay behind in it after the install finished. A block
# has a scope of its own and leaves nothing.
& {
    $ErrorActionPreference = 'Stop'
    # Windows PowerShell draws a progress bar for every `Invoke-WebRequest`, and
    # redrawing it per chunk costs more than the download does -- a ten-megabyte
    # file takes minutes with it and seconds without.
    $ProgressPreference = 'SilentlyContinue'

    function Say($message) { Write-Host $message }

    # `throw`, and never `exit`. Run the advertised way this is inside the
    # user's own session, where `exit` closes their window -- so a machine with
    # no build for it would take the terminal with it. What is thrown is caught
    # at the bottom and written out as one line on standard error, which is
    # where `install.sh` puts the same sentence.
    function Die($message) { throw $message }

    # `GET url` into a file, answering whether it worked rather than stopping.
    #
    # `Invoke-WebRequest` raises on an HTTP error rather than writing the error
    # page to the file, which is what matters -- writing it is the failure mode
    # that produces a "corrupt archive" three steps later. What it raises is not
    # worth showing, though: both callers below know what a missing file means
    # there and say so better than a 404 can.
    function Get-Url($url, $into) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $into -UseBasicParsing
            return $true
        } catch {
            return $false
        }
    }

    # Move `$staged` on to `$at`, whatever is there already.
    #
    # `ReplaceFile` when there is something to replace: one call, and the name
    # holds the old binary until it holds the new one. It needs the destination
    # to exist, so a first install is a plain `Move`, and neither can cross a
    # volume, which is why the staged file sits beside its name.
    #
    # **A running image can be renamed but not replaced**, so if `sharpie.exe`
    # is in use the replace is refused. Then the old file moves aside to
    # `sharpie.exe.old` and the new one takes the name -- `init`'s answer to the
    # same rule, and the same leftover, which the next `init` clears.
    function Publish-Staged($staged, $at) {
        if (-not (Test-Path -LiteralPath $at)) {
            [System.IO.File]::Move($staged, $at)
            return
        }
        try {
            # `[NullString]::Value`, not `$null`: PowerShell hands a .NET
            # `string` parameter an empty string for `$null`, and an empty
            # backup name is refused where no backup is what was meant.
            [System.IO.File]::Replace($staged, $at, [NullString]::Value)
            return
        } catch {
            # Refused; the way round it is below.
        }
        $old = "$at.old"
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        [System.IO.File]::Move($at, $old)
        try {
            [System.IO.File]::Move($staged, $at)
        } catch {
            # Put the old one back: a failed upgrade leaves what was there.
            [System.IO.File]::Move($old, $at)
            throw
        }
    }

    try {
        $repo = if ($env:SHARPIE_REPO) { $env:SHARPIE_REPO } else { 'sinisterMage/sharpie' }

        # **`$env:HOME` before `$env:USERPROFILE`, and not PowerShell's
        # `$HOME`.** This has to land on the same directory `sharpie` will work
        # out for itself a moment later, because `init` is what makes the
        # proxies and it asks `os.home()` -- which tries `HOME` first and
        # `USERPROFILE` second. Every Git for Windows installation sets `HOME`,
        # so on a developer's machine PowerShell's `$HOME` and sharpie's answer
        # are not always the same directory, and this script would then put the
        # binary somewhere `init` never looked.
        $homeDir =
            if ($env:SHARPIE_HOME) { $env:SHARPIE_HOME }
            elseif ($env:HOME) { Join-Path $env:HOME '.sharpie' }
            elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.sharpie' }
            else { Die 'neither HOME nor USERPROFILE is set; set SHARPIE_HOME' }

        # Windows PowerShell defaults to whatever the .NET Framework was
        # configured for, which on an unpatched machine is TLS 1.0 -- and GitHub
        # answers that by closing the connection rather than with an error worth
        # reading. PowerShell 7 negotiates for itself and ignores this.
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {
            # A runtime that does not have the knob does not need it turned.
        }

        # -------------------------------------------------------------------
        # Which build belongs here
        # -------------------------------------------------------------------
        #
        # The triples are cargo's, because `sharpie` itself answers with
        # `os.target()` and the two have to agree -- an installed sharpie would
        # otherwise look for a different archive than the one that installed it.
        #
        # Not every triple named here is published: sharpie is built by
        # `wsharp`, so it exists where WSharp has been built, which on Windows
        # is x86_64. The others are named anyway rather than rejected here, for
        # `install.sh`'s reason -- the release either has the file or it does
        # not, and letting the download say so keeps one list instead of two
        # that can disagree.
        #
        # `PROCESSOR_ARCHITECTURE` is the architecture of *this process*, so a
        # 32-bit PowerShell on a 64-bit machine says `x86`. `ARCHITEW6432` is
        # what the machine is, and is set only in that case.
        $machine = $env:PROCESSOR_ARCHITEW6432
        if (-not $machine) { $machine = $env:PROCESSOR_ARCHITECTURE }
        $triple = switch ($machine) {
            'AMD64' { 'x86_64-pc-windows-msvc' }
            'ARM64' { 'aarch64-pc-windows-msvc' }
            'x86'   { 'i686-pc-windows-msvc' }
            default { Die "no build for $machine" }
        }

        # -------------------------------------------------------------------
        # What to install
        # -------------------------------------------------------------------

        if ($env:SHARPIE_VERSION) {
            $version = $env:SHARPIE_VERSION
        } else {
            # The newest release, asked for by following the `latest` redirect
            # rather than by reading the API: the answer is a URL with the tag
            # in it, and a URL needs no JSON parser -- and, unlike the API, no
            # rate limit that a shared address can already have spent.
            $latest = "https://github.com/$repo/releases/latest"
            try {
                $request = [System.Net.WebRequest]::Create($latest)
                $request.AllowAutoRedirect = $false
                $request.Method = 'HEAD'
                $request.UserAgent = 'sharpie-install'
                $response = $request.GetResponse()
                try {
                    $location = $response.Headers['Location']
                } finally {
                    $response.Dispose()
                }
            } catch {
                Die "cannot ask for the latest release: $($_.Exception.Message)"
            }
            if (-not $location) { Die "cannot ask for the latest release: $latest did not redirect" }
            $version = $location.Substring($location.LastIndexOf('/') + 1)
            if (-not $version -or $version -eq $location) {
                Die "cannot read a version out of $location"
            }
        }
        $version = $version -replace '^v', ''

        $stage = "sharpie-$version-$triple"
        $base = "https://github.com/$repo/releases/download/v$version"

        Say "sharpie $version for $triple"

        # `tar` is in Windows itself from Windows 10 1803, and unpacking a
        # `.tar.gz` is the one thing PowerShell cannot do on its own:
        # `Expand-Archive` reads zip and nothing else. The format is not
        # negotiable here -- it is what every other platform's release is, and
        # what sharpie itself reads when it goes and fetches a toolchain.
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            Die "no ``tar`` on PATH. Windows has shipped one since Windows 10 1803; on anything older, unpack $stage.tar.gz by hand from https://github.com/$repo/releases/tag/v$version"
        }

        # -------------------------------------------------------------------
        # Fetch, check, unpack
        # -------------------------------------------------------------------

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("sharpie-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        # `finally` rather than a tidy-up at the end: this leaves early in a
        # dozen places and every one of them should leave nothing behind.
        try {
            $archive = Join-Path $work "$stage.tar.gz"
            $sidecar = "$archive.sha256"

            # A missing archive is the one failure worth naming, because it is
            # the one a user can do nothing about, and the raw message for it --
            # a 404 out of `Invoke-WebRequest` -- reads like a broken script
            # rather than an unsupported machine.
            if (-not (Get-Url "$base/$stage.tar.gz" $archive)) {
                Die "no sharpie $version for $triple. Published builds are at https://github.com/$repo/releases/tag/v$version -- sharpie is built by ``wsharp``, so it exists for the platforms W# does."
            }
            if (-not (Get-Url "$base/$stage.tar.gz.sha256" $sidecar)) {
                Die "no published checksum for $stage.tar.gz, and an unchecked download is not worth having"
            }

            # The published digest is the first field. What comes after it is
            # whatever the machine that wrote it called the file -- and how: a
            # `sha256sum` run on Windows writes `<hex> *<name>`, with a star for
            # binary mode, where every other platform writes two spaces.
            # Splitting on whitespace and taking the first field reads both.
            $want = (Get-Content -Raw $sidecar).Trim() -split '\s+' | Select-Object -First 1
            $got = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash
            # `-ne` on strings ignores case, which is what is wanted here:
            # `Get-FileHash` answers in upper case and `sha256sum` writes lower.
            if ($want -ne $got) { Die 'what was downloaded is not what was published' }

            tar -xzf $archive -C $work
            if ($LASTEXITCODE -ne 0) { Die "cannot unpack $stage.tar.gz" }

            # `FullName`, because the .NET calls below resolve a relative path
            # against the process's directory rather than PowerShell's, and
            # `SHARPIE_HOME` may well be relative.
            $bin = (New-Item -ItemType Directory -Path (Join-Path $homeDir 'bin') -Force).FullName
            # One binary. `sharpie init` makes the proxies out of it, because
            # deciding what to proxy is sharpie's business and not this
            # script's.
            #
            # **Staged beside its name and swapped in, never copied over it.**
            # Running this again is how sharpie is upgraded, so `sharpie.exe`
            # is usually a working binary already, and `Copy-Item -Force` on to
            # it truncates it first -- a copy that stopped part way left half a
            # binary under the one name every proxy is made from. `install.sh`
            # and `init` both stage and rename, for the same reason.
            $installed = Join-Path $bin 'sharpie.exe'
            $staged = "$installed." + [System.Guid]::NewGuid().ToString('N')
            try {
                Copy-Item -LiteralPath (Join-Path $work "$stage\sharpie.exe") -Destination $staged
                Publish-Staged $staged $installed
            } catch {
                Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
                Die "cannot put sharpie at ${installed}: $($_.Exception.Message)"
            }

            & $installed init
            if ($LASTEXITCODE -ne 0) { Die '`sharpie init` failed' }
        } finally {
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }

        # Said rather than done. Rewriting a user's `Path` is a change to their
        # account that outlives this install and that nothing here would undo,
        # so it is left as one line they can read before running -- which is
        # what `install.sh` does with a shell profile, for the same reason.
        Say ''
        Say 'Add this to your PATH for this session:'
        Say ''
        Say "    `$env:Path = `"$bin;`$env:Path`""
        Say ''
        Say 'and once, to keep it:'
        Say ''
        Say "    [Environment]::SetEnvironmentVariable('Path', `"$bin;`" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"
        Say ''
        # Single-quoted, so a backtick is a backtick. The two Die messages
        # above are double-quoted and spell the same character ` `` `.
        Say 'Then `sharpie install stable` gets a W# toolchain.'
    } catch {
        # One line, on standard error, and then a short stop. Letting the
        # exception out unhandled would print the same sentence through
        # PowerShell's renderer, which folds it into a wrapped paragraph with a
        # stack frame in front of it -- and the sentence is the whole point.
        [Console]::Error.WriteLine("install.ps1: " + $_.Exception.Message)
        throw 'sharpie was not installed'
    }
}
