(**This library offers facilities for executing several tasks in parallel.

   A task is executed by a logical {i thread}. A new thread is created by
   {!spawn} and by several other combinators that use {!spawn} internally.

   At this time, there is no hardware parallelism. All logical threads run
   on the same hardware thread. Their executions are interleaved at {!yield}
   points. Therefore, executing two tasks in parallel {i until they both
   terminate} is {i not} faster than executing these tasks sequentially! The
   point of this library is to allow {i speculative parallel execution}, by
   which we mean executing two tasks in parallel {i until one of them
   terminates}. This is permitted by the combinators {!earliest},
   {!earliest_decisive}, {!conjunction}, and {!disjunction}.

   Execution is driven by demand. A thread is executed only if and as long
   as its result appears to be possibly needed. If the result of a currently
   running thread suddenly becomes unneeded, then this thread is suspended.
   If its result later becomes possibly needed, then this thread is resumed
   where it left off, so that no work is duplicated.

   TODO define futures

   To implement demand-driven execution, the library maintains a dynamic
   dependency graph, whose vertices are futures and where an edge from
   future {i A} to future {i B} means that {i A} is waiting for {i B} to
   receive a result. At all times, this graph is acyclic; it is a DAG. The
   future associated with the main thread, also known as the root future, is
   the entry point of this graph. At every moment, if a future {i F} is
   currently reachable from the root future, then the result of {i F} is
   currently possibly needed, and the thread associated with {i F} is
   allowed to continue its execution. If, on the contrary, {i F} is
   currently unreachable, then the result of {i F} is currently unneeded,
   and this thread is not allowed to run. The structure of the dependency
   graph changes over time. In particular, edges can appear and disappear.
   For example, a call to {!wait} creates a new edge. On the contrary, when
   one the two threads spawned by {!earliest} terminates, the result of the
   other thread is no longer required, so an edge is destroyed. Therefore, a
   reachable vertex can become unreachable, and vice-versa. As a result, a
   thread whose execution has begun can be suspended, and a suspended thread
   can be resumed.

   If the future that represents the result of a thread becomes unreachable
   in the eyes of the garbage collector (that is, unreachable from the root
   future, and also unreachable from every future that the client holds)
   then this future and this thread are reclaimed by the garbage collector,
   and this thread is never allowed to continue its execution. *)

(* -------------------------------------------------------------------------- *)

(* {2 Basic Functions} *)

type 'a task =
  unit -> 'a
  (* task is allowed to spawn, wait, yield *)

val run : 'a task -> 'a

val yield: unit -> unit

(* -------------------------------------------------------------------------- *)

(* {2 Task API} *)

(* high-level *)

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
