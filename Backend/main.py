"""Semak QR's intentionally stateless transaction-screening API."""

import asyncio
import base64
import csv
import json
import logging
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import httpx
from exa_py import AsyncExa
from fastapi import FastAPI, File, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from openai import AsyncOpenAI
from pydantic import BaseModel
from dotenv import load_dotenv


load_dotenv()

# Diagnostics record only exception class names and lookup status, never screenshots,
# account numbers, recipient names, query strings, or verdicts.
logger = logging.getLogger("semakqr")

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

# The Android client has a 10-second request budget. These sequential stages
# must fit inside it, including transfer overhead: 3.5s vision + 2s parallel
# lookups + 3s verdict = 8.5s maximum provider wait time.
VISION_TIMEOUT = 3.5
LOOKUP_TIMEOUT = 2.0
VERDICT_TIMEOUT = 3.0

UNKNOWN_RESPONSE = {
    "risk_level": "unknown",
    "reason": "Couldn't read the QR confirmation screen clearly, please try again.",
}

VISION_PROMPT = """Read this Malaysian bank / DuitNow payment confirmation screenshot.
Extract exactly this JSON object, with no markdown and no additional keys:
{
  "recipient_name": string | null,
  "account_number": string | null,
  "bank_name": string | null,
  "amount": string | number | null
}
Only use text visibly shown in the image. Never infer or guess a missing value.
"""

VERDICT_SYSTEM_PROMPT = """You are a cautious payment-safety assessor. Return only a JSON object with:
{
  "risk_level": "low" | "medium" | "high",
  "reason": "one plain-language sentence with no jargon",
  "evidence": ["short evidence bullet", "..."]
}
Base the verdict only on the lookup evidence supplied by the user. Never invent a
report, source, count, identity match, or conclusion that the evidence does not support.
A lookup whose status is "unavailable" produced no evidence at all - it is not a clean result.
If evidence is unavailable or inconclusive, use medium risk and plainly say checks were inconclusive.

The evidence may contain these sources:
- "local_reports" and "scam_database": checks of this exact account number. A flagged
  account here is the strongest signal available; treat it as high risk.
- "bnm_alert_list": whether the recipient's NAME matches a company Bank Negara has
  warned is unauthorised. This matches names, not account numbers, so it is suggestive
  and never proof that this particular account is a scam account. Say the name matches
  a warned company; do not claim the account itself was reported.
- "web_search": public web results. Only count a result as evidence if it actually
  concerns this account number or recipient; ignore generic scam-advice pages.
"""

# One shared OpenRouter client, opened on startup and closed on shutdown, so no
# per-request connection setup sits inside the latency budget.
llm_client: Optional[AsyncOpenAI] = None
http_client: Optional[httpx.AsyncClient] = None

# Two offline evidence sources, read once at startup and held in memory. They need no
# API key and no network call, so they still produce evidence when every remote lookup
# is unavailable - which is the normal state while PenipuMY access is pending approval.
local_accounts: dict[str, dict[str, Any]] = {}
bnm_alert_list: dict[str, dict[str, Any]] = {}

BASE_DIR = Path(__file__).resolve().parent

# Suffixes carry no identity, so "IGOFX SDN BHD" must match the listed "IGOFX".
COMPANY_SUFFIXES = {
    "SDN", "BHD", "BERHAD", "PLT", "LLP", "LTD", "LIMITED", "INC", "CORP",
    "ENTERPRISE", "ENTERPRISES", "TRADING", "RESOURCES", "HOLDINGS", "GROUP",
}
# A short listed name inside a longer payee name is far more likely to be a coincidence
# than a real hit, so containment matching requires this much distinctive text.
MIN_CONTAINMENT_LENGTH = 8


class ExtractedTransaction(BaseModel):
    recipient_name: Optional[str] = None
    account_number: Optional[str] = None
    bank_name: Optional[str] = None
    amount: Optional[Any] = None


def _clean_text(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _clean_account_number(value: Any) -> Optional[str]:
    """Vision models occasionally return an all-digit account as a JSON number."""
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    return _clean_text(value)


def _digits_only(value: Optional[str]) -> Optional[str]:
    """Compare account numbers by digits so spacing or dashes never change a match."""
    if not value:
        return None
    digits = re.sub(r"\D", "", value)
    return digits or None


def _parse_json_object(value: str) -> Optional[dict[str, Any]]:
    """Accept provider JSON, including an occasional fenced JSON response."""
    cleaned = value.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.IGNORECASE)
    try:
        parsed = json.loads(cleaned)
    except (json.JSONDecodeError, TypeError):
        match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
        if not match:
            return None
        try:
            parsed = json.loads(match.group(0))
        except json.JSONDecodeError:
            return None
    return parsed if isinstance(parsed, dict) else None


def _transaction_from_json(payload: Optional[dict[str, Any]]) -> ExtractedTransaction:
    if not payload:
        return ExtractedTransaction()
    raw_amount = payload.get("amount")
    amount = raw_amount if isinstance(raw_amount, (str, int, float)) and not isinstance(raw_amount, bool) else None
    return ExtractedTransaction(
        recipient_name=_clean_text(payload.get("recipient_name")),
        account_number=_clean_account_number(payload.get("account_number")),
        bank_name=_clean_text(payload.get("bank_name")),
        amount=amount if amount not in ("", None) else None,
    )


def _all_fields_empty(transaction: ExtractedTransaction) -> bool:
    return all(
        value is None
        for value in (
            transaction.recipient_name,
            transaction.account_number,
            transaction.bank_name,
            transaction.amount,
        )
    )


async def extract_transaction(image_bytes: bytes, mime_type: str) -> ExtractedTransaction:
    # Screenshot bytes and extracted payment fields stay in request memory only; never log or persist them.
    if llm_client is None:
        return ExtractedTransaction()
    try:
        encoded_image = base64.b64encode(image_bytes).decode("ascii")
        response = await llm_client.with_options(timeout=VISION_TIMEOUT).chat.completions.create(
            model=os.getenv("OPENROUTER_VISION_MODEL", "google/gemini-2.5-flash-lite"),
            response_format={"type": "json_object"},
            temperature=0,
            max_tokens=300,
            messages=[
                {"role": "system", "content": "Return accurate JSON only."},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": VISION_PROMPT},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:{mime_type};base64,{encoded_image}"},
                        },
                    ],
                },
            ],
        )
        content = response.choices[0].message.content or ""
        return _transaction_from_json(_parse_json_object(content))
    except Exception as exc:
        # Provider failures deliberately look like an unreadable screen to the client.
        logger.warning("vision extraction failed: %s", type(exc).__name__)
        return ExtractedTransaction()


def _coerce_count(value: Any) -> int:
    try:
        count = int(value)
    except (TypeError, ValueError):
        return 0
    return max(count, 0)


def _normalize_penipumy(data: Any) -> dict[str, Any]:
    """Tolerate the shapes PenipuMY may return: a record, a wrapper, or a result list."""
    if isinstance(data, dict):
        for key in ("data", "result", "results"):
            if key in data:
                return _normalize_penipumy(data[key])
        record = data
    elif isinstance(data, list):
        if not data:
            return {"status": "available", "flagged": False, "report_count": 0}
        record = data[0] if isinstance(data[0], dict) else {}
    else:
        return {"status": "unavailable", "detail": "unexpected_response_shape"}

    report_count = max(
        _coerce_count(record.get("police_report_count")),
        _coerce_count(record.get("verified_report_count")),
        _coerce_count(record.get("report_count")),
        _coerce_count(record.get("reports")),
        _coerce_count(record.get("count")),
    )
    flagged = bool(record.get("fraud") or record.get("is_scam") or record.get("flagged")) or report_count > 0
    return {
        "status": "available",
        "flagged": flagged,
        "report_count": report_count,
        "police_report_status": record.get("police_report_status", "unknown"),
    }


async def penipumy_lookup(account_number: Optional[str]) -> dict[str, Any]:
    """Make at most one PenipuMY request for this transaction."""
    api_key = os.getenv("PENIPUMY_API_KEY")
    if not account_number or not api_key or http_client is None:
        return {"status": "unavailable", "detail": "not_configured"}

    # Endpoint, auth header and query parameter are configurable so the exact values
    # from PenipuMY's docs can be set in .env without a code change.
    url = os.getenv("PENIPUMY_API_URL", "https://penipu.my/api/v1/search")
    header_name = os.getenv("PENIPUMY_AUTH_HEADER", "X-API-Key")
    header_prefix = os.getenv("PENIPUMY_AUTH_PREFIX", "")
    query_param = os.getenv("PENIPUMY_QUERY_PARAM", "q")
    try:
        response = await http_client.get(
            url,
            params={query_param: account_number},
            headers={header_name: f"{header_prefix}{api_key}"},
            timeout=LOOKUP_TIMEOUT,
        )
        response.raise_for_status()
        data = response.json()
    except httpx.HTTPStatusError as exc:
        # A wrong endpoint or key must be distinguishable from a genuinely clean account.
        logger.warning("penipumy lookup rejected: http_%s", exc.response.status_code)
        return {"status": "unavailable", "detail": f"http_{exc.response.status_code}"}
    except httpx.TimeoutException:
        logger.warning("penipumy lookup timed out")
        return {"status": "unavailable", "detail": "timeout"}
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        logger.warning("penipumy lookup failed: %s", type(exc).__name__)
        return {"status": "unavailable", "detail": type(exc).__name__}
    # Only lookup evidence is kept briefly for the verdict; neither it nor PII is logged or stored.
    return _normalize_penipumy(data)


async def _exa_search(client: AsyncExa, query: str) -> Any:
    """Ask for highlights, but stay compatible with SDK versions that lack them.

    A kwarg rejected by the installed exa-py must not be swallowed as a timeout -
    that would silently disable this lookup on every single request.
    """
    try:
        return await client.search_and_contents(
            query, type="neural", num_results=5, highlights=True
        )
    except TypeError:
        return await client.search(query, num_results=5)


async def exa_lookup(account_number: Optional[str], recipient_name: Optional[str]) -> dict[str, Any]:
    api_key = os.getenv("EXA_API_KEY")
    query_terms = " ".join(item for item in (account_number, recipient_name) if item)
    if not query_terms or not api_key:
        return {"status": "unavailable", "detail": "not_configured", "results": []}
    try:
        client = AsyncExa(api_key=api_key)
        result = await asyncio.wait_for(
            _exa_search(client, f"{query_terms} scam penipu reported"),
            timeout=LOOKUP_TIMEOUT,
        )
        results = []
        for item in (getattr(result, "results", None) or [])[:5]:
            results.append(
                {
                    "title": getattr(item, "title", None),
                    "url": getattr(item, "url", None),
                    "highlights": (getattr(item, "highlights", None) or [])[:2],
                }
            )
        # Search evidence exists only in this request while the verdict model evaluates it; never persisted or logged.
        return {"status": "available", "results": results}
    except asyncio.TimeoutError:
        # The lookup is intentionally best-effort: a slow search must not block a payment warning.
        logger.warning("exa lookup timed out")
        return {"status": "unavailable", "detail": "timeout", "results": []}
    except Exception as exc:
        logger.warning("exa lookup failed: %s", type(exc).__name__)
        return {"status": "unavailable", "detail": type(exc).__name__, "results": []}


def _normalize_name(value: Optional[str]) -> Optional[str]:
    """Compare payee names ignoring case, punctuation and company suffixes."""
    if not value:
        return None
    text = re.sub(r"[^A-Za-z0-9\s]", " ", value).upper()
    tokens = [token for token in text.split() if token not in COMPANY_SUFFIXES]
    return " ".join(tokens) or None


def _resolve_data_path(env_var: str, default: str) -> Path:
    """Resolve relative to this file so the working directory can't break startup."""
    configured = Path(os.getenv(env_var, default))
    return configured if configured.is_absolute() else BASE_DIR / configured


def load_local_accounts() -> dict[str, dict[str, Any]]:
    """Offline list of known-flagged accounts, keyed by digits so spacing never matters."""
    path = _resolve_data_path("LOCAL_FLAGGED_ACCOUNTS_PATH", "data/local_flagged_accounts.json")
    index: dict[str, dict[str, Any]] = {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        entries = payload.get("accounts") if isinstance(payload, dict) else payload
        for entry in entries or []:
            if not isinstance(entry, dict):
                continue
            digits = _digits_only(_clean_account_number(entry.get("account_number")))
            source = _clean_text(entry.get("source"))
            # An entry with no stated source is not evidence - accusing a real account
            # without a citable origin is exactly the failure this file must not ship.
            if not digits or not source:
                continue
            index[digits] = {
                "report_count": _coerce_count(entry.get("report_count")),
                "source": source,
                "note": _clean_text(entry.get("note")),
            }
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        logger.warning("local flagged-account list unavailable: %s", type(exc).__name__)
        return {}
    return index


def load_bnm_alert_list() -> dict[str, dict[str, Any]]:
    """Bank Negara's Financial Consumer Alert List, indexed by normalized name and alias."""
    path = _resolve_data_path("BNM_ALERT_LIST_PATH", "data/bnm_consumer_alert.csv")
    index: dict[str, dict[str, Any]] = {}
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                listed_name = _clean_text(row.get("name"))
                if not listed_name:
                    continue
                record = {
                    "listed_name": listed_name,
                    "listed_since": _clean_text(row.get("sanctions")),
                }
                aliases = (row.get("aliases") or "").split(";")
                for candidate in [listed_name, *aliases]:
                    key = _normalize_name(candidate)
                    if key:
                        index.setdefault(key, record)
    except (OSError, ValueError, TypeError, csv.Error) as exc:
        logger.warning("bnm alert list unavailable: %s", type(exc).__name__)
        return {}
    return index


def local_account_lookup(account_number: Optional[str]) -> dict[str, Any]:
    """In-memory account check; no network call, so it cannot time out or be rate limited."""
    if not local_accounts:
        return {"status": "unavailable", "detail": "not_loaded"}
    digits = _digits_only(account_number)
    record = local_accounts.get(digits) if digits else None
    if not record:
        return {"status": "available", "flagged": False}
    return {"status": "available", "flagged": True, **record}


def bnm_alert_lookup(recipient_name: Optional[str]) -> dict[str, Any]:
    """Name-based check against BNM's alert list.

    This matches entity names, never account numbers, so a hit means the payee name
    matches an entity BNM has flagged as unauthorised - suggestive, not proof of a
    mule account. Matching stays deliberately strict: wrongly flagging a legitimate
    business is a worse failure here than missing a scam the other sources can catch.
    """
    if not bnm_alert_list:
        return {"status": "unavailable", "detail": "not_loaded"}
    key = _normalize_name(recipient_name)
    if not key:
        return {"status": "available", "listed": False}

    record = bnm_alert_list.get(key)
    if record is None:
        # A listed entity often appears on the payment screen wrapped in extra words.
        for listed_key, candidate in bnm_alert_list.items():
            if len(listed_key) < MIN_CONTAINMENT_LENGTH:
                continue
            if re.search(rf"(?:^|\s){re.escape(listed_key)}(?:\s|$)", key):
                record = candidate
                break
    if record is None:
        return {"status": "available", "listed": False}
    return {"status": "available", "listed": True, **record}


def fallback_verdict(sources: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Safe response if the verdict model is unavailable or returns malformed JSON."""
    local = sources.get("local_reports", {})
    scam_db = sources.get("scam_database", {})
    bnm = sources.get("bnm_alert_list", {})
    web = sources.get("web_search", {})

    if local.get("flagged") or scam_db.get("flagged"):
        reports = max(
            _coerce_count(local.get("report_count")),
            _coerce_count(scam_db.get("report_count")),
        )
        detail = (
            f"Scam-report checks returned {reports} report(s) for this account."
            if reports
            else "Scam-report checks flagged this account."
        )
        return {
            "risk_level": "high",
            "reason": "This account has been flagged in scam-report checks.",
            "evidence": [detail],
        }
    if bnm.get("listed"):
        # A name match is suggestive, not proof this specific account is a mule account.
        return {
            "risk_level": "high",
            "reason": "The recipient's name matches a company Bank Negara has warned the public about.",
            "evidence": [
                f"Bank Negara Financial Consumer Alert List entry: {bnm.get('listed_name')}."
            ],
        }
    if any(source.get("status") == "available" for source in sources.values()):
        return {
            "risk_level": "medium",
            "reason": "Available checks did not provide enough evidence to confirm this payment is safe.",
            "evidence": ["No conclusive risk verdict was available from all checks."],
        }
    return {
        "risk_level": "medium",
        "reason": "We couldn't complete enough safety checks to assess this payment.",
        "evidence": ["Scam-database and web-search checks were unavailable."],
    }


async def create_verdict(transaction: ExtractedTransaction, sources: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if llm_client is None:
        return fallback_verdict(sources)
    # Evidence is assembled in memory for this one call and discarded with the response.
    # Sources are named by what they are, not by vendor, so swapping a provider never
    # requires rewording the prompt the model was tuned against.
    evidence = {"transaction": transaction.model_dump(), **sources}
    try:
        response = await llm_client.with_options(timeout=VERDICT_TIMEOUT).chat.completions.create(
            model=os.getenv("OPENROUTER_REASONING_MODEL", "deepseek/deepseek-chat"),
            response_format={"type": "json_object"},
            temperature=0,
            max_tokens=400,
            messages=[
                {"role": "system", "content": VERDICT_SYSTEM_PROMPT},
                {"role": "user", "content": json.dumps(evidence)},
            ],
        )
        verdict = _parse_json_object(response.choices[0].message.content or "")
        if not verdict or verdict.get("risk_level") not in {"low", "medium", "high"}:
            return fallback_verdict(sources)
        reason = _clean_text(verdict.get("reason"))
        evidence_items = verdict.get("evidence")
        if not reason or not isinstance(evidence_items, list):
            return fallback_verdict(sources)
        return {
            "risk_level": verdict["risk_level"],
            "reason": reason,
            "evidence": [_clean_text(item) for item in evidence_items if _clean_text(item)],
        }
    except Exception as exc:
        logger.warning("verdict model failed: %s", type(exc).__name__)
        return fallback_verdict(sources)


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Hold pooled clients for the process lifetime instead of rebuilding them per request."""
    global llm_client, http_client, local_accounts, bnm_alert_list
    # Offline sources are read once here rather than per request. Both loaders return
    # empty on any failure, which surfaces as "unavailable" rather than a false clean.
    local_accounts = load_local_accounts()
    bnm_alert_list = load_bnm_alert_list()
    logger.info(
        "offline sources loaded: %d local account(s), %d bnm name(s)",
        len(local_accounts),
        len(bnm_alert_list),
    )
    api_key = os.getenv("OPENROUTER_API_KEY")
    if api_key:
        llm_client = AsyncOpenAI(
            api_key=api_key,
            base_url=OPENROUTER_BASE_URL,
            timeout=VISION_TIMEOUT,
            max_retries=0,
            default_headers={
                "HTTP-Referer": os.getenv("OPENROUTER_SITE_URL", "https://semakqr.local"),
                "X-Title": "Semak QR",
            },
        )
    http_client = httpx.AsyncClient(timeout=LOOKUP_TIMEOUT)
    try:
        yield
    finally:
        if llm_client is not None:
            await llm_client.close()
            llm_client = None
        if http_client is not None:
            await http_client.aclose()
            http_client = None


app = FastAPI(title="Semak QR API", version="0.2.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/check-transaction")
async def check_transaction(screenshot: Optional[UploadFile] = File(default=None)) -> dict[str, Any]:
    """Screen one payment confirmation image without retaining user data."""
    try:
        if screenshot is None or not (screenshot.content_type or "").startswith("image/"):
            return UNKNOWN_RESPONSE

        # Uploaded image bytes stay in memory for this request only, then are discarded with the response.
        image_bytes = await screenshot.read()
        if not image_bytes:
            return UNKNOWN_RESPONSE
        transaction = await extract_transaction(image_bytes, screenshot.content_type or "image/jpeg")
        if _all_fields_empty(transaction):
            return UNKNOWN_RESPONSE

        test_account = _digits_only(os.getenv("TEST_FLAGGED_ACCOUNT"))
        if test_account and _digits_only(transaction.account_number) == test_account:
            # Demo-only test data is deterministic; no live lookup occurs for this exact configured account.
            verdict = {
                "risk_level": "high",
                "reason": "This account was flagged 3 times in scam-report checks.",
                "evidence": ["Demo safety check: account flagged 3 times."],
            }
        else:
            # Remote lookups run in parallel; the two offline sources are plain dict
            # lookups, so they add no latency and still produce evidence when both
            # remote lookups are unavailable.
            penipumy, exa = await asyncio.gather(
                penipumy_lookup(transaction.account_number),
                exa_lookup(transaction.account_number, transaction.recipient_name),
            )
            sources = {
                "local_reports": local_account_lookup(transaction.account_number),
                "scam_database": penipumy,
                "bnm_alert_list": bnm_alert_lookup(transaction.recipient_name),
                "web_search": exa,
            }
            verdict = await create_verdict(transaction, sources)

        # The response is generated from in-memory request data only; no screenshot, PII, or verdict is retained.
        return {
            **verdict,
            "recipient_name": transaction.recipient_name,
            "account_number": transaction.account_number,
            "amount": transaction.amount,
        }
    except Exception as exc:
        # Never expose provider exceptions, tracebacks, or implementation details to the client.
        logger.warning("check-transaction failed: %s", type(exc).__name__)
        return UNKNOWN_RESPONSE
