open Ast

type sym_value =
  | SAccessor of accessor
  | SCons of constructor * sym_value list

type constraint_tree =
  | Unreachable
  | Failure
  | Leaf of sym_value list
  | Guard of sym_value list * constraint_tree * constraint_tree
  | Node of accessor * (constructor * constraint_tree) list * constraint_tree
(* We distinguish
   - Unreachable: we statically know that no value can go there
   - Failure: a value matching this part results in an error

  If we had a type-declaration-based analysis to know the list of constructors
  at a given type, we could produce Unreachable instead of Failure for
  fallbacks of closed signature:

    (function true -> 1)

  returns in, morally

    Node ([(true, Leaf 1)], Failure)

  while

    (function true -> 1 | false -> 2)

  will (somday) give

    Node ([(true, Leaf 1); (false, Leaf 2)], Unreachable)

  In the meantime, it is possible to produce Unreachable examples by using
  OCaml refutation clauses (a "dot" in the right-hand-side)

    (function true -> 1 | false -> 2 | _ -> .)

  We trust this annotation, which is reasonable as the OCaml type-checker
  verifies that it indeed holds.
*)

let print_result stree =
  let bprintf = Printf.bprintf
  in
  let rec bprint_accessor buf = function
    | AcRoot -> bprintf buf "AcRoot"
    | AcField (a, i) -> bprintf buf "%a.%d" bprint_accessor a i
  in
  let rec bprint_list ~sep bprint buf = function
    | [] -> ()
    | [x] -> bprint buf x
    | x :: xs ->
      bprintf buf "%a%t%a"
        bprint x
        sep
        (bprint_list ~sep bprint) xs
  in
  let bprint_constructor buf k = match k with
    | Variant s -> bprintf buf "Variant %s" s
    | Int i -> bprintf buf "Int %d" i
    | Bool b -> bprintf buf "Bool %b" b
    | String s -> bprintf buf "String \"%s\"" s
    | Tuple narity -> bprintf buf "Tuple[%d]" narity
    | Nil ->  bprintf buf "Nil"
    | Cons -> bprintf buf "Cons"
  in
  let rec bprint_sym_value buf = function
    | SAccessor acc -> bprintf buf "%a"
                         bprint_accessor acc
    | SCons (k, svl) -> bprintf buf "%a %a"
                          bprint_constructor k
                          (bprint_list ~sep:ignore bprint_sym_value) svl
  in
  let break ntabs buf =
    bprintf buf "\n%s" (BatList.init ntabs (fun _ -> "\t") |> String.concat "") in
  let rec bprint_tree ntabs buf tree =
    let sep = break (ntabs+1) in
    match tree with
    | Failure -> bprintf buf "Failure"
    | Unreachable -> bprintf buf "Unreachable"
    | Leaf sym_value_list ->
      bprintf buf
        "Leaf='%a'"
        (bprint_list ~sep:ignore bprint_sym_value) sym_value_list
    | Guard (sym_value_list, ctrue, cfalse) ->
      let bprint_child prefix tree =
        bprintf buf
          "%t%s =%t%a"
          (break ntabs) prefix sep
          (bprint_tree (ntabs+1)) tree
      in
      bprintf buf "Guard (%a) ="
        (bprint_list ~sep:ignore bprint_sym_value) sym_value_list;
      bprint_child "guard(true)" ctrue ; bprint_child "guard(false)" cfalse
    | Node (ac, k_cst_list, fallback_cst) ->
      bprintf buf "Node %a:{\
                   %a \
                   %t} Fallback: %a"
        bprint_accessor ac
        (bprint_list ~sep:sep
           (fun buf (k,cst) -> bprintf buf "%t%a -> %t%a"
               sep
               bprint_constructor k
               (break (ntabs+2))
               (bprint_tree (ntabs+1)) cst))
        k_cst_list
        (break ntabs)
        (bprint_tree (ntabs+1)) fallback_cst
  in
  let buf = Buffer.create 42 in
  bprint_tree 0 buf stree;
  BatIO.write_line BatIO.stdout (Buffer.contents buf)

type matrix = accessor list * matrix_row list
and matrix_row = pattern list row

type group = {
  arity: int;
  accessors: accessor list;
  rev_rows: pattern list row list ref;
}

let matrix_of_group { accessors; rev_rows; _ } : matrix =
  (accessors, List.rev !rev_rows)

let empty_group acs arity =
  match acs with
  | [] -> assert false
  | ac :: acs ->
     let accessors = List.init arity (fun i -> AcField(ac, i)) @ acs in
     {
       arity;
       accessors;
       rev_rows = ref [];
     }

let group_add_children { arity; rev_rows; _ } children row =
  assert (List.length children = arity);
  rev_rows := { row with lhs = children @ row.lhs } :: !rev_rows

let group_add_omegas { arity; rev_rows; _ } row =
  let wildcards = List.init arity (fun _ -> (Wildcard : pattern)) in
  rev_rows := { row with lhs = List.rev_append wildcards row.lhs } :: !rev_rows

let group_constructors type_env (acs, rows) : (constructor * matrix) list * matrix =
  let group_tbl : (constructor, group) Hashtbl.t = Hashtbl.create 42 in
  let wildcard_group = empty_group acs 0 in
  let rec collect_constructors : pattern list -> unit = function
    | [] -> ()
    | (pattern::ptl) ->
      match pattern with
      | Wildcard -> ()
      | Or (p1, p2) -> collect_constructors (p1::p2::ptl)
      | As (p, _) -> collect_constructors (p::ptl)
      | Constructor (k, _plist) ->
        if not (Hashtbl.mem group_tbl k) then begin
          let arity = Source_env.constructor_arity type_env k in
          Hashtbl.add group_tbl k (empty_group acs arity)
        end;
        collect_constructors ptl
  in
  List.iter (fun row -> collect_constructors row.lhs) rows;
  let all_constructor_groups =
    group_tbl |> Hashtbl.to_seq_values |> List.of_seq
  in
  let rec put_in_group (row : matrix_row) =
    match row.lhs with
    | [] -> assert false
    | pattern::ptl ->
      let with_lhs pats = { row with lhs = pats } in
      let row_rest = with_lhs ptl in
      match pattern with
      | Constructor (k, plist) ->
        let group = Hashtbl.find group_tbl k in
        group_add_children group plist row_rest
      | Wildcard ->
        List.iter (fun group -> group_add_omegas group row_rest)
          (wildcard_group :: all_constructor_groups);
      | As (pattern, _) -> put_in_group (with_lhs (pattern::ptl))
      | Or (p1, p2) -> put_in_group (with_lhs (p1::ptl)); put_in_group (with_lhs (p2::ptl))
  in
  List.iter put_in_group rows;
  let constructor_matrices =
    group_tbl
    |> Hashtbl.to_seq
    |> Seq.map (fun (k, group) -> (k, matrix_of_group group))
    |> List.of_seq
  in
  let wildcard_matrix = matrix_of_group wildcard_group in
  (constructor_matrices, wildcard_matrix)

let sym_exec source =
  let rec source_value_to_sym_value : source_value -> sym_value = function
    | VConstructor (k, svl) -> SCons (k, List.map source_value_to_sym_value svl)
    | VVar _ -> assert false
  in
  let type_env = Source_env.build_type_env source.type_decls in
  let rec decompose (matrix : matrix) : constraint_tree =
    match matrix with
    | (_, []) -> assert false
    | ([] as _no_acs, ({ lhs = []; guard = None;_ } as row)::_) ->
       begin match (row.rhs : source_rhs) with
         | Unreachable -> Unreachable
         | Observe expr -> Leaf (List.map source_value_to_sym_value expr)
       end
    | ([] as _no_acs,
       ({ lhs = []; guard = Some (Guard guard); _ } as row) :: rest)
      ->
       Guard (List.map source_value_to_sym_value guard,
              decompose ([], { row with guard = None } :: rest),
              decompose ([], rest))
    | (_::_ as _accs, { lhs = []; _ }::_) -> assert false
    | ([] as _no_accs, { lhs = _::_; _  }::_) -> assert false
    | (ac_head::_ as _acs, { lhs = (_::_); _ }::_) ->
      let groups, fallback = group_constructors type_env matrix in
      let groups_evaluated =
        groups |> List.map (fun (k, submatrix) -> (k, decompose submatrix))
      in
      let fallback_evaluated = match fallback with
        | (_, []) -> Failure
        | nonempty_matrix -> decompose nonempty_matrix
      in
      Node (ac_head, groups_evaluated, fallback_evaluated)
    in
    let row_of_clause clause = { clause with lhs = [clause.lhs] } in
    decompose ([AcRoot], List.map row_of_clause source.clauses)

let eval source_ast =
  let result = sym_exec source_ast in
  print_result result
