import {
  Output,
  Sandbox,
  SandboxOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

@Entry
@Component
struct MultipleRuntimesPage {
  @State status: string = "Ready";
  @State output: string = "";
  @State busy: boolean = false;

  private async runAll(): Promise<void> {
    this.busy = true;
    this.status = "Loading python, edge, php";
    this.output = "";
    const wasmer: Wasmer = await Wasmer.create();
    let sandbox: Sandbox | null = null;
    try {
      const packages: string[] = [
        "python/python@=3.13.20",
        "wasmer/edgejs@0.2.0",
        "php/php-32",
      ];
      const options: SandboxOptions = { packages: packages };
      sandbox = await wasmer.sandboxes.create(options);
      const results: string[] = [];
      const shell: Output = await sandbox.command("echo", ["hello from shell tools"]).run();
      results.push(shell.text().trim());
      const python: Output = await sandbox
        .command("python", ["-c", "print('hello from Python')"])
        .run();
      results.push(python.text().trim());
      const edge: Output = await sandbox
        .command("edge", ["-e", "console.log('hello from Edge.js')"])
        .run();
      results.push(edge.text().trim());
      const php: Output = await sandbox
        .command("php", ["-r", "echo 'hello from PHP';"])
        .run();
      results.push(php.text().trim());
      this.output = results.join("\n");
      this.status = "All runtimes completed";
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
      Text("Multiple runtimes")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Button(this.busy ? "Running…" : "Run all")
        .enabled(!this.busy)
        .onClick(() => {
          this.runAll();
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
