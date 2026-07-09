import assert from "node:assert/strict";
import { chmod, mkdtemp, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  Portraitist,
  capture,
  captureCommand,
  captureProcess,
  captureScript,
  portraitist,
} from "../dist/index.js";

const node = process.execPath;

test("portraitist.captureCommand captures stdout as the default value", async () => {
  const result = await portraitist.captureCommand("printf hello");

  assert.equal(result.ok, true);
  assert.equal(result.value, "hello");
  assert.equal(result.stdout, "hello");
  assert.equal(result.stderr, "");
  assert.equal(result.output, "hello");
  assert.equal(result.exitCode, 0);
  assert.equal(result.target.kind, "command");
});

test("capture.command delegates to the default portraitist", async () => {
  const result = await capture.command("printf facade");

  assert.equal(result.ok, true);
  assert.equal(result.value, "facade");
});

test("captureCommand helper delegates to the default portraitist", async () => {
  const result = await captureCommand("printf helper");

  assert.equal(result.ok, true);
  assert.equal(result.value, "helper");
});

test("captureProcess passes literal args without shell interpretation", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "console.log(process.argv[1])",
    "hello; echo nope",
  ]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "hello; echo nope\n");
  assert.equal(result.target.kind, "process");
});

test("capture.process delegates to captureProcess", async () => {
  const result = await capture.process(node, ["-e", "process.stdout.write('facade')"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "facade");
});

test("captureProcess helper delegates to the default portraitist", async () => {
  const result = await captureProcess(node, ["-e", "process.stdout.write('helper')"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "helper");
});

test("captureScript runs a path with args and parses stdout by default", async () => {
  const result = await portraitist.captureScript(node, [
    "-e",
    "console.error('warn'); console.log(JSON.stringify({ hostname: 'local' }))",
  ], {
    parser: JSON.parse,
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.value, { hostname: "local" });
  assert.equal(result.stderr, "warn\n");
  assert.equal(result.target.kind, "script");
});

test("captureScript supports an explicit interpreter", async () => {
  const script = await temporaryScript(
    "explicit.portraiture-js",
    "process.stdout.write(process.argv[2]);",
  );

  const result = await portraitist.captureScript(script, ["via-interpreter"], {
    interpreter: { command: node, args: ["--no-warnings"] },
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "via-interpreter");
  assert.equal(result.target.command, node);
  assert.equal(result.target.script, script);
  assert.deepEqual(result.target.interpreter, { command: node, args: ["--no-warnings"] });
});

test("Portraitist can use default interpreters by extension", async () => {
  const script = await temporaryScript(
    "default.portraiture-js",
    "process.stdout.write(process.argv[2]);",
  );
  const custom = new Portraitist({
    interpreters: {
      "portraiture-js": node,
    },
  });

  const result = await custom.captureScript(script, ["from-default"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "from-default");
  assert.equal(result.target.command, node);
  assert.equal(result.target.script, script);
});

test("capture.script delegates to captureScript", async () => {
  const result = await capture.script(node, ["-e", "process.stdout.write('facade')"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "facade");
});

test("captureScript helper delegates to the default portraitist", async () => {
  const result = await captureScript(node, ["-e", "process.stdout.write('helper')"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "helper");
});

test("parseInput can parse combined output", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdout.write(JSON.stringify({ ok: true }))",
  ], {
    parser: JSON.parse,
    parseInput: "combined",
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.value, { ok: true });
});

test("parser errors return parse failures", async () => {
  const result = await portraitist.captureProcess(node, ["-e", "process.stdout.write('not-json')"], {
    parser: JSON.parse,
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "parse");
  assert.equal(result.stdout, "not-json");
});

test("standard schema parsers validate JSON-decoded stdout", async () => {
  const schema = standardSchema((value) => {
    if (
      typeof value === "object" &&
      value !== null &&
      "hostname" in value &&
      typeof value.hostname === "string"
    ) {
      return { value: { hostname: value.hostname } };
    }

    return { issues: [{ message: "Expected hostname", path: ["hostname"] }] };
  });

  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdout.write(JSON.stringify({ hostname: 'local' }))",
  ], {
    parser: schema,
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.value, { hostname: "local" });
});

test("standard schema parsers can validate raw text when output is not JSON", async () => {
  const schema = standardSchema((value) => {
    if (value === "plain text") {
      return { value };
    }

    return { issues: [{ message: "Expected plain text" }] };
  });

  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdout.write('plain text')",
  ], {
    parser: schema,
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "plain text");
});

test("standard schema validation issues return parse failures", async () => {
  const schema = standardSchema(() => ({
    issues: [{ message: "Expected hostname", path: ["hostname"] }],
  }));

  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdout.write(JSON.stringify({ name: 'local' }))",
  ], {
    parser: schema,
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "parse");
  assert.match(result.error.message, /hostname: Expected hostname/);
});

test("stderr can be promoted to failure", async () => {
  const result = await portraitist.captureProcess(node, ["-e", "console.error('warn')"], {
    stderr: "fail",
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "stderr");
  assert.equal(result.stderr, "warn\n");
});

test("nonzero exits fail by default and keep captured output", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "console.log('before'); console.error('bad'); process.exit(7)",
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "exit");
  assert.equal(result.exitCode, 7);
  assert.equal(result.stdout, "before\n");
  assert.equal(result.stderr, "bad\n");
});

test("nonzero exits can be collected as successful data", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdout.write('data'); process.exit(7)",
  ], {
    failOnNonZeroExit: false,
  });

  assert.equal(result.ok, true);
  assert.equal(result.exitCode, 7);
  assert.equal(result.value, "data");
});

test("timeouts fail with timeout kind", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "setTimeout(() => {}, 5000)",
  ], {
    timeoutMs: 50,
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "timeout");
});

test("spawn errors fail with spawn kind", async () => {
  const result = await portraitist.captureProcess("__portraiture_missing_executable__");

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "spawn");
});

test("stdin is sent to the process", async () => {
  const result = await portraitist.captureProcess(node, [
    "-e",
    "process.stdin.pipe(process.stdout)",
  ], {
    stdin: "hello stdin",
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "hello stdin");
});

test("logger receives lifecycle and stream events", async () => {
  const events = [];
  const result = await portraitist.captureProcess(node, [
    "-e",
    "console.log('out'); console.error('err')",
  ], {
    logger(event) {
      events.push(event.type);
    },
  });

  assert.equal(result.ok, true);
  assert.equal(events[0], "start");
  assert.equal(events.at(-1), "finish");
  assert.equal(events.includes("stdout"), true);
  assert.equal(events.includes("stderr"), true);
});

test("logger exceptions do not change the capture result", async () => {
  const result = await portraitist.captureProcess(node, ["-e", "process.stdout.write('ok')"], {
    logger() {
      throw new Error("logger failed");
    },
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "ok");
});

test("Portraitist defaults apply and call options can override them", async () => {
  const strict = new Portraitist({ stderr: "fail" });
  const strictResult = await strict.captureProcess(node, ["-e", "console.error('warn')"]);
  const overrideResult = await strict.captureProcess(node, ["-e", "console.error('warn')"], {
    stderr: "capture",
  });

  assert.equal(strictResult.ok, false);
  assert.equal(strictResult.error.kind, "stderr");
  assert.equal(overrideResult.ok, true);
  assert.equal(overrideResult.stderr, "warn\n");
});

test("Portraitist can set a default working directory", async () => {
  const directory = await realpath(await mkdtemp(join(tmpdir(), "portraiture-cwd-")));
  const portraitistWithCwd = new Portraitist({ cwd: directory });

  const result = await portraitistWithCwd.captureProcess(node, [
    "-e",
    "process.stdout.write(process.cwd())",
  ]);

  assert.equal(result.ok, true);
  assert.equal(result.value, directory);
});

test("per-call cwd overrides the Portraitist default working directory", async () => {
  const defaultDirectory = await realpath(await mkdtemp(join(tmpdir(), "portraiture-cwd-default-")));
  const overrideDirectory = await realpath(await mkdtemp(join(tmpdir(), "portraiture-cwd-override-")));
  const portraitistWithCwd = new Portraitist({ cwd: defaultDirectory });

  const result = await portraitistWithCwd.captureProcess(node, [
    "-e",
    "process.stdout.write(process.cwd())",
  ], {
    cwd: overrideDirectory,
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, overrideDirectory);
});

test("without a parser the value is the combined output string", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('out'); process.stderr.write('err')",
  ]);

  assert.equal(result.ok, true);
  assert.equal(result.value, result.output);
  assert.equal([...result.value].sort().join(""), "eorrtu");
});

test("per-call env augments the parent environment", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write(`${process.env.PATH !== undefined}|${process.env.PORTRAITURE_TEST_VAR}`)",
  ], {
    env: { PORTRAITURE_TEST_VAR: "augmented" },
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "true|augmented");
});

test("constructor default env applies and per-call env overrides it per key", async () => {
  const artist = new Portraitist({
    env: { PORTRAITURE_A: "a-default", PORTRAITURE_B: "b-default" },
  });

  const result = await artist.captureProcess(node, [
    "-e",
    "process.stdout.write([process.env.PORTRAITURE_A, process.env.PORTRAITURE_B, process.env.PORTRAITURE_C, String(process.env.PATH !== undefined)].join('|'))",
  ], {
    env: { PORTRAITURE_B: "b-call", PORTRAITURE_C: "c-call" },
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "a-default|b-call|c-call|true");
});

test("constructor default timeoutMs applies and per-call timeoutMs overrides it", async () => {
  const artist = new Portraitist({ timeoutMs: 100, killGraceMs: 200 });

  const timedOut = await artist.captureProcess(node, ["-e", "setTimeout(() => {}, 5000)"]);
  const overridden = await artist.captureProcess(node, [
    "-e",
    "process.stdout.write('quick')",
  ], {
    timeoutMs: 10000,
  });

  assert.equal(timedOut.ok, false);
  assert.equal(timedOut.error.kind, "timeout");
  assert.equal(overridden.ok, true);
  assert.equal(overridden.value, "quick");
});

test("constructor default failOnNonZeroExit applies and per-call overrides it", async () => {
  const artist = new Portraitist({ failOnNonZeroExit: false });
  const program = ["-e", "process.stdout.write('data'); process.exit(7)"];

  const collected = await artist.captureProcess(node, program);
  const failed = await artist.captureProcess(node, program, { failOnNonZeroExit: true });

  assert.equal(collected.ok, true);
  assert.equal(collected.exitCode, 7);
  assert.equal(failed.ok, false);
  assert.equal(failed.error.kind, "exit");
});

test("constructor default stdin applies and per-call stdin overrides it", async () => {
  const artist = new Portraitist({ stdin: "default stdin" });
  const program = ["-e", "process.stdin.pipe(process.stdout)"];

  const fromDefault = await artist.captureProcess(node, program);
  const fromCall = await artist.captureProcess(node, program, { stdin: "call stdin" });

  assert.equal(fromDefault.ok, true);
  assert.equal(fromDefault.value, "default stdin");
  assert.equal(fromCall.ok, true);
  assert.equal(fromCall.value, "call stdin");
});

test("constructor default logger applies and per-call logger overrides it", async () => {
  const defaultEvents = [];
  const callEvents = [];
  const artist = new Portraitist({ logger: (event) => defaultEvents.push(event.type) });

  await artist.captureProcess(node, ["-e", "process.stdout.write('a')"]);
  await artist.captureProcess(node, ["-e", "process.stdout.write('b')"], {
    logger: (event) => callEvents.push(event.type),
  });

  assert.deepEqual(defaultEvents, ["start", "stdout", "finish"]);
  assert.deepEqual(callEvents, ["start", "stdout", "finish"]);
});

test("constructor default parseInput applies and per-call parseInput overrides it", async () => {
  const artist = new Portraitist({ parseInput: "stderr" });
  const program = ["-e", "process.stdout.write('out'); process.stderr.write('err')"];

  const fromDefault = await artist.captureProcess(node, program, { parser: (text) => text });
  const fromCall = await artist.captureProcess(node, program, {
    parser: (text) => text,
    parseInput: "stdout",
  });

  assert.equal(fromDefault.ok, true);
  assert.equal(fromDefault.value, "err");
  assert.equal(fromCall.ok, true);
  assert.equal(fromCall.value, "out");
});

test("constructor default shell applies and per-call shell overrides it", async () => {
  const artist = new Portraitist({ shell: true });

  const viaShell = await artist.captureProcess("printf shelly");
  const withoutShell = await artist.captureCommand("printf hello", { shell: false });

  assert.equal(viaShell.ok, true);
  assert.equal(viaShell.value, "shelly");
  assert.equal(withoutShell.ok, false);
  assert.equal(withoutShell.error.kind, "spawn");
});

test("parseInput selects stdout explicitly", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('out'); process.stderr.write('err')",
  ], {
    parser: (text) => text,
    parseInput: "stdout",
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "out");
});

test("parseInput selects stderr explicitly", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('out'); process.stderr.write('err')",
  ], {
    parser: (text) => text,
    parseInput: "stderr",
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "err");
});

test("captureProcess accepts args through the options object", async () => {
  const result = await captureProcess(node, {
    args: ["-e", "process.stdout.write('opts-args')"],
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "opts-args");
});

test("captureScript accepts args through the options object", async () => {
  const result = await captureScript(node, {
    args: ["-e", "process.stdout.write('script-opts-args')"],
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "script-opts-args");
});

test("async parsers resolve and receive the capture context", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('payload'); process.stderr.write('ctx')",
  ], {
    parser: async (text, context) => ({
      text,
      exitCode: context.exitCode,
      stderrText: context.stderr,
      hasChunks: context.chunks.length > 0,
    }),
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.value, {
    text: "payload",
    exitCode: 0,
    stderrText: "ctx",
    hasChunks: true,
  });
});

test("multibyte characters survive chunk boundaries", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('\\u20ac'.repeat(100000))",
  ]);

  assert.equal(result.ok, true);
  assert.equal(result.stdout.includes("�"), false);
  assert.equal(result.stdout, "€".repeat(100000));
});

test("default interpreters can be keyed with a leading dot", async () => {
  const script = await temporaryScript(
    "dotted.portraiture-js",
    "process.stdout.write(process.argv[2]);",
  );
  const custom = new Portraitist({
    interpreters: {
      ".portraiture-js": node,
    },
  });

  const result = await custom.captureScript(script, ["from-dotted"]);

  assert.equal(result.ok, true);
  assert.equal(result.value, "from-dotted");
  assert.equal(result.target.command, node);
});

test("interpreter null suppresses a configured default interpreter", async () => {
  const script = await temporaryScript(
    "suppress.portraiture-js",
    "#!/bin/sh\nprintf direct\n",
  );
  await chmod(script, 0o755);
  const custom = new Portraitist({
    interpreters: {
      ".portraiture-js": node,
    },
  });

  const result = await custom.captureScript(script, [], { interpreter: null });

  assert.equal(result.ok, true);
  assert.equal(result.value, "direct");
  assert.equal(result.target.command, script);
  assert.equal(result.target.interpreter, undefined);
});

test("results expose chunks, signal, and duration metadata", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('a'); process.stderr.write('b'); process.stdout.write('c')",
  ]);

  assert.equal(result.ok, true);
  assert.equal(Object.isFrozen(result.chunks), true);
  for (const chunk of result.chunks) {
    assert.equal(["stdout", "stderr"].includes(chunk.stream), true);
    assert.equal(typeof chunk.text, "string");
  }
  const stdoutText = result.chunks
    .filter((chunk) => chunk.stream === "stdout")
    .map((chunk) => chunk.text)
    .join("");
  const stderrText = result.chunks
    .filter((chunk) => chunk.stream === "stderr")
    .map((chunk) => chunk.text)
    .join("");
  assert.equal(stdoutText, "ac");
  assert.equal(stderrText, "b");
  assert.equal(result.output.length, 3);
  assert.equal(result.signal, null);
  assert.equal(typeof result.durationMs, "number");
  assert.equal(result.durationMs >= 0, true);
});

test("output captured before a timeout stays on the result", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('early'); setTimeout(() => {}, 5000)",
  ], {
    timeoutMs: 500,
    killGraceMs: 300,
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "timeout");
  assert.equal(result.stdout, "early");
  assert.equal(result.signal, "SIGTERM");
});

test("timeouts kill shell grandchildren and resolve within the deadline", async () => {
  const startedAt = performance.now();
  const result = await captureCommand("sleep 5 & sleep 5", {
    timeoutMs: 200,
    killGraceMs: 500,
  });
  const elapsed = performance.now() - startedAt;

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "timeout");
  assert.equal(elapsed < 3000, true, `expected timely resolution, took ${elapsed}ms`);
});

test("timeouts escalate to SIGKILL when the child traps SIGTERM", async () => {
  const startedAt = performance.now();
  const result = await captureProcess(node, [
    "-e",
    "process.on('SIGTERM', () => {}); process.stdout.write('trapped'); setInterval(() => {}, 1000)",
  ], {
    timeoutMs: 200,
    killGraceMs: 300,
  });
  const elapsed = performance.now() - startedAt;

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "timeout");
  assert.equal(result.signal, "SIGKILL");
  assert.equal(result.stdout, "trapped");
  assert.equal(elapsed < 4000, true, `expected timely resolution, took ${elapsed}ms`);
});

test("pending stdin does not extend a capture past its timeout", async () => {
  const startedAt = performance.now();
  const result = await captureProcess(node, [
    "-e",
    "setTimeout(() => {}, 5000)",
  ], {
    stdin: "x".repeat(1024 * 1024),
    timeoutMs: 200,
    killGraceMs: 300,
  });
  const elapsed = performance.now() - startedAt;

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "timeout");
  assert.equal(elapsed < 3000, true, `expected timely resolution, took ${elapsed}ms`);
});

test("large stdin to a fast-exiting child does not crash the host", async () => {
  const result = await captureProcess(node, ["-e", "process.exit(0)"], {
    stdin: "x".repeat(1024 * 1024),
  });

  assert.equal(result.ok, true);
  assert.equal(result.exitCode, 0);
});

test("binary Uint8Array stdin is delivered byte-for-byte", async () => {
  const result = await captureProcess(node, [
    "-e",
    "const parts = []; process.stdin.on('data', (d) => parts.push(d)); process.stdin.on('end', () => { const b = Buffer.concat(parts); process.stdout.write(`${b.length}:${b[0]},${b[1]},${b[2]}`); })",
  ], {
    stdin: new Uint8Array([0, 255, 128]),
  });

  assert.equal(result.ok, true);
  assert.equal(result.value, "3:0,255,128");
});

test("synchronous spawn failures emit start and finish logger events", async () => {
  const events = [];
  const result = await captureProcess("", {
    logger: (event) => events.push(event),
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "spawn");
  assert.deepEqual(events.map((event) => event.type), ["start", "finish"]);
  assert.equal(events[1].ok, false);
});

test("asynchronous spawn failures emit start and finish logger events", async () => {
  const events = [];
  const result = await captureProcess("__portraiture_missing_executable__", {
    logger: (event) => events.push(event),
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "spawn");
  assert.deepEqual(events.map((event) => event.type), ["start", "finish"]);
  assert.equal(events[1].ok, false);
});

test("signal-terminated children report the signal in the exit failure", async () => {
  const result = await captureProcess(node, [
    "-e",
    "process.kill(process.pid, 'SIGTERM'); setTimeout(() => {}, 5000)",
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "exit");
  assert.match(result.error.message, /terminated by signal SIGTERM/);
  assert.equal(result.exitCode, null);
  assert.equal(result.signal, "SIGTERM");
});

test("an abort signal cancels a running capture", async () => {
  const controller = new AbortController();
  setTimeout(() => controller.abort(new Error("caller cancelled")), 100);

  const startedAt = performance.now();
  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('started'); setTimeout(() => {}, 5000)",
  ], {
    signal: controller.signal,
    killGraceMs: 300,
  });
  const elapsed = performance.now() - startedAt;

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "abort");
  assert.equal(result.stdout, "started");
  assert.equal(elapsed < 3000, true, `expected timely resolution, took ${elapsed}ms`);
});

test("a pre-aborted signal fails without spawning and still logs lifecycle events", async () => {
  const controller = new AbortController();
  controller.abort();
  const events = [];

  const result = await captureProcess(node, [
    "-e",
    "process.stdout.write('never')",
  ], {
    signal: controller.signal,
    logger: (event) => events.push(event.type),
  });

  assert.equal(result.ok, false);
  assert.equal(result.error.kind, "abort");
  assert.equal(result.stdout, "");
  assert.deepEqual(events, ["start", "finish"]);
});

function standardSchema(validate) {
  return {
    "~standard": {
      version: 1,
      vendor: "portraiture-test",
      validate,
    },
  };
}

async function temporaryScript(name, contents) {
  const directory = await mkdtemp(join(tmpdir(), "portraiture-test-"));
  const path = join(directory, name);
  await writeFile(path, contents);
  return path;
}
