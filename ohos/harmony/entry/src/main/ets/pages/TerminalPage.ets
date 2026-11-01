import { util } from "@kit.ArkTS";
import {
  Process,
  Sandbox,
  SandboxOptions,
  SpawnOptions,
  TerminalOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

@Entry
@Component
struct TerminalPage {
  @State output: string = "";
  @State status: string = "Ready";
  @State command: string = "echo hello from the terminal";
  @State running: boolean = false;
  private wasmer: Wasmer | null = null;
  private sandbox: Sandbox | null = null;
  private process: Process | null = null;
  private pumping: boolean = false;

  aboutToDisappear(): void {
    this.stop();
  }

  private async start(): Promise<void> {
    this.status = "Starting bash";
    this.output = "";
    try {
      const wasmer: Wasmer = await Wasmer.create();
      this.wasmer = wasmer;
      const packages: string[] = ["wasmer/bash"];
      const options: SandboxOptions = { packages: packages };
      const sandbox = await wasmer.sandboxes.create(options);
      this.sandbox = sandbox;
      const dimensions: TerminalOptions = { columns: 100, rows: 30 };
      const spawnOptions: SpawnOptions = { terminal: dimensions };
      const process = await sandbox.command("bash", ["-i"]).spawn(spawnOptions);
      this.process = process;
      this.running = true;
      this.status = "bash pid " + process.id;
      this.pumping = true;
      this.pump(process);
    } catch (error) {
      this.fail(error as Object);
    }
  }

  private async pump(process: Process): Promise<void> {
    const stdout = process.stdout;
    if (stdout === null) {
      return;
    }
    const decoder: util.TextDecoder = new util.TextDecoder("utf-8");
    try {
      while (this.pumping) {
        const chunk = await stdout.next();
        if (chunk.done) {
          break;
        }
        const value = chunk.value;
        if (value !== undefined) {
          this.output += decoder.decodeToString(value, { stream: true });
        }
      }
    } catch (error) {
      this.fail(error as Object);
    }
  }

  private async send(): Promise<void> {
    const process = this.process;
    if (process === null || process.stdin === null) {
      return;
    }
    await process.stdin.write(this.command + "\n");
  }

  private resize(): void {
    const process = this.process;
    if (process !== null) {
      process.resizeTerminal(120, 40);
      this.status = "Resized to 120x40";
    }
  }

  private async stop(): Promise<void> {
    this.pumping = false;
    const process = this.process;
    this.process = null;
    if (process !== null) {
      await process.terminate({ gracePeriodMs: 1000 });
      await process.wait();
    }
    const sandbox = this.sandbox;
    this.sandbox = null;
    if (sandbox !== null) {
      await sandbox.close();
    }
    const wasmer = this.wasmer;
    this.wasmer = null;
    if (wasmer !== null) {
      await wasmer.close();
    }
    this.running = false;
    this.status = "Stopped";
  }

  private fail(error: Object): void {
    if (error instanceof WasmerError) {
      this.status = error.code + ": " + error.message;
    } else if (error instanceof Error) {
      this.status = error.message;
    } else {
      this.status = String(error);
    }
  }

  build() {
    Column({ space: 12 }) {
      Text("Interactive bash")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Row({ space: 10 }) {
        Button(this.running ? "Running" : "Start")
          .enabled(!this.running)
          .onClick(() => {
            this.start();
          })
        Button("Resize")
          .enabled(this.running)
          .onClick(() => {
            this.resize();
          })
        Button("Stop")
          .enabled(this.running)
          .onClick(() => {
            this.stop();
          })
      }
      Text(this.status)
        .fontSize(12)
        .fontColor("#7FD1AE")
      Scroll() {
        Text(this.output === "" ? "Terminal output will appear here." : this.output)
          .fontSize(12)
          .fontFamily("monospace")
          .width("100%")
      }
      .layoutWeight(1)
      .width("100%")
      .padding(8)
      .backgroundColor("#151922")
      Row({ space: 8 }) {
        TextInput({ text: this.command, placeholder: "Command" })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.command = value;
          })
        Button("Send")
          .enabled(this.running)
          .onClick(() => {
            this.send();
          })
      }
      .width("100%")
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .alignItems(HorizontalAlign.Start)
  }
}
