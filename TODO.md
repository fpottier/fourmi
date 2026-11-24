# To Do

## Code

* Document which functions must be called in the scope of `run`
  and which functions can be called outside of its scope.
  Dynamically test that `s.running` is true when a function
  of the first kind is invoked.

* It is currently *not* OK to let a continuation be reclaimed by the GC
  without explicitly discontinuing it.
  + Wait for a future version of OCaml where this is permitted?
    If so, document the fact that user threads should not hold
    system resources, or these resources might be lost.
  + Or, keep a list of all threads and perform manual collection.
  + Or, install a finalizer on each thread.

* Should `query` perform path compression?
  Are there other places where path compression should be performed?

* Should union-find be used in a different way,
  without `Proxy` futures? (Making links invisible.)
  When two futures are merged,
  their parent lists should be merged.

* Offer an operator that waits for one of / all of an array of futures to finish?
  That would be more efficient than a sequence of calls to `wait`
  or nested calls to `earliest`.
  The difficulty with an array is what to do once one child becomes
  done (but is not decisive).

* Support cancellation. Allow a user task to throw an exception,
  record it in the future, throw it again when someone waits on
  the future.
  + Only for one dedicated exception, `Cancel`?
  + Or for every exception?

* Consider building a form of granularity control inside `yield`.
  A call to `yield` really yields only one out of `K` times.
  One counter per thread.

## Documentation

* Document whether it is necessary to call `yield`
  as opposed to just `spawn` and `wait`.
  Maybe `spawn` and `wait` should implicitly yield.

## Testing

* Test with variables of type future, so we get a DAG.
  Also test with a mutable store of futures,
  while avoiding deadlocks.

* Can we test that a thread whose future is unreachable is reclaimed
  by the GC?

* Benchmark; measure the overhead compared with sequential execution.

## Release

* Before releasing, use `cppo` to get rid of the debugging support fields
  `fut.id` and `edge.active` and `s.next_future_id.

## Related Work

* Read [Tail Modulo Async-Await](https://hal.science/hal-05006570v2/document).
  What is "the forward optimisation [...] applied to an asynchronous call in tail position"?

* [Godot: All the Benefits of Implicit and Explicit Futures](https://doi.org/10.4230/LIPIcs.ECOOP.2019.2)

* [An Optimised Flow for Futures: From Theory to Practice](https://arxiv.org/abs/2107.07298)

* [Active Objects based on Algebraic Effects](https://doi.org/10.1007/978-3-031-51060-1_1)

* "ParT: An Asynchronous Parallel Abstraction for Speculative Pipeline Computations"

* Futures in Haskell; parallel Haskell.

* Futures in C++ and Rust.

* Look at Picos, Moonpool, and other existing libraries to see whether
  something similar exists.

## Micro-optimizations

* In the type `thread`, the field `awaits` has type `untyped_edge option`.
  One could remove the option by using a pointer to a sentinel value.

* Defining `earliest`, `conjunction`, and `disjunction` in terms of
  `earliest_decisive` costs two words of memory in each edge of the binary
  future, because the functions `decisive1` and `decisive2` are stored in
  memory. One could avoid this by duplicating and specializing the code.
