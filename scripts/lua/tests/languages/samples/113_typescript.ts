type Result<T> = { ok: true; value: T } | { ok: false; error: Error };

interface Repository<T extends { id: string }> {
  find(id: string): Promise<Result<T>>;
}

export class MemoryRepository<T extends { id: string }> implements Repository<T> {
  constructor(private values: Map<string, T> = new Map()) {}
  async find(id: string): Promise<Result<T>> {
    const value = this.values.get(id);
    return value ? { ok: true, value } : { ok: false, error: new Error(id) };
  }
}

enum Status {
  Draft = "draft",
  Published = "published",
}

namespace Demo {
  export abstract class Controller<T> {
    protected constructor(readonly repository: Repository<T & { id: string }>) {}
    abstract handle(id: string): Promise<Result<T & { id: string }>>;
  }
}

const tuple = ["id", 1] as const satisfies readonly [string, number];
type AwaitedResult = Awaited<ReturnType<Repository<{ id: string }>["find"]>>;

Infinity NaN arguments async await break case catch class const continue debugger default delete do else export extends false finally for function get if implements import in instanceof let new null return set static super switch this throw true try typeof undefined var void while with yield ;
