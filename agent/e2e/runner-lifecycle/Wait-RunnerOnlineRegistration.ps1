<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-RunnerLifecycleTest.ps1
    after Infrastructure.GitHub (for Invoke-GitHubApi) is loaded.
#>

# ---------------------------------------------------------------------------
# Wait-RunnerOnlineRegistration
#   Polls the GitHub API until a named self-hosted runner reports 'online',
#   and returns its registration record - or the last thing seen if it never
#   got there.
#
#   Two callers need this and used to carry a copy each: the post-register
#   check, which waits for a runner to come online for the first time, and
#   the post-re-provision check, which expects one to still BE online. They
#   differ only in how long they are willing to wait and in what they say
#   when it fails, so the poll itself lives here once and each caller keeps
#   its own -MaxAttempts and its own error wording.
#
#   Deliberately does NOT throw: "not online" is the answer for one caller
#   and a regression for the other, and only the caller knows which. It
#   returns $null when the runner is absent from the fleet listing entirely,
#   so a caller can tell "missing" from "present but offline".
#
#   Transport failures are not handled here. Invoke-GitHubApi retries those
#   internally, so this loop only ever waits on runner STATE.
# ---------------------------------------------------------------------------

function Wait-RunnerOnlineRegistration {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RunnersToken,

        # Full repository URL, e.g. https://github.com/owner/repo. Parsed into
        # the owner/repo pair the runners endpoint needs.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $GithubUrl,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RunnerName,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int] $MaxAttempts,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $DelaySeconds = 5
    )

    $onlineStatus = 'online'

    $parts    = $GithubUrl.TrimEnd('/') -split '/'
    $apiOwner = $parts[-2]
    $apiRepo  = $parts[-1]

    $registration = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = Invoke-GitHubApi `
            -Token    $RunnersToken `
            -Endpoint "repos/$apiOwner/$apiRepo/actions/runners?per_page=100"
        $registration = @($response.runners) |
            Where-Object { $_.name -eq $RunnerName } |
            Select-Object -First 1

        if ($null -ne $registration -and $registration.status -eq $onlineStatus) {
            return $registration
        }

        # No sleep after the final attempt - the caller is about to fail, and
        # a last wait buys nothing.
        if ($attempt -lt $MaxAttempts) {
            $statusMsg = if ($null -eq $registration) { 'not found' }
                         else { $registration.status }
            Write-Host ("  [attempt $attempt/$MaxAttempts] Runner status: " +
                "$statusMsg - waiting ${DelaySeconds}s ...") -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $registration
}
