# 01 · OpenAI

Independent Java 25 / Quarkus / Gradle / React / Vite / Tailwind coffee demo.

## Provider setup

Put your OpenAI API key in `AI_API_KEY`. Keep the full OpenAI chat-completions URL and select a chat-capable `AI_MODEL` you can access. The key stays in the backend. `AI_JSON_MODE=true` requests JSON-object output. Normal API charges apply.

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
