/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-106): Profile settings > Preferences toggle for the global board template.

import { useEffect, useState } from "react";
import { observer } from "mobx-react";
// plane imports
import { useTranslation } from "@plane/i18n";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
import { EIssuesStoreType } from "@plane/types";
import { ToggleSwitch } from "@plane/ui";
// components
import { SettingsControlItem } from "@/components/settings/control-item";
// hooks
import { useIssues } from "@/hooks/store/use-issues";
import { useUser } from "@/hooks/store/user";
// local imports
import { getForkUserSettingsStore } from "../store";

export const GlobalBoardPreferenceToggle = observer(function GlobalBoardPreferenceToggle() {
  const { t } = useTranslation();
  const { data: currentUser } = useUser();
  const { issuesFilter } = useIssues(EIssuesStoreType.PROJECT);
  const store = getForkUserSettingsStore();
  const [saving, setSaving] = useState(false);
  const userId = currentUser?.id;

  useEffect(() => {
    void store.ensure(userId);
  }, [store, userId]);

  const loaded = store.isLoadedFor(userId);
  const enabled = loaded && store.settings.global_board.enabled;

  const handleChange = async (value: boolean) => {
    if (!loaded || saving) return;
    setSaving(true);
    try {
      await issuesFilter.forkBoard.setEnabled(value);
    } catch (_error) {
      setToast({ type: TOAST_TYPE.ERROR, title: t("error"), message: t("something_went_wrong") });
    } finally {
      setSaving(false);
    }
  };

  return (
    <SettingsControlItem
      title={t("account_settings.preferences.global_board_title")}
      description={t("account_settings.preferences.global_board_description")}
      control={
        <ToggleSwitch
          value={enabled}
          onChange={(value) => void handleChange(value)}
          disabled={!loaded || saving}
          size="sm"
        />
      }
    />
  );
});
