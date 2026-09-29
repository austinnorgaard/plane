/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { runInAction } from "mobx";
import { clone } from "lodash-es";
// plane imports
import type { TIssue } from "@plane/types";
// services
import { IssueService } from "@/services/issue/issue.service";
// local imports
import type { TLiveEvent, TLiveItem } from "./client";
import type { IProjectIssues } from "@/store/issue/project";
import type { ICycleIssues } from "@/store/issue/cycle";
import type { IModuleIssues } from "@/store/issue/module";
import type { IProjectViewIssues } from "@/store/issue/project-views";
import type { IIssueDetail } from "@/store/issue/issue-details/root.store";
import type { IIssueStore } from "@/store/issue/issue.store";
import { EIssueGroupedAction } from "@/store/issue/helpers/base-issues.store";
import type { IBaseIssuesStore } from "@/store/issue/helpers/base-issues.store";

export const APPLY_DEBOUNCE_MS = 300;
export const APPLY_DEBOUNCE_MAX_MS = 1000;
export const COARSE_DEBOUNCE_MS = 1000;
export const CHUNK_SIZE = 50;
export const PEEK_FETCH_THROTTLE_MS = 2000;
export const OWN_ACTOR_DELAY_MS = 1500;

// ---------------------------------------------------------------------------
// pure decision logic
// ---------------------------------------------------------------------------

export type TListScope =
  | { kind: "project" }
  | { kind: "cycle"; cycleId: string }
  | { kind: "module"; moduleId: string };
export type TStoreAction = "add" | "update" | "remove" | "none";

/** True when the issue belongs in the list a store represents. */
export const isIssueInScope = (
  scope: TListScope,
  projectId: string,
  issue: Pick<TIssue, "project_id" | "cycle_id" | "module_ids">
): boolean => {
  if (issue.project_id !== projectId) return false;
  switch (scope.kind) {
    case "project":
      return true;
    case "cycle":
      return issue.cycle_id === scope.cycleId;
    case "module":
      return (issue.module_ids ?? []).includes(scope.moduleId);
  }
};

/**
 * What a list store has to do with a fetched issue.
 * - in scope and not listed yet: add (local-create semantics, bumps counts)
 * - in scope and listed: update (regroup / resort from the before state)
 * - out of scope and listed: remove
 */
export const decideStoreAction = (params: {
  scope: TListScope;
  projectId: string;
  issue: Pick<TIssue, "project_id" | "cycle_id" | "module_ids">;
  inList: boolean;
}): TStoreAction => {
  const inScope = isIssueInScope(params.scope, params.projectId, params.issue);
  if (inScope) return params.inList ? "update" : "add";
  return params.inList ? "remove" : "none";
};

/** Walks a (sub)grouped id structure and reports whether the id is listed anywhere. */
export const listContainsIssue = (grouped: unknown, issueId: string): boolean => {
  if (Array.isArray(grouped)) return grouped.includes(issueId);
  if (typeof grouped !== "object" || grouped === null) return false;
  return Object.values(grouped).some((value) => listContainsIssue(value, issueId));
};

/** A store is "filtered" when its filter expression is not empty. Filtered lists take the coarse path. */
export const isFilterExpressionActive = (richFilters: unknown): boolean =>
  typeof richFilters === "object" && richFilters !== null && Object.keys(richFilters).length > 0;

export const chunkIds = (ids: string[], size: number = CHUNK_SIZE): string[][] => {
  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += size) chunks.push(ids.slice(i, i + size));
  return chunks;
};

export const changeKey = (kind: string, verb: string) => `${kind}:${verb}`;

/** kinds x verbs of one hub item, as the keys the applier accumulates per issue */
export const itemChangeKeys = (item: Pick<TLiveItem, "kinds" | "verbs">): string[] => {
  const kinds = item.kinds.length > 0 ? item.kinds : ["issue"];
  const verbs = item.verbs.length > 0 ? item.verbs : ["updated"];
  return kinds.flatMap((kind) => verbs.map((verb) => changeKey(kind, verb)));
};

/** True when every actor of the item is the current user (an item without actors is never "own"). */
export const isOwnItem = (item: Pick<TLiveItem, "actor_ids">, currentUserId: string | undefined): boolean =>
  !!currentUserId && item.actor_ids.length > 0 && item.actor_ids.every((id) => id === currentUserId);

const isCommentKey = (key: string) => key.startsWith("comment:") || key.startsWith("comment_reaction:");

/** A comment was updated, deleted or reacted to: the cached comment list of the issue is stale. */
export const shouldResetComments = (keys: Iterable<string>): boolean => {
  for (const key of keys) if (isCommentKey(key) && key !== changeKey("comment", "created")) return true;
  return false;
};

/** The batch carries an issue delete for the id: the only case where the issue map entry may be dropped. */
export const hasIssueDeleted = (keys: Iterable<string>): boolean => {
  for (const key of keys) if (key === changeKey("issue", "deleted")) return true;
  return false;
};

/** Best effort: the service rethrows only the response body, so the status may be missing. */
export const isNotFoundError = (error: unknown): boolean => {
  if (typeof error !== "object" || error === null) return false;
  const body = error as { status?: unknown; status_code?: unknown; error?: unknown; detail?: unknown };
  if (body.status === 404 || body.status_code === 404) return true;
  const text = typeof body.error === "string" ? body.error : typeof body.detail === "string" ? body.detail : "";
  return /not found/i.test(text);
};

/** Any comment change at all. */
export const hasCommentChange = (keys: Iterable<string>): boolean => {
  for (const key of keys) if (isCommentKey(key)) return true;
  return false;
};

// ---------------------------------------------------------------------------
// applier
// ---------------------------------------------------------------------------

export type TLiveRoute = { cycleId?: string; moduleId?: string; viewId?: string };

export interface ILiveApplierDeps {
  workspaceSlug: string;
  projectId: string;
  getRoute: () => TLiveRoute;
  getCurrentUserId: () => string | undefined;
  issueMap: IIssueStore;
  projectIssues: IProjectIssues;
  cycleIssues: ICycleIssues;
  moduleIssues: IModuleIssues;
  viewIssues: IProjectViewIssues;
  getFilterExpression: (store: "project" | "cycle" | "module" | "view") => unknown;
  issueDetail: IIssueDetail;
  onIssueMissingFromPeek: () => void;
}

type TListTarget = {
  store: IBaseIssuesStore;
  scope: TListScope;
  coarse: boolean;
  refetch: () => Promise<unknown>;
};

export class LiveWorkItemsApplier {
  private issueService = new IssueService();
  private pending = new Map<string, Set<string>>();
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private debounceStartedAt = 0;
  private coarseTimer: ReturnType<typeof setTimeout> | undefined;
  private coarseAll = false;
  private ownActorTimers = new Set<ReturnType<typeof setTimeout>>();
  private lastPeekFetch = new Map<string, number>();
  private peekTrailingTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private disposed = false;

  private deps: ILiveApplierDeps;

  constructor(deps: ILiveApplierDeps) {
    this.deps = deps;
  }

  dispose() {
    this.disposed = true;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    if (this.coarseTimer) clearTimeout(this.coarseTimer);
    this.ownActorTimers.forEach((timer) => clearTimeout(timer));
    this.peekTrailingTimers.forEach((timer) => clearTimeout(timer));
    this.ownActorTimers.clear();
    this.peekTrailingTimers.clear();
    this.pending.clear();
  }

  /** Entry point for every event of the project. */
  handle(event: TLiveEvent) {
    if (this.disposed || event.project_id !== this.deps.projectId) return;

    if (event.type === "revoked") {
      // access lost: close an open peek, the lists follow through the coarse refresh
      if (this.getOpenIssueIds().length > 0) this.closePeek();
      this.scheduleCoarse(true);
      return;
    }

    if (event.type === "resync" || event.full_refresh) {
      this.scheduleCoarse(true);
      // an open peek is not part of any list, refresh it too
      const peeked = this.getOpenIssueIds();
      if (peeked.length > 0) this.enqueue(peeked, [changeKey("issue", "updated")]);
      return;
    }

    const currentUserId = this.deps.getCurrentUserId();
    const own: TLiveItem[] = [];
    for (const item of event.items) {
      if (isOwnItem(item, currentUserId)) own.push(item);
      else this.enqueue([item.issue_id], itemChangeKeys(item));
    }
    if (own.length === 0) return;
    // the user's own change is already applied locally: delay it, never drop it
    const timer = setTimeout(() => {
      this.ownActorTimers.delete(timer);
      own.forEach((item) => this.enqueue([item.issue_id], itemChangeKeys(item)));
    }, OWN_ACTOR_DELAY_MS);
    this.ownActorTimers.add(timer);
  }

  private enqueue(issueIds: string[], keys: string[]) {
    if (issueIds.length === 0) return;
    for (const id of issueIds) {
      const kinds = this.pending.get(id) ?? new Set<string>();
      keys.forEach((key) => kinds.add(key));
      this.pending.set(id, kinds);
    }
    const now = Date.now();
    if (!this.debounceTimer) this.debounceStartedAt = now;
    else clearTimeout(this.debounceTimer);
    // trailing debounce, but never wait longer than the max window
    const wait = Math.max(0, Math.min(APPLY_DEBOUNCE_MS, this.debounceStartedAt + APPLY_DEBOUNCE_MAX_MS - now));
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      void this.flush();
    }, wait);
  }

  private scheduleCoarse(all: boolean) {
    if (all) this.coarseAll = true;
    if (this.coarseTimer) return;
    this.coarseTimer = setTimeout(() => {
      this.coarseTimer = undefined;
      const includeAll = this.coarseAll;
      this.coarseAll = false;
      void this.runCoarse(includeAll);
    }, COARSE_DEBOUNCE_MS);
  }

  private async runCoarse(all: boolean) {
    if (this.disposed) return;
    const targets = this.getTargets().filter((target) => all || target.coarse);
    await Promise.all(
      targets.map((target) => target.refetch().catch((error: unknown) => console.error("live refresh failed", error)))
    );
  }

  private getOpenIssueIds(): string[] {
    const peek = this.deps.issueDetail.peekIssue;
    if (!peek || peek.projectId !== this.deps.projectId) return [];
    return [peek.issueId];
  }

  /** The list stores that are on screen for the current route. */
  private getTargets(): TListTarget[] {
    const { workspaceSlug, projectId } = this.deps;
    const route = this.deps.getRoute();
    const targets: TListTarget[] = [];
    if (route.cycleId) {
      const cycleId = route.cycleId;
      const store = this.deps.cycleIssues;
      targets.push({
        store,
        scope: { kind: "cycle", cycleId },
        coarse: isFilterExpressionActive(this.deps.getFilterExpression("cycle")),
        refetch: () => store.fetchIssuesWithExistingPagination(workspaceSlug, projectId, "mutation", cycleId),
      });
    } else if (route.moduleId) {
      const moduleId = route.moduleId;
      const store = this.deps.moduleIssues;
      targets.push({
        store,
        scope: { kind: "module", moduleId },
        coarse: isFilterExpressionActive(this.deps.getFilterExpression("module")),
        refetch: () => store.fetchIssuesWithExistingPagination(workspaceSlug, projectId, "mutation", moduleId),
      });
    } else if (route.viewId) {
      const viewId = route.viewId;
      const store = this.deps.viewIssues;
      targets.push({
        store,
        scope: { kind: "project" },
        // a saved view is always a filtered list
        coarse: true,
        refetch: () => store.fetchIssuesWithExistingPagination(workspaceSlug, projectId, viewId, "mutation"),
      });
    } else {
      const store = this.deps.projectIssues;
      targets.push({
        store,
        scope: { kind: "project" },
        coarse: isFilterExpressionActive(this.deps.getFilterExpression("project")),
        refetch: () => store.fetchIssuesWithExistingPagination(workspaceSlug, projectId, "mutation"),
      });
    }
    // a store that has never loaded has nothing to update
    return targets.filter((target) => target.store.groupedIssueIds !== undefined);
  }

  private async flush() {
    if (this.disposed || this.pending.size === 0) return;
    const batch = this.pending;
    this.pending = new Map();
    const { workspaceSlug, projectId, issueMap } = this.deps;

    const fetched = new Map<string, TIssue>();
    const missing: string[] = [];
    try {
      const responses = await Promise.all(
        chunkIds([...batch.keys()]).map(async (chunk) => ({
          chunk,
          issues: await this.issueService.retrieveIssues(workspaceSlug, projectId, chunk),
        }))
      );
      for (const { chunk, issues } of responses) {
        const found = new Set<string>();
        for (const issue of issues ?? []) {
          fetched.set(issue.id, issue);
          found.add(issue.id);
        }
        chunk.forEach((id) => !found.has(id) && missing.push(id));
      }
    } catch (error) {
      // could not tell what changed: fall back to the coarse refresh instead of guessing
      console.error("live work item fetch failed", error);
      this.scheduleCoarse(true);
      return;
    }
    if (this.disposed) return;

    const targets = this.getTargets();
    const listTargets = targets.filter((target) => !target.coarse);
    const coarseNeeded = targets.some((target) => target.coarse);

    // states before the map is touched, updateIssueList needs them to regroup
    const before = new Map<string, TIssue | undefined>();
    fetched.forEach((_issue, id) => {
      const existing = issueMap.getIssueById(id);
      before.set(id, existing ? clone(existing) : undefined);
    });

    runInAction(() => {
      if (fetched.size > 0) issueMap.addIssue([...fetched.values()]);

      fetched.forEach((_issue, id) => {
        const after = issueMap.getIssueById(id);
        if (!after) return;
        const beforeState = before.get(id);
        for (const target of listTargets) {
          const action = decideStoreAction({
            scope: target.scope,
            projectId,
            issue: after,
            inList: listContainsIssue(target.store.groupedIssueIds, id),
          });
          if (action === "add") target.store.addIssueToList(id);
          else if (action === "update") target.store.updateIssueList(after, beforeState);
          else if (action === "remove")
            target.store.updateIssueList(undefined, beforeState ?? after, EIssueGroupedAction.DELETE);
        }
      });

      // removeIssueFromList reads the issue map, so the map entry must outlive it. The list endpoint also
      // omits archived, draft and intake work items, so only an issue delete drops the map entry.
      for (const id of missing) {
        for (const target of listTargets) target.store.removeIssueFromList(id);
        if (hasIssueDeleted(batch.get(id) ?? [])) issueMap.removeIssue(id);
      }
    });

    if (coarseNeeded) this.scheduleCoarse(false);
    await this.refreshOpenIssues(batch, new Set(missing.filter((id) => hasIssueDeleted(batch.get(id) ?? []))));
  }

  // ---- peek / detail ----

  private async refreshOpenIssues(batch: Map<string, Set<string>>, deleted: Set<string>) {
    const refreshes: Promise<void>[] = [];
    for (const issueId of this.getOpenIssueIds()) {
      const kinds = batch.get(issueId);
      if (!kinds) continue;
      if (deleted.has(issueId)) {
        // deleted: never fetchIssue on it
        this.closePeek();
        continue;
      }
      refreshes.push(this.refreshIssueDetail(issueId, kinds));
    }
    await Promise.all(refreshes);
  }

  private closePeek() {
    this.deps.issueDetail.setPeekIssue(undefined);
    this.deps.onIssueMissingFromPeek();
  }

  private async refreshIssueDetail(issueId: string, kinds: Set<string>) {
    const { workspaceSlug, projectId, issueDetail } = this.deps;
    const hasCommentEvent = hasCommentChange(kinds);
    // fetchIssue refetches activities and comments itself; otherwise they are refetched here
    const fetchedIssue = this.throttledFetchIssue(issueId, () => {
      if (shouldResetComments(kinds)) this.resetComments(issueId);
    });
    if (fetchedIssue) return;
    try {
      if (hasCommentEvent) {
        if (shouldResetComments(kinds)) this.resetComments(issueId);
        await issueDetail.fetchComments(workspaceSlug, projectId, issueId, "mutate");
      }
      await issueDetail.fetchActivities(workspaceSlug, projectId, issueId, "mutate");
    } catch (error) {
      console.error("live detail refresh failed", error);
    }
  }

  private resetComments(issueId: string) {
    const comments = this.deps.issueDetail.comment.comments;
    runInAction(() => {
      delete comments[issueId];
    });
  }

  private fetchIssueDetail(issueId: string) {
    const { workspaceSlug, projectId, issueDetail } = this.deps;
    issueDetail.fetchIssue(workspaceSlug, projectId, issueId).catch((error: unknown) => {
      // gone or no longer visible: close the peek, anything else is transient
      if (isNotFoundError(error) && this.getOpenIssueIds().includes(issueId)) this.closePeek();
      else console.error("live detail fetch failed", error);
    });
  }

  /**
   * At most one fetchIssue per issue every PEEK_FETCH_THROTTLE_MS. Returns true when a fetch was started now;
   * otherwise a trailing fetch is scheduled and the caller refreshes comments and activities itself.
   */
  private throttledFetchIssue(issueId: string, beforeFetch: () => void): boolean {
    const now = Date.now();
    const last = this.lastPeekFetch.get(issueId) ?? -Infinity;
    if (now - last >= PEEK_FETCH_THROTTLE_MS) {
      this.lastPeekFetch.set(issueId, now);
      beforeFetch();
      this.fetchIssueDetail(issueId);
      return true;
    }
    if (!this.peekTrailingTimers.has(issueId)) {
      const timer = setTimeout(
        () => {
          this.peekTrailingTimers.delete(issueId);
          if (this.disposed || !this.getOpenIssueIds().includes(issueId)) return;
          this.lastPeekFetch.set(issueId, Date.now());
          this.fetchIssueDetail(issueId);
        },
        Math.max(0, PEEK_FETCH_THROTTLE_MS - (now - last))
      );
      this.peekTrailingTimers.set(issueId, timer);
    }
    return false;
  }
}
