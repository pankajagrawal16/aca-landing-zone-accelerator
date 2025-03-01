targetScope = 'resourceGroup'

// ------------------
//    PARAMETERS
// ------------------
@description('The name of the workload that is being deployed. Up to 10 characters long.')
@minLength(2)
@maxLength(10)
param workloadName string

@description('The name of the environment (e.g. "dev", "test", "prod", "uat", "dr", "qa"). Up to 8 characters long.')
@maxLength(8)
param environment string

@description('The location where the resources will be created. This needs to be the same region as the spoke.')
param location string = resourceGroup().location

@description('Optional. The tags to be assigned to the created resources.')
param tags object = {}

// Hub
@description('The resource ID of the existing hub virtual network.')
param hubVNetId string

// Spoke
@description('The name of the existing spoke virtual network.')
param spokeVNetName string

@description('The name of the existing spoke infrastructure subnet.')
param spokeInfraSubnetName string

// Telemetry
@description('Enable or disable the createion of Application Insights.')
param enableApplicationInsights bool

@description('Enable or disable Dapr application instrumentation using Application Insights. If enableApplicationInsights is false, this parameter is ignored.')
param enableDaprInstrumentation bool

@description('Enable sending usage and telemetry feedback to Microsoft.')
param enableTelemetry bool = true

@description('The resource id of an existing Azure Log Analytics Workspace.')
param logAnalyticsWorkspaceId string

@description('Optional, default value is true. If true, any resources that support AZ will be deployed in all three AZ. However if the selected region is not supporting AZ, this parameter needs to be set to false.')
param deployZoneRedundantResources bool = true

// ------------------
// VARIABLES
// ------------------

var hubVNetResourceIdTokens = !empty(hubVNetId) ? split(hubVNetId, '/') : array('')

@description('The ID of the subscription containing the hub virtual network.')
var hubSubscriptionId = hubVNetResourceIdTokens[2]

@description('The name of the resource group containing the hub virtual network.')
var hubResourceGroupName = hubVNetResourceIdTokens[4]

@description('The name of the hub virtual network.')
var hubVNetName = hubVNetResourceIdTokens[8]

var telemetryId = '9b4433d6-924a-4c07-b47c-7478619759c7-${location}-acasb'

// ------------------
// EXISTING RESOURCES
// ------------------

@description('The existing hub virtual network.')
resource vnetHub 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  name: hubVNetName
}

@description('The existing spoke virtual network.')
resource spokeVNet 'Microsoft.Network/virtualNetworks@2022-01-01' existing = {
  name: spokeVNetName

  resource infraSubnet 'subnets' existing = {
    name: spokeInfraSubnetName
  }
}

// ------------------
// RESOURCES
// ------------------

@description('User-configured naming rules')
module naming '../../../../shared/bicep/naming/naming.module.bicep' = {
  name: take('04-sharedNamingDeployment-${deployment().name}', 64)
  params: {
    uniqueId: uniqueString(resourceGroup().id)
    environment: environment
    workloadName: workloadName
    location: location
  }
}

@description('Azure Application Insights, the workload\' log & metric sink and APM tool')
module applicationInsights '../../../../shared/bicep/app-insights.bicep' = if (enableApplicationInsights) {
  name: take('applicationInsights-${uniqueString(resourceGroup().id)}', 64)
  params: {
    name: naming.outputs.resourcesNames.applicationInsights
    location: location
    tags: tags
    workspaceResourceId: logAnalyticsWorkspaceId
  }
}

@description('The Azure Container Apps (ACA) cluster.')
module containerAppsEnvironment '../../../../shared/bicep/aca-environment.bicep' = {
  name: take('containerAppsEnvironment-${uniqueString(resourceGroup().id)}', 64)
  params: {
    name: naming.outputs.resourcesNames.containerAppsEnvironment
    location: location
    tags: tags
    logAnalyticsWsResourceId: logAnalyticsWorkspaceId
    subnetId: spokeVNet::infraSubnet.id
    vnetEndpointInternal: true
    appInsightsInstrumentationKey: (enableApplicationInsights && enableDaprInstrumentation) ? applicationInsights.outputs.appInsInstrumentationKey : ''
    zoneRedundant: deployZoneRedundantResources
  }
}

@description('The Private DNS zone containing the ACA load balancer IP')
module containerAppsEnvironmentPrivateDnsZone '../../../../shared/bicep/network/private-dns-zone.bicep' = {
  name: 'containerAppsEnvironmentPrivateDnsZone-${uniqueString(resourceGroup().id)}'
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    name: containerAppsEnvironment.outputs.containerAppsEnvironmentDefaultDomain
    virtualNetworkLinks: [
      {
        vnetName: spokeVNet.name  /* Link to spoke */
        vnetId: spokeVNet.id
        registrationEnabled: false
      }
      {
        vnetName: vnetHub.name  /* Link to hub */
        vnetId: vnetHub.id
        registrationEnabled: false
      }
    ]
    tags: tags
    aRecords: [
      {
        name: '*'
        ipv4Address: containerAppsEnvironment.outputs.containerAppsEnvironmentLoadBalancerIP
      }
    ]
  }
}

@description('Microsoft telemetry deployment.')
resource telemetrydeployment 'Microsoft.Resources/deployments@2021-04-01' = if (enableTelemetry) {
  name: telemetryId
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
      contentVersion: '1.0.0.0'
      resources: {}
    }
  }
}

// ------------------
// OUTPUTS
// ------------------

@description('The resource ID of the Container Apps environment.')
output containerAppsEnvironmentId string = containerAppsEnvironment.outputs.containerAppsEnvironmentNameId

@description('The name of the Container Apps environment.')
output containerAppsEnvironmentName string = containerAppsEnvironment.outputs.containerAppsEnvironmentName
