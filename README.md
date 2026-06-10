# voip-test-rig

[![Sipfront VoIP Rig CI Tests](https://github.com/sipfront/voip-test-rig/actions/workflows/rig.yml/badge.svg)](https://github.com/sipfront/voip-test-rig/actions/workflows/rig.yml)

A **reference implementation of a typical telco stack** — Kamailio, Asterisk,
rtpengine, MySQL and a [sip.js](https://sipjs.com) WebRTC client — wired so the
whole thing is **automatically tested in a throwaway GitHub runner on every push**,
using [Sipfront](https://sipfront.com) agents for both **SIP and WebRTC**.

Everything that defines the system lives as **plain editable files in this repo**.
Push a change and a runner stands the rig up in Docker, launches Sipfront test
agents into it, runs the full test suite end-to-end, and tears it all down.

```
  Sipfront cloud (dev) ◀──MQTT/443──▶ sf-agent   (agents dial out to the cloud)

┌─────────────────────────────── GitHub runner ───────────────────────────────┐
│  external net 172.30.10.0/24            internal net 172.30.20.0/24         │
│                                                                             │
│  sf-agent ──SIP/RTP──┐                    ┌──▶ asterisk  (MoH/IVR/ooo)      │
│  webapp (sip.js) ─WSS─┼──▶ kamailio ───────┼──▶ jambonz ──▶ Gemini / OpenAI │
│                       │      ▲             │      (voicebot)                │
│                       └─▶ rtpengine ◀──────┘                                │
│                          (media bridge ext◀▶int, transcode)                 │
│                          mysql · redis                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

- **kamailio** — SIP proxy: registration, MySQL digest auth, location lookup. Routes the
  `voicebot` user to jambonz; forces **every** other call through Asterisk so the app
  server owns the media path. Terminates WSS for the web client.
- **asterisk** — application/announcement server (music-on-hold, voicemail, IVR /
  attendant, out-of-office). Sits in the media path for all calls.
- **rtpengine** — media relay between the two networks. Transcodes endpoint codecs
  (Opus, G.722, …) to the G.711 the app servers speak, and bridges WebRTC DTLS-SRTP ⇄
  plain RTP. Userspace-only (`table = -1`), since runners lack the in-kernel module.
- **webapp** — a minimal sip.js SIP-over-WebRTC client served over HTTPS; registers and
  calls over WSS to Kamailio.
- **jambonz** (+ **voicebot**) — a Voice-AI sub-stack (drachtio SBC, rtpengine, FreeSWITCH,
  sbc-inbound, feature-server, redis). Dialing **`voicebot`** reaches it; the `voicebot`
  app bridges the call to a speech-to-speech LLM, behaving per the editable
  `voicebot/system-prompt.md`. The backend is **switchable via `VOICEBOT_VENDOR`** in
  `.env` — `google` (the working default) or `openai`. See
  [Voice-AI voicebot](#voice-ai-voicebot-openai-vs-google) for how each is wired and why
  the OpenAI path is currently blocked.
- **mysql** — Kamailio's subscriber/location store **and** the jambonz `jambones` DB,
  seeded on first boot from `kamailio/initdb.d/*.sql`.

Two docker networks model a real deployment: clients and the web app on the
**external** edge, app/DB services **internal**, with rtpengine the only bridge across.
The editable surface is the config under `kamailio/`, `rtpengine/`, `asterisk/`,
`webapp/`, and `docker-compose.yml`.

## Voice-AI voicebot (OpenAI vs Google)

Dialing **`voicebot`** is routed by Kamailio into the jambonz sub-stack, which answers
and bridges the call to a **speech-to-speech (S2S) LLM**. The bot's persona/behaviour
comes from **`voicebot/system-prompt.md`** — mounted read-only into the container and
**read live on every call** (edit it, next call picks it up; no rebuild).

### How the app picks a backend

`voicebot/lib/routes/voicebot.js` exposes one websocket route (`/voicebot`) and, per
call, emits a jambonz **`llm` verb** built for the vendor named in **`VOICEBOT_VENDOR`**
(`google` | `openai`). Both vendors read the **same** `system-prompt.md`; only the verb
shape and the credential differ:

| | `google` (default) | `openai` |
| --- | --- | --- |
| Env key | `GEMINI_API_KEY` | `OPENAI_API_KEY` |
| jambonz verb | `vendor: google` | `vendor: openai` |
| Model | `models/gemini-2.5-flash-native-audio-latest` (override: `VOICEBOT_GOOGLE_MODEL`) | `gpt-realtime` (override: `VOICEBOT_OPENAI_MODEL`) |
| Prompt → | `llmOptions.setup.systemInstruction` | `llmOptions.session_update.instructions` |
| Voice | `speechConfig` prebuilt voice (`VOICEBOT_GOOGLE_VOICE`, default `Puck`) | `audio.output.voice` (`alloy`) |
| FreeSWITCH module | `mod_google_s2s` (`uuid_google_s2s`) | `mod_openai_s2s` (`uuid_openai_s2s`) |

The **feature-server** runs the verb, but the actual S2S websocket to the provider is
opened by **FreeSWITCH** (the corresponding `mod_*_s2s` module), not by jambonz. That
detail is the crux of the OpenAI problem below.

### Why OpenAI currently doesn't work

The pinned media image is **`drachtio/drachtio-freeswitch-mrf:latest`** (FreeSWITCH
**1.10.10**), paired with **`jambonz/feature-server:10.2.2`**. Its `mod_openai_s2s`
still connects to OpenAI's **Realtime *beta*** endpoint and sends the old beta session
shape. OpenAI has since removed the beta API in favour of GA (`/v1/realtime`), so the
session is rejected a second or two after media is established:

```
beta_api_shape_disabled: The Realtime Beta API is no longer supported.
Please use /v1/realtime for the GA API.
```

The call sets up (SIP + RTP both connect) and then drops when the OpenAI socket closes.
The feature-server itself is GA-aware, but it doesn't open that socket — FreeSWITCH does,
and this image's module predates the cutover. There's no beta/GA toggle on the module and
no newer public `drachtio-freeswitch-mrf` tag with the GA shape, so **OpenAI S2S is an
upstream blocker**, not a config error on our side. Revisit when a newer FreeSWITCH-MRF
image ships an updated `mod_openai_s2s`.

**Google has no such issue:** `mod_google_s2s` talks to the Gemini Live API
(`bidiGenerateContent`) directly, so dialing `voicebot` with `VOICEBOT_VENDOR=google`
connects and holds a real two-way conversation. (One gotcha we hit: the older
`gemini-2.0-flash-live-001` model isn't served on this key's `v1beta` endpoint — hence
the `gemini-2.5-flash-native-audio-latest` default; list valid Live models with
`GET https://generativelanguage.googleapis.com/v1beta/models` and look for those
supporting `bidiGenerateContent`.)

## How it's tested

Each push runs `.github/workflows/rig.yml`: generate an on-demand CA + certs →
`docker compose up` the rig → launch agents → run the Sipfront **`voip-test-rig`
project** (every test in it) → report pass/fail in the job summary → tear everything
down. The job fails if any test fails.

Agents are plain containers on the external network that dial **out** to the Sipfront
cloud over MQTT and join a private **agent pool**; the cloud then drives them to
register and place calls against the rig:

- **Two SIP agents** (`scripts/launch-agents.sh`) for the SIP/RTP tests — basic calls,
  codecs (Opus/G.722), DTMF, hold/retrieve, TLS scan, etc.
- **One browser agent** (`scripts/launch-webrtc-agent.sh`) — a Selenium Chrome plus a
  `sipfront/agent` joined to pool-group **`webrtc`**, which loads the sip.js client in a
  real browser and places WebRTC calls. It trusts the rig CA and reaches the stack by
  its cert-valid FQDNs (`webapp.rig.local`, `kamailio.rig.local`). The browser test
  itself (CodeceptJS script, `browser_url`, credentials) is defined on the Sipfront
  side.

The on-demand CA is mounted into every agent (and the browser) so they accept the rig's
self-signed TLS/WSS.

### Required GitHub secrets

| Secret | Purpose |
| --- | --- |
| `SF_API_PUBLIC_KEY` / `SF_API_SECRET_KEY` | Trigger the project run (`sipfront/action-call-test`) |
| `SF_POOL_ID` / `SF_POOL_SECRET` | The Sipfront agent pool the in-runner agents join |

The `voip-test-rig` project and its tests must already exist on Sipfront and be bound to
that pool.

## Run it locally

```bash
make run            # certs + build + start the rig, wait until ready
make voicebot       # rig + the jambonz Voice-AI stack (opt-in; needs GEMINI_API_KEY in .env)
make agent          # launch 2 SIP agents                         (needs SF_POOL_* in .env)
make webrtc-agent   # launch the WebRTC browser agent + Selenium   (needs SF_POOL_* in .env)
make agent-logs     # follow logs from all running sf-agent-* containers
make down           # stop the rig and remove the agents
```

The jambonz voicebot stack is **opt-in** (a `voicebot` compose profile), so the default
`make run` and CI stay lean. `make voicebot` brings up the rig plus jambonz; then call
`voicebot` to talk to the bot (Gemini Live by default — see
[Voice-AI voicebot](#voice-ai-voicebot-openai-vs-google)).

`make help` lists every target. Copy `.env.example` to `.env` and set
`SF_POOL_ID`/`SF_POOL_SECRET` (optionally override subnets/passwords) before launching
agents.

> Build notes: Kamailio (6.0) and rtpengine (mr26.0) build on Debian stable from
> `deb.kamailio.org`; Asterisk on Debian **bullseye** (the last release shipping the
> daemon). No external tokens or accounts needed.

## Use the rig by hand

**Web client** — open `https://localhost:8081/` and register `webrtc@rig.local` /
`webrtc123` (WSS defaults to `wss://localhost:8443`). Call `moh`, `voicemail`, `ivr`,
`attendant`, `ooo`, or a subscriber (`alice` / `bob`).

> **Trust the CA first.** Browsers silently drop a WSS to an untrusted cert (close
> `1006`), so trust the rig CA up front. macOS:
> ```bash
> sudo security add-trusted-cert -d -r trustRoot \
>   -k /Library/Keychains/System.keychain certs/out/ca.crt
> ```
> (Linux: add `certs/out/ca.crt` to your OS/browser trust store.)

**Softphone** — point at `localhost:5060` (UDP/TCP) or `localhost:5061` (TLS), domain
`rig.local`, as `alice` / `bob` (seeded passwords in `kamailio/initdb.d/10-seed.sql`).
On macOS/Windows use these published `localhost` ports — the container IPs
(`172.30.10.x`) aren't routable from the host.
