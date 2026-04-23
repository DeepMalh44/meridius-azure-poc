// ============================================================================
// Meridius Platform — Azure POC Infrastructure
// ============================================================================
// Purpose: Provisions all Azure infrastructure required for the Meridius
//          checkout platform POC. This is a flat, single-file deployment
//          designed for speed. Modularize later for Marketplace packaging.
//
// Resources created:
//   - Virtual Network (3 subnets: AKS, services, endpoints)
//   - AKS Cluster (Free tier, system + workload node pools)
//   - PostgreSQL Flexible Server x2 (Commerce DB + TimescaleDB)
//   - Event Hubs Namespace (Kafka-enabled, Standard tier)
//   - Azure Container Registry (Standard)
//   - Key Vault (RBAC authorization)
//   - Log Analytics Workspace
//   - Managed Grafana
//   - User-Assigned Managed Identity (for AKS workload identity)
// ============================================================================

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Environment name used as prefix for resource names')
@minLength(2)
@maxLength(12)
param environmentName string = 'meridiuspoc'

@description('PostgreSQL administrator login name')
@minLength(1)
param postgresAdminLogin string

@secure()
@description('PostgreSQL administrator password')
@minLength(8)
param postgresAdminPassword string

@description('AKS system node pool VM size')
param aksSystemNodeVmSize string = 'Standard_D2s_v5'

@description('AKS workload node pool VM size')
param aksWorkloadNodeVmSize string = 'Standard_D4s_v5'

@description('AKS system node pool count')
@minValue(1)
@maxValue(5)
param aksSystemNodeCount int = 2

@description('AKS workload node pool count')
@minValue(1)
@maxValue(10)
param aksWorkloadNodeCount int = 2

@description('PostgreSQL Commerce DB SKU name')
param postgresCommerceSkuName string = 'Standard_B2s'

@description('PostgreSQL TimescaleDB SKU name')
param postgresTsdbSkuName string = 'Standard_B2s'

@description('PostgreSQL storage size in GB')
param postgresStorageSizeGB int = 32

@description('Event Hubs throughput units')
@minValue(1)
@maxValue(20)
param eventHubsThroughputUnits int = 1

// ── Variables ───────────────────────────────────────────────────────────────

var uniqueSuffix = uniqueString(resourceGroup().id)
var vnetName = '${environmentName}-vnet'
var aksName = '${environmentName}-aks'
var acrName = '${replace(environmentName, '-', '')}acr${uniqueSuffix}'       // ACR requires alphanumeric only
var keyVaultName = '${take(environmentName, 7)}-kv-${uniqueSuffix}'         // Key Vault max 24 chars (7+4+13=24)
var logAnalyticsName = '${environmentName}-logs'
var grafanaName = '${environmentName}-grafana'
var eventHubsName = '${environmentName}-eventhubs'
var postgresCommerceName = '${environmentName}-pg-commerce'
var postgresTsdbName = '${environmentName}-pg-tsdb'
var aksIdentityName = '${environmentName}-aks-identity'
var workloadIdentityName = '${environmentName}-workload-identity'

// Subnet CIDR ranges
var vnetAddressPrefix = '10.100.0.0/16'
var aksSubnetPrefix = '10.100.0.0/20'       // /20 = 4096 IPs for AKS pods
var servicesSubnetPrefix = '10.100.16.0/24'  // PaaS delegated services
var endpointsSubnetPrefix = '10.100.17.0/24' // Future Private Endpoints

// Explicit subnet resource IDs (avoids preflight issues on redeployment)
var aksSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'aks-subnet')
var servicesSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'services-subnet')

// ── User-Assigned Managed Identities ────────────────────────────────────────

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: aksIdentityName
  location: location
}

resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: workloadIdentityName
  location: location
}

// ── Virtual Network ─────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: aksSubnetPrefix
          networkSecurityGroup: {
            id: aksNsg.id
          }
        }
      }
      {
        name: 'services-subnet'
        properties: {
          addressPrefix: servicesSubnetPrefix
          delegations: [
            {
              name: 'postgres-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: 'endpoints-subnet'
        properties: {
          addressPrefix: endpointsSubnetPrefix
        }
      }
    ]
  }
}

// ── Network Security Group (AKS) ───────────────────────────────────────────

resource aksNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${environmentName}-aks-nsg'
  location: location
  properties: {
    securityRules: []  // AKS manages its own rules; empty is correct
  }
}

// ── Log Analytics Workspace ─────────────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ── Azure Container Registry ────────────────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false  // Use managed identity, not admin credentials
  }
}

// ── AKS Cluster ─────────────────────────────────────────────────────────────

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentity.id}': {}
    }
  }
  properties: {
    dnsPrefix: aksName
    // Omit kubernetesVersion to use AKS default (latest stable)
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      serviceCidr: '10.200.0.0/16'
      dnsServiceIP: '10.200.0.10'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: aksSystemNodeCount
        vmSize: aksSystemNodeVmSize
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vnetSubnetID: aksSubnetId
        enableAutoScaling: true
        minCount: aksSystemNodeCount
        maxCount: aksSystemNodeCount + 1
      }
      {
        name: 'workload'
        count: aksWorkloadNodeCount
        vmSize: aksWorkloadNodeVmSize
        mode: 'User'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vnetSubnetID: aksSubnetId
        enableAutoScaling: true
        minCount: aksWorkloadNodeCount
        maxCount: aksWorkloadNodeCount + 2
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalytics.id
        }
      }
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

// Grant AKS identity AcrPull on the container registry
resource aksAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aksIdentity.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalType: 'ServicePrincipal'
  }
}

// ── Azure Key Vault ─────────────────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7  // Short for POC — increase for production
    // enablePurgeProtection omitted = disabled (allows purge for easy POC cleanup)
  }
}

// ── Event Hubs Namespace (Kafka-enabled) ────────────────────────────────────

resource eventHubsNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubsName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: eventHubsThroughputUnits
  }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: eventHubsThroughputUnits * 2
    kafkaEnabled: true
  }
}

// Create a default Event Hub for testing Kafka connectivity
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubsNamespace
  name: 'meridius-events'
  properties: {
    messageRetentionInDays: 3
    partitionCount: 4
  }
}

// ── Private DNS Zone for PostgreSQL ─────────────────────────────────────────

resource postgresDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${environmentName}.private.postgres.database.azure.com'
  location: 'global'
}

resource postgresDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: postgresDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// ── PostgreSQL Flexible Server — Commerce DB ────────────────────────────────

resource postgresCommerce 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresCommerceName
  location: location
  sku: {
    name: postgresCommerceSkuName
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: postgresStorageSizeGB
    }
    network: {
      delegatedSubnetResourceId: servicesSubnetId
      privateDnsZoneArmResourceId: postgresDnsZone.id
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'  // POC only — enable for production
    }
    highAvailability: {
      mode: 'Disabled'  // POC only — enable ZoneRedundant for production
    }
  }
  dependsOn: [
    postgresDnsZoneVnetLink
    vnet
  ]
}

// ── PostgreSQL Flexible Server — TimescaleDB ────────────────────────────────

resource postgresTsdb 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresTsdbName
  location: location
  sku: {
    name: postgresTsdbSkuName
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: postgresStorageSizeGB
    }
    network: {
      delegatedSubnetResourceId: servicesSubnetId
      privateDnsZoneArmResourceId: postgresDnsZone.id
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
  dependsOn: [
    postgresDnsZoneVnetLink
    vnet
    postgresCommerce  // Avoid DNS zone conflicts during parallel creation
  ]
}

// Enable TimescaleDB extension on the TSDB server
resource tsdbExtension 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgresTsdb
  name: 'azure.extensions'
  properties: {
    value: 'TIMESCALEDB'
    source: 'user-override'
  }
}

// ── Managed Grafana ─────────────────────────────────────────────────────────

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: grafanaName
  location: location
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    grafanaMajorVersion: '11'
    publicNetworkAccess: 'Enabled'  // POC — restrict in production
    apiKey: 'Enabled'
  }
}

// Grant Grafana Monitoring Reader on the resource group for dashboard access
resource grafanaMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, grafana.id, '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  properties: {
    principalId: grafana.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05') // Monitoring Reader
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output aksClusterName string = aks.name
output aksClusterFqdn string = aks.properties.fqdn
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output eventHubsNamespace string = eventHubsNamespace.name
output eventHubsKafkaEndpoint string = '${eventHubsNamespace.name}.servicebus.windows.net:9093'
output postgresCommerceHost string = postgresCommerce.properties.fullyQualifiedDomainName
output postgresTsdbHost string = postgresTsdb.properties.fullyQualifiedDomainName
output logAnalyticsWorkspaceId string = logAnalytics.properties.customerId
output grafanaEndpoint string = grafana.properties.endpoint
output vnetName string = vnet.name
output workloadIdentityClientId string = workloadIdentity.properties.clientId
