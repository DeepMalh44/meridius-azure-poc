# ============================================================================
# Meridius POC — Azure Infrastructure Deployment Script
# ============================================================================
# Usage:  .\deploy.ps1 -ResourceGroupName "meridius-poc-rg" -Location "centralus" -PostgresPassword "<password>"
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "centralus",

    [Parameter(Mandatory = $true)]
    [SecureString]$PostgresPassword
)

$ErrorActionPreference = "Stop"

# ── Pre-flight checks ───────────────────────────────────────────────────────

Write-Host "`n=== Meridius POC — Azure Infrastructure Deployment ===" -ForegroundColor Cyan

# Verify Azure CLI is installed and logged in
try {
    $accountJson = az account show --output json
    if ($LASTEXITCODE -ne 0) { throw "az account show failed" }
    $account = $accountJson | ConvertFrom-Json
    Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green
    Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Azure CLI is not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

# Verify Bicep CLI is available
try {
    $bicepVersion = az bicep version 2>&1
    Write-Host "Bicep: $bicepVersion" -ForegroundColor Green
}
catch {
    Write-Host "Installing Bicep CLI..." -ForegroundColor Yellow
    az bicep install
}

# ── Create Resource Group ────────────────────────────────────────────────────

Write-Host "`nCreating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Yellow
az group create --name $ResourceGroupName --location $Location --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create resource group '$ResourceGroupName'. Check the error above." -ForegroundColor Red
    exit 1
}
Write-Host "Resource group created." -ForegroundColor Green

# ── Deploy Bicep Template ────────────────────────────────────────────────────

$templateFile = Join-Path $PSScriptRoot "main.bicep"
$paramsFile = Join-Path $PSScriptRoot "main.bicepparam"

# Convert SecureString to plain text for az cli
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PostgresPassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

Write-Host "`nDeploying Meridius POC infrastructure (this takes 15-25 minutes)..." -ForegroundColor Yellow
Write-Host "Template: $templateFile" -ForegroundColor Gray

$deploymentName = "meridius-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$result = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $deploymentName `
    --template-file $templateFile `
    --parameters $paramsFile `
    --parameters postgresAdminPassword=$plainPassword `
    --output json

# Clear password from memory
$plainPassword = $null

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nERROR: Deployment failed. See error details above." -ForegroundColor Red
    Write-Host "Portal: https://portal.azure.com/#@/resource/subscriptions/$($account.id)/resourceGroups/$ResourceGroupName/deployments" -ForegroundColor Yellow
    Write-Host "`nIf this is a re-deployment and Key Vault failed, purge the soft-deleted vault first:" -ForegroundColor Yellow
    Write-Host "  az keyvault purge --name <vault-name>" -ForegroundColor Gray
    exit 1
}

$outputs = ($result | ConvertFrom-Json).properties.outputs

# ── Display Connection Information ───────────────────────────────────────────

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "── AKS Cluster ──" -ForegroundColor Cyan
Write-Host "  Name:     $($outputs.aksClusterName.value)"
Write-Host "  FQDN:     $($outputs.aksClusterFqdn.value)"
Write-Host "  Connect:  az aks get-credentials --resource-group $ResourceGroupName --name $($outputs.aksClusterName.value)"
Write-Host ""
Write-Host "── Container Registry ──" -ForegroundColor Cyan
Write-Host "  Login Server: $($outputs.acrLoginServer.value)"
Write-Host "  Push image:   az acr login --name $($outputs.acrName.value)"
Write-Host ""
Write-Host "── Event Hubs (Kafka) ──" -ForegroundColor Cyan
Write-Host "  Namespace:       $($outputs.eventHubsNamespace.value)"
Write-Host "  Kafka Endpoint:  $($outputs.eventHubsKafkaEndpoint.value)"
Write-Host ""
Write-Host "── PostgreSQL ──" -ForegroundColor Cyan
Write-Host "  Commerce DB:  $($outputs.postgresCommerceHost.value)"
Write-Host "  TimescaleDB:  $($outputs.postgresTsdbHost.value)"
Write-Host "  Login:        $($outputs.postgresCommerceHost.value) -U meridius_admin"
Write-Host ""
Write-Host "── Key Vault ──" -ForegroundColor Cyan
Write-Host "  Name: $($outputs.keyVaultName.value)"
Write-Host "  URI:  $($outputs.keyVaultUri.value)"
Write-Host ""
Write-Host "── Monitoring ──" -ForegroundColor Cyan
Write-Host "  Log Analytics Workspace ID: $($outputs.logAnalyticsWorkspaceId.value)"
Write-Host "  Grafana Dashboard:          $($outputs.grafanaEndpoint.value)"
Write-Host ""
Write-Host "── Workload Identity ──" -ForegroundColor Cyan
Write-Host "  Client ID: $($outputs.workloadIdentityClientId.value)"
Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Yellow
Write-Host "1. Get AKS credentials:     az aks get-credentials --resource-group $ResourceGroupName --name $($outputs.aksClusterName.value)"
Write-Host "2. Push images to ACR:       az acr login --name $($outputs.acrName.value)"
Write-Host "3. Deploy Helm charts:       helm install control-center ./helm/control-center"
Write-Host "4. Test Kafka connectivity:  Use the Kafka endpoint above with SASL_SSL authentication"
Write-Host ""
