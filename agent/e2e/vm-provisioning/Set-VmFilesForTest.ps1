<#
.NOTES
    Files-flow dispatcher for the provisioning E2E layer. The provisioning
    phases put each VM's operator-declared `files` entries on the VM one of two
    ways, selected by $Config.FilesFlow (threaded from Start-E2EAgent):

      custom-powershell - provision.ps1's in-line transport copies them during
        post-provisioning, serving the bytes off a host-side HttpListener the
        VM curls from. This dispatcher is then a no-op.

      ansible (default) - the phases author the SAME `files` array in
        VmProvisionerConfig (the single desired-state source both engines read),
        but provision.ps1 runs with -SkipFiles so its in-line transport copies
        nothing, and this dispatcher runs Infrastructure-Vm-Provisioner's
        hyper-v/ubuntu/Ansible/ops/provision-files.sh instead. That wrapper
        reads the same per-VM `files` arrays from VmProvisionerConfig,
        translates their Windows source paths to the WSL controller's /mnt form,
        and runs the Common-Ansible vm_files / files_report roles per host.

    Both engines land the same end state - the file present at its declared
    target, root:root, 0644 - so the phases run one shared set of
    Invoke-FileTransferAssertions / Invoke-BulkFileTransferAssertions across
    both. Unlike the toolchain axis there are no engine-specific assertion
    parameters: nothing about the on-VM result differs by engine.

    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Initialize-E2EEnvironment and the secret cmdlets are loaded.
#>

# The WSL shell-out itself, shared with Set-VmToolchainsForTest. Dot-sourced
# here rather than by the orchestrator alone so this file's unit tests load
# their dependency by sourcing only the file under test.
. "$PSScriptRoot\Invoke-VmProvisionerAnsibleOps.ps1"

# ---------------------------------------------------------------------------
# Set-VmFilesForTest
#   The single switch point the phases call after provision.ps1 to transport the
#   phase's declared `files` entries under whichever engine the session
#   selected. custom-powershell returns immediately (provision.ps1's in-line
#   copy already did the work); ansible runs the provision-files.sh driver,
#   which reads the entries from VmProvisionerConfig - the same secret the phase
#   wrote and that provision.ps1 -SkipFiles left untouched.
#
#   Peer of Set-VmToolchainsForTest, and called BEFORE it at every site: the
#   menu's Ansible scenario runs provision-files then provision-toolchains, and
#   the PowerShell engine copies files before installing toolchains inside
#   Invoke-VmPostProvisioning. Keeping the E2E in that order means both engines
#   are exercised in the sequence an operator actually drives them.
# ---------------------------------------------------------------------------

function Set-VmFilesForTest {
    [CmdletBinding()]
    param(
        # Selects the engine. ValidateSet rejects unknown values at parse
        # time so a typo never reaches the dispatch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $FilesFlow,

        # Infrastructure-Vm-Provisioner repo root - the provision-files.sh
        # wrapper's home. Its Ansible slice self-resolves the Common-Ansible
        # substrate (roles + bridge) as a sibling checkout, so no Common-Ansible
        # path is threaded here.
        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # WSL distro the Ansible bridge runs inside. Required for the ansible
        # flow; ignored by custom-powershell. Passed via `wsl -d <name>` so the
        # run does not depend on the workstation's WSL default (Docker Desktop
        # silently moves it to its no-bash 'docker-desktop' distro).
        [Parameter()]
        [string] $WslDistro
    )

    # custom-powershell: the in-line transport copied the files inside
    # provision.ps1 already (the phase left the `files` array in
    # VmProvisionerConfig and did NOT pass -SkipFiles). Nothing to drive here.
    if ($FilesFlow -eq 'custom-powershell') {
        return
    }

    if (-not $WslDistro) {
        throw 'FilesFlow=ansible requires -WslDistro'
    }

    # provision-files.sh reads the per-VM `files` arrays straight from
    # VmProvisionerConfig (written by the phase, left untouched by provision.ps1
    # -SkipFiles). There is no separate desired-state vault: VmProvisionerConfig
    # is the single source of truth for both engines - which is why nothing
    # about the desired state is passed across the boundary here.
    Invoke-VmProvisionerAnsibleOps `
        -ProvisionerPath $ProvisionerPath `
        -WslDistro       $WslDistro `
        -OpsScript       'provision-files.sh' `
        -Activity        'files'
}
