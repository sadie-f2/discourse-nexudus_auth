# discourse-nexudus_auth

Authenticate Discourse users against a Nexudus coworking instance via the Nexudus REST API.

## How it works

1. User submits email + password on a custom OmniAuth form
2. Email is looked up in a paginated, in-process member cache (sourced from `/billing/coworkercontracts`)
3. Password is verified against the Nexudus public token endpoint (`/{space}.spaces.nexudus.com/api/token`)
4. On success, the user is logged into Discourse and added to the configured member group

API calls shell out to `curl` rather than using Ruby's `Net::HTTP` — see **TLS fingerprint note** below.

## Environment variables

| Variable | Description |
|---|---|
| `NEXUDUS_BASE_URL` | API base, default `https://spaces.nexudus.com/api` |
| `NEXUDUS_EMAIL` | Admin email for basic auth |
| `NEXUDUS_PASSWORD` | Admin password for basic auth |
| `NEXUDUS_BOOKING_TOKEN` | Bearer token (alternative to basic auth, leave blank to use basic) |
| `NEXUDUS_SPACE` | Space subdomain, e.g. `artisans` for `artisans.spaces.nexudus.com` |

Set permanently in `app.yml` (`env:` block) and rebuild. Temporary workaround: add to `/etc/default/discourse` — survives restarts but not a full `./launcher rebuild app`.

## Site settings

| Setting | Default | Description |
|---|---|---|
| `nexudus_auth_enabled` | `true` | Enable/disable the provider |
| `nexudus_auth_group` | `makerspace-members` | Discourse group members are added to on login |
| `nexudus_auth_diagnostics` | `false` | Show diagnostic output on failed login — **dev/debug only, never leave on in production** |

## TLS fingerprint note

Ruby's `Net::HTTP` (via OpenSSL) presents a TLS ClientHello fingerprint that Nexudus's CloudFront WAF blocks. All Nexudus API calls therefore shell out to `curl`, which uses libssl and is not blocked.

**On Ubuntu 24 upgrade:** test `probe_auth.rb` against the Nexudus API before assuming curl is still needed. The Ruby + OpenSSL version change may produce a fingerprint that is no longer blocked — if so, the `Open3.capture3('curl', ...)` calls in `lib/nexudus_membership_provider.rb` can be replaced with clean `Net::HTTP`, removing the subprocess overhead and simplifying error handling.

## Known limitations

### Show/hide password toggle

Members want to reveal their password while typing. Three attempts were made:

- **Inline `onclick`** — blocked by Discourse's `script-src` CSP on OmniAuth popup responses
- **`<script>` block with `addEventListener`** — also blocked (CSP applies to all inline scripts)
- **CSP nonce via `action_dispatch.content_security_policy_nonce`** — nonce not populated at OmniAuth middleware depth; script rendered without nonce, still blocked

Additionally, `autocomplete="current-password"` on a custom form field caused some browsers to autofill with the visual mask string (`••••••••`) rather than the real password, breaking `verify_password`. Reverted to `OmniAuth::Form` which avoids both issues.

**Paths to a real fix (in order of effort):**

1. **(4-6 hrs, medium risk)** Serve a small JS file from the plugin's `public/` directory at a predictable same-origin URL and reference it via `<script src="...">` — allowed by `script-src 'self'`. Needs investigation into Discourse's plugin static file serving.

2. **(1-2 days)** Use a Discourse plugin outlet inside the login modal's Ember template to inject a show/hide toggle into the OmniAuth popup's password field.

3. **(2-3 days)** Move the Nexudus email/password fields into Discourse's own login modal as an Ember component, POST to the OmniAuth callback via `fetch`, handle the result in JS. Eliminates the popup entirely and all CSP constraints with it.

Option 3 is architecturally correct. All options carry risk without a staging server.

## Cache architecture

Member data is cached in a class variable (`@@cache`) per Pitchfork worker process, with a 300-second TTL. The cache warms at boot via a background thread. Multiple concurrent requests during a cache-expired window are serialized by a `Mutex` (per-process).

**Known limitation:** each Pitchfork worker holds its own independent cache after fork. Workers can briefly disagree on membership during the TTL window after a Nexudus data change. At typical makerspace traffic levels this is acceptable; if real-time cross-worker consistency is needed, migrate to `Rails.cache` (Redis-backed, shared across all workers).
