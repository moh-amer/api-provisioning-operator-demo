# Apigee API Operator

A Kubernetes operator that manages **Google Cloud Apigee API proxies** as native Kubernetes custom resources, built using the `client-go` library following the `sample-controller` architecture.

```
kubectl apply -f my-api.yaml  →  Apigee proxy created, deployed & live in ~10s
kubectl delete -f my-api.yaml →  Apigee proxy undeployed & deleted automatically
```

---

## Table of Contents

1. [What You Need (Inputs)](#what-you-need-inputs)
2. [Quick Start — Brand New Cluster](#quick-start--brand-new-cluster)
3. [How Authentication Works](#how-authentication-works)
   - [Option A: Local / kind (ADC — your gcloud login)](#option-a-local--kind-adc--your-gcloud-login)
   - [Option B: Any remote cluster (Workload Identity Federation)](#option-b-any-remote-cluster-workload-identity-federation)
   - [Option C: GKE (Built-in Workload Identity)](#option-c-gke-built-in-workload-identity)
4. [Usage](#usage)
   - [Create an API Proxy](#create-an-api-proxy)
   - [Add Policies to Your API](#add-policies-to-your-api)
   - [Update, Delete, Check Status](#update-an-api-proxy)
5. [CRD Reference](#crd-reference)
6. [Make Targets](#make-targets)
7. [How It Works (Architecture)](#how-it-works-architecture)
8. [Troubleshooting](#troubleshooting)

---

## What You Need (Inputs)

Before you start, collect these **4 values**. Everything else is automated.

| # | Input | Where to find it | Example |
|---|---|---|---|
| 1 | **GCP Project ID** | [GCP Console](https://console.cloud.google.com) → top-left dropdown | `my-project-abc123` |
| 2 | **Apigee Environment name** | [Apigee Console](https://console.cloud.google.com/apigee/environments) → Environments tab | `eval` |
| 3 | **Your `gcloud` login** | Run `gcloud auth login` once | `you@gmail.com` |
| 4 | **A running Kubernetes cluster** | kind (local), GKE, EKS, AKS | `kind-operator-demo` |

> **Apigee prerequisite:** You need an Apigee organization provisioned in your GCP project.
> Go to [console.cloud.google.com/apigee](https://console.cloud.google.com/apigee) and provision
> an **Evaluation** org (free, 60 days) if you don't have one.

---

## Quick Start — Brand New Cluster

Copy-paste this entire block. Replace the two values at the top.

```bash
# ── YOUR INPUTS (only these two lines need changing) ────────────────
export PROJECT_ID="your-gcp-project-id"        # e.g. my-project-abc123
export APIGEE_ENV="eval"                        # e.g. eval, dev, prod
# ────────────────────────────────────────────────────────────────────

# 1. Clone and build
git clone <your-repo-url> apigee-api-operator
cd apigee-api-operator
export PATH=/usr/local/go/bin:$PATH
go build -o apigee-api-operator .

# 2. Log in to Google Cloud (opens browser once)
gcloud auth login
gcloud auth application-default login

# 3. Create a local kind cluster (skip if you already have a cluster)
kind create cluster --name operator-demo

# 4. One-command auth setup (creates GCP SA, grants roles, injects secret)
make setup-auth PROJECT=$PROJECT_ID

# 5. Install CRDs + RBAC into cluster
make install

# 6. Edit the example CR with your project ID
sed -i "s/your-gcp-project-id/$PROJECT_ID/" deploy/examples/hello-api.yaml
sed -i "s/environment: \"eval\"/environment: \"$APIGEE_ENV\"/" deploy/examples/hello-api.yaml

# 7. Start the operator (runs locally, uses your gcloud login)
make run-local &

# 8. Create your first Apigee API proxy via Kubernetes!
kubectl apply -f deploy/examples/hello-api.yaml

# 9. Watch it deploy
kubectl get aapi -w
```

**Expected output in ~15 seconds:**
```
NAME        ORG              ENV    BASEPATH    PHASE      REVISION  DEPLOYED  AGE
hello-api   my-project-id   eval   /k8s-demo                         false     1s
hello-api   my-project-id   eval   /k8s-demo   Creating              false     2s
hello-api   my-project-id   eval   /k8s-demo   Deploying  95         false     4s
hello-api   my-project-id   eval   /k8s-demo   Ready      95         true      12s
```

**Test the live API:**
```bash
curl https://${PROJECT_ID}-${APIGEE_ENV}.apigee.net/k8s-demo/get
```

---

## How Authentication Works

The operator uses **Google Application Default Credentials (ADC)** — the same library used by `gcloud` and all Google Cloud SDKs. Choose the mode that matches your cluster:

### Option A: Local / kind (ADC — your gcloud login)

**Best for:** Local development, kind clusters, demos.
**What it does:** Uses your personal Google account that you logged into with `gcloud`.
**No JSON keys stored anywhere.**

```bash
# One-time login (opens browser)
gcloud auth application-default login

# Set up GCP service account and inject ADC into cluster
make setup-auth PROJECT=your-project-id

# Run operator (it picks up ADC automatically)
make run-local
# OR with explicit path:
GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json \
  ./apigee-api-operator --kubeconfig ~/.kube/config -v=4
```

**What `make setup-auth` does:**
1. Creates GCP Service Account `apigee-operator-sa`
2. Grants it `roles/apigee.environmentAdmin` + `roles/apigee.apiAdmin`
3. Detects your cluster is **not GKE** → falls back to ADC
4. Injects your ADC credentials into cluster as K8s Secret `apigee-sa-key`
5. Cleans up — no JSON key files left on disk

---

### Option B: Any Remote Cluster (Workload Identity Federation)

**Best for:** EKS, AKS, any cluster with a public OIDC endpoint. True keyless auth.
**What it does:** The pod's Kubernetes ServiceAccount token is automatically exchanged for a short-lived GCP access token at runtime. No secrets, no JSON keys anywhere.

```bash
# Auto-detect your cluster's OIDC issuer and configure WIF
make setup-wif PROJECT=your-project-id

# If auto-detection fails, provide the issuer manually:
make setup-wif PROJECT=your-project-id ISSUER=https://oidc.eks.amazonaws.com/id/XXXX

# Deploy with WIF support (uses projected SA token volume)
make deploy-wif
```

**What `make setup-wif` does:**
1. Creates GCP Service Account + grants roles
2. Creates a **Workload Identity Pool** in GCP (`apigee-operator-pool`)
3. Registers your cluster's OIDC issuer as a trusted provider
4. Creates an IAM binding: K8s SA `apigee-api-operator` → GCP SA (via the pool)
5. Generates a `credentials.json` **config** (not a key) and stores it as a K8s ConfigMap
6. The pod mounts a projected K8s SA token + this config → ADC does the rest automatically

**How to find your cluster OIDC issuer:**
```bash
# Auto-detect (works on most clusters)
kubectl get --raw /.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"

# EKS
aws eks describe-cluster --name CLUSTER_NAME --query 'cluster.identity.oidc.issuer'

# AKS
az aks show -n CLUSTER_NAME -g RESOURCE_GROUP --query 'oidcIssuerProfile.issuerUrl'
```

---

### Option C: GKE (Built-in Workload Identity)

**Best for:** Production deployments on GKE. Automatic, natively integrated.
**What it does:** Annotates the K8s ServiceAccount to transparently map to the GCP SA. No extra volumes or config needed.

```bash
make setup-wif-gke PROJECT=your-project-id
make deploy
```

---

## Authentication Quick Reference

```
Your Cluster            Command                              How it authenticates
──────────────────────────────────────────────────────────────────────────────────
kind (local demo)       make setup-auth PROJECT=xxx          ADC (your gcloud login)
                        make run-local

Any cluster (EKS/AKS)  make setup-wif PROJECT=xxx           WIF — projected K8s token
                        make deploy-wif                      exchanged for GCP token

GKE                     make setup-wif-gke PROJECT=xxx       Workload Identity (built-in)
                        make deploy
──────────────────────────────────────────────────────────────────────────────────
```

---

## Usage

### Create an API Proxy

```yaml
# my-api.yaml
apiVersion: apigee.example.com/v1alpha1
kind: ApigeeAPI
metadata:
  name: hello-api
  namespace: default
spec:
  organization: "your-gcp-project-id"    # ← Your GCP project ID
  environment: "eval"                    # ← Your Apigee environment
  basePath: "/hello"                     # ← Must start with /
  targetUrl: "https://httpbin.org"       # ← Backend your proxy routes to
  description: "My K8s-managed API"     # ← Optional
```

```bash
kubectl apply -f my-api.yaml
kubectl get aapi -w           # Watch phases: Creating → Deploying → Ready
```

### Add Policies to Your API

Declare policies in `spec.policies[]`. They run in the Apigee ProxyEndpoint **PreFlow Request**
in declaration order, after the built-in `StripBasePath` policy.

#### Rate limiting (SpikeArrest + Quota)

```yaml
spec:
  organization: "my-project"
  environment: "eval"
  basePath: "/limited"
  targetUrl: "https://httpbin.org"
  policies:
    - type: SpikeArrest
      config:
        rate: "30pm"       # max 30 req/min (burst smoothing)
    - type: Quota
      config:
        allow: "1000"
        interval: "1"
        timeUnit: "day"    # 1000 req/day hard cap
```

```bash
kubectl apply -f deploy/examples/rate-limited-api.yaml
```

#### API Key authentication

```yaml
spec:
  policies:
    - type: VerifyAPIKey
      config:
        apiKeyLocation: "queryparam"   # read key from ?apikey=xxx
        apiKeyName: "apikey"
    - type: SpikeArrest
      config:
        rate: "10ps"                   # 10 req/sec after key verified
```

```bash
# Without key → 401
curl https://YOUR_HOSTNAME/secure/get

# With valid key → 200
curl "https://YOUR_HOSTNAME/secure/get?apikey=YOUR_KEY"
```

#### CORS headers

```yaml
spec:
  policies:
    - type: CORS
      config:
        allowOrigins: "https://app.example.com"
        allowMethods: "GET,POST,DELETE"
        allowHeaders: "Content-Type,Authorization"
```

#### OAuth2 token verification

```yaml
spec:
  policies:
    - type: OAuthV2    # validates Bearer token in Authorization header
```

> **Policy ordering matters.** Policies run in the order declared.
> Auth policies (`VerifyAPIKey`, `OAuthV2`) should come before rate-limit policies.


Edit the spec (e.g. change `targetUrl`) and re-apply. The operator detects the change via `metadata.generation` and uploads a new Apigee revision automatically.

```bash
kubectl apply -f my-api.yaml
# → New revision created and deployed, status updates to Ready
```

### Delete an API Proxy (with Finalizer cleanup)

```bash
kubectl delete apigeeapi hello-api
```

**The operator's Finalizer guarantees:**
1. Undeploys the proxy from the Apigee environment
2. Deletes the proxy bundle from Apigee
3. Only then removes the K8s object

The Apigee resource is never orphaned.

### Check Status

```bash
# Summary table
kubectl get aapi

# Full status
kubectl describe apigeeapi hello-api

# Just the public URL
kubectl get apigeeapi hello-api -o jsonpath='{.status.publicUrl}'

# All status fields as JSON
kubectl get apigeeapi hello-api -o json | python3 -m json.tool | grep -A20 '"status"'
```

---

## CRD Reference

### Spec Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `organization` | string | ✅ | GCP project ID (this is your Apigee org for Apigee X) |
| `environment` | string | ✅ | Apigee environment (`eval`, `dev`, `prod`) |
| `basePath` | string | ✅ | URL path prefix — must start with `/` |
| `targetUrl` | string | ✅ | Backend URL — must start with `http://` or `https://` |
| `proxyName` | string | ❌ | Custom proxy name. Defaults to the CR name |
| `description` | string | ❌ | Free-text description shown in the Apigee console |
| `policies` | []PolicySpec | ❌ | Ordered list of Apigee policies. See [Policy Reference](#policy-reference) |

### Policy Reference

Each item in `spec.policies[]` has:

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | ✅ | `Quota`, `SpikeArrest`, `VerifyAPIKey`, `CORS`, or `OAuthV2` |
| `name` | string | ❌ | Instance name in Apigee. Defaults to `{Type}-{index}`. Must be unique. |
| `config` | map[string]string | ❌ | Policy-specific key-value config. See table below. |

**Config keys by policy type:**

| Type | Key | Default | Description |
|---|---|---|---|
| `Quota` | `allow` | `"1000"` | Max requests per interval |
| `Quota` | `interval` | `"1"` | Interval count |
| `Quota` | `timeUnit` | `"minute"` | `minute` \| `hour` \| `day` \| `month` |
| `SpikeArrest` | `rate` | `"30pm"` | `Nps` (per sec) or `Npm` (per min), e.g. `"10ps"`, `"100pm"` |
| `VerifyAPIKey` | `apiKeyLocation` | `"queryparam"` | `queryparam` \| `header` |
| `VerifyAPIKey` | `apiKeyName` | `"apikey"` | Query param name or header name |
| `CORS` | `allowOrigins` | `"*"` | Allowed origin. Use `"*"` for any, or specific domain. |
| `CORS` | `allowMethods` | `"GET,POST,PUT,DELETE,OPTIONS"` | Comma-separated HTTP methods |
| `CORS` | `allowHeaders` | `"Content-Type,Authorization"` | Comma-separated allowed headers |
| `OAuthV2` | _(none)_ | — | Always runs `VerifyAccessToken` operation |

> Unknown policy types are **skipped with a log warning** — the proxy still deploys without that policy.

### Status Fields

| Field | Type | Description |
|---|---|---|
| `phase` | string | `Creating` → `Deploying` → `Ready` (or `Error`, `Deleting`) |
| `deployed` | bool | `true` when the proxy is active in the environment |
| `proxyRevision` | int | Currently deployed revision number |
| `publicUrl` | string | Live endpoint (e.g. `https://org-eval.apigee.net/hello`) |
| `message` | string | Human-readable description of the current state |
| `observedGeneration` | int64 | The spec generation last successfully reconciled — prevents redeployment loops |

### Short Names

```bash
kubectl get apigeeapis    # full name
kubectl get aapi          # short alias
```

---

## Make Targets

```bash
make help                                  # List all targets

# ── Auth Setup ────────────────────────────────────────
make setup-auth PROJECT=my-project         # Auto-detect (kind → ADC, GKE → WI)
make setup-wif  PROJECT=my-project         # WIF for any cluster (auto-detect OIDC)
make setup-wif  PROJECT=my-project ISSUER=https://...   # WIF with explicit issuer
make setup-wif-gke  PROJECT=my-project     # GKE Workload Identity
make setup-wif-kind PROJECT=my-project     # kind cluster (ADC fallback)

# ── Build ─────────────────────────────────────────────
make build                                 # Compile binary
make docker-build                          # Build Docker image

# ── Cluster ───────────────────────────────────────────
make kind-create                           # Create kind cluster
make install                               # Install CRDs + RBAC only
make deploy                                # Full deploy to kind cluster
make deploy-wif                            # Deploy with WIF-enabled manifest
make run-local                             # Run binary locally (uses your ADC)

# ── Demo ──────────────────────────────────────────────
make demo                                  # Apply hello-api and watch
make demo-full PROJECT=my-project          # End-to-end: kind → auth → deploy → demo

# ── Cleanup ───────────────────────────────────────────
make undeploy                              # Remove operator from cluster
make delete-apis                           # Delete all ApigeeAPI CRs (runs finalizers)
make kind-delete                           # Destroy kind cluster
```

---

## How It Works (Architecture)

### Flow

```
kubectl apply hello-api.yaml
        │
        ▼
   K8s API Server stores ApigeeAPI CR
        │
        ▼
   SharedIndexInformer (watches ApigeeAPI)
        │ AddFunc triggered
        ▼
   RateLimiting Workqueue
        │
        ▼
   syncHandler()
        │
        ├── [First time] Add Finalizer ──→ re-enqueue (finalizerAdded trigger)
        │
        ├── [Idempotency guard] Already Ready + same generation? → skip ✓
        │
        ├── Call Apigee REST API:
        │     POST /organizations/{org}/apis?action=import   (upload ZIP bundle)
        │     POST .../environments/{env}/apis/{name}/revisions/{rev}/deployments
        │
        └── UpdateStatus → phase=Ready, deployed=true, observedGeneration=generation
```

### Key Design Decisions

| Decision | Reason |
|---|---|
| **Finalizers** (not OwnerReferences) | Apigee proxies are external resources — K8s GC can't touch them |
| **1 Informer** (not 4 like StaticSite) | No K8s child resources to watch — only the CRD itself |
| **`observedGeneration`** in status | Prevents redeployment loops — operator skips if already reconciled |
| **`UpdateFunc` generation filter** | Status writes don't bump generation → no spurious re-syncs |
| **`liveGet` + `RetryOnConflict`** | Avoids stale resourceVersion conflicts on concurrent writes |
| **In-memory ZIP bundle** | No filesystem needed — proxy XML generated in Go at runtime |
| **ADC via `google.FindDefaultCredentials`** | Works transparently with WIF, SA keys, local gcloud login |

---

## Troubleshooting

### Operator not deploying after CR is created
The finalizer logic now correctly re-enqueues after the finalizer is added (`finalizerAdded` trigger in `UpdateFunc`). If you upgraded from an older build, restart the operator.

### Operator keeps redeploying to Apigee in a loop
Fixed via two mechanisms:
1. `UpdateFunc` only re-queues on generation change or deletion
2. `observedGeneration` guard in `syncHandler` skips already-reconciled CRs

Verify with:
```bash
kubectl get apigeeapi hello-api -o json | python3 -c \
  "import sys,json; d=json.load(sys.stdin); s=d['status']; \
   print('OK' if s.get('observedGeneration')==d['metadata']['generation'] else 'BUG')"
```

### `FAILED_PRECONDITION: Key creation is not allowed`
Org policy blocks SA JSON key creation. The `setup-auth.sh` script automatically falls back to your ADC user credentials. Use `make setup-wif` for a fully keyless alternative.

### `unknown field "status.observedGeneration"` warning
Apply the updated CRD schema:
```bash
kubectl apply -f deploy/01-crd.yaml
```

### CR stuck in `Terminating`
Force-remove the finalizer (this will **not** clean up Apigee — do it manually in the console):
```bash
kubectl patch apigeeapi NAME -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### Check operator is authenticated correctly
```bash
# Verify your ADC is set up
gcloud auth application-default print-access-token | head -c 20

# Verify Apigee is accessible
gcloud apigee apis list --organization=YOUR_PROJECT_ID
```
