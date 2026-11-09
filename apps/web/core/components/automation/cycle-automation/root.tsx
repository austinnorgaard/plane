/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

/**
 * PLN-129: Project settings > Automations > Cycle automation. An ordered list of rules: when a cycle starts or
 * completes, move its work items from some states to one state. Rules of one trigger run in this order, each
 * seeing the result of the previous one. Admins edit; the page itself is admin only.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { sortBy } from "lodash-es";
import { observer } from "mobx-react";
import { ChevronDown, ChevronUp, Repeat, Trash2 } from "lucide-react";
// plane imports
import { useTranslation } from "@plane/i18n";
import { Button } from "@plane/propel/button";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
import type { IState } from "@plane/types";
import { CustomSelect, ToggleSwitch } from "@plane/ui";
// components
import { SettingsControlItem } from "@/components/settings/control-item";
// hooks
import { useProjectState } from "@/hooks/store/use-project-state";
// services
import { CycleAutomationService } from "@/services/cycle-automation.service";
import type {
  TCycleAutomationRule,
  TCycleAutomationRulePayload,
  TCycleAutomationTrigger,
} from "@/services/cycle-automation.service";
// local imports
import { StateMultiSelect, StateSingleSelect } from "./state-select";

const service = new CycleAutomationService();
const TRIGGERS: TCycleAutomationTrigger[] = ["cycle_started", "cycle_completed"];

const byName = (states: IState[], name: string) =>
  states.find((state) => state.name.trim().toLowerCase() === name.toLowerCase());

/** The preset rules: on start Backlog -> Todo, on completion Testing Complete -> Done (null when a state is missing). */
const buildPreset = (states: IState[], which: "start" | "complete"): TCycleAutomationRulePayload | null => {
  if (which === "start") {
    const from = states.filter((state) => state.group === "backlog").map((state) => state.id);
    const to = byName(states, "Todo") ?? states.find((state) => state.group === "unstarted");
    if (!from.length || !to) return null;
    return { trigger: "cycle_started", from_state_ids: from, to_state_id: to.id, is_enabled: false };
  }
  const from = byName(states, "Testing Complete");
  const to = byName(states, "Done") ?? states.find((state) => state.group === "completed");
  if (!from || !to || from.id === to.id) return null;
  return { trigger: "cycle_completed", from_state_ids: [from.id], to_state_id: to.id, is_enabled: false };
};

type Props = {
  workspaceSlug: string;
  projectId: string;
  isAdmin: boolean;
};

export const CycleAutomation = observer(function CycleAutomation(props: Props) {
  const { workspaceSlug, projectId, isAdmin } = props;
  const { t } = useTranslation();
  const { projectStates } = useProjectState();
  const states = useMemo(() => projectStates ?? [], [projectStates]);
  const [rules, setRules] = useState<TCycleAutomationRule[] | undefined>(undefined);
  const [busy, setBusy] = useState(false);

  const showError = useCallback(
    (key: "load" | "save", err?: unknown) => {
      const detail =
        err && typeof err === "object" ? Object.values(err as Record<string, unknown>).flat()[0] : undefined;
      setToast({
        type: TOAST_TYPE.ERROR,
        title: t(`cycle_automation.errors.${key}`),
        message: typeof detail === "string" ? detail : undefined,
      });
    },
    [t]
  );

  useEffect(() => {
    let cancelled = false;
    service
      .listRules(workspaceSlug, projectId)
      .then((list) => !cancelled && setRules(list))
      .catch(() => !cancelled && showError("load"));
    return () => {
      cancelled = true;
    };
  }, [workspaceSlug, projectId, showError]);

  const sorted = useMemo(() => sortBy(rules ?? [], "sort_order"), [rules]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (err) {
      showError("save", err);
    } finally {
      setBusy(false);
    }
  };

  const createRule = (payload: TCycleAutomationRulePayload) =>
    run(async () => {
      const last = sorted[sorted.length - 1];
      const created = await service.createRule(workspaceSlug, projectId, {
        ...payload,
        sort_order: (last?.sort_order ?? 0) + 1000,
      });
      setRules((list) => [...(list ?? []), created]);
    });

  const updateRule = (rule: TCycleAutomationRule, payload: TCycleAutomationRulePayload) =>
    run(async () => {
      const updated = await service.updateRule(workspaceSlug, projectId, rule.id, payload);
      setRules((list) => list?.map((item) => (item.id === updated.id ? updated : item)));
    });

  const deleteRule = (rule: TCycleAutomationRule) =>
    run(async () => {
      await service.deleteRule(workspaceSlug, projectId, rule.id);
      setRules((list) => list?.filter((item) => item.id !== rule.id));
    });

  const swap = (index: number, other: number) =>
    run(async () => {
      const a = sorted[index];
      const b = sorted[other];
      if (!a || !b) return;
      const [updatedA, updatedB] = await Promise.all([
        service.updateRule(workspaceSlug, projectId, a.id, { sort_order: b.sort_order }),
        service.updateRule(workspaceSlug, projectId, b.id, { sort_order: a.sort_order }),
      ]);
      setRules((list) =>
        list?.map((item) => (item.id === updatedA.id ? updatedA : item.id === updatedB.id ? updatedB : item))
      );
    });

  const startPreset = buildPreset(states, "start");
  const completePreset = buildPreset(states, "complete");
  const disabled = !isAdmin || busy;

  return (
    <div className="flex flex-col gap-4 py-2">
      <div className="flex items-center gap-3">
        <div className="grid size-10 shrink-0 place-items-center rounded-sm bg-layer-2">
          <Repeat className="size-4 shrink-0 text-secondary" />
        </div>
        <SettingsControlItem
          title={t("cycle_automation.title")}
          description={t("cycle_automation.description")}
          control={null}
        />
      </div>
      <div className="ml-13 flex flex-col gap-3">
        {rules !== undefined && sorted.length === 0 && (
          <p className="text-13 text-tertiary">{t("cycle_automation.empty")}</p>
        )}
        {sorted.map((rule, index) => (
          <div
            key={rule.id}
            className="flex flex-wrap items-center gap-2 rounded-sm border border-subtle bg-surface-2 px-4 py-3"
          >
            <div className="w-44">
              <CustomSelect
                value={rule.trigger}
                label={t(`cycle_automation.trigger.${rule.trigger}`)}
                onChange={(value: TCycleAutomationTrigger) => void updateRule(rule, { trigger: value })}
                input
                disabled={disabled}
              >
                {TRIGGERS.map((trigger) => (
                  <CustomSelect.Option key={trigger} value={trigger}>
                    {t(`cycle_automation.trigger.${trigger}`)}
                  </CustomSelect.Option>
                ))}
              </CustomSelect>
            </div>
            <span className="text-13 text-secondary">{t("cycle_automation.from")}</span>
            <div className="w-48">
              <StateMultiSelect
                states={states}
                value={rule.from_state_ids}
                onChange={(value) => value.length && void updateRule(rule, { from_state_ids: value })}
                placeholder={t("cycle_automation.select_states")}
                disabled={disabled}
              />
            </div>
            <span className="text-13 text-secondary">{t("cycle_automation.to")}</span>
            <div className="w-44">
              <StateSingleSelect
                states={states}
                value={rule.to_state_id}
                onChange={(value) => void updateRule(rule, { to_state_id: value })}
                placeholder={t("cycle_automation.select_state")}
                disabled={disabled}
              />
            </div>
            <div className="ml-auto flex items-center gap-2">
              <button
                type="button"
                aria-label={t("cycle_automation.move_up")}
                className="rounded-sm p-1 text-secondary hover:bg-layer-1 disabled:opacity-40"
                disabled={disabled || index === 0}
                onClick={() => void swap(index, index - 1)}
              >
                <ChevronUp className="size-4" />
              </button>
              <button
                type="button"
                aria-label={t("cycle_automation.move_down")}
                className="rounded-sm p-1 text-secondary hover:bg-layer-1 disabled:opacity-40"
                disabled={disabled || index === sorted.length - 1}
                onClick={() => void swap(index, index + 1)}
              >
                <ChevronDown className="size-4" />
              </button>
              <button
                type="button"
                aria-label={t("cycle_automation.delete")}
                className="rounded-sm p-1 text-secondary hover:bg-layer-1 disabled:opacity-40"
                disabled={disabled}
                onClick={() => void deleteRule(rule)}
              >
                <Trash2 className="size-4" />
              </button>
              <ToggleSwitch
                value={rule.is_enabled}
                onChange={() => void updateRule(rule, { is_enabled: !rule.is_enabled })}
                size="sm"
                disabled={disabled}
              />
            </div>
          </div>
        ))}
        {isAdmin && (
          <div className="flex flex-wrap gap-2">
            <Button
              variant="secondary"
              size="sm"
              disabled={disabled || !states.length}
              onClick={() => {
                const firstBacklog = states.find((state) => state.group === "backlog") ?? states[0];
                const target = states.find((state) => state.id !== firstBacklog?.id);
                if (firstBacklog && target)
                  void createRule({
                    trigger: "cycle_started",
                    from_state_ids: [firstBacklog.id],
                    to_state_id: target.id,
                    is_enabled: false,
                  });
              }}
            >
              {t("cycle_automation.add_rule")}
            </Button>
            <Button
              variant="secondary"
              size="sm"
              disabled={disabled || !startPreset}
              title={startPreset ? undefined : t("cycle_automation.presets.missing")}
              onClick={() => startPreset && void createRule(startPreset)}
            >
              {t("cycle_automation.presets.start")}
            </Button>
            <Button
              variant="secondary"
              size="sm"
              disabled={disabled || !completePreset}
              title={completePreset ? undefined : t("cycle_automation.presets.missing")}
              onClick={() => completePreset && void createRule(completePreset)}
            >
              {t("cycle_automation.presets.complete")}
            </Button>
          </div>
        )}
      </div>
    </div>
  );
});
