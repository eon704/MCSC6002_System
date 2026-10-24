# MCSC6002_System
Deployment and tests for the Secure Microservices Inventory System: Docker Compose, setup and run scripts, the attack suite and a Postman collection.

## Run it
Needs Docker Desktop and Git Bash; the .NET 10 SDK only for the attack suite. Clone all seven repos into one folder, then from `MCSC6002_System`:

```bash
bash scripts/setup.sh    # once: JWT keys, mTLS certs, .env with random passwords
bash scripts/run.sh      # builds and starts everything in Docker: SQL Server, RabbitMQ (TLS), Redis and the four services
bash scripts/demo.sh     # step-by-step demo, or: dotnet run tests/AttackTests.cs
bash scripts/run.sh stop # stop all containers
```

Keys and certificates go to `../keys` (outside every repo); each container mounts only its own, read-only. Logs: `docker compose logs <service>`. Seeded users: `admin@cloudbase.com` and `basic@cloudbase.com`, passwords in `.env`. Gateway: https://localhost:7000. RabbitMQ management UI: http://localhost:15672.
