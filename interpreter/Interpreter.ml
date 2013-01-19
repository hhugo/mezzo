open SurfaceSyntax
open InterpreterDefs

(* This module contains the interpreter. *)

(* ---------------------------------------------------------------------------- *)

(* Extending the environment with a binding of an unqualified name [x]
   to a value [v]. *)

let extend_unqualified (x : Variable.name) (v : value) (env : env) : env =
  QualifiedVariableMap.add (local, x) v env

(* ---------------------------------------------------------------------------- *)

(* The unit value is the empty tuple. *)

let unit_value =
  VTuple []

(* The [core] module. *)

let core : Module.name =
  Module.register "core"

(* The Boolean values are [core::True] and [core::False]. *)

let true_value =
  VAddress { tag = (core, Datacon.register "True"); adopter = None; fields = [||] }

let false_value =
  VAddress { tag = (core, Datacon.register "False"); adopter = None; fields = [||] }

(* ---------------------------------------------------------------------------- *)

(* Un-tagging values. *)

let asBlock (v : value) : block =
  match v with
  | VAddress block ->
      block
  | _ ->
      (* Runtime tag error. *)
      assert false

let asTuple (v : value) : value list =
  match v with
  | VTuple vs ->
      vs
  | _ ->
      (* Runtime tag error. *)
      assert false

let asClosure (v : value) : closure =
  match v with
  | VClosure c ->
      c
  | _ ->
      (* Runtime tag error. *)
      assert false

(* ---------------------------------------------------------------------------- *)

(* Translating a field to an integer offset. *)

let field_to_offset (field : field) : int =
  assert false

(* Finding how many fields a data constructor carries. *)

let tag_to_length (tag : Datacon.name) : int =
  assert false

(* Converting a tag to a Boolean value. *)

let tag_to_boolean (tag : QualifiedDatacon.name) : bool =
  assert false

(* ---------------------------------------------------------------------------- *)

(* Translating a type to a pattern. *)

let rec type_to_pattern (ty : typ) : pattern =
  match ty with

  (* A structural type constructor is translated to the corresponding
     structural pattern. *)

  | TyTuple tys ->
      PTuple (List.map type_to_pattern tys)

  | TyConcreteUnfolded (datacon, fields) ->
      let fps =
	List.fold_left (fun fps field ->
	  match field with
          | FieldValue (f, ty) -> (f, type_to_pattern ty) :: fps
          | FieldPermission _  -> fps
	) [] fields in
      PConstruct (datacon, fps)

   (* A name introduction gives rise to a variable pattern. *)

  | TyNameIntro (x, ty) ->
      PAs (type_to_pattern ty, PVar x)

  (* Pass (go down into) the following constructs. *)

  | TyLocated (ty, _, _)
  | TyAnd (_, ty)
  | TyConsumes ty
  | TyBar (ty, _) ->
      type_to_pattern ty

  (* Stop at (do not go down into) the following constructs. *)

  | TyForall _
  | TyUnknown
  | TyArrow _ 
  | TySingleton _
  | TyQualified _
  | TyDynamic
  | TyApp _
  | TyVar _ ->
      PAny

  (* The following cases should not arise. *)

  | TyEmpty
  | TyStar _
  | TyAnchoredPermission _ ->
      assert false

(* ---------------------------------------------------------------------------- *)

(* Matching a value [v] against a pattern [p]. The resulting bindings are
   accumulated in the environment [env]. The function [match_pattern] raises
   [MatchFailure] if [p] does not match [v]. The following two functions
   catch this exception. *)

exception MatchFailure

let rec match_pattern (env : env) (p : pattern) (v : value) : env =
  match p with
  | PVar x ->
      extend_unqualified x v env
  | PTuple ps ->
      begin try
	List.fold_left2 match_pattern env ps (asTuple v)
      with Invalid_argument _ ->
	(* Tuples of non-matching lengths. *)
	assert false
      end
  | PConstruct (datacon, fps) ->
      let b = asBlock v in
      (* TEMPORARY problems with name resolution for datacons *)
      if QualifiedDatacon.compare (local, datacon) b.tag = 0 then
        List.fold_left (fun env (f, p) ->
	  let field = { field_datacon = datacon; field_name = f } in
	  let offset = field_to_offset field in
	  match_pattern env p b.fields.(offset)
	) env fps
      else
        raise MatchFailure
  | PLocated (p, _, _)
  | PConstraint (p, _) ->
      match_pattern env p v
  | PAs (p1, p2) ->
      let env = match_pattern env p1 v in
      let env = match_pattern env p2 v in
      env
  | PAny ->
      env

let match_irrefutable_pattern (env : env) (p : pattern) (v : value) : env =
  try
    match_pattern env p v
  with MatchFailure ->
    (* This pattern was supposed to be irrefutable! *)
    assert false

let match_refutable_pattern (env : env) (p : pattern) (v : value) : env option =
  try
    Some (match_pattern env p v)
  with MatchFailure ->
    None

(* ---------------------------------------------------------------------------- *)

(* Evaluating a qualified variable name. *)

let eval_EQualified (env : env) (x : QualifiedVariable.name) : value =
  (* Look up this qualified name in the environment. *)
  (* TEMPORARY should we have two environments for global/local names? *)
  try
    QualifiedVariableMap.find x env
  with Not_found ->
    (* This variable is undefined. *)
    assert false

(* ---------------------------------------------------------------------------- *)

(* Evaluating an expression. *)

let rec eval (env : env) (e : expression) : value =
  match e with

  | EConstraint (e, _) ->
      eval env e

  | EVar x ->
      (* Map the unqualified name [x] to a (possibly-)qualified name. *)
      (* TEMPORARY this probably requires a static resolution environment? *)
      let x : QualifiedVariable.name = assert false in
      (* Evaluate this qualified name. *)
      eval_EQualified env x

  | EQualified (m, x) ->
      eval_EQualified env (m, x)

  | ELet (Nonrecursive, equations, body) ->
      (* Evaluate the equations, in left-to-right order. *)
      let new_env : env =
	List.fold_left (fun new_env (p, e) ->
	  (* For each equation [p = e], evaluate the expression [e] in the old
	     environment [env], and match the resulting value against the
	     pattern [p]. Accumulate the resulting bindings in the new
	     environment [new_env]. The type-checker guarantees that no
	     variable is bound twice. *)
	  match_irrefutable_pattern new_env p (eval env e)
	) env equations
      in
      (* Evaluate the body. *)
      eval new_env body

  | ELet (Recursive, equations, body) ->
      (* We must construct an environment and a number of closures
	 that point to each other; this is Landin's knot. We begin
         by constructing a list of partly initialized closures, as
         well as the new environment, which contains these closures. *)
      let (new_env : env), (closures : closure list) =
	List.fold_left (fun (new_env, closures) (p, e) ->
	  match p, e with
	  | PVar f, EFun (_type_parameters, argument_type, _result_type, body) ->
	      (* Build a closure with an uninitialized environment field. *)
	      let c = {
		(* The argument pattern is implicit in the argument type. *)
		arg = type_to_pattern argument_type;
		(* The function body. *)
		body = body;
		(* An uninitialized environment. *)
		env = QualifiedVariableMap.empty;
	      } in
	      (* Bind [f] to this closure. *)
	      extend_unqualified f (VClosure c) new_env,
	      c :: closures
	  | _, _ ->
	      (* The left-hand side of a recursive definition must be a variable,
		 and the right-hand side must be a lambda-abstraction. *)
	      (* TEMPORARY should deal with PLocated too *)
	      assert false
	) (env, []) equations
      in
      (* There remains to patch the closures with the new environment. *)
      List.iter (fun c ->
	(* TEMPORARY environment could/should be filtered *)
        c.env <- new_env
      ) closures;
      (* Evaluate the body. *)
      eval new_env body

  | EFun (_type_parameters, argument_type, _result_type, body) ->
      VClosure {
	(* The argument pattern is implicit in the argument type. *)
	arg = type_to_pattern argument_type;
	(* The function body. *)
	body = body;
	(* The environment. *)
	(* TEMPORARY environment could/should be filtered *)
	env = env;
      }

  | EAssign (e1, field, e2) ->
      let b1 = asBlock (eval env e1) in
      let v2 = eval env e2 in
      b1.fields.(field_to_offset field) <- v2;
      unit_value

  | EAssignTag (e, { datacon_name = tag; _ }) ->
      let b = asBlock (eval env e) in
      (* TEMPORARY problem: tags are not qualified *)
      (* for now, cheat *)
      b.tag <- (local, tag);
      unit_value

  | EAccess (e, field) ->
      let b = asBlock (eval env e) in
      b.fields.(field_to_offset field)

  | EAssert _ ->
      unit_value

  | EApply (e1, e2) ->
      let c1 = asClosure (eval env e1) in
      let v2 = eval env e2 in
      (* Extend the closure's environment with a binding of the
	 formal argument to the actual argument. Evaluate the
	 closure body. *)
      eval (match_irrefutable_pattern c1.env c1.arg v2) c1.body

  | ETApply (e, _) ->
      eval env e

  | EMatch (_, e, branches) ->
      switch env (eval env e) branches

  | ETuple es ->
      (* [List.map] implements left-to-right evaluation. *)
      VTuple (List.map (eval env) es)

  | EConstruct (tag, fes) ->
      (* Evaluate the fields in the order specified by the programmer. *)
      let fvs =
	List.map (fun (f, e) -> (f, eval env e)) fes
      in
      (* Allocate a field array. *)
      let fields = Array.create (tag_to_length tag) unit_value in
      (* Populate the field array. *)
      List.iter (fun (f, v) ->
	let field = { field_name = f; field_datacon = tag } in
	let offset = field_to_offset field in
	fields.(offset) <- v
      ) fvs;
      (* Allocate a memory block. *)
      VAddress {
	(* TEMPORARY problem with qualified tags *)
	tag = (local, tag);
	adopter = None;
	fields = fields;
      }

  | EIfThenElse (_, e, e1, e2) ->
      let b = asBlock (eval env e) in
      if tag_to_boolean b.tag then
	eval env e1
      else
	eval env e2

  | ESequence (e1, e2) ->
      let _unit = eval env e1 in
      eval env e2

  | ELocated (e, pos1, pos2) ->
      (* TEMPORARY keep track of locations for runtime error messages *)
      eval env e

  | EInt i ->
      VInt i

  | EExplained e ->
      eval env e

  | EGive (e1, e2) ->
      let b1 = asBlock (eval env e1) in
      let b2 = asBlock (eval env e2) in
      assert (b1.adopter = None);
      b1.adopter <- Some b2;
      unit_value

  | ETake (e1, e2) ->
      let b1 = asBlock (eval env e1) in
      let b2 = asBlock (eval env e2) in
      begin match b1.adopter with
      | Some b when (b == b2) ->
          b1.adopter <- None;
          unit_value
      | _ ->
          Log.error "Take failure.\n"
      end

  | EOwns (e1, e2) ->
      let b1 = asBlock (eval env e1) in
      let b2 = asBlock (eval env e2) in
      begin match b1.adopter with
      | Some b when (b == b2) ->
	  true_value
      | _ ->
          false_value
      end

  | EFail ->
      Log.error "Failure.\n"

(* ---------------------------------------------------------------------------- *)

(* Evaluating a switch construct. *)

and switch (env : env) (v : value) (branches : (pattern * expression) list) : value =
  match branches with
  | (p, e) :: branches ->
      begin match match_refutable_pattern env p v with
      | Some env ->
	  (* [p] matches [v]. Evaluate the branch [e]. *)
	  eval env e
      | None ->
	  (* [p] does not match [v]. Try the next branch. *)
	  switch env v branches
      end
  | [] ->
      (* No more branches. This should not happen if the type-checker has
         checked for exhaustiveness. At the moment, this is not done,
         though. *)
      (* TEMPORARY should print a location and the value [v] *)
      Log.error "Match failure.\n"

(* ---------------------------------------------------------------------------- *)

