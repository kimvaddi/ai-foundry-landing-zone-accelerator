using './hub-bootstrap.bicep'

param workload = 'klzfin'
param env      = 'prod'
param location = 'eastus2'
param hubAddressSpace = '10.0.0.0/16'
param firewallSubnetCidr = '10.0.0.0/26'

param tags = {
  workload:  'klzfin'
  env:       'prod'
  purpose:   'hub-bootstrap'
  ownedBy:   'klz-accelerator'
}
