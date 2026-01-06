# event-driven-order-processing

# AWS Event-Driven Order Processing System
A production-ready, event-driven order processing system built with AWS serverless services. This project demonstrates microservices architecture, asynchronous messaging, fault tolerance, and observability patterns used by companies like Amazon, Netflix, and Uber.

## 🎯 Project Overview

This system implements a complete order processing workflow using:
- **SQS** for message queuing and decoupling
- **SNS** for fanout notifications to multiple subscribers
- **EventBridge** for intelligent event routing
- **Lambda** for serverless compute
- **CloudWatch** for monitoring and observability

### Architecture Diagram

```
Customer Order
     ↓
[API Gateway]
     ↓
[SQS Queue: OrderProcessingQueue] ← Buffer for async processing
     ↓
[Lambda: OrderProcessor] ← Business logic
     ↓
[EventBridge] ← Event router
     ↓
   ┌─────┴─────┬──────────┐
   ↓           ↓          ↓
[SNS Topic] [Lambda 2] [SQS Audit]
   ↓
Email/SMS/Webhooks
```

## 🚀 Features

- ✅ **Asynchronous Processing** - Non-blocking order handling
- ✅ **Fault Tolerance** - Automatic retries with exponential backoff
- ✅ **Dead Letter Queue** - Failed message isolation
- ✅ **Event-Driven Architecture** - Loose coupling between services
- ✅ **Fanout Pattern** - One event, multiple subscribers
- ✅ **Idempotency** - Safe message reprocessing
- ✅ **Observability** - CloudWatch logs, metrics, and alarms
- ✅ **Free Tier Optimized** - Costs $0 to run and test
