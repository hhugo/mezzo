(*****************************************************************************)
(*  Mezzo, a programming language based on permissions                       *)
(*  Copyright (C) 2011, 2012 Jonathan Protzenko and François Pottier         *)
(*                                                                           *)
(*  This program is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU General Public License as published by     *)
(*  the Free Software Foundation, either version 3 of the License, or        *)
(*  (at your option) any later version.                                      *)
(*                                                                           *)
(*  This program is distributed in the hope that it will be useful,          *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(*  GNU General Public License for more details.                             *)
(*                                                                           *)
(*  You should have received a copy of the GNU General Public License        *)
(*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*                                                                           *)
(*****************************************************************************)

(* This module implements a well-kindedness check for the types of
   the surface language. [Note Jonathan: a clean version of the rules can be
   found in my thesis noteboook, date June, 16th 2012]. *)

open SurfaceSyntax
module T = TypeCore
module E = Expressions


(* ---------------------------------------------------------------------------- *)

(* Maps of identifiers to things. *)

module M =
  Variable.Map

(* An environment maps an identifier to a pair of a kind and a de Bruijn level
   (not to be confused with a de Bruijn index!). An environment also keeps
   track of the current de Bruijn level.

   This binding representation is specific to this first phase -- we use more
   sophisticated environments later on, and the level thing is just some sort of
   hack. *)

type level =
    int

(* When a module is opened in scope, the names it exports point to points that
 * are already valid in the environment (think of these as binders that have
 * been opened already). Otherwise, it's a bound variable. *)
type var = Var of level | Point of T.var
let tvar = function Var x -> T.TyBound x | Point x -> T.TyOpen x;;
let evar = function Var x -> E.EVar x | Point x -> E.EOpen x;;

type datacon_origin =
  | InCurrentModule of level * SurfaceSyntax.datacon_info
  | InAnotherModule of T.var * SurfaceSyntax.datacon_info

type env = {
  (* The current de Bruijn level. *)
  level: level;

  (* A mapping of identifiers to pairs of a kind and a level. *)
  mapping: (kind * var) M.t;

  (* The current start and end positions *)
  location: Lexing.position * Lexing.position;

  (* [Driver] already discovered our dependencies for us, and processed them, so
   * [env] contains all the information about our dependencies. However, it
   * contains no information about the module that's being processed, except
   * for the field [module_name] (that's not entirely true if we're matching an
   * implementation against its interface but the bottom line is: only use this
   * environment for you dependencies on other modules). *)
  env: T.env;

  (* If the data constructor belongs to another module, that module's signature
   * has been imported in [env] and the definition which the data constructors
   * belongs to will be found there (using the point).
   *
   * If the data constructor belongs to a data type defined in the current
   * module, then it belongs to a type definition that has a De Bruijn level.
   *
   * Because we must maintain the physical identity of the [datacon_info]s,
   * they're all stored here and this helps us maintain the invariant that they
   * are only created once.
   *
   * This order counts (at least for unqualified items). *)
  known_datacons: (Datacon.name maybe_qualified * datacon_origin) list;
}

let mkdatacon_info dc i fields =
  (* Create the map. *)
  let fmap = MzList.fold_lefti
    (fun i fmap f -> Field.Map.add f i fmap)
    Field.Map.empty fields
  in {
    datacon_name = Datacon.print dc;
    datacon_arity = List.length fields;
    datacon_index = i;
    datacon_fields = fmap;
  }
;;


(* The empty environment. *)

let empty (env: T.env): env =
  (* We build the list of initially available data constructors: these are
   * available through a [Qualified] prefix, and they are defined
   * [InAnotherModule]. *)
  let initial_datacons =
    let open T in
    fold_definitions env (fun acc var definition ->
      let names = get_names env var in
      (* We're only interested in things that signatures exported with their
       * corresponding definitions. *)
      match definition with
      | Some def, _ ->
          (* Find the module name which this definition comes from. Yes, there's
           * no better way to do that. *)
          let mname = MzList.find_opt
            (function User (mname, _) -> Some mname | _ -> None)
            names
          in
          let mname = Option.extract mname in
          (* Build the entries for [known_datacons]. *)
          let datacons = List.mapi (fun i branch ->
	    let dc = branch.branch_datacon
	    and fields = branch.branch_fields in
            (* This data constructor will be initially accessible only in a
             * qualified manner. *)
            let qualif = Qualified (mname, dc) in
            (* We're building information for the interpreter: drop the
             * permission fields. *)
            let fields = MzList.map_some (function
              | FieldValue (name, _) -> Some name
              | FieldPermission _ -> None
            ) fields in
            (* Now the info structure is ready. *)
            let info = InAnotherModule (var, mkdatacon_info dc i fields) in
            qualif, info
          ) def in
          datacons @ acc
      | _ ->
          acc
  ) []
  in {
    level = 0;
    mapping = M.empty;
    location = Lexing.dummy_pos, Lexing.dummy_pos;
    env;
    known_datacons = initial_datacons;
  }
;;



(* ---------------------------------------------------------------------------- *)

(* Error messages. *)

type error = env * raw_error

and raw_error =
  | Unbound of Variable.name
  | Mismatch of kind * kind
  | NotAnArrow of kind
  | BoundTwice of Variable.name
  | IllegalConsumes
  | BadConditionsInFact of Variable.name
  | BadConclusionInFact of Variable.name
  | NonDistinctHeadsInFact of Variable.name * Mode.mode
  | DuplicateConstructor of Datacon.name
  | DuplicateField of Variable.name
  | AdopterNotExclusive of Variable.name
  | UnboundDataConstructor of Datacon.name
  | FieldMismatch of Datacon.name * Field.name list (* missing fields *) * Field.name list (* extra fields *)
  | ImplicationOnlyOnArrow

exception KindError of error

let raise_error env e =
  raise (KindError (env, e))
;;

let pkenv buf env =
  let open Types.TypePrinter in
  (* Uncomment this part to get a really verbose error message. *)
  Printf.bprintf buf "\n";
  let bindings = M.fold (fun x (kind, level) acc ->
    (level, (x, kind)) :: acc) env.mapping []
  in
  let bindings = List.sort (fun (x, _) (y, _) -> compare x y) bindings in
  List.iter (fun (level, (x, kind)) ->
    match level with
    | Var level ->
        Printf.bprintf buf "  [debug] level=%d, variable=%a, kind=%a\n"
          level
          Variable.p x
          p_kind kind
    | Point _ ->
        Printf.bprintf buf "  [debug] external point, variable=%a, kind=%a\n"
          Variable.p x
          p_kind kind
  ) bindings
;;

module P = struct

  open MzPprint

  let print_field field =
    utf8string (Field.print field)

  let print_fields fields =
    separate_map (comma ^^ space) print_field fields

  let p_fields buf fields =
    Types.TypePrinter.pdoc buf (print_fields, fields)

end

let print_error buf (env, raw_error) =
  let open Types.TypePrinter in
  let bprintf s = Printf.bprintf buf s in
  (* Print the location. *)
  Lexer.p buf env.location;
  (* Print the error message. *)
  begin match raw_error with
  | Unbound x ->
      bprintf
        "Unbound identifier %a"
        Variable.p x
  | Mismatch (expected_kind, inferred_kind) ->
      let inferred, _ = flatten_kind inferred_kind in
      let expected, _ = flatten_kind expected_kind in
      if inferred <> expected then
        bprintf
          "This is a %a but we were expecting a %a"
          p_kind inferred
          p_kind expected
      else
        bprintf
          "This type has kind %a but we were expecting kind %a"
          p_kind inferred_kind
          p_kind expected_kind
  | NotAnArrow (kind) ->
      bprintf
        "Cannot apply arguments to this type since it has kind %a"
        p_kind kind
  | BoundTwice x ->
      bprintf
        "Variable %a is bound twice"
        Variable.p x
  | IllegalConsumes ->
      bprintf
        "Unexpected consumes annotation"
  | BadConditionsInFact x ->
      bprintf
        "The conditions for the fact about %a can only be type variables"
        Variable.p x
  | BadConclusionInFact x ->
      bprintf
        "The conclusion for the fact about %a can only be %a applied to its \
        parameters"
        Variable.p x
        Variable.p x
  | NonDistinctHeadsInFact (x, mode) ->
      bprintf
	"Distinct facts must concern distinct modes.\n\
         In the declaration of %a, two distinct facts concern the mode %s"
	Variable.p x
	(Mode.print mode)
  | DuplicateField d ->
      bprintf
        "The field %a appears several times in this branch"
        Variable.p d
   | DuplicateConstructor d ->
      bprintf
        "The constructor %a appears several times in this data type group"
        Datacon.p d
  | AdopterNotExclusive x ->
      bprintf
        "Type %a carries an adopts clause, but is not marked as mutable"
        Variable.p x
  | UnboundDataConstructor d ->
      bprintf
        "The data constructor %a is not bound to any type"
        Datacon.p d
  | FieldMismatch (datacon, missing, extra) ->
      bprintf
        "This type does not have the fields of data constructor %a"
        Datacon.p datacon;
      if missing <> [] then
	bprintf
	  "\nThe following field%s missing: %a"
	  (if List.length missing > 1 then "s are" else " is")
	  P.p_fields missing;
      if extra <> [] then
	bprintf
	  "\nThe following field%s superfluous: %a"
	  (if List.length extra > 1 then "s are" else " is")
	  P.p_fields extra
  | ImplicationOnlyOnArrow ->
      bprintf
	"Implication => is permitted only on top of a function type."
  end;
  if Log.debug_level () > 4 then
    pkenv buf env;
;;

let unbound env x =
  raise_error env (Unbound x)
;;

let mismatch env expected_kind inferred_kind =
  raise_error env (Mismatch (expected_kind, inferred_kind))
;;

let illegal_consumes env =
  raise_error env IllegalConsumes
;;

let bound_twice env x =
  raise_error env (BoundTwice x)
;;

let bad_condition_in_fact env x =
  raise_error env (BadConditionsInFact x)
;;

let non_distinct_heads_in_fact env x mode =
  raise_error env (NonDistinctHeadsInFact (x, mode))
;;

let bad_conclusion_in_fact env x =
  raise_error env (BadConclusionInFact x)
;;

let duplicate_constructor env d =
  raise_error env (DuplicateConstructor d)
;;

let duplicate_field env f =
  raise_error env (DuplicateField f)
;;


(* ---------------------------------------------------------------------------- *)

(* Kind constructors. *)

let karrow bindings kind =
  List.fold_right (fun (_, kind1) kind2 ->
    KArrow (kind1, kind2)
  ) bindings kind
;;

let deconstruct_arrow env = function
  | KArrow (k1, k2) ->
      k1, k2
  | kind ->
      raise_error env (NotAnArrow kind)
;;


(* ---------------------------------------------------------------------------- *)

(* Working with environments *)

type fragment =
    kind M.t

(* [find x env] looks up the name [x] in the environment [env] and returns a
   pair of a kind and a de Bruijn index (not a de Bruijn level!). *)
let find x env =
  try
    let kind, level = M.find x env.mapping in
    let level =
      match level with
      | Var level ->
          Var (env.level - level - 1)
      | Point _ ->
          level
    in
    kind, level
  with Not_found ->
    unbound env x
;;

(* The strict mode of [bind] is never used, it seems; duplicate names
   are detected using another means. *)

(* [bind env (x, kind)] binds the name [x] with kind [kind]. *)
let bind env (x, kind) : env =
  (* The current level becomes [x]'s level. The current level is
     then incremented. *)
  { env with
    level = env.level + 1;
    mapping = M.add x (kind, Var env.level) env.mapping }
;;

let bind_external env (x, kind, p): env =
  { env with mapping = M.add x (kind, Point p) env.mapping }
;;

let bind_datacon env dc level info =
  { env with known_datacons = (Unqualified dc, InCurrentModule (level, info)) :: env.known_datacons }
;;

let bind_external_datacon env dc point info =
  { env with known_datacons = (Unqualified dc, InAnotherModule (point, info)) :: env.known_datacons }
;;

(* Find in [tsenv.env] all the names exported by module [mname], and add them to our
 * own [tsenv]. *)
let open_module_in (mname: Module.name) (env: env): env =
  (* Import all the names. *)
  let names = T.get_exports env.env mname in
  let _ =
    let names = List.map (fun (x, _, _) -> Variable.print x) names in
    let names = String.concat ", " names in
    Log.debug "Importing module %a into scope, names = %s" Module.p mname names
  in
  let env = List.fold_left bind_external env names in

  (* Now also open the data constructors. *)
  let mname_datacons = MzList.map_some (function
    | Qualified (mname', dc), origin when Module.equal mname mname' ->
        Some (Unqualified dc, origin)
    | _ ->
        None
  ) env.known_datacons in
  (* This is a trick: because we know the data constructors are already present
   * in [known_datacons], but prefixed with their module name, we just re-add
   * them, but with the current module name. *)
  { env with known_datacons = mname_datacons @ env.known_datacons }
;;

let kind_external env mname x =
  let open T in
  try
    let { env; _ } = env in
    let p = point_by_name env ~mname x in
    get_kind env p
  with Not_found ->
    unbound env (Variable.register (Module.print mname ^ "::" ^ Variable.print x))
;;

(* [locate env p] extends [env] with the provided location information. *)
let locate env p : env =
  { env with location = p }
;;

(* [extend env xs] extends the current environment with new bindings; [xs] is
   a fragment, that is, a map of identifiers to kinds. Because an arbitrary
   order is chosen for the bindings, the function returns not only an extended
   environment, but also a list of bindings, which indicates in which order
   the bindings are performed. At the head of the list comes the innermost
   binding. *)
let extend (env : env) (xs : type_binding list) : env =
  List.fold_left (fun env (x, k, _) ->
    bind env (x, k)) env xs
;;

(* [forall bindings ty] builds a series of universal quantifiers.
   The innermost binding comes first in the list [bindings]. *)
let forall bindings ty =
  List.fold_left (fun ty binding ->
    T.TyForall (binding, ty)
  ) ty bindings
;;

(* [exist bindings ty] builds a series of existential quantifiers.
   The innermost binding comes first in the list [bindings]. *)
let exist bindings ty =
  List.fold_left (fun ty binding ->
    T.TyExists (binding, ty)
  ) ty bindings
;;


(* ---------------------------------------------------------------------------- *)

(* Some helper functions for working with [SurfaceSyntax] types. *)

let flatten_tyapp t =
  let rec flatten_tyapp acc = function
    | TyApp (t1, t2) ->
        flatten_tyapp (t2 :: acc) t1
    | TyLocated (t, _) ->
        flatten_tyapp acc t
    | _ as x ->
        x, acc
  in
  flatten_tyapp [] t
;;

(* Yes, this is a bit too abstract and contrived, sorry. I want to
   avoid using generic hashing & equality over an abstract type of
   names. *)

let check_for_duplicate_things
    (compare : 'thing -> 'thing -> int)
    (project : 'a -> 'thing)
    (elements: 'a list)
    (exit: 'thing -> 'b)
    : unit
=
  let compare (x : 'a) (y : 'a) : int =
    compare (project x) (project y)
  in
  match MzList.check_for_duplicates compare elements with
  | None ->
      ()
  | Some (x, _) ->
      exit (project x)

let check_for_duplicate_variables
    (project : 'a -> Variable.name)
    (elements: 'a list)
    (exit: Variable.name -> 'b)
    : unit
=
  check_for_duplicate_things Variable.compare project elements exit

let check_for_duplicate_datacons
    (project : 'a -> Datacon.name)
    (elements: 'a list)
    (exit: Datacon.name -> 'b)
    : unit
=
  check_for_duplicate_things Datacon.compare project elements exit

(* ---------------------------------------------------------------------------- *)

(* The ↑ relation, which we implement as [names]. *)

(* [bv loc accu p] adds to the accumulator [accu] the names bound by the
   pattern [p]. For each name, we add a triple of the name, its kind (which is
   always [KTerm]), and a location. *)

let rec bv loc (accu : type_binding list) (p : pattern) : type_binding list =
  match p with
  | PVar x ->
      (x, KTerm, loc) :: accu
  | PTuple ps ->
      List.fold_left (bv loc) accu ps
  | PConstruct (_, fps) ->
      List.fold_left (fun accu (_, p) ->
	bv loc accu p
      ) accu fps
  | PLocated (p, loc) ->
      bv loc accu p
  | PConstraint (p, _) ->
      bv loc accu p
  | PAs (p, x) ->
      (x, KTerm, loc) :: bv loc accu p
  | PAny ->
      accu

(* [names ty] returns a [fragment] containing all the names that [ty] binds. It
   is up to the [check] function to introduce the binders in scope in the right
   places. The order is not important here, since this will be passed on to the
   [extend] function which will then pick a give order. *)
let names env ty : type_binding list =

  (* First, convert the type [ty] to a pattern, using the function
     [type_to_pattern]. This function is also used by the interpreter
     and compiler, so we should have a unified notion of which names
     are ghost and which names are actually available at runtime. *)

  let p = type_to_pattern ty in

  (* Now, collect the names bound by [p]. *)

  let bindings = bv env.location [] p in

  (* Check that no name is bound twice. *)

  check_for_duplicate_variables
    (fun (x, _, _) -> x)
    bindings
    (fun x -> bound_twice env x);

  (* Return the bindings. *)
  bindings
;;

(* [bindings_data_type_group] returns a list of names that the whole data type
   group binds, with the corresponding kinds. The list is in the same order as
   the data type definitions. *)
let bindings_data_type_group (data_type_group: data_type_def list): (Variable.name * kind) list =
  List.map (function
      | Concrete (_flag, (name, params), _, _) ->
          let params = List.map (fun (_, (x, y, _)) -> x, y) params in
          let k = karrow params KType in
          (name, k)
      | Abstract ((name, params), return_kind, _fact) ->
          let params = List.map (fun (_, (x, y, _)) -> x, y) params in
          let k = karrow params return_kind in
          (name, k))
    data_type_group
;;


(* [bindings_pattern] returns in prefix order the list of names bound in a
   pattern. *)
let bindings_pattern
    (check_for_duplicates: env option) (p: pattern)
    : (Variable.name * kind) list
=
  let loc = (Lexing.dummy_pos, Lexing.dummy_pos) in
  let bindings = bv loc [] p in
  (* Discard the dummy location information, and reverse the list, so it
     appears in left-to-right order (not sure if it's important). *)
  let bindings = List.rev_map (fun (x, kind, _) -> x, kind) bindings in
  (* If requested by the caller, check for duplicates. *)
  match check_for_duplicates with
  | None ->
      bindings
  | Some env ->
      check_for_duplicate_variables (fun (x, _) -> x) bindings (bound_twice env);
    bindings
;;

(* [bindings_patterns] is the same, but applies to a list of patterns.
   The check for duplicates (if performed) applies to all patterns at
   once. *)
let bindings_patterns
    (check_for_duplicates: env option) (ps: pattern list)
    : (Variable.name * kind) list
=
  bindings_pattern check_for_duplicates (PTuple ps)

(* ---------------------------------------------------------------------------- *)

(* The kind-checking functions. *)


(* This just makes sure that the type parameters mentioned in the fact are in
   the list of the original type parameters. *)
let rec check_fact_parameter (env: env) (x: Variable.name) (args: Variable.name list) (t: typ) =
  match t with
  | TyLocated (t, p) ->
      check_fact_parameter (locate env p) x args t
  | TyBound x' ->
      if not (List.exists (Variable.equal x') args) then
        bad_condition_in_fact env x
  | _ ->
      bad_condition_in_fact env x
;;


(* The conclusion of a fact, if any, must be the exact original type applied to
   the exact same arguments. *)
let rec check_fact_conclusion (env: env) (x: Variable.name) (args: Variable.name list) (t: typ) =
  match t with
  | TyLocated (t, p) ->
      check_fact_conclusion (locate env p) x args t
  | _ ->
      match flatten_tyapp t with
      | TyBound x', args' ->
          Log.debug "%a %a" Variable.p x Variable.p x';
          if not (Variable.equal x x') then
            bad_conclusion_in_fact env x;
          if not (List.length args = List.length args') then
            bad_conclusion_in_fact env x;
          List.iter2 (fun x arg' ->
            match arg' with
            | TyBound x'
            | TyLocated (TyBound x', _) ->
                if not (Variable.equal x x') then
                  bad_conclusion_in_fact env x;
            | _ ->
                bad_conclusion_in_fact env x) args args';
      | _ ->
          bad_conclusion_in_fact env x;
;;

let check_distinct_heads env name facts =
  ignore (
    List.fold_left (fun accu (Fact (_, (mode, _))) ->
      if Mode.ModeMap.mem mode accu then
	non_distinct_heads_in_fact env name mode
      else
	Mode.ModeMap.add mode () accu
    ) Mode.ModeMap.empty facts
  )

let rec check (env: env) (t: typ) (expected_kind: kind) =
  let inferred_kind = infer env t in
  if expected_kind <> inferred_kind then
    mismatch env expected_kind inferred_kind

and infer (env: env) (t: typ) =
  match t with
  | TyLocated (t, p) ->
      infer (locate env p) t

  | TyTuple ts ->
      List.iter (fun t -> check env t KType) ts;
      KType

  | TyUnknown
  | TyDynamic ->
      KType

  | TyEmpty ->
      KPerm

  | TyQualified (mname, x) ->
      kind_external env mname x

  | TyBound x ->
      let kind, _index = find x env in
      kind

  | TyConcreteUnfolded branch ->
      check_branch env branch;
      KType

  | TySingleton t ->
      check env t KTerm;
      KType

  | TyApp (t1, t2) ->
      let k, k' = deconstruct_arrow env (infer env t1) in
      check env t2 k;
      k'

  | TyArrow (t1, t2) ->
      let f1 = names env t1 in
      let f2 = names env t2 in
      let env = extend env f1 in
      check env t1 KType;
      let env = extend env f2 in
      check env t2 KType;
      KType

  | TyForall ((x, k, _), t)
  | TyExists ((x, k, _), t) ->
      let env = bind env (x, k) in
      infer env t

  | TyAnchoredPermission (t1, t2) ->
      check env t1 KTerm;
      check env t2 KType;
      KPerm

  | TyStar (t1, t2) ->
      check env t1 KPerm;
      check env t2 KPerm;
      KPerm

  | TyNameIntro (x, t) ->
      ignore (find x env);
      infer env t

  | TyConsumes t ->
      infer env t

  | TyBar (t1, t2) ->
      check env t1 KType;
      check env t2 KPerm;
      KType

  | TyAnd ((_, t), u)
  | TyImply ((_, t), u) ->
      check env t KType;
      infer env u

and check_field (env: env) (field: data_field_def) =
  match field with
  | FieldValue (_name, t) ->
      check_type_with_names env t KType
  | FieldPermission t ->
      (* I have removed the calls to [names] and [extend], because
	 a permission component does not bind any names. -fpottier *)
      check env t KPerm

and check_branch: 'a. env -> ('a * data_field_def list) -> unit = fun env branch ->
  let _, fields = branch in
  let names = MzList.map_some (function
    | FieldValue (name, _) ->
        Some name
    | FieldPermission _ ->
        None
  ) fields in
  check_for_duplicate_variables
    (fun x -> x)
    names
    (duplicate_field env);
  List.iter (check_field env) fields

and check_type_with_names (env: env) (t: typ) (k: kind) =
  let bindings = names env t in
  let env = List.fold_left (fun env (x, k, _) -> bind env (x, k)) env bindings in
  check env t k

;;


(* Check a data type definition. For abstract types, this just checks that the
   fact is well-formed. For concrete types, check that the branches are all
   well-formed. *)
let check_data_type_def (env: env) (def: data_type_def) =
  match def with
  | Abstract ((name, bindings), _return_kind, facts) ->
      (* Get the names of the parameters. *)
      let args = List.map (fun (_, (x, _, _)) -> x) bindings in
      (* Perform a tedious check. *)
      List.iter (function Fact (clauses, conclusion) ->
        List.iter (fun (_, t) -> check_fact_parameter env name args t) clauses;
        let (_, t) = conclusion in check_fact_conclusion env name args t
      ) facts;
      check_distinct_heads env name facts
  | Concrete (flavor, (name, bindings), branches, clause) ->
      let bindings = List.map (fun (_, (x, y, _)) -> x, y) bindings in
      let env = List.fold_left bind env bindings in
      (* Check the branches. *)
      List.iter (check_branch env) branches;
      match clause with
      | None ->
          ()
      | Some t ->
          check_type_with_names env t KType;
          (* We can do that early. *)
	  if not (DataTypeFlavor.can_adopt flavor) then
	    raise_error env (AdopterNotExclusive name)
;;


let check_data_type_group (env: env) (data_type_group: data_type_def list) =
  (* Check that the constructors are unique to this data type group. *)
  let all_branches = MzList.map_flatten (function
    | Abstract _ ->
        []
    | Concrete (_, _, branches, _) ->
        branches
  ) data_type_group in
  check_for_duplicate_datacons
    (fun (datacon, _fields) -> datacon)
    all_branches
    (duplicate_constructor env);

  (* Do the remainder of the checks. *)
  List.iter (check_data_type_def env) data_type_group
;;


let rec check_pattern (env: env) (pattern: pattern) =
  match pattern with
  | PConstraint (p, t) ->
      check_pattern env p;
      Log.debug "check_type_with_names";
      check_type_with_names env t KType
  | PVar x ->
      ignore (find x env)
  | PTuple patterns ->
      List.iter (check_pattern env) patterns
  | PConstruct (_, name_pats) ->
      let _, patterns = List.split name_pats in
      List.iter (check_pattern env) patterns
  | PLocated (p, _) ->
      check_pattern env p
  | PAs (p1, x2) ->
      check_pattern env p1;
      check_pattern env (PVar x2)
  | PAny ->
      ()
;;


let rec check_patexpr (env: env) (flag: rec_flag) (pat_exprs: (pattern * expression) list): env =
  let patterns, expressions = List.split pat_exprs in
  (* Introduce all bindings from the patterns *)
  let bindings = bindings_patterns (Some env) patterns in
  let sub_env = List.fold_left bind env bindings in
  (* Type annotation in patterns may reference names introduced in the entire
   * pattern (same behavior as tuple types). *)
  List.iter (check_pattern sub_env) patterns;
  (* Whether the variables defined in the pattern are available in the
   * expressions depends, of course, on whether this is a recursive binding. *)
  begin match flag with
  | Recursive ->
      List.iter (check_expression sub_env) expressions
  | Nonrecursive ->
      List.iter (check_expression env) expressions
  end;
  (* Return the environment extended with bindings so that we can check whatever
   * comes afterwards. *)
  sub_env


and check_expression (env: env) (expr: expression) =
  match expr with
  | EConstraint (e, t) ->
      check_expression env e;
      check_type_with_names env t KType

  | EVar x ->
      let k, _ = find x env in
      (* TEMPORARY check that only lambda-bound variables can appear in code *)
      if k <> KTerm then
        mismatch env KTerm k

  | EQualified (mname, x) ->
      let k = kind_external env mname x in
      if k <> KTerm then
        mismatch env KTerm k

  | EBuiltin _ ->
      ()

  | ELet (flag, pat_exprs, expr) ->
      let env = check_patexpr env flag pat_exprs in
      check_expression env expr

  | EFun (bindings, arg, return_type, body) ->
      check_for_duplicate_variables Types.fst3 bindings (bound_twice env);
      let bindings = List.map (fun (x, y, _) -> x, y) bindings in
      let env = List.fold_left bind env bindings in
      let arg_bindings = names env arg in
      let env = extend env arg_bindings in
      check env arg KType;
      check_expression env body;
      let return_bindings = names env return_type in
      let env = extend env return_bindings in
      check env return_type KType

  | EAssign (e1, _, e2) ->
      check_expression env e1;
      check_expression env e2

  | EAssignTag (e1, _, _) ->
      check_expression env e1

  | EAccess (e, _) ->
      check_expression env e

  | EAssert t ->
      check env t KPerm

  | EApply (e1, e2) ->
      check_expression env e1;
      check_expression env e2

  | ETApply (e1, _) ->
      (* The kind-checking of [ts] is deferred until we have performed type
       * inference, which will allow [TypeChecker] to tell whether this type
       * application is valid or not. *)
      check_expression env e1

  | EMatch (_, e, pat_exprs) ->
      check_expression env e;
      List.iter (fun (pat, expr) ->
        let bindings = bindings_pattern (Some env) pat in
        let sub_env = List.fold_left bind env bindings in
        check_pattern sub_env pat;
        check_expression sub_env expr
      ) pat_exprs

  | ETuple exprs ->
      List.iter (check_expression env) exprs

  | EConstruct (_, field_exprs) ->
      let _, exprs = List.split field_exprs in
      List.iter (check_expression env) exprs

  | EIfThenElse (_, e1, e2, e3) ->
      check_expression env e1;
      check_expression env e2;
      check_expression env e3

  | ESequence (e1, e2)
  | EGive (e1, e2)
  | ETake (e1, e2)
  | EOwns (e1, e2) ->
      check_expression env e1;
      check_expression env e2

  | ELocated (e, p) ->
      check_expression (locate env p) e

  | EInt _ ->
      ()

  | EExplained e ->
      check_expression env e


  | EFail ->
      ()
;;


(* Because the binding structure of top-level declarations is possibly
 * complicated, because of patterns, this function does both the binding and the
 * checking at the same time (i.e. there's no [bindings_declaration_group]
 * function. However, it returns the environment with all the bindings added. *)
let check_declaration_group (env: env) (declaration_group: declaration list) =
  List.fold_left (fun env -> function
    | DLocated (DMultiple (rec_flag, pat_exprs), p) ->
      let env = locate env p in
      check_patexpr env rec_flag pat_exprs
    | _ ->
        Log.error "Unexpected shape for a [declaration_group]."
  ) env declaration_group
;;

let check_implementation (tenv: T.env) (program: implementation) =
  let env = empty tenv in
  let env = List.fold_left (fun env -> function
    | DataTypeGroup (p, data_type_group) ->
        (* Collect the names from the data type definitions, since they
         * will be made available in both the data type definitions themselves,
         * and the value definitions. All definitions in a data type groupe are
         * mutually recursive. *)
        let bindings = bindings_data_type_group data_type_group in
        check_for_duplicate_variables
	  (fun (x, _) -> x)
	  bindings
	  (fun x -> bound_twice env x);
        (* Create an environment that includes those names. The strict parameter
         * makes sure we don't bind the same name twice. Admittedly, we could do
         * something better for error reporting. *)
        let env = locate env p in
        let env = List.fold_left bind env bindings in
        (* Check the data type definitions in the environment. *)
        check_data_type_group env data_type_group;

        env

    | ValueDeclarations declaration_group ->
        (* This function does everything at once and takes care of both binding
         * the variables and checking the bodies. *)
        check_declaration_group env declaration_group;

    | PermDeclaration (x, t) ->
        check_type_with_names env t KType;
        let env = bind env (x, KTerm) in
        env

    | OpenDirective mname ->
        open_module_in mname env
  ) env program in
  ignore (env);
;;

let check_interface (tenv: T.env) (interface: interface) =
  (* Check for duplicate variables. *)
  let all_bindings = MzList.map_flatten (function
    | DataTypeGroup (_, data_type_group) ->
        bindings_data_type_group data_type_group
    | PermDeclaration (x, _) ->
        [x, KTerm]
    | OpenDirective _ ->
        []
    | ValueDeclarations _ ->
        assert false
  ) interface in
  check_for_duplicate_variables fst all_bindings (bound_twice (empty tenv));

  (* Check for duplicate data constructors. *)
  let all_datacons = MzList.map_flatten (function
    | DataTypeGroup (_, data_type_group) ->
        MzList.map_flatten (function
          | Abstract _ ->
              []
          | Concrete (_, _, branches, _) ->
              branches
        ) data_type_group
    | _ ->
        []
  ) interface in
  check_for_duplicate_datacons fst all_datacons (duplicate_constructor (empty tenv));

  (* Do all the regular checks. *)
  check_implementation tenv interface
;;

(* ---------------------------------------------------------------------------- *)

(* Printers. *)

module KindPrinter = struct

  open MzPprint
  open TypeCore
  open Types
  open TypePrinter

  (* Prints an abstract data type. Very straightforward. *)
  let print_abstract_type_def print_env name kind =
    string "abstract" ^^ space ^^ print_var print_env name ^^ space ^^ colon ^^ space ^^
    print_kind kind
  ;;

  let print_variance = function
    | Invariant ->
        empty
    | Covariant ->
        plus
    | Contravariant ->
        minus
    | Bivariant ->
        equals
  ;;

  (* Prints a data type defined in the global scope. Assumes [print_env] has been
     properly populated. *)
  let print_data_type_def (env: env) name kind variance branches =
    let _return_kind, params = flatten_kind kind in
    (* Turn the list of parameters into letters *)
    let letters: string list = name_gen (List.length params) in
    let letters = List.map2 (fun variance letter ->
      print_variance variance ^^ utf8string letter
    ) variance letters in
    let env, _, branches =
      bind_datacon_parameters env kind branches
    in
    let sep = break 1 ^^ bar ^^ space in
    (* The whole blurb *)
    string "data" ^^ space ^^ lparen ^^
    print_var env name ^^ space ^^ colon ^^ space ^^
    print_kind kind ^^ rparen ^^ concat_map (precede space) letters ^^
    space ^^ equals ^^
    jump
      (ifflat empty (bar ^^ space) ^^
      separate_map sep (print_unresolved_branch env) branches
      )
  ;;

  let print_def env name kind def =
    match def with
    | Some branches, variance ->
        print_data_type_def env name kind variance branches
    | None, _ ->
        print_abstract_type_def env name kind
  ;;

  (* This function prints the contents of a [Types.env]. *)
  let print_kinds env =
    (* Now we have a pretty-printing environment that's ready, proceed. *)
    let defs = fold_definitions env (fun acc var definition ->
      let name = get_name env var in
      let kind = get_kind env var in
      print_def env name kind definition :: acc
    ) [] in
    separate (twice (break 1)) defs
  ;;

  let print_group env (group: data_type_group) =
    let defs = List.map (fun (name, _, def, _, kind) ->
      let name = User (module_name env, name) in
      print_def env name kind def
    ) group in
    nest 2 (separate (twice (break 1)) defs) ^^ hardline
  ;;


  let pgroup buf arg =
    pdoc buf ((fun (env, group) -> print_group env group), arg)
  ;;


  let print_kinds_and_facts program_env =
    colors.red ^^ string "KINDS:" ^^ colors.default ^^
    nest 2 (hardline ^^ print_kinds program_env) ^^ hardline ^^
    hardline ^^
    colors.red ^^ string "FACTS:" ^^ colors.default ^^
    nest 2 (hardline ^^ print_facts program_env) ^^ hardline
  ;;

end
