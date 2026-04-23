using './main.bicep'

param environmentName = 'meridiuspoc'
param location = 'centralus'

// ── PostgreSQL Credentials ──────────────────────────────────────────────────
// IMPORTANT: Change these before deploying. For production, use Key Vault references.
param postgresAdminLogin = 'meridius_admin'
param postgresAdminPassword = '<REPLACE-WITH-STRONG-PASSWORD>'

// ── AKS Configuration ───────────────────────────────────────────────────────
param aksSystemNodeVmSize = 'Standard_D2s_v5'
param aksWorkloadNodeVmSize = 'Standard_D4s_v5'
param aksSystemNodeCount = 2
param aksWorkloadNodeCount = 2

// ── PostgreSQL Configuration ────────────────────────────────────────────────
param postgresCommerceSkuName = 'Standard_B2s'
param postgresTsdbSkuName = 'Standard_B2s'
param postgresStorageSizeGB = 32

// ── Event Hubs ──────────────────────────────────────────────────────────────
param eventHubsThroughputUnits = 1
