(**This library offers a {b speculative parallel execution} facility,
   where several tasks compete to produce a result as early as possible.
   It does not exploit hardware parallelism.

   A task is executed by a logical {i thread}. A new thread is created by
   [spawn] and by the combinators that use [spawn] internally. A full list
   of these combinators is: [spawn], [spawn_wait], [map], [bind],
   [earliest], [earliest_decisive], [conjunction], and [disjunction].

   All logical threads run on the same hardware thread. Their executions are
   interleaved at [yield] points. Therefore, executing two tasks in parallel
   {i until they both terminate} is no faster than executing these tasks in
   sequence. The raison d'être of this library is to allow {i speculative
   parallel execution}, that is, executing two tasks in parallel {i until one
   of them terminates}. This is made possible by the combinator
   [earliest_decisive] and by its special cases, which include [earliest],
   [conjunction], and [disjunction].

   Execution is demand-driven. A thread is executed only if, when, and as long
   as its result appears to be possibly needed. If the result of a currently
   running thread becomes unneeded, then this thread is suspended. If its
   result later becomes possibly needed again, then this thread is resumed
   where it left off. No work is duplicated. *)

(**Applying [Make()] creates a fresh scheduler. This scheduler is started by
   invoking [run] or [run_fut]. Although two nested calls to [run] on the same
   scheduler are forbidden, two nested calls to [run] on two distinct
   schedulers are permitted. *)
module Make () : sig

(* -------------------------------------------------------------------------- *)

(**{1 Basic Functions} *)

(**A task of type ['a task] is just a function of type [unit -> 'a]. It is a
   description of a computation that the user wishes to perform. A task may
   use the combinators offered by this library, such as {!yield}, {!earliest},
   {!spawn}, {!wait}, etc. To have the scheduler execute a task [task], call
   [run task]. Just calling [task()] will not work: it will result in an
   {i unhandled effect} exception.

   Because execution is demand-driven, a task or subtask is not always
   executed until it terminates: it may be stopped by the scheduler. Therefore
   a task should not allocate operating system resources that need to be
   eventually released, such as file descriptors. *)
type 'a task =
  unit -> 'a

(**[run task] executes the task [task] and returns its result.

   {!run} is the entry point of the scheduler: it should be called once, at
   the top level, to start the scheduler. In other words, the function [task]
   should not call {!run}. It may call any of the combinators offered by this
   library, such as {!yield}, {!earliest}, {!spawn}, {!wait}, etc.

   A nested call to {!run} results in an exception [Reentrancy]. An attempt to
   execute a task whose dependency graph is cyclic results in an exception
   [Deadlock]. These exceptions are currently not part of the public API, as
   they are not meant to be handled. *)
val run : 'a task -> 'a

(**{!yield} has no observable effect and returns no result. It offers an
   opportunity to the scheduler to suspend the current task and schedule
   another task. In order to ensure that every task regularly receives a share
   of execution time, every task must call {!yield} sufficiently often. *)
val yield: unit -> unit

(* -------------------------------------------------------------------------- *)

(**{1 Task API} *)

(**The task API is a simple, high-level API. It offers a small number of
   combinators that construct composite tasks out of simpler tasks. *)

(**The task API does not allow {i naming} the future result of a task before
   this task is executed. As a result, it only allows constructing a {i tree}
   of tasks. It does not allow constructing an acyclic {i graph} of tasks,
   where the result of a task can be awaited and used by several other tasks.
   For this purpose, the {{!section-future}Future API} must be used. *)

(**Although this may seem surprising, there is no parallel pair combinator.
   One might have expected a combinator [par : 'a task -> 'b task -> ('a * 'b)
   task], which spawns two subtasks, waits for them to terminate, and returns
   a pair of their results. However, such a combinator would not be useful. In
   our setting, running two tasks in parallel, until they complete, is no
   faster than running them in sequence. *)

(**On the other hand, the following combinators spawn two subtasks and (in
   some circumstances) are able to return as soon as one of them terminates,
   without waiting for the other subtask to terminate. *)

(**[conjunction task1 task2] returns the Boolean conjunction of the Boolean
   results produced by [task1] and [task2]. It is therefore equivalent to
   [task1() && task2()], but it runs [task1] and [task2] in parallel and is
   able to return [false] as soon as one of them returns [false], without
   waiting for the other task to terminate.

   {!conjunction} is a special case of {!earliest_decisive} where the result
   [false] is decisive. *)
val conjunction: bool task -> bool task -> bool

(**[disjunction task1 task2] returns the Boolean disjunction of the Boolean
   results produced by [task1] and [task2]. It is therefore equivalent to
   [task1() || task2()], but it runs [task1] and [task2] in parallel and is
   able to return [true] as soon as one of them returns [true], without
   waiting for the other task to terminate.

   {!disjunction} is a special case of {!earliest_decisive} where the result
   [true] is decisive. *)
val disjunction: bool task -> bool task -> bool

(**[earliest task1 task2] spawns the subtasks [task1] and [task2]. As soon as
   one of them terminates and returns a result, {!earliest} itself terminates
   and returns this result.

   The tasks [task1] and [task2] must have the same type. To apply {!earliest}
   to two tasks with distinct types ['a] and ['b], just wrap the results of
   these tasks in a common type, such as [('a, 'b) Either.t].

   {!earliest} is a special case of {!earliest_decisive} where every result is
   decisive. *)
val earliest: 'a task -> 'a task -> 'a

(**[earliest_decisive decisive1 decisive2 task1 task2] spawns the subtasks
   [task1] and [task2].

   If [task1] terminates first and returns [result1], if this result is {i
   decisive} (which is determined by the function call [decisive1 result1])
   then {!earliest_decisive} itself terminates and returns this result. if
   [result1] is not decisive then {!earliest_decisive} waits for [task2] to
   return a result [result2] and returns this result.

   If [task2] terminates first and returns [result2], then the situation is
   symmetric. If [decisive2 result2] is [true] then {!earliest_decisive}
   returns [result2]. Otherwise it waits for [task1] to terminate and
   transmits its result. *)
val earliest_decisive: ('a -> bool) -> ('a -> bool) -> 'a task -> 'a task -> 'a

(* -------------------------------------------------------------------------- *)

(**{1:future Future API} *)

(* low-level; can create cycles, disallowed *)

type 'a future
  (* can a future created by one instance of [run] be used outside of it? *)

val run_fut : 'a future -> 'a

val spawn: 'a task -> 'a future
  (* the new thread does not start running immediately; it starts
     running only if and when its result is awaited. A thread can be
     paused if its result is no longer awaited, and can be resumed if
     its result is awaited again. *)

val wait : 'a future -> 'a

(**[spawn_wait task] is equivalent to [spawn task |> join].
   It is also equivalent to [spawn (fun () -> wait (task()))]. *)
val spawn_wait : 'a future task -> 'a future

val earliest_fut: 'a future -> 'a future -> 'a future
val earliest_decisive_fut: ('a -> bool) -> ('a -> bool) -> 'a future -> 'a future -> 'a future
val conjunction_fut: bool future -> bool future -> bool future
val disjunction_fut: bool future -> bool future -> bool future

type 'a reply =
  | Result of 'a
  | Future of 'a future

val query : 'a future -> 'a reply

(* -------------------------------------------------------------------------- *)

(**{1 Monadic API} *)

(**[return x] is equivalent to [spawn (fun () -> x)],
   and is more efficient. *)
val return : 'a -> 'a future

val bind : 'a future -> ('a -> 'b future) -> 'b future

(**[map f fut] is equivalent to [spawn @@ fun () -> wait fut |> f].
   It is also equivalent to [bind fut (fun x -> return (f x))].
   It is more efficient than either of these expressions. *)
val map : ('a -> 'b) -> 'a future -> 'b future

val join : 'a future future -> 'a future

end (* Make *)
