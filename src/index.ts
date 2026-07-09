import { spawn } from "node:child_process";
import type { ChildProcess, SpawnOptions } from "node:child_process";
import { extname } from "node:path";

export type CaptureTargetKind = "command" | "process" | "script";
export type CaptureStream = "stdout" | "stderr";
export type CaptureParseInput = "combined" | "stdout" | "stderr";
export type CaptureStderrPolicy = "capture" | "fail";

/** One captured chunk of child output, in best-effort arrival order. */
export interface CaptureChunk {
  readonly stream: CaptureStream;
  readonly text: string;
}

/**
 * Public description of the process a capture launches (or launched).
 *
 * A `CaptureTarget` is part of the public API: it is accepted by
 * {@link runCapture} and returned as the `target` metadata on every
 * {@link CaptureResult}.
 */
export interface CaptureTarget {
  /** Which capture method shape produced this target. */
  readonly kind: CaptureTargetKind;
  /** The executable, script path, or shell command string to launch. */
  readonly command: string;
  /** Literal arguments passed to the command. */
  readonly args: readonly string[];
  /** The original script path when `kind` is `"script"`. */
  readonly script?: string;
  /** The interpreter used to run the script, when one was resolved. */
  readonly interpreter?: NormalizedCaptureInterpreter;
}

export interface CaptureContext {
  readonly stdout: string;
  readonly stderr: string;
  readonly output: string;
  readonly chunks: readonly CaptureChunk[];
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly durationMs: number;
}

export type CaptureParser<T> = (text: string, context: CaptureContext) => T | Promise<T>;

export interface StandardSchemaV1<Input = unknown, Output = Input> {
  readonly "~standard": StandardSchemaV1.Props<Input, Output>;
}

export declare namespace StandardSchemaV1 {
  export interface Props<Input = unknown, Output = Input> {
    readonly version: 1;
    readonly vendor: string;
    readonly validate: (
      value: unknown,
      options?: Options,
    ) => Result<Output> | Promise<Result<Output>>;
    readonly types?: Types<Input, Output> | undefined;
  }

  export interface Options {
    readonly libraryOptions?: Record<string, unknown> | undefined;
  }

  export type Result<Output> = SuccessResult<Output> | FailureResult;

  export interface SuccessResult<Output> {
    readonly value: Output;
    readonly issues?: undefined;
  }

  export interface FailureResult {
    readonly issues: readonly Issue[];
  }

  export interface Issue {
    readonly message: string;
    readonly path?: readonly (PropertyKey | PathSegment)[] | undefined;
  }

  export interface PathSegment {
    readonly key: PropertyKey;
  }

  export interface Types<Input = unknown, Output = Input> {
    readonly input: Input;
    readonly output: Output;
  }
}

export type CaptureSchema<T> = StandardSchemaV1<unknown, T>;
export type CaptureParserLike<T> = CaptureParser<T> | CaptureSchema<T>;

export type CaptureLogEvent =
  | { readonly type: "start"; readonly target: CaptureTarget }
  | { readonly type: "stdout"; readonly text: string }
  | { readonly type: "stderr"; readonly text: string }
  | {
    readonly type: "finish";
    readonly ok: boolean;
    readonly durationMs: number;
    readonly exitCode: number | null;
    readonly signal: NodeJS.Signals | null;
  };

export type CaptureLogger = (event: CaptureLogEvent) => void;

export interface CaptureOptions<T = string> {
  /** Working directory for the child process only; the host cwd is untouched. */
  readonly cwd?: string;
  /**
   * Environment variables for the child process.
   *
   * Supplied variables AUGMENT the parent environment rather than replace it:
   * the child sees `process.env`, overlaid with the `Portraitist` constructor
   * default `env`, overlaid with this per-call `env`.
   */
  readonly env?: NodeJS.ProcessEnv;
  /** Fail with kind `"exit"` on nonzero exit. Defaults to `true`. */
  readonly failOnNonZeroExit?: boolean;
  /**
   * Grace period in milliseconds between the initial SIGTERM and the SIGKILL
   * escalation when a capture is killed by timeout or abort. Defaults to 2000.
   */
  readonly killGraceMs?: number;
  readonly logger?: CaptureLogger;
  /**
   * Which stream the parser reads. Defaults to `"stdout"` when a parser is
   * present, `"combined"` otherwise (so without a parser, `value` is the
   * combined output string).
   */
  readonly parseInput?: CaptureParseInput;
  readonly parser?: CaptureParserLike<T>;
  readonly shell?: boolean | string;
  /**
   * Caller cancellation. When the signal aborts while the capture is running,
   * the child process tree is killed (SIGTERM, escalating to SIGKILL after
   * {@link killGraceMs}) and the capture resolves as a failed result with
   * failure kind `"abort"`; output captured before the abort remains on the
   * result. A signal that is already aborted prevents the spawn entirely. If
   * the child completes before the abort takes effect, the completed result
   * is returned unchanged. An aborted capture resolves normally; it never
   * rejects.
   */
  readonly signal?: AbortSignal;
  readonly stderr?: CaptureStderrPolicy;
  readonly stdin?: string | Uint8Array;
  /**
   * Kill the capture after this many milliseconds and fail with kind
   * `"timeout"`. The entire child process tree is killed on POSIX (children
   * are spawned in their own process group), with SIGTERM escalating to
   * SIGKILL after {@link killGraceMs}. Output captured before the timeout
   * remains on the result.
   */
  readonly timeoutMs?: number;
}

/** {@link CaptureOptions} with a parser present, binding the value type `T`. */
export type CaptureOptionsWithParser<T> = CaptureOptions<T> & {
  readonly parser: CaptureParserLike<T>;
};

export interface CaptureScriptOptions<T = string> extends CaptureOptions<T> {
  readonly args?: readonly string[];
  /**
   * Interpreter for this call. Pass `null` to explicitly suppress a
   * `Portraitist` default interpreter and run the script path directly.
   */
  readonly interpreter?: CaptureInterpreter | null;
}

export type CaptureScriptOptionsWithParser<T> = CaptureScriptOptions<T> & {
  readonly parser: CaptureParserLike<T>;
};

export interface CaptureProcessOptions<T = string> extends CaptureOptions<T> {
  readonly args?: readonly string[];
}

export type CaptureProcessOptionsWithParser<T> = CaptureProcessOptions<T> & {
  readonly parser: CaptureParserLike<T>;
};

export interface NormalizedCaptureInterpreter {
  readonly command: string;
  readonly args: readonly string[];
}

export type CaptureInterpreter = string | NormalizedCaptureInterpreter;
export type CaptureInterpreterMap = Record<string, CaptureInterpreter>;

export interface PortraitistOptions extends Omit<CaptureOptions<unknown>, "parser"> {
  readonly interpreters?: CaptureInterpreterMap;
}

/**
 * Failure kinds. `"abort"` reports caller cancellation through the
 * {@link CaptureOptions.signal} option; the remaining kinds are the
 * cross-language required set.
 */
export type CaptureFailureKind = "abort" | "exit" | "parse" | "spawn" | "stderr" | "timeout";

export interface CaptureFailure {
  readonly kind: CaptureFailureKind;
  readonly message: string;
  readonly cause?: unknown;
}

export interface CaptureBaseResult {
  readonly chunks: readonly CaptureChunk[];
  readonly durationMs: number;
  readonly exitCode: number | null;
  readonly output: string;
  readonly signal: NodeJS.Signals | null;
  readonly stderr: string;
  readonly stdout: string;
  readonly target: CaptureTarget;
}

export interface CaptureSuccess<T> extends CaptureBaseResult {
  readonly ok: true;
  readonly value: T;
}

export interface CaptureErrorResult extends CaptureBaseResult {
  readonly ok: false;
  readonly error: CaptureFailure;
}

export type CaptureResult<T = string> = CaptureSuccess<T> | CaptureErrorResult;

export interface CaptureFacade {
  command<T>(command: string, options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
  command(command: string, options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
  process<T>(program: string, options: CaptureProcessOptionsWithParser<T>): Promise<CaptureResult<T>>;
  process<T>(program: string, args: readonly string[], options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
  process(program: string, options?: CaptureProcessOptions<string>): Promise<CaptureResult<string>>;
  process(program: string, args: readonly string[], options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
  script<T>(path: string, options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
  script<T>(path: string, args: readonly string[], options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
  script(path: string, options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
  script(path: string, args: readonly string[], options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
}

export class Portraitist {
  constructor(private readonly defaults: PortraitistOptions = {}) {}

  captureCommand<T>(command: string, options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
  captureCommand(command: string, options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
  captureCommand<T = string>(
    command: string,
    options: CaptureOptions<T> = {},
  ): Promise<CaptureResult<T>> {
    return executeCapture(
      { kind: "command", command, args: [] },
      mergeOptions(this.defaults, options),
    );
  }

  captureProcess<T>(program: string, options: CaptureProcessOptionsWithParser<T>): Promise<CaptureResult<T>>;
  captureProcess<T>(program: string, args: readonly string[], options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
  captureProcess(program: string, options?: CaptureProcessOptions<string>): Promise<CaptureResult<string>>;
  captureProcess(program: string, args: readonly string[], options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
  captureProcess<T = string>(
    program: string,
    argsOrOptions: readonly string[] | CaptureProcessOptions<T> = {},
    options: CaptureOptions<T> = {},
  ): Promise<CaptureResult<T>> {
    if (isArgs(argsOrOptions)) {
      return executeCapture(
        { kind: "process", command: program, args: argsOrOptions },
        mergeOptions(this.defaults, options),
      );
    }

    const processArgs = argsOrOptions.args ?? [];
    const captureOptions = withoutArgs(argsOrOptions);

    return executeCapture(
      { kind: "process", command: program, args: processArgs },
      mergeOptions(this.defaults, captureOptions),
    );
  }

  captureScript<T>(path: string, options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
  captureScript<T>(path: string, args: readonly string[], options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
  captureScript(path: string, options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
  captureScript(path: string, args: readonly string[], options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
  captureScript<T = string>(
    path: string,
    argsOrOptions: readonly string[] | CaptureScriptOptions<T> = {},
    options: CaptureScriptOptions<T> = {},
  ): Promise<CaptureResult<T>> {
    if (isArgs(argsOrOptions)) {
      const captureOptions = withoutArgs(options);
      const mergedOptions = mergeOptions(this.defaults, captureOptions);
      return executeCapture(
        createScriptTarget(path, argsOrOptions, resolveScriptInterpreter(path, this.defaults, options.interpreter)),
        mergedOptions,
      );
    }

    const scriptArgs = argsOrOptions.args ?? [];
    const captureOptions = withoutArgs(argsOrOptions);
    const mergedOptions = mergeOptions(this.defaults, captureOptions);

    return executeCapture(
      createScriptTarget(path, scriptArgs, resolveScriptInterpreter(path, this.defaults, argsOrOptions.interpreter)),
      mergedOptions,
    );
  }
}

export const portraitist = new Portraitist();

export function captureCommand<T>(command: string, options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function captureCommand(command: string, options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
export function captureCommand(
  command: string,
  options: CaptureOptions<any> = {},
): Promise<CaptureResult<any>> {
  return portraitist.captureCommand(command, options);
}

export function captureProcess<T>(program: string, options: CaptureProcessOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function captureProcess<T>(program: string, args: readonly string[], options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function captureProcess(program: string, options?: CaptureProcessOptions<string>): Promise<CaptureResult<string>>;
export function captureProcess(program: string, args: readonly string[], options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
export function captureProcess(
  program: string,
  argsOrOptions: readonly string[] | CaptureProcessOptions<any> = {},
  options: CaptureOptions<any> = {},
): Promise<CaptureResult<any>> {
  return isArgs(argsOrOptions)
    ? portraitist.captureProcess(program, argsOrOptions, options)
    : portraitist.captureProcess(program, argsOrOptions);
}

export function captureScript<T>(path: string, options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function captureScript<T>(path: string, args: readonly string[], options: CaptureScriptOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function captureScript(path: string, options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
export function captureScript(path: string, args: readonly string[], options?: CaptureScriptOptions<string>): Promise<CaptureResult<string>>;
export function captureScript(
  path: string,
  argsOrOptions: readonly string[] | CaptureScriptOptions<any> = {},
  options: CaptureScriptOptions<any> = {},
): Promise<CaptureResult<any>> {
  return isArgs(argsOrOptions)
    ? portraitist.captureScript(path, argsOrOptions, options)
    : portraitist.captureScript(path, argsOrOptions);
}

export const capture: CaptureFacade = {
  command: captureCommand,
  process: captureProcess,
  script: captureScript,
};

/**
 * Low-level public entry point that runs a prebuilt {@link CaptureTarget}
 * with fully merged options and returns a {@link CaptureResult}.
 *
 * This is part of the public API: the `Portraitist` methods and the module
 * facades all funnel into this behavior. Use it when you want to construct
 * target metadata yourself (for example, to reuse a target across calls or to
 * integrate Portraiture into another launcher). Unlike the `Portraitist`
 * methods, it applies no constructor defaults — the options you pass are the
 * options that run.
 */
export function runCapture<T>(target: CaptureTarget, options: CaptureOptionsWithParser<T>): Promise<CaptureResult<T>>;
export function runCapture(target: CaptureTarget, options?: CaptureOptions<string>): Promise<CaptureResult<string>>;
export function runCapture(
  target: CaptureTarget,
  options: CaptureOptions<any> = {},
): Promise<CaptureResult<any>> {
  return executeCapture(target, options);
}

const DEFAULT_KILL_GRACE_MS = 2000;

async function executeCapture<T>(
  target: CaptureTarget,
  options: CaptureOptions<T>,
): Promise<CaptureResult<T>> {
  const startedAt = performance.now();
  const chunks: CaptureChunk[] = [];
  let stdout = "";
  let stderr = "";
  let child: ChildProcess;

  emit(options.logger, { type: "start", target });

  if (options.signal?.aborted === true) {
    return finishFailure(options.logger, target, emptyContext(startedAt), {
      kind: "abort",
      message: "Capture was aborted before the target started.",
      cause: options.signal.reason,
    });
  }

  try {
    child = spawn(target.command, target.args, spawnOptions(target, options));
  } catch (cause) {
    return finishFailure(options.logger, target, emptyContext(startedAt), {
      kind: "spawn",
      message: messageFrom(cause, "Failed to start capture target."),
      cause,
    });
  }

  let killRequested = false;
  let killConfirmed = false;
  let escalation: NodeJS.Timeout | undefined;
  const killGraceMs = options.killGraceMs ?? DEFAULT_KILL_GRACE_MS;

  const requestKill = (): void => {
    if (killRequested) {
      return;
    }
    killRequested = true;
    // Stop feeding stdin so pending writes cannot outlive the deadline.
    child.stdin?.destroy();
    killConfirmed = killTree(child, "SIGTERM");
    escalation = setTimeout(() => {
      killTree(child, "SIGKILL");
      // Grandchildren may hold inherited pipes open even after the group is
      // dead on runtimes without group kill; force our ends closed so the
      // 'close' event (and this capture) cannot hang.
      child.stdout?.destroy();
      child.stderr?.destroy();
    }, killGraceMs);
  };

  let timedOut = false;
  const timeoutHandle = options.timeoutMs === undefined
    ? undefined
    : setTimeout(() => {
      timedOut = true;
      requestKill();
    }, options.timeoutMs);

  let aborted = false;
  const abortListener = (): void => {
    aborted = true;
    requestKill();
  };
  options.signal?.addEventListener("abort", abortListener, { once: true });

  // Decode through the stream so multibyte characters split across raw
  // chunks are never corrupted.
  child.stdout?.setEncoding("utf8");
  child.stdout?.on("data", (text: string) => {
    stdout += text;
    chunks.push(Object.freeze({ stream: "stdout" as const, text }));
    emit(options.logger, { type: "stdout", text });
  });

  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (text: string) => {
    stderr += text;
    chunks.push(Object.freeze({ stream: "stderr" as const, text }));
    emit(options.logger, { type: "stderr", text });
  });

  const stdinStream = child.stdin;
  if (stdinStream !== null) {
    // Swallow EPIPE (and friends) when the child exits without draining
    // stdin; an unhandled 'error' here would crash the host process.
    stdinStream.on("error", () => {});
    if (options.stdin !== undefined) {
      stdinStream.write(options.stdin);
    }
    stdinStream.end();
  }

  const closeResult = await waitForClose(child);
  if (timeoutHandle !== undefined) {
    clearTimeout(timeoutHandle);
  }
  if (escalation !== undefined) {
    clearTimeout(escalation);
  }
  options.signal?.removeEventListener("abort", abortListener);

  const durationMs = performance.now() - startedAt;
  const output = chunks.map((chunk) => chunk.text).join("");
  const context = {
    stdout,
    stderr,
    output,
    chunks: Object.freeze(chunks.slice()),
    exitCode: closeResult.exitCode,
    signal: closeResult.signal,
    durationMs,
  } satisfies CaptureContext;

  // Only classify as timeout/abort when our kill actually took effect;
  // if the child had already completed when the deadline fired, report the
  // real outcome instead.
  const killTookEffect = killConfirmed || closeResult.signal !== null;

  if (aborted && killTookEffect) {
    return finishFailure(options.logger, target, context, {
      kind: "abort",
      message: "Capture was aborted.",
      cause: options.signal?.reason,
    });
  }

  if (timedOut && killTookEffect) {
    return finishFailure(options.logger, target, context, {
      kind: "timeout",
      message: `Capture target timed out after ${options.timeoutMs}ms.`,
    });
  }

  if (closeResult.spawnError !== undefined) {
    return finishFailure(options.logger, target, context, {
      kind: "spawn",
      message: messageFrom(closeResult.spawnError, "Capture target failed while running."),
      cause: closeResult.spawnError,
    });
  }

  const failOnNonZeroExit = options.failOnNonZeroExit ?? true;
  if (failOnNonZeroExit && closeResult.exitCode !== 0) {
    return finishFailure(options.logger, target, context, {
      kind: "exit",
      message: closeResult.exitCode === null && closeResult.signal !== null
        ? `Capture target was terminated by signal ${closeResult.signal}.`
        : `Capture target exited with code ${closeResult.exitCode}.`,
    });
  }

  if (options.stderr === "fail" && stderr.length > 0) {
    return finishFailure(options.logger, target, context, {
      kind: "stderr",
      message: "Capture target wrote to stderr.",
    });
  }

  try {
    const selectedText = selectText(
      context,
      options.parseInput ?? (options.parser === undefined ? "combined" : "stdout"),
    );
    // Without a parser the overloads pin T to string, so this cast is sound.
    const value = options.parser === undefined
      ? (selectedText as T)
      : await parseCaptureValue(options.parser, selectedText, context);

    emit(options.logger, {
      type: "finish",
      ok: true,
      durationMs,
      exitCode: closeResult.exitCode,
      signal: closeResult.signal,
    });

    return {
      ok: true,
      value,
      target,
      ...context,
    };
  } catch (cause) {
    return finishFailure(options.logger, target, context, {
      kind: "parse",
      message: messageFrom(cause, "Parser failed."),
      cause,
    });
  }
}

/**
 * Sends a signal to the child's whole process tree where possible. Children
 * are spawned detached (their own process group) on POSIX, so signalling the
 * negative PID reaches grandchildren too; on Windows or when the group is
 * already gone this falls back to signalling the child alone. Returns whether
 * a signal was actually delivered.
 */
function killTree(child: ChildProcess, signal: NodeJS.Signals): boolean {
  const pid = child.pid;
  if (pid === undefined) {
    return false;
  }

  if (process.platform !== "win32") {
    try {
      process.kill(-pid, signal);
      return true;
    } catch {
      // Group already gone (or not detached); fall back to the child itself.
    }
  }

  return child.kill(signal);
}

function withoutArgs<T>(options: CaptureProcessOptions<T>): CaptureOptions<T>;
function withoutArgs<T>(options: CaptureScriptOptions<T>): CaptureOptions<T>;
function withoutArgs<T>(options: CaptureProcessOptions<T> | CaptureScriptOptions<T>): CaptureOptions<T> {
  const { args: _args, ...rest } = options;
  if ("interpreter" in rest) {
    const { interpreter: _interpreter, ...captureOptions } = rest;
    return captureOptions;
  }

  return rest;
}

function mergeOptions<T>(
  defaults: PortraitistOptions,
  options: CaptureOptions<T>,
): CaptureOptions<T> {
  const { interpreters: _interpreters, ...captureDefaults } = defaults;
  const merged = { ...captureDefaults, ...options };

  // env maps merge key-by-key (per-call wins) instead of replacing wholesale.
  if (defaults.env !== undefined && options.env !== undefined) {
    return { ...merged, env: { ...defaults.env, ...options.env } };
  }

  return merged;
}

function isArgs<T>(
  argsOrOptions: readonly string[] | CaptureProcessOptions<T> | CaptureScriptOptions<T>,
): argsOrOptions is readonly string[] {
  return Array.isArray(argsOrOptions);
}

function spawnOptions(target: CaptureTarget, options: CaptureOptions<unknown>): SpawnOptions {
  return {
    cwd: options.cwd,
    // Supplied env vars augment the parent environment (see CaptureOptions.env).
    env: options.env === undefined ? process.env : { ...process.env, ...options.env },
    // Run the child in its own process group on POSIX so timeout/abort can
    // kill the entire tree, not just the immediate child.
    detached: process.platform !== "win32",
    shell: options.shell ?? (target.kind === "command"),
  };
}

function createScriptTarget(
  path: string,
  args: readonly string[],
  interpreter: NormalizedCaptureInterpreter | undefined,
): CaptureTarget {
  if (interpreter === undefined) {
    return { kind: "script", command: path, args, script: path };
  }

  return {
    kind: "script",
    command: interpreter.command,
    args: [...interpreter.args, path, ...args],
    script: path,
    interpreter,
  };
}

function resolveScriptInterpreter(
  path: string,
  defaults: PortraitistOptions,
  explicit?: CaptureInterpreter | null,
): NormalizedCaptureInterpreter | undefined {
  if (explicit === null) {
    // Explicitly suppress any configured default interpreter for this call.
    return undefined;
  }

  if (explicit !== undefined) {
    return normalizeInterpreter(explicit);
  }

  const extension = normalizeExtension(extname(path));
  if (extension === undefined) {
    return undefined;
  }

  const interpreter = defaults.interpreters?.[extension] ?? defaults.interpreters?.[extension.slice(1)];
  return interpreter === undefined ? undefined : normalizeInterpreter(interpreter);
}

function normalizeInterpreter(interpreter: CaptureInterpreter): NormalizedCaptureInterpreter {
  if (typeof interpreter === "string") {
    return { command: interpreter, args: [] };
  }

  return {
    command: interpreter.command,
    args: interpreter.args ?? [],
  };
}

function normalizeExtension(extension: string): string | undefined {
  if (extension.length === 0) {
    return undefined;
  }

  return extension.startsWith(".")
    ? extension.toLowerCase()
    : `.${extension.toLowerCase()}`;
}

function waitForClose(child: ChildProcess): Promise<{
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  spawnError?: Error;
}> {
  return new Promise((resolve) => {
    let spawnError: Error | undefined;

    child.once("error", (error) => {
      spawnError = error;
    });

    child.once("close", (exitCode, signal) => {
      if (spawnError === undefined) {
        resolve({ exitCode, signal });
        return;
      }

      resolve({ exitCode, signal, spawnError });
    });
  });
}

function selectText(context: CaptureContext, parseInput: CaptureParseInput): string {
  if (parseInput === "stdout") {
    return context.stdout;
  }

  if (parseInput === "stderr") {
    return context.stderr;
  }

  return context.output;
}

async function parseCaptureValue<T>(
  parser: CaptureParserLike<T>,
  text: string,
  context: CaptureContext,
): Promise<T> {
  if (!isStandardSchema(parser)) {
    return parser(text, context);
  }

  const input = parseStandardSchemaInput(text);
  const result = await parser["~standard"].validate(input);

  if (result.issues !== undefined) {
    throw new StandardSchemaValidationError(result.issues);
  }

  return result.value;
}

function parseStandardSchemaInput(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function isStandardSchema<T>(parser: CaptureParserLike<T>): parser is CaptureSchema<T> {
  if (typeof parser !== "object" || parser === null || !("~standard" in parser)) {
    return false;
  }

  const standard = parser["~standard"];
  return standard.version === 1 && typeof standard.validate === "function";
}

class StandardSchemaValidationError extends Error {
  constructor(readonly issues: readonly StandardSchemaV1.Issue[]) {
    super(`Standard Schema validation failed: ${formatStandardSchemaIssues(issues)}`);
    this.name = "StandardSchemaValidationError";
  }
}

function formatStandardSchemaIssues(issues: readonly StandardSchemaV1.Issue[]): string {
  if (issues.length === 0) {
    return "unknown validation failure";
  }

  return issues.map(formatStandardSchemaIssue).join("; ");
}

function formatStandardSchemaIssue(issue: StandardSchemaV1.Issue): string {
  const path = issue.path?.map(formatStandardSchemaPathSegment).join(".");
  return path === undefined || path.length === 0
    ? issue.message
    : `${path}: ${issue.message}`;
}

function formatStandardSchemaPathSegment(segment: PropertyKey | StandardSchemaV1.PathSegment): string {
  if (typeof segment === "object" && segment !== null && "key" in segment) {
    return String(segment.key);
  }

  return String(segment);
}

function emptyContext(startedAt: number): CaptureContext {
  return {
    stdout: "",
    stderr: "",
    output: "",
    chunks: Object.freeze([]),
    exitCode: null,
    signal: null,
    durationMs: performance.now() - startedAt,
  };
}

function finishFailure(
  logger: CaptureLogger | undefined,
  target: CaptureTarget,
  context: CaptureContext,
  error: CaptureFailure,
): CaptureErrorResult {
  emit(logger, {
    type: "finish",
    ok: false,
    durationMs: context.durationMs,
    exitCode: context.exitCode,
    signal: context.signal,
  });

  return {
    ok: false,
    error,
    target,
    ...context,
  };
}

function messageFrom(error: unknown, fallback: string): string {
  if (error instanceof Error) {
    return error.message;
  }

  if (error === undefined || error === null) {
    return fallback;
  }

  const text = String(error);
  return text.length > 0 ? text : fallback;
}

function emit(logger: CaptureLogger | undefined, event: CaptureLogEvent): void {
  try {
    logger?.(event);
  } catch {
    // Logging should observe the run, not change its outcome.
  }
}
