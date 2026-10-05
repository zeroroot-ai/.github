import React from "react";

// A server component: no "use client" directive. Its props stay on the server.
export default function ServerPanel({ token }: { token?: string }) {
  return <div>{token ? "signed in" : "anonymous"}</div>;
}
