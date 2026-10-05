import { z } from "zod";

declare function save(x: unknown): Promise<void>;

const Schema = z.object({ name: z.string() });

// Negative: the read goes straight into parse.
export async function POST(req: any) {
  const data = Schema.parse(req.body);
  return save(data);
}

// Negative: the read is stored first, then reaches safeParse.
export async function PUT(request: any) {
  const raw = request.body;
  const parsed = Schema.safeParse(raw);
  return save(parsed);
}
