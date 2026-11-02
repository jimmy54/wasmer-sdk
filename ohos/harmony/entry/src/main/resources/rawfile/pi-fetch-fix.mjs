import http from "node:http";
import https from "node:https";

class SimpleHeaders {
  constructor(raw) {
    this.values = new Map();
    if (raw === undefined || raw === null) {
      return;
    }
    for (const key of Object.keys(raw)) {
      const value = raw[key];
      if (Array.isArray(value)) {
        this.values.set(key.toLowerCase(), value.join(", "));
      } else if (value !== undefined && value !== null) {
        this.values.set(key.toLowerCase(), String(value));
      }
    }
  }

  get(name) {
    const value = this.values.get(name.toLowerCase());
    return value === undefined ? null : value;
  }

  has(name) {
    return this.values.has(name.toLowerCase());
  }

  forEach(callback) {
    this.values.forEach((value, key) => {
      callback(value, key);
    });
  }

  entries() {
    return this.values.entries();
  }

  [Symbol.iterator]() {
    return this.values.entries();
  }
}

function readAll(stream) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let text = "";
  return new Promise((resolve, reject) => {
    const pump = () => {
      reader.read().then((result) => {
        if (result.done) {
          resolve(text + decoder.decode());
          return;
        }
        text += decoder.decode(result.value, { stream: true });
        pump();
      }).catch(reject);
    };
    pump();
  });
}

function toResponse(incoming) {
  const stream = new ReadableStream({
    start(controller) {
      incoming.on("data", (chunk) => {
        controller.enqueue(new Uint8Array(chunk));
      });
      incoming.on("end", () => {
        controller.close();
      });
      incoming.on("error", (error) => {
        controller.error(error);
      });
    },
    cancel() {
      incoming.destroy();
    },
  });
  const status = incoming.statusCode === undefined ? 0 : incoming.statusCode;
  return {
    ok: status >= 200 && status < 300,
    status: status,
    statusText: incoming.statusMessage === undefined ? "" : incoming.statusMessage,
    headers: new SimpleHeaders(incoming.headers),
    body: stream,
    bodyUsed: false,
    text: () => readAll(stream),
    json: () => readAll(stream).then((text) => JSON.parse(text)),
  };
}

function headerRecord(headers) {
  const record = {};
  if (headers === undefined || headers === null) {
    return record;
  }
  if (headers instanceof SimpleHeaders) {
    headers.forEach((value, key) => {
      record[key] = value;
    });
    return record;
  }
  if (Array.isArray(headers)) {
    for (let index = 0; index + 1 < headers.length; index += 2) {
      record[String(headers[index]).toLowerCase()] = String(headers[index + 1]);
    }
    return record;
  }
  for (const key of Object.keys(headers)) {
    const value = headers[key];
    record[key] = Array.isArray(value) ? value.join(", ") : String(value);
  }
  return record;
}

function fetchImpl(input, init) {
  const options = init === undefined ? {} : init;
  const urlText = typeof input === "string" ? input : String(input.url);
  return new Promise((resolve, reject) => {
    const target = new URL(urlText);
    const transport = target.protocol === "https:" ? https : http;
    const method = options.method === undefined ? "GET" : String(options.method);
    const request = transport.request({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: target.pathname + target.search,
      method: method,
      headers: headerRecord(options.headers),
    }, (incoming) => {
      resolve(toResponse(incoming));
    });
    request.on("error", reject);
    const signal = options.signal;
    if (signal !== undefined && signal !== null) {
      if (signal.aborted) {
        request.destroy(new Error("The operation was aborted"));
        return;
      }
      signal.addEventListener("abort", () => {
        request.destroy(new Error("The operation was aborted"));
      });
    }
    const body = options.body;
    if (body !== undefined && body !== null) {
      request.write(typeof body === "string" ? body : String(body));
    }
    request.end();
  });
}

function install() {
  globalThis.fetch = fetchImpl;
}

install();

export default function () {
  install();
}
