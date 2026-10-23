# Threat Model (STRIDE)

Secure Microservices Inventory System. State as of 2026-10-23.

## Method

- STRIDE per component and trust boundary.
- Risk = Likelihood x Impact, each Low/Medium/High; risk shown before mitigation.
- Status: Done (implemented and tested), Partial, Planned, Open (no owner yet).

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
| TB2 | Gateway -> services | mTLS, project CA only, CN=api-gateway |
| TB3 | Services -> RabbitMQ | None yet (plain AMQP, guest/guest) |
| TB4 | Services -> SQL Server, Redis | EF Core; connections not encrypted, Redis without auth |
| TB5 | Inventory -> Gateway (product lookup) | HTTPS, forwarded user JWT |

## Threats

| ID | STRIDE | Component | Threat | Risk | Mitigation | Status |
|---|---|---|---|---|---|---|
| S1 | Spoofing | All | Forged JWT using shared HS256 secret (was in 4 configs) | High | RS256; private key only in Identity, others get public key | Done |
| S2 | Spoofing | All | Algorithm confusion (none, HS256, RS384) | High | ValidAlgorithms pinned to RS256 (incl. refresh) | Done |
| S3 | Spoofing | Services | Direct call bypassing gateway | High | mTLS; services reject any client cert except gateway's | Done |
| S4 | Spoofing | Identity | Password brute force (min length 6, seed pwd 123456, no lockout) | High | Gateway: 5 req/min per IP on /auth/* (429); planned: Identity lockout, stronger policy | Partial |
| S5 | Spoofing | RabbitMQ | Fake events published with default credentials | High | Dedicated broker users, HMAC-signed events | Open |
| T1 | Tampering | Gateway, services | Edited JWT payload (add permission) | High | Signature validated at gateway and again in service | Done |
| T2 | Tampering | TB2 | MITM between gateway and services | High | TLS + mTLS, custom CA trust, hostname check | Done |
| T3 | Tampering | RabbitMQ | Modified event (Quantity, ProductId) | High | HMAC per event, AMQP over TLS | Planned |
| T4 | Tampering | Services, DB | SQL injection | Medium | EF Core parameterized queries; FluentValidation in Identity, Product | Partial (Inventory: no validators) |
| R1 | Repudiation | Product, Inventory | No record of who changed products or stock | Medium | Audit log with user id (NameIdentifier) per write | Planned |
| I1 | Info disclosure | Gateway | Exception messages and internal URLs in responses | Medium | Generic messages; details to server log | Done |
| I2 | Info disclosure | Services | Dev exception page (stack trace) passed through gateway | Medium | Run Production; UseExceptionHandler in services | Partial |
| I3 | Info disclosure | Gateway | Server header fingerprinting | Low | Server/X-Powered-By stripped, incl. downstream copies | Done |
| I4 | Info disclosure | Repos | Secrets in git: seed passwords, RabbitMQ creds, old HS256 secret in history | High | Env vars, User Secrets, Docker secrets; HS256 secret no longer used | Planned |
| I5 | Info disclosure | Identity DB | Refresh tokens stored in plaintext | Medium | Store SHA-256 hash, constant-time compare | Planned |
| I6 | Info disclosure | JWT | Email and phone in readable token payload | Low | Keep only id and permissions | Planned |
| I7 | Info disclosure | TB4 | SQL traffic unencrypted (Encrypt=False) | Medium | Encrypt=True with trusted cert | Planned |
| D1 | DoS | Inventory | ProductCreated.Quantity unbounded; consumer creates one row per unit | High | Max quantity in validator and consumer | Planned |
| D2 | DoS | Gateway | No request rate limiting | Medium | Ocelot RateLimitOptions | Planned |
| D3 | DoS | All | Oversized bodies (Kestrel default ~28 MB) | Low | Lower MaxRequestBodySize | Planned |
| E1 | EoP | Gateway, services | Basic user calls admin endpoint (BFLA) | High | Permission claim at gateway (RouteClaimsRequirement) + [HasPermission] in service | Done |
| E2 | EoP | Clients | Stolen access token reused | Medium | 15-min lifetime; refresh token rotated on each use | Done |
| E3 | EoP | Identity | Old access token + leaked refresh token -> new session | Medium | Rotation, 1-day expiry; add reuse detection, revoke endpoint | Partial |
| E4 | EoP | Services | BOLA/IDOR on records | Low | No per-user records in current model; revisit if ownership added | N/A |
| E5 | EoP | mTLS | Stolen gateway cert (PFX without password, no revocation) | Medium | Restrict file access, Docker secrets, short validity; CRL if needed | Planned |

## Summary

| Status | Count |
|---|---|
| Done | 9 |
| Partial | 4 |
| Planned | 10 |
| Open | 1 |
| N/A | 1 |

## Top open risks

- S4: no account lockout (gateway rate limit only slows guessing).
- S5, T3: unauthenticated, unsigned queue events (needs owner: messaging).
- D1: unbounded Quantity in events.
- I4: secrets committed to git.
