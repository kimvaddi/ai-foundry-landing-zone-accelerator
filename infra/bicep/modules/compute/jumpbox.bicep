// =============================================================================
// jumpbox.bicep — Windows Server 2022 jump VM (no public IP, accessed via Bastion)
//
// Sized for ops/admin use (default B2s). Boots SystemAssigned MI so the VM can
// pull from Azure resources (KV, Storage) without local creds. NIC attaches to
// JumpboxSubnet from spoke-vnet.bicep.
// =============================================================================

@description('VM name (and computerName). Max 15 chars for Windows.')
@maxLength(15)
param name string

@description('Region.')
param location string

@description('Resource ID of JumpboxSubnet.')
param subnetResourceId string

@description('VM size.')
param vmSize string = 'Standard_B2s'

@description('Admin username.')
param adminUsername string = 'klzadmin'

@description('Admin password (provide via Key Vault reference at deploy time).')
@secure()
param adminPassword string

@description('Tags.')
param tags object = {}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: union(tags, { 'klz:component': 'jumpbox' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${name}'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output vmId        string = vm.id
output vmName      string = vm.name
output principalId string = vm.identity.principalId
