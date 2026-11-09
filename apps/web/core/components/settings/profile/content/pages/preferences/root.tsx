/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { observer } from "mobx-react";
// plane imports
import { useTranslation } from "@plane/i18n";
// components
import { ProfileSettingsHeading } from "@/components/settings/profile/heading";
// hooks
import { useUserProfile } from "@/hooks/store/user";
// local imports
import { ProfileSettingsDefaultPreferencesList } from "./default-list";
import { ProfileSettingsLanguageAndTimezonePreferencesList } from "./language-and-timezone-list";
// fork (PLN-106, PLN-107): board preferences
import { ForkBoardPreferencesList } from "@/fork/board-settings/components/board-preferences-list";

export const PreferencesProfileSettings = observer(function PreferencesProfileSettings() {
  const { t } = useTranslation();
  // hooks
  const { data: userProfile } = useUserProfile();

  if (!userProfile) return null;

  return (
    <div className="size-full">
      <ProfileSettingsHeading
        title={t("account_settings.preferences.heading")}
        description={t("account_settings.preferences.description")}
      />
      <div className="mt-7 flex w-full flex-col gap-6">
        <section>
          <ProfileSettingsDefaultPreferencesList />
        </section>
        <section className="flex flex-col gap-y-3">
          <div className="text-h6-medium text-primary">{t("language_and_time")}</div>
          <ProfileSettingsLanguageAndTimezonePreferencesList />
        </section>
        {/* fork (PLN-106, PLN-107) */}
        <section className="flex flex-col gap-y-3">
          <div className="text-h6-medium text-primary">{t("account_settings.preferences.boards_heading")}</div>
          <ForkBoardPreferencesList />
        </section>
      </div>
    </div>
  );
});
