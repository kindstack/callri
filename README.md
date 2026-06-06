# Asterisk PBX (Telnyx) on Synology x86_64

Self-hosted Asterisk 18 LTS in Docker, configured for a Telnyx SIP trunk and two
local SIP extensions. Designed to run on a Synology DSM 6 NAS via the **Docker**
package (`docker` + `docker-compose` v1). Also works on DSM 7 via Container Manager.

## What's in this folder

| File | Purpose |
|---|---|
| `Dockerfile` | Asterisk 18 LTS on Ubuntu 22.04 (jammy). **Why 22.04 not 24.04?** Ubuntu 24.04's glibc 2.39 calls `getrandom()` which Synology DSM 6's Docker seccomp profile blocks — Asterisk crash-loops. 22.04's glibc 2.35 falls back to `/dev/urandom` and boots fine. |
| `docker-compose.yml` | Runs with `network_mode: host` (required for SIP/RTP); bind-mounts `.env` so the container picks up edits on `docker-compose restart` |
| `entrypoint.sh` | Fixes bind-mount permissions, seeds defaults on first run, renders config templates from `.env` |
| `render-env-configs.sh` | Shared renderer: reads `.env`, validates required values, runs `envsubst` over the three `.template` files |
| `reload-env.sh` | Optional zero-downtime helper installed as `/usr/local/bin/reload-env`. Re-renders configs and gracefully reloads Asterisk without dropping active calls (`docker exec asterisk reload-env`). For most edits a plain `docker-compose restart asterisk` is simpler. |
| `verify-nat.sh` | Diagnostic helper installed as `/usr/local/bin/verify-nat`. Confirms the CRLF NAT keepalive (`keep_alive_interval`) is active, shows the outbound registration refresh timer, and reports Telnyx trunk reachability (`docker exec asterisk verify-nat`). Use it when inbound calls drop after a router/ISP blip. |
| `.env` | **Site-specific values — gitignored.** All passwords, your DID, public address, Telnyx username. Copy `.env.example` to create it. |
| `.env.example` | Template for `.env` with placeholder values + comments |
| `config/asterisk.conf` | Core options |
| `config/modules.conf` | Loads only what we need; skips legacy/hardware |
| `config/logger.conf` | Logging |
| `config/rtp.conf` | RTP media port range (10000–10100) |
| `config/pjsip.conf` | Telnyx trunk + extensions 100 and 101 (no secrets) |
| `config/pjsip_auth.conf.template` | Template for `pjsip_auth.conf` (the rendered output, gitignored, holds passwords + Telnyx username from `.env`) |
| `config/pjsip_env.conf.template` | Template for `pjsip_env.conf` (rendered, gitignored — public address + DID from `.env`) |
| `config/extensions.conf` | Dial plan (echo test, internal calls, outbound) |
| `config/extensions_globals.conf.template` | Template for the `[globals]` block (rendered, gitignored — `TRUNK_CID` from `.env`) |
| `config/outbound_whitelist.txt` | Allowed *destination* numbers (E.164). Empty = block all outbound. |
| `config/inbound_whitelist.txt` | Allowed *caller* numbers (E.164). `*` on its own line = allow all. |

## Quick reference: SIP credentials currently configured

| What | Value |
|---|---|
| Telnyx SIP server | `sip.telnyx.com:5060/udp` |
| Telnyx SIP username | *(your own — `TELNYX_USERNAME` in `.env`)* |
| Telnyx SIP password | *(your own — `TELNYX_PASSWORD` in `.env`; rotate after first successful test!)* |
| DID (outbound caller-ID + inbound number) | *(your own — e.g. `+15551234567`; `TELNYX_DID` in `.env`)* |
| Extension 100 password | *(`EXT_100_PASSWORD` in `.env`)* |
| Extension 101 password | *(`EXT_101_PASSWORD` in `.env`)* |
| Asterisk host (LAN) | `ds.local` (mDNS/Bonjour name of the Synology) |
| LAN subnet | *(your own — e.g. `192.168.1.0/24`)* |
| Public address | *(your own — `PUBLIC_ADDRESS` in `.env`; DDNS hostname recommended)* |

> Throughout this README we use **`ds.local`** as the hostname for the Synology
> running Asterisk. That's the Bonjour/mDNS name DSM advertises on the LAN, so
> all LAN clients (softphones, HT801, your Mac) can keep working even if your
> router hands the NAS a new DHCP lease. Substitute your NAS's actual mDNS
> name (DSM → Control Panel → Info Center → "Server name", then `.local`) or
> an IP/reserved DHCP address if your LAN doesn't do mDNS.

If your public address (or any other value) changes, edit `.env` on the NAS and run:
```bash
sudo docker-compose restart asterisk
```
The entrypoint re-renders the configs from `.env` on every container start.
(If you'd rather not drop in-flight calls, the alternative is
`sudo docker exec asterisk reload-env` — same effect, hot-reloaded.)
With DDNS, you usually don't have to edit `.env` at all; Asterisk
re-resolves the hostname on restart.

---

## Mac vs Synology — read this first

This project has been **partially validated on a Mac** (Docker Desktop) and is
**ready to deploy to your Synology NAS**. Here's where each environment lands:

| Validation step | Mac (Docker Desktop) | Synology (Linux Docker) |
|---|---|---|
| Image builds | ✅ Confirmed | Will work — same Dockerfile, x86_64 native |
| Telnyx trunk registers | ✅ Confirmed | Will work |
| Softphone registers to extension | ✅ Confirmed (via SIP signaling) | Will work |
| Dialplan executes (`*60`, `*43`) | ✅ Confirmed in logs | Will work |
| **Audio (RTP) flows** | ❌ Docker Desktop on macOS has a known UDP-proxy limitation | ✅ Linux Docker handles UDP natively |

If you'd like to keep the Mac container around as a SIP signaling sandbox,
fine — but **don't burn time chasing one-way / no audio on the Mac**. Go straight
to Synology to validate audio.

---

## Telnyx portal setup (what you still need to do)

You've already created the **SIP Connection** (referred to below as `<your-sip-connection>`) with credentials.
What's still pending on the Telnyx side:

### 1. Attach an Outbound Voice Profile
Without this, the connection is inbound-only and Asterisk can't place calls.

- Mission Control → **Voice → Outbound Voice Profiles → + Add**
  - Name: `asterisk-out`
  - Traffic Type: **Conversational**
  - Allowed Destinations: your country only (keeps trial safe)
  - Concurrent Call Limit: 2
  - Save.
- Back to your SIP Connection (`<your-sip-connection>`) → Outbound tab → select `asterisk-out` → Save.

### 2. Add a Verified Number (only number you can dial on the trial)
- Try the direct URL while logged in:
  `https://portal.telnyx.com/#/app/verified-numbers`
- Or search "verified" in the top portal search bar.
- Or look under the **Voice Suite** group in the left sidebar.
- Click **Add Verified Number** → enter your mobile in E.164 (`+1XXXXXXXXXX`)
  → choose SMS or Voice → enter the code → done.

> Trial limits: 1 verified number at a time, 10 changes total, 2 concurrent calls,
> 10-min cap per call. Outbound only goes to verified numbers until you upgrade.

### 3. (Skip until you upgrade) Buy a DID
Once you've upgraded:
- **Numbers → Buy Numbers** → pick a number ($1/mo typical) → checkout.
- After purchase, **Numbers → My Numbers**, click the number, set
  **Connection / Number Format** → assign to the `<your-sip-connection>` SIP Connection.
- Inbound calls will then arrive in Asterisk's `from-telnyx` context.

---

## Deploy to Synology

### A. Get the files onto the NAS

> Replace `admin@ds.local` below with whatever username you use to SSH
> into your Synology (DSM Control Panel → Terminal & SNMP → Enable SSH service
> if you haven't already).

Pick one:

1. **Manual rsync from your workstation:**
   ```bash
   # from this directory
   ssh admin@ds.local "sudo mkdir -p /volume1/docker/asterisk && sudo chown $(whoami) /volume1/docker/asterisk"
   rsync -avz --exclude='.git' --exclude='data' --exclude='logs' --exclude='spool' \
       ./ admin@ds.local:/volume1/docker/asterisk/
   ```
2. **DSM File Station:** create `/docker/asterisk/` and drag the folder contents in
   (skip `data/`, `logs/`, `spool/`, `.git/`). Make sure `.env` came over —
   it holds all the passwords and your DID.
3. **Git clone on the NAS** (after you push this repo somewhere). You'll still
   need to copy `.env` separately since it's gitignored.

### B. Open the firewall

DSM → Control Panel → Security → Firewall → Edit Rules → add:
- Allow **UDP 5060** from your LAN subnet (e.g. `192.168.1.0/24`) and from any (Telnyx will hit you back here)
- Allow **UDP 10000-10100** from any (RTP media)

> No router port forwarding needed — Asterisk initiates the connection out to Telnyx
> and the registration keeps the NAT pinhole open for return traffic.

### C. Configure `.env`

All site-specific values (passwords, your DID, public address, Telnyx
username) live in a single `.env` file at the root of this folder. It's
gitignored, so your values never get committed.

On the NAS, in `/volume1/docker/asterisk/`:
```bash
cp .env.example .env
vi .env
```

Fill in real values for:

| Variable | What |
|---|---|
| `TELNYX_USERNAME` | SIP username from Telnyx portal → Authentication & Routing |
| `TELNYX_PASSWORD` | SIP password from the same tab |
| `TELNYX_DID` | Your DID in E.164 (`+1XXXXXXXXXX`). On the trial you don't have one yet — leave it as the example placeholder for now and Telnyx will rewrite it. |
| `PUBLIC_ADDRESS` | DDNS hostname (recommended) or your current public IPv4 |
| `EXT_100_PASSWORD` | strong password for SIP extension 100 (your softphone uses it) |
| `EXT_101_PASSWORD` | strong password for SIP extension 101 (HT801 or second softphone) |
| `INBOUND_DIAL` | *(optional)* Endpoint(s) to ring on inbound calls — Asterisk `Dial()` syntax. Defaults to `PJSIP/100&PJSIP/101` (rings both extensions in parallel). Examples: `PJSIP/100`, or `PJSIP/100&PJSIP/+15125551234@telnyx-endpoint` to fork-ring your mobile via Telnyx. |

### D. Build and start

SSH into the NAS:
```bash
ssh <user>@ds.local
cd /volume1/docker/asterisk
sudo docker-compose up -d --build      # DSM 6 (hyphenated)
# sudo docker compose up -d --build    # DSM 7+ (no hyphen)
```

**When do you actually need `--build` or anything else?**

| You changed... | Command on NAS |
|---|---|
| `.env` or any `config/*.conf` | `sudo docker-compose restart asterisk` (~10s, drops any in-flight calls) |
| `config/*_whitelist.txt` (live list) | nothing — re-grepped on every call |
| `Dockerfile`, `entrypoint.sh`, helper scripts | `sudo docker-compose up -d --build` (rebuild image) |
| `docker-compose.yml` | `sudo docker-compose up -d` (recreate container) |

> **Hot reload alternative** (zero-downtime; rarely needed for a home PBX):
> `sudo docker exec asterisk reload-env` re-renders configs and graceful-reloads
> Asterisk without dropping active calls. Use it if you ever edit `.env`
> mid-call. For everything else, plain `restart` is simpler.

> If `docker-compose` is not found on DSM 6, install it once:
> `sudo curl -SL "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose`
> (the bundled compose with the DSM 6 Docker package is usually old but
> sufficient — the curl install only matters if it complains about compose
> file version `3.8`.)

GUI alternative (DSM 6 Docker package — no Compose support in the GUI itself,
unfortunately, so you need SSH for the first build; afterwards you can
start/stop the container from the GUI under Container).

### E. Tail the logs and watch the registration happen

```bash
sudo docker logs -f asterisk
```

You should see, within ~30 seconds:
```
Outbound REGISTER ... 'telnyx-reg' is now Registered
```

In the Telnyx portal, your `<your-sip-connection>` SIP Connection should now show
**Connection Status: Online / Registered**.

---

## Testing checklist

Run these in order. Each step rules out a class of problems.

### Test 1 — Asterisk is alive
```bash
sudo docker exec asterisk asterisk -rx 'core show version'
```
Expect: `Asterisk 20.x.x ...`

### Test 2 — PJSIP loaded cleanly
```bash
sudo docker exec asterisk asterisk -rx 'pjsip show endpoints'
```
Expect: `telnyx`, `100`, `101` listed.

### Test 3 — Telnyx registration succeeded
```bash
sudo docker exec asterisk asterisk -rx 'pjsip show registrations'
```
Expect: `telnyx-reg ... Registered`.
If you see `Rejected`, double-check `TELNYX_USERNAME` / `TELNYX_PASSWORD`
in `.env`, then `sudo docker-compose restart asterisk`.

### Test 4 — Register a softphone to extension 100
Install **Zoiper** (free) on your iPhone or Mac. Add a SIP account:

| Field | Value |
|---|---|
| Host / Domain | `ds.local` |
| Username | `100` |
| Password | *(value of `EXT_100_PASSWORD` in `.env`)* |
| Transport | UDP |
| Port | 5060 |

The phone should show "Registered" within seconds.

Verify on the Asterisk side:
```bash
sudo docker exec asterisk asterisk -rx 'pjsip show contacts'
```
You should see a contact for AOR `100`.

### Test 5 — Internal: dial `*43` (echo test)
With your softphone registered, dial `*43`. You should hear the echo-test prompt
and your own voice echoed back. This proves audio works end-to-end **inside**
Asterisk (no Telnyx involved yet).

### Test 6 — Register a second softphone to extension 101, dial 100 from it
Internal extension-to-extension calling. Proves both endpoints work.

### Test 7 — Outbound through Telnyx to your verified number
With softphone on extension 100, dial your verified phone number in
**11-digit US format** (e.g. `15125551234`). The dial plan normalizes it
to `+15125551234` before handing to Telnyx.

If it rings your phone → trunk works → you're done with the trial test.

> ⚠️ **Before upgrading**, watch the call complete in `docker logs -f asterisk`.
> Confirm `Dial: ... ANSWER` and clean hangup. If you only get one-way audio,
> see Troubleshooting → NAT below.

---

## Configuring the Grandstream HT801 (analog telephone adapter)

The HT801 is a 1-FXS ATA: plug a regular analog phone into the **PHONE** jack
and the HT801 makes it look like a SIP softphone to Asterisk. We point it at
the Synology by hostname (`ds.local`) so a DHCP-driven NAS IP change doesn't
silently brick the phone.

### Step 0 — Preflight: confirm `ds.local` resolves on your LAN

From your Mac (on the same Wi-Fi/LAN as the NAS):

```bash
ping -c 2 ds.local
```

If you get replies → you're good. If you get *cannot resolve host* → fix one
of these before configuring the HT801, because the ATA will hit the same wall:

- **DSM Bonjour off?** DSM → Control Panel → File Services → Advanced →
  enable *"Enable Bonjour service discovery"*. Server name lives at Control
  Panel → Info Center; change it there if you want a different `<name>.local`.
- **Router DNS doesn't proxy mDNS?** Either:
  - Add a **DHCP reservation** for the Synology MAC in your router admin
    (fixes the NAS IP permanently — then the IP itself is your stable
    "hostname"), OR
  - Add a **manual DNS record** `ds.local → <NAS-IP>` in your router /
    pi-hole / OPNsense / AdGuard Home.
- **Worst case**: use the NAS's current LAN IP in step 4 below instead of
  `ds.local`. You'll just have to re-edit the HT801 the next time the IP
  changes.

### Step 1 — Cable it up

1. WAN port → your switch or router (HT801 needs LAN access to reach the NAS).
2. PHONE port → analog phone via standard RJ-11.
3. Power on. Wait ~30s for boot (LEDs settle).

### Step 2 — Find the HT801's IP

Pick up the analog phone and dial the built-in voice menu:

1. Dial `***` — you'll hear *"Enter a menu option"*.
2. Dial `02` — it reads out the current IP address.

(Alternative: check your router's DHCP client list for a device whose MAC
starts with `C0:74:AD` or hostname `HT801`.)

### Step 3 — Log in to the HT801 web UI

Browse to `http://<HT801-IP>/` from your Mac.

- **Default user**: `admin`
- **Default password**: printed on the sticker on the bottom of the unit
  (recent firmware ships with a unique random password per device). Older
  units default to `admin`. You'll be forced to change it on first login.

### Step 4 — Configure the SIP account

The HT801 web UI splits the SIP account across several pages in the left
nav. Walk them top-to-bottom. Anything not listed below: leave at the
firmware default.

#### 4a. General Settings → Account Registration

| Field | Value | Notes |
|---|---|---|
| Account Active | **Yes** | turns the SIP account on |
| Primary SIP Server | **`ds.local`** | mDNS name of the Synology — survives NAS IP changes |
| Failover SIP Server | *(blank)* | single Asterisk, no failover |
| Prefer Primary SIP Server | **No** | default |
| Outbound Proxy | *(blank)* | direct registration |
| Backup Outbound Proxy | *(blank)* | |
| Prefer Primary Outbound Proxy | **No** | default |
| From Domain | *(blank)* | |
| Allow DHCP Option 120 to Override SIP Server | **No** | otherwise a stray DHCP option could clobber `ds.local` |
| SIP User ID | **`100`** | the Asterisk extension to claim — use `101` for a second ATA |
| SIP Authenticate ID | **`100`** | same as User ID |
| SIP Authentication Password | *(value of `EXT_100_PASSWORD` in `.env`)* | |
| Name | **`Home Line`** | cosmetic — pick any label you like (`Kitchen`, `Office`, `Fax`, etc.) |
| Tel URI | **Disabled** | Asterisk speaks `sip:` URIs, not `tel:` |

#### 4b. General Settings → Network Settings

| Field | Value | Notes |
|---|---|---|
| Layer 3 QoS SIP DSCP | **26** | default — AF31 |
| Layer 3 QoS RTP DSCP | **46** | default — EF (voice priority) |
| DNS Mode | **A Record** | required so `ds.local` resolves as a normal hostname |
| DNS SRV Failover Mode | **Default** | |
| Failback Timer | **60** | default |
| Maximum Number of SIP Request Retries | **2** | default |
| Register Before DNS SRV Failover | **No** | default — no SRV in play |
| Primary IP / Backup IP 1 / Backup IP 2 | *(blank)* | we resolve via A record |
| NAT Traversal | **No** | HT801 and NAS are on the same LAN |
| Use NAT IP | *(blank)* | |
| Proxy-Require | *(blank)* | |

> ℹ️ **Other pages** (SIP Settings, Audio Settings, Call Settings, FXS Port,
> etc.) are configured below as we walk through them. Click **Update** /
> **Apply** at the bottom of each page before navigating away, then hit
> **Apply** at the very end and **Reboot** the unit so the registration
> rebuilds against the new config.

#### 4c. SIP Settings → SIP Basic Settings

Only the rows below need attention. Anything not listed: leave the firmware
default.

| Field | Value | Notes |
|---|---|---|
| SIP Registration | **Yes** | |
| SIP Transport | **UDP** | matches Asterisk's `transport-udp` |
| Unregister On Reboot | **Yes** | sends `Expires:0` on reboot so Asterisk drops the stale contact instead of dialing a dead IP |
| Outgoing Call without Registration | **No** | force register-then-call |
| Register Expiration | **5** (minutes) | *change from default 60* — shorter expiry means a network blip recovers in minutes, not an hour |
| Re-Register before Expiration | **0** | default — re-registers at expiry |
| SIP Registration Failure Retry Wait Time | **20** | default |
| Retry Wait Time upon 403 Forbidden | **1200** | default — long back-off if the password ever drifts, so we don't hammer Asterisk |
| Port Voltage Off upon no SIP Registration | **0** | default — keep the analog line powered even if registration drops, so the handset isn't dead |
| Enable SIP OPTIONS/NOTIFY Keep Alive | **No** | default — Asterisk's `qualify_frequency=30` on the AOR template already pings the HT801; HT801→Asterisk pings would be redundant |
| SUBSCRIBE for MWI | **No** | voicemail isn't configured in Asterisk yet; flip to **Yes** once it is, otherwise MWI subscriptions just generate 404 log noise |
| Local SIP Port | **`5060`** | fine to keep at 5060 — the HT801 has its own LAN IP so reusing 5060 on a different host doesn't clash with Asterisk |
| Add MAC in User-Agent | **No** | don't leak the MAC into headers that traverse the LAN |
| Use MAC Header | **No** | same |

Everything else on this page (T1/T2 timers, all `Use *-Header` toggles,
GRUU, 100rel, User-Agent, etc.) → **leave default**. Asterisk doesn't need
any of them.

#### 4d. SIP Settings → Session Timer

| Field | Value | Notes |
|---|---|---|
| Enable Session Timer | **Yes** | auto-tears down stale calls if a refresh is missed |
| Session Expiration | **180** | default (seconds) |
| Min-SE | **90** | default (seconds) |
| Caller Request Timer | **No** | default |
| Callee Request Timer | **No** | default |
| Force Timer | **No** | default |
| UAC / UAS Specify Refresher | **Auto / Omit** | default |
| Force INVITE | **No** | default — UPDATE is preferred for refreshes |
| When To Restart Session After Re-INVITE received | default | |

#### 4e. Codec Settings → DTMF

| Field | Value | Notes |
|---|---|---|
| Preferred DTMF — choice 1 | **RFC2833** | matches Asterisk's `dtmf_mode=rfc4733` (RFC2833 and RFC4733 are the same wire protocol) |
| Preferred DTMF — choice 2 | **SIP INFO** | fallback |
| Preferred DTMF — choice 3 | **In-audio** | last-resort fallback |
| Force DTMF to be sent via SIP INFO simultaneously | **No** | avoids duplicated DTMF events |
| DTMF Payload Type | **101** | default, matches Asterisk |

Everything else in this section (inband duration, gain, DSP detector
thresholds, RFC2833 event counts) → **leave default**.

#### 4f. Codec Settings → Vocoder

> ⚠️ Reorder the vocoder list. Asterisk only ships **G.722**, **PCMU** and
> **PCMA** in this image (Opus, G.729, G.723, G.726, iLBC are not loaded).
> Anything else in the HT801's offer just clutters SDP.

| Slot | Set to |
|---|---|
| choice 1 | **G722** (HD voice) |
| choice 2 | **PCMU** |
| choice 3 | **PCMA** |
| choice 4-8 | **"—"** / disabled if your firmware allows; otherwise leave default (unused) |

| Other field | Value | Notes |
|---|---|---|
| Voice Frames per TX | **2** | default — 40ms ptime; Asterisk tolerates it |
| Enable Audio RED with FEC | **No** | Asterisk doesn't support RED |
| Silence Suppression | **No** | default |
| Use First Matching Vocoder in 200OK SDP | **Yes** | deterministic codec selection |
| Fax Mode | **None** (or **Pass-Through**) | only pick **T.38** if you actually plug a fax machine into the HT801 |
| Jitter Buffer Type | **Adaptive** | default |
| Jitter Buffer Length | **Medium** | default |

Anything else on this page → **leave default**.

#### 4g. Codec Settings → RTP

| Field | Value | Notes |
|---|---|---|
| Local RTP Port | **5004** | default — only one call at a time, fixed port is fine |
| Use Random RTP Port | **No** | default |
| Symmetric RTP | **Yes** | **important** — matches Asterisk's `rtp_symmetric=yes`, ensures the HT801 sends RTP back to wherever Asterisk's RTP arrived from |
| Enable RTCP | **Yes** | default |
| RTP/RTCP Keep Alive On Hold | **No** | default |
| SRTP Mode | **Disabled** | Asterisk's endpoint template doesn't set `media_encryption`, so SRTP would fail negotiation |
| VQ RTCP-XR Collector Name / Address / Port | *(blank)* | no quality collector configured |

#### 4h. Analog Signal Line Configuration

US-default page — **nothing to change**, but worth confirming:

| Field | Expected value |
|---|---|
| SLIC Setting | **USA 1 (BELLCORE 600 ohms)** |
| Caller ID Scheme | **Bellcore/Telcordia** |
| Polarity Reversal | **No** |
| Loop Current Disconnect | **No** (Asterisk hangs up via SIP BYE) |
| Enable Pulse Dialing | **Yes** — safe to leave on even with a touch-tone phone (DTMF and pulse detection run in parallel and don't interfere; hook-flash window of 300–1100 ms cleanly distinguishes a flash from a pulse break) |
| Pulse Dialing Standard | **General Standard** (10 pps, 60/40 make/break — fits virtually every US/EU rotary phone) |
| Enable Hook Flash | **Yes** (needed for call-waiting / transfer via flash) |
| Hook Flash Timing | **300 – 1100 ms** |
| Gain TX / RX | **0 dB / −6 dB** (firmware default — only adjust if audio levels are wrong) |
| Enable Line Echo Canceller (LEC) | **Yes** (essential for analog — never disable) |
| Ring Frequency / Power | **20 Hz / 45 Vrms** (US) |
| OnHook DC Feed Current | **30 mA** |

If you're outside North America, set **SLIC Setting** and **Caller ID
Scheme** to the matching country profile in the dropdowns — everything else
in the table above stays.

#### 4i. Call Settings → Dial / Dial Plan

| Field | Value | Notes |
|---|---|---|
| Off-hook Auto Dial | *(blank)* | normal dial tone on pickup. Put `*43` here if you want a dedicated echo-test handset. |
| Off-hook Auto-Dial Delay | **0** | irrelevant when Auto Dial is blank |
| No Key Entry Timeout | **4** | default — auto-sends after 4 s of silence |
| Early Dial | **No** | dial plan matching happens on the HT801; per-digit SIP INFO is unnecessary |
| **Dial Plan** | **`{ x+ \| \+x+ \| *x+ \| *xx*x+ }`** | keep as-is — covers any-digits (`100`, `5125551234`, `15125551234`), E.164 (`+...`), star codes (`*43`, `*60`), and star-code-with-arg (`*72*...`) |
| Use # as Dial Key | **Yes** | default — press `#` to send immediately |
| Enable # as Redial Key | **No** | would conflict with "send now" semantics |

#### 4j. Call Settings → General / Call Features

| Field | Value |
|---|---|
| RFC2543 Hold | **No** (default — use modern RFC3264 sendonly) |
| Enable Call-Waiting | **Yes** |
| Enable Call-Waiting Caller ID | **Yes** |
| Enable Call-Waiting Tone | **Yes** |
| Send Anonymous | **No** (otherwise every outbound call hides caller-ID) |
| Anonymous Call Rejection | **No** — let Asterisk's `inbound_whitelist.txt` do the filtering (it understands the `anonymous` token) |
| Outgoing / Incoming Call Duration Limit | **0** (unlimited) |
| Enable Visual MWI | **No** for now (flip to Yes once Asterisk has voicemail) |
| Send Hook Flash Event | **No** (default — HT801 handles flash locally for call-waiting and 3-way) |
| Ring Timeout | **60** (default) |
| Caller ID Display | **Yes** (default) |
| Replace Beginning '+' with 00 in Caller ID | **No** — keep raw E.164 |

Reminder tones, Call Transfer, Hook Flash sub-timings, and Call Display
flags not listed → **leave default**.

#### 4k. Advanced Settings → Security

Two changes from default, both worth making.

| Field | Value | Notes |
|---|---|---|
| Special Feature | **Standard** | other modes (Broadsoft, CBCom, Huawei, etc.) inject carrier-specific SIP quirks that break Asterisk/Telnyx |
| Conference URI | *(blank)* | 3-way is handled locally on the HT801 |
| **Allow SIP Reset** | **No** (disable) | **important** — defaults allow a `NOTIFY Event: reset` to factory-reset the unit over SIP. Anyone who reaches the HT801's SIP port could wipe it. |
| Validate Incoming SIP Message | **Yes** | basic SIP syntax sanity check |
| Check SIP User ID for Incoming INVITE | **Yes** | rejects INVITEs whose `To:` user-part doesn't match SIP User ID `100` — blocks SIP scanners |
| Authenticate Incoming INVITE | **No** (default) | turning it on forces a 401 round-trip on every call; the next option is the stronger mitigation |
| **Allow Incoming SIP Messages from SIP Proxy Only** | **Yes** (enable) | **important** — source-IP-restricts SIP traffic to the resolved address of `ds.local`. Even if a LAN scanner finds the HT801's IP, SIP packets from anywhere else get dropped. |
| Authenticate Server Certificate domain / chain, Trusted Domain Name List | defaults | TLS-only settings; we're on UDP |

> Trade-off with **"from SIP Proxy Only"**: the HT801 only re-resolves
> `ds.local` when its DNS cache expires (mDNS TTL is typically ~120 s).
> If the NAS gets a new DHCP lease, expect up to ~2 minutes of SIP
> rejection before the HT801 catches up. Worth it for the extra hardening.

#### 4l. Call Features Settings (star codes)

Master switches:
- **Enable Local Call Features = Yes** (default) — required for star codes
- **Reset Call Features = Yes** (default)

One feature to actively turn off, the rest leave at defaults:

| Star code | Feature | What to do |
|---|---|---|
| `*47` | **Direct IP Calling** | **Disable** — `*47 <ip>` sends an INVITE directly to an arbitrary IP, bypassing Asterisk completely. No whitelist, no auth, no logging. Kill it. |
| `*16/*17/*18/*19` | SRTP enable/disable | leave defaults — SRTP is off in Codec → RTP, so the codes would just fail call setup. Harmless. |
| `*31/*30`, `*82/*67` | CID enable/disable | leave defaults — `*82`/`*67` are well-known US star codes |
| `*51/*50/*71/*70` | Call Waiting toggle | leave defaults |
| `*69` | Call Return | leave default (local last-number-recall) |
| `*72/*73`, `*90/*91`, `*92/*93` | Call Forward (unconditional / busy / delayed) | leave defaults. HT801 implements these by returning `302 Moved Temporarily`; Asterisk's `[from-internal]` doesn't currently chase 302s, so they're effectively no-ops today — harmless to keep wired. |
| `*74` | Paging | leave default (Asterisk has no paging group; harmless) |
| `*78/*79` | DND | leave defaults (HT801 returns `486 Busy`) |
| `*87` | Blind Transfer | leave default |
| `*03` | Disable LEC per call | leave default |
| `*77` | Off-hook Auto-Dial toggle | leave default |
| `*98` | **Play registration ID** | leave default and **remember it exists** — speaks the current SIP registration status on the handset; invaluable for "is it actually registered?" troubleshooting without opening the web UI |
| `*23` | Star-code 3-Way Conference | leave default; Bellcore-style 3WC (hook-flash) also enabled by default |
| `*02 + 7110 / 7111 / 722` | Forced Codec PCMU / PCMA / G722 | leave defaults — these match Asterisk's loaded codecs |
| `*02 + 723 / 729 / 7201` | Forced Codec G723 / G729 / iLBC | leave defaults but **don't dial them** — Asterisk doesn't load these codecs, so the call will fail setup |

<!-- HT801-PAGE-INSERT -->

### Step 5 — Verify registration on the Asterisk side

```bash
ssh <user>@ds.local
sudo docker exec asterisk asterisk -rx 'pjsip show contacts'
```

You should see a contact for AOR `100` whose URI is `sip:100@<HT801-IP>:5062`.
If you also see a softphone contact for `100`, both will ring in parallel
(`max_contacts=3` in the AOR template). To dedicate the HT801 to its own line,
re-do step 4 against extension `101` instead.

### Step 6 — Smoke test from the analog phone

1. Pick up the handset → you should hear a dial tone (HT801's local tone, not
   Asterisk).
2. Dial `*43` → echo test. Speak; you should hear yourself. This proves
   bidirectional RTP between the HT801 and Asterisk.
3. Dial `860` (or `*60`) → spoken time. Proves dialplan execution.
4. Dial `101` → rings your softphone on extension 101 (if you set one up).
5. Dial your verified Telnyx number in 11-digit form (`15125551234`) → rings
   your mobile. Proves end-to-end outbound through the Telnyx trunk.

### Step 7 — If the HT801 won't register

- **HT801 web UI → Status tab → "SIP Registration"** is the source of truth.
  If it shows *Not Registered* or *Failed*, the registrar can't be reached or
  the password is wrong.
- Watch Asterisk live while you reboot the HT801:
  ```bash
  sudo docker exec -it asterisk asterisk -rvvv
  pjsip set logger on
  ```
  You should see a `REGISTER` from the HT801's IP. If Asterisk logs `401
  Unauthorized` → password mismatch with `[100-auth]`. If you see *nothing* →
  the HT801 isn't reaching the NAS at all (DNS for `ds.local`, or Synology
  firewall blocking UDP 5060 from your LAN).
- Re-test the DNS from a workstation: `dig +short ds.local @224.0.0.251 -p 5353`
  (mDNS query) should return the NAS IP.

### Step 8 — Optional hardening

- Change the HT801 admin password to something long; the web UI is on the LAN
  but it's still a SIP credential proxy.
- HT801 **Advanced Settings → Disable Telnet** (some firmware ships with
  telnet on port 23 enabled).
- HT801 **Advanced Settings → Web Access Mode = HTTPS** if your firmware
  supports it.

---

## Troubleshooting

### Registration fails — `403 Forbidden`
- Wrong password. Re-check `TELNYX_PASSWORD` in `.env` matches the SIP
  Connection's Authentication & Routing tab. Watch out for trailing newlines
  if you pasted it in DSM Text Editor.
- After fixing: `sudo docker-compose restart asterisk`.

### Outbound call says "all circuits are busy"
- Outbound Voice Profile not attached to the SIP Connection. Fix in Telnyx
  portal (see step 1 above).
- Trial: you dialed something other than your verified number.

### Outbound rings but one-way audio (you can hear them, they can't hear you, or vice-versa)
- NAT misconfig. Verify your **actual current public IP** from inside the
  container matches what `PUBLIC_ADDRESS` in `.env` resolves to:
  ```bash
  sudo docker exec asterisk curl -s https://api.ipify.org
  sudo docker exec asterisk getent hosts "$(grep PUBLIC_ADDRESS /etc/asterisk/.env | cut -d= -f2)"
  ```
  If different, fix DDNS (or update `PUBLIC_ADDRESS` in `.env`) and
  `sudo docker-compose restart asterisk`.
- Make sure RTP ports `10000-10100/udp` are not blocked by Synology's firewall
  or any router-level firewall.

### iPhone softphone won't connect
- Make sure the iPhone is on the same Wi-Fi as the Synology.
- Some carrier-provided routers do "AP isolation" between wireless clients —
  disable it in the router settings.
- Synology firewall: allow UDP 5060 from your LAN subnet.

---

## Number whitelists (allowed-callers and allowed-destinations)

Two flat-text files control which numbers can call in and which numbers you
can call out:

| File | Controls | Default |
|---|---|---|
| `config/outbound_whitelist.txt` | Numbers this PBX is allowed to dial | empty → **all outbound BLOCKED** |
| `config/inbound_whitelist.txt`  | Caller-IDs allowed to ring through | contains `*` → all inbound allowed |

**Format:**
- One number per line in **E.164** format (`+15125551234`).
- `;` starts a comment — everything after `;` on a line is ignored, so you can label numbers with names:
  ```
  +15125551234  ; Mom mobile
  +15555550100;Plumber
  ```
- Blank or comment-only lines are ignored.
- A line whose token is just `*` means "allow any number".
- For inbound only, the literal `anonymous` matches calls with no caller-ID.

**Match is format-agnostic for NANP numbers.** Both the inbound CID and your
whitelist entries are normalized to E.164 (`+1NXXNXXXXXX`) before comparing,
so on either side these all match each other:
- `+12063009920` (E.164, recommended)
- `12063009920` (11-digit)
- `2063009920` (10-digit)

This matters because Telnyx isn't strictly consistent — the same DID can
deliver any of the three formats depending on the upstream carrier.
International numbers must include the leading `+`.

**Outbound match happens after normalization.** You can dial any of these
and the PBX will check `+15125551234` against the file:
- `+15125551234` (E.164)
- `15125551234` (11-digit US)
- `5125551234` (10-digit US/CA)

**Edits are LIVE.** The dialplan greps the file on each call — no reload,
no restart. Edit `config/outbound_whitelist.txt` on the NAS via File Station
or SSH, save, then place the next call. That's it.

**Blocked outbound** → caller hears `Sorry, that's not a recognised number`
(Asterisk's `privacy-incorrect` sound) and the call is hung up with cause 21
(call rejected).

**Blocked inbound** → call is rejected with hangup cause 21 *before* Answer(),
so on a paid plan you don't incur billable airtime on rejected spam.

**Verify what got matched** (in the Asterisk CLI):
```
sudo docker exec -it asterisk asterisk -rvvv
```
Look for `Outbound ALLOWED for +1...` or `Inbound BLOCKED from +1...` in the
verbose log when calls flow.

---

## Asterisk CLI for live debugging
```bash
sudo docker exec -it asterisk asterisk -rvvv
```
Useful commands inside:
- `pjsip set logger on` — verbose SIP message log
- `pjsip show endpoint telnyx` — Telnyx trunk state
- `pjsip show registrations`
- `core show channels` — active calls
- `exit`

---

## Rotating the Telnyx password (do this now)

Because the password was pasted in chat:

1. In the Telnyx portal, open the `<your-sip-connection>` SIP Connection → Authentication & Routing.
2. Click **Generate** next to the password → save it.
3. Update `TELNYX_PASSWORD` in `.env` on the NAS.
4. Restart Asterisk to pick up the change:
   ```bash
   sudo docker-compose restart asterisk
   ```
   (Or `sudo docker exec asterisk reload-env` if you want to avoid dropping
   in-flight calls.)
5. Re-check registration with Test 3 above.

---

## Security model

What this PBX already protects against, and what it doesn't:

| Threat | Mitigation in this config |
|---|---|
| Random attacker on the internet brute-forcing ext 100/101 passwords | `[endpoint-template]` has `deny=0.0.0.0/0` + `permit=` for RFC1918 only — internet REGISTER attempts are dropped before auth is even tried |
| Toll fraud via spoofed `[from-internal]` source | Same ACL above. Plus the outbound whitelist is a second layer: even if an attacker got onto the LAN they could only reach numbers you've explicitly allowed |
| Stolen / cracked Telnyx password used by someone else | Out of our hands — rotate the password (see below). Optional: enable Telnyx's portal-side IP allowlist for the SIP Connection |
| Robocall spam ringing your softphones | Inbound whitelist, **but** it defaults to `*` (allow all). Once you have a DID, edit `config/inbound_whitelist.txt` and remove the `*` line |
| Telnyx rotating their SIP edge IPs and breaking inbound | `[telnyx-identify]` uses `match=sip.telnyx.com` (DNS) — usually fine, but DNS-resolved match is only re-evaluated on reload. If inbound stops working: `sudo docker-compose restart asterisk` |
| Plaintext SIP/RTP on the public internet | **Not addressed.** Production should switch to SIP-TLS on 5061 + SRTP. See "When you upgrade" below |

---

## When you upgrade to a paid account

1. Buy a DID in Telnyx portal, assign it to the `<your-sip-connection>` SIP Connection.
2. Set the DID as your outbound caller-ID:
   ```bash
   vi .env                           # set TELNYX_DID=+1XXXXXXXXXX
   sudo docker-compose restart asterisk
   ```
   On the trial Telnyx silently rewrote your From header to your verified number,
   so a placeholder caller-ID worked. **On a paid account that auto-rewrite is
   gone** and any non-DID caller-ID gets rejected with `403 Forbidden`.
   (`TELNYX_DID` drives both the SIP `from_user` and the dialplan `TRUNK_CID`,
   so a single edit covers both.)
3. Inbound routing is driven by `INBOUND_DIAL` in `.env` (default
   `PJSIP/100&PJSIP/101` — rings both extensions in parallel; unregistered
   ones are silently skipped). To override per-DID or send to a different
   target, edit `.env` (or `config/extensions.conf` `[from-telnyx]` for
   more elaborate routing), e.g.:
   ```
   ; .env
   INBOUND_DIAL=PJSIP/100&PJSIP/+15125551234@telnyx-endpoint
   ```
   Then: `sudo docker exec asterisk reload-env`.
4. Restart Asterisk: `sudo docker-compose restart asterisk`.
5. (Recommended) Switch SIP transport to **TLS** on port 5061 and enable
   **SRTP** for media encryption. That's a follow-up task.
6. (Recommended) Install **fail2ban** on the NAS or add IP-restrict rules so
   only Telnyx IPs can hit your SIP port.
