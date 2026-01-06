"""
AWS Lambda Function: Order Processor

This Lambda function processes orders from an SQS queue, validates them,
sends events to EventBridge, and publishes notifications via SNS.

Author: Your Name
Date: January 2026
Version: 1.0.0

Environment Variables:
    SNS_TOPIC_ARN: ARN of the SNS topic for notifications
    EVENT_BUS_NAME: Name of the EventBridge event bus
    
Triggers:
    - SQS: OrderProcessingQueue (batch size: 10, window: 5s)
    - SNS: OrderEvents (for confirmations)
    
Memory: 128 MB (optimized for free tier)
Timeout: 10 seconds
"""

import json
import boto3
import os
from datetime import datetime
from typing import Dict, List, Any

# Initialize AWS clients outside handler for connection reuse across invocations
# This improves performance and reduces cold start time
sns = boto3.client('sns')
events = boto3.client('events')

# Environment variables with defaults for local testing
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
EVENT_BUS_NAME = os.environ.get('EVENT_BUS_NAME', 'OrderEventBus')

# Configuration constants
MAX_RETRIES = 0  # SQS handles retries, not Lambda (prevents double charging)
REQUIRED_FIELDS = ['orderId', 'customerId', 'items', 'total']


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler function.
    
    Processes orders from SQS queue in batches, validates each order,
    and publishes events to downstream services.
    
    Args:
        event: Lambda event containing SQS messages in 'Records' array
        context: Lambda context object with runtime information
        
    Returns:
        dict: Response with statusCode and processing results
              On partial failure, returns batchItemFailures for retry
              
    Free Tier Optimization:
        - Processes messages in batches (up to 10 at once)
        - Fast execution (typically < 1 second)
        - Minimal memory usage (128 MB)
        
    Example event:
        {
            "Records": [
                {
                    "messageId": "msg-123",
                    "body": "{\"orderId\": \"ORD-001\", ...}",
                    "receiptHandle": "handle-123",
                    "attributes": {
                        "ApproximateReceiveCount": "1"
                    }
                }
            ]
        }
    """
    print(f"[INFO] Received {len(event['Records'])} messages for processing")
    print(f"[INFO] Function memory: {context.memory_limit_in_mb}MB, "
          f"Remaining time: {context.get_remaining_time_in_millis()}ms")
    
    # Tracking variables
    success_count = 0
    failed_messages = []
    
    # Process each SQS message in the batch
    for record in event['Records']:
        message_id = record.get('messageId', 'unknown')
        receive_count = record.get('attributes', {}).get('ApproximateReceiveCount', '1')
        
        try:
            # Parse the message body (JSON string -> Python dict)
            message_body = json.loads(record['body'])
            order_id = message_body.get('orderId', 'UNKNOWN')
            
            print(f"[INFO] Processing order: {order_id} "
                  f"(message: {message_id}, attempt: {receive_count})")
            
            # Step 1: Validate order data
            if not validate_order(message_body):
                raise ValueError(f"Order validation failed for {order_id}")
            
            # Step 2: Send event to EventBridge (fire-and-forget for speed)
            # EventBridge will route this to multiple targets based on rules
            send_order_event(message_body, 'ORDER_PROCESSED')
            
            # Step 3: Notify subscribers via SNS (fanout pattern)
            # SNS will deliver to all subscriptions (email, SQS, Lambda, etc.)
            notify_order_status(message_body, 'processed')
            
            success_count += 1
            print(f"[SUCCESS] ✓ Order {order_id} processed successfully")
                
        except Exception as e:
            # Log the error with full context for debugging
            error_msg = str(e)
            print(f"[ERROR] ✗ Failed to process message {message_id}: {error_msg}")
            print(f"[ERROR] Message body: {record.get('body', 'N/A')}")
            
            # Track failed message for partial batch failure response
            # SQS will make this message visible again for retry
            failed_messages.append({
                'itemIdentifier': message_id  # SQS uses this to identify which messages failed
            })
    
    # Log summary statistics
    print(f"[SUMMARY] Batch complete: {success_count} successful, "
          f"{len(failed_messages)} failed")
    
    # Return partial batch failure response if any messages failed
    # This tells SQS to:
    # - Delete successfully processed messages from queue
    # - Keep failed messages for retry (they become visible again after visibility timeout)
    if failed_messages:
        print(f"[WARNING] Returning {len(failed_messages)} messages for retry")
        return {
            'batchItemFailures': failed_messages
        }
    
    # All messages processed successfully
    return {
        'statusCode': 200,
        'body': json.dumps({
            'processed': success_count,
            'failed': 0
        })
    }


def validate_order(order: Dict[str, Any]) -> bool:
    """
    Validate order data structure and business rules.
    
    Checks:
        - All required fields present
        - Items array not empty
        - Total is positive number
        
    Args:
        order: Order dictionary to validate
        
    Returns:
        bool: True if valid, False otherwise
        
    Example valid order:
        {
            "orderId": "ORD-001",
            "customerId": "CUST-123",
            "items": [
                {"productId": "PROD-1", "quantity": 2, "price": 29.99}
            ],
            "total": 59.98
        }
    """
    try:
        # Check all required fields exist
        for field in REQUIRED_FIELDS:
            if field not in order:
                print(f"[VALIDATION] Missing required field: {field}")
                return False
        
        # Check items array exists and is not empty
        items = order.get('items', [])
        if not items or len(items) == 0:
            print(f"[VALIDATION] Order must contain at least one item")
            return False
        
        # Check total is positive
        total = order.get('total', 0)
        if total <= 0:
            print(f"[VALIDATION] Order total must be positive, got: {total}")
            return False
        
        # All validations passed
        return True
        
    except Exception as e:
        print(f"[VALIDATION] Validation error: {str(e)}")
        return False


def send_order_event(order: Dict[str, Any], event_type: str) -> None:
    """
    Send order event to EventBridge for downstream processing.
    
    EventBridge will route this event to targets based on:
        - Source: "order.service"
        - DetailType: event_type (e.g., "ORDER_PROCESSED")
        - Detail content: order data
        
    Targets might include:
        - Lambda functions for specific processing
        - SQS queues for async workflows
        - SNS topics for notifications
        - Step Functions for orchestration
        
    Args:
        order: Order data dictionary
        event_type: Type of event (e.g., "ORDER_PROCESSED", "ORDER_SHIPPED")
        
    Returns:
        None (fire-and-forget pattern for performance)
        
    Note:
        Errors are caught and logged but don't fail the main process.
        This prevents EventBridge issues from blocking order processing.
    """
    try:
        # Construct event entry for EventBridge
        event_entry = {
            'Source': 'order.service',  # Identifies where event came from
            'DetailType': event_type,    # Type of event for routing rules
            'Detail': json.dumps({       # Actual event payload
                'orderId': order['orderId'],
                'customerId': order['customerId'],
                'status': 'processed',
                'total': order['total'],
                'timestamp': datetime.utcnow().isoformat(),
                'items': order.get('items', [])
            }),
            'EventBusName': EVENT_BUS_NAME  # Custom event bus name
        }
        
        # Send event to EventBridge
        response = events.put_events(Entries=[event_entry])
        
        # Check for failures (EventBridge can partially fail)
        if response.get('FailedEntryCount', 0) > 0:
            print(f"[WARNING] EventBridge partial failure: {response}")
        else:
            print(f"[EVENTBRIDGE] Event sent successfully: {event_type}")
            
    except Exception as e:
        # Log error but don't fail the Lambda execution
        # Order is still processed, just event notification failed
        print(f"[ERROR] Failed to send event to EventBridge: {str(e)}")
        print(f"[ERROR] Event type: {event_type}, Order: {order.get('orderId')}")


def notify_order_status(order: Dict[str, Any], status: str) -> None:
    """
    Send order notification via SNS (fanout to all subscribers).
    
    SNS will deliver this message to all subscriptions:
        - Email addresses (customer notifications)
        - SQS queues (audit logs, async processing)
        - Lambda functions (additional processing)
        - HTTP endpoints (webhooks)
        - SMS numbers (critical alerts)
        
    Args:
        order: Order data dictionary
        status: Order status (e.g., "processed", "shipped", "cancelled")
        
    Returns:
        None (fire-and-forget pattern)
        
    Message Attributes:
        Used by subscribers to filter messages they want to receive.
        Example: Email subscriber only wants "ORDER_SHIPPED" events.
        
    Note:
        Errors are logged but don't fail processing to prevent
        notification issues from blocking order fulfillment.
    """
    # Check if SNS topic ARN is configured
    if not SNS_TOPIC_ARN:
        print("[WARNING] SNS_TOPIC_ARN not configured, skipping notification")
        return
    
    try:
        # Construct notification message
        message = {
            'orderId': order['orderId'],
            'status': status,
            'customerId': order['customerId'],
            'total': order['total'],
            'timestamp': datetime.utcnow().isoformat()
        }
        
        # Publish to SNS topic with message attributes for filtering
        response = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f'Order {order["orderId"]} - {status.upper()}',  # Email subject line
            Message=json.dumps(message, indent=2),  # Pretty-printed JSON for readability
            MessageAttributes={
                # Subscribers can filter on these attributes
                'eventType': {
                    'DataType': 'String',
                    'StringValue': 'ORDER_PROCESSED'
                },
                'orderId': {
                    'DataType': 'String',
                    'StringValue': order['orderId']
                },
                'status': {
                    'DataType': 'String',
                    'StringValue': status
                }
            }
        )
        
        # Log successful publish with message ID for tracking
        message_id = response.get('MessageId', 'unknown')
        print(f"[SNS] Notification sent successfully: {message_id}")
        
    except Exception as e:
        # Log error but don't fail Lambda execution
        # Order processing continues even if notification fails
        print(f"[ERROR] Failed to send SNS notification: {str(e)}")
        print(f"[ERROR] Order: {order.get('orderId')}, Status: {status}")


# Example test event for local testing
if __name__ == "__main__":
    """
    Local testing example.
    
    Run with: python app.py
    
    This simulates an SQS event with one order message.
    """
    test_event = {
        "Records": [
            {
                "messageId": "test-msg-001",
                "receiptHandle": "test-handle",
                "body": json.dumps({
                    "orderId": "ORD-TEST-001",
                    "customerId": "CUST-999",
                    "items": [
                        {
                            "productId": "PROD-1",
                            "quantity": 2,
                            "price": 29.99
                        }
                    ],
                    "total": 59.98
                }),
                "attributes": {
                    "ApproximateReceiveCount": "1"
                }
            }
        ]
    }
    
    # Mock context for local testing
    class MockContext:
        memory_limit_in_mb = 128
        def get_remaining_time_in_millis(self):
            return 10000
    
    # Run handler
    result = lambda_handler(test_event, MockContext())
    print(f"\nTest Result: {json.dumps(result, indent=2)}")
