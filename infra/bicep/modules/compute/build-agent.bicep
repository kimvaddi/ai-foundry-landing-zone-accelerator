// =============================================================================
// build-agent.bicep — Ubuntu 24.04 LTS build agent VM (no public IP)
//
// Companion of DevOpsBuildSubnet. Sized for build/test pipelines (default B2s),
// SystemAssigned MI so it can authenticate to ACR/KV/Storage without secrets.
// Accessed via Bastion or self-hosted runner registration.
// =============================================================================

@description('VM name. Linux allows 64 chars.')
@maxLength(64)
param name string

@description('Region.')
param location string

@description('Resource ID of DevOpsBuildSubnet.')
param subnetResourceId string

@description('VM size.')
param vmSize string = 'Standard_B2s'

@description('Admin username.')
param adminUsername string = 'klzadmin'

@description('SSH public key for the admin user (preferred over password).')
param sshPublicKey string

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
  tags: union(tags, { 'klz:component': 'build-agent' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
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
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
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
