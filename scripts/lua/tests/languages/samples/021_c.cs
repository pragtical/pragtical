using System;
using System.Collections.Generic;

namespace Demo;

public interface IRepository<T> { T? Find(string id); }

public sealed class MemoryRepository<T> : IRepository<T> where T : class {
  private readonly Dictionary<string, T> values = new();
  public MemoryRepository(Dictionary<string, T> seed) => values = seed;
  public T? Find(string id) => values.TryGetValue(id, out var value) ? value : null;
}

public static class Program {
  public static void Main() {
    Console.WriteLine(new MemoryRepository<object>(new()).Find("id") is null);
  }
}

public readonly record struct Item(string Label, bool Enabled);

public delegate void Changed<in T>(T value);

public partial class Controller {
  public event Changed<Item>? OnChanged;
  public async Task<string> RenderAsync(IEnumerable<Item> items) {
    await Task.Yield();
    return string.Join(",", items.Where(static item => item.Enabled).Select(item => item.Label));
  }

  public string this[int index] {
    get => index.ToString();
    set => OnChanged?.Invoke(new Item(value, true));
  }
}
