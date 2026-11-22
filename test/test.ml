open Generate

(* Environments. *)

type 'a env =
  'a list

let empty =
  []

let lookup env x =
  List.nth env x

let extend env v =
  v :: env

let rec number i env =
  match env with
  | [] ->
      []
  | ty :: env ->
      (i, ty) :: number (i+1) env

(* Splitting a random budget. *)

let split budget =
  if budget = 0 then
    0, 0
  else
    let budget1 = Random.int (budget+1) in
    budget1, budget - budget1

(* The (untyped) syntax of a task. *)

type syntax =
| Var :
    int -> syntax
| BoolLit :
    bool -> syntax
| Seq :
    syntax * syntax -> syntax
| Let :
    syntax * syntax -> syntax
| Yield :
    syntax
| Conjunction :
    syntax * syntax -> syntax
| Disjunction :
    syntax * syntax -> syntax
| Spawn :
    syntax -> syntax
| Wait :
    syntax -> syntax

let yield s =
  Seq (Yield, s)

(* Types. *)

type ty =
  | TyBool
  | TyFut of ty

(* A generator of random well-typed tasks. *)

(* [env] maps variables to types. *)

(* [budget] is the desired size. *)

(* [target] is the desired type. *)

let var (env : ty env) (target : ty) : syntax choices =
  number 0 env
  |> List.filter_map (fun (i, ty) -> if ty = target then Some (Var i) else None)
  |> Array.of_list
  |> constants 1

let bool (target : ty) : syntax choices =
  if target = TyBool then
    singleton 1 @@ fun () ->
    BoolLit (Random.bool())
  else
    nope

let rec conjunction (env : ty env) (target : ty) (budget : int) : syntax choices =
  match target with
  | TyBool ->
      singleton 1 @@ fun () ->
      let budget1, budget2 = split budget in
      Conjunction (generate env TyBool budget1, generate env TyBool budget2)
  | _ ->
      nope

and disjunction (env : ty env) (target : ty) (budget : int) : syntax choices =
  match target with
  | TyBool ->
      singleton 1 @@ fun () ->
      let budget1, budget2 = split budget in
      Disjunction (generate env TyBool budget1, generate env TyBool budget2)
  | _ ->
      nope

and spawn (env : ty env) (target : ty) (budget : int) : syntax choices =
  match target with
  | TyFut target ->
      singleton 1 @@ fun () ->
      Spawn (generate env target budget)
  | _ ->
      nope

and wait (env : ty env) (target : ty) (budget : int) : syntax choices =
  singleton 1 @@ fun () ->
  Wait (generate env (TyFut target) budget)

(* TODO produce [let] constructs *)

and generate (env : ty env) (target : ty) (budget : int) : syntax =
  assert (0 <= budget);
  if budget = 0 then
    (* The target size is zero. Produce a variable or a Boolean literal. *)
    choose (
      var env target @
      bool target
    )
  else
    (* The target size is nonzero. *)
    yield @@
    (* Produce a conjunction or disjunction. *)
    let budget = budget - 1 in
    choose (
      conjunction env target budget @
      disjunction env target budget
    )
        (* TODO *)
        (* Spawn (generate env budget) *)
        (* Wait (generate env budget) *)

(* The signature of an implementation. *)

module type S = sig
  type 'a task = unit -> 'a
  val run : 'a task -> 'a
  val yield : unit -> unit
  val conjunction : bool task -> bool task -> bool
  val disjunction : bool task -> bool task -> bool
  type 'a future
  val spawn: 'a task -> 'a future
  val wait : 'a future -> 'a
end

(* An interpreter of (well-typed) tasks. *)

module Eval (I : S) = struct

(* Values. *)

type value =
  | VBool of bool
  | VUnit
  | VFut of value I.future

let vBool b =
  VBool b

let asBool v =
  match v with VBool b -> b | _ -> assert false

let vUnit () =
  VUnit

let asUnit v =
  match v with VUnit -> () | _ -> assert false

let vFut fut =
  VFut fut

let asFut v =
  match v with VFut fut -> fut | _ -> assert false

let rec eval env (s : syntax) : value =
  match s with
  | Var x ->
      lookup env x
  | BoolLit b ->
      b
      |> vBool
  | Seq (s1, s2) ->
      let () = eval env s1 |> asUnit in
      eval env s2
  | Let (s1, s2) ->
      let v1 = eval env s1 in
      let env = extend env v1 in
      eval env s2
  | Yield ->
      I.yield()
      |> vUnit
  | Conjunction (s1, s2) ->
      I.conjunction
        (fun () -> eval env s1 |> asBool)
        (fun () -> eval env s2 |> asBool)
      |> vBool
  | Disjunction (s1, s2) ->
      I.disjunction
        (fun () -> eval env s1 |> asBool)
        (fun () -> eval env s2 |> asBool)
      |> vBool
  | Spawn s ->
      I.spawn (fun () -> eval env s)
      |> vFut
  | Wait s ->
      I.wait (eval env s |> asFut)

let run (s : syntax) : value =
  I.run (fun () -> eval empty s)

end

(* The reference implementation. *)
module R = Eval(Reference)

(* The candidate implementation. *)
module C = Eval(Fourmi.Async)

(* Comparing a reference value and a candidate value. *)

let related (v1 : R.value) (v2 : C.value) =
  match v1, v2 with
  | VBool b1, VBool b2 ->
      b1 = b2
  | VUnit, VUnit ->
      true
  | VFut _, VFut _ ->
      (* The type ['a future] is opaque. *)
      assert false
  | _, _ ->
      assert false

(* One test run. *)

exception Fail

let test budget =
  let s = generate empty TyBool budget in
  let rv = R.run s in
  let cv = C.run s in
  if not (related rv cv) then
    raise Fail

(* The main program. *)

let iterations =
  10000

let budget =
  1000

let () =
  for _i = 1 to iterations do
    test budget
  done;
  Printf.eprintf "Successfully performed %d test runs.\n%!" iterations
