/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

/**
 * fork (PLN-107): a collapsed kanban column renders only its header, so it has no drop target of its own.
 * With auto-collapse on, the header becomes one, with the same COLUMN data as the expanded column. After the
 * drop the column is toggled open (a session override that ends as soon as the column holds an item, so an
 * empty column then stays open because it is no longer empty, and a column collapsed by hand opens too).
 *
 * fork (PLN-108): onDropped must open the column (expandGroup), not toggle it: the drop has already put the
 * ticket in the store when onDropped runs, so a toggle saw a non-empty column and collapsed it again.
 * CollapsedRowDropTarget does the same for a collapsed kanban sub-group row (swimlane), which renders only
 * its header: a ticket dropped on it keeps its column and moves to that row.
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
  /** called after a drop, to expand the column (the same as the list layout does on a collapsed group) */
  onDropped: () => void;
  children: React.ReactNode;
};

export function CollapsedColumnDropTarget(props: Props) {
  if (!props.enabled) return <>{props.children}</>;
  return <DropTarget {...props} />;
}

function DropTarget(props: Props) {
  const { groupId, subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, onDropped, children } = props;
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
        onDropped();
      },
    });
  }, [groupId, subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, onDropped, t]);

  return (
    <div ref={ref} className={cn("rounded-sm", { "ring-1 ring-accent-strong": isOver })}>
      {children}
    </div>
  );
}

type RowProps = {
  /** false: renders the children unchanged, with no wrapper and no drop target */
  enabled: boolean;
  subGroupId: string;
  isDropDisabled?: boolean;
  dropErrorMessage?: string;
  handleOnDrop: (source: GroupDropLocation, destination: GroupDropLocation) => Promise<void>;
  /** called after a drop, to expand the row */
  onDropped: () => void;
  children: React.ReactNode;
};

export function CollapsedRowDropTarget(props: RowProps) {
  if (!props.enabled) return <>{props.children}</>;
  return <RowDropTarget {...props} />;
}

function RowDropTarget(props: RowProps) {
  const { subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, onDropped, children } = props;
  const { t } = useTranslation();
  const ref = useRef<HTMLDivElement | null>(null);
  const [isOver, setIsOver] = useState(false);

  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    return dropTargetForElements({
      element,
      // not a COLUMN: the destination column is the source's, which is known only at drop time
      getData: () => ({ subGroupId, type: "SUB_GROUP_ROW" }),
      onDragEnter: () => setIsOver(true),
      onDragLeave: () => setIsOver(false),
      onDrop: (payload) => {
        setIsOver(false);
        const source = getSourceFromDropPayload(payload);
        if (!source || source.subGroupId === subGroupId) return;
        if (isDropDisabled) {
          if (dropErrorMessage)
            setToast({ type: TOAST_TYPE.WARNING, title: t("common.warning"), message: dropErrorMessage });
          return;
        }
        const destination: GroupDropLocation = {
          groupId: source.groupId,
          subGroupId,
          columnId: `${source.groupId}__${subGroupId}`,
          id: undefined,
        };
        void handleOnDrop(source, destination);
        onDropped();
      },
    });
  }, [subGroupId, isDropDisabled, dropErrorMessage, handleOnDrop, onDropped, t]);

  return (
    <div ref={ref} className={cn("rounded-sm", { "ring-1 ring-accent-strong": isOver })}>
      {children}
    </div>
  );
}
