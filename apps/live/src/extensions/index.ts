/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { PageWriteLockExtension } from "@/pages-api/write-lock";
import { Database } from "./database";
import { ForceCloseHandler } from "./force-close-handler";
import { Logger } from "./logger";
import { Redis } from "./redis";
import { TitleSyncExtension } from "./title-sync";

export const getExtensions = () => [
  new Logger(),
  new PageWriteLockExtension(), // priority 1000: its onLoadDocument runs before the Database fetch
  new Database(),
  new Redis(),
  new TitleSyncExtension(),
  new ForceCloseHandler(), // Must be after Redis to receive broadcasts
];
