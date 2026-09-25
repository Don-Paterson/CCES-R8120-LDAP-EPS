# CCES-R8120-LDAP-EPS bootstrap
# Usage (elevated, on A-LDAP):
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-LDAP-EPS/main/install.ps1 | iex
# Custom parameters: set $EPSArgs first, e.g.
#   $EPSArgs = @('-Remove')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo   = 'https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-LDAP-EPS/main'
$dir    = 'C:\Temp\CCES-EPS'
$script = Join-Path $dir 'Deploy-EPSLab.ps1'

New-Item $dir -ItemType Directory -Force | Out-Null
Invoke-WebRequest "$repo/Deploy-EPSLab.ps1" -OutFile $script -UseBasicParsing
Unblock-File $script
Write-Host "Downloaded $script" -ForegroundColor Cyan

$runArgs = if ($EPSArgs) { @($EPSArgs) } else { @('-Restart') }
Remove-Variable EPSArgs -ErrorAction SilentlyContinue
Write-Host "Running in Windows PowerShell 5.1 with: $($runArgs -join ' ')" -ForegroundColor Cyan

# Always run in powershell.exe (5.1): native AD/GroupPolicy modules, no signing prompt
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @runArgs
