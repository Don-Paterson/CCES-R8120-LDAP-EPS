# CCES-R8120-LDAP-EPS

Automated Active Directory deployment of the Check Point Endpoint Security client in the CCES R81.20 lab.

It runs on **A-LDAP** (Windows Server 2016 DC, domain `alpha.cp`) and installs an exported Endpoint package on domain-joined lab machines (default: **A-Host**). The install runs from a GPO computer startup script, so it happens as SYSTEM at boot, before anyone logs on.

## Quick start

1. Export the package from SmartEndpoint (*Deployment → Packages for Export*).
2. Copy the package to A-LDAP over RDP, into `C:\Temp\EPS-Full`.
3. On A-LDAP, open an **elevated** PowerShell prompt and run:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-LDAP-EPS/main/install.ps1 | iex
```

The bootstrap downloads `Deploy-EPSLab.ps1` to `C:\Temp\CCES-EPS`. It always runs it in Windows PowerShell 5.1 with `-ExecutionPolicy Bypass`, even if you start from PowerShell 7, and with `-Restart` by default. The run is then hands-off:

- A-Host is rebooted.
- The script watches `\\A-Host\C$\Windows\Temp\EPS_install.log`.
- If the GPO was only picked up in the background, it reboots A-Host a second time.
- It performs the final reboot the MSI asks for (exit code 3010).

## Custom runs

To pass different parameters through the one-liner, set `$EPSArgs` first:

```powershell
# Initial Client package instead of the full package
$EPSArgs = @('-PackageFolder','C:\Temp\EPS-Initial','-ShareRoot','C:\EPS-Initial','-ShareName','EPS-Initial$','-OuName','Endpoints-Initial','-GpoName','Deploy - CP Endpoint Initial','-Restart')
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-LDAP-EPS/main/install.ps1 | iex

# Stage only: no reboot, the install happens at the next boot
$EPSArgs = @('-ComputerNames','A-Host')

# Teardown
$EPSArgs = @('-Remove')
```

Once the script has been downloaded, you can also run it directly:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Temp\CCES-EPS\Deploy-EPSLab.ps1 -Restart
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-PackageFolder` | `C:\Temp\EPS-Full` | Exported package folder. If `EPS.msi` isn't there but exactly one `.msi` is, that file is used. |
| `-MsiName` | `EPS.msi` | MSI file name. |
| `-ShareRoot` | `C:\EPS-Full` | Local folder the package is copied to. |
| `-ShareName` | `EPS-Full$` | Hidden read-only share. |
| `-OuName` | `Endpoints-Full` | OU the GPO is linked to. |
| `-GpoName` | `Deploy - CP Endpoint Full` | GPO name. |
| `-ComputerNames` | `A-Host` | Machines to move into the OU. Pass several as a comma-separated list. |
| `-Restart` | off | Reboot and monitor the install to completion. |
| `-BootTimeoutMinutes` | 15 | Maximum wait for a target to come back after a reboot. |
| `-GpoWaitMinutes` | 5 | Wait for an install log to appear before the second reboot. |
| `-InstallTimeoutMinutes` | 30 | Maximum time allowed for the install to finish. |
| `-Remove` | off | Remove the GPO and share, move the computers back to `Computers`, and delete the OU if it's empty. |

## What gets built

- Share `\\A-LDAP.alpha.cp\EPS-Full$`, with Read for Authenticated Users and NTFS RX for Domain Computers.
- OU `Endpoints-Full`, with the target computers moved into it.
- GPO `Deploy - CP Endpoint Full`, linked to that OU, with:
  - **Always wait for the network at computer startup and logon** enabled.
  - GPO script timeout raised to 30 minutes.
  - Verbose Windows Installer logging.
  - A startup script `Install-EPS.cmd` that exits if a Check Point Endpoint product is already installed. Otherwise it runs `msiexec /i … /qn /norestart /l*v %SystemRoot%\Temp\EPS_install.log`.

## Lab notes

- **Only domain members are targeted.** A-Remote is in WORKGROUP, so no GPO can reach it, and it keeps the official manual install. The script skips any name that isn't in AD.
- **Reboots use `shutdown.exe /m`, not `Restart-Computer`.** Remote WMI/DCOM from A-LDAP to A-Host is denied (`0x80070005`), most likely because of DCOM hardening (KB5004442) between the 2016 DC and the Windows 10 22H2 client. `shutdown.exe` uses a different RPC path that works.
- **Monitoring uses the `C$` admin share**, over SMB, which works as a domain admin.
- **Exit code 3010 is a success.** It means installed, restart required. With `-Restart`, the script does that final reboot.
- **Logon is delayed while the install runs.** A-Host's AutoAdminLogon session waits at "Please wait" while the package (about 940 MB for the full package) copies and installs.
- **The Media Encryption warning after install** only means the client detected a removable or secondary drive. It is not a deployment error.
- **`-Remove` does not uninstall the client.** To re-test on the same machine, uninstall the client or revert the lab.

## Checking on the client

```powershell
gpresult /r /scope computer                                   # GPO listed under Applied Group Policy Objects?
Get-Content "$env:SystemRoot\Temp\EPS_install.log" -Tail 30   # look for "completed successfully" and MainEngineThread is returning 0 / 3010
```
