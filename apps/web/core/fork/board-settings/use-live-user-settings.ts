/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-106): keeps the user's fork settings fresh from the live events hub. The hub sends a
// user_settings event (version only) to every socket of the user; a newer version is refetched.

import { useEffect } from "react";
// hooks
import { useUser } from "@/hooks/store/user";
// lib
import { getLiveEventsClient } from "@/lib/live-events/client";
// local imports
import { getForkUserSettingsStore } from "./store";

export const useLiveUserSettings = () => {
  const { data: currentUser } = useUser();
  const userId = currentUser?.id;

  useEffect(() => {
    if (!userId) return;
    const store = getForkUserSettingsStore();
    void store.ensure(userId);
    return getLiveEventsClient().subscribeUser((event) => {
      if (event.type === "resync") void store.refresh();
      else if (event.kind === "user_settings") void store.refresh(event.version);
    });
  }, [userId]);
};
