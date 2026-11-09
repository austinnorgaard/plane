/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { useContext, useEffect, useRef } from "react";
import { useLocation, useParams } from "react-router";
// hooks
import { useUser } from "@/hooks/store/user";
import { StoreContext } from "@/lib/store-context";
// local imports
import { LiveWorkItemsApplier } from "./apply";
import { buildApplierDeps, useWorkItemUnavailableNotice } from "./applier-deps";
import { getLiveEventsClient } from "./client";

/**
 * Keeps the work item lists and the open peek of a project live.
 * Mounted once in the project layout; subscribes while the project is on screen.
 *
 * PLN-78: also mounted by the full-page work item detail (browse/[workItem]), which is outside the project
 * layout. `pageIssueId` is that page's work item: it is refreshed like an open peek (details, comments and
 * activity on its events).
 */
export const useLiveWorkItems = (
  workspaceSlug: string | undefined,
  projectId: string | undefined,
  options?: { pageIssueId?: string }
) => {
  const { cycleId, moduleId, viewId } = useParams();
  // PLN-77: the archived work items route (list or detail) has no route param of its own
  const { pathname } = useLocation();
  const archived = /\/projects\/[^/]+\/archives\/issues(\/|$)/.test(pathname);
  // PLN-76: the intake (triage) route
  const intake = /\/projects\/[^/]+\/intake(\/|$)/.test(pathname);
  const root = useContext(StoreContext);
  const { data: currentUser } = useUser();
  // PLN-119: translated, and stable across renders
  const notifyUnavailable = useWorkItemUnavailableNotice();

  // the applier reads the latest values without being recreated on every navigation inside the project
  const latest = useRef({
    cycleId,
    moduleId,
    viewId,
    archived,
    intake,
    userId: currentUser?.id,
    pageIssueId: options?.pageIssueId,
  });
  latest.current = {
    cycleId,
    moduleId,
    viewId,
    archived,
    intake,
    userId: currentUser?.id,
    pageIssueId: options?.pageIssueId,
  };
  // the root store is a stable singleton, read through a ref so the subscription only follows the project
  const stores = useRef({ root, notifyUnavailable });
  stores.current = { root, notifyUnavailable };

  useEffect(() => {
    const { root: rootStore, notifyUnavailable: notify } = stores.current;
    if (!workspaceSlug || !projectId || !rootStore) return;
    const applier = new LiveWorkItemsApplier(
      buildApplierDeps(rootStore, {
        workspaceSlug,
        projectId,
        getRoute: () => ({
          cycleId: latest.current.cycleId,
          moduleId: latest.current.moduleId,
          viewId: latest.current.viewId,
          archived: latest.current.archived,
          intake: latest.current.intake,
        }),
        getCurrentUserId: () => latest.current.userId,
        getPageIssueId: () => latest.current.pageIssueId,
        onIssueUnavailable: notify,
      })
    );
    const unsubscribe = getLiveEventsClient().subscribe(workspaceSlug, projectId, (event) => applier.handle(event));
    return () => {
      unsubscribe();
      applier.dispose();
    };
  }, [workspaceSlug, projectId]);
};
