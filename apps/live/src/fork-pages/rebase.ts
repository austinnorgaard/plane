/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// Stateless in-lineage rebase: applies new content on top of a stored document state so the result
// shares the stored state's history. Deliberately has no Hocuspocus imports.

import { getSchema } from "@tiptap/core";
import { generateJSON } from "@tiptap/html";
import { prosemirrorJSONToYXmlFragment } from "y-prosemirror";
import * as Y from "yjs";
import {
  CoreEditorExtensionsWithoutProps,
  DocumentEditorExtensionsWithoutProps,
  generateTitleProsemirrorJson,
  getAllDocumentFormatsFromDocumentEditorBinaryData,
} from "@plane/editor/lib";

// Drift point: the stock document extensions and schema are module-private in the editor package,
// so they are rebuilt here from the same public lists. Keep in sync with yjs-utils.ts.
// The cast bridges two installed copies of the tiptap type declarations (same runtime classes).
const DOC_EXTENSIONS = [
  ...CoreEditorExtensionsWithoutProps,
  ...DocumentEditorExtensionsWithoutProps,
] as unknown as Parameters<typeof getSchema>[0];
const DOC_SCHEMA = getSchema(DOC_EXTENSIONS);

export class InvalidBaseStateError extends Error {
  constructor() {
    super("base state is not a valid document update");
    this.name = "InvalidBaseStateError";
  }
}

export type TRebaseInput = {
  baseBinary: Uint8Array;
  /** null leaves the body untouched */
  descriptionHtml: string | null;
  /** null leaves the title untouched */
  name: string | null;
};

export type TRebaseResult = {
  description_binary: string;
  description_html: string;
  description_json: object;
};

const replaceFragment = (doc: Y.Doc, field: string, json: object) => {
  const fragment = doc.getXmlFragment(field);
  fragment.delete(0, fragment.length);
  prosemirrorJSONToYXmlFragment(DOC_SCHEMA, json, fragment);
};

export const rebase = ({ baseBinary, descriptionHtml, name }: TRebaseInput): TRebaseResult => {
  const doc = new Y.Doc();
  try {
    Y.applyUpdate(doc, baseBinary);
  } catch {
    throw new InvalidBaseStateError();
  }
  // A partial update (one that depends on structs the base does not contain) is kept as pending and
  // would silently produce a result outside the stored lineage, so only a full state is accepted.
  if (doc.store.pendingStructs !== null || doc.store.pendingDs !== null) {
    throw new InvalidBaseStateError();
  }

  // Convert before opening the transaction so a conversion failure leaves nothing half applied.
  const bodyJSON = descriptionHtml === null ? null : generateJSON(descriptionHtml, DOC_EXTENSIONS);
  const titleJSON = name === null ? null : generateTitleProsemirrorJson(name);

  doc.transact(() => {
    if (bodyJSON) replaceFragment(doc, "default", bodyJSON);
    if (titleJSON) replaceFragment(doc, "title", titleJSON);
  });

  const state = Y.encodeStateAsUpdate(doc);
  const { contentBinaryEncoded, contentHTML, contentJSON } = getAllDocumentFormatsFromDocumentEditorBinaryData(
    state,
    true
  );
  return { description_binary: contentBinaryEncoded, description_html: contentHTML, description_json: contentJSON };
};
