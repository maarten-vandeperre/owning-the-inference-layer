# 02 · Podman AI Lab

Independent Java 25 / Quarkus / Gradle / React / Vite / Tailwind coffee demo.

## Provider setup

In Podman Desktop, install AI Lab, download an instruction-following model that fits your machine, and start a Model Service. Copy the model ID and full chat-completions path from its client example.

The coffee app now runs in a container. **Do not use `localhost` or `127.0.0.1` as the model host in the default Compose setup:** that would point back to the coffee container. Replace that host with `host.containers.internal`, retaining the actual published service port and full path. Port 8081 in `.env.example` is an example, not an AI Lab default. Keep `AI_HTTP_ALLOWED_HOSTS=host.containers.internal`. Leave the API key empty only if your local service has no authentication.

Podman provides `host.containers.internal` for host access. Actual reachability also depends on the model service's bind address and the host/VM network. Verify the published model port is reachable from the app container. On native Linux with a service bound only to host loopback, the alternative below shares host networking and keeps the app itself bound to loopback:

```bash
podman compose -f compose.host.yaml up --build -d
```

Set `AI_HOST_CHAT_URL` to the actual `http://127.0.0.1:PORT/.../chat/completions` URL in `.env`. This alternative is for native Linux; on macOS/Windows, host networking refers to the Podman VM and may not reach a host-only service. Use the normal container-reachable endpoint there. The alternative uses host port 8080 and does not use `APP_PORT`.

Compose starts the application, not AI Lab itself. Model weights and the AI Lab service remain managed by Podman Desktop. JSON mode defaults off for runtime compatibility; server validation remains enabled.

## Run with Podman Compose

Start Podman and configure a Compose provider. Duplicate `.env.example` as `.env` and fill in the provider values above. From this folder:

```bash
podman compose up --build -d
```

Open **http://localhost:8080**. The multi-stage build installs frontend dependencies, builds React, runs backend tests and packages the app. You do not need Java or Node on the host. Follow logs with `podman compose logs -f coffee`; stop with `podman compose down`. Use a different `APP_PORT` in each `.env` if running all versions simultaneously.

## Demo

Submit **“Two large oat lattes and a cappuccino, please.”** Review both lines and the **€14.00** total, then confirm the whole order. Try **“One latte and one decaf soy latte.”** and verify the variants remain separate. Try **“Coffee, please.”** for a clarification. Up to six cups are allowed across the whole order.

## Labelled mock rehearsal

```bash
podman compose -f compose.yaml -f compose.rehearsal.yaml up --build -d
```

This starts an app plus a fixture server, displays “Rehearsal mock (no model)” and needs no real model credential. A `.env` copy must still exist because the base Compose file references it. Stop with `podman compose -f compose.yaml -f compose.rehearsal.yaml down`.

## Verification

The Containerfile runs backend tests against a local mock during the build. The optional twelve-case model evaluation is `python3 ../tools/evaluate.py http://localhost:8080`; real providers consume quota. Review the complete order before confirming. This is a demo with in-memory state and no payments.

See `../README.md`, `../DEMO_GUIDE.md` and `../VALIDATION.md` for configuration, talk flow and test limits.
