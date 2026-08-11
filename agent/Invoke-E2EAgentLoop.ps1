<#
.NOTES
    Dot-sourced by Start-E2EAgent.ps1's runtime body and by
    Invoke-E2EAgentLoop.Tests.ps1. Kept in its own file so the polling
    loop is unit-testable without the vault-reading bootstrap.

    Depends on Get-RefreshedDeploymentToken (the caller dot-sources it
    too) plus the GitHub-facing cmdlets (Get-GitHubAppToken,
    Get-PendingDeployment, Set-DeploymentStatus) and Assert-WslHasBash,
    which the runtime body loads via the module bootstrap and the tests
    stub.
#>

# ---------------------------------------------------------------------------
# Invoke-E2EAgentLoop
#   Core polling loop. Runs until $Deadline, processing every pending
#   deployment in the order returned by Get-PendingDeployment (oldest
#   first). After each deployment (pass or fail) the loop re-polls
#   immediately to drain the queue before sleeping again.
#
#   Lifecycle test failures do not propagate - the deployment is marked
#   'failure' on GitHub and polling resumes. Structural errors (token
#   refresh, GitHub API) propagate to the caller for restart handling.
#
#   Isolated from the vault-reading bootstrap so it can be unit-tested
#   without a real vault. $Deadline is injectable for tests; production
#   code passes [DateTime]::MinValue and lets the function compute it
#   from $TimeoutMinutes.
# ---------------------------------------------------------------------------

function Invoke-E2EAgentLoop {
    [CmdletBinding()]
    param(
        # GitHub App credentials - used to obtain both the deployment token
        # (E2EInstallationId) and passed through to the lifecycle test for
        # runner token acquisition (RunnersInstallationId).
        [Parameter(Mandatory)]
        [int] $AppId,

        # Installation ID for the Infrastructure-E2E repo.
        # Used to obtain a token with deployments:write permission.
        [Parameter(Mandatory)]
        [int] $E2EInstallationId,

        # Installation ID for the Infrastructure-GitHubRunners repo.
        # Passed to the lifecycle test so it can mint a token scoped to
        # administration:write on that repo only.
        [Parameter(Mandatory)]
        [int] $RunnersInstallationId,

        # Local path to the GitHub App RSA private key (.pem).
        [Parameter(Mandatory)]
        [string] $PrivateKeyPath,

        # Absolute path to the Infrastructure-Vm-Provisioner repo root on
        # the workstation. Passed to the lifecycle test so it can call
        # provision.ps1 and deprovision.ps1.
        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # Absolute path to the Infrastructure-Vm-Users repo root on the
        # workstation. Passed to the lifecycle test so it can call
        # create-users.ps1 (when UsersFlow=custom-powershell) and
        # remove-users.ps1 (always - the teardown half stays on the
        # Vm-Users path for both flows until feature 03 ships).
        [Parameter(Mandatory)]
        [string] $UsersPath,

        # Selects which create-users implementation the test layer
        # dispatches to. 'ansible' is the post-feature-02 default;
        # 'custom-powershell' opts back in to the original Vm-Users path
        # for parallel validation. Both are permanent first-class peers.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $UsersFlow = 'ansible',

        # Selects which register-runners implementation the runner
        # lifecycle test dispatches to. 'ansible' (the default) runs
        # Infrastructure-GitHubRunners'
        # hyper-v/ubuntu/Ansible/ops/register-runners.sh.
        # 'custom-powershell' opts back in to the same repo's
        # register-runners.ps1 for parallel validation. Both are permanent
        # first-class peers.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $RunnersFlow = 'ansible',

        # Selects which engine puts the jdk / dotnet toolchains on the VM
        # during the provisioning phases. 'ansible' (the default) drives
        # Infrastructure-Vm-Provisioner's
        # hyper-v/ubuntu/Ansible/ops/provision-toolchains.sh against the
        # Common-Ansible jdk / dotnet_sdk / dotnet_tools roles.
        # 'custom-powershell' opts back in to the PowerShell reconciler,
        # which installs them via the javaDevKit / dotnetSdk / dotnetTools
        # blocks in VmProvisionerConfig inside provision.ps1. The same jdk /
        # dotnet end-state assertions run across both engines, so the two
        # are measured against one bar. Both are permanent first-class peers.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $ToolchainsFlow = 'ansible',

        # Selects which engine transports each VM's operator-declared `files`
        # entries during the provisioning phases. 'ansible' (the default)
        # drives Infrastructure-Vm-Provisioner's
        # hyper-v/ubuntu/Ansible/ops/provision-files.sh against the
        # Common-Ansible vm_files / files_report roles, pushing bytes through
        # the SSH channel. 'custom-powershell' opts back in to provision.ps1's
        # in-line transport, which serves the same files off a host-side
        # HttpListener the VM curls from. Both engines land the same on-VM end
        # state, so one shared set of file-transfer assertions runs across both.
        # Both are permanent first-class peers.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $FilesFlow = 'ansible',

        # Name of the WSL distro to run the Ansible bridge inside. Passed
        # via `wsl -d <name>` so the agent does not depend on the
        # workstation's WSL default - Docker Desktop's installer silently
        # changes the default to its no-bash `docker-desktop` engine
        # distro, which broke this code path until the explicit -d was
        # added. Required whenever any of UsersFlow / RunnersFlow /
        # ToolchainsFlow / FilesFlow is 'ansible' - all four default to
        # 'ansible', so WslDistro is required unless a layer is set to
        # custom-powershell.
        # Each ansible
        # wrapper (create/remove-users.sh in Vm-Users, register-runners.sh
        # in GitHubRunners, provision-toolchains.sh and provision-files.sh in
        # Vm-Provisioner)
        # self-resolves the Common-Ansible substrate as a sibling checkout,
        # so no Common-Ansible path is threaded through this loop.
        [Parameter()]
        [string] $WslDistro,

        # Absolute path to the Infrastructure-GitHubRunners repo root on
        # the workstation. Passed to the lifecycle test so it can call
        # register-runners.ps1 and deregister-runners.ps1.
        [Parameter(Mandatory)]
        [string] $RunnersPath,

        # Local directory on the workstation where the actions/runner tarball
        # is cached between test runs. Passed to the lifecycle test so it can
        # pre-seed the VM cache without downloading through the Hyper-V NAT.
        [Parameter(Mandatory)]
        [string] $HostTarballCachePath,

        # Operator-specific VM config for the E2E test VM. Contains the
        # workstation-specific values (IP, gateway, paths) that cannot be
        # hardcoded. Written to the VmProvisioner vault at test startup.
        [Parameter(Mandatory)]
        [PSCustomObject] $TestVm,

        # GitHub organisation or user that owns the E2E repo.
        [Parameter(Mandatory)]
        [string] $Owner,

        # Name of the E2E repository (without the owner prefix).
        [Parameter(Mandatory)]
        [string] $Repo,

        # Deployment environment name to poll.
        # Must match the 'environment' field set when the workflow creates
        # the deployment.
        [Parameter(Mandatory)]
        [string] $Environment,

        # Seconds to wait between polls when no deployment is found.
        [Parameter(Mandatory)]
        [int] $PollIntervalSeconds,

        # How far back (in hours) Get-PendingDeployment looks when deciding
        # which deployments are worth a status check. GitHub never deletes
        # deployments, so status-checking every one each tick is an N+1
        # fan-out; a short lookback keeps a quiet poll to a single list call.
        # The only hard requirement is lookback >= the GitHub-side wait
        # window, so a deployment still being waited on is never skipped:
        # e2e.yml polls for 30 min before giving up. 1h is the smallest
        # whole-hour value comfortably above that window. Vault-overridable.
        [Parameter()]
        [int] $DeploymentLookbackHours = 1,

        # Maximum minutes to poll before giving up and exiting cleanly.
        [Parameter(Mandatory)]
        [int] $TimeoutMinutes,

        # Injectable deadline for unit tests. Pass [DateTime]::MinValue
        # (the default) to have the function compute it from $TimeoutMinutes.
        [Parameter()]
        [DateTime] $Deadline = [DateTime]::MinValue
    )

    if ($Deadline -eq [DateTime]::MinValue) {
        $Deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    }

    # Fail-fast: validate WslDistro at startup so a misconfigured session
    # does not build a VM and only then discover the bridge is
    # unreachable. custom-powershell ignores it; only the ansible flow on
    # either layer needs it. Each ansible wrapper self-resolves the
    # Common-Ansible substrate, so there is no path to validate here.
    #
    # WslDistro is verified up-front via Assert-WslHasBash from
    # Common.PowerShell - that catches the docker-desktop-default trap
    # (no bash) named in the parameter docs, and surfaces a
    # WslMissingBash: error with a remediation hint instead of letting
    # the bridge fail mid-test with a sparse-PATH error.
    $ansibleFlows = @()
    if ($UsersFlow      -eq 'ansible') { $ansibleFlows += 'UsersFlow' }
    if ($RunnersFlow    -eq 'ansible') { $ansibleFlows += 'RunnersFlow' }
    if ($ToolchainsFlow -eq 'ansible') { $ansibleFlows += 'ToolchainsFlow' }
    if ($FilesFlow      -eq 'ansible') { $ansibleFlows += 'FilesFlow' }
    if ($ansibleFlows.Count -gt 0) {
        $flowList = $ansibleFlows -join '/'
        if (-not $WslDistro) {
            throw "${flowList}='ansible' requires -WslDistro."
        }
        Assert-WslHasBash -DistroName $WslDistro
    }

    # Derive display value from the resolved Deadline so injected deadlines
    # (e.g. in tests) show accurate output rather than the TimeoutMinutes param.
    $totalMinutes = [int]($Deadline - [DateTime]::UtcNow).TotalMinutes

    Write-Host "E2E agent started. Polling '$Environment' in $Owner/$Repo." `
        -ForegroundColor Cyan
    Write-Host "Poll interval: ${PollIntervalSeconds}s   Timeout: ${totalMinutes}min" `
        -ForegroundColor Cyan

    # Acquire the initial deployment token. The token lasts 1 hour; the
    # refresh block inside the loop handles long poll waits near that boundary.
    $tokenResult = Get-GitHubAppToken `
        -AppId          $AppId `
        -InstallationId $E2EInstallationId `
        -PrivateKeyPath $PrivateKeyPath

    while ([DateTime]::UtcNow -lt $Deadline) {
        # Refresh the deployment token if fewer than 5 minutes remain so a
        # long poll wait does not produce a stale-token failure mid-poll.
        $tokenResult = Get-RefreshedDeploymentToken `
            -TokenResult    $tokenResult `
            -AppId          $AppId `
            -InstallationId $E2EInstallationId `
            -PrivateKeyPath $PrivateKeyPath

        # Recompute the cutoff each tick so the lookback window tracks the
        # wall clock rather than freezing at loop entry. Deployments older
        # than this are skipped without an API call - see the N+1 note on
        # $DeploymentLookbackHours above.
        $createdSince = [DateTime]::UtcNow.AddHours(-$DeploymentLookbackHours)

        $deployment = Get-PendingDeployment `
            -Token        $tokenResult.Token `
            -Owner        $Owner `
            -Repo         $Repo `
            -Environment  $Environment `
            -CreatedSince $createdSince

        if ($null -ne $deployment) {
            Write-Host "Deployment $($deployment.id) found - running E2E tests ..." `
                -ForegroundColor Green

            # Sourced per deployment so test-code edits land in the
            # next iteration without a process restart. PowerShell
            # binds function defs at dot-source time and does not
            # reload them on its own.
            . "$PSScriptRoot\e2e\runner-lifecycle\Invoke-RunnerLifecycleTest.ps1"

            try {
                # Post in_progress inside the try so a status-write failure
                # (e.g. a 401 from a stale token / wrong Owner) marks this
                # deployment failed and lets the loop continue, instead of
                # escaping to the restart handler and crash-looping the agent.
                Set-DeploymentStatus `
                    -Token        $tokenResult.Token `
                    -Owner        $Owner `
                    -Repo         $Repo `
                    -DeploymentId $deployment.id `
                    -State        'in_progress' `
                    -Description  'E2E tests running'

                # Per-run flow override.
                #   The calling repo's PR encodes which create/remove
                #   implementation each layer should exercise in the
                #   deployment payload (set by .github/workflows/e2e.yml
                #   from its flow-spec input). A custom-powershell repo's PR
                #   thus tests its own path while ansible stays the default
                #   scenario. Absent payload (manual deployments, older
                #   callers) keeps the session flows read from the vault.
                #   Parsing/validation runs inside this try so a malformed
                #   spec posts a 'failure' status instead of crashing the
                #   agent. Guarded property access is required under
                #   Set-StrictMode -Latest.
                $effectiveUsersFlow      = $UsersFlow
                $effectiveRunnersFlow    = $RunnersFlow
                $effectiveToolchainsFlow = $ToolchainsFlow
                $effectiveFilesFlow      = $FilesFlow
                if ($deployment.PSObject.Properties['payload'] -and $deployment.payload) {
                    $payload = $deployment.payload
                    # GitHub returns the payload as a parsed object when it
                    # was created as JSON; tolerate a raw JSON string too.
                    if ($payload -is [string]) { $payload = $payload | ConvertFrom-Json }
                    if ($payload.PSObject.Properties['usersFlow']   -and $payload.usersFlow) {
                        $effectiveUsersFlow   = $payload.usersFlow
                    }
                    if ($payload.PSObject.Properties['runnersFlow'] -and $payload.runnersFlow) {
                        $effectiveRunnersFlow = $payload.runnersFlow
                    }
                    if ($payload.PSObject.Properties['toolchainsFlow'] -and $payload.toolchainsFlow) {
                        $effectiveToolchainsFlow = $payload.toolchainsFlow
                    }
                    if ($payload.PSObject.Properties['filesFlow'] -and $payload.filesFlow) {
                        $effectiveFilesFlow = $payload.filesFlow
                    }
                    Write-Host ("Flow spec from payload: UsersFlow=$effectiveUsersFlow " +
                        "RunnersFlow=$effectiveRunnersFlow " +
                        "ToolchainsFlow=$effectiveToolchainsFlow " +
                        "FilesFlow=$effectiveFilesFlow") -ForegroundColor Cyan
                }

                # Validate the effective flows. An unknown value fails loud
                # here rather than as a sparse ValidateSet error deep in a
                # dispatcher. An 'ansible' effective flow re-asserts the
                # WslDistro prerequisite: the startup check only covered the
                # session defaults, so a payload that upgrades a layer to
                # ansible (vault set custom-powershell) must still have a
                # usable bridge or it would fail mid-test.
                foreach ($pair in @(
                        @{ Name = 'usersFlow';      Value = $effectiveUsersFlow },
                        @{ Name = 'runnersFlow';    Value = $effectiveRunnersFlow },
                        @{ Name = 'toolchainsFlow'; Value = $effectiveToolchainsFlow },
                        @{ Name = 'filesFlow';      Value = $effectiveFilesFlow })) {
                    if ($pair.Value -notin @('custom-powershell', 'ansible')) {
                        throw ("Invalid $($pair.Name) '$($pair.Value)' in deployment " +
                            "payload; expected 'custom-powershell' or 'ansible'.")
                    }
                }
                if ($effectiveUsersFlow -eq 'ansible' -or $effectiveRunnersFlow -eq 'ansible' -or
                    $effectiveToolchainsFlow -eq 'ansible' -or $effectiveFilesFlow -eq 'ansible') {
                    if (-not $WslDistro) {
                        throw "Effective flow is 'ansible' but WslDistro is not set."
                    }
                }

                Invoke-RunnerLifecycleTest -Config ([PSCustomObject]@{
                    AppId                 = $AppId
                    RunnersInstallationId = $RunnersInstallationId
                    PrivateKeyPath        = $PrivateKeyPath
                    ProvisionerPath       = $ProvisionerPath
                    UsersPath             = $UsersPath
                    UsersFlow             = $effectiveUsersFlow
                    WslDistro             = $WslDistro
                    RunnersPath           = $RunnersPath
                    RunnersFlow           = $effectiveRunnersFlow
                    ToolchainsFlow        = $effectiveToolchainsFlow
                    FilesFlow             = $effectiveFilesFlow
                    HostTarballCachePath  = $HostTarballCachePath
                    Owner                 = $Owner
                    TestVm                = $TestVm
                })

                # The lifecycle run above can span most of the token's
                # 1-hour life, so re-mint if it is now near expiry before
                # posting the terminal status (otherwise: 401).
                $tokenResult = Get-RefreshedDeploymentToken `
                    -TokenResult    $tokenResult `
                    -AppId          $AppId `
                    -InstallationId $E2EInstallationId `
                    -PrivateKeyPath $PrivateKeyPath

                Set-DeploymentStatus `
                    -Token        $tokenResult.Token `
                    -Owner        $Owner `
                    -Repo         $Repo `
                    -DeploymentId $deployment.id `
                    -State        'success' `
                    -Description  'All E2E tests passed'

                Write-Host 'E2E tests passed.' -ForegroundColor Green
            }
            catch {
                # GitHub caps deployment status descriptions at 140 characters.
                $msg = $_.Exception.Message
                $description = if ($msg.Length -gt 140) { $msg.Substring(0, 137) + '...' } else { $msg }

                try {
                    # Same expiry risk as the success path: a long (or hung)
                    # run can outlast the token, so re-mint if near expiry
                    # before posting failure. Inside this try so a refresh
                    # that itself fails degrades to the warning below rather
                    # than escaping to the restart handler.
                    $tokenResult = Get-RefreshedDeploymentToken `
                        -TokenResult    $tokenResult `
                        -AppId          $AppId `
                        -InstallationId $E2EInstallationId `
                        -PrivateKeyPath $PrivateKeyPath

                    Set-DeploymentStatus `
                        -Token        $tokenResult.Token `
                        -Owner        $Owner `
                        -Repo         $Repo `
                        -DeploymentId $deployment.id `
                        -State        'failure' `
                        -Description  $description
                }
                catch {
                    Write-Host "Warning: failed to post failure status to GitHub: $($_.Exception.Message)" `
                        -ForegroundColor Yellow
                }

                Write-Host "E2E tests failed: $msg" -ForegroundColor Red
                continue
            }

            continue
        }

        $remaining = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMinutes)
        Write-Host ("[$(Get-Date -Format 'HH:mm:ss')] No pending deployment. " +
            "${remaining}min remaining. Waiting ${PollIntervalSeconds}s ...") `
            -ForegroundColor DarkGray

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Host "Agent timed out after $totalMinutes minutes - no deployment found." `
        -ForegroundColor Yellow
}
