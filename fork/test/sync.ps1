# SPDX-License-Identifier: AGPL-3.0-only
<#
  sync.ps1 - mirror the working tree of the Plane fork into a WSL podman
  distro so builds and tests run on the distro's ext4 disk, not over 9p.

  What it does:
    1. deletes files and symlinks under $Dest (but keeps every node_modules and
       .turbo directory, so pnpm installs done by node-tests.sh survive a sync)
    2. streams a tar of $Source (excluding .git, node_modules, .pnpm-store and the top-level build and dist) into
       $Dest through cmd.exe, because the PowerShell 5.1 pipeline is text-only
       and corrupts binary streams
    3. repairs what a Windows checkout loses: tracked symlinks (mode 120000 is a
       plain text file on Windows) and exec bits (mode 100755), both taken from
       `git ls-files -s`
    4. prints per-phase and total seconds and the file count

  Usage:  powershell -File fork\test\sync.ps1 -Source <repo> -Distro <distro> [-Dest /root/plane-work]
  Run it from an existing shell; it never opens a window.
#>
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Distro,
  [string]$Dest = '/root/plane-work'
)

$ErrorActionPreference = 'Stop'

# $Dest is used in `find ... -exec rm`, so it must be a safe absolute path that is
# not the filesystem root. Restricting the character set also makes quoting safe.
$Dest = $Dest.TrimEnd('/')
if ([string]::IsNullOrWhiteSpace($Dest) -or $Dest -notmatch '^/[A-Za-z0-9._/-]+$' -or $Dest -match '(^|/)\.\.?(/|$)' -or $Dest -match '//') {
  throw "invalid -Dest '$Dest': must be a non-empty absolute path (not /) using only letters, digits, . _ - and /"
}
if ($Distro -notmatch '^[A-Za-z0-9._-]+$') { throw "invalid -Distro '$Distro'" }
$total = [System.Diagnostics.Stopwatch]::StartNew()
$t = @{}

# 1. clear stale files but keep installed dependencies
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& wsl.exe -d $Distro -u root -- sh -c "mkdir -p '$Dest' && find '$Dest' \( -name node_modules -o -name .turbo \) -prune -o \( -type f -o -type l \) -exec rm -f {} +"
if ($LASTEXITCODE -ne 0) { throw "wsl cleanup failed ($LASTEXITCODE)" }
$t['clean'] = $sw.Elapsed.TotalSeconds

# 2. stream the tree (cmd.exe pipe is binary safe)
$sw.Restart()
$excludes = '--exclude=.git --exclude=node_modules --exclude=./build --exclude=./dist --exclude=.pnpm-store'
$cmd = "tar.exe -C `"$Source`" -cf - $excludes . | wsl.exe -d $Distro -u root -- tar -x --no-same-owner --no-same-permissions -C '$Dest'"
& cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "tar stream failed ($LASTEXITCODE)" }
$t['stream'] = $sw.Elapsed.TotalSeconds

# 3. restore symlinks and exec bits recorded in git
$sw.Restart()
$fixes = New-Object System.Collections.Generic.List[string]
foreach ($line in (& git -C $Source ls-files -s)) {
  if ($line -match '^(\d{6}) \S+ \d\t(.+)$') {
    $mode = $Matches[1]; $path = $Matches[2]
    if ($mode -eq '100755') {
      $fixes.Add("chmod 755 '$path'")
    } elseif ($mode -eq '120000') {
      $target = (Get-Content -Raw -LiteralPath (Join-Path $Source $path)).Trim()
      $fixes.Add("rm -f '$path' && ln -s '$target' '$path'")
    }
  }
}
if ($fixes.Count -gt 0) {
  & wsl.exe -d $Distro -u root -- sh -c ("cd '$Dest' && " + ($fixes -join ' && '))
  if ($LASTEXITCODE -ne 0) { throw "mode/symlink repair failed ($LASTEXITCODE)" }
}
$t['repair'] = $sw.Elapsed.TotalSeconds

$total.Stop()
$count = (& wsl.exe -d $Distro -u root -- sh -c "find '$Dest' -path '*/node_modules' -prune -o \( -type f -o -type l \) -print | wc -l").Trim()
'{0}: synced {1} files to {2}:{3} in {4:N1}s (clean {5:N1}s, stream {6:N1}s, repair {7:N1}s; {8} mode/symlink fixes)' -f `
  (Get-Date -Format s), $count, $Distro, $Dest, $total.Elapsed.TotalSeconds, $t['clean'], $t['stream'], $t['repair'], $fixes.Count
