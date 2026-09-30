# SPDX-License-Identifier: AGPL-3.0-only
<#
.SYNOPSIS
Build fork images v1.4.2-live.N and save to tar archive.

.DESCRIPTION
Builds three Docker images (web, live, api) from a specific commit,
records build metrics, and saves them to a tar archive with sha256 checksum.
Process counts are checked to ensure no windows were opened.

.PARAMETER Sha
The full 40-character commit SHA to build. Must be contained in
origin/live-updates/v1.4.2. Required.

.PARAMETER N
The build number (live.<N>). Used in image tags and output filenames. Required.

.PARAMETER Distro
The WSL distro name to run builds in. Required unless using -DryRun.

.PARAMETER OutDir
Output directory inside the distro for the tar archive. Defaults to /root/out.

.PARAMETER DryRun
Print commands instead of running them. Useful for validation.

.EXAMPLE
.\build.ps1 -Sha ec33e4fb6d9e41972b03d33fd0fac2595f138ac2 -N 1 -Distro <distro>

.EXAMPLE
.\build.ps1 -Sha ec33e4fb6d9e41972b03d33fd0fac2595f138ac2 -N 1 -DryRun

#>

param(
  [Parameter(Mandatory = $true)][string]$Sha,
  [Parameter(Mandatory = $true)][int]$N,
  [string]$Distro,
  [string]$OutDir = '/root/out',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Validate Sha format
if ($Sha -notmatch '^[0-9a-f]{40}$') {
  throw "Invalid SHA format: must be 40 hex characters, got '$Sha'"
}

# Validate N
if ($N -lt 0) {
  throw "N must be non-negative"
}

# Validate Distro
if (-not $DryRun -and [string]::IsNullOrWhiteSpace($Distro)) {
  throw "Distro is required unless using -DryRun"
}
if ($Distro -and $Distro -notmatch '^[A-Za-z0-9._-]+$') {
  throw "Invalid Distro name: must contain only alphanumerics, dots, hyphens and underscores"
}

# Validate OutDir
$OutDir = $OutDir.TrimEnd('/')
if ($OutDir -notmatch '^/[A-Za-z0-9._/-]+$') {
  throw "Invalid OutDir: must be an absolute path, got '$OutDir'"
}

# Tag for images
$imageTag = "v1.4.2-live.$N"
$tarName = "plane-fork-live.$N.tar"
$sha256Name = "plane-fork-live.$N.sha256"
$buildDir = "/root/plane-build/$Sha"
$buildLabel = "plane-fork-build=$Sha"

# The checkout that holds this script, not the caller's working directory.
$repoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$distroShown = if ($Distro) { $Distro } else { '<distro>' }

# MEASURE lines printed by fork/test/measure.sh, collected while the builds run.
$script:MeasureLines = New-Object System.Collections.Generic.List[string]

# Run a shell command as root in the distro. Output goes to the console, the
# MEASURE lines are remembered, and a non-zero exit code throws. Returns nothing.
# No command passed here may contain a double quote (Windows PowerShell 5.1 does
# not escape embedded quotes when it builds the wsl.exe command line).
function Invoke-Sh {
  param(
    [Parameter(Mandatory = $true)][string]$ShellCommand,
    [Parameter(Mandatory = $true)][string]$What
  )

  if ($DryRun) {
    Write-Host "wsl.exe -d $distroShown -u root -- sh -c `"$ShellCommand`""
    return
  }
  & wsl.exe -d $Distro -u root -- sh -c $ShellCommand | ForEach-Object {
    Write-Host $_
    if ("$_" -match '^MEASURE ') { $script:MeasureLines.Add("$_") }
  }
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

# Same, but returns the output lines instead of showing them. Throws on failure.
function Get-Sh {
  param(
    [Parameter(Mandatory = $true)][string]$ShellCommand,
    [Parameter(Mandatory = $true)][string]$What
  )

  if ($DryRun) {
    Write-Host "wsl.exe -d $distroShown -u root -- sh -c `"$ShellCommand`""
    return , @()
  }
  $out = & wsl.exe -d $Distro -u root -- sh -c $ShellCommand
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
  return , @($out | Where-Object { $null -ne $_ } | ForEach-Object { "$_".TrimEnd("`r") })
}

# Check that Sha is in origin/live-updates/v1.4.2
if (-not $DryRun) {
  Write-Host "Verifying SHA $Sha is in origin/live-updates/v1.4.2..."

  # No 2>&1 here: under $ErrorActionPreference='Stop' Windows PowerShell 5.1 turns
  # any redirected native stderr line (git fetch prints progress there) into a
  # terminating error. Let stderr go to the console and rely on the exit code.
  & git -C $repoRoot fetch origin live-updates/v1.4.2 --quiet
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch origin/live-updates/v1.4.2"
  }

  & git -C $repoRoot merge-base --is-ancestor $Sha origin/live-updates/v1.4.2
  if ($LASTEXITCODE -ne 0) {
    throw "SHA $Sha is not contained in origin/live-updates/v1.4.2. Refusing to build."
  }

  Write-Host "SHA verified: $Sha is in origin/live-updates/v1.4.2"
}

# Record process counts at start
$initialCounts = @{}
if (-not $DryRun) {
  $procs = Get-Process -Name WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue
  $initialCounts['WindowsTerminal'] = @($procs | Where-Object { $_.Name -eq 'WindowsTerminal' }).Count
  $initialCounts['OpenConsole'] = @($procs | Where-Object { $_.Name -eq 'OpenConsole' }).Count
  Write-Host "Process counts at start: WindowsTerminal=$($initialCounts['WindowsTerminal']), OpenConsole=$($initialCounts['OpenConsole'])"
}

# Build: 1. Ship the source tree of $Sha into the distro
Invoke-Sh "rm -rf $buildDir && mkdir -p $buildDir" 'Preparing the build directory'

if ($DryRun) {
  Write-Host "git -C <repo> -c core.autocrlf=false archive --format=tar -o <tempfile> $Sha"
  Write-Host "cmd.exe /d /s /c `"wsl.exe -d $distroShown -u root -- tar -x --no-same-owner -C $buildDir < <tempfile>`""
  Write-Host "extracted file count is compared with: git ls-tree -r $Sha (minus submodule entries)"
} else {
  Write-Host "Archiving $Sha and extracting it in the distro..."

  # git writes the tar to a file (so its exit code is seen), and cmd.exe feeds that
  # file to tar with a raw `<` redirection. A PowerShell pipeline would decode the
  # bytes as text and corrupt the archive.
  $tempArchive = [System.IO.Path]::GetTempFileName()
  try {
    & git -C $repoRoot -c core.autocrlf=false archive --format=tar -o $tempArchive $Sha
    if ($LASTEXITCODE -ne 0) { throw "git archive failed" }

    # With /s, cmd.exe strips the outer quotes of the /c string and keeps the
    # quoted path (which may contain spaces) intact.
    & cmd.exe /d /s /c "wsl.exe -d $Distro -u root -- tar -x --no-same-owner -C $buildDir < `"$tempArchive`""
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract the archive in the distro" }
  } finally {
    Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
  }

  # Loud failure for a damaged or partial extract: compare the number of files
  # with the number of blobs in the commit (submodule entries are not archived).
  $treeLines = @(& git -C $repoRoot ls-tree -r $Sha)
  if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed" }
  $expectedFiles = @($treeLines | Where-Object { "$_" -notmatch '^160000 ' }).Count
  $countOut = Get-Sh "cd $buildDir && find . -type f -o -type l | wc -l" 'Counting extracted files'
  $actualFiles = [int](("$($countOut[0])").Trim())
  if ($actualFiles -ne $expectedFiles) {
    throw "Extraction check failed: $actualFiles files in the distro, $expectedFiles in commit $Sha"
  }
  Write-Host "Extraction verified: $actualFiles files"
}

# Build: 2. Build the three images. --label marks the images (and any layers that
# carry the label) so that the prune below only touches this build's leftovers.
Write-Host "Building images with tag $imageTag..."

$cd = "cd $buildDir"
$m = 'fork/test/measure.sh'
$builds = @(
  @{ Label = 'web'; Cmd = "$cd && $m web podman build --cpu-period=100000 --cpu-quota=800000 --label $buildLabel -f apps/web/Dockerfile.web -t localhost/plane-fork-web:$imageTag ." },
  @{ Label = 'live'; Cmd = "$cd && $m live podman build --cpu-period=100000 --cpu-quota=800000 --label $buildLabel -f apps/live/Dockerfile.live -t localhost/plane-fork-live:$imageTag ." },
  @{ Label = 'api'; Cmd = "$cd && $m api podman build --label $buildLabel -f fork/docker/Dockerfile.fork-api -t localhost/plane-fork-api:$imageTag ." }
)
foreach ($b in $builds) {
  Invoke-Sh $b.Cmd "Build of $($b.Label)"
}

# Build: 3. Save images to tar
Write-Host "Saving images to $OutDir/$tarName..."
Invoke-Sh "mkdir -p $OutDir && podman save -m --format docker-archive -o $OutDir/$tarName localhost/plane-fork-web:$imageTag localhost/plane-fork-live:$imageTag localhost/plane-fork-api:$imageTag" 'Saving images'

# Build: 4. Create sha256 checksum
Write-Host "Creating sha256 checksum..."
Invoke-Sh "cd $OutDir && sha256sum $tarName > $sha256Name" 'Creating the checksum'

# Build: 5. Prune. Only dangling (untagged) images that carry this build's label
# are removed. That frees the leftover images of this build (for example the
# previous images of the same tags if they were rebuilt). Base images, images of
# other builds, unlabelled stage layers and the pnpm cache mounts are not touched.
Write-Host "Pruning this build's dangling images ($buildLabel)..."
$pruned = @()
try {
  $pruned = Get-Sh "podman image prune -f --filter dangling=true --filter label=$buildLabel" 'Pruning'
} catch {
  Write-Warning "Prune failed, continuing: $_"
}

# Verify that exactly the three expected images exist
$tarSha = ''
$expectedImages = @("plane-fork-api:$imageTag", "plane-fork-live:$imageTag", "plane-fork-web:$imageTag") | ForEach-Object { "localhost/$_" }
if (-not $DryRun) {
  Write-Host "Verifying images were created..."

  $listed = Get-Sh "podman images --filter 'reference=localhost/plane-fork-*:$imageTag' --format '{{.Repository}}:{{.Tag}}'" 'Listing images'
  $images = @($listed | Sort-Object)
  if (($images -join ',') -ne ($expectedImages -join ',')) {
    throw "Expected images $($expectedImages -join ', ') but found: $($images -join ', ')"
  }
  Write-Host "Images verified: $($images -join ', ')"

  $shaLines = Get-Sh "cat $OutDir/$sha256Name" 'Reading the checksum'
  $tarSha = ("$($shaLines[0])" -split '\s+')[0]
  if ($tarSha -notmatch '^[0-9a-f]{64}$') { throw "Unexpected checksum file content" }
  Write-Host "Tar sha256: $tarSha"
}

# Append results to fork/README.md (LF line endings, no BOM)
if (-not $DryRun) {
  Write-Host "Updating fork/README.md with results..."

  $measures = @{}
  foreach ($line in $script:MeasureLines) {
    $kv = @{}
    foreach ($mm in [regex]::Matches($line, '(\w+)=(\S+)')) { $kv[$mm.Groups[1].Value] = $mm.Groups[2].Value }
    $measures[$kv['label']] = $kv
  }

  $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add("### Build $N - $timestamp")
  $out.Add("- SHA: $Sha")
  $out.Add("- Output: $tarName, sha256 $tarSha ($sha256Name)")
  $out.Add("- Tags: $($expectedImages -join ', ')")
  foreach ($b in $builds) {
    $kv = $measures[$b.Label]
    if (-not $kv) { throw "No MEASURE line captured for the $($b.Label) build" }
    $out.Add("- $($b.Label) build: $($kv['wall_s']) s wall, peak RAM used $($kv['peak_used_mb']) MB (+$($kv['peak_delta_mb']) MB over idle), lowest available $($kv['min_available_mb']) MB")
  }
  $out.Add("- Prune ($buildLabel, dangling only): $(@($pruned).Count) image(s) removed")
  $text = ($out -join "`n") + "`n`n"

  $readmeFile = Join-Path (Join-Path $repoRoot 'fork') 'README.md'
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  if (-not (Test-Path -LiteralPath $readmeFile)) {
    $header = "# Plane Fork Build Results`n`nBuild results for plane-fork images v1.4.2-live releases.`n`n## Builds`n`n"
    [System.IO.File]::WriteAllText($readmeFile, $header, $utf8)
  } elseif (-not ([System.IO.File]::ReadAllText($readmeFile).EndsWith("`n"))) {
    [System.IO.File]::AppendAllText($readmeFile, "`n", $utf8)
  }
  [System.IO.File]::AppendAllText($readmeFile, $text, $utf8)
  Write-Host "Results appended to fork/README.md"
}

# Final check: verify process counts haven't changed
if (-not $DryRun) {
  $finalProcs = Get-Process -Name WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue
  $finalCounts = @{}
  $finalCounts['WindowsTerminal'] = @($finalProcs | Where-Object { $_.Name -eq 'WindowsTerminal' }).Count
  $finalCounts['OpenConsole'] = @($finalProcs | Where-Object { $_.Name -eq 'OpenConsole' }).Count

  Write-Host "Process counts at end: WindowsTerminal=$($finalCounts['WindowsTerminal']), OpenConsole=$($finalCounts['OpenConsole'])"

  if ($finalCounts['WindowsTerminal'] -ne $initialCounts['WindowsTerminal'] -or `
      $finalCounts['OpenConsole'] -ne $initialCounts['OpenConsole']) {
    throw ("Process counts changed during the build. Initial: WindowsTerminal=$($initialCounts['WindowsTerminal']), OpenConsole=$($initialCounts['OpenConsole']); " +
      "final: WindowsTerminal=$($finalCounts['WindowsTerminal']), OpenConsole=$($finalCounts['OpenConsole']). " +
      "The script opens no windows itself, so this can be a false positive if a terminal was opened or closed by hand while the build ran (about 10 minutes). " +
      "The tar, checksum and README entry were already written and are valid; check for a stray window before re-running.")
  }

  Write-Host "Process counts verified: no new windows opened"
  Write-Host "Build complete!"
}
