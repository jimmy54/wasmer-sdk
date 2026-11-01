export declare class ProgressSink {
  constructor();
  readonly token: number;
  drain(): string[];
  clear(): void;
}

export declare class PackageLoadCancellationCore {
  constructor();
  readonly token: number;
  cancel(): void;
}

export declare class PackageCore {
  readonly id: string;
  readonly commands: string[];
  readonly entrypoint: string | undefined;
  readonly token: number;
  hasCommand(name: string): boolean;
}

export declare class SandboxBuilderCore {
  package(packageToken: number): void;
  file(path: string, bytes: Uint8Array): void;
  env(key: string, value: string): void;
  network(mode: string): void;
  start(): Promise<SandboxCore>;
}

export declare class SandboxCore {
  command(name: string): CommandCore;
  commandPackage(packageToken: number): CommandCore;
  commandRef(packageToken: number, name: string): CommandCore;
  installPackage(specifier: string): Promise<PackageCore>;
  installPackageBytes(bytes: Uint8Array): Promise<PackageCore>;
  installPackageRef(packageToken: number): Promise<PackageCore>;
  writeFile(path: string, bytes: Uint8Array): Promise<void>;
  readFile(path: string): Promise<Uint8Array>;
  mkdir(path: string, recursive: boolean): void;
  readDir(path: string): string;
  stat(path: string): string;
  remove(path: string, recursive: boolean): void;
  rename(from: string, to: string): Promise<void>;
  waitForPort(port: number, timeoutMs: number): Promise<void>;
  listeningPorts(): number[];
  isPortListening(port: number): boolean;
  close(): Promise<void>;
}

export declare class CommandCore {
  args(args: string[]): void;
  env(key: string, value: string): void;
  currentDir(path: string): void;
  input(bytes: Uint8Array): void;
  outputBytes(bytes: number): void;
  timeoutMs(milliseconds: number): void;
  terminal(columns: number, rows: number): void;
  stdinMode(mode: string): void;
  stdoutMode(mode: string): void;
  stderrMode(mode: string): void;
  run(): Promise<OutputCore>;
  spawn(): Promise<ProcessCore>;
}

export declare class OutputCore {
  readonly exitCode: number;
  readonly ok: boolean;
  readonly reason: string;
  readonly stdout: Uint8Array;
  readonly stderr: Uint8Array;
  readonly stdoutTruncated: boolean;
  readonly stderrTruncated: boolean;
}

export declare class ProcessCore {
  readonly id: number;
  writeStdin(bytes: Uint8Array): Promise<void>;
  closeStdin(): Promise<void>;
  readStdout(maxBytes: number): Promise<Uint8Array | null>;
  readStderr(maxBytes: number): Promise<Uint8Array | null>;
  wait(): Promise<OutputCore>;
  terminate(graceMs: number): Promise<void>;
  kill(): void;
  resizeTerminal(columns: number, rows: number): void;
}

export declare class WasmerCore {
  static create(optionsJson: string): WasmerCore;
  createPackage(
    definitionJson: string,
    moduleNames: string[],
    moduleBytes: Uint8Array[],
    fileNames: string[],
    fileBytes: Uint8Array[]
  ): Promise<number>;
  loadPackage(specifier: string): Promise<number>;
  loadPackageBytes(bytes: Uint8Array): Promise<number>;
  loadPackages(
    sources: Array<string | Uint8Array>,
    sinkToken?: number,
    cancellationToken?: number
  ): Promise<number[]>;
  wrapPackage(token: number): PackageCore;
  sandbox(): SandboxBuilderCore;
  shutdown(): Promise<void>;
}

declare const nativeModule: {
  ProgressSink: typeof ProgressSink;
  PackageLoadCancellationCore: typeof PackageLoadCancellationCore;
  WasmerCore: typeof WasmerCore;
};

export default nativeModule;
