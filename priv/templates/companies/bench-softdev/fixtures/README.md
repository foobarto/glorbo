# bench-softdev fixtures

Everything under `repo/` is the frozen codebase the engineer +
reviewer work on. Do **not** mutate files here — mutations go in
the scaffolded company's workspace, not back into this template
tree.

The fixture SHA (hash of sorted file hashes) is recorded in every
bench-run manifest so reruns can self-verify.

## Layout

```
repo/
├── mix.exs
├── lib/
│   ├── auth.ex              (bugs-1 target)
│   ├── theme_controller.ex  (bugs-2 target)
│   └── comment_renderer.ex  (bugs-3 target)
└── test/
    ├── auth_test.exs
    ├── theme_controller_test.exs
    └── comment_renderer_test.exs
```
