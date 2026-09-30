# Validate the MaaS installation / model serving

```shell
export YOUR_API_KEY="<your api key>"
export MODEL_ID="publishers/maas-models/models/qwen3-0-6b"
```

```shell
curl -sS -i \
  "https://maas.apps.ocp.vsw4v.sandbox782.opentlc.com/v1/models" \
  -H "Authorization: Bearer $YOUR_API_KEY"
```

```shell
curl -sS \
  "https://maas.apps.ocp.vsw4v.sandbox782.opentlc.com/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $YOUR_API_KEY" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": \"Explain OpenShift in one paragraph.\"
      }
    ],
    \"temperature\": 0.7,
    \"max_tokens\": 500
  }"
```

```shell
curl -sS \
  "https://maas.apps.ocp.vsw4v.sandbox782.opentlc.com/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $YOUR_API_KEY" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": \"Explain OpenShift in one paragraph.\"
      }
    ],
    \"temperature\": 0.7,
    \"max_tokens\": 500
  }" \
  | jq -r '.choices[0].message.content'
```