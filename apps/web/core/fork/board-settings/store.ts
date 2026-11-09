/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-106, PLN-107): the current user's fork settings, shared by every board in the tab.

import { action, makeObservable, observable, runInAction } from "mobx";
// local imports
import type { TForkUserSettings, TForkUserSettingsPatch, TForkUserSettingsResponse } from "./service";
import { DEFAULT_FORK_USER_SETTINGS, ForkUserSettingsService } from "./service";

export type TForkSettingsChangeSource = "local" | "remote";
export type TForkSettingsListener = (
  next: TForkUserSettings,
  previous: TForkUserSettings,
  source: TForkSettingsChangeSource
) => void;

const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

/** Applies a patch the way the API merges it (global_board one level deep, project_filters per project). */
export const mergeForkSettings = (current: TForkUserSettings, patch: TForkUserSettingsPatch): TForkUserSettings => {
  const next = clone(current);
  if (patch.auto_collapse_empty_groups !== undefined)
    next.auto_collapse_empty_groups = patch.auto_collapse_empty_groups;
  const board = patch.global_board;
  if (board) {
    if (board.enabled !== undefined) next.global_board.enabled = board.enabled;
    if (board.template !== undefined) next.global_board.template = board.template;
    if (board.project_filters === null) next.global_board.project_filters = {};
    else if (board.project_filters) {
      for (const [projectId, expression] of Object.entries(board.project_filters)) {
        if (expression === null) delete next.global_board.project_filters[projectId];
        else next.global_board.project_filters[projectId] = expression;
      }
    }
  }
  return next;
};

export class ForkUserSettingsStore {
  settings: TForkUserSettings = clone(DEFAULT_FORK_USER_SETTINGS);
  version = 0;
  /** the user the settings belong to; undefined until the first fetch finished */
  userId: string | undefined = undefined;

  private service = new ForkUserSettingsService();
  private loading: Promise<void> | undefined;
  private loadingFor: string | undefined;
  private listeners = new Set<TForkSettingsListener>();

  constructor() {
    makeObservable(this, {
      settings: observable.ref,
      version: observable,
      userId: observable,
      update: action,
    });
  }

  /** True once the settings of this user are loaded. */
  isLoadedFor = (userId: string | undefined) => !!userId && this.userId === userId;

  subscribe(listener: TForkSettingsListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** Loads the settings once per user. Never throws: on failure the defaults (all off) stay in place. */
  ensure(userId: string | undefined): Promise<void> {
    if (!userId) return Promise.resolve();
    if (this.userId === userId) return Promise.resolve();
    if (this.loading && this.loadingFor === userId) return this.loading;
    this.loadingFor = userId;
    this.loading = this.service
      .fetch()
      .then((response) => this.set(response, "remote", userId, true))
      .catch((error: unknown) => console.error("fork settings fetch failed", error))
      .finally(() => {
        if (this.loadingFor === userId) this.loading = undefined;
      });
    return this.loading;
  }

  /** Refetches when the server may hold a newer version (a live event, or a resync after a gap). */
  async refresh(minVersion?: number): Promise<void> {
    const userId = this.userId;
    if (!userId) return;
    if (minVersion !== undefined && minVersion <= this.version) return;
    try {
      const response = await this.service.fetch();
      this.set(response, "remote", userId, false);
    } catch (error) {
      console.error("fork settings refresh failed", error);
    }
  }

  /** Optimistic update. On failure the server state is fetched again and the error rethrown. */
  update = async (patch: TForkUserSettingsPatch): Promise<void> => {
    const userId = this.userId;
    if (!userId) throw new Error("fork settings are not loaded");
    const previous = this.settings;
    const next = mergeForkSettings(previous, patch);
    this.settings = next;
    this.notify(next, previous, "local");
    try {
      const response = await this.service.update(patch);
      // the response is this write's own result: a newer version was already applied by a live refresh
      runInAction(() => {
        if (this.userId === userId && response.version > this.version) this.version = response.version;
      });
    } catch (error) {
      await this.refresh();
      throw error;
    }
  };

  private set(response: TForkUserSettingsResponse, source: TForkSettingsChangeSource, userId: string, first: boolean) {
    if (!response?.settings) return;
    // a stale response (older than what this tab already has) is ignored
    if (!first && (this.userId !== userId || response.version <= this.version)) return;
    const previous = first ? clone(DEFAULT_FORK_USER_SETTINGS) : this.settings;
    const next = mergeForkSettings(clone(DEFAULT_FORK_USER_SETTINGS), {
      global_board: response.settings.global_board,
      auto_collapse_empty_groups: response.settings.auto_collapse_empty_groups,
    });
    runInAction(() => {
      this.settings = next;
      this.version = response.version;
      this.userId = userId;
    });
    this.notify(next, previous, source);
  }

  private notify(next: TForkUserSettings, previous: TForkUserSettings, source: TForkSettingsChangeSource) {
    for (const listener of this.listeners) {
      try {
        listener(next, previous, source);
      } catch (error) {
        console.error("fork settings listener failed", error);
      }
    }
  }
}

let singleton: ForkUserSettingsStore | undefined;
export const getForkUserSettingsStore = (): ForkUserSettingsStore => (singleton ??= new ForkUserSettingsStore());
