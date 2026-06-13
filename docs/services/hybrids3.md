# Object Storage (hybrids3)

Base URL: `http://localhost:4000/storage/`

### HTTP API

| Method   | Path                              | Auth                        | Description                                        |
| -------- | --------------------------------- | --------------------------- | -------------------------------------------------- |
| `GET`    | `/storage/health`                 | none                        | Returns `{"status":"ok"}`                          |
| `GET`    | `/storage/`                       | master or bucket key        | List buckets (master sees all, bucket key sees own)|
| `GET`    | `/storage/<bucket>`               | public: none / private: key | List objects (supports `?prefix=` and `?max-keys=`)|
| `PUT`    | `/storage/<bucket>/<key>`         | bucket key or master key    | Upload object (MIME auto-detected)                 |
| `GET`    | `/storage/<bucket>/<key>`         | public: none / private: key | Download object                                    |
| `HEAD`   | `/storage/<bucket>/<key>`         | public: none / private: key | Object metadata — no body                          |
| `DELETE` | `/storage/<bucket>/<key>`         | bucket key or master key    | Delete object — 204 even if it doesn't exist       |
| `POST`   | `/storage/presign/<bucket>/<key>` | bucket key or master key    | Generate presigned URL                             |
| `POST`   | `/storage/mcp/`                   | per-tool `auth_key`         | MCP endpoint                                       |

Authentication: pass `Authorization: Bearer <key>` where `<key>` is the bucket's private key or `$HYBRIDS3_MASTER_KEY`.

The `uploads` bucket is configured as public-read — GET/LIST require no auth. PUT/DELETE always require the bucket key.

### Presigned URLs

```bash
# generate a GET presigned URL (default; expires in 1 hour, max 7 days)
curl -X POST "http://localhost:4000/storage/presign/uploads/photo.jpg?expires=3600" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# generate a PUT presigned URL — append ?method=PUT
curl -X POST "http://localhost:4000/storage/presign/uploads/photo.jpg?method=PUT&expires=3600" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# response for public bucket (GET) — plain URL, no expiry
{"url": "http://localhost:4000/storage/uploads/photo.jpg", "expires": null}

# response for private bucket / PUT — signed URL with expiry
{"url": "http://localhost:4000/storage/private/doc.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...", "expires": 3600}

# use a GET presigned URL — no auth header needed
curl "http://localhost:4000/storage/uploads/photo.jpg"

# use a PUT presigned URL — upload directly, no auth header
curl -X PUT --data-binary @photo.jpg "<presigned-put-url>"
```

The signature binds the HTTP method into its canonical request — a GET-signed URL cannot be used to PUT, and vice versa. Public buckets still require a signed URL for PUT (anonymous writes are never allowed; anonymous reads still work).

### S3-compatible access (boto3)

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:4000/storage",
    aws_access_key_id="uploads",           # bucket name (public_key)
    aws_secret_access_key=HYBRIDS3_UPLOADS_KEY,
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)

s3.upload_file("image.png", "uploads", "image.png")
s3.download_file("uploads", "image.png", "local.png")
s3.list_objects_v2(Bucket="uploads", Prefix="images/")
s3.delete_object(Bucket="uploads", Key="image.png")

# generate presigned URLs via boto3 — GET or PUT
get_url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "uploads", "Key": "image.png"},
    ExpiresIn=3600,
)
put_url = s3.generate_presigned_url(
    "put_object",
    Params={"Bucket": "uploads", "Key": "image.png"},
    ExpiresIn=3600,
)
```

### Response headers

Every response includes `X-Request-Id` for log correlation and `X-Content-Type-Options: nosniff`. Upload responses include `ETag` (MD5 of content). GET/HEAD responses include `ETag`, `Last-Modified`, `Content-Length`, and `Content-Type` (auto-detected from content).

### Concurrency and locking

Each object key has its own async read-write lock. Multiple concurrent reads are allowed. Writes are exclusive — a write blocks all other readers and writers on that key. Requests that can't acquire the lock within 30 seconds, or that hold it for more than 300 seconds, get 503.

### TTL

The `uploads` bucket has TTL configured (default: `HYBRIDS3_UPLOADS_TTL`, typically 168h / 7 days). Uploading a file resets its expiry clock. A background sweep runs every minute and deletes expired objects.

---

