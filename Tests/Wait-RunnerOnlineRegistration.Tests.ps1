BeforeAll {
    # Module cmdlet the poller calls but does not define. Stubbed at file
    # scope so Pester's Mock can attach to it per-test.
    function Invoke-GitHubApi { param($Token, $Endpoint) }

    . "$PSScriptRoot\..\agent\e2e\runner-lifecycle\Wait-RunnerOnlineRegistration.ps1"

    # Builds the fleet-listing shape the runners endpoint returns.
    function New-RunnersResponse {
        param([string] $Name, [string] $Status)

        if (-not $Name) { return [PSCustomObject]@{ runners = @() } }
        [PSCustomObject]@{ runners = @([PSCustomObject]@{ name = $Name; status = $Status }) }
    }
}

Describe 'Wait-RunnerOnlineRegistration' {

    BeforeAll {
        # Every test drives the loop; none should actually wait.
        Mock Start-Sleep {}
    }

    # ------------------------------------------------------------------
    Context 'runner reaches online' {
    # ------------------------------------------------------------------

        It 'returns the registration on the first attempt without waiting' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'online' }

            $result = Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 10

            $result.status | Should -Be 'online'
            Should -Invoke Invoke-GitHubApi -Times 1 -Exactly
            Should -Invoke Start-Sleep      -Times 0 -Exactly
        }

        It 'keeps polling until the runner comes online' {
            $script:_calls = 0
            Mock Invoke-GitHubApi {
                $script:_calls++
                $status = if ($script:_calls -lt 3) { 'offline' } else { 'online' }
                New-RunnersResponse -Name 'e2e-runner' -Status $status
            }

            $result = Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 10

            $result.status  | Should -Be 'online'
            $script:_calls  | Should -Be 3
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It 'ignores a runner whose name does not match' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'other-runner' -Status 'online' }

            $result = Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 2

            $result | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'runner never reaches online' {
    # ------------------------------------------------------------------
    # The distinction the two callers act on: absent from the fleet entirely
    # is a different failure from present-but-offline, so the return value
    # has to tell them apart rather than throwing one generic error.

        It 'returns null when the runner is absent from the listing' {
            Mock Invoke-GitHubApi { New-RunnersResponse }

            $result = Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 3

            $result | Should -BeNullOrEmpty
        }

        It 'returns the offline registration when it is present but never online' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'offline' }

            $result = Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 3

            $result.status | Should -Be 'offline'
        }

        It 'exhausts exactly MaxAttempts calls' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'offline' }

            Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 4 | Out-Null

            Should -Invoke Invoke-GitHubApi -Times 4 -Exactly
        }

        It 'does not wait after the final attempt' {
            # One sleep fewer than attempts - a last wait buys nothing when the
            # caller is about to fail.
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'offline' }

            Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 4 | Out-Null

            Should -Invoke Start-Sleep -Times 3 -Exactly
        }

        It 'honours the configured delay' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'offline' }

            Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo' `
                -RunnerName 'e2e-runner' -MaxAttempts 2 -DelaySeconds 11 | Out-Null

            Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 11 }
        }
    }

    # ------------------------------------------------------------------
    Context 'endpoint construction' {
    # ------------------------------------------------------------------

        It 'derives owner and repo from the GitHub URL' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'online' }

            Wait-RunnerOnlineRegistration -RunnersToken 'tok' `
                -GithubUrl 'https://github.com/Klark-Morrigan/Infrastructure-GitHubRunners' `
                -RunnerName 'e2e-runner' -MaxAttempts 1 | Out-Null

            Should -Invoke Invoke-GitHubApi -ParameterFilter {
                $Endpoint -eq ('repos/Klark-Morrigan/Infrastructure-GitHubRunners/' +
                               'actions/runners?per_page=100') -and
                $Token -eq 'tok'
            }
        }

        It 'tolerates a trailing slash on the URL' {
            Mock Invoke-GitHubApi { New-RunnersResponse -Name 'e2e-runner' -Status 'online' }

            Wait-RunnerOnlineRegistration -RunnersToken 't' `
                -GithubUrl 'https://github.com/owner/repo/' `
                -RunnerName 'e2e-runner' -MaxAttempts 1 | Out-Null

            Should -Invoke Invoke-GitHubApi -ParameterFilter {
                $Endpoint -eq 'repos/owner/repo/actions/runners?per_page=100'
            }
        }
    }
}
