BeforeAll {
    # Stub every external function the loop calls so tests never hit real
    # infrastructure. All stubs are overridden by Mocks inside each Context.
    function Get-GitHubAppToken         { param($AppId, $InstallationId, $PrivateKeyPath) }
    function Get-PendingDeployment      { param($Token, $Owner, $Repo, $Environment, $CreatedSince) }
    function Set-DeploymentStatus       { param($Token, $Owner, $Repo, $DeploymentId, $State, $Description, $LogUrl) }
    function Invoke-RunnerLifecycleTest { param($Config) }
    # Assert-WslHasBash is a Common.PowerShell cmdlet the ansible-flow
    # startup validation calls to catch the docker-desktop-default trap
    # (a no-bash WSL distro). Stub it as a no-op so the unit tests are not
    # forced to actually have WSL installed.
    function Assert-WslHasBash          { param($DistroName) }
    # When the loop finds a deployment it dot-sources the runner-lifecycle
    # cascade, which installs Posh-SSH at load time via Invoke-ModuleInstall
    # (a Common.PowerShell cmdlet). A clean test runspace has no
    # Common.PowerShell, so that load-time call would otherwise throw
    # CommandNotFoundException; stub it as a no-op. The loop's own logic,
    # not module installation, is what these tests exercise.
    function Invoke-ModuleInstall       { param($ModuleName, $MinimumVersion) }

    # Source the function under test and the token helper it calls directly
    # (one-function-per-file convention), rather than the whole
    # Start-E2EAgent.ps1 entry script - the loop logic is what these tests
    # exercise, not the vault-reading bootstrap.
    . "$PSScriptRoot\..\agent\Get-RefreshedDeploymentToken.ps1"
    . "$PSScriptRoot\..\agent\Invoke-E2EAgentLoop.ps1"
}

Describe 'Invoke-E2EAgentLoop' {

    BeforeAll {
        # Shared parameters. PollIntervalSeconds=0 removes Start-Sleep latency.
        # Deadline is intentionally absent here - set fresh each test by the
        # BeforeEach below so the loop does not spin for hours once the
        # deployment mock starts returning $null.

        $Script:BaseParams = @{
            AppId                 = 1
            E2EInstallationId     = 10
            RunnersInstallationId = 20
            PrivateKeyPath        = 'C:\test.pem'
            ProvisionerPath       = 'C:\test\provisioner'
            UsersPath             = 'C:\test\users'
            UsersFlow             = 'ansible'
            # WslDistro is required when UsersFlow=ansible; the value is
            # not exercised here (Assert-WslHasBash is stubbed above).
            WslDistro             = 'Ubuntu-24.04'
            RunnersPath           = 'C:\test\runners'
            HostTarballCachePath  = 'C:\test\tarball-cache'
            TestVm                = [PSCustomObject]@{
                ubuntuVersion       = '24.04'
                dns                 = '8.8.8.8'
                externalSwitchName  = 'ExternalSwitch-Shared'
                externalAdapterName = 'Ethernet'
                vmConfigPath        = 'E:\a_VMs\Hyper-V\Config'
                vhdPath             = 'E:\a_VMs\Hyper-V\Disks'
            }
            Owner                 = 'org'
            Repo                  = 'repo'
            Environment           = 'e2e-workstation'
            PollIntervalSeconds   = 0
            TimeoutMinutes        = 60
        }

        # Token with expiry safely in the future - used wherever the refresh
        # path is NOT under test.
        $Script:FreshToken = [PSCustomObject]@{
            Token     = 'tok'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
        }
    }

    BeforeEach {
        # Refresh the deadline for every test. Without this, after a deployment
        # is processed and the mock starts returning $null, the loop would spin
        # until the far-future deadline set in BeforeAll - effectively hanging.
        # 500ms is long enough for one synchronous processing cycle and short
        # enough that null-spinning does not meaningfully slow the test suite.
        $Script:BaseParams['Deadline'] = [DateTime]::UtcNow.AddMilliseconds(500)
    }

    # ------------------------------------------------------------------
    Context 'token acquisition' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_taCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Return a deployment on the first poll so the token-acquisition
            # assertion is reachable, then null so the loop exits at deadline.
            Mock Get-PendingDeployment {
                $script:_taCount++
                if ($script:_taCount -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'acquires a token on startup with the correct credentials' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-GitHubAppToken -Times 1 -ParameterFilter {
                $AppId          -eq 1            -and
                $InstallationId -eq 10           -and
                $PrivateKeyPath -eq 'C:\test.pem'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'deployment found on first poll' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_dfpCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Return the deployment once, then null so the loop exits at deadline.
            Mock Get-PendingDeployment {
                $script:_dfpCount++
                if ($script:_dfpCount -eq 1) { return [PSCustomObject]@{ id = 42 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'posts in_progress before running the lifecycle test' {
            $Script:_statusOrder = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus   { $Script:_statusOrder.Add($State) }
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_statusOrder[0] | Should -Be 'in_progress'
        }

        It 'posts in_progress before invoking the lifecycle test, not after' {
            # The status order test above only compares status calls to each other.
            # This test captures both Set-DeploymentStatus and Invoke-RunnerLifecycleTest
            # in a single timeline to verify the cross-function ordering constraint.
            $Script:_callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus       { $Script:_callOrder.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest { $Script:_callOrder.Add('lifecycle') }

            Invoke-E2EAgentLoop @Script:BaseParams

            $inProgressIdx = $Script:_callOrder.IndexOf('status:in_progress')
            $lifecycleIdx  = $Script:_callOrder.IndexOf('lifecycle')
            $inProgressIdx | Should -BeLessThan $lifecycleIdx
        }

        It 'calls the lifecycle test with app credentials, repo paths, and VM config' {
            $Script:_config = $null
            Mock Invoke-RunnerLifecycleTest { $Script:_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_config.AppId                   | Should -Be 1
            $Script:_config.RunnersInstallationId   | Should -Be 20
            $Script:_config.PrivateKeyPath          | Should -Be 'C:\test.pem'
            $Script:_config.ProvisionerPath         | Should -Be 'C:\test\provisioner'
            $Script:_config.UsersPath               | Should -Be 'C:\test\users'
            $Script:_config.UsersFlow               | Should -Be 'ansible'
            $Script:_config.RunnersPath             | Should -Be 'C:\test\runners'
            $Script:_config.HostTarballCachePath    | Should -Be 'C:\test\tarball-cache'
            $Script:_config.Owner            | Should -Be 'org'
            # TestVm carries the operator-supplied dns + switch info;
            # router IP / gateway / subnetMask are intentionally absent
            # (ext0 DHCPs, no operator IPs to pin per Start-E2EAgent
            # docstring).
            $Script:_config.TestVm.dns                 | Should -Be '8.8.8.8'
            $Script:_config.TestVm.externalSwitchName  | Should -Be 'ExternalSwitch-Shared'
            $Script:_config.TestVm.externalAdapterName | Should -Be 'Ethernet'
        }

        It 'posts success after the lifecycle test passes' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 42 -and $State -eq 'success'
            }
        }

        It 'posts success after the lifecycle test completes, not before' {
            # Complements the in_progress ordering test: success must follow the
            # lifecycle test. Posting success before Invoke-RunnerLifecycleTest would
            # mean GitHub shows the deployment as succeeded before we know the outcome.
            $Script:_callOrder2 = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus       { $Script:_callOrder2.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest { $Script:_callOrder2.Add('lifecycle') }

            Invoke-E2EAgentLoop @Script:BaseParams

            $lifecycleIdx = $Script:_callOrder2.IndexOf('lifecycle')
            $successIdx   = $Script:_callOrder2.IndexOf('status:success')
            $lifecycleIdx | Should -BeLessThan $successIdx
        }

        It 'uses the deployment id in all status calls' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter { $DeploymentId -eq 42 }
        }

        It 'posts deployment status to the correct owner and repo' {
            # A bug that hard-codes the wrong owner or repo would post status
            # to a different repository; the deployment-id checks alone cannot
            # catch this because the mock accepts any parameters.
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $Owner -eq 'org' -and $Repo -eq 'repo'
            }
        }

        It 'calls Get-PendingDeployment with the correct owner, repo, environment, and token' {
            # A bug that hard-codes any of these values would not be caught by
            # the invocation-count checks in other tests.
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -ParameterFilter {
                $Token       -eq 'tok'              -and
                $Owner       -eq 'org'              -and
                $Repo        -eq 'repo'             -and
                $Environment -eq 'e2e-workstation'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'deployment found after several null polls' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_pollCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_pollCount++
                # Return the deployment exactly on call 3, null for all others.
                if ($script:_pollCount -eq 3) { return [PSCustomObject]@{ id = 7 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'calls Get-PendingDeployment until a deployment is found' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -Times 3
        }

        It 'posts success on the deployment that was eventually found' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 7 -and $State -eq 'success'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'lifecycle test failure' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_lfCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_lfCount++
                if ($script:_lfCount -eq 1) { return [PSCustomObject]@{ id = 5 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { throw 'runner service failed to start' }
        }

        It 'posts failure status when the lifecycle test throws' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 5 -and $State -eq 'failure'
            }
        }

        It 'includes the exception message in the failure description' {
            $Script:_desc = $null
            Mock Set-DeploymentStatus { if ($State -eq 'failure') { $Script:_desc = $Description } }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_desc | Should -Be 'runner service failed to start'
        }

        It 'does not post success when the lifecycle test throws' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -Times 0 -ParameterFilter { $State -eq 'success' }
        }

        It 'does not throw and continues polling after a lifecycle test failure' {
            # The operator sees the failure via the GitHub deployment status.
            # The agent must not crash - it continues to drain any queued
            # deployments and picks up new ones after the failure.
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'in_progress status post failure' {
    # ------------------------------------------------------------------
        # The in_progress post lives inside the per-deployment try, so a
        # status write that fails (e.g. a 401 from a stale token / wrong
        # Owner) fails just that deployment - the loop must mark it failed
        # and keep going, not rethrow and crash the agent.

        BeforeEach {
            $script:_ipCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_ipCount++
                if ($script:_ipCount -eq 1) { return [PSCustomObject]@{ id = 9 } }
                return $null
            }
            # Throw on the in_progress write; let the later 'failure' write succeed.
            Mock Set-DeploymentStatus { if ($State -eq 'in_progress') { throw 'simulated 401' } }
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'does not rethrow when the in_progress post fails' {
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw
        }

        It 'posts failure for the deployment whose in_progress post failed' {
            Invoke-E2EAgentLoop @Script:BaseParams
            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 9 -and $State -eq 'failure'
            }
        }

        It 'does not run the lifecycle test when the in_progress post failed' {
            Invoke-E2EAgentLoop @Script:BaseParams
            Should -Invoke Invoke-RunnerLifecycleTest -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'queue drain - multiple pending deployments' {
    # ------------------------------------------------------------------

        It 'processes a second deployment after the first succeeds' {
            $script:_qdCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount++
                if ($script:_qdCount -eq 1) { return [PSCustomObject]@{ id = 10 } }
                if ($script:_qdCount -eq 2) { return [PSCustomObject]@{ id = 11 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 10 -and $State -eq 'success'
            }
            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 11 -and $State -eq 'success'
            }
        }

        It 'processes a second deployment after the first fails' {
            $script:_qdCount2 = 0
            $script:_qdLifecycle = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount2++
                if ($script:_qdCount2 -eq 1) { return [PSCustomObject]@{ id = 20 } }
                if ($script:_qdCount2 -eq 2) { return [PSCustomObject]@{ id = 21 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {
                $script:_qdLifecycle++
                if ($script:_qdLifecycle -eq 1) { throw 'first test failed' }
            }

            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 20 -and $State -eq 'failure'
            }
            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 21 -and $State -eq 'success'
            }
        }

        It 'continues polling after processing a deployment instead of exiting' {
            $script:_qdCount3 = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount3++
                if ($script:_qdCount3 -eq 1) { return [PSCustomObject]@{ id = 30 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # More than one call means the loop re-polled after the deployment
            # was processed rather than returning immediately.
            $script:_qdCount3 | Should -BeGreaterThan 1
        }
    }

    # ------------------------------------------------------------------
    Context 'timeout' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment { $null }
            Mock Set-DeploymentStatus {}
        }

        It 'exits without error when the deadline is already past' {
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            { Invoke-E2EAgentLoop @params } | Should -Not -Throw
        }

        It 'does not post any deployment status when no deployment was found before timeout' {
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            Invoke-E2EAgentLoop @params

            Should -Invoke Set-DeploymentStatus -Times 0
        }

        It 'does not poll for deployments when the deadline is already past' {
            # Verifies the while guard is respected - a bug that called
            # Get-PendingDeployment unconditionally before the loop would be missed
            # by the Set-DeploymentStatus check alone.
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            Invoke-E2EAgentLoop @params

            Should -Invoke Get-PendingDeployment -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'UsersFlow / WslDistro plumbing' {
    # ------------------------------------------------------------------

        It 'defaults UsersFlow to ansible when callers do not pass one' {
            # Once feature 02 ships, the Ansible flow is the primary path.
            # A regression that re-flips the default to custom-powershell
            # would silently route every test session through the older
            # flow - this assertion fails such a regression at unit time.
            $Script:_def_config = $null
            Mock Get-GitHubAppToken { $Script:FreshToken }
            $script:_defCount = 0
            Mock Get-PendingDeployment {
                $script:_defCount++
                if ($script:_defCount -eq 1) { return [PSCustomObject]@{ id = 99 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { $Script:_def_config = $Config }

            # Clone BaseParams and strip UsersFlow so the default kicks in.
            $params = $Script:BaseParams.Clone()
            $params.Remove('UsersFlow')

            Invoke-E2EAgentLoop @params

            $Script:_def_config.UsersFlow | Should -Be 'ansible'
        }

        It 'defaults ToolchainsFlow to ansible when callers do not pass one' {
            # The Ansible toolchain path is the primary engine now that it
            # has validated. A regression that re-flips the default to
            # custom-powershell would silently route every unpinned run
            # through the reconciler - this fails such a regression at unit
            # time. BaseParams does not set ToolchainsFlow, so the parameter
            # default is what reaches the config here.
            $Script:_tcdef_config = $null
            Mock Get-GitHubAppToken { $Script:FreshToken }
            $script:_tcdefCount = 0
            Mock Get-PendingDeployment {
                $script:_tcdefCount++
                if ($script:_tcdefCount -eq 1) { return [PSCustomObject]@{ id = 96 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { $Script:_tcdef_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_tcdef_config.ToolchainsFlow | Should -Be 'ansible'
        }

        It 'defaults FilesFlow to ansible when callers do not pass one' {
            # The Ansible file transport is the primary engine. A regression
            # that re-flipped the default to custom-powershell would silently
            # route every unpinned run back through the in-line HttpListener
            # transport - this fails such a regression at unit time.
            # BaseParams does not set FilesFlow, so the parameter default is
            # what reaches the config here.
            $Script:_fldef_config = $null
            Mock Get-GitHubAppToken { $Script:FreshToken }
            $script:_fldefCount = 0
            Mock Get-PendingDeployment {
                $script:_fldefCount++
                if ($script:_fldefCount -eq 1) { return [PSCustomObject]@{ id = 95 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { $Script:_fldef_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_fldef_config.FilesFlow | Should -Be 'ansible'
        }

        It 'defaults RunnersFlow to ansible when callers do not pass one' {
            # The runner Ansible path is now the primary engine too. A
            # regression that re-flips the default to custom-powershell
            # would silently route every unpinned run through the older
            # register-runners.ps1 - this fails such a regression at unit
            # time. BaseParams does not set RunnersFlow, so the parameter
            # default is what reaches the config here.
            $Script:_rndef_config = $null
            Mock Get-GitHubAppToken { $Script:FreshToken }
            $script:_rndefCount = 0
            Mock Get-PendingDeployment {
                $script:_rndefCount++
                if ($script:_rndefCount -eq 1) { return [PSCustomObject]@{ id = 97 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { $Script:_rndef_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_rndef_config.RunnersFlow | Should -Be 'ansible'
        }

        It "throws at startup when UsersFlow='ansible' and WslDistro is missing" {
            # No mocks reachable: the validation runs before the polling
            # loop starts, so no token / deployment calls happen.
            $params = $Script:BaseParams.Clone()
            $params.Remove('WslDistro')

            { Invoke-E2EAgentLoop @params } | Should -Throw '*requires -WslDistro*'
        }

        It "throws at startup when ToolchainsFlow='ansible' and WslDistro is missing" {
            # ToolchainsFlow=ansible needs the bridge just like the other
            # ansible flows; the startup gate must include it. Every other
            # layer is set to custom-powershell so ToolchainsFlow is the sole
            # ansible trigger, proving it alone requires WslDistro.
            $params = $Script:BaseParams.Clone()
            $params['UsersFlow']      = 'custom-powershell'
            $params['RunnersFlow']    = 'custom-powershell'
            $params['FilesFlow']      = 'custom-powershell'
            $params['ToolchainsFlow'] = 'ansible'
            $params.Remove('WslDistro')

            { Invoke-E2EAgentLoop @params } | Should -Throw '*requires -WslDistro*'
        }

        It "throws at startup when FilesFlow='ansible' and WslDistro is missing" {
            # provision-files.sh runs over the same WSL bridge, so the files
            # axis joins the startup gate. Every other layer is pinned to
            # custom-powershell, proving FilesFlow alone requires WslDistro.
            $params = $Script:BaseParams.Clone()
            $params['UsersFlow']      = 'custom-powershell'
            $params['RunnersFlow']    = 'custom-powershell'
            $params['ToolchainsFlow'] = 'custom-powershell'
            $params['FilesFlow']      = 'ansible'
            $params.Remove('WslDistro')

            { Invoke-E2EAgentLoop @params } | Should -Throw '*requires -WslDistro*'
        }

        It "does not require WslDistro when every flow is 'custom-powershell'" {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment { $null }
            Mock Set-DeploymentStatus {}

            $params = $Script:BaseParams.Clone()
            $params['UsersFlow']      = 'custom-powershell'
            $params['RunnersFlow']    = 'custom-powershell'
            $params['ToolchainsFlow'] = 'custom-powershell'
            $params['FilesFlow']      = 'custom-powershell'
            $params['EnvVarsFlow']    = 'custom-powershell'
            $params.Remove('WslDistro')

            { Invoke-E2EAgentLoop @params } | Should -Not -Throw
        }

        It "rejects unknown UsersFlow values at parameter binding time" {
            $params = $Script:BaseParams.Clone()
            $params['UsersFlow'] = 'legacy'

            { Invoke-E2EAgentLoop @params } | Should -Throw '*ValidateSet*'
        }
    }

    # ------------------------------------------------------------------
    Context 'flow spec from deployment payload' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Set-DeploymentStatus {}
        }

        It 'overrides both session flows with the payload flows for that run' {
            # BaseParams sets the session defaults to the ansible scenario;
            # a custom-powershell repo's PR rides its own scenario in the
            # deployment payload and must win for that deployment.
            $Script:_pl_config = $null
            $script:_plCount = 0
            Mock Get-PendingDeployment {
                $script:_plCount++
                if ($script:_plCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 77
                        payload = [PSCustomObject]@{
                            usersFlow   = 'custom-powershell'
                            runnersFlow = 'custom-powershell'
                        }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest { $Script:_pl_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_pl_config.UsersFlow   | Should -Be 'custom-powershell'
            $Script:_pl_config.RunnersFlow | Should -Be 'custom-powershell'
        }

        It 'falls back to the session flows when the deployment has no payload' {
            $Script:_nopl_config = $null
            $script:_noplCount = 0
            Mock Get-PendingDeployment {
                $script:_noplCount++
                if ($script:_noplCount -eq 1) { return [PSCustomObject]@{ id = 78 } }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest { $Script:_nopl_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            # BaseParams sets UsersFlow=ansible and leaves RunnersFlow /
            # ToolchainsFlow / FilesFlow at their parameter defaults, which are
            # all ansible now that every layer defaults to the Ansible path.
            $Script:_nopl_config.UsersFlow      | Should -Be 'ansible'
            $Script:_nopl_config.RunnersFlow    | Should -Be 'ansible'
            $Script:_nopl_config.ToolchainsFlow | Should -Be 'ansible'
            $Script:_nopl_config.FilesFlow      | Should -Be 'ansible'
        }

        It 'overrides ToolchainsFlow from the payload, keeping the other layers at the session value' {
            # A repo pinning custom-powershell toolchains opts its layer down
            # via the payload while users / runners stay on their session
            # flows; proves the payload wins over the ansible default.
            $Script:_tc_config = $null
            $script:_tcCount = 0
            Mock Get-PendingDeployment {
                $script:_tcCount++
                if ($script:_tcCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 81
                        payload = [PSCustomObject]@{ toolchainsFlow = 'custom-powershell' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest { $Script:_tc_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_tc_config.ToolchainsFlow | Should -Be 'custom-powershell'  # from payload
            $Script:_tc_config.UsersFlow      | Should -Be 'ansible'   # session default
            $Script:_tc_config.RunnersFlow    | Should -Be 'ansible'   # param default
        }

        It 'overrides FilesFlow from the payload, keeping the other layers at the session value' {
            # A repo pinning the in-line PowerShell transport opts its layer
            # down via the payload while the other layers stay on their session
            # flows; proves the payload wins over the ansible default.
            $Script:_fl_config = $null
            $script:_flCount = 0
            Mock Get-PendingDeployment {
                $script:_flCount++
                if ($script:_flCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 82
                        payload = [PSCustomObject]@{ filesFlow = 'custom-powershell' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest { $Script:_fl_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_fl_config.FilesFlow      | Should -Be 'custom-powershell'  # from payload
            $Script:_fl_config.ToolchainsFlow | Should -Be 'ansible'   # param default
            $Script:_fl_config.UsersFlow      | Should -Be 'ansible'   # session default
        }

        It 'posts failure for an unknown filesFlow value in the payload' {
            # The files axis joins the same validation sweep: an unknown value
            # must fail this deployment loudly rather than reach a dispatcher
            # as a sparse ValidateSet error.
            $script:_flBadCount = 0
            Mock Get-PendingDeployment {
                $script:_flBadCount++
                if ($script:_flBadCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 83
                        payload = [PSCustomObject]@{ filesFlow = 'scp' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest {}

            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 83 -and $State -eq 'failure'
            }
            Should -Invoke Invoke-RunnerLifecycleTest -Times 0
        }

        It 'applies only the flow present in the payload, keeping the other at the session value' {
            $Script:_partial_config = $null
            $script:_partialCount = 0
            Mock Get-PendingDeployment {
                $script:_partialCount++
                if ($script:_partialCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 79
                        payload = [PSCustomObject]@{ runnersFlow = 'custom-powershell' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest { $Script:_partial_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_partial_config.UsersFlow   | Should -Be 'ansible'   # session default
            $Script:_partial_config.RunnersFlow | Should -Be 'custom-powershell'   # from payload
        }

        It 'posts failure for an unknown flow value in the payload instead of crashing' {
            $script:_badCount = 0
            Mock Get-PendingDeployment {
                $script:_badCount++
                if ($script:_badCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 80
                        payload = [PSCustomObject]@{ usersFlow = 'legacy' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest {}

            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 80 -and $State -eq 'failure'
            }
            # The bad spec is rejected before the lifecycle test is reached.
            Should -Invoke Invoke-RunnerLifecycleTest -Times 0
        }

        It "posts failure when a payload upgrades a layer to 'ansible' but WslDistro is missing" {
            # The startup check only validated the session defaults. A payload
            # that flips a custom-powershell session to ansible must re-assert
            # the bridge prerequisites or it would fail deep in a dispatcher.
            $script:_upCount = 0
            Mock Get-PendingDeployment {
                $script:_upCount++
                if ($script:_upCount -eq 1) {
                    return [PSCustomObject]@{
                        id      = 81
                        payload = [PSCustomObject]@{ usersFlow = 'ansible' }
                    }
                }
                return $null
            }
            Mock Invoke-RunnerLifecycleTest {}

            # Session is custom-powershell with no WslDistro, so startup
            # validation passes; the payload's ansible upgrade is caught
            # per-run instead. EVERY layer is pinned to custom-powershell -
            # ToolchainsFlow, FilesFlow and EnvVarsFlow default to ansible,
            # which would otherwise trip the startup gate before the payload
            # runs.
            $params = $Script:BaseParams.Clone()
            $params['UsersFlow']      = 'custom-powershell'
            $params['RunnersFlow']    = 'custom-powershell'
            $params['ToolchainsFlow'] = 'custom-powershell'
            $params['FilesFlow']      = 'custom-powershell'
            $params['EnvVarsFlow']    = 'custom-powershell'
            $params.Remove('WslDistro')

            { Invoke-E2EAgentLoop @params } | Should -Not -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 81 -and $State -eq 'failure'
            }
            Should -Invoke Invoke-RunnerLifecycleTest -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'deployment lookback cutoff' {
    # ------------------------------------------------------------------
        # The loop hands Get-PendingDeployment a CreatedSince so it can skip
        # the status fetch for historical deployments - the fix that stops
        # the N+1 poll fan-out from exhausting the GitHub rate limit.

        It 'passes a CreatedSince ~DeploymentLookbackHours in the past (default 1h)' {
            $script:_csValues = [System.Collections.Generic.List[datetime]]::new()
            Mock Get-GitHubAppToken    { $Script:FreshToken }
            Mock Get-PendingDeployment { $script:_csValues.Add($CreatedSince); $null }
            Mock Set-DeploymentStatus  {}

            # BaseParams omits DeploymentLookbackHours, so the 1h default applies.
            Invoke-E2EAgentLoop @Script:BaseParams

            $script:_csValues.Count | Should -BeGreaterThan 0
            $expected = [DateTime]::UtcNow.AddHours(-1)
            [Math]::Abs(($script:_csValues[0] - $expected).TotalMinutes) |
                Should -BeLessThan 5
        }

        It 'honours a custom DeploymentLookbackHours' {
            $script:_csValues2 = [System.Collections.Generic.List[datetime]]::new()
            Mock Get-GitHubAppToken    { $Script:FreshToken }
            Mock Get-PendingDeployment { $script:_csValues2.Add($CreatedSince); $null }
            Mock Set-DeploymentStatus  {}

            $params = $Script:BaseParams.Clone()
            $params['DeploymentLookbackHours'] = 2
            Invoke-E2EAgentLoop @params

            $script:_csValues2.Count | Should -BeGreaterThan 0
            $expected = [DateTime]::UtcNow.AddHours(-2)
            [Math]::Abs(($script:_csValues2[0] - $expected).TotalMinutes) |
                Should -BeLessThan 5
        }
    }

    # ------------------------------------------------------------------
    Context 'token refresh' {
    # ------------------------------------------------------------------

        It 'refreshes the token when ExpiresAt is within 5 minutes' {
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }
            $refreshedToken = [PSCustomObject]@{
                Token     = 'refreshed_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
            }

            $script:_tokenCallCount = 0
            Mock Get-GitHubAppToken {
                $script:_tokenCallCount++
                if ($script:_tokenCallCount -eq 1) { return $expiringToken }
                return $refreshedToken
            }
            $script:_trCount = 0
            Mock Get-PendingDeployment {
                $script:_trCount++
                if ($script:_trCount -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called twice: once at startup, once for the near-expiry refresh.
            Should -Invoke Get-GitHubAppToken -Times 2
        }

        It 'refreshes using the E2E installation ID' {
            # The refresh must re-authenticate against the E2E installation
            # (deployments:write). Using the wrong installation ID would return
            # a token without deployments:write and break status posting.
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }

            $script:_installationIds = [System.Collections.Generic.List[int]]::new()
            $script:_tokenCallCount2 = 0
            Mock Get-GitHubAppToken {
                $script:_tokenCallCount2++
                $script:_installationIds.Add($InstallationId)
                if ($script:_tokenCallCount2 -eq 1) { return $expiringToken }
                return [PSCustomObject]@{ Token = 'tok'; ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o') }
            }
            $script:_trCount2 = 0
            Mock Get-PendingDeployment {
                $script:_trCount2++
                if ($script:_trCount2 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Both the startup and the refresh call must use E2EInstallationId (10).
            $script:_installationIds | ForEach-Object { $_ | Should -Be 10 }
        }

        It 'uses the refreshed token for subsequent API calls' {
            # Verifies that the re-assignment $tokenResult = Get-GitHubAppToken ...
            # actually takes effect. A bug that calls Get-GitHubAppToken without
            # capturing the result would keep passing the expiring token.
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }
            $refreshedToken = [PSCustomObject]@{
                Token     = 'refreshed_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
            }

            $script:_callCount = 0
            Mock Get-GitHubAppToken {
                $script:_callCount++
                if ($script:_callCount -eq 1) { return $expiringToken }
                return $refreshedToken
            }
            $script:_trCount3 = 0
            Mock Get-PendingDeployment {
                $script:_trCount3++
                if ($script:_trCount3 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -ParameterFilter { $Token -eq 'refreshed_tok' }
        }

        It 'does not refresh the token when ExpiresAt is more than 5 minutes away' {
            $script:_trCount4 = 0
            Mock Get-GitHubAppToken     { $Script:FreshToken }  # ExpiresAt = +55min
            Mock Get-PendingDeployment  {
                $script:_trCount4++
                if ($script:_trCount4 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called only once at startup - no refresh needed.
            Should -Invoke Get-GitHubAppToken -Times 1
        }
    }

    # ------------------------------------------------------------------
    Context 'terminal status token refresh' {
    # ------------------------------------------------------------------
        # Regression guard: a lifecycle run can outlast the token's 1-hour
        # life, so the deployment token must be re-checked for expiry
        # immediately before the success/failure post - otherwise the
        # terminal write 401s on a stale token. These tests assert a
        # refresh call sits directly before each terminal post by mocking
        # the helper as a pass-through recorder (the real expiry logic is
        # covered by the 'Get-RefreshedDeploymentToken' Describe below).

        It 'refreshes the token immediately before posting success' {
            $Script:_order = [System.Collections.Generic.List[string]]::new()
            $script:_tsCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-RefreshedDeploymentToken { $Script:_order.Add('refresh'); $TokenResult }
            Mock Get-PendingDeployment {
                $script:_tsCount++
                if ($script:_tsCount -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus       { $Script:_order.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            $successIdx = $Script:_order.IndexOf('status:success')
            $successIdx | Should -BeGreaterThan 0
            $Script:_order[$successIdx - 1] | Should -Be 'refresh'
        }

        It 'refreshes the token immediately before posting failure' {
            $Script:_orderF = [System.Collections.Generic.List[string]]::new()
            $script:_tsCountF = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-RefreshedDeploymentToken { $Script:_orderF.Add('refresh'); $TokenResult }
            Mock Get-PendingDeployment {
                $script:_tsCountF++
                if ($script:_tsCountF -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus       { $Script:_orderF.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest { throw 'lifecycle failed' }

            Invoke-E2EAgentLoop @Script:BaseParams

            $failureIdx = $Script:_orderF.IndexOf('status:failure')
            $failureIdx | Should -BeGreaterThan 0
            $Script:_orderF[$failureIdx - 1] | Should -Be 'refresh'
        }

        It 'posts the terminal status with the token returned by the refresh' {
            # Proves the re-assignment takes effect: a refresh that returns a
            # new token must be the one the success post uses, not the stale
            # pre-test token.
            $script:_tsCount2 = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Pass-through at loop top (keeps 'tok'); swap to a fresh token
            # only on the pre-post call so we can assert the post uses it.
            $script:_refreshCalls = 0
            Mock Get-RefreshedDeploymentToken {
                $script:_refreshCalls++
                if ($script:_refreshCalls -ge 2) {
                    return [PSCustomObject]@{
                        Token     = 'post_fresh_tok'
                        ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
                    }
                }
                return $TokenResult
            }
            Mock Get-PendingDeployment {
                $script:_tsCount2++
                if ($script:_tsCount2 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $State -eq 'success' -and $Token -eq 'post_fresh_tok'
            }
        }
    }
}
