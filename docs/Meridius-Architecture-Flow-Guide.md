# Meridius Platform — Architecture Flow Guide

**For:** Customers new to Azure  
**Date:** April 17, 2026  
**Purpose:** Plain-language walkthrough of how the Meridius platform is deployed, how software reaches your stores, and how data flows between your stores and the cloud.

---

## What Is This Platform?

Meridius is a **checkout and commerce platform** that runs in two places:

1. **In the cloud** (Azure) — the "brain" that manages configuration, AI features, dashboards, and data
2. **In each store** (on-premises) — the actual registers, pricing engines, and checkout software that your store associates and customers interact with

Everything runs inside **your own Azure subscription**. Meridius does not see or touch your data — it simply provides the software. Think of it like buying an appliance that you install in your own home.

---

## How Does the Software Get Into My Azure Subscription?

This is the **Azure Marketplace** model. Here's how it works, step by step:

```
┌─────────────────────────────────┐
│  Meridius Engineering (their    │
│  own, separate environment)     │
│                                 │
│  1. Developers write code       │
│  2. Build Pipeline creates      │
│     container images            │
│  3. Images are packaged into    │
│     a "CNAB bundle" (think of   │
│     it as a shipping box with   │
│     everything inside)          │
│  4. Bundle is published to      │
│     Azure Marketplace via       │
│     Microsoft Partner Center    │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Azure Marketplace              │
│  (Microsoft-hosted, public)     │
│                                 │
│  Like an "app store" for Azure. │
│  The Meridius listing appears   │
│  here. When you click "Deploy", │
│  the images are copied into     │
│  YOUR subscription.             │
└──────────────┬──────────────────┘
               │  You click "Deploy" in Azure Portal
               ▼
┌─────────────────────────────────┐
│  Your Azure Subscription        │
│  (Central US region)            │
│                                 │
│  A "Solution Template" (a       │
│  recipe) runs automatically     │
│  and creates all the Azure      │
│  resources you need:            │
│                                 │
│  • AKS cluster (runs software)  │
│  • Databases (PostgreSQL)       │
│  • Messaging (Event Hubs)       │
│  • Networking (VNet, firewall)  │
│  • Security (Key Vault, Entra)  │
│  • Monitoring (Grafana, logs)   │
│  • Your own Container Registry  │
│    (ACR) — a private copy of    │
│    all the Meridius images      │
│                                 │
│  This takes about 2-4 hours.    │
└─────────────────────────────────┘
```

**Key point:** Meridius never has access to your subscription after deployment. All data (including PII and PCI card data) stays in your tenant.

---

## How Do Software Images Reach the Store?

This is one of the most important flows to understand. Your stores have physical server hardware (the "rack") and checkout registers. Both need software to run. Here's how that software gets from Azure to your stores:

```
┌──────────────────────┐
│  Azure Marketplace   │
│  (Meridius images)   │
└──────────┬───────────┘
           │ At deployment time, images
           │ are copied into your subscription
           ▼
┌──────────────────────┐
│  Your Customer ACR   │
│  (Container Registry │
│   in YOUR Azure      │
│   subscription)      │
│                      │
│  This is the SINGLE  │
│  SOURCE OF TRUTH for │
│  all images          │
└──┬───────┬───────┬───┘
   │       │       │
   │       │       │
   ▼       ▼       ▼
 ┌───┐  ┌─────┐  ┌───────────────────┐
 │AKS│  │Store│  │Store Registers    │
 │   │  │Rack │  │(checkout machines)│
 └───┘  └─────┘  └───────────────────┘

 Cloud    On-Prem   On-Prem
 apps     server    terminals
```

### Three destinations, one source:

1. **AKS cluster** (cloud) — Pulls images from your ACR to run cloud workloads like Control Center, Commerce Gateway, and AI services. This is standard Kubernetes behavior.

2. **Store Server Rack** (in-store hardware) — The physical servers in your store pull container images from the same Customer ACR over the internet (outbound HTTPS). This means when Meridius publishes a software update to the Marketplace, and you approve it, the new images flow into your ACR, and your store racks pull the updated images automatically.

3. **Registers** (checkout machines) — Your checkout terminals can also pull deployable images directly from Customer ACR. Alternatively, they get their software from the store server rack via network boot (the traditional approach). The cloud pull option provides a fallback if the store rack is being updated.

### What does the store need to make this work?

- **Outbound internet access** (HTTPS on port 443) to reach your Azure Container Registry
- The store network does NOT need to be "opened up" to inbound traffic from the internet — the store hardware initiates the pull (outbound only)

---

## Data Flows — What Talks to What?

Here are the main data flows in the system, explained simply:

### Flow ① ② — Admin Portal Access

```
Store Manager or Platform Admin
        │
        ├──① Opens Android Chatbot App (for voice queries)
        │
        └──② Opens Control Center portal (web browser)
               │
               ▼
         Internal Load Balancer → AKS → Control Center
```

The Control Center is a web application where store managers configure rules, view dashboards, and manage the fleet. It's accessed over HTTPS through an internal load balancer (not exposed to the public internet).

### Flow ③ ④ ⑤ — AI Voice Chatbot

This is the flow when a store manager asks a question using the Android voice chatbot:

```
Android App  ──③──▶  App Gateway WAF v2  ──④──▶  MCP Server (on AKS)  ──⑤──▶  Azure AI Foundry
 (voice query)      (firewall + identity         (processes the query)         (Qwen3-32B model
                     check via Entra ID)                                        generates answer)
```

- **Step ③:** The Android app sends the voice query over HTTPS to the App Gateway. The App Gateway is a **web application firewall** — it inspects the traffic for threats and verifies the user's identity using **Entra ID** (Microsoft's identity service, like a bouncer at a door).
- **Step ④:** Once verified, the request passes through to the **MCP Server** running on AKS inside the cluster. The MCP Server knows how to search Elasticsearch for relevant store data.
- **Step ⑤:** The MCP Server calls **Azure AI Foundry**, which hosts the **Qwen3-32B** language model. The model generates a response, which flows back through the same path to the Android app.

**Why this matters:** The chatbot is the only component exposed to the public internet, and it's protected by both a firewall (WAF) and identity verification (Entra). Everything else stays internal.

### Flow ⑥ — Store-to-Cloud Data Sync (Orders & Transactions)

```
Store Server Rack  ──⑥──▶  Azure Event Hubs (Kafka API)
(local Kafka)               (cloud message queue)
```

Your store processes transactions locally (it works even if the internet goes down). When connectivity is available, the store's local Kafka system syncs order data up to **Azure Event Hubs** in the cloud. Event Hubs keeps a **3-day buffer**, so even if a store is offline for up to 3 days, no data is lost — it catches up when reconnected.

### Flow ⑦ — Fleet Management (Store → Cloud)

```
Azure Arc Agent  ──⑦──▶  Azure Arc (fleet control plane)
(1 per store)              (centralized management)
```

Each store has a small **Azure Arc agent** installed. This agent periodically sends health and telemetry data to Azure — things like "is the server running?", "how much disk space is left?", "are all services healthy?". Your IT team can see all stores on a single dashboard in the Azure portal, powered by **Managed Grafana**.

### Flow ⑩ — Commerce Engine Integration

```
Commerce Gateway (on AKS)  ──⑩──▶  Your Enterprise Systems
(Engine Adapters)                   (SAP / Oracle / Shopify / OMS / etc.)
```

The Commerce Gateway has **pluggable adapters** that connect to whatever commerce systems you already use (SAP, Oracle, Shopify, etc.). These are REST API calls. The adapters are pre-built by Meridius — you just provide connection credentials.

---

## What Gets Deployed Automatically vs. What's Manual?

| Deployed automatically by the Solution Template | Set up separately |
|---|---|
| AKS cluster with all namespaces | Azure ML GPU compute (needs quota approval from Microsoft) |
| Event Hubs (Kafka) | Entra ID tenant configuration / federation with your IdP |
| PostgreSQL databases (Commerce + TSDB) | Defender for Containers / Servers (subscription-level enablement) |
| Storage Account | Azure Arc enrollment of each store (done per-store during rollout) |
| VNet + Private Endpoints + DNS | Your enterprise system connectivity (VPN, ExpressRoute, etc.) |
| Internal Load Balancer + NGINX Ingress | Commerce engine adapter credentials (Shopify/SAP API keys) |
| App Gateway WAF v2 | Physical store hardware imaging |
| Customer ACR (seeded with images) | |
| Key Vault (secrets store) | |
| Managed Identities | |
| Managed Grafana (dashboards) | |
| Azure Monitor + Log Analytics | |
| AI Foundry endpoint configuration | |

**In simple terms:** You click "Deploy" in Azure Marketplace, and 2-4 hours later you have a fully working cloud environment. The manual work is mostly about connecting it to your existing systems and rolling out to physical stores.

---

## Security Summary (Plain Language)

| Concern | How it's handled |
|---|---|
| **Who can access the system?** | Microsoft Entra ID (MFA + role-based access). Only authorized admins can log in. |
| **Is the chatbot safe from hackers?** | App Gateway WAF v2 inspects all traffic for attacks. Entra ID verifies every user. |
| **Where is my data?** | In YOUR Azure subscription, in the Central US region. Meridius cannot see it. |
| **How do services talk to each other?** | Using Managed Identities — no passwords stored anywhere. Azure handles authentication automatically. |
| **Are secrets (API keys, etc.) safe?** | Stored in Azure Key Vault — encrypted, access-controlled, audit-logged. |
| **What about the store servers?** | Optional Microsoft Defender for Servers P1 provides threat detection on store hardware. |
| **Is the software scanned?** | Microsoft Defender for Containers scans all container images for known vulnerabilities. |

---

## Network Diagram (Simplified)

```
                    ┌────────────────────────────────────────────────────────┐
                    │              YOUR AZURE SUBSCRIPTION                   │
                    │                                                        │
  Internet ────▶   │  App Gateway WAF ──▶ AKS Cluster                      │
  (Chatbot only)   │  (public IP)         ├─ Control Center                 │
                    │                      ├─ Commerce Gateway               │
  Internal ────▶   │  Internal LB ────▶   └─ AI/ML Services                │
  (Portal)         │  (private IP)                                           │
                    │                                                        │
                    │  PostgreSQL (×2)   Event Hubs   Storage   Key Vault   │
                    │  Grafana           Arc          Monitor   Entra ID    │
                    │                                                        │
                    │  Customer ACR ──────────────────┐                     │
                    │   (image source for everything)  │                     │
                    └──────────────────────────────────┼─────────────────────┘
                                                       │
                              ┌─────────────────────────┤
                              │                         │
                              ▼                         ▼
                    ┌──────────────────┐     ┌──────────────────┐
                    │  Store Server    │     │  Store Server    │
                    │  Rack (Store 1)  │     │  Rack (Store 2)  │
                    │  ├─ K3s cluster  │     │  ├─ K3s cluster  │
                    │  ├─ Registers    │     │  ├─ Registers    │
                    │  └─ Arc Agent    │     │  └─ Arc Agent    │
                    └──────────────────┘     └──────────────────┘
```

---

## Glossary of Azure Terms

| Term | What it means |
|---|---|
| **AKS (Azure Kubernetes Service)** | A managed service that runs containers (packaged software). Think of it as a "container orchestra" — it keeps your applications running, restarts them if they crash, and scales them up if needed. |
| **ACR (Azure Container Registry)** | A private library where container images (the software packages) are stored. Like a private app store just for your organization. |
| **App Gateway WAF v2** | A firewall that sits in front of your web applications. It blocks common attack patterns (SQL injection, cross-site scripting, etc.) and checks user identity before allowing traffic through. |
| **Azure Arc** | A management tool that extends Azure's visibility to hardware running outside of Azure (like your store servers). It doesn't move your workloads — it gives you a single pane of glass to see everything. |
| **Entra ID** | Microsoft's identity and access management service (formerly Azure Active Directory). It handles who can log in, with what permissions, and enforces multi-factor authentication. |
| **Event Hubs** | A cloud-based message queue that can receive millions of events per second. Meridius uses it with the Kafka protocol to sync store data to the cloud. |
| **Key Vault** | A secure vault for storing secrets (passwords, API keys, certificates). Access is tightly controlled and audited. |
| **Managed Identity** | A way for Azure services to authenticate to each other without storing any passwords. Azure handles the credentials behind the scenes. |
| **PostgreSQL Flexible Server** | A managed database service. "Managed" means Microsoft handles backups, patches, and high availability — you just use the database. |
| **Private Endpoint** | A network interface that connects your Azure services using a private IP address inside your virtual network, keeping traffic off the public internet. |
| **Solution Template** | An automated deployment recipe (ARM template) that creates all Azure resources in one go. You approve it and Azure builds everything. |
| **VNet (Virtual Network)** | Your private network space in Azure. All your resources communicate inside this network, isolated from others. |

---

