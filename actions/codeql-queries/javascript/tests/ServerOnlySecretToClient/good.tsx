import React from "react";
import { NextResponse } from "next/server";
import Panel from "./Panel";
import { region } from "./config";

// Negative: a NEXT_PUBLIC_ variable is public by contract.
export default function Page() {
  return <Panel name={process.env.NEXT_PUBLIC_SITE_URL} />;
}

// Negative: the secret authenticates a server fetch. Only the fetched data crosses.
export async function GET() {
  const upstream = await fetch("https://api.example.com/items", {
    headers: { "x-api-key": process.env.API_KEY ?? "" },
  });
  const items = await upstream.json();
  return NextResponse.json(items);
}

// Negative: the module that exports region has no server-only import.
export async function getServerSideProps() {
  return { props: { region } };
}

// Negative: NODE_ENV decides a label. Neither the name nor the value crosses.
export function Mode() {
  const dev = process.env.NODE_ENV !== "production";
  return <Panel name={dev ? "development" : "production"} />;
}

// Negative: DOCS_URL is the public origin of the docs site. It is a link.
export function DocsLink() {
  return <Panel name={`${process.env.DOCS_URL}/docs/missions`} />;
}

// Negative: WWW_URL is the public origin of the marketing site. The read goes
// through a parameter whose default value is the environment.
export function MarketingLink(source: Record<string, string | undefined> = process.env) {
  const marketingUrl = source["WWW_URL"];
  return <Panel name={marketingUrl} />;
}
