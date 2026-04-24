---
kind: path-request/v1
task_id: deploy-01
paths:
  - mode: read
    path: /etc/myapp/config.yaml
  - mode: write
    path: /var/log/myapp/deploy.log
reason: Deploying the new release needs to read the app config and append a deploy line to the log.
---
