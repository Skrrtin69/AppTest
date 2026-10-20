import Foundation

/// Extra routes on the local server that support video playback:
///   /player/video.html?src=&type=   HTML5 player page; falls back to the bundled ogv.js
///                                   WebAssembly decoder when WebKit can't play WebM itself.
///   /player/ogv/<file>              ogv.js runtime files (bundled under Resources/Player).
///   /local/<path>                   files from Documents/Downloads (Library playback).
///   /proxy?url=<url>[&site=<id>]    fetches a remote file so the decoder can read it
///                                   regardless of that server's CORS headers.
enum PlayerRoutes {
    static func serveStatic(_ path: String) -> HTTPResponse? {
        if path == "/player/video.html" { return .text(playerHTML, type: "text/html; charset=utf-8") }
        if path.hasPrefix("/player/") {
            let sub = String(path.dropFirst("/player/".count))
            guard !sub.contains(".."), let url = bundleURL("Player/" + sub), let data = try? Data(contentsOf: url) else {
                return .json(["error": "no such player file"], status: 404)
            }
            return HTTPResponse(contentType: contentType(sub), headers: ["Cache-Control": "max-age=86400"], body: data)
        }
        if path.hasPrefix("/local/") {
            let rel = String(path.dropFirst("/local/".count))
            guard !rel.contains("..") else { return .json(["error": "bad path"], status: 400) }
            let file = DownloadManager.root.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: file) else { return .json(["error": "no such file"], status: 404) }
            return HTTPResponse(contentType: MockMedia.contentType(rel), body: data)
        }
        return nil
    }

    static func bundleURL(_ relative: String) -> URL? {
        let ns = relative as NSString
        return Bundle.main.url(forResource: ns.lastPathComponent, withExtension: nil, subdirectory: ns.deletingLastPathComponent)
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "js": return "application/javascript"
        case "wasm": return "application/wasm"
        case "html": return "text/html; charset=utf-8"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

    static let chunk = 2 * 1024 * 1024

    /// Fetches `url` for the player (forwarding Range) using the matching adapter's client.
    static func proxy(_ req: HTTPRequest) async -> HTTPResponse {
        guard let s = req.query["url"], let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .json(["error": "bad url"], status: 400)
        }
        var r = URLRequest(url: url)
        if let range = req.headers["range"] {
            // "bytes=N-" would make the whole rest of the file download before anything is
            // sent on; asking for 2 MB at a time lets the player start right away (it asks
            // for the next piece itself, as a 206 answer allows).
            if let m = range.range(of: "^bytes=[0-9]+-$", options: .regularExpression), m.lowerBound == range.startIndex,
               let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                r.setValue("bytes=\(start)-\(start + Self.chunk - 1)", forHTTPHeaderField: "Range")
            } else {
                r.setValue(range, forHTTPHeaderField: "Range")
            }
        }
        let client = req.query["site"].flatMap { AdapterRegistry.shared.adapter(for: $0)?.client } ?? NetworkClient.shared
        for (k, v) in client.mediaHeaders { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await client.session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .json(["error": "bad response"], status: 502) }
            var out = HTTPResponse(status: http.statusCode,
                                   contentType: http.value(forHTTPHeaderField: "Content-Type") ?? MockMedia.contentType(url.path),
                                   body: data)
            if let cr = http.value(forHTTPHeaderField: "Content-Range") { out.headers["Content-Range"] = cr }
            return out
        } catch {
            return .json(["error": error.localizedDescription], status: 502)
        }
    }

    /// Native <video> first; if WebKit can't play the file (WebM on most iOS versions),
    /// switch to ogv.js, which decodes VP8/VP9 in WebAssembly and draws to a canvas.
    static let playerHTML = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>
    html,body{margin:0;height:100%;background:#000;overflow:hidden}
    #stage{position:absolute;top:0;left:0;right:0;bottom:0}
    video,ogvjs{position:absolute!important;top:0;left:0;width:100%!important;height:100%!important;object-fit:contain}
    ogvjs canvas{object-fit:contain}
    #msg{color:#fff;font:16px -apple-system;padding:24px;position:absolute;top:40%;width:100%;box-sizing:border-box;text-align:center}
    #snd{position:absolute;right:14px;bottom:140px;width:44px;height:44px;border-radius:22px;border:0;
         background:rgba(0,0,0,.55);color:#fff;font:20px -apple-system;display:none;z-index:5}
    </style></head><body><div id="stage"></div><button id="snd" aria-label="Sound">🔊</button>
    <script src="/player/ogv/ogv.js"></script>
    <script>
    var q=new URLSearchParams(location.search), src=q.get('src')||'', type=q.get('type')||'', startMuted=q.get('muted')==='1';
    var stage=document.getElementById('stage'), player=null, usingOgv=false, snd=document.getElementById('snd');
    function setSoundIcon(){ snd.textContent = (player && player.muted) ? '🔇' : '🔊'; snd.setAttribute('aria-label', (player && player.muted) ? 'Sound off, tap for sound' : 'Sound on'); }
    // A tap here is also the user gesture iOS needs before it allows audio.
    snd.onclick=function(e){ e.stopPropagation(); if(!player) return; player.muted=!player.muted; var p=player.play(); if(p&&p.catch){p.catch(function(){});} setSoundIcon(); post('sound '+(player.muted?'off':'on')); };
    function post(m){try{window.webkit.messageHandlers.status.postMessage(m);}catch(e){}}
    function fail(why){stage.innerHTML='<div id="msg">This video can\\'t be played on this device.<br>('+why+')</div>';post('error: '+why);}
    function useOgv(){
      if(usingOgv) return; usingOgv=true;
      if(typeof OGVPlayer==='undefined'){fail('decoder files missing');return;}
      stage.innerHTML='';
      OGVLoader.base='/player/ogv';
      try{ player=new OGVPlayer({simd:false,threading:false}); }catch(e){fail('decoder failed to start: '+e);return;}
      player.muted=startMuted;
      player.addEventListener('ended',function(){ if(window.mdLoopOn){player.currentTime=0;player.play();} else {post('ended');} });
      player.addEventListener('error',function(){fail('decoder error');});
      player.addEventListener('playing',function(){post('engine: ogv.js (WebAssembly)');});
      player.addEventListener('canplay',function(){post('canplay');});
      player.addEventListener('loadedmetadata',function(){post('metadata '+player.videoWidth+'x'+player.videoHeight);});
      player.src=src;
      stage.appendChild(player);
      player.play();
      snd.style.display='block'; setSoundIcon();
      stage.onclick=function(){ if(player.paused) player.play(); else player.pause(); };
    }
    function useNative(){
      var v=document.createElement('video');
      v.setAttribute('playsinline',''); v.playsInline=true; v.autoplay=true; v.loop=true; v.muted=startMuted; v.controls=true;
      v.addEventListener('error',useOgv);
      v.addEventListener('playing',function(){post('engine: WebKit <video>');});
      v.addEventListener('canplay',function(){post('canplay');});
      v.addEventListener('ended',function(){post('ended');});
      v.src=src; stage.appendChild(v); player=v;
      snd.style.display='block'; setSoundIcon();
      // If iOS refuses autoplay with sound, start muted and let the speaker button unmute.
      var p=v.play(); if(p&&p.catch){p.catch(function(){ v.muted=true; setSoundIcon(); v.play().catch(function(){}); });}
    }
    var isWebm=/webm/i.test(type)||/\\.webm(\\?|$)/i.test(src);
    var can=document.createElement('video').canPlayType('video/webm');
    post('canPlayType(video/webm)="'+can+'"');
    if(isWebm && can===''){useOgv();}else{useNative();}
    window.mdPlay=function(){if(player)player.play();};
    window.mdPause=function(){if(player)player.pause();};
    window.mdLoopOn=true;
    window.mdSetLoop=function(on){ window.mdLoopOn=on; if(player && !usingOgv){ player.loop=on; } };
    window.mdSpeed=function(r){ if(player){ try{ player.playbackRate=r; }catch(e){} } };
    </script></body></html>
    """
}
