#!/bin/bash
set -e

# Check if environment parameter is provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}

echo "🚀 Starting deployment for ${PROJECT_NAME}-${ENVIRONMENT}..."

# 1. Package backend Lambda function
echo "📦 Packaging Lambda function..."
cd backend

# Install dependencies using uv
uv pip install -r requirements.txt --target lambda-package

# Copy Lambda handler to package directory
cp lambda_function.py lambda-package/

# Create deployment zip
cd lambda-package
zip -r ../lambda-deployment.zip . -q
cd ..

echo "✅ Lambda package created: $(du -h lambda-deployment.zip | cut -f1)"
cd ..

# 2. Terraform workspace & apply
cd terraform

# Get AWS Account ID and Region for backend configuration
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialize Terraform with S3 backend
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    terraform workspace new "$ENVIRONMENT"
fi

terraform workspace select "$ENVIRONMENT"

# Apply infrastructure
if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
    terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi

# Get outputs
API_URL=$(terraform output -raw api_gateway_url)
CLOUDFRONT_URL=$(terraform output -raw cloudfront_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)

cd ..

# 3. Build and deploy frontend
echo "🎨 Building frontend..."
cd frontend

npm ci
NEXT_PUBLIC_API_URL="$API_URL" npm run build

echo "📤 Deploying frontend to S3..."
aws s3 sync out/ "s3://$FRONTEND_BUCKET/" --delete

cd ..

echo ""
echo "✅ Deployment complete!"
echo "🌐 CloudFront URL: $CLOUDFRONT_URL"
echo "📡 API Gateway: $API_URL"
echo "🪣 Frontend Bucket: $FRONTEND_BUCKET"
echo ""
echo "💡 CloudFront may take 5-10 minutes to fully propagate changes"
