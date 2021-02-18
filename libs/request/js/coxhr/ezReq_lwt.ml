module Base = EzCohttp_base.Make(Cohttp_lwt_xhr.Client)

module Interface = struct
  let get ?meth ?headers ?msg url =
    Base.get ?meth ?headers ?msg url

  let post ?meth ?content_type ?content ?headers ?msg url =
    Base.post ?meth ?content_type ?content ?headers ?msg url
end

include EzRequest_lwt.Make(Interface)

let init () =
  init ();
  EzRequest_lwt.log := (fun s -> Js_of_ocaml.(Firebug.console##log (Js.string s)));
  !EzRequest_lwt.log "ezCoXhr Loaded"