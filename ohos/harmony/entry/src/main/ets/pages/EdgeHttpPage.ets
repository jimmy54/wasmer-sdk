import { webview } from "@kit.ArkWeb";
import {
  BrowserServer,
  NetworkPolicy,
  Process,
  Sandbox,
  SandboxOptions,
  Wasmer,
  WasmerError,
} from "@wasmer/harmony";

const SERVER_SOURCE: string = `
const http = require("http");
const port = Number(process.env.PORT || 8080);
http.createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/plain" });
  response.end("hello from Edge.js on HarmonyOS\\n");
}).listen(port, () => console.log("listening on " + port));
`;

@Entry
@Component
struct EdgeHttpPage {
  @State status: string = "Ready";
  @State url: string = "";
  @State busy: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private wasmer: Wasmer | null = null;
  private sandbox: Sandbox | null = null;
  private server: BrowserServer | null = null;
  private guest: Process | null = null;

  aboutToDisappear(): void {
    this.stopServer();
  }

  private async startServer(): Promise<void> {
    this.busy = true;
    this.status = "Starting Edge.js";
    try {
      if (this.wasmer === null) {
        this.wasmer = await Wasmer.create();
      }
      let wasmer = this.wasmer;
      if (wasmer === null) {
        throw new Error("Wasmer client unavailable");
      }
      this.wasmer = wasmer;
      const files: Record<string, string> = {};
      files["server.js"] = SERVER_SOURCE;
      const env: Record<string, string> = {};
      env["PORT"] = "8080";
      const network: NetworkPolicy = { mode: "host" };
      const packages: string[] = ["wasmer/edgejs-quickjs@0.1.0"];
      const options: SandboxOptions = {
        packages: packages,
        files: files,
        env: env,
        network: network,
      };
      const sandbox = await wasmer.sandboxes.create(options);
      this.sandbox = sandbox;
      const guest = await sandbox
        .command("edge", ["/workspace/server.js"])
        .spawn({ stdout: "pipe", stderr: "capture" });
      this.guest = guest;
      this.status = "Waiting for port 8080";
      const timeoutMs: number = 20000;
      await sandbox.ports.wait(8080, { timeoutMs: timeoutMs });
      const server = await sandbox.ports.expose(8080, { timeoutMs: timeoutMs });
      this.server = server;
      this.url = server.url.href;
      this.status = "Serving " + this.url;
    } catch (error) {
      if (error instanceof WasmerError) {
        this.status = error.code + ": " + error.message;
      } else if (error instanceof Error) {
        this.status = error.message;
      }
    } finally {
      this.busy = false;
    }
  }

  private stopServer(): void {
    const guest = this.guest;
    this.guest = null;
    if (guest !== null) {
      guest.terminate({ gracePeriodMs: 2000 }).then(() => guest.wait());
    }
    const server = this.server;
    this.server = null;
    if (server !== null) {
      server.close();
    }
    const sandbox = this.sandbox;
    this.sandbox = null;
    if (sandbox !== null) {
      sandbox.close();
    }
    const wasmer = this.wasmer;
    this.wasmer = null;
    if (wasmer !== null) {
      wasmer.close();
    }
    this.url = "";
    this.status = "Stopped";
  }

  build() {
    Column({ space: 12 }) {
      Text("Guest HTTP server")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Row({ space: 10 }) {
        Button(this.busy ? "Starting…" : "Start")
          .enabled(!this.busy)
          .onClick(() => {
            this.startServer();
          })
        Button("Stop")
          .enabled(!this.busy)
          .onClick(() => {
            this.stopServer();
          })
      }
      Text(this.status)
        .fontSize(12)
        .fontColor("#7FD1AE")
      if (this.url !== "") {
        Web({ src: this.url, controller: this.controller })
          .width("100%")
          .layoutWeight(1)
      }
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .alignItems(HorizontalAlign.Start)
  }
}
