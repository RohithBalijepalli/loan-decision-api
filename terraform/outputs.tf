output "api_endpoint" {
  description = "Base URL of the deployed Loan Decision API"
  value       = module.api_gateway.api_endpoint
}

output "api_key_id" {
  description = "API Key ID (retrieve value from AWS console or CLI)"
  value       = module.api_gateway.api_key_id
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = module.lambda.function_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table storing loan decisions"
  value       = module.dynamodb.table_name
}

output "curl_example" {
  description = "Example curl command to test the API"
  value       = <<-EOT
    curl -X POST ${module.api_gateway.api_endpoint}/loan/evaluate \
      -H "Content-Type: application/json" \
      -H "x-api-key: <YOUR_API_KEY>" \
      -d '{
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
      }'
  EOT
}
