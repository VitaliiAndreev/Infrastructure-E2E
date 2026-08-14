<#
.NOTES
    Shared WSL shell-out for the two Infrastructure-Vm-Provisioner Ansible ops
    wrappers the provisioning phases drive - provision-files.sh and
    provision-toolchains.sh. Both cross the same boundary the same way, so the
    boundary lives here once: a gotcha fixed for one engine axis is fixed for
    the other, rather than being fixed in one file and quietly left stale in
    its twin.

    Deliberately NOT shared with Set-VmUsersForTest / Set-VmRunnersForTest.
    Those cross the same boundary but carry real per-flow work on top - a
    verbose-log tee with retention sweep, and a GH_TOKEN / WSLENV save-restore
    pair - so folding them in would mean a parameter for each variant and a
    body of branches. Two callers with an identical body is what this abstracts.

    Do not run this file directly. Dot-sourced by the two dispatchers.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisionerAnsibleOps
#   Runs one ops wrapper from Infrastructure-Vm-Provisioner's Ansible slice
#   inside the named WSL distro, and throws with the exit code if it fails.
#   Callers have already decided the ansible engine is selected; this function
#   only knows how to cross the boundary.
# ---------------------------------------------------------------------------

function Invoke-VmProvisionerAnsibleOps {
    [CmdletBinding()]
    param(
        # Infrastructure-Vm-Provisioner repo root. Both wrappers' Ansible slice
        # self-resolves the Common-Ansible substrate (roles + bridge) as a
        # sibling checkout, so no Common-Ansible path is threaded here.
        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # WSL distro the Ansible bridge runs inside.
        [Parameter(Mandatory)]
        [string] $WslDistro,

        # Wrapper file name under hyper-v/ubuntu/Ansible/ops/, e.g.
        # 'provision-files.sh'. Also names the wrapper in the failure message,
        # so an operator reading a bare exit code knows which driver produced it.
        [Parameter(Mandatory)]
        [string] $OpsScript,

        # What the run is doing, for the progress line ('files', 'toolchains').
        [Parameter(Mandatory)]
        [string] $Activity
    )

    # Push-Location + `wsl -d <distro> --`: cwd is $ProvisionerPath so the
    # relative wrapper path resolves as the Linux cwd, and -d targets the
    # bash-having distro regardless of the WSL default (Docker Desktop's
    # installer silently moves that default to its no-bash 'docker-desktop'
    # engine distro). `wsl --cd <path>` would anchor the cwd too, but it routes
    # through a /bin/sh -c interop layer whose sparse PATH cannot find `bash`.
    #
    # SECRET_SUFFIX - the only env either wrapper needs - is already exported
    # and forwarded through WSLENV by Initialize-E2EEnvironment, so the wsl
    # child inherits it.
    #
    # `2>&1 | Out-Host`: the wsl call is a native command; without Out-Host its
    # stdout/stderr would fold into this function's pipeline and be silently
    # swallowed by any caller in an assignment / subexpression context, leaving
    # an exit code with no error text. Same gotcha as Set-VmRunnersForTest /
    # Set-VmUsersForTest; see those for the full note.
    #
    # Per-task timing needs nothing here: when the run is instrumented,
    # Measure-ChildProcessTimingSpan sets TIMING_TREE_OUTPUT_PATH (forwarded via
    # WSLENV), the wrapper points the timing_tree callback at a rows file, and
    # the per-role/per-task nodes graft under the caller's span - no separate
    # artifact, no E2E-side wiring.
    Push-Location $ProvisionerPath
    try {
        Write-Host "Provisioning $Activity via ansible flow (WSL '$WslDistro') ..." `
            -ForegroundColor Magenta
        & wsl -d $WslDistro -- "./hyper-v/ubuntu/Ansible/ops/$OpsScript" 2>&1 |
            Out-Host
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Ansible $OpsScript exited $LASTEXITCODE"
    }
}
