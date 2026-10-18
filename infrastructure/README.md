# MyBuddy Connect — deployment

MyBuddy works on the same Wi-Fi with no server at all. **MyBuddy Connect** is the optional
internet mode: a small service that lets a paired phone find its Mac from anywhere, relays the
end-to-end-encrypted signaling, and hands out short-lived TURN credentials for when a direct
connection is impossible. It never sees screen contents, keystrokes, files, prompts or AI keys —
everything between the phone and the Mac stays MBH1/DTLS encrypted end-to-end.

```
 phone ──TLS──▶ Caddy :443 ──▶ connect-api :8787 ──▶ Postgres        (internal network only)
   │                                ▲
   │                                └── issues TURN credentials (HMAC, 10 min)
   └──── DTLS-SRTP media ──▶ coturn :3478 ──▶ Mac   (only when no direct path exists)
```

| Service | Image | Exposed | Notes |
|---|---|---|---|
| `caddy` | `caddy:2.11-alpine` | 80, 443/tcp, 443/udp | Automatic HTTPS (ACME), HSTS, no access log |
| `connect-api` | built from `services/connect-api` (distroless, non-root, read-only FS) | nothing | Reachable only through Caddy |
| `postgres` | `postgres:18-alpine` | nothing | `backend` network is `internal: true` |
| `coturn` | `coturn/coturn:4.18-alpine` | 3478/udp+tcp, 49160–49200/udp | Host networking; denies relaying to private ranges |

## Requirements

- A Linux server with a public IPv4 address, Docker Engine and the Compose plugin.
- A DNS `A` record (e.g. `connect.example.com`) pointing at it.
- Firewall open for: `80/tcp`, `443/tcp`, `443/udp`, `3478/tcp`, `3478/udp`, `49160-49200/udp`.
  Nothing else — in particular never 5432 (Postgres) or 8787 (API).

## Deploy

```sh
cd infrastructure
cp .env.example .env            # set MYBUDDY_DOMAIN, MYBUDDY_ACME_EMAIL, MYBUDDY_TURN_HOST
scripts/init-secrets.sh 203.0.113.10   # this server's public IPv4
docker compose up -d --build
```

`init-secrets.sh` creates `secrets/` (git-ignored): a random Postgres password and URL, the TURN
shared secret, and `turnserver.conf` rendered from `coturn/turnserver.conf.example`. It prints no
secret values and refuses to overwrite an existing `secrets/`. Containers receive secrets as
mounted files (`*_FILE` variables), never as command-line arguments.

## Verify

```sh
curl -fsS https://connect.example.com/healthz          # → {"status":"ok"}
curl -fsS https://connect.example.com/readyz           # → {"status":"ready"} (database reachable)
docker compose ps                                      # all services healthy / running
docker run --rm --network host coturn/coturn:4.18-alpine turnutils_stunclient 203.0.113.10
```

The Mac and Android apps do not talk to Connect yet: wiring them to it (device registration,
signaling relay, TURN) is Phase 11, and until then MyBuddy works on the local network only. The
deployed API can already be exercised directly — see `docs/PROTOCOL.md` §7.

## Operations

- **Logs:** `docker compose logs -f connect-api` (structured JSON; no tokens, keys or request bodies).
- **Backup:** `docker compose exec -T postgres pg_dump -U mybuddy mybuddy > mybuddy-$(date +%F).sql`
  — the database holds device public keys, pairings and a 30-day audit trail; no secrets.
- **Update:** `git pull && docker compose pull && docker compose up -d --build`.
- **Rotating the TURN secret:** stop the stack, replace `secrets/turn_secret` and the
  `static-auth-secret=` line in `secrets/turnserver.conf` with a new 48-character random value
  (e.g. from `openssl rand -base64 64 | tr -dc A-Za-z0-9 | head -c 48`, written with an editor, not
  pasted into a command), then `docker compose up -d`. Issued credentials expire within 10 minutes.
- **Rotating the database password:** `docker compose exec postgres psql -U mybuddy -c '\password mybuddy'`
  (interactive prompt), then put the same value into `secrets/db_password` and
  `secrets/database_url` and run `docker compose up -d connect-api`.
  `POSTGRES_PASSWORD_FILE` only applies when the volume is first initialised.

## TURN over TLS (optional)

Plain TURN on 3478 is enough for most networks, and the media inside is already encrypted. For
networks that only allow TLS on 443/5349, give coturn a certificate (for example copied from
Caddy's data volume by a renewal hook), uncomment `tls-listening-port`, `cert` and `pkey` in
`secrets/turnserver.conf`, mount the files read-only, open 5349/tcp, and add
`turns:<host>:5349?transport=tcp` to `MYBUDDY_TURN_URLS`.

## Security notes

- The API refuses to listen on a non-loopback address unless `MYBUDDY_ALLOW_PUBLIC_LISTEN=1`; here
  that is safe because port 8787 is never published — only Caddy can reach it.
- `MYBUDDY_TRUST_PROXY=1` makes the API rate-limit by `X-Forwarded-For`. Caddy overwrites that
  header for untrusted clients, and nothing but Caddy can reach the API, so it cannot be spoofed.
- Postgres sits on an internal network with no internet route and no published port.
- coturn denies peers in loopback, RFC 1918, CGNAT, link-local, ULA and other reserved ranges, so
  the relay cannot be used to reach the server's own network; its CLI is disabled.
- Pin image digests for production (`docker buildx imagetools inspect <image>`), and keep
  `secrets/` out of backups that leave the server.

## Connect the apps

1. Mac: *MyBuddy → Settings → Connections → Internet (MyBuddy Connect)*: enter `https://<your-domain>` and
   *Turn On*. The status reads "Online · <your-domain>" once the Mac signed in with its device key (no account,
   no password — the server only stores public keys and pairing records).
2. Connect the phone once over Wi-Fi (or Tailscale). It shows *Internet access offered* → *Allow*. The Mac then
   lists it as "Internet access on".
3. Away from home the phone uses the server automatically when Wi-Fi and Tailscale don't answer, and shows
   "Connected · Internet" (or "… (relayed)" when coturn carries the packets — file transfer is off then).
4. To undo: *Remove Internet Access* on the Mac (per phone) or on the phone, or *Turn Off* on the Mac. Revoking
   the phone in *Devices & permissions* also removes its pairing on the server.

## Local testing without a server

`services/devturn` is a loopback-only TURN relay for development that accepts the same REST credentials, so the
whole internet path — including the relayed case — can be exercised on one Mac with the Android emulator
(`docs/TEST_PLAN.md` §3.1 step 9). It is never deployed.

## Status

Verified on the development Mac (Docker is not installed there): the Compose file parses, the
secrets script was dry-run in a scratch copy (output shape, permissions, refusal to overwrite, no
secret printed), and the `connect-api` binary was smoke-tested with `*_FILE` secrets and the
`healthcheck` subcommand. Session 4: both apps were wired to the API and the internet path ran end-to-end on
the emulator against a local `connect-api` and the development relay (direct and relayed). **Not yet verified:**
building the images, running the stack, ACME issuance, and coturn relaying on a real server — the first
deployment is the test (`docs/TEST_PLAN.md` I1–I4).
