# Cloudflared (optional, `CLOUDFLARED=1`)

Disabled by default. Enable by setting `CLOUDFLARED=1` in `.env`.

### Quick tunnel (no account needed)

```env
CLOUDFLARED=1
```

Cloudflare assigns a random `*.trycloudflare.com` URL and logs it on startup:

```bash
docker compose up -d
docker compose logs cloudflared | grep trycloudflare
```

### Named tunnel (fixed domain, requires Cloudflare account)

```env
CLOUDFLARED=1
CLOUDFLARED_CONFIG=/absolute/path/to/config.yml
CLOUDFLARED_CREDS=/absolute/path/to/credentials.json
```

Example `config.yml`:

```yaml
tunnel: <your-tunnel-id>
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: aigate.yourdomain.com
    service: http://nginx:4000
  - service: http_status:404
```

Get your tunnel ID and credentials: [Cloudflare Tunnel guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/)

---

