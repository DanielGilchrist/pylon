# pylon

A two way file syncer written in Crystal. A **base** tree (the last state both sides agreed on) plus two replicas, **local** and **remote**. A cycle is: scan both sides → reconcile against the base → transfer content → write → commit the new base.

Primary goals are **correctness**, then **performance**. Never trade the first for the second.

## Commands

```sh
crystal spec                                        # the spec suite
script/check-end-to-end                             # real binaries over a stub ssh
crystal build --no-codegen bench/<file>.cr          # bench/ is NOT compiled by crystal spec, check after renames
crystal build --release -o bin/pylon src/pylon.cr   # mac binary
./build-linux.sh                                    # static linux binaries, needs docker
```

Run all three checks before considering a change done. The end-to-end script catches client/server mismatches that in-process specs cannot, because the server is a separate process.

## Architecture

`Session#cycle` drives one sync: scan both sides in parallel, reconcile the two trees against the base, ship content, write, commit the new base. With `--watch`, `Runner` repeats the cycle on watcher signals.

- `core/` pure tree logic, no I/O. `Entry` is the tree node (a whole tree is nested entries), `Reconciler` turns base/local/remote into per-side changes and conflicts, `Differ` diffs two trees, `Applier` applies changes to a tree, `Safety` halts the cycle before anything is written when the planned changes would delete or retype the sync root, or when one side suddenly reports an empty tree while the other does not (an unmounted disk must not be mirrored as a mass deletion, for example).
- `scan/` turns a directory into an `Entry` tree. `Scanner` reuses untouched subtrees via a baseline plus recheck set, `Cache` holds per-path metadata and digests, `Ignores` filters paths.
- `write/` applies changes to a filesystem. `Guard` refuses a write when the on-disk state no longer matches the cache, `Outcome` reports what happened per path.
- `wire/` the binary protocol. `Message` is the frame union, `Binary` encodes and decodes, `Chunks` moves zstd-compressed content, `ContentSource` supplies content to send.
- `session/` orchestration. `Session` runs the cycle, `Server` is the remote side (`pylon serve` over ssh stdin/stdout), `LocalEndpoint` and `RemoteEndpoint` give both sides one interface, `Checkpoint` persists the base and caches between runs.
- `watch/` file watchers, inotify on linux, watchman on mac.
- `compress/` zstd through hand-rolled lib bindings, `Identity` is the no-op codec for specs.
- `cli/` the `sync`, `serve` and `local` commands plus terminal reporting.
- `disk.cr` the real filesystem, specs substitute in-memory fakes.

## Comments

Code must explain itself. If it needs a comment saying *what* it does, rewrite the code. The only comments allowed explain *why*, and **only humans write them**. As an LLM you never add a comment, ever - not a doc comment, not a "why" comment, nothing. Comments in the code examples below are teaching notes for this document, not licence to write them in source.

## Principles

### Parse, don't validate

Convert raw data into a typed value once, at the boundary. Everything past the boundary works with the parsed type and never re-checks it.

```crystal
# Bad: raw bits leak past the boundary, every caller re-derives meaning
if stat.st_mode & LibC::S_IFMT == LibC::S_IFREG

# Good: parsed once at the syscall boundary, callers ask the type
metadata = Metadata.from(stat)
if metadata.kind.file?
```

When the input can be malformed, parsing fails and the failure is a value the caller must handle. `Metadata.of` returns `Metadata | Problem | Nil` (nil is absence, `Problem` says why it could not be examined), `Target.parse` returns `Target | Invalid`.

Never default a missing or malformed field into something that happens to type-check.

```crystal
# Bad: a missing field is invented, a malformed frame
# silently becomes a change at path ""
path = read_string(io) || ""

# Good: a failed parse produces no value at all,
# the caller handles Invalid or there is no Target to misuse
def self.parse(specification : String) : Target | Invalid
```

Refuse malformed input and surface the refusal as a value, per the errors principle below.

### Make invalid states unrepresentable

If a field is only meaningful in some states, or two fields can contradict each other, replace them with a type per state.

```crystal
# Example src/pylon/watch/dirty.cr: rather than one record where a field (`paths`) is meaningless based on state, encode the invariants into the type system
record Everything
record Touched, paths : Array(String)
alias Dirty = Everything | Touched
```

```crystal
# Bad: two exclusive modes as nilable fields.
# An invalid instance where both are `nil` is possible and we're forced to handle invalid states which also muddles the implementation.
struct ContentSource
  def initialize(@contents : Contents? = nil, @materialise : Proc(Contents)? = nil)
  end

  def contents : Contents
    @contents || @materialise.try(&.call) || Contents.new
  end
end

# Good: one subtype per mode, invalid state isn't possible
abstract struct ContentSource
  abstract def contents : Contents

  struct Materialised < ContentSource
    getter contents : Contents

    def initialize(@contents : Contents)
    end
  end

  struct Streaming < ContentSource
    def initialize(@materialise : Proc(Contents))
    end

    def contents : Contents
      @materialise.call
    end
  end
end
```

One kind, one type: when a record carries a kind discriminant plus fields that are only meaningful for some kinds, split it into a union of per-kind types. `Core::Entry` is the model: `Directory | File | SymbolicLink | Untracked | Problematic`, where a `File` always has a digest and a `Directory` never does, so no reader ever checks a field the kind cannot have and the wire decoder cannot build a directory carrying a digest. A kind enum survives only where a flat tag is the honest shape, such as `Scan::Metadata::Kind` parsed from a stat mode.

The principle also runs the other way: model the awkward real-world states instead of omitting them. The `Core::Entry` union includes `Untracked` and `Problematic`, so ignored and broken paths are ordinary tree nodes and the differ and reconciler need no special cases for them.

### Errors are values

Exceptions are not part of control flow in this codebase, expected or otherwise. If a failure can be handled anywhere, even only at the very top before exiting, it is a return value carrying everything needed to handle it, and the union return type forces every caller to deal with it. The only permitted raises are assertions (next principle), and those are never rescued, they end the process.

```crystal
# Bad: the failure is invisible in the signature, callers find out when it
# raises, and handling it means rescuing at a distance with no type checking
def self.parse(specification : String) : Target
  raise ArgumentError.new("bad target") unless specification.includes?(':')
  # ...
end

# Good: the caller cannot use the result without handling the failure
def self.parse(specification : String) : Target | Invalid
```

```crystal
# Good: an interface can mandate it for every implementation
abstract def compress(source : Bytes, into : Bytes) : Bytes | Error
```

The stdlib and C bindings do raise. Reach for the non-raising variant first, most raising APIs have one: `Hash#[]?`, `File.info?`, `Channel#receive?`, `Enum.from_value?`.

```crystal
# Bad: exception as control flow when a nil-returning API exists
info = begin
  File.info(path)
rescue File::Error
  nil
end

# Good
info = File.info?(path)
```

When no non-raising API exists (reading a file's content, for example), quarantine the exception: rescue immediately around the foreign call and convert to a value on the spot, so it never crosses one of our own method boundaries. This is parse-don't-validate applied to failures.

```crystal
# Good: no `?` variant exists here, the exception lives and dies inside the boundary method
def read(path : String) : Bytes | Failure
  File.open(path) { |file| ... }
rescue error : IO::Error
  Failure.new(path, error.message)
end
```

A `rescue` anywhere else means an expected failure was modelled as an exception, fix the model instead. Never rescue broadly, and never collapse a failure into a bare `nil` or `Bool` that discards why it failed when a caller could act on the reason.

Two mechanisms are the only exceptions, and both exist so the rescue lives in exactly one place:

- The wire decoder aborts a parse by raising `Wire::Truncated` internally; every decode entry point runs inside `Wire::Truncated.contain`, which converts the abort (and any `IO::Error` from the stream) into `Wire::Invalid`. Never rescue `Truncated` anywhere else, and never let it escape a public entry point.
- An exception left unhandled in a fiber is swallowed: the fiber prints to stderr and dies, and any waiter proceeds as if the work completed. `Pylon::Fibers` owns the only broad rescues: `future`/`await` and `parallel` capture an unexpected exception inside the fiber and re-raise it in the waiter. Spawn worker fibers through `Fibers`, never hand-roll the capture.

### Assertions are a last resort

An assertion is any construct that says "trust me" instead of proving it: `.not_nil!`, `.as` casts, `raise "unreachable"`. Each one is a place the compiler stopped checking and a runtime crash became possible. Basically never use them. If you absolutely must, it is required that you leave a comment explaining why. Ensure you validate the why is correct and be thorough in validating its necessity.

Pointer casts at a `lib` binding boundary (`buffer.to_unsafe.as(Void*)` into a C function) are a calling convention, not an assertion, and need no comment. `.as` on our own types remains banned.

Prefer, in order:

1. Flow narrowing. Assign and check, the compiler proves the rest.

```crystal
# Bad
process(entries[path]?.not_nil!)

# Good
if (entry = entries[path]?)
  process(entry)
end
```

2. Restructure so the condition cannot arise, using the invalid-states principle above. A field that "is never nil at this point" wants a type where it is not nilable at all.
3. Exhaustive `case ... in`, which proves variant coverage instead of asserting it with an `else raise`.

The last resort itself: an invariant the type system genuinely cannot express, whose violation means internal state is corrupt and continuing risks wrong data. Then raise, with a message naming the broken invariant, so the crash is a diagnosis rather than a mystery. This is for bugs in our own logic. Anything arriving from outside the process is input to parse, never a condition to assert.

### Exhaustive `case ... in`

Match enums and unions with `in`, never `when`, so adding a variant lets the compiler inform us of all of the cases that should handle it.

```crystal
# Bad: a new entry type falls through silently
case entry
when Core::File      then write_file(entry)
when Core::Directory then create_directory(entry)
end

# Good: adding a type to the Entry union is a compile error here until it is handled
case entry
in Core::File                        then write_file(entry)
in Core::Directory                   then create_directory(entry)
in Core::SymbolicLink                then create_symlink(entry)
in Core::Untracked, Core::Problematic then nil
end
```

The same applies to consuming a union with `is_a?`: a chain of `if value.is_a?(...)` checks over a union has no exhaustiveness either, so a new variant silently takes whatever the fallthrough does. Consume a union-typed value with `case ... in`; a lone `is_a?` is for sites where only one variant can ever matter, exactly like a lone enum predicate.

Prefer the `.file?` shorthand over spelling out `Kind::File` in `in` branches on enums, and prefer symbol autocasting over enum constants wherever the compiler knows the target type: arguments, named arguments and default values. Both are checked at compile time, a typo does not compile.

```crystal
# Bad
Preferences::Rule.new(Preferences::Side::Local, pattern)

# Good: the symbol is autocast to the enum and verified by the compiler
Preferences::Rule.new(:local, pattern)
```

The same reasoning applies to lone comparisons. `==` against a string is invisible to the compiler when a variant is added, so exhaustive matching is the norm and a direct check is the exception, reserved for sites where only one variant can ever matter.

```crystal
# Bad: a typo compiles and never matches
outcome.skipped.try(&.explain) == "modification detected"

# Acceptable only when this site genuinely cares about a single variant
outcome.skipped.is_a?(Write::DryRun)

# The norm: the compiler drags this site back when a variant is added
case outcome.skipped
in Nil                                          then record(outcome)
in Write::ModificationDetected, Write::UnknownState then retry_later(outcome)
in Write::StagedContentMissing                  then request_content(outcome)
in Write::DryRun                                then preview(outcome)
in Write::WriteFailed                           then report(outcome)
end
```

Give the owning type intention-revealing predicates (`Outcome#applied?`, `Outcome#skipped?`) so most callers never touch the union at all.

Abstract structs cannot be exhaustively cased and Crystal doesn't support sealed classes. This must be modelled using `alias` with a union type (`Wire::Message`, `Watch::Dirty`). An abstract struct suits method dispatch instead (`ContentSource` above).

### Structs for values, classes for mutable state

Immutable value types are structs, and prefer `record` when there is no behaviour beyond the fields. Anything mutated in place is a class. The trap is a struct with mutable ivars: passed as an argument it is copied, methods mutate the copy, and the caller's instance never changes.

```crystal
# Bad: passed to another method, the dedup set diverges silently on a copy
struct Reporter
  def report(conflicts)
    @announced = current(conflicts)
  end
end

# Good: shared mutable state is a class
class Reporter
```

The split is also an allocation strategy. A struct is stack allocated, so building one per iteration of a hot loop is free. A class instance is a heap allocation the GC must track, so a mutable heap object created per iteration is GC churn by design: hoist it out of the loop, allocate once and reuse it (the scanner allocates one read buffer per worker, not one per file). Mutable heap state should be long-lived and owned in one place. A short-lived object built per iteration wants to be an immutable struct (or the design should be reconsidered to avoid short-lived objects).

Constant lists are tuple literals, not array literals. An `Array` constant is a shared mutable global, a `Tuple` is an immutable value.

### No Hash, Tuple, or String where a type belongs

A hash or tuple crossing a method boundary carries its meaning only in the author's head. Name it with a `record`. A tuple is fine as a multiple return destructured on the spot, it is not fine threaded through several methods.

```crystal
# Bad: which String is which lives in the reader's memory
def wanted : Array({Bytes, String})

# Good
record Wanted, digest : Bytes, path : String

def wanted : Array(Wanted)
```

### One type per file

A file defines one top-level type, named after it (`struct RelativePath` in `relative_path.cr`). Do not nest other types within a file, they should be split out properly into their own file through namespacing. This keeps the codebase easy to navigate and find appropriate types. If two independent types share a file, split them and have one `require` the other where it needs it.

There are two exceptions to this:

- A sealed union: the variant types and the `alias` that unites them are one modelled concept (`Directory | File | … `, `alias Entry` in `entry.cr` or `Everything`/`Touched`/`alias Dirty` in `dirty.cr`). They only have meaning as a set, so they are defined together, in a file named after the union.
- A type nested inside and scoped to its owner (`Metadata::Kind`, `Target::Invalid`, `Checkpoint::Damaged`). It is part of that type's surface and lives with it.

### Performance is measured, never estimated

- Hot paths get allocation budgets as specs via `assert_allocates_under(budget, what, &)` (`spec/support/allocations.cr`), so regressions fail to compile.
- Hot loops take caller-supplied buffers: one buffer per worker, not one per file.
- Copy on write, not defensive copying. Return the original when nothing changed and only copy once a divergence is found (`Entry.synchronizable`).
- Give collections `initial_capacity:` when the size is known.
- Any speed claim in a commit or discussion needs a number from `bench/` or a real run behind it.

## Concurrency and parallelism

Pylon explicitly makes use of execution contexts introduced in Crystal 1.21:

- The default context has parallelism 1. Parallel hashing gets its own `Fiber::ExecutionContext::Parallel`.
- The inotify read runs on an `Isolated` context because the fd cannot be driven by the event loop without deadlocking it.
- An unhandled exception in a fiber **does not stop the process**: the fiber prints to stderr and dies, `WaitGroup.wait` returns as if the work completed, and the caller continues on partial results (a half-scanned tree reconciles as a mass deletion). `Pylon::Fibers` (`future`/`await`, `parallel`) turns that into a crash on the waiting fiber instead. Spawn concurrent work through it, never with a bare `spawn` plus `WaitGroup`.
- Block variables are shared across every fiber spawned in a loop, so a buffer captured by closure is one buffer written by all workers concurrently. Pass per-worker state as method parameters (`Scanner#hash_slice`); the loop body handed to `Fibers.parallel` should be a single method call carrying everything worker-specific.

## Testing

- Specs substitute in-memory fakes for `Disk`. Nothing in `core/` touches I/O, so it is property-testable (`spec/pylon/core/properties_spec.cr` runs seeded random reconciliations).
- A bug fix ships with a regression spec verified to fail against the bug.
- `bench/` rots silently. Compile-check it after any rename.
