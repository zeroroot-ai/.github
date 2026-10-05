import React from "react";

// Positive: a variable reaches __html with no sanitizer on its path.
export function Bad({ html }: { html: string }) {
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
