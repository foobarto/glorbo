# bench-softdev fixture: Go repo

Minimal Go package mirroring the Elixir fixture's three-bug
shape. Agents fix one bug per task; do NOT mutate these files —
the canonical copy lives under `priv/templates/` and reruns must
see the same starting state.

## Layout

```
go.mod
auth.go              (bugs-go-1 target)
theme_controller.go  (bugs-go-2 target)
comment_renderer.go  (bugs-go-3 target)
auth_test.go
theme_controller_test.go
comment_renderer_test.go
```
