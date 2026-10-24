# Q&A Prep

Likely questions after the talk, with short answers. IDs refer to `threat-model.md` and `testing.md`.

## Arman

**1. Why RS256 instead of HS256?**
Only Identity holds the private key; the gateway and services hold the public key and can only verify. A compromised service cannot mint tokens. The old HS256 secret sat in four configs and in git history; test A4 shows it is now rejected.

**2. What stops someone calling a service directly?**
Mutual TLS. Each service accepts only a client certificate issued by our CA with CN=api-gateway, and there is no plain HTTP port. Tests N1 to N3.

**3. What if the gateway's client certificate is stolen?**
The attacker could reach the services, but still needs a valid user token: every service re-checks the JWT and the permission. The certificate has no password and no revocation yet, so this is planned work (E5): file permissions, Docker secrets, short validity.

**4. Can a signed event be replayed?**
Yes, within the five-minute window; older events are rejected (M3). That is why T3 is only partly mitigated. The fix is a message id per event and a store of ids already seen.

**5. Why is the HMAC key shared?**
It was the simplest scheme that blocks forged and altered events. The downside is that Inventory could also sign events. Product signing with a private key, or one key per service, would remove that.

**6. What if a refresh token leaks?**
It is single use, valid one day, stored only as a SHA-256 hash, and revoked on logout (A9, A14). An attacker who uses it first still gets one session, because reuse detection is not built yet (E3).

**7. How do you know the tests test the right thing?**
35 of the 37 cases map to a threat ID; the other two (V2b, M5) are controls. Positive cases show normal use still works: a valid event is accepted (M5) and a basic user can still read (A8). We also discarded our first ZAP run after the gateway logs showed it never sent the token.

**8. Why rate-limit only the auth routes?**
Login and refresh are the brute-force targets; every other route needs a valid token first. Limits on other routes are planned (D2).

## Mario

**9. Why does BOLA not apply?**
No record belongs to a single user: products and stock are company-wide. Access is decided by permission, which is function-level authorization (E1, test A7). If records gained owners, each query would need an owner check.

**10. Why events instead of Product calling Inventory?**
Product does not wait for Inventory, and events stay in the queue if Inventory is down, so stock catches up when it returns. The cost is eventual consistency: stock appears a moment after the product.

**11. Why Ocelot?**
It is a .NET gateway configured per route, including authentication and the required permission claim. Its delegating handlers let us replace the body of any server error (5xx) from a service with a generic message.

**12. How is the system deployed?**
Docker Compose runs everything: SQL Server, RabbitMQ, Redis and the four services, each built from its own repository and run as a non-root user. Each container mounts only its own keys, read-only, and gets passwords from `.env`. Ports are published on 127.0.0.1 only.

**13. Is the database connection secure?**
It is encrypted, but the server certificate is not verified and all services share the sa login (I7, I4). The fix is a trusted server certificate and one login per service.

**14. What was the hardest problem?**
Dependencies. MassTransit 9 needs a commercial license, which crashed two services until we moved to version 8. A clean build also pulled an unrelated AuthLibrary 2.0.0 from nuget.org (dependency confusion); we now bundle our packages and map those names to them only.

**15. What would you do before production?**
Replay protection, refresh token reuse detection, an audit log, a secrets manager instead of environment variables, one database login per service, and certificate revocation.
