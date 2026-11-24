open Printf
open Effect
open Effect.Shallow
type mark = Mark.t

(* -------------------------------------------------------------------------- *)

(* The functor [Make()] begins here. Each application of [Make()] initializes
   a fresh scheduler state, which all functions have access to. *)

(* Even though the type ['a future] does not depend on the scheduler's state,
   we make the functor generative, and publish the type ['a future] as part of
   the functor's result signature. Thus, each application of [Make()] produces
   a new abstract type of futures. A future created by one instance of
   [Make()] cannot be passed to another instance of [Make()]. This seems
   desirable. If we removed this restriction, we would find that running a
   user-provided task can modify our internal data structures (the futures
   and the DAG). *)

module Make () = struct

(* -------------------------------------------------------------------------- *)

(* In order to try and keep track of effects at the type level, we introduce
   a distinction between the types ['a task] and ['a resumption]. When we
   construct a resumption using the data constructor [Resumption], we check,
   by visual inspection, that the task has been wrapped in our effect
   handler, which is implemented by the function [handle]. *)

(* A task of type ['a task] produces a value of type ['a].
   It may perform effects: IT IS NOT wrapped in an effect handler. *)

type 'a task =
  unit -> 'a

(* A resumption of type ['a resumption] produces a value of type ['a].
   It cannot perform effects: IT IS wrapped in our effect handler. *)

type 'a resumption =
  | Resumption of 'a task [@@unboxed]

let[@inline] execute (task : 'a resumption) : 'a =
  match task with
  | Resumption task ->
      task()

(* A shallow continuation is not wrapped in an effect handler.
   It is executed by our effect handler, [handle]. *)

type 'a cont =
  ('a, unit) continuation

(* -------------------------------------------------------------------------- *)

(* We work with two main kinds of objects, namely futures and threads.

   A future is a placeholder for a result that is perhaps not yet available,
   but will become available once it has been computed. It can be viewed
   roughly as a reference that contains either nothing yet or a result.

   A thread is a computation whose ultimate aim is to fulfill one future.
   Every thread aims to fulfill a future. A future that is meant to be
   fulfilled by a thread is ordinary. Not every future is ordinary. *)

(* The main thread and the root future are created by the public function
   [run]. Auxiliary threads are created by the public functions [spawn],
   [spawn_wait], [map], [bind]. When a thread is created, a new ordinary
   future is created as well, and this thread is in charge of fulfilling this
   future. *)

(* Besides ordinary futures, we have proxy futures, join futures, and earliest
   futures. These futures do not have a corresponding thread.
   1- A proxy future watches one future
      and adopts its result.
   2- A join future watches one future
      and transforms itself into a proxy for its result.
   3- An earliest future watches two futures and
      either adopts the result of the child that terminates first
      or transforms itself into a proxy for the remaining child. *)

(* Futures and threads form a dependency graph, whose edges evolve over time:
   1- An ordinary future depends on the thread that will fulfill this future.
   2- A thread that is currently waiting for a future to be fulfilled
      currently depends on this future.
   3- A proxy future depends on one other future.
   4- A join future depends on one other future.
   5- An earliest future depends on two other futures. *)

(* The dependency graph is acyclic: it is a DAG. If the client uses mutable
   state in a strange way, then the dependency graph can become cyclic, but
   that would be a mistake on the client's part. *)

(* In the dependency graph, a thread has exactly one parent and at most one
   child. In order to simplify our view of the graph, we do not view threads
   as vertices in the dependency graph; only futures are vertices.
   Therefore, items 1- and 2- above can be summed up as follows:
   1- If an ordinary future F is meant to be fulfilled by thread T,
      and if thread T is currently waiting on future F',
      then F currently depends on F'. *)

(* An unfulfilled future is currently active if and only if it is currently
   reachable from the root future via a path in the dependency graph.
   A fulfilled future is inactive.  *)

(* A thread is said to be ready if it is either currently running or logically
   present in the scheduler's queue. A thread is said to be suspended if it is
   not ready, that is, neither running nor present in the queue. A thread is
   said to be blocked if it is currently waiting on a future. *)

(* Suppose that an ordinary future F is meant to be fulfilled by thread T.
   Then T is ready if and only if T awaits nothing **and F is active**.

   That is, thread T is allowed to run only if its result may (transitively)
   be needed by the root future. When a thread becomes unreachable from the
   root future, it is suspended. Therefore, we avoid wasting work computing
   results that are definitely not needed. A suspended thread is not thrown
   away; it is kept at hand, and is scheduled again when it becomes reachable
   again. *)

(* Every future F' stores a bag of its active parents. By this, we mean a bag
   of active incoming edges. These are the edges F → F' such that F watches F'
   and F is active. This bag is represented as a possibly empty, circular
   doubly-linked list of edges, so an edge can be added or removed in constant
   time.

   A future is active if and only if its bag of active parents is nonempty.
   The root future is equipped with a dummy incoming edge, so it is always
   active. *)

(* When a future is fulfilled, its active parents are notified. This is made
   possible by the bag of edges that point up to the active parents.

   The inactive parents must not appear in this bag, because 1- we do not
   wish to waste time notifying an inactive parent, and more importantly,
   2- we wish to let the garbage collector reclaim an inactive parent that
   has become unreachable.

   Therefore, when a parent becomes inactive, it must be removed from its
   children's bags of active parents. *)

(* In summary, we maintain a DAG where the vertices are objects of type
   ['a future] and the edges are objects of type ['a edge]. Within this
   graph, two areas must be carefully distinguished, namely the active
   vertices versus the inactive vertices.

   1- Every vertex carries pointers to its outgoing edges,
      which point to its children.
   2- Every vertex carries pointers to its active incoming edges,
      which point to its active parents.

   In other words, the downward links, from a vertex to its children,
   exist everywhere, whereas the upwards links, from a child to its
   parents, exist only in the active area of the graph.

   The active area and on the inactive area enjoy different invariants. In the
   active area, a stronger invariant is imposed, namely: if an edge F → F' is
   active, then F' is not fulfilled. (Indeed, once F' becomes fulfilled, then,
   because this edge is active, F is notified and updates its status.) In the
   inactive area, this property is not true. *)

type thread = {

  mutable resumption : unit resumption;
    (**The resumption that this thread intends to execute.

       While this thread is the current thread, this field contains the
       value [dummy_resumption]. Otherwise, it contains a meaningful
       value. *)

  fulfills           : untyped_future;
    (**The future that this thread intends to fulfill.

       This future can be viewed as the parent of this thread in the
       dependency graph.

       Two distinct threads have distinct [fulfills] futures. Therefore the
       unique identifier of this future can also be viewed as the unique
       identifier of this thread. *)

  mutable awaits     : untyped_edge option;
    (**The future that this thread currently awaits (if there is one).

       This future can be viewed as the child of this thread in the
       dependency graph. *)

  mutable enqueued   : bool;
    (**Whether this thread is currently physically present in the queue. When
       a thread becomes inactive, it is logically removed from the queue, but
       remains physically present in the queue. This flag lets us test whether
       a thread is physically in the queue. Thus we avoid enqueuing a thread
       twice. *)

}

and 'a edge = {

  mutable notify     : 'a notify;
    (**Information on how to notify this edge's parent future once the child
       future produces a result. *)

  child              : 'a future;
    (**This edge's child future. It is the target of this directed edge.

       This future is empty (not fulfilled). Indeed, once a future is
       fulfilled, its parents are notified and the edges that point down
       to this future disappear. *)

  mutable prev       : 'a edge;
  mutable next       : 'a edge;
    (**This edge's previous and next neighbors in the circular doubly-linked
       list of the child's active parents. If this edge is currently
       isolated (that is, not a member of any doubly-linked list) then
       [prev] and [next] point to this edge itself. *)

  mutable active     : bool;
    (**Whether this field is currently considered active. This field is used
       for debugging purposes only. *)

}

(**A value of type ['a notify] decorates an edge of type ['a edge]. It
   describes the relationship between the parent and child. It can also
   be viewed as a defunctionalized function [notify : 'a -> unit]. *)
and 'a notify =
  | NRoot     : 'a notify
      (**The child is the root future. There is no parent. *)

  | NAwaken   : thread * 'a cont -> 'a notify
      (**The parent is an ordinary future. Therefore a thread [thread]
         is waiting on the child's result to run a continuation [k]. *)

  | NProxy    : 'a future -> 'a notify
      (**The parent is a proxy future. Its result has the same type as
         the child's result. *)

  | NJoin     : 'a future -> 'a future notify
      (**The parent is a join future. If the child's result has type
         ['a future] then the parent's result has type ['a]. *)

  | NEarliest : 'a future -> 'a notify
      (**The parent is an earliest future. Its result has the same type as
         the child's result. We might wish to store the index of the child
         in the sequence of the parent's children; this is not currently
         done. *)

(* [untyped_edge] is the existential type [∃'a. 'a edge]. It is an edge
   where the child's result type is unknown. The data constructor [UE]
   serves as a hint for the OCaml type-checker; at runtime, an untyped
   edge is an edge. *)

and untyped_edge =
  | UE : 'a edge -> untyped_edge [@@unboxed]

and 'a future = {

  id                 : int;
    (**A unique identifier for this future.

       This field is used for debugging purposes only. *)

  mutable status     : 'a status;
    (**The current status of this future. *)

  mutable mark       : mark;
    (**A transient mark, for use during certain DAG traversals. *)

}

(* [untyped_future] is the existential type [∃'a. 'a future]. It is a future
   whose result type is unknown. The data constructor [UF] serves as a hint
   for the OCaml type-checker; at runtime, an untyped future is a future. *)

and untyped_future =
  | UF : 'a future -> untyped_future [@@unboxed]

and 'a status =

  | Uninitialized
      (**An uninitialized future. *)

  | Done of  { result : 'a }
      (**A fulfilled future, whose result is stored. *)

  | Ordinary of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      mutable thread  : thread;
        (**The thread in charge of fulfilling this future. *)

    }
      (**An ordinary future, whose result has not yet been computed.
         An ordinary future is eventually fulfilled by a thread. *)

  | Proxy of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      edge            : 'a edge;
        (**A downward edge to the future that this future watches. *)

    }
      (**A proxy future copies the result of its child.  *)

  | Join of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      edge            : 'a future edge;
        (**A downward edge to the future that this future watches. *)

    }
      (**A join future transforms itself into a proxy for the
         future produced by its child.  *)

  | Earliest of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      edge1 : 'a edge;
      edge2 : 'a edge;
        (**Downward edges toward the futures that this future watches. *)

      decisive1 : 'a -> bool;
      decisive2 : 'a -> bool;
        (**[decisive1 result1] examines the result [result1] produced by the
           first child and determines whether this result is decisive, that
           is, whether it should be made the result of this future. If so,
           this becomes fulfilled. Otherwise, this future stops watching this
           child and becomes a proxy for its remaining child. *)

    }
      (**An "earliest" future watches an array of futures. *)

(**A bag of edges is a possibly empty doubly-linked list of edges. *)
and 'a parents =
  'a edge option

(* -------------------------------------------------------------------------- *)

(* Dummy resumption; dummy future; dummy thread. *)

(* These are needed to allow initialization in several steps. *)

let dummy_resumption : 'a resumption =
  Resumption (fun () -> assert false)

let dummy_mark =
  Mark.fresh()

let dummy_future : 'a future =
  let id = -1
  and status = Uninitialized
  and mark = dummy_mark in
  { id; status; mark }

let dummy_thread : thread =
  let resumption = dummy_resumption
  and fulfills = UF dummy_future
  and awaits = None
  and enqueued = false in
  { resumption; fulfills; awaits; enqueued }

(* -------------------------------------------------------------------------- *)

(* Debugging support. *)

let debug =
  false

(* [info format ...] prints a message. Use [if debug then info format ...]. *)

let info format =
  ksprintf (fun msg -> eprintf "[scheduler] %s\n%!" msg) format

(* [fail format ...] prints a message and returns [false]. Use it inside
   an assertion, after determining that the Boolean condition is false. *)

let fail format =
  ksprintf (fun msg -> eprintf "[scheduler] %s\n%!" msg; false) format

(* By convention, the ID of a thread is the ID of its target future. *)

let[@inline] thread_id thread =
  match thread.fulfills with
  | UF fut ->
      fut.id

(* [print_future] prints internal information about a future. *)

let print_future fut =
  if debug then
    match fut.status with
    | Uninitialized ->
        info "  Future %d is uninitialized." fut.id
    | Done _ ->
        info "  Future %d is done." fut.id
    | Ordinary _ ->
        info "  Future %d is ordinary." fut.id
    | Proxy { edge; _ } ->
        info "  Future %d is a proxy for future %d."
          fut.id edge.child.id
    | Join { edge; _ } ->
        info "  Future %d is a join future, watching future %d."
          fut.id edge.child.id
    | Earliest { edge1; edge2; _ } ->
        info "  Future %d is an earliest future, watching futures %d and %d."
          fut.id edge1.child.id edge2.child.id

(* [print_future] prints internal information about a thread, about
   its target future, and about the future that it awaits. *)

let[@warning "-32"] print_thread thread =
  if debug then
    let id = thread_id thread in
    let UF fut = thread.fulfills in
    info "Thread %d is in charge of fulfilling future %d." id fut.id;
    print_future fut;
    match thread.awaits with
    | None ->
        info "Thread %d awaits nothing." id
    | Some (UE edge) ->
        let child = edge.child in
        info "Thread %d awaits future %d." id child.id;
        print_future child

(* [show_edge_parent edge] returns the identifier the source vertex of the
   edge [edge] as a string. *)

let show_edge_parent : type a . a edge -> string =
fun edge ->
  match edge.notify with
  | NRoot ->
      "<root>"
  | NAwaken (thread, _) ->
      sprintf "%d" (thread_id thread)
  | NProxy parent ->
      sprintf "%d" parent.id
  | NJoin parent ->
      sprintf "%d" parent.id
  | NEarliest parent ->
      sprintf "%d" parent.id

(* -------------------------------------------------------------------------- *)

(* The scheduler's state. *)

type state = {

  mutable current: thread;
    (**The thread that is currently running.

       The field [current.resumption] contains [dummy_resumption]. Indeed,
       when a thread is about to become the current thread,
       [thread.resumption] is read and, just before this resumption is
       executed, is overwritten with [dummy_resumption]. *)

  queue: thread Queue.t;
    (**A queue of threads all active and unblocked threads. A thread is active
       if it is reachable from the root future. A thread is unblocked if it is
       not currently awaiting a future.

       The queue may also contain threads that are NOT active and unblocked.
       These threads should be ignored; they are not logically part of the
       queue.

       The flag [thread.enqueued] indicates whether a thread is physically
       in the queue. It is used to avoid inserting a thread twice into the
       queue.

       Quite surprisingly, extracting ANY resumption out of the queue and
       running this resumption until it terminates effectively runs ALL
       resumptions until the main resumption terminates (or until a deadlock
       is reached). *)

  mutable running: bool;
    (**Whether a call to [run_fut] or [run] is currently in progress. This
       is used to detect reentrant calls to [run], which must be forbidden,
       because each invocation of [run] should have its own [state] record. *)

  mutable next_future_id: int;
    (**The next available future ID. This field is used for debugging only. *)

}

(* Allocate the scheduler's state. *)

let s : state =
  let current = dummy_thread
  and queue = Queue.create()
  and running = false
  and next_future_id = 0 in
  { current; queue; running; next_future_id }

(* Initialize or re-initialize the scheduler's state. *)

(* [init action] runs [action()] with a re-initialized scheduler state.
   It detects and forbids reentrant calls. *)

(* is invoked by [run_fut] and [run]. *)

exception Reentrancy

let[@inline] init action =
  if s.running then raise Reentrancy;
  s.current <- dummy_thread;
  Queue.clear s.queue;
  s.running <- true;
    (* [next_future_id] is not reset because
       a future can persist across several calls to [run]. *)
  let finished() = s.running <- false in
  Fun.protect ~finally:finished action

(* -------------------------------------------------------------------------- *)

(* The effects that we use internally. *)

(* Each application of the functor [Make()] causes two fresh effect names
   [Wait] and [Yield] to be dynamically generated. Therefore, two distinct
   applications of [Make()] use distinct effect names, and do not interfere
   with each other, even if they are nested within one another. *)

type _ Effect.t +=
| Wait  : 'a future -> 'a Effect.t
| Yield : unit Effect.t

(* Public combinators. *)

let[@inline] wait fut =
  perform (Wait fut)

let[@inline] yield () =
  perform Yield

(* -------------------------------------------------------------------------- *)

(* Basic tests and queries on futures and threads. *)

(* The following little functions are used in assertions. *)

let is_ordinary fut =
  match fut.status with Ordinary _ -> true | _ -> false

let is_proxy fut =
  match fut.status with Proxy _ -> true | _ -> false

let is_join fut =
  match fut.status with Join _ -> true | _ -> false

let is_earliest fut =
  match fut.status with Earliest _ -> true | _ -> false

(* [is_initialized fut] tests whether [fut] has been initialized. *)

let[@inline] is_initialized (fut : 'a future) : bool =
  match fut.status with Uninitialized -> false | _ -> true

(* [is_fulfilled fut] tests whether [fut] has already received a value. *)

(* We are interested in [fut] itself. If [fut] is a proxy for [fut'], then we
   do not follow the link. Indeed, once [fut'] becomes fulfilled, we do not
   wish to consider that [fut] implicitly becomes fulfilled at the same time.
   Instead, assuming that [fut] is active, we expect [fut'] to notify [fut],
   which then becomes fulfilled and no longer points to [fut']. *)

let[@inline] is_fulfilled (fut : 'a future) : bool =
  assert (is_initialized fut);
  match fut.status with
  | Done _ ->
      true
  | Uninitialized
  | Ordinary _
  | Join _
  | Earliest _
  | Proxy _ ->
      false

let[@inline] is_unfulfilled fut =
  not (is_fulfilled fut)

(* [is_active fut] determines whether the future [fut] is active. This is
   done by testing whether its list of active parents is nonempty. *)

(* If [fut] is fulfilled then it is inactive. *)

let is_active (fut : 'a future) : bool =
  assert (is_initialized fut);
  match fut.status with
  | Uninitialized
  | Done _ ->
      false
  | Ordinary { parents; _ }
  | Proxy { parents; _ }
  | Join { parents; _ }
  | Earliest { parents; _ }
      -> Option.is_some parents

let[@inline] is_inactive fut =
  not (is_active fut)

(* If the result of the future [fut] is available then [unsafe_query fut]
   returns this result. Otherwise [unsafe_query fut] returns [fut] or an
   equivalent future, obtained from [fut] by following a chain of [Proxy]
   links. *)

(* [fut] is not necessarily active. Thus, one should not use [unsafe_query]
   directly. Instead, one should use [query], which performs a cleanup
   phase, starting at [fut], before attempting to determine whether [fut]
   has been fulfilled. *)

(* Once a [Proxy] link has been followed, we cannot reach a fulfilled
   future. This is true both in the case where [fut] is active and in the
   case where [fut] is inactive and has been cleaned up. The auxiliary
   function [unsafe_query1] verifies this fact. *)

type 'a reply =
  | Result of 'a
  | Future of 'a future

let rec unsafe_query1 (fut : 'a future) : 'a reply =
  assert (is_initialized fut);
  assert (is_unfulfilled fut);
  match fut.status with
  | Uninitialized
  | Done _
  | Ordinary _
  | Join _
  | Earliest _ ->
      Future fut
  | Proxy { edge; _ } ->
      unsafe_query1 edge.child

let unsafe_query (fut : 'a future) : 'a reply =
  assert (is_initialized fut);
  match fut.status with
  | Done { result } ->
      Result result
  | Uninitialized
  | Ordinary _
  | Join _
  | Earliest _ ->
      Future fut
  | Proxy { edge; _ } ->
      unsafe_query1 edge.child

(* [thread_is_active thread] determines whether the thread [thread] is
   active. This is done by testing whether the future [thread.fulfills]
   is active. *)

let[@inline] thread_is_active thread =
  match thread.fulfills with
  | UF fut ->
      assert (is_ordinary fut);
      is_active fut

let[@inline] thread_is_inactive thread =
  not (thread_is_active thread)

(* [is_blocked thread] determines whether [thread] is blocked, that is,
   waiting for the result of a future to become available. *)

let[@inline] is_blocked thread =
  match thread.awaits with None -> false | Some _ -> true

let[@inline] is_unblocked thread =
  not (is_blocked thread)

(* -------------------------------------------------------------------------- *)

(* Creating new threads, edges, and futures. *)

(* [new_thread fut resumption] creates a new thread in charge of fulfilling
   the future [fut] by running the resumption [resumption]. *)

let new_thread (fut : 'a future) (resumption : unit resumption) : thread =
  let fulfills = UF fut
  and awaits = None
  and enqueued = false in
  let thread = { resumption; fulfills; awaits; enqueued } in
  if debug then
    info "Creating thread %d." (thread_id thread);
  thread

(* [new_edge child] creates a new edge whose target vertex is [child]. The
   edge's [notify] field is not initialized, and must be initialized before
   this edge is used. This two-step initialization process is necessary
   because the parent future and the edge point to each other. *)

let new_edge child =
  assert (is_unfulfilled child);
  let notify = NRoot
  and active = false in
  let rec edge = { notify; child; prev = edge; next = edge; active } in
  edge

(* [new_future kind] creates a new uninitialized future [fut]. The field
   [fut.status] is not initialized, and must be initialized before this
   future is used. This two-step initialization process is necessary
   because the future and its status point to each other. The string
   [kind] is used in a debugging message. *)

let new_future (kind : string) : 'a future =
  let id = s.next_future_id in
  s.next_future_id <- id + 1;
  let status = Uninitialized
  and mark = dummy_mark in
  if debug then
    info "Creating %s future %d." kind id;
  { id; status; mark }

let[@inline] init_ordinary_future (fut : 'a future) (thread : thread) =
  let parents = None in
  fut.status <- Ordinary { parents; thread }

let[@inline] init_join_future fut edge =
  let parents = None in
  fut.status <- Join { parents; edge }

let[@inline] init_earliest_future fut edge1 edge2 decisive1 decisive2 =
  let parents = None in
  fut.status <- Earliest { parents; edge1; edge2; decisive1; decisive2 }

(* [new_ordinary_future_and_thread resumption] creates a new ordinary
   future [fut] together with a new thread, initializes this thread's
   resumption with the result of [resumption fut], and displays debugging
   messages. It returns the new future [fut] and the thread [thread]. *)

let[@inline] new_ordinary_future_and_thread
  (resumption : 'a future -> unit resumption)
: 'a future * thread =
  (* Create a new uninitialized future. *)
  let fut = new_future "ordinary" in
  (* Create a new thread that runs the resumption [resumption fut]. *)
  let thread = new_thread fut (resumption fut) in
  (* Complete the initialization of [fut]. *)
  init_ordinary_future fut thread;
  (* Done. *)
  if debug then
    info "Thread %d spawns a new thread %d."
      (thread_id s.current) fut.id;
  fut, thread

let[@inline] new_ordinary_future resumption : 'a future =
  let fut, _thread = new_ordinary_future_and_thread resumption in
  fut

(* -------------------------------------------------------------------------- *)

(* Operations on the scheduler's queue. *)

(* [enqueue thread] inserts the thread [thread] into the queue. *)

let[@inline] enqueue (thread : thread) : unit =
  (* This thread must be active. *)
  assert (
    thread_is_active thread ||
    fail "About to enqueue thread %d, but it is not active!\n%!"
      (thread_id thread)
  );
  (* This thread must be unblocked. *)
  assert (is_unblocked thread);
  (* Insert this thread into the queue. *)
  if debug then
    info "Enqueuing thread %d." (thread_id thread);
  (* If this thread is already physically present in the queue, do nothing;
     otherwise enqueue it. *)
  if not thread.enqueued then begin
    thread.enqueued <- true;
    Queue.add thread s.queue
  end

(* [dequeue()] extracts a thread from the queue, if there is one, and
   executes its resumption. As noted above, this runs the scheduler until
   the main thread terminates or until a deadlock is reached. *)

(* [dequeue] potentially overwrites [s.current]. *)

(* We allow the queue to contain inactive threads. This obviates the need to
   need to remove a thread from the queue when it becomes inactive. This
   implies that a thread can appear several times in the queue, which
   implies that a blocked thread can appear in the queue. *)

let rec dequeue () : unit =
  match Queue.take s.queue with
  | exception Queue.Empty ->
      ()
  | thread ->
      assert (thread.enqueued);
      thread.enqueued <- false;
      (* If this thread is inactive or blocked, ignore it. *)
      if thread_is_inactive thread || is_blocked thread then
        dequeue()
      else begin
        (* Make this thread the current thread. *)
        s.current <- thread;
        (* Read the thread's resumption, then overwrite this field, so as to
           avoid a memory leak. Indeed, once the resumption runs, there is
           no need to store it any more. Furthermore, this guarantees that
           we do not mistakenly run this resumption a second time. *)
        let resumption = thread.resumption in
        thread.resumption <- dummy_resumption;
        if debug then
          info "Now running thread %d." (thread_id thread);
        execute resumption
      end

(* -------------------------------------------------------------------------- *)

(* Operations on bags (doubly-linked lists) of parent edges. *)

(* [entry parents] returns the entry point of the doubly-linked list
   [parents], under the assumption that this list is nonempty. *)

let[@inline] entry (parents : 'a parents) : 'a edge =
  match parents with
  | None ->
      assert false
  | Some edge ->
      edge

(* [get_parents fut] reads the [parents] field of the future [fut]. *)

(* [update_parents fut f] applies the transformation function [f] to the
   [parents] field of the future [fut]. This field exists only if [fut] is
   not fulfilled already. *)

(* There is some code duplication here, because the [parents] field
   appears in several branches of the algebraic data type [status],
   yet the OCaml type-checker considers these fields unrelated. *)

let[@inline] get_parents (fut : 'a future) : 'a parents =
  assert (is_initialized fut);
  match fut.status with
  | Uninitialized
  | Done _ ->
      None
  | Ordinary r ->
      r.parents
  | Proxy r ->
      r.parents
  | Join r ->
      r.parents
  | Earliest r ->
      r.parents

let[@inline] update_parents (fut : 'a future) (f : 'a parents -> 'a parents) =
  assert (is_initialized fut);
  match fut.status with
  | Uninitialized
  | Done _ ->
      ()
  | Ordinary r ->
      let parents = r.parents in
      let parents' = f parents in
      if parents' != parents then
        r.parents <- parents'
  | Proxy r ->
      let parents = r.parents in
      let parents' = f parents in
      if parents' != parents then
        r.parents <- parents'
  | Join r ->
      let parents = r.parents in
      let parents' = f parents in
      if parents' != parents then
        r.parents <- parents'
  | Earliest r ->
      let parents = r.parents in
      let parents' = f parents in
      if parents' != parents then
        r.parents <- parents'

(* [insert_edge edge parents] inserts the edge [edge] into the bag of
   active parent edges [parents]. It returns an updated bag. The edge
   [edge] must be isolated. [insert_edge edge] is meant to be used as
   an update function [f] in a call to [update_parents]. *)

let[@inline] insert_edge (edge : 'a edge) (parents : 'a parents) : 'a parents =
  (* [edge] must be isolated. *)
  assert (edge.prev == edge && edge.next == edge);
  match parents with
  | None ->
      Some edge
  | Some neighbor ->
      let prev = neighbor.prev in
      neighbor.prev <- edge;
      prev.next <- edge;
      edge.prev <- prev;
      edge.next <- neighbor;
      parents

(* [remove_edge edge parents] removes the edge [edge] from the bag of active
   parent edges [parents]. It returns an updated bag. The edge [edge] must
   be a member of the bag [parents]. [remove_edge edge] is meant to be used
   as an update function [f] in a call to [update_parents]. *)

let[@inline] remove_edge (edge : 'a edge) (parents : 'a parents) : 'a parents =
  let prev = edge.prev
  and next = edge.next in
  edge.prev <- edge;
  edge.next <- edge;
  if prev == edge then begin
    (* This edge is alone in the bag. *)
    assert (next == edge);
    assert (entry parents == edge);
    None
  end
  else begin
    (* This edge is not alone. Unlink it. *)
    prev.next <- next;
    next.prev <- prev;
    if entry parents == edge then Some prev else parents
  end

(* -------------------------------------------------------------------------- *)

(* Activation. *)

(* Activation begins when the client expresses interest in a future [fut]
   which, so far, was inactive. For example, perhaps the client invokes
   [wait fut]. *)

(* Activation is subtler than it seems. One might think that activation
   requires traversing the graph, starting at [fut], following inactive
   edges only, and activating every such edge along the way. However, this
   understanding is too naive, and can lead to activating futures that
   should not be activated. Indeed, recall that if a future F is inactive
   then an edge F → F' can lead to a future F' that is fulfilled already.
   In such a case, the future F should be updated, and (if F has more than
   one child) this can cause F to stop watching its other child F''. Thus
   F'' must not be activated. *)

(* To address this problem, we perform activation in two stages:

   1- The cleanup stage traverses the inactive area of the DAG and (on the
      way back up) updates the status of each future based on the statuses
      of its children. This can cause inactive edges to disappear.

   2- The activation stage traverses the inactive area of the DAG
      and (on the way down) activates every inactive edge along the way.

   In the cleanup stage, to avoid visiting a vertex more than once,
   we use the transient field [mark]. The mark [visited] is used to
   mark the vertices that have been visited during this traversal.

   In the activation stage, an edge is traversed only after its inactive
   parent becomes active. Therefore an edge is traversed at most once. *)

(* The cleanup stage. *)

let rec cleanup_future : 'a . mark -> 'a future -> unit =
  fun visited fut ->
  assert (is_initialized fut);
  (* An inactive parent can have an active child, so this future
     may be active. If it is active, ignore it. If it is inactive,
     and if it has not yet been visited, then mark it and visit it. *)
  if is_inactive fut && not (Mark.same fut.mark visited) then begin
    fut.mark <- visited;
    cleanup_unvisited_future visited fut
  end

and cleanup_unvisited_future : 'a . mark -> 'a future -> unit =
  fun visited fut ->
  assert (is_initialized fut);
  assert (is_inactive fut);
  if debug then info "Cleaning up future %d." fut.id;

  (* Examine [fut]'s status. In the cases of ordinary futures, proxy futures,
     and join futures, we call [cleanup_edge], which calls [cleanup_future]
     possibly followed with [notify]. This avoids code duplication. In the
     case of join futures, attempting to use [notify] would be awkward, as
     this function is designed to deal with a situation where at most one
     child is fulfilled. Thus, we write ad hoc code to handle this case. *)
  match fut.status with

  | Uninitialized
  | Done _ ->
      ()

  | Ordinary { thread; _ } ->
      (* If the child future has become fulfilled then [cleanup_edge]
         unblocks this thread. However, this thread is not active yet,
         as we are only in the first stage of the activation process;
         so the thread is not inserted into the queue. *)
      assert (thread_is_inactive thread);
      cleanup_optional_untyped_edge visited thread.awaits

  | Proxy { edge; _ } ->
      (* If the child future has become fulfilled then [cleanup_edge]
          fulfills this future. *)
      cleanup_edge visited edge

  | Join { edge; _ } ->
      (* If the child future has become fulfilled then [cleanup_edge]
         invokes [link] on this future, causing this future to either
         become fulfilled or become changed into a proxy future. *)
      cleanup_edge visited edge

  | Earliest { edge1; edge2; decisive1; decisive2; _ } ->
      (* We do not want to use two calls to [cleanup_edge] because
         the case where the two children are fulfilled would not be
         properly handled. So, we first clean up the two children,
         then update the status of the parent. *)
      let child1 = edge1.child in
      cleanup_future visited child1;
      let child2 = edge2.child in
      cleanup_future visited child2;
      match child1.status, child2.status with
      | Done { result = result1 }, Done { result = result2 } ->
          if decisive1 result1 then
            (* [edge2] is lost, and was inactive, so there is no need to
               call [deactivate_edge]. *)
            fulfill fut result1
          else
            (* No need to test whether [result2] is decisive. *)
            fulfill fut result2
      | Done { result = result1 }, _ ->
          if decisive1 result1 then
            fulfill fut result1
          else
            init_proxy_future fut edge2
      | _, Done { result = result2 } ->
          if decisive2 result2 then
            fulfill fut result2
          else
            init_proxy_future fut edge1
      | _, _ ->
          ()

and cleanup_edge : 'a . mark -> 'a edge -> unit =
  fun visited edge ->
  cleanup_future visited edge.child;
  (* If the child future has become fulfilled,
     then send a notification up this edge. *)
  match edge.child.status with
  | Done { result } ->
      notify edge result
  | _ ->
      ()

and cleanup_optional_untyped_edge visited edge =
  match edge with
  | None ->
      ()
  | Some (UE edge) ->
      cleanup_edge visited edge

and query : 'a . 'a future -> 'a reply =
  fun fut ->
  assert (is_initialized fut);
  (* If [fut] is fulfilled or active then cleanup is not necessary. *)
  match fut.status with
  | Uninitialized ->
      assert false
  | Done { result } ->
      Result result
  | Ordinary { parents; _ }
  | Proxy { parents; _ }
  | Join { parents; _ }
  | Earliest { parents; _ } ->
      if Option.is_some parents then
        unsafe_query fut
      else
        (* [fut] is not fulfilled, and is inactive. *)
        let visited = Mark.fresh() in
        cleanup_future visited fut;
        unsafe_query fut

(* The activation stage. *)

(* [activate_edge s edge] updates the DAG so as to reflect the fact that the
   source vertex of the edge [edge] has become newly active. This requires
   1- inserting [edge] into the active parent bag of the future [edge.child];
   2- testing whether [edge.child] becomes newly active, and if so,
      a- scheduling the thread in charge of fulfilling this future,
         if there is such a thread and
         if this thread is not waiting on any future;
      b- recursively activating this thread's outgoing edges,
         otherwise. *)

(* We expect the future [edge.child] to be unfulfilled. *)

and activate_edge : 'a . 'a edge -> unit =
  fun edge ->
  assert (not edge.active);
  edge.active <- true;
  (* Because [edge.parent] was inactive until now,
     this edge must be isolated. *)
  assert (edge.prev == edge && edge.next == edge);
  (* Activate this edge's child, a future. *)
  let fut = edge.child in
  (* We expect [fut] to be unfulfilled. *)
  assert (
    is_unfulfilled fut ||
    fail "About to activate edge %s -> %d, but child future is fulfilled already!"
      (show_edge_parent edge) fut.id
  );
  let was_active = is_active fut in
  (* Insert [edge] into [fut]'s active parent set. *)
  update_parents fut (insert_edge edge);
  assert (is_active fut);
  (* If [fut] was not active, then it has become active. *)
  if not was_active then
    match fut.status with
    | Uninitialized
    | Done _ ->
        assert false
    | Ordinary { thread; _ } ->
        begin match thread.awaits with
          | None ->
              (* The thread associated with [fut] is not waiting on a
                 future. Then, this thread must be scheduled. *)
              assert (thread_is_active thread);
              enqueue thread
          | Some (UE edge) ->
              (* The thread associated with [fut] is waiting on the future
                 [edge.child]. Then, this thread must not be scheduled; that
                 would be useless. Instead, this thread's outgoing edge must
                 be activated. *)
              activate_edge edge
        end
    | Proxy { edge; _ } ->
        activate_edge edge
    | Join { edge; _ } ->
        activate_edge edge
    | Earliest { edge1; edge2; _ } ->
        activate_edge edge1;
        activate_edge edge2

(* -------------------------------------------------------------------------- *)

(* Deactivation. *)

(* [deactivate_edge edge] updates the DAG so as to reflect the fact that the
   edge [edge] has become inactive; that is, the source vertex of this edge
   no longer watches the target vertex. This requires
   1- removing [edge] from the active parent bag of the future [edge.child];
   2- testing whether [edge.child] becomes inactive, and if so,
      recursively deactivating this thread's outgoing edges.

   When an ordinary future becomes inactive, its thread should ideally be
   removed from the queue, if it is currently in the queue (that is, if this
   thread is not currently waiting). This could be achieved by implementing
   the queue as a doubly-linked list of threads. For the moment, we prefer
   to just leave the thread in the queue. This implies that not every thread
   in the queue is active. In [dequeue], one must test whether the extracted
   thread is active. If it is inactive, it must be ignored. *)

(* Due to possible aliasing between the children of a binary future, it may
   be the case that [edge.child] is fulfilled already. *)

and deactivate_edge : 'a . 'a edge -> unit =
  fun edge ->
  if debug then
    info "Removing the edge %s -> %d."
      (show_edge_parent edge) edge.child.id;
  assert edge.active;
  edge.active <- false;
  (* Examine this edge's child, a future. *)
  let fut = edge.child in
  assert (is_initialized fut);
  (* Because [edge] was active, we expect [fut] to be active. *)
  assert (is_active fut);
  (* Remove [edge] from [fut]'s active parent set. *)
  update_parents fut (remove_edge edge);
  (* If [fut] has become inactive,
     then its outgoing edges must be deactivated. *)
  if not (is_active fut) then
    match fut.status with
    | Uninitialized
    | Done _ ->
        ()
    | Ordinary { thread; _ } ->
        begin match thread.awaits with
          | None ->
              (* Leave [thread] in the queue, even though it becomes inactive. *)
              if debug then
                info "Thread %d becomes inactive." (thread_id thread)
          | Some (UE edge) ->
              deactivate_edge edge
        end
    | Proxy { edge; _ } ->
        deactivate_edge edge
    | Join { edge; _ } ->
        deactivate_edge edge
    | Earliest { edge1; edge2; _ } ->
        deactivate_edge edge1;
        deactivate_edge edge2

(* -------------------------------------------------------------------------- *)

(* Notifications. *)

(* [notify edge result] sends a notification up along the edge [edge].
   The parent is notified that the child has produced the result [result]. *)

(* [notify] is called on two different occasions:
   - It can be invoked when [edge] is active,
     that is, when both the parent and child futures are active,
     and the future [edge.child] has just been fulfilled.
   - It can be invoked during the cleanup stage;
     then [edge] is inactive and is possibly (but not certainly)
     about to be activated.
     This mode of invocation is NOT used for earliest futures. *)

and notify : type a . a edge -> a -> unit =
  fun edge result ->
  if debug && edge.notify <> NRoot then
    info "Sending a notification up the %s edge %s -> %d"
      (if edge.active then "active" else "inactive")
      (show_edge_parent edge) edge.child.id;
  assert (is_fulfilled edge.child);
  match edge.notify with
  | NRoot ->
      ()
  | NAwaken (thread, k) ->
      awaken thread k result
  | NProxy parent ->
      assert (is_proxy parent);
      fulfill parent result
  | NJoin parent ->
      assert (is_join parent);
      link parent result
  | NEarliest parent ->
      assert edge.active;
      assert (is_active parent);
      assert (is_earliest parent);
      let other, decisive =
        match parent.status with
        | Earliest { edge1; edge2; decisive1; decisive2; _ } ->
            if edge == edge1 then edge2, decisive1
            else edge1, decisive2
        | _ ->
            assert false
      in
      assert (is_unfulfilled other.child);
      if decisive result then begin
        (* This child has returned a decisive result. We do not need to wait
           for the other child. Transmit the result to [parent] and deactivate
           the edge that leads from the parent to its other child. *)
        if debug then
          info "Future %d is fulfilled and stops watching future %d."
            parent.id other.child.id;
        fulfill parent result;
        deactivate_edge other
      end
      else
        (* This child has returned a non-decisive result. We need to wait for
           the other child. The parent future degenerates into a proxy future,
           watching just the other child. *)
        init_proxy_future parent other

(* [notify_parents parents result] iterates on the (possibly empty) bag of
   edges [parents]. Every parent vertex is notified that the result of the
   child vertex is [result]. *)

and notify_parents (parents : 'a edge option) (result : 'a) : unit =
  match parents with
  | None ->
      ()
  | Some edge ->
      (* Iteration on a circular doubly-linked list. *)
      let sentinel = edge in
      let rec loop edge =
        notify edge result;
        let next = edge.next in
        if next != sentinel then loop next
      in
      loop edge

(* [fulfill fut result] fulfills the future [fut] with the result [result]
   and notifies [fut]'s parents in the dependency graph. *)

(* [fut] must not be fulfilled already. *)

and fulfill : 'a . 'a future -> 'a -> unit =
  fun fut result ->
  assert (
    is_unfulfilled fut ||
    fail "About to fulfill future %d, but it is already fulfilled!" fut.id
  );
  if debug then
    info "Future %d is now fulfilled." fut.id;
  let parents = get_parents fut in
  fut.status <- Done { result };
  notify_parents parents result

(* [init_proxy_future fut edge] changes the existing future [fut],
   which has an existing outgoing edge [edge], into a proxy future
   with the same outgoing edge. *)

and[@inline] init_proxy_future : type a . a future -> a edge -> unit =
  fun fut edge ->
  assert (is_unfulfilled fut);
  assert (is_unfulfilled edge.child);
  if debug then
    info "Future %d becomes a proxy future, watching future %d."
      fut.id edge.child.id;
  let parents = get_parents fut in
  edge.notify <- NProxy fut;
  fut.status <- Proxy { parents; edge }

(* [link fut1 fut2] transforms [fut1] into a proxy for [fut2]. *)

(* If [fut2] is fulfilled already, then [fut1] immediately becomes
   fulfilled, with the same result. Otherwise, [fut1] becomes a proxy
   future, and an edge from [fut1] toward [fut2] is created. *)

(* We assume that [fut1] is active. Thus the new edge toward [fut2]
   is activated immediately. *)

(* The caller must hold the unique permission to fulfill [fut1].
   This permission is consumed. *)

and link : type a . a future -> a future -> unit =
  fun fut1 fut2 ->
  assert (is_unfulfilled fut1);
  assert (is_active fut1);
  match query fut2 with
  | Result result ->
      fulfill fut1 result
  | Future fut2 ->
      let edge = new_edge fut2 in
      init_proxy_future fut1 edge;
      activate_edge edge

(* -------------------------------------------------------------------------- *)

(* Handlers for the main three types of events: termination of a thread,
   wait, yield. [handle_termination], [handle_wait] and [handle_yield]
   form the three branches of our effect handler. They are later grouped
   in the function [handle]. *)

(* [handle_termination ()] handles the termination of the current thread. *)

and handle_termination () : unit =
  (* The current thread has terminated. There may remain some threads
     in the queue, whose results are not needed by this thread. *)
  let thread = s.current in
  if debug then
    info "Thread %d terminates." (thread_id thread);
  (* Run one of the remaining active threads. *)
  dequeue()

(* [block active thread fut k] blocks (suspends) the thread [thread],
   waiting on the future [fut]. The thread is meant to be awoken once
   [fut] terminates; once resumed, it applies the continuation [k] to
   the result produced by [fut]. *)

(* [active] determines whether the thread [thread] is currently active,
   that is, reachable from the root future. *)

(* The future [fut] must be the result of a call to [query]. Therefore
   it is clean, so one can safely call [activate_edge]. *)

and block : bool -> thread -> 'a future -> 'a cont -> unit =
fun active thread fut k ->
    assert (is_unfulfilled fut);
    assert (active = thread_is_active thread);
    (* Create a new edge from [thread] to [fut], so that,
       once [fut] is fulfilled, [thread] is awoken and
       applies [k] to the result of [fut]. *)
    let edge = new_edge fut in
    edge.notify <- NAwaken (thread, k);
    thread.awaits <- Some (UE edge);
    (* If [thread] is currently active, activate this edge.
       This adds one active parent to [fut]. *)
    if active then
      activate_edge edge
    (* [thread] is blocked but remains possibly active. *)

(* [awaken thread k result] awakens the thread [thread], in charge of
   running continuation [k] applied to result [result]. This thread must
   be currently blocked. It is not necessarily currently active. If it is
   active then it is inserted into the queue. Thus, we maintain the fact
   that every active and unblocked thread is in the queue. *)

and awaken : 'a . thread -> 'a cont -> 'a -> unit =
fun thread k result ->
  assert (is_blocked thread);
  thread.resumption <- resumption k result;
  thread.awaits <- None;
  if thread_is_active thread then
    enqueue thread

(* [handle_wait fut k] handles a request by the current thread to
   wait for the future [fut]. [k] is the continuation of the current
   thread. *)

and handle_wait : 'a . 'a future -> 'a cont -> unit
= fun fut k ->
    let thread = s.current in
    (* We expect the current thread to be active. *)
    assert (thread_is_active thread);
    if debug then
      info "Thread %d waits on future %d." (thread_id thread) fut.id;
    (* The current thread wants to wait on [fut]. *)
    match query fut with
    | Result result ->
        (* The result of [fut] is already available.
           Resume the current thread immediately. *)
        if debug then
          info "Thread %d continues." (thread_id thread);
        handle k result
    | Future fut ->
        assert (is_unfulfilled fut);
        (* The result is not available. Suspend the current thread. *)
        block true thread fut k;
        (* [thread] is not enqueued again. Run some other thread. *)
        dequeue()

(* [handle_yield k] handles a request by the current thread to yield.
   [k] is the continuation of the current thread. *)

and handle_yield (k : unit cont) : unit =
  (* The current thread requests a context switch. *)
  let thread = s.current in
  (* As an optimization, if the queue is currently empty, then no thread
     other than the current thread can run. In this case, there is no need
     to insert it into the queue; we would then immediately dequeue it. *)
  if Queue.is_empty s.queue then begin
    if debug then
      info "Thread %d offers to yield, but no other thread is ready."
        (thread_id thread);
    handle k ()
  end
  else begin
    if debug then
      info "Thread %d yields." (thread_id thread);
    thread.resumption <- unit_resumption k;
    (* The current thread remains active and ready. *)
    assert (thread_is_active thread);
    enqueue thread;
    (* Run some other thread first. *)
    dequeue()
  end

(* -------------------------------------------------------------------------- *)

(* [handle k x] runs the continuation [k] with argument [x] under our effect
   handler. This is boilerplate code; nothing interesting happens here. *)

and handle : type a . a cont -> a -> unit =
  fun k x ->
  continue_with k x {
    retc = handle_termination;
    exnc = raise;
    effc = fun (type reply) (eff : reply Effect.t) ->
      match eff with
      | Wait (fut : reply future) ->
          Some (fun (k : reply cont) -> handle_wait fut k)
      | Yield ->
          Some (fun (k : reply cont) -> handle_yield k)
      | _ ->
          None
  }

(* [resumption k x] builds the function [fun () -> handle k x] and
   converts it to the type [unit resumption], as it is wrapped in the
   effect handler and does not perform effects. *)

and resumption : 'a cont -> 'a -> unit resumption =
  fun k x ->
  let resume () = handle k x in
  Resumption resume

(* [unit_resumption k] is equivalent to [resumption k ()]
   but is more efficient (it builds a smaller closure). *)

and unit_resumption : unit cont -> unit resumption =
  fun k ->
  let resume () = handle k () in
  Resumption resume

(* -------------------------------------------------------------------------- *)

(* If [Deadlock] is raised, then the main thread has not finished. Yet, no
   thread is able to make progress; every thread is blocked. *)

(* As long as the dependency graph remains acyclic, a deadlock cannot
   happen. The dependency graph is normally acyclic, but could become
   cyclic if the client uses mutable state in a strange way. *)

exception Deadlock

(* -------------------------------------------------------------------------- *)

(* When creating a new future [fut] and spawning a new thread to run a task
   [task], we face two choices, each of which has two branches:

   1- Should the new thread fulfill [fut] with the result of [task],
      or make [fut] a proxy for the result of [task]?
        (The second branch assumes that this result is itself a future.)

   2- Should the new thread be initially ready to run,
      or should it wait for some other future?

   These two two-way choices give rise to four variants, namely
   [spawn], [spawn_wait], [map], and [bind]. *)

(* [spawn task] creates a new future [fut] and a new thread. This thread
   runs the task [task] and fulfills [fut] with its result. The new thread
   is not blocked, but is not scheduled now. It becomes active only once
   some thread waits on the future [fut]. *)

let[@inline] spawn (task : 'a task) : 'a future =
  new_ordinary_future @@ fun fut ->
  (* Run [task] and fulfill [fut] with its result. *)
  let child () = fulfill fut (task()) in
  unit_resumption (fiber child)

(* [spawn_wait task] creates a new thread in charge of running [task] and
   waiting on its result, which is expected to be a future. Once [task] has
   terminated, the future [fut] is transformed into a proxy for the future
   returned by [task]. *)

let[@inline] spawn_wait (task : 'a future task) : 'a future =
  new_ordinary_future @@ fun fut ->
  (* Run [task] and change [fut] into a proxy for its result. *)
  let child () = link fut (task()) in
  unit_resumption (fiber child)

(* [map f fut1] creates a new thread in charge of
   1- waiting for the future [fut1],
      then, once [fut1] produces a result [result],
   2- producing the result [f result]. *)

(* If [fut1] is fulfilled already then a simple use of [spawn] suffices.
   Otherwise the new thread is created in a blocked state, waiting for
   [fut1]. *)

let map (f : 'a -> 'b) (fut1 : 'a future) : 'b future =
  match query fut1 with
  | Result result ->
      spawn (fun () -> f result)
  | Future fut1 ->
      let fut, thread = new_ordinary_future_and_thread @@ fun _fut -> dummy_resumption in
      (* Block the new thread on [fut1]. Once the thread awakens,
         run [f] and fulfill [fut] with its result. *)
      let resume result = fulfill fut (f result) in
      block false thread fut1 (fiber resume);
      fut

(* [bind fut1 task] creates a new thread in charge of
   1- waiting for the future [fut1],
      then, once [fut1] produces a result [result],
   2- run [task result] and wait on its result. *)

(* If [fut1] is fulfilled already then a simple use of [spawn_wait]
   suffices. Otherwise the new thread is created in a blocked state,
   waiting for [fut1]. *)

let bind (fut1 : 'a future) (task : 'a -> 'b future) : 'b future =
  match query fut1 with
  | Result result ->
      spawn_wait (fun () -> task result)
  | Future fut1 ->
      let fut, thread = new_ordinary_future_and_thread @@ fun _fut -> dummy_resumption in
      (* Block the new thread on [fut1]. Once the thread awakens,
         run [task] and change [fut] into a proxy for its result. *)
      let resume result = link fut (task result) in
      block false thread fut1 (fiber resume);
      fut

(* -------------------------------------------------------------------------- *)

(* The toplevel functions, [run_fut] and [run]. *)

(* [run_fut] (re-)initializes the scheduler's state, activates the future
   [fut], runs the scheduler until it terminates (or a deadlock occurs),
   and extracts the result of the future [fut]. *)

(* [fut] must be clean; that is, either freshly created by [spawn], or
   the result of a call to [query]. *)

let run_fut (fut : 'a future) : 'a =
  (* Re-initialize the scheduler's global state. *)
  init @@ fun () ->
  (* We wish to treat [fut] as the root future. *)
  (* Create an edge whose child is [fut]. *)
  let edge = new_edge fut in
  edge.notify <- NRoot;
  (* Activate this edge. This activates the root future
     and schedules the main thread for execution. *)
  activate_edge edge;
  (* Launch the scheduler. *)
  dequeue();
  (* [fut] is now fulfilled, unless deadlock has occurred. *)
  (* Extract the result. *)
  assert (is_fulfilled fut || is_active fut);
  match query fut with
  | Result result ->
      result
  | Future _ ->
      raise Deadlock

let[@inline] run (task : 'a task) : 'a =
  (* Create a future for the task [task] and run it. *)
  run_fut (spawn task)

let run_fut fut =
  match query fut with
  | Result result ->
      result
  | Future fut ->
      run_fut fut

(* -------------------------------------------------------------------------- *)

(* Monadic combinators. *)

let[@inline] return (result : 'a) : 'a future =
  let fut = new_future "fulfilled" in
  fut.status <- Done { result };
  fut

(* A simple implementation of [map] using [spawn] and [wait]. *)

let _map (f : 'a -> 'b) (fut : 'a future) : 'b future =
  spawn @@ fun () ->
  wait fut
  |> f

(* A simple implementation of [map] using [bind]. This implementation is
   preferable to the previous one, as the new thread is created directly in
   the blocked state. *)

let _map (f : 'a -> 'b) (fut : 'a future) : 'b future =
  bind fut @@ fun x ->
  return (f x)

(* The type of [join] is an instance of the type of [wait]. Yet [wait] is
   not a correct implementation of [join]: it would be too eager. Indeed,
   we expect [join] to create a new future and to return immediately; no
   computation should take place until the result of the new future is
   demanded. *)

(* A simple implementation of [join] using [map] and [wait]. *)

let _join (fut : 'a future future) : 'a future =
  map wait fut

(* A simple implementation of [join] using [bind]. *)

let _join (fut : 'a future future) : 'a future =
  bind fut (fun x -> x)

(* A more complex implementation of [join]. *)

(* This implementation does not spawn a new thread, so it should be more
   efficient than the above implementations. First, we create a dependency
   edge from the new future [join] to the future [fut]. Then, once [fut]
   produces a result [result], which itself is a future, we change [join]
   into a proxy future for [result]. *)

let join (fut : 'a future future) : 'a future =
  match query fut with
  | Result result ->
      result
  | Future fut ->
      (* Create a fresh unary future [join], watching [fut]. *)
      let join = new_future "join" in
      let edge = new_edge fut in
      edge.notify <- NJoin join;
      init_join_future join edge;
      join

(* A simple implementation of [bind] using [map] and [join]. *)

let _bind (fut : 'a future) (f : 'a -> 'b future) : 'b future =
  map f fut
  |> join

(* A simple implementation of [bind] using [spawn] and [wait]. *)

(* In this code, it is clear that the new thread begins its life by waiting
   on [fut], and ends its life by waiting on the result of [f]. Therefore,
   instead of this naïve implementation, it seems preferable to create the
   new thread directly in a suspended state, waiting for [fut], and to let
   it end its life without waiting, by instead creating a proxy link from
   the result of [f] to the future that this thread is expected to fulfill. *)

let _bind (fut : 'a future) (f : 'a -> 'b future) : 'b future =
  spawn @@ fun () ->
  wait fut
  |> f
  |> wait

(* -------------------------------------------------------------------------- *)

(* [earliest_decisive] *)

(* A race between two distinct, unfulfilled futures. *)

let raw_earliest_decisive decisive1 decisive2 fut1 fut2 =
  assert (is_unfulfilled fut1);
  assert (is_unfulfilled fut2);
  assert (fut1 != fut2);
  let fut = new_future "earliest_decisive" in
  let edge1 = new_edge fut1
  and edge2 = new_edge fut2 in
  if debug then
    info "Future %d watches futures %d and %d."
      fut.id fut1.id fut2.id;
  edge1.notify <- NEarliest fut;
  edge2.notify <- NEarliest fut;
  init_earliest_future fut edge1 edge2 decisive1 decisive2;
  fut

(* A race between two tasks. *)

let[@inline] earliest_decisive decisive1 decisive2 task1 task2 =
  raw_earliest_decisive decisive1 decisive2 (spawn task1) (spawn task2)
  |> wait

(* A race between two arbitrary futures. *)

let earliest_decisive_fut decisive1 decisive2 fut1 fut2 =
  match query fut1, query fut2 with
  | Result result1, _ ->
      if decisive1 result1 then fut1 else fut2
  | _, Result result2 ->
      if decisive2 result2 then fut2 else fut1
  | Future fut1, Future fut2 ->
      if fut1 == fut2 then fut1 else
      raw_earliest_decisive decisive1 decisive2 fut1 fut2

(* -------------------------------------------------------------------------- *)

(* [earliest] *)

let always _ =
  true

let[@inline] earliest task1 task2 =
  earliest_decisive always always task1 task2

let[@inline] earliest_fut fut1 fut2 =
  earliest_decisive_fut always always fut1 fut2

(* -------------------------------------------------------------------------- *)

(* [conjunction]. *)

let is_false b =
  not b

let[@inline] conjunction task1 task2 =
  earliest_decisive is_false is_false task1 task2

let[@inline] conjunction_fut fut1 fut2 =
  earliest_decisive_fut is_false is_false fut1 fut2

(* -------------------------------------------------------------------------- *)

(* [disjunction] *)

let is_true b =
  b

let[@inline] disjunction task1 task2 =
  earliest_decisive is_true is_true task1 task2

let[@inline] disjunction_fut fut1 fut2 =
  earliest_decisive_fut is_true is_true fut1 fut2

(* -------------------------------------------------------------------------- *)

end (* Make *)
