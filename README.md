# Hyper-V Cluster VM Group Management

An interactive PowerShell menu for managing native **Hyper-V VM Groups** (`VMCollectionType`) on a Windows Server failover cluster.

Hyper-V has no GUI for VM Groups, and in a cluster they're easy to get wrong: they depend on a shared config store, different nodes can show different views, and membership has to be changed on the node that owns each VM. This script takes care of those details and gives you a menu for creating groups and moving VMs between them, with health checks and safety prompts.

```text
Hyper-V VM  ->  VM Group membership  ->  whatever consumes the group
                (Development / Production / Critical ...)
```

---

## What VM Groups are useful for

A VM Group is a named, cluster-wide collection of VMs that tools and scripts can target as a unit. Common uses:

- **Backup classification.** Backup products that understand Hyper-V VM Groups can target a group instead of individual VMs. For example, a Veeam Backup & Replication job pointed at a group picks up whatever VMs are in it, so moving a VM to another group changes which job protects it, without editing the job. This is the use case the script was originally built for, and several of its warnings are written with it in mind. Check your own backup product's documentation for VM Group support.
- **Scripted bulk operations.** A group can stand in for a hard-coded list of VM names in your own scripts:

  ```powershell
  # Shut down every VM in the "Development" group before maintenance
  (Get-VMGroup -Name Development -ComputerName <node>).VMMembers | Stop-VM

  # Take a checkpoint of each VM in a group before patching
  (Get-VMGroup -Name Production -ComputerName <node>).VMMembers |
      Checkpoint-VM -SnapshotName "Pre-patch $(Get-Date -Format yyyy-MM-dd)"
  ```

- **Multi-tier applications.** Keep the VMs that make up one application (web, app, database) together so they can be handled as one unit.
- **Hyper-V Replica.** Microsoft supports replicating VMs that share VHD Sets as a group.
- **Organization and reporting.** Use groups as a classification you can see across the cluster, such as environment, owner or patch ring. The script's reporting options show which VMs aren't in any group.

> This script manages **VM collection groups** (`VMCollectionType`) only. Management groups (`ManagementCollectionType`, groups of groups) are not created or changed.

---

## Features

- **Batch membership changes.** Add, move or remove many VMs at once with selections like `1, 4-7, 11, 14`, VM names, or `all`.
- **No reliance on a single node.** It prefers the node it's running on. Otherwise it picks an online node that actually answers VM Group queries, and switches automatically if that node goes away.
- **Health check in the menu header.** It checks:
  - the cluster's `ConfigStoreRootPath`
  - the CSV that holds it
  - that VMMS is running on every node and can reach the store
  - how many clustered VMs are in no group
- **Diagnostics (`D`).** Runs the full health check, then compares group membership as seen from each node and from the cluster name. If the views disagree, it offers a VMMS restart.
- **Stale member cleanup.** At startup, it finds group entries whose VM no longer exists on any node and offers to remove them.
- **Safety prompts,** since group membership often drives something important, like backup coverage:
  - Move adds a VM to the new group *before* removing it from the old one, so the VM always stays in a group.
  - Every move and remove shows its plan first.
  - Removing a batch requires typing `REMOVE`.
  - VMs that would end up in no group are called out.
- **Change log.** Every change is written to `Logs\VMGroupChanges.log` next to the script, with a timestamp and the user who made it.

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- **FailoverClusters** and **Hyper-V** PowerShell modules on the machine running the script:
  - Windows Server: `Install-WindowsFeature RSAT-Clustering-PowerShell, Hyper-V-PowerShell`
  - Windows client: enable the *RSAT: Failover Clustering Tools* and *Hyper-V Module for Windows PowerShell* optional features.
- WinRM / PowerShell Remoting to every cluster node. The health check and VMMS restarts use `Invoke-Command`.
- An account with Hyper-V and cluster admin rights on the nodes.
- **`ConfigStoreRootPath` configured on the cluster.** See below; without it, VM Groups aren't shared across the cluster.

> If VMware PowerCLI is also installed on the script host, that's fine. The script calls `Hyper-V\Get-VM` explicitly so PowerCLI's `Get-VM` can't take over.

---

## Cluster prerequisite: ConfigStoreRootPath

In a cluster, VM Group definitions must live on shared storage, or each node keeps its own copy and they drift apart. Point the cluster's shared config store at a folder on a Cluster Shared Volume:

```powershell
$cluster = "hvcluster.contoso.com"
$path    = "C:\ClusterStorage\Volume1\Hyper-V-ClusterConfig"

# Create the folder from a node so it lands on the CSV
Invoke-Command -ComputerName <node> { New-Item -ItemType Directory -Path $using:path -Force | Out-Null }

# Check the current value (should be empty on a fresh cluster)
Get-ClusterResource -Cluster $cluster "Virtual Machine Cluster WMI" |
    Get-ClusterParameter ConfigStoreRootPath

# Set it
Get-ClusterResource -Cluster $cluster "Virtual Machine Cluster WMI" |
    Set-ClusterParameter -Name ConfigStoreRootPath -Value $path

# Restart VMMS on each node (running VMs stay up)
Get-ClusterNode -Cluster $cluster | ForEach-Object {
    Invoke-Command -ComputerName $_.Name { Restart-Service vmms }
}
```

Hyper-V then creates `Groups`, `Persistent Tasks` and `Snapshot Groups` under that folder.

### Choose the location carefully. It can't easily be changed later.

Once `ConfigStoreRootPath` has a value, `Set-ClusterParameter` refuses to change it ("The request is not supported"). If the CSV holding it is later removed or renamed, **every VM Group cmdlet fails with `Generic failure`**, including creating a new group.

Things to keep in mind:

- Put it on a CSV you don't expect to retire or rename.
- If you restore that CSV from a storage snapshot, the group metadata is rolled back too.
- If that CSV goes offline, VM Group operations fail cluster-wide.

<details>
<summary><b>Recovery: repointing ConfigStoreRootPath after the CSV is gone</b> (needs downtime, use at your own risk)</summary>

This edits the cluster database offline. Microsoft doesn't document it, but it's the widely used workaround. The steps below are for a **single-node** cluster. On a multi-node cluster, all nodes must be stopped and the edited node started first, so plan carefully or open a support case.

Run locally on the node:

```powershell
$resId = (Get-ClusterResource "Virtual Machine Cluster WMI").Id

# 1. Shut down VMs, back up, stop the cluster service
Get-VM | Where-Object State -eq 'Running' | Stop-VM
New-Item -ItemType Directory C:\Temp -Force | Out-Null
reg export HKLM\Cluster C:\Temp\Cluster-backup.reg /y
Stop-Service clussvc
Copy-Item C:\Windows\Cluster\CLUSDB C:\Temp\CLUSDB.bak

# 2. Remove the stale value from the offline cluster database
reg load HKLM\CLUSDB_EDIT C:\Windows\Cluster\CLUSDB
reg query  "HKLM\CLUSDB_EDIT\Resources\$resId\Parameters" /v ConfigStoreRootPath
reg delete "HKLM\CLUSDB_EDIT\Resources\$resId\Parameters" /v ConfigStoreRootPath /f
reg unload HKLM\CLUSDB_EDIT

# 3. Start the cluster and WAIT until the node is Up and all CSVs are Online
Start-Service clussvc
Get-ClusterNode; Get-ClusterSharedVolume

# 4. Set the new path, cycle the resource and VMMS
Start-ClusterResource "Virtual Machine Cluster WMI"
Get-ClusterResource "Virtual Machine Cluster WMI" |
    Set-ClusterParameter -Name ConfigStoreRootPath -Value "C:\ClusterStorage\<NewCSV>\Hyper-V-ClusterConfig"
Stop-ClusterResource  "Virtual Machine Cluster WMI"
Start-ClusterResource "Virtual Machine Cluster WMI"
Restart-Service vmms
Get-VMGroup
```

**If the cluster won't start:** stop `clussvc`, copy `C:\Temp\CLUSDB.bak` back over `C:\Windows\Cluster\CLUSDB`, and start it again.

**If `Set-ClusterParameter` still fails after the node and CSVs are healthy:** set the value directly in the offline database instead, with `reg add ... /v ConfigStoreRootPath /t REG_SZ /d "<path>"` in step 2.

**A node reboot may be needed afterward** for VM networking and VMMS to fully settle.

Old groups are lost if their metadata lived on the removed CSV. Recreate them and re-add the VMs. The new groups have new IDs, so anything that referenced the old groups needs updating: for example, rescan the cluster in your backup product and re-point its jobs.

</details>

---

## Configuration

Edit the top of `hypervvmgroups.ps1`:

```powershell
# FQDN of the Hyper-V failover cluster
$script:ClusterName = "hvcluster.contoso.com"

# Where ConfigStoreRootPath SHOULD point; the health check flags drift. $null to skip.
$script:ExpectedConfigStore = "C:\ClusterStorage\Volume1\Hyper-V-ClusterConfig"

# Change log location; $null to disable
$script:LogFile = Join-Path $PSScriptRoot "Logs\VMGroupChanges.log"
```

---

## Usage

```powershell
.\hypervvmgroups.ps1
```

Run it from any machine with the required modules: a cluster node, a management server, or an admin workstation. Keeping the script on a CSV means it's available from every node.

At startup it checks for stale group members, then shows the menu:

```text
+------------------------------------------------------------------+
|               Hyper-V Cluster VM Group Management                |
+------------------------------------------------------------------+

  Cluster:         hvcluster.contoso.com
  Management Node: HV-NODE-1
  Config Store:    C:\ClusterStorage\Volume1\Hyper-V-ClusterConfig
  Health:          OK
  Ungrouped VMs:   0

 VM MEMBERSHIP
   1.  Add VM(s) to Existing Group
   2.  Move VM(s) to New Group
   3.  Remove VM(s) from Group

 REPORTING
   4.  List Virtual Machines
   5.  View Existing Group Membership
   6.  List VM Groups

 GROUP MANAGEMENT
   7.  Create VM Group
   8.  Delete VM Group
   9.  Rename VM Group

 TOOLS
   D.  Diagnostics
   R.  Refresh Status

   10. Exit
```

### Selecting VMs

Options 1–3 show a numbered list of clustered VMs, with each VM's owner node and current group. You can enter:

| Input              | Selects                         |
|--------------------|---------------------------------|
| `3`                | VM #3                           |
| `1, 4-7, 11, 14`   | VMs 1, 4, 5, 6, 7, 11 and 14    |
| `SQLServer1, 2`    | The VM named SQLServer1, and #2 |
| `all`              | Every VM in the list            |
| *(Enter)*          | Cancel                          |

Ranges can be written backwards (`7-4`), and duplicates are ignored. Invalid input says which part was wrong and asks again.

### What each option does

| Option | Behavior |
|---|---|
| **1. Add** | Skips VMs already in the target group. If a VM is already in a *different* group, you choose: add anyway (it'll be in both groups, so anything targeting either group will include it), skip, or cancel. |
| **2. Move** | Shows an `old -> new` plan and confirms once. Each VM is added to the new group first, then removed from the old one. VMs in more than one group are skipped. |
| **3. Remove** | Shows a plan and flags VMs that will end up in **no group**. One VM needs `y`; a batch needs the word `REMOVE`. |
| **4. List VMs** | Every clustered VM with owner node, state and group, plus a count of ungrouped VMs and VMs in more than one group. |
| **5. Membership** | Each group with its members, plus a **No Group** section listing VMs that aren't covered. |
| **6. List Groups** | Group names and member counts. |
| **7–9** | Create, delete (only empty groups, with confirmation) or rename groups. |
| **D** | Full diagnostics: config store, CSV, per-node VMMS, cross-node group view comparison, stale member check. |
| **R** | Re-runs the header health check. |
| **10 / Q** | Exit. If you made changes, it checks that all nodes agree and only offers a VMMS restart if they don't. |

---

## How it talks to the cluster

- **Group-level operations** (create, list, rename, delete) run against a physical node, never the cluster name.
- **Membership changes** run against the node that currently owns each VM.
- **Shared state** lives in `ConfigStoreRootPath`, so every node sees the same groups.
- **Management node choice:**
  1. The local node, if the script is running on a cluster node.
  2. Otherwise Up nodes before Paused ones, in name order.
  3. A node is only used if it answers a VM Group query. The choice is re-made if that node leaves the cluster or an operation fails.
- **Paused (draining) nodes count as online,** so their VMs stay visible.
- **VMs and groups are matched by ID, not name.** Two objects with the same name can't be confused.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Get-VMGroup : Generic failure` on every operation | `ConfigStoreRootPath` points to a path that no longer exists (CSV removed or renamed) or is offline. Run `D`, then see the recovery section above. |
| Header shows a config store problem | The path doesn't match `$ExpectedConfigStore`, its CSV isn't Online, or a node can't reach it. |
| Groups look different from different nodes | VMMS views have drifted. `D` shows which node differs and offers a VMMS restart. |
| A rebuilt or restored VM is no longer in its group (and dropped out of anything targeting that group, such as a backup job) | The recreated VM has a new VM ID, so it isn't in the old group. It shows under **Ungrouped VMs**; add it back with option 1. |
| Stale-member check says "skipped" | A node is down. The check won't run until every node is online, so VMs on the down node aren't mistaken for deleted ones. |

---

## Changelog

**2.3**
- Management node selection no longer depends on a particular node. It prefers the local node and skips nodes that don't respond. Paused nodes count as online.
- Option 5 lists VMs that are in no group.

**2.2**
- Options 2 and 3 accept multiple VMs.
- Move and Remove show a plan first. Batch removes need a typed `REMOVE`.
- Stale group member check at startup and in Diagnostics.
- Header shows the ungrouped VM count.

**2.1**
- Option 1 accepts multiple VMs (`1, 4-7, 11`, names, `all`), with handling for VMs already in another group.

**2.0**
- Health check in the menu header, plus `D` (Diagnostics) and `R` (Refresh).
- VMs and groups matched by ID. Numbered VM picker.
- Move adds to the new group before removing from the old one.
- Confirmations and warnings on changes that affect backup coverage.
- On exit, VMMS is only restarted if views disagree, and then on all nodes, not just one.
- Fixed: Cancel on the exit prompt ended the script.
- Fixed: VM Group errors showed up as "No VM Groups exist".
- `Hyper-V\Get-VM` is called explicitly so VMware PowerCLI can't take over.
- Change log file.

**1.2**
- Original release.

---

## Disclaimer

Provided as-is, without warranty. Test in a non-production cluster first. If anything in your environment targets VM Groups, such as backup jobs or automation scripts, changing membership changes what those tools act on. Review what each operation will do before confirming.

Veeam and Veeam Backup & Replication are trademarks of Veeam Software. This project is not affiliated with or endorsed by Veeam.
