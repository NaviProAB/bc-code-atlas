// bc-code-atlas for Navipro: one Linux VM that runs the five atlas servers, the
// sign-in gateway and Caddy (HTTPS), plus a Key Vault that holds the service keys.
//
//   az group create -n rg-bc-atlas -l swedencentral
//   az deployment group create -g rg-bc-atlas -f main.bicep -p sshPublicKey="$(cat key.pub)" keyVaultAdminObjectId=<your object id>
//
// Only 80 (certificate issuance and redirect) and 443 are open. There is no SSH
// from the internet: manage the VM with `az vm run-command` or the serial console.

@description('Azure region.')
param location string = resourceGroup().location

@description('DNS label; the server answers on <label>.<region>.cloudapp.azure.com.')
param dnsLabel string = 'navipro-bc-atlas'

@description('VM size. Indexing wants cores; serving two or three corpora wants memory. Resize down after the first index if it is idle.')
param vmSize string = 'Standard_D8s_v5'

@description('OS disk size in GB. One built (country, version) is about 3 GB; the source mirror and Python environments need about 20 GB.')
param diskSizeGb int = 128

@description('Admin user on the VM (key only, no password).')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user. Required by Azure even though port 22 is closed.')
param sshPublicKey string

@description('Repository and branch the VM clones.')
param repoUrl string = 'https://github.com/NaviProAB/bc-code-atlas.git'
param repoBranch string = 'navipro'

@description('GitHub organizations whose members may use the server, comma separated.')
param githubOrgs string = 'NaviProAB'

@description('Object id of the person or group that manages the service keys in Key Vault.')
param keyVaultAdminObjectId string

param tags object = {
  application: 'bc-code-atlas'
  source: 'https://github.com/NaviProAB/bc-code-atlas'
}

var hostname = '${dnsLabel}.${location}.cloudapp.azure.com'
var cloudInit = replace(replace(replace(replace(loadTextContent('cloud-init.sh'), '__REPO_URL__', repoUrl), '__REPO_BRANCH__', repoBranch), '__HOSTNAME__', hostname), '__GITHUB_ORGS__', githubOrgs)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-bcatlas'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-https'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '443' }
      }
      {
        name: 'allow-http-for-certificates'
        properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '80' }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-bcatlas'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.61.0.0/24'] }
    subnets: [
      { name: 'default', properties: { addressPrefix: '10.61.0.0/27', networkSecurityGroup: { id: nsg.id } } }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-bcatlas'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: dnsLabel }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-bcatlas'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-bcatlas'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { name: 'osdisk-bcatlas', createOption: 'FromImage', diskSizeGB: diskSizeGb, managedDisk: { storageAccountType: 'Premium_LRS' } }
    }
    osProfile: {
      computerName: 'bcatlas'
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
        patchSettings: { patchMode: 'AutomaticByPlatform', assessmentMode: 'AutomaticByPlatform' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
  }
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-bcatlas-${take(uniqueString(resourceGroup().id), 10)}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 30
  }
}

// Key Vault Secrets Officer: read and write the service keys.
resource kvAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, keyVaultAdminObjectId, 'secrets-officer')
  scope: kv
  properties: {
    principalId: keyVaultAdminObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  }
}

output hostname string = hostname
output mcpUrl string = 'https://${hostname}/mcp'
output keyVaultName string = kv.name
output vmName string = vm.name
