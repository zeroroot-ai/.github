import React from "react";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import Panel from "./Panel";
import ServerPanel from "./ServerPanel";

declare function getSession(): Promise<{ accessToken: string; user: { name: string } }>;
declare function verify(token: string | undefined): boolean;

// Negative: the cookie value is checked on the server and only a boolean crosses.
export default async function Page() {
  const store = await cookies();
  const token = store.get("session")?.value;
  const ok = verify(token);
  return <Panel name={ok ? "member" : "guest"} />;
}

// Negative: the user name crosses, the token in the same object does not.
export async function Account() {
  const session = await getSession();
  return <Panel name={session.user.name} />;
}

// Negative: a server component receives the token. It never reaches the client.
export async function Gate() {
  const store = await cookies();
  const token = store.get("session")?.value;
  return <ServerPanel token={token} />;
}

// Negative: the response body carries no credential.
export async function GET() {
  return NextResponse.json({ ok: true });
}

// Negative: the page prop is a user id, not a token.
export async function getServerSideProps({ req }: { req: any }) {
  const session = await getSession();
  return { props: { name: session.user.name, method: req.method } };
}
