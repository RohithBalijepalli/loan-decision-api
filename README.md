# 🏦 Intelligent Loan Decision API

> A serverless, AI-powered loan pre-screening API built on AWS. Uses Claude 3 Sonnet via Amazon Bedrock to evaluate loan applications with explainable risk reasoning — fully provisioned with Terraform.

---

## Architecture

```
Client Request
     │
     ▼
API Gateway (REST + API Key auth)
     │
     ▼
Lambda (Python 3.12)
     │         │
     ▼         ▼
 Bedrock    DynamoDB
 (Claude)   (Audit Log)
```

**AWS Services Used:**
- **API Gateway** — REST API with API key auth and throttling
- **Lambda** — Stateless evaluator function (Python 3.12)
- **Amazon Bedrock** — Claude 3 Sonnet for AI risk reasoning
- **DynamoDB** — Immutable audit trail of all decisions (banking compliance)
- **CloudWatch** — Structured logs + error rate alarms
- **IAM** — Least-privilege roles (Bedrock invoke scoped to specific model)
- **X-Ray** — Distributed tracing across API Gateway and Lambda

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
- Bedrock model access enabled in us-east-1 (Claude 3 Sonnet)

### Enable Bedrock Access

Before deploying, enable model access in AWS Console:
```
AWS Console → Amazon Bedrock → Model access → Enable "Claude 3 Sonnet"
```

### Deploy

```bash
# 1. Clone and enter project
git clone https://github.com/yourusername/loan-decision-api
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
[LinkedIn](https://linkedin.com/in/yourprofile) · [GitHub](https://github.com/yourusername)
