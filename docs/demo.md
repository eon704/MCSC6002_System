# Demo Run Sheet

About 3 minutes. Matches slide 12.

## Before the talk

1. `docker compose up -d` (from MCSC6002_System).
2. Start the four services, one terminal each: `dotnet run --launch-profile https` in ApiGateway, IdentityService/WebApi, ProductService/WebApi, InventoryService/WebApi. Wait for "Bus started" in Product and Inventory.
3. Open a Git Bash terminal in MCSC6002_System with a large font. Run the demo once as a rehearsal, then leave everything running.
4. Optional: open the RabbitMQ UI (http://127.0.0.1:15672) on the `ProductCreatedEventQueue_error` queue.

## During the demo

Run `bash scripts/demo.sh` and press Enter for each step.

| Step | Shows | Expected | Threat |
|---|---|---|---|
| 1 | Admin login | `alg: RS256`, valid 15 minutes | S1, E2 |
| 2 | Basic user creates a product | HTTP 403 | E1 |
| 3 | Admin creates a product, quantity 3 | 3 stock items with barcodes | - |
| 4 | Token payload edited to add Create | 401 "Invalid token." | T1 |
| 5 | Direct call to Product, no gateway certificate | curl exit 56, TLS rejected | S3 |
| 6 | Unsigned event published to RabbitMQ | 0 stock items, error queue +1 | S5 |
| 7 | Full attack suite (waits out the 1-minute login limit if needed) | 33/33 passed | all |

## If something fails

- Login returns 429: the 1-minute login limit was hit. Wait a minute.
- Login fails for a seeded user: the account may be locked for 15 minutes after failed attempts. Use the other seeded user, or wait.
- "Service Unavailable" from the gateway: a service stopped. Restart it.
- Live demo not possible: show the testing table in the report (Appendix B) instead.
