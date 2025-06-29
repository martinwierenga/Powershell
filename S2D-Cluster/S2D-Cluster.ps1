<#
.SYNOPSIS
  Build 2-node S2D + VLANs + Network ATC on NFIVE-A,B.
#>

#— VARIABLES —#
$Nodes         = ‘NFIVE-A’,’NFIVE-B’
$ClusterName   = ‘WIERENGA-S2D’
$ClusterVIP    = ’10.0.40.10’    # VLAN 40 for RDMA
$Domain        = ‘wierenga.tech’
$DCsCred       = Get-Credential -Message ‘Domain Admin creds’
$DSRMpwd       = Read-Host ‘DSRM password for new DCs’ -AsSecureString

# VLAN subnets on eth1 trunk
$vlanConfigs = @{
  10 = ’10.0.10.11’
  20 = ’10.0.20.11’
  30 = ’10.0.30.11’
  50 = ’10.0.50.11’
  60 = ’10.0.60.11’
}

# GenFiles share (2 TB ReFS)
$GenFilesSize = 2TB
$GenFilesName = ‘GenFiles’
$GenFilesACL  = @(‘WIERENGA\Domain Admins’,’WIERENGA\TechUsers’)

# File-Share witness
$WitnessShare = ‘\\MS01\WitnessShare’

# DHCP Failover details
$DhcpScope    = ’10.0.10.0’
$DhcpStart    = ’10.0.10.100’
$DhcpEnd      = ’10.0.10.200’
$DhcpPartner  = $ClusterVIP


# 1) Install Roles + Prep NICs
Invoke-Command -ComputerName $Nodes -ScriptBlock {
  # Failover Clustering + File-Server + ATC prerequisites
  Install-WindowsFeature `
    Failover-Clustering, FS-FileServer, FS-BranchCache, NetworkATC, Data-Center-Bridging `
    -IncludeManagementTools  # Network ATC, DCB, clustering[43dcd9a7-70db-4a1f-b0ae-981daa162054](https://learn.microsoft.com/en-us/windows-server/networking/network-atc/network-atc?citationMarker=43dcd9a7-70db-4a1f-b0ae-981daa162054 “1”)

  # eth0 = RDMA (10 GbE)
  Set-NetAdapterAdvancedProperty -Name ‘Ethernet0’ `
    -DisplayName ‘Jumbo Packet’ -DisplayValue ‘9014 Bytes’
  Enable-NetAdapterRdma -Name ‘Ethernet0’
}

# 2) VLAN IP sub-interfaces on eth1
Foreach($node in $Nodes) {
  Invoke-Command -ComputerName $node -ScriptBlock {
    Param($cfg)
    Foreach($v in $cfg.Keys) {
      New-NetIPAddress `
        -InterfaceAlias ‘Ethernet1’ `
        -IPAddress $cfg[$v] -PrefixLength 24 `
        -AddressFamily IPv4 `
        -SkipAsSource $false `
        -PolicyStore ActiveStore
    }
  } -ArgumentList (,[ref]$vlanConfigs)
}

# 3) Create the cluster
If(-not (Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue)) {
  New-Cluster -Name $ClusterName -Node $Nodes `
    -StaticAddress $ClusterVIP -NoStorage -AdministrativeAccessPoint DNS
  Start-Sleep 10
}

# 4) Enable S2D
Enable-ClusterS2D -Cluster $ClusterName

# 5) Create tiered pool
$cache = Get-PhysicalDisk -Cluster $ClusterName |
         Where-Object BusType -Eq NVMe | Where-Object Size -Ge 3TB
$cap   = Get-PhysicalDisk -Cluster $ClusterName |
         Where-Object-Object BusType -Eq SATA| Where-Object Size -Ge 7TB

New-StoragePool -Cluster $ClusterName `
  -FriendlyName S2DPool `
  -PhysicalDisks ($cache+$cap)

# 6) Create volumes
New-Volume -Cluster $ClusterName `
  -StoragePoolFriendlyName S2DPool `
  -FriendlyName $GenFilesName `
  -FileSystem CSVFS_ReFS -Size $GenFilesSize

New-Volume -Cluster $ClusterName `
  -StoragePoolFriendlyName S2DPool `
  -FriendlyName CSVData `
  -FileSystem CSVFS_ReFS -UseMaximumSize

# 7) Add to CSV & share GenFiles
Get-ClusterAvailableDisk -Cluster $ClusterName |
  Add-ClusterDisk -Cluster $ClusterName

Invoke-Command -ComputerName $Nodes[0] -ScriptBlock {
  Param($name,$acl)
  New-SmbShare -Name $name `
    -Path “C:\ClusterStorage\$name” `
    -FolderEnumerationMode AccessBased `
    -FullAccess $acl -ChangeAccess $acl
} -ArgumentList $GenFilesName,$GenFilesACL

# 8) Configure file-share witness
Set-ClusterQuorum -Cluster $ClusterName `
  -FileShareWitness $WitnessShare -DynamicIPAddress

# 9) Promote each node to DC
Foreach($n in $Nodes) {
  Invoke-Command -ComputerName $n -ScriptBlock {
    Param($dom,[PSCredential] $cred,$dsrm)
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
    Import-Module ADDSDeployment
    Install-ADDSDomainController `
      -DomainName $dom `
      -Credential $cred `
      -InstallDns `
      -SafeModeAdministratorPassword $dsrm `
      -Force
  } -ArgumentList $Domain,$DCsCred,$DSRMpwd
}

# 10) Configure DHCP failover on cluster
Invoke-Command -ComputerName $Nodes[0] -ScriptBlock {
  Param($scope,$start,$end,$partner)
  Add-DhcpServerv4Scope -Name ‘Office’ `
    -StartRange $start -EndRange $end `
    -SubnetMask 255.255.255.0 -ScopeId $scope
  Add-DhcpServerv4Failover -Name ‘DHCP-Failover’ `
    -PartnerServer $partner `
    -ScopeId $scope -Mode LoadBalance -LoadBalancePercent 50
} -ArgumentList $DhcpScope,$DhcpStart,$DhcpEnd,$DhcpPartner

# 11) Enforce Network ATC intents (cluster RDMA + secondary storage)[43dcd9a7-70db-4a1f-b0ae-981daa162054](https://infohub.delltechnologies.com/en-us/l/windows-server-2025-deployment-and-operations-guide-with-scalable-networking/configure-network-atc/2/?citationMarker=43dcd9a7-70db-4a1f-b0ae-981daa162054 “2”)
Invoke-Command -ComputerName $Nodes -ScriptBlock {
  # RDMA intent on eth0 (VLAN 40)
  Add-NetIntent -Name ClusterRDMA `
    -AdapterName ‘Ethernet0’ -Storage -StorageVlan 40

  # Secondary storage on USB4 (tb0)
  Add-NetIntent -Name USB4Storage `
    -AdapterName ‘tb0’ -Storage
  # (Optional) verify
  Get-NetIntentStatus
}

