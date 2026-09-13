# Semak QR backend

FastAPI endpoint for checking a DuitNow/bank-payment confirmation screenshot before payment.
It reads the screen with a vision model, gathers evidence from four independent sources, then
asks a reasoning model for an evidence-bound, plain-language verdict. Two of the four sources
are offline and need no API key, so the service produces real evidence even with no keys at all. Both model calls go through
OpenRouter on a single API key. The service is stateless: images, extracted payment details,
lookup responses, and verdicts are handled in memory only and never written to disk or a database.

## Pipeline

1. **Vision extraction** — `google/gemini-2.5-flash-lite` via OpenRouter reads the screenshot
   into `{recipient_name, account_number, bank_name, amount}`. Unreadable fields come back
   `null` rather than guessed.
2. **Evidence gathering** — four sources, none of which can fail the request:

   | Source | Key? | Matches | Notes |
   | --- | --- | --- | --- |
   | `local_reports` | no | account number | Offline seed list, in memory |
   | `scam_database` | yes | account number | PenipuMY; one request, never retried |
   | `bnm_alert_list` | no | recipient **name** | BNM Financial Consumer Alert List, in memory |
   | `web_search` | yes | number + name | Exa neural search |

   The two remote lookups run in parallel with a 5s timeout each; the two offline ones are
   dict lookups and add no latency. An unavailable lookup is reported as unavailable rather
   than silently treated as a clean result.
3. **Verdict** — `deepseek/deepseek-chat` via OpenRouter turns the evidence into
   `{risk_level, reason, evidence}`, bound strictly to the lookup results. If it fails or
   returns malformed JSON, a deterministic non-LLM fallback verdict is used instead.

Worst-case provider latency is bounded at roughly 3.5s + 2s + 3s, leaving
headroom for transfer overhead inside the Android client's 10-second timeout.

## Setup

1. Create and activate a virtual environment, then install the dependencies:

   ```powershell
   py -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   ```

2. Copy `.env.example` to `.env` and provide `OPENROUTER_API_KEY`, `PENIPUMY_API_KEY`, and
   `EXA_API_KEY`. Every key is optional at runtime — a missing key degrades that one step
   instead of failing the request. With no keys at all the service still starts, still
   returns 200, and still checks both offline sources.

3. Start the API:

   ```powershell
   uvicorn main:app --host 0.0.0.0 --port 8000 --reload
   ```

## Test it

```powershell
curl.exe -X POST "http://127.0.0.1:8000/check-transaction" `
  -F "screenshot=@C:\path\to\payment-confirmation.png"
```

The response has `risk_level`, `reason`, `evidence`, `recipient_name`, `account_number`,
and `amount`. An unreadable image returns HTTP 200 with `risk_level: "unknown"`; a slow
PenipuMY or Exa lookup is treated as unavailable rather than failing the request. No input
ever produces a 500 or a stack trace.

## Demo account

`TEST_FLAGGED_ACCOUNT` (default `158118482136`) always returns a deterministic
"flagged 3 times" high-risk verdict without touching the live lookups, so the demo's bad
case fires reliably. Matching ignores spaces and dashes, so `1581 1848-2136` also fires.
Every other account number runs the real pipeline.

The same account is also the seed entry in `data/local_flagged_accounts.json`, so the bad
case still fires as high risk through the normal evidence pipeline even if that env var is
unset — two independent paths to the one result the demo depends on.

## Offline data sources

Both files live in `data/` and are read once at startup. A missing or malformed file disables
that one source and logs a warning; it never blocks startup or a request.

**`data/local_flagged_accounts.json`** — flagged account numbers, matched digits-only so
`1581 1848-2136` and `158118482136` are the same account. Every entry **must** carry a
`source`; entries without one are dropped at load time. Use `demo_seed` only for synthetic
demo data, and cite a verifiable public origin for anything real — an invented report is a
false accusation against a real account holder. The shipped seed contains only the demo
account. SemakMule publishes a regularly-updated top-ten list that is a reasonable source
for real entries.

**`data/bnm_consumer_alert.csv`** — Bank Negara's Financial Consumer Alert List (601 entities),
via OpenSanctions' free non-commercial mirror. Refresh it with:

```powershell
curl.exe -L -o data/bnm_consumer_alert.csv `
  "https://data.opensanctions.org/datasets/latest/my_consumer_alert_list/targets.simple.csv"
```

This source matches **entity names, not account numbers**, so a hit means the payee name
matches a company BNM has warned about — suggestive, never proof that this account is a mule
account. Both the prompt and the fallback verdict are worded to preserve that distinction.
Matching is deliberately strict (case, punctuation and company suffixes ignored; a listed name
must match exactly or appear as a whole phrase of at least 8 characters). `IGOFX Sdn Bhd` hits
the listed `IGOFX`; `IGOFX Malaysia` does not, because 5 characters is too short to embed
safely. That trades recall for precision on purpose: wrongly accusing a legitimate business is
a worse failure than a miss the other three sources can still catch.

## Open item before the demo

`PENIPUMY_API_KEY` is issued by approval and we do not have one yet, so `scam_database` reports
`status: "unavailable"` and the other three sources carry the verdict. The request shape is
also **not verified against their docs**: `PENIPUMY_API_URL`, `PENIPUMY_AUTH_HEADER`,
`PENIPUMY_AUTH_PREFIX`, and `PENIPUMY_QUERY_PARAM` are all settable in `.env` so the correct
values can be dropped in without a code change once a key arrives. Note that `penipu.my`
returned 404 through Cloudflare for every API path probed from a server, so verify the endpoint
is reachable from your host early rather than assuming the key alone is enough.

## Privacy

The screenshot, the extracted name/account number, and the verdict are processed entirely in
memory per request and discarded once the response is sent. Nothing is written to a database
or a log file. Diagnostic logging records only exception class names and lookup status —
never user data, query strings, or verdicts.
