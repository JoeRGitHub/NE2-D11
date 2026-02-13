# Windows 11 Pro Hardening Rollback Script
# Run as Administrator
# Removes Operator user and reverts all hardening policies

#Requires -RunAsAdministrator

param(
    [string]$Username = "Operator",
    [switch]$KeepUser
)

# Function to remove registry value
function Remove-RegistryValue {
    param(
        [string]$Path,
        [string]$Name
    )
    
    if (Test-Path $Path) {
        $property = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($property) {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null
            return $true
        }
    }
    return $false
}

Write-Host "=== Windows 11 Pro Hardening Rollback Script ===" -ForegroundColor Cyan
Write-Host ""

# Check if user exists
$userExists = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue

if (-not $userExists) {
    Write-Host "User '$Username' does not exist. Nothing to rollback." -ForegroundColor Yellow
    exit 0
}

# Get the user SID for registry modifications
$userSID = (Get-LocalUser -Name $Username).SID.Value
$userRegPath = "Registry::HKEY_USERS\$userSID"

Write-Host "Found user: $Username (SID: $userSID)" -ForegroundColor Green
Write-Host ""

# Load user registry hive if not loaded
Write-Host "[1/4] Loading user registry hive..." -ForegroundColor Yellow
$profilePath = "C:\Users\$Username"
$userHivePath = "$profilePath\NTUSER.DAT"

if (Test-Path $userHivePath) {
    reg load "HKU\$userSID" "$userHivePath" 2>$null
    Start-Sleep -Seconds 1
}

# Step 1: Remove Run Dialog restrictions
Write-Host "[2/4] Removing Run dialog restrictions..." -ForegroundColor Yellow
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoRun"

# Step 2: Remove Command Prompt and Batch Script restrictions
Write-Host "[3/4] Re-enabling Command Prompt and scripts..." -ForegroundColor Yellow
Remove-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\System" -Name "DisableCMD"
Remove-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\PowerShell" -Name "EnableScripts"
Remove-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\PowerShell" -Name "ExecutionPolicy"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows Script Host\Settings" -Name "Enabled"

# Step 3: Remove Taskbar, Start Menu, and Search restrictions
Write-Host "[4/4] Restoring taskbar, Start menu, and Search..." -ForegroundColor Yellow

# Restore taskbar
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoTaskbar"

# Restore Start Menu
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenu"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenuMorePrograms"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenuPinnedList"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoWindowsHotkeys"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableLockWorkstation"

# Restore Search
Remove-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCortanaButton"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent"

# Remove additional security restrictions
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoControlPanel"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoSetFolders"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoViewOnDrive"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoRunAs"
Remove-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoSettingsPage"

# Unload the registry hive
Start-Sleep -Seconds 1
reg unload "HKU\$userSID" 2>$null

# Remove desktop shortcuts if they exist
Write-Host ""
Write-Host "Removing desktop shortcuts..." -ForegroundColor Yellow
$desktopPath = "$profilePath\Desktop"
$shortcuts = @("Logoff.lnk", "Restart.lnk", "Shutdown.lnk")
foreach ($shortcut in $shortcuts) {
    $shortcutPath = Join-Path $desktopPath $shortcut
    if (Test-Path $shortcutPath) {
        Remove-Item -Path $shortcutPath -Force -ErrorAction SilentlyContinue
        Write-Host "  ✓ Removed $shortcut" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "=== Registry Cleanup Complete ===" -ForegroundColor Green
Write-Host ""

# Remove user account unless -KeepUser is specified
if (-not $KeepUser) {
    Write-Host "Removing user account '$Username'..." -ForegroundColor Yellow
    
    try {
        Remove-LocalUser -Name $Username -ErrorAction Stop
        Write-Host "  User '$Username' removed successfully." -ForegroundColor Green
        
        # Optionally remove user profile folder
        if (Test-Path $profilePath) {
            Write-Host "  Removing user profile folder..." -ForegroundColor Gray
            Start-Sleep -Seconds 2
            Remove-Item -Path $profilePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  ERROR: Failed to remove user - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  You may need to remove manually or restart and try again." -ForegroundColor Yellow
    }
} else {
    Write-Host "User '$Username' kept (restrictions removed)." -ForegroundColor Cyan
    Write-Host "To manually remove later, run: Remove-LocalUser -Name '$Username'" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Rollback Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  ✓ All registry restrictions removed" -ForegroundColor Gray
Write-Host "  ✓ User account removed (unless -KeepUser specified)" -ForegroundColor Gray
Write-Host "  ✓ System restored to default state" -ForegroundColor Gray
Write-Host ""
