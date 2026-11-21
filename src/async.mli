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
