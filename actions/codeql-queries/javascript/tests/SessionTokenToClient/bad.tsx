import React from "react";
import { cookies, headers } from "next/headers";
import { NextResponse } from "next/server";
import Panel, { Badge } from "./Panel";

declare function getSession(): Promise<{ accessToken: string; user: { name: string } }>;

// Positive: a cookie value becomes a client component prop.
export default async function Page() {
  const store = await cookies();
  const token = store.get("session")?.value;
  return <Panel token={token} />;
}

// Positive: a session token read from a session object becomes a client prop.
export async function Account() {
  const session = await getSession();
  return <Badge label={session.accessToken} />;
}

// Positive: an auth header is sent back in a response body, nested in an object.
export async function GET() {
  const auth = headers().get("authorization");
  return NextResponse.json({ ok: true, auth });
}

// Positive: a request cookie is serialized as a page prop.
export async function getServerSideProps({ req }: { req: any }) {
  const sessionToken = req.cookies.session;
  return { props: { sessionToken } };
}
