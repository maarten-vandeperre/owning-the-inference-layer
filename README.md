# Devoxx Coffee Lab

One coffee-ordering application, three independent projects.

| Folder | Inference | Provider setup |
|---|---|---|
| `01` | OpenAI | API key and a chat-capable model |
| `02` | Podman AI Lab | A running local model service |
| `03` | OpenShift AI Models-as-a-Service | Published model, full completion URL and team credential |

Every version uses **Java 25, Quarkus, Gradle, React, Vite and Tailwind**. Each has its own Compose file, multi-stage Containerfile, tests and README. Application code is intentionally duplicated so each folder works independently. No real credentials or model weights are included.

## Start with Podman Compose

Install Podman / Podman Desktop and enable its Compose provider. On macOS or Windows, start the Podman machine. **No host Java, Gradle, Node or npm installation is needed.** The first build needs network access to download images and dependencies.

1. Open folder `01`, `02` or `03`.
2. Duplicate `.env.example` as `.env`, then enter that provider's endpoint, model and credential. For `02`, read its networking instructions first.
3. From that folder, run:

```bash
podman compose up --build -d
```

Open **http://localhost:8080**. Compose builds React, runs the backend tests, packages Quarkus and starts one container serving both the UI and API. It publishes the browser port on loopback. Subsequent launches reuse cached build layers. The tests in the image build use a local mock, not a paid model.

```bash
podman compose logs -f coffee
podman compose down
```

Stop one version before launching another on the same port, or give each folder a different `APP_PORT` in `.env` (for example 8080, 8082 and 8083). The stack also appears as a Compose group in Podman Desktop. Compose starts the coffee application; OpenAI, the AI Lab model service and OpenShift AI remain separate provider prerequisites.

## Order several drinks

Try **“Two large oat lattes and a cappuccino, please.”** The review should show:

| Drink | Quantity | Unit price | Line total |
|---|---:|---:|---:|
| Large oat latte | 2 | €5.10 | €10.20 |
| Regular dairy cappuccino | 1 | €3.80 | €3.80 |
| **Order total** | **3 cups** | | **€14.00** |

Different drinks, sizes, milks and decaf options can share one order, up to **six cups in total**. Identical variants are combined. Every line is visible before and after confirmation. Try “One latte and one decaf soy latte.” to see separate variants of the same drink.

The server calculates every price; model-supplied prices are ignored. One confirmation places the complete server-owned quote. A clarification or invalid item prevents a partial order from being confirmed. The model can still misunderstand natural language, so review every line. No payment is taken; restarting the app clears its in-memory quotes and orders.

## Application contract

`POST /api/interpret` accepts:

```json
{"text":"Two large oat lattes and a cappuccino, please."}
```

Quarkus sends the order text and a system prompt to the configured chat-completions endpoint. The expected model response is:

```json
{"items":[
  {"drink":"latte","size":"large","milk":"oat","quantity":2,"decaf":false},
  {"drink":"cappuccino","size":"regular","milk":"dairy","quantity":1,"decaf":false}
],"clarification":""}
```

The server returns `quote.items[]` with the validated fields plus `unitCents` and line `totalCents`. `quote.totalCents` is the sum of the lines. Ambiguity yields a clarification and no quote. This replaces the earlier single `quote.item` contract.

`POST /api/orders` accepts `{"quoteId":"..."}` and returns the same server-owned items and total, plus an order reference. Confirmation is idempotent while that confirmed quote remains in the bounded cache. Quotes expire after ten minutes. Each demo cache holds at most 200 entries. Large adds €0.70 per cup; oat/soy adds €0.40; decaf is free. Small and regular have the same base price; espresso is always small with no milk.

## Rehearse without provider credentials

After making a `.env` copy, use the explicitly labelled fixture configuration:

```bash
podman compose -f compose.yaml -f compose.rehearsal.yaml up --build -d
```

This starts both the app and a local mock-model container, with no manual Python server. The browser says **Rehearsal mock (no model)**. It has fixed responses for the documented examples; it is not real inference. Stop it with the same two files and `down`, then start normal `compose.yaml` for a live provider. There is no automatic fallback to fixtures or another provider.

## Acceptance evaluation

With a real provider or rehearsal configuration running, an optional host Python 3 command is:

```bash
python3 tools/evaluate.py http://localhost:8080
```

From within an app folder, use `../tools/evaluate.py`. This checks twelve synthetic requests, including mixed drinks, variants, six cups, unsupported items and ambiguity. It creates quotes, never orders. With real providers it consumes normal quota and may cost money. It is a smoke evaluation, not a benchmark.

## Configuration

| Variable | Meaning |
|---|---|
| `AI_CHAT_URL` | Full POST URL, including gateway prefixes and `/chat/completions` |
| `AI_MODEL` | Exact served model identifier |
| `AI_API_KEY` | Backend-only bearer credential; never prefix it with `VITE_` |
| `AI_JSON_MODE` | `true` sends JSON-object mode; `false` uses prompting plus validation |
| `AI_TIMEOUT_SECONDS` | Completion timeout, default 90 seconds |
| `AI_PROVIDER` | Provider label shown in the UI |
| `AI_HTTP_ALLOWED_HOSTS` | Comma-separated exact trusted local HTTP hosts; empty for remote providers |
| `APP_PORT` | Host browser port published by Compose, default 8080 |

Remote providers use HTTPS. Loopback HTTP is allowed; other HTTP hosts must be explicitly allowlisted for container networking. The `02` example uses `host.containers.internal`. Requests never follow redirects. Endpoint URLs cannot contain embedded credentials, query parameters or fragments. For private certificate authorities, add the CA to the JVM trust configuration; do not disable TLS verification.

`.env` is excluded from both Podman and Docker build contexts. Credentials enter only at runtime. The app has no production authentication, persistence or payment system and should remain a local conference demo.

## Optional source development

The original `scripts/dev.mjs`, `scripts/build.sh` and `scripts/run.sh` remain available for developers who want hot reload. They require JDK 25 and Node 22.12+ or 24 LTS on the host. For host execution of version `02`, use the AI Lab host URL (`127.0.0.1` and the actual service port), not the container hostname. Compose is the default run path.

See `DEMO_GUIDE.md`, `VALIDATION.md`, `SOURCES.md` and `TALK_MAP.md` for the live sequence, verification scope, references and slide map. The demos start at slides 11, 25 and 38.

Validation note: application builds and tests passed, but Podman itself was unavailable here, so the container launch still needs a local check. See `VALIDATION.md`.
