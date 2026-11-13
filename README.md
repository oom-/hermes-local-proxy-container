# hermes-local-proxy

Gives [Hermes](#prompt-for-hermes) (an agent running in Docker on a VPS) a **residential IP** for web
search, scraping and Chromium, by tunnelling its web traffic through a machine you own at home
(laptop today, Raspberry Pi or small server later). The VPS datacenter IP is never used for that
traffic, so it does not get rate-limited or banned.

```
 home machine (residential IP)                 VPS
 ┌──────────────────────────────┐              ┌───────────────────────────────────────────┐
 │ hermes-local-proxy container │  SSH (out)   │ sshd                                      │
 │  microsocks 127.0.0.1:1080 ◄─┼──────────────┼─ reverse tunnel on 172.17.0.1:1081..1090  │
 │  ssh -R loop                 │              │        ▲                                  │
 └──────────────┬───────────────┘              │        │ Docker network of Hermes         │
                │                              │  hermes-proxy-relay:1080  ◄── Hermes      │
                ▼                              └───────────────────────────────────────────┘
            internet
```

- The home machine **dials out** to the VPS over SSH (works behind NAT, nothing to open at home).
- `ssh -R` publishes the home SOCKS5 proxy on the VPS, bound **only** to the Docker bridge IP
  (e.g. `172.17.0.1`), never on a public interface.
- A small relay container (`hermes-proxy-relay`) joins Hermes's Docker network, so Hermes uses
  `socks5h://hermes-proxy-relay:1080`. The relay logs each request (time, destination, tunnel).
- Up to **10 home devices** can be online at once (ports `1081`–`1090`). The relay picks one per
  destination site and sticks to it while it works, and fails over to another when it goes down.
- If no device is online, the relay refuses the connection. Hermes is told to **queue** web tasks
  until the proxy is back and to notify you on its usual channel (see the prompt below).

## Requirements

- Home machine: Docker.
- VPS: Docker, OpenSSH ≥ 7.8, `sudo`, Hermes running in a container on a bridge/compose network,
  a normal (non-root) SSH user, and root access once for the bootstrap.

## Install

### 1. Build the image (on the home machine)

```bash
docker build -t hermes-local-proxy .
```

### 2. Run the setup wizard

```bash
docker run -it --rm -v /opt/hermes-local-proxy:/data -e DEVICE_NAME=$(hostname) hermes-local-proxy setup
```

Config, SSH key and `known_hosts` are stored on the host in `/opt/hermes-local-proxy`
(change the `-v` path if you prefer). The wizard:

1. Asks the VPS IP/hostname, SSH user (root is refused) and SSH port.
2. Generates an ed25519 key with a descriptive comment
   (`hermes-proxy-setup-<device>-<date>`) and prints the public key. Add it to
   `~<user>/.ssh/authorized_keys` on the VPS.
3. Tests the connection with `whoami`.
4. Prints a **root bootstrap script** (also saved as `/opt/hermes-local-proxy/remote-bootstrap.sh`).
   Log in to the VPS as root and paste it. See [What the root script changes](#what-the-root-script-changes-on-the-vps).
5. Checks the result through the read-only helper and saves the config.

If Hermes's container name does not contain `hermes`, run `export HERMES_CONTAINER=<name>` in
the root shell before pasting (and `HERMES_NETWORK=<network>` if it is on several networks).

### 3. Start the proxy

```bash
docker run -d --name hermes-local-proxy --restart always --cap-add NET_ADMIN -v /opt/hermes-local-proxy:/data hermes-local-proxy
```

`--cap-add NET_ADMIN` is required: the container firewalls itself so the proxy can never reach
your home network (see [Security notes](#security-notes)). It refuses to start without it.

`--restart always` brings it back after a reboot (as long as Docker starts at boot). It reconnects
forever with backoff (1s up to 60s) when the network or the VPS drops.

### 4. Tell Hermes

Send Hermes the prompt below. It is also printed in the logs every time the container starts:

```bash
docker logs hermes-local-proxy
```

## Prompt for Hermes

<!-- hermes-prompt:start -->
```text
You now have a residential-IP SOCKS5 proxy. Create a persistent skill (or memory) so that, from now on and in every future session, ALL your outbound web traffic goes through it: web search, scraping, HTTP/API fetches of websites, and Chromium / browser automation.

Proxy address (from your container, no auth): socks5h://hermes-proxy-relay:1080
Always resolve DNS through the proxy (socks5h, --socks5-hostname), never locally.

How to use it:
- Chromium / Puppeteer: --proxy-server=socks5://hermes-proxy-relay:1080
- Playwright: proxy={"server": "socks5://hermes-proxy-relay:1080"}
- Python requests / httpx: proxies "socks5h://hermes-proxy-relay:1080" (install requests[socks] or httpx[socks])
- curl: curl --socks5-hostname hermes-proxy-relay:1080 <url>
- Tools reading env vars: ALL_PROXY=socks5h://hermes-proxy-relay:1080 (plus HTTP_PROXY/HTTPS_PROXY with the same value if the tool supports socks5h there)

Health check: curl -s --max-time 15 --socks5-hostname hermes-proxy-relay:1080 https://api.ipify.org
- Success = proxy ONLINE (it prints the residential exit IP).
- Connection refused, SOCKS failure or timeout = proxy OFFLINE.

Mode: STRICT (default).
- Never make a web request without the proxy. Never fall back to a direct connection.
- When the proxy is offline: put web tasks in a queue, tell the user they are waiting for the proxy, re-run the health check every 60 seconds, and when it is back run the queued tasks in order.
- FALLBACK mode only if the user explicitly asks for it: when offline, use a direct connection instead of queueing.

Notifications:
- Keep track of the proxy state (online/offline). Whenever it changes, send the user a short message through the same channel/gateway they use to talk to you, for example:
  "Residential proxy OFFLINE, web tasks are queued." / "Residential proxy back ONLINE (exit IP x.x.x.x), running N queued tasks."
- Only notify on a change, not on every check. Check every 60 seconds while tasks are queued, and every 5 minutes otherwise.

The exit IP may differ between websites and over time (several home devices can serve the proxy). That is expected.
```
<!-- hermes-prompt:end -->

Print it again anytime with `docker run --rm hermes-local-proxy prompt`.

## What the root script changes on the VPS

It is idempotent: re-pasting it updates everything in place.

| What | Where |
|---|---|
| Relay container `hermes-proxy-relay` ([gost](https://gost.run) `gogost/gost:3.3.3`, `--restart always`, on Hermes's network, no published port) | Docker, config in `/opt/hermes-proxy-relay/gost.yaml` |
| `Match User <user>` block: `GatewayPorts clientspecified`, `PermitListen <bridge-ip>:1081 … :1090`, client keepalive 15s | end of `/etc/ssh/sshd_config` (backup: `sshd_config.hermes-proxy.bak`) |
| ufw rule allowing only Hermes's subnet to reach the tunnel ports (only if ufw is active) | ufw |
| Read-only status helper | `/usr/local/bin/hermes-proxy-info`, config in `/etc/hermes-proxy.conf` |
| sudo rule: the user may run that helper as root, **with no arguments**, nothing else | `/etc/sudoers.d/hermes-proxy` |

The Hermes compose file is **not** modified: the relay joins Hermes's existing network with a
plain `docker run --network`.

### Security notes

- **GatewayPorts exposure.** `GatewayPorts clientspecified` alone would let the SSH user bind a
  reverse tunnel on any address, including the public IP, which would turn your home connection
  into an open proxy for the internet. The script therefore also sets `PermitListen`, so this user
  can only bind the 10 tunnel ports on the Docker bridge IP. Those addresses are reachable from the
  VPS itself and its containers, not from the internet. Check with `ss -tlnp | grep 108` on the
  VPS: you must see `172.17.0.1:108x`, never `0.0.0.0:108x`.
- The `Match User` block also applies to anything else this user does over SSH (their own `-R`
  forwards are limited the same way). A dedicated user (e.g. `hermesproxy`) keeps things separate.
- The helper lives in `/usr/local/bin`, not in the user's home: a user can delete and replace any
  file in a directory they own, so a root-run script in their home would be a root escalation.
  It only prints fixed status fields (not `docker inspect` output, which contains env secrets).
- **Home network isolation.** A SOCKS proxy at home could otherwise be used to reach your router,
  NAS or the home machine itself (for example if a web page tricks Hermes into opening
  `http://192.168.1.1`). On start, the home container blocks all outgoing traffic to private,
  loopback, link-local and CGNAT ranges (IPv4 and IPv6) with iptables. The filter applies after
  DNS resolution, so a public name pointing at a private IP is blocked too. Only the VPS SSH port
  and the container's DNS servers are exempt.
- Any container on Hermes's network can use the relay (no auth). The relay is not published on
  the host.
- Everything Hermes fetches leaves from your home IP. Watch the relay log:
  `ssh <user>@<vps> sudo hermes-proxy-info` (last 20 lines), or as root
  `docker logs -f hermes-proxy-relay`. Each request: time, client, `host:port`, `dst=` tunnel port.

## Several home devices (rotation)

Run the same image on each device with its **own** setup (each gets its own key; re-pasting the
root script is harmless). Each device takes the first free port in `1081`–`1090`; a device whose
port is taken moves to the next one. The relay:

- sends a new destination site to a random online device, then keeps that site on that device
  (sites often tie sessions/cookies to an IP),
- moves the site to another device as soon as that one stops answering,
- refuses the connection only when no device is online.

To retire a device: stop its container and delete its line (the comment says which device it is)
from `~<user>/.ssh/authorized_keys` on the VPS.

## Operations

- **Status from home:** `docker logs -f hermes-local-proxy` shows `tunnel: UP` / `tunnel: DOWN`.
- **Status of the VPS side:** `ssh <user>@<vps> sudo hermes-proxy-info`.
- **`docker compose down` on the VPS** will complain that Hermes's network still has an active
  endpoint (the relay). Run `docker rm -f hermes-proxy-relay` first, then re-paste the root script
  after `docker compose up -d` (`/opt/hermes-local-proxy/remote-bootstrap.sh` on the home machine).
  A plain `docker compose up -d` / restart keeps the network and needs nothing.
- **Change VPS / user:** re-run the setup wizard; it keeps the key and pre-fills previous answers.

### Uninstall (VPS, as root)

```bash
docker rm -f hermes-proxy-relay
rm -rf /opt/hermes-proxy-relay /etc/hermes-proxy.conf /usr/local/bin/hermes-proxy-info /etc/sudoers.d/hermes-proxy
sed -i '/^# hermes-proxy begin/,/^# hermes-proxy end/d' /etc/ssh/sshd_config && systemctl reload ssh
```

Then remove the key from `authorized_keys`, and the ufw rule if one was added (`ufw status numbered`).

## Troubleshooting

| Symptom | Check |
|---|---|
| `tunnel: DOWN after 0s` in a loop | VPS reachable? Key in `authorized_keys`? `AllowTcpForwarding` not set to `no` for this user in sshd. |
| Tunnel UP but relay logs `connection refused` / `i/o timeout` on every tunnel | Firewall on the VPS blocks containers → host (`ufw`, `firewalld`, `nftables`). Allow Hermes's subnet to `<bridge-ip>:1081-1090`. |
| Hermes cannot resolve `hermes-proxy-relay` | Relay not on Hermes's network: `sudo hermes-proxy-info`, re-paste the root script. |
| Setup step 5 fails on `sudo` | The root script did not finish, or `sudo` asks for a password (check `/etc/sudoers.d/hermes-proxy`). |

## How the relay is configured

The relay is stock [gost](https://gost.run) (no custom code). The root script generates
`/opt/hermes-proxy-relay/gost.yaml`:

- SOCKS5 service on `:1080`, forwarding through one hop whose nodes are the 10 tunnel ports.
- `strategy: hash` + `hash: host`: a destination site always maps to the same online tunnel.
  When a device connects or disconnects, sites are redistributed once, then stay stable.
- `retries: 9`: if the chosen tunnel is dead, gost tries another one within the same request,
  so Hermes never sees an error while at least one device is online.
- `maxFails: 1`, `failTimeout: 30s`: a dead tunnel is skipped for 30s.
- Connector `timeout: 10s`: a port that accepts but never answers (stale SSH session after a
  device lost its network) is abandoned after 10s and the request moves to another tunnel.
  It only covers the handshake, not the transfer.
- Log lines (`level: info`): `client <-> host:port … dst=<bridge-ip>:<tunnel-port>`.
  The tunnel port tells which device served the request.
