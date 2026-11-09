/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-106, PLN-107): the per-user settings record, GET/PATCH /api/users/me/fork-settings/

import { API_BASE_URL } from "@plane/constants";
import type {
  IIssueDisplayFilterOptions,
  IIssueDisplayProperties,
  TIssueLayouts,
  TWorkItemFilterExpression,
} from "@plane/types";
import { APIService } from "@/services/api.service";

export type TGlobalBoardTemplate = {
  layout?: TIssueLayouts | null;
  display_filters?: IIssueDisplayFilterOptions | null;
  display_properties?: IIssueDisplayProperties | null;
  /** portable conditions only, see portable-filters.ts */
  filters?: TWorkItemFilterExpression | null;
};

export type TGlobalBoardSettings = {
  enabled: boolean;
  template: TGlobalBoardTemplate | null;
  /** project-specific conditions while the template is on, per project id */
  project_filters: Record<string, TWorkItemFilterExpression>;
};

export type TForkUserSettings = {
  global_board: TGlobalBoardSettings;
  auto_collapse_empty_groups: boolean;
};

export type TForkUserSettingsResponse = { settings: TForkUserSettings; version: number };

export type TForkUserSettingsPatch = {
  global_board?: {
    enabled?: boolean;
    template?: TGlobalBoardTemplate | null;
    /** a null value removes that project's entry; null for the whole map clears every entry */
    project_filters?: Record<string, TWorkItemFilterExpression | null> | null;
  };
  auto_collapse_empty_groups?: boolean;
};

export const DEFAULT_FORK_USER_SETTINGS: TForkUserSettings = {
  global_board: { enabled: false, template: null, project_filters: {} },
  auto_collapse_empty_groups: false,
};

export class ForkUserSettingsService extends APIService {
  constructor() {
    super(API_BASE_URL);
  }

  async fetch(): Promise<TForkUserSettingsResponse> {
    return this.get("/api/users/me/fork-settings/")
      .then((response) => response?.data)
      .catch((error) => {
        throw error?.response?.data;
      });
  }

  async update(data: TForkUserSettingsPatch): Promise<TForkUserSettingsResponse> {
    return this.patch("/api/users/me/fork-settings/", data)
      .then((response) => response?.data)
      .catch((error) => {
        throw error?.response?.data;
      });
  }
}
