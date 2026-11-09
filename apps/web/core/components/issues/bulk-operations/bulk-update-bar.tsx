/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

/**
 * fork (PLN-129): a small bulk update bar for the selection in the list and spreadsheet layouts of a project, cycle,
 * module or project view, in place of the upgrade banner. It sets the state and/or priority of the selected work
 * items in one call (`bulk-operation-issues/`: one transaction, activity per work item, one live event).
 */

import { useState } from "react";
import { observer } from "mobx-react";
import { useParams } from "next/navigation";
// plane imports
import { ISSUE_PRIORITIES } from "@plane/constants";
import type { TBulkOperationsPayload, TIssuePriorities } from "@plane/types";
import { useTranslation } from "@plane/i18n";
import { Button } from "@plane/propel/button";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
import { CustomSelect } from "@plane/ui";
import { cn } from "@plane/utils";
// components
import { StateSingleSelect } from "@/components/automation/cycle-automation/state-select";
// hooks
import { useIssues } from "@/hooks/store/use-issues";
import { useMultipleSelectStore } from "@/hooks/store/use-multiple-select-store";
import { useProjectState } from "@/hooks/store/use-project-state";
import { useIssueStoreType } from "@/hooks/use-issue-layout-store";

type TBulkUpdater = {
  bulkUpdateProperties?: (workspaceSlug: string, projectId: string, data: TBulkOperationsPayload) => Promise<void>;
};

type Props = {
  className?: string;
};

export const BulkUpdateBar = observer(function BulkUpdateBar(props: Props) {
  const { className } = props;
  const { workspaceSlug, projectId } = useParams();
  const { t } = useTranslation();
  const storeType = useIssueStoreType();
  const { issues } = useIssues(storeType);
  const { selectedEntityIds, clearSelection } = useMultipleSelectStore();
  const { getProjectStates } = useProjectState();
  const [stateId, setStateId] = useState<string | null>(null);
  const [priority, setPriority] = useState<TIssuePriorities | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const updater = issues as unknown as TBulkUpdater;
  if (!workspaceSlug || !projectId || !updater.bulkUpdateProperties) return null;
  const states = getProjectStates(projectId.toString()) ?? [];

  const onApply = async () => {
    if (!updater.bulkUpdateProperties || (!stateId && !priority)) return;
    setIsSaving(true);
    const issueIds = [...selectedEntityIds];
    try {
      await updater.bulkUpdateProperties(workspaceSlug.toString(), projectId.toString(), {
        issue_ids: issueIds,
        properties: { ...(stateId ? { state_id: stateId } : {}), ...(priority ? { priority } : {}) },
      });
      setToast({ type: TOAST_TYPE.SUCCESS, title: t("cycle_automation.bulk.success", { count: issueIds.length }) });
      setStateId(null);
      setPriority(null);
      clearSelection();
    } catch {
      setToast({ type: TOAST_TYPE.ERROR, title: t("cycle_automation.bulk.error") });
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className={cn("sticky bottom-0 left-0 z-[2] grid h-20 place-items-center px-3.5", className)}>
      <div className="flex h-14 w-full items-center gap-3 rounded-md border border-subtle bg-surface-1 px-3.5 shadow-raised-100">
        <span className="text-13 font-medium text-primary">
          {t("cycle_automation.bulk.selected", { count: selectedEntityIds.length })}
        </span>
        <div className="w-44">
          <StateSingleSelect
            states={states}
            value={stateId}
            onChange={setStateId}
            placeholder={t("cycle_automation.bulk.state")}
            disabled={isSaving}
          />
        </div>
        <div className="w-36">
          <CustomSelect
            value={priority}
            label={
              priority
                ? (ISSUE_PRIORITIES.find((p) => p.key === priority)?.title ?? priority)
                : t("cycle_automation.bulk.priority")
            }
            onChange={(value: TIssuePriorities) => setPriority(value)}
            input
            disabled={isSaving}
          >
            {ISSUE_PRIORITIES.map((p) => (
              <CustomSelect.Option key={p.key} value={p.key}>
                {p.title}
              </CustomSelect.Option>
            ))}
          </CustomSelect>
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Button variant="secondary" size="sm" onClick={() => clearSelection()} disabled={isSaving}>
            {t("cycle_automation.bulk.clear")}
          </Button>
          <Button
            variant="primary"
            size="sm"
            onClick={() => void onApply()}
            loading={isSaving}
            disabled={!stateId && !priority}
          >
            {t("cycle_automation.bulk.apply")}
          </Button>
        </div>
      </div>
    </div>
  );
});
