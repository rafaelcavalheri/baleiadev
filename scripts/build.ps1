<#
.SYNOPSIS
    Builds CodeWhale binaries with progress reporting.

.DESCRIPTION
    Compiles all default workspace members (codewhale-cli, codewhale-tui,
    codewhale-app-server) in release mode and shows live cargo output
    with a PowerShell progress bar.

.PARAMETER Debug
    Build in debug mode instead of release.

.PARAMETER Bin
    Build only a specific binary (e.g. "codewhale", "codewhale-tui", "codewhale-app-server").
    If omitted, builds all three.

.PARAMETER Clean
    Run `cargo clean` before building.

.EXAMPLE
    .\scripts\build.ps1
    .\scripts\build.ps1 -Debug
    .\scripts\build.ps1 -Bin codewhale-tui
    .\scripts\build.ps1 -Clean
#>

param(
    [switch]$Debug,
    [string]$Bin,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path "$ScriptDir/.."

Write-Host @"
╔══════════════════════════════════════════╗
║           CodeWhale Build Tool           ║
║              v0.8.68                      ║
╚══════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Push-Location $ProjectRoot

try {
    # ── Clean ──────────────────────────────────────────
    if ($Clean) {
        Write-Host "`n[1/3] Cleaning previous build artifacts..." -ForegroundColor Yellow
        cargo clean 2>&1 | Out-Null
        Write-Host "       Done." -ForegroundColor Green
    }

    # ── Profile ───────────────────────────────────────
    $ProfileFlag = if ($Debug) { "" } else { "--release" }
    $ProfileName = if ($Debug) { "debug" } else { "release" }
    $TargetDir = "target/$ProfileName"

    Write-Host "`n[$(if ($Clean) { '2' } else { '1' })/3] Building in $ProfileName mode..." -ForegroundColor Yellow

    # ── Build ─────────────────────────────────────────
    $Binaries = if ($Bin) {
        @($Bin)
    } else {
        @("codewhale", "codewhale-tui", "codewhale-app-server")
    }

    $BuildArgs = @(
        "build",
        $ProfileFlag
    )
    # Filter to requested binaries
    foreach ($b in $Binaries) {
        $BuildArgs += "--bin"
        $BuildArgs += $b
    }

    # Run cargo and stream output, capturing progress
    $TotalSteps = $Binaries.Count
    $CurrentStep = 0

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "cargo"
    $pinfo.Arguments = $BuildArgs -join " "
    $pinfo.WorkingDirectory = $ProjectRoot
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $pinfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $pinfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo

    $outputLines = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $errorOutput = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

    $outputEvent = Register-ObjectEvent -InputObject $process `
        -EventName 'OutputDataReceived' `
        -Action {
            if ($EventArgs.Data) {
                [System.Console]::WriteLine($EventArgs.Data)
                $Event.MessageData.Add($EventArgs.Data)
            }
        } -MessageData $outputLines

    $errorEvent = Register-ObjectEvent -InputObject $process `
        -EventName 'ErrorDataReceived' `
        -Action {
            if ($EventArgs.Data) {
                Write-Host $EventArgs.Data -ForegroundColor Red
                $Event.MessageData.Add($EventArgs.Data)
            }
        } -MessageData $errorOutput

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process.Start() | Out-Null
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.WaitForExit()

    Unregister-Event -SourceIdentifier $outputEvent.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue

    $stopwatch.Stop()

    if ($process.ExitCode -ne 0) {
        Write-Host "`nBuild FAILED with exit code $($process.ExitCode)" -ForegroundColor Red
        exit $process.ExitCode
    }

    # ── Verify binaries ───────────────────────────────
    Write-Host "`n[$(if ($Clean) { '3' } else { '2' })/3] Verifying binaries..." -ForegroundColor Yellow

    $ext = if ($IsWindows) { ".exe" } else { "" }
    $Found = @()
    $Missing = @()

    foreach ($b in $Binaries) {
        $path = Join-Path $TargetDir "$b$ext"
        if (Test-Path $path) {
            $item = Get-Item $path
            $sizeMB = [math]::Round($item.Length / 1MB, 2)
            $Found += [PSCustomObject]@{
                Binary   = $b
                Path     = $item.FullName
                Size     = "$sizeMB MB"
                Modified = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            }
        } else {
            $Missing += $b
        }
    }

    # ── Summary ───────────────────────────────────────
    Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host   "║              BUILD SUCCESS                ║" -ForegroundColor Green
    Write-Host   "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

    Write-Host "`n  Elapsed : $($stopwatch.Elapsed.ToString('mm\:ss'))" -ForegroundColor White
    Write-Host "  Profile : $ProfileName" -ForegroundColor White
    Write-Host ""

    ($Found | Format-Table -Property Binary, Size, Modified -AutoSize | Out-String).TrimEnd() | Write-Host

    if ($Missing.Count -gt 0) {
        Write-Host "`nWARNING: Missing binaries: $($Missing -join ', ')" -ForegroundColor Yellow
    }

    Write-Host ""
} finally {
    Pop-Location
}
