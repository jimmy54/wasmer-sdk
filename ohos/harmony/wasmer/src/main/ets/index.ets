/**
 * `@wasmer/sdk` for HarmonyOS.
 *
 * A 1:1 port of the upstream JavaScript API on top of the Wasmer Rust core,
 * exposed through a Node-API bridge (libwasmer_sdk_ohos.so).
 *
 * Target-specific adaptations:
 * - Networking: HarmonyOS guests use host networking. `http` and `wisp`
 *   policies map to host networking, and `setWispUrl()` is unavailable.
 * - Ports: guest listeners are host sockets; `expose()` returns a loopback URL
 *   instead of registering a service-worker route.
 * - Streams: `ReadableBytes`/`WritableBytes` provide WHATWG-style readers and
 *   writers supplied by this package.
 */

import { url } from "@kit.ArkTS";
import nativeModule from "libwasmer_sdk_ohos.so";
import type {
  CommandCore,
  OutputCore,
  PackageCore,
  PackageLoadCancellationCore,
  ProcessCore,
  ProgressSink,
  SandboxBuilderCore,
  SandboxCore,
  WasmerCore,
} from "libwasmer_sdk_ohos.so";
import { AbortSignal, WasmerError, WasmerErrorCode } from "./errors";
import {
  MAX_WASM32_SIZE,
  TerminalDimensions,
  callNative,
  callNativeSync,
  createTextDecoder,
  decodeStream,
  decodeText,
  defaultCacheRoot,
  encode,
  escapeShellValue,
  parseNativeError,
  validateInteger,
  validateOutputBytes,
  validateParallelism,
  validateTerminalDimensions,
  validateTimeoutMs,
} from "./internal";

export interface CacheOptions {
  /**
   * Cache root. On HarmonyOS this defaults to the application cache directory
   * under `wasmer/`.
   */
  directory?: string;
  /** Logical cache namespace, mapped to a subdirectory of the cache root. */
  namespace?: string;
  /** Accepted for API compatibility; HarmonyOS always allows writes. */
  readOnly?: boolean;
}

export interface WasmerOptions {
  outputBytes?: number;
  /**
   * Accepted for API compatibility and validated. The native runtime schedules
   * work on the device's CPU parallelism; this value does not resize the pool.
   */
  parallelism?: number;
  cache?: "memory" | false | CacheOptions;
}

export type PackageSource = string | Uint8Array | Package;
export type CommandSelector = string | Package | CommandRef;
export type FileContents = string | Uint8Array;

/** A WASI/WASIX command referencing a named module in its package. */
export interface PackageCommandDefinition {
  module: string;
}

/** Executable content used to create a package without a WEBC archive. */
export interface PackageDefinition {
  modules: Record<string, Uint8Array>;
  commands: Record<string, PackageCommandDefinition>;
  /** Command name; inferred when there is exactly one command. */
  entrypoint?: string;
  /** Bundled files at canonical absolute guest paths, e.g. /data/config.json. */
  files?: Record<string, FileContents>;
}

export interface WispConnectionRequest {
  url?: string;
  error?: Error;
}

export type WispUrlProvider = (request: WispConnectionRequest) => string | Promise<string>;

export type NetworkMode = "disabled" | "host" | "http" | "wisp";

/**
 * Network policy. On HarmonyOS `http` and `wisp` both use host networking;
 * browser peer isolation is not available.
 */
export interface NetworkPolicy {
  mode: NetworkMode;
  /** Browser-only peer isolation; rejected on HarmonyOS when supplied. */
  peers?: Sandbox[];
  /** Browser WISP endpoint; accepted but unused on HarmonyOS. */
  url?: string;
  dnsUrl?: string;
  requestUrl?: WispUrlProvider;
}

export type PackageLoadPhase = "resolving" | "downloading" | "loading" | "ready";

/** Decoded package bytes; cache hits and local sources add zero download bytes. */
export interface DownloadProgress {
  readonly downloadedBytes: number;
  readonly totalBytes: number | null;
  readonly percent: number | null;
}

export interface PackageProgress {
  readonly id: string;
  readonly phase: PackageLoadPhase;
  readonly cached: boolean;
  readonly download: DownloadProgress;
}

/** A snapshot, not a delta. Download completion does not imply load readiness. */
export interface PackageLoadProgress {
  readonly phase: PackageLoadPhase;
  readonly download: DownloadProgress;
  readonly packages: PackageProgress[];
}

export interface PackageLoadOptions {
  /** Short synchronous observer. Exceptions detach it without failing the load. */
  onProgress?: (progress: PackageLoadProgress) => void;
  signal?: AbortSignal;
}

export interface SandboxOptions {
  /** Package acquisition only, before the remaining sandbox setup. */
  onPackageProgress?: (progress: PackageLoadProgress) => void;
  signal?: AbortSignal;
  packages?: PackageSource[];
  files?: Record<string, FileContents>;
  env?: Record<string, string>;
  network?: NetworkPolicy;
  /** The command used by `sandbox.shell()` and `sandbox.sh`. */
  shell?: CommandSelector;
}

export interface Packages {
  /** Create an in-memory package. Module and file bytes are copied. */
  create(definition: PackageDefinition): Promise<Package>;
  /**
   * Resolve a registry package, WEBC bytes, or raw WASI/WASIX bytes.
   * Raw modules must export `_start`; their command and entrypoint are `main`.
   */
  load(source: PackageSource, options?: PackageLoadOptions): Promise<Package>;
  /** Load concurrently, sharing downloads and preserving input order. */
  loadMany(sources: PackageSource[], options?: PackageLoadOptions): Promise<Package[]>;
}

export interface Sandboxes {
  create(options?: SandboxOptions): Promise<Sandbox>;
}

export interface InstallPackageOptions extends PackageLoadOptions {
  /** Select one command exported by this package as the sandbox's shell. */
  asShell?: string;
}

export interface CommandOptions {
  cwd?: string;
  env?: Record<string, string>;
}

export interface RunOptions {
  stdin?: string | Uint8Array;
  timeoutMs?: number;
  outputBytes?: number;
  /** Throw a ProcessExitError when the process is unsuccessful. Defaults to true. */
  check?: boolean;
}

export type OutputMode = "pipe" | "capture" | "discard";

export interface SpawnOptions {
  timeoutMs?: number;
  outputBytes?: number;
  stdin?: "pipe" | "closed";
  stdout?: OutputMode;
  stderr?: OutputMode;
  /** Attach a process-tree terminal. This implies piped stdin/stdout/stderr. */
  terminal?: boolean | TerminalOptions;
}

export interface TerminalOptions {
  columns?: number;
  rows?: number;
}

export type ExitReason = "exited" | "terminated" | "timeout";

export interface FileStat {
  kind: "file" | "directory";
  size: number;
}

export interface DirectoryEntry extends FileStat {
  name: string;
}

/** Managed HTTP host used by browser port exposure. Present for API parity. */
export const DEFAULT_SERVICE_WORKER_ORIGIN: string = "https://default.local.wasmer.site/";

export interface ExposePortOptions {
  /**
   * Browser service-worker origin. Ignored on HarmonyOS, where the guest
   * listener is already reachable through host networking.
   */
  serviceWorker?: string | url.URL;
  /** Time allowed for the guest to begin listening. Defaults to 30 seconds. */
  timeoutMs?: number;
}

export interface PortListenerOptions {
  /** Listener discovery interval. Defaults to 50 milliseconds. */
  intervalMs?: number;
  /** Called when a previously observed listener closes. */
  onClose?: (port: number) => void;
}

export interface BrowserIframeOptions {
  title?: string;
  className?: string;
  sandbox?: string[] | false;
}

const packageCores: WeakMap<Package, PackageCore> = new WeakMap<Package, PackageCore>();

class ClientOptionsJson {
  cacheRoot: string = "";
  ephemeralCache: boolean = false;
  outputBytes: number | undefined = undefined;
}

class CachedPackageDefinition {
  modules: Uint8Array[] = [];
  moduleNames: string[] = [];
  files: Uint8Array[] = [];
  fileNames: string[] = [];
  commands: Record<string, PackageCommandDefinition> = {};
  entrypoint: string | undefined = undefined;
}

interface PackageDefinitionJson {
  commands: Record<string, PackageCommandDefinition>;
  entrypoint?: string;
}

/**
 * A Wasmer client: package acquisition, sandbox creation, and shared cache.
 */
export class Wasmer {
  readonly packages: Packages;
  readonly sandboxes: Sandboxes;
  private readonly options: WasmerOptions;
  private corePromise: Promise<WasmerCore> | undefined = undefined;

  constructor(options: WasmerOptions = {}) {
    this.options = {
      outputBytes: options.outputBytes === undefined ? undefined : validateOutputBytes(options.outputBytes),
      parallelism: options.parallelism === undefined ? undefined : validateParallelism(options.parallelism),
      cache: options.cache,
    };
    this.packages = new PackagesService(
      (sources: PackageSource[], loadOptions: PackageLoadOptions): Promise<Package[]> =>
        this.loadPackagesInternal(sources, loadOptions),
      (definition: PackageDefinition): Promise<Package> => this.createPackageInternal(definition),
    );
    this.sandboxes = new SandboxesService(
      (sandboxOptions: SandboxOptions): Promise<Sandbox> => this.createSandboxInternal(sandboxOptions),
    );
  }

  /** Compatibility factory that reports initialization errors immediately. */
  static async create(options: WasmerOptions = {}): Promise<Wasmer> {
    const wasmer = new Wasmer(options);
    await wasmer.ready();
    return wasmer;
  }

  /** Wait for the native runtime to finish initializing. */
  async ready(): Promise<Wasmer> {
    await this.getCore();
    return this;
  }

  /**
   * Resolve a registry package, WEBC bytes, or raw WASI/WASIX bytes.
   * @deprecated Use `wasmer.packages.load(source)`.
   */
  async loadPackage(source: string | Uint8Array): Promise<Package> {
    return this.packages.load(source);
  }

  /** @deprecated Use `wasmer.sandboxes.create(options)`. */
  async createSandbox(options: SandboxOptions = {}): Promise<Sandbox> {
    return this.sandboxes.create(options);
  }

  /** Close the client and release its runtime resources and cache handles. */
  async close(): Promise<void> {
    if (this.corePromise === undefined) {
      return;
    }
    const client = await this.corePromise;
    await callNative(client.shutdown());
  }

  /** @deprecated Use {@link Wasmer.close}. */
  async shutdown(): Promise<void> {
    await this.close();
  }

  private getCore(): Promise<WasmerCore> {
    if (this.corePromise === undefined) {
      this.corePromise = this.initializeCore();
    }
    return this.corePromise;
  }

  private async initializeCore(): Promise<WasmerCore> {
    const options = new ClientOptionsJson();
    const cache = this.options.cache;
    options.outputBytes = this.options.outputBytes;
    options.cacheRoot = defaultCacheRoot();
    if (cache === false || cache === "memory") {
      options.ephemeralCache = true;
    } else if (cache !== undefined) {
      if (cache.directory !== undefined) {
        options.cacheRoot = cache.directory;
      }
      if (cache.namespace !== undefined && cache.namespace !== "") {
        options.cacheRoot = options.cacheRoot + "/" + cache.namespace;
      }
    }
    return callNativeSync(
      (): WasmerCore => nativeModule.WasmerCore.create(JSON.stringify(options)),
    );
  }

  private async createPackageInternal(definition: PackageDefinition): Promise<Package> {
    let snapshot = new CachedPackageDefinition();
    try {
      const moduleNames = Object.keys(definition.modules);
      for (const name of moduleNames) {
        const bytes = definition.modules[name];
        if (!(bytes instanceof Uint8Array)) {
          throw new TypeError("module and binary file contents must be Uint8Array values");
        }
        snapshot.moduleNames.push(name);
        snapshot.modules.push(new Uint8Array(bytes));
      }
      const commandNames = Object.keys(definition.commands);
      const commands: Record<string, PackageCommandDefinition> = {};
      for (const name of commandNames) {
        const command = definition.commands[name];
        const copy: PackageCommandDefinition = { module: command.module };
        commands[name] = copy;
      }
      snapshot.commands = commands;
      snapshot.entrypoint = definition.entrypoint;
      if (definition.files !== undefined) {
        const fileNames = Object.keys(definition.files);
        for (const path of fileNames) {
          const contents = definition.files[path];
          snapshot.fileNames.push(path);
          if (typeof contents === "string") {
            snapshot.files.push(encode(contents));
          } else if (contents instanceof Uint8Array) {
            snapshot.files.push(new Uint8Array(contents));
          } else {
            throw new TypeError("module and binary file contents must be Uint8Array values");
          }
        }
      }
    } catch (cause) {
      throw new WasmerError(
        `invalid package definition: ${String(cause)}`,
        "INVALID_ARGUMENT",
        cause as Object,
      );
    }
    const client = await this.getCore();
    const definitionJson: PackageDefinitionJson = {
      commands: snapshot.commands,
      entrypoint: snapshot.entrypoint,
    };
    const token = await callNative(
      client.createPackage(
        JSON.stringify(definitionJson),
        snapshot.moduleNames,
        snapshot.modules,
        snapshot.fileNames,
        snapshot.files,
      ),
    );
    return new Package(client.wrapPackage(token));
  }

  private async loadPackagesInternal(
    sources: PackageSource[],
    options: PackageLoadOptions,
  ): Promise<Package[]> {
    options.signal?.throwIfAborted();
    const reused: Package[] = [];
    const snapshots: Array<string | Uint8Array> = [];
    for (const source of sources) {
      if (source instanceof Package) {
        reused.push(source);
      } else if (typeof source === "string") {
        snapshots.push(source);
      } else if (source instanceof Uint8Array) {
        snapshots.push(new Uint8Array(source));
      } else {
        throw new WasmerError(
          "package sources must be specifiers, Uint8Array values, or Package instances",
          "INVALID_PACKAGE_SOURCE",
        );
      }
    }
    const client = await this.getCore();
    options.signal?.throwIfAborted();
    const sink: ProgressSink = callNativeSync((): ProgressSink => new nativeModule.ProgressSink());
    const cancellation: PackageLoadCancellationCore = callNativeSync(
      (): PackageLoadCancellationCore => new nativeModule.PackageLoadCancellationCore(),
    );
    const cancel = (): void => {
      cancellation.cancel();
    };
    options.signal?.addEventListener("abort", cancel, { once: true });
    let observer = options.onProgress;
    let timer: number | undefined = undefined;
    if (observer !== undefined) {
      timer = setInterval((): void => {
        if (observer === undefined || options.signal?.aborted === true) {
          return;
        }
        let events: string[] = [];
        try {
          events = sink.drain();
        } catch (error) {
          return;
        }
        for (const json of events) {
          let progress: PackageLoadProgress;
          try {
            progress = JSON.parse(json) as PackageLoadProgress;
          } catch (error) {
            continue;
          }
          const merged = mergeReusedPackages(progress, reused);
          if (observer !== undefined) {
            try {
              observer(merged);
            } catch (error) {
              observer = undefined;
              console.error("Package progress observer failed", error);
            }
          }
        }
      }, 50);
    }
    try {
      const tokens = await callNative(
        client.loadPackages(snapshots, sink.token, cancellation.token),
      );
      options.signal?.throwIfAborted();
      const loaded: Package[] = [];
      for (const token of tokens) {
        loaded.push(new Package(client.wrapPackage(token)));
      }
      let next = 0;
      const result: Package[] = [];
      for (const source of sources) {
        if (source instanceof Package) {
          result.push(source);
        } else {
          const pkg = loaded[next];
          next += 1;
          if (pkg === undefined) {
            throw new WasmerError(
              "the runtime returned fewer packages than requested",
              "INTERNAL_ERROR",
            );
          }
          result.push(pkg);
        }
      }
      return result;
    } catch (error) {
      options.signal?.throwIfAborted();
      throw parseNativeError(error as Object);
    } finally {
      if (timer !== undefined) {
        clearInterval(timer);
      }
      options.signal?.removeEventListener("abort", cancel);
      try {
        sink.clear();
      } catch (error) {
        // The sink may already be released by the runtime.
      }
    }
  }

  private async createSandboxInternal(options: SandboxOptions): Promise<Sandbox> {
    const client = await this.getCore();
    const sources: PackageSource[] = options.packages ?? [];
    const packages = await this.packages.loadMany(sources, {
      onProgress: options.onPackageProgress,
      signal: options.signal,
    });
    options.signal?.throwIfAborted();
    const builder = client.sandbox();
    for (const pkg of packages) {
      const core = packageCores.get(pkg);
      if (core === undefined) {
        throw new WasmerError("the package handle is no longer valid", "INVALID_ARGUMENT");
      }
      callNativeSync((): void => builder.package(core.token));
    }
    const files = options.files;
    if (files !== undefined) {
      for (const path of Object.keys(files)) {
        const contents = files[path];
        callNativeSync((): void => builder.file(path, encode(contents)));
      }
    }
    const environment = options.env;
    if (environment !== undefined) {
      for (const key of Object.keys(environment)) {
        const value = environment[key];
        callNativeSync((): void => builder.env(key, value));
      }
    }
    const network: NetworkPolicy = options.network ?? { mode: "disabled" };
    if (network.peers !== undefined && network.peers.length > 0) {
      throw new WasmerError(
        "explicit network peers are not available on HarmonyOS; host networking exposes localhost to every sandbox in the app",
        "CAPABILITY_UNAVAILABLE",
      );
    }
    switch (network.mode) {
      case "disabled":
      case "host":
      case "http":
      case "wisp":
        callNativeSync((): void => builder.network(network.mode));
        break;
      default:
        throw new WasmerError(
          `unsupported network mode \`${String((network as NetworkPolicy).mode)}\``,
          "INVALID_ARGUMENT",
        );
    }
    const core = await callNative(builder.start());
    return new Sandbox(this, core, options.shell);
  }
}

function mergeReusedPackages(
  progress: PackageLoadProgress,
  reused: Package[],
): PackageLoadProgress {
  if (reused.length === 0) {
    return progress;
  }
  const seen: Set<string> = new Set<string>();
  const packages: PackageProgress[] = [];
  for (const entry of progress.packages) {
    seen.add(entry.id);
    packages.push(entry);
  }
  const emptyDownload: DownloadProgress = {
    downloadedBytes: 0,
    totalBytes: 0,
    percent: 100,
  };
  for (const pkg of reused) {
    if (!seen.has(pkg.id)) {
      packages.push({
        id: pkg.id,
        phase: "ready",
        cached: true,
        download: emptyDownload,
      });
    }
  }
  return {
    phase: progress.phase,
    download: progress.download,
    packages: packages,
  };
}

class PackagesService implements Packages {
  private readonly loadPackages: (sources: PackageSource[], options: PackageLoadOptions) => Promise<Package[]>;
  private readonly createPackage: (definition: PackageDefinition) => Promise<Package>;

  constructor(
    loadPackages: (sources: PackageSource[], options: PackageLoadOptions) => Promise<Package[]>,
    createPackage: (definition: PackageDefinition) => Promise<Package>,
  ) {
    this.loadPackages = loadPackages;
    this.createPackage = createPackage;
  }

  create(definition: PackageDefinition): Promise<Package> {
    return this.createPackage(definition);
  }

  async load(source: PackageSource, options: PackageLoadOptions = {}): Promise<Package> {
    return (await this.loadMany([source], options))[0];
  }

  loadMany(sources: PackageSource[], options: PackageLoadOptions = {}): Promise<Package[]> {
    return this.loadPackages(sources, options);
  }
}

class SandboxesService implements Sandboxes {
  private readonly createSandbox: (options: SandboxOptions) => Promise<Sandbox>;

  constructor(createSandbox: (options: SandboxOptions) => Promise<Sandbox>) {
    this.createSandbox = createSandbox;
  }

  create(options: SandboxOptions = {}): Promise<Sandbox> {
    return this.createSandbox(options);
  }
}

export class Package {
  private readonly core: PackageCore;

  constructor(core: PackageCore) {
    this.core = core;
    packageCores.set(this, core);
  }

  get id(): string {
    return this.core.id;
  }

  get commands(): string[] {
    return this.core.commands;
  }

  /** The command run when this package is used directly as a selector. */
  get entrypoint(): string | undefined {
    return this.core.entrypoint;
  }

  /**
   * Select a named command from this package, resolving name collisions
   * between installed packages.
   */
  command(name: string): CommandRef {
    if (!this.core.hasCommand(name)) {
      throw new WasmerError(
        `package \`${this.id}\` does not export the command \`${name}\``,
        "COMMAND_NOT_FOUND",
      );
    }
    return new CommandRef(this, name);
  }
}

/** A command explicitly qualified by its package. */
export class CommandRef {
  readonly pkg: Package;
  readonly name: string;

  constructor(pkg: Package, name: string) {
    this.pkg = pkg;
    this.name = name;
  }
}

export type ShellValue = string | number | object | Array<string | number | object>;

/** Runtime network controls for one sandbox. */
export interface SandboxNetwork {
  /** Browser-only WISP endpoint switching; unavailable on HarmonyOS. */
  setWispUrl(url: string): void;
}

class SandboxNetworkService implements SandboxNetwork {
  setWispUrl(url: string): void {
    throw new WasmerError(
      "this sandbox does not use WISP networking; HarmonyOS sandboxes use host networking",
      "CAPABILITY_UNAVAILABLE",
    );
  }
}

export class Sandbox {
  readonly wasmer: Wasmer;
  readonly fs: SandboxFileSystem;
  readonly ports: Ports;
  readonly network: SandboxNetwork;
  private readonly core: SandboxCore;
  private shellSelector: CommandSelector | undefined;

  constructor(wasmer: Wasmer, core: SandboxCore, shell?: CommandSelector) {
    this.wasmer = wasmer;
    this.core = core;
    this.fs = new SandboxFileSystem(core);
    this.ports = new Ports(core);
    this.network = new SandboxNetworkService();
    this.shellSelector = shell;
  }

  command(
    selector: CommandSelector,
    args: string[] | CommandOptions = [],
    options: CommandOptions = {},
  ): Command {
    let argv: string[] = [];
    let settings: CommandOptions = options;
    if (Array.isArray(args)) {
      argv = args.slice();
    } else {
      settings = args as CommandOptions;
    }
    const core = this.core;
    const cwd = settings.cwd;
    const environment = settings.env;
    return new Command((): CommandCore => {
      let command: CommandCore;
      if (selector instanceof CommandRef) {
        const pkgCore = packageCores.get(selector.pkg);
        if (pkgCore === undefined) {
          throw new WasmerError("the package handle is no longer valid", "INVALID_ARGUMENT");
        }
        command = callNativeSync((): CommandCore => core.commandRef(pkgCore.token, selector.name));
      } else if (selector instanceof Package) {
        const pkgCore = packageCores.get(selector);
        if (pkgCore === undefined) {
          throw new WasmerError("the package handle is no longer valid", "INVALID_ARGUMENT");
        }
        command = callNativeSync((): CommandCore => core.commandPackage(pkgCore.token));
      } else {
        command = callNativeSync((): CommandCore => core.command(selector as string));
      }
      callNativeSync((): void => command.args(argv));
      if (cwd !== undefined && cwd !== "") {
        callNativeSync((): void => command.currentDir(cwd));
      }
      if (environment !== undefined) {
        for (const key of Object.keys(environment)) {
          const value = environment[key];
          callNativeSync((): void => command.env(key, value));
        }
      }
      return command;
    });
  }

  /**
   * Build a command that runs `script` through the sandbox's configured shell.
   */
  shell(script: string, options: CommandOptions = {}): Command {
    return this.command(this.requireShell(), ["-c", script], options);
  }

  /** Tagged-template shell with argument escaping. */
  sh(strings: TemplateStringsArray, ...values: ShellValue[]): Command {
    let script = strings[0] ?? "";
    for (let index = 0; index < values.length; index += 1) {
      script += escapeShellValue(values[index]) + (strings[index + 1] ?? "");
    }
    return this.shell(script);
  }

  async installPackage(
    source: PackageSource,
    options: InstallPackageOptions = {},
  ): Promise<Package> {
    options.signal?.throwIfAborted();
    const loaded = await this.wasmer.packages.load(source, options);
    options.signal?.throwIfAborted();
    const pkgCore = packageCores.get(loaded);
    if (pkgCore === undefined) {
      throw new WasmerError("the package handle is no longer valid", "INVALID_ARGUMENT");
    }
    const installed = await callNative(this.core.installPackageRef(pkgCore.token));
    const pkg = new Package(installed);
    if (options.asShell !== undefined) {
      this.shellSelector = pkg.command(options.asShell);
    }
    return pkg;
  }

  async close(): Promise<void> {
    await this.ports.close();
    await callNative(this.core.close());
  }

  private requireShell(): CommandSelector {
    if (this.shellSelector === undefined) {
      throw new WasmerError(
        "no shell is configured for this sandbox; install a shell-providing " +
          "package and select it with `SandboxOptions.shell` or " +
          "`installPackage(source, { asShell })`",
        "SHELL_NOT_CONFIGURED",
      );
    }
    return this.shellSelector;
  }
}

/** Guest port facilities for one sandbox. */
export class Ports {
  private readonly core: SandboxCore;
  private readonly servers: Set<BrowserServer> = new Set<BrowserServer>();
  private readonly watchers: Set<() => void> = new Set<() => void>();

  constructor(core: SandboxCore) {
    this.core = core;
  }

  /**
   * Wait until a guest TCP listener accepts connections on `port`.
   * Uses a real TCP probe under host networking.
   */
  async wait(port: number, options: PortWaitOptions = {}): Promise<void> {
    const validPort = validateInteger("port", port, 1, 65535);
    const timeoutMs = validateTimeoutMs(options.timeoutMs ?? 30000);
    await callNative(this.core.waitForPort(validPort, timeoutMs));
  }

  /**
   * Expose a guest listener through the device's loopback interface.
   * The sandbox must use `host`, `http`, or `wisp` networking.
   */
  async expose(port: number, options: ExposePortOptions = {}): Promise<BrowserServer> {
    const validPort = validateInteger("port", port, 1, 65535);
    const timeoutMs = validateTimeoutMs(options.timeoutMs ?? 30000);
    await this.wait(validPort, { timeoutMs: timeoutMs });
    const server = new BrowserServer("http://127.0.0.1:" + validPort + "/");
    this.servers.add(server);
    return server;
  }

  /**
   * Observe guest TCP listeners. Existing listeners are delivered immediately.
   * A port is delivered again if its listener closes and is rebound.
   */
  onListen(
    listener: (port: number) => void,
    options: PortListenerOptions = {},
  ): () => void {
    const intervalMs = validateInteger(
      "intervalMs",
      options.intervalMs ?? 50,
      10,
      60000,
    );
    const observed: Set<number> = new Set<number>();
    let timer: number | undefined = undefined;
    let active = true;
    const poll = (): void => {
      if (!active) {
        return;
      }
      let current: number[] = [];
      try {
        current = this.core.listeningPorts();
      } catch (error) {
        stop();
        setTimeout((): void => {
          throw parseNativeError(error);
        }, 0);
        return;
      }
      const currentSet: Set<number> = new Set<number>(current);
      for (const port of currentSet) {
        if (!observed.has(port)) {
          listener(port);
        }
      }
      for (const port of observed) {
        if (!currentSet.has(port)) {
          observed.delete(port);
          options.onClose?.(port);
        }
      }
      for (const port of currentSet) {
        observed.add(port);
      }
      timer = setTimeout(poll, intervalMs);
    };
    const stop = (): void => {
      if (!active) {
        return;
      }
      active = false;
      if (timer !== undefined) {
        clearTimeout(timer);
      }
      this.watchers.delete(stop);
    };
    this.watchers.add(stop);
    poll();
    return stop;
  }

  /** Close every exposed route owned by this sandbox. */
  async close(): Promise<void> {
    for (const stop of this.watchers) {
      stop();
    }
    for (const server of this.servers) {
      await server.close();
    }
    this.servers.clear();
  }
}

export interface PortWaitOptions {
  timeoutMs?: number;
}

/** A loopback route to one HTTP listener inside a HarmonyOS sandbox. */
export class BrowserServer {
  readonly url: url.URL;
  private closed: boolean = false;

  constructor(href: string) {
    this.url = new url.URL(href);
  }

  /** ArkUI embeds guest pages with the `Web` component on HarmonyOS. */
  createIframe(options: BrowserIframeOptions = {}): Object {
    throw new WasmerError(
      "createIframe() is only available in a browser; use the Web component with `server.url.href` on HarmonyOS",
      "CAPABILITY_UNAVAILABLE",
    );
  }

  async close(): Promise<void> {
    this.closed = true;
  }
}

/**
 * A reusable, immutable execution description. Each `run()` or `spawn()`
 * starts an independent process.
 */
export class Command {
  private readonly build: () => CommandCore;

  constructor(build: () => CommandCore) {
    this.build = build;
  }

  async run(options: RunOptions = {}): Promise<Output> {
    const timeoutMs = options.timeoutMs === undefined ? undefined : validateTimeoutMs(options.timeoutMs);
    const outputBytes = options.outputBytes === undefined ? undefined : validateOutputBytes(options.outputBytes);
    const core = callNativeSync(this.build);
    if (timeoutMs !== undefined) {
      callNativeSync((): void => core.timeoutMs(timeoutMs));
    }
    if (outputBytes !== undefined) {
      callNativeSync((): void => core.outputBytes(outputBytes));
    }
    if (options.stdin !== undefined) {
      callNativeSync((): void => core.input(encode(options.stdin!)));
    }
    const output = Output.fromCore(await callNative(core.run()));
    if (options.check !== false && !output.ok) {
      throw new ProcessExitError(output);
    }
    return output;
  }

  async spawn(options: SpawnOptions = {}): Promise<Process> {
    const timeoutMs = options.timeoutMs === undefined ? undefined : validateTimeoutMs(options.timeoutMs);
    const outputBytes = options.outputBytes === undefined ? undefined : validateOutputBytes(options.outputBytes);
    const terminal = options.terminal;
    const stdin = terminal !== undefined && terminal !== false ? "pipe" : (options.stdin ?? "closed");
    const stdout = terminal !== undefined && terminal !== false ? "pipe" : (options.stdout ?? "pipe");
    const stderr = terminal !== undefined && terminal !== false ? "pipe" : (options.stderr ?? "pipe");
    const dimensions = validateTerminalDimensions(
      terminal,
      typeof terminal === "object" ? terminal.columns : undefined,
      typeof terminal === "object" ? terminal.rows : undefined,
    );
    const core = callNativeSync(this.build);
    if (timeoutMs !== undefined) {
      callNativeSync((): void => core.timeoutMs(timeoutMs));
    }
    if (outputBytes !== undefined) {
      callNativeSync((): void => core.outputBytes(outputBytes));
    }
    if (dimensions !== undefined) {
      callNativeSync((): void => core.terminal(dimensions.columns, dimensions.rows));
    }
    callNativeSync((): void => core.stdinMode(stdin));
    callNativeSync((): void => core.stdoutMode(stdout));
    callNativeSync((): void => core.stderrMode(stderr));
    const process = await callNative(core.spawn());
    return new Process(process, {
      stdin: stdin === "pipe",
      stdout: stdout === "pipe",
      stderr: stderr === "pipe",
    });
  }
}

export class CapturedOutput {
  readonly bytes: Uint8Array;
  readonly truncated: boolean;

  constructor(bytes: Uint8Array, truncated: boolean) {
    this.bytes = bytes;
    this.truncated = truncated;
  }

  text(): string {
    return decodeText(this.bytes);
  }
}

export class Output {
  readonly exitCode: number;
  readonly reason: ExitReason;
  readonly stdout: CapturedOutput;
  readonly stderr: CapturedOutput;

  constructor(
    exitCode: number,
    reason: ExitReason,
    stdout: CapturedOutput,
    stderr: CapturedOutput,
  ) {
    this.exitCode = exitCode;
    this.reason = reason;
    this.stdout = stdout;
    this.stderr = stderr;
  }

  static fromCore(core: OutputCore): Output {
    return new Output(
      core.exitCode,
      core.reason as ExitReason,
      new CapturedOutput(core.stdout, core.stdoutTruncated),
      new CapturedOutput(core.stderr, core.stderrTruncated),
    );
  }

  /** True only when the guest exited on its own with a zero status. */
  get ok(): boolean {
    return this.reason === "exited" && this.exitCode === 0;
  }

  /** Check success and decode stdout. */
  text(): string {
    this.check();
    return this.stdout.text();
  }

  check(): Output {
    if (!this.ok) {
      throw new ProcessExitError(this);
    }
    return this;
  }
}

const STDERR_EXCERPT_BYTES: number = 512;

function describeExit(output: Output): string {
  let base: string;
  switch (output.reason) {
    case "terminated":
      base = "process was terminated before completing";
      break;
    case "timeout":
      base = "process timed out";
      break;
    default:
      base = `process exited unsuccessfully with status ${output.exitCode}`;
  }
  const stderr = output.stderr.bytes;
  const start = Math.max(0, stderr.length - STDERR_EXCERPT_BYTES);
  const excerpt = decodeText(stderr.subarray(start)).trim();
  if (excerpt === "") {
    return base;
  }
  return `${base}\nstderr: ${start > 0 ? "…" : ""}${excerpt}`;
}

/** A checked command completed unsuccessfully; `output` holds the details. */
export class ProcessExitError extends Error {
  readonly output: Output;

  constructor(output: Output) {
    super(describeExit(output));
    this.name = "ProcessExitError";
    this.output = output;
  }

  get code(): "PROCESS_EXITED" | "PROCESS_TERMINATED" | "TIMEOUT" {
    switch (this.output.reason) {
      case "terminated":
        return "PROCESS_TERMINATED";
      case "timeout":
        return "TIMEOUT";
      default:
        return "PROCESS_EXITED";
    }
  }
}

export interface ProcessStreams {
  stdin: boolean;
  stdout: boolean;
  stderr: boolean;
}

export class Process {
  readonly stdin: WritableBytes | null;
  readonly stdout: ReadableBytes | null;
  readonly stderr: ReadableBytes | null;
  private readonly core: ProcessCore;

  constructor(core: ProcessCore, streams: ProcessStreams) {
    this.core = core;
    this.stdin = streams.stdin ? new WritableBytes(core) : null;
    this.stdout = streams.stdout
      ? new ReadableBytes((size: number): Promise<Uint8Array | null> => core.readStdout(size))
      : null;
    this.stderr = streams.stderr
      ? new ReadableBytes((size: number): Promise<Uint8Array | null> => core.readStderr(size))
      : null;
  }

  get id(): number {
    return this.core.id;
  }

  async wait(options: ProcessWaitOptions = {}): Promise<Output> {
    const output = Output.fromCore(await callNative(this.core.wait()));
    if (options.check === true && !output.ok) {
      throw new ProcessExitError(output);
    }
    return output;
  }

  /** Ask the guest to exit; escalate to a forced kill after the grace period. */
  async terminate(options: TerminateOptions = {}): Promise<void> {
    const gracePeriodMs = validateTimeoutMs(options.gracePeriodMs ?? 1000, "gracePeriodMs");
    await callNative(this.core.terminate(gracePeriodMs));
  }

  /** Immediate forced termination. */
  async kill(): Promise<void> {
    callNativeSync((): void => this.core.kill());
  }

  /** Resize the attached terminal. */
  resizeTerminal(columns: number, rows: number): void {
    callNativeSync((): void => this.core.resizeTerminal(
      validateInteger("terminal.columns", columns, 1, 4294967295),
      validateInteger("terminal.rows", rows, 1, 4294967295),
    ));
  }
}

export interface ProcessWaitOptions {
  check?: boolean;
}

export interface TerminateOptions {
  gracePeriodMs?: number;
}

/** Writable guest stdin. Closing it sends EOF; it does not kill the process. */
export class WritableBytes {
  private readonly core: ProcessCore;

  constructor(core: ProcessCore) {
    this.core = core;
  }

  async write(data: string | Uint8Array): Promise<void> {
    await callNative(this.core.writeStdin(encode(data)));
  }

  async close(): Promise<void> {
    await callNative(this.core.closeStdin());
  }

  toWritableStream(): WritableStream {
    return new WritableStream(this);
  }
}

export class WritableStream {
  private readonly sink: WritableBytes;

  constructor(sink: WritableBytes) {
    this.sink = sink;
  }

  getWriter(): WritableStreamDefaultWriter {
    return new WritableStreamDefaultWriter(this.sink);
  }
}

export class WritableStreamDefaultWriter {
  private readonly sink: WritableBytes;

  constructor(sink: WritableBytes) {
    this.sink = sink;
  }

  async write(chunk: Uint8Array): Promise<void> {
    await this.sink.write(chunk);
  }

  async close(): Promise<void> {
    await this.sink.close();
  }

  async abort(): Promise<void> {
    await this.sink.close();
  }

  releaseLock(): void {
  }
}

/**
 * A readable byte stream. ArkTS has no `Symbol.asyncIterator`, so callers pull
 * chunks with `next()` or `readAll()` instead of `for await`.
 */
export class ReadableBytes {
  private readonly readFn: (size: number) => Promise<Uint8Array | null>;

  constructor(read: (size: number) => Promise<Uint8Array | null>) {
    this.readFn = read;
  }

  /** Pull the next chunk; `done` once the stream reaches EOF. */
  async next(): Promise<ReadableStreamReadResult> {
    const chunk = await callNative(this.readFn(64 * 1024));
    if (chunk === null) {
      return { done: true };
    }
    return { done: false, value: chunk };
  }

  iterator(): ReadableBytesIterator {
    return new ReadableBytesIterator(this.readFn);
  }

  /** Incrementally decoded lines; never assumes one chunk is one line. */
  lines(): Lines {
    return new Lines(this.readFn);
  }

  /** Read until EOF into a single buffer. */
  async readAll(): Promise<Uint8Array> {
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const chunk = await callNative(this.readFn(64 * 1024));
      if (chunk === null) {
        break;
      }
      chunks.push(chunk);
      total += chunk.length;
    }
    const result = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }

  toReadableStream(): ReadableStream {
    return new ReadableStream(this);
  }
}

export class ReadableBytesIterator {
  private readonly readFn: (size: number) => Promise<Uint8Array | null>;
  private done: boolean = false;

  constructor(read: (size: number) => Promise<Uint8Array | null>) {
    this.readFn = read;
  }

  async next(): Promise<ReadableStreamReadResult> {
    if (this.done) {
      return { done: true };
    }
    const chunk = await callNative(this.readFn(64 * 1024));
    if (chunk === null) {
      this.done = true;
      return { done: true };
    }
    return { done: false, value: chunk };
  }
}

export interface LineReadResult {
  done: boolean;
  value?: string;
}

/** Pull-based line reader; equivalent to upstream's `for await (... of lines())`. */
export class Lines {
  private readonly readFn: (size: number) => Promise<Uint8Array | null>;
  private readonly decoder = createTextDecoder();
  private pending: string = "";
  private queue: string[] = [];
  private done: boolean = false;

  constructor(read: (size: number) => Promise<Uint8Array | null>) {
    this.readFn = read;
  }

  async next(): Promise<LineReadResult> {
    for (;;) {
      if (this.queue.length > 0) {
        const line = this.queue[0];
        this.queue = this.queue.slice(1);
        return { done: false, value: line };
      }
      if (this.done) {
        return { done: true };
      }
      const chunk = await callNative(this.readFn(64 * 1024));
      if (chunk === null) {
        this.pending += decodeStream(this.decoder, new Uint8Array(0), false);
        this.done = true;
        if (this.pending !== "") {
          const line = this.pending;
          this.pending = "";
          return { done: false, value: line };
        }
        return { done: true };
      }
      this.pending += decodeStream(this.decoder, chunk, true);
      for (;;) {
        const newline = this.pending.indexOf("\n");
        if (newline < 0) {
          break;
        }
        let line = this.pending.substring(0, newline);
        if (line.endsWith("\r")) {
          line = line.substring(0, line.length - 1);
        }
        this.pending = this.pending.substring(newline + 1);
        this.queue.push(line);
      }
    }
  }

  /** Collect every remaining line. */
  async readAll(): Promise<string[]> {
    const lines: string[] = [];
    for (;;) {
      const result = await this.next();
      if (result.done) {
        return lines;
      }
      lines.push(result.value as string);
    }
  }
}

export class ReadableStream {
  private readonly source: ReadableBytes;

  constructor(source: ReadableBytes) {
    this.source = source;
  }

  getReader(): ReadableStreamDefaultReader {
    return new ReadableStreamDefaultReader(this.source);
  }

  async cancel(): Promise<void> {
  }
}

export interface ReadableStreamReadResult {
  done: boolean;
  value?: Uint8Array;
}

export class ReadableStreamDefaultReader {
  private readonly source: ReadableBytes;

  constructor(source: ReadableBytes) {
    this.source = source;
  }

  async read(): Promise<ReadableStreamReadResult> {
    return this.source.next();
  }

  releaseLock(): void {
  }

  async cancel(): Promise<void> {
  }
}

export class SandboxFileSystem {
  private readonly core: SandboxCore;

  constructor(core: SandboxCore) {
    this.core = core;
  }

  async writeFile(path: string, contents: FileContents): Promise<void> {
    await callNative(this.core.writeFile(path, encode(contents)));
  }

  async writeText(path: string, text: string): Promise<void> {
    await this.writeFile(path, text);
  }

  async readFile(path: string): Promise<Uint8Array> {
    return callNative(this.core.readFile(path));
  }

  async readText(path: string): Promise<string> {
    return decodeText(await this.readFile(path));
  }

  async mkdir(path: string, options: MkdirOptions = {}): Promise<void> {
    await callNativeSync((): void => this.core.mkdir(path, options.recursive ?? false));
  }

  async readDir(path: string): Promise<DirectoryEntry[]> {
    const json = await callNativeSync((): string => this.core.readDir(path));
    return JSON.parse(json) as DirectoryEntry[];
  }

  async stat(path: string): Promise<FileStat> {
    const json = await callNativeSync((): string => this.core.stat(path));
    return JSON.parse(json) as FileStat;
  }

  async remove(path: string, options: RemoveOptions = {}): Promise<void> {
    await callNativeSync((): void => this.core.remove(path, options.recursive ?? false));
  }

  async rename(from: string, to: string): Promise<void> {
    await callNative(this.core.rename(from, to));
  }
}

export interface MkdirOptions {
  recursive?: boolean;
}

export interface RemoveOptions {
  recursive?: boolean;
}

