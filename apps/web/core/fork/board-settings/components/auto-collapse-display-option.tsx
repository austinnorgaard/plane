/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-107): the auto-collapse setting, mirrored in every board's display menu.

import { useEffect } from "react";
import { observer } from "mobx-react";
// plane imports
import { useTranslation } from "@plane/i18n";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
// components
import { FilterOption } from "@/components/issues/issue-layouts/filters/header/helpers/filter-option";
// hooks
import { useUser } from "@/hooks/store/user";
// local imports
import { getForkUserSettingsStore } from "../store";

export const AutoCollapseDisplayOption = observer(function AutoCollapseDisplayOption() {
  const { t } = useTranslation();
  const { data: currentUser } = useUser();
  const userId = currentUser?.id;
  const store = getForkUserSettingsStore();

  useEffect(() => {
    void store.ensure(userId);
  }, [store, userId]);

  if (!store.isLoadedFor(userId)) return null;
  const enabled = store.settings.auto_collapse_empty_groups;

  return (
    <FilterOption
      isChecked={enabled}
      onClick={() =>
        store
          .update({ auto_collapse_empty_groups: !enabled })
          .catch(() => setToast({ type: TOAST_TYPE.ERROR, title: t("error"), message: t("something_went_wrong") }))
      }
      title={t("account_settings.preferences.auto_collapse_title")}
    />
  );
});
