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
