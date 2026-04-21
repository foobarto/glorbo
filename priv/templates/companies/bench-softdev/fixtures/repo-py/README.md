# bench-softdev fixture: Python repo

Minimal Python package mirroring the Elixir fixture's three-bug
shape. Agents fix one bug per task; do NOT mutate these files —
the canonical copy lives under `priv/templates/` and reruns must
see the same starting state.

## Layout

```
src/
├── auth.py              (bugs-py-1 target)
├── theme_controller.py  (bugs-py-2 target)
└── comment_renderer.py  (bugs-py-3 target)
tests/
├── test_auth.py
├── test_theme_controller.py
└── test_comment_renderer.py
pyproject.toml
```
