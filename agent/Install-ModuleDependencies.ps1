<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-E2E agent
    needs.

.DESCRIPTION
    Centralised so Initialize-E2EEnvironment.ps1 (and any other E2E entry
    point) can dot-source one file instead of repeating the install/import
    block. Intentionally not a function: dot-sourcing imports every required
    module into the caller's scope.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.

    Step 2 - Common.PowerShell: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

.NOTES
    Initialize-E2EEnvironment.ps1 is the broader "set up the E2E session"
    script (provider registration, etc.) and dot-sources this file first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Install-PowerShellCommonWithRetry
#   The chicken-and-egg case: Invoke-ModuleInstall (which has retry built
#   in) lives inside Common.PowerShell, so it cannot be used to install
#   Common.PowerShell itself. A small inline retry wrapper here covers
#   that single bootstrap call. All later Invoke-ModuleInstall calls below
#   get retry for free.
#
#   Defaults mirror Invoke-ModuleInstall's: 6 attempts, exponential 10 s ->
#   20 -> 40 -> 80 -> 160, capped at 300 s (5 min). Total wait ~5 min
#   before giving up - long enough to ride out a transient PSGallery
#   resolution blip, short enough that a real outage fails the run.
# ---------------------------------------------------------------------------
function Install-PowerShellCommonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Version] $MinimumVersion,
        [int] $MaxAttempts         = 6,
        [int] $InitialDelaySeconds = 10,
        [int] $MaxDelaySeconds     = 300
    )
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # -ErrorAction Stop promotes PSGallery "Unable to resolve
            # package source" (a non-terminating error by default) to a
            # terminating one so the catch block can retry it.
            Install-Module Common.PowerShell `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning (
                "Install-Module Common.PowerShell failed " +
                "(attempt $attempt/$MaxAttempts): " +
                "$($_.Exception.Message). Retrying in ${delay}s ..."
            )
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Common.PowerShell (provides Invoke-ModuleInstall).
#
# 9.1.0 for the N-level timing surface (New-TimingSpanTree /
# Measure-TimingSpan) that the runner-lifecycle orchestration wraps its
# phases and parts with (feature 88 C1). That release also carries the
# 9.0.1 Invoke-ModuleInstall -Global fix - the imports below land in this
# script's scope, not Common.PowerShell's - and satisfies
# Infrastructure.Secrets 4.0.0 (needs >= 9.0.0) and Assert-WslHasBash. Keep
# the Get-Module gate and the Install-Module pin in lockstep.
$_common = Get-Module -ListAvailable -Name Common.PowerShell |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'9.1.0') {
    Install-PowerShellCommonWithRetry -MinimumVersion '9.1.0'
    # Re-query so the comparison below uses the freshly installed version.
    $_common = Get-Module -ListAvailable -Name Common.PowerShell |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because the bootstrap installs
# the very module that defines that function.
$_loaded = @(Get-Module -Name Common.PowerShell)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Common.PowerShell -Force -ErrorAction Stop
}

# Step 3 - Everything else
#
# Secrets 4.0.0 is a hard floor: it depends on Common.PowerShell by name.
# Secrets <= 3.0.1 instead pulls in the legacy Infrastructure.Common - a
# duplicate Get-PendingDeployment exporter that shadows
# Infrastructure.GitHub's -CreatedSince version. Don't relax below 4.0.0.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '4.0.0'
# 1.2.1 makes Invoke-GitHubApi retry transient network failures. Without it a
# DNS hiccup on the host resolver aborts a whole run: the runner-online poll
# in Invoke-RunnerLifecycleTest retries the runner's *status*, not the API
# call, so a "No such host is known" throws straight out of the loop.
# It also supersedes the older 1.1.0 floor, which was there for the
# -CreatedSince parameter the polling loop passes to Get-PendingDeployment.
Invoke-ModuleInstall -ModuleName 'Infrastructure.GitHub'  -MinimumVersion '1.2.1'
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV'  -MinimumVersion '0.11.0'
# Infrastructure.Wsl supplies Invoke-WslShell + Assert-Wsl2Ready /
# Assert-WslHasBash. The agent's Ansible flow needs all three (one
# shell into WSL per playbook run, plus the readiness gates from
# Initialize-E2EEnvironment).
Invoke-ModuleInstall -ModuleName 'Infrastructure.Wsl'     -MinimumVersion '0.1.0'
