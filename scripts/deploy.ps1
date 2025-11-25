param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Package backend Lambda function
Write-Host "Packaging Lambda function..." -ForegroundColor Yellow
Set-Location backend

# Install dependencies using uv
uv pip install -r requirements.txt --target lambda-package

# Copy Lambda handler and application files to package directory
Copy-Item lambda_handler.py lambda-package/
Copy-Item server.py lambda-package/
Copy-Item context.py lambda-package/
Copy-Item resources.py lambda-package/

# Copy data directory if it exists
if (Test-Path "data") {
    Copy-Item -Path data -Destination lambda-package/ -Recurse
}

# Create deployment zip
Compress-Archive -Path lambda-package\* -DestinationPath lambda-deployment.zip -Force

Write-Host "Lambda package created: $((Get-Item lambda-deployment.zip).Length / 1MB) MB" -ForegroundColor Green
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file=prod.tfvars -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

$ApiUrl        = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

# Create production environment file with API URL
Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"VITE_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
npm run build
aws s3 sync .\dist "s3://$FrontendBucket/" --delete
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
