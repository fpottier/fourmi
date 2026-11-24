(**This library offers a {b speculative parallel execution} facility,
   where several tasks compete to produce a result as early as possible.
   It does not exploit hardware parallelism.

   A task is executed by a logical {i thread}. A new thread is created by
   {!spawn} and by the combinators that use {!spawn} internally. A full list
   of these combinators is: {!spawn}, {!spawn_wait}, {!map}, {!bind},
   {!earliest}, {!earliest_decisive}, {!conjunction}, and {!disjunction}.

   All logical threads run on the same hardware thread. Their executions are
   interleaved at {!yield} points. Therefore, executing two tasks in parallel
   {i until they both terminate} is no faster than executing these tasks in
   sequence. The raison d'être of this library is to allow {i speculative
   parallel execution}, that is, executing two tasks in parallel {i until one
   of them terminates}. This is made possible by the combinator
   {!earliest_decisive} and by its special cases, which include {!earliest},
   {!conjunction}, and {!disjunction}.

   Execution is demand-driven. A thread is executed only if, when, and as long
   as its result appears to be possibly needed. If the result of a currently
   running thread becomes unneeded, then this thread is suspended. If its
   result later becomes possibly needed again, then this thread is resumed
   where it left off. No work is duplicated. *)

(* -------------------------------------------------------------------------- *)

(* {2 Basic Functions} *)

module Make () : sig

(**A task whose result type is ['a] is just a function of type [unit -> 'a]. *)
type 'a task =
  unit -> 'a

(**[run task] runs the task [task] and returns its result. This task is
   allowed to create subtasks, to let them run in parallel, and to await
   their results. To do so, it can use all the API functions described
   below. *)
val run : 'a task -> 'a
  (* [run] can raise [Deadlock] and [Reentrancy]; publish them? *)

val yield: unit -> unit

(* -------------------------------------------------------------------------- *)

(* {2 Task API} *)

(* high-level *)

(* TODO this API only allows constructing a tree of tasks;
   the future API allows naming the result of a task,
   thereby sharing it; allows constructing a DAG of tasks,
   or even a cyclic graph, though this is invalid *)

(* There is no [par] combinator because it would not be useful.
   In our setting, running two tasks in parallel, until they
   complete, is equivalent to running them in sequence. *)

val earliest: 'a task -> 'a task -> 'a
  (* To apply [earliest] to two tasks of types ['a task] and ['b task],
     just wrap the results of these tasks in a common type, such as
     [('a, 'b) Either.t]. *)

val earliest_decisive: ('a -> bool) -> ('a -> bool) -> 'a task -> 'a task -> 'a

val conjunction: bool task -> bool task -> bool
val disjunction: bool task -> bool task -> bool

(* -------------------------------------------------------------------------- *)

(* {2 Future API} *)

(* low-level *)

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

(* {2 Monadic API} *)

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
