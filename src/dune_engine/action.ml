open Import
include Action_types
module Ext = Action_ext

module Prog = struct
  module Not_found = struct
    type t =
      { context : Context_name.t
      ; program : string
      ; hint : string option
      ; loc : Loc.t option
      }

    let create ?hint ~context ~program ~loc () = { hint; context; program; loc }

    let user_message { context; program; hint; loc } =
      let hint =
        match program with
        | "refmt" -> Some (Option.value ~default:"opam install reason" hint)
        | _ -> hint
      in
      Utils.program_not_found_message ?hint ~loc ~context program

    let raise t = raise (User_error.E (user_message t))

    let to_dyn { context; program; hint; loc = _ } =
      let open Dyn in
      record
        [ ("context", Context_name.to_dyn context)
        ; ("program", string program)
        ; ("hint", option string hint)
        ]
  end

  type t = (Path.t, Not_found.t) result

  let encode = function
    | Ok s -> Dpath.encode s
    | Error (e : Not_found.t) -> Dune_lang.Encoder.string e.program

  let to_dyn t = Result.to_dyn Path.to_dyn Not_found.to_dyn t

  let ok_exn = function
    | Ok s -> s
    | Error e -> Not_found.raise e
end

module Encode_ext = struct
  type t =
    (module Action_ext.Instance
       with type target = Dpath.Build.t
        and type path = Dpath.t)

  let encode = Dune_lang.Encoder.unknown
end

module type Ast =
  Action_intf.Ast
    with type program = Prog.t
    with type path = Path.t
    with type target = Path.Build.t
    with type string = String.t
     and type ext = Encode_ext.t

module rec Ast : Ast = Ast

module String_with_sexp = struct
  type t = string

  let encode = Dune_lang.Encoder.string
end

include
  Action_ast.Make (Prog) (Dpath) (Dpath.Build) (String_with_sexp) (Encode_ext)
    (Ast)

include Monoid.Make (struct
  type nonrec t = t

  let empty = Progn []

  let combine a b =
    match (a, b) with
    | Progn [], x | x, Progn [] -> x
    | Progn xs, Progn ys -> Progn (xs @ ys)
    | x, y -> Progn [ x; y ]
end)

type string = String.t

module For_shell = struct
  module type Ast =
    Action_intf.Ast
      with type program = string
      with type path = string
      with type target = string
      with type string = string
      with type ext = Dune_lang.t

  module rec Ast : Ast = Ast

  include
    Action_ast.Make (String_with_sexp) (String_with_sexp) (String_with_sexp)
      (String_with_sexp)
      (struct
        type t = Dune_lang.t

        let encode = Dune_lang.Encoder.sexp
      end)
      (Ast)
end

module Relativise = Action_mapper.Make (Ast) (For_shell.Ast)

let for_shell t =
  let rec loop t ~dir ~f_program ~f_string ~f_path ~f_target ~f_ext =
    match t with
    | Symlink (src, dst) ->
      let src =
        match Path.Build.parent dst with
        | None -> Path.to_string src
        | Some from -> Path.reach ~from:(Path.build from) src
      in
      let dst = Path.reach ~from:dir (Path.build dst) in
      For_shell.Symlink (src, dst)
    | t ->
      Relativise.map_one_step loop t ~dir ~f_program ~f_string ~f_path ~f_target
        ~f_ext
  in
  let f_path ~dir x = Path.reach x ~from:dir in
  let f_target ~dir x = Path.reach (Path.build x) ~from:dir in
  loop t ~dir:Path.root
    ~f_string:(fun ~dir:_ x -> x)
    ~f_path ~f_target
    ~f_ext:(fun ~dir (module A) ->
      A.Spec.encode A.v
        (fun p -> Dune_lang.atom_or_quoted_string (f_path p ~dir))
        (fun p -> Dune_lang.atom_or_quoted_string (f_target p ~dir)))
    ~f_program:(fun ~dir x ->
      match x with
      | Ok p -> Path.reach p ~from:dir
      | Error e -> e.program)

let fold_one_step t ~init:acc ~f =
  match t with
  | Chdir (_, t)
  | Setenv (_, _, t)
  | Redirect_out (_, _, _, t)
  | Redirect_in (_, _, t)
  | Ignore (_, t)
  | With_accepted_exit_codes (_, t)
  | No_infer t -> f acc t
  | Progn l | Pipe (_, l) -> List.fold_left l ~init:acc ~f
  | Run _
  | Dynamic_run _
  | Echo _
  | Cat _
  | Copy _
  | Symlink _
  | Hardlink _
  | System _
  | Bash _
  | Write_file _
  | Rename _
  | Remove_tree _
  | Mkdir _
  | Diff _
  | Merge_files_into _
  | Extension _ -> acc

include Action_mapper.Make (Ast) (Ast)

(* TODO change [chdir] to use [Path.Build.t] in the directory. This will be
   easier once [Action.t] is split off from the dune lang's action *)
let chdirs =
  let rec loop acc t =
    let acc =
      match t with
      | Chdir (dir, _) -> (
        match Path.as_in_build_dir dir with
        | None ->
          Code_error.raise "chdir ouside the build directory"
            [ ("dir", Path.to_dyn dir) ]
        | Some dir -> Path.Build.Set.add acc dir)
      | _ -> acc
    in
    fold_one_step t ~init:acc ~f:loop
  in
  fun t -> loop Path.Build.Set.empty t

let empty = Progn []

let rec is_dynamic = function
  | Dynamic_run _ -> true
  | Chdir (_, t)
  | Setenv (_, _, t)
  | Redirect_out (_, _, _, t)
  | Redirect_in (_, _, t)
  | Ignore (_, t)
  | With_accepted_exit_codes (_, t)
  | No_infer t -> is_dynamic t
  | Progn l | Pipe (_, l) -> List.exists l ~f:is_dynamic
  | Run _
  | System _
  | Bash _
  | Echo _
  | Cat _
  | Copy _
  | Symlink _
  | Hardlink _
  | Write_file _
  | Rename _
  | Remove_tree _
  | Diff _
  | Mkdir _
  | Merge_files_into _
  | Extension _ -> false

let maybe_sandbox_path sandbox p =
  match Path.as_in_build_dir p with
  | None -> p
  | Some p -> Path.build (Sandbox.map_path sandbox p)

let sandbox t sandbox : t =
  map t ~dir:Path.root
    ~f_string:(fun ~dir:_ x -> x)
    ~f_path:(fun ~dir:_ p -> maybe_sandbox_path sandbox p)
    ~f_target:(fun ~dir:_ p -> Sandbox.map_path sandbox p)
    ~f_program:(fun ~dir:_ p -> Result.map p ~f:(maybe_sandbox_path sandbox))
    ~f_ext:(fun ~dir:_ (module A) ->
      let module A = struct
        include A

        let v =
          Spec.bimap v (maybe_sandbox_path sandbox) (Sandbox.map_path sandbox)
      end in
      (module A))

type is_useful =
  | Clearly_not
  | Maybe

let is_useful_to distribute memoize =
  let rec loop t =
    match t with
    | Chdir (_, t) -> loop t
    | Setenv (_, _, t) -> loop t
    | Redirect_out (_, _, _, t) -> memoize || loop t
    | Redirect_in (_, _, t) -> loop t
    | Ignore (_, t) | With_accepted_exit_codes (_, t) | No_infer t -> loop t
    | Progn l | Pipe (_, l) -> List.exists l ~f:loop
    | Echo _ -> false
    | Cat _ -> memoize
    | Copy _ -> memoize
    | Symlink _ -> false
    | Hardlink _ -> false
    | Write_file _ -> distribute
    | Rename _ -> memoize
    | Remove_tree _ -> false
    | Diff _ -> distribute
    | Mkdir _ -> false
    | Merge_files_into _ -> distribute
    | Run _ -> true
    | Dynamic_run _ -> true
    | System _ -> true
    | Bash _ -> true
    | Extension (module A) -> A.Spec.is_useful_to ~distribute ~memoize
  in
  fun t ->
    match loop t with
    | true -> Maybe
    | false -> Clearly_not

let is_useful_to_sandbox = is_useful_to false false

let is_useful_to_distribute = is_useful_to true false

let is_useful_to_memoize = is_useful_to true true

module Full = struct
  module T = struct
    type nonrec t =
      { action : t
      ; env : Env.t
      ; locks : Path.t list
      ; can_go_in_shared_cache : bool
      ; sandbox : Sandbox_config.t
      }

    let empty =
      { action = Progn []
      ; env = Env.empty
      ; locks = []
      ; can_go_in_shared_cache = true
      ; sandbox = Sandbox_config.default
      }

    let combine { action; env; locks; can_go_in_shared_cache; sandbox } x =
      { action = combine action x.action
      ; env = Env.extend_env env x.env
      ; locks = locks @ x.locks
      ; can_go_in_shared_cache =
          can_go_in_shared_cache && x.can_go_in_shared_cache
      ; sandbox = Sandbox_config.inter sandbox x.sandbox
      }
  end

  include T
  include Monoid.Make (T)

  let make ?(env = Env.empty) ?(locks = []) ?(can_go_in_shared_cache = true)
      ?(sandbox = Sandbox_config.default) action =
    { action; env; locks; can_go_in_shared_cache; sandbox }

  let map t ~f = { t with action = f t.action }

  let add_env e t = { t with env = Env.extend_env t.env e }

  let add_locks l t = { t with locks = t.locks @ l }

  let add_can_go_in_shared_cache b t =
    { t with can_go_in_shared_cache = t.can_go_in_shared_cache && b }

  let add_sandbox s t = { t with sandbox = Sandbox_config.inter t.sandbox s }
end
