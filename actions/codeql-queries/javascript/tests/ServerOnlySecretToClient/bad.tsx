import React from "react";
import { NextResponse } from "next/server";
import Panel from "./Panel";
import { region } from "./secrets";

// Positive: an environment variable becomes a client component prop.
export default function Page() {
  return <Panel token={process.env.API_KEY} />;
}

// Positive: a destructured environment variable is nested in a response body.
export async function GET() {
  const { DATABASE_URL } = process.env;
  return NextResponse.json({ ok: true, db: DATABASE_URL });
}

// Positive: a binding from a server-only module is serialized as a page prop.
export async function getServerSideProps() {
  return { props: { region } };
}

// Positive: the whole environment is spread into a client component.
export function Everything() {
  return <Panel {...process.env} />;
}
