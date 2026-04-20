# Intelligent Loan Decision API

> A serverless, AI-powered loan pre-screening API built on AWS. Uses Claude Sonnet 4.6 via Amazon Bedrock to evaluate loan applications with explainable risk reasoning — fully provisioned with Terraform and deployed via GitHub Actions CI/CD.

---

## Architecture

```mermaid
flowchart TD
    Client(["🏦 Bank LOS / API Consumer"])

    subgraph GitHub["GitHub"]
        GHA["⚙️ GitHub Actions\nCI/CD Pipeline\nOIDC Keyless Auth"]
    end

    subgraph AWS["AWS — us-east-1"]

        subgraph Security["Security Layer"]
            WAF["🛡️ AWS WAFv2\nSQLi · XSS · Rate Limit\n100 req / 5 min / IP"]
        end

        subgraph API["API Layer"]
            APIGW["🔌 API Gateway\nREST · API Key Auth\n5 req/sec · 1k/month quota\nX-Ray Tracing"]
        end

        subgraph Compute["Compute Layer"]
            LAMBDA["λ Lambda\nPython 3.12 · 512MB · 30s\n1. Validate input\n2. Calculate DTI\n3. Build prompt\n4. Call Bedrock\n5. Save audit record"]
        end

        subgraph AI["AI Layer"]
            BEDROCK["🤖 Amazon Bedrock\nClaude Sonnet 4.6\nCross-Region Inference\nStructured JSON output"]
        end

        subgraph Storage["Storage Layer"]
            DYNAMO["🗄️ DynamoDB\nloan-decisions table\nPK: request_id\nGSI: decision + timestamp\nPITR · TTL · SSE"]
        end

        subgraph Observability["Observability"]
            CW["📊 CloudWatch\nLogs · Alarms · Dashboard\np95 latency · Error rate\n5xx alerts"]
            XRAY["🔍 X-Ray\nDistributed Tracing\nAPI GW → Lambda → Bedrock"]
            SNS["🔔 SNS\nEmail Alerts\nOn alarm breach"]
        end

        subgraph IAM["Identity & Access"]
            ROLE["🔐 Lambda IAM Role\nbedrock:InvokeModel\n→ claude-sonnet-4-6 only\ndynamodb:PutItem/Query\n→ loan-decisions only"]
        end

        subgraph TFState["Terraform State"]
            S3["🪣 S3 Bucket\nTerraform State\nVersioned · Encrypted"]
            LOCK["🔒 DynamoDB\nState Lock Table"]
        end
    end

    Client -->|"POST /loan/evaluate\nx-api-key header"| WAF
    WAF -->|"✅ Passes rules"| APIGW
    WAF -->|"❌ Block SQLi · XSS · Rate limit"| Client
    APIGW -->|"API Key valid\nAWS_PROXY"| LAMBDA
    LAMBDA -->|"InvokeModel\nClaude Sonnet 4.6"| BEDROCK
    BEDROCK -->|"JSON decision\nrisk_score · reasoning"| LAMBDA
    LAMBDA -->|"PutItem\nFull audit record"| DYNAMO
    LAMBDA -->|"HTTP 200\ndecision + reasoning"| Client
    LAMBDA -->|"Logs · Metrics"| CW
    LAMBDA -->|"Trace segments"| XRAY
    CW -->|"Alarm breach"| SNS
    ROLE -.->|"Assumed by"| LAMBDA
    GHA -->|"OIDC token\nterraform apply"| AWS
    GHA -->|"State read/write"| S3
    GHA -->|"Lock acquire"| LOCK

    style Client fill:#FF9900,color:#000
    style WAF fill:#DD344C,color:#fff
    style APIGW fill:#8C4FFF,color:#fff
    style LAMBDA fill:#FF9900,color:#000
    style BEDROCK fill:#01A88D,color:#fff
    style DYNAMO fill:#3F48CC,color:#fff
    style CW fill:#E7157B,color:#fff
    style XRAY fill:#E7157B,color:#fff
    style SNS fill:#E7157B,color:#fff
    style ROLE fill:#DD344C,color:#fff
    style S3 fill:#3F48CC,color:#fff
    style LOCK fill:#3F48CC,color:#fff
    style GHA fill:#24292E,color:#fff
```

**AWS Services Used:**
- **WAFv2** — SQLi/XSS protection + IP rate limiting (100 req / 5 min)
- **API Gateway** — REST API with API key auth, throttling, X-Ray tracing
- **Lambda** — Stateless evaluator function (Python 3.12, 512MB)
- **Amazon Bedrock** — Claude Sonnet 4.6 via cross-region inference profile
- **DynamoDB** — Immutable audit trail with GSI for compliance queries
- **CloudWatch** — Structured logs, 4 alarms, operational dashboard
- **X-Ray** — Distributed tracing across API Gateway → Lambda → Bedrock
- **SNS** — Email alerts on alarm breach
- **IAM** — Least-privilege role scoped to specific model ARN and table
- **S3 + DynamoDB** — Terraform remote state + state locking
- **GitHub Actions** — OIDC keyless CI/CD (no stored AWS credentials)

---

## Why This Architecture

This is a **regulated financial services pattern**. Design decisions were intentional:

| Decision | Reason |
|---|---|
| API Key auth | Simulates internal service auth in a banking environment |
| DynamoDB audit log | Regulatory requirement — every decision must be traceable |
| Throttle: 5 req/sec | Loan evaluation is not a high-frequency operation; prevents abuse |
| Bedrock over direct API | Keeps data inside AWS boundary — critical for financial data compliance |
| PAY_PER_REQUEST DynamoDB | Unpredictable traffic pattern for loan submissions |
| X-Ray tracing | Latency debugging across the async Bedrock call chain |

---

## Request / Response

### POST `/loan/evaluate`

**Headers:**
```
Content-Type: application/json
x-api-key: <your-api-key>
```

**Request Body:**
```json
{
  "applicant": {
    "name": "Jane Smith",
    "annual_income": 85000,
    "monthly_debt": 800,
    "employment_years": 5,
    "credit_history": "Good standing, no defaults, 2 credit cards paid on time",
    "notes": "Stable government employment"
  },
  "loan": {
    "amount": 25000,
    "term_months": 60,
    "purpose": "Home renovation"
  }
}
```

**Response:**
```json
{
  "request_id": "f3a2b1c0-...",
  "timestamp": "2024-11-15T14:32:00Z",
  "decision": "APPROVE",
  "risk_score": 28,
  "confidence": "HIGH",
  "reasoning": "Applicant demonstrates stable income with a DTI of 34% including the proposed loan, well within acceptable range. Five years of continuous employment and clean credit history support approval.",
  "risk_factors": ["Self-reported credit history only", "No asset collateral mentioned"],
  "recommended_conditions": []
}
```

**Decision values:** `APPROVE` | `DENY` | `REVIEW`

---

## Getting Started

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Python 3.12
- Bedrock model access enabled in us-east-1 (Claude Sonnet 4.6)

### Enable Bedrock Access

Claude Sonnet 4.6 activates automatically on first invocation. No manual steps needed — AWS Marketplace subscription is triggered on first use.

### Deploy

```bash
# 1. Clone and enter project
git clone https://github.com/RohithBalijepalli/loan-decision-api
cd loan-decision-api

# 2. Configure variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Init and deploy
cd terraform
terraform init
terraform plan
terraform apply

# 4. Get your API endpoint and key
terraform output api_endpoint
# Get API key value from AWS Console → API Gateway → API Keys
```

### Test

```bash
# Use the generated curl from outputs
terraform output curl_example

# Or run against all test cases manually using docs/test_payloads.json
```

---

## Project Structure

```
loan-decision-api/
├── terraform/
│   ├── main.tf                    # Root module
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── api_gateway/           # REST API + throttling + API key
│       ├── lambda/                # Function + CloudWatch alarm + X-Ray
│       ├── bedrock_iam/           # Least-privilege IAM role
│       └── dynamodb/              # Audit table + GSI + encryption
├── src/
│   └── lambda/
│       └── handler.py             # Core evaluation logic
└── docs/
    └── test_payloads.json         # 3 test cases: approve, deny, review
```

---

## What I Learned / Engineering Notes

- **Bedrock response parsing**: Claude returns clean JSON when system prompt is strict, but defensive parsing is still necessary for edge cases
- **DTI calculation**: Estimated monthly payment (amount / term) is included in DTI — same approach real underwriters use
- **Audit trail design**: Using `request_id` as DynamoDB hash key with `decision` GSI allows querying all denials — useful for bias auditing
- **IAM scoping**: Bedrock invoke permission is scoped to the specific model ARN, not `bedrock:*` — principle of least privilege matters in financial contexts
- **Throttle rationale**: 5 req/sec is intentional — loan applications are low-volume, high-value. A burst of 100 req/sec would signal abuse or a runaway process

---

## Cleanup

```bash
cd terraform
terraform destroy
```

---

## Author

**Rohit Balijepalli** — Software Engineer  
AWS Certified Solutions Architect | Popular Bank  
[LinkedIn](www.linkedin.com/in/rohit-balijepalli) · [GitHub](https://github.com/RohithBalijepalli)
