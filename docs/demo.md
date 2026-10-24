# Demo Run Sheet

About 3 minutes. The talk plays a recording of this run on slide 11; slides 12 to 14 show its output in case the video fails.

## Before running or recording

1. `bash scripts/run.sh` (from MCSC6002_System). Wait for the four "up" lines.
2. Open a Git Bash terminal in MCSC6002_System with a large font. Run the demo once as a rehearsal, then leave everything running.
3. Optional: open the RabbitMQ UI (http://127.0.0.1:15672) on the `ProductCreatedEventQueue_error` queue.

## Steps

Run `bash scripts/demo.sh` and press Enter for each step. Each step prints the request (`curl`, with passwords and tokens masked), the response, the log line from the service that acted on it, and a one-line "Why".

| Step | Shows | Expected | Threat |
|---|---|---|---|
| 1 | Admin login | `alg: RS256`, valid 15 minutes | S1, E2 |
| 2 | Basic user creates a product | HTTP 403 | E1 |
| 3 | Admin creates a product, quantity 3 | 3 stock items with barcodes | - |
| 4 | Token payload edited to add Create | 401 "Invalid token." | T1 |
| 5 | Direct call to Product, no gateway certificate | curl fails at the TLS handshake | S3 |
| 6 | Unsigned event published to RabbitMQ | 0 stock items, error queue +1 | S5 |
| 7 | Full attack suite (waits out the 1-minute login limit if needed) | 37/37 passed | all |

## If something fails

- Login returns 429: the 1-minute login limit was hit. Wait a minute.
- Login fails for a seeded user: the account may be locked for 15 minutes after failed attempts. Use the other seeded user, or wait.
- "Service Unavailable" from the gateway: a service stopped. Check `docker compose logs <service>`, then `bash scripts/run.sh` again.
- Step 5 wording: since the services run in Docker, curl reports "server closed abruptly" instead of `SEC_E_CERT_UNKNOWN` (as in the recording). Both are the rejected handshake.
- Video does not play during the talk: move on to slides 12 to 14.

## Recording the video for slide 11

1. Run `bash scripts/run.sh`, then wait a minute after any earlier login so steps 1 to 3 are not rate-limited.
2. Git Bash full screen at 1920x1080, font size 16 or larger, notifications off.
3. Start recording: Win+Alt+R (Xbox Game Bar), or OBS.
4. Type `bash scripts/demo.sh`. Press Enter for each step and pause about 5 seconds after each one so the command, response and log line can be read:
   - Steps 1 to 3 (normal use): RS256 token header, HTTP 403 with the gateway log line, 3 stock items with the Inventory log line.
   - Steps 4 to 6 (attacks): HTTP 401, curl failing at the TLS handshake, the "missing signature" log line and the error queue going up by 1.
   - Step 7: wait for the per-area summary and "37/37 passed." The pause before it is up to a minute; trim it while editing.
5. Stop recording. Trim the start and end (Clipchamp or Photos); keep it to about 3 minutes, MP4, 1080p.
6. In PowerPoint (the .pptx downloaded from Google Slides): slide 11, Insert, Video, This Device. Playback: Start On Click.
7. Open the .pptx on another computer once: check that the video plays and the fonts look right.

Record without narration; you and Mario talk over it during the talk (cues are in the slide 11 notes).
