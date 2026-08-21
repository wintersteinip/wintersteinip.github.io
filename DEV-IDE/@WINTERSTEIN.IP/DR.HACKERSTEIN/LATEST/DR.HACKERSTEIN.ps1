#requires -RunAsAdministrator

# DR.HACKERSTEIN.v0.00.1.ps1
# Windows 11 Recovery / Merge Tool
#
# Behavior:
# 1. User selects a source folder.
# 2. User selects a different destination parent folder.
# 3. The script creates:
#
#    <Destination>\@MERGE
#
# 4. Non-colliding files are moved into:
#
#    <Destination>\@MERGE\<relative path>
#
# 5. Colliding files are moved into:
#
#    <Destination>\@MERGE\MERGE.0001\<relative path>
#    <Destination>\@MERGE\MERGE.0002\<relative path>
#    <Destination>\@MERGE\MERGE.0003\<relative path>
#
# 6. Existing destination files are never overwritten.
#
# Restore behavior:
# - Restore is currently folder-level only.
# - Original file locations cannot be reconstructed without a file mapping log.
#

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# ADMINISTRATOR CHECK
# ---------------------------------------------------------------------------

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    $isAdministrator = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if (-not $isAdministrator) {
        throw "Please run this script from an elevated PowerShell window as Administrator."
    }
}

# ---------------------------------------------------------------------------
# DIRECTORY HELPERS
# ---------------------------------------------------------------------------

function New-DirIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $Path `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }
}

function Get-NormalizedFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathIsSameOrNested {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $parent = Get-NormalizedFullPath -Path $ParentPath
    $child = Get-NormalizedFullPath -Path $ChildPath

    return (
        $child.Equals(
            $parent,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $child.StartsWith(
            ($parent + '\'),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Assert-SourceAndDestinationAreValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $source = Get-NormalizedFullPath -Path $SourcePath
    $destination = Get-NormalizedFullPath -Path $DestinationPath

    if ($source.Equals(
        $destination,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "The source and destination cannot be the same folder."
    }

    if (Test-PathIsSameOrNested `
        -ParentPath $SourcePath `
        -ChildPath $DestinationPath) {
        throw "The destination cannot be inside the source folder."
    }

    if (Test-PathIsSameOrNested `
        -ParentPath $DestinationPath `
        -ChildPath $SourcePath) {
        throw "The source cannot be inside the destination folder."
    }
}

# ---------------------------------------------------------------------------
# OWNERSHIP AND PERMISSIONS
# ---------------------------------------------------------------------------

function TakeOwnership-And-GrantAdmins {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot change permissions because the path does not exist: $Path"
    }

    $fullPath = Get-NormalizedFullPath -Path $Path

    Write-Host ""
    Write-Host "Taking ownership of:" -ForegroundColor Cyan
    Write-Host $fullPath -ForegroundColor Cyan

    $takeownArguments = @(
        "/F"
        $fullPath
        "/R"
        "/D"
        "Y"
    )

    $takeownResult = Start-Process `
        -FilePath "takeown.exe" `
        -ArgumentList $takeownArguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($takeownResult.ExitCode -ne 0) {
        Write-Warning "takeown.exe returned exit code $($takeownResult.ExitCode)."
    }

    Write-Host "Granting Administrators Full Control:" -ForegroundColor Cyan

    $icaclsArguments = @(
        $fullPath
        "/inheritance:e"
        "/grant:r"
        "Administrators:(F)"
        "/T"
        "/C"
    )

    $icaclsResult = Start-Process `
        -FilePath "icacls.exe" `
        -ArgumentList $icaclsArguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($icaclsResult.ExitCode -ne 0) {
        Write-Warning "icacls.exe returned exit code $($icaclsResult.ExitCode)."
    }
}

# ---------------------------------------------------------------------------
# COLLISION ROUTING
# ---------------------------------------------------------------------------

function Get-NextMergeRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [string]$FileRelativePath
    )

    $destinationRootFull = Get-NormalizedFullPath `
        -Path $DestinationRoot

    New-DirIfMissing -Path $destinationRootFull

    # Primary merge folder:
    # <Destination>\@MERGE
    $primaryMergeRoot = Join-Path `
        $destinationRootFull `
        "@MERGE"

    New-DirIfMissing -Path $primaryMergeRoot

    $primaryDestinationFile = Join-Path `
        $primaryMergeRoot `
        $FileRelativePath

    # If there is no collision, use the primary @MERGE folder.
    if (-not (Test-Path -LiteralPath $primaryDestinationFile)) {
        return $primaryMergeRoot
    }

    # Collision folders:
    # <Destination>\@MERGE\MERGE.0001
    # <Destination>\@MERGE\MERGE.0002
    # ...
    for ($index = 1; $index -le 9999; $index++) {
        $suffix = "{0:0000}" -f $index

        $collisionRoot = Join-Path `
            $primaryMergeRoot `
            "MERGE.$suffix"

        $collisionDestinationFile = Join-Path `
            $collisionRoot `
            $FileRelativePath

        if (-not (Test-Path -LiteralPath $collisionDestinationFile)) {
            New-DirIfMissing -Path $collisionRoot
            return $collisionRoot
        }
    }

    throw @"
Collision routing failed.

All collision folders from MERGE.0001 through MERGE.9999
already contain this relative path:

$FileRelativePath
"@
}

# ---------------------------------------------------------------------------
# FILE MOVE OPERATION
# ---------------------------------------------------------------------------

function Move-WithFileLevelCollisionRouting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $sourceRootFull = Get-NormalizedFullPath `
        -Path $SourceRoot

    $destinationRootFull = Get-NormalizedFullPath `
        -Path $DestinationRoot

    Assert-SourceAndDestinationAreValid `
        -SourcePath $sourceRootFull `
        -DestinationPath $destinationRootFull

    if (-not (Test-Path `
        -LiteralPath $sourceRootFull `
        -PathType Container)) {
        throw "The source folder does not exist: $sourceRootFull"
    }

    New-DirIfMissing -Path $destinationRootFull

    Write-Host ""
    Write-Host "Scanning source files..." -ForegroundColor Cyan

    $files = Get-ChildItem `
        -LiteralPath $sourceRootFull `
        -Recurse `
        -File `
        -Force `
        -ErrorAction Stop

    if ($files.Count -eq 0) {
        Write-Warning "The selected source folder contains no files."
        return
    }

    $movedCount = 0
    $failedCount = 0

    foreach ($file in $files) {
        try {
            $relativePath = $file.FullName.Substring(
                $sourceRootFull.Length
            ).TrimStart('\')

            $selectedMergeRoot = Get-NextMergeRoot `
                -DestinationRoot $destinationRootFull `
                -FileRelativePath $relativePath

            $destinationFile = Join-Path `
                $selectedMergeRoot `
                $relativePath

            $destinationDirectory = Split-Path `
                -Parent `
                $destinationFile

            New-DirIfMissing -Path $destinationDirectory

            Write-Host ""
            Write-Host "Moving file:" -ForegroundColor Green
            Write-Host "  Source:      $($file.FullName)"
            Write-Host "  Destination: $destinationFile"

            Move-Item `
                -LiteralPath $file.FullName `
                -Destination $destinationFile `
                -Force `
                -ErrorAction Stop

            $movedCount++
        }
        catch {
            $failedCount++

            Write-Warning @"
Could not move:
$($file.FullName)

Reason:
$($_.Exception.Message)
"@
        }
    }

    # Remove empty directories left behind by the file moves.
    Write-Host ""
    Write-Host "Removing empty source directories..." -ForegroundColor Cyan

    $directories = Get-ChildItem `
        -LiteralPath $sourceRootFull `
        -Recurse `
        -Directory `
        -Force `
        -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending

    foreach ($directory in $directories) {
        try {
            $remainingItems = Get-ChildItem `
                -LiteralPath $directory.FullName `
                -Force `
                -ErrorAction SilentlyContinue

            if ($null -eq $remainingItems) {
                Remove-Item `
                    -LiteralPath $directory.FullName `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "Could not remove directory: $($directory.FullName)"
        }
    }

    Write-Host ""
    Write-Host "Move operation finished." -ForegroundColor Cyan
    Write-Host "Files moved: $movedCount" -ForegroundColor Green
    Write-Host "Files failed: $failedCount" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# RESTORE OPERATION
# ---------------------------------------------------------------------------

function Restore-FolderLevel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SelectedFolder
    )

    $selectedFullPath = Get-NormalizedFullPath `
        -Path $SelectedFolder

    if (-not (Test-Path `
        -LiteralPath $selectedFullPath `
        -PathType Container)) {
        throw "The selected restore path is not a folder: $selectedFullPath"
    }

    $parent = Split-Path `
        -Parent `
        $selectedFullPath

    $target = Join-Path `
        $parent `
        "@MERGE"

    if (Test-Path -LiteralPath $target) {
        throw @"
Restore cannot continue because this folder already exists:

$target
"@
    }

    Write-Host ""
    Write-Host "Restoring folder-level path:" -ForegroundColor Cyan
    Write-Host "$selectedFullPath"
    Write-Host "To:"
    Write-Host "$target"

    Rename-Item `
        -LiteralPath $selectedFullPath `
        -NewName "@MERGE" `
        -ErrorAction Stop

    TakeOwnership-And-GrantAdmins -Path $target

    Write-Host ""
    Write-Host "Folder-level restore complete." -ForegroundColor Green
    Write-Warning "Original file names and locations require a mapping log."
}

# ---------------------------------------------------------------------------
# ERROR DISPLAY
# ---------------------------------------------------------------------------

function Show-OperationError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $message = @"
$($ErrorRecord.Exception.Message)

Command:
$($ErrorRecord.InvocationInfo.Line)

Script line:
$($ErrorRecord.InvocationInfo.ScriptLineNumber)
"@

    Write-Error $message

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

# ---------------------------------------------------------------------------
# WINDOWS FORMS USER INTERFACE
# ---------------------------------------------------------------------------

function BrowseForm-Invoke {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$OnMove,

        [Parameter(Mandatory = $true)]
        [scriptblock]$OnRestore
    )

    $form = New-Object System.Windows.Forms.Form

    $form.Text = "DR.HACKERSTEIN Recovery/Merge Tool"
    $form.Size = New-Object System.Drawing.Size(470, 210)
    $form.StartPosition = "CenterScreen"
    $form.Topmost = $false
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $btnMove = New-Object System.Windows.Forms.Button
    $btnMove.Location = New-Object System.Drawing.Point(25, 25)
    $btnMove.Size = New-Object System.Drawing.Size(195, 45)
    $btnMove.Text = "A) SELECT SOURCE AND DESTINATION"

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Location = New-Object System.Drawing.Point(240, 25)
    $btnRestore.Size = New-Object System.Drawing.Size(195, 45)
    $btnRestore.Text = "B) SELECT FOLDER TO RESTORE"

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(25, 90)
    $label.Size = New-Object System.Drawing.Size(410, 70)
    $label.Text = @"
Move:
Select a source folder and a different destination parent.
The script creates destination\@MERGE.
"@
    $label.AutoSize = $false

    $form.Controls.Add($btnMove)
    $form.Controls.Add($btnRestore)
    $form.Controls.Add($label)

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.ShowNewFolderButton = $true
    $folderDialog.RootFolder = `
        [Environment+SpecialFolder]::MyComputer

    $btnMove.Add_Click({
        try {
            $folderDialog.Description = `
                "Select the SOURCE folder to merge."

            $sourceResult = $folderDialog.ShowDialog()

            if ($sourceResult -ne `
                [System.Windows.Forms.DialogResult]::OK) {
                return
            }

            $sourcePath = $folderDialog.SelectedPath

            $folderDialog.Description = `
                "Select the DESTINATION parent folder. A @MERGE folder will be created here."

            $destinationResult = $folderDialog.ShowDialog()

            if ($destinationResult -ne `
                [System.Windows.Forms.DialogResult]::OK) {
                return
            }

            $destinationPath = $folderDialog.SelectedPath

            Assert-SourceAndDestinationAreValid `
                -SourcePath $sourcePath `
                -DestinationPath $destinationPath

            & $OnMove $sourcePath $destinationPath
        }
        catch {
            Show-OperationError `
                -ErrorRecord $_ `
                -Title "Move/Merge Failed"
        }
    })

    $btnRestore.Add_Click({
        try {
            $folderDialog.Description = `
                "Select a folder under @MERGE to restore."

            $restoreResult = $folderDialog.ShowDialog()

            if ($restoreResult -ne `
                [System.Windows.Forms.DialogResult]::OK) {
                return
            }

            $restorePath = $folderDialog.SelectedPath

            & $OnRestore $restorePath
        }
        catch {
            Show-OperationError `
                -ErrorRecord $_ `
                -Title "Restore Failed"
        }
    })

    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

try {
    Assert-Admin

    BrowseForm-Invoke `
        -OnMove {
            param(
                [string]$SelectedSource,
                [string]$SelectedDestination
            )

            $ErrorActionPreference = "Stop"

            Write-Host ""
            Write-Host "Selected source:" -ForegroundColor Cyan
            Write-Host $SelectedSource

            Write-Host ""
            Write-Host "Selected destination:" -ForegroundColor Cyan
            Write-Host $SelectedDestination

            Assert-SourceAndDestinationAreValid `
                -SourcePath $SelectedSource `
                -DestinationPath $SelectedDestination

            if (-not (Test-Path `
                -LiteralPath $SelectedSource `
                -PathType Container)) {
                throw "The selected source folder is invalid: $SelectedSource"
            }

            New-DirIfMissing -Path $SelectedDestination

            # This grants access to the source before file operations.
            TakeOwnership-And-GrantAdmins `
                -Path $SelectedSource

            # This creates:
            #
            # <SelectedDestination>\@MERGE
            # <SelectedDestination>\@MERGE\MERGE.0001
            # <SelectedDestination>\@MERGE\MERGE.0002
            #
            Move-WithFileLevelCollisionRouting `
                -SourceRoot $SelectedSource `
                -DestinationRoot $SelectedDestination

            $mergeRoot = Join-Path `
                $SelectedDestination `
                "@MERGE"

            if (Test-Path -LiteralPath $mergeRoot) {
                TakeOwnership-And-GrantAdmins `
                    -Path $mergeRoot
            }

            $completionMessage = @"
Move/Merge complete.

Source:
$SelectedSource

Destination:
$mergeRoot

Collision folders:
$mergeRoot\MERGE.0001
$mergeRoot\MERGE.0002
$mergeRoot\MERGE.0003
"@

            Write-Host ""
            Write-Host $completionMessage -ForegroundColor Green

            [System.Windows.Forms.MessageBox]::Show(
                $completionMessage,
                "Move/Merge Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } `
        -OnRestore {
            param(
                [string]$SelectedRestoreFolder
            )

            $ErrorActionPreference = "Stop"

            Restore-FolderLevel `
                -SelectedFolder $SelectedRestoreFolder

            $restoreMessage = @"
Folder-level restore complete.

Selected:
$SelectedRestoreFolder
"@

            [System.Windows.Forms.MessageBox]::Show(
                $restoreMessage,
                "Restore Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
}
catch {
    Show-OperationError `
        -ErrorRecord $_ `
        -Title "DR.HACKERSTEIN Startup Error"
}
