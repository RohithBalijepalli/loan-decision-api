# 🚀 Execution Guide — Loan Decision API

Complete step-by-step guide to deploy, run with GitHub Actions,
and validate against the AWS Well-Architected Framework.

---

## Prerequisites Checklist

Before you start, make sure you have:

- [ ] AWS account with admin access
- [ ] AWS CLI installed and configured (`aws configure`)
- [ ] Terraform >= 1.7 installed
- [ ] Python 3.12 installed
- [ ] Git installed
- [ ] GitHub account
- [ ] Bedrock Claude 3 Sonnet enabled in us-east-1

Enable Bedrock model access:
```
AWS Console → Amazon Bedrock → Model access → Request access → Claude 3 Sonnet → Save
```
Wait ~2 minutes for activation.

---

## Part 1 — Local Setup (15 min)

### 1.1 Create GitHub repo

```bash
# On GitHub: create new repo named "loan-decision-api" (public)
# Then locally:
git clone https://github.com/YOUR_USERNAME/loan-decision-api
cd loan-decision-api
```

### 1.2 Copy project files into the repo

Copy all files from the ZIP into this directory, keeping the folder structure.

### 1.3 Verify structure

```bash
find . -type f | grep -v ".git" | sort
```

Expected output:
```
./.github/workflows/deploy.yml
./.gitignore
./README.md
./scripts/bootstrap-oidc.sh
./src/lambda/handler.py
./src/tests/test_handler.py
./terraform/main.tf
./terraform/modules/api_gateway/main.tf
./terraform/modules/bedrock_iam/main.tf
./terraform/modules/dynamodb/main.tf
./terraform/modules/lambda/main.tf
./terraform/modules/monitoring/main.tf
./terraform/modules/waf/main.tf
./terraform/outputs.tf
./terraform/terraform.tfvars.example
./terraform/variables.tf
./docs/test_payloads.json
```

---

## Part 2 — Bootstrap AWS for GitHub Actions (20 min)

This creates the OIDC trust between GitHub and AWS.
You only do this once.

### 2.1 Edit the bootstrap script

```bash
# Open scripts/bootstrap-oidc.sh
# Edit lines 10-11:
GITHUB_ORG="your-actual-github-username"
GITHUB_REPO="loan-decision-api"
```

### 2.2 Run bootstrap

```bash
chmod +x scripts/bootstrap-oidc.sh
./scripts/bootstrap-oidc.sh
```

Expected output at the end:
```
✅ Bootstrap complete!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Add these as GitHub Secrets in your repo:

  AWS_ROLE_ARN       = arn:aws:iam::123456789012:role/github-actions-loan-api-role
  TF_STATE_BUCKET    = loan-api-tf-state-123456789012
  TF_LOCK_TABLE      = loan-api-tf-lock
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 2.3 Add GitHub Secrets

Go to: `GitHub repo → Settings → Secrets and variables → Actions → New repository secret`

Add these 3 secrets:
| Secret Name | Value |
|---|---|
| `AWS_ROLE_ARN` | The ARN from bootstrap output |
| `TF_STATE_BUCKET` | The bucket name from bootstrap output |
| `TF_LOCK_TABLE` | `loan-api-tf-lock` |

---

## Part 3 — Run Tests Locally First (10 min)

Always confirm tests pass before pushing.

```bash
cd src
pip install pytest pytest-cov boto3 moto
pytest tests/ -v --cov=lambda --cov-report=term-missing
```

Expected output:
```
tests/test_handler.py::TestValidateInput::test_valid_payload_passes PASSED
tests/test_handler.py::TestValidateInput::test_missing_applicant_raises PASSED
tests/test_handler.py::TestValidateInput::test_negative_income_raises PASSED
tests/test_handler.py::TestBuildPrompt::test_prompt_contains_dti PASSED
tests/test_handler.py::TestParseDecision::test_parses_clean_json PASSED
tests/test_handler.py::TestParseDecision::test_strips_markdown_fences PASSED
tests/test_handler.py::TestLambdaHandler::test_successful_approval PASSED
tests/test_handler.py::TestLambdaHandler::test_bad_payload_returns_400 PASSED

---------- coverage: lambda/handler.py ----------
TOTAL    94    18    81%

8 passed in 3.42s ✅
```

---

## Part 4 — First Deploy via GitHub Actions (30 min)

### 4.1 Push to develop branch (deploys to dev)

```bash
git checkout -b develop
git add .
git commit -m "feat: initial loan decision API"
git push origin develop
```

### 4.2 Watch the pipeline run

Go to: `GitHub repo → Actions tab`

You will see 3 jobs running in sequence:

```
🧪 Test Lambda         → running...
🔍 Terraform Lint      → running...
        ↓ (both must pass)
🚀 Deploy → Dev        → running...
```

Click on "Deploy → Dev" to watch live logs.

### 4.3 What each job does

**🧪 Test Lambda (2-3 min)**
```
✓ Set up Python 3.12
✓ Install pytest, moto, boto3
✓ Run 8 unit tests
✓ Coverage: 81%
✓ Upload coverage artifact
```

**🔍 Terraform Lint (2-3 min)**
```
✓ terraform fmt -check    ← fails if formatting is wrong
✓ terraform init -backend=false
✓ terraform validate      ← catches syntax errors
✓ tfsec scan              ← security issues (warnings only)
```

**🚀 Deploy → Dev (5-8 min)**
```
✓ Configure AWS via OIDC  ← no access keys, secure
✓ terraform init          ← downloads providers, connects to S3 backend
✓ terraform apply         ← creates all 15 AWS resources
✓ Smoke test              ← hits the live endpoint to verify 200 response
```

### 4.4 Expected final output in GitHub Actions logs

```
Apply complete! Resources: 15 added, 0 changed, 0 destroyed.

Outputs:

api_endpoint = "https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev"
api_key_id   = "a1b2c3d4e5"
lambda_function_name = "loan-decision-api-dev-evaluator"
dynamodb_table_name  = "loan-decisions"

Testing endpoint: https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev
Response status: 200
✅ Smoke test passed
```

---

## Part 5 — Test the Live API (10 min)

### 5.1 Get your API key value

```bash
# Get the key ID from Terraform output
cd terraform
terraform output api_key_id
# Output: a1b2c3d4e5

# Get the actual key value
aws apigateway get-api-key \
  --api-key a1b2c3d4e5 \
  --include-value \
  --query value \
  --output text
# Output: AbCdEf123456789...
```

### 5.2 Test all 3 scenarios

**Test 1 — Strong Approve**
```bash
curl -X POST https://YOUR_ENDPOINT/dev/loan/evaluate \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "applicant": {
      "name": "Sarah Johnson",
      "annual_income": 120000,
      "monthly_debt": 500,
      "employment_years": 8,
      "credit_history": "Excellent. 780 score, no defaults, two paid-off auto loans."
    },
    "loan": { "amount": 30000, "term_months": 60, "purpose": "Home renovation" }
  }'
```

Expected response:
```json
{
  "request_id": "f3a2b1c0-4e5f-6g7h-8i9j-0k1l2m3n4o5p",
  "timestamp": "2024-11-15T14:32:00Z",
  "decision": "APPROVE",
  "risk_score": 22,
  "confidence": "HIGH",
  "reasoning": "Applicant demonstrates strong financial profile with estimated DTI of 27%, well within acceptable limits. Eight years of stable employment and excellent credit history strongly support approval.",
  "risk_factors": ["No collateral mentioned"],
  "recommended_conditions": []
}
```

**Test 2 — Clear Deny**
```bash
curl -X POST https://YOUR_ENDPOINT/dev/loan/evaluate \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "applicant": {
      "name": "Mike Torres",
      "annual_income": 32000,
      "monthly_debt": 1800,
      "employment_years": 0,
      "credit_history": "Recent default 4 months ago. Two open collections."
    },
    "loan": { "amount": 45000, "term_months": 36, "purpose": "Debt consolidation" }
  }'
```

Expected response:
```json
{
  "decision": "DENY",
  "risk_score": 87,
  "confidence": "HIGH",
  "reasoning": "Application presents multiple high-risk indicators: DTI exceeds 91% including proposed loan, recent default within 6 months, zero employment tenure, and open collections accounts.",
  "risk_factors": ["DTI > 90%", "Recent default", "No employment history", "Open collections"],
  "recommended_conditions": []
}
```

**Test 3 — Borderline Review**
```bash
curl -X POST https://YOUR_ENDPOINT/dev/loan/evaluate \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "applicant": {
      "name": "Priya Patel",
      "annual_income": 68000,
      "monthly_debt": 1200,
      "employment_years": 3,
      "credit_history": "One late payment 18 months ago. Student loans current.",
      "notes": "Self-employed consultant"
    },
    "loan": { "amount": 20000, "term_months": 48, "purpose": "Business equipment" }
  }'
```

Expected response:
```json
{
  "decision": "REVIEW",
  "risk_score": 48,
  "confidence": "MEDIUM",
  "reasoning": "Variable self-employment income introduces uncertainty despite moderate DTI. Single late payment within 2 years and business-purpose loan warrant human review.",
  "risk_factors": ["Variable self-employment income", "Late payment within 24 months"],
  "recommended_conditions": ["Provide 2 years tax returns", "Verify business revenue"]
}
```

### 5.3 Verify audit trail in DynamoDB

```bash
aws dynamodb scan \
  --table-name loan-decisions \
  --region us-east-1 \
  --query "Items[*].{ID:request_id.S, Decision:decision.S, Score:risk_score.N, Time:timestamp.S}" \
  --output table
```

Expected output:
```
----------------------------------------------------------------------------------
|                                     Scan                                       |
+--------------------------------------+----------+-------+----------------------+
| ID                                   | Decision | Score | Time                 |
+--------------------------------------+----------+-------+----------------------+
| f3a2b1c0-4e5f-...                   | APPROVE  | 22    | 2024-11-15T14:32:00Z |
| a1b2c3d4-5e6f-...                   | DENY     | 87    | 2024-11-15T14:33:12Z |
| 9g8h7i6j-5k4l-...                   | REVIEW   | 48    | 2024-11-15T14:34:45Z |
+--------------------------------------+----------+-------+----------------------+
```

---

## Part 6 — Well-Architected Framework Validation

The AWS WAF has 6 pillars. Here's how this project addresses each one:

### ✅ Operational Excellence
- GitHub Actions automates deploy, test, and smoke test on every push
- CloudWatch dashboard gives single-pane-of-glass visibility
- Structured JSON logging in Lambda (queryable via CloudWatch Insights)
- X-Ray tracing gives end-to-end latency breakdown

Verify in console:
```
CloudWatch → Dashboards → loan-decision-api-dev
```

### ✅ Security
- OIDC auth for GitHub Actions — zero long-lived IAM keys
- IAM role scoped to specific Bedrock model ARN (not `bedrock:*`)
- API Gateway requires API key on every request
- WAF blocks SQLi, XSS, known bad inputs, and rate-limits per IP
- DynamoDB encrypted at rest (SSE enabled)
- S3 Terraform state bucket: versioned, encrypted, public access blocked

### ✅ Reliability
- Lambda is inherently multi-AZ — no single point of failure
- DynamoDB PAY_PER_REQUEST scales to any load automatically
- CloudWatch alarms page on Lambda errors and API 5xx spikes
- Point-in-time recovery enabled on DynamoDB

### ✅ Performance Efficiency
- Lambda right-sized at 512MB (enough for Bedrock call, not wasteful)
- API Gateway throttled to 5 req/sec (loan eval is not a high-frequency op)
- CloudWatch p95/p99 duration alarm — catches Bedrock latency regressions early

### ✅ Cost Optimization
- PAY_PER_REQUEST everywhere — zero idle cost
- Lambda billed per 100ms — typical Bedrock call costs ~$0.002
- DynamoDB TTL on dev records — auto-cleans after 90 days
- No NAT gateway, no VPC (not needed for public Bedrock endpoint)

### ✅ Sustainability
- Serverless = zero compute waste when idle
- No always-on EC2 instances or RDS clusters
- Lambda scales to zero between requests

---

## Part 7 — Deploy to Prod (PR flow)

```bash
# Create PR from develop → main
git checkout main
git merge develop
git push origin main
```

GitHub will:
1. Run tests + lint
2. Pause at "Deploy → Prod" and wait for manual approval
3. You approve in GitHub UI → deploy runs
4. Auto-tags the release with a timestamp

---

## Cleanup

```bash
cd terraform
terraform destroy -var="environment=dev"
# Type "yes" when prompted

# Also delete bootstrap resources if done:
aws s3 rb s3://loan-api-tf-state-ACCOUNT_ID --force
aws dynamodb delete-table --table-name loan-api-tf-lock
```

---

## What to Screenshot for LinkedIn

1. GitHub Actions → green pipeline with all 3 jobs passing
2. The APPROVE JSON response in terminal
3. DynamoDB table with 3 different decision types
4. CloudWatch Dashboard showing metrics
5. The architecture diagram (draw it in Excalidraw or Lucidchart)
