<#
.SYNOPSIS
  CCES-R8120-LDAP-EPS: stages Check Point Endpoint Security client deployment via a GPO
  computer startup script, for the CCES R81.20 lab (A-LDAP, Windows Server 2016).

.DESCRIPTION
  1. Copies the exported Endpoint package to a local folder and shares it read-only.
  2. Creates an OU and moves the target computers into it.
  3. Creates and links a GPO that:
       - enables "Always wait for the network at computer startup and logon"
       - raises the GPO script timeout to 30 minutes
       - turns on verbose Windows Installer logging
       - runs Install-EPS.cmd at computer startup (skips if the client is already installed)
  4. Optional (-Restart): reboots each target with shutdown.exe, watches the install log over
     the C$ admin share, reboots a second time if the GPO was only applied in the background,
     and performs the final reboot the MSI asks for (exit code 3010).

.EXAMPLE
  .\Deploy-EPSLab.ps1 -Restart
  Full package from C:\Temp\EPS-Full to A-Host, hands-off.

.EXAMPLE
  .\Deploy-EPSLab.ps1 -PackageFolder C:\Temp\EPS-Initial -ShareRoot C:\EPS-Initial -ShareName 'EPS-Initial$' -OuName Endpoints-Initial -GpoName 'Deploy - CP Endpoint Initial' -ComputerNames A-Host -Restart

.EXAMPLE
  .\Deploy-EPSLab.ps1 -Remove
  Removes the GPO and share, moves A-Host back to Computers, deletes the OU if empty.

.NOTES
  Run elevated on the DC, ideally in Windows PowerShell 5.1 (powershell.exe).
  -Remove does NOT uninstall the Endpoint client from the targets.
  https://github.com/Don-Paterson/CCES-R8120-LDAP-EPS
#>
[CmdletBinding()]
param(
    [string]$PackageFolder = 'C:\Temp\EPS-Full',
    [string]$MsiName       = 'EPS.msi',
    [string]$ShareRoot     = 'C:\EPS-Full',
    [string]$ShareName     = 'EPS-Full$',
    [string]$OuName        = 'Endpoints-Full',
    [string]$GpoName       = 'Deploy - CP Endpoint Full',
    [string[]]$ComputerNames = @('A-Host'),
    [switch]$Restart,
    [int]$BootTimeoutMinutes    = 15,
    [int]$GpoWaitMinutes        = 5,
    [int]$InstallTimeoutMinutes = 30,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# ---------- Pre-flight ----------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) prompt.'
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Warning 'Running in PowerShell 7. The AD and GroupPolicy modules load via a compatibility session; Windows PowerShell 5.1 (powershell.exe) is recommended.'
}

# Allow "-ComputerNames A-Host,A-GUI" when passed through powershell.exe -File (arrives as one string)
$ComputerNames = @($ComputerNames | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Import-Module ActiveDirectory, GroupPolicy

$domain  = Get-ADDomain
$ouDn    = "OU=$OuName,$($domain.DistinguishedName)"
$server  = "$env:COMPUTERNAME.$($domain.DNSRoot)"

# ---------- Helpers ----------
function Write-Step([string]$Message) {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] $Message" -ForegroundColor Cyan
}

function Get-ComputerObject([string]$Name) {
    try { Get-ADComputer $Name } catch { $null }
}

function Test-Port([string]$HostName, [int]$Port = 445, [int]$TimeoutMs = 1500) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected) { $tcp.EndConnect($ar); return $true }
        return $false
    }
    catch { return $false }
    finally { $tcp.Close() }
}

function Invoke-TargetRestart([string]$Computer) {
    # shutdown.exe uses InitiateSystemShutdown over RPC. Restart-Computer (WMI/DCOM) is denied in this lab.
    shutdown.exe /r /f /t 0 /m "\\$Computer" /c "Check Point Endpoint deployment"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not restart $Computer (shutdown.exe exit code $LASTEXITCODE)"
        return $false
    }
    Write-Step "Restart sent to $Computer"
    return $true
}

function Wait-TargetReboot([string]$Computer) {
    $down = (Get-Date).AddMinutes(3)
    while ((Test-Port $Computer) -and (Get-Date) -lt $down) { Start-Sleep -Seconds 3 }
    $up = (Get-Date).AddMinutes($BootTimeoutMinutes)
    while (-not (Test-Port $Computer)) {
        if ((Get-Date) -gt $up) {
            Write-Warning "$Computer did not come back within $BootTimeoutMinutes minutes"
            return $false
        }
        Start-Sleep -Seconds 5
    }
    Write-Step "$Computer is back on the network"
    return $true
}

function Get-InstallState([string]$Computer, [datetime]$Since) {
    $log = "\\$Computer\C$\Windows\Temp\EPS_install.log"
    try {
        $item = Get-Item $log -ErrorAction Stop
        if ($item.LastWriteTime -lt $Since) { return @{ State = 'None' } }
        $text = Get-Content $log -Raw -ErrorAction Stop
    }
    catch { return @{ State = 'None' } }
    $m = [regex]::Matches($text, 'MainEngineThread is returning (\d+)')
    if ($m.Count -eq 0) { return @{ State = 'Running' } }
    return @{ State = 'Done'; Code = [int]$m[$m.Count - 1].Groups[1].Value }
}

function Wait-Install([string]$Computer, [datetime]$Since) {
    $seenBy = (Get-Date).AddMinutes($GpoWaitMinutes)
    $doneBy = (Get-Date).AddMinutes($InstallTimeoutMinutes)
    $announced = $false
    while ($true) {
        $s = Get-InstallState $Computer $Since
        if ($s.State -eq 'Done') { return $s }
        if ($s.State -eq 'Running' -and -not $announced) { Write-Step "Install running on $Computer"; $announced = $true }
        if ($s.State -eq 'None' -and (Get-Date) -gt $seenBy) { return $s }
        if ((Get-Date) -gt $doneBy) { return @{ State = 'Timeout' } }
        Start-Sleep -Seconds 10
    }
}

function Invoke-Deployment([string]$Computer) {
    $prior = Get-InstallState $Computer ([datetime]::MinValue)
    if ($prior.State -eq 'Done' -and $prior.Code -in 0, 3010) {
        Write-Step "$Computer already has a successful install log (exit $($prior.Code)) - skipping restart cycle"
        return
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $since = Get-Date
        if (-not (Invoke-TargetRestart $Computer)) { return }
        if (-not (Wait-TargetReboot $Computer)) { return }
        $s = Wait-Install $Computer $since

        if ($s.State -eq 'None') {
            if ($attempt -eq 1) {
                Write-Step "No install on $Computer yet - GPO was probably applied in the background. Rebooting again."
                continue
            }
            Write-Warning "No install log on $Computer after two reboots. On the client run: gpresult /r /scope computer"
            return
        }
        if ($s.State -eq 'Timeout') {
            Write-Warning "Install on $Computer did not finish within $InstallTimeoutMinutes minutes"
            return
        }
        switch ($s.Code) {
            0    { Write-Step "$Computer : install completed (exit 0)" }
            3010 {
                Write-Step "$Computer : install completed, restart required (3010) - final reboot"
                if (Invoke-TargetRestart $Computer) { [void](Wait-TargetReboot $Computer) }
                Write-Step "$Computer : done"
            }
            1641 {
                Write-Step "$Computer : installer started its own restart (1641)"
                [void](Wait-TargetReboot $Computer)
            }
            default { Write-Warning "$Computer : install failed (exit $($s.Code)). Log: \\$Computer\C$\Windows\Temp\EPS_install.log" }
        }
        return
    }
}

# ---------- Teardown ----------
if ($Remove) {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Remove-GPO -Name $GpoName -Confirm:$false
        Write-Step "Removed GPO '$GpoName'"
    }
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $ShareName -Force
        Write-Step "Removed share $ShareName"
    }
    foreach ($c in $ComputerNames) {
        $obj = Get-ComputerObject $c
        if ($obj -and $obj.DistinguishedName -like "*,$ouDn") {
            Move-ADObject -Identity $obj.DistinguishedName -TargetPath $domain.ComputersContainer
            Write-Step "Moved $c back to $($domain.ComputersContainer)"
        }
    }
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'") {
        if (-not (Get-ADObject -SearchBase $ouDn -SearchScope OneLevel -Filter *)) {
            Remove-ADOrganizationalUnit -Identity $ouDn -Confirm:$false
            Write-Step "Removed empty OU $ouDn"
        } else {
            Write-Warning "OU $ouDn is not empty - left in place"
        }
    }
    Write-Host "`nThe Endpoint client is still installed on the targets, and $ShareRoot is left on disk."
    return
}

# ---------- 1. Package + share ----------
if (-not (Test-Path (Join-Path $PackageFolder $MsiName))) {
    $found = @(Get-ChildItem $PackageFolder -Filter *.msi -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) {
        $MsiName = $found[0].Name
        Write-Step "Using $MsiName found in $PackageFolder"
    } else {
        throw "$MsiName not found in $PackageFolder (and not exactly one .msi to fall back on). Copy the exported package there or use -PackageFolder / -MsiName."
    }
}
$msiUnc = "\\$server\$ShareName\$MsiName"

New-Item $ShareRoot -ItemType Directory -Force | Out-Null
Write-Step "Copying package to $ShareRoot"
Copy-Item (Join-Path $PackageFolder '*') $ShareRoot -Recurse -Force

if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $ShareName -Path $ShareRoot -ReadAccess 'NT AUTHORITY\Authenticated Users' | Out-Null
}
icacls $ShareRoot /grant "$($domain.NetBIOSName)\Domain Computers:(OI)(CI)RX" | Out-Null
Write-Step "Share ready: \\$server\$ShareName"

# ---------- 2. OU + computer placement ----------
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'")) {
    New-ADOrganizationalUnit -Name $OuName -Path $domain.DistinguishedName -ProtectedFromAccidentalDeletion $false
    Write-Step "Created OU $ouDn"
}
$targets = @()
foreach ($c in $ComputerNames) {
    $obj = Get-ComputerObject $c
    if (-not $obj) { Write-Warning "$c is not a computer account in $($domain.DNSRoot) (workgroup machine?) - skipped"; continue }
    if ($obj.DistinguishedName -notlike "*,$ouDn") {
        Move-ADObject -Identity $obj.DistinguishedName -TargetPath $ouDn
        Write-Step "Moved $c to $ouDn"
    }
    $targets += $c
}

# ---------- 3. GPO + link + settings ----------
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $GpoName }
if (-not ((Get-GPInheritance -Target $ouDn).GpoLinks.DisplayName -contains $GpoName)) {
    New-GPLink -Guid $gpo.Id -Target $ouDn | Out-Null
}

# Always wait for the network at computer startup and logon
Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\Software\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    -ValueName SyncForegroundPolicy -Type DWord -Value 1 | Out-Null
# Allow GPO scripts up to 30 min (default is 600 s)
Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\Software\Policies\Microsoft\Windows\System' `
    -ValueName MaxGPOScriptWait -Type DWord -Value 1800 | Out-Null
# Verbose Windows Installer logging
Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\Software\Policies\Microsoft\Windows\Installer' `
    -ValueName Logging -Type String -Value 'voicewarmupx' | Out-Null

# ---------- 4. Startup script into SYSVOL ----------
$gpoPath    = "\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies\{$($gpo.Id)}"
$scriptsDir = "$gpoPath\Machine\Scripts"
$startupDir = "$scriptsDir\Startup"
New-Item $startupDir -ItemType Directory -Force | Out-Null

$cmd = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$k='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; if (Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.Publisher -like 'Check Point*' -and $_.DisplayName -match 'Endpoint|Harmony' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL%==0 exit /b 0
msiexec.exe /i "__MSI__" /qn /norestart /l*v "%SystemRoot%\Temp\EPS_install.log"
exit /b 0
'@ -replace '__MSI__', $msiUnc
Set-Content "$startupDir\Install-EPS.cmd" $cmd -Encoding ASCII

$iniPath = "$scriptsDir\scripts.ini"
if (Test-Path $iniPath) { (Get-Item $iniPath -Force).Attributes = 'Normal' }
Set-Content $iniPath "[Startup]`r`n0CmdLine=Install-EPS.cmd`r`n0Parameters=`r`n" -Encoding Unicode
(Get-Item $iniPath -Force).Attributes = 'Hidden'

# ---------- 5. Register Scripts CSE + bump machine version ----------
$gpoDn = "CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName)"
$gpoAd = Get-ADObject -Identity $gpoDn -Properties gPCMachineExtensionNames, versionNumber
$ext   = [string]$gpoAd.gPCMachineExtensionNames
if ($ext -notlike '*42B5FAAE-6536-11D2-AE5A-0000F87571E3*') {
    # Scripts CSE sorts after the Registry CSE {35378EAC...}, so appending keeps GUID order
    $ext += '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
}
$newVer = [int]$gpoAd.versionNumber + 1
Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = $ext; versionNumber = $newVer }
Set-Content "$gpoPath\GPT.ini" "[General]`r`nVersion=$newVer`r`n" -Encoding ASCII
Write-Step "GPO '$GpoName' linked to $ouDn (version $newVer), installs $msiUnc"

# ---------- 6. Optional: reboot and monitor ----------
if ($Restart) {
    foreach ($c in $targets) { Invoke-Deployment $c }
} else {
    Write-Host "`nNo -Restart: the install runs at each target's next boot."
}

Write-Host "`nVerify on the client: gpresult /r /scope computer ; Get-Content `"`$env:SystemRoot\Temp\EPS_install.log`" -Tail 30"
