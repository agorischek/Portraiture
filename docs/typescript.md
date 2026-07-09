# TypeScript

```ts
import { capture, portraitist, Portraitist } from "portraiture";
```

## Command capture

```ts
const result = await portraitist.captureCommand("uname -a");

if (!result.ok) {
  throw new Error(result.error.message);
}

console.log(result.value);
```

The `capture` convenience object is available for the default instance:

```ts
const result = await capture.command("uname -a");
```

## Process capture

Use `captureProcess` when you want literal arguments without shell
interpretation:

```ts
const result = await portraitist.captureProcess("rg", ["TODO", "."]);
```

## Script capture

```ts
const result = await portraitist.captureScript("./scripts/collect-host", [
  "--json",
]);
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```ts
await portraitist.captureScript("./scripts/collect-host.ps1", ["--json"], {
  interpreter: {
    command: "pwsh",
    args: ["-NoProfile", "-NonInteractive", "-File"],
  },
});
```

Default interpreters can be configured on a `Portraitist`:

```ts
const portraitist = new Portraitist({
  interpreters: {
    ".ps1": {
      command: "pwsh",
      args: ["-NoProfile", "-NonInteractive", "-File"],
    },
    ".py": "python3",
  },
});
```

## Defaults

```ts
const portraitist = new Portraitist({
  cwd: "/workspace/project",
  timeoutMs: 5_000,
  stderr: "fail",
});

await portraitist.captureCommand("git status --short", {
  cwd: "/workspace/other",
});
```

Per-call options override constructor defaults.

## Parsers

Parser functions receive the selected captured text and the full capture
context. Parsers read stdout by default.

```ts
type HostPortrait = {
  hostname: string;
  platform: string;
};

const result = await portraitist.captureScript("./scripts/collect-host-json", {
  parser: (text): HostPortrait => JSON.parse(text),
});

if (result.ok) {
  console.log(result.value.hostname);
}
```

Select parser input explicitly when needed:

```ts
await portraitist.captureCommand("tool --diagnostics", {
  parseInput: "stderr",
  parser: (text) => text.split("\n"),
});
```

TypeScript also accepts Standard Schema V1 compatible schemas as parsers.
