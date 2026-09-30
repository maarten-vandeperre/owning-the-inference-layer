# Getting Started with Qwen3-4B-GGUF on Podman AI

This guide shows how to run **Qwen3-4B-GGUF** locally with **Podman Desktop + Podman AI Lab**, expose it through an **OpenAI-compatible API**, and test it from the command line.

## 1. What you will run

We will use:

- **Model:** `Qwen3-4B-GGUF`
- **Recommended quantization:** `Q4_K_M`
- **Model file:** `Qwen3-4B-Q4_K_M.gguf`
- **Approximate download size:** 2.5 GB
- **Runtime:** Podman AI Lab / llama.cpp-based inference
- **API style:** OpenAI-compatible

Qwen3-4B is a 4-billion-parameter language model. The official GGUF release provides several quantizations, including `Q4_K_M`, `Q5_K_M`, `Q6_K`, and `Q8_0`.

For most laptops and developer workstations, **Q4_K_M is a good place to start** because it offers a useful balance between memory usage, speed, and output quality.

---

## 2. Prerequisites

You need:

1. **Podman Desktop**
2. A working **Podman machine**
3. **Podman AI Lab** extension
4. Around **4–6 GB of free RAM** available to the Podman machine for a comfortable start
5. Around **3 GB of free disk space** for the Q4 model, plus extra space for containers and runtime data

Podman Desktop documentation recommends a Podman machine with at least **6 GB memory** for its AI Lab tutorial.


### Environment used for this guide

This guide was tried on a Mac with the following Podman setup:

```text
Client:
  Podman Engine Version: 5.6.2
  API Version:           5.6.2
  Go Version:            go1.25.1
  Built:                 Tue Sep 30 16:50:46 2025
  Build Origin:          brew
  OS/Arch:               darwin/arm64

Server:
  Podman Engine Version: 5.6.2
  API Version:           5.6.2
  Go Version:            go1.24.7
  OS/Arch:               linux/arm64
```

The Podman machine configuration used was:

```text
NAME                     VM TYPE   CREATED       LAST UP             CPUS   MEMORY      DISK SIZE
podman-machine-default*  libkrun   9 months ago Currently running   5      20.95 GiB   100 GiB
```

In other words, this setup was validated with:

- **macOS on ARM64 / Apple Silicon**
- **Podman 5.6.2**
- **libkrun** as the Podman machine VM type
- **5 virtual CPUs**
- **20.95 GiB RAM assigned to the Podman machine**
- **100 GiB Podman machine disk**
- **Linux/ARM64** inside the Podman machine

This is comfortably sufficient for `Qwen3-4B-Q4_K_M.gguf`. You do **not** need to match these resources exactly; the values above are simply the environment on which the steps in this guide were tried.

You can check your own configuration with:

```bash
podman version
podman machine list
```

### Verify Podman

```bash
podman version
```

You should get client/server information.

You can also check your running Podman machine:

```bash
podman machine list
```

If no machine exists yet:

```bash
podman machine init
podman machine start
```

> On Linux, Podman can run natively and a Podman machine may not be required.

---

## 3. Install Podman AI Lab

Open **Podman Desktop**.

Go to:

```text
Extensions
  -> Catalog
  -> Podman AI Lab
  -> Install
```

After installation, an **AI Lab** section should appear in the left navigation.

Podman AI Lab provides:

- a model catalog
- local model import
- inference services
- playgrounds
- ready-made AI application recipes

---

## 4. Download Qwen3-4B-GGUF

The official Qwen GGUF repository is:

```text
https://huggingface.co/Qwen/Qwen3-4B-GGUF
```

For local development, download:

```text
Qwen3-4B-Q4_K_M.gguf
```

### Option A — download with curl

```bash
mkdir -p ~/models/qwen3
cd ~/models/qwen3

curl -L \
  -o Qwen3-4B-Q4_K_M.gguf \
  https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf
```

Check the file:

```bash
ls -lh Qwen3-4B-Q4_K_M.gguf
```

You should see a file of roughly **2.5 GB**.

### Option B — Hugging Face CLI

If you have the Hugging Face CLI installed:

```bash
hf download \
  Qwen/Qwen3-4B-GGUF \
  Qwen3-4B-Q4_K_M.gguf \
  --local-dir ~/models/qwen3
```

---

## 5. Import the GGUF into Podman AI Lab

Open Podman Desktop and go to:

```text
AI Lab
  -> Catalog
  -> Import
```

Select:

```text
~/models/qwen3/Qwen3-4B-Q4_K_M.gguf
```

Podman AI Lab supports importing local models in GGUF format.

After the import completes, the model should appear in your local model catalog.

---

## 6. Create a model service

Now create an inference endpoint.

Go to:

```text
AI Lab
  -> Services
  -> New Model Service
```

Select the imported Qwen model.

For example:

```text
Qwen3-4B-Q4_K_M
```

Choose a port. For this guide we will assume:

```text
8080
```

Then click:

```text
Create service
```

Podman AI Lab starts a containerized inference server and loads the GGUF model.

Once it is running, open the **service details** page.

Podman AI Lab displays:

- service status
- endpoint
- model information
- generated client examples

The exact host port can differ if you select another port in the UI.

---

## 7. Check the service

Assuming your model service is exposed on port `8080`, test whether the server responds.

```bash
curl http://localhost:8080/v1/models
```

You should receive JSON describing the available model.

If your Podman AI Lab service uses another port, replace `8080` with that port.

---

## 8. Send your first prompt

Podman AI Lab exposes an OpenAI-compatible chat API.

Try:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-4B-Q4_K_M",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful developer assistant."
      },
      {
        "role": "user",
        "content": "Explain containers in three short sentences."
      }
    ],
    "temperature": 0.6
  }'
```

### Important

The exact model identifier exposed by your service can differ.

Check it first with:

```bash
curl http://localhost:8080/v1/models
```

Then use the returned model ID in the request.

---

## 9. Pretty-print the response

If you have `jq` installed:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-4B-Q4_K_M",
    "messages": [
      {
        "role": "user",
        "content": "What are the advantages of Podman over running an LLM directly on my host?"
      }
    ]
  }' | jq
```

To print only the generated text:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-4B-Q4_K_M",
    "messages": [
      {
        "role": "user",
        "content": "Give me five useful Podman commands."
      }
    ]
  }' \
  | jq -r '.choices[0].message.content'
```

---

## 10. Use the Podman AI Lab Playground

You do not have to use `curl`.

Go to:

```text
AI Lab
  -> Playgrounds
  -> New Playground
```

Select:

1. the inference runtime
2. your Qwen3 model
3. the model service

Create the playground.

You can now interact with Qwen from the Podman Desktop UI.

The playground also lets you experiment with settings such as:

- system prompt
- temperature
- maximum generated tokens
- top-p
- other inference parameters exposed by the runtime

This is useful for finding good settings before integrating the model into an application.

---

## 11. Access Qwen from an application

Because the endpoint is OpenAI-compatible, many OpenAI-compatible SDKs and frameworks can use the local model simply by changing the base URL.

Conceptually:

```text
Application
    |
    | OpenAI-compatible REST API
    v
localhost:8080
    |
    v
Podman AI Lab model service
    |
    v
llama.cpp runtime
    |
    v
Qwen3-4B-Q4_K_M.gguf
```

Your application therefore does not need to know that Qwen is running as a GGUF file.

This is especially useful if you want to keep the application portable between:

- a local model
- OpenShift AI
- a Model-as-a-Service platform
- another OpenAI-compatible inference provider

---

## 12. Example with Python OpenAI SDK

Install the SDK:

```bash
pip install openai
```

Create `test-qwen.py`:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="Qwen3-4B-Q4_K_M",
    messages=[
        {
            "role": "system",
            "content": "You are a concise developer assistant."
        },
        {
            "role": "user",
            "content": "Explain Kubernetes operators."
        }
    ],
    temperature=0.6
)

print(response.choices[0].message.content)
```

Run:

```bash
python test-qwen.py
```

If the model ID is different, retrieve it with:

```bash
curl http://localhost:8080/v1/models
```

and update the Python code accordingly.

---

## 13. Example with environment variables

For application development, avoid hardcoding the endpoint.

```bash
export OPENAI_BASE_URL=http://localhost:8080/v1
export OPENAI_API_KEY=not-needed
export MODEL_NAME=Qwen3-4B-Q4_K_M
```

Your application can now treat the local Qwen instance similarly to another OpenAI-compatible provider.

---

## 14. Qwen3 thinking behavior

Qwen3 supports both **thinking** and **non-thinking** styles of interaction, depending on the inference stack and prompt/template being used.

For application development, keep in mind that:

- reasoning can increase response latency
- reasoning can increase generated token count
- short application responses often benefit from non-thinking behavior
- complex planning or reasoning tasks can benefit from thinking behavior

The exact controls depend on the chat template and inference runtime version used by Podman AI Lab.

If you are building an application that depends on a specific thinking mode, verify the generated prompt/template and model behavior in the Podman AI Lab playground before relying on it.

---

## 15. Choosing a quantization

The official Qwen repository provides several GGUF variants.

| Quantization | Approx. model size | Typical use |
|---|---:|---|
| Q4_K_M | ~2.5 GB | Recommended starting point |
| Q5_0 | ~2.8 GB | Slightly higher quality |
| Q5_K_M | ~2.9 GB | Higher-quality local usage |
| Q6_K | ~3.3 GB | More memory, better fidelity |
| Q8_0 | ~4.3 GB | High quality, higher RAM usage |

For a normal development laptop:

```text
Q4_K_M
```

is usually the most practical first choice.

The amount of actual memory required at runtime is higher than the GGUF file size because the runtime also needs memory for:

- KV cache
- context
- runtime buffers
- inference engine
- container overhead

---

## 16. Context size

Qwen3-4B has a native context length of **32,768 tokens**. Larger contexts are possible with YaRN according to the Qwen model documentation.

However, do not automatically configure the maximum context size on a laptop.

A larger context means a larger KV cache and therefore more memory usage.

For local development, start with something like:

```text
4096–8192 tokens
```

unless your workload specifically needs more.

Increase the context only after verifying memory consumption and performance.

---

## 17. GPU acceleration

CPU inference works for Qwen3-4B, but a supported GPU can make generation substantially faster.

Podman AI Lab can use GPU-enabled Podman environments where supported.

On macOS, current Podman AI Lab documentation can prompt you to create a **GPU-enabled Podman machine** when creating a model service.

GPU support depends on:

- operating system
- hardware
- Podman version
- Podman machine provider
- Podman AI Lab version

For the first test, Qwen3-4B `Q4_K_M` is small enough that CPU inference is also a reasonable way to validate the setup.

---

## 18. Inspect the running containers

Podman AI Lab ultimately runs the inference service as containers.

List them:

```bash
podman ps
```

Show all containers:

```bash
podman ps -a
```

Inspect a container:

```bash
podman inspect <container-name>
```

View logs:

```bash
podman logs <container-name>
```

Follow logs:

```bash
podman logs -f <container-name>
```

These commands are useful when the model service fails to start or the API does not respond.

---

## 19. Troubleshooting

### Model does not appear after import

Verify that you imported the actual `.gguf` file:

```bash
file ~/models/qwen3/Qwen3-4B-Q4_K_M.gguf
```

and check that the download completed:

```bash
ls -lh ~/models/qwen3/Qwen3-4B-Q4_K_M.gguf
```

---

### Service stops while loading

The most common cause is insufficient memory.

Inspect the Podman machine:

```bash
podman machine inspect
```

If necessary, recreate or resize your Podman machine with more memory.

Qwen3-4B Q4 is relatively small, but the runtime needs more memory than the 2.5 GB model file itself.

---

### `curl` cannot connect

Check the model service in Podman AI Lab and inspect:

```bash
podman ps
```

Then check the exposed ports:

```bash
podman port <container-name>
```

Make sure your `curl` request uses the host port shown by Podman AI Lab.

---

### Wrong model name

Do not assume the imported filename is always the API model ID.

Query:

```bash
curl http://localhost:8080/v1/models
```

Use the returned ID in:

```text
/v1/chat/completions
```

---

### Responses are slow

Try:

1. using `Q4_K_M`
2. reducing context size
3. reducing `max_tokens`
4. enabling GPU acceleration if supported
5. closing other memory-heavy applications

---

## 20. Minimal quickstart

If you already have Podman Desktop and Podman AI Lab, the complete workflow is essentially:

```bash
mkdir -p ~/models/qwen3

curl -L \
  -o ~/models/qwen3/Qwen3-4B-Q4_K_M.gguf \
  https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf
```

Then:

```text
Podman Desktop
 -> AI Lab
 -> Catalog
 -> Import
 -> Qwen3-4B-Q4_K_M.gguf
```

Then:

```text
AI Lab
 -> Services
 -> New Model Service
 -> select Qwen3
 -> Create service
```

Finally:

```bash
curl http://localhost:8080/v1/models
```

and:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-4B-Q4_K_M",
    "messages": [
      {
        "role": "user",
        "content": "Hello Qwen. Explain why running models locally can be useful."
      }
    ]
  }'
```

That gives you a fully local Qwen3 model running behind a containerized, OpenAI-compatible inference API.

---

## 21. Next steps

Once this works, useful next steps are:

- connect a **Quarkus + LangChain4j** application
- connect **OpenCode** or another OpenAI-compatible coding client
- package the client application with **Podman Compose**
- compare Qwen3-4B with Granite, Mistral, or larger Qwen models
- add an **AI Gateway** in front of the endpoint
- move the same application toward **OpenShift AI / Model-as-a-Service**
- test tool calling and agent workloads
- benchmark latency, tokens/second, context usage, and memory

---

## References

- Podman AI Lab documentation  
  https://podman-desktop.io/docs/ai-lab

- Installing Podman AI Lab  
  https://podman-desktop.io/docs/ai-lab/installing

- Starting an inference server  
  https://podman-desktop.io/docs/ai-lab/start-inference-server

- Creating a playground  
  https://podman-desktop.io/docs/ai-lab/create-playground

- Red Hat Developer — importing your own GGUF model into Podman AI Lab  
  https://developers.redhat.com/articles/2024/05/07/podman-ai-lab-getting-started

- Official Qwen3-4B-GGUF model  
  https://huggingface.co/Qwen/Qwen3-4B-GGUF
