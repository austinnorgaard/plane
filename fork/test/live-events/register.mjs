// SPDX-License-Identifier: AGPL-3.0-only
// Registers the module hooks that let node load the web live-events sources directly.
import { register } from "node:module";
register("./hooks.mjs", import.meta.url);
