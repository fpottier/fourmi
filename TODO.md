# To Do

* `par` performs a `spawn_wait_modulo`.

* Could we get rid of the `State` effect?

* How can this library be thoroughly tested?

* Should `query` perform path compression?
  Are there other places where path compression should be performed?

* Should union-find be used in a different way,
  without `Proxy` futures? (Making links invisible.)
  When two futures are merged,
  their parent lists should be merged.

* Offer an operator that waits for one of / all of an array of futures to finish?
  That would be more efficient than a sequence of calls to `wait`
  or nested calls to `select`.

* Define a specialized form `conjunction (spawn _) (spawn _)`,
  which takes two tasks as arguments instead of two futures?
  Should it return a future, or do we want to also build in a `wait`?
  Same question about `select` and other binary combinators.

* Support cancellation. Allow a user task to throw an exception,
  record it in the future, throw it again when someone waits on the future.

* Is it a problem that we use fixed (toplevel) effect names?
  Does this cause problems with nested uses of `run`?
  Should each instance of `run` have
  its own effect names and/or
  its own abstract type of futures?

* In the field `awaits`, we could get rid of the option
  by using a sentinel.

* Before releasing, use `cppo` to get rid of the debugging support
  fields.
