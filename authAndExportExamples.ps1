# Authentication for M365 DSC
# Using an App SP and Cert Thumbprint
# 12/22/2024

# App Information
$AppId = '8dc055d2-fe88-4237-80ed-08abf488511e' 
$TenantId = 'brandonscarberrycom.onmicrosoft.com'

# Get the local certificate thumbrpint
$CertThumbprint = (Get-ChildItem -Path 'Cert:\CurrentUser\My' -DnsName 'M365DSCCert').Thumbprint


#Export the config
#Export-M365DSCConfiguration -ApplicationId $AppId -TenantId $TenantId -CertificateThumbprint $CertThumbprint -FileName 'M365DSConfig_Gold.ps1' -Path 'C:\Temp\M365DSC\'-Components @('AADConditionalAccessPolicy')
Export-M365DSCConfiguration -ApplicationId $AppId -TenantId $TenantId -CertificateThumbprint $CertThumbprint -FileName 'M365DSConfig_Gold.ps1' -Path 'C:\Temp\M365DSC\'-Components @('AADConditionalAccessPolicy','AADNamedLocationPolicy')

#Deploy Configuration
#This uses the authentication used for the export in the created ConfigurationData.psd1 file
#First compile the exported configuration .ps1 file by running it: .\M365DSCongif_Gold.ps1
#This will create the complied configuration for deployment
Start-DscConfiguration -Path 'C:\Temp\M365DSC\M365DSConfig_Gold' -Wait -Verbose -Force
