# Builds priv/ezstd_nif.dll on Windows with Zig (https://ziglang.org), which carries its
# own C/C++ toolchain and the mingw-w64 headers, so nothing else has to be installed:
# no Visual Studio, no MSYS2. rebar.config runs this as the `win32` compile hook, the
# way `make compile_nif` runs on Linux and macOS.
#
# zstd itself is fetched at the commit `ZSTD_SHA` in build_deps.sh names (one pin for
# every platform) and compiled from source into the DLL; there is no separate libzstd.
#
# Runs under Windows PowerShell 5.1 and PowerShell 7. `-Clean` removes what it built.

[CmdletBinding()]
param([switch]$Clean)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$root = $PSScriptRoot
$build = Join-Path $root '_build\win32'
$zstdDir = Join-Path $root '_build\deps\zstd'
$zstdLib = Join-Path $zstdDir 'lib'
$objDir = Join-Path $build 'obj'

# Where rebar3 (or Mix, which sets REBAR_BARE_COMPILER_OUTPUT_DIR) expects the NIF.
$privDir = if ($env:REBAR_BARE_COMPILER_OUTPUT_DIR) {
    Join-Path $env:REBAR_BARE_COMPILER_OUTPUT_DIR 'priv'
} else {
    Join-Path $root 'priv'
}
$output = Join-Path $privDir 'ezstd_nif.dll'

if ($Clean) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $build
    Remove-Item -Force -ErrorAction SilentlyContinue $output
    exit 0
}

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ezstd: '$Exe $($Arguments -join ' ')' failed with exit code $LASTEXITCODE"
    }
}

# --- toolchain ----------------------------------------------------------------------------

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    throw "ezstd: building the NIF on Windows needs 'zig' on the PATH (https://ziglang.org/download/)"
}

$target = switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'aarch64-windows-gnu' }
    default { 'x86_64-windows-gnu' }
}

# erl_nif.h: Mix hands ERTS_INCLUDE_DIR to rebar3, rebar3 hands ERLANG_ROOT_DIR and
# ERLANG_ERTS_VER to its hooks, and a script run by hand asks erl. (The format string is
# an atom because PowerShell 5.1 strips double quotes out of a native command line.)
$ertsInclude = $env:ERTS_INCLUDE_DIR
if (-not $ertsInclude -and $env:ERLANG_ROOT_DIR -and $env:ERLANG_ERTS_VER) {
    $ertsInclude = Join-Path $env:ERLANG_ROOT_DIR "erts-$env:ERLANG_ERTS_VER\include"
}
if (-not $ertsInclude) {
    if (-not (Get-Command erl -ErrorAction SilentlyContinue)) {
        throw "ezstd: neither ERTS_INCLUDE_DIR nor 'erl' on the PATH; cannot find erl_nif.h"
    }
    $ertsInclude = & erl -noshell -eval 'io:format(''~s/erts-~s/include'', [code:root_dir(), erlang:system_info(version)]), halt().'
}
if (-not (Test-Path (Join-Path $ertsInclude 'erl_nif.h'))) {
    throw "ezstd: no erl_nif.h under '$ertsInclude'"
}

# --- zstd source ---------------------------------------------------------------------------

$pin = Select-String -Path (Join-Path $root 'build_deps.sh') -Pattern '^ZSTD_SHA="([0-9a-f]+)"'
if (-not $pin) { throw 'ezstd: no ZSTD_SHA in build_deps.sh' }
$zstdSha = $pin.Matches[0].Groups[1].Value

if (-not (Test-Path (Join-Path $zstdLib 'zstd.h'))) {
    Write-Host "ezstd: fetching zstd $zstdSha"
    New-Item -ItemType Directory -Force $zstdDir | Out-Null
    Push-Location $zstdDir
    try {
        Invoke-Checked git @('init', '-q')
        Invoke-Checked git @('remote', 'add', 'origin', 'https://github.com/facebook/zstd.git')
        Invoke-Checked git @('fetch', '-q', '--depth', '1', 'origin', $zstdSha)
        Invoke-Checked git @('checkout', '-q', 'FETCH_HEAD')
    } finally {
        Pop-Location
    }
}

# --- compile -------------------------------------------------------------------------------

New-Item -ItemType Directory -Force $objDir, $privDir | Out-Null

# The same library the Makefile's `lib-release` produces: common, compress, decompress and
# dictBuilder, no legacy formats, no multithreading. The assembly Huffman decoder is left
# out (`ZSTD_DISABLE_ASM`) so the whole thing is plain C for one compiler.
$cflags = @(
    '-target', $target, '-O3', '-DNDEBUG',
    '-DZSTD_DISABLE_ASM=1', '-DZSTD_LEGACY_SUPPORT=0', '-DXXH_NAMESPACE=ZSTD_',
    "-I$zstdLib"
)
$objects = @()
foreach ($sub in 'common', 'compress', 'decompress', 'dictBuilder') {
    foreach ($src in Get-ChildItem (Join-Path $zstdLib $sub) -Filter '*.c') {
        $obj = Join-Path $objDir ($src.BaseName + '.o')
        $objects += $obj
        if ((Test-Path $obj) -and (Get-Item $obj).LastWriteTime -ge $src.LastWriteTime) { continue }
        Invoke-Checked zig (@('cc') + $cflags + @('-c', $src.FullName, '-o', $obj))
    }
}

Write-Host "ezstd: linking $output ($target)"
$cxxflags = @(
    '-target', $target, '-O3', '-DNDEBUG', '-std=c++11', '-fno-exceptions', '-fno-rtti',
    '-Wall', '-Wextra', '-Wno-missing-field-initializers', '-Wno-nullability-completeness',
    "-I$ertsInclude", "-I$zstdLib", '-shared', '-s', '-o', $output,
    (Join-Path $root 'c_src\ezstd_nif.cc'), (Join-Path $root 'c_src\nif_utils.cc')
)
Invoke-Checked zig (@('c++') + $cxxflags + $objects)

# The linker leaves an import library and a debug file beside the DLL; neither is loaded.
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $privDir 'ezstd_nif.lib'), (Join-Path $privDir 'ezstd_nif.pdb')
