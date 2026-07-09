# Contributing

Thanks for helping improve Portraiture.

## Development

Install dependencies from the repository root:

```sh
npm install
```

Run every language suite:

```sh
npm run test:all
```

Run one suite:

```sh
npm run test:ts
npm run test:python
npm run test:csharp
npm run test:go
npm run test:elixir
npm run test:powershell
npm run test:rust
```

## API changes

Portraiture is intentionally small and cross-language. When changing behavior,
update each affected implementation or document why a language-specific omission
is acceptable.

Use `REQUIREMENTS.md` as the internal implementation contract.

## Pull requests

Before opening a pull request:

- keep scripts dependency-free from Portraiture itself
- add or update tests for the affected language
- update docs in `docs/` for user-facing behavior
- mention any language implementations that intentionally do not change
