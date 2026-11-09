/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

/**
 * fork (PLN-107): a collapsed kanban column renders only its header, so it has no drop target of its own.
 * With auto-collapse on, the header becomes one, with the same COLUMN data as the expanded column. After the
 * drop the column holds an item, so it expands by itself.
 */

import { useEffect, useRef, useState } from "react";
import { dropTargetForElements } from "@atlaskit/pragmatic-drag-and-drop/element/adapter";
// plane imports
import { useTranslation } from "@plane/i18n";
import { TOAST_TYPE, setToast } from "@plane/propel/toast";
import { cn } from "@plane/utils";
// components
import type { GroupDropLocation } from "@/components/issues/issue-layouts/utils";
import { getDestinationFromDropPayload, getSourceFromDropPayload } from "@/components/issues/issue-layouts/utils";

type Props = {
  /** false: renders the children unchanged, with no wrapper and no drop target */
  enabled: boolean;
  groupId: string;
  subGroupId: string;
  isDropDisabled?: boolean;
  dropErrorMessage?: string;
  handleOnDrop: (source: GroupDropLocation, destination: GroupDropLocation) => Promise<void>;
  children: React.ReactNode;
};

export function CollapsedColumnDropTarget(props: Props) {
  if (!props.enabled) return <>{props.children}</>;
  return <DropTarget {...props} />;
}

function DropTarget(props: Props) {
  const { groupId, subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, children } = props;
  const { t } = useTranslation();
  const ref = useRef<HTMLDivElement | null>(null);
  const [isOver, setIsOver] = useState(false);

  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    return dropTargetForElements({
      element,
      getData: () => ({ groupId, subGroupId, columnId: `${groupId}__${subGroupId}`, type: "COLUMN" }),
      onDragEnter: () => setIsOver(true),
      onDragLeave: () => setIsOver(false),
      onDrop: (payload) => {
        setIsOver(false);
        const source = getSourceFromDropPayload(payload);
        const destination = getDestinationFromDropPayload(payload);
        if (!source || !destination) return;
        if (isDropDisabled) {
          if (dropErrorMessage)
            setToast({ type: TOAST_TYPE.WARNING, title: t("common.warning"), message: dropErrorMessage });
          return;
        }
        void handleOnDrop(source, destination);
      },
    });
  }, [groupId, subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, t]);

  return (
    <div ref={ref} className={cn("rounded-sm", { "ring-1 ring-accent-strong": isOver })}>
      {children}
    </div>
  );
}
