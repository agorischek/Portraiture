# Contributing

Thanks for helping improve Portraiture.

## Issues first for external contributions

Portraiture uses detailed issues as the primary path for external contribution
discussion. Please open an issue for bugs, feature requests, API proposals, and
new language implementation ideas before sending code.

A good issue includes:

- the affected language implementation
- the smallest reproduction or concrete API sketch
- expected behavior
- actual behavior or motivation
- any compatibility concerns

Maintainers use issues to discuss scope and then make repository changes through
the maintainer workflow. Unsolicited pull requests may be closed if they are not
linked to a maintainer-accepted issue or maintainer-owned work.

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

Pull requests are still used for maintainer workflow, trusted automation, and
work that maintainers have explicitly requested. PRs should link to the relevant
issue and pass the full language test matrix before merge.
