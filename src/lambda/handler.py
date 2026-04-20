import json
import boto3
import uuid
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
dynamodb = boto3.resource("dynamodb", region_name="us-east-1")

TABLE_NAME = "loan-decisions"

SYSTEM_PROMPT = """You are a senior credit risk analyst at a regulated financial institution.
You evaluate loan applications based on standard underwriting criteria.
You must respond ONLY with a valid JSON object — no markdown, no explanation outside the JSON.

Evaluate the applicant and return this exact structure:
{
  "decision": "APPROVE" | "DENY" | "REVIEW",
  "risk_score": <integer 0-100, where 100 is highest risk>,
  "confidence": "HIGH" | "MEDIUM" | "LOW",
  "reasoning": "<2-3 sentence explanation of the decision>",
  "risk_factors": ["<factor1>", "<factor2>"],
  "recommended_conditions": ["<condition1>"] 
}

Rules:
- APPROVE: strong income, good DTI (<40%), stable employment, clean history
- DENY: high DTI (>55%), poor credit indicators, unstable income, recent defaults
- REVIEW: borderline cases needing human review
- recommended_conditions: only include if APPROVE or REVIEW (e.g. "Require collateral", "Co-signer needed")
- Be conservative. This is a regulated banking environment."""


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
        validate_input(body)

        applicant = body["applicant"]
        loan = body["loan"]
        request_id = str(uuid.uuid4())

        logger.info(f"Processing loan request {request_id}")

        prompt = build_prompt(applicant, loan)
        bedrock_response = invoke_bedrock(prompt)
        decision = parse_decision(bedrock_response)

        record = {
            "request_id": request_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "applicant_name": applicant.get("name", "UNKNOWN"),
            "loan_amount": loan.get("amount"),
            "loan_purpose": loan.get("purpose"),
            "decision": decision["decision"],
            "risk_score": decision["risk_score"],
            "confidence": decision["confidence"],
            "reasoning": decision["reasoning"],
            "risk_factors": decision["risk_factors"],
            "recommended_conditions": decision.get("recommended_conditions", []),
            "raw_input": json.dumps(body),
            "status": "COMPLETED"
        }

        save_to_dynamodb(record)

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "X-Request-ID": request_id
            },
            "body": json.dumps({
                "request_id": request_id,
                "timestamp": record["timestamp"],
                "decision": decision["decision"],
                "risk_score": decision["risk_score"],
                "confidence": decision["confidence"],
                "reasoning": decision["reasoning"],
                "risk_factors": decision["risk_factors"],
                "recommended_conditions": decision.get("recommended_conditions", [])
            })
        }

    except ValueError as e:
        logger.warning(f"Validation error: {str(e)}")
        return error_response(400, str(e))
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}", exc_info=True)
        return error_response(500, "Internal server error. Please try again.")


def validate_input(body):
    if "applicant" not in body:
        raise ValueError("Missing required field: applicant")
    if "loan" not in body:
        raise ValueError("Missing required field: loan")

    applicant = body["applicant"]
    loan = body["loan"]

    required_applicant = ["name", "annual_income", "monthly_debt", "employment_years", "credit_history"]
    for field in required_applicant:
        if field not in applicant:
            raise ValueError(f"Missing applicant field: {field}")

    required_loan = ["amount", "term_months", "purpose"]
    for field in required_loan:
        if field not in loan:
            raise ValueError(f"Missing loan field: {field}")

    if not isinstance(loan["amount"], (int, float)) or loan["amount"] <= 0:
        raise ValueError("loan.amount must be a positive number")
    if not isinstance(applicant["annual_income"], (int, float)) or applicant["annual_income"] <= 0:
        raise ValueError("applicant.annual_income must be a positive number")


def build_prompt(applicant, loan):
    monthly_income = applicant["annual_income"] / 12
    dti = ((applicant["monthly_debt"] + (loan["amount"] / loan["term_months"])) / monthly_income) * 100

    return f"""Evaluate this loan application:

APPLICANT PROFILE:
- Name: {applicant['name']}
- Annual Income: ${applicant['annual_income']:,.2f}
- Monthly Debt Obligations: ${applicant['monthly_debt']:,.2f}
- Employment Tenure: {applicant['employment_years']} years
- Credit History: {applicant['credit_history']}
- Additional Notes: {applicant.get('notes', 'None')}

LOAN REQUEST:
- Amount: ${loan['amount']:,.2f}
- Term: {loan['term_months']} months
- Purpose: {loan['purpose']}

CALCULATED METRICS:
- Monthly Income: ${monthly_income:,.2f}
- Estimated DTI (including new loan): {dti:.1f}%
- Monthly Payment Estimate: ${loan['amount'] / loan['term_months']:,.2f}

Evaluate this application and return your decision as JSON."""


def invoke_bedrock(prompt):
    response = bedrock.invoke_model(
        modelId="anthropic.claude-sonnet-4-6",
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1000,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": prompt}
            ]
        })
    )
    response_body = json.loads(response["body"].read())
    return response_body["content"][0]["text"]


def parse_decision(raw_response):
    try:
        clean = raw_response.strip()
        if clean.startswith("```"):
            clean = clean.split("```")[1]
            if clean.startswith("json"):
                clean = clean[4:]
        return json.loads(clean.strip())
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Bedrock response: {raw_response}")
        raise ValueError(f"Invalid response format from AI model: {str(e)}")


def save_to_dynamodb(record):
    try:
        table = dynamodb.Table(TABLE_NAME)
        table.put_item(Item=record)
        logger.info(f"Saved decision {record['request_id']} to DynamoDB")
    except Exception as e:
        logger.error(f"DynamoDB save failed: {str(e)}")
        raise


def error_response(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message})
    }
