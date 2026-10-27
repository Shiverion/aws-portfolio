# AI Portfolio Assistant

A React and Vite portfolio site backed by a Python API that answers questions using Amazon Bedrock. Terraform defines the static site and API deployment.

## System Design

### Requirements

**Functional**
- Serve the portfolio interface and answer questions using portfolio context.
- Preserve conversation history by session identifier.

**Non-functional**
- Use the AWS SDK and the deployment role or local AWS credentials for Bedrock and S3 access.
- Store conversation memory in local JSON files by default, with S3 available when `USE_S3` is enabled.

### High-level architecture

```text
Browser
  └─ React/Vite static site (CloudFront and S3)
       └─ POST /api/chat/portfolio
            └─ API Gateway → Lambda adapter → FastAPI
                 ├─ Amazon Bedrock
                 └─ Conversation history: local JSON or S3
```

The backend loads portfolio prompt context from files under `backend/data/`. Terraform declares the static frontend, API Gateway, Lambda, and optional domain resources.

### API and data

| Interface | Purpose |
| --- | --- |
| `POST /api/chat/portfolio` | Accept a message and optional session ID; return an assistant response and session ID. |
| Conversation JSON | Store message roles, content, and timestamps under a session ID. |

### Scale and reliability

Bedrock generation is synchronous. The prompt includes at most the last 20 stored messages. Local file memory suits development; S3 provides shared storage for deployment.

### Trade-offs

| Decision | Benefit | Cost |
| --- | --- | --- |
| Keep conversation context in JSON | Simple and inspectable history. | Context can grow; local files do not coordinate across instances. |
| Use Bedrock Converse | Model calls stay within AWS. | Availability and latency depend on the selected AWS region and account. |

### What to revisit

- Add per-session ownership and retention controls for conversation history.
- Add bounded retries and clearer handling for throttling and provider timeouts.
- Narrow Terraform role permissions to the actions the Lambda uses.

## Local Development

Configure AWS credentials and `VITE_API_URL` before starting the services.

Start the backend:

```bash
cd backend
uv sync
uv run uvicorn server:app --reload --port 8000
```

In a second terminal, start the frontend:

```bash
cd frontend
npm install
npm run dev
```

Set `VITE_API_URL=http://localhost:8000` in the frontend environment. The backend also reads `DEFAULT_AWS_REGION`; S3 memory requires `USE_S3=true` and `S3_BUCKET`.
