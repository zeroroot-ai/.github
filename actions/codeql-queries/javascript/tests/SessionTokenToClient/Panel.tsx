"use client";

import React from "react";

// A client component. Every prop it receives is serialized into the page.
export default function Panel({ token, name }: { token?: string; name?: string }) {
  return <div>{name ?? token}</div>;
}

export function Badge(props: { label: string }) {
  return <span>{props.label}</span>;
}
