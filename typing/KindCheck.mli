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

(** This module implements a well-kindedness check for the types of the surface
   language. It also offers the necessary building blocks for resolving names
   (i.e. determining which definition each variable and data constructor refers
   to) and translating types and expressions down to the internal syntax. *)

open Kind
open SurfaceSyntax

(* ---------------------------------------------------------------------------- *)

(** An environment maintains a mapping of external variable names to internal
   objects, represented by the type [var]. A [var] is either a local name,
   represented as de Bruijn index, or a non-local name, represented in some
   other way. Typically, when checking a compilation unit, the names defined
   within this compilation unit are translated to local names, whereas the
   names defined in other units that this unit depends on are translated to
   non-local names. *)
type 'v var =
       Local of int
  | NonLocal of 'v

type 'v env

(* ---------------------------------------------------------------------------- *)

(** {1 Errors.} *)

(** A [KindError] exception carries a function that displays an error message. *)
exception KindError of (Buffer.t -> unit -> unit)

(** This error is detected during the translation towards the internal syntax. *)
val implication_only_on_arrow: 'v env -> 'a

(* ---------------------------------------------------------------------------- *)

(** {1 Building environments.} *)

(** An empty environment. *)
val empty: Module.name -> 'v env

(* ---------------------------------------------------------------------------- *)

(** {1 Extracting information out of an environment.} *)

(** [module_name env] is the name of the current module. *)
val module_name: 'v env -> Module.name

(** [location env] is the current location in the source code. *)
val location: 'v env -> location

(** [find_variable env x] looks up the possibly-qualified variable [x]
    in the environment [env]. *)
val find_variable: 'v env -> Variable.name maybe_qualified -> 'v var

(** [find_kind env x] returns the kind of the possibly-qualified
    variable [x]. *)
val find_kind: 'v env -> Variable.name maybe_qualified -> kind

(** [find_nonlocal_variable env x] looks up the unqualified variable [x]
    in the environment [env]. The result is expected to be a [NonLocal]
    variable, and this injection is stripped off. If the variable is not
    found, the error message indicates that [x] is not defined in an
    implementation file, whereas its existence is advertised in the
    corresponding interface file. *)
val find_nonlocal_variable: 'v env -> Variable.name -> 'v

(** [resolve_datacon env dref] looks up the possibly-qualified data constructor
    [dref.datacon_unresolved] in the environment [env]. It updates [dref] in
    place with a [datacon_info] component. It returns a triple of the type with
    which this data constructor is associated, the unqualified name of this
    data constructor, and its flavor. *)
val resolve_datacon: 'v env -> datacon_reference -> 'v var * Datacon.name * DataTypeFlavor.flavor

(** [get_exports env] returns the list of names that are exported by [env].
 * Calling this function only makes sense after type-checking took place. *)
val get_exports: 'v env -> (Variable.name * 'v) list

(* ---------------------------------------------------------------------------- *)

(** {1 Extending an environment.} *)

(** [locate env loc] updates [env] with the location [loc]. *)
val locate: 'v env -> location -> 'v env

(** [enter_module env m] resets [env] so that it is ready to translate another
 * unit (interface or implementation) named [m]. *)
val enter_module: 'v env -> Module.name -> 'v env

(** [extend env bindings] iterates over the list [bindings], from left to
    right, and for each binding of the form [(x, kind, loc)], it extends
    the environment by binding the unqualified variable [x] to a new local
    name whose kind is [kind]. *)
val extend: 'v env -> type_binding list -> 'v env

(** [bind_nonlocal env (x, kind, v)] binds the unqualified variable [x] to the
    non-local name [v], whose kind is [kind]. *)
val bind_nonlocal: 'v env -> Variable.name * kind * 'v -> 'v env

(** [dissolve env m] has the effect of introducing a new binding of [x]
    for every existing binding of [m::x]. This concerns both variables and
    data constructors. *)
val dissolve: 'v env -> Module.name -> 'v env

(** [bindings_data_group_types group] returns a list of bindings for the types
    of the data group. *)
val bindings_data_group_types: data_type_def list -> type_binding list

(** [bind_data_group_datacons env group] extends the environment with bindings
    for the data constructors of the data group. It must be called after the
    environment has been extended with bindings for the types. *)
val bind_data_group_datacons: 'v env -> data_type_def list -> 'v env

val bind_nonlocal_datacon: 'v env -> Datacon.name -> datacon_info -> 'v -> 'v env

(* ---------------------------------------------------------------------------- *)

(** {1 Extending an environment with external names.} *)

(** These functions are used when constructing an interface. We need to add
 * additional bindings in the Kind-Checking environment. *)

val bind_external_name: 'v env -> Module.name -> Variable.name -> kind -> 'v -> 'v env
val bind_external_datacon: 'v env -> Module.name -> Datacon.name -> datacon_info -> 'v -> 'v env

(* ---------------------------------------------------------------------------- *)

(** {1 Functions for obtaining the bindings introduced by a pattern or by a type
   (interpreted as a pattern).} *)

(** [bv p] returns the names bound by the pattern [p], in left-to-right order.
    The order matters -- the de Bruijn numbering convention relies on it. *)
val bv: pattern -> type_binding list

(** [names ty] returns a list of the names introduced by the type [ty], via
    [TyNameIntro] forms. The list is returned in left-to-right order, as
    above. [names] is in fact implemented via a call to [bv]. *)
val names: typ -> type_binding list

(* ---------------------------------------------------------------------------- *)

(** {1 Kind-checking functions.} *)

(** [infer_reset env ty] returns the kind of the type [ty]. *)
val infer_reset: 'v env -> typ -> kind

(** [check_implementation env i] checks that the implementation file [i] is
    well-formed, i.e. all names are properly bound and all types are
    well-kinded. *)
val check_implementation: 'v env -> implementation -> unit

(** [check_implementation env i] checks that the interface file [i] is
    well-formed, i.e. all names are properly bound and all types are
    well-kinded. *)
val check_interface: 'v env -> interface -> unit

(* ---------------------------------------------------------------------------- *)

(** {1 Debugging functions.} *)

val p: Buffer.t -> 'a env -> unit
