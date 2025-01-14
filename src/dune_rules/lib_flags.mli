open Import

(** Operation on list of libraries and modules *)
module Lib_and_module : sig
  type t =
    | Lib of Lib.t
    | Module of Path.t Obj_dir.t * Module.t

  module L : sig
    type nonrec t = t list

    val link_flags :
      t -> lib_config:Lib_config.t -> mode:Link_mode.t -> _ Command.Args.t
  end
end

(** Operations on list of libraries *)
module L : sig
  type nonrec t = Lib.t list

  val to_iflags : Path.Set.t -> _ Command.Args.t

  val include_paths : ?project:Dune_project.t -> t -> Mode.t -> Path.Set.t

  val include_flags : ?project:Dune_project.t -> t -> Mode.t -> _ Command.Args.t

  val c_include_flags : t -> _ Command.Args.t

  val toplevel_include_paths : t -> Path.Set.t
end

(** The list of files that will be read by the compiler when linking an
    executable against this library *)
val link_deps : Lib.t -> Link_mode.t -> Path.t list Memo.t
