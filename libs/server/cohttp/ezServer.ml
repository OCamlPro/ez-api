open Lwt.Infix
open EzAPI
open EzAPIServerUtils
open Cohttp

module Server = Cohttp_lwt_unix.Server

let set_debug () = Cohttp_lwt_unix.Debug.activate_debug ()

let register_ip req io =
  let open Conduit_lwt_unix in match io with
  | Domain_socket _
  | Vchan _ -> ()
  | TCP tcp ->
    match[@warning "-42"] Lwt_unix.getpeername tcp.fd with
    | Lwt_unix.ADDR_INET (ip,_port) ->
      let ip = Ipaddr.to_string (Ipaddr_unix.of_inet_addr ip) in
      let ip =
        match Header.get (Request.headers req) "x-forwarded-for" with
        | None -> ip
        | Some ip -> ip in
      Ip.register ip
    | Lwt_unix.ADDR_UNIX _path -> ()

let headers_from_cohttp req =
  let headers = ref StringMap.empty in
  Header.iter (fun s v ->
      headers :=
        StringMap.add (String.lowercase_ascii s) v !headers)
    (Request.headers req);
  !headers

let meth_from_cohttp req =
  match Request.meth req with
  | #Meth.all as m -> Some m
  | _ -> None

let version_from_cohttp req =
  match Request.version req with
  | #Req.version as v -> Some v
  | _ -> None

let debug_cohttp req =
  debug "[%s] REQUEST: %s %S" (pp_time ())
    (req |> Request.meth |> Code.string_of_method)
    (req |> Request.uri |> Uri.path_and_query);
  debugf ~v:1 (fun () ->
      Header.iter (fun s v ->
          List.iter (fun v -> EzDebug.printf "  %s: %s" s v) v)
        (Request.headers req))

let dispatch ?catch s io req body =
  Timings.set_req_time ();
  register_ip req io;
  debug_cohttp req;
  let headers = headers_from_cohttp req in
  let version = version_from_cohttp req in
  let path_str, path, content_type, r =
    Req.request ?version ~headers (Request.uri req) in
  let meth = meth_from_cohttp req in
  Cohttp_lwt.Body.to_string body >>= fun body ->
  let ws = Ws.ws req in
  Lwt.catch (fun () -> handle ~ws ?meth ?content_type s.server_kind r path body)
    (fun exn ->
       EzDebug.printf "In %s: exception %s" path_str @@ Printexc.to_string exn;
       match catch with
       | None -> Lwt.return (`http {Answer.code=500; body=""; headers=[]})
       | Some c -> c path_str exn >|= fun a -> `http a)
  >>= function
  | `ws ra -> Lwt.return ra
  | `http {Answer.code; body; headers} ->
    let headers = headers @ access_control_headers in
    let status = Code.status_of_code code in
    debug ~v:(if code >= 200 && code < 300 then 1 else 0) "Reply computed to %S: %d" path_str code;
    debug ~v:3 "Reply content:\n  %s" body;
    let headers = Header.of_list headers in
    Server.respond_string ~headers ~status ~body () >|= fun (r, b) ->
    `Response (r, b)

let create_server ?catch server_port server_kind =
  let s = { server_port; server_kind } in
  Timings.init @@ Doc.nservices ();
  ignore @@ Doc.all_services_registered ();
  let callback conn req body = dispatch ?catch s (fst conn) req body in
  let on_exn = function
    | Unix.Unix_error (Unix.EPIPE, _, _) -> ()
    | exn -> EzDebug.printf "Server Error: %s" (Printexc.to_string exn) in
  EzDebug.printf "Starting COHTTP server (port: %d)" server_port;
  Server.create
    ~on_exn
    ~mode:(`TCP (`Port server_port))
    (Server.make_response_action ~callback ())

let server ?catch servers =
  Lwt.join (List.map (fun (port,kind) -> create_server ?catch port kind) servers)