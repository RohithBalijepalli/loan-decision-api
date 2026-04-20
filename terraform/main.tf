terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Uncomment to use S3 backend (recommended for production)
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "loan-decision-api/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}

# --------------------------------------------------------------------------
# Lambda package
# --------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/lambda"
  output_path = "${path.root}/lambda_package.zip"
}

# --------------------------------------------------------------------------
# Modules
# --------------------------------------------------------------------------
module "bedrock_iam" {
  source       = "./modules/bedrock_iam"
  project_name = var.project_name
  environment  = var.environment
}

module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  environment  = var.environment
}

module "lambda" {
  source             = "./modules/lambda"
  project_name       = var.project_name
  environment        = var.environment
  lambda_role_arn    = module.bedrock_iam.lambda_role_arn
  lambda_zip_path    = data.archive_file.lambda_zip.output_path
  lambda_zip_hash    = data.archive_file.lambda_zip.output_base64sha256
  dynamodb_table_name = module.dynamodb.table_name
}

module "api_gateway" {
  source              = "./modules/api_gateway"
  project_name        = var.project_name
  environment         = var.environment
  lambda_invoke_arn   = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
}
