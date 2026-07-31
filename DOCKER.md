# Running VDO.Ninja in Docker

A container that serves this repo's static client behind your existing reverse
proxy.

VDO.Ninja is pure static HTML/JS/CSS — there is no backend in this repo and no
build step. The image is the site plus an nginx configured for it.

**What this image does not include:** the signalling ("handshake") server or a
TURN server. By default the client keeps using the free public handshake
server at `wss://wss.vdo.ninja:443` and public STUN, which upstream explicitly
allows for private deployments. Video itself is peer-to-peer and never touches
those servers. See [Going fully self-hosted](#going-fully-self-hosted) if you
want signalling on your LAN too.

---

## Quick start

```sh
docker compose up -d
```

That pulls the prebuilt image from GHCR. Then point your reverse proxy at
`http://<docker-host>:8080`.

To build from source instead, swap `image:` for `build:` in
`docker-compose.yml` and run `docker compose up -d --build`. The first build
takes a few minutes — it copies ~242 MB of assets (most of it `thirdparty/`)
and precompresses the text ones. The resulting image is roughly 270–280 MB.

Check it came up:

```sh
curl -sI http://localhost:8080/healthz        # 200
curl -sI http://localhost:8080/mixer          # 200, serves mixer.html
curl -sI http://localhost:8080/mixer.html     # 302 -> /mixer
```

---

## The published image

`.github/workflows/publish-container.yml` builds and pushes to
`ghcr.io/dyay108/vdo.ninja` on every push to `develop`, on `v*` tags, and on
manual dispatch. Pull requests that touch container files build and smoke-test
the image but never push.

Tags produced:

| Tag | Points at |
| --- | --- |
| `latest` | newest `develop` build |
| `develop` | same, named by branch |
| `sha-abc1234` | one specific commit — use this to pin or roll back |
| `v1.2.3`, `1.2.3` | git tags, if you ever cut releases |

Images are multi-arch (`linux/amd64` and `linux/arm64`), so the same tag works
on an x86 box or an ARM SBC. This is nearly free to build: the compress stage
is pinned to `BUILDPLATFORM` and the runtime stage has no `RUN` steps, so no
QEMU emulation is involved.

Every build also runs a smoke test — it boots the image and asserts that `/`,
`/mixer`, `/obs/simple` and `/main.js` return 200, `/mixer.html` returns a 302,
and `lib.js` comes back gzipped. A broken nginx config fails the build instead
of shipping.

### First publish: make the package pullable

**New GHCR packages are private by default.** The first `docker compose up -d`
on your homelab box will fail with `denied` or `manifest unknown` until you fix
this. Pick one:

- **Make it public** (easiest for a homelab): after the first successful run,
  go to the repo → Packages → `vdo.ninja` → Package settings → Change
  visibility → Public. Note this publishes your image, not your source; the
  repo is already public either way.
- **Keep it private**: create a PAT with `read:packages` and log in on the
  Docker host once:
  ```sh
  echo "$GHCR_PAT" | docker login ghcr.io -u dyay108 --password-stdin
  ```

Also confirm the workflow is allowed to write packages: repo → Settings →
Actions → General → Workflow permissions. The workflow requests
`packages: write` explicitly, but an org-level policy can still block it.

---

## HTTPS is not optional

Browsers only expose `getUserMedia` (camera, mic, screen share) in a **secure
context**. Over plain `http://` from anything other than `localhost`, VDO.Ninja
loads but the device picker comes up empty and permissions fail. This is the
single most common self-hosting failure.

So the container speaks plain HTTP on 8080 and your proxy must serve it over
`https://` with a certificate the client devices actually trust. A public
domain with Let's Encrypt is by far the least painful route — self-signed certs
work on desktop but several mobile browsers still refuse camera access on them.

### Caddy

```caddyfile
vdo.example.com {
    reverse_proxy <docker-host>:8080
}
```

### Traefik

Labels are already in `docker-compose.yml` — uncomment them, remove the
`ports:` block, and set your hostname.

### Nginx Proxy Manager

New Proxy Host → forward to `<docker-host>` port `8080`, scheme `http`. Enable
**Websockets Support**, then request a Let's Encrypt cert on the SSL tab.

### Plain nginx

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name vdo.example.com;

    ssl_certificate     /etc/letsencrypt/live/vdo.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vdo.example.com/privkey.pem;

    location / {
        proxy_pass http://<docker-host>:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Whatever proxy you use, **do not add `X-Frame-Options` or a
`Content-Security-Policy`**. Both break core features — see the notes in
`docker/default.conf`.

---

## Configuring the app

All client settings live in the config block near the bottom of `index.html`
(around line 3400, search for `session.wss`). It is a plain `<script>` that
runs *after* `webrtc.js` loads, so anything you set there overrides the
built-in defaults. Useful ones:

```js
session.hidehome = true;              // hide the landing page
session.darkmode = true;
session.totalRoomBitrate = 500;       // kbps
session.title = "My Studio";
```

Edit, then `docker compose up -d --build`.

Because that file is baked into the image, a rebuild is needed for any change.
If you would rather not rebuild, bind-mount your edited copy over the one in
the image:

```yaml
volumes:
  - ./index.html:/usr/share/nginx/html/index.html:ro
```

---

## Going fully self-hosted

To keep signalling on your own network — required for air-gapped or
internet-free use — deploy
[steveseguin/websocket_server](https://github.com/steveseguin/websocket_server),
expose it over `wss://` through the same proxy, then uncomment in `index.html`:

```js
session.wss = "wss://wss.example.com:443";
session.customWSS = true;
```

You can test a signalling server before committing to it with the `&wss=` URL
parameter, e.g. `https://vdo.example.com/?wss=wss.example.com:443`.

A TURN server (`turnserver.md`) is only worth adding if guests connect from
outside your network and sit behind symmetric NAT or CGNAT. For LAN-only use it
does nothing. Roughly 5% of internet guests need one.

---

## Updating

Pull the newest published build:

```sh
docker compose pull && docker compose up -d
```

To pick up upstream changes, merge and let CI rebuild the image:

```sh
dgit fetch upstream
dgit merge upstream/develop
dgit push origin develop      # triggers the publish workflow
```

The container files are additive (`Dockerfile`, `docker/`, `.dockerignore`,
`docker-compose.yml`, `.github/workflows/publish-container.yml`, this file), so
upstream merges should not conflict.

Rolling back is `image: ghcr.io/dyay108/vdo.ninja:sha-<short>` in
`docker-compose.yml`, then `docker compose up -d`.

Markup and JSON are served `no-cache` and JS/CSS with a 1 hour TTL, so an
update goes live without users clearing caches. Media, fonts and model weights
cache for 30 days since they never change.

---

## Trimming the image

`thirdparty/longpipe/models` is ~120 MB of segmentation weights used only by
the `&effects` virtual-background and blur features. If you never use those,
uncomment the last line of `.dockerignore` to cut the image roughly in half.
Everything else keeps working.

---

## Troubleshooting

**`denied` or `manifest unknown` when pulling.** The GHCR package is still
private, or the first publish has not run yet. See
[First publish](#first-publish-make-the-package-pullable).

**Device picker is empty / "permission denied".** Not a secure context. You are
on `http://`, or the cert is untrusted on that device. Confirm the padlock.

**Page loads, guests never connect.** The handshake server is unreachable — a
firewall or DNS filter is blocking `wss://wss.vdo.ninja:443`. Check the browser
console for websocket errors.

**Guests connect but see no video.** Both peers are behind restrictive NAT and
need TURN. Test by having one guest join over a different network.

**Container will not start, filesystem errors in the logs.** Drop `read_only:
true` from `docker-compose.yml`. It should be fine for a static site, but it is
the first thing to rule out.

**`nginx: [emerg] unknown directive "gzip_static"`.** You swapped the base
image for one built without `--with-http_gzip_static_module`. Either restore
`nginxinc/nginx-unprivileged` or delete the `gzip_static on;` line — plain
`gzip` still covers it.
