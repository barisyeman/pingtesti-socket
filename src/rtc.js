/**
 * WebRTC uygulaması seçimi:
 *  1) node-datachannel (libdatachannel, yerel/hızlı) — hazır derlemesi glibc ≥ 2.29 ister
 *  2) werift (saf JavaScript) — derleme gerektirmez; eski glibc'li sistemlerde (AlmaLinux/RHEL 8 vb.) otomatik kullanılır
 * RTC_IMPL=werift ile zorlanabilir.
 */
export async function loadRTC(log = () => {}) {
  if (process.env.RTC_IMPL !== 'werift') {
    try {
      const m = await import('node-datachannel/polyfill');
      return { name: 'node-datachannel', RTCPeerConnection: m.RTCPeerConnection };
    } catch (e) {
      log('info', `node-datachannel yüklenemedi (${String(e.message).split('\n')[0].slice(0, 160)}) → werift kullanılacak`);
    }
  }
  const w = await import('werift');
  return { name: 'werift', RTCPeerConnection: w.RTCPeerConnection };
}
