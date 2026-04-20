"""
Unit tests for the Loan Decision API Lambda handler.
Uses moto to mock AWS services — no real AWS calls made.
"""

import json
import os
import pytest
import boto3
from unittest.mock import patch, MagicMock
from moto import mock_aws

# Set env vars before importing handler
os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ["AWS_ACCESS_KEY_ID"] = "test"
os.environ["AWS_SECRET_ACCESS_KEY"] = "test"
os.environ["DYNAMODB_TABLE"] = "loan-decisions"
os.environ["ENVIRONMENT"] = "test"

# Now import handler
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../lambda"))
from handler import lambda_handler, validate_input, build_prompt, parse_decision


# ─────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────

@pytest.fixture
def valid_payload():
    return {
        "applicant": {
            "name": "Jane Smith",
            "annual_income": 85000,
            "monthly_debt": 800,
            "employment_years": 5,
            "credit_history": "Good. No defaults.",
            "notes": "Stable employment"
        },
        "loan": {
            "amount": 25000,
            "term_months": 60,
            "purpose": "Home renovation"
        }
    }

@pytest.fixture
def apigw_event(valid_payload):
    return {
        "body": json.dumps(valid_payload),
        "httpMethod": "POST",
        "path": "/loan/evaluate"
    }

@pytest.fixture
def mock_bedrock_response():
    return json.dumps({
        "decision": "APPROVE",
        "risk_score": 28,
        "confidence": "HIGH",
        "reasoning": "Strong income with low DTI. Clean credit history supports approval.",
        "risk_factors": ["Self-reported credit history"],
        "recommended_conditions": []
    })


# ─────────────────────────────────────────────
# Validation tests
# ─────────────────────────────────────────────

class TestValidateInput:

    def test_valid_payload_passes(self, valid_payload):
        # Should not raise
        validate_input(valid_payload)

    def test_missing_applicant_raises(self):
        with pytest.raises(ValueError, match="Missing required field: applicant"):
            validate_input({"loan": {"amount": 10000, "term_months": 36, "purpose": "test"}})

    def test_missing_loan_raises(self):
        with pytest.raises(ValueError, match="Missing required field: loan"):
            validate_input({"applicant": {"name": "X", "annual_income": 50000,
                                          "monthly_debt": 500, "employment_years": 2,
                                          "credit_history": "good"}})

    def test_negative_income_raises(self, valid_payload):
        valid_payload["applicant"]["annual_income"] = -1000
        with pytest.raises(ValueError, match="annual_income must be a positive number"):
            validate_input(valid_payload)

    def test_zero_loan_amount_raises(self, valid_payload):
        valid_payload["loan"]["amount"] = 0
        with pytest.raises(ValueError, match="amount must be a positive number"):
            validate_input(valid_payload)

    def test_missing_credit_history_raises(self, valid_payload):
        del valid_payload["applicant"]["credit_history"]
        with pytest.raises(ValueError, match="Missing applicant field: credit_history"):
            validate_input(valid_payload)


# ─────────────────────────────────────────────
# Prompt building tests
# ─────────────────────────────────────────────

class TestBuildPrompt:

    def test_prompt_contains_applicant_name(self, valid_payload):
        prompt = build_prompt(valid_payload["applicant"], valid_payload["loan"])
        assert "Jane Smith" in prompt

    def test_prompt_contains_dti(self, valid_payload):
        prompt = build_prompt(valid_payload["applicant"], valid_payload["loan"])
        assert "DTI" in prompt

    def test_prompt_contains_loan_amount(self, valid_payload):
        prompt = build_prompt(valid_payload["applicant"], valid_payload["loan"])
        assert "25,000" in prompt


# ─────────────────────────────────────────────
# Response parsing tests
# ─────────────────────────────────────────────

class TestParseDecision:

    def test_parses_clean_json(self, mock_bedrock_response):
        result = parse_decision(mock_bedrock_response)
        assert result["decision"] == "APPROVE"
        assert result["risk_score"] == 28

    def test_strips_markdown_fences(self):
        raw = '```json\n{"decision": "DENY", "risk_score": 80, "confidence": "HIGH", "reasoning": "High DTI", "risk_factors": ["High debt"]}\n```'
        result = parse_decision(raw)
        assert result["decision"] == "DENY"

    def test_invalid_json_raises(self):
        with pytest.raises(ValueError, match="Invalid response format"):
            parse_decision("this is not json at all")

    def test_all_decision_values(self):
        for decision in ["APPROVE", "DENY", "REVIEW"]:
            raw = json.dumps({
                "decision": decision,
                "risk_score": 50,
                "confidence": "MEDIUM",
                "reasoning": "Test",
                "risk_factors": []
            })
            result = parse_decision(raw)
            assert result["decision"] == decision


# ─────────────────────────────────────────────
# Full handler integration tests (mocked AWS)
# ─────────────────────────────────────────────

class TestLambdaHandler:

    @mock_aws
    @patch("handler.invoke_bedrock")
    def test_successful_approval(self, mock_bedrock, apigw_event, mock_bedrock_response):
        # Setup DynamoDB table
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName="loan-decisions",
            KeySchema=[{"AttributeName": "request_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "request_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST"
        )

        mock_bedrock.return_value = mock_bedrock_response

        response = lambda_handler(apigw_event, {})

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["decision"] == "APPROVE"
        assert "request_id" in body
        assert "reasoning" in body
        assert body["risk_score"] == 28

    @mock_aws
    @patch("handler.invoke_bedrock")
    def test_response_has_required_fields(self, mock_bedrock, apigw_event, mock_bedrock_response):
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName="loan-decisions",
            KeySchema=[{"AttributeName": "request_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "request_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST"
        )
        mock_bedrock.return_value = mock_bedrock_response
        response = lambda_handler(apigw_event, {})
        body = json.loads(response["body"])

        required_fields = ["request_id", "timestamp", "decision", "risk_score",
                           "confidence", "reasoning", "risk_factors"]
        for field in required_fields:
            assert field in body, f"Missing field: {field}"

    def test_bad_payload_returns_400(self):
        event = {"body": json.dumps({"invalid": "data"})}
        response = lambda_handler(event, {})
        assert response["statusCode"] == 400

    def test_malformed_body_returns_400(self):
        event = {"body": "not valid json{{{"}
        response = lambda_handler(event, {})
        assert response["statusCode"] in [400, 500]
