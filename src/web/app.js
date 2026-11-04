/* 客户端：信令走 WebSocket（只传 SDP / ICE），媒体 P2P。接口按 W3C WebRTC 规范实现。 */
'use strict';

const $ = (s) => document.querySelector(s);
const QS = new URLSearchParams(location.search);

const S = {
  ws: null,
  myId: null,
  room: (QS.get('room') || 'demo').slice(0, 32),
  name: (QS.get('name') || '').slice(0, 32),
  localStream: null,
  cameraTrack: null,
  micTrack: null,
  peers: new Map(),          // peerId -> peer 对象
  joined: false,
  rateCap: 1500,             // kbps，0 = 不限
  iceServers: [],
  synthetic: false,
  statsTimer: null,
};

/* ------------------------------------------------------------------ 工具 */
function log(msg, isErr) {
  const el = $('#log');
  const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
  S.logbuf = S.logbuf || [];
  S.logbuf.push(line);
  if (S.logbuf.length > 60) S.logbuf.shift();
  if (!el) return;
  const span = document.createElement('span');
  span.className = isErr ? 'e' : '';
  span.textContent = line + '\n';
  el.appendChild(span);
  el.scrollTop = el.scrollHeight;
  (isErr ? console.warn : console.log)(msg);
}

function setSig(state, text) {
  const dot = $('#sigDot');
  dot.className = 'dot' + (state === 'ok' ? ' ok' : state === 'wait' ? ' wait' : '');
  $('#sigText').textContent = text;
}

const kbps = (bytes, dt) => (dt > 0 ? Math.round((bytes * 8) / dt / 1000) : 0);

/* ---------- 移动端音频解锁 ----------
 * iOS 禁止带声音的自动播放，必须由用户手势触发 play()。
 * 我们的 video 是异步创建的，手势早已失效，所以要提供手动解锁入口。 */
function remoteVideos() {
  return [...document.querySelectorAll('.tile:not(.local) video')];
}

function showSoundBtn(show) {
  const b = $('#soundBtn');
  if (b) b.classList.toggle('hidden', !show);
}

async function ensureAudio() {
  let blocked = false;
  for (const v of remoteVideos()) {
    try {
      v.muted = false;
      v.volume = 1;
      if (v.paused || v.readyState < 2) await v.play();
    } catch (e) {
      blocked = true;
      log(`远端声音被浏览器拦截（${e.name}）→ 点「开启声音」`, true);
    }
  }
  showSoundBtn(blocked);
  return !blocked;
}

// 先静音播放保证画面可见（iOS 上带声音的 play() 会被拒，整个 video 卡在 paused）。
async function primeVideo(v) {
  if (!v || v.srcObject == null) return;
  v.muted = false;
  v.volume = 1;
  try {
    if (v.paused) await v.play();
    showSoundBtn(false);
    return;
  } catch (e) {
    try {
      v.muted = true;
      await v.play();
      showSoundBtn(true);
      log(`画面已显示（静音）；点「开启声音」或屏幕任意处解锁声音（${e.name}）`);
      return;
    } catch (e2) {
      log(`远端画面无法播放：${e2.name}`, true);
    }
  }
  showSoundBtn(true);
}

function installAudioUnlock() {
  const once = async () => {
    if (await ensureAudio()) {
      ['touchend', 'click', 'pointerup'].forEach((ev) => document.removeEventListener(ev, once, true));
      log('音频已解锁');
    }
  };
  ['touchend', 'click', 'pointerup'].forEach((ev) => document.addEventListener(ev, once, true));
}

/* ------------------------------------------------------- 本端媒体获取 */
function synthStream() {
  const cv = document.createElement('canvas');
  cv.width = 1280; cv.height = 720;
  const ctx = cv.getContext('2d');
  const t0 = performance.now();
  // 用 setInterval：后台标签页会暂停 requestAnimationFrame，导致码率为 0。
  setInterval(() => {
    const t = (performance.now() - t0) / 1000;
    const g = ctx.createLinearGradient(0, 0, cv.width, cv.height);
    g.addColorStop(0, '#0d1b2a'); g.addColorStop(1, '#16324a');
    ctx.fillStyle = g; ctx.fillRect(0, 0, cv.width, cv.height);
    ctx.strokeStyle = 'rgba(10,132,255,.55)'; ctx.lineWidth = 3;
    for (let i = 0; i < 24; i++) {
      const r = 60 + i * 26 + 14 * Math.sin(t * 2 + i * 0.5);
      ctx.beginPath(); ctx.arc(cv.width / 2, cv.height / 2, r, 0, Math.PI * 2); ctx.stroke();
    }
    ctx.fillStyle = '#e6edf3';
    ctx.font = '600 44px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('SYNTHETIC TEST PATTERN', cv.width / 2, 96);
    ctx.font = '500 30px ui-monospace, monospace';
    ctx.fillStyle = '#22c55e';
    ctx.fillText(`frame ${Math.round(t * 30)}  |  ${cv.width}x${cv.height}@30`, cv.width / 2, cv.height - 70);
    ctx.fillStyle = '#8b98a7';
    ctx.font = '24px system-ui, sans-serif';
    ctx.fillText('无需摄像头的兜底信号（用于通路自检）', cv.width / 2, cv.height - 30);
  }, 33);

  const tracks = [...cv.captureStream(30).getVideoTracks()];
  try {
    const ac = new (window.AudioContext || window.webkitAudioContext)();
    const osc = ac.createOscillator();
    const gain = ac.createGain();
    const dst = ac.createMediaStreamDestination();
    osc.type = 'sine'; osc.frequency.value = 440;
    gain.gain.value = 0.04;
    osc.connect(gain); gain.connect(dst); osc.start();
    tracks.push(...dst.stream.getAudioTracks());
  } catch (e) {
    log('合成音频不可用：' + e.message, true);
  }
  return new MediaStream(tracks);
}

async function openMedia({ videoId, audioId } = {}) {
  const base = {
    audio: {
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      ...(audioId ? { deviceId: { exact: audioId } } : {}),
    },
    video: {
      width: { ideal: 1280 }, height: { ideal: 720 },
      frameRate: { ideal: 30, max: 30 },
      ...(videoId ? { deviceId: { exact: videoId } } : {}),
    },
  };
  try {
    const stream = await navigator.mediaDevices.getUserMedia(base);
    log(`摄像头/麦克风已打开：${stream.getVideoTracks()[0]?.label || '-'} / ${stream.getAudioTracks()[0]?.label || '-'}`);
    return { stream, synthetic: false };
  } catch (err) {
    S.mediaError = `${err.name}: ${err.message}`;
    log(`getUserMedia 失败（${err.name}: ${err.message}）→ 改用合成测试信号`, true);
    return { stream: synthStream(), synthetic: true };
  }
}

async function listDevices() {
  if (!navigator.mediaDevices?.enumerateDevices) return;
  const devs = await navigator.mediaDevices.enumerateDevices();
  const fill = (sel, kind, label) => {
    const prev = sel.value;
    sel.innerHTML = '';
    devs.filter((d) => d.kind === kind).forEach((d, i) => {
      const o = document.createElement('option');
      o.value = d.deviceId;
      o.textContent = d.label || `${label} ${i + 1}`;
      sel.appendChild(o);
    });
    if (prev) sel.value = prev;
  };
  fill($('#camSel'), 'videoinput', '摄像头');
  fill($('#micSel'), 'audioinput', '麦克风');
}

/* ---------------------------------------------------------------- 画面格 */
function createTile(name, isLocal) {
  const el = document.createElement('div');
  el.className = 'tile' + (isLocal ? ' local' : '');
  el.innerHTML = `
    <video autoplay playsinline webkit-playsinline x5-playsinline ${isLocal ? 'muted' : ''}></video>
    <div class="label"><span class="nm"></span><span class="tag"></span></div>
    <div class="badge">—</div>
    <div class="off">摄像头已关闭</div>
    <div class="state"><span class="mic">🎤</span><span class="cam">📷</span></div>`;
  el.querySelector('.nm').textContent = name;
  el.querySelector('.tag').textContent = isLocal ? '本端' : '连接中';
  el.querySelector('.badge').textContent = isLocal ? 'localhost' : '—';
  return el;
}

function attachLocalTile(stream) {
  let tile = document.querySelector('.tile.local');
  if (!tile) {
    tile = createTile(`${S.name || '我'}`, true);
    $('#grid').prepend(tile);
  }
  tile.querySelector('video').srcObject = stream;
  const v = stream.getVideoTracks()[0];
  tile.classList.toggle('camoff', !v || !v.enabled);
  tile.querySelector('.badge').textContent = v
    ? `${v.getSettings().width || '?'}x${v.getSettings().height || '?'}`
    : 'no video';
  $('#hint')?.remove();
}

/* -------------------------------------------------------------- 对端管理 */
function peerTile(id, name) {
  let p = S.peers.get(id);
  if (p) return p.tile;
  let el = document.getElementById('tile-' + id);
  if (!el) {
    el = createTile(name || id, false);
    el.id = 'tile-' + id;
    $('#grid').appendChild(el);
  }
  return el;
}

function makePeer(id, name, polite) {
  if (S.peers.has(id)) return S.peers.get(id);

  const pc = new RTCPeerConnection({ iceServers: S.iceServers, iceCandidatePoolSize: 0 });
  const peer = {
    id, name: name || id, polite, pc,
    makingOffer: false, ignoreOffer: false, answerPending: false,
    tile: peerTile(id, name),
    senders: { audio: null, video: null },
    prev: { t: 0, outB: 0, inB: 0, outAB: 0, inAB: 0 },
    remoteStream: new MediaStream(),
  };
  S.peers.set(id, peer);

  // 本端轨道
  for (const track of S.localStream?.getTracks() || []) {
    const sender = pc.addTrack(track, S.localStream);
    if (track.kind === 'audio') peer.senders.audio = sender;
    else { peer.senders.video = sender; track.contentHint = 'motion'; }
  }

  // perfect negotiation：由 id 字典序定角色，只有一方发 offer。
  // 两端同时 offer 时，polite 方 rollback 后自己的轨道会丢失，变成单向。
  pc.onnegotiationneeded = async () => {
    if (peer.polite) {
      // polite 一方：会话还没建立时不主动 offer
      if (pc.connectionState !== 'connected') {
        log(`${peer.name}：我是 polite 一方，等对方 offer（本端轨道随 answer 一起发）`);
        return;
      }
    }
    try {
      peer.makingOffer = true;
      await pc.setLocalDescription();
      send({ type: 'signal', to: id, data: { description: pc.localDescription } });
      log(`→ offer 给 ${peer.name}（${pc.localDescription.sdp.length}B）`);
    } catch (e) {
      log('offer 失败：' + e.message, true);
    } finally {
      peer.makingOffer = false;
    }
  };

  pc.onicecandidate = ({ candidate }) => {
    send({ type: 'signal', to: id, data: { candidate } });
  };

  pc.ontrack = ({ track, streams }) => {
    log(`← ${peer.name} 的 ${track.kind} 轨道 (${track.label || 'no-label'})`);
    peer.remoteStream.addTrack(track);
    const video = peer.tile.querySelector('video');
    if (video.srcObject !== peer.remoteStream) video.srcObject = peer.remoteStream;
    // 轨道到达即尝试播放，被拒则静音播 + 提示用户点「开启声音」
    primeVideo(video);
    track.onmute = () => log(`${peer.name} 的 ${track.kind} 静音`);
    track.onunmute = () => log(`${peer.name} 的 ${track.kind} 恢复`);
    if (track.kind === 'video') peer.tile.classList.remove('camoff');
    $('#hint')?.remove();
  };

  pc.onconnectionstatechange = () => {
    const st = pc.connectionState;
    peer.tile.classList.toggle('connected', st === 'connected');
    peer.tile.classList.toggle('connecting', st === 'connecting' || st === 'new');
    peer.tile.querySelector('.tag').textContent = st;
    log(`${peer.name} 连接状态 → ${st}`);
    if (st === 'failed') {
      log(`${peer.name} 连接失败，尝试 ICE 重启`, true);
      try { pc.restartIce(); } catch (_) {}
    }
  };

  pc.oniceconnectionstatechange = () => {
    log(`${peer.name} ICE → ${pc.iceConnectionState}`);
  };

  pc.onicecandidateerror = (e) => log(`ICE 候选错误 ${e.errorCode} ${e.errorText}`, true);

  applyRateCap(peer);
  (peer.tile.querySelector('video')).onclick = () => peer.tile.querySelector('video').play().catch(() => {});
  return peer;
}

async function onDescription(peer, description) {
  const pc = peer.pc;
  const readyForOffer = !peer.makingOffer && (pc.signalingState === 'stable' || peer.answerPending);
  const offerCollision = description.type === 'offer' && !readyForOffer;
  peer.ignoreOffer = !peer.polite && offerCollision;
  if (peer.ignoreOffer) {
    log(`忽略与 ${peer.name} 的 offer 冲突（我是 impolite 一方）`);
    return;
  }
  peer.answerPending = description.type === 'answer';
  await pc.setRemoteDescription(description);
  peer.answerPending = false;
  if (description.type === 'offer') {
    await pc.setLocalDescription();
    send({ type: 'signal', to: peer.id, data: { description: pc.localDescription } });
    log(`→ answer 给 ${peer.name}`);
  }
}

async function onCandidate(peer, candidate) {
  try {
    await peer.pc.addIceCandidate(candidate);
  } catch (e) {
    if (!peer.ignoreOffer) log('addIceCandidate 失败：' + e.message, true);
  }
}

function dropPeer(id, reason) {
  const peer = S.peers.get(id);
  if (!peer) return;
  try { peer.pc.close(); } catch (_) {}
  peer.tile?.remove();
  S.peers.delete(id);
  log(`✖ ${peer.name} 断开（${reason}）`);
  if (S.peers.size === 0 && S.joined) {
    const hint = document.createElement('div');
    hint.className = 'hint';
    hint.id = 'hint';
    hint.innerHTML = `<h3>等待对端加入</h3><p class="muted">房间「${S.room}」里现在只有你。另一台设备用同样房间名加入即可。</p>`;
    $('.stage').appendChild(hint);
  }
}

/* --------------------------------------------------------------- 码率控制 */
async function applyRateCap(peer) {
  if (!peer?.senders?.video) return;
  try {
    const params = peer.senders.video.getParameters();
    if (!params.encodings || !params.encodings.length) params.encodings = [{}];
    if (S.rateCap > 0) {
      params.encodings[0].maxBitrate = S.rateCap * 1000;
      params.encodings[0].maxFramerate = 30;
    } else {
      delete params.encodings[0].maxBitrate;
    }
    await peer.senders.video.setParameters(params);
    log(`→ ${peer.name} 视频码率上限 ${S.rateCap ? S.rateCap + ' kbps' : '不限'}`);
  } catch (e) {
    log('setParameters 失败：' + e.message, true);
  }
}

/* ------------------------------------------------------------------ 信令 */
function send(obj) {
  if (S.ws?.readyState === WebSocket.OPEN) S.ws.send(JSON.stringify(obj));
}

function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const url = `${proto}://${location.host}/ws`;
  setSig('wait', '连接信令…');
  const ws = new WebSocket(url);
  S.ws = ws;

  ws.onopen = () => {
    log('信令已连接 ' + url);
    send({ type: 'join', room: S.room, name: S.name || defaultName() });
  };
  ws.onclose = () => {
    setSig('', '信令断开');
    log('信令断开', true);
    if (S.joined) {
      S.joined = false;
      [...S.peers.keys()].forEach((id) => dropPeer(id, '信令断开'));
      $('#joinBtn').disabled = false;
      $('#leaveBtn').disabled = true;
    }
  };
  ws.onerror = () => { setSig('', '信令错误'); log('信令连接错误', true); };

  ws.onmessage = async (ev) => {
    let m;
    try { m = JSON.parse(ev.data); } catch { return; }

    if (m.type === 'welcome') {
      S.myId = m.id;
      S.joined = true;
      setSig('ok', `信令已连接 · 我是 ${m.id}`);
      log(`进入房间「${m.room}」id=${m.id}，已有对端 ${m.peers.length} 个（上限 ${m.limit}）`);
      $('#joinBtn').disabled = true;
      $('#leaveBtn').disabled = false;
      ['micBtn', 'camBtn', 'camSel', 'micSel', 'rateSel'].forEach((s) => { $(`#${s}`).disabled = false; });
      // 我比对方 id 大 → polite（谁 polite 由 id 字典序唯一确定，两端一致）
      for (const p of m.peers) makePeer(p.id, p.name, S.myId > p.id);
      return;
    }
    if (m.type === 'peer-join') {
      const p = m.peer;
      log(`＋ ${p.name} (${p.id}) 加入房间`);
      makePeer(p.id, p.name, S.myId > p.id);
      return;
    }
    if (m.type === 'peer-leave') { dropPeer(m.id, '离开房间'); return; }
    if (m.type === 'peer-state') {
      const peer = S.peers.get(m.id);
      if (peer) {
        peer.tile.querySelector('.mic').textContent = m.mic ? '🎤' : '🔇';
        peer.tile.querySelector('.mic').classList.toggle('muted', !m.mic);
        peer.tile.querySelector('.cam').textContent = m.cam ? '📷' : '🚫';
        peer.tile.classList.toggle('camoff', !m.cam);
      }
      return;
    }
    if (m.type === 'signal') {
      const peer = S.peers.get(m.from);
      if (!peer) return;
      const d = m.data || {};
      try {
        if (d.description) await onDescription(peer, d.description);
        else if ('candidate' in d) await onCandidate(peer, d.candidate);
      } catch (e) {
        log('信令处理异常：' + e.message, true);
      }
      return;
    }
    if (m.type === 'error') { log('服务器：' + m.message, true); return; }
  };
}

function defaultName() {
  const ua = navigator.userAgent;
  if (/Firefox/i.test(ua)) return 'Firefox';
  if (/Edg/i.test(ua)) return 'Edge';
  if (/Chrome/i.test(ua)) return 'Chrome';
  return location.hostname.split('.')[0] || 'peer';
}

/* ------------------------------- 状态上报（供 /healthz 远程排查） */
let reportTick = 0;
function postReport(peersSummary) {
  if (++reportTick % 3 !== 0) return;                 // 每 3 秒一次
  const payload = {
    name: S.name || defaultName(),
    id: S.myId,
    room: S.room,
    href: location.href,
    ua: navigator.userAgent,
    synthetic: S.synthetic,
    mediaError: S.mediaError || null,
    log: (S.logbuf || []).slice(-25),
    media: {
      video: S.cameraTrack ? { label: S.cameraTrack.label, settings: S.cameraTrack.getSettings(), enabled: S.cameraTrack.enabled } : null,
      audio: S.micTrack ? { label: S.micTrack.label, enabled: S.micTrack.enabled } : null,
    },
    peers: peersSummary,
  };
  fetch('/report', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
    .catch(() => {});
}

/* ------------------------------------------------------------------ 统计 */
function cls(v, good, bad) {
  if (v >= bad) return 'bad';
  if (v >= good) return 'warn';
  return 'good';
}

async function collectStats() {
  const box = $('#stats');
  const out = [];
  const summary = [];
  const now = performance.now();
  if (!S.peers.size) {
    box.innerHTML = '<p class="muted">房间内暂无对端</p>';
    postReport(summary);            // 没对端也上报，便于远程确认本端摄像头/麦克风状态
    return;
  }
  for (const peer of S.peers.values()) {
    let report;
    try { report = await peer.pc.getStats(); } catch { continue; }
    const o = { res: '—', fps: 0, outK: 0, inK: 0, inRes: '—', inFps: 0, loss: 0, jitter: 0, rtt: null, codec: '—', conn: peer.pc.connectionState };
    let outB = 0, inB = 0, outAB = 0, inAB = 0, codecId = null, lossNum = 0, lossDen = 0, rtt = null, jab = 0;
    const locals = [];
    let selectedPair = null;
    report.forEach((s) => {
      if (s.type === 'local-candidate') {
        locals.push(`${s.candidateType}/${s.protocol}/${s.address || '?'}:${s.port}${s.address && /^169\.254\./.test(s.address) ? '(link-local)' : ''}`);
      }
      if (s.type === 'candidate-pair' && s.state === 'succeeded') selectedPair = selectedPair || s;
    });
    report.forEach((s) => {
      if (s.type === 'outbound-rtp' && s.kind === 'video') {
        outB += s.bytesSent || 0;
        o.res = s.frameWidth ? `${s.frameWidth}x${s.frameHeight}` : o.res;
        o.fps = Math.round(s.framesPerSecond || 0);
      }
      if (s.type === 'outbound-rtp' && s.kind === 'audio') { outB += s.bytesSent || 0; outAB += s.bytesSent || 0; }
      if (s.type === 'inbound-rtp' && s.kind === 'video') {
        inB += s.bytesReceived || 0;
        o.inRes = s.frameWidth ? `${s.frameWidth}x${s.frameHeight}` : o.inRes;
        o.inFps = Math.round(s.framesPerSecond || 0);
        lossNum += s.packetsLost || 0; lossDen += s.packetsReceived || 0;
        jab = Math.max(jab, (s.jitter || 0) * 1000);
        codecId = s.codecId || codecId;
      }
      if (s.type === 'inbound-rtp' && s.kind === 'audio') {
        inB += s.bytesReceived || 0;
        inAB += s.bytesReceived || 0;
        jab = Math.max(jab, (s.jitter || 0) * 1000);
      }
      if (s.type === 'candidate-pair' && s.state === 'succeeded' && s.nominated !== false) {
        if (typeof s.currentRoundTripTime === 'number') rtt = s.currentRoundTripTime * 1000;
      }
    });
    if (codecId) {
      const c = [...report.values()].find((s) => s.id === codecId);
      if (c?.mimeType) o.codec = c.mimeType.split('/')[1];
    }
    const dt = (now - (peer.prev.t || now)) / 1000;
    if (peer.prev.t) {
      o.outK = kbps(outB - peer.prev.outB, dt);
      o.inK = kbps(inB - peer.prev.inB, dt);
      o.outAK = kbps(outAB - (peer.prev.outAB || 0), dt);
      o.inAK = kbps(inAB - (peer.prev.inAB || 0), dt);
    }
    peer.prev = { t: now, outB, inB, outAB, inAB };
    o.loss = lossDen ? ((lossNum / (lossNum + lossDen)) * 100) : 0;
    o.jitter = jab;
    o.rtt = rtt;
    peer.tile.querySelector('.badge').textContent = o.inRes !== '—' ? `${o.inRes} · ${o.inK}kbps` : o.conn;
    summary.push({
      id: peer.id, name: peer.name, conn: o.conn, codec: o.codec,
      inK: o.inK, outK: o.outK, inRes: o.inRes, inFps: o.inFps, outRes: o.res,
      aInK: o.inAK || 0, aOutK: o.outAK || 0,
      play: (() => {
        const v = peer.tile.querySelector('video');
        return { paused: v.paused, muted: v.muted, vol: v.volume, rs: v.readyState, err: v.error ? v.error.code : null };
      })(),
      loss: Number(o.loss.toFixed(2)), jitter: Number(o.jitter.toFixed(1)), rtt: o.rtt == null ? null : Math.round(o.rtt),
      iceState: peer.pc.iceConnectionState,
      gatherState: peer.pc.iceGatheringState,
      locals,
      pair: selectedPair ? `${selectedPair.nominated ? 'nominated' : 'ok'} rtt=${selectedPair.currentRoundTripTime ?? '—'}` : null,
    });
    out.push(`
      <div class="peer">
        <span class="n">${escapeHtml(peer.name)} <span class="muted">· ${o.conn}</span></span>
        <dl>
          <dt>通话编解码</dt><dd>${o.codec}</dd>
          <dt>接收</dt><dd>${o.inK} kbps · ${o.inFps} fps · ${o.inRes}</dd>
          <dt>发送</dt><dd>${o.outK} kbps · ${o.fps} fps · ${o.res}</dd>
          <dt>丢包率</dt><dd class="${cls(o.loss, 2, 8)}">${o.loss.toFixed(2)} %</dd>
          <dt>抖动</dt><dd class="${cls(o.jitter, 30, 100)}">${o.jitter.toFixed(1)} ms</dd>
          <dt>RTT</dt><dd class="${o.rtt == null ? '' : cls(o.rtt, 60, 200)}">${o.rtt == null ? '—' : o.rtt.toFixed(0) + ' ms'}</dd>
        </dl>
      </div>`);
  }
  box.innerHTML = out.join('');
  postReport(summary);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ------------------------------------------------------------------ 交互 */
async function join() {
  S.room = ($('#roomInput').value || 'demo').trim().slice(0, 32);
  S.name = ($('#nameInput').value || defaultName()).trim().slice(0, 32);
  S.rateCap = Number($('#rateSel').value || 1500);
  const stun = $('#stunInput').value.trim();
  S.iceServers = stun
    ? stun.split(',').map((s) => s.trim()).filter(Boolean).map((u) => ({ urls: u }))
    : [];

  $('#joinBtn').disabled = true;
  const { stream, synthetic } = await openMedia();
  S.localStream = stream;
  S.synthetic = synthetic;
  S.cameraTrack = stream.getVideoTracks()[0] || null;
  S.micTrack = stream.getAudioTracks()[0] || null;
  attachLocalTile(stream);
  await listDevices();
  if (S.cameraTrack) {
    const set = S.cameraTrack.getSettings();
    if (set.deviceId) $('#camSel').value = set.deviceId;
  }
  if (S.micTrack?.getSettings().deviceId) $('#micSel').value = S.micTrack.getSettings().deviceId;
  connect();
  S.statsTimer = setInterval(collectStats, 1000);
  collectStats();
}

function leave() {
  send({ type: 'bye' });
  [...S.peers.keys()].forEach((id) => dropPeer(id, '主动离开'));
  S.ws?.close();
  S.joined = false;
  clearInterval(S.statsTimer);
  S.localStream?.getTracks().forEach((t) => t.stop());
  S.localStream = null;
  document.querySelector('.tile.local')?.remove();
  ['micBtn', 'camBtn', 'camSel', 'micSel', 'rateSel'].forEach((s) => { $(`#${s}`).disabled = true; });
  $('#joinBtn').disabled = false;
  $('#leaveBtn').disabled = true;
}

async function swapTrack(kind, newTrack) {
  for (const peer of S.peers.values()) {
    const sender = peer.senders[kind];
    if (sender) {
      try { await sender.replaceTrack(newTrack || null); } catch (e) { log(`replaceTrack(${kind}) 失败：` + e.message, true); }
    }
  }
}

async function switchDevice(kind) {
  const isCam = kind === 'video';
  const deviceId = isCam ? $('#camSel').value : $('#micSel').value;
  if (!deviceId) return;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      [isCam ? 'video' : 'audio']: isCam
        ? { deviceId: { exact: deviceId }, width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } }
        : { deviceId: { exact: deviceId }, echoCancellation: true, noiseSuppression: true },
    });
    const track = stream.getTracks()[0];
    const old = isCam ? S.cameraTrack : S.micTrack;
    if (isCam) S.cameraTrack = track; else S.micTrack = track;
    old?.stop();
    const ls = S.localStream;
    if (ls) { [...ls.getTracks()].filter((t) => t.kind === track.kind).forEach((t) => ls.removeTrack(t)); ls.addTrack(track); }
    await swapTrack(kind, track);
    if (isCam) attachLocalTile(ls || new MediaStream([track]));
    log(`已切换${isCam ? '摄像头' : '麦克风'}：${track.label}`);
  } catch (e) {
    log(`切换设备失败：${e.name} ${e.message}`, true);
  }
}

function toggleMic() {
  if (!S.micTrack) return;
  S.micTrack.enabled = !S.micTrack.enabled;
  const on = S.micTrack.enabled;
  const btn = $('#micBtn');
  btn.classList.toggle('on', on);
  btn.classList.toggle('off', !on);
  btn.textContent = on ? '🎤 麦克风' : '🔇 已静音';
  send({ type: 'state', mic: on, cam: !!S.cameraTrack?.enabled });
}

function toggleCam() {
  if (!S.cameraTrack) return;
  S.cameraTrack.enabled = !S.cameraTrack.enabled;
  const on = S.cameraTrack.enabled;
  const btn = $('#camBtn');
  btn.classList.toggle('on', on);
  btn.classList.toggle('off', !on);
  btn.textContent = on ? '📷 摄像头' : '🚫 摄像头关';
  document.querySelector('.tile.local')?.classList.toggle('camoff', !on);
  send({ type: 'state', mic: !!S.micTrack?.enabled, cam: on });
}

/* ------------------------------------------------------------------ 启动 */
window.addEventListener('DOMContentLoaded', async () => {
  $('#roomInput').value = S.room;
  $('#nameInput').value = S.name || '';
  $('#nameInput').placeholder = defaultName();

  if (QS.get('stun')) $('#stunInput').value = QS.get('stun');
  if (QS.get('rate')) { $('#rateSel').value = QS.get('rate'); }

  $('#joinBtn').onclick = join;
  $('#leaveBtn').onclick = leave;
  $('#micBtn').onclick = toggleMic;
  $('#camBtn').onclick = toggleCam;
  // iOS：任何一次点按都尝试解锁远端声音；仍被拒时按钮常亮
  $('#soundBtn').onclick = () => ensureAudio();
  installAudioUnlock();
  setInterval(() => {
    if (!S.joined) return showSoundBtn(false);
    const vids = remoteVideos();
    showSoundBtn(vids.length > 0 && vids.some((v) => v.paused || v.muted || v.volume === 0));
  }, 1500);
  $('#camSel').onchange = () => switchDevice('video');
  $('#micSel').onchange = () => switchDevice('audio');
  $('#rateSel').onchange = async () => {
    S.rateCap = Number($('#rateSel').value);
    for (const peer of S.peers.values()) await applyRateCap(peer);
  };
  window.addEventListener('beforeunload', () => { try { send({ type: 'bye' }); } catch (_) {} });

  listDevices().catch(() => {});
  log(`页面就绪 ${location.href}`);

  // 顶部显示手机访问地址（隧道地址由 start.sh 写入 local/tunnel-url.txt）
  fetch('/tunnel').then((r) => (r.ok ? r.json() : null)).then((d) => {
    if (!d || !d.url) return;
    const url = `${d.url}/?room=${encodeURIComponent(S.room)}`;
    const b = $('#phoneBanner');
    b.innerHTML = `📱 手机访问 <code></code><button class="ghost" id="copyUrl">复制</button>`;
    b.querySelector('code').textContent = url;
    b.classList.remove('hidden');
    $('#copyUrl').onclick = async () => {
      try {
        await navigator.clipboard.writeText(url);
        log('手机访问地址已复制到剪贴板');
      } catch (e) {
        log('复制失败，请手动选中复制：' + url, true);
      }
    };
  }).catch(() => {});

  if (QS.get('autostart') === '1') join();
});
