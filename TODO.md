# To Do

## Code

* Is it OK to let a continuation be reclaimed by the GC
  without explicitly discontinuing it?

* Could we get rid of the `State` effect?

* Should `query` perform path compression?
  Are there other places where path compression should be performed?

* Should union-find be used in a different way,
  without `Proxy` futures? (Making links invisible.)
  When two futures are merged,
  their parent lists should be merged.

* Offer an operator that waits for one of / all of an array of futures to finish?
  That would be more efficient than a sequence of calls to `wait`
  or nested calls to `select`.

* Support cancellation. Allow a user task to throw an exception,
  record it in the future, throw it again when someone waits on
  the future.
  + Only for one dedicated exception, `Cancel`?
  + Or for every exception?

* Is it a problem that we use fixed (toplevel) effect names?
  Does this cause problems with nested uses of `run`?
  Should each instance of `run` have
  its own effect names and/or
  its own abstract type of futures?

* Perhaps prefer to remove a thread from the queue when it becomes
  inactive or blocked; this would be cleaner (though slower?).

## Testing

* Test with variables of type future, so we get a DAG.
  Also test with a mutable store of futures,
  while avoiding deadlocks.

* Can we test that a thread whose future is unreachable is reclaimed
  by the GC?

## Release

* Before releasing, use `cppo` to get rid of the debugging support fields
  `fut.id` and `edge.parent`.

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

* Defining `conjunction` and `disjunction` in terms of `earliest_decisive`
  costs two words of memory in each edge of the binary future, because the
  functions `decisive1` and `decisive2` are stored in memory. One could avoid
  this by duplicating and specializing the code.
