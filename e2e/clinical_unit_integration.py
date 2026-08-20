"""Playwright integration checks for a deployed Clinical Unit application.

The runner covers the public frontend, the same-origin backend API proxy, and
the authenticated patient-search workflow. It intentionally does not automate
Entra credentials. Supply a reusable Playwright storage state or opt into a
headed, interactive login.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit


@dataclass(frozen=True)
class Config:
    frontend_url: str
    backend_url: str
    backend_url_is_explicit: bool
    patient_id: str | None
    access_token: str | None
    storage_state: Path | None
    save_storage_state: Path | None
    artifacts_dir: Path
    browser: str
    headed: bool
    interactive_login: bool
    require_authenticated_ui: bool
    ignore_https_errors: bool
    capture_screenshots: bool
    capture_trace: bool
    timeout_ms: int
    login_timeout_ms: int


@dataclass
class CheckResult:
    name: str
    status: str
    duration_ms: int
    detail: str


class CheckRecorder:
    def __init__(self, secrets: list[str | None]) -> None:
        self.results: list[CheckResult] = []
        self._secrets = [secret for secret in secrets if secret]

    def redact(self, value: str) -> str:
        redacted = value
        for secret in self._secrets:
            redacted = redacted.replace(secret, "<redacted>")
            redacted = redacted.replace(quote(secret, safe=""), "<redacted>")
        return redacted

    async def run(
        self,
        name: str,
        operation: Callable[[], Awaitable[str]],
    ) -> bool:
        started = time.perf_counter()
        try:
            detail = self.redact(await operation())
            status = "PASS"
            passed = True
        except Exception as error:
            detail = self.redact(str(error) or error.__class__.__name__)
            status = "FAIL"
            passed = False

        duration_ms = round((time.perf_counter() - started) * 1000)
        self.results.append(CheckResult(name, status, duration_ms, detail))
        print(f"[{status}] {name}: {detail}")
        return passed

    def skip(self, name: str, detail: str) -> None:
        detail = self.redact(detail)
        self.results.append(CheckResult(name, "SKIP", 0, detail))
        print(f"[SKIP] {name}: {detail}")

    def fail(self, name: str, detail: str) -> None:
        detail = self.redact(detail)
        self.results.append(CheckResult(name, "FAIL", 0, detail))
        print(f"[FAIL] {name}: {detail}")


def _normalize_url(value: str, argument_name: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise argparse.ArgumentTypeError(
            f"{argument_name} must be an absolute HTTP or HTTPS URL"
        )
    return value


def _parse_args() -> Config:
    parser = argparse.ArgumentParser(
        description=(
            "Run Playwright API and browser integration checks against Clinical Unit."
        )
    )
    parser.add_argument(
        "--frontend-url",
        default=os.getenv("CLINICAL_UNIT_FRONTEND_URL"),
        help="Deployed frontend origin (env: CLINICAL_UNIT_FRONTEND_URL).",
    )
    parser.add_argument(
        "--backend-url",
        default=os.getenv("CLINICAL_UNIT_BACKEND_URL"),
        help=(
            "Optional direct backend origin. Defaults to the frontend origin for "
            "same-origin /api proxy checks (env: CLINICAL_UNIT_BACKEND_URL)."
        ),
    )
    parser.add_argument(
        "--patient-id",
        default=os.getenv("CLINICAL_UNIT_PATIENT_ID"),
        help=(
            "Synthetic test MRN for positive API and UI checks "
            "(env: CLINICAL_UNIT_PATIENT_ID)."
        ),
    )
    parser.add_argument(
        "--storage-state",
        type=Path,
        default=(
            Path(os.environ["CLINICAL_UNIT_STORAGE_STATE"])
            if os.getenv("CLINICAL_UNIT_STORAGE_STATE")
            else None
        ),
        help="Playwright storage state containing an authenticated Entra session.",
    )
    parser.add_argument(
        "--save-storage-state",
        type=Path,
        help="Save browser auth state after a successful interactive login.",
    )
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "artifacts",
        help="Directory for the JSON report and optional diagnostic artifacts.",
    )
    parser.add_argument(
        "--browser",
        choices=("chromium", "firefox", "webkit"),
        default="chromium",
    )
    parser.add_argument(
        "--headed",
        action="store_true",
        help="Show the browser window.",
    )
    parser.add_argument(
        "--interactive-login",
        action="store_true",
        help="Open a headed browser and wait for a user to complete Entra login.",
    )
    parser.add_argument(
        "--require-authenticated-ui",
        action="store_true",
        help="Fail instead of skipping authenticated UI checks at the login page.",
    )
    parser.add_argument(
        "--ignore-https-errors",
        action="store_true",
        help="Allow non-public test certificates.",
    )
    parser.add_argument(
        "--screenshots",
        action="store_true",
        help="Capture UI screenshots. Use synthetic data because images may contain PHI.",
    )
    parser.add_argument(
        "--trace",
        action="store_true",
        help="Capture a Playwright trace. Traces may include tokens and patient data.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=30,
        help="Timeout for each API or browser operation (default: 30).",
    )
    parser.add_argument(
        "--login-timeout-seconds",
        type=int,
        default=300,
        help="Interactive Entra login timeout (default: 300).",
    )
    args = parser.parse_args()

    if not args.frontend_url:
        parser.error(
            "--frontend-url or CLINICAL_UNIT_FRONTEND_URL is required"
        )
    if args.timeout_seconds <= 0 or args.login_timeout_seconds <= 0:
        parser.error("timeouts must be greater than zero")
    if args.storage_state and not args.storage_state.is_file():
        parser.error(f"storage state does not exist: {args.storage_state}")

    frontend_url = _normalize_url(args.frontend_url, "--frontend-url")
    backend_url_is_explicit = bool(args.backend_url)
    backend_url = _normalize_url(
        args.backend_url or frontend_url,
        "--backend-url",
    )

    return Config(
        frontend_url=frontend_url,
        backend_url=backend_url,
        backend_url_is_explicit=backend_url_is_explicit,
        patient_id=args.patient_id.strip() if args.patient_id else None,
        access_token=os.getenv("CLINICAL_UNIT_ACCESS_TOKEN"),
        storage_state=args.storage_state,
        save_storage_state=args.save_storage_state,
        artifacts_dir=args.artifacts_dir,
        browser=args.browser,
        headed=args.headed or args.interactive_login,
        interactive_login=args.interactive_login,
        require_authenticated_ui=args.require_authenticated_ui,
        ignore_https_errors=args.ignore_https_errors,
        capture_screenshots=args.screenshots,
        capture_trace=args.trace,
        timeout_ms=args.timeout_seconds * 1000,
        login_timeout_ms=args.login_timeout_seconds * 1000,
    )


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


async def _wait_for_frontend_state(
    patient_heading: Any,
    login_button: Any,
    timeout_ms: int,
) -> str:
    deadline = time.monotonic() + (timeout_ms / 1000)
    while time.monotonic() < deadline:
        if await patient_heading.is_visible():
            return "authenticated"
        if await login_button.is_visible():
            return "login"
        await asyncio.sleep(0.25)
    raise AssertionError("neither the login page nor Patient Search became visible")


async def _run(config: Config, async_playwright: Any) -> int:
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = config.artifacts_dir / f"{run_id}-{os.getpid()}"
    run_dir.mkdir(parents=True, exist_ok=False)

    checks = CheckRecorder([config.access_token, config.patient_id])
    page_errors: list[str] = []
    console_errors: list[str] = []
    failed_requests: list[str] = []

    print(f"Frontend: {config.frontend_url}")
    print(f"Backend:  {config.backend_url}")
    print(f"Browser:  {config.browser} ({'headed' if config.headed else 'headless'})")

    async with async_playwright() as playwright:
        request_options = {
            "ignore_https_errors": config.ignore_https_errors,
            "timeout": config.timeout_ms,
        }
        frontend_request = await playwright.request.new_context(
            base_url=config.frontend_url,
            **request_options,
        )

        api_headers = {"Accept": "application/json"}
        if config.access_token:
            api_headers["Authorization"] = f"Bearer {config.access_token}"
        backend_request = await playwright.request.new_context(
            base_url=config.backend_url,
            extra_http_headers=api_headers,
            **request_options,
        )

        async def check_frontend_health() -> str:
            response = await frontend_request.get("/healthz")
            body = await response.text()
            _expect(response.status == 200, f"GET /healthz returned {response.status}")
            _expect(body.strip() == "ok", "GET /healthz did not return 'ok'")
            return "GET /healthz returned 200 and 'ok'"

        async def check_frontend_document() -> str:
            response = await frontend_request.get("/")
            body = await response.text()
            content_type = response.headers.get("content-type", "")
            _expect(response.status == 200, f"GET / returned {response.status}")
            _expect("text/html" in content_type, "GET / was not HTML")
            _expect(
                re.search(r"<title>\s*Clinical Rounds\s*</title>", body) is not None,
                "frontend HTML did not contain the Clinical Rounds title",
            )
            return "frontend HTML loaded with the expected title"

        await checks.run("frontend health", check_frontend_health)
        await checks.run("frontend document", check_frontend_document)

        if config.backend_url_is_explicit:

            async def check_backend_health() -> str:
                response = await backend_request.get("/")
                _expect(response.status == 200, f"GET / returned {response.status}")
                payload = await response.json()
                _expect(
                    payload == {"message": "Hello World"},
                    "backend root returned an unexpected payload",
                )
                return "direct backend root returned the expected health payload"

            await checks.run("backend health", check_backend_health)
        else:
            checks.skip(
                "backend health",
                "direct backend URL not supplied; deployed ingress exposes /api only",
            )

        requested_patient_id = config.patient_id or f"pw-missing-{uuid.uuid4()}"
        patient_path = f"/api/patient/{quote(requested_patient_id, safe='')}"

        async def check_patient_api() -> str:
            response = await backend_request.get(patient_path)
            if not config.access_token:
                _expect(
                    response.status in {401, 403},
                    f"protected patient API returned {response.status} without a token",
                )
                return "protected patient API rejected an unauthenticated request"

            if not config.patient_id:
                _expect(
                    response.status == 404,
                    f"missing-patient lookup returned {response.status}; expected 404",
                )
                payload = await response.json()
                _expect(
                    isinstance(payload, dict) and "error" in payload,
                    "missing-patient response did not contain an error object",
                )
                return "token was accepted and a missing patient returned 404"

            _expect(
                response.status == 200,
                f"configured patient lookup returned {response.status}",
            )
            payload = await response.json()
            patient = payload.get("patient", payload) if isinstance(payload, dict) else None
            _expect(isinstance(patient, dict), "patient API did not return an object")
            returned_id = patient.get("mrn") or patient.get("_id") or patient.get("id")
            _expect(returned_id is not None, "patient API response had no patient identifier")
            _expect(str(returned_id) == config.patient_id, "patient API returned another MRN")
            return "token-backed patient lookup returned the configured synthetic record"

        await checks.run("patient API", check_patient_api)

        browser_type = getattr(playwright, config.browser)
        browser = await browser_type.launch(headless=not config.headed)
        context_options: dict[str, Any] = {
            "ignore_https_errors": config.ignore_https_errors,
            "viewport": {"width": 1440, "height": 1000},
        }
        if config.storage_state:
            context_options["storage_state"] = str(config.storage_state)
        context = await browser.new_context(**context_options)
        context.set_default_timeout(config.timeout_ms)
        context.set_default_navigation_timeout(config.timeout_ms)

        if config.capture_trace:
            await context.tracing.start(screenshots=True, snapshots=True, sources=False)

        page = await context.new_page()
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        page.on(
            "console",
            lambda message: (
                console_errors.append(message.text) if message.type == "error" else None
            ),
        )
        page.on(
            "requestfailed",
            lambda request: failed_requests.append(
                f"{request.method} {request.url}: {request.failure or 'request failed'}"
            ),
        )

        authenticated = False
        browser_loaded = False
        patient_heading = page.get_by_role("heading", name="Patient Search")
        login_button = page.get_by_role("button", name="Log In", exact=True)

        async def check_browser_shell() -> str:
            nonlocal authenticated, browser_loaded
            response = await page.goto(config.frontend_url, wait_until="domcontentloaded")
            _expect(response is not None, "frontend navigation returned no response")
            _expect(response.status < 400, f"frontend navigation returned {response.status}")
            _expect("Clinical Rounds" in await page.title(), "unexpected browser title")
            state = await _wait_for_frontend_state(
                patient_heading,
                login_button,
                config.timeout_ms,
            )
            config_error = page.get_by_role("heading", name="Configuration Error")
            _expect(
                not await config_error.is_visible(),
                "frontend reported an Entra configuration error",
            )
            authenticated = state == "authenticated"
            browser_loaded = True
            return (
                "authenticated Patient Search rendered"
                if authenticated
                else "unauthenticated login page rendered"
            )

        await checks.run("frontend browser shell", check_browser_shell)

        if browser_loaded and not authenticated and config.interactive_login:

            async def check_interactive_login() -> str:
                nonlocal authenticated
                print(
                    "Complete Microsoft Entra authentication in the browser window; "
                    f"waiting up to {config.login_timeout_ms // 1000} seconds."
                )
                await login_button.click()
                await patient_heading.wait_for(
                    state="visible",
                    timeout=config.login_timeout_ms,
                )
                authenticated = True
                return "interactive Entra login completed and Patient Search rendered"

            await checks.run("frontend authentication", check_interactive_login)
        elif authenticated:
            checks.results.append(
                CheckResult(
                    "frontend authentication",
                    "PASS",
                    0,
                    "authenticated browser storage state was accepted",
                )
            )
            print(
                "[PASS] frontend authentication: "
                "authenticated browser storage state was accepted"
            )
        elif config.require_authenticated_ui:
            checks.fail(
                "frontend authentication",
                "login required; provide --storage-state or --interactive-login",
            )
        else:
            checks.skip(
                "frontend authentication",
                "login page verified; provide auth state to exercise Patient Search",
            )

        if authenticated and config.save_storage_state:
            config.save_storage_state.parent.mkdir(parents=True, exist_ok=True)
            await context.storage_state(path=str(config.save_storage_state))
            print(f"Saved browser storage state to {config.save_storage_state}")

        if authenticated and config.patient_id:

            async def check_patient_search_ui() -> str:
                mrn_input = page.get_by_label("MRN", exact=True)
                search_button = page.get_by_role("button", name="Search", exact=True)
                await mrn_input.fill(config.patient_id)
                async with page.expect_response(
                    lambda response: (
                        response.request.method == "GET"
                        and "/api/patient/" in response.url
                    ),
                    timeout=config.timeout_ms,
                ) as response_info:
                    await search_button.click()
                response = await response_info.value
                _expect(
                    response.status == 200,
                    f"browser patient request returned {response.status}",
                )
                await page.get_by_role(
                    "button",
                    name="Switch Patient",
                    exact=True,
                ).wait_for(state="visible")
                return "MRN search loaded the patient view through the /api proxy"

            await checks.run("frontend patient search", check_patient_search_ui)
        elif not authenticated:
            checks.skip("frontend patient search", "authenticated UI is unavailable")
        else:
            checks.skip(
                "frontend patient search",
                "no synthetic patient MRN was supplied",
            )

        async def check_browser_runtime() -> str:
            _expect(
                not page_errors,
                "unhandled browser errors: " + "; ".join(page_errors[:3]),
            )
            return "no unhandled page errors were observed"

        if browser_loaded:
            await checks.run("frontend runtime", check_browser_runtime)
        else:
            checks.skip("frontend runtime", "browser shell did not load")

        if config.capture_screenshots:
            await page.screenshot(path=run_dir / "frontend-final.png", full_page=True)

        if config.capture_trace:
            await context.tracing.stop(path=run_dir / "playwright-trace.zip")

        await context.close()
        await browser.close()
        await backend_request.dispose()
        await frontend_request.dispose()

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "configuration": {
            "frontend_url": config.frontend_url,
            "backend_url": config.backend_url,
            "browser": config.browser,
            "headed": config.headed,
            "patient_id_configured": config.patient_id is not None,
            "access_token_configured": config.access_token is not None,
            "storage_state_configured": config.storage_state is not None,
        },
        "checks": [asdict(result) for result in checks.results],
        "diagnostics": {
            "page_errors": [checks.redact(value) for value in page_errors],
            "console_errors": [checks.redact(value) for value in console_errors],
            "failed_requests": [checks.redact(value) for value in failed_requests],
        },
    }
    report_path = run_dir / "integration-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    failures = sum(result.status == "FAIL" for result in checks.results)
    passes = sum(result.status == "PASS" for result in checks.results)
    skips = sum(result.status == "SKIP" for result in checks.results)
    print(f"Result: {passes} passed, {failures} failed, {skips} skipped")
    print(f"Report: {report_path}")
    return 1 if failures else 0


def main() -> int:
    config = _parse_args()
    try:
        from playwright.async_api import async_playwright
    except ImportError:
        print(
            "Playwright is not installed. Run: "
            "python -m pip install -r e2e/requirements.txt",
            file=sys.stderr,
        )
        return 2

    try:
        return asyncio.run(_run(config, async_playwright))
    except KeyboardInterrupt:
        print("Integration run cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())