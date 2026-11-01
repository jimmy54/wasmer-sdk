import {
  Output,
  ProcessExitError,
  Sandbox,
  SandboxOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

@Entry
@Component
struct PythonPage {
  @State status: string = "Ready";
  @State output: string = "";
  @State busy: boolean = false;

  private async runPython(): Promise<void> {
    this.busy = true;
    this.status = "Loading python/python";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    try {
      const files: Record<string, string> = {};
      files["main.py"] = "print(sum(number * number for number in range(10)))";
      const packages: string[] = ["python/python@=3.13.20"];
      const options: SandboxOptions = { packages: packages, files: files };
      sandbox = await wasmer.sandboxes.create(options);
      this.status = "Running main.py";
      const result: Output = await sandbox
        .command("python", ["/workspace/main.py"])
        .run();
      this.output = result.text();
      this.status = "Exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof ProcessExitError) {
        this.output = error.output.stderr.text();
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

  build() {
    Column({ space: 12 }) {
      Text("Python on HarmonyOS")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Button(this.busy ? "Running…" : "Run Python")
        .enabled(!this.busy)
        .onClick(() => {
          this.runPython();
        })
      Text(this.status)
        .fontSize(13)
        .fontColor("#7FD1AE")
      Scroll() {
        Text(this.output === "" ? "Output will appear here." : this.output)
          .fontSize(13)
          .fontFamily("monospace")
          .width("100%")
      }
      .layoutWeight(1)
      .width("100%")
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .alignItems(HorizontalAlign.Start)
  }
}
