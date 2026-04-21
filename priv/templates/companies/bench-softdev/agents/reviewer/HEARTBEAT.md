---
kind: agent-heartbeat/v1
---
# HEARTBEAT — reviewer

On wake:

1. Check your inbox for review-request messages.
2. If the engineer has filed a diff, read the diff + the original
   task body + the relevant fixture files, then produce your
   review per the reply format in `AGENT.md`.
3. No pending reviews → exit cleanly.
