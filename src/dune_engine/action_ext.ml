open Import

type context =
  { targets : Targets.Validated.t option
  ; context : Build_context.t option
  ; purpose : Process.purpose
  ; rule_loc : Loc.t
  }

type env =
  { working_dir : Path.t
  ; env : Env.t
  ; stdout_to : Process.Io.output Process.Io.t
  ; stderr_to : Process.Io.output Process.Io.t
  ; stdin_from : Process.Io.input Process.Io.t
  ; exit_codes : int Predicate.t
  }

module type Spec = sig
  type ('path, 'target) t

  val name : string

  val version : int

  val is_useful_to : distribute:bool -> memoize:bool -> bool

  val encode :
    ('p, 't) t -> ('p -> Dune_lang.t) -> ('t -> Dune_lang.t) -> Dune_lang.t

  val bimap : ('a, 'b) t -> ('a -> 'x) -> ('b -> 'y) -> ('x, 'y) t

  val action :
       (Path.t, Path.Build.t) t
    -> ectx:context
    -> eenv:env
    -> (* cwong: For now, I think we should only worry about extensions with
          known dependencies. In the future, we may generalize this to return an
          [Action_exec.done_or_more_deps], but that may be trickier to get
          right, and is a bridge we can cross when we get there. *)
       unit Fiber.t
end

module type Instance = sig
  type target

  type path

  module Spec : Spec

  val v : (path, target) Spec.t
end
