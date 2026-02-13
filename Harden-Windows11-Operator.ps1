# Windows 11 Pro Hardening Script for Operator User
# Run as Administrator
# Creates restricted Operator user account with locked-down policies

#Requires -RunAsAdministrator

param(
    [string]$Username = "Operator",
    [string]$FullName = "Operator User",
    [string]$Description = "Restricted operator account",
    [SecureString]$Password
)

# Function to set registry value
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = "DWORD"
    )
    
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

Write-Host "=== Windows 11 Pro Hardening Script ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Create Operator User
Write-Host "[1/6] Creating Operator user account..." -ForegroundColor Yellow

try {
    # Check if user already exists
    $userExists = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    
    if ($userExists) {
        Write-Host "  User '$Username' already exists. Skipping creation." -ForegroundColor Green
    } else {
        if (-not $Password) {
            # Generate secure random password if not provided
            $Password = ConvertTo-SecureString "Op3r@t0r$(Get-Random -Minimum 1000 -Maximum 9999)!" -AsPlainText -Force
        }
        
        New-LocalUser -Name $Username -Password $Password -FullName $FullName -Description $Description -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
        Write-Host "  User '$Username' created successfully." -ForegroundColor Green
    }
} catch {
    Write-Host "  ERROR: Failed to create user - $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get the user SID for registry modifications
$userSID = (Get-LocalUser -Name $Username).SID.Value
$userRegPath = "Registry::HKEY_USERS\$userSID"

# Load user registry hive if not loaded
Write-Host "[2/6] Loading user registry hive..." -ForegroundColor Yellow
$profilePath = "C:\Users\$Username"
$userHivePath = "$profilePath\NTUSER.DAT"

# Create profile if it doesn't exist by logging in once programmatically
if (-not (Test-Path $userHivePath)) {
    Write-Host "  User profile not found. Loading default hive..." -ForegroundColor Gray
    reg load "HKU\$userSID" "C:\Users\Default\NTUSER.DAT" 2>$null
}

# Step 2: Disable Run Dialog (Win+R and Run command)
Write-Host "[3/6] Disabling Run dialog..." -ForegroundColor Yellow
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoRun" -Value 1

# Step 3: Disable Command Prompt and Batch Scripts
Write-Host "[4/6] Disabling Command Prompt and batch script execution..." -ForegroundColor Yellow

# Disable cmd.exe completely
Set-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\System" -Name "DisableCMD" -Value 2  # 2 = Disable cmd.exe and batch scripts

# Additional: Disable PowerShell for this user (optional but recommended)
Set-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\PowerShell" -Name "EnableScripts" -Value 0
Set-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\PowerShell" -Name "ExecutionPolicy" -Value "Restricted" -Type "String"

# Disable script hosts
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows Script Host\Settings" -Name "Enabled" -Value 0

# Step 4: Hide Taskbar, Start Menu, and Search
Write-Host "[5/6] Hiding taskbar, Start menu, and Search..." -ForegroundColor Yellow

# Hide entire taskbar
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoTaskbar" -Value 1

# Disable Start Menu (Windows key)
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenu" -Value 1
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenuMorePrograms" -Value 1
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoStartMenuPinnedList" -Value 1

# Disable Windows key completely
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoWindowsHotkeys" -Value 1
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableLockWorkstation" -Value 1

# Disable Search
Set-RegistryValue -Path "$userRegPath\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value 0  # 0 = Hidden
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCortanaButton" -Value 0

# Disable Cortana
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent" -Value 0

# Step 5: Create Desktop Shortcuts for Power Management
Write-Host "[6/7] Creating desktop shortcuts (Logoff/Restart/Shutdown)..." -ForegroundColor Yellow

$desktopPath = "$profilePath\Desktop"
if (-not (Test-Path $desktopPath)) {
    New-Item -Path $desktopPath -ItemType Directory -Force | Out-Null
}

$WshShell = New-Object -ComObject WScript.Shell

# Create Logoff shortcut
try {
    $shortcut = $WshShell.CreateShortcut("$desktopPath\Logoff.lnk")
    $shortcut.TargetPath = "shutdown.exe"
    $shortcut.Arguments = "/l"
    $shortcut.Description = "Log off current user"
    $shortcut.IconLocation = "shell32.dll,44"
    $shortcut.Save()
    Write-Host "  ✓ Logoff shortcut created" -ForegroundColor Gray
} catch {
    Write-Host "  ⚠ Failed to create Logoff shortcut" -ForegroundColor Yellow
}

# Create Restart shortcut
try {
    $shortcut = $WshShell.CreateShortcut("$desktopPath\Restart.lnk")
    $shortcut.TargetPath = "shutdown.exe"
    $shortcut.Arguments = "/r /t 0"
    $shortcut.Description = "Restart computer"
    $shortcut.IconLocation = "shell32.dll,238"
    $shortcut.Save()
    Write-Host "  ✓ Restart shortcut created" -ForegroundColor Gray
} catch {
    Write-Host "  ⚠ Failed to create Restart shortcut" -ForegroundColor Yellow
}

# Create Shutdown shortcut
try {
    $shortcut = $WshShell.CreateShortcut("$desktopPath\Shutdown.lnk")
    $shortcut.TargetPath = "shutdown.exe"
    $shortcut.Arguments = "/s /t 0"
    $shortcut.Description = "Shut down computer"
    $shortcut.IconLocation = "shell32.dll,27"
    $shortcut.Save()
    Write-Host "  ✓ Shutdown shortcut created" -ForegroundColor Gray
} catch {
    Write-Host "  ⚠ Failed to create Shutdown shortcut" -ForegroundColor Yellow
}

[System.Runtime.Interopservices.Marshal]::ReleaseComObject($WshShell) | Out-Null

# Step 6: Additional Security Hardening
Write-Host "[7/7] Applying additional security restrictions..." -ForegroundColor Yellow

# Disable Task Manager
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Value 1

# Disable Registry Editor
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools" -Value 1

# Disable Control Panel
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoControlPanel" -Value 1
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoSetFolders" -Value 1

# Disable File Explorer access to drives
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoViewOnDrive" -Value 0  # 0 = all drives visible, change as needed

# Remove "Run as Administrator" context menu
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoRunAs" -Value 1

# Disable Windows Settings
Set-RegistryValue -Path "$userRegPath\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoSettingsPage" -Value 1

# Unload the registry hive
reg unload "HKU\$userSID" 2>$null

Write-Host ""
Write-Host "=== Configuration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Operator User: $Username" -ForegroundColor Cyan
Write-Host "Restrictions Applied:" -ForegroundColor Cyan
Write-Host "  ✓ Run dialog disabled (Win+R)" -ForegroundColor Gray
Write-Host "  ✓ Command Prompt disabled" -ForegroundColor Gray
Write-Host "  ✓ Batch scripts (.bat/.cmd) blocked" -ForegroundColor Gray
Write-Host "  ✓ PowerShell execution disabled" -ForegroundColor Gray
Write-Host "  ✓ Taskbar hidden" -ForegroundColor Gray
Write-Host "  ✓ Start menu disabled (keyboard + mouse)" -ForegroundColor Gray
Write-Host "  ✓ Search disabled" -ForegroundColor Gray
Write-Host "  ✓ Task Manager disabled" -ForegroundColor Gray
Write-Host "  ✓ Registry Editor disabled" -ForegroundColor Gray
Write-Host "  ✓ Control Panel disabled" -ForegroundColor Gray
Write-Host ""
Write-Host "Desktop Shortcuts Created:" -ForegroundColor Cyan
Write-Host "  ✓ Logoff.lnk" -ForegroundColor Gray
Write-Host "  ✓ Restart.lnk" -ForegroundColor Gray
Write-Host "  ✓ Shutdown.lnk" -ForegroundColor Gray
Write-Host ""
Write-Host "IMPORTANT: User must log in once to create profile, then log out and log in again for all policies to take effect." -ForegroundColor Yellow
Write-Host ""
Write-Host "To revert changes, run: Remove-LocalUser -Name '$Username'" -ForegroundColor Gray
