<#
.NOTES
    Do not run this file directly. Dot-source it after Common.PowerShell
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this).
#>

. "$PSScriptRoot\..\vm-users\Invoke-VmUsersTest.ps1"

# End-of-run timing emission (report + rolling JSON artifact + retention).
# Dot-sourced here because this file's outer finally is the single point that
# fires on every exit path (success, failure, best-effort cleanup).
. "$PSScriptRoot\..\timing\Publish-E2ETimingReport.ps1"

# Register-side dispatcher: symmetric peer of Set-VmUsersForTest, selecting
# between Infrastructure-GitHubRunners' register-runners.ps1 and its
# hyper-v/ubuntu/Ansible/ops/register-runners.sh. The lifecycle test
# forwards $Config.RunnersFlow into this single switch point.
. "$PSScriptRoot\Set-VmRunnersForTest.ps1"

# Shared GitHub-side poll used by both the post-register check below and the
# post-re-provision check in Invoke-RunnerStillOnlineAssertions.ps1.
. "$PSScriptRoot\Wait-RunnerOnlineRegistration.ps1"

# Lightweight re-verification of the runner after a re-provision (phase 2
# or phase 3). Confirms the systemd service is still active and the
# runner still appears 'online' in GitHub.
. "$PSScriptRoot\Invoke-RunnerStillOnlineAssertions.ps1"

# ---------------------------------------------------------------------------
# Assert-RunnerStillOnline
#   Opens a fresh SSH session to the VM and re-asserts that the runner
#   systemd service is still active and the runner is still 'online' in
#   GitHub. Pairs with Invoke-RunnerStillOnlineAssertions; this wrapper
#   owns the SSH connection lifecycle so callers between provisioning
#   phases do not re-implement the connect/dispose pattern.
# ---------------------------------------------------------------------------

function Assert-RunnerStillOnline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $VmDef,
        [Parameter(Mandatory)] [string]         $RunnerName,
        [Parameter(Mandatory)] [string]         $RunnersToken,
        [Parameter(Mandatory)] [string]         $GithubUrl
    )

    Write-Host "Re-asserting runner on $($VmDef.vmName) ..." -ForegroundColor Magenta

    $sshSession = $null
    try {
        $sshSession = New-VmSshClientWithJump -Vm $VmDef
        Invoke-RunnerStillOnlineAssertions `
            -SshClient    $sshSession.Client `
            -VmName       $VmDef.vmName `
            -RunnerName   $RunnerName `
            -RunnersToken $RunnersToken `
            -GithubUrl    $GithubUrl
    }
    finally {
        if ($null -ne $sshSession) {
            try { $sshSession.Dispose() } catch { Write-Verbose "Ignoring SSH session dispose failure: $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------------------
# Get-E2ERunnerUsersEntry
#   Returns the VmUsersConfig entry for the runner lifecycle test. Extends
#   the base users entry (from Get-E2EUsersTestEntry) with:
#     - e2edeploy  - SSH deploy user that installs and registers the runner.
#                    Must have a password so Read-VmDeployPasswords can index
#                    it; full passwordless sudo so register-runners.ps1 can
#                    run config.sh as the runner user and svc.sh as root.
#     - e2erunner  - Service user that owns the runner binary and systemd
#                    unit. No password (service account, no interactive
#                    login needed).
#
#   DeployPassword is generated fresh per test run by
#   Invoke-RunnerLifecycleSetup so the credential never lives in source code
#   or a config file.
# ---------------------------------------------------------------------------

function Get-E2ERunnerUsersEntry {
    # SSH.NET PasswordAuthenticationMethod and the VmUsersConfig JSON schema
    # both require plain strings. The password is generated once per test
    # run, never written to source or disk, and discarded when the VM is
    # destroyed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'DeployPassword')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DeployPassword
    )

    $base = Get-E2EUsersTestEntry

    return [ordered]@{
        vmName = $base.vmName
        groups = @($base.groups)
        users  = @(
            # Preserve the base test user (e2euser) from the users layer.
            @($base.users)[0],
            # Deploy user: SSH access + the canonical narrowly-scoped
            # NOPASSWD grants required by register-runners.ps1 /
            # deregister-runners.ps1. Mirrors the production rules
            # documented in Infrastructure-Vm-Users README so this E2E
            # exercises the same sudoers surface as prod - a blanket
            # NOPASSWD: ALL would mask missing grants that would fail in
            # production (e.g. a new 'sudo chmod' or 'sudo rm' that has
            # no corresponding rule).
            [ordered]@{
                username     = 'e2edeploy'
                shell        = '/bin/bash'
                homeDir      = '/home/e2edeploy'
                groups       = @()
                sudoersRules = @(
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /usr/bin/mkdir',
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /usr/bin/rm',
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /usr/bin/curl',
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /usr/bin/tar',
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /usr/bin/test',
                    'e2edeploy ALL=(root) NOPASSWD: /usr/bin/mkdir',
                    'e2edeploy ALL=(root) NOPASSWD: /usr/bin/chown',
                    'e2edeploy ALL=(root) NOPASSWD: /usr/bin/rm -rf /opt/runners/*',
                    'e2edeploy ALL=(e2erunner) NOPASSWD: /opt/runners/*/config.sh',
                    'e2edeploy ALL=(root) NOPASSWD: /opt/runners/*/svc.sh',
                    'e2edeploy ALL=(root) NOPASSWD: /bin/systemctl start actions.runner.*',
                    'e2edeploy ALL=(root) NOPASSWD: /bin/systemctl stop actions.runner.*',
                    'e2edeploy ALL=(root) NOPASSWD: /bin/systemctl is-active actions.runner.*'
                )
                password     = $DeployPassword
            },
            # Runner service user: owns runner files and the systemd unit.
            #
            # 'docker' is required, not optional. The register flow asserts
            # every runner user is in that group before it will register
            # (GitHubRunners playbooks/tasks/_assert-docker-socket-access.yml),
            # because container-based CI composites need /var/run/docker.sock.
            #
            # It has to be granted HERE specifically. Ownership of the grant is
            # split across three repos: Vm-Provisioner installs the daemon and
            # creates the group but leaves membership empty; Vm-Users is the
            # single authority for supplementary groups and sets them with
            # `append: false`, so this list IS the user's complete set and a
            # membership added anywhere else is stripped on the next reconcile;
            # GitHubRunners only asserts. Granting it in the runner flow would
            # look like a fix and silently regress one reconcile later.
            #
            # The ordering that makes this work is Invoke-VmUsersSetup's:
            # provisioning Phase 1 (which installs docker via the sections-2/3
            # taxonomy block) runs BEFORE the user reconcile, so the group
            # exists by the time this list is applied.
            [ordered]@{
                username = 'e2erunner'
                shell    = '/bin/bash'
                homeDir  = '/home/e2erunner'
                groups   = @('docker')
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Get-E2ERunnersConfigEntry
#   Returns the GitHubRunnersConfig array written to the GitHubRunners vault
#   by Invoke-RunnerLifecycleSetup. The runner registers against the repo
#   whose name is the last path component of Config.RunnersPath - the same
#   convention used when cloning the repo (directory name == repo name).
#
#   VM1's IP is taken from $script:Vm1Ip (the test's internal private-
#   subnet IP, 10.99.0.10). Operator config carries only the router VM's
#   upstream IP now; downstream IPs are constants chosen by the test
#   fixture to live on the per-environment private switch.
# ---------------------------------------------------------------------------

function Get-E2ERunnersConfigEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $runnersRepo = Split-Path $Config.RunnersPath -Leaf

    # The leading comma wraps the array in a second array so PowerShell's
    # automatic pipeline unwrapping strips only the outer layer on
    # assignment. Without it, a single-element @([ordered]@{}) unwraps to
    # the OrderedDictionary itself and $result[0] returns the first value
    # rather than the first element.
    return , @(
        [ordered]@{
            vmName         = $script:Vm1Name
            ipAddress      = $script:Vm1Ip
            deployUsername = 'e2edeploy'
            runnerUsername = 'e2erunner'
            githubUrl      = "https://github.com/$($Config.Owner)/$runnersRepo"
            runnerName     = 'e2e-runner'
            runnerLabels   = @('e2e', 'self-hosted', 'linux')
        }
    )
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleSetup
#   Brings up the pre-registration stack:
#     1. Generate a throw-away deploy password (never stored in source).
#     2. Write GitHubRunnersConfig to the GitHubRunners vault.
#     3. Provision the VM and create users via Invoke-VmUsersSetup (extended
#        entry includes e2edeploy and e2erunner on top of the base users).
#     4. Acquire a short-lived GitHub App token for the runners installation.
#
#   Tarball prefetch, VM-side caching, runner registration, and service start
#   are all handled by register-runners.ps1 (the production script), which the
#   caller invokes immediately after this function returns.
#
#   Returns a PSCustomObject with VmDef, RunnersToken, and Entry so the
#   caller can pass the token to register-runners.ps1 and supply state to
#   teardown.
#
#   Teardown counterpart: Invoke-RunnerLifecycleTeardown.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config,

        # Timing context owned by Invoke-RunnerLifecycleTest. Forwarded to
        # Invoke-VmUsersSetup so the provision / user-reconcile shell-outs
        # record as spans under this run's 'Setup' node rather than a
        # detached tree.
        [Parameter(Mandatory)]
        [object] $Tree
    )

    # Generate a random deploy password per test run. Hex GUID - no special
    # chars that could confuse chpasswd or SSH.NET.
    $deployPassword = [System.Guid]::NewGuid().ToString('N')
    $entry          = Get-E2ERunnerUsersEntry -DeployPassword $deployPassword

    # Write GitHubRunnersConfig first so register-runners.ps1 finds it.
    Write-Host 'Writing test GitHubRunnersConfig to vault ...' -ForegroundColor Magenta
    $runnersEntries = Get-E2ERunnersConfigEntry -Config $Config
    Set-Secret `
        -Vault  GitHubRunners `
        -Name   (Get-E2ESecretName 'GitHubRunnersConfig') `
        -Secret (ConvertTo-Json $runnersEntries -Depth 5 -Compress)

    # Provision VM, create all users (base + e2edeploy + e2erunner).
    # -Tree threads the run's timing context so the provision and
    # user-reconcile shell-outs nest under this run's 'Setup' span.
    $vmDef = Invoke-VmUsersSetup -Config $Config -Entry $entry -Tree $Tree

    # Mint a token scoped to Infrastructure-GitHubRunners with administration:write
    # only. Scoping to one repo and one permission prevents the token from
    # touching the other repos the installation covers, even if the app declares
    # broader permissions.
    Write-Host 'Acquiring GitHub App token for runner registration ...' `
        -ForegroundColor Magenta
    $runnersRepo = Split-Path $Config.RunnersPath -Leaf
    $tokenResult = Get-GitHubAppToken `
        -AppId          $Config.AppId `
        -InstallationId $Config.RunnersInstallationId `
        -PrivateKeyPath $Config.PrivateKeyPath `
        -Repositories   @($runnersRepo) `
        -Permissions    @{ administration = 'write' }

    return [PSCustomObject]@{
        VmDef        = $vmDef
        RunnersToken = $tokenResult.Token
        Entry        = $entry
    }
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleTeardown
#   Tears down the full lifecycle stack in reverse order:
#     1. Deregister runners from GitHub and remove runner files via
#        deregister-runners.ps1 (-Force ensures cleanup even when the runner
#        service is down after a mid-test failure).
#     2. Remove OS users and VM via Invoke-VmUsersTeardown (extended entry).
#     3. Remove GitHubRunnersConfig from the vault.
#
#   Order rationale:
#     - Deregister first: runner service and GitHub registration are removed
#       while the VM is still alive so deregister-runners.ps1 can use SSH.
#     - VmUsersTeardown second: VM is still alive for OS-level assertions,
#       then destroyed.
#     - Vault cleanup last: vault entries are valid until all dependents are
#       gone.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config,

        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef,

        # Token acquired during setup. Valid for 1 hour; test runs are
        # expected to complete well within that window.
        [Parameter(Mandatory)]
        [string] $RunnersToken,

        # Full VmUsersConfig entry (base + deploy + runner users). Passed to
        # Invoke-VmUsersTeardown so it can assert all users are gone.
        [Parameter(Mandatory)]
        [object] $Entry
    )

    Write-Host 'Deregistering runners ...' -ForegroundColor Magenta
    # -Force: if the runner service crashed mid-test, -Force removes the
    # GitHub registration via the API without SSH access.
    & "$($Config.RunnersPath)\hyper-v\ubuntu\PowerShell\deregister-runners.ps1" `
        -Token $RunnersToken `
        -SecretSuffix $script:E2ETestSecretSuffix `
        -Force

    $configEntry = Get-E2ERunnersConfigEntry -Config $Config
    $runnerName  = $configEntry[0].runnerName

    # Assert runner service is gone and runner directory is removed - while
    # the VM is still alive so we can SSH in. Must run before
    # Invoke-VmUsersTeardown destroys the VM.
    Write-Host "Verifying runner deregistration: $($VmDef.vmName) at $($VmDef.ipAddress) ..." `
        -ForegroundColor Magenta

    $sshSession = $null

    try {
        $sshSession = New-VmSshClientWithJump -Vm $VmDef
        $sshClient  = $sshSession.Client

        # Runner service unit must be gone. deregister-runners.ps1 runs
        # svc.sh uninstall which removes the unit file.
        $nameResult  = Invoke-SshClientCommand `
            -SshClient $sshClient `
            -Command   ("systemctl list-unit-files --no-legend " +
                        "--type=service 'actions.runner.*' " +
                        "| grep -F '.$runnerName.'")
        $serviceLine = ($nameResult.Output -join '').Trim()
        if ($serviceLine) {
            throw ("Teardown incomplete: runner service for '$runnerName' " +
                "still installed on $($VmDef.vmName): $serviceLine")
        }
        Write-Host "  [OK] runner service removed from $($VmDef.vmName)." `
            -ForegroundColor Green

        # Runner directory must be gone. deregister-runners.ps1 removes
        # files via Remove-RunnerFiles after config.sh remove.
        $runnerDir   = "/opt/runners/$runnerName"
        $dirResult   = Invoke-SshClientCommand `
            -SshClient $sshClient `
            -Command   "test -d '$runnerDir' && echo exists || echo absent"
        if (($dirResult.Output -join '').Trim() -ne 'absent') {
            throw ("Teardown incomplete: runner directory '$runnerDir' " +
                "still exists on $($VmDef.vmName).")
        }
        Write-Host "  [OK] runner directory removed from $($VmDef.vmName)." `
            -ForegroundColor Green
    }
    finally {
        if ($null -ne $sshSession) {
            try { $sshSession.Dispose() } catch { Write-Verbose "Ignoring SSH session dispose failure: $($_.Exception.Message)" }
        }
    }

    # Assert runner is no longer registered on GitHub. This must succeed
    # whether the VM was reachable or not (-Force handles the unreachable case).
    Write-Host 'Verifying runner deregistered from GitHub API ...' -ForegroundColor Magenta
    $githubUrl    = $configEntry[0].githubUrl
    $parts        = $githubUrl.TrimEnd('/') -split '/'
    $apiOwner     = $parts[-2]
    $apiRepo      = $parts[-1]
    $response     = Invoke-GitHubApi `
        -Token    $RunnersToken `
        -Endpoint "repos/$apiOwner/$apiRepo/actions/runners?per_page=100"
    $registration = @($response.runners) |
        Where-Object { $_.name -eq $runnerName } |
        Select-Object -First 1
    if ($null -ne $registration) {
        throw ("Teardown incomplete: runner '$runnerName' still registered " +
            "on GitHub (status: $($registration.status)).")
    }
    Write-Host "  [OK] runner '$runnerName' removed from GitHub." -ForegroundColor Green

    Invoke-VmUsersTeardown -Config $Config -VmDef $VmDef -Entry $Entry

    Write-Host 'Removing test GitHubRunnersConfig from vault ...' -ForegroundColor Magenta
    Remove-Secret -Vault GitHubRunners -Name (Get-E2ESecretName 'GitHubRunnersConfig')
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleTest
#   Full E2E test covering provisioning, user setup, and runner lifecycle.
#   Sets up the stack via Invoke-RunnerLifecycleSetup, asserts:
#     1. Runner systemd service is active on the VM (SSH check).
#     2. Runner appears online in the GitHub API.
#   Then tears down regardless of outcome.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config,

        # Timing context for the run. Defaults to a fresh runner-lifecycle
        # tree; each phase and part below records as a span so the report
        # (feature 88 C3) shows the phase/part breakdown. Injectable so a
        # caller - or a test - can observe the accumulated tree after the
        # run, including on the failure path where a return value is lost
        # to the re-thrown exception.
        [object] $Tree = $null
    )

    if ($null -eq $Tree) {
        $Tree = New-TimingSpanTree -RootName 'runner-lifecycle'
    }

    $vmDef        = $null
    $runnersToken = $null
    $entry        = $null
    $succeeded    = $false

    try {
        # Setup phase: pre-registration stack (config, provision, users,
        # token). Its provision / user-reconcile shell-outs nest as parts
        # under this span via the threaded $Tree.
        $setup        = Measure-TimingSpan -Tree $Tree -Name 'Setup' -Action {
            Invoke-RunnerLifecycleSetup -Config $Config -Tree $Tree
        }
        $vmDef        = $setup.VmDef
        $runnersToken = $setup.RunnersToken
        $entry        = $setup.Entry

        $configEntry = Get-E2ERunnersConfigEntry -Config $Config
        $runnerName  = $configEntry[0].runnerName

        # Registration starts here - $runnersToken is already assigned so the
        # finally block can call deregister-runners.ps1 even if this fails
        # mid-way (e.g. config.sh succeeds but svc.sh fails).
        Write-Host "Registering runners via '$($Config.RunnersFlow)' flow ..." `
            -ForegroundColor Magenta
        # $Config carries RunnersFlow + WslDistro from Start-E2EAgent.
        # WslDistro is optional in the dispatcher and ignored unless
        # RunnersFlow=ansible; the agent-loop validates its presence at
        # startup so a missing value fails before the VM is built. The
        # ansible flow resolves register-runners.sh under $RunnersPath
        # (GitHubRunners), which self-resolves the Common-Ansible substrate.
        # Wrapped so register-runners' own exported timing tree grafts under
        # this span once its emitter ships (feature 88 C2/D2).
        Measure-ChildProcessTimingSpan -Tree $Tree -Name 'Register runners' -Action {
            Set-VmRunnersForTest `
                -RunnersFlow  $Config.RunnersFlow `
                -RunnersPath  $Config.RunnersPath `
                -WslDistro    $Config.WslDistro `
                -Token        $runnersToken `
                -SecretSuffix $script:E2ETestSecretSuffix `
                -VmDef        $vmDef `
                -Entry        $configEntry
        }

        # Verify-online phase: the runner service is installed and active
        # on the VM (SSH) and the runner reports 'online' in the GitHub
        # API. Wrapped as one span; a not-installed / not-active / offline
        # failure marks it Failed and the report shows how far the run got.
        Measure-TimingSpan -Tree $Tree -Name 'Verify online' -Action {
            Write-Host "Verifying runner service: $($vmDef.vmName) at $($vmDef.ipAddress) ..." `
                -ForegroundColor Magenta

            $sshClient = $null

            try {
                $sshSession = New-VmSshClientWithJump -Vm $vmDef
                $sshClient  = $sshSession.Client

                # Resolve the full systemd unit name. svc.sh names it
                # 'actions.runner.{owner}-{repo}.{runnerName}.service'.
                # Matching on '.$runnerName.' avoids false positives when
                # one runner name is a prefix of another.
                $nameResult = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   ("systemctl list-unit-files --no-legend " +
                                "--type=service 'actions.runner.*' " +
                                "| grep -F '.$runnerName.'")
                $serviceLine = ($nameResult.Output -join '').Trim()
                if (-not $serviceLine) {
                    throw ("Runner service for '$runnerName' not found on " +
                        "$($vmDef.vmName) - svc.sh may not have run.")
                }
                $serviceName = ($serviceLine -split '\s+')[0]
                Write-Host "  [OK] runner service installed: $serviceName" `
                    -ForegroundColor Green

                $activeResult = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "systemctl is-active '$serviceName'"
                if (($activeResult.Output -join '').Trim() -ne 'active') {
                    throw ("Runner service '$serviceName' is not active on " +
                        "$($vmDef.vmName). " +
                        "Check: journalctl -u '$serviceName'")
                }
                Write-Host '  [OK] runner service active.' -ForegroundColor Green
            }
            finally {
                if ($null -ne $sshSession) {
                    try { $sshSession.Dispose() } catch { Write-Verbose "Ignoring SSH session dispose failure: $($_.Exception.Message)" }
                }
            }

            # Assert runner online via GitHub API.
            # The runner service needs a few seconds after start to open its
            # websocket to GitHub and appear as 'online'. Poll with backoff
            # rather than sleeping a fixed amount - most runs will succeed on
            # the first or second attempt.
            Write-Host 'Verifying runner online via GitHub API ...' -ForegroundColor Magenta
            $githubUrl = $configEntry[0].githubUrl

            # Ten attempts: a cold runner can take the better part of a minute
            # to open its websocket, and this is the one place that waits for
            # it to happen at all.
            $registration = Wait-RunnerOnlineRegistration `
                -RunnersToken $runnersToken `
                -GithubUrl    $githubUrl `
                -RunnerName   $runnerName `
                -MaxAttempts  10

            if ($null -eq $registration) {
                throw "Runner '$runnerName' not found in GitHub API for $githubUrl."
            }
            if ($registration.status -ne 'online') {
                throw ("Runner '$runnerName' status is '$($registration.status)', " +
                    "expected 'online'.")
            }
            Write-Host "  [OK] runner '$runnerName' online in GitHub." -ForegroundColor Green
        }

        # Re-provision phases now run against a fully configured VM
        # (users created, runner registered + online). After each phase
        # re-assert users + runner are still intact so a re-provision
        # regression that disturbs either layer surfaces immediately,
        # not after teardown when only "VMs are gone" can be observed.
        $vm2Def    = $vmDef._SecondaryVm
        $usersEntry = $entry   # captured from Setup; same Entry passed to Teardown
        $githubUrl  = $configEntry[0].githubUrl

        # Phase 2 + reassert: re-provision, then confirm the user and
        # runner layers survived it. A regression in either surfaces as a
        # Failed span here rather than only as "VMs gone" after teardown.
        Measure-TimingSpan -Tree $Tree -Name 'Phase 2 + reassert' -Action {
            # -Tree threads this span's context into the phase so its per-sub-
            # phase provision / toolchains shell-outs nest here as child spans
            # (2a/2b provision + toolchains) instead of the phase running as
            # one flat bar.
            Invoke-VmProvisioningPhase2 -Config $Config -Vm1Def $vmDef -Vm2Def $vm2Def -Tree $Tree
            Measure-TimingSpan -Tree $Tree -Name 'reassert users' -Action {
                Assert-VmUsersStillIntact -Config $Config -VmDef $vmDef -Entry $usersEntry
            }
            Measure-TimingSpan -Tree $Tree -Name 'reassert runner' -Action {
                Assert-RunnerStillOnline  -Config $Config -VmDef $vmDef `
                                          -RunnerName    $runnerName `
                                          -RunnersToken  $runnersToken `
                                          -GithubUrl     $githubUrl
            }
        }

        # Phase 3 + reassert: second re-provision with the same guardrails.
        Measure-TimingSpan -Tree $Tree -Name 'Phase 3 + reassert' -Action {
            # -Tree threads this span's context into the phase so its per-sub-
            # phase provision / toolchains shell-outs nest here as child spans
            # (3a/3b provision + toolchains) instead of the phase running as
            # one flat bar.
            Invoke-VmProvisioningPhase3 -Config $Config -Vm1Def $vmDef -Vm2Def $vm2Def -Tree $Tree
            Measure-TimingSpan -Tree $Tree -Name 'reassert users' -Action {
                Assert-VmUsersStillIntact -Config $Config -VmDef $vmDef -Entry $usersEntry
            }
            Measure-TimingSpan -Tree $Tree -Name 'reassert runner' -Action {
                Assert-RunnerStillOnline  -Config $Config -VmDef $vmDef `
                                          -RunnerName    $runnerName `
                                          -RunnersToken  $runnersToken `
                                          -GithubUrl     $githubUrl
            }
        }

        $succeeded = $true
    }
    catch {
        Write-Host "E2E test error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        # Teardown phase. Timed on both the clean and the best-effort
        # path so every run - pass or fail - contributes a Teardown span
        # to the report. Only one branch runs per invocation, so the
        # by-name accumulation records a single node either way.
        #
        # Wrapped in an inner try/finally so the timing report + rolling
        # artifact still emit even when teardown itself throws (e.g. a
        # success-path post-condition assertion fails): the report must
        # fire on every exit path, and a teardown failure that reaches
        # here still propagates out afterwards as the run's outcome.
        try {
            if ($succeeded) {
                Measure-TimingSpan -Tree $Tree -Name 'Teardown' -Action {
                    Invoke-RunnerLifecycleTeardown `
                        -Config       $Config `
                        -VmDef        $vmDef `
                        -RunnersToken $runnersToken `
                        -Entry        $entry

                    # Provisioning-layer teardown post-conditions (both VMs gone,
                    # per-VM disk artifacts gone, host-side JDK cache intact,
                    # switch + NAT removed, VmProvisionerConfig vault entry gone)
                    # have already been verified - Invoke-RunnerLifecycleTeardown
                    # calls Invoke-VmUsersTeardown, which calls
                    # Invoke-VmProvisioningTeardown, which calls
                    # Invoke-VmTeardownAssertions at the end of its own run.

                    # Assert VmUsersConfig vault entry was removed (vm-users
                    # layer). Mirrors the same check inside the vm-users
                    # standalone teardown.
                    $usersSecretName = Get-E2ESecretName 'VmUsersConfig'
                    if ($null -ne (Get-SecretInfo -Vault VmUsers -Name $usersSecretName `
                            -ErrorAction SilentlyContinue)) {
                        throw "Teardown incomplete: $usersSecretName still present in vault."
                    }
                    Write-Host "  [OK] $usersSecretName removed from vault." -ForegroundColor Green

                    # Assert GitHubRunnersConfig vault entry was removed (runner
                    # layer's own teardown post-condition).
                    $runnersSecretName = Get-E2ESecretName 'GitHubRunnersConfig'
                    if ($null -ne (Get-SecretInfo -Vault GitHubRunners -Name $runnersSecretName `
                            -ErrorAction SilentlyContinue)) {
                        throw "Teardown incomplete: $runnersSecretName still present in vault."
                    }
                    Write-Host "  [OK] $runnersSecretName removed from vault." -ForegroundColor Green
                }
            }
            else {
                Measure-TimingSpan -Tree $Tree -Name 'Teardown' -Action {
                    Write-Host 'Test did not complete - running best-effort cleanup ...' `
                        -ForegroundColor Yellow

                    # Deregister first if we got a token - removes GitHub registration
                    # and runner files while the VM may still be alive.
                    if ($runnersToken) {
                        try {
                            & "$($Config.RunnersPath)\hyper-v\ubuntu\PowerShell\deregister-runners.ps1" `
                                -Token  $runnersToken `
                                -SecretSuffix $script:E2ETestSecretSuffix `
                                -Force
                        }
                        catch {
                            Write-Warning "Best-effort deregistration failed: $($_.Exception.Message)"
                        }
                    }

                    try { Invoke-VmProvisioningTeardown -Config $Config }
                    catch { Write-Warning "Best-effort deprovisioning failed: $($_.Exception.Message)" }

                    try { Remove-Secret -Vault VmUsers -Name (Get-E2ESecretName 'VmUsersConfig') -ErrorAction SilentlyContinue }
                    catch { Write-Warning "Best-effort secret removal failed: $($_.Exception.Message)" }

                    try { Remove-Secret -Vault GitHubRunners -Name (Get-E2ESecretName 'GitHubRunnersConfig') -ErrorAction SilentlyContinue }
                    catch { Write-Warning "Best-effort secret removal failed: $($_.Exception.Message)" }
                }
            }
        }
        finally {
            # Emit the console report + rolling JSON artifact on every exit
            # path, after the Teardown span is recorded so teardown appears in
            # the report. Best-effort: a diagnostics write must never mask the
            # run's real outcome - on the failure path the original exception
            # is still in flight and must win - so any failure here is warned,
            # not thrown. The artifact lands under the run's diagnostics root,
            # next to runtime-diag.log / console.log.
            try {
                $diagnosticsRoot = Join-Path $Config.TestVm.vmConfigPath 'diagnostics'
                Publish-E2ETimingReport -Tree $Tree -DiagnosticsRoot $diagnosticsRoot
            }
            catch {
                Write-Warning "Timing report/artifact emission failed: $($_.Exception.Message)"
            }
        }
    }
}
