# MCSC6002_System
System-level artifacts for the Secure Microservices Inventory System: threat model, architecture diagrams, deployment.

## Run it
Needs Docker Desktop, the .NET 10 SDK and Git Bash. Clone all six repos into one folder, then from `MCSC6002_System`:

```bash
bash scripts/setup.sh    # once: JWT keys, mTLS certs, .env with random passwords, user-secrets
bash scripts/run.sh      # SQL Server, RabbitMQ (TLS), Redis in Docker; the four services in the background
bash scripts/demo.sh     # step-by-step demo, or: dotnet run tests/AttackTests.cs
bash scripts/run.sh stop # stop the services (docker compose stop for the infrastructure)
```

Keys and certificates go to `../keys` (outside every repo). Service logs: `logs/`. Seeded users: `admin@cloudbase.com` and `basic@cloudbase.com`, passwords in `.env`. Gateway: https://localhost:7000. RabbitMQ management UI: http://localhost:15672.
