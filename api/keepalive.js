// Supabase 무료 프로젝트 일시정지 방지용
// Vercel이 매일 1번 이 주소를 자동 호출(vercel.json의 crons) → Supabase DB에 가벼운 조회 1건 발생
// 직접 확인: https://(내 사이트)/api/keepalive  → {"ok":true,...}
module.exports = async (req, res) => {
  try {
    // config.js에 넣어 둔 주소·키를 그대로 읽어 씀 (설정을 두 군데 할 필요 없음)
    const host = process.env.VERCEL_PROJECT_PRODUCTION_URL || req.headers.host;
    const cfgText = await (await fetch(`https://${host}/config.js`)).text();
    const url = (cfgText.match(/SUPABASE_URL:\s*"([^"]+)"/) || [])[1];
    const key = (cfgText.match(/SUPABASE_ANON_KEY:\s*"([^"]+)"/) || [])[1];
    if (!url || !key) return res.status(500).json({ ok: false, error: 'config.js에서 주소·키를 찾지 못했습니다' });

    // 없는 회차로 조회 → DB가 실제로 한 번 동작하고 'not_found'를 돌려줌 (데이터는 바뀌지 않음)
    const r = await fetch(`${url}/rest/v1/rpc/checkin_context`, {
      method: 'POST',
      headers: { apikey: key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_session: '00000000-0000-0000-0000-000000000000', p_token: 'keepalive' })
    });
    const body = await r.text();
    res.status(r.ok ? 200 : 502).json({ ok: r.ok, status: r.status, at: new Date().toISOString(), supabase: body.slice(0, 200) });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
};
