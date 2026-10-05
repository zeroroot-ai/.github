import React from "react";
import DOMPurify from "dompurify";

// Negative: sanitized inline.
export function Inline({ html }: { html: string }) {
  return <div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(html) }} />;
}

// Negative: sanitized one line earlier, into a variable.
export function Stored({ html }: { html: string }) {
  const clean = DOMPurify.sanitize(html);
  return <div dangerouslySetInnerHTML={{ __html: clean }} />;
}

// Negative: a string constant is not an injection vector.
export function Constant() {
  return <div dangerouslySetInnerHTML={{ __html: "<b>static</b>" }} />;
}

// Negative: the empty string the old filter flagged.
export function Empty() {
  return <div dangerouslySetInnerHTML={{ __html: "" }} />;
}
