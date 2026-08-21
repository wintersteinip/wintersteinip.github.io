# DR.HACKERSTEIN.v0.01.1.ps1
# REVISED DATE/TIME: 2026-08-21
# Status: Production-Ready (ACL-Aware Version)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script as Administrator."
    }
}

function New-DirIfMissing {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-PathIsSameOrNested {
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\')

    return (
        $child.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-SourceAndDestinationAreValid {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    $source = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
    $destination = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\')

    if ($source.Equals($destination, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source and destination cannot be the same folder."
    }

    if (Test-PathIsSameOrNested -ParentPath $source -ChildPath $destination) {
        throw "Destination cannot be inside the source folder."
    }

    if (Test-PathIsSameOrNested -ParentPath $destination -ChildPath $source) {
        throw "Source cannot be inside the destination folder."
    }
}

function Get-NextMergeRoot {
    param(
        [Parameter(Mandatory = $true)][string]$MergeRoot,
        [Parameter(Mandatory = $true)][string]$FileRelPath
    )
    New-DirIfMissing -Path $MergeRoot

    # Primary Destination: <Destination>\@MERGE
    $primaryRoot = Join-Path $MergeRoot "@MERGE"
    New-DirIfMissing -Path $primaryRoot

    $primaryFile = Join-Path $primaryRoot $FileRelPath
    if (-not (Test-Path -LiteralPath $primaryFile)) {
        return $primaryRoot
    }

    # Collision Destinations: <Destination>\@MERGE\MERGE.0001 ... 9999
    for ($i = 1; $i -le 9999; $i++) {
        $suffix = "{0:0000}" -f $i
        $candidate = Join-Path $primaryRoot "MERGE.$suffix"
        $candidateFile = Join-Path $candidate $FileRelPath

        if (-not (Test-Path -LiteralPath $candidateFile)) {
            New-DirIfMissing -Path $candidate
            return $candidate
        }
    }
    throw "No available collision destination remains for: $FileRelPath"
}

function TakeOwnership-And-GrantAdmins {
    param(
             [Parameter(Mandatory = $true)][string]$Path
    )
    
    # Check if the file system supports ACLs (NTFS/ReFS)
    $driveLetter = (Get-Item -LiteralPath $Path).PSDrive.Name
    $fs = (Get-Volume -DriveLetter $driveLetter).FileSystem
    
    if ($fs -ne "NTFS" -and $fs -ne "ReFS") {
        Write-Host "Skipping ACL modification: File system ($fs) on {$driveLetter}: does not support ownership/permissions." -ForegroundColor Yellow
        return
    }

    $quoted = $Path.Replace('"', '')
    Write-Host "Taking ownership + granting Administrators Full Control for: $Path" -ForegroundColor Cyan
    cmd /c "takeown /F `"$quoted`" /R /D Y" | Out-Null
    cmd /c "icacls `"$quoted`" /inheritance:e /grant:r Administrators:(F) /T /C" | Out-Null
}

function Move-WithFileLevelCollisionRouting {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')

    if (Test-PathIsSameOrNested -ParentPath $sourceFull -ChildPath $destinationFull) {
        throw "The destination cannot be the same as, or inside, the source folder."
    }

    New-DirIfMissing -Path $destinationFull

    $files = Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force -ErrorAction Stop

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($sourceFull.Length).TrimStart('\')
        $chosenRoot = Get-NextMergeRoot -MergeRoot $destinationFull -FileRelPath $rel

        $destPath = Join-Path $chosenRoot $rel
        $destDir = Split-Path -Parent $destPath
        New-DirIfMissing -Path $destDir

        Write-Host "Moving: $($f.FullName) -> $destPath" -ForegroundColor Green
        Move-Item -LiteralPath $f.FullName -Destination $destPath -Force -ErrorAction Stop
    }

    # Cleanup empty source directories
    Get-ChildItem -LiteralPath $sourceFull -Recurse -Directory -Force |
        Sort-Object FullName -Descending |
        ForEach-Object {
            try {
                if ((Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
}

function Restore-FolderLevel {
    param(
        [Parameter(Mandatory = $true)][string]$SelectedFolder
    )
    $parent = Split-Path -Parent $SelectedFolder
    $target = Join-Path $parent "@MERGE"

    if (Test-Path -LiteralPath $target) {
        throw "Target already exists: $target"
    }

    Write-Host "Renaming $SelectedFolder -> $target (folder-level restore only)" -ForegroundColor Cyan
    Rename-Item -LiteralPath $SelectedFolder -NewName "@MERGE" -ErrorAction Stop

    TakeOwnership-And-GrantAdmins -Path $target
    Write-Host "Restore complete (folder-level)." -ForegroundColor Green
}

function BrowseForm-Invoke {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$OnMove,
        [Parameter(Mandatory = $true)][scriptblock]$OnRestore
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Recovery/Merge Tool"
    $form.Size = New-Object System.Drawing.Size(420, 170)
    $form.StartPosition = "CenterScreen"
    $form.Topmost = $false

    $btnMove = New-Object System.Windows.Forms.Button
    $btnMove.Location = New-Object System.Drawing.Point(20, 20)
    $btnMove.Size = New-Object System.Drawing.Size(170, 40)
    $btnMove.Text = "A) BROWSE TO MOVE"

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Location = New-Object System.Drawing.Point(210, 20)
    $btnRestore.Size = New-Object System.Drawing.Size(170, 40)
    $btnRestore.Text = "B) BROWSE TO RESTORE"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20, 75)
    $lbl.Size = New-Object System.Drawing.Size(360, 50)
    $lbl.Text = "Choose a source, then choose a different destination."
    $lbl.AutoSize = $false

    $form.Controls.Add($btnMove)
    $form.Controls.Add($btnRestore)
    $form.Controls.Add($lbl)

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.ShowNewFolderButton = $true

    $btnMove.Add_Click({
        try {
            $folderDialog.Description = "Select the SOURCE folder to merge."
            if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $sourcePath = $folderDialog.SelectedPath

            $folderDialog.Description = "Select the DESTINATION parent folder."
            if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $destinationPath = $folderDialog.SelectedPath

            Assert-SourceAndDestinationAreValid -SourcePath $sourcePath -DestinationPath $destinationPath

            & $OnMove $sourcePath $destinationPath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            Write-Error $_
        }
    })

    $btnRestore.Add_Click({
        try {
            $folderDialog.Description = "Select a folder under @MERGE to restore."
            if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            & $OnRestore $folderDialog.SelectedPath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            Write-Error $_
        }
    })

    [void]$form.ShowDialog()
}

# ---------------- MAIN ----------------
Assert-Admin

BrowseForm-Invoke `
    -OnMove {
        param([string]$selectedSource, [string]$selectedDestination)

        $ErrorActionPreference = "Stop"

        Write-Host "Source: $selectedSource" -ForegroundColor Cyan
        Write-Host "Destination: $selectedDestination" -ForegroundColor Cyan

        # Ensure the target exists and we have access to the source.
        New-DirIfMissing -Path $selectedDestination
        TakeOwnership-And-GrantAdmins -Path $selectedSource

        # Perform merge with nested collision routing.
        Move-WithFileLevelCollisionRouting -SourceRoot $selectedSource -DestinationRoot $selectedDestination

        $mergeRoot = Join-Path $selectedDestination "@MERGE"
        if (Test-Path -LiteralPath $mergeRoot) { 
            TakeOwnership-And-GrantAdmins -Path $mergeRoot 
        }

        Write-Host "Move/Merge complete." -ForegroundColor Green
        [System.Windows.Forms.MessageBox]::Show("Move/Merge complete.`nDestination: $mergeRoot","Done",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } `
    -OnRestore {
        param([string]$selectedRestoreFolder)

        $ErrorActionPreference = "Stop"
        Restore-FolderLevel -SelectedFolder $selectedRestoreFolder
        [System.Windows.Forms.MessageBox]::Show("Restore complete.`nSelected: $selectedRestoreFolder","Done",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
