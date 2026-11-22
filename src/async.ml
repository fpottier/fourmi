open Printf
open Effect
open Effect.Shallow

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

(* An observer of type ['a observer] expects a value of type ['a]. *)

type 'a observer =
  'a -> unit

(* A shallow continuation is not wrapped in an effect handler.
   It is executed by our effect handler, [handle]. *)

type 'a cont =
  ('a, unit) continuation

(* -------------------------------------------------------------------------- *)

(* We work with two main kinds of objects, namely futures and threads.

   A future is a placeholder for a result that is perhaps not yet available,
   but will become available in the future, once it has been computed. It
   can be viewed roughly as a reference that contains either nothing yet or
   a result.

   A thread is a computation whose ultimate aim is to fulfill one future. *)

(* The main thread is created by [run]. Every other thread is created by
   [spawn]. In either case, when a thread is created, a future is created at
   the same time, and this thread is in charge of fulfilling this future.

   A future created by [run] or [spawn] is an ordinary future.

   The future created by [run] is the root future. The main thread is in
   charge of fulfilling this future. It is an ordinary future. *)

(* A proxy future or a binary future does not have a corresponding thread.
   A proxy future watches one future and adopts its result (unmodified).
   A binary future watches two futures and computes its own result based
   on their results. Possibly one result is enough for it to produce
   a result. If it is not enough, then a binary future changes itself into
   a proxy future. *)

(* Futures and threads form a dependency graph, whose edges evolve over time:
   1- An ordinary future depends on the thread that will fulfill this future.
   2- A thread that is currently waiting for a future to be fulfilled
      currently depends on this future.
   3- A proxy future depends on one other future.
   4- A binary future depends on two other futures. *)

(* The dependency graph is acyclic: it is a DAG. If the client uses mutable
   state in a strange way, then the dependency graph can become cyclic, but
   that would be a mistake on the client's part. *)

(* In the dependency graph, a thread has exactly one parent and at most one
   child. In order to simplify our view of the graph, we do not view threads
   as vertices in the dependency graph; only futures are vertices.
   Therefore, items 1- and 2- can be summed up as follows:
   1- If an ordinary future F is meant to be fulfilled by thread T,
      and if thread T is currently waiting on future F',
      then F currently depends on F'. *)

(* A future is currently active if and only if it is currently reachable from
   the root future via a path in the dependency graph. *)

(* A thread is said to be ready if it is either currently running or present
   in the scheduler's queue. A thread is said to be suspended if it is not
   ready, that is, neither running nor present in the queue. *)

(* Suppose that an ordinary future F is meant to be fulfilled by thread T.
   Then T is ready if and only if T awaits nothing **and F is active**.

   That is, thread T is allowed to run only if its result may (transitively)
   be needed by the root future. When a thread becomes unreachable from the
   root future, it is suspended. Therefore, we avoid wasting work computing
   results that are definitely not needed. A suspended thread is not thrown
   away; it is kept at hand, and is scheduled again when it becomes reachable
   again. *)

(* Every future F' stores the number of its active parents, that is,
   the number of futures F such that F depends on F' and F is active.

   A future is active if and only if the number of its active parents
   is nonzero. *)

(* When a future is fulfilled, its active parents (which await its result)
   must be notified. Therefore, every future must maintain a bag of edges
   that point up towards its active parents.

   The inactive parents must not appear in this bag, because 1- we do not
   wish to waste time notifying an inactive parent, and more importantly,
   2- we wish to let the garbage collector reclaim an inactive parent that
   has become unreachable.

   Therefore, when a parent becomes inactive, it must be removed from its
   children's bags of active parents.

   We set things up as follows. Between an active parent and a child, there
   is an edge object. The parent and child point to the edge, which points
   back to the parent and child. The child's bag of active parents is in
   fact a circular doubly-linked list of edges, so an edge can be added or
   removed in constant time. *)

type thread = {

  mutable resumption : unit resumption;
    (**The resumption that this thread intends to execute.

       This field is updated when the thread is suspended by [wait] or
       [yield]. *)

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

}

and 'a edge = {

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

  mutable notify     : 'a observer;
    (**The action that must be taken by this parent once the child future
       has been fulfilled. This action function must not have effects.
       This field is declared mutable to facilitate initialization. *)

  (* We could keep a pointer to this edge's parent future, which is the
     source vertex of this edge, and which awaits the result of the future
     [child]. At this time, this is not needed. The address of the parent
     future is usually known to the function [notify]. In other words,
     [notify] can be viewed as an implicit parent pointer. *)

}

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
      (**A proxy future, whose result has not yet been computed.
         A proxy future copies the result of its child,
         without transforming it; that is, the function [edge.notify]
         fulfills the proxy future with the result of the child future.  *)

  | Unary of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      edge            : untyped_edge;
        (**A downward edge to the future that this future watches. *)

    }
      (**A unary future, whose result has not yet been computed.
         A unary future transforms the result of its child.  *)

  | Binary of {

      mutable parents : 'a parents;
        (**A possibly empty bag of this future's active incoming edges. *)

      edge1 : untyped_edge;
      edge2 : untyped_edge;
        (**Downward edges toward the two futures that this future watches. *)

    }
      (**A binary future, none of whose children has been fulfilled.
         A binary future watches two futures. *)

(**A bag of edges is a possibly empty doubly-linked list of edges. *)
and 'a parents =
  'a edge option

(* -------------------------------------------------------------------------- *)

(* Dummy resumption; dummy future; dummy thread. *)

(* These are needed to allow initialization in several steps. *)

let dummy_resumption : 'a resumption =
  Resumption (fun () -> assert false)

let dummy_future : 'a future =
  let id = -1
  and status = Uninitialized in
  { id; status }

let dummy_thread : thread =
  let resumption = dummy_resumption
  and fulfills = UF dummy_future
  and awaits = None in
  { resumption; fulfills; awaits }

(* -------------------------------------------------------------------------- *)

(* Debugging support. *)

let info format =
  ksprintf (fun msg -> eprintf "[scheduler] %s\n%!" msg) format

let[@inline] thread_id thread =
  match thread.fulfills with
  | UF fut ->
      fut.id

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
    (**A queue of threads that are active (reachable from the root future)
       and ready to be executed (not currently awaiting a future).

       Quite surprisingly, extracting ANY resumption out of the queue and
       running this resumption until it terminates effectively runs ALL
       resumptions until the main resumption terminates (or until a deadlock
       is reached). *)

}

(* -------------------------------------------------------------------------- *)

(* The effects that we use internally. *)

type _ Effect.t +=
| State : state Effect.t
| Wait  : 'a future -> 'a Effect.t
| Yield : unit Effect.t

(* A private function. *)

let[@inline] get_state () : state =
  perform State

(* Public combinators. *)

let[@inline] wait fut =
  perform (Wait fut)

let[@inline] yield () =
  perform Yield

(* -------------------------------------------------------------------------- *)

(* If the result of the future [fut] is already available
   then [query fut] returns this result.
   Otherwise [query fut] returns [fut] or an equivalent future,
   obtained from [fut] by following a chain of [Proxy] links. *)

(* Once a [Proxy] link has been followed, we cannot reach a fulfilled
   future. Indeed, once a future is fulfilled, the proxy futures that
   are watching it are notified and become fulfilled, too. The
   auxiliary function [query1] verifies this claim. *)

type 'a reply =
  | Result of 'a
  | Future of 'a future

let rec query1  (fut : 'a future) : 'a reply =
  match fut.status with
  | Uninitialized ->
      assert false
  | Done _ ->
      (* Cannot reach a fulfilled future after following a link. *)
      assert false
  | Ordinary _
  | Unary _
  | Binary _ ->
      Future fut
  | Proxy { edge; _ } ->
      query1 edge.child

let query (fut : 'a future) : 'a reply =
  match fut.status with
  | Uninitialized ->
      assert false
  | Done { result } ->
      Result result
  | Ordinary _
  | Unary _
  | Binary _ ->
      Future fut
  | Proxy { edge; _ } ->
      query1 edge.child

(* [is_fulfilled fut] tests whether [fut] has already received a value. *)

(* We are interested in [fut] itself. If [fut] is a proxy for some other
   future [fut'], then we do not follow the link. Indeed, once [fut']
   becomes fulfilled, we do not wish to consider that [fut] implicitly
   becomes fulfilled at the same time. Instead, we expect [fut'] to
   explicitly notify [fut], which then becomes fulfilled and no longer
   points to [fut']. *)

let[@inline] is_fulfilled (fut : 'a future) : bool =
  match fut.status with
  | Uninitialized ->
      assert false
  | Done _ ->
      true
  | Ordinary _
  | Unary _
  | Binary _
  | Proxy _ ->
      false

(* [is_active fut] determines whether the future [fut] is active. This is
   done by testing whether its list of active parents is nonempty. *)

let is_active (fut : 'a future) : bool =
  match fut.status with
  | Uninitialized ->
      assert false
  | Done _ ->
      false
  | Ordinary { parents; _ }
  | Proxy { parents; _ }
  | Unary { parents; _ }
  | Binary { parents; _ }
      -> Option.is_some parents

(* [thread_is_active thread] determines whether the thread [thread] is
   active. This is done by testing whether the future [thread.fulfills]
   is active. *)

let[@inline] thread_is_active thread =
  match thread.fulfills with
  | UF fut ->
      is_active fut

(* -------------------------------------------------------------------------- *)

(* Creating new threads, edges, and futures. *)

(* [new_thread fut resumption] creates a new thread in charge of fulfilling
   the future [fut] by running the resumption [resumption]. *)

let new_thread (fut : 'a future) (resumption : unit resumption) : thread =
  let fulfills = UF fut
  and awaits = None in
  let thread = { resumption; fulfills; awaits } in
  info "Creating thread %d." (thread_id thread);
  thread

(* [new_edge child] creates a new edge whose target vertex is [child]. The
   field [edge.notify] is not initialized, and must be initialized before
   this edge is used. This two-step initialization process is necessary
   because, when creating a binary future, we need to create two edges
   whose [notify] functions point to the other edge. *)

let dummy_notify _ =
  ()

let new_edge child =
  assert (not (is_fulfilled child));
  let notify = dummy_notify in
  let rec edge = { child; prev = edge; next = edge; notify } in
  edge

(* [new_future kind] creates a new uninitialized future [fut]. The field
   [fut.status] is not initialized, and must be initialized before this
   future is used. This two-step initialization process is necessary
   because the future and its status point to each other. The string
   [kind] is used in a debugging message. *)

let next_future_id =
  ref 0

let new_future (kind : string) : 'a future =
  let id = !next_future_id in
  next_future_id := id + 1;
  let status = Uninitialized in
  info "Creating %s future %d." kind id;
  { id; status }

let[@inline] init_ordinary_future (fut : 'a future) (thread : thread) =
  let parents = None in
  fut.status <- Ordinary { parents; thread }

let[@inline] init_unary_future fut edge =
  let parents = None in
  let edge = UE edge in
  fut.status <- Unary { parents; edge }

let[@inline] init_binary_future fut edge1 edge2 =
  let parents = None in
  let edge1 = UE edge1
  and edge2 = UE edge2 in
  fut.status <- Binary { parents; edge1; edge2 }

(* [new_ordinary_future_and_thread s resumption] creates a new ordinary
   future [fut] together with a new thread, initializes this thread's
   resumption with the result of [resumption fut], and displays debugging
   messages. It returns the new future [fut] and the thread [thread]. *)

let[@inline] new_ordinary_future_and_thread
  (s : state)
  (resumption : 'a future -> unit resumption)
: 'a future * thread =
  (* Create a new uninitialized future. *)
  let fut = new_future "ordinary" in
  (* Create a new thread that runs the resumption [resumption s fut]. *)
  let thread = new_thread fut (resumption fut) in
  (* Complete the initialization of [fut]. *)
  init_ordinary_future fut thread;
  (* Done. *)
  info "Thread %d spawns new thread %d." (thread_id s.current) fut.id;
  fut, thread

let[@inline] new_ordinary_future s resumption : 'a future =
  let fut, _thread = new_ordinary_future_and_thread s resumption in
  fut

(* Creating a new scheduler state. *)

let new_state () : state =
  let current = dummy_thread
  and queue = Queue.create() in
  { current; queue }

(* -------------------------------------------------------------------------- *)

(* Operations on the scheduler's queue. *)

(* [enqueue s thread] inserts the thread [thread] into the queue. *)

let[@inline] enqueue (s : state) (thread : thread) : unit =
  (* We expect this thread to be active. *)
  assert (thread_is_active thread);
  (* We expect this thread to be unblocked (not waiting). *)
  assert (thread.awaits = None);
  info "Enqueuing thread %d." (thread_id thread);
  Queue.add thread s.queue

(* [dequeue s] extracts a thread from the queue, if there is one, and
   executes its resumption. As noted above, this runs the scheduler until
   the main thread terminates or until a deadlock is reached. *)

(* [dequeue] potentially overwrites [s.current]. *)

let rec dequeue (s : state) : unit =
  match Queue.take s.queue with
  | exception Queue.Empty ->
      ()
  | thread ->
      (* Test whether this thread is active. (We allow the queue to contain
         inactive threads. This obviates the need to need to remove a thread
         from the queue when it becomes inactive.) *)
      if not (thread_is_active thread) then
        dequeue s
      else begin
        (* We expect this thread not to be waiting on a future. *)
        assert (thread.awaits = None);
        (* Make this thread the current thread. *)
        s.current <- thread;
        (* Read the thread's resumption, then overwrite this field, so as to
           avoid a memory leak. Indeed, once the resumption runs, there is
           no need to store it any more. Furthermore, this guarantees that
           we do not mistakenly run this resumption a second time. *)
        let resumption = thread.resumption in
        thread.resumption <- dummy_resumption;
        info "Now running thread %d." (thread_id thread);
        execute resumption
      end

(* -------------------------------------------------------------------------- *)

(* Operations on bags (doubly-linked lists) of parent edges. *)

(* [handle parents] returns the entry point of the doubly-linked list
   [parents], under the assumption that this list is nonempty. *)

let[@inline] handle (parents : 'a parents) : 'a edge =
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
  match fut.status with
  | Uninitialized ->
      assert false
  | Done _ ->
      None
  | Ordinary r ->
      r.parents
  | Proxy r ->
      r.parents
  | Unary r ->
      r.parents
  | Binary r ->
      r.parents

let[@inline] update_parents (fut : 'a future) (f : 'a parents -> 'a parents) =
  match fut.status with
  | Uninitialized ->
      assert false
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
  | Unary r ->
      let parents = r.parents in
      let parents' = f parents in
      if parents' != parents then
        r.parents <- parents'
  | Binary r ->
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
    assert (handle parents == edge);
    None
  end
  else begin
    (* This edge is not alone. Unlink it. *)
    let next = edge.next in
    prev.next <- next;
    next.prev <- prev;
    if handle parents == edge then Some prev else parents
  end

(* -------------------------------------------------------------------------- *)

(* Operations on edges. *)

(* [activate_edge s edge] updates the DAG so as to reflect the fact that the
   source vertex of the edge [edge] has become newly active. This requires
   1- inserting [edge] into the active parent bag of the future [edge.child];
   2- testing whether [edge.child] becomes newly active, and if so,
      a- scheduling the thread in charge of fulfilling this future,
         if there is such a thread and
         if this thread is not waiting on any future;
      b- recursively activating this thread's outgoing edges,
         otherwise. *)

(* [activate_edge] performs a DAG traversal. An edge is traversed only when
   the number of active parents of its source vertex changes from 0 to 1.
   Therefore an edge is traversed at most once. *)

(* We expect the future [edge.child] to be unfulfilled, i.e., not [Done].
   Indeed, once a future is fulfilled, its parents are notified and the
   edges that point down to this future disappear. *)

let rec activate_edge : 'a . state -> 'a edge -> unit =
fun s edge ->
  (* Because [edge.parent] was inactive until now,
     this edge must be isolated. *)
  assert (edge.prev == edge && edge.next == edge);
  (* Examine this edge's child, a future. *)
  let fut = edge.child in
  (* We expect [fut] to be unfulfilled. *)
  assert (not (is_fulfilled fut));
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
            enqueue s thread
        | Some (UE edge) ->
            (* The thread associated with [fut] is waiting on the future
               [edge.child]. Then, this thread must not be scheduled; that
               would be useless. Instead, this thread's outgoing edge must
               be activated. *)
            activate_edge s edge
        end
  | Proxy { edge; _ } ->
      activate_edge s edge
  | Unary { edge; _ } ->
      activate_untyped_edge s edge
  | Binary { edge1; edge2; _ } ->
      activate_untyped_edge s edge1;
      activate_untyped_edge s edge2

and activate_untyped_edge s edge =
  match edge with
  | UE edge ->
      activate_edge s edge

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

let rec deactivate_edge : 'a . 'a edge -> unit =
fun edge ->
  (* Examine this edge's child, a future. *)
  let fut = edge.child in
  (* Because [edge] was active, we expect [fut] to be active. *)
  assert (is_active fut);
  (* Remove [edge] from [fut]'s active parent set. *)
  update_parents fut (remove_edge edge);
  (* If [fut] has become inactive,
     then its outgoing edges must be deactivated. *)
  if not (is_active fut) then
    match fut.status with
    | Uninitialized ->
        assert false
    | Done _ ->
        ()
    | Ordinary { thread; _ } ->
        begin match thread.awaits with
        | None ->
            (* Leave [thread] in the queue, even though it becomes inactive. *)
            info "Thread %d becomes inactive." (thread_id thread)
        | Some (UE edge) ->
            deactivate_edge edge
        end
  | Proxy { edge; _ } ->
      deactivate_edge edge
  | Unary { edge; _ } ->
      deactivate_untyped_edge edge
  | Binary { edge1; edge2; _ } ->
      deactivate_untyped_edge edge1;
      deactivate_untyped_edge edge2

and deactivate_untyped_edge edge =
  match edge with
  | UE edge ->
      deactivate_edge edge

(* [notify_parents parents result] iterates on the (possibly empty) bag of
   edges [parents]. Every parent vertex is notified that the result of the
   child vertex is [result]. *)

let notify_parents (parents : 'a edge option) (result : 'a) =
  match parents with
  | None ->
      ()
  | Some edge ->
      (* Iteration on a circular doubly-linked list. *)
      let sentinel = edge in
      let rec loop edge =
        edge.notify result;
        let next = edge.next in
        if next != sentinel then loop next
      in
      loop edge

(* [fulfill fut result] fulfills the future [fut] with the result [result]
   and notifies [fut]'s parents in the dependency graph. *)

(* [fut] must not be fulfilled already. *)

let[@inline] fulfill (fut : 'a future) (result : 'a) : unit =
  assert (not (is_fulfilled fut));
  let parents = get_parents fut in
  fut.status <- Done { result };
  notify_parents parents result

(* [init_proxy_future fut edge] changes the existing future [fut],
   which has an existing outgoing edge [edge], into a proxy future
   with the same outgoing edge. *)

let[@inline] init_proxy_future (fut : 'a future) (edge : 'a edge) =
  assert (not (is_fulfilled fut));
  assert (not (is_fulfilled edge.child));
  info "Future %d becomes a proxy future." fut.id;
  let parents = get_parents fut in
  edge.notify <- fulfill fut;
  fut.status <- Proxy { parents; edge }

(* [link s fut1 fut2] transforms [fut1] into a proxy for [fut2]. *)

(* If [fut2] is fulfilled already, then [fut1] immediately becomes
   fulfilled, with the same result. Otherwise, [fut1] becomes a proxy
   future, and an edge from [fut1] toward [fut2] is created. *)

(* We assume that [fut1] is active. Thus the new edge toward [fut2]
   is activated immediately. *)

let link (s : state) (fut1 : 'a future) (fut2 : 'a future) =
  assert (not (is_fulfilled fut1));
  assert (is_active fut1);
  match query fut2 with
  | Result result ->
      fulfill fut1 result
  | Future fut2 ->
      let edge = new_edge fut2 in
      init_proxy_future fut1 edge;
      activate_edge s edge

(* -------------------------------------------------------------------------- *)

(* Handlers for the main three types of events: termination of a thread,
   wait, yield. *)

(* In the following functions, [s] is the scheduler's state.
   [handle s k x] applies the continuation [k] to an argument [x]
   under our effect handler. *)

(* [handle_termination s ()] handles the termination of the current thread. *)

let handle_termination s () : unit =
  (* The current thread has terminated. There may remain some threads
     in the queue, whose results are not needed by this thread. *)
  let thread = s.current in
  info "Thread %d terminates." (thread_id thread);
  (* Run one of the remaining active threads. *)
  dequeue s

(* [block s active thread fut k] blocks (suspends) the thread [thread],
   waiting on the future [fut]. The thread is meant to be awoken once
   [fut] terminates; once resumed, it applies the continuation [k] to
   the result produced by [fut]. *)

(* [active] determines whether the thread [thread] is currently active,
   that is, reachable from the root future. *)

let rec block : state -> bool -> thread -> 'a future -> 'a cont -> unit
= fun s active thread fut k ->
  assert (not (is_fulfilled fut));
  assert (active = thread_is_active thread);
  (* Create a new edge from [thread] to [fut], so that,
     once [fut] is fulfilled, [thread] is awoken and
     applies [k] to the result of [fut]. *)
  let edge = new_edge fut in
  edge.notify <- awaken s thread k;
  thread.awaits <- Some (UE edge);
  (* If [thread] is currently active, activate this edge.
     This adds one active parent to [fut]. *)
  if active then
    activate_edge s edge
  (* [thread] is suspended but remains active.
     Active means reachable from the root future. *)

(* [awaken s thread k result] inserts the thread [thread] into the queue,
   in charge of running continuation [k] applied to result [result]. *)

(* The partial application [awaken s thread k] is typically used as a
   [notify] function that is installed on an edge. *)

and awaken : 'a . state -> thread -> 'a cont -> 'a -> unit =
fun s thread k result ->
  assert (thread.awaits <> None);
  thread.resumption <- resumption s k result;
  thread.awaits <- None;
  enqueue s thread

(* [handle_wait s fut k] handles a request by the current thread to
   wait for the future [fut]. [k] is the continuation of the current
   thread. *)

and handle_wait : 'a . state -> 'a future -> 'a cont -> unit
= fun s fut k ->
  let thread = s.current in
  (* We expect the current thread to be active. *)
  assert (thread_is_active thread);
  info "Thread %d waits on future %d." (thread_id thread) fut.id;
  (* The current thread wants to wait on [fut]. *)
  match query fut with
  | Result result ->
      (* The result of [fut] is already available.
         Resume the current thread immediately. *)
      info "Thread %d continues." (thread_id thread);
      handle s k result
  | Future fut ->
      (* The result is not available. Suspend the current thread. *)
      block s true thread fut k;
      (* [thread] is not enqueued again. Run some other thread. *)
      dequeue s

(* [handle_yield s k] handles a request by the current thread to yield.
   [k] is the continuation of the current thread. *)

and handle_yield (s : state) (k : unit cont) : unit =
  (* The current thread requests a context switch. *)
  let thread = s.current in
  (* As an optimization, if the queue is currently empty, then no thread
     other than the current thread can run. In this case, there is no need
     to insert it into the queue; we would then immediately dequeue it. *)
  if Queue.is_empty s.queue then begin
    info "Thread %d offers to yield, but no other thread is ready."
      (thread_id thread);
    handle s k ()
  end
  else begin
    info "Thread %d yields." (thread_id thread);
    thread.resumption <- unit_resumption s k;
    (* The current thread remains active and ready. *)
    enqueue s thread;
    (* Run some other thread first. *)
    dequeue s
  end

(* -------------------------------------------------------------------------- *)

(* [handle s k x] runs the continuation [k] with argument [x] under our effect
   handler. This is boilerplate code; nothing interesting happens here. *)

and handle : type a . state -> a cont -> a -> unit =
fun s k x ->
  continue_with k x {
    retc = handle_termination s;
    exnc = raise;
    effc = fun (type reply) (eff : reply Effect.t) ->
      match eff with
      | State ->
          Some (fun (k : reply cont) -> handle s k s)
      | Wait (fut : reply future) ->
          Some (fun (k : reply cont) -> handle_wait s fut k)
      | Yield ->
          Some (fun (k : reply cont) -> handle_yield s k)
      | _ ->
          None
  }

(* [resumption s k x] builds the function [fun () -> handle s k x] and
   converts it to the type [unit resumption], as it is wrapped in the
   effect handler and does not perform effects. *)

and resumption : state -> 'a cont -> 'a -> unit resumption =
fun s k x ->
  let resume () = handle s k x in
  Resumption resume

(* [unit_resumption s k] is equivalent to [resumption s k ()]
   but is more efficient (it builds a smaller closure). *)

and unit_resumption : state -> unit cont -> unit resumption =
fun s k ->
  let resume () = handle s k () in
  Resumption resume

(* -------------------------------------------------------------------------- *)

(* If [Deadlock] is raised, then the main thread has not finished. Yet, no
   thread is able to make progress; every thread is blocked. *)

(* As long as the dependency graph remains acyclic, a deadlock cannot
   happen. The dependency graph is normally acyclic, but could become
   cyclic if the client uses mutable state in a strange way. *)

exception Deadlock

(* -------------------------------------------------------------------------- *)

(* The main function, [run]. *)

(* [run] allocates and initializes the scheduler's state,
   creates the root future and the main thread,
   runs the scheduler until the main thread terminates (or a deadlock occurs),
   extracts the result of the main thread,
   and returns this result. *)

let run (type w) (main : w task) : w =
  next_future_id := 0;
  (* Initialize a scheduler state [s]. *)
  let s = new_state() in
  (* Create the root future and the main thread, which runs [main()]
     and writes its result into the root future. *)
  let fut = new_ordinary_future s @@ fun fut ->
    let main () = fulfill fut (main()) in
    unit_resumption s (fiber main)
  in
  (* Create an edge whose child is the root future. *)
  let notify _ = () in
  let edge = new_edge fut in
  edge.notify <- notify;
  (* Activate this edge. This activates the root future
     and schedules the main thread for execution. *)
  activate_edge s edge;
  (* Launch the scheduler. *)
  dequeue s;
  (* Extract the result. *)
  match query fut with
  | Result result ->
      result
  | Future _ ->
      raise Deadlock

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
  let s = get_state() in
  new_ordinary_future s @@ fun fut ->
  (* Run [task] and fulfill [fut] with its result. *)
  let child () = fulfill fut (task()) in
  unit_resumption s (fiber child)

(* [spawn_wait task] creates a new thread in charge of running [task] and
   waiting on its result, which is expected to be a future. Once [task] has
   terminated, the future [fut] is transformed into a proxy for the future
   returned by [task]. *)

let[@inline] spawn_wait (task : 'a future task) : 'a future =
  let s = get_state() in
  new_ordinary_future s @@ fun fut ->
  (* Run [task] and change [fut] into a proxy for its result. *)
  let child () = link s fut (task()) in
  unit_resumption s (fiber child)

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
      let s = get_state() in
      let fut, thread = new_ordinary_future_and_thread s @@ fun _fut -> dummy_resumption in
      (* Block the new thread on [fut1]. Once the thread awakens,
         run [f] and fulfill [fut] with its result. *)
      let resume result = fulfill fut (f result) in
      block s false thread fut1 (fiber resume);
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
      let s = get_state() in
      let fut, thread = new_ordinary_future_and_thread s @@ fun _fut -> dummy_resumption in
      (* Block the new thread on [fut1]. Once the thread awakens,
         run [task] and change [fut] into a proxy for its result. *)
      let resume result = link s fut (task result) in
      block s false thread fut1 (fiber resume);
      fut

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

let notify_join (join : 'a future) (result : 'a future) =
  (* The future [fut] has returned [result], which itself is a future.
     Change [join], in place, into a proxy future for [result].*)
  let s = get_state() in
  link s join result

let join (fut : 'a future future) : 'a future =
  match query fut with
  | Result result ->
      result
  | Future fut ->
      (* Create a fresh unary future [join], watching [fut]. *)
      let join = new_future "join" in
      let edge = new_edge fut in
      edge.notify <- notify_join join;
      init_unary_future fut edge;
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

(* [earliest] *)

(* [notify_earliest fut edge2 result1] is invoked when [fut1] has returned
   [result1]. We do not need to wait for [fut2]. We transmit [result1] to
   [fut] and deactivate the edge that leads from [fut] to [fut2]. *)

let[@inline] notify_earliest fut edge2 result1 =
  info "Future %d is fulfilled and stops watching future %d."
    fut.id edge2.child.id;
  fulfill fut result1;
  deactivate_edge edge2

(* A race between two distinct, unfulfilled futures. *)

let raw_earliest (fut1 : 'a future) (fut2 : 'a future) : 'a future =
  assert (not (is_fulfilled fut1));
  assert (not (is_fulfilled fut2));
  assert (fut1 != fut2);
  let fut = new_future "earliest" in
  let edge1 = new_edge fut1
  and edge2 = new_edge fut2 in
  edge1.notify <- notify_earliest fut edge2;
  edge2.notify <- notify_earliest fut edge1;
  init_binary_future fut edge1 edge2;
  fut

(* A race between two tasks. *)

let[@inline] earliest (task1 : 'a task) (task2 : 'a task) : 'a =
  raw_earliest (spawn task1) (spawn task2)
  |> wait

(* A race between two arbitrary futures. *)

let earliest_fut (fut1 : 'a future) (fut2 : 'a future) : 'a future =
  match query fut1, query fut2 with
  | Result _, _ ->
      fut1
  | _, Result _ ->
      fut2
  | Future fut1, Future fut2 ->
      if fut1 == fut2 then fut1 else
      raw_earliest fut1 fut2

(* -------------------------------------------------------------------------- *)

(* [earliest_decisive] *)

let notify_earliest_decisive decisive1 fut edge2 result1 =
  if decisive1 result1 then
    (* [fut1] has returned a decisive result. We do not need to wait for
       [fut2]. Transmit the result to [fut] and deactivate the edge that
       leads from [fut] to [fut2]. *)
    notify_earliest fut edge2 result1
  else
    (* [fut1] has returned a non-decisive result. We need to wait for
       [fut2]. The binary future [fut] degenerates into a proxy future,
       watching just [fut2]. *)
    init_proxy_future fut edge2

(* A race between two distinct, unfulfilled futures. *)

let raw_earliest_decisive decisive1 decisive2 fut1 fut2 =
  assert (not (is_fulfilled fut1));
  assert (not (is_fulfilled fut2));
  assert (fut1 != fut2);
  let fut = new_future "earliest_decisive" in
  let edge1 = new_edge fut1
  and edge2 = new_edge fut2 in
  edge1.notify <- notify_earliest_decisive decisive1 fut edge2;
  edge2.notify <- notify_earliest_decisive decisive2 fut edge1;
  init_binary_future fut edge1 edge2;
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

(* Conjunction and disjunction. *)

let is_false b =
  not b

let[@inline] conjunction task1 task2 =
  earliest_decisive is_false is_false task1 task2

let[@inline] conjunction_fut fut1 fut2 =
  earliest_decisive_fut is_false is_false fut1 fut2

let is_true b =
  b

(* Disjunction. *)

let[@inline] disjunction task1 task2 =
  earliest_decisive is_true is_true task1 task2

let[@inline] disjunction_fut fut1 fut2 =
  earliest_decisive_fut is_true is_true fut1 fut2
