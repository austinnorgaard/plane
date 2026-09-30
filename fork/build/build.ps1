# SPDX-License-Identifier: AGPL-3.0-only
<#
.SYNOPSIS
Build fork images v1.4.2-live.N and save to tar archive.

.DESCRIPTION
Builds three Docker images (frontend, live, backend) from a specific commit,
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

function Invoke-Wsl {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  if ($DryRun) {
    $cmd = "wsl.exe -d $Distro -u root -- " + ($Arguments -join ' ')
    Write-Host $cmd
    return 0
  } else {
    & wsl.exe -d $Distro -u root -- @Arguments
    return $LASTEXITCODE
  }
}

function Invoke-Sh {
  param(
    [Parameter(Mandatory = $true)][string]$ShellCommand
  )

  if ($DryRun) {
    $cmd = "wsl.exe -d $Distro -u root -- sh -c `"$ShellCommand`""
    Write-Host $cmd
    return 0
  } else {
    & wsl.exe -d $Distro -u root -- sh -c $ShellCommand
    return $LASTEXITCODE
  }
}

# Check that Sha is in origin/live-updates/v1.4.2
if (-not $DryRun) {
  Write-Host "Verifying SHA $Sha is in origin/live-updates/v1.4.2..."

  # First fetch to ensure we have latest remote tracking branch
  & git fetch origin live-updates/v1.4.2 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch origin/live-updates/v1.4.2"
  }

  # Check if SHA is an ancestor of the branch
  & git merge-base --is-ancestor $Sha origin/live-updates/v1.4.2
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

# Build: 1. Archive the source tree
if (-not $DryRun) {
  Write-Host "Archiving source tree for SHA $Sha into /root/plane-build/$Sha..."
}

$archiveCmd = "rm -rf /root/plane-build/$Sha && mkdir -p /root/plane-build/$Sha && cd /root/plane-build/$Sha"
$rc = Invoke-Sh $archiveCmd
if ($rc -ne 0) { throw "Failed to prepare build directory" }

# Use git archive to get the source
if ($DryRun) {
  Write-Host "git -C . -c core.autocrlf=false archive --format=tar $Sha | wsl.exe -d $Distro -u root -- tar -x -C /root/plane-build/$Sha"
} else {
  Write-Host "Streaming git archive through tar..."
  $archiveStream = & git -c core.autocrlf=false archive --format=tar $Sha
  $archiveStream | & cmd.exe /c "wsl.exe -d $Distro -u root -- tar -x --no-same-owner -C /root/plane-build/$Sha"
  if ($LASTEXITCODE -ne 0) { throw "Failed to archive source tree" }
}

# Build: 2. Build the three images
if (-not $DryRun) {
  Write-Host "Building images with tag $imageTag..."
}

$buildCommands = @(
  "bash -c `"cd /root/plane-build/$Sha && fork/test/measure.sh frontend podman build --cpu-period=100000 --cpu-quota=800000 -f apps/web/Dockerfile.web -t localhost/plane-fork-frontend:$imageTag .`"",
  "bash -c `"cd /root/plane-build/$Sha && fork/test/measure.sh live podman build --cpu-period=100000 --cpu-quota=800000 -f apps/live/Dockerfile.live -t localhost/plane-fork-live:$imageTag .`"",
  "bash -c `"cd /root/plane-build/$Sha && fork/test/measure.sh backend podman build -f fork/docker/Dockerfile.fork-api -t localhost/plane-fork-backend:$imageTag .`""
)

foreach ($buildCmd in $buildCommands) {
  $rc = Invoke-Sh $buildCmd
  if ($rc -ne 0) { throw "Build failed: $buildCmd" }
}

# Build: 3. Save images to tar
if (-not $DryRun) {
  Write-Host "Saving images to $OutDir/$tarName..."
}

$saveCmd = "mkdir -p $OutDir && podman save -m --format docker-archive -o $OutDir/$tarName localhost/plane-fork-frontend:$imageTag localhost/plane-fork-live:$imageTag localhost/plane-fork-backend:$imageTag"
$rc = Invoke-Sh $saveCmd
if ($rc -ne 0) { throw "Failed to save images to tar" }

# Build: 4. Create sha256 checksum
if (-not $DryRun) {
  Write-Host "Creating sha256 checksum..."
}

$checksumCmd = "cd $OutDir && sha256sum $tarName > $sha256Name"
$rc = Invoke-Sh $checksumCmd
if ($rc -ne 0) { throw "Failed to create checksum" }

# Build: 5. Prune fork-only intermediates (dangling images from these builds)
# Keep base images and pnpm store/cache mounts
if (-not $DryRun) {
  Write-Host "Pruning fork-only build intermediates..."
}

$pruneCmd = "podman image prune -f --filter 'dangling=true'"
$rc = Invoke-Sh $pruneCmd
if ($rc -ne 0) {
  Write-Warning "Prune command failed, but continuing"
}

# Verify images exist
if (-not $DryRun) {
  Write-Host "Verifying images were created..."

  $verifyCmd = "podman images --filter 'reference=localhost/plane-fork-*:$imageTag' --format '{{.Repository}}:{{.Tag}}'"
  $images = @()
  $output = & wsl.exe -d $Distro -u root -- sh -c $verifyCmd
  if ($LASTEXITCODE -eq 0 -and $output) {
    $images = $output -split "`n" | Where-Object { $_ }
  }

  if ($images.Count -ne 3) {
    throw "Expected 3 images but found $($images.Count): $images"
  }

  Write-Host "Images verified: $($images -join ', ')"
}

# Append results to fork/README.md (create if missing)
if (-not $DryRun) {
  Write-Host "Updating fork/README.md with results..."

  $currentDir = Get-Location
  $repoRoot = git rev-parse --show-toplevel
  $readmeFile = Join-Path $repoRoot "fork/README.md"

  # Check if file exists, create with header if not
  if (-not (Test-Path $readmeFile)) {
    $header = @"
# Plane Fork Build Results

Build results for plane-fork images v1.4.2-live releases.

## Builds

"@
    Set-Content -Path $readmeFile -Value $header -Encoding UTF8
  }

  # Append this build's results (simplified for now, details from measure.sh logs)
  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $results = @"
### Build $N - $timestamp
- SHA: $Sha
- Output: $tarName ($sha256Name)

"@

  Add-Content -Path $readmeFile -Value $results -Encoding UTF8
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
    throw "Process counts changed during build! Initial: WindowsTerminal=$($initialCounts['WindowsTerminal']), OpenConsole=$($initialCounts['OpenConsole']); Final: WindowsTerminal=$($finalCounts['WindowsTerminal']), OpenConsole=$($finalCounts['OpenConsole'])"
  }

  Write-Host "Process counts verified: no new windows opened"
  Write-Host "Build complete!"
}
