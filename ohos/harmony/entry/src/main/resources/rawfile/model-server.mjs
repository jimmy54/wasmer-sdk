import fs from "node:fs";
import http from "node:http";

// Deterministic OpenAI-compatible streaming endpoint for the Pi agent test.
// It drives the real provider/tool loop without credentials or paid calls.
const steps = [
  ["read", { path: "hello.js" }],
  ["write", { path: "pi-test/result.txt", content: "before\n" }],
  ["edit", { path: "pi-test/result.txt", oldText: "before", newText: "after" }],
  ["bash", { command: "cat pi-test/result.txt" }],
  ["grep", { pattern: "after", path: "pi-test" }],
  ["find", { pattern: "*.txt", path: "pi-test" }],
  ["ls", { path: "pi-test" }],
];

let requests = 0;

const server = http.createServer(async (request, response) => {
  fs.appendFileSync("/workspace/model-requests.log",
    (request.method ?? "") + " " + (request.url ?? "") + "\n");
  if (request.url === "/health") {
    response.end("ok");
    return;
  }
  let body = "";
  for await (const chunk of request) {
    body += chunk;
  }
  const step = steps[requests++];
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
  });
  const send = (delta, finishReason = null) => {
    response.write("data: " + JSON.stringify({
      id: "wasmer-test-" + requests,
      object: "chat.completion.chunk",
      created: 1,
      model: "test",
      choices: [{ index: 0, delta: delta, finish_reason: finishReason }],
    }) + "\n\n");
  };
  send({ role: "assistant" });
  if (step !== undefined) {
    send({
      tool_calls: [{
        index: 0,
        id: "call-" + requests,
        type: "function",
        function: { name: step[0], arguments: JSON.stringify(step[1]) },
      }],
    });
    send({}, "tool_calls");
  } else {
    send({ content: "PI_AGENT_" });
    send({ content: "TOOLS_OK" });
    send({}, "stop");
  }
  response.end("data: [DONE]\n\n");
});

server.listen(8787, "127.0.0.1", () => {
  console.log("MODEL_READY");
});
