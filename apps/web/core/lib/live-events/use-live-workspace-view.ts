/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { useContext, useEffect, useRef } from "react";
import { sortBy } from "lodash-es";
// hooks
import { useProject } from "@/hooks/store/use-project";
import { useUser } from "@/hooks/store/user";
import { StoreContext } from "@/lib/store-context";
// local imports
import { LiveWorkItemsApplier } from "./apply";
import { buildApplierDeps, useWorkItemUnavailableNotice } from "./applier-deps";
import { getLiveEventsClient } from "./client";

/**
 * PLN-37: at most this many projects are subscribed for a workspace view (the hub allows 100 per socket). The
 * user's joined projects are taken in their sidebar order; work items of other projects in the view update on
 * the next load.
 */
export const MAX_WORKSPACE_VIEW_PROJECTS = 50;

/**
 * PLN-37: keeps a workspace view (all, assigned, created, subscribed, or a saved workspace view) live.
 *
 * The workspace views route is outside the project layout, so useLiveWorkItems is not mounted there. This
 * hook subscribes to the user's joined projects in one subscribe frame (subscribeMany) and runs one
 * LiveWorkItemsApplier per project: each one applies its project's events to the workspace issues store
 * (and to an open peek), with the view's filter evaluated per work item (PLN-38). The appliers share one
 * list refetch, so a full refresh or a coarse view over several projects costs one request.
 */
export const useLiveWorkspaceView = (workspaceSlug: string | undefined, globalViewId: string | undefined) => {
  const root = useContext(StoreContext);
  const { data: currentUser } = useUser();
  const { joinedProjectIds } = useProject();
  // PLN-119: translated, and stable across renders
  const notifyUnavailable = useWorkItemUnavailableNotice();

  // read by the appliers without recreating them when the view changes
  const latest = useRef({ globalViewId, userId: currentUser?.id });
  latest.current = { globalViewId, userId: currentUser?.id };
  const stores = useRef({ root, notifyUnavailable });
  stores.current = { root, notifyUnavailable };

  // the subscription follows the set of projects only (sorted, so a reorder does not resubscribe)
  const projectKey = sortBy(joinedProjectIds.slice(0, MAX_WORKSPACE_VIEW_PROJECTS)).join(",");

  useEffect(() => {
    const { root: rootStore, notifyUnavailable: notify } = stores.current;
    const projectIds = projectKey ? projectKey.split(",") : [];
    if (!workspaceSlug || !rootStore || projectIds.length === 0) return;
    const workspaceIssues = rootStore.issue.workspaceIssues;
    const workspaceFilter = rootStore.issue.workspaceIssuesFilter;

    // one list refetch at a time for the whole view, shared by the per-project appliers
    let inflight: Promise<unknown> | null = null;
    const refetch = () => {
      const viewId = latest.current.globalViewId;
      if (!viewId) return Promise.resolve();
      inflight ??= workspaceIssues.fetchIssuesWithExistingPagination(workspaceSlug, viewId, "mutation").finally(() => {
        inflight = null;
      });
      return inflight;
    };

    const appliers = new Map<string, LiveWorkItemsApplier>();
    for (const projectId of projectIds) {
      appliers.set(
        projectId,
        new LiveWorkItemsApplier(
          buildApplierDeps(rootStore, {
            workspaceSlug,
            projectId,
            getRoute: () => ({ globalViewId: latest.current.globalViewId }),
            getCurrentUserId: () => latest.current.userId,
            workspace: {
              issues: workspaceIssues,
              refetch,
              getRichFilters: () => workspaceFilter.getIssueFilters(latest.current.globalViewId)?.richFilters,
            },
            onIssueUnavailable: notify,
          })
        )
      );
    }

    const unsubscribe = getLiveEventsClient().subscribeMany(workspaceSlug, projectIds, (event) =>
      appliers.get(event.project_id)?.handle(event)
    );
    return () => {
      unsubscribe();
      appliers.forEach((applier) => applier.dispose());
    };
  }, [workspaceSlug, projectKey]);
};
