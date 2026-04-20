variable "project_name" {}
variable "environment" {}
variable "lambda_role_arn" {}
variable "lambda_zip_path" {}
variable "lambda_zip_hash" {}
variable "dynamodb_table_name" {}
variable "memory_mb" { default = 512 }
variable "timeout_seconds" { default = 30 }

resource "aws_lambda_function" "loan_evaluator" {
  function_name    = "${var.project_name}-${var.environment}-evaluator"
  filename         = var.lambda_zip_path
  source_code_hash = var.lambda_zip_hash
  role             = var.lambda_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds

  environment {
    variables = {
      DYNAMODB_TABLE = var.dynamodb_table_name
      ENVIRONMENT    = var.environment
      LOG_LEVEL      = var.environment == "prod" ? "WARNING" : "INFO"
    }
  }

  tracing_config {
    mode = "Active" # X-Ray tracing
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-evaluator"
  }
}

# CloudWatch Log Group with retention
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.loan_evaluator.function_name}"
  retention_in_days = 30
}

# CloudWatch alarm: error rate > 5%
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda error count exceeded threshold"

  dimensions = {
    FunctionName = aws_lambda_function.loan_evaluator.function_name
  }
}

output "function_name" {
  value = aws_lambda_function.loan_evaluator.function_name
}

output "invoke_arn" {
  value = aws_lambda_function.loan_evaluator.invoke_arn
}

output "function_arn" {
  value = aws_lambda_function.loan_evaluator.arn
}
