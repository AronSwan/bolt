open Ast.Ast_types
open Core
open Desugaring.Desugared_ast

let rec elem_in_list x = function [] -> false | y :: ys -> x = y || elem_in_list x ys
let intersect_lists list1 list2 = List.filter ~f:(fun x -> elem_in_list x list2) list1
let is_subset_of xs ys = List.for_all ~f:(fun x -> elem_in_list x ys) xs

let var_lists_are_equal xs ys =
  let compare_fn x y = String.compare (Var_name.to_string x) (Var_name.to_string y) in
  let deduped_xs = List.dedup_and_sort ~compare:compare_fn xs in
  let deduped_ys = List.dedup_and_sort ~compare:compare_fn ys in
  List.equal (fun x y -> x = y) deduped_xs deduped_ys

let identifier_matches_var_name var_name = function
  | Variable (_, name, _, _) -> name = var_name
  | ObjField (_, name, _, _, _, _) -> name = var_name

let get_class_defn class_name class_defns =
  let matching_class_defns =
    List.filter ~f:(fun (TClass (name, _, _, _, _)) -> class_name = name) class_defns
  in
  (* This should never throw an exception since we've checked this property in earlier
     type-checking stages of the pipeline *)
  List.hd_exn matching_class_defns

let rec get_class_capabilities class_name class_defns =
  get_class_defn class_name class_defns
  |> fun (TClass (_, maybe_superclass, capabilities, _, _)) ->
  ( match maybe_superclass with
  | Some super_class -> get_class_capabilities super_class class_defns
  | None             -> [] )
  |> fun superclass_caps -> List.concat [superclass_caps; capabilities]

let rec get_class_fields class_name class_defns =
  get_class_defn class_name class_defns
  |> fun (TClass (_, maybe_superclass, _, field_defns, _)) ->
  ( match maybe_superclass with
  | Some super_class -> get_class_fields super_class class_defns
  | None             -> [] )
  |> fun superclass_fields -> List.concat [superclass_fields; field_defns]

let get_class_field class_defns class_name field_name =
  let matching_field_defns =
    List.filter
      ~f:(fun (TField (_, _, name, _)) -> field_name = name)
      (get_class_fields class_name class_defns) in
  List.hd_exn matching_field_defns

let get_class_field_capabilities class_name field_name class_defns =
  get_class_field class_defns class_name field_name
  |> fun (TField (_, _, _, field_capability_names)) ->
  get_class_capabilities class_name class_defns
  |> fun capabilities ->
  List.filter
    ~f:(fun (TCapability (_, capability_name)) ->
      elem_in_list capability_name field_capability_names)
    capabilities

let get_class_capability_fields class_name capability_name class_defns =
  get_class_fields class_name class_defns
  |> fun fields ->
  List.filter
    ~f:(fun (TField (_, _, _, field_capability_names)) ->
      elem_in_list capability_name field_capability_names)
    fields

(* Convert a parameter to a representation which contains the capabilities it is allowed
   to access. *)
let param_to_obj_var_and_capabilities class_defns
    (TParam (type_expr, param_name, maybe_capability_guards, _)) =
  match type_expr with
  | TEClass (param_class, _) ->
      let class_capabilities = get_class_capabilities param_class class_defns in
      let obj_capabilities =
        match maybe_capability_guards with
        | None -> class_capabilities
        (* no constraints so can access anything *)
        | Some capability_guards ->
            List.filter
              ~f:(fun (TCapability (_, cap_name)) ->
                elem_in_list cap_name capability_guards)
              class_capabilities in
      Some (param_name, param_class, obj_capabilities)
  | _                        ->
      (* not an object so ignore *)
      None

let get_function_defn func_name function_defns =
  List.hd_exn
    (List.filter
       ~f:(fun (TFunction (name, _, _, _, _)) -> name = func_name)
       function_defns)

let get_function_params func_name function_defns =
  get_function_defn func_name function_defns
  |> fun (TFunction (_, _, _, params, _)) -> params

let rec get_class_method_defns class_name class_defns =
  get_class_defn class_name class_defns
  |> fun (TClass (_, maybe_superclass, _, _, method_defns)) ->
  ( match maybe_superclass with
  | Some superclass -> get_class_method_defns superclass class_defns
  | None            -> [] )
  |> fun superclass_methods ->
  List.concat [superclass_methods; method_defns]
  (* filter out overridden methods (i.e those with same name) *)
  |> List.dedup_and_sort
       ~compare:(fun (TMethod (name_1, _, _, _, _, _))
                     (TMethod (name_2, _, _, _, _, _))
                     -> if name_1 = name_2 then 0 else 1)

let get_method_defn class_name meth_name class_defns =
  get_class_method_defns class_name class_defns
  |> fun method_defns ->
  List.hd_exn
    (List.filter
       ~f:(fun (TMethod (name, _, _, _, _, _)) -> name = meth_name)
       method_defns)

let get_method_params class_name meth_name class_defns =
  get_method_defn class_name meth_name class_defns
  |> fun (TMethod (_, _, _, params, _, _)) -> params

let params_to_obj_vars_and_capabilities class_defns params =
  List.filter_map ~f:(param_to_obj_var_and_capabilities class_defns) params

let get_identifier_name = function
  | Variable (_, name, _, _) -> name
  | ObjField (_, name, _, _, _, _) -> name

let get_identifier_capabilities = function
  | Variable (_, _, capabilities, _) -> capabilities
  | ObjField (_, _, _, _, capabilities, _) -> capabilities

let get_method_capabilities_used class_name meth_name class_defns =
  get_method_defn class_name meth_name class_defns
  |> fun (TMethod (_, _, _, _, capabilities_used, _)) -> capabilities_used

let set_identifier_capabilities id new_capabilities =
  match id with
  | Variable (var_type, var_name, _, maybeBorrowed) ->
      Variable (var_type, var_name, new_capabilities, maybeBorrowed)
  | ObjField (obj_class, obj_name, field_type, field_name, _, maybeBorrowed) ->
      ObjField
        (obj_class, obj_name, field_type, field_name, new_capabilities, maybeBorrowed)

let capability_mode_present mode_present mode_required =
  match mode_required with
  | ThreadSafe -> (
    match mode_present with
    | Read | Locked | ThreadSafe -> true
    | Linear | ThreadLocal | Subordinate | Encapsulated -> false )
  | Encapsulated -> (
    match mode_present with
    | Subordinate | Encapsulated -> true
    | Linear | ThreadLocal | Read | Locked | ThreadSafe -> false )
  | Linear | ThreadLocal | Subordinate | Read | Locked -> mode_present = mode_required

let class_has_mode class_name mode class_defns =
  let rec class_has_mode_helper class_name mode class_defns seen_class_names =
    if elem_in_list class_name seen_class_names then
      (* Avoid infinite recursion on type definition *)
      false
    else
      get_class_capabilities class_name class_defns
      |> fun capabilities ->
      get_class_fields class_name class_defns
      |> fun fields ->
      match mode with
      (* any one of its capabilities (and nested field types) hold the mode *)
      | Linear | Subordinate | ThreadLocal ->
          List.exists
            ~f:(fun (TCapability (capability_mode, _)) -> capability_mode = mode)
            capabilities
          || List.exists
               ~f:(fun (TField (_, field_type, _, _)) ->
                 match field_type with
                 | TEClass (nested_class, _) ->
                     class_has_mode_helper nested_class mode class_defns
                       (class_name :: seen_class_names)
                 | _                         -> false)
               fields
      (* all its capabilities hold the mode *)
      | Read | Encapsulated | ThreadSafe ->
          List.for_all
            ~f:(fun (TCapability (capability_mode, _)) ->
              capability_mode_present capability_mode mode)
            capabilities
      | Locked ->
          class_has_mode_helper class_name ThreadSafe class_defns seen_class_names
          && List.exists
               ~f:(fun (TCapability (capability_mode, _)) -> capability_mode = Locked)
               capabilities in
  class_has_mode_helper class_name mode class_defns []

let type_has_mode type_expr mode class_defns =
  match type_expr with
  | TEClass (class_name, _) -> class_has_mode class_name mode class_defns
  | _                       -> false

let capability_fields_have_mode (TCapability (capability_mode, capability_name))
    class_name mode class_defns =
  capability_mode_present capability_mode mode
  || get_class_capability_fields class_name capability_name class_defns
     |> fun fields_in_capability ->
     List.exists
       ~f:(fun (TField (_, field_type, _, _)) ->
         match field_type with
         | TEClass (field_class, _) -> class_has_mode field_class mode class_defns
         | _                        -> false)
       fields_in_capability

let identifier_has_mode id mode class_defns =
  let check_capability_modes class_name capabilities =
    List.exists
      ~f:(fun capability ->
        capability_fields_have_mode capability class_name mode class_defns)
      capabilities in
  match id with
  | Variable (var_type, _, capabilities, _) -> (
    match var_type with
    | TEClass (var_class, _) -> check_capability_modes var_class capabilities
    | _                      -> false )
  | ObjField (obj_class, _, _, _, capabilities, _) ->
      check_capability_modes obj_class capabilities

let rec reduce_expr_to_obj_ids expr =
  match expr with
  | Integer _ | Boolean _ -> []
  | Identifier (_, id) -> [id]
  | BlockExpr (_, block_expr) -> reduce_block_expr_to_obj_ids block_expr
  | Constructor (_, _, _, _) -> []
  | Let (_, var_type, var_name, _) -> [Variable (var_type, var_name, [], None)]
  | Assign (_, _, id, _) -> [id]
  | Consume (_, _) -> []
  | MethodApp (_, _, _, _, _, _, _) -> []
  | FunctionApp (_, _, _, _) -> []
  | Printf (_, _, _) -> []
  | FinishAsync (_, _, _, _, curr_thread_expr) ->
      reduce_block_expr_to_obj_ids curr_thread_expr
  | If (_, _, _, then_expr, else_expr) ->
      let then_id = reduce_block_expr_to_obj_ids then_expr in
      let else_id = reduce_block_expr_to_obj_ids else_expr in
      then_id @ else_id
  | While _ -> []
  | BinOp _ -> [] (* Bin op returns either a TEInt or a Bool *)
  | UnOp _ -> []

and reduce_block_expr_to_obj_ids (Block (loc, type_expr, exprs)) =
  match exprs with
  | []             -> []
  | [expr]         -> reduce_expr_to_obj_ids expr
  | _ :: rem_exprs -> reduce_block_expr_to_obj_ids (Block (loc, type_expr, rem_exprs))

(* Check if the expression is reduced to an id that matches a given name_to_match *)
let has_matching_expr_reduced_ids should_match_fields name_to_match ids =
  List.length
    (List.filter
       ~f:(function
         | Variable (_, name, _, _) -> name_to_match = name
         | ObjField (_, obj_name, _, _, _, _) ->
             should_match_fields && name_to_match = obj_name)
       ids)
  > 0

let rec find_immediate_aliases_in_expr should_match_fields orig_obj_name curr_aliases expr
    =
  let find_imm_aliases_in_expr_rec =
    find_immediate_aliases_in_expr should_match_fields orig_obj_name in
  let find_imm_aliases_in_block_expr_rec =
    find_immediate_aliases_in_block_expr should_match_fields orig_obj_name in
  match expr with
  | Let (_, _, name, bound_expr) ->
      find_immediate_aliases_in_expr should_match_fields orig_obj_name curr_aliases
        bound_expr
      |> fun updated_aliases ->
      reduce_expr_to_obj_ids bound_expr
      |> fun expr_reduced_ids ->
      if
        List.exists
          ~f:(fun name_to_match ->
            has_matching_expr_reduced_ids should_match_fields name_to_match
              expr_reduced_ids)
          (orig_obj_name :: updated_aliases)
      then name :: updated_aliases
      else updated_aliases
  (* now we just recurse in other cases *)
  | Integer _ | Boolean _ | Identifier _ -> curr_aliases
  | BlockExpr (_, block_expr) ->
      find_imm_aliases_in_block_expr_rec curr_aliases block_expr
  | Constructor (_, _, _, constructor_args) ->
      List.fold ~init:curr_aliases
        ~f:(fun acc_aliases (ConstructorArg (_, _, expr)) ->
          find_imm_aliases_in_expr_rec acc_aliases expr)
        constructor_args
  | Assign (_, _, _, assigned_expr) ->
      find_imm_aliases_in_expr_rec curr_aliases assigned_expr
  | Consume _ -> curr_aliases
  | MethodApp (_, _, _, _, _, _, args_exprs) ->
      List.fold ~init:curr_aliases ~f:find_imm_aliases_in_expr_rec args_exprs
  | FunctionApp (_, _, _, args_exprs) ->
      List.fold ~init:curr_aliases ~f:find_imm_aliases_in_expr_rec args_exprs
  | Printf (_, _, args_exprs) ->
      List.fold ~init:curr_aliases ~f:find_imm_aliases_in_expr_rec args_exprs
  | FinishAsync (_, _, async_exprs, _, curr_thread_expr) ->
      List.fold
        ~init:(find_imm_aliases_in_block_expr_rec curr_aliases curr_thread_expr)
        ~f:(fun acc_aliases (AsyncExpr (_, async_expr)) ->
          find_imm_aliases_in_block_expr_rec acc_aliases async_expr)
        async_exprs
  | If (_, _, cond_expr, then_expr, else_expr) ->
      List.fold
        ~init:(find_imm_aliases_in_expr_rec curr_aliases cond_expr)
        ~f:find_imm_aliases_in_block_expr_rec [then_expr; else_expr]
  | While (_, cond_expr, loop_expr) ->
      (* Note we check twice to simulate going through loop multiple times *)
      find_imm_aliases_in_expr_rec curr_aliases cond_expr
      |> fun curr_aliases_with_cond ->
      find_imm_aliases_in_block_expr_rec curr_aliases_with_cond loop_expr
  | BinOp (_, _, _, expr1, expr2) ->
      List.fold ~init:curr_aliases ~f:find_imm_aliases_in_expr_rec [expr1; expr2]
  | UnOp (_, _, _, expr) -> find_imm_aliases_in_expr_rec curr_aliases expr

and find_immediate_aliases_in_block_expr should_match_fields orig_obj_name curr_aliases
    (Block (_, _, exprs)) =
  List.fold ~init:curr_aliases
    ~f:(find_immediate_aliases_in_expr should_match_fields orig_obj_name)
    exprs

let find_aliases_in_block_expr ~should_match_fields name_to_match block_expr =
  (* Get the least fixed point of an object's aliases *)
  let rec get_all_obj_aliases should_match_fields curr_aliases block_expr =
    find_immediate_aliases_in_block_expr should_match_fields name_to_match curr_aliases
      block_expr
    |> fun updated_aliases ->
    if var_lists_are_equal updated_aliases curr_aliases then curr_aliases
    else get_all_obj_aliases should_match_fields updated_aliases block_expr in
  get_all_obj_aliases should_match_fields [] block_expr
