import {
  Output,
  Sandbox,
  SandboxOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

@Entry
@Component
struct BashPage {
  @State status: string = "Ready";
  @State output: string = "";
  @State busy: boolean = false;

  private async runShell(): Promise<void> {
    this.busy = true;
    this.status = "Installing bash";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    try {
      const packages: string[] = ["wasmer/bash"];
      const options: SandboxOptions = { packages: packages };
      sandbox = await wasmer.sandboxes.create(options);
      await sandbox.installPackage("wasmer/bash", { asShell: "bash" });
      this.status = "Running shell command";
      const name: string = "HarmonyOS";
      const result: Output = await sandbox.sh`echo "hello from ${name}"; pwd; echo done`.run();
      this.output = result.stdout.text() + result.stderr.text();
      this.status = "Exited with status " + result.exitCode;
    } catch (error) {
      if (error instanceof WasmerError) {
        this.status = error.code;
        this.output = error.message;
      } else if (error instanceof Error) {
        this.status = "Error";
        this.output = error.message;
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
      Text("Shell tools")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Button(this.busy ? "Running…" : "Run bash")
        .enabled(!this.busy)
        .onClick(() => {
          this.runShell();
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
