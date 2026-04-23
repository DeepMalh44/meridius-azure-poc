# Meridius — Azure Go-Live Implementation Plan

**Date:** April 20, 2026  
**Prepared for:** Meridius / Lowe's Commerce Solutions Engineering & Leadership  
**Prepared by:** Microsoft Azure Team  
**Companion to:** Meridius Azure Architecture Review & Pricing Summary

---

## 1. Executive Summary

This plan outlines **what Meridius needs to build, what teams to staff, and how to sequence the work** to go from "we've decided on Azure" to a production Marketplace listing with live retailer deployments. The plan covers three parallel tracks:

1. **IaC & Marketplace Packaging** — ARM/Bicep templates, CNAB bundle, Partner Center listing
2. **Application Modernization** — Containerize/adapt workloads for AKS, wire up Azure PaaS
3. **Store Edge & Fleet Management** — Azure Arc integration, ACR-based image distribution

**Target:** First retailer pilot deployment in **~14–16 weeks** from kickoff (includes Marketplace certification).

---

## 2. What IaC Is Needed and Why

### 2.1 The Marketplace Deployment Model

Azure Marketplace **Solution Templates** use ARM (Azure Resource Manager) templates — or Bicep, which compiles to ARM — to define every Azure resource that gets created when a retailer clicks "Deploy." This is not optional; it's how Marketplace works.

**What Meridius must produce:**

| Artifact | Format | Purpose |
|----------|--------|---------|
| **Main deployment template** | ARM JSON or Bicep → ARM | Creates all Azure resources: AKS, PostgreSQL, Event Hubs, VNet, Private Endpoints, Key Vault, ACR, Grafana, Monitor, App Gateway, Load Balancer |
| **createUiDefinition.json** | JSON | The Azure Portal wizard that retailers see — dropdowns for region, SKU size, optional modules (chatbot yes/no, Vision AI yes/no), admin credentials |
| **Nested/linked templates** | ARM JSON or Bicep | Modular pieces (networking, AKS, data, security, observability) that the main template orchestrates |
| **CNAB bundle manifest** | porter.yaml or equivalent | Packages the ARM templates + container images together into a single deployable unit for Marketplace |
| **Helm charts** | Helm v3 | Deploys Meridius application workloads (Control Center, Commerce Gateway, AI services) onto AKS after infrastructure is provisioned |
| **Post-deployment scripts** | Bash / PowerShell | Seeds ACR with images, configures NGINX Ingress, creates Kubernetes namespaces, applies network policies |

### 2.2 Bicep vs ARM — Recommendation

**Use Bicep for authoring, ARM for Marketplace submission.** Bicep is far more readable and maintainable, and `az bicep build` compiles it to the ARM JSON that Partner Center requires. This gives you:

- Human-readable IaC that developers can review in PRs
- ARM-compatible output that Marketplace accepts
- Module system for reusable components (networking module, AKS module, data module, etc.)

### 2.3 Template Architecture (Recommended)

```
meridius-marketplace/
├── mainTemplate.json              ← Entry point (compiled from main.bicep)
├── createUiDefinition.json        ← Portal wizard definition
├── modules/
│   ├── networking.bicep           ← VNet, subnets, NSGs, Private DNS Zones
│   ├── aks.bicep                  ← AKS cluster, node pools, managed identity
│   ├── data.bicep                 ← PostgreSQL (commerce + TSDB), Event Hubs
│   ├── security.bicep             ← Key Vault, Managed Identities, Defender
│   ├── observability.bicep        ← Log Analytics, App Insights, Grafana
│   ├── ingress.bicep              ← ILB, App Gateway WAF v2 (conditional)
│   ├── acr.bicep                  ← Container Registry + Private Endpoint
│   └── ai.bicep                   ← AI Foundry endpoint config (conditional)
├── scripts/
│   ├── seed-acr.sh                ← Copies images from Meridius source ACR
│   ├── configure-aks.sh           ← Helm install, namespace creation, NGINX
│   └── validate-deployment.sh     ← Post-deployment health checks
├── helm/
│   ├── control-center/            ← CC frontend + backend + ES + MCP + analytics
│   ├── commerce-gateway/          ← CG API + adapters + OMS + pricing + tax
│   └── ai-services/               ← Vision AI inference, ticketing agent
└── porter.yaml                    ← CNAB bundle definition
```

### 2.4 What the Template Creates (Parameter-Driven)

The retailer fills in the Portal wizard, and the template creates everything. Key parameters:

| Parameter | Type | Options |
|-----------|------|---------|
| Region | dropdown | Central US, East US 2, West US 2, etc. |
| Environment size | dropdown | Demo / Production |
| Enable AI Chatbot | boolean | Creates App Gateway WAF v2 + AI Foundry endpoint if true |
| Enable Vision AI | boolean | Creates ML workspace + GPU compute if true |
| Commerce engine | dropdown | Shopify / Medusa / SAP / Oracle / Custom |
| Admin email / IdP | string | For Entra ID configuration |
| Store count (initial) | number | Sizes Update Manager, Arc, Defender licensing |

---

## 3. Team & Resource Requirements

### 3.1 Meridius Engineering Team (Build Side)

| Role | FTE | Duration | Responsibility |
|------|-----|----------|----------------|
| **Cloud Infrastructure Engineer** (Bicep/ARM) | 1–2 | Weeks 1–10 | Author all Bicep modules, createUiDefinition.json, CNAB bundle; automate Private Endpoints, DNS, NSGs |
| **DevOps / Platform Engineer** | 1–2 | Weeks 1–14 | CI/CD pipeline (GitHub Actions or Azure DevOps) to build images, run tests, package CNAB bundle, publish to Partner Center; Helm chart authoring |
| **AKS / Kubernetes Engineer** | 1 | Weeks 2–10 | AKS cluster design (node pools, autoscaler, workload identity, network policies, NGINX Ingress config), Helm charts, pod security |
| **Application Developer(s)** | 2–3 | Weeks 2–12 | Adapt existing Spring Boot / React / Java workloads for AKS; wire up Azure PaaS SDKs (Event Hubs Kafka client, PostgreSQL connection strings from Key Vault, Managed Identity auth) |
| **AI/ML Engineer** | 1 | Weeks 6–12 | Azure ML workspace setup, RFDetr training pipeline on A100's, AI Foundry endpoint config for Qwen3-32B, MCP Server integration |
| **Security / Compliance Lead** | 0.5 | Weeks 1–14 | Entra ID federation, RBAC design, Key Vault policy, Defender onboarding, PCI-DSS scoping review for Azure deployment model |
| **QA / Test Engineer** | 1 | Weeks 6–14 | End-to-end testing of Marketplace deployment flow, Helm chart validation, store-edge integration testing |

**Total: ~8–10 engineers for ~14 weeks**, tapering to 3–4 after Marketplace certification.

### 3.2 Microsoft Support (Available Resources)

| Resource | How to Engage | What They Help With |
|----------|---------------|---------------------|
| **FastTrack for Azure** | Nominate via Microsoft account team | Architecture review, AKS best practices, Marketplace guidance — no cost |
| **Azure Marketplace Onboarding Team** | Via Partner Center portal | CNAB bundle validation, createUiDefinition review, certification process |
| **ISV Success Program** | Via Microsoft partner manager | GTM support, co-sell listing, customer referrals |
| **Microsoft AI Cloud Partner Program** | Enroll at partner.microsoft.com | Technical benefits, Azure credits for dev/test, priority support |
| **Azure Support (Premier/Unified)** | Customer-side procurement | Production support SLA, break-fix, advisory hours |

### 3.3 Retailer (Customer) Team — Per Deployment

| Role | Effort | Responsibility |
|------|--------|----------------|
| **Cloud Admin** | 2–3 days | Create Azure subscription, set quotas, approve resource creation, configure ExpressRoute/VPN if needed |
| **Identity Admin** | 1–2 days | Entra ID tenant setup, user provisioning, IdP federation (Okta if applicable) |
| **Network Admin** | 1–2 days | Firewall rules for outbound ACR access from stores, Private Endpoint DNS forwarding |
| **Store Ops** | Per-store (2–4 hrs) | Physical rack imaging, register network boot validation, Arc agent installation |

---

## 4. Phased Implementation Plan

### Phase 0 — Foundation (Weeks 1–2)

**Goal:** Azure engineering environment set up, team ramped, architecture validated.

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 0.1 | Provision Meridius engineering Azure subscription (dev/test) | Cloud Infra | Subscription with contributor access for team |
| 0.2 | Set up CI/CD pipeline (GitHub Actions or Azure DevOps) | DevOps | Pipeline repo with build/test/package stages |
| 0.3 | Create Bicep module skeleton (networking, AKS, data, security) | Cloud Infra | Initial `meridius-marketplace/` repo structure |
| 0.4 | Enroll in Microsoft Partner Center | DevOps / PM | Publisher account for Azure Marketplace |
| 0.5 | Architecture design review with Microsoft FastTrack | All | Validated architecture doc, any adjustments |
| 0.6 | Set up shared dev AKS cluster for application testing | AKS Engineer | Working AKS + PostgreSQL + Event Hubs in dev |
| 0.7 | Containerize any remaining non-containerized workloads | App Devs | All services build as Docker images |

### Phase 1 — IaC & Application Adaptation (Weeks 3–8)

**Goal:** All Bicep templates working end-to-end, applications running on AKS.

#### Track A — Infrastructure as Code

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 1.1 | Author `networking.bicep` — VNet, subnets, NSGs, Private DNS Zones | Cloud Infra | Deploys isolated network with correct CIDR ranges |
| 1.2 | Author `aks.bicep` — Cluster, 3 node pools, workload identity, autoscaler | Cloud Infra + AKS Eng | AKS cluster with system/workload/memory-optimized pools |
| 1.3 | Author `data.bicep` — PostgreSQL × 2, Event Hubs, Storage | Cloud Infra | Both DBs with Private Endpoints, HA toggle, TimescaleDB extension |
| 1.4 | Author `security.bicep` — Key Vault, Managed Identities, Defender | Cloud Infra + Security | Zero-trust config, workload identity federation |
| 1.5 | Author `observability.bicep` — Log Analytics, App Insights, Grafana | Cloud Infra | Unified monitoring with diagnostic settings on all resources |
| 1.6 | Author `ingress.bicep` — ILB + App Gateway WAF (conditional) | Cloud Infra | Parameterized: WAF only deploys when chatbot = true |
| 1.7 | Author `acr.bicep` — Premium ACR + Private Endpoint | Cloud Infra | Geo-replication ready, private link |
| 1.8 | Author `ai.bicep` — AI Foundry endpoint (conditional) | Cloud Infra + AI Eng | Serverless Qwen3-32B endpoint provisioning |
| 1.9 | Build `mainTemplate.json` (compile from Bicep) + `createUiDefinition.json` | Cloud Infra + DevOps | Full end-to-end deployment from Portal wizard |
| 1.10 | Automated deployment testing (deploy/destroy/redeploy) | DevOps + QA | CI pipeline that deploys template to a test subscription on every PR |

#### Track B — Application Modernization for AKS

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 1.11 | Create Helm charts — Control Center (frontend, backend, ES, MCP, analytics, messaging) | DevOps + App Devs | `helm/control-center/` with values.yaml for env-specific config |
| 1.12 | Create Helm charts — Commerce Gateway (CG API, adapters, OMS, pricing, tax, promotions) | DevOps + App Devs | `helm/commerce-gateway/` |
| 1.13 | Create Helm charts — AI Services (Vision AI inference, ticketing agent) | DevOps + AI Eng | `helm/ai-services/` |
| 1.14 | Wire Spring Boot apps to Azure services via Managed Identity | App Devs | No hardcoded credentials; Key Vault references for connection strings |
| 1.15 | Switch Kafka producer/consumer config to Event Hubs Kafka endpoint | App Devs | Tested with Kafka API on Event Hubs Standard |
| 1.16 | Configure PostgreSQL connection pooling (PgBouncer sidecar or built-in) | App Devs + AKS Eng | Connection pooling for HA failover scenarios |
| 1.17 | Configure Elasticsearch cluster on memory-optimized node pool | AKS Eng | ES StatefulSet with node affinity for E4s_v5 pool, PVCs for data |
| 1.18 | Wire NGINX Ingress + TLS termination + Internal LB | AKS Eng | All internal traffic routed via NGINX, TLS certs from Key Vault |
| 1.19 | Wire App Gateway WAF → NGINX Ingress for chatbot path | AKS Eng | `/chatbot/*` routed via public App GW → backend pool on AKS |
| 1.20 | Implement health probes (liveness, readiness, startup) for all pods | App Devs | Kubernetes-native health checks for all Helm charts |

### Phase 2 — CNAB Bundle & Marketplace Certification (Weeks 8–12)

**Goal:** Deployable Marketplace listing that passes Microsoft certification.

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 2.1 | Author `porter.yaml` CNAB bundle manifest | DevOps | Bundle that packages ARM templates + Helm charts + ACR seed script |
| 2.2 | Build CNAB bundle CI pipeline (build bundle → push to staging) | DevOps | Automated bundle build on every release tag |
| 2.3 | Create ACR seed script — copies images from Meridius source ACR to customer ACR | DevOps | `scripts/seed-acr.sh` using `az acr import` |
| 2.4 | Author Marketplace listing content (description, screenshots, support URL, pricing model) | PM + Marketing | Partner Center listing draft |
| 2.5 | Submit to Partner Center for technical validation | DevOps + PM | Pre-certification test deployment in Microsoft's test environment |
| 2.6 | Address certification feedback, iterate | All | Typically 1–3 rounds of feedback over 2–3 weeks |
| 2.7 | Create deployment runbook (step-by-step for customer cloud admins) | Cloud Infra | Customer-facing doc: prerequisites, deployment, post-deployment validation |
| 2.8 | Create operations runbook (day-2: scaling, patching, backup, DR) | Cloud Infra + AKS Eng | Customer-facing doc: how to operate the deployed solution |

### Phase 3 — Store Edge & AI Integration (Weeks 8–12, parallel)

**Goal:** Store-side image pull from ACR, Arc enrollment, AI pipelines working.

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 3.1 | Configure store rack K3s to pull images from Customer ACR (token auth or SP) | DevOps + Edge Eng | K3s imagePullSecrets pointing to customer's ACR |
| 3.2 | Configure register cloud boot pull as ACR fallback | DevOps + Edge Eng | Registers can pull directly from ACR if rack is updating |
| 3.3 | Create Azure Arc onboarding script for store servers | Cloud Infra | `arc-enroll.sh` — installs Arc agent, connects to Azure tenant |
| 3.4 | Configure Update Manager policies for Arc-enrolled servers | Cloud Infra | Automated OS patching schedule (e.g., maintenance window Tuesday 2am) |
| 3.5 | Set up Azure ML workspace + RFDetr training pipeline | AI Eng | Blob Storage → ML datastore → training pipeline → model registry |
| 3.6 | Deploy Qwen3-32B serverless endpoint on AI Foundry | AI Eng | MCP Server configured to call endpoint for chatbot queries |
| 3.7 | Create Grafana dashboard templates (store health, register status, fleet overview) | App Devs + Cloud Infra | Pre-built dashboards deployed with Helm chart |

### Phase 4 — Pilot Deployment & Go-Live (Weeks 12–16)

**Goal:** First retailer live on Azure.

| # | Task | Owner | Deliverable |
|---|------|-------|-------------|
| 4.1 | Provision pilot retailer Azure subscription | Customer Cloud Admin | Subscription with quotas approved (especially GPU for Vision AI) |
| 4.2 | Deploy via Marketplace listing (or pre-release private listing) | Meridius + Customer | All Azure resources created via Solution Template |
| 4.3 | Configure commerce engine adapters (Shopify/Medusa/SAP credentials) | App Devs + Customer | Live connection to customer's commerce backend |
| 4.4 | Configure Entra ID / IdP federation | Security Lead + Customer Identity Admin | SSO working for Control Center access |
| 4.5 | Deploy pilot stores (3–5 stores) | Meridius Field Ops + Customer Store Ops | K3s imaging, Arc enrollment, register boot validation |
| 4.6 | End-to-end integration testing (checkout → Event Hubs → Control Center → Grafana) | QA + App Devs | Full transaction flow validated |
| 4.7 | Performance & load testing | QA | AKS autoscaler validated, connection pooling under load |
| 4.8 | Security review (penetration test, Defender alerts review) | Security Lead | No critical findings |
| 4.9 | Go-live sign-off | All stakeholders | Pilot stores processing live transactions |
| 4.10 | Fleet rollout plan (remaining stores at 2–4/day) | Meridius Field Ops | Automated Arc enrollment + image distribution at scale |

---

## 5. Marketplace Certification — What to Expect

| Step | Who | Duration | Details |
|------|-----|----------|---------|
| **1. Partner Center enrollment** | Meridius PM | 1–3 days | Create publisher profile, accept agreements |
| **2. Create offer** | Meridius PM + DevOps | 1 day | Offer type = "Azure Application — Solution Template" |
| **3. Upload technical artifacts** | DevOps | 1 day | mainTemplate.json, createUiDefinition.json, nested templates |
| **4. Automated validation** | Microsoft (automated) | 1–2 days | ARM template linting, resource API version checks, security policy checks |
| **5. Manual review** | Microsoft certification team | 5–10 business days | Deploys template in test subscription, validates UX, security, billing |
| **6. Feedback & iteration** | Meridius DevOps | 3–7 days | Typically 1–3 rounds (common: missing resource locks, incorrect API versions, UX wording) |
| **7. Go-live** | Microsoft | 1 day | Listing appears in Azure Marketplace |

**Total certification time: ~3–4 weeks.** Can overlap with Phase 3 (store edge work).

**Private offers:** While public certification is in progress, Meridius can use **Private Plans** in Partner Center to deploy to specific retailer tenants without waiting for public listing.

---

## 6. CI/CD Pipeline Architecture

```
Developer pushes code
        │
        ▼
┌─────────────────────────────────────────────────┐
│  GitHub Actions / Azure DevOps Pipeline          │
│                                                   │
│  Stage 1: BUILD                                   │
│  ├─ Build Docker images (Spring Boot, React, etc.)│
│  ├─ Run unit tests                                │
│  ├─ Push images to Meridius internal ACR          │
│  └─ Tag with semantic version                     │
│                                                   │
│  Stage 2: IaC VALIDATE                            │
│  ├─ Compile Bicep → ARM                           │
│  ├─ Run ARM what-if (dry run)                     │
│  └─ Validate createUiDefinition.json              │
│                                                   │
│  Stage 3: INTEGRATION TEST                        │
│  ├─ Deploy to test subscription (ephemeral)       │
│  ├─ Helm install onto test AKS                    │
│  ├─ Run smoke tests (health endpoints, DB conn)   │
│  └─ Tear down (cost control)                      │
│                                                   │
│  Stage 4: PACKAGE                                 │
│  ├─ Build CNAB bundle (porter build)              │
│  └─ Push bundle to staging ACR                    │
│                                                   │
│  Stage 5: PUBLISH (manual gate)                   │
│  ├─ Upload to Partner Center                      │
│  └─ Trigger certification                         │
└─────────────────────────────────────────────────┘
```

---

## 7. Key Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **GPU quota not approved in time** | Medium | Vision AI delayed | Request GPU quota (NC A100) in target region immediately in Week 1; have fallback region identified |
| **Marketplace certification takes longer than expected** | Medium | Delays first customer deployment | Use Private Plans for pilot customer; start certification early (Week 8, not Week 12) |
| **Elasticsearch stability on AKS** | Medium | Control Center degraded | Proper resource requests/limits, PVC sizing, anti-affinity rules; consider managed Elastic Cloud on Azure as future option |
| **Event Hubs Kafka API compatibility gaps** | Low | Kafka producer/consumer changes needed | Test early (Week 3–4) with actual Meridius Kafka client config; known gaps: no exactly-once semantics, no compacted topics |
| **PCI-DSS scope review lengthens timeline** | Medium | Go-live delayed | Start PCI scoping in Phase 0; Azure's PCI DSS compliance covers infra layer, but application-layer compliance is Meridius's responsibility |
| **Store network blocks ACR pull** | Medium | Stores can't update software | Document outbound firewall rules needed (ACR endpoints on 443); provide offline bundle as fallback |

---

## 8. Microsoft Engagement Asks

To accelerate this plan, Meridius should request the following from their Microsoft account team:

| Ask | Benefit |
|-----|---------|
| **FastTrack for Azure nomination** | Free architecture review + AKS/Marketplace guidance sessions |
| **ISV Success Program enrollment** | Azure credits for dev/test, priority support, GTM support |
| **Marketplace Onboarding Office Hours** | Direct access to certification team for pre-submission review — avoids failed certification rounds |
| **GPU Quota Pre-Approval** | NC A100 quota in Central US (and backup region) approved before Phase 3 |
| **Azure Expert MSP partner referral** (if needed) | If Meridius doesn't have Azure IaC expertise in-house, Microsoft can connect them with a partner for the Bicep/ARM work |

---

## 9. Summary Timeline

```
Week  1  2  3  4  5  6  7  8  9  10  11  12  13  14  15  16
      ├──┤                                                      Phase 0: Foundation
         ├─────────────────────────┤                            Phase 1: IaC + App (Track A & B)
                                    ├──────────────────┤        Phase 2: CNAB + Certification
                                    ├──────────────────┤        Phase 3: Store Edge + AI (parallel)
                                                         ├─────────┤  Phase 4: Pilot + Go-Live
      ▲                          ▲                    ▲         ▲
      │                          │                    │         │
   Kickoff                  Template               Cert     Pilot
                            works E2E             complete   go-live
```

**Total estimated effort:** ~8–10 engineers × 14–16 weeks  
**First retailer pilot go-live:** Week 14–16 from kickoff  
**Fleet rollout:** Ongoing from Week 16 at 2–4 stores/day

---

*This plan assumes Meridius's existing application workloads are already containerized and running on K3s. The work is primarily about packaging for Azure (IaC + Marketplace) and wiring Azure PaaS services, not rewriting applications.*
