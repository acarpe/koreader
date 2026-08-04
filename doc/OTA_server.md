# Running your own OTA update server

KOReader can update itself from any static web server. This is useful if you build your
own packages and want them installed through the normal update flow instead of copying
files over USB.

The device only ever does plain HTTP GETs, so any static file server will do — as long as
it supports range requests (see [Server requirements](#server-requirements)).

## Pointing a device at your server

Either from the UI, in *(main menu)* → **Update** → **Settings** → **Update server** →
**Custom server**, or by setting `OTA_SERVER` in `defaults.custom.lua`:

```lua
OTA_SERVER = "http://192.168.1.10:8080/",
```

The precedence is: the server picked in the menu (stored as `ota_server` in
`settings.reader.lua`) → `OTA_SERVER` → the built-in mirror list. Clearing the menu entry
falls back to `OTA_SERVER`, so a value baked into a build keeps working after an update.

`OTA_SERVER` is the one to use if you build your own packages, because it is part of the
package and therefore survives updating.

## What to publish

For each device model and channel you serve, two files **in the same directory**:

| File | Content |
| --- | --- |
| `koreader-<model>-latest-<channel>.kotasync` | the manifest the device polls |
| `koreader-<model>-<version>.tar.xz` | the package itself |

The manifest names the package it belongs to, and the device resolves that name relative
to the manifest's own URL — so the two must be siblings.

`<model>` is what `Device:otaModel()` reports, which is not always the build target:
`kindle`, `kindlehf`, `kindlepw2`, `kindle-legacy`, `kobo`, `kobov5`, `cervantes`,
`pocketbook`, `remarkable`, `remarkable-aarch64`. `<channel>` is `stable` or `nightly`,
matching the **Update channel** menu entry.

`<version>` must contain a `git describe`-style version token — `v2026.07`, or
`v2026.07-123-gabc1234_2026-08-03` for a build past a tag. The device works out the
available version by parsing the *package filename*, so a name without a `vYYYY.MM` token
parses as version 0 and looks like a huge downgrade. Building with `./kodev release` gets
this right for free.

## Building and publishing

`tools/publish-ota.sh` does the whole thing — build, manifest, publish. Both halves of the
toolchain are Linux-only (see the note at the end of this section), so the usual place to
run it is the server itself, publishing to a local directory:

```sh
tools/publish-ota.sh --dest /srv/koreader-ota --url http://localhost:8080/ --keep 3
```

Give `--dest` a `HOST:DIR` instead and it copies over ssh, for when you build somewhere
else. `DIR` may be relative to the remote home:

```sh
tools/publish-ota.sh --dest nas:/srv/koreader-ota --url http://nas:8080/ --keep 3
tools/publish-ota.sh --dest 192.168.1.10:~/koreader-ota --url http://192.168.1.10:8080/
```

It defaults to the `kindlehf` target and the `stable` channel; `--target`, `--channel` and
`--model` change that, `--no-build` publishes a package you already have, and `--dry-run`
builds everything but leaves the destination alone. `--keep N` deletes all but the N newest
payloads for that model afterwards, and does nothing unless you ask for it. With `--url` it
range-fetches what it just published and fails if the server is not usable. Run it with
`-h` for the rest.

The three steps it wraps, if you would rather do them by hand:

```sh
# 1. Build the OTA package. This also generates the ota/package.index it must contain.
./kodev release kindlehf txz
#    -> koreader-kindlehf-v2026.07-123-gabc1234_2026-08-03.tar.xz

# 2. Generate the manifest next to it. kotasync is built from
#    koreader-base: make -C base/kotasync
kotasync make \
    --manifest=koreader/ota/package.index \
    --reorder=koreader-kindlehf-latest-stable.kotasync \
    koreader-kindlehf-v2026.07-123-gabc1234_2026-08-03.tar.xz \
    koreader-kindlehf-latest-stable.kotasync

# 3. Copy the payload to the directory your web server serves, and only then the
#    manifest — a device checking in between must not see a manifest whose package
#    has not landed yet.
```

Three things that are easy to get wrong:

- **Always package with `./kodev release`, never with `tar cJf`.** `tools/mkrelease.sh`
  compresses with one independently decodable XZ block per archive entry, which is what
  lets the device fetch individual files with range requests. A conventionally compressed
  `.tar.xz` cannot be used at all. `mkrelease.sh` also normalizes permissions and stamps
  every entry with a fixed timestamp derived from the last tag; without that, every file
  looks modified on every build and the device re-downloads the whole package instead of
  the parts that changed.
- **The package must contain `ota/package.index`,** the list of every file it installs.
  After unpacking, the launcher deletes every path that was in the *previously installed*
  index but is not in the new one. A missing or wrong index therefore deletes files that
  should have been kept. `--manifest=` puts it there.
- `--reorder` is optional but worth it: it repacks the new archive so unchanged files keep
  the block order of the previous release, which turns many small range requests into
  fewer large ones. Point it at the previous `.kotasync` or `.tar.xz`.

**None of this runs on macOS.** Cross-compiling for e-ink targets needs the toolchains from
[koxtoolchain](https://github.com/koreader/koxtoolchain), which are Linux x86_64 binaries,
and `kotasync` is built as a Linux AppImage (`make -C base/kotasync`), so `publish-ota.sh`
stops with *"no kotasync binary found"* anywhere else. Build on a Linux box — the server, a
container, or a VM. See `doc/Building_targets.md`.

## Server requirements

- **Range requests are mandatory, and `Accept-Ranges: bytes` has to be on the `206`
  response itself.** The client checks that header on the reply to its first ranged
  request and gives up with *"server does not support range requests!"* if it is missing
  (`base/ffi/downloader.lua`). That is stricter than HTTP requires — a `206` is
  self-describing, so a server is entitled to send `Accept-Ranges` only on `200` — and it
  matters in practice: **stock nginx fails this check.** Busybox's `httpd`, Caddy and
  Apache pass it as shipped. Python's `http.server` serves no ranges at all; don't use it.
- `ETag` on the `.kotasync` is honoured (with `If-None-Match`, and `304` handled), which
  saves re-fetching an unchanged manifest. Not required.
- `https://` works with no extra configuration.

A minimal check that a server is suitable — note that the `Accept-Ranges` line has to show
up in the output of *this* request, the one that returns `206`:

```sh
curl -s -r 0-99 -o /dev/null -D - \
    http://192.168.1.10:8080/koreader-kindlehf-v2026.07.tar.xz \
    | grep -iE '^HTTP/|accept-ranges|content-range'
# want: HTTP/1.1 206 Partial Content
#       Accept-Ranges: bytes
#       Content-Range: bytes 0-99/<total>
```

## A container that meets them

Busybox's `httpd` is enough, and it is the smallest thing that is: a 2.5 MB image, no
configuration, and it gets `Accept-Ranges` on `206`, `Content-Range`, `ETag` and
`If-None-Match` → `304` all right. Multi-arch down to arm and riscv64, so it runs on a Pi.
Put the published files in `/srv/koreader-ota/` on the host, then:

```sh
docker run -d --name koreader-ota --restart unless-stopped \
    -p 8080:80 \
    -v /srv/koreader-ota:/srv:ro \
    busybox:uclibc httpd -f -p 80 -h /srv
```

That serves the directory at `http://<host>:8080/`, which is what goes in the
**Custom server** field. As a compose file:

```yaml
services:
  koreader-ota:
    image: busybox:uclibc
    container_name: koreader-ota
    restart: unless-stopped
    command: httpd -f -p 80 -h /srv
    ports:
      - "8080:80"
    volumes:
      - /srv/koreader-ota:/srv:ro
```

Its one limitation: no directory listing, so `GET /` is a 404 unless you drop an
`index.html` in there. The device asks for exact filenames and does not care, but you
cannot eyeball what you have published from a browser.

If you want that listing, `caddy:alpine` is the next step up — 85 MB, also correct with no
configuration:

```sh
docker run -d --name koreader-ota --restart unless-stopped \
    -p 8080:80 \
    -v /srv/koreader-ota:/srv:ro \
    caddy:alpine caddy file-server --root /srv --listen :80 --browse
```

`httpd:alpine` (Apache, 107 MB) works unconfigured too — mount the directory at
`/usr/local/apache2/htdocs`.

**nginx needs one extra line,** because it sends `Accept-Ranges` only on `200` responses
and the client insists on seeing it on the `206`. Save this as `/srv/koreader-ota.conf`:

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    autoindex on;
    # Mandatory: nginx omits this on 206 replies, which the client rejects.
    add_header Accept-Ranges bytes;
}
```

and mount it over the default site:

```sh
docker run -d --name koreader-ota --restart unless-stopped \
    -p 8080:80 \
    -v /srv/koreader-ota:/usr/share/nginx/html:ro \
    -v /srv/koreader-ota.conf:/etc/nginx/conf.d/default.conf:ro \
    nginx:alpine
```

`200` replies then carry `Accept-Ranges` twice, nginx's own plus this one. Harmless — the
client only reads it on the ranged request. `nginx:alpine-slim` (22 MB) behaves identically
with the same config, if you want nginx without the bulk.

`static-web-server:2` (11 MB) is also correct, but sends no `ETag`, so every check
re-downloads the manifest instead of getting a `304`. That is a few KB, so it only matters
over a slow link.

Whatever you run, the one way to break it is to put compression in front of the files. A
server compressing a response on the fly cannot serve ranges from it, so a reverse proxy or
CDN with gzip or brotli enabled for `application/octet-stream` turns every update into a
full download at best and a hard failure at worst. `.tar.xz` is already compressed, so
there is nothing to gain. Run the `curl -r` check through whatever the device will actually
talk to, not just against the container.

## Things to know

- **An update server is trusted to run code on your device, and nothing authenticates
  it.** There are no signatures: the only integrity check is a non-cryptographic hash per
  block, taken from the same manifest the server supplied. So anyone who controls the URL
  you configure — or the network path to it — can install arbitrary code. Keep a
  self-hosted server on your own network. This is not specific to self-hosting; the
  built-in mirrors are plain HTTP too.
- **Rebuilding the same commit will not offer an update.** Versions are compared as
  numbers parsed from the version token, and the commit hash is ignored, so two builds of
  the same commit — or of two commits at the same distance from a tag — compare equal and
  report "KOReader is up to date". Committing before building is enough to avoid this.
- Downgrades are offered, with a confirmation prompt saying so.
- The device keeps its download state in `<data dir>/ota/`. Deleting that directory forces
  a fresh manifest fetch and a full download.
