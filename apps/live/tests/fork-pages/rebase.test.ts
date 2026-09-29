/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { describe, expect, it } from "vitest";
import { TiptapTransformer } from "@hocuspocus/transformer";
import type { AnyExtension } from "@tiptap/core";
import * as Y from "yjs";
import {
  convertBase64StringToBinaryData,
  getBinaryDataFromDocumentEditorHTMLString,
  generateTitleProsemirrorJson,
  getAllDocumentFormatsFromDocumentEditorBinaryData,
} from "@plane/editor/lib";
import { TITLE_EDITOR_EXTENSIONS } from "@plane/editor";
import { InvalidBaseStateError, rebase } from "@/fork-pages/rebase";

const textOf = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const occurrences = (haystack: string, needle: string) => haystack.split(needle).length - 1;

type JsonNode = { text?: string; content?: unknown[] };
const collect = (node: JsonNode): string =>
  typeof node.text === "string" ? node.text : (node.content ?? []).map((c) => collect(c as JsonNode)).join("");

const baseState = () => getBinaryDataFromDocumentEditorHTMLString("<p>old body</p>", "Old title");
const formats = (state: Uint8Array) => getAllDocumentFormatsFromDocumentEditorBinaryData(state, true);

describe("rebase", () => {
  it("replaces body and title in the base lineage without duplicating content", () => {
    const base = baseState();
    // an editor that cached the base state before the rebase
    const cachedClient = new Y.Doc();
    Y.applyUpdate(cachedClient, base);

    const result = rebase({ baseBinary: base, descriptionHtml: "<p>new body</p>", name: "New title" });
    Y.applyUpdate(cachedClient, convertBase64StringToBinaryData(result.description_binary));

    const merged = formats(Y.encodeStateAsUpdate(cachedClient));
    expect(textOf(merged.contentHTML)).toBe("new body");
    expect(occurrences(merged.contentHTML, "new body")).toBe(1);
    expect(merged.contentHTML).not.toContain("old body");
    expect(merged.titleHTML).toBe("New title");
    expect(textOf(result.description_html)).toBe("new body");
  });

  it("round-trips the new title through the real title editor extensions", () => {
    const result = rebase({ baseBinary: baseState(), descriptionHtml: "<p>new body</p>", name: "Round trip title" });
    const doc = new Y.Doc();
    Y.applyUpdate(doc, convertBase64StringToBinaryData(result.description_binary));

    const titleJson = TiptapTransformer.extensions(TITLE_EDITOR_EXTENSIONS as AnyExtension[]).fromYdoc(doc, "title");
    expect(collect(titleJson)).toBe("Round trip title");

    // Pin the node structure too (a level 1 heading holding the text). The transformer output is identical
    // to the generated JSON with no extra default attrs, so a plain toEqual is enough.
    expect(titleJson).toEqual(generateTitleProsemirrorJson("Round trip title"));
  });

  it("CONTROL: fresh conversion merged onto the old cached state duplicates content", () => {
    // Standing evidence for why the rebase keeps the stored lineage instead of converting from scratch.
    const base = baseState();
    const cachedClient = new Y.Doc();
    Y.applyUpdate(cachedClient, base);

    const fresh = getBinaryDataFromDocumentEditorHTMLString("<p>new body</p>", "New title");
    Y.applyUpdate(cachedClient, fresh);

    const merged = formats(Y.encodeStateAsUpdate(cachedClient));
    expect(occurrences(merged.contentHTML, "new body")).toBe(1);
    expect(occurrences(merged.contentHTML, "old body")).toBe(1); // old content survives next to the new
    expect(textOf(merged.contentHTML)).toContain("old body");
    expect(textOf(merged.contentHTML)).toContain("new body");
  });

  it("keeps the base state when merged with a client that made concurrent unrelated edits", () => {
    const base = baseState();
    const result = rebase({ baseBinary: base, descriptionHtml: "<p>new body</p>", name: null });
    const again = rebase({
      baseBinary: convertBase64StringToBinaryData(result.description_binary),
      descriptionHtml: "<p>new body</p>",
      name: null,
    });
    expect(occurrences(again.description_html, "new body")).toBe(1);
  });

  it("leaves the title untouched when name is null", () => {
    const result = rebase({ baseBinary: baseState(), descriptionHtml: "<p>x</p>", name: null });
    expect(formats(convertBase64StringToBinaryData(result.description_binary)).titleHTML).toBe("Old title");
  });

  it("leaves the body untouched when description_html is null", () => {
    const result = rebase({ baseBinary: baseState(), descriptionHtml: null, name: "Renamed" });
    expect(textOf(result.description_html)).toBe("old body");
    expect(formats(convertBase64StringToBinaryData(result.description_binary)).titleHTML).toBe("Renamed");
  });

  it("clears the title for an empty name and returns json in the same shape as the html", () => {
    const result = rebase({ baseBinary: baseState(), descriptionHtml: "<p>a</p>", name: "" });
    expect(formats(convertBase64StringToBinaryData(result.description_binary)).titleHTML).toBe("");
    expect(JSON.stringify(result.description_json)).toContain("a");
  });

  it("applies both changes in one transaction (single update event)", () => {
    const base = baseState();
    const result = rebase({ baseBinary: base, descriptionHtml: "<p>b</p>", name: "T" });
    const observer = new Y.Doc();
    Y.applyUpdate(observer, base);
    let updates = 0;
    observer.on("update", () => (updates += 1));
    Y.applyUpdate(observer, convertBase64StringToBinaryData(result.description_binary));
    expect(updates).toBe(1);
  });

  it("treats empty html as an empty paragraph", () => {
    const result = rebase({ baseBinary: baseState(), descriptionHtml: "", name: null });
    expect(result.description_html).toMatch(/^<p[^>]*><\/p>$/);
    expect(textOf(result.description_html)).toBe("");
  });

  it("rejects a partial update whose dependencies are missing from the base", () => {
    const source = new Y.Doc();
    source.getXmlFragment("default").insert(0, [new Y.XmlText("first")]);
    const before = Y.encodeStateVector(source);
    source.getXmlFragment("default").insert(1, [new Y.XmlText("second")]);
    const diffOnly = Y.encodeStateAsUpdate(source, before);
    expect(() => rebase({ baseBinary: diffOnly, descriptionHtml: "<p>x</p>", name: null })).toThrow(
      InvalidBaseStateError
    );
  });

  it("rejects a base that is not a Yjs update", () => {
    expect(() =>
      rebase({ baseBinary: new Uint8Array([255, 255, 255, 9]), descriptionHtml: "<p>x</p>", name: null })
    ).toThrow(InvalidBaseStateError);
  });
});
