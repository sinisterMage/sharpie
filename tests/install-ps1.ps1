# `install.ps1`, run offline, and an upgrade through it cut short part way.
#
# The PowerShell half of `rung_self_upgrade` in `rungs.sh`, and the same three
# steps: a first install, an upgrade whose copy stops half way, and an upgrade
# that does not. After each, `bin\sharpie.exe` has to be the whole binary --
# compared by its bytes, because half of this binary still answers `version`.
# `install.ps1` used to `Copy-Item -Force` the new binary on to the old one, so
# a copy that stopped part way left half a binary under the one name every proxy
# is made from.
#
# **Offline, and with the interruption injected**, for the reason `rungs.sh`
# gives. A function takes precedence over a cmdlet of the same name, and a
# script sees the functions of the scope that ran it -- so `Invoke-WebRequest`
# here answers from a directory, and for the middle step `Copy-Item` writes the
# first half of the file and throws, which is what a real interruption leaves.
#
#   powershell -File tests/install-ps1.ps1 -Sharpie .\sharpie.exe
#
# CI runs it under Windows PowerShell 5.1, the oldest `install.ps1` promises to
# run on. It also runs under PowerShell 7 on Linux, which is how it can be
# checked on a machine with no Windows: the binary is then a Linux one wearing
# `.exe`, which sharpie takes off its own name anyway.
param([Parameter(Mandatory = $true)] [string] $Sharpie)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows' own `tar` first, as on the machine `install.ps1` is for. A runner
# with Git on `PATH` may otherwise find GNU tar, which reads `C:\...` as a host
# called `C` -- the trap `rungs.sh` describes, met here from the other side.
if ($env:SystemRoot) {
    $env:Path = (Join-Path $env:SystemRoot 'System32') + [System.IO.Path]::PathSeparator + $env:Path
}

$root = Split-Path -Parent $PSScriptRoot
$Sharpie = (Resolve-Path -LiteralPath $Sharpie).ProviderPath
$version = '9.8.7'
# What `install.ps1` makes of an x86_64 machine. Set where it is missing, which
# is only ever off Windows.
if (-not $env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE = 'AMD64' }
$triple = 'x86_64-pc-windows-msvc'
$name = "sharpie-$version-$triple"

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("sharpie-ps1-" + [System.Guid]::NewGuid().ToString('N'))
$shelf = Join-Path $scratch 'shelf'
$stage = Join-Path $scratch 'stage'
$sharpieHome = Join-Path $scratch 'home'
$bin = Join-Path $sharpieHome 'bin'
New-Item -ItemType Directory -Force -Path (Join-Path $stage $name), $shelf | Out-Null

# A release of the sharpie under test, laid out as the release workflow lays
# one out, with the digest beside it.
Copy-Item -LiteralPath $Sharpie -Destination (Join-Path (Join-Path $stage $name) 'sharpie.exe')
$archive = Join-Path $shelf "$name.tar.gz"
tar -czf $archive -C $stage $name
if ($LASTEXITCODE -ne 0) { throw "cannot build $archive" }
$digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLower()
[System.IO.File]::WriteAllText("$archive.sha256", "$digest  $name.tar.gz`n")

$want = (Get-FileHash -Algorithm SHA256 -LiteralPath $Sharpie).Hash

# The network, answered from the shelf by the last component of the URL.
function Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
    $file = Join-Path $shelf $Uri.Substring($Uri.LastIndexOf('/') + 1)
    if (-not (Test-Path -LiteralPath $file)) { throw "404: $Uri" }
    [System.IO.File]::Copy($file, $OutFile, $true)
}

# A copy that stops half way. Defined only for the step that wants it.
function Copy-Short {
    param([string] $Path, [string] $LiteralPath, [string] $Destination, [switch] $Force)
    $from = $LiteralPath
    if (-not $from) { $from = $Path }
    $resolve = $ExecutionContext.SessionState.Path
    $whole = [System.IO.File]::ReadAllBytes($resolve.GetUnresolvedProviderPathFromPSPath($from))
    $half = New-Object byte[] ([int][Math]::Floor($whole.Length / 2))
    [System.Array]::Copy($whole, $half, $half.Length)
    [System.IO.File]::WriteAllBytes($resolve.GetUnresolvedProviderPathFromPSPath($Destination), $half)
    throw 'the copy was cut short'
}

$env:SHARPIE_HOME = $sharpieHome
$env:SHARPIE_VERSION = $version

$failed = 0
function Check($label, [bool] $ok, $detail) {
    if ($ok) {
        Write-Output "$label ... ok"
    } else {
        Write-Output "$label ... FAILED"
        if ($detail) { Write-Output "    $detail" }
        $script:failed += 1
    }
}

# Whether the install ran to the end, rather than throwing on the way.
#
# Through `Invoke-Expression`, which is how the README runs it -- `irm ... |
# iex` -- and which no execution policy stands in front of.
function Installed {
    try {
        Invoke-Expression ([System.IO.File]::ReadAllText((Join-Path $root 'install.ps1'))) *> $null
        return $true
    } catch {
        return $false
    }
}

# Whether `bin\sharpie.exe` is the whole binary.
function Whole {
    $at = Join-Path $bin 'sharpie.exe'
    if (-not (Test-Path -LiteralPath $at)) { return 'bin holds no sharpie.exe' }
    $got = Get-Item -LiteralPath $at
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $at).Hash -ne $want) {
        return "bin\sharpie.exe is not the binary that was installed: $($got.Length) of $((Get-Item -LiteralPath $Sharpie).Length) bytes"
    }
    return ''
}

try {
    $ok = Installed
    $why = Whole
    Check 'a first install' ($ok -and -not $why) $why

    Set-Item -Path function:Copy-Item -Value ${function:Copy-Short}
    $ok = Installed
    Remove-Item -Path function:Copy-Item
    $why = Whole
    # Nothing staged left beside it: only `sharpie.exe` and the `.old` that
    # Windows' own `init` leaves when it could not replace a running proxy.
    # `-like` rather than `-Filter`, whose Win32 wildcards let `sharpie.exe.*`
    # match `sharpie.exe` itself.
    $stray = @(Get-ChildItem -LiteralPath $bin | Where-Object {
        $_.Name -like 'sharpie.exe.*' -and $_.Name -ne 'sharpie.exe.old'
    })
    if (-not $why -and $stray.Count -gt 0) { $why = "left in bin: $($stray.Name -join ' ')" }
    if ($ok) { $why = 'install.ps1 succeeded with its copy cut short' }
    Check 'an upgrade cut short leaves the sharpie that was there' (-not $why) $why

    $ok = Installed
    $why = Whole
    Check 'an upgrade over it' ($ok -and -not $why) $why
} finally {
    Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Output "$failed failed"
    exit 1
}
Write-Output 'all passed'
