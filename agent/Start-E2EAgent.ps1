<#
.SYNOPSIS
    Polls GitHub for pending E2E deployments and runs the full test suite.

.PARAMETER RuntimeHours
    Total number of hours the agent will run before terminating cleanly.
    Defaults to 1. The agent may overshoot by up to TimeoutMinutes (the
    per-session polling window) because the check only fires at session
    boundaries.

.DESCRIPTION
    Reads configuration from the E2EConfig vault, acquires a short-lived
    GitHub App token, then polls the deployments API on a fixed interval
    until a pending deployment is found or the timeout expires.

    When a deployment is found the agent:
      1. Posts 'in_progress' status so the workflow's status poll sees work begin.
      2. Runs Invoke-RunnerLifecycleTest (provisions VM, sets up users, registers
         and verifies the GitHub Actions runner, tears everything down).
      3. Posts 'success' or 'failure' depending on the outcome.
      4. Immediately re-polls so any queued pending deployments are drained
         before sleeping again.

    The agent runs indefinitely - use Ctrl+C to stop it. If a structural error
    occurs (vault unreachable, GitHub API failure), the loop restarts after a
    60-second pause so transient failures do not require operator intervention.

    The token is refreshed automatically when it is within 5 minutes of expiry -
    both at the top of each poll tick and again immediately before the terminal
    status post, so neither a long poll wait nor a lifecycle run that outlasts
    the token's 1-hour life produces a stale-token (401) failure.

    Prerequisites:
      - setup-secrets.ps1 has been run to populate the E2EConfig vault.
      - Common.PowerShell >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.

.EXAMPLE
    .\agent\Start-E2EAgent.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int] $RuntimeHours = 1,

    # Required. The agent's own persistent config is read as
    # `E2EConfig-<Suffix>`. Operator launches pass `Production`. The
    # agent's lifecycle-internal test fixtures (VmProvisionerConfig,
    # VmUsersConfig, GitHubRunnersConfig) use a separate `E2E` suffix
    # so they're isolated from the operator's persistent vault
    # entries even if the operator runs production workflows on the
    # same workstation.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Script body
#   The guard below prevents this block from running when Start-E2EAgent.ps1
#   is dot-sourced by Pester tests. Every function this script needs lives in
#   its own file (one-function-per-file convention) and is dot-sourced here
#   inside the guard - the tests dot-source those files directly, so none of
#   them need to load at parse time. Invoke-E2EAgentLoop is the entry point;
#   Get-RefreshedDeploymentToken is its token helper; the rest serve the
#   restart handler below.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {

    . "$PSScriptRoot\Initialize-E2EEnvironment.ps1"
    . "$PSScriptRoot\Get-RefreshedDeploymentToken.ps1"
    . "$PSScriptRoot\Invoke-E2EAgentLoop.ps1"
    . "$PSScriptRoot\Get-RateLimitBackoffDelay.ps1"
    . "$PSScriptRoot\Test-GitHubAuthError.ps1"
    . "$PSScriptRoot\Resolve-AgentCrashAction.ps1"

    # ---------------------------------------------------------------------------
    # Read E2EConfig from vault
    #
    # Expected JSON shape:
    # {
    #   "AppId":               123456,
    #   "PrivateKeyPath":      "C:\\certs\\my-app.private-key.pem",
    #   "E2EInstallationId":   111111,
    #   "RunnersInstallationId": 222222,
    #   "Owner":               "my-org",
    #   "Repo":                "Infrastructure-E2E",
    #   "Environment":         "e2e-workstation",
    #   "PollIntervalSeconds": 30,
    #   "TimeoutMinutes":      10,
    #   "ProvisionerPath":     "C:\\a_Code\\Infrastructure-Vm-Provisioner",
    #   "UsersPath":           "C:\\a_Code\\Infrastructure-Vm-Users",
    #   "RunnersPath":         "C:\\a_Code\\Infrastructure-GitHubRunners",
    #   "UsersFlow":           "ansible",
    #   "RunnersFlow":         "ansible",
    #   "ToolchainsFlow":      "ansible",
    #   "FilesFlow":           "ansible",
    #   "WslDistro":           "Ubuntu-24.04",
    #   "HostTarballCachePath": "C:\\cache\\github-runners",
    #   "TestVm": {
    #     "ubuntuVersion":       "24.04",
    #     "dns":                 "8.8.8.8",
    #     "externalSwitchName":  "ExternalSwitch-Shared",
    #     "externalAdapterName": "Ethernet",
    #     "vmConfigPath":        "E:\\a_VMs\\Hyper-V\\Config",
    #     "vhdPath":             "E:\\a_VMs\\Hyper-V\\Disks"
    #   }
    # }
    #
    # The router VM the test provisions in front of every workload VM
    # (feature 53 topology) takes its upstream IP from DHCP - whatever
    # LAN the host's External vSwitch is bridged to. No operator IP
    # values to pin in TestVm; the orchestrator discovers the router's
    # actual IP via Hyper-V KVP after boot. Workload VMs sit on
    # PrivateSwitch-E2E at 10.99.0.10 / 10.99.0.11 (constants chosen
    # by the test fixture, not operator config). `dns` is dnsmasq's
    # upstream forwarder on the router; `externalSwitchName` /
    # `externalAdapterName` configure the host-side vSwitch.
    # ---------------------------------------------------------------------------

    $e2eSecretName = "E2EConfig-$SecretSuffix"
    Write-Host "Reading $e2eSecretName from vault ..." -ForegroundColor Cyan

    $configJson = Get-InfrastructureSecret -VaultName 'E2EConfig' -SecretName $e2eSecretName
    $config     = $configJson | ConvertFrom-Json

    $globalDeadline = [DateTime]::UtcNow.AddHours($RuntimeHours)
    Write-Host ("Agent will terminate after $RuntimeHours hour(s) " +
        "at $($globalDeadline.ToString('HH:mm:ss')) UTC.") -ForegroundColor Cyan

    # Each iteration is one polling session (TimeoutMinutes long). The global
    # deadline is checked at session boundaries so the agent stops without
    # operator intervention. PipelineStoppedException (Ctrl+C) is re-thrown
    # so the operator can also stop it early.
    # UsersFlow / RunnersFlow / ToolchainsFlow / FilesFlow / WslDistro are
    # optional in the vault payload so older E2EConfig files do not need a
    # re-write to keep working. When absent, Invoke-E2EAgentLoop's defaults
    # (UsersFlow=ansible, RunnersFlow=ansible,
    # ToolchainsFlow=ansible, FilesFlow=ansible) apply, and WslDistro has no
    # default
    # - if any flow is 'ansible' the loop fail-fasts with a named error so
    # the operator adds it to the vault rather than the agent guessing.
    # Strict mode requires guarded property access.
    # These vault values are the session defaults only; an individual
    # deployment may override any of the four flows for that
    # one run via its payload (set by the e2e.yml flow-spec input), so each
    # calling repo's PR exercises the create/remove/install path it owns.
    # DeploymentLookbackHours is likewise optional: absent vault payloads
    # fall back to Invoke-E2EAgentLoop's 1h default. An operator only sets
    # it to tune the lookback (see the parameter docstring); the default is
    # safe for normal operation.
    $vaultUsersFlow              = $null
    $vaultRunnersFlow            = $null
    $vaultToolchainsFlow         = $null
    $vaultFilesFlow              = $null
    $vaultWslDistro              = $null
    $vaultDeploymentLookbackHours = $null
    if ($config.PSObject.Properties['UsersFlow'])      { $vaultUsersFlow      = $config.UsersFlow }
    if ($config.PSObject.Properties['RunnersFlow'])    { $vaultRunnersFlow    = $config.RunnersFlow }
    if ($config.PSObject.Properties['ToolchainsFlow']) { $vaultToolchainsFlow = $config.ToolchainsFlow }
    if ($config.PSObject.Properties['FilesFlow'])      { $vaultFilesFlow      = $config.FilesFlow }
    if ($config.PSObject.Properties['WslDistro'])      { $vaultWslDistro      = $config.WslDistro }
    if ($config.PSObject.Properties['DeploymentLookbackHours']) {
        $vaultDeploymentLookbackHours = $config.DeploymentLookbackHours
    }

    while ([DateTime]::UtcNow -lt $globalDeadline) {
        try {
            $loopParams = @{
                AppId                 = $config.AppId
                E2EInstallationId     = $config.E2EInstallationId
                RunnersInstallationId = $config.RunnersInstallationId
                PrivateKeyPath        = $config.PrivateKeyPath
                ProvisionerPath       = $config.ProvisionerPath
                UsersPath             = $config.UsersPath
                RunnersPath           = $config.RunnersPath
                HostTarballCachePath  = $config.HostTarballCachePath
                TestVm                = $config.TestVm
                Owner                 = $config.Owner
                Repo                  = $config.Repo
                Environment           = $config.Environment
                PollIntervalSeconds   = $config.PollIntervalSeconds
                TimeoutMinutes        = $config.TimeoutMinutes
            }
            if ($vaultUsersFlow)      { $loopParams['UsersFlow']      = $vaultUsersFlow }
            if ($vaultRunnersFlow)    { $loopParams['RunnersFlow']    = $vaultRunnersFlow }
            if ($vaultToolchainsFlow) { $loopParams['ToolchainsFlow'] = $vaultToolchainsFlow }
            if ($vaultFilesFlow)      { $loopParams['FilesFlow']      = $vaultFilesFlow }
            if ($vaultWslDistro)      { $loopParams['WslDistro']      = $vaultWslDistro }
            if ($vaultDeploymentLookbackHours) {
                $loopParams['DeploymentLookbackHours'] = $vaultDeploymentLookbackHours
            }

            Invoke-E2EAgentLoop @loopParams
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            Write-Host "Agent crashed: $($_.Exception.Message)" -ForegroundColor Red

            # The routing decision lives in Resolve-AgentCrashAction (unit-
            # tested); this block only performs the chosen side effect.
            $crashAction = Resolve-AgentCrashAction -ErrorRecord $_
            switch ($crashAction.Action) {
                'Backoff' {
                    # Rate-limit crash: the budget only refills when GitHub's
                    # rolling window resets, so sleep that long before resuming
                    # rather than crash-looping against an empty budget.
                    Write-Host ('GitHub rate limit hit - backing off ' +
                        "$($crashAction.DelaySeconds)s until the budget resets ...") `
                        -ForegroundColor Yellow
                    Start-Sleep -Seconds $crashAction.DelaySeconds
                }
                'Stop' {
                    # 401 / permission-403 will not self-heal on retry - looping
                    # would just burn the API budget against a config error.
                    # Stop loudly so the operator fixes the App credentials /
                    # Owner in the vault and relaunches.
                    Write-Host ('GitHub authentication failed - the App credentials or ' +
                        'the configured Owner are wrong. Fix the vault config, then ' +
                        'restart the agent. Stopping.') -ForegroundColor Red
                    return
                }
                'Restart' {
                    Write-Host "Restarting in $($crashAction.DelaySeconds) seconds ..." `
                        -ForegroundColor Yellow
                    Start-Sleep -Seconds $crashAction.DelaySeconds
                }
            }
        }
    }

    Write-Host "Global runtime of $RuntimeHours hour(s) elapsed. Agent stopping." `
        -ForegroundColor Yellow
}
