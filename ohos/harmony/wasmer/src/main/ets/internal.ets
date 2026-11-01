/**
 * Internal helpers shared by the public API: native error translation,
 * byte/text conversion, argument validation, and cache placement.
 */

import { util } from "@kit.ArkTS";
import { application } from "@kit.AbilityKit";
import nativeModule from "libwasmer_sdk_ohos.so";
import type {
  CommandCore,
  OutputCore,
  PackageCore,
  PackageLoadCancellationCore,
  ProcessCore,
  ProgressSink,
  SandboxBuilderCore,
  SandboxCore,
  WasmerCore,
} from "libwasmer_sdk_ohos.so";
import { WasmerError, WasmerErrorCode } from "./errors";

export {
  nativeModule,
  type CommandCore,
  type OutputCore,
  type PackageCore,
  type PackageLoadCancellationCore,
  type ProcessCore,
  type ProgressSink,
  type SandboxBuilderCore,
  type SandboxCore,
  type WasmerCore,
};

export const MAX_SAFE_INTEGER: number = 9007199254740991;
export const MAX_WASM32_SIZE: number = 4294967295;

const ERROR_CODES: Set<string> = new Set<string>([
  "CLIENT_CLOSED",
  "SANDBOX_CLOSED",
  "INVALID_ARGUMENT",
  "INVALID_PACKAGE_SOURCE",
  "PACKAGE_NOT_FOUND",
  "PACKAGE_LOAD_FAILED",
  "PACKAGE_NOT_INSTALLED",
  "PACKAGE_HAS_NO_ENTRYPOINT",
  "COMMAND_NOT_FOUND",
  "COMMAND_AMBIGUOUS",
  "SHELL_NOT_CONFIGURED",
  "CAPABILITY_UNAVAILABLE",
  "INVALID_PATH",
  "FILESYSTEM_ERROR",
  "TIMEOUT",
  "PROCESS_EXITED",
  "PROCESS_TERMINATED",
  "INVALID_UTF8",
  "EXECUTION_ERROR",
  "TASK_ERROR",
  "INTERNAL_ERROR",
  "IO_ERROR",
  "INITIALIZATION_ERROR",
  "TARGET_ERROR",
]);

const ERROR_PREFIX: string = "WASMER_ERROR::";

function errorMessage(error: Object | undefined | null): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (error === undefined || error === null) {
    return "the Wasmer native module failed";
  }
  return String(error);
}

/** Convert a native rejection, including `WASMER_ERROR::CODE::message`, into `WasmerError`. */
export function parseNativeError(error: Object | undefined | null): WasmerError {
  if (error instanceof WasmerError) {
    return error;
  }
  const raw = errorMessage(error);
  if (raw.startsWith(ERROR_PREFIX)) {
    const rest = raw.substring(ERROR_PREFIX.length);
    const separator = rest.indexOf("::");
    if (separator > 0) {
      const code = rest.substring(0, separator);
      const message = rest.substring(separator + 2);
      if (ERROR_CODES.has(code)) {
        return new WasmerError(message, code as WasmerErrorCode, error ?? undefined);
      }
      return new WasmerError(message, "INTERNAL_ERROR", error ?? undefined);
    }
  }
  return new WasmerError(raw, "INTERNAL_ERROR", error ?? undefined);
}

export async function callNative<T>(work: Promise<T>): Promise<T> {
  try {
    return await work;
  } catch (error) {
    throw parseNativeError(error);
  }
}

export function callNativeSync<T>(work: () => T): T {
  try {
    return work();
  } catch (error) {
    throw parseNativeError(error);
  }
}

const textEncoder: util.TextEncoder = new util.TextEncoder();

export function encode(value: string | Uint8Array): Uint8Array {
  if (typeof value === "string") {
    return textEncoder.encodeInto(value);
  }
  return value;
}

export function createTextDecoder(): util.TextDecoder {
  return new util.TextDecoder("utf-8");
}

export function decodeText(bytes: Uint8Array): string {
  return createTextDecoder().decodeToString(bytes);
}

export function decodeStream(
  decoder: util.TextDecoder,
  bytes: Uint8Array,
  stream: boolean,
): string {
  return decoder.decodeToString(bytes, { stream: stream });
}

export function defaultCacheRoot(): string {
  try {
    const context = application.getApplicationContext();
    return context.cacheDir + "/wasmer";
  } catch (error) {
    return ".wasmer";
  }
}

export function validateInteger(
  name: string,
  value: number,
  minimum: number,
  maximum: number,
): number {
  if (
    !Number.isFinite(value) ||
    !Number.isInteger(value) ||
    value < minimum ||
    value > maximum
  ) {
    throw new WasmerError(
      `\`${name}\` must be an integer between ${minimum} and ${maximum}, inclusive`,
      "INVALID_ARGUMENT",
    );
  }
  return value;
}

export function validateTimeoutMs(value: number, name: string = "timeoutMs"): number {
  return validateInteger(name, value, 0, MAX_SAFE_INTEGER);
}

export function validateOutputBytes(value: number): number {
  return validateInteger("outputBytes", value, 0, MAX_WASM32_SIZE);
}

export function validateParallelism(value: number): number {
  return validateInteger("parallelism", value, 1, MAX_WASM32_SIZE);
}

export class TerminalDimensions {
  readonly columns: number;
  readonly rows: number;

  constructor(columns: number, rows: number) {
    this.columns = columns;
    this.rows = rows;
  }
}

export function validateTerminalDimensions(
  terminal: boolean | object | undefined,
  columns: number | undefined,
  rows: number | undefined,
): TerminalDimensions | undefined {
  if (terminal === undefined || terminal === false) {
    return undefined;
  }
  return new TerminalDimensions(
    validateInteger("terminal.columns", columns ?? 80, 1, 4294967295),
    validateInteger("terminal.rows", rows ?? 24, 1, 4294967295),
  );
}

export function escapeShellValue(value: string | number | object | Array<string | number | object>): string {
  if (Array.isArray(value)) {
    const parts: string[] = [];
    const entries = value as Array<string | number | object>;
    for (const entry of entries) {
      parts.push(escapeShellWord(String(entry)));
    }
    return parts.join(" ");
  }
  return escapeShellWord(String(value));
}

export function escapeShellWord(value: string): string {
  return "'" + value.split("'").join("'\\''") + "'";
}
