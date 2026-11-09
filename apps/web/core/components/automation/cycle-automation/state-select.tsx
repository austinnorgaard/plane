/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

/** PLN-129: state pickers for the cycle automation rules and the "Move work items" modal. */

import { observer } from "mobx-react";
// plane imports
import { EIconSize } from "@plane/constants";
import { StateGroupIcon } from "@plane/propel/icons";
import type { IState } from "@plane/types";
import { CustomSearchSelect } from "@plane/ui";

const stateOptions = (states: IState[]) =>
  states.map((state) => ({
    value: state.id,
    query: state.name,
    content: (
      <div className="flex items-center gap-2">
        <StateGroupIcon stateGroup={state.group} color={state.color} size={EIconSize.LG} />
        {state.name}
      </div>
    ),
  }));

type TMultiProps = {
  states: IState[];
  value: string[];
  onChange: (value: string[]) => void;
  placeholder: string;
  disabled?: boolean;
};

export const StateMultiSelect = observer(function StateMultiSelect(props: TMultiProps) {
  const { states, value, onChange, placeholder, disabled } = props;
  const names = states.filter((state) => value.includes(state.id)).map((state) => state.name);
  return (
    <CustomSearchSelect
      value={value}
      onChange={(next: string[]) => onChange(next)}
      options={stateOptions(states)}
      label={<span className="truncate">{names.length ? names.join(", ") : placeholder}</span>}
      multiple
      input
      disabled={disabled}
    />
  );
});

type TSingleProps = {
  states: IState[];
  value: string | null;
  onChange: (value: string) => void;
  placeholder: string;
  disabled?: boolean;
};

export const StateSingleSelect = observer(function StateSingleSelect(props: TSingleProps) {
  const { states, value, onChange, placeholder, disabled } = props;
  const selected = states.find((state) => state.id === value);
  return (
    <CustomSearchSelect
      value={value}
      onChange={(next: string) => onChange(next)}
      options={stateOptions(states)}
      label={
        selected ? (
          <div className="flex items-center gap-2">
            <StateGroupIcon stateGroup={selected.group} color={selected.color} size={EIconSize.LG} />
            <span className="truncate">{selected.name}</span>
          </div>
        ) : (
          <span className="text-placeholder">{placeholder}</span>
        )
      }
      input
      disabled={disabled}
    />
  );
});
