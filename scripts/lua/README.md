# Lua Scripts

This directory contains lua scripts for running with Pragtical.

### Tests

Run the full Lua test suite:

```sh
SDL_VIDEO_DRIVER=dummy ./scripts/run-local build test scripts/lua/tests
```

Run a single Lua test file:

```sh
SDL_VIDEO_DRIVER=dummy ./scripts/run-local build test scripts/lua/tests/tokenizer.lua
```

### Build

**pgo.lua** This script is used to generate profiler data, for more details
check the instructions included inside the file.

### Benchmarks

**benchmarks/tokenizer.lua** Benchmarks the Lua and native tokenizer paths for
an input file.

```sh
./scripts/run-local build run scripts/lua/benchmarks/tokenizer.lua /path/to/file.ext
```
