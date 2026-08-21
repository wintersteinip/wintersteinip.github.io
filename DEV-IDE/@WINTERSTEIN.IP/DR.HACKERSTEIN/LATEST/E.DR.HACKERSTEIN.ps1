# DR.HACKERSTEIN.v0.00.0.ps1
# NEW DATE/TIME 
# OLD  DATE/TIME 
#requires -RunAsAdministrator
<#
Recovery/Merge Tool (Windows 11)
- A) Browse to Move:
  1) Renames selected folder to "@MERGE" in-place
  2) Moves its contents into E:\@MERGE
  3) If a destination file already exists (same relative path + same name/ext),
     the incoming colliding file is redirected into the next available E:\@MERGE.000X
     (0001–9999). Non-colliding files stay where they are.
  4) Takes ownership recursively and grants Administrators Full Control ("777-equivalent") recursively.

- B) Browse to Restore:
  This script currently restores at the folder level:
  - If you select a folder under one of the E:\@MERGE* destinations, it will move it back to its parent as "@MERGE"
    by reversing the "contents under @MERGE*" concept.
  - True original filename/extension restoration requires a mapping/log created earlier; not implemented.

USAGE:
1) Run this script as admin
2) Use the popup to choose A or B

NOTE:
- Collision policy is "Keep existing + redirect incoming" (no overwrite).
- Uses file-level collision routing to avoid moving non-colliding files into new folders.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script as Administrator."
    }
}

function Get-NextMergeRoot {
    param(
        [Parameter(Mandatory=$true)][string]$BasePath,   # E:\@MERGE
        [Parameter(Mandatory=$true)][string]$FileRelPath  # used to test existence
    )
    # Ensure BasePath exists
    if (-not (Test-Path $BasePath)) {
        New-Item -ItemType Directory -Path $BasePath -Force | Out-Null
    }

    # First try BasePath (E:\@MERGE)
    $candidate = $BasePath
    $destFile = Join-Path $candidate $FileRelPath
    if (-not (Test-Path $destFile)) { return $candidate }

    # Then try @MERGE.0001..@MERGE.9999
    for ($i=1; $i -le 9999; $i++) {
        $suffix = "{0:0000}" -f $i   # 0001..9999
        $cand = "${BasePath}.$suffix"
        $destFile = Join-Path $cand $FileRelPath
        if (-not (Test-Path $destFile)) {
            if (-not (Test-Path $cand)) {
                New-Item -ItemType Directory -Path $cand -Force | Out-Null
            }
            return $cand
        }
    }

    throw "Collision routing failed: all E:\@MERGE.0001..@MERGE.9999 already contain $FileRelPath"
}

function TakeOwnership-And-GrantAdmins {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    # Using icacls + takeown for recursive takeover/grant.
    # Grant: Administrators:(F)
    # takeown: /F path /R /D Y
    # icacls: grant Administrators Full Control recursively, replace existing inherited ACLs
    #
    # /T traverses subdirectories/files
    # /C continue on errors
    # /L follow symlinks (optional; leave off to avoid surprises)
    $quoted = $Path.Replace('"','')

    Write-Host "Taking ownership + granting Administrators Full Control for: $Path" -ForegroundColor Cyan
    cmd /c "takeown /F `"$quoted`" /R /D Y" | Out-Null
    cmd /c "icacls `"$quoted`" /inheritance:e /grant:r Administrators:(F) /T /C" | Out-Null
}

function New-DirIfMissing {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Move-WithFileLevelCollisionRouting {
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,   # the renamed local @MERGE folder (in-place)
        [Parameter(Mandatory=$true)][string]$DestBaseRoot # E:\@MERGE
    )

    New-DirIfMissing $DestBaseRoot

    # Enumerate all files and move them one by one to destinations chosen per collision.
    # Also ensure directories are created under chosen destination roots.
    $files = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\')
        $chosenRoot = Get-NextMergeRoot -BasePath $DestBaseRoot -FileRelPath $rel

        $destDir = Split-Path -Parent (Join-Path $chosenRoot $rel)
        New-DirIfMissing $destDir

        $destPath = Join-Path $chosenRoot $rel

        # Collision policy is "keep existing, redirect incoming"
        # chosenRoot guarantees destPath doesn't exist.
        Write-Host "Moving: $($f.FullName) -> $destPath" -ForegroundColor Green
        Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
    }

    # After moving files, clean up empty directories under source root
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -Directory -Force |
        Sort-Object FullName -Descending |
        ForEach-Object {
            try {
                if ((Get-ChildItem -LiteralPath $_.FullName -Force | Measure-Object).Count -eq 0) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
}

function Rename-FolderToMergeInPlace {
    param(
        [Parameter(Mandatory=$true)][string]$SelectedFolder
    )
    # Rename selected folder to "@MERGE" in its current parent folder.
    $parent = Split-Path -Parent $SelectedFolder
    $currentName = Split-Path -Leaf $SelectedFolder
    $target = Join-Path $parent "@MERGE"

    if ($currentName -ieq "@MERGE") {
        Write-Host "Selected folder is already @MERGE. Continuing." -ForegroundColor Yellow
        return $SelectedFolder
    }

    if (Test-Path $target) {
        throw "Cannot rename in-place: $target already exists. Please choose a different folder or move it out of the way."
    }

    Rename-Item -LiteralPath $SelectedFolder -NewName "@MERGE"
    return $target
}

function BrowseForm-Invoke {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$OnMove,
        [Parameter(Mandatory=$true)][scriptblock]$OnRestore
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Recovery/Merge Tool"
    $form.Size = New-Object System.Drawing.Size(420,170)
    $form.StartPosition = "CenterScreen"
    $form.Topmost = $false

    $btnMove = New-Object System.Windows.Forms.Button
    $btnMove.Location = New-Object System.Drawing.Point(20,20)
    $btnMove.Size = New-Object System.Drawing.Size(170,40)
    $btnMove.Text = "A) BROWSE TO MOVE"

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Location = New-Object System.Drawing.Point(210,20)
    $btnRestore.Size = New-Object System.Drawing.Size(170,40)
    $btnRestore.Text = "B) BROWSE TO RESTORE"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20,75)
    $lbl.Size = New-Object System.Drawing.Size(360,50)
    $lbl.Text = "Move: rename to @MERGE then merge contents into E:\@MERGE*"
    $lbl.AutoSize = $false

    $form.Controls.Add($btnMove)
    $form.Controls.Add($btnRestore)
    $form.Controls.Add($lbl)

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.ShowNewFolderButton = $false
    $folderDialog.Description = "Select a folder."

    $btnMove.Add_Click({
        $folderDialog.Description = "Select the folder to MOVE (it will be renamed to @MERGE in-place)."
        $res = $folderDialog.ShowDialog()
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $OnMove.Invoke($folderDialog.SelectedPath)
    })

    $btnRestore.Add_Click({
        $folderDialog.Description = "Select a folder under E:\@MERGE* to RESTORE (folder-level action)."
        $res = $folderDialog.ShowDialog()
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $OnRestore.Invoke($folderDialog.SelectedPath)
    })

    [void]$form.ShowDialog()
}

function Restore-FolderLevel {
    param(
        [Parameter(Mandatory=$true)][string]$SelectedFolder
    )
    # This is a placeholder "folder-level undo" that moves the selected folder
    # back under its parent as @MERGE (best-effort).
    #
    # True original per-file name/extension restoration requires a mapping/log created earlier.
    $parent = Split-Path -Parent $SelectedFolder
    $target = Join-Path $parent "@MERGE"

    if (Test-Path $target) {
        throw "Target already exists: $target"
    }

    Write-Host "Renaming $SelectedFolder -> $target (folder-level restore only)" -ForegroundColor Cyan
    Rename-Item -LiteralPath $SelectedFolder -NewName "@MERGE" -ErrorAction Stop

    TakeOwnership-And-GrantAdmins -Path $target
    Write-Host "Restore complete (folder-level)." -ForegroundColor Green
}

# ---------------- MAIN ----------------
Assert-Admin

$destBase = "E:\@MERGE"

BrowseForm-Invoke `
    -OnMove {
        param($selected)

        $ErrorActionPreference = "Stop"

        Write-Host "Selected folder: $selected" -ForegroundColor Cyan

        # 1) Rename in-place to @MERGE
        $renamedRoot = Rename-FolderToMergeInPlace -SelectedFolder $selected
        Write-Host "Renamed to: $renamedRoot" -ForegroundColor Cyan

        # 2) Take ownership + grant admins before heavy operations (more reliable)
        TakeOwnership-And-GrantAdmins -Path $renamedRoot

        # 3) Move contents with file-level collision routing into E:\@MERGE*
        Move-WithFileLevelCollisionRouting -SourceRoot $renamedRoot -DestBaseRoot $destBase

        # 4) Take ownership + grant admins recursively on destination roots that may have received files
        #    We apply to base root and then any .000X that exists (best-effort).
        if (Test-Path $destBase) { TakeOwnership-And-GrantAdmins -Path $destBase }

        $suffixRoots = Get-ChildItem -LiteralPath (Split-Path -Parent $destBase) -Directory -Force |
            Where-Object { $_.Name -match '^@MERGE\.\d{4}$' }

        foreach ($r in $suffixRoots) {
            $full = $r.FullName
            if (Test-Path $full) {
                TakeOwnership-And-GrantAdmins -Path $full
            }
        }

        Write-Host "Move/Merge complete." -ForegroundColor Green
        [System.Windows.Forms.MessageBox]::Show("Move/Merge complete.`nDestination: $destBase and @MERGE.0001..@MERGE.9999 as needed.","Done",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } `
    -OnRestore {
        param($selectedRestoreFolder)

        $ErrorActionPreference = "Stop"
        Restore-FolderLevel -SelectedFolder $selectedRestoreFolder
        [System.Windows.Forms.MessageBox]::Show("Restore complete (folder-level).`nSelected: $selectedRestoreFolder","Done",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
