(* A biased conjunction is [A ∧ B], under the assumption that [A → B] holds.
   As in a plain conjunction, if either side returns [false], we can return
   [false] immediately. Furthermore, if [A] returns [true], then [B] must be
   [true] as well, so can return [true] immediately. If [B] returns [true]
   then we must wait for [A]. *)

(* A biased conjunction is a hybrid between [earliest] and [conjunction].
   Along its left edge, it behaves like [earliest]. Along its right edge,
   it behaves like [conjunction]. *)
