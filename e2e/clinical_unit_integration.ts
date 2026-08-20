/** Playwright integration checks for a deployed Clinical Unit application. */

import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import process from "node:process";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import {
  chromium,
  firefox,
  request as playwrightRequest,
  webkit,
  type BrowserContextOptions,
  type Locator,
} from "playwright";

type BrowserName = "chromium" | "firefox" | "webkit";
type CheckStatus = "PASS" | "FAIL" | "SKIP";
type FrontendState = "authenticated" | "login";

interface Config {
  frontendUrl: string;
  backendUrl: string;
  backendUrlIsExplicit: boolean;
  patientId?: string;
  accessToken?: string;
  storageState?: string;
  saveStorageState?: string;
  artifactsDir: string;
  browser: BrowserName;
  headed: boolean;
  interactiveLogin: boolean;
  requireAuthenticatedUi: boolean;
  ignoreHttpsErrors: boolean;
  captureScreenshots: boolean;
  captureTrace: boolean;
  timeoutMs: number;
  loginTimeoutMs: number;
}

interface CheckResult {
  name: string;
  status: CheckStatus;
  duration_ms: number;
  detail: string;
}

class CheckRecorder {
  readonly results: CheckResult[] = [];
  private readonly secrets: string[];

  constructor(secrets: Array<string | undefined>) {
    this.secrets = secrets.filter((secret): secret is string => Boolean(secret));
  }

  redact(value: string): string {
    let redacted = value;
    for (const secret of this.secrets) {
      redacted = redacted.replaceAll(secret, "<redacted>");
      redacted = redacted.replaceAll(encodeURIComponent(secret), "<redacted>");
    }
    return redacted;
  }

  async run(name: string, operation: () => Promise<string>): Promise<boolean> {
    const started = performance.now();
    let detail: string;
    let status: CheckStatus;

    try {
      detail = this.redact(await operation());
      status = "PASS";
    } catch (error) {
      detail = this.redact(formatError(error));
      status = "FAIL";
    }

    const durationMs = Math.round(performance.now() - started);
    this.results.push({ name, status, duration_ms: durationMs, detail });
    console.log(`[${status}] ${name}: ${detail}`);
    return status === "PASS";
  }

  skip(name: string, detail: string): void {
    const redacted = this.redact(detail);
    this.results.push({ name, status: "SKIP", duration_ms: 0, detail: redacted });
    console.log(`[SKIP] ${name}: ${redacted}`);
  }

  fail(name: string, detail: string): void {
    const redacted = this.redact(detail);
    this.results.push({ name, status: "FAIL", duration_ms: 0, detail: redacted });
    console.log(`[FAIL] ${name}: ${redacted}`);
  }
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function expectCondition(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeUrl(value: string, argumentName: string): string {
  const normalized = value.trim().replace(/\/+$/, "");
  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    throw new Error(`${argumentName} must be an absolute HTTP or HTTPS URL`);
  }

  if (!["http:", "https:"].includes(parsed.protocol) || !parsed.host) {
    throw new Error(`${argumentName} must be an absolute HTTP or HTTPS URL`);
  }
  return normalized;
}

function parsePositiveInteger(
  value: string | undefined,
  defaultValue: number,
  argumentName: string,
): number {
  const parsed = value === undefined ? defaultValue : Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${argumentName} must be a positive integer`);
  }
  return parsed;
}

function printHelp(): void {
  console.log(`Run Playwright API and browser integration checks against Clinical Unit.

Usage:
  npm run test:integration -- --frontend-url <url> [options]

Options:
  --frontend-url <url>          Deployed frontend origin
  --backend-url <url>           Optional direct backend origin
  --patient-id <mrn>            Synthetic test MRN
  --storage-state <path>        Authenticated Playwright storage state
  --save-storage-state <path>   Save state after interactive login
  --artifacts-dir <path>        Report and diagnostic artifact directory
  --browser <name>              chromium, firefox, or webkit (default: chromium)
  --headed                      Show the browser window
  --interactive-login           Wait for a user to complete Entra login
  --require-authenticated-ui    Fail when the authenticated UI is unavailable
  --ignore-https-errors         Allow non-public test certificates
  --screenshots                 Capture a final full-page screenshot
  --trace                       Capture a Playwright trace
  --timeout-seconds <seconds>   Operation timeout (default: 30)
  --login-timeout-seconds <s>   Interactive login timeout (default: 300)
  --help                        Show this help

Environment:
  CLINICAL_UNIT_FRONTEND_URL, CLINICAL_UNIT_BACKEND_URL,
  CLINICAL_UNIT_PATIENT_ID, CLINICAL_UNIT_ACCESS_TOKEN,
  CLINICAL_UNIT_STORAGE_STATE`);
}

function parseConfig(): Config | undefined {
  const { values } = parseArgs({
    options: {
      "frontend-url": { type: "string" },
      "backend-url": { type: "string" },
      "patient-id": { type: "string" },
      "storage-state": { type: "string" },
      "save-storage-state": { type: "string" },
      "artifacts-dir": { type: "string" },
      browser: { type: "string" },
      headed: { type: "boolean" },
      "interactive-login": { type: "boolean" },
      "require-authenticated-ui": { type: "boolean" },
      "ignore-https-errors": { type: "boolean" },
      screenshots: { type: "boolean" },
      trace: { type: "boolean" },
      "timeout-seconds": { type: "string" },
      "login-timeout-seconds": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
    strict: true,
    allowPositionals: false,
  });

  if (values.help) {
    printHelp();
    return undefined;
  }

  const frontendUrlValue = values["frontend-url"] ?? process.env.CLINICAL_UNIT_FRONTEND_URL;
  if (!frontendUrlValue) {
    throw new Error("--frontend-url or CLINICAL_UNIT_FRONTEND_URL is required");
  }

  const backendUrlValue = values["backend-url"] ?? process.env.CLINICAL_UNIT_BACKEND_URL;
  const patientIdValue = values["patient-id"] ?? process.env.CLINICAL_UNIT_PATIENT_ID;
  const storageStateValue =
    values["storage-state"] ?? process.env.CLINICAL_UNIT_STORAGE_STATE;
  const browserValue = values.browser ?? "chromium";
  if (!["chromium", "firefox", "webkit"].includes(browserValue)) {
    throw new Error("--browser must be chromium, firefox, or webkit");
  }
  if (storageStateValue && !existsSync(storageStateValue)) {
    throw new Error(`storage state does not exist: ${storageStateValue}`);
  }

  const frontendUrl = normalizeUrl(frontendUrlValue, "--frontend-url");
  const backendUrlIsExplicit = Boolean(backendUrlValue);
  const backendUrl = normalizeUrl(backendUrlValue ?? frontendUrl, "--backend-url");
  const scriptDirectory = dirname(fileURLToPath(import.meta.url));

  return {
    frontendUrl,
    backendUrl,
    backendUrlIsExplicit,
    ...(patientIdValue?.trim() ? { patientId: patientIdValue.trim() } : {}),
    ...(process.env.CLINICAL_UNIT_ACCESS_TOKEN
      ? { accessToken: process.env.CLINICAL_UNIT_ACCESS_TOKEN }
      : {}),
    ...(storageStateValue ? { storageState: resolve(storageStateValue) } : {}),
    ...(values["save-storage-state"]
      ? { saveStorageState: resolve(values["save-storage-state"]) }
      : {}),
    artifactsDir: resolve(values["artifacts-dir"] ?? join(scriptDirectory, "artifacts")),
    browser: browserValue as BrowserName,
    headed: Boolean(values.headed || values["interactive-login"]),
    interactiveLogin: Boolean(values["interactive-login"]),
    requireAuthenticatedUi: Boolean(values["require-authenticated-ui"]),
    ignoreHttpsErrors: Boolean(values["ignore-https-errors"]),
    captureScreenshots: Boolean(values.screenshots),
    captureTrace: Boolean(values.trace),
    timeoutMs:
      parsePositiveInteger(values["timeout-seconds"], 30, "--timeout-seconds") * 1000,
    loginTimeoutMs:
      parsePositiveInteger(
        values["login-timeout-seconds"],
        300,
        "--login-timeout-seconds",
      ) * 1000,
  };
}

async function waitForFrontendState(
  patientHeading: Locator,
  loginButton: Locator,
  timeoutMs: number,
): Promise<FrontendState> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (await patientHeading.isVisible()) {
      return "authenticated";
    }
    if (await loginButton.isVisible()) {
      return "login";
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
  }
  throw new Error("neither the login page nor Patient Search became visible");
}

function selectBrowser(browser: BrowserName) {
  switch (browser) {
    case "firefox":
      return firefox;
    case "webkit":
      return webkit;
    default:
      return chromium;
  }
}

function createRunId(): string {
  return new Date().toISOString().replaceAll("-", "").replaceAll(":", "").replace(/\.\d{3}Z$/, "Z");
}

async function run(config: Config): Promise<number> {
  const runDirectory = join(config.artifactsDir, `${createRunId()}-${process.pid}`);
  await mkdir(runDirectory, { recursive: true });

  const checks = new CheckRecorder([config.accessToken, config.patientId]);
  const pageErrors: string[] = [];
  const consoleErrors: string[] = [];
  const failedRequests: string[] = [];

  console.log(`Frontend: ${config.frontendUrl}`);
  console.log(`Backend:  ${config.backendUrl}`);
  console.log(`Browser:  ${config.browser} (${config.headed ? "headed" : "headless"})`);

  const requestOptions = {
    ignoreHTTPSErrors: config.ignoreHttpsErrors,
    timeout: config.timeoutMs,
  };
  const frontendRequest = await playwrightRequest.newContext({
    baseURL: config.frontendUrl,
    ...requestOptions,
  });
  const apiHeaders: Record<string, string> = { Accept: "application/json" };
  if (config.accessToken) {
    apiHeaders.Authorization = `Bearer ${config.accessToken}`;
  }
  const backendRequest = await playwrightRequest.newContext({
    baseURL: config.backendUrl,
    extraHTTPHeaders: apiHeaders,
    ...requestOptions,
  });

  await checks.run("frontend health", async () => {
    const response = await frontendRequest.get("/healthz");
    const body = await response.text();
    expectCondition(response.status() === 200, `GET /healthz returned ${response.status()}`);
    expectCondition(body.trim() === "ok", "GET /healthz did not return 'ok'");
    return "GET /healthz returned 200 and 'ok'";
  });

  await checks.run("frontend document", async () => {
    const response = await frontendRequest.get("/");
    const body = await response.text();
    const contentType = response.headers()["content-type"] ?? "";
    expectCondition(response.status() === 200, `GET / returned ${response.status()}`);
    expectCondition(contentType.includes("text/html"), "GET / was not HTML");
    expectCondition(
      /<title>\s*Clinical Rounds\s*<\/title>/.test(body),
      "frontend HTML did not contain the Clinical Rounds title",
    );
    return "frontend HTML loaded with the expected title";
  });

  if (config.backendUrlIsExplicit) {
    await checks.run("backend health", async () => {
      const response = await backendRequest.get("/");
      expectCondition(response.status() === 200, `GET / returned ${response.status()}`);
      const payload: unknown = await response.json();
      expectCondition(
        isRecord(payload) && payload.message === "Hello World" && Object.keys(payload).length === 1,
        "backend root returned an unexpected payload",
      );
      return "direct backend root returned the expected health payload";
    });
  } else {
    checks.skip(
      "backend health",
      "direct backend URL not supplied; deployed ingress exposes /api only",
    );
  }

  const requestedPatientId = config.patientId ?? `pw-missing-${randomUUID()}`;
  const patientPath = `/api/patient/${encodeURIComponent(requestedPatientId)}`;
  await checks.run("patient API", async () => {
    const response = await backendRequest.get(patientPath);
    if (!config.accessToken) {
      expectCondition(
        [401, 403].includes(response.status()),
        `protected patient API returned ${response.status()} without a token`,
      );
      return "protected patient API rejected an unauthenticated request";
    }

    if (!config.patientId) {
      expectCondition(
        response.status() === 404,
        `missing-patient lookup returned ${response.status()}; expected 404`,
      );
      const payload: unknown = await response.json();
      expectCondition(
        isRecord(payload) && "error" in payload,
        "missing-patient response did not contain an error object",
      );
      return "token was accepted and a missing patient returned 404";
    }

    expectCondition(
      response.status() === 200,
      `configured patient lookup returned ${response.status()}`,
    );
    const payload: unknown = await response.json();
    const patient = isRecord(payload) && isRecord(payload.patient) ? payload.patient : payload;
    expectCondition(isRecord(patient), "patient API did not return an object");
    const returnedId = patient.mrn ?? patient._id ?? patient.id;
    expectCondition(returnedId !== undefined, "patient API response had no patient identifier");
    expectCondition(String(returnedId) === config.patientId, "patient API returned another MRN");
    return "token-backed patient lookup returned the configured synthetic record";
  });

  const browser = await selectBrowser(config.browser).launch({ headless: !config.headed });
  const contextOptions: BrowserContextOptions = {
    ignoreHTTPSErrors: config.ignoreHttpsErrors,
    viewport: { width: 1440, height: 1000 },
    ...(config.storageState ? { storageState: config.storageState } : {}),
  };
  const context = await browser.newContext(contextOptions);
  context.setDefaultTimeout(config.timeoutMs);
  context.setDefaultNavigationTimeout(config.timeoutMs);

  if (config.captureTrace) {
    await context.tracing.start({ screenshots: true, snapshots: true, sources: false });
  }

  const page = await context.newPage();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
    }
  });
  page.on("requestfailed", (request) => {
    failedRequests.push(
      `${request.method()} ${request.url()}: ${request.failure()?.errorText ?? "request failed"}`,
    );
  });

  let authenticated = false;
  let browserLoaded = false;
  const patientHeading = page.getByRole("heading", { name: "Patient Search" });
  const loginButton = page.getByRole("button", { name: "Log In", exact: true });

  await checks.run("frontend browser shell", async () => {
    const response = await page.goto(config.frontendUrl, { waitUntil: "domcontentloaded" });
    expectCondition(response, "frontend navigation returned no response");
    expectCondition(response.status() < 400, `frontend navigation returned ${response.status()}`);
    expectCondition((await page.title()).includes("Clinical Rounds"), "unexpected browser title");
    const state = await waitForFrontendState(patientHeading, loginButton, config.timeoutMs);
    const configError = page.getByRole("heading", { name: "Configuration Error" });
    expectCondition(
      !(await configError.isVisible()),
      "frontend reported an Entra configuration error",
    );
    authenticated = state === "authenticated";
    browserLoaded = true;
    return authenticated
      ? "authenticated Patient Search rendered"
      : "unauthenticated login page rendered";
  });

  if (browserLoaded && !authenticated && config.interactiveLogin) {
    await checks.run("frontend authentication", async () => {
      console.log(
        "Complete Microsoft Entra authentication in the browser window; " +
          `waiting up to ${config.loginTimeoutMs / 1000} seconds.`,
      );
      await loginButton.click();
      await patientHeading.waitFor({ state: "visible", timeout: config.loginTimeoutMs });
      authenticated = true;
      return "interactive Entra login completed and Patient Search rendered";
    });
  } else if (authenticated) {
    const detail = "authenticated browser session was accepted";
    checks.results.push({
      name: "frontend authentication",
      status: "PASS",
      duration_ms: 0,
      detail,
    });
    console.log(`[PASS] frontend authentication: ${detail}`);
  } else if (config.requireAuthenticatedUi) {
    checks.fail(
      "frontend authentication",
      "login required; provide --storage-state or --interactive-login",
    );
  } else {
    checks.skip(
      "frontend authentication",
      "login page verified; provide auth state to exercise Patient Search",
    );
  }

  if (authenticated && config.saveStorageState) {
    await mkdir(dirname(config.saveStorageState), { recursive: true });
    await context.storageState({ path: config.saveStorageState });
    console.log(`Saved browser storage state to ${config.saveStorageState}`);
  }

  if (authenticated && config.patientId) {
    await checks.run("frontend patient search", async () => {
      const mrnInput = page.getByLabel("MRN", { exact: true });
      const searchButton = page.getByRole("button", { name: "Search", exact: true });
      await mrnInput.fill(config.patientId!);
      const responsePromise = page.waitForResponse(
        (response) =>
          response.request().method() === "GET" && response.url().includes("/api/patient/"),
        { timeout: config.timeoutMs },
      );
      await searchButton.click();
      const response = await responsePromise;
      expectCondition(
        response.status() === 200,
        `browser patient request returned ${response.status()}`,
      );
      await page
        .getByRole("button", { name: "Switch Patient", exact: true })
        .waitFor({ state: "visible" });
      return "MRN search loaded the patient view through the /api proxy";
    });
  } else if (!authenticated) {
    checks.skip("frontend patient search", "authenticated UI is unavailable");
  } else {
    checks.skip("frontend patient search", "no synthetic patient MRN was supplied");
  }

  if (browserLoaded) {
    await checks.run("frontend runtime", async () => {
      expectCondition(
        pageErrors.length === 0,
        `unhandled browser errors: ${pageErrors.slice(0, 3).join("; ")}`,
      );
      return "no unhandled page errors were observed";
    });
  } else {
    checks.skip("frontend runtime", "browser shell did not load");
  }

  if (config.captureScreenshots) {
    await page.screenshot({ path: join(runDirectory, "frontend-final.png"), fullPage: true });
  }
  if (config.captureTrace) {
    await context.tracing.stop({ path: join(runDirectory, "playwright-trace.zip") });
  }

  await context.close();
  await browser.close();
  await backendRequest.dispose();
  await frontendRequest.dispose();

  const report = {
    generated_at: new Date().toISOString(),
    configuration: {
      frontend_url: config.frontendUrl,
      backend_url: config.backendUrl,
      browser: config.browser,
      headed: config.headed,
      patient_id_configured: config.patientId !== undefined,
      access_token_configured: config.accessToken !== undefined,
      storage_state_configured: config.storageState !== undefined,
    },
    checks: checks.results,
    diagnostics: {
      page_errors: pageErrors.map((value) => checks.redact(value)),
      console_errors: consoleErrors.map((value) => checks.redact(value)),
      failed_requests: failedRequests.map((value) => checks.redact(value)),
    },
  };
  const reportPath = join(runDirectory, "integration-report.json");
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  const failures = checks.results.filter((result) => result.status === "FAIL").length;
  const passes = checks.results.filter((result) => result.status === "PASS").length;
  const skips = checks.results.filter((result) => result.status === "SKIP").length;
  console.log(`Result: ${passes} passed, ${failures} failed, ${skips} skipped`);
  console.log(`Report: ${reportPath}`);
  return failures > 0 ? 1 : 0;
}

async function main(): Promise<number> {
  try {
    const config = parseConfig();
    return config ? await run(config) : 0;
  } catch (error) {
    console.error(`ERROR: ${formatError(error)}`);
    return 2;
  }
}

process.exitCode = await main();