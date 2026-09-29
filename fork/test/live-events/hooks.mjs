// SPDX-License-Identifier: AGPL-3.0-only
// Module hooks for the live-events tests: relative imports get their .ts extension and every
// package or alias import (mobx, lodash, @plane/*, @/*) resolves to a small stub, so the
// sources run under node's built-in type stripping without installing anything.
const STUB = "stub:deps";

export async function resolve(specifier, context, nextResolve) {
  if (specifier === STUB) return { url: STUB, shortCircuit: true };
  if (specifier.startsWith("./") && !specifier.endsWith(".ts") && !specifier.endsWith(".mjs")) {
    return nextResolve(`${specifier}.ts`, context);
  }
  if (
    !specifier.startsWith(".") &&
    !specifier.startsWith("/") &&
    !specifier.startsWith("node:") &&
    !specifier.startsWith("file:") &&
    !specifier.startsWith("stub:")
  ) {
    return { url: STUB, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  if (url === STUB) {
    return {
      format: "module",
      shortCircuit: true,
      source: `
        export const EIssueGroupedAction = { ADD: "ADD", DELETE: "DELETE" };
        export class IssueService { retrieveIssues(...args) { return globalThis.__retrieveIssues(...args); } }
        export const runInAction = (fn) => fn();
        export const clone = (value) => (value && typeof value === "object" ? { ...value } : value);
        export const LIVE_BASE_URL = "";
        export const LIVE_BASE_PATH = "/live";
      `,
    };
  }
  return nextLoad(url, context);
}
