#Requires -Version 5.1
<#
.SYNOPSIS
    Hyper-V Cluster VM Group Management

.DESCRIPTION
    Interactive menu for managing native Hyper-V VM Groups (VMCollectionType)
    on a failover cluster. Veeam B&R discovers these groups and backup jobs
    target them, so group membership = backup classification.

    - Group-level operations (create / list / rename / delete) run against a
      physical cluster node, never the cluster name.
    - Membership changes run against the node that currently owns the VM.
    - Shared group state lives in the cluster's ConfigStoreRootPath.

.NOTES
    Version: 2.3

    2.3 changes
      - Management node is no longer "first node alphabetically": the local
        node is preferred when the script runs on a cluster node, and any
        node that doesn't answer a VM Group query is skipped. Paused nodes
        count as online (their VMs stay visible).
      - Option 5 also lists clustered VMs that are in no group.
      - Selection examples use generic names only.

    2.2 changes
      - Options 2 and 3 accept multiple VMs (same syntax as option 1).
      - Move shows a full old -> new plan and asks once before running.
      - Remove shows a plan, flags VMs that will end up in NO group, and
        needs "y" for one VM or the typed word REMOVE for a batch.
      - Startup (and D) checks for stale group members - entries whose VM
        no longer exists on any node - and offers to remove them. Skipped
        unless every node is online, so VMs on a down node aren't mistaken
        for deleted ones.
      - Header shows how many clustered VMs are in no group.

    2.1 changes
      - Option 1 accepts multiple VMs: "1, 4-7, 11, 14", names, or "all".
        VMs already in the target group are skipped; VMs in another group
        can be added anyway, skipped, or the operation cancelled.

    2.0 changes
      - Startup health check: ConfigStoreRootPath, the CSV holding it, VMMS
        and store reachability on every node, shown in the menu header.
      - D = Diagnostics (full health check + node/cluster group view
        comparison), R = refresh status.
      - VMs and groups are matched by ID instead of name.
      - VMs are picked from a numbered list (number or name accepted).
      - Move adds to the new group BEFORE removing from the old one, so a
        VM is never left without a group (and without backup coverage).
      - Confirmations on move / remove / delete; warnings when a change
        affects Veeam coverage.
      - Exit checks whether node and cluster views agree and only offers a
        VMMS restart (on ALL nodes) when they don't.
      - Fixed: "Cancel" on the exit prompt ended the script.
      - Fixed: VM Group errors were non-terminating and showed up as
        "No VM Groups exist".
      - Get-VM is module-qualified (Hyper-V\Get-VM) so VMware PowerCLI can't
        hijack it.
      - Change log written next to the script (Logs\VMGroupChanges.log).
#>

# ============================================================
# Configuration
# ============================================================

# FQDN of the Hyper-V failover cluster.
# >>> CHANGE THIS to your cluster's name. <<<
$script:ClusterName = "hvcluster.contoso.com"

# Where the cluster's ConfigStoreRootPath SHOULD point (a folder on a CSV).
# The health check flags it if the actual value drifts from this.
# >>> CHANGE THIS to your path, or set to $null to skip the comparison. <<<
$script:ExpectedConfigStore = "C:\ClusterStorage\Volume1\Hyper-V-ClusterConfig"

# Change log. Set to $null to disable logging.
$script:LogFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Logs\VMGroupChanges.log" } else { $null }

$script:ChangesMade = $false
$script:Health      = $null
$script:ManagementNode = $null


# ============================================================
# Console Helpers (plain ASCII only, so nothing garbles if this
# file is re-saved without a BOM or opened on another codepage)
# ============================================================

function Get-ConsoleWidth {
    try   { $w = $Host.UI.RawUI.WindowSize.Width }
    catch { $w = 80 }
    if (-not $w -or $w -lt 1) { $w = 80 }
    [Math]::Max(60, [Math]::Min($w, 140))
}

function Write-Rule {
    param([string]$Char = "-", [string]$Color = "DarkCyan")
    Write-Host ($Char * (Get-ConsoleWidth)) -ForegroundColor $Color
}

function Write-Banner {
    param([Parameter(Mandatory)][string]$Title)

    $inner = (Get-ConsoleWidth) - 2
    $pad   = [Math]::Max(0, [Math]::Floor(($inner - $Title.Length) / 2))
    $line  = (" " * $pad) + $Title
    if ($line.Length -gt $inner) { $line = $line.Substring(0, $inner) }
    $line  = $line.PadRight($inner)

    Write-Host ("+" + ("-" * $inner) + "+") -ForegroundColor Cyan
    Write-Host ("|" + $line + "|")          -ForegroundColor Cyan
    Write-Host ("+" + ("-" * $inner) + "+") -ForegroundColor Cyan
}

function Write-StatusLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Value = "",
        [string]$ValueColor = "White"
    )
    Write-Host ("  {0,-17}" -f "$($Label):") -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-Success  { param([string]$Message) Write-Host "  [OK]   $Message" -ForegroundColor Green }
function Write-ErrorMsg { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Write-WarnMsg  { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-InfoMsg  { param([string]$Message) Write-Host "  [i]    $Message" -ForegroundColor DarkGray }

function Write-SectionHeader {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ""
    Write-Host " $Text" -ForegroundColor Yellow
    Write-Rule -Char "-" -Color DarkGray
}

function Pause-ForUser {
    Write-Host ""
    Write-Host "Press any key to return to the menu..." -ForegroundColor DarkGray
    # ReadKey isn't supported in ISE / VS Code consoles; fall back to Enter.
    try   { [void][System.Console]::ReadKey($true) }
    catch { [void](Read-Host) }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question)
    $answer = "$(Read-Host "$Question (y/N)")".Trim()
    return ($answer -match '^(y|yes)$')
}

function Write-OperationError {
    param($ErrorRecord)

    $msg = $ErrorRecord.Exception.Message
    Write-Host ""
    Write-ErrorMsg $msg

    if ($msg -match 'Generic failure') {
        Write-WarnMsg "'Generic failure' from Hyper-V usually means the cluster config store"
        Write-WarnMsg "(ConfigStoreRootPath) is missing or unreachable."
        Write-InfoMsg "Run D (Diagnostics) for details."
    }

    # Force a fresh health check (and node pick) on the next menu draw.
    $script:Health = $null
    $script:ManagementNode = $null
}

function Write-ChangeLog {
    param([Parameter(Mandatory)][string]$Message)

    if (-not $script:LogFile) { return }

    try {
        $dir = Split-Path -Parent $script:LogFile
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = "{0}  {1}\{2}  {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:USERDOMAIN, $env:USERNAME, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -ErrorAction Stop
    }
    catch {
        Write-InfoMsg "Could not write change log: $($_.Exception.Message)"
    }
}


# ============================================================
# Cluster / Hyper-V Data Helpers
# ============================================================

function Get-UpNodes {
    # Online nodes: Up, or Paused (a paused/draining node is still running
    # VMs and answering Hyper-V queries, so its VMs must stay visible).
    @(Get-ClusterNode -Cluster $script:ClusterName -ErrorAction Stop |
        Where-Object { $_.State -eq "Up" -or $_.State -eq "Paused" } |
        Sort-Object Name |
        ForEach-Object { $_.Name })
}

function Get-ManagementNode {
    # Picks the node that group-level operations run against. Nothing is
    # tied to a specific node:
    #   1. The node this script is running on, if it's a cluster node.
    #   2. Otherwise Up nodes before Paused ones, then alphabetical.
    #   3. A candidate is only used if it actually answers a VM Group query;
    #      if one is down or its VMMS is stuck, the next one is tried.
    # The choice is cached for the session and re-picked if that node
    # leaves the cluster or an operation fails.

    $nodes = @(Get-ClusterNode -Cluster $script:ClusterName -ErrorAction Stop |
        Where-Object { $_.State -eq "Up" -or $_.State -eq "Paused" })

    if ($nodes.Count -eq 0) {
        throw "No online nodes found in cluster '$($script:ClusterName)'."
    }

    if ($script:ManagementNode -and (@($nodes | ForEach-Object { $_.Name }) -contains $script:ManagementNode)) {
        return $script:ManagementNode
    }

    $ordered = $nodes | Sort-Object `
        @{ Expression = { $_.Name -ne $env:COMPUTERNAME } }, `
        @{ Expression = { $_.State -ne "Up" } }, `
        Name

    $failures = @()
    foreach ($n in $ordered) {
        try {
            [void](Get-VMGroup -ComputerName $n.Name -ErrorAction Stop)
            $script:ManagementNode = $n.Name
            return $n.Name
        }
        catch {
            $failures += "$($n.Name): $($_.Exception.Message)"
        }
    }

    throw "No cluster node answered a VM Group query. $($failures -join ' | ')"
}

function Get-CollectionGroups {
    param([Parameter(Mandatory)][string]$ComputerName)

    # -ErrorAction Stop matters: without it a failed query looks like
    # "no groups exist" instead of an error.
    @(Get-VMGroup -ComputerName $ComputerName -ErrorAction Stop |
        Where-Object { $_.GroupType -eq "VMCollectionType" } |
        Sort-Object Name)
}

function Get-ClusterVMs {
    # One parallel call across all online nodes. Each VM's ComputerName is
    # the node that currently owns it.
    $nodes = @(Get-UpNodes)
    @(Hyper-V\Get-VM -ComputerName $nodes -ErrorAction Stop |
        Where-Object { $_.IsClustered } |
        Sort-Object Name)
}

function Get-MemberIds {
    param($Group)
    @(@($Group.VMMembers) |
        Where-Object { $null -ne $_ } |
        ForEach-Object { $_.VMId })
}

function Get-GroupKey {
    # Prefer the group's InstanceId; fall back to name.
    param($Group)
    if ($Group.PSObject.Properties["InstanceId"] -and $Group.InstanceId) {
        return [string]$Group.InstanceId
    }
    [string]$Group.Name
}

function Get-GroupsForVM {
    param([object[]]$Groups, $VM)
    @($Groups | Where-Object { (Get-MemberIds -Group $_) -contains $VM.VMId })
}

function Get-MembershipLookup {
    # VMId (string) -> List of group names
    param([object[]]$Groups)

    $lookup = @{}
    foreach ($g in $Groups) {
        foreach ($id in (Get-MemberIds -Group $g)) {
            $key = $id.ToString()
            if (-not $lookup.ContainsKey($key)) {
                $lookup[$key] = New-Object System.Collections.Generic.List[string]
            }
            $lookup[$key].Add($g.Name)
        }
    }
    $lookup
}

function Resolve-GroupOnNode {
    # Membership changes run on the VM's owner node, so get that node's
    # copy of the group object.
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$ComputerName
    )

    if ($Group.ComputerName -and $Group.ComputerName -eq $ComputerName) {
        return $Group
    }

    $key   = Get-GroupKey -Group $Group
    $match = Get-CollectionGroups -ComputerName $ComputerName |
        Where-Object { (Get-GroupKey -Group $_) -eq $key } |
        Select-Object -First 1

    if (-not $match) {
        throw "VM Group '$($Group.Name)' is not visible from node '$ComputerName'. Nodes may be out of sync - run D (Diagnostics)."
    }
    $match
}


# ============================================================
# Selection Helpers
# ============================================================

function Read-Selection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [string]$Title = "Items",
        [string]$Prompt = "Select",
        [scriptblock]$Display = { param($i) $i.Name }
    )

    if ($Items.Count -eq 0) { return $null }

    Write-Host ""
    Write-Host " $($Title):" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("   {0,3}. {1}" -f ($i + 1), (& $Display $Items[$i])) -ForegroundColor Cyan
    }
    Write-Host ""

    while ($true) {
        $answer = "$(Read-Host "$Prompt [1-$($Items.Count) or name, Enter to cancel]")".Trim()

        if ($answer -eq "" -or $answer -eq "cancel") { return $null }

        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
            return $Items[$number - 1]
        }

        $byName = @($Items | Where-Object { $_.Name -eq $answer })
        if ($byName.Count -eq 1) { return $byName[0] }
        if ($byName.Count -gt 1) {
            Write-WarnMsg "More than one entry is named '$answer'. Select by number."
            continue
        }

        Write-WarnMsg "Invalid selection."
    }
}

function ConvertFrom-SelectionString {
    # Turns "1, 4-7, 11, SQLServer1" (or "all") into a sorted, de-duplicated
    # list of 1-based indexes. Throws a readable message on bad input.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][object[]]$Items
    )

    $count   = $Items.Count
    $indexes = New-Object System.Collections.Generic.List[int]
    $tokens  = @($Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($tokens.Count -eq 0) { throw "Nothing selected." }

    foreach ($t in $tokens) {

        if ($t -eq "all" -or $t -eq "*") {
            1..$count | ForEach-Object { $indexes.Add($_) }
            continue
        }

        if ($t -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]
            $b = [int]$Matches[2]
            if ($a -gt $b) { $a, $b = $b, $a }
            if ($a -lt 1 -or $b -gt $count) { throw "Range '$t' is outside 1-$count." }
            $a..$b | ForEach-Object { $indexes.Add($_) }
            continue
        }

        if ($t -match '^\d+$') {
            $n = [int]$t
            if ($n -lt 1 -or $n -gt $count) { throw "'$t' is outside 1-$count." }
            $indexes.Add($n)
            continue
        }

        # Otherwise treat it as a name (case-insensitive, exact).
        $hits = @(for ($i = 0; $i -lt $count; $i++) { if ($Items[$i].Name -eq $t) { $i + 1 } })
        if ($hits.Count -eq 1) { $indexes.Add($hits[0]); continue }
        if ($hits.Count -gt 1) { throw "More than one entry is named '$t'. Use its number instead." }
        throw "'$t' is not a number, range, or name in the list."
    }

    $indexes | Sort-Object -Unique
}

function Read-MultiSelection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [string]$Title = "Items",
        [string]$Prompt = "Select",
        [scriptblock]$Display = { param($i) $i.Name }
    )

    if ($Items.Count -eq 0) { return }

    Write-Host ""
    Write-Host " $($Title):" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("   {0,3}. {1}" -f ($i + 1), (& $Display $Items[$i])) -ForegroundColor Cyan
    }
    Write-Host ""
    Write-InfoMsg "Examples: 3   |   1, 4-7, 11, 14   |   SQLServer1, 2   |   all"

    while ($true) {
        $answer = "$(Read-Host "$Prompt [Enter to cancel]")".Trim()
        if ($answer -eq "" -or $answer -eq "cancel") { return }

        try {
            $indexes = @(ConvertFrom-SelectionString -Text $answer -Items $Items)
            foreach ($n in $indexes) { $Items[$n - 1] }
            return
        }
        catch {
            Write-WarnMsg $_.Exception.Message
        }
    }
}

function Select-VMGroup {
    param(
        [AllowEmptyCollection()][object[]]$Groups,
        [string]$Prompt = "Select group"
    )
    $display = { param($g) "{0,-30} {1,3} VM(s)" -f $g.Name, @(@($g.VMMembers) | Where-Object { $null -ne $_ }).Count }
    Read-Selection -Items $Groups -Title "VM Groups" -Prompt $Prompt -Display $display
}

function Select-ClusterVM {
    param(
        [AllowEmptyCollection()][object[]]$VMs,
        [AllowEmptyCollection()][object[]]$Groups,
        [string]$Prompt = "Select VM",
        [switch]$Multiple
    )

    $lookup = Get-MembershipLookup -Groups $Groups

    $display = {
        param($v)
        $names = $lookup[$v.VMId.ToString()]
        $label = "-"
        if ($null -ne $names) { $label = ($names | Sort-Object) -join ", " }
        "{0,-32} {1,-16} {2}" -f $v.Name, $v.ComputerName, $label
    }.GetNewClosure()

    $title = "Clustered VMs  (name / owner node / group)"
    if ($Multiple) {
        Read-MultiSelection -Items $VMs -Title $title -Prompt $Prompt -Display $display
    }
    else {
        Read-Selection -Items $VMs -Title $title -Prompt $Prompt -Display $display
    }
}


# ============================================================
# Health Check / Diagnostics
# ============================================================

function Get-ClusterHealth {
    $h = [pscustomobject]@{
        ManagementNode = $null
        ConfigStore    = $null
        CsvName        = $null
        CsvState       = $null
        Nodes          = @()
        Ungrouped      = $null
        Problems       = New-Object System.Collections.Generic.List[string]
    }

    try {
        if (@(Get-UpNodes).Count -eq 0) {
            $h.Problems.Add("No online nodes in cluster '$($script:ClusterName)'.")
            return $h
        }
    }
    catch {
        $h.Problems.Add("Cannot reach cluster: $($_.Exception.Message)")
        return $h
    }

    # If no node can answer VM Group queries, keep going: the config store
    # checks below usually explain why.
    try {
        $h.ManagementNode = Get-ManagementNode
    }
    catch {
        $h.Problems.Add($_.Exception.Message)
    }

    # --- Clustered VMs not in any group (no group-based backup) ---
    if ($h.ManagementNode) {
        try {
            $grp    = @(Get-CollectionGroups -ComputerName $h.ManagementNode)
            $lookup = Get-MembershipLookup -Groups $grp
            $h.Ungrouped = @(Get-ClusterVMs |
                Where-Object { -not $lookup.ContainsKey($_.VMId.ToString()) } |
                ForEach-Object { $_.Name })
        }
        catch { }
    }

    # --- ConfigStoreRootPath ---
    $storeRead = $false
    try {
        $h.ConfigStore = (Get-ClusterResource -Cluster $script:ClusterName -Name "Virtual Machine Cluster WMI" -ErrorAction Stop |
            Get-ClusterParameter -Name ConfigStoreRootPath -ErrorAction Stop).Value
        $storeRead = $true
    }
    catch {
        $h.Problems.Add("Could not read ConfigStoreRootPath: $($_.Exception.Message)")
    }

    if ($storeRead -and [string]::IsNullOrWhiteSpace($h.ConfigStore)) {
        $h.Problems.Add("ConfigStoreRootPath is not set. VM Groups will not be shared across the cluster.")
    }
    elseif ($storeRead -and $script:ExpectedConfigStore -and
            $h.ConfigStore.TrimEnd('\') -ne $script:ExpectedConfigStore.TrimEnd('\')) {
        $h.Problems.Add("ConfigStoreRootPath is '$($h.ConfigStore)', expected '$($script:ExpectedConfigStore)'.")
    }

    # --- CSV holding the config store ---
    if ($h.ConfigStore) {
        try {
            foreach ($csv in (Get-ClusterSharedVolume -Cluster $script:ClusterName -ErrorAction Stop)) {
                foreach ($info in @($csv.SharedVolumeInfo)) {
                    $root = ([string]$info.FriendlyVolumeName).TrimEnd('\')
                    if (-not $root) { continue }
                    if ($h.ConfigStore.TrimEnd('\') -eq $root -or
                        $h.ConfigStore.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $h.CsvName  = $csv.Name
                        $h.CsvState = [string]$csv.State
                    }
                }
            }

            if (-not $h.CsvName) {
                $h.Problems.Add("ConfigStoreRootPath is not on any Cluster Shared Volume (was the CSV removed or renamed?).")
            }
            elseif ($h.CsvState -ne "Online") {
                $h.Problems.Add("CSV '$($h.CsvName)' holding the config store is $($h.CsvState).")
            }
        }
        catch {
            $h.Problems.Add("Could not query Cluster Shared Volumes: $($_.Exception.Message)")
        }
    }

    # --- Per-node VMMS + store reachability (one parallel WinRM call) ---
    try {
        $nodes = @(Get-UpNodes)
        $h.Nodes = @(Invoke-Command -ComputerName $nodes -ErrorAction Stop -ArgumentList @([string]$h.ConfigStore) -ScriptBlock {
            param($StorePath)
            $svc     = Get-Service -Name vmms -ErrorAction SilentlyContinue
            $vmms    = "NotInstalled"
            if ($svc) { $vmms = [string]$svc.Status }
            $visible = $false
            if ($StorePath) { $visible = Test-Path -LiteralPath $StorePath }
            [pscustomobject]@{
                Node         = $env:COMPUTERNAME
                Vmms         = $vmms
                StoreVisible = $visible
            }
        } | Sort-Object Node)

        foreach ($n in $h.Nodes) {
            if ($n.Vmms -ne "Running") {
                $h.Problems.Add("VMMS on $($n.Node) is $($n.Vmms).")
            }
            if ($h.ConfigStore -and -not $n.StoreVisible) {
                $h.Problems.Add("Config store path is not reachable from $($n.Node).")
            }
        }
    }
    catch {
        $h.Problems.Add("Could not check nodes over WinRM: $($_.Exception.Message)")
    }

    $h
}

function Get-GroupViewSignature {
    # One string describing every group and its members as seen from a host.
    param([Parameter(Mandatory)][string]$ComputerName)

    $parts = foreach ($g in (Get-CollectionGroups -ComputerName $ComputerName)) {
        $members = @(@($g.VMMembers) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { $_.Name } |
            Sort-Object)
        "{0}=[{1}]" -f $g.Name, ($members -join ",")
    }
    (@($parts) | Sort-Object) -join "; "
}

function Show-ViewConsistency {
    # Compares the management node's view with every other node and with the
    # cluster name (the view Veeam relies on). Returns $true if all agree.
    try {
        $mgmt    = Get-ManagementNode
        $sources = @($mgmt) + @(Get-UpNodes | Where-Object { $_ -ne $mgmt }) + @($script:ClusterName)
    }
    catch {
        Write-ErrorMsg "Cannot compare views: $($_.Exception.Message)"
        return $false
    }

    $baseline = $null
    $allMatch = $true

    foreach ($src in $sources) {
        try {
            $sig = Get-GroupViewSignature -ComputerName $src
            if ($src -eq $mgmt) { $baseline = $sig }

            if ($sig -eq $baseline) {
                Write-Success ("{0,-30} matches" -f $src)
            }
            else {
                Write-WarnMsg ("{0,-30} DIFFERS: {1}" -f $src, $sig)
                $allMatch = $false
            }
        }
        catch {
            Write-ErrorMsg ("{0,-30} {1}" -f $src, $_.Exception.Message)
            $allMatch = $false
        }
    }

    if ($null -ne $baseline) {
        $shown = $baseline
        if (-not $shown) { $shown = "(no groups)" }
        Write-InfoMsg "Baseline ($mgmt): $shown"
    }

    $allMatch
}

function Restart-VmmsAllNodes {
    # One node at a time. Running VMs keep running; Hyper-V management is
    # briefly unavailable on each node while VMMS restarts.
    foreach ($node in (Get-UpNodes)) {
        Write-WarnMsg "Restarting VMMS on $node..."
        try {
            Invoke-Command -ComputerName $node -ErrorAction Stop -ScriptBlock {
                Restart-Service -Name vmms -ErrorAction Stop
            }
            Write-Success "VMMS restarted on $node."
            Write-ChangeLog "VMMS   restarted on $node"
        }
        catch {
            Write-ErrorMsg "VMMS restart on $node failed: $($_.Exception.Message)"
        }
    }
    $script:Health = $null
    $script:ManagementNode = $null
}

function Show-Diagnostics {
    Write-SectionHeader "Diagnostics"

    Write-InfoMsg "Running health check..."
    $script:Health = Get-ClusterHealth
    $h = $script:Health

    $store = $h.ConfigStore
    if (-not $store) { $store = "(not set)" }
    $csv = "-"
    if ($h.CsvName) { $csv = "$($h.CsvName) ($($h.CsvState))" }
    $expected = $script:ExpectedConfigStore
    if (-not $expected) { $expected = "(not checked)" }
    $mgmt = $h.ManagementNode
    if (-not $mgmt) { $mgmt = "Unavailable" }

    Write-Host ""
    Write-StatusLine -Label "Cluster"         -Value $script:ClusterName -ValueColor Cyan
    Write-StatusLine -Label "Management Node" -Value $mgmt
    Write-StatusLine -Label "Config Store"    -Value $store
    Write-StatusLine -Label "Expected Store"  -Value $expected
    Write-StatusLine -Label "Store CSV"       -Value $csv

    if ($h.Nodes.Count -gt 0) {
        Write-Host ""
        $h.Nodes | Format-Table Node, Vmms, StoreVisible -AutoSize | Out-Host
    }

    if ($h.Problems.Count -eq 0) {
        Write-Success "No configuration problems found."
    }
    else {
        foreach ($p in $h.Problems) { Write-ErrorMsg $p }
    }

    Write-Host ""
    Write-Host " Group view consistency" -ForegroundColor Yellow
    Write-Rule -Char "." -Color DarkGray

    $consistent = Show-ViewConsistency

    if (-not $consistent -and $h.Problems.Count -eq 0) {
        Write-Host ""
        if (Read-YesNo "Views disagree. Restart VMMS on all nodes to resync?") {
            Restart-VmmsAllNodes
        }
    }

    Write-Host ""
    Write-Host " Stale group members" -ForegroundColor Yellow
    Write-Rule -Char "." -Color DarkGray
    [void](Invoke-StaleMemberCheck)
}


# ============================================================
# Stale Member Check
#
# A group member is "stale" when its VM ID no longer exists on any
# cluster node (e.g. the VM was deleted or unregistered while still
# in a group). Stale entries don't break Veeam, but they clutter the
# groups and the config store.
#
# Safety: the check only runs when EVERY cluster node is online (Up or
# Paused). A VM living on a down node would otherwise look deleted, and
# removing its membership would silently drop it from its backup job.
# ============================================================

function Find-StaleGroupMembers {
    $allNodes = @(Get-ClusterNode -Cluster $script:ClusterName -ErrorAction Stop)
    $notUp    = @($allNodes | Where-Object { $_.State -ne "Up" -and $_.State -ne "Paused" })

    if ($notUp.Count -gt 0) {
        $list = ($notUp | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ", "
        return [pscustomobject]@{ Skipped = "not every node is online: $list"; Items = @() }
    }

    $mgmt   = Get-ManagementNode
    $groups = @(Get-CollectionGroups -ComputerName $mgmt)

    # Every VM on every node, clustered or not.
    $known = @{}
    foreach ($vm in @(Hyper-V\Get-VM -ComputerName ($allNodes | ForEach-Object { $_.Name }) -ErrorAction Stop)) {
        $known[$vm.VMId.ToString()] = $true
    }

    $items = foreach ($g in $groups) {
        if ($null -eq $g.VMMembers) { continue }   # empty group, nothing to check

        foreach ($m in $g.VMMembers) {
            if ($null -eq $m) {
                [pscustomobject]@{ Group = $g; Member = $null; Name = "(unresolvable entry)"; VMId = "" }
                continue
            }
            $id = [string]$m.VMId
            if (-not $id -or -not $known.ContainsKey($id)) {
                $name = $m.Name
                if (-not $name) { $name = "(no name)" }
                [pscustomobject]@{ Group = $g; Member = $m; Name = $name; VMId = $id }
            }
        }
    }

    [pscustomobject]@{ Skipped = $null; Items = @($items) }
}

function Invoke-StaleMemberCheck {
    # Returns $true if it printed anything the user should read.
    param([switch]$Startup)

    try {
        $result = Find-StaleGroupMembers
    }
    catch {
        Write-WarnMsg "Stale-member check failed: $($_.Exception.Message)"
        return $true
    }

    if ($result.Skipped) {
        Write-WarnMsg "Stale-member check skipped: $($result.Skipped)."
        return $true
    }

    if ($result.Items.Count -eq 0) {
        if (-not $Startup) { Write-Success "No stale group members found." }
        return $false
    }

    Write-Host ""
    Write-WarnMsg "$($result.Items.Count) group member(s) refer to VMs that no longer exist on any node:"
    foreach ($s in $result.Items) {
        Write-Host ("         - {0,-28} in '{1}'  {2}" -f $s.Name, $s.Group.Name, $s.VMId) -ForegroundColor Cyan
    }
    Write-Host ""

    if (-not (Read-YesNo "Remove these stale entries now?")) {
        Write-InfoMsg "Left in place. Run D (Diagnostics) to check again later."
        return $true
    }

    $ok = 0; $failed = 0
    foreach ($s in $result.Items) {
        if ($null -eq $s.Member) {
            $failed++
            Write-ErrorMsg "Unresolvable entry in '$($s.Group.Name)' can't be removed by cmdlet. Try a VMMS restart (D), then re-check."
            continue
        }
        try {
            Remove-VMGroupMember -VMGroup $s.Group -VM $s.Member -ErrorAction Stop
            $ok++
            $script:ChangesMade = $true
            Write-ChangeLog "STALE  removed '$($s.Name)' ($($s.VMId)) from '$($s.Group.Name)'"
            Write-Success "Removed stale '$($s.Name)' from '$($s.Group.Name)'"
        }
        catch {
            $failed++
            Write-ErrorMsg "'$($s.Name)' in '$($s.Group.Name)': $($_.Exception.Message)"
        }
    }

    Write-BatchSummary -Ok $ok -Failed $failed -Verb "cleaned up"
    $true
}


# ============================================================
# Menu
# ============================================================

function Show-Menu {
    Clear-Host

    if ($null -eq $script:Health) {
        Write-Host ""
        Write-Host "  Checking cluster health..." -ForegroundColor DarkGray
        $script:Health = Get-ClusterHealth
        Clear-Host
    }
    $h = $script:Health

    $mgmt = $h.ManagementNode
    $mgmtColor = "Green"
    if (-not $mgmt) { $mgmt = "Unavailable"; $mgmtColor = "Red" }

    $store = $h.ConfigStore
    if (-not $store) { $store = "(not set)" }

    $healthy = ($h.Problems.Count -eq 0)

    Write-Banner -Title "Hyper-V Cluster VM Group Management"
    Write-Host ""
    Write-StatusLine -Label "Cluster"         -Value $script:ClusterName -ValueColor Cyan
    Write-StatusLine -Label "Management Node" -Value $mgmt  -ValueColor $mgmtColor
    Write-StatusLine -Label "Config Store"    -Value $store -ValueColor $(if ($healthy) { "Green" } else { "Red" })

    if ($healthy) {
        Write-StatusLine -Label "Health" -Value "OK" -ValueColor Green
    }
    else {
        Write-StatusLine -Label "Health" -Value "$($h.Problems.Count) issue(s) - press D for details" -ValueColor Red
        $h.Problems | Select-Object -First 2 | ForEach-Object { Write-ErrorMsg $_ }
    }

    if ($null -ne $h.Ungrouped) {
        if ($h.Ungrouped.Count -eq 0) {
            Write-StatusLine -Label "Ungrouped VMs" -Value "0" -ValueColor Green
        }
        else {
            Write-StatusLine -Label "Ungrouped VMs" -Value "$($h.Ungrouped.Count) - not covered by any group job (option 4)" -ValueColor Yellow
        }
    }
    Write-Host ""

    Write-Rule -Char "-" -Color DarkGray
    Write-Host " VM MEMBERSHIP" -ForegroundColor Yellow
    Write-Host ("   {0,-3} {1}" -f "1.", "Add VM(s) to Existing Group")
    Write-Host ("   {0,-3} {1}" -f "2.", "Move VM(s) to New Group")
    Write-Host ("   {0,-3} {1}" -f "3.", "Remove VM(s) from Group")

    Write-Host ""
    Write-Host " REPORTING" -ForegroundColor Yellow
    Write-Host ("   {0,-3} {1}" -f "4.", "List Virtual Machines")
    Write-Host ("   {0,-3} {1}" -f "5.", "View Existing Group Membership")
    Write-Host ("   {0,-3} {1}" -f "6.", "List VM Groups")

    Write-Host ""
    Write-Host " GROUP MANAGEMENT" -ForegroundColor Yellow
    Write-Host ("   {0,-3} {1}" -f "7.", "Create VM Group")
    Write-Host ("   {0,-3} {1}" -f "8.", "Delete VM Group")
    Write-Host ("   {0,-3} {1}" -f "9.", "Rename VM Group")

    Write-Host ""
    Write-Host " TOOLS" -ForegroundColor Yellow
    Write-Host ("   {0,-3} {1}" -f "D.", "Diagnostics")
    Write-Host ("   {0,-3} {1}" -f "R.", "Refresh Status")

    Write-Host ""
    Write-Rule -Char "-" -Color DarkGray
    Write-Host ("   {0,-3} {1}" -f "10.", "Exit")
    Write-Rule -Char "=" -Color Cyan
    Write-Host ""
}


# ============================================================
# 1. Add VM To Group
# ============================================================

function Add-VMToGroup {
    Write-SectionHeader "Add VM To Existing Group"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if ($groups.Count -eq 0) {
            Write-WarnMsg "No VM Groups exist yet. Create one with option 7."
            return
        }

        $group = Select-VMGroup -Groups $groups -Prompt "Select group"
        if (-not $group) { Write-WarnMsg "Operation cancelled."; return }

        $vms = @(Get-ClusterVMs)
        if ($vms.Count -eq 0) { Write-WarnMsg "No clustered VMs found."; return }

        $selected = @(Select-ClusterVM -VMs $vms -Groups $groups -Multiple -Prompt "Select VM(s) to add to '$($group.Name)'")
        if ($selected.Count -eq 0) { Write-WarnMsg "Operation cancelled."; return }

        # Sort the selection into: already in this group / in another group / clean.
        $key       = Get-GroupKey -Group $group
        $already   = New-Object System.Collections.Generic.List[object]
        $conflicts = New-Object System.Collections.Generic.List[object]
        $clean     = New-Object System.Collections.Generic.List[object]

        foreach ($vm in $selected) {
            $current = @(Get-GroupsForVM -Groups $groups -VM $vm)
            if (@($current | Where-Object { (Get-GroupKey -Group $_) -eq $key }).Count -gt 0) {
                $already.Add($vm)
            }
            elseif ($current.Count -gt 0) {
                $conflicts.Add([pscustomobject]@{ VM = $vm; Current = (($current | ForEach-Object { $_.Name }) -join ", ") })
            }
            else {
                $clean.Add($vm)
            }
        }

        if ($already.Count -gt 0) {
            Write-Host ""
            Write-InfoMsg ("Already in '{0}', skipping: {1}" -f $group.Name, (($already | ForEach-Object { $_.Name }) -join ", "))
        }

        $toAdd = New-Object System.Collections.Generic.List[object]
        $clean | ForEach-Object { $toAdd.Add($_) }

        if ($conflicts.Count -gt 0) {
            Write-Host ""
            Write-WarnMsg "These VMs are already in another group. A VM in two groups is backed up by two Veeam jobs:"
            $conflicts | ForEach-Object {
                Write-Host ("         - {0,-28} (in: {1})" -f $_.VM.Name, $_.Current) -ForegroundColor Cyan
            }
            Write-InfoMsg "To reclassify VMs, use option 2 (Move) instead."
            Write-Host ""
            Write-Host "   A. Add them to '$($group.Name)' as well"
            Write-Host "   S. Skip them, add only the rest"
            Write-Host "   C. Cancel"
            Write-Host ""

            switch ("$(Read-Host "Select [A/S/C]")".Trim().ToUpper()) {
                "A" { $conflicts | ForEach-Object { $toAdd.Add($_.VM) } }
                "S" { }
                default { Write-WarnMsg "Operation cancelled."; return }
            }
        }

        if ($toAdd.Count -eq 0) {
            Write-Host ""
            Write-WarnMsg "Nothing to add."
            return
        }

        $toAdd = @($toAdd | Sort-Object Name)

        Write-Host ""
        Write-Host (" Adding {0} VM(s) to '{1}':" -f $toAdd.Count, $group.Name) -ForegroundColor Yellow
        $toAdd | ForEach-Object { Write-Host "         - $($_.Name)" -ForegroundColor Cyan }
        Write-Host ""

        # Single-VM adds skip the confirmation, like before.
        if ($toAdd.Count -gt 1 -and -not (Read-YesNo "Proceed?")) {
            Write-WarnMsg "Operation cancelled."
            return
        }

        # Resolve the group once per owner node, then add each VM.
        $groupOnNode = @{}
        $ok        = 0
        $failed    = 0
        $lastError = $null

        Write-Host ""
        foreach ($vm in $toAdd) {
            try {
                $node = $vm.ComputerName
                if (-not $groupOnNode.ContainsKey($node)) {
                    $groupOnNode[$node] = Resolve-GroupOnNode -Group $group -ComputerName $node
                }

                Add-VMGroupMember -VMGroup $groupOnNode[$node] -VM $vm -ErrorAction Stop

                $ok++
                $script:ChangesMade = $true
                Write-ChangeLog "ADD    '$($vm.Name)' -> '$($group.Name)' (owner $node)"
                Write-Success "Added '$($vm.Name)'"
            }
            catch {
                $failed++
                $lastError = $_.Exception.Message
                Write-ErrorMsg "'$($vm.Name)': $lastError"
            }
        }

        Write-Host ""
        if ($failed -eq 0) {
            Write-Success "$ok VM(s) added to '$($group.Name)'."
        }
        else {
            Write-WarnMsg "$ok added, $failed failed."
            if ($lastError -match 'Generic failure') {
                Write-WarnMsg "'Generic failure' usually means the cluster config store is unreachable. Run D (Diagnostics)."
                $script:Health = $null
            }
        }
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# Batch Helpers (shared by Move / Remove)
# ============================================================

function Get-CachedNodeGroup {
    # Resolve a group on a node once per batch, not once per VM.
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $k = "{0}|{1}" -f $ComputerName.ToUpper(), (Get-GroupKey -Group $Group)
    if (-not $Cache.ContainsKey($k)) {
        $Cache[$k] = Resolve-GroupOnNode -Group $Group -ComputerName $ComputerName
    }
    $Cache[$k]
}

function Write-BatchSummary {
    param([int]$Ok, [int]$Failed, [string]$Verb, [string]$LastError)
    Write-Host ""
    if ($Failed -eq 0) {
        Write-Success "$Ok VM(s) $Verb."
        return
    }
    Write-WarnMsg "$Ok $Verb, $Failed failed."
    if ($LastError -match 'Generic failure') {
        Write-WarnMsg "'Generic failure' usually means the cluster config store is unreachable. Run D (Diagnostics)."
        $script:Health = $null
    }
}


# ============================================================
# 2. Move VM(s) To New Group
# ============================================================

function Move-VMToNewGroup {
    Write-SectionHeader "Move VM(s) To New Group"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if ($groups.Count -lt 2) {
            Write-WarnMsg "At least two VM Groups are needed to move VMs between them."
            return
        }

        # Only VMs that are in a group can be moved.
        $lookup = Get-MembershipLookup -Groups $groups
        $vms    = @(Get-ClusterVMs | Where-Object { $lookup.ContainsKey($_.VMId.ToString()) })

        if ($vms.Count -eq 0) {
            Write-WarnMsg "No clustered VMs are currently in a VM Group. Use option 1 to add them."
            return
        }

        $selected = @(Select-ClusterVM -VMs $vms -Groups $groups -Multiple -Prompt "Select VM(s) to move")
        if ($selected.Count -eq 0) { Write-WarnMsg "Operation cancelled."; return }

        $new = Select-VMGroup -Groups $groups -Prompt "Move selected VM(s) to"
        if (-not $new) { Write-WarnMsg "Operation cancelled."; return }
        $newKey = Get-GroupKey -Group $new

        # Build the plan.
        $plan       = New-Object System.Collections.Generic.List[object]
        $alreadyIn  = New-Object System.Collections.Generic.List[string]
        $multiGroup = New-Object System.Collections.Generic.List[string]

        foreach ($vm in $selected) {
            $current = @(Get-GroupsForVM -Groups $groups -VM $vm)

            if ($current.Count -gt 1) {
                $multiGroup.Add(("{0} (in: {1})" -f $vm.Name, (($current | ForEach-Object { $_.Name }) -join ", ")))
                continue
            }
            if ((Get-GroupKey -Group $current[0]) -eq $newKey) {
                $alreadyIn.Add($vm.Name)
                continue
            }
            $plan.Add([pscustomobject]@{ VM = $vm; Old = $current[0] })
        }

        if ($alreadyIn.Count -gt 0) {
            Write-Host ""
            Write-InfoMsg ("Already in '{0}', skipping: {1}" -f $new.Name, ($alreadyIn -join ", "))
        }
        if ($multiGroup.Count -gt 0) {
            Write-Host ""
            Write-WarnMsg "Skipping VMs that are in more than one group (fix these with option 3 first):"
            $multiGroup | ForEach-Object { Write-Host "         - $_" -ForegroundColor Cyan }
        }

        if ($plan.Count -eq 0) {
            Write-Host ""
            Write-WarnMsg "Nothing to move."
            return
        }

        Write-Host ""
        Write-Host (" Moving {0} VM(s) to '{1}':" -f $plan.Count, $new.Name) -ForegroundColor Yellow
        $plan | Sort-Object { $_.VM.Name } | ForEach-Object {
            Write-Host ("         - {0,-28} {1}  ->  {2}" -f $_.VM.Name, $_.Old.Name, $new.Name) -ForegroundColor Cyan
        }
        Write-Host ""
        Write-InfoMsg "Each VM leaves its current group's Veeam job and joins '$($new.Name)'."

        if (-not (Read-YesNo "Proceed?")) {
            Write-WarnMsg "Operation cancelled."
            return
        }

        $cache     = @{}
        $ok        = 0
        $failed    = 0
        $lastError = $null

        Write-Host ""
        foreach ($item in ($plan | Sort-Object { $_.VM.Name })) {
            $vm   = $item.VM
            $old  = $item.Old
            $node = $vm.ComputerName

            try {
                $newTarget = Get-CachedNodeGroup -Cache $cache -Group $new -ComputerName $node
                $oldTarget = Get-CachedNodeGroup -Cache $cache -Group $old -ComputerName $node

                # Add first, then remove: the VM is never without a group, so it
                # can't fall out of backup coverage partway through a move.
                Add-VMGroupMember -VMGroup $newTarget -VM $vm -ErrorAction Stop
                $script:ChangesMade = $true
            }
            catch {
                $failed++
                $lastError = $_.Exception.Message
                Write-ErrorMsg "'$($vm.Name)': $lastError (left in '$($old.Name)')"
                continue
            }

            try {
                Remove-VMGroupMember -VMGroup $oldTarget -VM $vm -ErrorAction Stop
                $ok++
                Write-ChangeLog "MOVE   '$($vm.Name)' '$($old.Name)' -> '$($new.Name)' (owner $node)"
                Write-Success ("Moved '{0}'  {1} -> {2}" -f $vm.Name, $old.Name, $new.Name)
            }
            catch {
                $failed++
                $lastError = $_.Exception.Message
                Write-ChangeLog "MOVE   '$($vm.Name)' added to '$($new.Name)' but removal from '$($old.Name)' FAILED"
                Write-ErrorMsg "'$($vm.Name)': added to '$($new.Name)' but removal from '$($old.Name)' failed: $lastError"
                Write-WarnMsg  "'$($vm.Name)' is now in both groups. Remove it from '$($old.Name)' with option 3."
            }
        }

        Write-BatchSummary -Ok $ok -Failed $failed -Verb "moved" -LastError $lastError
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 3. Remove VM(s) From Group
# ============================================================

function Remove-VMFromGroup {
    Write-SectionHeader "Remove VM(s) From Group"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)
        $lookup = Get-MembershipLookup -Groups $groups

        # Only offer VMs that are actually in a group.
        $vms = @(Get-ClusterVMs | Where-Object { $lookup.ContainsKey($_.VMId.ToString()) })

        if ($vms.Count -eq 0) {
            Write-WarnMsg "No clustered VMs are currently in a VM Group."
            return
        }

        $selected = @(Select-ClusterVM -VMs $vms -Groups $groups -Multiple -Prompt "Select VM(s) to remove from their group")
        if ($selected.Count -eq 0) { Write-WarnMsg "Operation cancelled."; return }

        # Build the plan. VMs in several groups get asked which one.
        $plan = New-Object System.Collections.Generic.List[object]

        foreach ($vm in $selected) {
            $memberGroups = @(Get-GroupsForVM -Groups $groups -VM $vm)

            if ($memberGroups.Count -eq 1) {
                $plan.Add([pscustomobject]@{ VM = $vm; Group = $memberGroups[0]; LastGroup = $true })
                continue
            }

            Write-Host ""
            Write-WarnMsg "'$($vm.Name)' is in more than one group."
            $g = Select-VMGroup -Groups $memberGroups -Prompt "Remove '$($vm.Name)' from which group"
            if (-not $g) {
                Write-InfoMsg "Skipping '$($vm.Name)'."
                continue
            }
            $plan.Add([pscustomobject]@{ VM = $vm; Group = $g; LastGroup = $false })
        }

        if ($plan.Count -eq 0) {
            Write-Host ""
            Write-WarnMsg "Nothing to remove."
            return
        }

        $plan = @($plan | Sort-Object { $_.VM.Name })
        $unprotected = @($plan | Where-Object { $_.LastGroup })

        Write-Host ""
        Write-Host (" Removing {0} VM membership(s):" -f $plan.Count) -ForegroundColor Yellow
        foreach ($item in $plan) {
            $note = ""
            if ($item.LastGroup) { $note = "  (will be in NO group)" }
            Write-Host ("         - {0,-28} from '{1}'{2}" -f $item.VM.Name, $item.Group.Name, $note) -ForegroundColor Cyan
        }
        Write-Host ""

        if ($unprotected.Count -gt 0) {
            Write-WarnMsg "$($unprotected.Count) VM(s) will no longer be in any group and will NOT be backed up by any group-based Veeam job."
        }

        # Removal drops backup coverage, so batches need a typed confirmation.
        if ($plan.Count -eq 1) {
            if (-not (Read-YesNo "Remove this membership?")) {
                Write-WarnMsg "Operation cancelled."
                return
            }
        }
        else {
            $typed = "$(Read-Host "Type REMOVE to remove these $($plan.Count) memberships")".Trim()
            if ($typed -cne "REMOVE") {
                Write-WarnMsg "Operation cancelled."
                return
            }
        }

        $cache     = @{}
        $ok        = 0
        $failed    = 0
        $lastError = $null

        Write-Host ""
        foreach ($item in $plan) {
            $vm = $item.VM
            try {
                $target = Get-CachedNodeGroup -Cache $cache -Group $item.Group -ComputerName $vm.ComputerName
                Remove-VMGroupMember -VMGroup $target -VM $vm -ErrorAction Stop

                $ok++
                $script:ChangesMade = $true
                Write-ChangeLog "REMOVE '$($vm.Name)' from '$($item.Group.Name)' (owner $($vm.ComputerName))"
                Write-Success "Removed '$($vm.Name)' from '$($item.Group.Name)'"
            }
            catch {
                $failed++
                $lastError = $_.Exception.Message
                Write-ErrorMsg "'$($vm.Name)': $lastError"
            }
        }

        Write-BatchSummary -Ok $ok -Failed $failed -Verb "removed" -LastError $lastError
    }
    catch {
        Write-OperationError $_
    }
}

# ============================================================
# 4. List Virtual Machines
# ============================================================

function List-VMs {
    Write-SectionHeader "Virtual Machines"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)
        $vms    = @(Get-ClusterVMs)

        if ($vms.Count -eq 0) {
            Write-WarnMsg "No clustered VMs found."
            return
        }

        $lookup = Get-MembershipLookup -Groups $groups
        $unassigned = 0
        $multiple   = 0

        $rows = foreach ($vm in $vms) {
            $names = $lookup[$vm.VMId.ToString()]
            $label = "-"
            if ($null -eq $names)     { $unassigned++ }
            else {
                $label = ($names | Sort-Object) -join ", "
                if ($names.Count -gt 1) { $multiple++ }
            }

            [pscustomobject]@{
                Name      = $vm.Name
                OwnerNode = $vm.ComputerName
                State     = $vm.State
                VMGroup   = $label
            }
        }

        Write-Host ""
        $rows | Format-Table Name, OwnerNode, State, VMGroup -AutoSize -Wrap | Out-Host

        if ($unassigned -gt 0) {
            Write-WarnMsg "$unassigned VM(s) are not in any group, so no group-based Veeam job covers them."
        }
        if ($multiple -gt 0) {
            Write-WarnMsg "$multiple VM(s) are in more than one group (backed up by more than one job)."
        }
        Write-InfoMsg "Group information sourced from: $mgmt"
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 5. View Existing Group Membership
# ============================================================

function View-ExistingGroupMembership {
    Write-SectionHeader "Existing Group Membership"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        Write-Host ""
        if ($groups.Count -eq 0) {
            Write-WarnMsg "No VM Groups exist."
            Write-Host ""
        }

        foreach ($group in $groups) {
            $members = @(@($group.VMMembers) | Where-Object { $null -ne $_ } | Sort-Object Name)

            Write-Host (" {0}  ({1} VM(s))" -f $group.Name, $members.Count) -ForegroundColor Cyan
            Write-Rule -Char "." -Color DarkGray

            if ($members.Count -eq 0) {
                Write-Host "   (empty)" -ForegroundColor DarkGray
            }
            else {
                $members | ForEach-Object { Write-Host "   - $($_.Name)" }
            }
            Write-Host ""
        }

        # Clustered VMs that aren't in any group.
        $lookup    = Get-MembershipLookup -Groups $groups
        $ungrouped = @(Get-ClusterVMs |
            Where-Object { -not $lookup.ContainsKey($_.VMId.ToString()) } |
            Sort-Object Name)

        Write-Host (" {0}  ({1} VM(s))" -f "No Group", $ungrouped.Count) -ForegroundColor Yellow
        Write-Rule -Char "." -Color DarkGray

        if ($ungrouped.Count -eq 0) {
            Write-Host "   (none - every clustered VM is in a group)" -ForegroundColor DarkGray
        }
        else {
            $ungrouped | ForEach-Object { Write-Host "   - $($_.Name)" -ForegroundColor Yellow }
            Write-Host ""
            Write-WarnMsg "These VMs are not covered by any group-based Veeam job. Use option 1 to assign them."
        }
        Write-Host ""

        Write-InfoMsg "Source Node: $mgmt"
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 6. List VM Groups
# ============================================================

function List-VMGroups {
    Write-SectionHeader "VM Groups"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if ($groups.Count -eq 0) {
            Write-WarnMsg "No VM Groups exist."
            return
        }

        $nameWidth = [Math]::Max(20, [Math]::Min(35, (Get-ConsoleWidth) - 25))

        Write-Host ""
        foreach ($group in $groups) {
            $count = @(@($group.VMMembers) | Where-Object { $null -ne $_ }).Count
            $label = $group.Name
            if ($label.Length -gt $nameWidth) { $label = $label.Substring(0, $nameWidth - 3) + "..." }

            Write-Host ("   {0,-$nameWidth} {1,3} VM(s)" -f $label, $count) -ForegroundColor Cyan
        }

        Write-Host ""
        Write-InfoMsg "Source Node: $mgmt"
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 7. Create VM Group
# ============================================================

function Test-GroupName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-ErrorMsg "Group name cannot be blank."
        return $false
    }
    if ($Name -match '[\\/:*?"<>|]') {
        Write-ErrorMsg 'Group name cannot contain \ / : * ? " < > |'
        return $false
    }
    $true
}

function Create-VMGroup {
    Write-SectionHeader "Create VM Group"

    $name = "$(Read-Host "Enter new group name (Enter to cancel)")".Trim()
    if ($name -eq "") { Write-WarnMsg "Operation cancelled."; return }
    if (-not (Test-GroupName -Name $name)) { return }

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if (@($groups | Where-Object { $_.Name -eq $name }).Count -gt 0) {
            Write-Host ""
            Write-WarnMsg "Group '$name' already exists."
            return
        }

        New-VMGroup -ComputerName $mgmt -Name $name -GroupType VMCollectionType -ErrorAction Stop | Out-Null

        $script:ChangesMade = $true
        Write-ChangeLog "CREATE group '$name' (node $mgmt)"

        Write-Host ""
        Write-Success "Group '$name' has been created."
        Write-InfoMsg "Created using node: $mgmt"
        Write-InfoMsg "Rescan the cluster in Veeam, then point a job at this group."
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 8. Delete VM Group
# ============================================================

function Delete-VMGroup {
    Write-SectionHeader "Delete VM Group"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if ($groups.Count -eq 0) {
            Write-WarnMsg "No VM Groups exist."
            return
        }

        $group = Select-VMGroup -Groups $groups -Prompt "Select group to delete"
        if (-not $group) { Write-WarnMsg "Operation cancelled."; return }

        $members = @(@($group.VMMembers) | Where-Object { $null -ne $_ })

        if ($members.Count -gt 0) {
            Write-Host ""
            Write-WarnMsg "Group '$($group.Name)' contains:"
            $members | Sort-Object Name | ForEach-Object { Write-Host "         - $($_.Name)" }
            Write-Host ""
            Write-WarnMsg "Cannot delete a group containing VMs. Move or remove them first."
            return
        }

        Write-Host ""
        Write-WarnMsg "Any Veeam job targeting '$($group.Name)' will lose its source object."
        if (-not (Read-YesNo "Delete group '$($group.Name)'?")) {
            Write-WarnMsg "Operation cancelled."
            return
        }

        Remove-VMGroup -VMGroup $group -Force -ErrorAction Stop

        $script:ChangesMade = $true
        Write-ChangeLog "DELETE group '$($group.Name)' (node $mgmt)"

        Write-Host ""
        Write-Success "Group '$($group.Name)' has been deleted."
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# 9. Rename VM Group
# ============================================================

function Rename-VMGroupMenu {
    Write-SectionHeader "Rename VM Group"

    try {
        $mgmt   = Get-ManagementNode
        $groups = @(Get-CollectionGroups -ComputerName $mgmt)

        if ($groups.Count -eq 0) {
            Write-WarnMsg "No VM Groups exist."
            return
        }

        $group = Select-VMGroup -Groups $groups -Prompt "Select group to rename"
        if (-not $group) { Write-WarnMsg "Operation cancelled."; return }

        $newName = "$(Read-Host "Enter new name for '$($group.Name)' (Enter to cancel)")".Trim()
        if ($newName -eq "") { Write-WarnMsg "Operation cancelled."; return }
        if (-not (Test-GroupName -Name $newName)) { return }

        $key = Get-GroupKey -Group $group
        if (@($groups | Where-Object { $_.Name -eq $newName -and (Get-GroupKey -Group $_) -ne $key }).Count -gt 0) {
            Write-WarnMsg "Group '$newName' already exists."
            return
        }

        $oldName = $group.Name
        Rename-VMGroup -VMGroup $group -NewName $newName -ErrorAction Stop

        $script:ChangesMade = $true
        Write-ChangeLog "RENAME group '$oldName' -> '$newName' (node $mgmt)"

        Write-Host ""
        Write-Success "Group '$oldName' renamed to '$newName'."
        Write-InfoMsg "Rescan the cluster in Veeam and confirm the job still references this group."
    }
    catch {
        Write-OperationError $_
    }
}


# ============================================================
# Exit
# ============================================================

function Invoke-ExitFlow {
    # Returns $true when the script should exit.
    Write-Host ""

    if (-not $script:ChangesMade) {
        Write-InfoMsg "No VM Group changes were made. Exiting..."
        return $true
    }

    Write-WarnMsg "VM Group changes were made. Checking that all nodes and the cluster view agree..."
    Write-Host ""

    if (Show-ViewConsistency) {
        Write-Host ""
        Write-Success "All views agree. No VMMS restart needed. Exiting..."
        return $true
    }

    Write-Host ""
    Write-WarnMsg "Views disagree. Veeam may not see the latest membership until they resync."
    Write-Host ""
    Write-Host " 1. Restart VMMS on all nodes and exit"
    Write-Host " 2. Exit without restarting VMMS"
    Write-Host " 3. Cancel (back to menu)"
    Write-Host ""

    switch ("$(Read-Host "Select")".Trim()) {
        "1" { Restart-VmmsAllNodes; return $true }
        "2" { Write-InfoMsg "Exiting without restarting VMMS."; return $true }
        default { return $false }
    }
}


# ============================================================
# Startup
# ============================================================

try {
    Import-Module FailoverClusters -ErrorAction Stop
    Import-Module Hyper-V          -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-ErrorMsg "Required PowerShell module missing: $($_.Exception.Message)"
    Write-InfoMsg  "Windows Server: Install-WindowsFeature RSAT-Clustering-PowerShell, Hyper-V-PowerShell"
    Write-InfoMsg  "Windows client: enable the RSAT Failover Clustering and Hyper-V Module optional features."
    exit 1
}

# Stale-member check. Only pauses if there's something to read.
Clear-Host
Write-Host ""
Write-Host "  Checking VM Groups for stale members..." -ForegroundColor DarkGray
if (Invoke-StaleMemberCheck -Startup) { Pause-ForUser }


# ============================================================
# Main Loop
# ============================================================

$exitRequested = $false

do {
    Show-Menu

    $choice = "$(Read-Host "Enter your choice")".Trim().ToUpper()
    $pause  = $true

    switch ($choice) {
        "1"  { Add-VMToGroup }
        "2"  { Move-VMToNewGroup }
        "3"  { Remove-VMFromGroup }
        "4"  { List-VMs }
        "5"  { View-ExistingGroupMembership }
        "6"  { List-VMGroups }
        "7"  { Create-VMGroup }
        "8"  { Delete-VMGroup }
        "9"  { Rename-VMGroupMenu }
        "D"  { Show-Diagnostics }
        "R"  { $script:Health = $null; $script:ManagementNode = $null; $pause = $false }
        "10" { $exitRequested = Invoke-ExitFlow }
        "Q"  { $exitRequested = Invoke-ExitFlow }
        default {
            Write-Host ""
            Write-WarnMsg "Invalid choice, please try again."
        }
    }

    # Membership/group changes alter the header's counts; re-check next draw.
    if ($choice -in "1", "2", "3", "7", "8", "9") { $script:Health = $null }

    if (-not $exitRequested -and $pause) { Pause-ForUser }

} while (-not $exitRequested)
