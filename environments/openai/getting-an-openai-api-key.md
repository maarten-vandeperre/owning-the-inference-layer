# How to Get an OpenAI API Key

This guide explains how to create an **OpenAI API key**, configure API billing, store the key safely, and test that it works.

> **Important:** An OpenAI API key is different from a ChatGPT subscription. ChatGPT and the OpenAI API have separate billing systems.

---

## 1. Sign in to the OpenAI API Platform

Go to:

https://platform.openai.com/

Sign in with your OpenAI account.

If you do not yet have an account, create one first.

---

## 2. Choose or create a project

OpenAI API keys are associated with projects.

For a simple personal setup, you can normally use the existing **Default project**.

If you are working in an organization and want a separate project:

1. Open the project selector in the OpenAI API Platform.
2. Select **Create project**.
3. Give the project a meaningful name.
4. Open that project before creating the API key.

Projects are useful because usage, permissions, limits, and API keys can be managed independently.

---

## 3. Open the API Keys page

Go to the API keys section of the OpenAI Platform:

https://platform.openai.com/api-keys

Alternatively, from the OpenAI Platform:

```text
Settings
  -> Project
  -> API Keys
```

The exact position of the menu can change slightly as the OpenAI Platform UI evolves.

---

## 4. Create a new secret key

Click:

```text
+ Create new secret key
```

Give the key a descriptive name, for example:

```text
local-podman-demo
```

or:

```text
opencode-development
```

You can also choose permissions for the key.

OpenAI currently supports permissions such as:

- **All** — full API access available to the project
- **Restricted** — configure read/write/no-access permissions for individual API endpoints
- **Read Only** — read-only access where applicable

For experiments, the default permissions may be sufficient. For production applications, prefer the minimum permissions required by the application.

Click **Create secret key**.

---

## 5. Copy the key immediately

The secret key will be shown after creation.

It will look similar to:

```text
sk-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Copy it immediately and store it somewhere secure.

> OpenAI does not show the complete secret key again later. If you lose it, create a new key and revoke the old one.

Never put your real API key:

- in documentation
- in screenshots
- in Git repositories
- directly in source code
- in public shell scripts
- in Dockerfiles or Containerfiles
- in chat messages

---

## 6. Configure API billing

A ChatGPT Plus, Pro, Business, or other ChatGPT subscription does **not** automatically include OpenAI API usage.

API billing is managed separately.

Open the API billing section in the OpenAI Platform and add a payment method if required.

Depending on your account, API usage can be handled through prepaid credits or automatic card charges.

For development, it is also a good idea to configure budgets or usage limits for the project.

---

## 7. Store the API key in an environment variable

On macOS or Linux:

```bash
export OPENAI_API_KEY="sk-proj-your-key-here"
```

Verify that the variable exists without printing the actual key:

```bash
if [ -n "$OPENAI_API_KEY" ]; then
  echo "OPENAI_API_KEY is configured"
else
  echo "OPENAI_API_KEY is missing"
fi
```

Avoid this:

```bash
echo $OPENAI_API_KEY
```

because it prints the secret into your terminal history or screen output.

---

## 8. Using a `.env` file

For local development, you can use a `.env` file.

Create:

```text
.env
```

with:

```bash
OPENAI_API_KEY=sk-proj-your-key-here
```

Make sure `.env` is ignored by Git.

Add this to `.gitignore`:

```gitignore
.env
.env.*
```

Do not commit API keys to GitHub.

A typical project can look like:

```text
my-project/
├── .env
├── .gitignore
├── README.md
└── src/
```

---

## 9. Test the API key with `curl`

You can test the key from your terminal.

For example:

```bash
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

If authentication succeeds, OpenAI returns JSON describing models available to your project/account.

If the key is invalid, you will receive an authentication error.

---

## 10. Test with the OpenAI Responses API

A simple request can look like:

```bash
curl https://api.openai.com/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "gpt-5-mini",
    "input": "Explain containers in three short sentences."
  }'
```

Model availability can vary by account and project, so use a model available to your API project.

---

## 11. Use the key from Python

Install the OpenAI SDK:

```bash
pip install openai
```

Create:

```text
test-openai.py
```

with:

```python
from openai import OpenAI

client = OpenAI()

response = client.responses.create(
    model="gpt-5-mini",
    input="Explain Kubernetes in three sentences."
)

print(response.output_text)
```

Because the SDK automatically reads:

```text
OPENAI_API_KEY
```

from your environment, there is no need to put the secret directly in your Python source code.

Run:

```bash
python test-openai.py
```

---

## 12. Using the API key with Podman

If an application running in a container needs the API key, pass it as an environment variable rather than building it into the image.

For example:

```bash
podman run \
  --rm \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  my-ai-application
```

With Podman Compose:

```yaml
services:
  app:
    image: my-ai-application
    environment:
      OPENAI_API_KEY: ${OPENAI_API_KEY}
```

Your `.env` file can then contain:

```bash
OPENAI_API_KEY=sk-proj-your-key-here
```

Again, keep `.env` out of Git.

---

## 13. Recommended setup for development

For a local AI or agentic-development project, a practical setup is:

```text
OpenAI Platform
       |
       | create project API key
       v
OPENAI_API_KEY
       |
       v
.env
       |
       v
Podman Compose / application
       |
       v
OpenAI API
```

For example:

```text
project/
├── .env
├── .gitignore
├── compose.yaml
├── README.md
└── app/
```

`.env`:

```bash
OPENAI_API_KEY=sk-proj-your-key-here
```

`.gitignore`:

```gitignore
.env
.env.*
```

`compose.yaml`:

```yaml
services:
  app:
    build: .
    environment:
      OPENAI_API_KEY: ${OPENAI_API_KEY}
```

---

## 14. Security recommendations

Treat an OpenAI API key like a password.

Recommended practices:

- create separate keys for separate applications
- prefer project-specific keys
- use restricted permissions when possible
- never commit keys to Git
- never include keys in container images
- use environment variables or a secret manager
- revoke keys that are no longer needed
- rotate a key immediately if you think it was exposed
- configure project budgets and usage controls
- use service accounts for non-human production workloads where appropriate

For production environments such as Kubernetes or OpenShift, store the key in a Secret rather than in application configuration.

For example:

```bash
oc create secret generic openai-api-key \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"
```

The application can then consume the Secret as an environment variable.

---

## 15. Common mistake: ChatGPT subscription vs API access

These are separate products:

```text
ChatGPT subscription
        ≠
OpenAI API billing
```

Having ChatGPT Plus or Pro does not mean that OpenAI API calls are included in that subscription.

You must configure billing for the API Platform separately if your API account requires paid usage.

---

## 16. Quick version

1. Go to `https://platform.openai.com/`
2. Sign in.
3. Select the project you want to use.
4. Open **API Keys**.
5. Click **Create new secret key**.
6. Copy the key.
7. Store it in an environment variable:

```bash
export OPENAI_API_KEY="sk-proj-your-key-here"
```

8. Configure API billing if required.
9. Test it:

```bash
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

You are now ready to use the OpenAI API.

---

## References

- OpenAI API Platform  
  https://platform.openai.com/

- API Keys  
  https://platform.openai.com/api-keys

- OpenAI API documentation  
  https://platform.openai.com/docs/

- Managing projects in the API Platform  
  https://help.openai.com/en/articles/9186755-managing-projects-in-the-api-platform

- Managing ChatGPT and API Platform billing  
  https://help.openai.com/en/articles/9039756-managing-billing-settings-on-the-chatgpt-web-and-api-platform
