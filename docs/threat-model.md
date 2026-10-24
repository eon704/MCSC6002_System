# Threat Model (STRIDE)

Secure Microservices Inventory System. State as of 2026-10-24.

## Method

- STRIDE per component and trust boundary.
- Risk = Likelihood x Impact, each Low/Medium/High; risk shown before mitigation.
- Status: Done (implemented and checked, by the attack suite or by hand), Partial, Planned, N/A (does not apply to this design).

## Assets

| Asset | Why it matters |
|---|---|
| JWT signing key (RSA private) | Whoever holds it can mint any user/permission |
| User credentials, refresh tokens | Account takeover |
| Product and stock data | Tampering = financial loss, supply chain fraud |
| Queue events (ProductCreated/Deleted) | Drive inventory changes without an API call |
| mTLS certs (CA, gateway client) | Bypass of the gateway |

## Trust boundaries

| ID | Boundary | Control |
|---|---|---|
| TB1 | Internet -> API Gateway | HTTPS, JWT, permission check per route |
| TB2 | Gateway -> services | mTLS, project CA only, CN=api-gateway; one server certificate per service |
| TB3 | Services -> RabbitMQ | Own broker account (not guest), shared by both services; AMQP over TLS only (project CA cert, checked by services); management API plain HTTP, localhost only; HMAC-SHA256 signed events, 5-min replay window |
| TB4 | Services -> SQL Server, Redis | EF Core; SQL Encrypt=True (cert not verified); Redis password |
| TB5 | Inventory -> Gateway (product lookup) | HTTPS (gateway cert checked against the project CA), forwarded user JWT |

## Threats

| ID | STRIDE | Component | Threat | Risk | Mitigation | Status |
|---|---|---|---|---|---|---|
| S1 | Spoofing | All | Forged JWT using shared HS256 secret (was in 4 configs) | High | RS256; private key only in Identity, others get public key | Done |
| S2 | Spoofing | All | Algorithm confusion (none, HS256, RS384) | High | ValidAlgorithms pinned to RS256 (incl. refresh) | Done |
| S3 | Spoofing | Services | Direct call bypassing gateway | High | mTLS; services reject any client cert except gateway's | Done |
| S4 | Spoofing | Identity | Password brute force / weak passwords | High | Gateway 5 req/min per IP on /auth/*; lockout after 5 failures (15 min); min 12 chars (NIST 800-63B: length over composition) and 6 unique (our rule), enforced on user creation; seeded users get random 24-char passwords. Accepted residual: lockout lets an attacker lock a known account | Done |
| S5 | Spoofing | RabbitMQ | Fake events published by anyone with broker access | High | Own broker account (not guest) from .env; Inventory accepts only events HMAC-signed with a key shared by Product and Inventory | Done |
| T1 | Tampering | Gateway, services | Edited JWT payload (add permission) | High | Signature validated at gateway and again in service | Done |
| T2 | Tampering | TB2 | MITM between gateway and services | High | TLS + mTLS, custom CA trust, hostname check | Done |
| T3 | Tampering | RabbitMQ | Modified or replayed event (Quantity, ProductId) | High | HMAC over type + timestamp + serialized message, checked in a consume filter; rejects go to the _error queue (done). AMQP over TLS with project CA cert, plain port closed (done). Open: replays within 5 min; one key shared by Product and Inventory, so Inventory could also sign events. Planned: message ids, per-service keys | Partial |
| T4 | Tampering | Services, DB | SQL injection | Medium | EF Core parameterized queries; FluentValidation in all three services (Inventory: known statuses only) | Done |
| T5 | Tampering | Build | Dependency confusion: shared AuthLibrary/ResponseLibrary are not on nuget.org, which hosts unrelated packages with the same names; a clean restore pulled AuthLibrary 2.0.0 | High | Exact packages bundled in each repo (nuget-local); nuget.config packageSourceMapping limits both names to that folder | Done |
| R1 | Repudiation | Product, Inventory | No record of who changed products or stock | Medium | Audit log with user id (NameIdentifier) per write | Planned |
| I1 | Info disclosure | Gateway | Exception messages and internal URLs in responses | Medium | Generic messages; details to server log | Done |
| I2 | Info disclosure | Services | Dev exception page (stack trace) passed through gateway | Medium | Gateway replaces every downstream 5xx body with a generic message; direct calls blocked by mTLS | Done |
| I3 | Info disclosure | Gateway | Server header fingerprinting | Low | Server/X-Powered-By stripped, incl. downstream copies | Done |
| I4 | Info disclosure | Repos | Secrets in git: seed passwords, RabbitMQ creds, old HS256 secret in history | High | DB/broker/Redis/seed passwords moved to a git-ignored .env, passed to the containers as environment variables; HS256 secret in history but unused; all services share SQL sa login | Partial |
| I5 | Info disclosure | Identity DB | Refresh tokens stored in plaintext | Medium | Only the SHA-256 hash is stored; constant-time compare | Done |
| I6 | Info disclosure | JWT | Email and phone in readable token payload | Low | Keep only id and permissions | Planned |
| I7 | Info disclosure | TB4 | SQL traffic unencrypted | Medium | Encrypt=True (done); trusted server cert instead of TrustServerCertificate=True (planned) | Partial |
| D1 | DoS | Inventory | ProductCreated.Quantity unbounded; consumer creates one row per unit | High | Quantity 1..1000 in Product validators and again in the Inventory consumer | Done |
| D2 | DoS | Gateway | No request rate limiting | Medium | Per-IP limit on /auth/* (done); other routes (planned) | Partial |
| D3 | DoS | All | Oversized bodies (Kestrel default ~28 MB) | Low | Gateway MaxRequestBodySize 2 MB; services reachable only through the gateway | Done |
| E1 | EoP | Gateway, services | Basic user calls admin endpoint (BFLA) | High | Permission claim at gateway (RouteClaimsRequirement) + [HasPermission] in service | Done |
| E2 | EoP | Clients | Stolen access token reused | Medium | 15-min lifetime; refresh token rotated on each use | Done |
| E3 | EoP | Identity | Old access token + leaked refresh token -> new session | Medium | Rotation, 1-day expiry, revoke on logout (/auth/revoke-token) (done); reuse detection (planned) | Partial |
| E4 | EoP | Services | BOLA/IDOR on records | Low | No per-user records in current model; revisit if ownership added | N/A |
| E5 | EoP | mTLS | Stolen gateway cert (PFX without password, no revocation) | Medium | Mounted read-only into the gateway container only; password, Docker secrets, short validity, CRL if needed | Planned |

## Summary

| Status | Count |
|---|---|
| Done | 17 |
| Partial | 5 |
| Planned | 3 |
| N/A | 1 |

## Top open risks

- T3: signed events can be replayed within 5 minutes; Product and Inventory share one HMAC key.
- R1: no audit log of who changed products or stock.
- E3: a leaked refresh token works once; no reuse detection.
