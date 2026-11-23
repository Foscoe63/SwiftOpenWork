const a = await api.get(1), b = await api.get(2);
await api.set(a);
if (x) { await api.get(3); await api.set(b); await api.del(4); }
log('no api here');
const c = await api.get(5);
