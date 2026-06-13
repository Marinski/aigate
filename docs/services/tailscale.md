# Tailscale (optional, `TAILSCALE=1`)

Disabled by default. Runs the official `tailscale/tailscale` image with [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve) configured for **L4 TCP forwarding** to nginx on port 4000. Access is **tailnet-only** — no public exposure, no port forwarding, no Cloudflare in the middle.

L4 mode means tailscale forwards the raw TCP stream straight to nginx without inspecting the Host header. nginx sees the original request — including Host, paths, everything — exactly as the client sent it. No FQDN config needed on the tailscale side.

State is bind-mounted at `${DATA_DIR_TAILSCALE:-${DATA_DIR:-.data}/tailscale}` so the node identity survives container recreates. After the first auth, the node stays logged in even if `TS_AUTHKEY` is rotated.

### Setup (hosted Tailscale)

1. Generate an auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) (reusable + ephemeral both work).
2. Set:

   ```env
   TAILSCALE=1
   TS_AUTHKEY=tskey-auth-...
   TS_HOSTNAME=aigate
   ```

3. `make run-bg`. The node joins your tailnet under `TS_HOSTNAME`.
4. From any tailnet-joined device: `http://aigate.tailXXXX.ts.net` → aigate's nginx.

Find your tailnet name with `docker compose exec tailscale tailscale status` after first connect.

### Setup (Headscale or other custom control server)

Add `--login-server` to `TS_EXTRA_ARGS`:

```env
TAILSCALE=1
TS_AUTHKEY=hskey-auth-...
TS_HOSTNAME=aigate
TS_EXTRA_ARGS=--login-server=https://your-headscale.example.com
```

The FQDN your tailnet exposes (`aigate.<base_domain>`) is determined by your Headscale's `base_domain` setting — nothing to configure on the aigate side.

### Custom port

Default forward port is 80 (`http://<host>.<tailnet>/`). Change with `TS_SERVE_PORT=8080` etc.

### Notes

- L4 forwarding means HTTPS auto-cert (Tailscale's hosted ACME proxy) is **not** in play here — TLS termination, if you want it, lives in nginx. Easier to keep it as plain HTTP over the tailnet, which is already encrypted by WireGuard.
- The container needs `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun` for kernel networking.
- Forwarding sysctls (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`) are set so subnet-routing and exit-node modes work if you add `--advertise-routes=...` or `--advertise-exit-node` via `TS_EXTRA_ARGS`.
- Stays on the `aigate-public` network so the `nginx:4000` upstream resolves via Docker DNS.

---

