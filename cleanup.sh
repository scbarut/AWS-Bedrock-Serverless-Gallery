#!/bin/bash

# Serverless AI Gallery Cleanup Script
# Usage: ./cleanup.sh <PROJECT_ID>
# Example: ./cleanup.sh 1732356890

# Continue even if there are errors (some resources may already be deleted)
set +e

# Color Outputs
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

print_status() { echo -e "${YELLOW}[ACTION]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. ID Check
if [ -z "$1" ]; then
    echo -e "${RED}ERROR: Project ID not specified!${NC}"
    echo "Usage: ./cleanup.sh <TIMESTAMP_ID>"
    echo "Hint: Use the number from the bucket name. Example: for ai-gallery-123456-images, ID: 123456"
    exit 1
fi

ID=$1
PROJECT_NAME="ai-gallery-$ID"
REGION="us-east-1"

# Variables (same format as install script)
BUCKET_NAME="${PROJECT_NAME}-images"
TABLE_NAME="${PROJECT_NAME}-metadata"
ROLE_NAME="${PROJECT_NAME}-role"
FUNCTION_NAME="${PROJECT_NAME}-function"

echo -e "${RED}!!! WARNING !!!${NC}"
echo "The following resources and ALL THEIR DATA will be deleted:"
echo "- S3 Bucket: $BUCKET_NAME"
echo "- DynamoDB Table: $TABLE_NAME"
echo "- Lambda Function: $FUNCTION_NAME"
echo "- IAM Role: $ROLE_NAME"
echo ""
read -p "Are you sure? (y/n): " confirmation

if [ "$confirmation" != "y" ]; then
    echo "Operation cancelled."
    exit 0
fi

echo "Starting cleanup..."

# 2. Delete S3 Bucket (with all contents)
print_status "Deleting S3 Bucket ($BUCKET_NAME)..."
# --force parameter empties and deletes the bucket even if it's not empty
aws s3 rb s3://$BUCKET_NAME --force --region $REGION
if [ $? -eq 0 ]; then print_success "S3 Bucket deleted."; else print_error "S3 could not be deleted or not found."; fi

# 3. Delete DynamoDB Table
print_status "Deleting DynamoDB table ($TABLE_NAME)..."
aws dynamodb delete-table --table-name $TABLE_NAME --region $REGION
if [ $? -eq 0 ]; then print_success "Table deleted."; else print_error "Table could not be deleted."; fi

# 4. Delete Lambda Function
print_status "Deleting Lambda function ($FUNCTION_NAME)..."
aws lambda delete-function --function-name $FUNCTION_NAME --region $REGION
if [ $? -eq 0 ]; then print_success "Lambda deleted."; else print_error "Lambda could not be deleted."; fi

# 5. Delete IAM Role and Policies
print_status "Cleaning up IAM Role ($ROLE_NAME)..."

# First we need to delete the policy inside the role
aws iam delete-role-policy --role-name $ROLE_NAME --policy-name GalleryPolicy
if [ $? -eq 0 ]; then print_success "Role policy deleted."; else print_error "Policy could not be deleted."; fi

# Then delete the role
aws iam delete-role --role-name $ROLE_NAME
if [ $? -eq 0 ]; then print_success "IAM Role deleted."; else print_error "Role could not be deleted."; fi

# 6. Clean Local Files
print_status "Cleaning local temporary files..."
rm -f lambda_function.zip lambda_function.py
print_success "Local files cleaned."

echo ""
echo -e "${GREEN}🎉 Cleanup completed. Your AWS account is now clean.${NC}"