[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]   $Path,                # exact VHDX path (e.g. C:\Users\how\AppData\Local\Docker\wsl\disk\docker_data.vhdx or ...\LocalState\ext4.vhdx)
  [string[]] $Roots,               # additional search roots if -Path not provided
  [switch]   $IncludeExt4 = $true, # include ext4.vhdx from WSL distros
  [switch]   $ForcePrune,          # run docker prune without asking
  [switch]   $SkipPrune,           # skip docker prune
  [string]   $LogPath,             # custom transcript path; default %TEMP%\Shrink-DockerVHD_yyyyMMdd_HHmmss.log
  [switch]   $OpenLog,             # open log in Notepad at the end or on error
  [switch]   $AutoClose,           # do not pause at the end
  [switch]   $ScanWSL = $true      # scan %LOCALAPPDATA%\Packages\*\LocalState for ext4.vhdx
)

$ErrorActionPreference = 'Stop'
$hadError = $false

# --- Transcript / logging ---
try {
  if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $tsName  = 'Shrink-DockerVHD_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log'
    $LogPath = Join-Path $env:TEMP $tsName
  } else {
    $dir = Split-Path -Parent $LogPath
    if (![string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
  }
  Start-Transcript -Path $LogPath -Force | Out-Null
} catch {
  Write-Warning "Failed to start transcript: $($_.Exception.Message)"
}
Write-Host "[*] Log file: $LogPath`n"

# --- Info banner (ASCII only) ---
Write-Host "============================================================================"
Write-Host " Docker / WSL VHDX Shrinker"
Write-Host "----------------------------------------------------------------------------"
Write-Host " Tip: you can free additional space by removing unused Docker objects:"
Write-Host "   docker system prune -a --volumes"
Write-Host "============================================================================`n"

# --- Utilities ---
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = [Security.Principal.WindowsPrincipal]::new($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run this script as Administrator."
  }
}

function Get-ReadableSize { param([long] $bytes)
  $sizes = 'B','KB','MB','GB','TB'
  $i = 0; $v = [double]$bytes
  while ($v -ge 1024 -and $i -lt $sizes.Length-1) { $v/=1024; $i++ }
  '{0:N2} {1}' -f $v,$sizes[$i]
}

function Prompt-YesNo {
  param([string] $Message = 'Proceed?', [bool] $DefaultYes = $true)
  $suffix = if ($DefaultYes) { '[Y]/n' } else { 'y/[N]' }
  while ($true) {
    $ans = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    switch -Regex ($ans.Trim()) {
      '^(y|yes)$' { return $true }
      '^(n|no)$'  { return $false }
      default     { Write-Host 'Please answer y or n.' }
    }
  }
}

function Stop-DockerDesktop {
  Write-Host ">> Stopping Docker Desktop..."
  $procs = 'Docker Desktop','com.docker.backend','com.docker.service','dockerd','Docker'
  foreach ($p in $procs){
    Get-Process -ErrorAction SilentlyContinue $p | ForEach-Object {
      if ($PSCmdlet.ShouldProcess($_.ProcessName, 'Stop-Process')) {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }
  Start-Sleep -Seconds 2
}

function WSL-Shutdown {
  Write-Host ">> Shutting down WSL (wsl --shutdown)"
  if ($PSCmdlet.ShouldProcess('WSL', 'wsl --shutdown')) {
    try { wsl --shutdown } catch { Write-Warning ("wsl --shutdown failed: {0}" -f $_.Exception.Message) }
  }
  Start-Sleep -Seconds 2
}

function Get-DefaultRoots {
  $roots = @()
  # Docker default locations
  if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Docker\wsl') }
  $roots += @(
    "$env:LOCALAPPDATA\Docker\wsl\data",
    "$env:LOCALAPPDATA\Docker\wsl\disk"
  ) | Where-Object { $_ -and (Test-Path $_) }
  $roots = $roots | Select-Object -Unique
  if (-not $roots) { $roots = @((Join-Path $env:LOCALAPPDATA 'Docker\wsl')) }
  return $roots
}

function Get-WSLRoots {
  # Return %LOCALAPPDATA%\Packages if present (we will filter to ext4.vhdx later)
  $pkg = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $pkg) { return ,$pkg }
  return @()
}

function Find-VHDX {
  param(
    [string[]] $SearchRoots,
    [switch]   $IncludeExt4,
    [switch]   $ScanWSL
  )
  $patterns = @('docker_data.vhdx','*.vhdx')
  $found = @()

  foreach ($root in $SearchRoots) {
    if (-not (Test-Path $root)) { continue }
    foreach ($pat in $patterns) {
      $found += Get-ChildItem -Path $root -Recurse -Filter $pat -ErrorAction SilentlyContinue
    }
  }

  # Optionally scan WSL packages for ext4.vhdx
  if ($ScanWSL) {
    $wslRoot = Get-WSLRoots
    foreach ($wr in $wslRoot) {
      if (Test-Path $wr) {
        # Only look for ext4.vhdx to avoid scanning everything
        $found += Get-ChildItem -Path $wr -Recurse -Filter 'ext4.vhdx' -ErrorAction SilentlyContinue
      }
    }
  }

  # Prefer Docker paths first
  $found = $found | Sort-Object { if ($_.FullName -match '\\Docker\\wsl\\') { 0 } else { 1 } }, Name -Unique

  # Optionally exclude ext4.vhdx
  if (-not $IncludeExt4) {
    $found = $found | Where-Object { $_.Name -notlike 'ext4.vhdx' }
  }

  # Prefer docker_data.vhdx > ext4.vhdx > others
  $found = $found | Sort-Object {
    switch -Wildcard ($_.Name) { 'docker_data.vhdx' {0}; 'ext4.vhdx' {1}; default {2} }
  }
  return $found
}

function Ensure-HyperVModule {
  $hasCmd = Get-Command Optimize-VHD -ErrorAction SilentlyContinue
  if ($hasCmd) { return $true }
  Write-Host ">> Optimize-VHD not found; falling back to DiskPart."
  return $false
}

function Compact-With-OptimizeVHD { param([string] $VhdPath)
  Write-Host (">> Optimize-VHD: {0}" -f $VhdPath)
  Optimize-VHD -Path $VhdPath -Mode Full
}

function Compact-With-DiskPart { param([string] $VhdPath)
  Write-Host (">> DiskPart compact vdisk: {0}" -f $VhdPath)
  $script = @"
select vdisk file="$VhdPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
  $tmp = New-TemporaryFile
  Set-Content -LiteralPath $tmp -Value $script -Encoding ASCII
  try { diskpart /s $tmp | Out-Host } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Shrink-OneVHDX {
  param([System.IO.FileInfo] $File, [bool] $UseOptimize)
  $full = $File.FullName
  $szBefore = (Get-Item $full).Length
  Write-Host ("  Target: {0}" -f $full)
  Write-Host ("  Before: {0}" -f (Get-ReadableSize $szBefore))

  if ($UseOptimize) {
    if ($PSCmdlet.ShouldProcess($full, 'Optimize-VHD')) { Compact-With-OptimizeVHD -VhdPath $full }
  } else {
    if ($PSCmdlet.ShouldProcess($full, 'DiskPart compact vdisk')) { Compact-With-DiskPart -VhdPath $full }
  }

  $szAfter = (Get-Item $full).Length
  Write-Host ("  After : {0}" -f (Get-ReadableSize $szAfter))
  $saved = [math]::Max(0, $szBefore - $szAfter)
  if ($saved -gt 0) {
    Write-Host ("  Saved : {0}" -f (Get-ReadableSize $saved))
  } else {
    Write-Host "  No significant change"
  }
  Write-Host ""

  [pscustomobject]@{ Path=$full; Before=$szBefore; After=$szAfter; Saved=$saved }
}

# --- Main ---
try {
  Assert-Admin

  # 0) docker prune (optional)
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    if ($SkipPrune) {
      Write-Host ">> Skip docker prune (requested)"
    } else {
      $doPrune = if ($ForcePrune) { $true } else { Prompt-YesNo -Message "Run 'docker system prune -a --volumes' now?" -DefaultYes:$true }
      if ($doPrune) {
        if ($PSCmdlet.ShouldProcess('docker', 'system prune -a --volumes --force')) {
          try { docker system prune -a --volumes --force } catch { Write-Warning ("docker prune failed: {0}" -f $_.Exception.Message) }
        }
      } else {
        Write-Host ">> Prune skipped by user."
      }
    }
  } else {
    Write-Host ">> 'docker' command not found; skipping prune."
  }

  # 1) Stop Docker & WSL
  Stop-DockerDesktop
  WSL-Shutdown

  # 2) Targets
  $targets = @()
  if ($Path) {
    if (-not (Test-Path $Path)) { throw "Target not found: $Path" }
    $targets = ,(Get-Item -LiteralPath $Path)
  } else {
    $searchRoots = @()
    $searchRoots += Get-DefaultRoots
    if ($Roots -and $Roots.Count -gt 0) { $searchRoots += $Roots }
    $searchRoots = $searchRoots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    Write-Host (">> Search roots: {0}" -f ($searchRoots -join '; '))
    $targets = Find-VHDX -SearchRoots $searchRoots -IncludeExt4:$IncludeExt4 -ScanWSL:$ScanWSL
    if (-not $targets -or $targets.Count -eq 0) {
      $hint = "Use -Path for a single file or -Roots to search. Example WSL path:`n" +
              "C:\Users\how\AppData\Local\Packages\*\LocalState\ext4.vhdx"
      throw "No VHDX found. $hint"
    }
  }

  # 3) Engine: Optimize-VHD or DiskPart
  $useOptimize = Ensure-HyperVModule

  # 4) Process
  $results = foreach ($f in $targets) { Shrink-OneVHDX -File $f -UseOptimize:$useOptimize }

  # 5) Summary
  $totalBefore = ($results | Measure-Object -Property Before -Sum).Sum
  $totalAfter  = ($results | Measure-Object -Property After  -Sum).Sum
  $totalSaved  = ($results | Measure-Object -Property Saved  -Sum).Sum

  Write-Host '====================== Summary ======================'
  Write-Host ("Total Before : {0}" -f (Get-ReadableSize $totalBefore))
  Write-Host ("Total After  : {0}" -f (Get-ReadableSize $totalAfter))
  Write-Host ("Total Saved  : {0}" -f (Get-ReadableSize $totalSaved))
  Write-Host '====================================================='
  if ($results) {
    Write-Host 'Files:'
    $results | ForEach-Object {
      Write-Host (" - {0}  (Saved: {1})" -f $_.Path, (Get-ReadableSize $_.Saved))
    }
  }

  Write-Host "`n>> Done."
} catch {
  $hadError = $true
  Write-Error $_.Exception.Message
} finally {
  try { Stop-Transcript | Out-Null } catch { }
  Write-Host "`n[*] Log file: $LogPath"
  if ($OpenLog -or $hadError) {
    try { Start-Process notepad.exe $LogPath } catch { }
  }
  if (-not $AutoClose) {
    Read-Host "Press Enter to exit..."
  }
}
