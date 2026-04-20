# Architecture — Loan Decision API

## What This System Does (In Plain English)

A bank or fintech receives thousands of loan applications — personal loans, auto loans, home improvement financing. Each application needs a credit risk decision: approve it, deny it, or flag it for a human underwriter to review.

Traditionally this involves a loan officer manually reviewing the application, pulling credit bureau data, and applying institutional underwriting rules. That process takes hours or days, costs staff time, and introduces human inconsistency.

This system automates the **pre-screening layer**. When a loan application comes in, the API evaluates the applicant's financial profile in under 5 seconds and returns a structured decision with full reasoning — which risk factors triggered the outcome, what confidence level the model has, and any conditions the bank should attach before funding.

The human underwriter still makes the final call, but they now receive a pre-analyzed application with a risk score, a narrative explanation, and a recommended decision — instead of starting from a blank page.

---

## Real-World Integration Scenario

```
Bank's Loan Origination System (LOS)
           │
           │  POST /loan/evaluate
           │  x-api-key: <service-account-key>
           ▼
    ┌─────────────────────────────────────────────────────────┐
    │                  THIS API                               │
    │                                                         │
    │ WAF → API Gateway → Lambda → Bedrock(Claude) → DynamoDB │
    └─────────────────────────────────────────────────────────┘
           │
           │  { decision, risk_score, reasoning, risk_factors }
           ▼
    Bank's Underwriting Dashboard
    (Loan officer reviews AI recommendation + full reasoning)
```

In practice, the bank's Loan Origination System (Encompass, nCino, or a custom internal system) calls this API the moment an applicant submits their application online. The response feeds directly into the underwriter's queue — pre-scored, pre-reasoned, ready for human review or straight-through processing on clear approvals.

---

## Full Architecture — Layer by Layer

### Layer 1: WAF (Web Application Firewall)

The outermost security layer. Every HTTP request hits WAF before anything else in AWS sees it.

**What it does:**
- Blocks SQL injection and cross-site scripting attempts
- Blocks known exploit patterns (Log4Shell, path traversal, Spring4Shell)
- Rate-limits any single IP address to 100 requests per 5 minutes — hard block after that

**Why it matters in financial services:**  
Loan APIs are targets. A competitor, fraudster, or bot could attempt to probe the system with crafted payloads to extract decision logic, or flood the endpoint to drive up AWS costs. WAF stops both.

---

### Layer 2: API Gateway

The front door for legitimate traffic that clears WAF.

**Authentication:** Every request must include `x-api-key` in the header. API Gateway validates the key before touching Lambda. No key = 403, no exceptions.

**Throttling (Usage Plan):**
- 5 requests/second sustained
- 10 request burst
- 1,000 requests/month quota

This is intentional design. Loan evaluation is a low-volume, high-value operation. A legitimate bank LOS sending 5 applications per second is already processing 18,000 applications per hour — more than any regional bank handles in a day. A spike beyond that signals abuse, a runaway process, or a DDoS attempt.

**Routing:** One route — `POST /loan/evaluate`. The API does one thing and does it well.

**Observability:** JSON-structured access logs written to CloudWatch (requestId, IP, latency, status code). X-Ray tracing enabled — every request gets a trace ID that follows it through Lambda and into Bedrock.

---

### Layer 3: Lambda (The Orchestrator)

Python 3.12. 512 MB RAM. 30-second timeout. This function is the core of the system.

**What happens on every invocation — step by step:**

**Step 1 — Validate input**

The function checks that all required fields are present and sane:
- `applicant.name`, `annual_income`, `monthly_debt`, `employment_years`, `credit_history`
- `loan.amount`, `term_months`, `purpose`
- `loan.amount > 0`, `annual_income > 0`

Missing or invalid fields return HTTP 400 immediately — Bedrock never gets called, no cost incurred.

**Step 2 — Calculate DTI (Debt-to-Income Ratio)**

```
DTI = (monthly_debt + loan_amount/term_months) / (annual_income/12) × 100
```

DTI is the single most important number in consumer credit underwriting. It answers: "After paying all existing debts AND this new loan, what percentage of the applicant's monthly income is consumed by debt payments?"

- DTI < 40%: acceptable range, approval likely
- DTI 40–55%: borderline, human review warranted
- DTI > 55%: high risk, denial likely

This calculation is done in the Lambda before calling Bedrock — it's a hard financial metric that Claude receives as an input alongside the narrative profile.

**Step 3 — Build the prompt**

The Lambda formats all applicant data into a structured prompt. Claude receives:
- Applicant name, income, debt obligations, employment history
- Credit history narrative
- The pre-calculated DTI
- Loan amount, term, and purpose

**Step 4 — Invoke Amazon Bedrock (Claude Sonnet 4.6)**

```python
bedrock.invoke_model(
    modelId="us.anthropic.claude-sonnet-4-6",   # cross-region inference profile
    body={ system_prompt + applicant_prompt }
)
```

The system prompt instructs Claude to act as a senior credit risk analyst at a regulated institution. It defines the exact JSON schema Claude must return — no prose, no markdown, structured output only. It also encodes the bank's underwriting policy:
- APPROVE: DTI < 40%, stable employment, clean history
- DENY: DTI > 55%, recent defaults, unstable income, open collections
- REVIEW: borderline cases requiring human underwriter judgment

**Why Amazon Bedrock instead of calling Claude's API directly?**  
Data residency and compliance. Bedrock keeps all data — the prompt, the response, everything — inside your AWS account and within AWS infrastructure. For financial institutions operating under GLBA, SOC 2, or state banking regulations, data cannot transit through third-party API infrastructure. Bedrock solves this by keeping the AI workload within the AWS boundary you already control.

**Step 5 — Parse and validate the decision**

Claude returns a JSON object:
```json
{
  "decision": "APPROVE",
  "risk_score": 18,
  "confidence": "HIGH",
  "reasoning": "Applicant presents strong DTI of 10%...",
  "risk_factors": ["Loan term extends repayment period"],
  "recommended_conditions": ["Verify income with pay stubs"]
}
```

The Lambda defensively parses this — stripping any markdown fences if present, JSON-parsing the result, and raising a structured error if Claude's output is malformed.

**Step 6 — Write audit record to DynamoDB**

Every decision — approve, deny, or review — is written to DynamoDB before the response is returned. The record includes the full input, the full output, a UUID, and a UTC timestamp. This is not optional. In regulated lending, every credit decision must be traceable for fair lending audits, regulatory examinations, and consumer disputes.

**Step 7 — Return the response**

HTTP 200 with the decision JSON. The entire round-trip takes 2–5 seconds, dominated by Bedrock inference time.

---

### Layer 4: Amazon Bedrock — Why AI for Credit Decisions?

Traditional credit scoring (FICO) reduces an applicant to a single number. It captures payment history and credit utilization but misses context:

- A nurse with 2 years employment history looks risky to FICO — but nurses have near-zero unemployment and highly stable income
- A self-employed consultant with variable income looks risky — but $200K annual revenue with consistent 3-year history is fundamentally different from $200K with one good year
- A recent graduate with no credit history looks high-risk — but a medical resident with $280K in student loans and a signed employment contract is a different story

A language model reading the full narrative credit history, employment context, and loan purpose can surface these nuances. More importantly, it **explains its reasoning** — the `reasoning` field in the response is a 2-3 sentence narrative that a loan officer can read, agree or disagree with, and use to make a better-informed final decision.

This is the key distinction: this system is not making autonomous lending decisions. It is providing **explainable AI-assisted pre-screening** that augments human underwriters. The REVIEW decision exists precisely for cases where the AI identifies mixed signals and escalates to human judgment.

---

### Layer 5: DynamoDB — The Audit Trail

Every decision is stored with full fidelity. Nothing is summarized or truncated.

**Schema:**
```
request_id     → UUID (primary key - fetch any decision instantly)
timestamp      → ISO 8601 UTC
applicant_name → String
loan_amount    → Number
loan_purpose   → String
decision       → APPROVE | DENY | REVIEW
risk_score     → 0–100
confidence     → HIGH | MEDIUM | LOW
reasoning      → Full narrative from Claude
risk_factors   → List of identified risk factors
recommended_conditions → List of conditions for approval
raw_input      → Full original request JSON (immutable record)
status         → COMPLETED
ttl            → Auto-expiry epoch (90 days in dev)
```

**GSI — decision-timestamp-index:**  
Hash key: `decision`, Range key: `timestamp`

This index enables fair lending compliance queries:
- "Show all DENY decisions in the last 90 days" — for disparate impact analysis
- "Show all REVIEW decisions pending underwriter action" — for pipeline management
- "Show all APPROVE decisions above risk score 60" — for portfolio risk monitoring

Without this index you'd need expensive table scans. With it, these are single-digit millisecond queries.

**Point-in-Time Recovery (PITR):** Enabled. You can restore the table to any second in the last 35 days. In a regulatory examination, you may need to reconstruct the exact decision state from 60 days ago. PITR makes this possible.

---

### Layer 6: IAM — Least-Privilege Security

The Lambda execution role can do exactly three things and nothing else:

```
Lambda Role
 ├── CloudWatch Logs: write logs
 ├── bedrock:InvokeModel → ONLY on claude-sonnet-4-6 inference profile + foundation model
 └── dynamodb: PutItem, GetItem, Query, Scan → ONLY on loan-decisions table
```

If this Lambda function were compromised — through a code injection vulnerability, a dependency exploit, or a stolen execution token — the attacker could only read/write the loan-decisions table and invoke Claude Sonnet 4.6. They could not access S3, other DynamoDB tables, other Bedrock models, EC2, or anything else in the AWS account. The blast radius is contained by design.

---

### Layer 7: CI/CD — GitHub Actions with OIDC

The deployment pipeline uses keyless authentication. There are no AWS access keys stored anywhere — not in GitHub Secrets, not in config files, nowhere.

Instead, GitHub Actions proves its identity to AWS using a signed JWT (OpenID Connect). AWS verifies the token and issues a temporary 1-hour session credential. The trust relationship is scoped specifically to this repository — a token from any other GitHub repo cannot assume this role.

**Pipeline gates before anything reaches AWS:**
1. All 8 unit tests must pass (pytest + moto mock)
2. Terraform must be syntactically valid and formatted correctly
3. Trivy security scan must find no high/critical IaC misconfigurations

Only after all three pass does Terraform apply run.

**Production deployments require manual approval** — a push to `main` triggers the pipeline but pauses before applying. A human must click Approve in GitHub before infrastructure changes go live in prod.

---

## What This Is NOT

This system is a **pre-screening engine**, not a fully autonomous lending platform. A production deployment at an actual bank would add:

| Missing Component | What It Does | Why Not Included Here |
|---|---|---|
| Credit bureau integration | Pull live FICO, Experian/Equifax/TransUnion data | Requires credit bureau contracts ($$$) |
| Identity verification | KYC/AML checks, document verification | Requires Socure/Jumio/similar vendor |
| Human review workflow | Step Functions state machine for REVIEW decisions | Significant scope addition |
| Cognito/OAuth | End-user authentication (vs. service-to-service API keys) | Depends on bank's existing auth infrastructure |
| VPC + PrivateLink | Keep Lambda off public internet | Adds NAT Gateway cost (~$32/month) |
| Customer-managed KMS | Bank-controlled encryption keys | Requires KMS key management ops |
| Adverse action notices | ECOA-required denial letters to applicants | Downstream system responsibility |

This architecture demonstrates every infrastructure and AI pattern a production system uses — the additions above are integrations with external vendors and downstream workflows, not architectural changes.

---

## Cost Profile

For a regional bank running 500 loan applications per day:

| Service | Usage | Monthly Cost |
|---|---|---|
| Lambda | 500 invocations × 3s × 512MB | ~$0.00 (free tier covers it) |
| API Gateway | 15,000 requests/month | ~$0.05 |
| Bedrock (Claude Sonnet 4.6) | 500 calls × ~2,000 tokens | ~$15–25 |
| DynamoDB | 500 writes + reads, 1GB storage | ~$0.00 (free tier) |
| CloudWatch | Logs + metrics | ~$2 |
| WAF | 15,000 requests | ~$6 |
| **Total** | | **~$25–35/month** |

A bank paying $25/month to pre-screen 500 loan applications — applications that previously required 15–30 minutes of a loan officer's time each — is getting several thousand dollars of labor productivity per month from this system.

---

## Summary

This is a serverless AI pre-screening API that sits between a bank's loan origination frontend and its human underwriting team. It receives a loan application, calculates DTI, invokes Claude Sonnet 4.6 via Amazon Bedrock to generate an explainable credit risk decision, stores an immutable audit record in DynamoDB, and returns a structured JSON response in under 5 seconds. Every component — WAF, API key auth, throttling, least-privilege IAM, PITR, OIDC-based CI/CD — reflects real financial services compliance and security requirements, not just cloud best practices.
