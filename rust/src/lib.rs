//! Capture stdout and stderr from external commands, processes, and scripts.
//!
//! Rust keeps the cross-language `CaptureResult<T>` shape so failed captures
//! still carry stdout, stderr, exit status, duration, chunks, and target
//! metadata. For Rust-style flow, call [`CaptureResult::into_std_result`],
//! [`CaptureResult::value`], or [`CaptureResult::error`].

use std::collections::HashMap;
use std::fmt;
use std::io::{self, Read, Write};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetKind {
    Command,
    Process,
    Script,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stream {
    Stdout,
    Stderr,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParseInput {
    Stdout,
    Stderr,
    Combined,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StderrPolicy {
    Capture,
    Fail,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FailureKind {
    Exit,
    Parse,
    Spawn,
    Stderr,
    Timeout,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureChunk {
    pub stream: Stream,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Interpreter {
    pub command: String,
    pub args: Vec<String>,
}

impl Interpreter {
    pub fn new(command: impl Into<String>) -> Self {
        Self {
            command: command.into(),
            args: Vec::new(),
        }
    }

    pub fn with_args(
        command: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            command: command.into(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureTarget {
    pub kind: TargetKind,
    pub command: String,
    pub args: Vec<String>,
    pub script: Option<String>,
    pub interpreter: Option<Interpreter>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureContext {
    pub stdout: String,
    pub stderr: String,
    pub output: String,
    pub chunks: Vec<CaptureChunk>,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub duration: Duration,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureFailure {
    pub kind: FailureKind,
    pub message: String,
}

impl fmt::Display for CaptureFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "portraiture {:?} failure: {}",
            self.kind, self.message
        )
    }
}

impl std::error::Error for CaptureFailure {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureResult<T> {
    pub ok: bool,
    pub value: Option<T>,
    pub error: Option<CaptureFailure>,
    pub stdout: String,
    pub stderr: String,
    pub output: String,
    pub chunks: Vec<CaptureChunk>,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub duration: Duration,
    pub target: CaptureTarget,
}

impl<T> CaptureResult<T> {
    pub fn is_ok(&self) -> bool {
        self.ok
    }

    pub fn is_err(&self) -> bool {
        !self.ok
    }

    pub fn value(&self) -> Result<&T, &CaptureFailure> {
        if self.ok {
            Ok(self
                .value
                .as_ref()
                .expect("successful capture missing value"))
        } else {
            Err(self.error.as_ref().expect("failed capture missing error"))
        }
    }

    pub fn error(&self) -> Option<&CaptureFailure> {
        self.error.as_ref()
    }

    pub fn into_std_result(self) -> Result<T, CaptureFailure> {
        if self.ok {
            Ok(self.value.expect("successful capture missing value"))
        } else {
            Err(self.error.expect("failed capture missing error"))
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Options {
    pub working_directory: Option<String>,
    pub environment: HashMap<String, String>,
    pub fail_on_nonzero_exit: Option<bool>,
    pub parse_input: Option<ParseInput>,
    pub interpreter: Option<Interpreter>,
    pub interpreters: HashMap<String, Interpreter>,
    pub use_shell: Option<bool>,
    pub stderr: Option<StderrPolicy>,
    pub standard_input: Option<String>,
    pub timeout: Option<Duration>,
}

#[derive(Clone, Debug, Default)]
pub struct Portraitist {
    defaults: Options,
}

#[derive(Clone, Debug)]
struct ResolvedOptions {
    working_directory: Option<String>,
    environment: HashMap<String, String>,
    fail_on_nonzero_exit: bool,
    parse_input: ParseInput,
    use_shell: bool,
    stderr: StderrPolicy,
    standard_input: Option<String>,
    timeout: Option<Duration>,
}

impl Portraitist {
    pub fn new(options: Options) -> Self {
        Self { defaults: options }
    }

    pub fn capture_command(
        &self,
        command: impl Into<String>,
        options: Options,
    ) -> CaptureResult<String> {
        let target = CaptureTarget {
            kind: TargetKind::Command,
            command: command.into(),
            args: Vec::new(),
            script: None,
            interpreter: None,
        };
        self.run_capture_with_default_parse_input(
            target,
            options,
            ParseInput::Combined,
            |text, _context| Ok::<String, std::convert::Infallible>(text.to_owned()),
        )
    }

    pub fn capture_command_parsed<T, E>(
        &self,
        command: impl Into<String>,
        options: Options,
        parser: impl FnOnce(&str, &CaptureContext) -> Result<T, E>,
    ) -> CaptureResult<T>
    where
        E: fmt::Display,
    {
        let target = CaptureTarget {
            kind: TargetKind::Command,
            command: command.into(),
            args: Vec::new(),
            script: None,
            interpreter: None,
        };
        self.run_capture_with_default_parse_input(target, options, ParseInput::Stdout, parser)
    }

    pub fn capture_process(
        &self,
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        options: Options,
    ) -> CaptureResult<String> {
        let target = CaptureTarget {
            kind: TargetKind::Process,
            command: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            script: None,
            interpreter: None,
        };
        self.run_capture_with_default_parse_input(
            target,
            options,
            ParseInput::Combined,
            |text, _context| Ok::<String, std::convert::Infallible>(text.to_owned()),
        )
    }

    pub fn capture_process_parsed<T, E>(
        &self,
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        options: Options,
        parser: impl FnOnce(&str, &CaptureContext) -> Result<T, E>,
    ) -> CaptureResult<T>
    where
        E: fmt::Display,
    {
        let target = CaptureTarget {
            kind: TargetKind::Process,
            command: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            script: None,
            interpreter: None,
        };
        self.run_capture_with_default_parse_input(target, options, ParseInput::Stdout, parser)
    }

    pub fn capture_script(
        &self,
        path: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        options: Options,
    ) -> CaptureResult<String> {
        let target = self.create_script_target(path.into(), args, &options);
        self.run_capture_with_default_parse_input(
            target,
            options,
            ParseInput::Combined,
            |text, _context| Ok::<String, std::convert::Infallible>(text.to_owned()),
        )
    }

    pub fn capture_script_parsed<T, E>(
        &self,
        path: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        options: Options,
        parser: impl FnOnce(&str, &CaptureContext) -> Result<T, E>,
    ) -> CaptureResult<T>
    where
        E: fmt::Display,
    {
        let target = self.create_script_target(path.into(), args, &options);
        self.run_capture_with_default_parse_input(target, options, ParseInput::Stdout, parser)
    }

    fn run_capture_with_default_parse_input<T, E>(
        &self,
        target: CaptureTarget,
        options: Options,
        default_parse_input: ParseInput,
        parser: impl FnOnce(&str, &CaptureContext) -> Result<T, E>,
    ) -> CaptureResult<T>
    where
        E: fmt::Display,
    {
        run_capture(
            target,
            self.resolve_options(&options, default_parse_input),
            parser,
        )
    }

    fn create_script_target(
        &self,
        path: String,
        args: impl IntoIterator<Item = impl Into<String>>,
        options: &Options,
    ) -> CaptureTarget {
        let script_args: Vec<String> = args.into_iter().map(Into::into).collect();
        let interpreter = self.resolve_interpreter(&path, options);

        if let Some(interpreter) = interpreter {
            let mut command_args = interpreter.args.clone();
            command_args.push(path.clone());
            command_args.extend(script_args);
            CaptureTarget {
                kind: TargetKind::Script,
                command: interpreter.command.clone(),
                args: command_args,
                script: Some(path),
                interpreter: Some(interpreter),
            }
        } else {
            CaptureTarget {
                kind: TargetKind::Script,
                command: path.clone(),
                args: script_args,
                script: Some(path),
                interpreter: None,
            }
        }
    }

    fn resolve_interpreter(&self, path: &str, options: &Options) -> Option<Interpreter> {
        if let Some(interpreter) = &options.interpreter {
            return Some(interpreter.clone());
        }

        let extension =
            normalize_extension(Path::new(path).extension()?.to_string_lossy().as_ref());
        if let Some(interpreter) = options.interpreters.get(&extension) {
            return Some(interpreter.clone());
        }

        if let Some(interpreter) = &self.defaults.interpreter {
            return Some(interpreter.clone());
        }

        self.defaults.interpreters.get(&extension).cloned()
    }

    fn resolve_options(
        &self,
        options: &Options,
        default_parse_input: ParseInput,
    ) -> ResolvedOptions {
        let mut environment = self.defaults.environment.clone();
        environment.extend(options.environment.clone());

        ResolvedOptions {
            working_directory: options
                .working_directory
                .clone()
                .or_else(|| self.defaults.working_directory.clone()),
            environment,
            fail_on_nonzero_exit: options
                .fail_on_nonzero_exit
                .or(self.defaults.fail_on_nonzero_exit)
                .unwrap_or(true),
            parse_input: options
                .parse_input
                .or(self.defaults.parse_input)
                .unwrap_or(default_parse_input),
            use_shell: options
                .use_shell
                .or(self.defaults.use_shell)
                .unwrap_or(false),
            stderr: options
                .stderr
                .or(self.defaults.stderr)
                .unwrap_or(StderrPolicy::Capture),
            standard_input: options
                .standard_input
                .clone()
                .or_else(|| self.defaults.standard_input.clone()),
            timeout: options.timeout.or(self.defaults.timeout),
        }
    }
}

pub fn capture_command(command: impl Into<String>) -> CaptureResult<String> {
    Portraitist::default().capture_command(command, Options::default())
}

pub fn capture_process(
    program: impl Into<String>,
    args: impl IntoIterator<Item = impl Into<String>>,
) -> CaptureResult<String> {
    Portraitist::default().capture_process(program, args, Options::default())
}

pub fn capture_script(
    path: impl Into<String>,
    args: impl IntoIterator<Item = impl Into<String>>,
) -> CaptureResult<String> {
    Portraitist::default().capture_script(path, args, Options::default())
}

fn run_capture<T, E>(
    target: CaptureTarget,
    options: ResolvedOptions,
    parser: impl FnOnce(&str, &CaptureContext) -> Result<T, E>,
) -> CaptureResult<T>
where
    E: fmt::Display,
{
    let started_at = Instant::now();
    let mut command = build_command(&target, &options);

    if let Some(cwd) = &options.working_directory {
        command.current_dir(cwd);
    }
    command.envs(&options.environment);
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return failure_result(
                target,
                empty_context(started_at.elapsed()),
                FailureKind::Spawn,
                error.to_string(),
            );
        }
    };

    let stdout = child.stdout.take().expect("stdout pipe missing");
    let stderr = child.stderr.take().expect("stderr pipe missing");
    let chunks = Arc::new(Mutex::new(Vec::new()));

    let stdout_chunks = Arc::clone(&chunks);
    let stdout_thread = thread::spawn(move || read_pipe(stdout, Stream::Stdout, stdout_chunks));

    let stderr_chunks = Arc::clone(&chunks);
    let stderr_thread = thread::spawn(move || read_pipe(stderr, Stream::Stderr, stderr_chunks));

    if let Some(input) = &options.standard_input {
        if let Some(mut stdin) = child.stdin.take() {
            let input = input.clone();
            thread::spawn(move || {
                let _ = stdin.write_all(input.as_bytes());
            });
        }
    }
    drop(child.stdin.take());

    let mut timed_out = false;
    let status = wait_for_child(&mut child, options.timeout, &mut timed_out);

    let _ = stdout_thread.join();
    let _ = stderr_thread.join();

    let duration = started_at.elapsed();
    let chunks = match Arc::try_unwrap(chunks) {
        Ok(mutex) => mutex.into_inner().unwrap_or_default(),
        Err(arc) => arc.lock().expect("chunk lock poisoned").clone(),
    };
    let context = context_from_chunks(chunks, status.as_ref().ok(), duration);

    if timed_out {
        return failure_result(
            target,
            context,
            FailureKind::Timeout,
            "Capture timed out.".to_string(),
        );
    }

    if let Err(error) = status {
        return failure_result(target, context, FailureKind::Spawn, error.to_string());
    }

    if options.stderr == StderrPolicy::Fail && !context.stderr.is_empty() {
        return failure_result(
            target,
            context,
            FailureKind::Stderr,
            "Capture wrote to stderr.".to_string(),
        );
    }

    if options.fail_on_nonzero_exit && context.exit_code != Some(0) {
        let message = if let Some(code) = context.exit_code {
            format!("Capture exited with code {code}.")
        } else {
            "Capture exited without a normal exit code.".to_string()
        };
        return failure_result(target, context, FailureKind::Exit, message);
    }

    let parse_text = match options.parse_input {
        ParseInput::Stdout => context.stdout.as_str(),
        ParseInput::Stderr => context.stderr.as_str(),
        ParseInput::Combined => context.output.as_str(),
    };

    match parser(parse_text, &context) {
        Ok(value) => success_result(target, context, value),
        Err(error) => failure_result(target, context, FailureKind::Parse, error.to_string()),
    }
}

fn build_command(target: &CaptureTarget, options: &ResolvedOptions) -> Command {
    if options.use_shell || target.kind == TargetKind::Command {
        #[cfg(windows)]
        {
            let mut command = Command::new("cmd.exe");
            command.arg("/C").arg(shell_line(target));
            command
        }
        #[cfg(not(windows))]
        {
            let mut command = Command::new("/bin/sh");
            command.arg("-c").arg(shell_line(target));
            command
        }
    } else {
        let mut command = Command::new(&target.command);
        command.args(&target.args);
        command
    }
}

fn shell_line(target: &CaptureTarget) -> String {
    if target.kind == TargetKind::Command {
        target.command.clone()
    } else {
        let mut parts = Vec::with_capacity(target.args.len() + 1);
        parts.push(shell_quote(&target.command));
        parts.extend(target.args.iter().map(|arg| shell_quote(arg)));
        parts.join(" ")
    }
}

fn wait_for_child(
    child: &mut Child,
    timeout: Option<Duration>,
    timed_out: &mut bool,
) -> io::Result<ExitStatus> {
    if let Some(timeout) = timeout {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            if Instant::now() >= deadline {
                *timed_out = true;
                let _ = child.kill();
                return child.wait();
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    child.wait()
}

fn read_pipe<R: Read>(mut pipe: R, stream: Stream, chunks: Arc<Mutex<Vec<CaptureChunk>>>) {
    let mut bytes = Vec::new();
    let _ = pipe.read_to_end(&mut bytes);
    if !bytes.is_empty() {
        let text = String::from_utf8_lossy(&bytes).into_owned();
        chunks
            .lock()
            .expect("chunk lock poisoned")
            .push(CaptureChunk { stream, text });
    }
}

fn context_from_chunks(
    chunks: Vec<CaptureChunk>,
    status: Option<&ExitStatus>,
    duration: Duration,
) -> CaptureContext {
    let stdout = chunks
        .iter()
        .filter(|chunk| chunk.stream == Stream::Stdout)
        .map(|chunk| chunk.text.as_str())
        .collect::<String>();
    let stderr = chunks
        .iter()
        .filter(|chunk| chunk.stream == Stream::Stderr)
        .map(|chunk| chunk.text.as_str())
        .collect::<String>();
    let output = format!("{stdout}{stderr}");

    CaptureContext {
        stdout,
        stderr,
        output,
        chunks,
        exit_code: status.and_then(ExitStatus::code),
        signal: exit_signal(status),
        duration,
    }
}

#[cfg(unix)]
fn exit_signal(status: Option<&ExitStatus>) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt;
    status.and_then(ExitStatusExt::signal)
}

#[cfg(not(unix))]
fn exit_signal(_status: Option<&ExitStatus>) -> Option<i32> {
    None
}

fn success_result<T>(target: CaptureTarget, context: CaptureContext, value: T) -> CaptureResult<T> {
    CaptureResult {
        ok: true,
        value: Some(value),
        error: None,
        stdout: context.stdout,
        stderr: context.stderr,
        output: context.output,
        chunks: context.chunks,
        exit_code: context.exit_code,
        signal: context.signal,
        duration: context.duration,
        target,
    }
}

fn failure_result<T>(
    target: CaptureTarget,
    context: CaptureContext,
    kind: FailureKind,
    message: String,
) -> CaptureResult<T> {
    CaptureResult {
        ok: false,
        value: None,
        error: Some(CaptureFailure { kind, message }),
        stdout: context.stdout,
        stderr: context.stderr,
        output: context.output,
        chunks: context.chunks,
        exit_code: context.exit_code,
        signal: context.signal,
        duration: context.duration,
        target,
    }
}

fn empty_context(duration: Duration) -> CaptureContext {
    CaptureContext {
        stdout: String::new(),
        stderr: String::new(),
        output: String::new(),
        chunks: Vec::new(),
        exit_code: None,
        signal: None,
        duration,
    }
}

fn normalize_extension(extension: &str) -> String {
    if extension.starts_with('.') {
        extension.to_lowercase()
    } else {
        format!(".{}", extension.to_lowercase())
    }
}

fn shell_quote(value: &str) -> String {
    #[cfg(windows)]
    {
        format!("\"{}\"", value.replace('"', "\\\""))
    }
    #[cfg(not(windows))]
    {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = env::temp_dir().join(format!("portraiture-rust-{name}-{unique}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_script(
        directory: &std::path::Path,
        name: &str,
        contents: &str,
        executable: bool,
    ) -> String {
        let path = directory.join(name);
        fs::write(&path, contents).unwrap();
        #[cfg(unix)]
        if executable {
            let mut permissions = fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&path, permissions).unwrap();
        }
        path.to_string_lossy().into_owned()
    }

    fn sh() -> &'static str {
        "/bin/sh"
    }

    fn cat() -> &'static str {
        "/bin/cat"
    }

    #[test]
    fn capture_command_captures_stdout() {
        let result = capture_command("printf hello");
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "hello");
        assert_eq!(result.target.kind, TargetKind::Command);
    }

    #[test]
    fn unparsed_value_is_combined_output() {
        let result = capture_command("printf out; printf err >&2");
        assert!(result.ok);
        assert_eq!(result.stdout, "out");
        assert_eq!(result.stderr, "err");
        assert_eq!(result.output, "outerr");
        assert_eq!(result.value.unwrap(), "outerr");
    }

    #[test]
    fn capture_process_passes_literal_args() {
        let directory = temp_dir("literal");
        let script = write_script(&directory, "echo-arg.sh", "printf '%s' \"$1\"", false);
        let result = capture_process(sh(), [script, "hello; echo nope".to_string()]);
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "hello; echo nope");
        assert_eq!(result.target.kind, TargetKind::Process);
    }

    #[test]
    fn capture_script_runs_directly_without_interpreter() {
        if cfg!(windows) {
            return;
        }
        let directory = temp_dir("direct-script");
        let script = write_script(
            &directory,
            "direct.sh",
            "#!/bin/sh\nprintf 'direct:%s' \"$1\"\n",
            true,
        );
        let result = capture_script(script.clone(), ["one"]);
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "direct:one");
        assert_eq!(result.target.command, script);
        assert_eq!(result.target.interpreter, None);
    }

    #[test]
    fn explicit_and_default_interpreters_work() {
        if cfg!(windows) {
            return;
        }
        let directory = temp_dir("interpreters");
        let script = write_script(&directory, "script.portraiture-sh", "printf \"$1\"", false);

        let explicit = Portraitist::default().capture_script(
            script.clone(),
            ["via-interpreter"],
            Options {
                interpreter: Some(Interpreter::new(sh())),
                ..Options::default()
            },
        );
        assert!(explicit.ok);
        assert_eq!(explicit.value.unwrap(), "via-interpreter");

        let portraitist = Portraitist::new(Options {
            interpreters: HashMap::from([(".portraiture-sh".to_string(), Interpreter::new(sh()))]),
            ..Options::default()
        });
        let defaulted = portraitist.capture_script(script, ["from-default"], Options::default());
        assert!(defaulted.ok);
        assert_eq!(defaulted.value.unwrap(), "from-default");
    }

    #[test]
    fn parser_reads_stdout_by_default() {
        let portraitist = Portraitist::default();
        let result = portraitist.capture_process_parsed(
            sh(),
            ["-c", "printf '{\"hostname\":\"local\"}'"],
            Options::default(),
            |text, _context| {
                if text.contains("\"hostname\":\"local\"") {
                    Ok("local".to_string())
                } else {
                    Err("missing hostname")
                }
            },
        );
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "local");
    }

    #[test]
    fn parse_input_can_read_stderr_and_combined() {
        let portraitist = Portraitist::default();
        let stderr = portraitist.capture_process_parsed(
            sh(),
            ["-c", "printf out; printf warn >&2"],
            Options {
                parse_input: Some(ParseInput::Stderr),
                ..Options::default()
            },
            |text, _context| Ok::<_, &str>(format!("parsed:{text}")),
        );
        assert!(stderr.ok);
        assert_eq!(stderr.value.unwrap(), "parsed:warn");

        let combined = portraitist.capture_process_parsed(
            sh(),
            ["-c", "printf out; printf err >&2"],
            Options {
                parse_input: Some(ParseInput::Combined),
                ..Options::default()
            },
            |text, _context| Ok::<_, &str>(text.to_string()),
        );
        assert!(combined.ok);
        assert_eq!(combined.value.unwrap(), "outerr");
    }

    #[test]
    fn parser_failures_return_parse_failures() {
        let portraitist = Portraitist::default();
        let result = portraitist.capture_process_parsed(
            sh(),
            ["-c", "printf not-json"],
            Options::default(),
            |_text, _context| Err::<String, _>("nope"),
        );
        assert!(!result.ok);
        assert_eq!(result.error.unwrap().kind, FailureKind::Parse);
        assert_eq!(result.stdout, "not-json");
    }

    #[test]
    fn stderr_can_fail_result() {
        let result = Portraitist::default().capture_process(
            sh(),
            ["-c", "printf warn >&2"],
            Options {
                stderr: Some(StderrPolicy::Fail),
                ..Options::default()
            },
        );
        assert!(!result.ok);
        assert_eq!(result.error.unwrap().kind, FailureKind::Stderr);
        assert_eq!(result.stderr, "warn");
    }

    #[test]
    fn nonzero_exit_fails_by_default_and_can_be_collected() {
        let portraitist = Portraitist::default();
        let failed = portraitist.capture_process(
            sh(),
            ["-c", "printf before; printf bad >&2; exit 7"],
            Options::default(),
        );
        assert!(!failed.ok);
        assert_eq!(failed.error.unwrap().kind, FailureKind::Exit);
        assert_eq!(failed.exit_code, Some(7));
        assert_eq!(failed.stdout, "before");
        assert_eq!(failed.stderr, "bad");

        let collected = portraitist.capture_process(
            sh(),
            ["-c", "printf data; exit 7"],
            Options {
                fail_on_nonzero_exit: Some(false),
                ..Options::default()
            },
        );
        assert!(collected.ok);
        assert_eq!(collected.exit_code, Some(7));
        assert_eq!(collected.value.unwrap(), "data");
    }

    #[test]
    fn timeout_returns_timeout_failure_and_preserves_output() {
        let result = Portraitist::default().capture_process(
            sh(),
            ["-c", "printf before; sleep 5"],
            Options {
                timeout: Some(Duration::from_millis(50)),
                ..Options::default()
            },
        );
        assert!(!result.ok);
        assert_eq!(result.error.unwrap().kind, FailureKind::Timeout);
        assert_eq!(result.stdout, "before");
    }

    #[test]
    fn spawn_errors_return_spawn_failures() {
        let result = Portraitist::default().capture_process(
            "__portraiture_missing_executable__",
            Vec::<String>::new(),
            Options::default(),
        );
        assert!(!result.ok);
        assert_eq!(result.error.unwrap().kind, FailureKind::Spawn);
    }

    #[test]
    fn stdin_is_sent_to_process() {
        let result = Portraitist::default().capture_process(
            cat(),
            Vec::<String>::new(),
            Options {
                standard_input: Some("hello stdin".to_string()),
                ..Options::default()
            },
        );
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "hello stdin");
    }

    #[test]
    fn constructor_default_env_applies_and_per_call_overrides() {
        let portraitist = Portraitist::new(Options {
            environment: HashMap::from([(
                "PORTRAITURE_RUST_TEST".to_string(),
                "default".to_string(),
            )]),
            ..Options::default()
        });
        let result = portraitist.capture_process(
            sh(),
            ["-c", "printf '%s' \"$PORTRAITURE_RUST_TEST\""],
            Options {
                environment: HashMap::from([(
                    "PORTRAITURE_RUST_TEST".to_string(),
                    "override".to_string(),
                )]),
                ..Options::default()
            },
        );
        assert!(result.ok);
        assert_eq!(result.value.unwrap(), "override");
    }

    #[test]
    fn working_directory_defaults_and_overrides() {
        let default_dir = temp_dir("cwd-default");
        let override_dir = temp_dir("cwd-override");
        fs::write(default_dir.join("marker.txt"), "default").unwrap();
        fs::write(override_dir.join("marker.txt"), "override").unwrap();

        let portraitist = Portraitist::new(Options {
            working_directory: Some(default_dir.to_string_lossy().into_owned()),
            ..Options::default()
        });

        let default_result = portraitist.capture_process(cat(), ["marker.txt"], Options::default());
        assert!(default_result.ok);
        assert_eq!(default_result.value.unwrap(), "default");

        let override_result = portraitist.capture_process(
            cat(),
            ["marker.txt"],
            Options {
                working_directory: Some(override_dir.to_string_lossy().into_owned()),
                ..Options::default()
            },
        );
        assert!(override_result.ok);
        assert_eq!(override_result.value.unwrap(), "override");
    }
}
