# Problem 5: Fortify the Castle

Security review of the [Problem 1](../problem1/SOLUTION.md) trading platform architecture. Every `[SEC-n]` tag below marks a specific change from that design; the table after the diagram explains each one.

---

## Updated Architecture (security changes marked)

```
                              Global Users
                                   │
                    ┌──────────────┼──────────────────┐
                    │              │                   │
              [SEC-1] AWS Shield Advanced + Global Accelerator
                    │
        ┌───────────┴────────────┐
        │                        │
   ┌────▼─────┐           ┌──────▼──────┐
   │   NLB     │           │  [SEC-2]     │
   │ (L4, hot  │           │  Thin ALB +  │  ← auth, admin, and any
   │  trading  │           │  AWS WAF     │    non-latency-critical
   │  path)    │           │  (edge path) │    route only
   └────┬─────┘           └──────┬──────┘
        │                        │
   ══════════════ VPC - public subnets end here ══════════════
        │                        │
   ┌────▼─────────────────────────▼─────┐        ┌───────────────────┐
   │   EKS - private subnets            │        │ [SEC-3] Admin API  │
   │   [SEC-4] IRSA, NetworkPolicy      │        │ NOT on public path.│
   │   default-deny, Pod Security       │        │ Internal ALB only, │
   │   "restricted" profile             │        │ reachable via VPN/ │
   │                                    │        │ Client VPN + SSO+  │
   │  ┌──────────┐  ┌─────────────┐    │        │ MFA. No internet   │
   │  │ User API │  │ WebSocket    │    │        │ route.             │
   │  │ (EKS)    │  │ Gateway      │    │        └─────────┬──────────┘
   │  │[SEC-5]   │  │ (AppSync)    │    │                  │
   │  │ authN +  │  └──────┬───────┘    │                  │
   │  │ rate     │         │            │                  │
   │  │ limit    │         │            │                  │
   │  └────┬─────┘         │            │                  │
   └───────┼────────────────┼───────────┘                  │
           │                │                               │
           └────────┬───────┴───────────────────────────────┘
                     │
          ┌──────────▼──────────┐
          │  [SEC-6] Amazon MSK  │  TLS in-transit, KMS at-rest,
          │  (Kafka), private,   │  IAM/SASL-SCRAM auth (no open
          │  no public endpoint  │  broker access), per-topic ACLs
          └──────────┬──────────┘
                     │
          ┌──────────▼──────────┐
          │  Matching Engine     │  [SEC-4] same pod hardening;
          │  (C++ on EKS)        │  [SEC-7] isolated namespace,
          │  + Redis Cluster     │  no route from public-facing
          │  [SEC-8] Redis AUTH  │  pods except via Kafka
          │  + TLS + encrypted   │
          │  at rest             │
          └──────────┬──────────┘
                     │
     ┌───────────────┼────────────────────┐
     │                │                    │
┌────▼────┐   ┌──────▼──────┐      ┌──────▼─────┐
│ Aurora  │   │  DynamoDB    │      │    S3      │
│[SEC-9]  │   │ [SEC-10]     │      │[SEC-11]    │
│ KMS enc,│   │ Audit logs:  │      │ SSE-KMS,   │
│ field-  │   │ TTL removed, │      │ bucket     │
│ level enc│   │ exported to  │      │ policy     │
│ for KYC/│   │ S3 Object    │      │ deny-*     │
│ SSN     │   │ Lock (WORM)  │      │ except role│
└─────────┘   └──────────────┘      └────────────┘

          [SEC-12] Custody / withdrawal signing service
          (AWS CloudHSM or equivalent, multi-party approval
          for withdrawals above threshold) - NOT inline with
          the hot trading path; separate control plane.

          [SEC-13] Secrets Manager + KMS - all DB/Redis/Kafka
          credentials, rotated automatically, injected via
          External Secrets Operator (no plaintext in env vars
          or ConfigMaps).

          [SEC-14] GuardDuty + Security Hub + CloudTrail, all
          shipped to a central SIEM; EventBridge rules alert
          on IAM/SG changes and GuardDuty findings in real time.
```

---

## Security Changes: What, Why, Protects Against

| Tag | Change | Protects against | Priority |
|---|---|---|---|
| **SEC-1** | Upgrade to **AWS Shield Advanced** on the Global Accelerator/NLB edge (was: default Shield Standard, unstated) | Volumetric/protocol DDoS against a platform whose entire value proposition is availability; Shield Standard alone gives no SLA-backed response team or cost protection during an attack | Ship |
| **SEC-2** | Add a **thin ALB + AWS WAF path** alongside the existing NLB, used only for auth endpoints, the admin API, and any HTTP(S) route that doesn't need sub-ms L4 routing | NLB is L4-only and *cannot* attach WAF. The original design put 100% of traffic on NLB for latency, which meant zero WAF coverage anywhere - including login/auth, the most attacked surface on any exchange. This keeps the hot order-matching path on NLB (no added latency there) while giving WAF (SQLi/XSS/bot rules, rate-based rules) to the parts that actually get attacked | Ship |
| **SEC-3** | **Admin API removed from the public path entirely.** Original design had it behind the same Global Accelerator as the user-facing API. Now: internal ALB only, reachable via Client VPN, with SSO + mandatory MFA | Admin endpoints (user impersonation, balance adjustments, trading halts) are the highest-value target on the platform. Exposing them on the same internet-facing edge as public trading traffic was the single biggest gap in the original design | Ship - refuse to ship without this |
| **SEC-4** | **EKS hardening**: IRSA (IAM Roles for Service Accounts) instead of node-level IAM roles, default-deny NetworkPolicies with explicit allow rules per service, Pod Security Standards "restricted" profile (no privileged containers, read-only root FS, non-root, dropped capabilities) | Blast radius of a single compromised pod. Without this, one vulnerable dependency in any EKS workload inherits node-wide AWS permissions and unrestricted pod-to-pod network access - including a straight line to Aurora and the matching engine | Ship |
| **SEC-5** | **AuthN + rate limiting on the User API**: short-lived JWT access tokens + refresh tokens, mandatory MFA on withdrawal/API-key-creation actions, per-user and per-IP rate limits on login and order submission | Credential stuffing, brute force, and order-spam DoS against the one API surface every retail user touches directly | Ship |
| **SEC-6** | **MSK hardened**: TLS in-transit, KMS encryption at rest, SASL/SCRAM or IAM auth (no unauthenticated broker access), per-topic ACLs so, e.g., the User API can produce to `orders` but not consume `trades.internal` | Original design treated Kafka purely as a throughput/durability choice with no mention of who can read/write which topics. An event log holding every order and trade is a prime target - unauthenticated or over-permissioned access here is a direct path to front-running or order forgery | Ship |
| **SEC-7** | **Matching engine isolated in its own namespace**, reachable only from Kafka consumers - no direct network path from public-facing API pods | Limits what an attacker who compromises the (higher-exposure) API tier can reach; the matching engine is where money actually moves | Ship |
| **SEC-8** | **Redis Cluster**: AUTH token required, TLS in-transit, encryption at rest (was: unstated, implicitly open within the VPC) | Redis holds the live order book state. Unauthenticated Redis is a classic breach vector (mass Redis ransomware campaigns exist specifically because "it's just internal cache" gets left open) | Ship |
| **SEC-9** | **Aurora**: KMS encryption at rest (was unstated) + **field-level encryption/tokenization for SSN and KYC document references** specifically, not the whole schema | Account balances and settled trade history are already behind Aurora's network boundary, but PII (SSN, KYC data) needs a second layer so a DB-level compromise or an overly-broad read query doesn't dump raw PII in plaintext | Ship (PII fields); full-schema field-level encryption deferred, see below |
| **SEC-10** | **DynamoDB audit logs: removed the 90-day TTL auto-delete**, added export to **S3 with Object Lock (WORM)** for long-term retention | This is a direct correction to the original design, not just an addition. Auto-deleting audit/compliance logs after 90 days likely violates financial recordkeeping requirements (typically 5–7 years depending on jurisdiction) and undermines non-repudiation - the exact thing an audit log exists for | Ship - refuse to ship without this |
| **SEC-11** | **S3 cold storage**: SSE-KMS + bucket policy denying all principals except the specific IAM role that needs it (was: unstated) | Default S3 buckets and permissive bucket policies are one of the most common real-world breach causes; this is table stakes, not optional | Ship |
| **SEC-12** | **Withdrawal/custody signing pulled out as a separate control plane** (CloudHSM-backed or equivalent, multi-party approval above a configurable threshold), explicitly *not* inline with the low-latency trading path | If this platform custodies crypto assets, the original design had no answer at all for how withdrawals get signed. Software-only signing inline with application logic is the highest-severity single point of failure possible on an exchange - this needs to be assumed compromised-until-proven-otherwise and isolated accordingly | Ship - refuse to ship without this **if** the platform custodies assets (see open questions) |
| **SEC-13** | **Secrets Manager + KMS for all credentials**, rotated automatically, delivered to EKS via External Secrets Operator | Original design didn't address secrets at all. Hardcoded or env-var credentials are the default failure mode for "it worked in the demo" architectures | Ship |
| **SEC-14** | **GuardDuty + Security Hub, fed into a central SIEM**, with EventBridge alerting on IAM/security-group changes and GuardDuty findings | CloudTrail and VPC Flow Logs (already in the original design) are collection, not detection - without something consuming them, a breach is discovered by a customer noticing a wrong balance, not by the platform | Ship |

---

## What I secured first, and why

Priority order, roughly matching the table above:

1. **Admin API exposure (SEC-3) and audit log retention (SEC-10)** - these aren't hardening, they're design errors in the original architecture that create a compliance failure or a walk-up attack surface on day one. Fixing "wrong" comes before adding "more."
2. **Custody/withdrawal signing (SEC-12)** - if applicable at all (see open questions), this is the one component where a design gap translates directly and irreversibly into stolen customer funds. Everything else is defense in depth; this is the one thing with no acceptable failure mode.
3. **Network segmentation and auth (SEC-2, SEC-4, SEC-5, SEC-6, SEC-7, SEC-8)** - the bulk of "make it not trivially exploitable": WAF where it can attach, default-deny networking, authenticated internal services. This is where most real-world breaches actually happen (an open Redis, an over-permissioned pod, an unauthenticated Kafka broker), so it gets weight proportional to how often it's the actual root cause in industry incidents, not just how it sounds architecturally.
4. **Encryption at rest/in transit and secrets management (SEC-8, SEC-9, SEC-11, SEC-13)** - genuinely important, but a well-configured VPC with no encryption is still harder to breach than an encrypted database sitting on a network anyone can reach. I ranked segmentation above encryption for that reason, not because encryption is optional.
5. **Detection (SEC-14)** - last in this list only because it doesn't prevent anything by itself; it determines how fast you find out prevention failed. It's still a "ship" item, not a "later" item.

## What I deliberately left out, and the trade-offs

- **Full service mesh / mTLS between every internal microservice (e.g., Istio).** VPC-level network policies (SEC-4/7) plus MSK's own TLS+auth (SEC-6) cover most of the realistic threat model - an attacker who's already pivoted inside the private subnets. A full mesh adds real latency and operational overhead to a system whose stated requirement is p99 <100ms, for a marginal security gain over what's already covered. I'd revisit this if a threat model or pentest specifically identified east-west traffic interception as a live risk, not preemptively.
- **Field-level encryption for the entire Aurora schema**, not just SSN/KYC (SEC-9). Encrypting every column adds query complexity and performance cost across the board. I scoped it to the fields that are actually high-sensitivity PII and left ordinary account metadata behind Aurora's existing network + at-rest encryption boundary. This is a judgment call I'd revisit after an actual data classification exercise, not before.
- **Real-time market manipulation / anomalous trading detection** (spoofing, wash trading, layering). This is a legitimate and serious risk for an exchange, but it's a risk/compliance modeling problem, not an infrastructure security problem - it needs input from people who understand market-abuse patterns, not just an architecture diagram. I'm flagging it as *needed* but explicitly out of scope for this exercise rather than inventing a fake detection pipeline to look complete.
- **Multi-region active-active security posture** (e.g., independent KMS keys/HSMs per region, cross-region secret replication policy). Problem 1 already scoped multi-region as a "Phase 2/3 growth" concern, not day-one. Security posture for infrastructure that doesn't exist yet is speculative; I'd design it when the multi-region rollout is actually planned, informed by that plan's specifics.
- **Automated dependency/SCA scanning and image signing in CI.** Genuinely belongs here, but it's the same concern already covered in depth in [Problem 4](../problem4/SOLUTION.md)'s pipeline design - I didn't duplicate it, just note that the EKS workloads in this architecture should be built by a pipeline with those gates, not a bare `docker build`.

## Facts I don't have - what I'd need, how I'd get it, what I assumed meanwhile

| Unknown | Why it matters | How I'd get it | What I assumed for this design |
|---|---|---|---|
| Does this platform actually custody customer crypto assets, or is it fiat/synthetic exposure only? | Determines whether SEC-12 (HSM custody, multi-party withdrawal approval) is a hard requirement or entirely inapplicable | Ask product/engineering leadership directly - this is a one-sentence question with an architecture-defining answer | Assumed **yes** (matches the "Binance-like" framing in Problem 1) and designed SEC-12 as a requirement; flagged it as conditional in the table above rather than asserting it unconditionally |
| Regulatory jurisdiction(s) - US (FinCEN/MSB), EU (MiCA), Singapore (MAS), etc. | Directly determines KYC/AML control requirements, audit log retention period (I assumed 5–7 years for SEC-10; actual number varies by regime), and data residency constraints | This needs legal/compliance sign-off, not an engineering guess - I'd request the target jurisdictions from legal before finalizing SEC-10's exact retention period | Assumed a conservative multi-year retention floor rather than picking a specific number, and designed for "extendable," not a hardcoded value |
| Existing corporate identity provider (Okta, Azure AD, etc.) | SEC-3's admin SSO+MFA needs to integrate with whatever IdP the org already runs, rather than standing up a parallel one | Ask the platform/IT team what's already in use | Assumed a generic SAML/OIDC-compatible IdP exists or would be stood up; didn't hardcode a specific vendor |
| Results of any prior threat model or penetration test | Would tell me which of these risks are theoretical vs. already-demonstrated, and re-prioritize accordingly | Request from the security team if one exists; if not, this design itself should be the input to commissioning one | Assumed none exists yet - treated every item above as unverified until a pentest says otherwise |
| Actual current data classification of every field in the Aurora schema | Needed to make the field-level-encryption scoping decision (SEC-9) precisely rather than by best guess | Requires a data classification exercise with whoever owns the schema | Assumed SSN + KYC document references are the highest-sensitivity fields based on the fields Problem 1 explicitly named ("user accounts, account balances") and treated everything else as standard-sensitivity pending that exercise |

## What I would refuse to ship without

Restating plainly, since the task asked directly: **SEC-3** (admin API off the public path), **SEC-10** (audit logs can't auto-delete), and **SEC-12** (custody/withdrawal signing isolated from the hot path, if the platform custodies assets at all). Everything else in the "Ship" priority column is important and I'd push hard for it, but these three are the ones where shipping without them isn't a risk trade-off - it's either a guaranteed compliance failure or a direct path to stolen funds, not a probabilistic one.
