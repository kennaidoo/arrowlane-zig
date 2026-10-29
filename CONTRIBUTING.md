# Contributing

This repository is the Zig implementation of arrowlane. The Python and Rust
implementations live in separate repositories.

## Before you start

- Open an issue for behaviour changes, new lanes, or wire-format changes.
- Keep a change small and focused. One concern per pull request.
- Do not change a lane id. Add a new id instead.
- Do not use `[*c]` outside `src/vendor/`.
- Do not publish a performance claim without a reproducible measurement.

## Local checks

```bash
bash tools/fetch-zstd.sh
zig build test
bash scripts/gate.sh
zig build -Doptimize=ReleaseSafe
```

A change is complete only when `bash scripts/gate.sh` passes.

## Documentation

Update the page that describes the behaviour you changed. Keep `docs/ai/` and
`llms.txt` accurate for agents.

## Commit messages

Use `type(scope): description`, for example:

```text
fix(frame): reject a truncated payload before allocation
```

## Security

Do not report a vulnerability in a public issue. Follow `SECURITY.md`.
