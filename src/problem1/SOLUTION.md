# Problem 1: Highly Available Trading System Architecture

## Executive Summary

This solution designs a highly available, low-latency trading platform similar to Binance, capable of handling **500 requests/second with p99 latency <100ms**. The architecture uses a microservices approach with a **high-performance C++ matching engine**, decoupled from the user-facing API via event streaming and WebSocket fan-out.

**Key Design Principles:**
- Separation of concerns (matching engine ≠ API layer)
- Event-driven data flow (Kafka as source of truth)
- Memory-first state management (Redis)
- Multi-AZ active-active design for resilience

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Global Users                             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                ┌────────▼─────────┐
                │  AWS Global      │
                │  Accelerator +   │
                │  NLB             │ (Layer 4, <1ms routing)
                └────────┬─────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   ┌────▼─────┐  ┌──────▼──────┐  ┌─────▼─────┐
   │  User    │  │  WebSocket  │  │  Admin    │
   │  API     │  │  Gateway    │  │  API      │
   │  (EKS)   │  │  (AppSync)  │  │  (EKS)    │
   └────┬─────┘  └──────┬──────┘  └─────┬─────┘
        │               │                │
        └───────────────┼────────────────┘
                        ▼
            ┌───────────────────────┐
            │   Amazon MSK (Kafka)  │  Event Log/Queue
            │  (Multi-AZ, Replicas) │
            └───────────┬───────────┘
                        │
            ┌───────────▼───────────┐
            │  Matching Engine      │
            │  (C++ on EKS)         │ Primary + Standby
            │  + Redis Cluster      │
            └───────────┬───────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐   ┌─────▼──────┐  ┌────▼─────┐
   │ Aurora  │   │  DynamoDB  │  │    S3    │
   │(User    │   │ (Audit     │  │(Cold     │
   │ Accts)  │   │  Logs)     │  │ Storage) │
   └─────────┘   └────────────┘  └──────────┘
```

---

## Core Service Components

### 1. Traffic Management: AWS Global Accelerator + NLB

**What it does:**
- Routes incoming traffic from global users to nearest healthy endpoint
- Maintains persistent TCP connections for WebSocket/live price feeds
- Provides instant failover across Availability Zones

**Why this choice:**
- **NLB** operates at **Layer 4 (Transport)**, processing millions of packets/second with microsecond latency
- **Global Accelerator** anchors connections at AWS edge, reducing jitter and enabling automatic zone failover
- Essential for handling 500 sustained concurrent connections with sub-ms latency

**Alternatives considered:**
- **Application Load Balancer (ALB)**: Layer 7 processing adds ~10-50ms latency per request (too slow)
- **CloudFront**: Better for static content caching; introduces jitter for real-time trading

**Capacity:** NLB can handle 100+ million requests/sec; easily handles 500 RPS

---

### 2. Order Submission API: REST endpoints on Amazon EKS

**What it does:**
- Receives market orders, limit orders, and cancellations from traders
- Validates inputs and pushes orders to Kafka
- Scales horizontally based on request volume

**Technology:**
- **Amazon EKS** (Elastic Kubernetes Service) with auto-scaling
- Node groups with **c5.2xlarge** instances (8 vCPU, 16GB RAM)
- Horizontal Pod Autoscaler (HPA) targeting 70% CPU

**Why this choice:**
- Kubernetes enables fine-grained scaling at the pod level
- Stateless design allows horizontal scaling to handle 500 RPS
- Native integration with AWS (IAM, CloudWatch, load balancers)

**Performance:** 
- Single pod handles ~10-20 orders/sec
- 25-50 pods needed to handle 500 RPS safely with headroom

**Alternatives considered:**
- **Lambda**: Cold start latency (100-500ms) incompatible with trading requirements
- **Fargate**: Simpler but less cost-effective for sustained load

---

### 3. Event Streaming: Amazon MSK (Managed Streaming for Kafka)

**What it does:**
- Acts as the **immutable event log** for all orders and trades
- Decouples order submission from matching engine
- Enables perfect reconstruction of order book state

**Configuration:**
- **Multi-AZ deployment** with 3+ brokers (one per AZ)
- **Replication factor 3** (survives any 2-node failure)
- **Topic retention: 7 days** (for regulatory compliance and debugging)

**Why this choice:**
- Industry standard for high-throughput financial systems
- Ensures **no order is lost**, even if matching engine crashes
- Enables event replay to rebuild state

**Performance:**
- Kafka can handle 1M+ messages/sec easily
- 500 orders/sec = minimal load

**Alternatives considered:**
- **Simple Queue Service (SQS)**: Limited visibility, no replay capability
- **RabbitMQ (self-managed)**: Requires operational overhead; AWS should handle that

---

### 4. Matching Engine: High-Performance C++ Service

**What it does:**
- Consumes orders from Kafka
- Performs order matching in memory using efficient data structures
- Updates order book and generates trade events
- Pushes results back to Kafka for subscribers

**Architecture:**
- **Primary-Replica pattern**: BTC/USDT matches on one dedicated service instance
- **Hot standby** waiting to take over if primary fails (failover <2 seconds)
- Each trading pair runs in isolation (no global lock contention)

**Technology:**
- **C++ with Boost libraries** and **std::map/std::set** for order book data structures
- **Redis Cluster Mode** for real-time state caching (sub-millisecond lookups)
- **Memory-first**: entire order book for a pair fits in <1GB for most pairs

**Why C++:**
- Deterministic performance (no garbage collection pauses like Java)
- Lock-free data structures enable matching at nanosecond scale
- Memory control prevents cache misses (keep hot data in L1/L2 cache)

**Performance targets:**
- **Matching latency**: <5ms (order received → order matched → event published)
- **Throughput**: 1000+ matches/second per instance (handles 100+ trading pairs)

**Alternatives considered:**
- **Java**: GC pauses cause p99 latencies >100ms (unacceptable)
- **Python/Go**: Interpreted overhead causes latency variance

---

### 5. Real-Time Price Feed: AWS AppSync with WebSockets

**What it does:**
- Subscribes to trade events from Kafka
- Fans out live order book updates and price tickers to thousands of connected traders simultaneously
- Decouples the matching engine from client connections

**Configuration:**
- **AppSync subscriptions** (GraphQL over WebSocket)
- Auto-scales connections up to 1M simultaneous users
- AWS manages all the hard parts (connection management, retry logic, etc.)

**Why this choice:**
- Massive fan-out capacity (1 matching engine output → 10,000+ websocket clients)
- Handles network jitter and drops gracefully
- DevOps team doesn't manage WebSocket server lifecycle

**Performance:**
- Latency: Price tick published → delivered to client ≈ 50-100ms (includes network RTT)

**Alternatives considered:**
- **Self-managed Socket.IO**: Requires managing WebSocket servers, round-robin, connection state
- **RabbitMQ with STOMP**: Adds operational burden

---

### 6. Persistence Layer: Aurora PostgreSQL + DynamoDB

**Aurora PostgreSQL:**
- **Purpose**: Stores user profiles, account balances, and settled trade history
- **Configuration**: 
  - **Multi-AZ**: 1 primary + 2 read replicas (automatic failover <30 seconds)
  - **Instance type**: **db.r5.2xlarge** (8 vCPU, 64GB RAM)
  - **Backup retention: 35 days** (compliance + recovery)
- **Why**: ACID guarantees on account balances; 3x faster than RDS PostgreSQL

**DynamoDB:**
- **Purpose**: High-volume audit logs and real-time trade history
- **Configuration**:
  - **On-demand billing** (pay per request, no capacity planning)
  - **Partition key**: `user_id + timestamp`
  - **TTL: 90 days** (auto-delete old records to save storage)
- **Why**: Handles 500+ writes/second effortlessly; operational simplicity

**Alternatives considered:**
- **MongoDB**: Requires replication tuning; eventual consistency risks
- **Cassandra**: Operationally complex; Aurora is simpler for transactional needs

---

## Addressing the 500 RPS & <100ms p99 Latency Requirements

| Component | RPS Capacity | p99 Latency | Notes |
|-----------|--------------|-------------|-------|
| **NLB** | 100M+/sec | <1ms | Negligible bottleneck |
| **EKS API Pods** | 500-1000/sec | 20-30ms | Kafka write + validation |
| **Kafka Broker** | 1M+/sec | <5ms | Async write; no bottleneck |
| **Matching Engine (C++)** | 1000+/sec | 5-10ms | Per-pair isolation |
| **AppSync fan-out** | 1000s/sec | 50-100ms | Network RTT included |
| **Aurora writes** | 1000s/sec | 10-20ms | Multi-AZ replication |
| **Total end-to-end** | **500/sec** | **<100ms** ✅ | Latencies *additive*; path: API (30ms) → Kafka (5ms) → Matching (8ms) → AppSync (50ms) |

---

## Scaling Strategy

### Current Setup (500 RPS)

| Component | Current Size | Handles |
|-----------|--------------|---------|
| NLB + Global Accelerator | 1 per region | 500 RPS |
| EKS API cluster | 30 pods, 10 nodes | 500 API requests/sec |
| Kafka | 3 brokers, 3 AZs | Easily |
| Matching engines | 1 per trading pair (20-50 pairs) | 100 pair trading |
| Aurora | 1 primary + 2 replicas | ACID at 500 writes/sec |
| DynamoDB | On-demand | Scales instantly |

### Phase 1: 5,000 RPS (10x growth)

**Scaling actions:**
1. **EKS**: Increase to 300 pods (auto-scale rules already enable this)
2. **Kafka**: Increase broker count to 6-9 (more partition leaders)
3. **Matching engines**: Deploy 2-3 standby instances per trading pair
4. **Aurora**: Upgrade to **db.r5.4xlarge** and add read replicas for reporting

**Cost**: ~$50K-70K/month (vs $5-8K today)

### Phase 2: 50,000 RPS (100x growth)

**New architecture decisions:**
1. **Shard by geography**: Deploy separate clusters in US-East, US-West, EU, Asia-Pacific
2. **DynamoDB Global Tables**: Sync user balances across regions in <1 second
3. **Caching layer**: Add **ElastiCache (Redis)** for frequently accessed balances
4. **API sharding**: Route users to nearest regional cluster based on IP geolocation

**Cost**: ~$500K-700K/month

### Phase 3: 500,000 RPS (1000x growth)

**Enterprise setup:**
1. **Dedicated matching engine clusters** per region + trading pair
2. **DynamoDB + S3**: Move cold data to Glacier for cost savings
3. **Kinesis Data Firehose**: Stream audit logs to S3 for analytics (Athena)
4. **CloudFront**: Edge caching for price tickers to reduce AppSync load

**Cost**: $5M+/month

---

## High Availability & Resilience

### Multi-AZ Active-Active Design

Every component runs across 3 AZs simultaneously:

```
Primary AZ West         Primary AZ Central      Primary AZ East
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ EKS Pod          │   │ EKS Pod          │   │ EKS Pod          │
│ Kafka Broker #1  │   │ Kafka Broker #2  │   │ Kafka Broker #3  │
│ Redis Node #1    │   │ Redis Node #2    │   │ Redis Node #3    │
│ Aurora Replica   │   │ Aurora Primary   │   │ Aurora Replica   │
└──────────────────┘   └──────────────────┘   └──────────────────┘
                           ▲
                           │
                      (Leader election
                       if Central fails)
```

**Failover sequence:**
- AZ becomes unavailable (network partition)
- Kafka rebalances (pick new broker leader from remaining AZs)
- Matching engine health check fails; replica in healthy AZ takes over (<2 sec)
- Aurora auto-promotes a read replica to primary
- **Result**: Seamless; no visible user impact

### For Matching Engine Specifically

**Primary-Replica Pattern:**
- Primary: Actively matching orders for BTC/USDT
- Replica: Idle, waiting, consuming same Kafka stream, rebuilding order book state
- **Failover**: If primary dies, replica is already 100% caught up; switches on in <100ms

**Data loss prevention:**
- Every order and match is persisted to Kafka (disk-synced)
- No in-memory-only state (even though matching is in-memory for speed)
- State reconstruction: Replay Kafka log from last checkpoint

---

## Cost Optimization

| Service | Monthly Cost (500 RPS) | Notes |
|---------|------------------------|-------|
| **EKS Compute** | $2,000 | 10 c5.2xlarge nodes, on-demand |
| **Kafka** | $800 | 3 brokers, moderate throughput |
| **Redis** | $600 | Cluster mode, 6 shards, 1GB each |
| **Aurora** | $1,500 | Multi-AZ, db.r5.2xlarge |
| **DynamoDB** | $400 | On-demand, small audit logs |
| **AppSync** | $300 | ~$50/million WebSocket MSG |
| **NLB + Global Accel** | $500 | LCU pricing + acceleration |
| **S3 (inactive logs)** | $50 | Cold storage tier |
| **Total** | **~$6,000/month** | Highly available, scalable |

**Cost-saving opportunities:**
- Use **Reserved Instances** for EKS and Aurora (30-40% discount)
- **Spot instances** for non-critical services (30-70% discount)
- **DynamoDB TTL** to auto-delete old records
- **S3 Intelligent Tiering** for automatic archival

---

## Future Growth & Advanced Features

### Cross-Region Deployment (Global Trading)

**For users in Tokyo, London, Singapore:**
- Deploy entire stack (EKS, Kafka, Matching Engine) in regional data centers
- **DynamoDB Global Tables**: Replicate user balances to all regions (<1 sec consistency)
- Regional NLBs + Global Accelerator route users to nearest region
- Cross-region settlement happens asynchronously via SNS/SQS

### Margin Trading & Derivatives

**New components:**
- **Risk Engine**: Separate service monitors leveraged positions (uses DynamoDB for exposure tracking)
- **Liquidation Engine**: Triggers automated liquidations if collateral drops
- **Futures Matching**: Separate matching engine for perpetual contracts

### Analytics & Real-Time Dashboards

**New data pipeline:**
- **Kinesis Data Firehose**: Stream all trades to S3 (Parquet format)
- **Athena**: SQL queries on historical trades (user dashboard)
- **QuickSight**: Executive dashboards on trading volume

### Compliance & Audit Trail

**Already in place:**
- **DynamoDB audit logs** with user actions and timestamps
- **CloudTrail**: Logs all AWS API calls for security audits
- **VPC Flow Logs**: Network traffic for detecting DDoS/attacks

---

## Technology Justification Summary

| Layer | Technology | Why Not Alternative |
|-------|-----------|---------------------|
| **Load Balancer** | NLB + Global Accel | ALB too slow; CloudFront adds jitter |
| **API Server** | EKS (Kubernetes) | Lambda too slow; Fargate less cost-efficient |
| **Event Log** | Kafka | SQS lacks replay; RabbitMQ adds ops |
| **Matching Engine** | C++ | Java/Go GC pauses; Python too slow |
| **State Cache** | Redis Cluster | Memcached lacks persistence; DynamoDB too slow |
| **Real-time Feed** | AppSync | Self-managed WebSockets; MQTT adds latency |
| **User DB** | Aurora | Self-managed Postgres; DDB eventual consistency |
| **Audit Log** | DynamoDB | Postgres/Aurora slower for high-write; Cassandra complex |

This architecture prioritizes **low-latency trading performance** while maintaining **high availability** and **cost efficiency** at scale.
