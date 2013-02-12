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

(** This module provides a variety of functions for dealing with types, mostly
 * built on top of {!DeBruijn} and {!TypeCore}. *)

open TypeCore


(* -------------------------------------------------------------------------- *)

(** {1 Convenient combinators.} *)

(** {2 Dealing with triples.} *)

val fst3 : 'a * 'b * 'c -> 'a
val snd3 : 'a * 'b * 'c -> 'b
val thd3 : 'a * 'b * 'c -> 'c

(** {2 Operators} *)

(** Asserts that this type is actually a [TyOpen]. *)
val ( !! ) : typ -> var

(** Asserts that this type is actually a [TySingleton (TyOpen ...)]. *)
val ( !!= ) : typ -> var

(** This is {!Lazy.force}. *)
val ( !* ) : 'a Lazy.t -> 'a

(** [bind] for the option monad. *)
val ( >>= ) : 'a option -> ('a -> 'b option) -> 'b option

(** [either] operator for the option monad *)
val ( ||| ) : 'a option -> 'a option -> 'a option

(** The standard implication connector, with the right associativity. *)
val ( ^=> ) : bool -> bool -> bool


(* -------------------------------------------------------------------------- *)

(** {1 Manipulating types.} *)

(** {2 Building types.} *)

val ty_unit : typ
val ty_tuple : typ list -> typ
val ty_bottom : typ
val ( @-> ) : typ -> typ -> typ
val ty_bar : typ -> typ -> typ
val ty_app : typ -> typ list -> typ
val ty_equals : var -> typ

(** {2 Binding types} *)

val bind_rigid_in_type :
  env ->
  type_binding ->
  typ -> env * typ * var
val bind_flexible_in_type :
  env ->
  type_binding ->
  typ -> env * typ * var
val bind_datacon_parameters :
  env ->
  kind ->
  data_type_def_branch list ->
  adopts_clause ->
  env * var list * data_type_def_branch list *
  adopts_clause

(** {2 Instantiation} *)

val instantiate_adopts_clause :
  typ option -> typ list -> typ
val instantiate_branch:
  'a * data_field_def list ->
  typ list ->
  'a * data_field_def list
val find_and_instantiate_branch :
  env ->
  var ->
  Datacon.name ->
  typ list ->
  (typ * Datacon.name) * data_field_def list * typ


(** {2 Folding and unfolding} *)

val flatten_kind :
  SurfaceSyntax.kind -> SurfaceSyntax.kind * SurfaceSyntax.kind list
val flatten_star : env -> typ -> typ list
val fold_star : typ list -> typ
val strip_forall :
  typ ->
  (type_binding * flavor) list * typ
val fold_forall :
  (type_binding * flavor) list ->
  typ -> typ
val fold_exists : type_binding list -> typ -> typ
val expand_if_one_branch : env -> typ -> typ


(* -------------------------------------------------------------------------- *)

(** {1 Dealing with variables} *)

(** {2 Various getters} *)

val get_name : env -> var -> name
val get_location : env -> var -> location
val get_adopts_clause :
  env -> var -> adopts_clause
val get_branches :
  env -> var -> data_type_def_branch list
val get_arity : env -> var -> int
val get_kind_for_type : env -> typ -> kind
val get_variance : env -> var -> variance list
val def_for_datacon :
  env ->
  resolved_datacon ->
  SurfaceSyntax.data_type_flag * data_type_def *
  adopts_clause

(** Get the variance of the i-th parameter of a data type. *)
val variance : env -> var -> int -> variance

(** {2 Inspecting} *)
val is_tyapp : typ -> (var * typ list) option
val is_term : env -> var -> bool
val is_type : env -> var -> bool
val is_user : name -> bool


(* -------------------------------------------------------------------------- *)

(** {1 Dealing with facts} *)

val fact_leq : fact -> fact -> bool
val fact_of_flag : SurfaceSyntax.data_type_flag -> fact


(* -------------------------------------------------------------------------- *)

(** {1 Miscellaneous} *)

val fresh_auto_var : string -> name
val find_type_by_name :
  env -> ?mname:string -> string -> typ
val make_datacon_letters :
  env ->
  SurfaceSyntax.kind ->
  bool -> (int -> fact) -> env * var list

(** Our not-so-pretty printer for types. *)
module TypePrinter :
  sig
    val pdoc : Buffer.t -> ('env -> Hml_Pprint.document) * 'env -> unit
    val print_var : env -> name -> Hml_Pprint.document
    val pvar : Buffer.t -> env * name -> unit
    val print_datacon : Datacon.name -> Hml_Pprint.document
    val print_field_name : Field.name -> Hml_Pprint.document
    val print_field : SurfaceSyntax.field -> Hml_Pprint.document
    val print_kind : SurfaceSyntax.kind -> Hml_Pprint.document
    val p_kind : Buffer.t -> SurfaceSyntax.kind -> unit
    val print_names :
      env -> name list -> Hml_Pprint.document
    val pnames : Buffer.t -> env * name list -> unit
    val pname : Buffer.t -> env * var -> unit
    val print_exports : env * Module.name -> PPrintEngine.document
    val pexports : Buffer.t -> env * Module.name -> unit
    val print_quantified :
      env ->
      string ->
      name -> kind -> typ -> Hml_Pprint.document
    val print_point : env -> var -> Hml_Pprint.document
    val print_type : env -> typ -> Hml_Pprint.document
    val print_constraints :
      env ->
      duplicity_constraint list -> Hml_Pprint.document
    val print_data_field_def :
      env -> data_field_def -> Hml_Pprint.document
    val print_data_type_def_branch :
      env ->
      Datacon.name ->
      data_field_def list -> typ -> Hml_Pprint.document
    val print_data_type_flag :
      SurfaceSyntax.data_type_flag -> Hml_Pprint.document
    val print_fact : fact -> Hml_Pprint.document
    val pfact : Buffer.t -> fact -> unit
    val print_facts : env -> Hml_Pprint.document
    val print_permission_list :
      env * typ list -> Hml_Pprint.document
    val ppermission_list : Buffer.t -> env * var -> unit
    val print_permissions : env -> Hml_Pprint.document
    val ppermissions : Buffer.t -> env -> unit
    val ptype : Buffer.t -> env * typ -> unit
    val penv : Buffer.t -> env -> unit
    val pconstraints :
      Buffer.t -> env * duplicity_constraint list -> unit
    val print_binders : env -> Hml_Pprint.document
  end