// Functional smoke test for the Node-API bridge, run on the build host.
// It exercises the same native surface the ArkTS SDK calls.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.join(__dirname, "..");
const dylib =
  process.env.WASMER_NATIVE_LIB ??
  path.join(root, "target", "debug", "libwasmer_sdk_ohos.dylib");
const modulePath = path.join(os.tmpdir(), `wasmer_sdk_ohos-${process.pid}.node`);
fs.copyFileSync(dylib, modulePath);
const native = require(modulePath);

const encode = (value) => new TextEncoder().encode(value);
const decode = (value) => new TextDecoder().decode(value);
let passed = 0;

async function test(name, body) {
  try {
    await body();
    passed += 1;
    console.log(`ok ${passed} - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    console.error(error);
    process.exitCode = 1;
    throw error;
  }
}

async function main() {
  const wasm = new Uint8Array(
    fs.readFileSync(path.join(root, "harmony/entry/src/main/resources/rawfile/demo.wasm")),
  );
  const cacheRoot = fs.mkdtempSync(path.join(os.tmpdir(), "wasmer-smoke-"));
  const core = native.WasmerCore.create(
    JSON.stringify({ cacheRoot, ephemeralCache: true, outputBytes: 1024 * 1024 }),
  );

  const definition = {
    commands: { main: { module: "demo.wasm" } },
    entrypoint: "main",
  };
  const token = await core.createPackage(
    JSON.stringify(definition),
    ["demo.wasm"],
    [wasm],
    [],
    [],
  );

  await test("package metadata", async () => {
    const pkg = core.wrapPackage(token);
    assert.ok(pkg.id.length > 0);
    assert.deepEqual(pkg.commands, ["main"]);
    assert.equal(pkg.entrypoint, "main");
    assert.equal(pkg.hasCommand("main"), true);
    assert.equal(pkg.hasCommand("missing"), false);
  });

  const builder = core.sandbox();
  builder.package(token);
  builder.file("/workspace/config.txt", encode("from the host"));
  builder.env("GREETING", "Host");
  builder.network("disabled");
  const sandbox = await builder.start();

  await test("run with args, env, stdin and filesystem", async () => {
    const command = sandbox.commandPackage(token);
    command.args(["--name", "Node"]);
    command.input(encode("ping from Node\n"));
    const output = await command.run();
    assert.equal(output.exitCode, 0);
    assert.equal(output.reason, "exited");
    assert.equal(output.stdoutTruncated, false);
    const stdout = decode(output.stdout);
    assert.match(stdout, /Hello from WASI on HarmonyOS!/);
    assert.match(stdout, /--name/);
    assert.match(stdout, /GREETING=Host/);
    assert.match(stdout, /stdin: ping from Node/);
    assert.match(stdout, /file: written by WASI/);
  });

  await test("nonzero exit reports reason and stderr", async () => {
    const command = sandbox.commandPackage(token);
    command.args(["--exit", "7"]);
    const output = await command.run();
    assert.equal(output.exitCode, 7);
    assert.equal(output.reason, "exited");
    assert.match(decode(output.stderr), /exiting with 7/);
  });

  await test("timeout reason", async () => {
    const command = sandbox.commandPackage(token);
    command.args(["--sleep", "5000"]);
    command.timeoutMs(150);
    const output = await command.run();
    assert.equal(output.reason, "timeout");
    assert.equal(output.exitCode, 137);
  });

  await test("output capture truncation", async () => {
    const command = sandbox.commandPackage(token);
    command.outputBytes(16);
    const output = await command.run();
    assert.equal(output.stdoutTruncated, true);
    assert.equal(output.stdout.length, 16);
  });

  await test("spawn pipes stdin/stdout", async () => {
    const command = sandbox.commandPackage(token);
    command.args(["--sleep", "50"]);
    command.stdinMode("pipe");
    command.stdoutMode("pipe");
    command.stderrMode("pipe");
    const process = await command.spawn();
    assert.ok(process.id > 0);
    await process.writeStdin(encode("streamed input\n"));
    await process.closeStdin();
    const chunks = [];
    for (;;) {
      const chunk = await process.readStdout(65536);
      if (chunk === null) break;
      chunks.push(chunk);
    }
    const output = await process.wait();
    assert.equal(output.reason, "exited");
    assert.match(decode(output.stdout), /streamed input/);
    assert.match(decode(Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)))), /streamed input/);
  });

  await test("terminate a running process", async () => {
    const command = sandbox.commandPackage(token);
    command.args(["--sleep", "10000"]);
    command.stdinMode("pipe");
    command.stdoutMode("capture");
    command.stderrMode("capture");
    const process = await command.spawn();
    await process.terminate(100);
    const output = await process.wait();
    assert.equal(output.reason, "terminated");
  });

  await test("sandbox filesystem operations", async () => {
    await sandbox.writeFile("/workspace/node.txt", encode("hello filesystem"));
    assert.equal(decode(await sandbox.readFile("/workspace/node.txt")), "hello filesystem");
    await sandbox.mkdir("/workspace/sub", true);
    const entries = JSON.parse(sandbox.readDir("/workspace"));
    assert.ok(entries.some((entry) => entry.name === "config.txt" && entry.kind === "file"));
    assert.ok(entries.some((entry) => entry.name === "sub" && entry.kind === "directory"));
    const stat = JSON.parse(sandbox.stat("/workspace/node.txt"));
    assert.equal(stat.kind, "file");
    assert.equal(stat.size, 16);
    await sandbox.rename("/workspace/node.txt", "/workspace/node2.txt");
    assert.equal(decode(await sandbox.readFile("/workspace/node2.txt")), "hello filesystem");
    await sandbox.remove("/workspace/node2.txt", false);
    await sandbox.remove("/workspace/sub", true);
  });

  await test("install package into the sandbox", async () => {
    const secondToken = await core.createPackage(
      JSON.stringify(definition),
      ["demo.wasm"],
      [wasm],
      [],
      [],
    );
    const installed = await sandbox.installPackageRef(secondToken);
    assert.deepEqual(installed.commands, ["main"]);
    const command = sandbox.commandRef(secondToken, "main");
    const output = await command.run();
    assert.equal(output.exitCode, 0);
    await command; // keep the reference alive until execution completes
  });

  await test("load raw WASI bytes and report progress", async () => {
    const loadedToken = await core.loadPackageBytes(wasm);
    const loaded = core.wrapPackage(loadedToken);
    assert.equal(loaded.entrypoint, "main");
    assert.deepEqual(loaded.commands, ["main"]);

    const sink = new native.ProgressSink();
    const tokens = await core.loadPackages([wasm], sink.token);
    assert.equal(tokens.length, 1);
    const events = sink.drain();
    assert.ok(events.length > 0);
    const snapshot = JSON.parse(events[events.length - 1]);
    assert.ok(Array.isArray(snapshot.packages));
    assert.ok(typeof snapshot.phase === "string");
    assert.ok(snapshot.download !== undefined);
  });

  await test("invalid progress and cancellation tokens are rejected", async () => {
    await assert.rejects(core.loadPackages([wasm], 999999), /WASMER_ERROR::INVALID_ARGUMENT::/);
    await assert.rejects(
      core.loadPackages([wasm], undefined, 999999),
      /WASMER_ERROR::INVALID_ARGUMENT::/,
    );
  });

  await test("install package bytes", async () => {
    const installed = await sandbox.installPackageBytes(wasm);
    assert.deepEqual(installed.commands, ["main"]);
  });

  await test("terminal spawn and resize", async () => {
    const command = sandbox.commandPackage(token);
    command.args([]);
    command.terminal(80, 24);
    command.stdinMode("pipe");
    command.stdoutMode("pipe");
    command.stderrMode("pipe");
    const process = await command.spawn();
    process.resizeTerminal(100, 40);
    await process.closeStdin();
    const output = await process.wait();
    assert.equal(output.reason, "exited");
    assert.equal(output.exitCode, 0);
  });

  await test("port observation surface", async () => {
    assert.equal(Array.isArray(sandbox.listeningPorts()), true);
    assert.equal(sandbox.isPortListening(1), false);
  });

  await test("invalid package definition is rejected", async () => {
    await assert.rejects(
      core.createPackage("{not json", [], [], [], []),
      /WASMER_ERROR::INVALID_ARGUMENT::/,
    );
  });

  await test("sandbox and client close cleanly", async () => {
    await sandbox.close();
    await core.shutdown();
  });

  console.log(`\n${passed} tests passed`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
