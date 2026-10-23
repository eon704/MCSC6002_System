# MCSC6002_System
System-level artifacts for the Secure Microservices Inventory System: threat model, architecture diagrams, deployment.

## Local infrastructure
SQL Server, RabbitMQ and Redis run in Docker; the services run on the host with `dotnet run`.

```bash
cp .env.example .env   # then set the passwords
docker compose up -d
```

RabbitMQ management UI: http://localhost:15672 (user/password from `.env`).
