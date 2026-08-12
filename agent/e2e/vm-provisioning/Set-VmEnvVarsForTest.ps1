<#
.NOTES
    EnvVars-flow dispatcher for the provisioning E2E layer. The provisioning
    phases reconcile each VM's operator-declared `envVars` managed block onto
    the VM one of two ways, selected by $Config.EnvVarsFlow (threaded from
    Start-E2EAgent):

      custom-powershell - provision.ps1's in-line transport
        (Set-VmEnvironmentVariables) writes the block during post-provisioning.
        This dispatcher is then a no-op.

      ansible (default) - the phases author the SAME `envVars` object in
        VmProvisionerConfig (the single desired-state source both engines
        read), but provision.ps1 runs with -SkipEnvVars so its in-line
        transport writes nothing, and this dispatcher runs
        Infrastructure-Vm-Provisioner's hyper-v/ubuntu/Ansible/ops/
        provision-env.sh instead. That wrapper hands the same per-VM `envVars`
        objects to the Common-Ansible vm_env_vars / env_vars_report roles.

    Both engines land the same end state - the sentinel-delimited block
    present in /etc/environment, root:root 0644, holding one NAME="value" line
    per declared entry - so the phases run one shared set of
    Invoke-EnvVarsAppliedAssertions / Invoke-EnvVarsRemovedAssertions across
    both. As on the files axis there are no engine-specific assertion
    parameters: nothing about the on-VM result differs by engine, which is the
    property the two engines' byte-identical block format exists to give.

    Why -SkipEnvVars is load-bearing here and why the switch was added for
    this: without it the in-line transport writes the block first and the
    Ansible run can only ever find it already correct, so the ansible leg
    would report green while never once being observed AUTHORING a block. The
    same applies to retraction - an `entries: []` phase would be executed
    in-line and the Ansible run would confirm a removal it did not perform.

    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Initialize-E2EEnvironment and the secret cmdlets are loaded.
#>

# The shared engine-selection body (what custom-powershell means, and the
# bridge requirement on the ansible branch), which pulls in the WSL shell-out
# transitively. Dot-sourced here rather than by the orchestrator alone so this
# file's unit tests load the whole chain by sourcing only the file under test.
. "$PSScriptRoot\Invoke-VmEngineDispatch.ps1"

# ---------------------------------------------------------------------------
# Set-VmEnvVarsForTest
#   The single switch point the phases call after provision.ps1 to reconcile
#   the phase's declared `envVars` block under whichever engine the session
#   selected. custom-powershell returns immediately (provision.ps1's in-line
#   transport already did the work); ansible runs the provision-env.sh driver,
#   which reads the object from VmProvisionerConfig - the same secret the phase
#   wrote and that provision.ps1 -SkipEnvVars left untouched.
#
#   Peer of Set-VmFilesForTest, and called AFTER it at every site, matching
#   the order both engines apply the two: the in-line path runs its files
#   dispatch before its envVars dispatch (an env value may name a path the
#   files step placed), and the operator's Ansible chain runs provision-files
#   before provision-env for the same reason.
# ---------------------------------------------------------------------------

function Set-VmEnvVarsForTest {
    [CmdletBinding()]
    param(
        # Selects the engine. ValidateSet rejects unknown values at parse
        # time so a typo never reaches the dispatch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $EnvVarsFlow,

        # Infrastructure-Vm-Provisioner repo root - the provision-env.sh
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

    # custom-powershell: the in-line transport wrote the block inside
    # provision.ps1 already (the phase left the `envVars` object in
    # VmProvisionerConfig and did NOT pass -SkipEnvVars). The ansible branch
    # drives provision-env.sh, which reads the same object from that same
    # secret - there is no separate desired-state vault, which is why nothing
    # about the desired state is passed across the boundary here.
    Invoke-VmEngineDispatch `
        -Flow              $EnvVarsFlow `
        -FlowParameterName 'EnvVarsFlow' `
        -ProvisionerPath   $ProvisionerPath `
        -WslDistro         $WslDistro `
        -OpsScript         'provision-env.sh' `
        -Activity          'environment variables'
}
