import { common } from "@kit.AbilityKit";
import { router } from "@kit.ArkUI";
import {
  Wasmer,
  Sandbox,
  Output,
  WasmerError,
  ProcessExitError,
  PackageDefinition,
  PackageCommandDefinition,
  NetworkPolicy,
  SandboxOptions,
  PackageLoadOptions,
  PackageLoadProgress,
} from "@wasmer/harmony";

@Entry
@Component
struct Index {
  @State output: string = "";
  @State status: string = "Ready";
  @State busy: boolean = false;
  private wasmer: Wasmer | null = null;
  private sandbox: Sandbox | null = null;

  aboutToDisappear(): void {
    this.closeSandbox();
  }

  private async client(): Promise<Wasmer> {
    if (this.wasmer === null) {
      this.wasmer = await Wasmer.create();
    }
    return this.wasmer;
  }

  private async closeSandbox(): Promise<void> {
    const sandbox = this.sandbox;
    this.sandbox = null;
    if (sandbox !== null) {
      await sandbox.close();
    }
  }

  private async runHello(): Promise<void> {
    this.busy = true;
    this.status = "Reading hello.wasm";
    this.output = "";
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const bytes = await context.resourceManager.getRawFileContent("demo.wasm");
      const wasmer = await this.client();
      this.status = "Creating package";
      const modules: Record<string, Uint8Array> = {};
      modules["demo.wasm"] = new Uint8Array(bytes);
      const commands: Record<string, PackageCommandDefinition> = {};
      const main: PackageCommandDefinition = { module: "demo.wasm" };
      commands["main"] = main;
      const definition: PackageDefinition = {
        modules: modules,
        commands: commands,
        entrypoint: "main",
      };
      const pkg = await wasmer.packages.create(definition);
      this.status = "Starting sandbox";
      await this.closeSandbox();
      const env: Record<string, string> = {};
      env["GREETING"] = "HarmonyOS";
      const network: NetworkPolicy = { mode: "disabled" };
      const sandboxOptions: SandboxOptions = {
        packages: [pkg],
        env: env,
        network: network,
      };
      const sandbox = await wasmer.sandboxes.create(sandboxOptions);
      this.sandbox = sandbox;
      this.status = "Running " + pkg.id;
      const result: Output = await sandbox.command(pkg, ["--name", "HarmonyOS"]).run({
        stdin: "ping from ArkTS\n",
      });
      this.output = result.stdout.text() + result.stderr.text();
      this.status = "Exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stdout.text() + error.output.stderr.text();
        this.status = error.message;
      } else if (error instanceof WasmerError) {
        this.status = error.code;
        this.output = error.message;
      } else if (error instanceof Error) {
        this.status = "Error";
        this.output = error.message;
      } else {
        this.status = "Error";
        this.output = String(error);
      }
    } finally {
      this.busy = false;
    }
  }

  private async runNode(): Promise<void> {
    this.busy = true;
    this.status = "Loading wasmer/edgejs-quickjs@0.1.0";
    this.output = "";
    try {
      const wasmer = await this.client();
      const loadOptions: PackageLoadOptions = {
        onProgress: (progress: PackageLoadProgress): void => {
          if (progress.download.percent !== null) {
            this.status = "Downloading Node.js: " +
              Math.floor(progress.download.percent) + "%";
          } else {
            this.status = "Loading Node.js: " + progress.phase;
          }
        },
      };
      const pkg = await wasmer.packages.load("wasmer/edgejs-quickjs@0.1.0", loadOptions);
      await this.closeSandbox();
      const files: Record<string, string> = {};
      files["index.js"] =
        "console.log('Hello from Node.js on HarmonyOS!');\n" +
        "console.log('argv:', JSON.stringify(process.argv.slice(1)));\n" +
        "console.log('platform:', process.platform, 'arch:', process.arch);\n" +
        "const squares = [1, 2, 3, 4, 5].map((n) => n * n);\n" +
        "console.log('squares:', squares.join(', '));\n" +
        "console.log('sum:', squares.reduce((a, b) => a + b, 0));\n";
      const network: NetworkPolicy = { mode: "disabled" };
      const sandboxOptions: SandboxOptions = {
        packages: [pkg],
        files: files,
        network: network,
      };
      const sandbox = await wasmer.sandboxes.create(sandboxOptions);
      this.sandbox = sandbox;
      this.status = "Running edge /workspace/index.js";
      const result: Output = await sandbox
        .command("edge", ["/workspace/index.js"])
        .run();
      this.output = result.stdout.text() + result.stderr.text();
      this.status = "Node exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stdout.text() + error.output.stderr.text();
        this.status = error.message;
      } else if (error instanceof WasmerError) {
        this.status = error.code;
        this.output = error.message;
      } else if (error instanceof Error) {
        this.status = "Error";
        this.output = error.message;
      } else {
        this.status = "Error";
        this.output = String(error);
      }
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 14 }) {
      Column({ space: 4 }) {
        Text("Wasmer SDK")
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor("#E6E9F0")
        Text("WASI/WASIX packages on HarmonyOS")
          .fontSize(14)
          .fontColor("#8A93A6")
      }
      .alignItems(HorizontalAlign.Start)
      .width("100%")

      Row({ space: 10 }) {
        Button(this.busy ? "Running…" : "Run hello.wasm")
          .enabled(!this.busy)
          .onClick(() => {
            this.runHello();
          })
        Button("Close sandbox")
          .enabled(this.sandbox !== null && !this.busy)
          .onClick(() => {
            this.closeSandbox();
            this.status = "Sandbox closed";
          })
        Button(this.busy ? "Running…" : "Run Node.js example")
          .enabled(!this.busy)
          .onClick(() => {
            this.runNode();
          })
      }
      .width("100%")

      Row({ space: 10 }) {
        Button("Official examples")
          .onClick(() => {
            router.pushUrl({ url: "pages/ExamplesPage" });
          })
      }
      .width("100%")

      Text(this.status)
        .fontSize(13)
        .fontColor("#7FD1AE")
        .width("100%")

      Scroll() {
        Text(this.output === "" ? "Output will appear here." : this.output)
          .fontSize(13)
          .fontColor("#C9D1E0")
          .fontFamily("monospace")
          .width("100%")
          .textAlign(TextAlign.Start)
      }
      .width("100%")
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .padding(12)
      .backgroundColor("#151922")
      .borderRadius(12)
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .backgroundColor("#0B0D12")
  }
}
