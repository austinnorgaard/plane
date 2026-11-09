/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { useContext, useEffect, useRef } from "react";
import { useLocation, useParams } from "react-router";
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
  const storeContext = useContext(StoreContext);
  const { data: currentUser } = useUser();
  const issueDetail = useIssueDetail();
  const projectStore = useIssues(EIssuesStoreType.PROJECT);
  const cycleStore = useIssues(EIssuesStoreType.CYCLE);
  const moduleStore = useIssues(EIssuesStoreType.MODULE);
  const viewStore = useIssues(EIssuesStoreType.PROJECT_VIEW);
  const archivedStore = useIssues(EIssuesStoreType.ARCHIVED);

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
  // the stores are stable singletons, read through a ref so the subscription only follows the project
  const stores = useRef({ storeContext, issueDetail, projectStore, cycleStore, moduleStore, viewStore, archivedStore });
  stores.current = { storeContext, issueDetail, projectStore, cycleStore, moduleStore, viewStore, archivedStore };

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
        archived: latest.current.archived,
        intake: latest.current.intake,
      }),
      getCurrentUserId: () => latest.current.userId,
      getPageIssueId: () => latest.current.pageIssueId,
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
      issueDetail: s.issueDetail,
      refreshProjectMetadata: () =>
        Promise.all([
          root.state.fetchProjectStates(workspaceSlug, projectId),
          root.label.fetchProjectLabels(workspaceSlug, projectId),
        ]),
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
