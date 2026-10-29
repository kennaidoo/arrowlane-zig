# Agent guide

Read CONTRIBUTING.md before changing code.

## Commands

- Dependencies: `bash tools/fetch-zstd.sh`
- Test: `zig build test`
- Fuzz: `zig build fuzz`
- Format: `zig fmt --check --exclude src/vendor .`
- Release build: `zig build -Doptimize=ReleaseSafe`
- Full gate: `bash scripts/gate.sh`

## Boundaries

- Do not create an issue or pull request unless the human asks.
- Do not change a lane id.
- Do not commit `vendor/`, `zig-out/` or `.zig-cache/`.
- Do not run benchmarks in CI.
- Keep changes focused. Report changed files, checks run and open risks.

## References

- `docs/ai/quickstart.md` and `docs/ai/api.md` for the public contract.
- `docs/ai/manifest.json` for the static manifest.
- `llms.txt` for the short retrieval entry point.
