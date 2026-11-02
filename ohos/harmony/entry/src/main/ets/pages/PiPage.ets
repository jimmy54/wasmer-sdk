import { common } from "@kit.AbilityKit";
import {
  FileContents,
  NetworkPolicy,
  Package,
  PackageLoadOptions,
  PackageLoadProgress,
  Output,
  Process,
  ProcessExitError,
  Sandbox,
  SandboxOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

interface ModelCost {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

interface ModelEntry {
  id: string;
  name: string;
  reasoning: boolean;
  input: string[];
  contextWindow: number;
  maxTokens: number;
  cost: ModelCost;
}

interface ProviderEntry {
  baseUrl: string;
  api: string;
  models: ModelEntry[];
}

interface AuthEntry {
  type: string;
  key: string;
}

interface ModelsFile {
  providers: Record<string, ProviderEntry>;
}

@Entry
@Component
struct PiPage {
  @State status: string = "Ready";
  @State output: string = "";
  @State busy: boolean = false;

  private async run(command: string, args: string[]): Promise<void> {
    this.busy = true;
    this.status = "Loading wasmer/pi@0.87.1";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    try {
      const loadOptions: PackageLoadOptions = {
        onProgress: (progress: PackageLoadProgress): void => {
          if (progress.download.percent !== null) {
            this.status = "Downloading Pi: " +
              Math.floor(progress.download.percent) + "%";
          } else {
            this.status = "Loading Pi: " + progress.phase;
          }
        },
      };
      const pkg = await wasmer.packages.load("wasmer/pi@=0.87.1", loadOptions);
      this.status = "Starting " + pkg.id;
      const env: Record<string, string> = {};
      env["HOME"] = "/workspace";
      env["PI_CODING_AGENT_DIR"] = "/workspace";
      env["PATH"] = "/bin:/usr/bin";
      const options: SandboxOptions = { packages: [pkg], env: env };
      sandbox = await wasmer.sandboxes.create(options);
      const result: Output = await sandbox.command(command, args).run();
      this.output = result.stdout.text() + result.stderr.text();
      this.status = "Exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stdout.text() + error.output.stderr.text();
        this.status = error.message;
      } else if (error instanceof WasmerError) {
        this.output = error.message;
        this.status = error.code;
      } else if (error instanceof Error) {
        this.output = error.message;
        this.status = "Error";
      }
    } finally {
      if (sandbox !== null) {
        await sandbox.close();
      }
      await wasmer.close();
      this.busy = false;
    }
  }

  private async runQuickJs(args: string[]): Promise<void> {
    this.busy = true;
    this.status = "Loading wasmer/pi + edgejs-quickjs";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    try {
      const loadOptions: PackageLoadOptions = {
        onProgress: (progress: PackageLoadProgress): void => {
          if (progress.download.percent !== null) {
            this.status = "Downloading: " +
              Math.floor(progress.download.percent) + "%";
          } else {
            this.status = "Loading: " + progress.phase;
          }
        },
      };
      const piPkg: Package = await wasmer.packages.load("wasmer/pi@=0.87.1", loadOptions);
      const quickjsPkg: Package =
        await wasmer.packages.load("wasmer/edgejs-quickjs@=0.2.5", loadOptions);
      this.status = "Starting " + piPkg.id;
      const env: Record<string, string> = {};
      env["HOME"] = "/workspace";
      env["PI_CODING_AGENT_DIR"] = "/workspace";
      env["PATH"] = "/bin:/usr/bin";
      const options: SandboxOptions = { packages: [piPkg, quickjsPkg], env: env };
      sandbox = await wasmer.sandboxes.create(options);
      const result: Output = await sandbox
        .command(quickjsPkg.command("edge"), ["/opt/pi/dist/bundle/cli.js"].concat(args))
        .run({ timeoutMs: 120000 });
      this.output = result.stdout.text() + result.stderr.text();
      this.status = "Exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stdout.text() + error.output.stderr.text();
        this.status = error.message;
      } else if (error instanceof WasmerError) {
        this.output = error.message;
        this.status = error.code;
      } else if (error instanceof Error) {
        this.output = error.message;
        this.status = "Error";
      }
    } finally {
      if (sandbox !== null) {
        await sandbox.close();
      }
      await wasmer.close();
      this.busy = false;
    }
  }

  private async runAgent(): Promise<void> {
    this.busy = true;
    this.status = "Loading Pi components";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    let server: Process | null = null;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const serverScript = await context.resourceManager.getRawFileContent("model-server.mjs");
      const fetchFix = await context.resourceManager.getRawFileContent("pi-fetch-fix.mjs");
      const loadOptions: PackageLoadOptions = {
        onProgress: (progress: PackageLoadProgress): void => {
          if (progress.download.percent !== null) {
            this.status = "Downloading: " +
              Math.floor(progress.download.percent) + "%";
          } else {
            this.status = "Loading: " + progress.phase;
          }
        },
      };
      const piPkg: Package = await wasmer.packages.load("wasmer/pi@=0.87.1", loadOptions);
      const quickjsPkg: Package =
        await wasmer.packages.load("wasmer/edgejs-quickjs@=0.2.5", loadOptions);
      const files: Record<string, FileContents> = {};
      files["model-server.mjs"] = new Uint8Array(serverScript);
      files["pi-fetch-fix.mjs"] = new Uint8Array(fetchFix);
      files["hello.js"] = "console.log('Hello, Wasmer!');\n";
      files["probe.mjs"] =
        "const r = await fetch('http://127.0.0.1:8787/health');\n" +
        "console.log('PROBE', r.status, (await r.text()).trim());\n" +
        "const p = await fetch('http://127.0.0.1:8787/probe', {\n" +
        "  method: 'POST',\n" +
        "  headers: { 'content-type': 'application/json', authorization: 'Bearer test-only-not-a-secret' },\n" +
        "  body: JSON.stringify({ stream: true, messages: [], tools: [] }),\n" +
        "});\n" +
        "console.log('POST', p.status, p.body === null ? 'null-body' : 'body');\n" +
        "console.log('TEXT', (await p.text()).slice(0, 80).replace(/\\n/g, '|'));\n";
      const modelEntry: ModelEntry = {
        id: "test",
        name: "Wasmer test",
        reasoning: false,
        input: ["text"],
        contextWindow: 32000,
        maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      };
      const provider: ProviderEntry = {
        baseUrl: "http://127.0.0.1:8787/v1",
        api: "openai-completions",
        models: [modelEntry],
      };
      const providers: Record<string, ProviderEntry> = {};
      providers["wasmer-test"] = provider;
      const modelsFile: ModelsFile = { providers: providers };
      files["models.json"] = JSON.stringify(modelsFile);
      const authEntry: AuthEntry = { type: "api_key", key: "test-only-not-a-secret" };
      const auth: Record<string, AuthEntry> = {};
      auth["wasmer-test"] = authEntry;
      files["auth.json"] = JSON.stringify(auth);
      const env: Record<string, string> = {};
      env["HOME"] = "/workspace";
      env["PI_CODING_AGENT_DIR"] = "/workspace";
      env["PATH"] = "/bin:/usr/bin";
      const network: NetworkPolicy = { mode: "host" };
      const options: SandboxOptions = {
        packages: [piPkg, quickjsPkg],
        env: env,
        files: files,
        network: network,
      };
      sandbox = await wasmer.sandboxes.create(options);
      this.status = "Starting local model fixture";
      const edge = quickjsPkg.command("edge");
      server = await sandbox.command(edge, ["/workspace/model-server.mjs"]).spawn();
      await sandbox.ports.expose(8787, { timeoutMs: 60000 });
      const probe: Output = await sandbox
        .command(edge, ["/workspace/probe.mjs"])
        .run({ timeoutMs: 30000, check: false });
      this.status = "Running Pi agent turn";
      const args: string[] = [
        "/opt/pi/dist/bundle/cli.js",
        "--offline",
        "--verbose",
        "--provider", "wasmer-test",
        "--model", "test",
        "--thinking", "off",
        "--tools", "read,write,edit,bash,grep,find,ls",
        "--extension", "/workspace/pi-fetch-fix.mjs",
        "-p", "Exercise the workspace tools.",
      ];
      const result: Output = await sandbox.command(edge, args).run({ timeoutMs: 180000, check: false });
      let resultFile: string = "(not created)";
      try {
        resultFile = await sandbox.fs.readText("pi-test/result.txt");
      } catch (_) {
        resultFile = "(not created)";
      }
      let requestsLog: string = "(none)";
      try {
        requestsLog = await sandbox.fs.readText("model-requests.log");
      } catch (_) {
        requestsLog = "(none)";
      }
      this.output = "probe: " + probe.stdout.text() + probe.stderr.text() +
        "\nrequests:\n" + requestsLog +
        "\n" + result.stdout.text() + result.stderr.text() +
        "\npi-test/result.txt: " + resultFile;
      this.status = "Agent exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stdout.text() + error.output.stderr.text();
        this.status = error.message;
      } else if (error instanceof WasmerError) {
        this.output = error.message;
        this.status = error.code;
      } else if (error instanceof Error) {
        this.output = error.message;
        this.status = "Error";
      }
    } finally {
      if (server !== null) {
        await server.terminate({ gracePeriodMs: 1000 });
      }
      if (sandbox !== null) {
        await sandbox.close();
      }
      await wasmer.close();
      this.busy = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Text("Pi coding agent")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor("#E6E9F0")
      Text("wasmer/pi@0.87.1 — upstream agent on Edge.js")
        .fontSize(13)
        .fontColor("#8A93A6")
      Row({ space: 10 }) {
        Button(this.busy ? "Running…" : "pi (Edge.js 0.2.4)")
          .enabled(!this.busy)
          .onClick(() => {
            this.run("pi", ["--version"]);
          })
        Button("pi --version (QuickJS)")
          .enabled(!this.busy)
          .onClick(() => {
            this.runQuickJs(["--version"]);
          })
        Button("pi --help (QuickJS)")
          .enabled(!this.busy)
          .onClick(() => {
            this.runQuickJs(["--help"]);
          })
      }
      .width("100%")
      Row({ space: 10 }) {
        Button(this.busy ? "Running…" : "Run agent turn (local model)")
          .enabled(!this.busy)
          .onClick(() => {
            this.runAgent();
          })
      }
      .width("100%")
      Text(this.status)
        .fontSize(13)
        .fontColor("#7FD1AE")
      Scroll() {
        Text(this.output === "" ? "Output will appear here." : this.output)
          .fontSize(13)
          .fontColor("#C9D1E0")
          .fontFamily("monospace")
          .width("100%")
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width("100%")
      .align(Alignment.TopStart)
      .padding(12)
      .backgroundColor("#151922")
      .borderRadius(12)
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .alignItems(HorizontalAlign.Start)
    .backgroundColor("#0B0D12")
  }
}
