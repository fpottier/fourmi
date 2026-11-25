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

module Make () : sig

(**The functor application [Make()] creates a fresh scheduler, whose mutable
   internal state includes a queue of threads that are ready to be executed.
   This scheduler is started by invoking {!run} or {!run_fut}.

   Some API functions can be called {i only while the scheduler is running},
   that is, only within the dynamic extent of a call to {!run} or {!run_fut}.
   These functions are {!wait}, {!yield}, {!conjunction}, {!disjunction},
   {!earliest}, {!earliest_decisive}, {!conjunction_fut}, {!disjunction_fut},
   {!earliest_fut}, and {!earliest_decisive_fut}. An attempt to call one of
   these functions while the scheduler is not running raises the exception
   [NotRunning].

   Some API functions can be called {i only while the scheduler is not
   running}. These functions are {!run} and {!run_fut}. In other words, {!run}
   and {!run_fut} cannot be nested. A nested call to {!run} or {!run_fut}
   raises the exception [Reentrancy]. (This said, if [Make()] is applied twice
   to create two distinct schedulers, then two uses of these distinct
   schedulers can be nested.)

   Some API functions can be called either while the scheduler is running
   or while it is not running. These functions are {!query}, {!spawn},
   {!spawn_wait}, {!return}, {!bind}, {!map}, {!join}.

   An attempt to execute a task whose dependency graph is cyclic causes {!run}
   and {!run_fut} to raise the exception [Deadlock]. It is up to the user to
   ensure that this graph remains acyclic. *)

(* -------------------------------------------------------------------------- *)

(**{1 Basic Functions} *)

(**A task of type ['a task] is just a function of type [unit -> 'a]. It is a
   description of a computation that the user wishes to perform. A task may
   use the combinators offered by this library, such as {!yield}, {!earliest},
   {!spawn}, {!wait}, etc.

   To let the scheduler execute a task [task], call [run task]. Just calling
   [task()] will not work: it will typically raise the exception [NotRunning],
   for the reasons described above.

   Because execution is demand-driven, a task or subtask is not always fully
   executed, that is, not always executed up to the point where it terminates.
   Instead, it may be stopped by the scheduler. Therefore a task should not
   allocate operating system resources that need to be eventually released,
   such as file descriptors. *)
type 'a task =
  unit -> 'a

(**[run task] starts the scheduler, executes the task [task], and returns its
   result. *)
val run : 'a task -> 'a

(**{!yield} has no observable effect and returns no result. It offers an
   opportunity to the scheduler to suspend the current task and schedule
   another task. In order to ensure that every task regularly receives a share
   of execution time, every task must call {!yield} sufficiently often. *)
val yield : unit -> unit

(* -------------------------------------------------------------------------- *)

(**{1:task Task API} *)

(**The Task API is a simple, high-level API. It offers a small number of
   combinators that construct composite tasks out of simpler tasks. *)

(**The Task API does not allow {i naming} the future result of a task before
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
val conjunction : bool task -> bool task -> bool

(**[disjunction task1 task2] returns the Boolean disjunction of the Boolean
   results produced by [task1] and [task2]. It is therefore equivalent to
   [task1() || task2()], but it runs [task1] and [task2] in parallel and is
   able to return [true] as soon as one of them returns [true], without
   waiting for the other task to terminate.

   {!disjunction} is a special case of {!earliest_decisive} where the result
   [true] is decisive. *)
val disjunction : bool task -> bool task -> bool

(**[earliest task1 task2] spawns the subtasks [task1] and [task2]. As soon as
   one of them terminates and returns a result, {!earliest} itself terminates
   and returns this result. {!earliest} is non-deterministic.

   The tasks [task1] and [task2] must have the same type. To apply {!earliest}
   to two tasks with distinct types ['a] and ['b], just wrap the results of
   these tasks in a common type, such as [('a, 'b) Either.t].

   {!earliest} is a special case of {!earliest_decisive} where every result is
   decisive. *)
val earliest : 'a task -> 'a task -> 'a

(**[earliest_decisive decisive1 decisive2 task1 task2] spawns the subtasks
   [task1] and [task2].

   Suppose [task1] terminates first and returns [result1]. If this result is
   {i decisive} (which is determined by the function call [decisive1 result1])
   then {!earliest_decisive} itself terminates and returns this result. If
   [result1] is not decisive then {!earliest_decisive} waits for [task2] to
   return a result [result2] and returns this result.

   If [task2] terminates first and returns [result2], then the situation is
   symmetric. If [decisive2 result2] is [true] then {!earliest_decisive}
   returns [result2]. Otherwise it waits for [task1] to terminate and
   transmits its result.

   {!earliest_decisive} is non-deterministic. *)
val earliest_decisive :
  ('a -> bool) -> ('a -> bool) ->
  'a task -> 'a task -> 'a

(* -------------------------------------------------------------------------- *)

(**{1:future Future API} *)

(**The Future API is slightly more complex and more low-level than the Task
   API. It allows {i naming} the future result of a task before this task is
   executed. Such a name is known as a {i future}. Once a future has been
   created, its result can be {i awaited} by several tasks. This allows {i
   sharing work} and creating a set of tasks whose dependencies form an
   acyclic graph. *)

(**It is up to the user to ensure that this graph remains acyclic. If the
   user creates a task that (transitively) awaits its own result, then an
   attempt to run this task will cause an exception [Deadlock]. *)

(**A future of type ['a future] represents a computation that has produced
   or will at some point in the future produce a result of type ['a]. *)
type 'a future

(**[run_fut fut] starts the scheduler, executes the computation represented by
   the future [fut], and returns its result.

   {!run_fut} is analogous to {!run} in the Task API. It is the entry point
   of the scheduler. It should be called once, at the top level, to start
   the scheduler. *)
val run_fut : 'a future -> 'a

(**['a reply] is the result type of the function {!query}. *)
type 'a reply =
  | Result of 'a
  | Future of 'a future

(**[query fut] does {i not} start the scheduler. If the future [fut] has been
   fully executed by a previous call to {!run} or {!run_fut} then its result
   is immediately returned. Otherwise the future [fut] itself, or an
   equivalent future, is returned. *)
val query : 'a future -> 'a reply

(**[spawn task] creates a new thread in charge of executing the task [task].
   It returns a new future, which represents the future result of this task.

   The new thread does {i not} start its execution immediately. It is executed
   only if and when [fut]'s result is demanded (needed). If, after this thread
   has started its execution, the scheduler finds that [fut]'s result is no
   longer needed, then this thread is paused. If, at a later time, [fut]'s
   result is needed again, then this thread is resumed. No work is thrown away
   or duplicated.

   Several other combinators use [spawn] internally to create one or two
   new threads. They are {!conjunction}, {!disjunction}, {!earliest},
   {!earliest_decisive}, {!spawn_wait}, {!map}, and {!bind}. *)
val spawn : 'a task -> 'a future
  (* The reason why a result that is needed at one time can become unneeded at
     a later time is that [earliest_decisive] can suspend one of its subtasks
     once its other subtask has finished. *)

(**[wait fut] waits until the result of the computation represented by the
   future [fut] becomes available, and returns this result. *)
val wait : 'a future -> 'a

(**[spawn_wait task] creates a new thread, which executes the task [task],
   whose result is a future, and awaits this result. Thus, it is equivalent to
   [spawn (fun () -> wait (task()))]. It is also equivalent to [spawn task |>
   join]. It is more efficient than either of these forms. *)
val spawn_wait : 'a future task -> 'a future

(**[conjunction_fut fut1 fut2] returns a future whose result is the Boolean
   conjunction of the Boolean results of the futures [fut1] and [fut2]. It is
   therefore equivalent to [spawn (fun () -> wait fut1 && wait fut2)], but it
   runs [fut1] and [fut2] in parallel and is able to return [false] as soon as
   one of them returns [false], without waiting for the other result to be
   available. *)
val conjunction_fut : bool future -> bool future -> bool future

(**[disjunction_fut fut1 fut2] returns a future whose result is the Boolean
   disjunction of the Boolean results of the futures [fut1] and [fut2]. It is
   therefore equivalent to [spawn (fun () -> wait fut1 || wait fut2)], but it
   runs [fut1] and [fut2] in parallel and is able to return [true] as soon as
   one of them returns [true], without waiting for the other result to be
   available. *)
val disjunction_fut : bool future -> bool future -> bool future

(**[earliest_fut fut1 fut2] returns a future whose result is the result of the
   future [fut1] or the result of the future [fut2], whichever is available
   earliest. It runs [fut1] and [fut2] in parallel and is able to return a
   result as soon as one of them finishes, without waiting for the other
   result to be available. It is non-deterministic. *)
val earliest_fut : 'a future -> 'a future -> 'a future

(**[earliest_decisive_fut decisive1 decisive2 fut1 fut2] returns a future
   whose result is the result [result1] of the future [fut1] or the result
   [result2] of the future [fut2], as determined by the following rule.

   Suppose [result1] becomes available first. If this result is {i decisive}
   (which is determined by the function call [decisive1 result1]) then
   [result1] is the final result and there is no need to wait for [result2] to
   be available. Otherwise, [result2] is the final result.

   If [result2] is available first then the situation is symmetric. If
   [decisive2 result2] is [true] then [result2] is the final result and there
   is no need to wait for [result1] to be available. Otherwise [result1] is
   the final result.

   {!earliest_decisive_fut} is non-deterministic. *)
val earliest_decisive_fut :
  ('a -> bool) -> ('a -> bool) ->
  'a future -> 'a future -> 'a future

(* -------------------------------------------------------------------------- *)

(**{1 Monadic API} *)

(**The type ['a future] is a monad. The following combinators can be used to
   write code in monadic style. However, this style is not recommended, as it
   is costly; {!bind} and {!map} each spawn a new thread. The recommended
   style is to use the direct-style combinators in the {{!section-task}Task
   API} and the {{!section-future}Future API}. *)

(**[return result] creates a future whose result is [result]. It is equivalent
   to [spawn (fun () -> result)], but it is more efficient, as it does not
   spawn a new thread. *)
val return : 'a -> 'a future

(**[bind fut task] spawns a new thread that awaits the result [a] of the
   future [fut], executes the task [task a], and awaits its result. It returns
   a future that represents the result of this thread. It is equivalent to
   [spawn (fun () -> wait fut |> task |> wait)]. It is also equivalent to
   [map task fut |> join]. It is more efficient than either of these forms. *)
val bind : 'a future -> ('a -> 'b future) -> 'b future

(**[map task fut] spawns a new thread that awaits the result [a] of the future
   [fut], executes the task [task a], and returns its result. It returns a
   future that represents the result of this thread. It is equivalent to
   [spawn (fun () -> wait fut |> task)]. It is also equivalent to
   [bind fut (fun a -> return (task a))].
   It is more efficient than either of these forms. *)
val map : ('a -> 'b) -> 'a future -> 'b future

(**[join fut] returns a future whose result is the result of the
   result of the future [fut].
   It is equivalent to [map wait fut].
   It is also equivalent to [bind fut (fun x -> x)].
   It is more efficient than either of these forms,
   as it does not spawn a new thread. *)
val join : 'a future future -> 'a future

end (* Make *)
