# nodeup.ps1
# This PowerShell script is to be run on startup of a Windows node managed via a kops InstanceGroup resource.
# There are a few pre-requisites in order for this script to work, as well as a few "best practices", all of which
# will be explained down.

# Define some of our constants.
$AWSSelfServiceUri = "169.254.169.254/latest"
$KubernetesDirectory = "c:/k"
$KopsConfigBaseRegex = "^ConfigBase: s3://(?<bucket>[^/]+)/(?<prefix>.+)$"
$RequiredWindowsUpdates = @(@{"Key"="KB4482887"; "Checksum"="826158e9ebfcabe08b425bf2cb160cd5bc1401da"})

########################################################################################################################
# Windows Update Installation
########################################################################################################################
function Is-UpdateApplied {
  param(
    [parameter(Mandatory=$true)] $UpdateId
  )

  return (((Get-Hotfix) | ? HotfixId -eq $UpdateId) -ne $null)
}

function Install-WindowsUpdates {
  param(
    [parameter(Mandatory=$true)] [Object[]] $Updates,
    [parameter(Mandatory=$false)] $ComputerInfo = (Get-ComputerInfo)
  )

  $MicrosoftUpdateInfo = @{
    "domain"="download.windowsupdate.com"
    "location"="c/msdownload/update/software/updt/2019/02"
  }

  # Generate our download directory.
  $DownloadDirectory = (Join-Path -Path (Get-Item Env:TEMP).Value -ChildPath "windows")
  New-Item -ItemType "directory" -Path "$DownloadDirectory" -ErrorAction Ignore

  # Get our OS version.
  $OsVersionRegex = "^(?<version>\d+\.\d+)\.\d+$"
  $m = ($ComputerInfo.OsVersion | Select-String -Pattern $OsVersionRegex -AllMatches).Matches.Groups
  $OsVersion = ($m | ? Name -eq "version").Value

  # Get a list of applied updates.
  $AppliedUpdates = (Get-Hotfix)

  foreach($u in $Updates) {
    $key = $u.Key
    # Check to see if the update is already applied, if it exists, skip it.
    if(Is-UpdateApplied -UpdateId $u.Key) { continue }

    # Generate the URI to download the update from Microsoft.
    $update = "http://{0}/{1}/windows{2}-{3}-x64_{4}.msu" -f `
      $MicrosoftUpdateInfo.domain, `
      $MicrosoftUpdateInfo.location, `
      $OsVersion, `
      $u.Key.toLower(), `
      $u.Checksum
    
    $LocalFile = (Join-Path -Path $DownloadDirectory -ChildPath $u.Key)

    Start-Job -Name $u.Key.toLower() -ScriptBlock {
      $remote = $args[0]
      $local = $args[1]

      # Download the update file.
      Write-Host "pulling $remote => $local.msu"
      wget "$remote" -OutFile "$local.msu"

      # Install the update quietly and don't restart.
      Write-Host "applying update $remote @ $local.msu"
      c:/windows/system32/wusa.exe "$local.msu" /quiet /norestart
    } -ArgumentList $update,(Join-Path -Path $DownloadDirectory -ChildPath $u.Key)
  }
}

########################################################################################################################
# Conveinence Functions
########################################################################################################################
function Get-AwsTag($TagName) { return ($script:Ec2Tags | Where-Object {$_.Key -eq "$TagName"}) }

########################################################################################################################
# Installation Functions
########################################################################################################################
function Install-DockerImages {
  param (
    [parameter(Mandatory=$false)] $WindowsVersion = $script:ComputerInfo.WindowsVersion,
    [parameter(Mandatory=$false)] $WithServerCore = $false
  )

  Start-Job -Name install-docker -ScriptBlock {
    $WindowsVersion = $args[0]
    $WithServerCore = $args[1]

    # Pull ready-made Windows containers of the given Windows version.
    docker pull "mcr.microsoft.com/windows/nanoserver:$WindowsVersion"

    # Tag the docker images.
    docker tag "mcr.microsoft.com/windows/nanoserver:$WindowsVersion" windows/nanoserver:latest
    docker tag "mcr.microsoft.com/windows/nanoserver:$WindowsVersion" microsoft/nanoserver:latest

    # Build our infrastructure image.
    $BuildDir = Join-Path -Path (Get-Item Env:TEMP).Value -ChildPath "docker"
    New-Item -Path $BuildDir -ItemType directory
    $DockerfileContents = "FROM mcr.microsoft.com/windows/nanoserver:$WindowsVersion`nCMD cmd /c ping -t localhost"
    
    Set-Content -Path $BuildDir/Dockerfile -Value $DockerfileContents
    docker build -t kubeletwin/pause -f $BuildDir/Dockerfile $BuildDir

    # Pull the servercore image if we're instructed to.
    if($WithServerCore) {
      docker pull "mcr.microsoft.com/windows/servercore:$WindowsVersion"
      docker tag "mcr.microsoft.com/windows/servercore:$WindowsVersion" windows/servercore:latest
      docker tag "mcr.microsoft.com/windows/servercore:$WindowsVersion" microsoft/servercore:latest
    }

    Remove-Item -Path $BuildDir -Recurse
  } -ArgumentList $WindowsVersion,$WithServerCore
}

function Install-AwsKubernetesNode {
  param (
    [parameter(Mandatory=$true)] $KubernetesVersion,
    [parameter(Mandatory=$true)] $InstallationDirectory,
    [parameter(Mandatory=$false)] $DownloadDirectory = (Join-Path -Path (Get-Item Env:TEMP).Value -ChildPath "knode")
  )

  Start-Job -Name install-knode {
    $KubernetesVersion = $args[0]
    $InstallationDirectory = $args[1]
    $DownloadDirectory = $args[2]

    New-Item -ItemType directory -Path $DownloadDirectory

    # Download Kubernetes Node Services
    wget "https://dl.k8s.io/v$KubernetesVersion/kubernetes-node-windows-amd64.tar.gz" `
      -OutFile "$DownloadDirectory/knode.tar.gz"
    tar -xzvf "$DownloadDirectory/knode.tar.gz" -C $DownloadDirectory

    # Install Kubernetes Binaries
    Move-Item -Path "$DownloadDirectory/kubernetes/node/bin/*.exe" -Destination "$InstallationDirectory/bin/"

    Remove-Item -Path $DownloadDirectory -Recurse
  } -ArgumentList $KubernetesVersion,$InstallationDirectory,$DownloadDirectory
}

function Install-AwsKubernetesFlannel {
  param (
    [parameter(Mandatory=$true)] $InstallationDirectory,
    [parameter(Mandatory=$false)] $FlanneldVersion = "0.11.0",
    [parameter(Mandatory=$false)] $DownloadBranch = "master",
    [parameter(Mandatory=$false)] $DownloadDirectory = (Join-Path -Path (Get-Item Env:TEMP).Value -ChildPath "flannel")
  )

  Start-Job -Name install-flannel -ScriptBlock {
    $DownloadDirectory = $args[0]
    $InstallationDirectory = $args[1]
    $DownloadBranch = $args[2]
    $FlanneldVersion = $args[3]
    $KubeClusterCidr = $args[4]

    New-Item -Path $DownloadDirectory -ItemType "directory"

    $GitHubMicrosoftSDNRepo = "github.com/Microsoft/SDN"
    $GitHubFlannelRepo = "github.com/coreos/flannel"

    # Download HNS Powershell module.
    wget "https://$GitHubMicrosoftSDNRepo/raw/$DownloadBranch/Kubernetes/windows/hns.psm1" `
      -OutFile "$InstallationDirectory/hns.psm1"

    # Install flanneld executable.
    wget "https://$GitHubFlannelRepo/releases/download/v$FlanneldVersion/flanneld.exe" `
      -OutFile "$InstallationDirectory/bin/flanneld.exe"

    # Install CNI executables.
    New-Item -Path "$InstallationDirectory/cni" -ItemType "directory"
    wget "https://$GitHubMicrosoftSDNRepo/raw/$DownloadBranch/Kubernetes/flannel/l2bridge/cni/host-local.exe" `
      -OutFile "$InstallationDirectory/cni/host-local.exe"
    wget "https://$GitHubMicrosoftSDNRepo/raw/$DownloadBranch/Kubernetes/flannel/l2bridge/cni/flannel.exe" `
      -OutFile "$InstallationDirectory/cni/flannel.exe"
    wget "https://$GitHubMicrosoftSDNRepo/raw/$DownloadBranch/Kubernetes/flannel/overlay/cni/win-overlay.exe" `
      -OutFile "$InstallationDirectory/cni/win-overlay.exe"

    # Create directories needed for runtime.
    New-Item -Path "c:/etc/kube-flannel" -ItemType directory -ErrorAction Ignore
    New-Item -Path "c:/run/flannel" -ItemType directory -ErrorAction Ignore
    Remove-Item -Path $DownloadDirectory -Recurse
  } -ArgumentList $DownloadDirectory,$InstallationDirectory,$DownloadBranch,$FlanneldVersion
}

function Install-NSSM {
  param (
    [parameter(Mandatory=$true)] $InstallationDirectory,
    [parameter(Mandatory=$false)] $NssmVersion = "2.23",
    [parameter(Mandatory=$false)] $DownloadDirectory = (Join-Path -Path (Get-Item Env:TEMP).Value -ChildPath "nssm")
  )

  Start-Job -Name install-nssm -ScriptBlock {
    $DownloadDirectory = $args[0]
    $InstallationDirectory = $args[1]
    $NssmVersion = $args[2]

    New-Item -ItemType directory -Path $DownloadDirectory

    wget "https://nssm.cc/release/nssm-$NssmVersion.zip" -OutFile "$DownloadDirectory/nssm.zip"
    Expand-Archive "$DownloadDirectory/nssm.zip" -DestinationPath "$DownloadDirectory/"

    Move-Item -Path "$DownloadDirectory/nssm-$NssmVersion/win64/nssm.exe" -Destination "$InstallationDirectory/bin/nssm.exe" -Force

    Remove-Item -Path $DownloadDirectory -Recurse
  } -ArgumentList $DownloadDirectory,$InstallationDirectory,$NssmVersion
}

function New-KubernetesConfigurations {
  param (
    [parameter(Mandatory=$true)] $DestinationBaseDir,
    [parameter(Mandatory=$true)] $KopsStateStoreBucket,
    [parameter(Mandatory=$true)] $KopsStateStorePrefix,
    [parameter(Mandatory=$true)] $KubernetesMasterInternalName,
    [parameter(Mandatory=$false)] [string[]] $KubernetesUsers
  )

  # Download the issued certificate authority keyset.
  New-Item $DestinationBaseDir/issued/ca -ItemType Directory -ErrorAction SilentlyContinue
  $S3ObjectKey = "$KopsStateStorePrefix/pki/issued/ca/keyset.yaml"
  $LocalCertificateAuthorityFile = "$DestinationBaseDir/ca-keyset.yaml"
  Read-S3Object -BucketName $KopsStateStoreBucket -Key $S3ObjectKey -File $LocalCertificateAuthorityFile

  # Load the certificate authority data.
  $CertificateAuthorityData = ((Get-Content $LocalCertificateAuthorityFile) | ConvertFrom-Yaml)
  $CertificateAuthorityCertificate = [System.Convert]::FromBase64String($CertificateAuthorityData.publicMaterial)
  Set-Content -Path $DestinationBaseDir/issued/ca.crt -Value $CertificateAuthorityCertificate -Encoding Byte
  foreach($KubernetesUser in $KubernetesUsers) {
    Write-Host "generating kubeconfig for $KubernetesUser"

    # Download each user's secrets.
    New-Item $DestinationBaseDir/private/$KubernetesUser -ItemType Directory -ErrorAction SilentlyContinue
    $S3ObjectKey = "$KopsStateStorePrefix/pki/private/$KubernetesUser/keyset.yaml"
    $LocalUserFile = "$DestinationBaseDir/$KubernetesUser-keyset.yaml"
    Read-S3Object -BucketName $KopsStateStoreBucket -Key $S3ObjectKey -File $LocalUserFile

    # Load the user's secrets.
    $KuberenetesUserData = ((Get-Content $LocalUserFile) | ConvertFrom-Yaml)

    # Generate the Kubernetes configuration file for each user.
    $KubernetesConfigData = @{
      "apiVersion"="v1";
      "clusters"=@(
          @{
              "cluster"=@{
                  "certificate-authority-data"=$CertificateAuthorityData.publicMaterial;
                  "server"="https://$KubernetesMasterInternalName";
              };
              "name"="local";
          }
      );
      "contexts"=@(
          @{
              "context"=@{
                  "cluster"="local";
                  "user"="$KubernetesUser";
              };
              "name"="service-account-context";
          }
      )
      "current-context"="service-account-context";
      "kind"="Config";
      "users"=@(
          @{
              "name"="$KubernetesUser";
              "user"=@{
                  "client-certificate-data"=$KuberenetesUserData.publicMaterial;
                  "client-key-data"=$KuberenetesUserData.privateMaterial;
              };
          }
      );
    }
    
    ConvertTo-Yaml $KubernetesConfigData | Set-Content -Path "$DestinationBaseDir/$KubernetesUser.kcfg"
    Remove-Item -Path $LocalUserFile -Force
  }
  Remove-Item -Path $LocalCertificateAuthorityFile -Force
}

########################################################################################################################
# Helper Functions
########################################################################################################################
function Get-NodeKeysetFromTags {
  param(
    [parameter(Mandatory=$true)] $Prefix,
    [parameter(Mandatory=$false)] $Tags = $script:Ec2Tags
  )

  $tags = $script:Ec2Tags
  $tags = $Tags | Where-Object { $_.Key -like "$Prefix/*" } | ForEach-Object {
    return $_.Key.replace("$Prefix/", "") + "=" + $_.Value
  }
  return $tags
}

function Get-NodeLabelsFromTags {
  param(
    [parameter(Mandatory=$false)] $Prefix = "k8s.io/cluster-autoscaler/node-template/label",
    [parameter(Mandatory=$false)] $Tags = $script:Ec2Tags
  )
  return (Get-NodeKeysetFromTags -Prefix $Prefix -Tags $Tags)
}

function Get-NodeTaintsFromTags {
  param(
    [parameter(Mandatory=$false)] $Prefix = "k8s.io/cluster-autoscaler/node-template/taint",
    [parameter(Mandatory=$false)] $Tags = $script:Ec2Tags
  )
  return (Get-NodeKeysetFromTags -Prefix $Prefix -Tags $Tags)
}

function Update-NetConfigurationFile {
  param(
    [parameter(Mandatory=$false)] $NetworkName = "vxlan0",
    [parameter(Mandatory=$false)] $NetworkMode = "vxlan",
    [parameter(Mandatory=$false)] $KubeClusterCidr = $env:KubeClusterCidr
  )

  $NetConfigurationFile = "c:/etc/kube-flannel/net-conf.json"

  $Configuration = @{
    "Network"="$KubeClusterCidr"
    "Backend"=@{
      "name"="$NetworkName"
      "type"="$NetworkMode"
    }
  }

  if(Test-Path $NetConfigurationFile) {
    Clear-Content -Path $NetConfigurationFile
  }

  Write-Host "Generated net-conf.json Config [$Configuration]"
  Add-Content -Path $NetConfigurationFile -Value (ConvertTo-Json $Configuration)
}

function Update-CniConfigurationFile {
  param(
    [parameter(Mandatory=$false)] $KubernetesDirectory = $script:KubernetesDirectory,
    [parameter(Mandatory=$false)] $NetworkName = "vxlan0",
    [parameter(Mandatory=$false)] $KubeDnsSuffix = "svc.cluster.local",
    [parameter(Mandatory=$false)] $KubeClusterCidr = $env:KubeClusterCidr,
    [parameter(Mandatory=$false)] $KubeServiceCidr = $env:KubeServiceCidr,
    [parameter(Mandatory=$false)] $KubeClusterDns = $env:KubeClusterDns
  )

  New-Item -Path "$KubernetesDirectory/cni/config" -ItemType directory
  $CniConfigurationFile = "$KubernetesDirectory/cni/config/cni.conf"

  $Configuration = @{
    "cniVersion"="0.2.0"
    "name"="$NetworkName"
    "type"="flannel"
    "delegate"=@{
      "type"="win-overlay"
      "dns"=@{
        "Nameservers"=@(
          "$KubeClusterDns"
        )
        "Search"=@(
          "$KubeDnsSuffix"
        )
      }
      "policies"=@(
        @{
          "Name"="EndpointPolicy"
          "Value"=@{
            "Type"="OutBoundNAT"
            "ExceptionList"=@(
              $KubeClusterCidr,
              $KubeServiceCidr
            )
          }
        },
        @{
          "Name"="EndpointPolicy"
          "Value"=@{
            "Type"="ROUTE"
            "DestinationPrefix"=$KubeServiceCidr
            "NeedEncap"=$true
          }
        }
      )
    }
  }

  if(Test-Path $CniConfigurationFile) {
    Clear-Content -Path $CniConfigurationFile
  }

  Write-Host "Generated CNI Config [$Configuration]"
  Add-Content -Path $CniConfigurationFile -Value (ConvertTo-Json $Configuration -Depth 20)
}

function Get-SourceVip {
  param(
    [parameter(Mandatory=$true)] $IpAddress,
    [parameter(Mandatory=$false)] $NetworkName = "vxlan0",
    [parameter(Mandatory=$false)] $KubernetesDirectory = $script:KubernetesDirectory
  )

  $hnsNetwork = Get-HnsNetwork | ? Name -eq $NetworkName.ToLower()
  $subnet = $hnsNetwork.Subnets[0].AddressPrefix

  $IpamConfig = @{
    "cniVersion"="0.2.0"
    "name"="$NetworkName"
    "ipam"=@{
      "type"="host-local"
      "ranges"=@(,
        @(,
          @{"subnet"="$subnet"}
        )
      )
    }
  }

  $env:CNI_COMMAND="ADD"
  $env:CNI_CONTAINERID="dummy"
  $env:CNI_NETNS="dummy"
  $env:CNI_IFNAME="dummy"
  $env:CNI_PATH="$KubernetesDirectory/cni" #path to host-local.exe

  $SourceVip = ($IpamConfig | ConvertTo-Json -Depth 20 | host-local.exe | ConvertFrom-Json).ip4.ip.Split("/")[0]

  Remove-Item env:CNI_COMMAND
  Remove-Item env:CNI_CONTAINERID
  Remove-Item env:CNI_NETNS
  Remove-Item env:CNI_IFNAME
  Remove-Item env:CNI_PATH

  return $SourceVip
}

function ConvertTo-AppParameters {
  param(
    [parameter(Mandatory=$true)] $AppParameters
  )

  $parameters = @()
  foreach($v in $AppParameters.GetEnumerator()) {
    $parameters += "--$($v.Name)=$($v.Value)"
  }

  return ($parameters -Join " ")
}

########################################################################################################################
# (1) Kops Cluster Configuration Extraction
# Prerequisites
#   (1) The kops-managed InstanceGroup resource will need to have two entries in `cloudLabels`:
#       - ccpgames.com/kops/state-store-bucket, set to the name of the S3 bucket containing the kops state store
#       - ccpgames.com/kops/state-store-prefix, set to the S3 prefix containing the kops state store
#       The script will use this information to pull the cluster configuration and extract the necessary information.
#   (2) A premade flannel serviceaccount Kubernetes configuration file must exist in S3 and be readable from a node.
########################################################################################################################
# Pull down our instance's tags.
$InstanceId = (wget "http://$script:AWSSelfServiceUri/meta-data/instance-id" -UseBasicParsing).Content
$Ec2Tags = (Get-EC2Tag -Filter @{ Name="resource-id"; Values="$InstanceId" })

# If we're instructed to prepare the node, then gather up all the necessary information and install components.
if($env:KOPS_NODE_STATE -eq $null) {
  # Start by obtaining information about our machine.
  $ComputerInfo = (Get-ComputerInfo)

  # Start the installation of our required Windows updates.
  Install-WindowsUpdates `
    -Updates $RequiredWindowsUpdates `
    -ComputerInfo $ComputerInfo
  
  # Install a Powershell YAML module.
  Start-Job -Name "yaml-install" -ScriptBlock { Install-Module powershell-yaml -Force }

  # Pull a few variables from AWS' self-service URI.
  $AwsRegion = ((wget "http://$script:AWSSelfServiceUri/dynamic/instance-identity/document" -UseBasicParsing).Content | ConvertFrom-Json).region
  $env:NODE_NAME = (wget "http://$script:AWSSelfServiceUri/meta-data/local-hostname" -UseBasicParsing).Content

  # Extract our kops configuration base from the user-data.
  $KopsUserDataFile = "c:/userdata.txt"
  $KopsUserData = (wget "http://$script:AWSSelfServiceUri/user-data" -UseBasicParsing).Content
  $KopsUserData = [System.Text.Encoding]::ASCII.GetString($KopsUserData)
  Set-Content -Path $KopsUserDataFile -Value $KopsUserData
  $KopsConfigBase = (Get-Content $KopsUserDataFile | Select-String -Pattern $KopsConfigBaseRegex -AllMatches).Matches.Groups
  Remove-Item -Path $KopsUserDataFile

  # Store kops S3 backend config information from the userdata.
  $KopsStateStoreBucket = ($KopsConfigBase | ? Name -eq "bucket").Value
  $KopsStateStorePrefix = ($KopsConfigBase | ? Name -eq "prefix").Value

  # Prepare our filesystem.
  New-Item -ItemType directory -Path "$KubernetesDirectory/bin"

  # Prepare our environment path.
  $env:PATH += ";$KubernetesDirectory/bin"
  $env:PATH += ";$KubernetesDirectory/cni"

  $KopsClusterSpecificationFile = "$KubernetesDirectory/cluster.spec"

  # Download the cluster specification from the kops S3 backend.
  Read-S3Object `
    -BucketName "$KopsStateStoreBucket" `
    -Key "$KopsStateStorePrefix/cluster.spec" `
    -File $KopsClusterSpecificationFile

  Get-Job -Name "yaml-install" | Wait-Job
  Import-Module powershell-yaml

  # Parse the YAML cluster specification file into a PowerShell object and remove the file.
  $KopsClusterSpecification = (Get-Content $KopsClusterSpecificationFile | ConvertFrom-Yaml 2>&1)
  Remove-Item -Path $KopsClusterSpecificationFile -Force

  # Extract all necessary configuration items regarding the cluster.
  $KubeClusterCidr = ($KopsClusterSpecification.clusterCidr | Sort-Object -Unique)
  $KubeClusterDns = ($KopsClusterSpecification.clusterDNS | Sort-Object -Unique)
  $KubeClusterInternalApi = ($KopsClusterSpecification.masterInternalName | Sort-Object -Unique)
  $KubeDnsDomain = ($KopsClusterSpecification.clusterDnsDomain | Sort-Object -Unique)
  $KubeNonMasqueradeCidr = ($KopsClusterSpecification.nonMasqueradeCIDR | Sort-Object -Unique)
  $KubeServiceCidr = ($KopsClusterSpecification.serviceClusterIPRange | Sort-Object -Unique)
  $KubernetesVersion = ($KopsClusterSpecification.kubernetesVersion | Sort-Object -Unique)

  # Download Kubernetes configuration files for both the kubelet and kube-proxy users.
  New-KubernetesConfigurations `
    -DestinationBaseDir "$KubernetesDirectory/kconfigs" `
    -KopsStateStoreBucket $KopsStateStoreBucket `
    -KopsStateStorePrefix $KopsStateStorePrefix `
    -KubernetesMasterInternalName $KubeClusterInternalApi `
    -KubernetesUsers kubelet,kube-proxy

  # Download the pre-made flannel ServiceAccount Kubernetes configuaration file.
  Read-S3Object `
    -BucketName "$KopsStateStoreBucket" `
    -Key "$KopsStateStorePrefix/serviceaccount/flannel.kcfg" `
    -File "$KubernetesDirectory/kconfigs/flannel.kcfg"

  Install-AwsKubernetesFlannel -InstallationDirectory $KubernetesDirectory
  Install-AwsKubernetesNode -KubernetesVersion $KubernetesVersion -InstallationDirectory $KubernetesDirectory
  Install-DockerImages
  Install-NSSM -InstallationDirectory $KubernetesDirectory

  # Wait for all installation jobs to finish.
  Get-Job | Wait-Job

  # Wait for all Windows updates to finish, don't know why the job exits early.
  Get-Process | ? Name -eq "wusa" | Wait-Process

  # Save all important pieces of information to the environment.
  $env:AwsRegion = $AwsRegion
  $env:KubeClusterCidr = $KubeClusterCidr
  $env:KubeClusterDns = $KubeClusterDns
  $env:KubeClusterInternalApi = $KubeClusterInternalApi
  $env:KubeDnsDomain = $KubeDnsDomain
  $env:KubeNonMasqueradeCidr = $KubeNonMasqueradeCidr
  $env:KubeServiceCidr = $KubeServiceCidr
  $env:KubeNonMasqueradeCidr = $KubeNonMasqueradeCidr
  
  $Target = [System.EnvironmentVariableTarget]::Machine
  [System.Environment]::SetEnvironmentVariable('AwsRegion', $env:AwsRegion, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterCidr', $env:KubeClusterCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterDns', $env:KubeClusterDns, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterInternalApi', $env:KubeClusterInternalApi, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeDnsDomain', $env:KubeDnsDomain, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeNonMasqueradeCidr', $env:KubeNonMasqueradeCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeServiceCidr', $env:KubeServiceCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeNonMasqueradeCidr', $env:KubeNonMasqueradeCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('NODE_NAME', $env:NODE_NAME, $Target)
  [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, $Target)
  [System.Environment]::SetEnvironmentVariable('KOPS_NODE_STATE', "prepared", $Target)

  $Target = [System.EnvironmentVariableTarget]::User
  [System.Environment]::SetEnvironmentVariable('AwsRegion', $env:AwsRegion, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterCidr', $env:KubeClusterCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterDns', $env:KubeClusterDns, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeClusterInternalApi', $env:KubeClusterInternalApi, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeDnsDomain', $env:KubeDnsDomain, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeNonMasqueradeCidr', $env:KubeNonMasqueradeCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeServiceCidr', $env:KubeServiceCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('KubeNonMasqueradeCidr', $env:KubeNonMasqueradeCidr, $Target)
  [System.Environment]::SetEnvironmentVariable('NODE_NAME', $env:NODE_NAME, $Target)
  [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, $Target)
  [System.Environment]::SetEnvironmentVariable('KOPS_NODE_STATE', "prepared", $Target)

  # Once everything has finished, restart the machine.
  Restart-Computer -Force
  exit
}

# If the node is already ready, just exit, we don't need to do anything.
if($env:KOPS_NODE_STATE -eq "ready") { exit }

# Acquire additional network information for a later stage.
$NetworkDefaultInterface = (
  Get-NetIPConfiguration | 
  Where-Object {
    $_.IPv4DefaultGateway -ne $null -and
    $_.NetAdapter.Status -ne "Disconnected"
  }
)
$NetworkDefaultGateway = $NetworkDefaultInterface.IPv4DefaultGateway.NextHop
$NetworkHostIpAddress = $NetworkDefaultInterface.IPv4Address.IPAddress

# Get taints and role from the cluster specification
$NodeTaints = (Get-NodeTaintsFromTags) -Join ""","""
$NodeLabels = (Get-NodeLabelsFromTags) -Join ""","""
$NodeTaints = """$NodeTaints"""
$NodeLabels = """$NodeLabels"""

# Go ahead install Docker credentials for AWS.
$env:DOCKER_CONFIG = "c:/.docker"
New-Item -Path $env:DOCKER_CONFIG -ItemType directory
Invoke-Expression -Command (Get-ECRLoginCommand -Region $env:AwsRegion).Command

# Run install docker again, this time with servercore
Install-DockerImages -WithServerCore $true

########################################################################################################################
# (3) Careful Execution of Kubernetes Executables and Networking
########################################################################################################################
Import-Module "$KubernetesDirectory/hns.psm1"

# Get the name of the flannel overlap network.
$FlannelConfigMap = (kubectl --kubeconfig="$KubernetesDirectory/kconfigs/flannel.kcfg" get configmaps -n kube-system kube-flannel-cfg -ojson | ConvertFrom-Json)
$FlannelCniConfiguration = ($FlannelConfigMap.data.'cni-conf.json' | ConvertFrom-Json)
$env:KUBE_NETWORK = $FlannelCniConfiguration.name

# Create an overlay network to trigger a vSwitch creation.
# Do this only once as it causes network blip.
New-NetFirewallRule `
  -Name OverlayTraffic4789UDP `
  -Description "Overlay network traffic UDP" `
  -Action Allow `
  -LocalPort 4789 `
  -Enabled True `
  -DisplayName "Overlay Traffic 4789 UDP" `
  -Protocol UDP `
  -ErrorAction SilentlyContinue
if(!(Get-HnsNetwork | ? Name -eq "External")) {
  New-HNSNetwork `
    -Name "External" `
    -Type "overlay" `
    -AddressPrefix "192.168.255.0/30" `
    -Gateway "192.168.255.1" `
    -SubnetPolicies @(@{ Type = "VSID"; VSID = 9999; }) `
    -Verbose
}

# Open up the port for shell and logs.
New-NetFirewallRule `
  -Name OverlayTraffic10250UDP `
  -Description "Overlay network traffic TCP" `
  -Action Allow `
  -LocalPort 10250 `
  -Enabled True `
  -DisplayName "Overlay Traffic 10250 TCP" `
  -Protocol TCP `
  -ErrorAction SilentlyContinue

# Readd the static route to the metadata service.
route ADD 169.254.169.254 MASK 255.255.255.255 $NetworkDefaultGateway /p

# Wait for the network to stabilize, usually takes about five to ten seconds.
kubectl get nodes --kubeconfig="$KubernetesDirectory/kconfigs/kubelet.kcfg" 2>&1 | Out-Null
while($? -eq $false) {
  Start-Sleep 1
  # Use `kubectl get nodes` to just test the connectivity to the cluster.
  kubectl get nodes --kubeconfig="$KubernetesDirectory/kconfigs/kubelet.kcfg" 2>&1 | Out-Null
}

########################################################################################################################

Update-NetConfigurationFile
Update-CniConfigurationFile

$Services = @("flanneld", "kubelet", "kube-proxy")
foreach($Service in $Services) {
# Install our base services.
  nssm install $Service "$KubernetesDirectory/bin/$Service"

  # Setup logging for each service.
  New-Item -ItemType "directory" -Path "c:/var/log/services/$Service"
  nssm set $Service AppStderr (Join-Path -Path "c:/var/log" -ChildPath "$Service/$Service.log")
}

# Set service dependencies.
nssm set kube-proxy DependOnService kubelet flanneld

# Determine environment for the services.
nssm set flanneld AppEnvironmentExtra NODE_NAME=$env:NODE_NAME
nssm set kube-proxy AppEnvironmentExtra KUBE_NETWORK=$env:KUBE_NETWORK

# Determine our base arguments for the services.
$KubeletArguments = @{
  "allow-privileged"="true";
  "anonymous-auth"="false";
  "authorization-mode"="Webhook";
  "cgroups-per-qos"="false";
  "client-ca-file"="$KubernetesDirectory/kconfigs/issued/ca.crt";
  "cloud-provider"="aws";
  "cluster-dns"="$env:KubeClusterDns";
  "cluster-domain"="$env:KubeDnsDomain";
  "cni-bin-dir"="$KubernetesDirectory/cni";
  "cni-conf-dir"="$KubernetesDirectory/cni/config";
  "enable-debugging-handlers"="true";
  "enforce-node-allocatable"="";
  "feature-gates"="""WinOverlay=true"""; # TODO: get this from cluster spec
  "hairpin-mode"="promiscuous-bridge";
  "hostname-override"="$env:NODE_NAME";
  "image-pull-progress-deadline"="20m";
  "kubeconfig"="$KubernetesDirectory/kconfigs/kubelet.kcfg";
  "network-plugin"="cni";
  "node-ip"="$NetworkHostIpAddress";
  "node-labels"="$NodeLabels";
  "non-masquerade-cidr"="$env:KubeNonMasqueradeCidr";
  "pod-infra-container-image"="kubeletwin/pause";
  "register-schedulable"="false";
  "register-with-taints"="$NodeTaints";
  "resolv-conf"="";
  "v"="6"
}

$FlannelArguments = @{
  "iface"="$NetworkHostIpAddress";
  "ip-masq"="1";
  "kubeconfig-file"="$KubernetesDirectory/kconfigs/flannel.kcfg";
  "kube-subnet-mgr"="1"
}

$KubeProxyArguments = @{
  "v"="4";
  "cluster-cidr"="$env:KubeClusterCidr";
  "enable-dsr"="false";
  "feature-gates"="""WinOverlay=true""";
  "hostname-override"="$env:NODE_NAME";
  "kubeconfig"="$KubernetesDirectory/kconfigs/kube-proxy.kcfg";
  "network-name"="$env:KUBE_NETWORK";
  "proxy-mode"="kernelspace";
  "source-vip"="$null"
}
nssm set kubelet AppParameters (ConvertTo-AppParameters -AppParameters $KubeletArguments)
nssm set flanneld AppParameters (ConvertTo-AppParameters -AppParameters $FlannelArguments)
nssm set kube-proxy AppParameters (ConvertTo-AppParameters -AppParameters $KubeProxyArguments)

# Start kubelet so that we register the node, but it won't be schedulable yet.
nssm start kubelet

# Start flannel so we can get the source VIP needed for kube-proxy.
nssm start flanneld

# We need to wait for a few seconds for flannel to start before we can get our source VIP.
# Ideally we'd have a way to check without having to poll, but as far as I can tell there's no way to tell if flannel
# is ready, aside from maybe parsing logs so this'll have to do.
Start-Sleep 5
while($SourceVip -eq $null) {
  Write-Host "attempting to get source-VIP"
  $SourceVip = Get-SourceVip -IpAddress $NetworkHostIpAddress -KubernetesDirectory $KubernetesDirectory
  Start-Sleep 1
}
Write-Host "obtained source-VIP"

$KubeProxyArguments.'source-vip' = "$SourceVip"
nssm set kube-proxy AppParameters (ConvertTo-AppParameters -AppParameters $KubeProxyArguments)

# Clear the HNS policy list before starting kube-proxy.
Get-HnsPolicyList | Remove-HnsPolicyList
nssm start kube-proxy

# Uncordon the node.
kubectl --kubeconfig="$KubernetesDirectory/kconfigs/kubelet.kcfg" uncordon $env:NODE_NAME

# Mark our machine as being fully ready.
[System.Environment]::SetEnvironmentVariable('KOPS_NODE_STATE', "ready", [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('KOPS_NODE_STATE', "ready", [System.EnvironmentVariableTarget]::User)