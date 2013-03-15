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

(* This module defines the syntax of types, as manipulated by the
   type-checker. *)

(* In the surface syntax, variables are named. Here, variables are
   represented as de Bruijn indices. We keep a variable name at each
   binding site as a pretty-printing hint. *)

type db_index =
  int

type point =
  PersistentUnionFind.point

type flex_index =
  int

type kind = SurfaceSyntax.kind = 
  | KTerm
  | KType
  | KPerm
  | KArrow of kind * kind

(** Has this name been auto-generated or not? *)
type name = User of Module.name * Variable.name | Auto of Variable.name

type location = Lexing.position * Lexing.position

type type_binding =
  name * kind * location

type flavor = SurfaceSyntax.binding_flavor = CanInstantiate | CannotInstantiate

module DataconMap = MzMap.Make(struct
  type t = Module.name * Datacon.name
  let compare = Pervasives.compare
end)

(* Record fields remain named. *)

module Field = Variable

type variance = SurfaceSyntax.variance = Invariant | Covariant | Contravariant | Bivariant

type typ =
    (* Special type constants. *)
  | TyUnknown
  | TyDynamic

    (* We adopt a locally nameless style. Local names are [TyBound]s, global
     * names are [TyOpen]. *)
  | TyBound of db_index
  | TyOpen of var

    (* Quantification and type application. *)
  | TyForall of (type_binding * flavor) * typ
  | TyExists of type_binding * typ
  | TyApp of typ * typ list

    (* Structural types. *)
  | TyTuple of typ list
  | TyConcreteUnfolded of resolved_branch

    (* Singleton types. *)
  | TySingleton of typ

    (* Function types. *)
  | TyArrow of typ * typ

    (* The bar *)
  | TyBar of typ * typ

    (* Permissions. *)
  | TyAnchoredPermission of typ * typ
  | TyEmpty
  | TyStar of typ * typ

    (* Constraint *)
  | TyAnd of mode_constraint * typ

and var =
  | VRigid of point
  | VFlexible of flex_index

(* Since data constructors are now properly scoped, they are resolved, that is,
 * they are either attached to a point, or a De Bruijn index, which will later
 * resolve to a point when we open the corresponding type definition. That way,
 * we can easily jump from a data constructor to the corresponding type
 * definition. *)
and resolved_datacon = typ * Datacon.name

and mode_constraint = Mode.mode * typ

and ('flavor, 'datacon) data_type_def_branch = {
  branch_flavor: 'flavor; (* DataTypeFlavor.flavor or unit *)
  branch_datacon: 'datacon; (* Datacon.name or resolved_datacon *)
  branch_fields: data_field_def list;
  (* The type of the adoptees; initially it's bottom and then
   * it gets instantiated to something less precise. *)
  branch_adopts: typ;
}

and resolved_branch =
    (unit, resolved_datacon) data_type_def_branch

and data_field_def =
  | FieldValue of (Field.name * typ)
  | FieldPermission of typ

type unresolved_branch =
    (DataTypeFlavor.flavor, Datacon.name) data_type_def_branch

type data_type_def =
  unresolved_branch list

type type_def =
  (* option here because abstract types do not have a definition *)
    data_type_def option
  * variance list

type data_type_group =
  (Variable.name * location * type_def * Fact.fact * kind) list

(* ---------------------------------------------------------------------------- *)

(* Program-wide environment. *)

type binding_type = Rigid | Flexible

type permissions = typ list

type level = int

(** This is the environment that we use throughout. *)
type env = {
  (* This maps global names (i.e. [TyOpen]s) to their corresponding binding. *)
  state: binding PersistentUnionFind.state;

  (* A mark that is used during various traversals of the [state]. *)
  mark: Mark.t;

  (* The current location. *)
  location: location;

  (* Did we figure out that this environment is inconsistent? It may be because
   * a point acquired two exclusive permissions, or maybe because the user wrote
   * "fail" at some point. This is by no means exhaustive: we only detect a few
   * inconsistencies when we're lucky. *)
  inconsistent: bool;

  (* The name of the current unit. *)
  module_name: Module.name;

  (* This is a list of abstract permissions available in the environment. It can
   * either be a type application, i.e. "p x", where "p" is abstract, or a type
   * variable. They're not attached to any point in particular, so we keep a
   * list of them here. *)
  floating_permissions: typ list;

  (* We need to bump the level when introducing a rigid binding after a flexible
   * one. *)
  last_binding: binding_type;

  (* We also need to store the current level. *)
  current_level: level;

  (* The list of flexible bindings. *)
  flexible: flex_descr list;
}

and flex_descr = {
  (* If a flexible variable is not instanciated, it has a descriptor. When it
   * becomes instantiated, it loses its descriptor and gains the information
   * from another type. We have the invariant that importants properties about
   * the variable (fact, level, kind) are "better" after it lost its descriptor
   * (more precise fact, lower level, equal kind). *)
  structure: structure;
}

and structure = NotInstantiated of var_descr | Instantiated of typ

and binding = var_descr * extra_descr

(** This contains all sorts of useful information about a type variable. *)
and var_descr = {
  (* This information is only for printing and debugging. *)
  names: name list;
  locations: location list;

  (* The kind of this variable. If kind is KTerm, then the [raw_binding] is a
   * [term_binder]. *)
  kind: kind;

  (* For some passes, we need to mark points as visited. This module provides a
   * set of functions to deal with marks. *)
  binding_mark: Mark.t;

  (* Associated fact. A type variable of kind [type] or [perm] has a fact of
     arity 0, that is, just a mode. A type constructor of kind [... -> type]
     or [... -> perm] has a fact of arity greater than 0. A type variable or
     type constructor of kind [term] does not have a fact. *)
  fact: Fact.fact option;

  (* Associated level. *)
  level: level;
}

and extra_descr = DType of type_descr | DTerm of term_descr | DNone

and type_descr = {
  (* This is the descriptor for a data type definition / abstract type
   * definition. *)
  definition: type_def;
}

and term_descr = {
  (* A list of available permissions for that identifier. *)
  permissions: permissions;

  (* A ghost variable has been introduced, say, through [x : term], and does
   * not represent something we can compile.
   *
   * TEMPORARY: as of 2012/07/12 this information is not accurate and one should
   * not rely on it. *)
  ghost: bool;
}

(* This is not pretty, but we need some of these functions for debugging, and
 * the printer is near the end. *)

let internal_ptype: (Buffer.t -> (env * typ) -> unit) ref = ref (fun _ -> assert false);;
let internal_pnames: (Buffer.t -> (env * name list) -> unit) ref = ref (fun _ -> assert false);;
let internal_ppermissions: (Buffer.t -> env -> unit) ref = ref (fun _ -> assert false);;
let internal_pfact: (Buffer.t -> Fact.fact -> unit) ref = ref (fun _ -> assert false);;

(* The empty environment. *)
let empty_env = {
  state = PersistentUnionFind.init ();
  mark = Mark.create ();
  location = Lexing.dummy_pos, Lexing.dummy_pos;
  inconsistent = false;
  module_name = Module.register "<none>";
  floating_permissions = [];
  last_binding = Rigid;
  current_level = 0;
  flexible = [];
}

let locate env location =
  { env with location }
;;

let location { location; _ } = location;;

let is_inconsistent { inconsistent; _ } = inconsistent;;

let mark_inconsistent env = { env with inconsistent = true };;

let module_name { module_name; _ } = module_name;;

let set_module_name env module_name = { env with module_name };;

let valid env = function
  | VFlexible v ->
      v < List.length env.flexible
  | VRigid p ->
      PersistentUnionFind.valid p env.state
;;

let find env p =
  PersistentUnionFind.find p env.state
;;

(* ---------------------------------------------------------------------------- *)

(** Dealing with flexible variables. Flexible variables are not stored in the
 * persistent union-find: they're stored in a separate list. *)

(* Given the index of a flexible variable, find its corresponding descriptor. *)
let find_flex (env: env) (f: flex_index): flex_descr =
  let l = List.length env.flexible in
  List.nth env.flexible (l - f - 1) 
;;

(* Replace the descriptor of a flexible variable with another one. *)
let replace_flex (env: env) (f: flex_index) (d: flex_descr): env =
  let l = List.length env.flexible in
  let flexible = List.mapi (fun i d' -> if i = l - f - 1 then d else d') env.flexible in
  { env with flexible }
;;

exception UnboundPoint

(* Goes through any flexible variables before finding "the real type". *)
let rec modulo_flex_v (env: env) (v: var): typ =
  match v with
  | VRigid _ ->
      if valid env v then
        TyOpen v
      else
        raise UnboundPoint
  | VFlexible f ->
      if valid env v then
        match (find_flex env f).structure with
        | Instantiated (TyOpen v) ->
            modulo_flex_v env v
        | Instantiated t ->
            t
        | NotInstantiated _ ->
            TyOpen v
      else
        raise UnboundPoint
;;

(* Same thing with a type. *)
let modulo_flex (env: env) (t: typ): typ =
  match t with
  | TyOpen v -> modulo_flex_v env v
  | _ -> t
;;

(* Is this variable flexible? (i.e. can I call "instantiate_flexible" on it? *)
let is_flexible (env: env) (v: var): bool =
  match modulo_flex_v env v with
  | TyOpen (VFlexible _) ->
      true
  | _ ->
      false
;;

let is_rigid env v =
  not (is_flexible env v)

(* ---------------------------------------------------------------------------- *)

(** Some functions that operate on variables. *)

let assert_var env v =
  match modulo_flex_v env v with
  | TyOpen v ->
      v
  | v ->
      Log.error "[assert_var] failed (%a is not a var)"
        !internal_ptype (env, v)
;;

let assert_point env v =
  match modulo_flex_v env v with
  | TyOpen (VRigid p) ->
      p
  | v ->
      Log.error "[assert_point] failed (%a is not a point)"
        !internal_ptype (env, v)
;;

let update_extra_descr (env: env) (var: var) (f: extra_descr -> extra_descr): env =
  let point = assert_point env var in
  { env with state =
    PersistentUnionFind.update (fun (var_descr, extra_descr) ->
      var_descr, f extra_descr
    ) point env.state
  }
;;

let get_var_descr (env: env) (v: var): var_descr =
  match assert_var env v with
  | VFlexible f ->
      begin match (find_flex env f).structure with
      | NotInstantiated descr ->
          descr
      | Instantiated _ ->
          assert false
      end
  | VRigid p ->
      let var_descr, _extra_descr = PersistentUnionFind.find p env.state in
      var_descr
;;

let update_var_descr (env: env) (v: var) (f: var_descr -> var_descr): env =
  match assert_var env v with
  | VFlexible i ->
      replace_flex env i (
        match find_flex env i with
        | { structure = NotInstantiated descr } ->
            { structure = NotInstantiated (f descr) }
        | { structure = Instantiated _ } ->
            assert false
      )
  | VRigid p ->
      {
        env with state =
          PersistentUnionFind.update (fun (var_descr, extra_descr) ->
            (f var_descr), extra_descr)
          p
          env.state
      }
;;
 
let initial_permissions_for_point point =
  [ TySingleton (TyOpen (VRigid point)); TyUnknown ]
;;

let get_permissions (env: env) (var: var): permissions =
  let point = assert_point env var in
  match find env point with
  | _, DTerm { permissions; _ } ->
      permissions
  | _ ->
      assert false
;;

let set_permissions (env: env) (var: var) (permissions: typ list): env =
  update_extra_descr env var (function
    | DTerm term ->
        DTerm { term with permissions }
    | _ ->
        Log.error "Not a term"
  )
;;

let reset_permissions (env: env) (var: var): env =
  let point = assert_point env var in
  update_extra_descr env var (function
    | DTerm term ->
        DTerm { term with permissions = initial_permissions_for_point point }
    | _ ->
        Log.error "Not a term"
  )
;;

let get_fact (env: env) (var: var): Fact.fact =
  Option.extract (get_var_descr env var).fact
;;

let get_locations (env: env) (var: var): location list =
  (get_var_descr env var).locations
;;

let add_location (env: env) (var: var) (loc: location): env =
  update_var_descr env var (fun var_descr ->
    { var_descr with locations = loc :: var_descr.locations }
  )
;;

let get_names (env: env) (var: var): name list =
  (get_var_descr env var).names
;;

let get_definition (env: env) (var: var): type_def option =
  match var with
  | VFlexible _ ->
      None
  | VRigid point ->
      match find env point with
      | _, DType { definition; _ } ->
          Some definition
      | _ ->
          None
;;

let update_definition (env: env) (var: var) (f: type_def -> type_def): env =
  update_extra_descr env var (function
    | DType { definition } ->
        DType { definition = f definition }
    | _ ->
        Log.error "Refining the definition of a type that didn't have one in the first place"
  )
;;

let set_definition (env: env) (var: var) (definition: type_def): env =
  update_extra_descr env var (function
    | DNone ->
        DType { definition }
    | _ ->
        Log.error "Setting the definition of a type that had one in the first place"
  )
;;

let get_kind (env: env) (var: var): kind =
  (get_var_descr env var).kind
;;

let set_fact (env: env) (var: var) (fact: Fact.fact): env =
  let fact = Some fact in
  update_var_descr env var (fun d -> { d with fact })
;;

let get_floating_permissions { floating_permissions; _ } =
  floating_permissions
;;

let set_floating_permissions env floating_permissions =
  { env with floating_permissions }
;;

(* ---------------------------------------------------------------------------- *)

(* A visitor for the internal syntax of types. *)

class virtual ['env, 'result] visitor = object (self)

  (* This method, whose default implementation is the identity,
     allows normalizing a type before inspecting its structure.
     This can be used, for instance, to replace flexible variables
     with the type that they stand for. *)
  method normalize (_ : 'env) (ty : typ) =
    ty

  (* This method, whose default implementation is the identity,
     can be used to extend the environment when a binding is
     entered. *)
  method extend (env : 'env) (_ : kind) : 'env =
    env

  (* The main visitor method inspects the structure of [ty] and
     dispatches control to the appropriate case method. *)
  method visit (env : 'env) (ty : typ) : 'result =
    match self#normalize env ty with
    | TyUnknown ->
        self#tyunknown env
    | TyDynamic ->
        self#tydynamic env
    | TyBound i ->
        self#tybound env i
    | TyOpen v ->
        self#tyopen env v
    | TyForall ((binding, flavor), body) ->
        self#tyforall env binding flavor body
    | TyExists (binding, body) ->
        self#tyexists env binding body
    | TyApp (head, args) ->
        self#tyapp env head args
    | TyTuple tys ->
        self#tytuple env tys
    | TyConcreteUnfolded branch ->
        self#tyconcreteunfolded env branch
    | TySingleton x ->
        self#tysingleton env x
    | TyArrow (ty1, ty2) ->
        self#tyarrow env ty1 ty2
    | TyBar (ty1, ty2) ->
        self#tybar env ty1 ty2
    | TyAnchoredPermission (ty1, ty2) ->
        self#tyanchoredpermission env ty1 ty2
    | TyEmpty ->
        self#tyempty env
    | TyStar (ty1, ty2) ->
        self#tystar env ty1 ty2
    | TyAnd (c, ty) ->
        self#tyand env c ty

  (* The case methods have no default implementation. *)
  method virtual tyunknown: 'env -> 'result
  method virtual tydynamic: 'env -> 'result
  method virtual tybound: 'env -> db_index -> 'result
  method virtual tyopen: 'env -> var -> 'result
  method virtual tyforall: 'env -> type_binding -> flavor -> typ -> 'result
  method virtual tyexists: 'env -> type_binding -> typ -> 'result
  method virtual tyapp: 'env -> typ -> typ list -> 'result
  method virtual tytuple: 'env -> typ list -> 'result
  method virtual tyconcreteunfolded: 'env -> resolved_branch -> 'result
  method virtual tysingleton: 'env -> typ -> 'result
  method virtual tyarrow: 'env -> typ -> typ -> 'result
  method virtual tybar: 'env -> typ -> typ -> 'result
  method virtual tyanchoredpermission: 'env -> typ -> typ -> 'result
  method virtual tyempty: 'env -> 'result
  method virtual tystar: 'env -> typ -> typ -> 'result
  method virtual tyand: 'env -> mode_constraint -> typ -> 'result

end

(* ---------------------------------------------------------------------------- *)

(* A [map] specialization of the visitor. *)

class ['env] map = object (self)

  inherit ['env, typ] visitor

  (* The case methods are defined by default as the identity, up to
     a recursive traversal. *)

  method tyunknown _env =
    TyUnknown

  method tydynamic _env =
    TyDynamic

  method tybound _env i =
    TyBound i

  method tyopen _env v =
    TyOpen v

  method tyforall env binding flavor body =
    let _, kind, _ = binding in
    TyForall ((binding, flavor), self#visit (self#extend env kind) body)

  method tyexists env binding body =
    let _, kind, _ = binding in
    TyExists (binding, self#visit (self#extend env kind) body)

  method tyapp env head args =
    TyApp (self#visit env head, self#visit_many env args)

  method tytuple env tys =
    TyTuple (self#visit_many env tys)

  method tyconcreteunfolded env branch =
    TyConcreteUnfolded (self#resolved_branch env branch)

  method tysingleton env x =
    TySingleton (self#visit env x)

  method tyarrow env ty1 ty2 =
    TyArrow (self#visit env ty1, self#visit env ty2)

  method tybar env ty1 ty2 =
    TyBar (self#visit env ty1, self#visit env ty2)

  method tyanchoredpermission env ty1 ty2 =
    TyAnchoredPermission (self#visit env ty1, self#visit env ty2)

  method tyempty _env =
    TyEmpty

  method tystar env ty1 ty2 =
    TyStar (self#visit env ty1, self#visit env ty2)

  method tyand env c ty =
    TyAnd (self#mode_constraint env c, self#visit env ty)

  (* An auxiliary method for transforming a list of types. *)
  method private visit_many env tys =
    List.map (self#visit env) tys

  (* An auxiliary method for transforming a resolved branch. *)
  method resolved_branch env (branch : resolved_branch) =
    { 
      branch_flavor = branch.branch_flavor;
      branch_datacon = self#resolved_datacon env branch.branch_datacon;
      branch_fields = List.map (self#field env) branch.branch_fields;
      branch_adopts = self#visit env branch.branch_adopts;
    }

  (* An auxiliary method for transforming a resolved data constructor. *)
  method resolved_datacon env (ty, dc) =
    self#visit env ty, dc

  (* An auxiliary method for transforming a field. *)
  method field env = function
    | FieldValue (field, ty) ->
        FieldValue (field, self#visit env ty)
    | FieldPermission p ->
        FieldPermission (self#visit env p)

  (* An auxiliary method for transforming a mode constraint. *)
  method private mode_constraint env (mode, ty) =
    (mode, self#visit env ty)

  (* An auxiliary method for transforming an unresolved branch. *)
  method unresolved_branch env (branch : unresolved_branch) =
    { 
      branch_flavor = branch.branch_flavor;
      branch_datacon = branch.branch_datacon;
      branch_fields = List.map (self#field env) branch.branch_fields;
      branch_adopts = self#visit env branch.branch_adopts;
    }

  (* An auxiliary method for transforming a data type group. *)
  method data_type_group env (group : data_type_group) =
    List.map (function element ->
      let name, loc, def, fact, kind = element in
      match def with
      | None, _ ->
          (* This is an abstract type. There are no branches. *)
          element
      | Some branches, variance ->
	  (* Enter the bindings for the type parameters. *)
	  let _, kinds = SurfaceSyntax.flatten_kind kind in
	  let env = List.fold_left self#extend env (List.rev kinds) in
	    (* TEMPORARY not sure about [kinds] versus [List.rev kinds] *)
	  (* Transform the branches in this extended environment. *)
	  let branches = List.map (self#unresolved_branch env) branches in
	  (* That's it. *)
	  let def = Some branches, variance in
          name, loc, def, fact, kind
    ) group

end

(* ---------------------------------------------------------------------------- *)

(* An [iter] specialization of the visitor. *)

class ['env] iter = object (self)

  inherit ['env, unit] visitor

  (* The case methods are defined by default as a recursive traversal. *)

  method tyunknown _env =
    ()

  method tydynamic _env =
    ()

  method tybound _env _i =
    ()

  method tyopen _env _v =
    ()

  method tyforall env binding _flavor body =
    let _, kind, _ = binding in
    self#visit (self#extend env kind) body

  method tyexists env binding body =
    let _, kind, _ = binding in
    self#visit (self#extend env kind) body

  method tyapp env head args =
    self#visit env head;
    self#visit_many env args

  method tytuple env tys =
    self#visit_many env tys

  method tyconcreteunfolded env branch =
    self#resolved_branch env branch

  method tysingleton env x =
    self#visit env x

  method tyarrow env ty1 ty2 =
    self#visit env ty1;
    self#visit env ty2

  method tybar env ty1 ty2 =
    self#visit env ty1;
    self#visit env ty2

  method tyanchoredpermission env ty1 ty2 =
    self#visit env ty1;
    self#visit env ty2

  method tyempty _env =
    ()

  method tystar env ty1 ty2 =
    self#visit env ty1;
    self#visit env ty2

  method tyand env c ty =
    self#mode_constraint env c;
    self#visit env ty

  (* An auxiliary method for visiting a list of types. *)
  method private visit_many env tys =
    List.iter (self#visit env) tys

  (* An auxiliary method for visiting a resolved branch. *)
  method resolved_branch env (branch : resolved_branch) =
    self#resolved_datacon env branch.branch_datacon;
    List.iter (self#field env) branch.branch_fields;
    self#visit env branch.branch_adopts

  (* An auxiliary method for visiting a resolved data constructor. *)
  method resolved_datacon env (ty, _dc) =
    self#visit env ty

  (* An auxiliary method for visiting a field. *)
  method field env = function
    | FieldValue (_, ty) ->
        self#visit env ty
    | FieldPermission p ->
        self#visit env p

  (* An auxiliary method for visiting a mode constraint. *)
  method private mode_constraint env (_, ty) =
    self#visit env ty

  (* An auxiliary method for visiting an unresolved branch. *)
  method unresolved_branch env (branch : unresolved_branch) =
    List.iter (self#field env) branch.branch_fields;
    self#visit env branch.branch_adopts

  (* An auxiliary method for visiting a data type group. *)
  method data_type_group env (group : data_type_group) =
    List.iter (function element ->
      let _, _, def, _, kind = element in
      match def with
      | None, _ ->
          (* This is an abstract type. There are no branches. *)
          ()
      | Some branches, _variance ->
	  (* Enter the bindings for the type parameters. *)
	  let _, kinds = SurfaceSyntax.flatten_kind kind in
	  let env = List.fold_left self#extend env (List.rev kinds) in
	    (* TEMPORARY not sure about [kinds] versus [List.rev kinds] *)
	  (* Visit the branches in this extended environment. *)
	  List.iter (self#unresolved_branch env) branches
    ) group

end

(* ---------------------------------------------------------------------------- *)

(* Dealing with levels... *)

let level (env : env) (ty : typ) : level =
  let max_level = ref 0 in
  (object
    inherit [unit] iter
    method normalize () ty =
      modulo_flex env ty
    method tyopen () v =
      max_level := max !max_level (get_var_descr env v).level
  end) # visit () ty;
  !max_level

let clean (top : env) (sub : env) : typ -> typ =
  (object (self)
    inherit [unit] map
    method tyopen () v =
      (* Resolve flexible variables with respect to [sub]. *)
      let ty = modulo_flex_v sub v in
      match ty with
      | TyOpen p ->
	  (* A (rigid or flexible) variable is allowed to escape only
	     if it makes sense in the environment [top]. *)
          if valid top p then ty else raise UnboundPoint
      | _ ->
          self#visit () ty
  end) # visit ()

(* ---------------------------------------------------------------------------- *)

(* Instantiate a flexible variable with a given type. *)
let instantiate_flexible (env: env) (v: var) (t: typ): env option =
  Log.check (is_flexible env v) "[instantiate_flex] wants flexible";
  
  (* Rework [t] so that this instantiation is legal. *)
  let l = (get_var_descr env v).level in
  let l_t = level env t in
  if l_t <= l then begin
    Log.debug "%sInstantiating%s flexible #%d a.k.a. %a (level=%d) with %a (level=%d)"
      Bash.colors.Bash.red Bash.colors.Bash.default
      (match v with VFlexible i -> i | _ -> assert false)
      !internal_pnames (env, get_names env v)
      l
      !internal_ptype (env, t)
      l_t;

    begin match modulo_flex_v env v with
    | TyOpen (VFlexible f) ->
        Some (replace_flex env f { structure = Instantiated t })
    | _ ->
        assert false
    end

  end else begin
    Log.debug "%s!! NOT instantiating !!%s\n  \
        level(%a) = %d\n  \
        level(%a) = %d"
      Bash.colors.Bash.red
      Bash.colors.Bash.default
      !internal_ptype (env, TyOpen v)
      l
      !internal_ptype (env, t)
      (level env t);
    None
  end
;;

(* ---------------------------------------------------------------------------- *)

(** Some functions related to the manipulation of the union-find structure of
 * the environment. *)

module VarMap = MzMap.Make(struct
  type t = var
  let compare x y =
    match x, y with
    | VRigid x, VRigid y ->
        PersistentUnionFind.compare x y
    | _ ->
        Log.error "[VarMap] used in the presence of flexible variables"
end)

module IVarMap = struct
  type key = var
  type 'data t = 'data VarMap.t ref
  let create () = ref VarMap.empty
  let clear m = m := VarMap.empty
  let add k v m = m := (VarMap.add k v !m)
  let find k m = VarMap.find k !m
  let iter f m = VarMap.iter f !m
end

(* Dealing with the union-find nature of the environment. *)
let same env v1 v2 =
  match assert_var env v1, assert_var env v2 with
  | VRigid p1, VRigid p2 ->
      PersistentUnionFind.same p1 p2 env.state
  | VFlexible f1, VFlexible f2 ->
      f1 = f2
  | _ ->
      false
;;

let names_equal n1 n2 =
  match n1, n2 with
  | Auto n1, Auto n2 when Variable.equal n1 n2 ->
      true
  | User (m1, n1), User (m2, n2) when Variable.equal n1 n2 && Module.equal m1 m2 ->
      true
  | _ ->
      false
;;

(* Merge while keeping the descriptor of the leftmost argument. *)
let merge_left_p2p env p2 p1 =
 (* All this work is just to make sure we keep the names, positions... from
   * both sides. *)
  let state = env.state in
  let { names = names; locations = locations; _ }, _b1 =
    PersistentUnionFind.find p1 state
  in
  let { names = names'; locations = locations'; _ }, _b2 =
    PersistentUnionFind.find p2 state
  in
  let names' = List.filter (fun x -> not (List.exists (names_equal x) names)) names' in
  let names = names @ names' in
  let locations' = List.filter (fun x -> not (List.exists ((=) x) locations)) locations' in
  let locations = locations @ locations' in

  (* It is up to the caller to move the permissions if needed... *)
  let state = PersistentUnionFind.update (fun (head, raw) ->
    { head with names; locations }, raw) p2 state
  in
  (* If we don't want to be fancy, the line below is enough. It keeps [p2]. *)
  let env = { env with state = PersistentUnionFind.union p1 p2 state } in
  env
;;

let merge_left env v1 v2 =
  let v1 = assert_var env v1 in
  let v2 = assert_var env v2 in

  (* Sanity check. *)
  Log.check (get_kind env v1 = get_kind env v2) "Kind mismatch when merging";

  (* Debug *)
  let open Bash in
  let l1 = (get_var_descr env v1).level in
  let l2 = (get_var_descr env v2).level in
  Log.debug ~level:5 "%sMerging%s %a (level=%d) with %a (level=%d)"
    colors.red colors.default
    !internal_pnames (env, get_names env v1) l1
    !internal_pnames (env, get_names env v2) l2;
  if get_kind env v1 = KType then
    Log.debug ~level:6 "→ facts: merging %a into %a"
      !internal_pfact (get_fact env v1)
      !internal_pfact (get_fact env v2);

 
  match v1, v2 with
  | VRigid p1, VRigid p2 ->
      Some (merge_left_p2p env p1 p2)
  | (VRigid _ as v), (VFlexible _ as vf)
  | (VFlexible _ as vf), (VRigid _ as v) ->
      instantiate_flexible env vf (TyOpen v)
  | VFlexible i, VFlexible j ->
      if i < j then
        instantiate_flexible env v2 (TyOpen v1)
      else
        instantiate_flexible env v1 (TyOpen v2)
;;


(* ---------------------------------------------------------------------------- *)

let internal_pflex buf (env, i, f) =
  Printf.bprintf buf "Flexible #%d is " i;
  match f.structure with
  | Instantiated t ->
      Printf.bprintf buf "instantiated with %a\n"
        !internal_ptype (env, t);
  | NotInstantiated { level; _ } ->
      Printf.bprintf buf "not instantiated, level=%d\n" level;
;;

let internal_pflexlist buf env =
  Printf.bprintf buf "env.current_level = %d\n" env.current_level;
  let l = List.length env.flexible in
  List.iteri (fun i flex ->
    internal_pflex buf (env, l - i - 1, flex)
  ) env.flexible
;;


let import_flex_instanciations env sub_env =
  Log.debug ~level:6 "%a" internal_pflexlist sub_env;
  let rec chop_n_first n l =
    if n = 0 then
      l
    else
      chop_n_first (n - 1) (List.tl l)
  in
  let diff = List.length sub_env.flexible - List.length env.flexible in 
  let flexible = chop_n_first diff sub_env.flexible in
  let flexible = List.map (function
    | { structure = Instantiated t } ->
        let t = clean env sub_env t in
        { structure = Instantiated t }
    | _ as flex_descr ->
        flex_descr
  ) flexible in
  let floating_permissions = List.map (clean env sub_env) env.floating_permissions in
  let env = { env with flexible; floating_permissions } in
  Log.debug ~level:6 "%a" internal_pflexlist env;
  env
;;


let rec resolved_datacons_equal env (t1, dc1) (t2, dc2) =
  equal env t1 t2 && Datacon.equal dc1 dc2

(* [equal env t1 t2] provides an equality relation between [t1] and [t2] modulo
 * equivalence in the [PersistentUnionFind]. *)
and equal env (t1: typ) (t2: typ) =
  let rec equal (t1: typ) (t2: typ) =
    match modulo_flex env t1, modulo_flex env t2 with
      (* Special type constants. *)
    | TyUnknown, TyUnknown
    | TyDynamic, TyDynamic ->
        true

    | TyBound i, TyBound i' ->
        i = i'

    | TyOpen p1, TyOpen p2 ->
        if not (valid env p1) || not (valid env p2) then
          raise UnboundPoint;

        same env p1 p2

    | TyExists ((_, k1, _), t1), TyExists ((_, k2, _), t2)
    | TyForall (((_, k1, _), _), t1), TyForall (((_, k2, _), _), t2) ->
        k1 = k2 && equal t1 t2

    | TyArrow (t1, t'1), TyArrow (t2, t'2)
    | TyBar (t1, t'1), TyBar (t2, t'2) ->
        equal t1 t2 && equal t'1 t'2

    | TyApp (t1, t'1), TyApp (t2, t'2)  ->
        equal t1 t2 && List.for_all2 equal t'1 t'2

    | TyTuple ts1, TyTuple ts2 ->
        List.length ts1 = List.length ts2 && List.for_all2 equal ts1 ts2

    | TyConcreteUnfolded branch1, TyConcreteUnfolded branch2 ->
        resolved_datacons_equal env branch1.branch_datacon branch2.branch_datacon &&
	(* In principle, if the data constructors are equal, then the flavors
	   should be equal too (we do not allow the flavor to change independently
	   of the data constructor), and the lists of fields should have the same
	   lengths (the list of fields is determined by the data constructor). *)
	(
	  assert (branch1.branch_flavor = branch2.branch_flavor);
          assert (List.length branch1.branch_fields = List.length branch2.branch_fields);
          equal branch1.branch_adopts branch2.branch_adopts &&
	  List.fold_left2 (fun acc f1 f2 ->
	    match f1, f2 with
	    | FieldValue (f1, t1), FieldValue (f2, t2) ->
		acc && Field.equal f1 f2 && equal t1 t2
	    | FieldPermission t1, FieldPermission t2 ->
		acc && equal t1 t2
	    | _ ->
		false) true branch1.branch_fields branch2.branch_fields
	)

    | TySingleton t1, TySingleton t2 ->
        equal t1 t2


    | TyStar (p1, q1), TyStar (p2, q2)
    | TyAnchoredPermission (p1, q1), TyAnchoredPermission (p2, q2) ->
        equal p1 p2 && equal q1 q2

    | TyEmpty, TyEmpty ->
        true

    | TyAnd ((m1, t1), u1), TyAnd ((m2, t2), u2) ->
        Mode.equal m1 m2 &&
        equal t1 t2 &&
        equal u1 u2

    | _ ->
        false
  in
  equal t1 t2
;;



(* ---------------------------------------------------------------------------- *)

(* Binding, finding, iterating. *)

let mkdescr env name kind location fact =
  let var_descr = {
    names = [name];
    locations = [location];
    kind;
    fact;
    binding_mark = Mark.create ();
    level = env.current_level;
  } in
  var_descr
;;

let top_fact =
  Some (Fact.constant Mode.top)

let mkfact k =
  match k with
  | KTerm ->
      None
  | _ ->
      top_fact
;;

let bind_rigid env (name, kind, location) =
  (* Deal with levels. *)
  let env =
    match env.last_binding with
    | Flexible ->
        { env with current_level = env.current_level + 1; last_binding = Rigid }
    | Rigid ->
        env
  in

  (* Prepare the descriptor. *)
  let var_descr = mkdescr env name kind location (mkfact kind) in
  let descr = var_descr, DNone in

  (* Register the descriptors in the union-find, update the list of permissions
   * if needed. *)
  let point, state = PersistentUnionFind.create descr env.state in
  let extra_descr =
    match kind with
    | KTerm ->
        DTerm { permissions = initial_permissions_for_point point; ghost = false }
    | _ ->
        DNone
  in
  let state = PersistentUnionFind.update (fun _ -> var_descr, extra_descr) point state in

  { env with state }, VRigid point
;;


let bind_flexible env (name, kind, location) =
  Log.debug ~level:6 "Binding flexible #%d (%a) @ level %d"
    (List.length env.flexible)
    !internal_pnames (env, [name])
    env.current_level;

  (* Deal with levels. No need to bump the level here. *)
  let env = { env with last_binding = Flexible } in

  (* Create the descriptor *)
  let var_descr = mkdescr env name kind location (mkfact kind) in

  (* Our (future) index in the list *)
  let f = List.length env.flexible in

  (* Create the flexible descriptor, add it to our list of flexible variables. *)
  let flex_descr = { structure = NotInstantiated var_descr } in
  let env = { env with flexible = flex_descr :: env.flexible } in

  env, VFlexible f
;;


(* ---------------------------------------------------------------------------- *)

(* Iterating on rigid variables. *)

let internal_fold env f acc =
  PersistentUnionFind.fold (fun acc k v ->
    f acc k v)
  acc env.state
;;

let fold env f acc =
  PersistentUnionFind.fold
    (fun acc point _ -> f acc (VRigid point))
    acc
    env.state
;;

let fold_terms env f acc =
  PersistentUnionFind.fold (fun acc point (_, extra_descr) ->
    match extra_descr with DTerm { permissions; _ } -> f acc (VRigid point) permissions | _ -> acc)
  acc env.state
;;

let fold_definitions env f acc =
  PersistentUnionFind.fold (fun acc point (_, extra_descr) ->
    match extra_descr with DType { definition } -> f acc (VRigid point) definition | _ -> acc)
  acc env.state
;;

let map env f =
  fold env (fun acc var -> f var :: acc) []
;;

(* ---------------------------------------------------------------------------- *)

(* Interface-related functions. *)

(* Get all the names from module [mname] found in [env]. *)
let get_exports env mname =
  let assoc =
    internal_fold env (fun acc point ({ names; kind; _ }, _) ->
      let canonical_names = MzList.map_some (function
        | User (m, x) when Module.equal m mname ->
            Some (x, kind)
        | _ ->
            None
      ) names in
      List.map (fun (x, k) -> x, k, VRigid point) canonical_names :: acc
    ) []
  in
  List.flatten assoc
;;

let point_by_name (env: env) ?(mname: Module.name option) (name: Variable.name): var =
  let mname = Option.map_none env.module_name mname in
  let module T = struct exception Found of point end in
  try
    internal_fold env (fun () point ({ names; _ }, _binding) ->
      if List.exists (names_equal (User (mname, name))) names then
        raise (T.Found point)) ();
    raise Not_found
  with T.Found point ->
    VRigid point
;;

(* ---------------------------------------------------------------------------- *)

(* Dealing with marks. *)

let is_marked (env: env) (var: var): bool =
  let { binding_mark; _ } = get_var_descr env var in
  Mark.equals binding_mark env.mark
;;

let mark (env: env) (var: var): env =
  update_var_descr env var (fun descr -> { descr with binding_mark = env.mark })
;;

let refresh_mark (env: env): env =
  { env with mark = Mark.create () }
;;

(* ---------------------------------------------------------------------------- *)

let internal_uniqvarid env = function
  | VFlexible i ->
      i lsl 16
  | VRigid point ->
      let p = PersistentUnionFind.repr point env.state in
      (Obj.magic p: int)
;;

let internal_checklevel env t =
  let l = level env t in
  Log.check (l <= env.current_level)
    "%a inconsistency detected: type %a has level %d, but env has level %d\n"
    Lexer.p (location env)
    !internal_ptype (env, t)
    l
    env.current_level;
;;

let internal_wasflexible = function
  | VFlexible _  -> true
  | VRigid _ -> false
;;
