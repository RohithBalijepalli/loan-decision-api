variable "project_name" {}
variable "environment" {}
variable "lambda_invoke_arn" {}
variable "lambda_function_name" {}

# --------------------------------------------------------------------------
# REST API
# --------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "loan_api" {
  name        = "${var.project_name}-${var.environment}"
  description = "Intelligent Loan Decision API powered by AWS Bedrock"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /loan resource
resource "aws_api_gateway_resource" "loan" {
  rest_api_id = aws_api_gateway_rest_api.loan_api.id
  parent_id   = aws_api_gateway_rest_api.loan_api.root_resource_id
  path_part   = "loan"
}

# /loan/evaluate resource
resource "aws_api_gateway_resource" "evaluate" {
  rest_api_id = aws_api_gateway_rest_api.loan_api.id
  parent_id   = aws_api_gateway_resource.loan.id
  path_part   = "evaluate"
}

# POST method
resource "aws_api_gateway_method" "post_evaluate" {
  rest_api_id      = aws_api_gateway_rest_api.loan_api.id
  resource_id      = aws_api_gateway_resource.evaluate.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true # API key enforced
}

# Lambda integration
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.loan_api.id
  resource_id             = aws_api_gateway_resource.evaluate.id
  http_method             = aws_api_gateway_method.post_evaluate.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

# --------------------------------------------------------------------------
# Deployment and stage
# --------------------------------------------------------------------------
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.loan_api.id

  depends_on = [
    aws_api_gateway_integration.lambda_integration
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.loan_api.id
  stage_name    = var.environment

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
    })
  }

  xray_tracing_enabled = true
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}"
  retention_in_days = 30
}

# --------------------------------------------------------------------------
# API Key and Usage Plan
# --------------------------------------------------------------------------
resource "aws_api_gateway_api_key" "loan_api_key" {
  name    = "${var.project_name}-${var.environment}-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "usage_plan" {
  name = "${var.project_name}-${var.environment}-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.loan_api.id
    stage  = aws_api_gateway_stage.stage.stage_name
  }

  throttle_settings {
    burst_limit = 10
    rate_limit  = 5 # 5 req/sec — appropriate for a loan evaluation API
  }

  quota_settings {
    limit  = 1000
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan_key" "plan_key" {
  key_id        = aws_api_gateway_api_key.loan_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.usage_plan.id
}

# --------------------------------------------------------------------------
# Lambda permission for API Gateway
# --------------------------------------------------------------------------
resource "aws_lambda_permission" "api_gw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.loan_api.execution_arn}/*/*"
}

output "api_endpoint" {
  value = aws_api_gateway_stage.stage.invoke_url
}

output "api_key_id" {
  value = aws_api_gateway_api_key.loan_api_key.id
}
