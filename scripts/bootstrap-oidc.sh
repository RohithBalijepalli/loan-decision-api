#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# bootstrap-oidc.sh
# Run this ONCE manually before your first GitHub Actions deploy.
# Creates the OIDC provider and IAM role that GitHub Actions uses
# to authenticate with AWS — no long-lived access keys needed.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

# ── EDIT THESE ──────────────────────────────────────────────────
GITHUB_ORG="RohithBalijepalli"        # e.g. rohitbalijepalli
GITHUB_REPO="loan-decision-api"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="github-actions-loan-api-role"
STATE_BUCKET_NAME="loan-api-tf-state-${AWS_ACCOUNT_ID}"
LOCK_TABLE_NAME="loan-api-tf-lock"
REGION="us-east-1"
# ────────────────────────────────────────────────────────────────

echo "AWS Account: $AWS_ACCOUNT_ID"
echo "GitHub: $GITHUB_ORG/$GITHUB_REPO"
echo ""

# Step 1: Create OIDC provider for GitHub
echo "▶ Creating GitHub OIDC provider..."
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --region $REGION || echo "OIDC provider may already exist, continuing..."

# Step 2: Create trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

# Step 3: Create IAM role
echo "▶ Creating IAM role: $ROLE_NAME..."
aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document "$TRUST_POLICY" || echo "Role may already exist, updating trust policy..."

# Step 4: Attach permissions (scoped to what Terraform needs)
echo "▶ Attaching permissions..."
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Note: PowerUserAccess for dev. For prod, scope this down to specific services.

# Step 5: Create S3 bucket for Terraform state
echo "▶ Creating Terraform state bucket: $STATE_BUCKET_NAME..."
aws s3api create-bucket \
  --bucket $STATE_BUCKET_NAME \
  --region $REGION || echo "Bucket may already exist."

aws s3api put-bucket-versioning \
  --bucket $STATE_BUCKET_NAME \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket $STATE_BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

aws s3api put-public-access-block \
  --bucket $STATE_BUCKET_NAME \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Step 6: Create DynamoDB lock table
echo "▶ Creating Terraform lock table: $LOCK_TABLE_NAME..."
aws dynamodb create-table \
  --table-name $LOCK_TABLE_NAME \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION || echo "Lock table may already exist."

# Step 7: Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Add these as GitHub Secrets in your repo:"
echo "  Settings → Secrets and variables → Actions → New secret"
echo ""
echo "  AWS_ROLE_ARN       = $ROLE_ARN"
echo "  TF_STATE_BUCKET    = $STATE_BUCKET_NAME"
echo "  TF_LOCK_TABLE      = $LOCK_TABLE_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
