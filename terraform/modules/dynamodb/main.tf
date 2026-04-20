variable "project_name" {}
variable "environment" {}

resource "aws_dynamodb_table" "loan_decisions" {
  name         = "loan-decisions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "decision"
    type = "S"
  }

  # GSI: query by decision type (e.g. all DENY decisions)
  global_secondary_index {
    name            = "decision-timestamp-index"
    hash_key        = "decision"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # TTL: auto-expire dev records after 90 days
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "loan-decisions-${var.environment}"
  }
}

output "table_name" {
  value = aws_dynamodb_table.loan_decisions.name
}

output "table_arn" {
  value = aws_dynamodb_table.loan_decisions.arn
}
