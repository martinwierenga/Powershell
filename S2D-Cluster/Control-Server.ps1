<#
.SYNOPSIS
  Build MS01 control-plane: AD/DNS/DHCP primary, WAC, BC Hosted Cache, WDS/PXE, File-Witness, WSB.
#>

#— VARIABLES —#
$Domain        = ‘wierenga.tech’
$DSRMpwd       = Read-Host ‘DSRM password (SecureString)’ -AsSecureString

# VLAN IPs on eth0 trunked 10,20,30,50,60
$vlanCfg = @{
  10 = ’10.0.10.2’
  20 = ’10.0.20.2’
  30 = ’10.0.30.2’
  50 = ’10.0.50.2’
  60 = ’10.0.60.2’
}

# Witness share
$WitnessPath   = ‘D:\Witness’
$WitnessShare  = ‘WitnessShare’

# BranchCache
$BCPath        = ‘D:\Cache’
$BC_SizeGB     = 200

# WDS
$WDSPath       = ‘D:\RemoteInstall’

# WAC installer (stage locally first)
$WAC_MSI       = ‘C:\Temp\WindowsAdminCenter.msi’

# Backup target
$BackupTarget  = ‘E:’


# 1) Install Roles/Features + Network ATC prerequisites
Install-WindowsFeature `
  AD-Domain-Services, DNS, DHCP, `
  FS-BranchCache, FS-FileServer, `
  Windows-Server-Backup, WDS, `
  Web-Windows-Auth, Web-Mgmt-Console, `
  NetworkATC, Data-Center-Bridging `
  -IncludeManagementTools    # ATC prereqs[43dcd9a7-70db-4a1f-b0ae-981daa162054](https://learn.microsoft.com/en-us/windows-server/networking/network-atc/network-atc?citationMarker=43dcd9a7-70db-4a1f-b0ae-981daa162054 “1”)

# 2) VLAN IP sub-interfaces
Foreach($v in $vlanCfg.Keys) {
  New-NetIPAddress `
    -InterfaceAlias ‘Ethernet0’ `
    -IPAddress $vlanCfg[$v] `
    -PrefixLength 24
}

# 3) Promote to DC + DNS
Import-Module ADDSDeployment
Install-ADDSDomainController `
  -DomainName $Domain `
  -InstallDns `
  -Credential (Get-Credential -Message ‘Domain Admin:’) `
  -SafeModeAdministratorPassword $DSRMpwd `
  -Force

# 4) DHCP primary + failover config
Add-DhcpServerv4Scope -Name ‘Office’ `
  -StartRange 10.0.10.100 -EndRange 10.0.10.200 `
  -SubnetMask 255.255.255.0 -ScopeId 10.0.10.0
Add-DhcpServerv4Failover -Name ‘DHCP-Failover’ `
  -PartnerServer ’10.0.40.10’ `
  -ScopeId 10.0.10.0 -Mode LoadBalance -LoadBalancePercent 50

# 5) BranchCache Hosted Cache
Enable-BCHostedServer –RegisterAsDistributedCache
Set-BCServiceConfiguration `
  -CacheLocation $BCPath `
  -MaxCacheSize ($BC_SizeGB*1GB)

# 6) File-Share Witness
New-Item -Path $WitnessPath -ItemType Directory -Force
New-SmbShare -Name $WitnessShare `
  -Path $WitnessPath `
  -FullAccess ‘NT AUTHORITY\SYSTEM’,’WIERENGA\Domain Admins’

# 7) WDS/PXE
Initialize-WdsServer -RemInst $WDSPath

# 8) Windows Admin Center
Start-Process msiexec.exe -ArgumentList “/i `”$WAC_MSI`” /qn SME_PORT=6516 SSL_CERTIFICATE_OPTION=CreateSelfSigned” -Wait

# 9) Windows Server Backup
Import-Module WindowsServerBackup
$policy = New-WBPolicy
Add-WBVolume -Policy $policy -VolumePath C:,D:
New-WBBackupTarget -Policy $policy -VolumePath $BackupTarget
Set-WBSchedule -Policy $policy -Schedule 02:00
Enable-WBPolicy -Policy $policy

# 10) (optional) Enforce ATC on MS01 for consistency
Add-NetIntent -Name MGMT_Trunk `
  -AdapterName ‘Ethernet0’ -Management -ManagementVlan 10
Get-NetIntentStatus

