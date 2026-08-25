## Summary

The API was unreliable/inaccessible due to a real port mismatch between Nginx and the API, a connection leak on the DB error path, and a stack with no health checks, restart policy, or startup ordering. All fixes below were applied to the actual files in this directory and verified with `docker compose up --build`.

---

## Problems Found

### 1. **Nginx proxied to the wrong API port**

- **Issue**: `nginx/conf.d/default.conf` had `proxy_pass http://api:3001;`, but the API listens on port `3000` (`app.listen(3000, ...)` in `api/src/index.js`).
- **Impact**: Every request through `/api/` returned `502 Bad Gateway` - the API was completely unreachable through the load balancer.
- **Diagnosis**: Compared the `proxy_pass` target in `nginx/conf.d/default.conf` against the port `api/src/index.js` actually listens on.
- **Root cause**: Configuration drift between the two files.

### 2. **`postgres/init.sql` existed but was never mounted**

- **Issue**: `docker-compose.yml`'s `postgres` service had no `volumes:` entry, so `postgres/init.sql` (which sets `max_connections`) never ran. It was dead code - the DB was actually running with the image default of 100 connections, not the constrained value the file implied.
- **Impact**: Misleading - anyone reading `init.sql` would assume connection limits were tighter than they actually were, masking the real headroom available for pooling.
- **Diagnosis**: `grep -n "volumes" docker-compose.yml` showed only the `nginx` service had a bind mount.
- **Root cause**: Incomplete Compose configuration.

### 3. **Connection leak on the DB error path**

- **Issue**: In `api/src/index.js`, `db.release()` was called *after* the `SELECT NOW()` query, with no `finally`. If `pool.query()` threw (timeout, transient DB error), execution jumped straight to the `catch` block and the checked-out client was **never released** back to the pool.
- **Impact**: Under any DB flakiness, the pool would leak connections one at a time until exhausted, after which every request would hang waiting for a free connection - this is the actual "sometimes inaccessible" symptom, not "no pooling configured" (the `pg` `Pool` already pools by default).
- **Diagnosis**: Traced the `try { db = await pool.connect(); ... db.release(); } catch {...}` control flow in `api/src/index.js`.
- **Root cause**: Missing `finally` block around `db.release()`.

### 4. **No health checks or startup ordering**

- **Issue**: `depends_on` only listed service names (start order), not readiness. No service had a `healthcheck:`.
- **Impact**: `api` could start and attempt to connect before Postgres/Redis were actually accepting connections; `nginx` could start routing before the API was listening - both produce intermittent failures that are timing-dependent and hard to reproduce.
- **Diagnosis**: `docker-compose.yml` had no `healthcheck` or `condition:` keys.
- **Root cause**: Incomplete Compose configuration.

### 5. **No restart policy**

- **Issue**: No `restart:` policy on any service.
- **Impact**: A crashed container (e.g., API OOM or an uncaught exception) stayed down until someone noticed and ran `docker compose up` again.
- **Diagnosis**: Same review of `docker-compose.yml`.
- **Root cause**: Default Compose restart policy is `no`.

### 6. **No graceful shutdown / Redis resilience in the API**

- **Issue**: No `SIGTERM` handler, and the Redis client had no `retryStrategy`/`maxRetriesPerRequest`.
- **Impact**: Container restarts or redeploys drop in-flight connections abruptly; a brief Redis restart or network blip could surface as an unhandled error instead of a retried request.
- **Diagnosis**: Reviewed client initialization and process lifecycle in `api/src/index.js`.
- **Root cause**: Missing lifecycle/resilience handling.

### 7. **Root `/` served as a binary download**

- **Issue**: `location = / { return 200 "..."; }` had no `default_type`, so Nginx served it as `application/octet-stream`.
- **Impact**: Browsers prompted a file download instead of rendering the welcome text.
- **Diagnosis**: `curl -I http://localhost:8080/` showed the wrong `Content-Type`.
- **Root cause**: Missing `default_type text/plain;` in the location block.

---

## Fixes Applied

**`nginx/conf.d/default.conf`**
- Fixed `proxy_pass` to `http://api:3000` (was `3001`).
- Added `default_type text/plain;` to the `/` location.
- Added an explicit `/status` location proxied to the API, with `proxy_connect_timeout`/`proxy_send_timeout`/`proxy_read_timeout` so a hung upstream doesn't hang Nginx indefinitely.

**`api/src/index.js`**
- Wrapped `db.release()` in a `finally` block so the client always returns to the pool, even on query failure - this is the actual leak fix.
- Set explicit pool bounds: `max: 10`, `idleTimeoutMillis: 30000`, `connectionTimeoutMillis: 5000`, plus a `pool.on('error', ...)` handler so idle-client errors don't crash the process.
- Added Redis `retryStrategy` (capped exponential backoff) and `maxRetriesPerRequest: 3`, plus an `on('error', ...)` handler.
- Added a `SIGTERM`/`SIGINT` handler that stops accepting new connections (`server.close`), drains the pool (`pool.end()`), disconnects Redis, then exits - for a clean container stop instead of connections being cut abruptly.

**`docker-compose.yml`**
- Removed the obsolete top-level `version:` key.
- Mounted `./postgres/init.sql` to `/docker-entrypoint-initdb.d/init.sql` so it actually runs, and bumped `max_connections` to `30` in that file to give the API's pool (`max: 10`) headroom.
- Added `healthcheck:` for `api` (Node one-liner hitting `/status` - no extra OS packages needed in the alpine image), `postgres` (`pg_isready`), and `redis` (`redis-cli ping`).
- Changed `depends_on` to `condition: service_healthy` for `api → postgres, redis` and `nginx → api`, so each service only starts once its dependency is actually ready, not just "started."
- Added `restart: on-failure` to all four services.

---

## Verification

Ran the actual stack and confirmed each fix:

```bash
docker compose up --build -d
docker compose ps
# all four containers report "healthy" (or running, for nginx which has no healthcheck defined)

curl -is http://localhost:8080/            # 200, Content-Type: text/plain
curl -is http://localhost:8080/status      # 200, {"status":"ok"}, proxied to API
curl -is http://localhost:8080/api/users   # 200, {"ok":true,"time":{"now":"..."}}

docker compose exec postgres psql -U postgres -c "SHOW max_connections;"
# max_connections = 30  (confirms postgres/init.sql is now actually applied)
```

All four checks passed. Startup order was also observed correctly: postgres/redis became healthy first, then api, then nginx - matching the new `condition: service_healthy` dependency chain.

---

## Monitoring & Alerts to Add

1. **Health check failures** - alert on any service's health check flipping to `unhealthy`; a repeated flap (not just one failure) should page.
2. **Postgres connection saturation** - track `pg_stat_activity` count vs. `max_connections`; alert at 80%. With pool `max: 10` and a single API replica this shouldn't approach 30, so a climb here signals a leak regression.
3. **API error rate** - 5xx rate on `/api/*` from Nginx access logs; alert if it exceeds ~1% over a rolling window.
4. **API p95/p99 latency** - a rising tail latency on `/api/users` is the earliest signal of pool contention, before requests start failing outright.
5. **Container restart count** - alert if `restart: on-failure` is firing more than a couple of times in a short window; auto-restart should mask transient issues, not silently paper over a crash loop.
6. **Redis availability** - alert on Redis health check failures separately, since it's a soft dependency for `/api/users` today but a hard failure point if usage grows.

## Production Prevention Strategies

- **CI check for port/config drift**: a simple test that spins up the compose stack and curls each route would have caught the 3001/3000 mismatch immediately - this class of bug shouldn't reach a report.
- **Test the unhappy path**: the connection leak only shows up when a query fails; add a test that forces a DB error and asserts the pool's connection count returns to baseline afterward.
- **Treat `depends_on` conditions and health checks as required, not optional**, for any multi-service Compose file - "started" is not "ready."
- **Don't leave unused config files in the repo** (like the unmounted `init.sql`) - either wire them in or delete them; a file that looks authoritative but isn't is worse than no file.
- **Secrets**: `POSTGRES_PASSWORD` is hardcoded in `docker-compose.yml` and duplicated in `api/src/index.js`. Fine for a local challenge, but in production this belongs in a secrets manager (or at minimum a `.env` file excluded from version control) and should be injected via environment variables end-to-end rather than hardcoded in source.
- **Structured logging + centralized aggregation** (e.g., Loki/ELK) from day one, so "sometimes inaccessible" reports come with correlated logs instead of requiring live reproduction.
