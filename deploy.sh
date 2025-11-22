#!/bin/bash

set -e

# Color Outputs
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Variables
PROJECT_NAME="ai-gallery-$(date +%s)"
REGION="us-east-1"
BUCKET_NAME="${PROJECT_NAME}-images"
TABLE_NAME="${PROJECT_NAME}-metadata"

print_info "🖼️ AI Smart Gallery Installing..."
print_info "Region: $REGION | Bucket: $BUCKET_NAME"

# 2. Create DynamoDB Table
print_info "🗄️ Creating DynamoDB table..."
aws dynamodb create-table \
    --table-name $TABLE_NAME \
    --attribute-definitions AttributeName=image_id,AttributeType=S \
    --key-schema AttributeName=image_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region $REGION > /dev/null

# 3. Create S3 Bucket
print_info "📦 Creating S3 bucket..."
aws s3 mb s3://$BUCKET_NAME --region $REGION

# 4. Prepare Lambda Function (Advanced Python Code)
print_info "Preparing Lambda code ..."
cat > lambda_function.py << 'EOF'
import json
import boto3
import base64
import os
from datetime import datetime

s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['TABLE_NAME'])

# Supported formats and Bedrock MIME types
SUPPORTED_FORMATS = {
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.webp': 'image/webp'
}

def lambda_handler(event, context):
    try:
        record = event['Records'][0]
        bucket_name = record['s3']['bucket']['name']
        file_key = record['s3']['object']['key']
        
        # Check file extension
        _, ext = os.path.splitext(file_key)
        ext = ext.lower()
        
        if ext not in SUPPORTED_FORMATS:
            print(f"Unsupported format skipped: {file_key}")
            return {'statusCode': 200, 'body': 'Skipped non-image file'}

        media_type = SUPPORTED_FORMATS[ext]
        print(f"Processing file: {file_key} (Type: {media_type})")

        # 1. Download image from S3
        file_obj = s3.get_object(Bucket=bucket_name, Key=file_key)
        image_content = file_obj['Body'].read()
        
        # 2. Convert to Base64
        image_b64 = base64.b64encode(image_content).decode('utf-8')
        
        # 3. Bedrock Prompt
        prompt = "What do you see in this image? Explain in detail. Also extract 5 comma-separated tags."
        
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1000,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": image_b64
                            }
                        },
                        {
                            "type": "text",
                            "text": prompt
                        }
                    ]
                }
            ]
        })

        # 4. Call Bedrock
        response = bedrock.invoke_model(
            modelId='anthropic.claude-3-5-sonnet-20240620-v1:0',
            body=body
        )
        
        response_body = json.loads(response['body'].read())
        ai_description = response_body['content'][0]['text']
        
        # 5. Save to DynamoDB
        item = {
            'image_id': file_key,
            'timestamp': datetime.now().isoformat(),
            'description': ai_description,
            'bucket': bucket_name,
            'format': ext
        }
        
        table.put_item(Item=item)
        print("✅ Saved to database.")
        
        return {'statusCode': 200, 'body': json.dumps('Success')}
        
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        return {'statusCode': 200, 'body': str(e)}
EOF

# Create zip
zip lambda_function.zip lambda_function.py

# 5. IAM Role and Permissions
print_info "🔐 Setting up IAM Role and Permissions..."

cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
EOF

ROLE_ARN=$(aws iam create-role --role-name ${PROJECT_NAME}-role --assume-role-policy-document file://trust-policy.json --query 'Role.Arn' --output text)

cat > permissions.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["s3:GetObject"],
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
        },
        {
            "Effect": "Allow",
            "Action": ["dynamodb:PutItem"],
            "Resource": "arn:aws:dynamodb:${REGION}:*:table/${TABLE_NAME}"
        },
        {
            "Effect": "Allow",
            "Action": ["bedrock:InvokeModel"],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
            "Resource": "*"
        }
    ]
}
EOF

aws iam put-role-policy --role-name ${PROJECT_NAME}-role --policy-name GalleryPolicy --policy-document file://permissions.json

print_info "Waiting for role to activate (10s)..."
sleep 10

# 6. Create Lambda Function
print_info "Deploying Lambda function..."
LAMBDA_ARN=$(aws lambda create-function \
    --function-name ${PROJECT_NAME}-function \
    --runtime python3.9 \
    --role $ROLE_ARN \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://lambda_function.zip \
    --timeout 60 \
    --environment Variables="{TABLE_NAME=$TABLE_NAME}" \
    --region $REGION \
    --query 'FunctionArn' --output text)

# 7. Configure S3 Trigger 
print_info "Connecting S3 Trigger..."

aws lambda add-permission \
    --function-name ${PROJECT_NAME}-function \
    --principal s3.amazonaws.com \
    --statement-id s3invoke \
    --action "lambda:InvokeFunction" \
    --source-arn "arn:aws:s3:::$BUCKET_NAME" \
    --region $REGION

cat > notification.json << EOF
{
    "LambdaFunctionConfigurations": [
        {
            "LambdaFunctionArn": "$LAMBDA_ARN",
            "Events": ["s3:ObjectCreated:*"]
        }
    ]
}
EOF

print_info "🔄 Testing connection (automatic retry for AWS delays)..."

# Retry Loop (5 attempts)
for i in {1..5}; do
    print_info "Attempt $i/5..."
    
    # Run command, continue if error (/dev/null)
    if aws s3api put-bucket-notification-configuration \
        --bucket $BUCKET_NAME \
        --notification-configuration file://notification.json 2>/dev/null; then
        
        print_success "✅ S3 and Lambda connection successful!"
        break
    else
        if [ $i -eq 5 ]; then
            print_error "Connection failed. Manual intervention may be required."
            exit 1
        fi
        print_info "⏳ Waiting for permissions (8s)..."
        sleep 8
    fi
done

# Cleanup
rm -f lambda_function.py lambda_function.zip trust-policy.json permissions.json notification.json

print_success "🎉 Installation Complete !"
print_info "📂 Bucket Name: $BUCKET_NAME"
print_info "📝 Table Name: $TABLE_NAME"