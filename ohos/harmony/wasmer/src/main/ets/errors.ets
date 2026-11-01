/**
 * Error types and abort primitives for the HarmonyOS Wasmer SDK.
 *
 * HarmonyOS ArkTS does not provide `AbortController`/`AbortSignal` or
 * `DOMException`, so this module supplies API-compatible implementations.
 */

export type WasmerErrorCode =
  | "CLIENT_CLOSED"
  | "SANDBOX_CLOSED"
  | "INVALID_ARGUMENT"
  | "INVALID_PACKAGE_SOURCE"
  | "PACKAGE_NOT_FOUND"
  | "PACKAGE_LOAD_FAILED"
  | "PACKAGE_NOT_INSTALLED"
  | "PACKAGE_HAS_NO_ENTRYPOINT"
  | "COMMAND_NOT_FOUND"
  | "COMMAND_AMBIGUOUS"
  | "SHELL_NOT_CONFIGURED"
  | "CAPABILITY_UNAVAILABLE"
  | "INVALID_PATH"
  | "FILESYSTEM_ERROR"
  | "TIMEOUT"
  | "PROCESS_EXITED"
  | "PROCESS_TERMINATED"
  | "INVALID_UTF8"
  | "EXECUTION_ERROR"
  | "TASK_ERROR"
  | "INTERNAL_ERROR"
  | "IO_ERROR"
  | "INITIALIZATION_ERROR"
  | "TARGET_ERROR";

/** An SDK failure with a machine-readable, currently provisional `code`. */
export class WasmerError extends Error {
  readonly code: WasmerErrorCode;
  readonly cause: Object | undefined;

  constructor(message: string, code: WasmerErrorCode, cause?: Object) {
    super(message);
    this.name = "WasmerError";
    this.code = code;
    this.cause = cause;
  }

  static is(error: Object | undefined | null, code?: WasmerErrorCode): boolean {
    if (!(error instanceof WasmerError)) {
      return false;
    }
    return code === undefined || error.code === code;
  }
}

/** Thrown by `throwIfAborted()` when no explicit abort reason was supplied. */
export class AbortError extends Error {
  constructor(message: string = "The operation was aborted") {
    super(message);
    this.name = "AbortError";
  }
}

export type AbortListener = () => void;

export interface AbortListenerOptions {
  once?: boolean;
}

class AbortListenerRecord {
  readonly listener: AbortListener;
  readonly once: boolean;

  constructor(listener: AbortListener, once: boolean) {
    this.listener = listener;
    this.once = once;
  }
}

/**
 * Minimal `AbortSignal` equivalent. Supports the subset used by `@wasmer/sdk`:
 * `aborted`, `reason`, `throwIfAborted()`, `addEventListener("abort", ...)`,
 * `removeEventListener`, and the `onabort` property.
 */
export class AbortSignal {
  aborted: boolean = false;
  reason: Error | undefined = undefined;
  onabort: AbortListener | null = null;
  private listeners: AbortListenerRecord[] = [];

  throwIfAborted(): void {
    if (!this.aborted) {
      return;
    }
    throw this.reason ?? new AbortError();
  }

  addEventListener(
    type: string,
    listener: AbortListener,
    options?: AbortListenerOptions,
  ): void {
    if (type !== "abort" || this.aborted) {
      return;
    }
    this.listeners.push(new AbortListenerRecord(listener, options?.once === true));
  }

  removeEventListener(type: string, listener: AbortListener): void {
    if (type !== "abort") {
      return;
    }
    this.listeners = this.listeners.filter(
      (record: AbortListenerRecord) => record.listener !== listener,
    );
  }

  /** @internal */
  markAborted(reason: Error): void {
    if (this.aborted) {
      return;
    }
    this.aborted = true;
    this.reason = reason;
    const pending = this.listeners;
    this.listeners = [];
    for (const record of pending) {
      try {
        record.listener();
      } catch (error) {
        console.error("Abort listener failed", error);
      }
    }
    const handler = this.onabort;
    if (handler !== null) {
      try {
        handler();
      } catch (error) {
        console.error("Abort handler failed", error);
      }
    }
  }
}

/** Minimal `AbortController` equivalent. */
export class AbortController {
  readonly signal: AbortSignal = new AbortSignal();

  abort(reason?: Error): void {
    this.signal.markAborted(reason ?? new AbortError());
  }
}
