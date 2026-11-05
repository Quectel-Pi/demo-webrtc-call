/* 界面文案与语言切换。key 用点分隔，{name} 形式为占位符。 */
'use strict';

const STRINGS = {
  zh: {
    'meta.title': 'WebRTC 视频通话 · Quectel Pi',
    'lang.switch': 'EN',
    'lang.name': 'English',

    'brand.title': 'WebRTC 视频通话',
    'sig.offline': '未连接信令',
    'sig.connecting': '连接信令…',
    'sig.connected': '信令已连接 · 我是 {id}',
    'sig.closed': '信令断开',
    'sig.error': '信令错误',

    'form.room': '房间',
    'form.name': '本端名称',
    'form.namePh': '板子 / PC',
    'form.join': '加入房间',
    'form.leave': '离开',

    'hint.title': '开始',
    'hint.s1': '点「加入房间」，允许摄像头和麦克风。',
    'hint.s2': '另一台设备打开同一地址，用相同房间名加入。',
    'hint.s3': '连上后右侧可看码率、分辨率、丢包、RTT。',
    'hint.limit': '一个房间最多 4 路。',
    'hint.waitTitle': '等待对端加入',
    'hint.waitDesc': '房间「{room}」里现在只有你。另一台设备用同样房间名加入即可。',

    'sound.enable': '🔊 点一下开启对方声音',

    'ctl.mic': '🎤 麦克风',
    'ctl.micOff': '🔇 已静音',
    'ctl.cam': '📷 摄像头',
    'ctl.camOff': '🚫 摄像头关',

    'field.camera': '摄像头',
    'field.mic': '麦克风',
    'field.rate': '视频码率上限',
    'field.stun': 'ICE 服务器（可选，逗号分隔）',

    'rate.800': '800 kbps（弱网 / 720p30 够用）',
    'rate.1500': '1.5 Mbps（默认 / 720p30）',
    'rate.3000': '3 Mbps（1080p30）',
    'rate.none': '不限制',
    'rate.unlimited': '不限',

    'stats.title': '实时统计',
    'stats.empty': '加入房间后显示',
    'stats.none': '房间内暂无对端',
    'stats.codec': '通话编解码',
    'stats.in': '接收',
    'stats.out': '发送',
    'stats.loss': '丢包率',
    'stats.jitter': '抖动',
    'stats.rtt': 'RTT',

    'log.title': '日志',

    'tile.local': '本端',
    'tile.connecting': '连接中',
    'tile.camoff': '摄像头已关闭',
    'tile.novideo': '无视频',

    'conn.new': '新建',
    'conn.connecting': '连接中',
    'conn.connected': '已连接',
    'conn.disconnected': '已断开',
    'conn.failed': '失败',
    'conn.closed': '已关闭',

    'banner.phone': '📱 手机访问',
    'banner.copy': '复制',
    'banner.copied': '手机访问地址已复制到剪贴板',
    'banner.copyFail': '复制失败，请手动选中复制：{url}',

    'device.camera': '摄像头',
    'device.mic': '麦克风',
    'name.me': '我',
    'synth.title': 'SYNTHETIC TEST PATTERN',
    'synth.note': '无需摄像头的兜底信号（用于通路自检）',

    'reason.leave': '离开房间',
    'reason.self': '主动离开',
    'reason.signal': '信令断开',

    'log.ready': '页面就绪 {url}',
    'log.sigOpen': '信令已连接 {url}',
    'log.sigClosed': '信令断开',
    'log.sigError': '信令连接错误',
    'log.welcome': '进入房间「{room}」id={id}，已有对端 {n} 个（上限 {limit}）',
    'log.peerJoin': '＋ {name} ({id}) 加入房间',
    'log.peerLeave': '✖ {name} 断开（{reason}）',
    'log.mediaOk': '摄像头/麦克风已打开：{video} / {audio}',
    'log.mediaFail': 'getUserMedia 失败（{name}: {msg}）→ 改用合成测试信号',
    'log.synthAudio': '合成音频不可用：{msg}',
    'log.polite': '{name}：我是 polite 一方，等对方 offer（本端轨道随 answer 一起发）',
    'log.offer': '→ offer 给 {name}（{len}B）',
    'log.offerFail': 'offer 失败：{msg}',
    'log.track': '← {name} 的 {kind} 轨道 ({label})',
    'log.trackMute': '{name} 的 {kind} 静音',
    'log.trackUnmute': '{name} 的 {kind} 恢复',
    'log.connState': '{name} 连接状态 → {state}',
    'log.connFail': '{name} 连接失败，尝试 ICE 重启',
    'log.ice': '{name} ICE → {state}',
    'log.iceErr': 'ICE 候选错误 {code} {text}',
    'log.ignoreOffer': '忽略与 {name} 的 offer 冲突（我是 impolite 一方）',
    'log.answer': '→ answer 给 {name}',
    'log.candFail': 'addIceCandidate 失败：{msg}',
    'log.rateCap': '→ {name} 视频码率上限 {cap}',
    'log.rateCapNone': '不限',
    'log.setParamsFail': 'setParameters 失败：{msg}',
    'log.signalFail': '信令处理异常：{msg}',
    'log.server': '服务器：{msg}',
    'log.deviceSwitched': '已切换{kind}：{label}',
    'log.deviceSwitchFail': '切换设备失败：{name} {msg}',
    'log.replaceFail': 'replaceTrack({kind}) 失败：{msg}',
    'log.audioBlocked': '远端声音被浏览器拦截（{name}）→ 点「开启声音」',
    'log.videoMuted': '画面已显示（静音）；点「开启声音」或屏幕任意处解锁声音（{name}）',
    'log.videoFail': '远端画面无法播放：{name}',
    'log.audioUnlocked': '音频已解锁',
  },

  en: {
    'meta.title': 'WebRTC Video Call · Quectel Pi',
    'lang.switch': '中文',
    'lang.name': '中文',

    'brand.title': 'WebRTC Video Call',
    'sig.offline': 'Signaling offline',
    'sig.connecting': 'Connecting signaling…',
    'sig.connected': 'Signaling connected · I am {id}',
    'sig.closed': 'Signaling closed',
    'sig.error': 'Signaling error',

    'form.room': 'Room',
    'form.name': 'Your name',
    'form.namePh': 'Board / PC',
    'form.join': 'Join room',
    'form.leave': 'Leave',

    'hint.title': 'Get started',
    'hint.s1': 'Tap "Join room" and allow camera and microphone access.',
    'hint.s2': 'Open the same address on another device and join with the same room name.',
    'hint.s3': 'Once connected, bitrate, resolution, packet loss and RTT appear on the right.',
    'hint.limit': 'Up to 4 peers per room.',
    'hint.waitTitle': 'Waiting for a peer',
    'hint.waitDesc': 'You are alone in room "{room}". Join from another device with the same room name.',

    'sound.enable': '🔊 Tap to enable peer audio',

    'ctl.mic': '🎤 Mic',
    'ctl.micOff': '🔇 Muted',
    'ctl.cam': '📷 Camera',
    'ctl.camOff': '🚫 Camera off',

    'field.camera': 'Camera',
    'field.mic': 'Microphone',
    'field.rate': 'Video bitrate cap',
    'field.stun': 'ICE servers (optional, comma separated)',

    'rate.800': '800 kbps (weak network / enough for 720p30)',
    'rate.1500': '1.5 Mbps (default / 720p30)',
    'rate.3000': '3 Mbps (1080p30)',
    'rate.none': 'No limit',
    'rate.unlimited': 'unlimited',

    'stats.title': 'Live statistics',
    'stats.empty': 'Shown after joining',
    'stats.none': 'No peers in this room',
    'stats.codec': 'Codec',
    'stats.in': 'Receive',
    'stats.out': 'Send',
    'stats.loss': 'Packet loss',
    'stats.jitter': 'Jitter',
    'stats.rtt': 'RTT',

    'log.title': 'Log',

    'tile.local': 'Local',
    'tile.connecting': 'Connecting',
    'tile.camoff': 'Camera off',
    'tile.novideo': 'no video',

    'conn.new': 'new',
    'conn.connecting': 'connecting',
    'conn.connected': 'connected',
    'conn.disconnected': 'disconnected',
    'conn.failed': 'failed',
    'conn.closed': 'closed',

    'banner.phone': '📱 Phone',
    'banner.copy': 'Copy',
    'banner.copied': 'Phone URL copied to clipboard',
    'banner.copyFail': 'Copy failed, select and copy manually: {url}',

    'device.camera': 'Camera',
    'device.mic': 'Microphone',
    'name.me': 'Me',
    'synth.title': 'SYNTHETIC TEST PATTERN',
    'synth.note': 'Fallback signal without a camera (link self-test)',

    'reason.leave': 'left the room',
    'reason.self': 'left by user',
    'reason.signal': 'signaling closed',

    'log.ready': 'Page ready {url}',
    'log.sigOpen': 'Signaling connected {url}',
    'log.sigClosed': 'Signaling closed',
    'log.sigError': 'Signaling connection error',
    'log.welcome': 'Joined room "{room}" as {id}, {n} peer(s) present (limit {limit})',
    'log.peerJoin': '+ {name} ({id}) joined the room',
    'log.peerLeave': '✖ {name} disconnected ({reason})',
    'log.mediaOk': 'Camera/microphone opened: {video} / {audio}',
    'log.mediaFail': 'getUserMedia failed ({name}: {msg}) → falling back to synthetic test signal',
    'log.synthAudio': 'Synthetic audio unavailable: {msg}',
    'log.polite': '{name}: I am the polite side, waiting for the offer (local tracks follow in the answer)',
    'log.offer': '→ offer to {name} ({len}B)',
    'log.offerFail': 'Offer failed: {msg}',
    'log.track': '← {kind} track from {name} ({label})',
    'log.trackMute': '{name} {kind} muted',
    'log.trackUnmute': '{name} {kind} resumed',
    'log.connState': '{name} connection state → {state}',
    'log.connFail': '{name} connection failed, restarting ICE',
    'log.ice': '{name} ICE → {state}',
    'log.iceErr': 'ICE candidate error {code} {text}',
    'log.ignoreOffer': 'Ignoring offer collision with {name} (I am the impolite side)',
    'log.answer': '→ answer to {name}',
    'log.candFail': 'addIceCandidate failed: {msg}',
    'log.rateCap': '→ {name} video bitrate cap {cap}',
    'log.rateCapNone': 'unlimited',
    'log.setParamsFail': 'setParameters failed: {msg}',
    'log.signalFail': 'Signaling handling error: {msg}',
    'log.server': 'Server: {msg}',
    'log.deviceSwitched': 'Switched {kind}: {label}',
    'log.deviceSwitchFail': 'Device switch failed: {name} {msg}',
    'log.replaceFail': 'replaceTrack({kind}) failed: {msg}',
    'log.audioBlocked': 'Peer audio blocked by the browser ({name}) → tap "Enable sound"',
    'log.videoMuted': 'Video shown (muted); tap "Enable sound" or anywhere on screen to unmute ({name})',
    'log.videoFail': 'Remote video cannot play: {name}',
    'log.audioUnlocked': 'Audio unlocked',
  },
};

let LANG = 'zh';

function t(key, vars) {
  const dict = STRINGS[LANG] || STRINGS.zh;
  let s = dict[key];
  if (s === undefined) s = STRINGS.zh[key];
  if (s === undefined) s = key;
  if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] !== undefined ? vars[k] : m));
  return s;
}

function detectLang() {
  const saved = localStorage.getItem('lang');
  if (saved === 'zh' || saved === 'en') return saved;
  return (navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en';
}

/* 切换语言：静态文案走 data-i18n，动态内容由页面自己监听 langchange 重绘 */
function applyLang(lang, opt) {
  LANG = lang === 'en' ? 'en' : 'zh';
  if (!opt || !opt.keepStorage) localStorage.setItem('lang', LANG);
  document.documentElement.lang = LANG === 'zh' ? 'zh-CN' : 'en';
  document.title = t('meta.title');

  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-ph]').forEach((el) => {
    el.placeholder = t(el.dataset.i18nPh);
  });
  document.querySelectorAll('[data-i18n-label]').forEach((el) => {
    el.setAttribute('aria-label', t(el.dataset.i18nLabel));
    el.title = t(el.dataset.i18nLabel);
  });

  window.dispatchEvent(new CustomEvent('langchange', { detail: { lang: LANG } }));
}

function toggleLang() {
  applyLang(LANG === 'zh' ? 'en' : 'zh');
}

function initLang() {
  applyLang(detectLang(), { keepStorage: true });
}
