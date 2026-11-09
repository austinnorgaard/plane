/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { useContext, useEffect, useRef } from "react";
import { sortBy } from "lodash-es";
// plane imports
import { EIssuesStoreType } from "@plane/types";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
// hooks
import { useIssueDetail } from "@/hooks/store/use-issue-detail";
import { useIssues } from "@/hooks/store/use-issues";
import { useProject } from "@/hooks/store/use-project";
import { useUser } from "@/hooks/store/user";
import { StoreContext } from "@/lib/store-context";
// local imports
import { LiveWorkItemsApplier } from "./apply";
import { getLiveEventsClient } from "./client";
import { refreshCycleAndModuleDefinitions } from "./metadata";

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
  const storeContext = useContext(StoreContext);
  const { data: currentUser } = useUser();
  const issueDetail = useIssueDetail();
  const { joinedProjectIds } = useProject();
  const projectStore = useIssues(EIssuesStoreType.PROJECT);
  const cycleStore = useIssues(EIssuesStoreType.CYCLE);
  const moduleStore = useIssues(EIssuesStoreType.MODULE);
  const viewStore = useIssues(EIssuesStoreType.PROJECT_VIEW);
  const archivedStore = useIssues(EIssuesStoreType.ARCHIVED);
  const workspaceStore = useIssues(EIssuesStoreType.GLOBAL);

  // read by the appliers without recreating them when the view changes
  const latest = useRef({ globalViewId, userId: currentUser?.id });
  latest.current = { globalViewId, userId: currentUser?.id };
  const stores = useRef({
    storeContext,
    issueDetail,
    projectStore,
    cycleStore,
    moduleStore,
    viewStore,
    archivedStore,
    workspaceStore,
  });
  stores.current = {
    storeContext,
    issueDetail,
    projectStore,
    cycleStore,
    moduleStore,
    viewStore,
    archivedStore,
    workspaceStore,
  };

  // the subscription follows the set of projects only (sorted, so a reorder does not resubscribe)
  const projectKey = sortBy(joinedProjectIds.slice(0, MAX_WORKSPACE_VIEW_PROJECTS)).join(",");

  useEffect(() => {
    const s = stores.current;
    const root = s.storeContext;
    const projectIds = projectKey ? projectKey.split(",") : [];
    if (!workspaceSlug || !root || projectIds.length === 0) return;

    // one list refetch at a time for the whole view, shared by the per-project appliers
    let inflight: Promise<unknown> | null = null;
    const refetch = () => {
      const viewId = latest.current.globalViewId;
      if (!viewId) return Promise.resolve();
      inflight ??= s.workspaceStore.issues
        .fetchIssuesWithExistingPagination(workspaceSlug, viewId, "mutation")
        .finally(() => {
          inflight = null;
        });
      return inflight;
    };

    const appliers = new Map<string, LiveWorkItemsApplier>();
    for (const projectId of projectIds) {
      appliers.set(
        projectId,
        new LiveWorkItemsApplier({
          workspaceSlug,
          projectId,
          getRoute: () => ({ globalViewId: latest.current.globalViewId }),
          getCurrentUserId: () => latest.current.userId,
          issueMap: root.issue.issues,
          projectIssues: s.projectStore.issues,
          cycleIssues: s.cycleStore.issues,
          moduleIssues: s.moduleStore.issues,
          viewIssues: s.viewStore.issues,
          archivedIssues: s.archivedStore.issues,
          projectInbox: root.projectInbox,
          getStateGroup: (stateId) => root.state.stateMap?.[stateId]?.group,
          getFilterExpression: (which) => {
            const filters = { project: s.projectStore, cycle: s.cycleStore, module: s.moduleStore, view: s.viewStore }[
              which
            ].issuesFilter.issueFilters;
            return filters?.richFilters;
          },
          workspace: {
            issues: s.workspaceStore.issues,
            refetch,
            getRichFilters: () =>
              s.workspaceStore.issuesFilter.getIssueFilters(latest.current.globalViewId)?.richFilters,
          },
          issueDetail: s.issueDetail,
          refreshProjectMetadata: () =>
            Promise.all([
              root.state.fetchProjectStates(workspaceSlug, projectId),
              root.label.fetchProjectLabels(workspaceSlug, projectId),
              // PLN-36: cycle and module definitions (quiet: no loader, deleted ones are dropped)
              refreshCycleAndModuleDefinitions(root, workspaceSlug, projectId),
            ]),
          // TODO: move the text to i18n keys (needs packages/i18n locale entries)
          onIssueMissingFromPeek: () =>
            setToast({
              type: TOAST_TYPE.INFO,
              title: "Work item unavailable",
              message: "This work item was deleted or you no longer have access to it.",
            }),
        })
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
