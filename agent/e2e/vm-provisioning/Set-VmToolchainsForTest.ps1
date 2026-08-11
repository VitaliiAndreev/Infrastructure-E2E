<#
.NOTES
    Toolchain-flow dispatcher for the provisioning E2E layer. The provisioning
    phases install jdk / dotnet toolchains one of two ways, selected by
    $Config.ToolchainsFlow (threaded from Start-E2EAgent):

      custom-powershell - the PowerShell reconciler installs the
        toolchains inside provision.ps1, reconciling the javaDevKit / dotnetSdk
        / dotnetTools blocks in VmProvisionerConfig. This dispatcher is then a
        no-op.

      ansible (default) - the phases author the SAME javaDevKit / dotnetSdk / dotnetTools
        blocks in VmProvisionerConfig (the single desired-state source both
        engines read), but provision.ps1 runs with -SkipToolchains so its
        reconciler leaves them alone, and this dispatcher runs
        Infrastructure-Vm-Provisioner's
        hyper-v/ubuntu/Ansible/ops/provision-toolchains.sh instead. That wrapper
        reads those same per-VM fields from VmProvisionerConfig, stages +
        verifies the artifacts host-side, and runs the Common-Ansible jdk /
        dotnet_sdk / dotnet_tools roles per host.

    The two engines reconcile the same on-VM end state, which is why the phases
    reuse one set of jdk / dotnet assertions across both (engine-specific
    manifest-store paths and the JDK install prefix are passed to those
    assertions by the phase, per step 5.5-A.5).

    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Initialize-E2EEnvironment and the secret cmdlets are loaded.
#>

# The WSL shell-out itself, shared with Set-VmFilesForTest. Dot-sourced here
# rather than by the orchestrator alone so this file's unit tests load their
# dependency by sourcing only the file under test.
. "$PSScriptRoot\Invoke-VmProvisionerAnsibleOps.ps1"

# ---------------------------------------------------------------------------
# Set-VmToolchainsForTest
#   The single switch point the phases call after provision.ps1 to install the
#   phase's desired toolchain state under whichever engine the session
#   selected. custom-powershell returns immediately (provision.ps1's reconciler
#   already did the work); ansible runs the provision-toolchains.sh driver,
#   which reads the desired state from VmProvisionerConfig - the same secret the
#   phase wrote and that provision.ps1 -SkipToolchains left untouched.
#
#   Symmetric with Set-VmUsersForTest / Set-VmRunnersForTest, but note the
#   sequencing: this runs AFTER provision.ps1 (which owns VM / network / files
#   / envVars creation) - only the toolchain install is gated here.
# ---------------------------------------------------------------------------

function Set-VmToolchainsForTest {
    [CmdletBinding()]
    param(
        # Selects the engine. ValidateSet rejects unknown values at parse
        # time so a typo never reaches the dispatch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $ToolchainsFlow,

        # Infrastructure-Vm-Provisioner repo root - the provision-toolchains.sh
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

    # custom-powershell: the reconciler installed the toolchains inside
    # provision.ps1 already (the phase left the javaDevKit / dotnetSdk /
    # dotnetTools blocks in VmProvisionerConfig and did NOT pass
    # -SkipToolchains). Nothing to drive here.
    if ($ToolchainsFlow -eq 'custom-powershell') {
        return
    }

    if (-not $WslDistro) {
        throw 'ToolchainsFlow=ansible requires -WslDistro'
    }

    # provision-toolchains.sh reads the per-VM toolchain fields straight from
    # VmProvisionerConfig (written by the phase, left untouched by provision.ps1
    # -SkipToolchains), resolves + stages the artifacts host-side, and runs the
    # roles per host. There is no separate desired-state vault: VmProvisioner
    # Config is the single source of truth for both engines - which is why
    # nothing about the desired state is passed across the boundary here.
    Invoke-VmProvisionerAnsibleOps `
        -ProvisionerPath $ProvisionerPath `
        -WslDistro       $WslDistro `
        -OpsScript       'provision-toolchains.sh' `
        -Activity        'toolchains'
}
