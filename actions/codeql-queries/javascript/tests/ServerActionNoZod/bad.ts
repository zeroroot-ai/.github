declare function save(x: unknown): Promise<void>;

// Positive: req.body is consumed with no parse on its path.
export async function POST(req: any) {
  const data = req.body;
  return save(data);
}
