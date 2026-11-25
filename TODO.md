# To Do

## Code

* Currently `wait fut` does not always yield; if `fut` is already fulfilled
  then the thread continues its execution without yielding. We might wish to
  modify `wait` so that it yields even in this case. We could then document
  the fact that `wait` yields.

## Testing

* Clean up `play.ml` and write hand-written tests / examples.
  Include examples where large computations are avoided.

* Enlarge the coverage of the randomized test suite.
  Write tests that involve a mutable store of futures,
  while avoiding deadlocks.

* Can we test that a thread whose future is unreachable is reclaimed
  by the GC?

* Benchmark. Measure the overhead compared with sequential execution.

## Release

* Before releasing, use `cppo` to get rid of the debugging support fields
  `fut.id` and `edge.active` and `s.next_future_id.

## LATER

* Consider building a form of granularity control inside `yield`.
  A call to `yield` really yields only one out of `K` times.
  One counter per thread, stored in the record `thread`.
  The global state lets us access the current thread via `s.current`.

* It is currently *not* OK to let a continuation be reclaimed by the GC
  without explicitly discontinuing it.
  + Wait for a future version of OCaml where this is permitted?
    If so, document the fact that user threads should not hold
    system resources, or these resources might be lost.
  + Or, keep a list of all threads and perform manual collection.
  + Or, install a finalizer on each thread.

* Should we perform path compression of `Proxy` links, in `query` or
  elsewhere?

* Should we use a union-find data structure off-the-shelf and remove `Proxy`
  futures entirely? The `Proxy` links would become entirely invisible. When
  two futures are merged, their parent lists should be merged.

* Should we offer a variant of `earliest_decisive` that accepts an array of
  futures, instead of just two futures? This might be messy, though. Once one
  child becomes fulfilled (but is not decisive), we have a hole in the array.

* Support cancellation. Allow a user task to throw an exception,
  record it in the future, throw it again when someone waits on
  the future.
  + Only for one dedicated exception, `Cancel`?
  + Or for every exception?

* Think about a truly parallel (multi-processor) implementation.

## Micro-optimizations

* In the type `thread`, the field `awaits` has type `untyped_edge option`.
  One could remove the option by using a pointer to a sentinel value.

* Defining `earliest`, `conjunction`, and `disjunction` in terms of
  `earliest_decisive` costs two words of memory in each edge of the binary
  future, because the functions `decisive1` and `decisive2` are stored in
  memory. One could avoid this by duplicating and specializing the code.

* Manual inlining of certain small functions in a large `let rec` may help.

## Related Work

* Read [Tail Modulo Async-Await](https://hal.science/hal-05006570v2/document).
  What is "the forward optimisation [...] applied to an asynchronous call in tail position"?

* [Godot: All the Benefits of Implicit and Explicit Futures](https://doi.org/10.4230/LIPIcs.ECOOP.2019.2)

* [An Optimised Flow for Futures: From Theory to Practice](https://arxiv.org/abs/2107.07298)

* [Active Objects based on Algebraic Effects](https://doi.org/10.1007/978-3-031-51060-1_1)

* "ParT: An Asynchronous Parallel Abstraction for Speculative Pipeline Computations"

* Futures in Haskell; parallel Haskell.

* Futures in C++ and Rust.

* Look at Picos and Moonpool.
