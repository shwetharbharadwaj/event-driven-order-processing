#!/bin/bash

################################################################################
# AWS Event-Driven Order Processing System - Deployment Script
#
# This script automates the deployment of all AWS resources needed for the
# order processing system.
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Appropriate IAM permissions
#   - Environment variables set (or uses defaults)
#
# Usage:
#   ./deploy.sh                    # Deploy with defaults
#   ./deploy.sh --region us-west-2 # Deploy to specific region
#   ./deploy.sh --cleanup          # Delete all resources
#
# Author: Your Name
# Date: January 2026
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
AWS_REGION=${AWS_REGION:-"us-east-1"}
STACK_NAME="order-processing-stack"
EMAIL_ADDRESS=""

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    
    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS Account ID: $AWS_ACCOUNT_ID"
    print_success "Region: $AWS_REGION"
}

# Function to create SQS queues
create_sqs_queues() {
    print_info "Creating SQS queues..."
    
    # Create Dead Letter Queue first
    print_info "Creating DLQ: OrderDLQ"
    DLQ_URL=$(aws sqs create-queue \
        --queue-name OrderDLQ \
        --region $AWS_REGION \
        --attributes MessageRetentionPeriod=1209600 \
        --query 'QueueUrl' \
        --output text)
    
    # Get DLQ ARN
    DLQ_ARN=$(aws sqs get-queue-attributes \
        --queue-url $DLQ_URL \
        --attribute-names QueueArn \
        --query 'Attributes.QueueArn' \
        --output text)
    
    print_success "DLQ created: $DLQ_URL"
    
    # Create main processing queue with DLQ configured
    print_info "Creating main queue: OrderProcessingQueue"
    
    # Create redrive policy
    REDRIVE_POLICY="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
    
    MAIN_QUEUE_URL=$(aws sqs create-queue \
        --queue-name OrderProcessingQueue \
        --region $AWS_REGION \
        --attributes \
            VisibilityTimeout=180,\
            MessageRetentionPeriod=345600,\
            RedrivePolicy="$REDRIVE_POLICY" \
        --query 'QueueUrl' \
        --output text)
    
    print_success "Main queue created: $MAIN_QUEUE_URL"
    
    # Create audit queue
    print_info "Creating audit queue: OrderAuditQueue"
    AUDIT_QUEUE_URL=$(aws sqs create-queue \
        --queue-name OrderAuditQueue \
        --region $AWS_REGION \
        --query 'QueueUrl' \
        --output text)
    
    print_success "Audit queue created: $AUDIT_QUEUE_URL"
    
    # Export for use in other functions
    export DLQ_URL MAIN_QUEUE_URL AUDIT_QUEUE_URL DLQ_ARN
}

# Function to create SNS topic
create_sns_topic() {
    print_info "Creating SNS topic..."
    
    SNS_TOPIC_ARN=$(aws sns create-topic \
        --name OrderEvents \
        --region $AWS_REGION \
        --query 'TopicArn' \
        --output text)
    
    print_success "SNS topic created: $SNS_TOPIC_ARN"
    
    # Subscribe email if provided
    if [ -n "$EMAIL_ADDRESS" ]; then
        print_info "Subscribing email: $EMAIL_ADDRESS"
        aws sns subscribe \
            --topic-arn $SNS_TOPIC_ARN \
            --protocol email \
            --notification-endpoint $EMAIL_ADDRESS \
            --region $AWS_REGION
        
        print_warning "Please check your email and confirm the subscription!"
    fi
    
    export SNS_TOPIC_ARN
}

# Function to create IAM role for Lambda
create_iam_role() {
    print_info "Creating IAM role for Lambda..."
    
    # Create trust policy
    cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
    
    # Create role
    ROLE_ARN=$(aws iam create-role \
        --role-name OrderProcessingLambdaRole \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --query 'Role.Arn' \
        --output text)
    
    print_success "IAM role created: $ROLE_ARN"
    
    # Attach policies
    print_info "Attaching IAM policies..."
    
    aws iam attach-role-policy \
        --role-name OrderProcessingLambdaRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    aws iam attach-role-policy \
        --role-name OrderProcessingLambdaRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole
    
    aws iam attach-role-policy \
        --role-name OrderProcessingLambdaRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess
    
    aws iam attach-role-policy \
        --role-name OrderProcessingLambdaRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess
    
    print_success "Policies attached"
    
    # Wait for role to be ready
    print_info "Waiting for IAM role to propagate (10 seconds)..."
    sleep 10
    
    export ROLE_ARN
}

# Function to package and deploy Lambda
deploy_lambda() {
    print_info "Deploying Lambda function..."
    
    # Create deployment package
    cd src/lambda/order_processor
    zip -r /tmp/order_processor.zip .
    cd -
    
    # Create Lambda function
    LAMBDA_ARN=$(aws lambda create-function \
        --function-name OrderProcessor \
        --runtime python3.9 \
        --role $ROLE_ARN \
        --handler app.lambda_handler \
        --zip-file fileb:///tmp/order_processor.zip \
        --timeout 10 \
        --memory-size 128 \
        --environment Variables="{SNS_TOPIC_ARN=$SNS_TOPIC_ARN,EVENT_BUS_NAME=OrderEventBus}" \
        --region $AWS_REGION \
        --query 'FunctionArn' \
        --output text)
    
    print_success "Lambda function created: $LAMBDA_ARN"
    
    export LAMBDA_ARN
}

# Function to create EventBridge event bus
create_event_bus() {
    print_info "Creating EventBridge event bus..."
    
    aws events create-event-bus \
        --name OrderEventBus \
        --region $AWS_REGION
    
    print_success "Event bus created: OrderEventBus"
    
    # Create rule for order processing
    print_info "Creating EventBridge rule..."
    
    aws events put-rule \
        --name RouteNewOrders \
        --event-bus-name OrderEventBus \
        --event-pattern '{"source":["order.service"],"detail-type":["ORDER_PROCESSED"]}' \
        --state ENABLED \
        --region $AWS_REGION
    
    # Add SNS as target
    aws events put-targets \
        --rule RouteNewOrders \
        --event-bus-name OrderEventBus \
        --targets "Id"="1","Arn"="$SNS_TOPIC_ARN" \
        --region $AWS_REGION
    
    print_success "EventBridge rule created and connected to SNS"
}

# Function to create SQS trigger for Lambda
create_lambda_trigger() {
    print_info "Creating Lambda SQS trigger..."
    
    # Get queue ARN
    QUEUE_ARN=$(aws sqs get-queue-attributes \
        --queue-url $MAIN_QUEUE_URL \
        --attribute-names QueueArn \
        --query 'Attributes.QueueArn' \
        --output text)
    
    # Create event source mapping
    aws lambda create-event-source-mapping \
        --function-name OrderProcessor \
        --batch-size 10 \
        --maximum-batching-window-in-seconds 5 \
        --event-source-arn $QUEUE_ARN \
        --function-response-types ReportBatchItemFailures \
        --scaling-config MaximumConcurrency=1 \
        --region $AWS_REGION
    
    print_success "SQS trigger created"
}

# Function to create CloudWatch alarms
create_alarms() {
    print_info "Creating CloudWatch alarms..."
    
    # Alarm for DLQ messages
    aws cloudwatch put-metric-alarm \
        --alarm-name OrderDLQ-HasMessages \
        --alarm-description "Alert when orders fail to process" \
        --metric-name ApproximateNumberOfMessagesVisible \
        --namespace AWS/SQS \
        --statistic Average \
        --period 300 \
        --threshold 0 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 1 \
        --dimensions Name=QueueName,Value=OrderDLQ \
        --region $AWS_REGION
    
    print_success "CloudWatch alarms created"
}

# Function to display deployment summary
display_summary() {
    print_success "\n========================================="
    print_success "Deployment Complete!"
    print_success "=========================================\n"
    
    echo "Resource URLs:"
    echo "  Main Queue: $MAIN_QUEUE_URL"
    echo "  DLQ: $DLQ_URL"
    echo "  Audit Queue: $AUDIT_QUEUE_URL"
    echo "  SNS Topic: $SNS_TOPIC_ARN"
    echo "  Lambda Function: $LAMBDA_ARN"
    echo ""
    echo "Next Steps:"
    echo "  1. If you provided an email, confirm the SNS subscription"
    echo "  2. Test the system: ./scripts/send-test-order.sh"
    echo "  3. View logs: aws logs tail /aws/lambda/OrderProcessor --follow"
    echo ""
    print_warning "Remember: All resources are within free tier limits!"
}

# Main deployment flow
main() {
    print_info "Starting AWS Event-Driven Order Processing deployment..."
    print_info "Region: $AWS_REGION"
    
    # Check if email provided
    read -p "Enter email for SNS notifications (optional): " EMAIL_ADDRESS
    
    check_prerequisites
    create_sqs_queues
    create_sns_topic
    create_iam_role
    deploy_lambda
    create_event_bus
    create_lambda_trigger
    create_alarms
    display_summary
}

# Run main function
main "$@"
