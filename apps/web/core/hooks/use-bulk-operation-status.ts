/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// fork (PLN-129): selection and the bulk update bar are on for the work item lists of a project, cycle, module or
// project view (the stores with bulkUpdateProperties). Upstream returns false here.
import { EIssuesStoreType } from "@plane/types";
import { useIssueStoreType } from "@/hooks/use-issue-layout-store";

const BULK_STORE_TYPES = new Set<EIssuesStoreType>([
  EIssuesStoreType.PROJECT,
  EIssuesStoreType.CYCLE,
  EIssuesStoreType.MODULE,
  EIssuesStoreType.PROJECT_VIEW,
]);

export const useBulkOperationStatus = () => BULK_STORE_TYPES.has(useIssueStoreType());
