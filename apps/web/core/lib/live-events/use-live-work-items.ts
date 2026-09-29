/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { useContext, useEffect, useRef } from "react";
import { useParams } from "react-router";
// plane imports
import { EIssuesStoreType } from "@plane/types";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
// hooks
import { useIssueDetail } from "@/hooks/store/use-issue-detail";
import { useIssues } from "@/hooks/store/use-issues";
import { useUser } from "@/hooks/store/user";
import { StoreContext } from "@/lib/store-context";
// local imports
import { LiveWorkItemsApplier } from "./apply";
import { getLiveEventsClient } from "./client";

/**
 * Keeps the work item lists and the open peek of a project live.
 * Mounted once in the project layout; subscribes while the project is on screen.
 */
export const useLiveWorkItems = (workspaceSlug: string | undefined, projectId: string | undefined) => {
  const { cycleId, moduleId, viewId } = useParams();
  const storeContext = useContext(StoreContext);
  const { data: currentUser } = useUser();
  const issueDetail = useIssueDetail();
  const projectStore = useIssues(EIssuesStoreType.PROJECT);
  const cycleStore = useIssues(EIssuesStoreType.CYCLE);
  const moduleStore = useIssues(EIssuesStoreType.MODULE);
  const viewStore = useIssues(EIssuesStoreType.PROJECT_VIEW);

  // the applier reads the latest values without being recreated on every navigation inside the project
  const latest = useRef({ cycleId, moduleId, viewId, userId: currentUser?.id });
  latest.current = { cycleId, moduleId, viewId, userId: currentUser?.id };
  // the stores are stable singletons, read through a ref so the subscription only follows the project
  const stores = useRef({ storeContext, issueDetail, projectStore, cycleStore, moduleStore, viewStore });
  stores.current = { storeContext, issueDetail, projectStore, cycleStore, moduleStore, viewStore };

  useEffect(() => {
    const s = stores.current;
    const root = s.storeContext;
    if (!workspaceSlug || !projectId || !root) return;
    const applier = new LiveWorkItemsApplier({
      workspaceSlug,
      projectId,
      getRoute: () => ({
        cycleId: latest.current.cycleId,
        moduleId: latest.current.moduleId,
        viewId: latest.current.viewId,
      }),
      getCurrentUserId: () => latest.current.userId,
      issueMap: root.issue.issues,
      projectIssues: s.projectStore.issues,
      cycleIssues: s.cycleStore.issues,
      moduleIssues: s.moduleStore.issues,
      viewIssues: s.viewStore.issues,
      getFilterExpression: (which) => {
        const filters = { project: s.projectStore, cycle: s.cycleStore, module: s.moduleStore, view: s.viewStore }[
          which
        ].issuesFilter.issueFilters;
        return filters?.richFilters;
      },
      issueDetail: s.issueDetail,
      // TODO: move the text to i18n keys (needs packages/i18n locale entries)
      onIssueMissingFromPeek: () =>
        setToast({
          type: TOAST_TYPE.INFO,
          title: "Work item unavailable",
          message: "This work item was deleted or you no longer have access to it.",
        }),
    });
    const unsubscribe = getLiveEventsClient().subscribe(workspaceSlug, projectId, (event) => applier.handle(event));
    return () => {
      unsubscribe();
      applier.dispose();
    };
  }, [workspaceSlug, projectId]);
};
