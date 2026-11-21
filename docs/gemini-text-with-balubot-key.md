# Gemini 4 text + web search with the BaluBot Google key

How another project can use the same Google Cloud key as BaluBot for text work (no voice) with **Gemini 4 Hydrogen** and **Gemini 4 Argon**, including Google web search. Tested 2026-11-21 from this PC: both models answered 200, and a search question returned 2 web sources.

## 1. What the "key" is

BaluBot has no Gemini API key string. It signs in to Google Cloud (Vertex AI, now called "Gemini Enterprise Agent Platform") with a **service-account JSON file**:

- PC: `aws-setup-and-migrations/private-data/bridge-restore/gcp-sa.json`
- Apps-Core-VM: `/etc/bridge/gcp-sa.json`

The project ID is inside that file (`project_id`). Copy the file into the new project's own `private-data/` (gitignored). Never commit it and never put it in a frontend or a phone app; only a server should hold it.

Usage and cost land on the same Google Cloud project and bill as BaluBot. If you later want to see or stop each app's spend on its own, create a second service account in that project with the role **Vertex AI User** and give the new app that one instead.

## 2. Rules that matter

| Setting | Value |
|---|---|
| Location | **`global`** (endpoint `https://aiplatform.googleapis.com`). `us-central1`, which BaluBot uses for voice, answers **404** for Gemini 4. `us` / `eu` also work |
| Model IDs | `gemini-4-hydrogen` (fast, cheaper; the default choice) · `gemini-4-argon` (deeper reasoning, long hard tasks) |
| Thinking | `thinkingLevel`: Hydrogen `LOW` / `MEDIUM` / `HIGH` (default) / `XHIGH`; Argon `LOW` / `MEDIUM` (default) / `HIGH`. `MINIMAL` or `thinkingBudget` returns **400** |
| Temperature, top_p, top_k | ignored by both models |
| Web search | add the tool `{"googleSearch": {}}`; the answer comes with `groundingMetadata` (search queries and source links) |
| Other tools | function calling, structured (JSON) output, URL context, code execution, PDF / image / audio input |

## 3. Price (Google list price, USD per 1M tokens, global endpoint)

| Model | Input | Output |
|---|---|---|
| Hydrogen | $1.50 | $7.50 |
| Argon | $2.00 until 2026-11-30 (promo), then **$4.00** | $10.00 until 2026-11-30, then **$20.00** |

Web search: 5,000 search queries a month free, **shared by every app on this Google project** (BaluBot included). After that, $14 per 1,000 queries, billed only when the answer has web sources. One question can make several queries (the test made 2).

## 4. Example (Python, the tested call)

`pip install google-auth requests`

```python
import json, requests, google.auth.transport.requests
from google.oauth2 import service_account

SA = "private-data/gcp-sa.json"                      # path in the new project
creds = service_account.Credentials.from_service_account_file(
    SA, scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())  # token lasts ~1 h; refresh again when expired
project = json.load(open(SA))["project_id"]

def ask(prompt, model="gemini-4-hydrogen", search=False, level="LOW"):
    url = (f"https://aiplatform.googleapis.com/v1/projects/{project}"
           f"/locations/global/publishers/google/models/{model}:generateContent")
    body = {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"thinkingConfig": {"thinkingLevel": level}}}
    if search:
        body["tools"] = [{"googleSearch": {}}]
    r = requests.post(url, json=body, timeout=120,
                      headers={"Authorization": f"Bearer {creds.token}"})
    r.raise_for_status()
    c = r.json()["candidates"][0]
    text = "".join(p.get("text", "") for p in c["content"]["parts"])
    sources = [g["web"]["uri"] for g in c.get("groundingMetadata", {}).get("groundingChunks", []) if "web" in g]
    return text, sources

print(ask("Summarise this in 3 lines: ..."))
print(ask("Latest RBI repo rate?", search=True))
print(ask("Review this contract clause: ...", model="gemini-4-argon", level="MEDIUM"))
```

Other ways, same settings (location `global`, same JSON file):

- **Google Gen AI SDK** (Python `google-genai`, Node `@google/genai`, Go `google.golang.org/genai`): set `GOOGLE_APPLICATION_CREDENTIALS=<path to json>` and create the client with `vertexai=True, project=<project_id>, location="global"`.
- **Go without an SDK**: copy BaluBot's pattern, `backend/app/jobs/summarize_conversation.go` in `projects/products/custom-android-os` (token source from the JSON + `generateContent` on `global`, model `gemini-4-argon`).
- **OpenAI-style clients**: the platform also has an OpenAI-compatible Chat Completions endpoint (see the model pages below).

## Sources

- [Gemini 4 Hydrogen model page](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-hydrogen) and [Gemini 4 Argon model page](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-argon) (IDs, locations, thinking levels, tools)
- [Agent Platform pricing](https://cloud.google.com/vertex-ai/generative-ai/pricing) (token and grounding prices, checked 2026-11-21)
- [Google blog: Introducing Gemini 4 Hydrogen](https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-hydrogen/)

Content from these pages was rephrased for compliance with licensing restrictions.
