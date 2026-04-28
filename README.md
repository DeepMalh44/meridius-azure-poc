# Meridius Platform — Azure POC Infrastructure

This repository contains the Bicep templates and deployment script to provision all Azure infrastructure required for the Meridius checkout platform Proof of Concept (POC).

## What Gets Deployed

| Resource | SKU / Config | Purpose |
|----------|-------------|---------|
| **Virtual Network** | 10.100.0.0/16, 3 subnets | Network isolation for all resources |
| **AKS Cluster** | Free tier, 2 node pools (system + workload) | Runs Control Center & Commerce Gateway |
| **PostgreSQL Flexible Server** (Commerce) | Burstable B2s, 32 GB | Commerce engine database (Medusa, OMS, etc.) |
| **PostgreSQL Flexible Server** (TSDB) | Burstable B2s, 32 GB, TimescaleDB | Time-series metrics for Grafana dashboards |
| **Event Hubs Namespace** | Standard, 1 TU, Kafka enabled | Cloud-side message backbone (Kafka API compatible) |
| **Azure Container Registry** | Standard | Stores all Meridius container images |
| **Key Vault** | Standard, RBAC auth | Secrets and connection strings |
| **Log Analytics Workspace** | Pay-per-GB | Centralized logging and AKS monitoring |
| **Managed Grafana** | Standard | Real-time dashboards (store health, registers) |
| **Private Endpoints** | ACR, Key Vault, Event Hubs, Grafana | Private-only access to PaaS services from VNet |
| **Managed Identities** | User-Assigned × 2 | AKS cluster identity + workload identity |

**Estimated monthly cost: ~$800–950** (core services with private connectivity, no AI/WAF components)

**Network posture:** AKS API is private cluster mode and ACR/Key Vault/Event Hubs/Grafana are configured for private endpoint access.

---

## Prerequisites

1. **Azure CLI** (v2.60+) with Bicep CLI installed
   ```powershell
   # Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli
   az bicep install
   az bicep upgrade
   ```

2. **Azure Subscription** with the following resource providers registered:
   ```powershell
   az provider register --namespace Microsoft.ContainerService
   az provider register --namespace Microsoft.DBforPostgreSQL
   az provider register --namespace Microsoft.EventHub
   az provider register --namespace Microsoft.ContainerRegistry
   az provider register --namespace Microsoft.KeyVault
   az provider register --namespace Microsoft.Dashboard
   az provider register --namespace Microsoft.OperationalInsights
   az provider register --namespace Microsoft.ManagedIdentity
   ```

3. **Sufficient quota** in the target region (Central US recommended):
   - D-series vCPUs: at least 12 (4 for system pool + 8 for workload pool)
   - Standard_D2s_v5 and Standard_D4s_v5 availability
   
   Check your quota:
   ```powershell
   az vm list-usage --location centralus --output table | Select-String "DSv5"
   ```

4. **Permissions**: Contributor + User Access Administrator on the subscription (or a dedicated resource group with Owner)

---

## Quick Start

### 1. Clone and configure

```powershell
cd meridius-poc
```

Edit `main.bicepparam` to review default values. At minimum, you **must** change:
- `postgresAdminPassword` — set a strong password (or pass via CLI, see below)
- `environmentName` — change if you want a different prefix (default: `meridiuspoc`)
- `location` — change if not using Central US

### 2. Login to Azure

```powershell
az login
az account set --subscription "<your-subscription-id>"
```

### 3. Deploy

```powershell
.\deploy.ps1 -ResourceGroupName "meridius-poc-rg" -Location "centralus" -PostgresPassword (Read-Host -AsSecureString "PostgreSQL password")
```

The deployment takes approximately **15–25 minutes**. The script will display all connection information upon completion.

### 4. Verify

```powershell
# Get AKS credentials
az aks get-credentials --resource-group meridius-poc-rg --name meridiuspoc-aks

# Verify cluster is running
kubectl get nodes

# Verify namespaces (should see default, kube-system, etc.)
kubectl get namespaces
```

---

## Post-Deployment: Application Setup

After infrastructure is ready, deploy the Meridius application components:

### Step 1 — Push Container Images to ACR

```powershell
# Login to ACR
az acr login --name <acrName from deployment output>

# Tag and push your images
docker tag meridius/control-center:latest <acrLoginServer>/meridius/control-center:latest
docker push <acrLoginServer>/meridius/control-center:latest

# Repeat for all application images (commerce-gateway, adapters, etc.)
```

### Step 2 — Create Kubernetes Namespaces

```powershell
kubectl create namespace control-center
kubectl create namespace commerce-gateway
```

### Step 3 — Store Connection Strings in Key Vault

```powershell
$kvName = "<keyVaultName from deployment output>"

# PostgreSQL Commerce DB connection string
az keyvault secret set --vault-name $kvName --name "postgres-commerce-connection" `
    --value "Host=<postgresCommerceHost>;Database=meridius;Username=meridius_admin;Password=<your-password>;SSL Mode=Require"

# PostgreSQL TimescaleDB connection string
az keyvault secret set --vault-name $kvName --name "postgres-tsdb-connection" `
    --value "Host=<postgresTsdbHost>;Database=metrics;Username=meridius_admin;Password=<your-password>;SSL Mode=Require"

# Event Hubs Kafka connection string
$ehConnStr = az eventhubs namespace authorization-rule keys list `
    --resource-group meridius-poc-rg `
    --namespace-name <eventHubsNamespace> `
    --name RootManageSharedAccessKey `
    --query primaryConnectionString -o tsv

az keyvault secret set --vault-name $kvName --name "eventhubs-kafka-connection" --value $ehConnStr
```

### Step 4 — Deploy Helm Charts

```powershell
# Deploy Control Center
helm install control-center ./helm/control-center \
    --namespace control-center \
    --set image.registry=<acrLoginServer> \
    --set postgresql.host=<postgresCommerceHost> \
    --set keyvault.name=<keyVaultName>

# Deploy Commerce Gateway
helm install commerce-gateway ./helm/commerce-gateway \
    --namespace commerce-gateway \
    --set image.registry=<acrLoginServer> \
    --set postgresql.host=<postgresCommerceHost> \
    --set eventhubs.endpoint=<eventHubsKafkaEndpoint> \
    --set keyvault.name=<keyVaultName>
```

### Step 5 — Validate Kafka Connectivity (Critical)

This is the **#1 risk item** — confirm existing Kafka producer/consumer code works with Event Hubs:

```powershell
# Get the Event Hubs connection string for Kafka
$ehConnStr = az eventhubs namespace authorization-rule keys list `
    --resource-group meridius-poc-rg `
    --namespace-name <eventHubsNamespace> `
    --name RootManageSharedAccessKey `
    --query primaryConnectionString -o tsv

# Kafka client configuration (for your application's producer/consumer config):
# bootstrap.servers = <eventHubsNamespace>.servicebus.windows.net:9093
# security.protocol = SASL_SSL
# sasl.mechanism = PLAIN
# sasl.jaas.config = org.apache.kafka.common.security.plain.PlainLoginModule required
#     username="$ConnectionString"
#     password="<Event Hubs connection string>";
```

Key Kafka compatibility notes:
- Event Hubs supports **Kafka protocol 1.0+**
- Consumer group names must be pre-created or use `$Default`
- Max message size: **1 MB** (vs Kafka's default 1 MB — should be fine)
- Topic = Event Hub name (`meridius-events` is pre-created)

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│  Azure Resource Group: meridius-poc-rg                           │
│                                                                  │
│  ┌─────────── VNet 10.100.0.0/16 ──────────────────────────┐   │
│  │                                                           │   │
│  │  ┌─── AKS Subnet 10.100.0.0/20 ──────────────────────┐  │   │
│  │  │  AKS Cluster (Free tier)                           │  │   │
│  │  │  ├── System Pool: 2× D2s_v5                        │  │   │
│  │  │  └── Workload Pool: 2× D4s_v5                      │  │   │
│  │  │      ├── namespace: control-center                  │  │   │
│  │  │      │   (CC Frontend, Backend, ES, MCP, Analytics) │  │   │
│  │  │      └── namespace: commerce-gateway                │  │   │
│  │  │          (CG API, Adapters, OMS, Pricing, Tax)      │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  │                                                           │   │
│  │  ┌─── Services Subnet 10.100.16.0/24 ────────────────┐  │   │
│  │  │  PostgreSQL Commerce (B2s)                         │  │   │
│  │  │  PostgreSQL TimescaleDB (B2s)                      │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  │                                                           │   │
│  │  ┌─── Endpoints Subnet 10.100.17.0/24 ───────────────┐  │   │
│  │  │  Private Endpoints: ACR, Key Vault, EH, Grafana    │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Event Hubs (Kafka)  ·  ACR  ·  Key Vault  ·  Grafana  ·  Logs │
└──────────────────────────────────────────────────────────────────┘
         ▲
         │ Image Pull (HTTPS)
         │
┌────────┴─────────┐
│  Store Edge K3s  │
│  (Test rack)     │
└──────────────────┘
```

---

## POC Validation Checklist

Use this checklist to confirm the POC is successful:

- [ ] AKS cluster running, `kubectl get nodes` shows all nodes Ready
- [ ] Container images pushed to ACR and pods pull successfully
- [ ] Control Center UI accessible (port-forward or ingress)
- [ ] Commerce Gateway API responds to health checks
- [ ] Kafka producers/consumers work against Event Hubs endpoint
- [ ] PostgreSQL Commerce DB accepts connections, schema migrations run
- [ ] TimescaleDB extension active, time-series inserts work
- [ ] Grafana dashboards render store health data
- [ ] Key Vault secrets accessible from AKS pods via workload identity
- [ ] (Optional) Test K3s store rack pulls images from ACR

---

## Cleanup

To tear down all POC resources:

```powershell
az group delete --name meridius-poc-rg --yes --no-wait
```

> **Re-deployment note:** Key Vault uses soft-delete (7-day retention). If you delete the resource group and redeploy, purge the old vault first:
> ```powershell
> az keyvault list-deleted --query "[?contains(name,'meridiu')]" -o table
> az keyvault purge --name <vault-name-from-above>
> ```

---

## What's Next (After POC Validation)

1. **Ingress Security** — Add App Gateway WAF and controlled public ingress where needed
2. **AI Extension** — Add Azure AI Foundry and ML workloads for chatbot/vision use cases
3. **Modularize** — Split `main.bicep` into per-domain modules (networking, AKS, data, security, observability, ingress, AI)
4. **Marketplace** — Build createUiDefinition.json, package CNAB bundle, submit to Partner Center
5. **Production** — Scale node pools, enable PostgreSQL HA, add Defender, configure Azure Arc for stores

See the [Meridius Azure Go-Live Implementation Plan](../Meridius-Azure-Go-Live-Plan.md) for the full production roadmap.
