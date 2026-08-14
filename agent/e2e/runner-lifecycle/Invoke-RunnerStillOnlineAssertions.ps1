<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-RunnerLifecycleTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) and
    Infrastructure.GitHub (for Invoke-GitHubApi) are loaded, and after
    Wait-RunnerOnlineRegistration.ps1 (which the GitHub-side check calls).
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerStillOnlineAssertions
#   Lightweight re-verification block that confirms the runner remains
#   installed AND online after an operation that should NOT have touched
#   runner state (e.g. a re-provision run that flipped javaDevKit.uninstall).
#
#   Narrower than the initial post-register block: that one polled with
#   backoff waiting for the runner to come online for the first time.
#   This one expects the runner to be online already - if it is not, a
#   regression has disturbed it. A small re-check loop is still useful
#   because the GitHub-side websocket can briefly flap; allowing a couple
#   of seconds prevents a transient flake.
#
#   Throws on the first failure with a message naming the regression
#   point. The outer try/finally in the lifecycle test still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-RunnerStillOnlineAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $RunnerName,

        # Token + GitHub URL needed for the GitHub-side status check.
        # GitHub URL is parsed into owner/repo for the API call.
        [Parameter(Mandatory)] [string] $RunnersToken,
        [Parameter(Mandatory)] [string] $GithubUrl
    )

    # 1) systemd service still active on the VM. Mirrors the resolution
    #    used in the initial post-register check.
    $nameResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   ("systemctl list-unit-files --no-legend " +
                    "--type=service 'actions.runner.*' " +
                    "| grep -F '.$RunnerName.'")
    $serviceLine = ($nameResult.Output -join '').Trim()
    if (-not $serviceLine) {
        throw "Runner service for '$RunnerName' missing on $VmName " +
            "after re-provision."
    }
    $serviceName = ($serviceLine -split '\s+')[0]

    $activeResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "systemctl is-active '$serviceName'"
    if (($activeResult.Output -join '').Trim() -ne 'active') {
        throw "Runner service '$serviceName' inactive on $VmName " +
            "after re-provision."
    }
    Write-Host "  [OK] runner service '$serviceName' still active." `
        -ForegroundColor Green

    # 2) GitHub-side status still online. Three attempts rather than the ten
    #    used at registration time: the runner is expected to be online
    #    already, so this only has to ride out a brief websocket flap.
    $registration = Wait-RunnerOnlineRegistration `
        -RunnersToken $RunnersToken `
        -GithubUrl    $GithubUrl `
        -RunnerName   $RunnerName `
        -MaxAttempts  3

    if ($null -eq $registration) {
        throw "Runner '$RunnerName' missing from GitHub API after re-provision."
    }
    if ($registration.status -ne 'online') {
        throw "Runner '$RunnerName' status is '$($registration.status)' " +
            "(expected 'online') after re-provision."
    }
    Write-Host "  [OK] runner '$RunnerName' still online in GitHub." `
        -ForegroundColor Green
}
