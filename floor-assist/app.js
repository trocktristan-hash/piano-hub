'use strict';
/* Floor Assist — sales-floor helper: Gemini + Best Buy Products/Stores API.
   Everything (keys, customers, history) lives in this browser's localStorage. */

// ---------- small helpers ----------
const $ = (s, el = document) => el.querySelector(s);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = n => (n == null || n === '' || isNaN(n)) ? '' : '$' + Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const LS = {
  get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { toast('Device storage is full — delete some old customers.'); } },
};
let toastTimer;
function toast(msg, ms = 2600) {
  const t = $('#toast'); t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied'); }
  catch { toast('Copy failed'); }
}

const IS_IOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const IS_STANDALONE = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

// ---------- settings ----------
const DEFAULTS = {
  geminiKey: '', bbKey: '', model: 'gemini-2.5-flash', demo: false,
  zip: '32159', store: null, radius: 25, stockMode: 'store', interval: 20, wakeLock: true, budget: '', speechEngine: 'auto',
};
const settings = { ...DEFAULTS, ...LS.get('fa.settings', {}) };
const saveSettings = () => LS.set('fa.settings', settings);

// ---------- customer sessions ----------
let sessions = LS.get('fa.sessions', []);
let current = null;

function newSession() {
  const d = new Date();
  const s = {
    id: uid(), created: Date.now(), updated: Date.now(),
    name: 'Customer ' + d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }),
    notes: '', messages: [], history: [], shortlist: [], transcript: '', tips: [],
  };
  sessions.unshift(s);
  if (sessions.length > 60) sessions.length = 60;
  return s;
}
// Photos are big: keep them in memory for the current visit, but strip them before saving.
function stripMedia(contents) {
  return contents.map(c => ({
    ...c,
    parts: (c.parts || []).map(p => (p.inlineData ? { text: '[photo attached earlier]' } : p)),
  }));
}
function saveSessions() {
  if (current) current.updated = Date.now();
  LS.set('fa.sessions', sessions.map(s => ({ ...s, history: stripMedia(s.history || []) })));
}
function switchSession(s) {
  if (Listen.active) Listen.stop();
  current = s;
  LS.set('fa.current', s.id);
  renderAll();
}

// ---------- Best Buy API ----------
const BB = 'https://api.bestbuy.com/v1';
const LIST_FIELDS = 'sku,name,salePrice,regularPrice,onSale,image,thumbnailImage,url,customerReviewAverage,customerReviewCount,manufacturer,modelNumber,shortDescription,inStoreAvailability,color,categoryPath.name';
const DETAIL_FIELDS = LIST_FIELDS + ',longDescription,features.feature,details.name,details.value,includedItemList.includedItem,height,width,depth,weight,warrantyLabor,warrantyParts,upc';

// Best Buy allows ~5 requests/sec per key; space calls out a bit.
let bbChain = Promise.resolve();
let bbLast = 0;
function bbSlot() {
  bbChain = bbChain.then(async () => {
    const wait = bbLast + 230 - Date.now();
    if (wait > 0) await sleep(wait);
    bbLast = Date.now();
  });
  return bbChain;
}
async function bbFetch(path, params = {}) {
  if (!settings.bbKey) throw new Error('Add your Best Buy API key in Settings (or turn on Demo inventory).');
  const qs = new URLSearchParams({ format: 'json', apiKey: settings.bbKey, ...params });
  const url = `${BB}${path}?${qs}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    await bbSlot();
    let res;
    try { res = await fetch(url); }
    catch { throw new Error('Could not reach the Best Buy API (network or browser blocked it).'); }
    if (res.status === 429 || res.status === 503) { await sleep(800 * (attempt + 1)); continue; }
    if (res.status === 404) return null;
    if (!res.ok) {
      let msg = `Best Buy API error ${res.status}`;
      try { const j = await res.json(); msg += ': ' + (j.error?.message || j.errorMessage || JSON.stringify(j).slice(0, 160)); } catch {}
      if (res.status === 403) msg += ' — check your Best Buy API key.';
      throw new Error(msg);
    }
    return res.json();
  }
  throw new Error('Best Buy API is rate-limiting — try again in a few seconds.');
}

function normProduct(p) {
  return {
    sku: p.sku, name: p.name,
    price: p.salePrice, regularPrice: p.regularPrice, onSale: !!p.onSale && p.regularPrice > p.salePrice,
    image: p.image || p.thumbnailImage || '', url: p.url || `https://www.bestbuy.com/site/${p.sku}.p?skuId=${p.sku}`,
    rating: p.customerReviewAverage, reviews: p.customerReviewCount,
    brand: p.manufacturer, model: p.modelNumber, color: p.color,
    summary: (p.shortDescription || '').slice(0, 220),
    category: (p.categoryPath || []).map(c => c.name).slice(-2).join(' › '),
    soldInStores: p.inStoreAvailability,
  };
}

const SORTS = { price_low: 'salePrice.asc', price_high: 'salePrice.dsc', top_rated: 'customerReviewAverage.dsc', best_selling: 'bestSellingRank.asc' };

async function bbSearch({ query, min_price, max_price, sort }, pageSize = 30) {
  const words = String(query || '').toLowerCase().replace(/[^a-z0-9.\- ]/g, ' ').split(/\s+/).filter(Boolean).slice(0, 6);
  if (!words.length) return [];
  const build = ws => {
    const f = ws.map(w => 'search=' + encodeURIComponent(w));
    f.push('active=true');
    if (min_price) f.push(`salePrice>=${Number(min_price)}`);
    if (max_price) f.push(`salePrice<=${Number(max_price)}`);
    return `/products(${f.join('&')})`;
  };
  const params = { show: LIST_FIELDS, pageSize: String(pageSize) };
  if (SORTS[sort]) params.sort = SORTS[sort];
  // Try the full query, then progressively looser ones if nothing matches.
  const attempts = [words];
  if (words.length > 3) attempts.push(words.slice(0, 3));
  if (words.length > 2) attempts.push(words.slice(0, 2));
  for (const ws of attempts) {
    const data = await bbFetch(build(ws), params);
    const list = (data?.products || []).map(normProduct);
    if (list.length) return list;
  }
  return [];
}

async function bbBySku(sku, fields = DETAIL_FIELDS) {
  const p = await bbFetch(`/products/${encodeURIComponent(sku)}.json`, { show: fields });
  return p ? { ...normProduct(p), raw: p } : null;
}
async function bbByUpc(upc) {
  const data = await bbFetch(`/products(upc=${encodeURIComponent(upc)})`, { show: DETAIL_FIELDS });
  const p = data?.products?.[0];
  return p ? { ...normProduct(p), raw: p } : null;
}

// ---- store stock ----
const stockCache = new Map(); // sku -> { t, stores }
function areaZip() { return settings.store?.postalCode || settings.zip || '32159'; }

async function storesWithStock(sku) {
  const hit = stockCache.get(sku);
  if (hit && Date.now() - hit.t < 10 * 60 * 1000) return hit.stores;
  let stores = [];
  if (settings.demo) stores = Demo.stock(sku);
  else {
    try {
      const data = await bbFetch(`/products/${encodeURIComponent(sku)}/stores.json`, { postalCode: areaZip() });
      stores = (data?.stores || []).map(s => ({
        id: String(s.storeID ?? s.storeId ?? ''), name: s.name, city: s.city,
        distance: s.distance, lowStock: !!s.lowStock,
      }));
    } catch (e) {
      if (/API key|reach/.test(e.message)) throw e;
      stores = []; // not pickup-eligible etc.
    }
  }
  stockCache.set(sku, { t: Date.now(), stores });
  return stores;
}

/* Returns { status: 'in' | 'low' | 'near' | 'none', label, nearby: [...] } */
async function stockFor(sku) {
  const stores = (await storesWithStock(sku)).filter(s => s.distance == null || s.distance <= settings.radius);
  const mine = settings.store && stores.find(s => s.id === String(settings.store.id));
  if (mine) return { status: mine.lowStock ? 'low' : 'in', label: mine.lowStock ? 'Low stock here' : 'In stock here', nearby: stores.map(s => s.name) };
  if (stores.length) {
    const n = stores[0];
    return { status: 'near', label: `Not here · ${n.name || n.city}${n.distance != null ? ` (${Math.round(n.distance)} mi)` : ''}`, nearby: stores.map(s => s.name) };
  }
  return { status: 'none', label: 'Not in stock nearby', nearby: [] };
}

/* Where products come from: Best Buy API (key), demo data, or web search + the associate's stock notebook. */
const source = () => (settings.demo ? 'demo' : settings.bbKey ? 'api' : 'web');

function effectiveMode() {
  if (source() === 'web') return settings.stockMode === 'any' ? 'any' : 'store';
  if (settings.stockMode === 'store' && !settings.store?.id) return 'nearby'; // API mode needs a real store id
  return settings.stockMode;
}

const normId = s => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const isSku = s => /^\d{6,8}$/.test(String(s ?? ''));
const idLabel = p => (isSku(p.sku) ? `SKU ${p.sku}` : p.model ? `Model ${p.model}` : '');
function ago(t) {
  const m = Math.round((Date.now() - t) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  if (m < 1440) return `${Math.round(m / 60)}h ago`;
  return `${Math.round(m / 1440)}d ago`;
}
// bestbuy.com search for the SKU/model; shows pickup availability for the store set as "My Store" (and opens the Best Buy app if installed).
const bbLink = p => `https://www.bestbuy.com/site/searchpage.jsp?st=${encodeURIComponent(isSku(p.sku) ? p.sku : p.model || p.name)}`;

/* Stock notebook: what the associate has verified (bestbuy.com / app / on the floor). Used for stock in web mode. */
const STOCK_FRESH_MS = 7 * 24 * 3600 * 1000;
const StockBook = {
  items: LS.get('fa.stockbook', []), // { id, sku, model, name, price, status: 'in'|'low'|'out', at, src }
  save() { LS.set('fa.stockbook', this.items.slice(0, 2000)); },
  find(p) {
    const sku = isSku(p.sku) ? String(p.sku) : null;
    const model = normId(p.model), name = normId(p.name);
    return this.items.find(e => (sku && e.sku === sku) || (model.length >= 4 && normId(e.model) === model) || (name && normId(e.name) === name));
  },
  mark(p, status, src = 'manual') {
    let e = this.find(p);
    if (e) this.items.splice(this.items.indexOf(e), 1); else e = { id: uid() };
    Object.assign(e, {
      sku: isSku(p.sku) ? String(p.sku) : e.sku || null, model: p.model || e.model || '', name: p.name || e.name || '',
      price: p.price ?? e.price ?? null, status, at: Date.now(), src,
    });
    this.items.unshift(e);
    this.save();
    return e;
  },
  remove(id) { this.items = this.items.filter(e => e.id !== id); this.save(); },
  stock(p) {
    const e = this.find(p);
    if (!e) return { status: 'unk', label: 'Not checked yet' };
    const word = { in: 'In stock', low: 'Low stock', out: 'Out of stock' }[e.status];
    if (Date.now() - e.at > STOCK_FRESH_MS) return { status: 'unk', label: `${word} ${ago(e.at)} — recheck` };
    return { status: e.status === 'out' ? 'none' : e.status, label: `${word} · ${ago(e.at)}` };
  },
};

const textOf = r => (r.candidates?.[0]?.content?.parts || []).filter(p => p.text && !p.thought).map(p => p.text).join('').trim();
function parseJSON(t, wantArray = true) {
  const m = String(t).match(wantArray ? /\[[\s\S]*\]/ : /\{[\s\S]*\}/);
  if (!m) return wantArray ? [] : null;
  try { return JSON.parse(m[0]); } catch { return wantArray ? [] : null; }
}

/* Web mode: Gemini with Google Search finds real Best Buy products (no Best Buy API key needed). */
const Web = {
  async ask(text, { grounded = true, image } = {}) {
    const parts = image ? [{ inlineData: image }, { text }] : [{ text }];
    const r = await gemini({
      contents: [{ role: 'user', parts }],
      ...(grounded ? { tools: [{ google_search: {} }] } : {}),
      generationConfig: { temperature: 0.2 },
    });
    return textOf(r);
  },
  product(x) {
    const digits = String(x.sku ?? '').replace(/\D/g, '');
    const p = {
      name: String(x.name || '').trim(), brand: x.brand || '', model: String(x.model || '').trim(),
      price: Number(String(x.price ?? '').replace(/[^0-9.]/g, '')) || null,
      summary: String(x.summary || '').slice(0, 200), image: '', web: true,
    };
    p.sku = isSku(digits) ? Number(digits) : 'w' + normId(p.model || p.name).slice(0, 30);
    p.url = bbLink(p);
    return p;
  },
  async search({ query, min_price, max_price }, n = 8) {
    const price = [min_price && `at least $${min_price}`, max_price && `at most $${max_price}`].filter(Boolean).join(' and ');
    const t = await this.ask(`Search bestbuy.com for products currently sold by Best Buy that match: "${query}"${price ? ` priced ${price}` : ''}.
Return ONLY a JSON array (no other text) of up to ${n} items, best matches first:
[{"name": "...", "brand": "...", "model": "manufacturer model number", "sku": "7-digit Best Buy SKU or null if you are not certain", "price": current Best Buy price as a number or null, "summary": "one short line"}]
Use real Best Buy listings only. Never guess a SKU.`);
    return parseJSON(t).filter(x => x && x.name).map(x => this.product(x))
      .filter(p => !max_price || !p.price || p.price <= max_price * 1.05);
  },
  async details(p) {
    return this.ask(`Using bestbuy.com and the manufacturer's site, give the key specs and features of: ${p.name}${p.model ? ` (model ${p.model})` : ''}${isSku(p.sku) ? ` (Best Buy SKU ${p.sku})` : ''}. Plain bullet list, max 15 bullets, include what's in the box and the current Best Buy price if listed.`);
  },
  async identify(code) {
    const t = await this.ask(`What product has ${code.length >= 11 ? 'UPC/EAN barcode' : 'Best Buy SKU'} ${code}? Search the web (bestbuy.com preferred).
Return ONLY JSON: {"name": "...", "brand": "...", "model": "...", "sku": "Best Buy SKU or null", "price": number or null, "summary": "one line"}. If you can't find it, return {}.`);
    const x = parseJSON(t, false);
    if (!x?.name) return null;
    if (code.length < 11 && !x.sku) x.sku = code;
    return this.product(x);
  },
  async readTags(image) {
    const t = await this.ask(`This photo was taken inside a Best Buy store: shelf tags, price labels, product boxes or a display. List every distinct product you can actually read.
Return ONLY a JSON array: [{"name": "...", "brand": "...", "model": "model number if visible", "sku": "Best Buy SKU digits if visible", "price": number or null}]. Don't invent anything you can't read.`, { grounded: false, image });
    return parseJSON(t).filter(x => x && x.name).map(x => this.product(x));
  },
};

function effectiveModeLabel() {
  const mode = effectiveMode();
  if (source() === 'web') return mode === 'any' ? 'no stock filter (web mode)' : 'web mode: stock is from the associate\'s stock notebook; items marked out are hidden, "Not checked yet" = unverified';
  return mode === 'store' ? `in stock at ${settings.store.name}` : mode === 'nearby' ? `in stock within ${settings.radius} mi of ${areaZip()}` : 'no stock filter';
}

/* Walk the search results in order, checking stock, until we have `want` matches. */
async function filterByStock(products, want) {
  const mode = effectiveMode();
  if (source() === 'web') {
    let list = products.map(p => ({ ...p, stock: StockBook.stock(p) }));
    if (mode !== 'any') list = list.filter(p => p.stock.status !== 'none');
    const rank = s => ({ in: 0, low: 1 }[s] ?? 2);
    list.sort((a, b) => rank(a.stock.status) - rank(b.stock.status)); // verified in-stock first, relevance otherwise
    return { results: list.slice(0, want), checked: products.length };
  }
  const out = [];
  let checked = 0;
  const maxChecks = mode === 'any' ? want : 24;
  const queue = products.slice(0, Math.max(maxChecks, want));
  let i = 0;
  async function worker() {
    while (i < queue.length && out.length < want && checked < maxChecks) {
      const p = queue[i++]; checked++;
      let stock;
      try { stock = await stockFor(p.sku); } catch (e) { if (mode === 'any') stock = { status: 'unk', label: 'Stock unknown' }; else throw e; }
      const ok = mode === 'any' || (mode === 'store' ? (stock.status === 'in' || stock.status === 'low') : stock.status !== 'none');
      if (ok && out.length < want) out.push({ ...p, stock });
    }
  }
  await Promise.all([worker(), worker(), worker()]);
  // keep original relevance order
  const order = new Map(products.map((p, idx) => [p.sku, idx]));
  out.sort((a, b) => order.get(a.sku) - order.get(b.sku));
  return { results: out, checked };
}

// ---------- demo inventory (no Best Buy key needed) ----------
const Demo = (() => {
  const P = (sku, name, price, reg, brand, cat, rating, reviews, summary) =>
    ({ sku, name, price, regularPrice: reg, onSale: reg > price, brand, model: 'DEMO-' + sku, category: cat, rating, reviews, summary, image: '', url: `https://www.bestbuy.com/site/searchpage.jsp?st=${encodeURIComponent(name)}`, soldInStores: true });
  const items = [
    P(9000001, 'Samsung 65" Class Crystal UHD 4K Smart TV', 449.99, 529.99, 'Samsung', 'TVs › 65-Inch TVs', 4.6, 3120, '4K UHD, HDR10+, Tizen smart platform.'),
    P(9000002, 'LG 65" Class C4 Series OLED evo 4K Smart TV', 1799.99, 2299.99, 'LG', 'TVs › OLED TVs', 4.8, 940, 'Self-lit OLED pixels, 144Hz, great for gaming and movies.'),
    P(9000003, 'TCL 55" Class Q6 QLED 4K Smart Google TV', 299.99, 349.99, 'TCL', 'TVs › 55-Inch TVs', 4.4, 2105, 'QLED color, Google TV, budget friendly.'),
    P(9000004, 'Sony 75" Class BRAVIA 7 Mini LED 4K Google TV', 1599.99, 1999.99, 'Sony', 'TVs › 75-Inch TVs', 4.7, 410, 'Mini LED brightness, excellent motion handling.'),
    P(9000005, 'Insignia 32" Class F20 Series LED HD Smart Fire TV', 99.99, 129.99, 'Insignia', 'TVs › 32-Inch TVs', 4.5, 8800, 'Small room or bedroom TV with Fire TV built in.'),
    P(9000011, 'Apple MacBook Air 13" Laptop M3 chip 16GB Memory 256GB SSD', 899.00, 1099.00, 'Apple', 'Laptops › MacBooks', 4.8, 2600, 'All-day battery, fanless, great for students.'),
    P(9000012, 'HP 15.6" Laptop Intel Core i5 8GB Memory 512GB SSD', 449.99, 579.99, 'HP', 'Laptops › Windows Laptops', 4.3, 1500, 'Everyday laptop for browsing, school and office.'),
    P(9000013, 'ASUS ROG Strix G16 Gaming Laptop RTX 4060 16GB 1TB', 1199.99, 1399.99, 'ASUS', 'Laptops › Gaming Laptops', 4.6, 720, '165Hz display, RTX 4060 graphics.'),
    P(9000014, 'Microsoft Surface Laptop 7th Edition Snapdragon X Plus 16GB 512GB', 999.99, 999.99, 'Microsoft', 'Laptops › 2-in-1 / Copilot+ PCs', 4.5, 380, 'Copilot+ PC, long battery life, touchscreen.'),
    P(9000015, 'Lenovo Chromebook Duet 11" 128GB', 279.99, 339.99, 'Lenovo', 'Laptops › Chromebooks', 4.4, 990, 'Detachable keyboard, great for kids and travel.'),
    P(9000021, 'Apple AirPods Pro 2 Wireless Earbuds with USB-C', 189.99, 249.99, 'Apple', 'Headphones › Earbuds', 4.8, 15000, 'Active noise cancelling, hearing health features.'),
    P(9000022, 'Sony WH-1000XM5 Wireless Noise Cancelling Headphones', 329.99, 399.99, 'Sony', 'Headphones › Over-Ear', 4.7, 6400, 'Industry-leading noise cancelling, 30-hour battery.'),
    P(9000023, 'Bose QuietComfort Ultra Earbuds', 249.00, 299.00, 'Bose', 'Headphones › Earbuds', 4.5, 2100, 'Immersive audio, top-tier ANC.'),
    P(9000024, 'JBL Tune 520BT Wireless On-Ear Headphones', 39.99, 49.99, 'JBL', 'Headphones › On-Ear', 4.5, 5100, 'Budget wireless headphones, 57-hour battery.'),
    P(9000031, 'Sonos Arc Ultra Soundbar with Dolby Atmos', 999.00, 999.00, 'Sonos', 'Home Audio › Soundbars', 4.7, 300, 'Premium Atmos soundbar, Trueplay tuning.'),
    P(9000032, 'Samsung HW-B550 2.1ch Soundbar with Wireless Subwoofer', 149.99, 229.99, 'Samsung', 'Home Audio › Soundbars', 4.6, 4300, 'Big bass upgrade over TV speakers.'),
    P(9000033, 'Rocketfish 32"-75" Full-Motion TV Wall Mount', 99.99, 129.99, 'Rocketfish', 'TV Accessories › Wall Mounts', 4.7, 3900, 'Tilt and swivel, fits most 32–75" TVs.'),
    P(9000034, 'Insignia 6ft 4K Ultra HD HDMI 2.1 Cable', 24.99, 29.99, 'Insignia', 'TV Accessories › HDMI Cables', 4.8, 2600, '48Gbps, 4K120 / 8K ready.'),
    P(9000041, 'Apple iPad 11-inch Wi-Fi 128GB', 329.99, 349.99, 'Apple', 'Tablets › iPad', 4.8, 4100, 'Great everyday tablet.'),
    P(9000042, 'Samsung Galaxy Tab A9+ 11" 64GB', 179.99, 219.99, 'Samsung', 'Tablets › Android Tablets', 4.5, 2500, 'Budget Android tablet, big screen.'),
    P(9000051, 'Nintendo Switch 2 Console', 449.99, 449.99, 'Nintendo', 'Video Games › Consoles', 4.8, 9000, 'Next-gen Nintendo hybrid console.'),
    P(9000052, 'Sony PlayStation 5 Slim Console Digital Edition', 399.99, 449.99, 'Sony', 'Video Games › Consoles', 4.8, 12000, 'PS5 performance, smaller design.'),
    P(9000053, 'Xbox Wireless Controller - Carbon Black', 49.99, 59.99, 'Microsoft', 'Video Games › Controllers', 4.7, 20000, 'Works with Xbox, PC and mobile.'),
    P(9000061, 'Canon EOS R50 Mirrorless Camera with 18-45mm Lens', 679.99, 799.99, 'Canon', 'Cameras › Mirrorless', 4.7, 900, 'Beginner-friendly 4K vlogging camera.'),
    P(9000071, 'Ninja Air Fryer Pro 5-qt', 89.99, 129.99, 'Ninja', 'Small Appliances › Air Fryers', 4.8, 18000, '4-in-1 air fry, roast, reheat, dehydrate.'),
    P(9000072, 'LG 27 cu. ft. French Door Smart Refrigerator - Stainless Steel', 1899.99, 2499.99, 'LG', 'Appliances › Refrigerators', 4.5, 600, 'Ice and water dispenser, smart diagnosis.'),
    P(9000081, 'Ring Battery Doorbell Plus', 119.99, 149.99, 'Ring', 'Smart Home › Video Doorbells', 4.5, 7000, 'Head-to-toe HD+ video, easy install.'),
    P(9000082, 'eero 6+ Mesh Wi-Fi System (3-pack)', 199.99, 299.99, 'eero', 'Networking › Mesh Wi-Fi', 4.6, 5200, 'Whole-home Wi-Fi up to 4,500 sq ft.'),
  ];
  const STORE = { id: '9999', name: 'Lady Lake (demo)', city: 'Lady Lake', region: 'FL', postalCode: '32159' };
  const hash = n => { let x = n * 2654435761 % 4294967296; return x / 4294967296; };
  return {
    STORE,
    search({ query, min_price, max_price, sort }) {
      const ws = String(query || '').toLowerCase().split(/\s+/).filter(w => w.length > 1);
      let list = items.map(p => {
        const hay = (p.name + ' ' + p.category + ' ' + p.brand + ' ' + p.summary).toLowerCase();
        return { p, score: ws.reduce((s, w) => s + (hay.includes(w.replace(/s$/, '')) ? 1 : 0), 0) };
      }).filter(x => x.score > 0);
      if (min_price) list = list.filter(x => x.p.price >= min_price);
      if (max_price) list = list.filter(x => x.p.price <= max_price);
      list.sort((a, b) => b.score - a.score);
      let out = list.map(x => x.p);
      if (sort === 'price_low') out.sort((a, b) => a.price - b.price);
      if (sort === 'price_high') out.sort((a, b) => b.price - a.price);
      if (sort === 'top_rated') out.sort((a, b) => b.rating - a.rating);
      return out;
    },
    bySku: sku => items.find(p => String(p.sku) === String(sku)) || null,
    stock(sku) {
      const h = hash(Number(sku));
      const stores = [];
      if (h > 0.2) stores.push({ id: STORE.id, name: STORE.name, city: 'Lady Lake', distance: 0, lowStock: h < 0.35 });
      if (h > 0.1) stores.push({ id: '9998', name: 'Ocala (demo)', city: 'Ocala', distance: 22, lowStock: false });
      return stores;
    },
    details(p) {
      return { ...p, raw: { longDescription: p.summary + ' (Demo data — connect a Best Buy API key for real specs.)', features: [{ feature: p.summary }] } };
    },
  };
})();

// Unified product access (real API or demo)
const Inventory = {
  async search(args, pageSize) {
    if (settings.demo) return Demo.search(args);
    return settings.bbKey ? bbSearch(args, pageSize) : Web.search(args);
  },
  async details(sku) {
    if (settings.demo) { const p = Demo.bySku(sku); return p ? Demo.details(p) : null; }
    return bbBySku(sku);
  },
  async upc(code) { return settings.demo ? null : bbByUpc(code); },
  async lookup(code) {
    if (source() === 'web') return Web.identify(code);
    let p = code.length >= 11 ? await this.upc(code) : null;
    return p || this.details(code);
  },
};

// ---------- Gemini ----------
function modelName() { return (settings.model || DEFAULTS.model).trim().replace(/^models\//, ''); }

async function gemini(body) {
  if (!settings.geminiKey) throw new Error('Add your Gemini API key in Settings ⚙ first.');
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(modelName())}:generateContent`;
  for (let attempt = 0; attempt < 3; attempt++) {
    let res;
    try {
      res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': settings.geminiKey }, body: JSON.stringify(body) });
    } catch { throw new Error('Could not reach Gemini — check your connection.'); }
    if (res.status === 429 || res.status === 503) { await sleep(1500 * (attempt + 1)); continue; }
    const j = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error('Gemini: ' + (j.error?.message || res.status));
    return j;
  }
  throw new Error('Gemini is busy or you hit the rate limit — try again shortly.');
}

const TOOL_DECLS = [{
  functionDeclarations: [
    {
      name: 'search_products',
      description: 'Search the Best Buy catalog. Results are already filtered to what is in stock per the associate\'s stock setting, and include price, rating and stock status. Use short keyword queries (product type + key spec/brand), e.g. "65 inch oled tv", "gaming laptop rtx", "wireless earbuds noise cancelling". Call several times with different queries to cover options or accessories.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Short keyword search, 1-5 words.' },
          min_price: { type: 'number' },
          max_price: { type: 'number' },
          sort: { type: 'string', enum: ['relevance', 'price_low', 'price_high', 'top_rated', 'best_selling'] },
          limit: { type: 'integer', description: 'How many in-stock results to return (1-8, default 6).' },
        },
        required: ['query'],
      },
    },
    {
      name: 'get_product_details',
      description: 'Get full description, features and specs for one product. Use before making specific spec claims or comparisons.',
      parameters: { type: 'object', properties: { sku: { type: 'string', description: 'Best Buy SKU, or the model number if there is no SKU.' } }, required: ['sku'] },
    },
    {
      name: 'check_stock',
      description: 'Check store stock for specific products (e.g. ones the customer mentions or saw online).',
      parameters: { type: 'object', properties: { skus: { type: 'array', items: { type: 'string' }, description: 'Best Buy SKUs (or model numbers if no SKU).' } }, required: ['skus'] },
    },
  ],
}];

const compact = p => ({
  sku: isSku(p.sku) ? p.sku : undefined, model: p.model || undefined, name: p.name, price: p.price, regular_price: p.onSale ? p.regularPrice : undefined,
  rating: p.rating, reviews: p.reviews, brand: p.brand, category: p.category, summary: p.summary || undefined,
  stock: p.stock?.label,
});

const TOOLS = {
  async search_products(args, found, onStatus) {
    const limit = Math.min(8, Math.max(1, Number(args.limit) || 6));
    const budget = Number(settings.budget) || 0;
    const a = { ...args };
    if (budget && (!a.max_price || a.max_price > budget)) a.max_price = budget;
    onStatus?.(`Searching “${a.query}”${a.max_price ? ` under ${money(a.max_price)}` : ''}…`);
    const raw = await Inventory.search(a, 30);
    if (!raw.length) return { results: [], note: 'No catalog matches. Try simpler or different keywords.' };
    onStatus?.(`Checking stock for “${a.query}”…`);
    const { results, checked } = await filterByStock(raw, limit);
    results.forEach(p => found.set(String(p.sku), p));
    return {
      stock_filter: effectiveModeLabel(),
      results: results.map(compact),
      note: results.length ? undefined : `${raw.length} catalog matches but none in stock (checked ${checked}). Try a different query, a higher budget, or suggest nearby/online.`,
    };
  },
  async get_product_details({ sku }, found, onStatus) {
    onStatus?.(`Reading specs for ${sku}…`);
    if (source() === 'web') {
      const key = normId(sku);
      let p = [...found.values()].find(x => String(x.sku) === String(sku) || normId(x.model) === key);
      if (!p) { p = Web.product({ name: String(sku), model: isSku(sku) ? '' : String(sku), sku: isSku(sku) ? sku : null }); }
      return { ...compact({ ...p, stock: StockBook.stock(p) }), details: await Web.details(p) };
    }
    const p = await Inventory.details(sku);
    if (!p) return { error: 'SKU not found' };
    const r = p.raw || {};
    if (!found.has(String(p.sku))) {
      try { p.stock = await stockFor(p.sku); } catch {}
      found.set(String(p.sku), p);
    }
    return {
      ...compact(p),
      description: String(r.longDescription || '').replace(/<[^>]+>/g, ' ').slice(0, 1500),
      features: (r.features || []).map(f => f.feature).slice(0, 12),
      specs: Object.fromEntries((r.details || []).slice(0, 40).map(d => [d.name, d.value])),
      included: (r.includedItemList || []).map(i => i.includedItem).slice(0, 10),
      dimensions: [r.width, r.height, r.depth].filter(Boolean).join(' x ') || undefined,
      weight: r.weight || undefined,
    };
  },
  async check_stock({ skus }, found, onStatus) {
    onStatus?.('Checking stock…');
    const out = [];
    if (source() === 'web') {
      for (const id of (skus || []).slice(0, 8)) {
        const key = normId(id);
        const p = [...found.values()].find(x => String(x.sku) === String(id) || normId(x.model) === key)
          || { sku: isSku(id) ? Number(id) : null, model: isSku(id) ? '' : String(id), name: '' };
        out.push({ product: id, stock: StockBook.stock(p).label });
      }
      return { results: out, note: 'Web mode: "Not checked yet" means the associate should tap Check stock on the card (bestbuy.com) and mark it.' };
    }
    for (const sku of (skus || []).slice(0, 8)) {
      try {
        const stock = await stockFor(sku);
        out.push({ sku, stock: stock.label, other_stores: stock.nearby.slice(0, 4) });
        const p = found.get(String(sku)) || await Inventory.details(sku).catch(() => null);
        if (p) found.set(String(p.sku), { ...p, stock });
      } catch (e) { out.push({ sku, error: e.message }); }
    }
    return { results: out };
  },
};

function systemPrompt(extra = '') {
  const mode = effectiveMode();
  const store = settings.store ? `${settings.store.name} (${settings.store.city}, ${settings.store.region})${settings.store.id ? `, store #${settings.store.id}` : ''}` : `ZIP ${areaZip()}`;
  const stockRule = source() === 'web'
    ? `There is NO live inventory feed. Products come from web search; each result's stock comes from the associate's own stock notebook (things they verified on bestbuy.com, the Best Buy app, or on the floor). Recommend items marked In stock first. Items "Not checked yet" may be suggested, but say they need a quick stock check (the Check stock button on the card). Never claim something is in stock unless its stock status says so. Prices come from the web: say "about $X".`
    : mode === 'store' ? `Only recommend products the tools report as in stock at ${store}.`
    : mode === 'nearby' ? `Prefer items in stock at the associate's store; nearby-store stock (within ${settings.radius} mi) is acceptable but say so.`
    : 'Stock filter is off; still mention stock status when known.';
  return `You are "Floor Assist", a fast, practical sidekick for a Best Buy sales associate working the floor at ${store}. Today is ${new Date().toDateString()}.
The associate describes a customer's needs (sometimes with photos of a product, room, cable, receipt or setup). Your job: understand the need and find real products from the inventory tools.

Rules:
- ALWAYS use search_products before recommending anything. Never invent products, SKUs, prices or stock — only use what the tools return.
- ${stockRule}
${settings.budget ? `- The customer's budget is ${money(settings.budget)} (already applied to searches).` : ''}
- If the request is vague, still search for sensible options, then suggest 1-2 quick questions the associate can ask.
- If a photo shows a product, identify it (brand/model/type) and search for it or compatible items/replacements.
- Keep answers short and scannable on a phone — the associate is standing with a customer.

Format:
**Need:** one line.
**Top picks:** 2-4 bullets: **Short name** (SKU 1234567, or the model number if there's no SKU) – $price – why it fits (one line). Mark one as the best fit.
**Ask:** 1-2 questions to narrow it down (skip if clear).
**Add-ons:** 1-3 relevant accessories you actually found in stock (cables, mounts, cases, chargers, soundbar, etc.), plus a reminder to offer protection/membership when it fits — don't quote plan prices.
${current?.notes ? `\nAssociate's notes about this customer: ${current.notes}` : ''}
${extra}`;
}

/* Keep context manageable: last ~24 turns, photos only in the 2 most recent user turns. */
function trimHistory(h) {
  let out = h.slice(-24);
  while (out.length && !(out[0].role === 'user' && out[0].parts.some(p => p.text || p.inlineData))) out = out.slice(1);
  let photoTurns = 0;
  for (let i = out.length - 1; i >= 0; i--) {
    if (out[i].role === 'user' && out[i].parts.some(p => p.inlineData)) {
      photoTurns++;
      if (photoTurns > 2) out[i] = { ...out[i], parts: out[i].parts.map(p => (p.inlineData ? { text: '[photo attached earlier]' } : p)) };
    }
  }
  return out;
}

/* Runs Gemini with tools until it produces a final answer. Mutates nothing on failure. */
async function runAgent(history, { extra = '', onStatus } = {}) {
  const work = trimHistory(history);
  const found = new Map();
  for (let round = 0; round < 8; round++) {
    onStatus?.(round === 0 ? 'Thinking…' : 'Putting it together…');
    const resp = await gemini({
      systemInstruction: { parts: [{ text: systemPrompt(extra) }] },
      contents: work,
      tools: TOOL_DECLS,
      generationConfig: { temperature: 0.4 },
    });
    const cand = resp.candidates?.[0];
    if (!cand?.content?.parts) {
      const why = resp.promptFeedback?.blockReason || cand?.finishReason || 'empty response';
      throw new Error('Gemini returned no answer (' + why + ').');
    }
    const content = { ...cand.content, role: 'model' };
    work.push(content);
    const calls = content.parts.filter(p => p.functionCall);
    if (!calls.length) {
      const text = content.parts.filter(p => p.text && !p.thought).map(p => p.text).join('').trim();
      return { text, products: [...found.values()], history: work };
    }
    const responses = await Promise.all(calls.map(async ({ functionCall: fc }) => {
      let response;
      try {
        const fn = TOOLS[fc.name];
        response = fn ? await fn(fc.args || {}, found, onStatus) : { error: 'unknown tool' };
      } catch (e) { response = { error: e.message }; }
      const fr = { name: fc.name, response };
      if (fc.id) fr.id = fc.id;
      return { functionResponse: fr };
    }));
    work.push({ role: 'user', parts: responses });
  }
  throw new Error('The assistant took too many steps — try rephrasing.');
}

/* Pick product cards to show: ones mentioned by SKU in the answer (in that order), else the top found. */
function cardsFor(text, products) {
  const t = String(text).toLowerCase();
  const pos = p => {
    const hits = [isSku(p.sku) ? t.indexOf(String(p.sku)) : -1, p.model && p.model.length >= 4 ? t.indexOf(p.model.toLowerCase()) : -1].filter(i => i >= 0);
    return hits.length ? Math.min(...hits) : -1;
  };
  const seen = products.map(p => [pos(p), p]).filter(([i]) => i >= 0).sort((a, b) => a[0] - b[0]).map(([, p]) => p);
  return (seen.length ? seen : products.slice(0, 6)).map(slimProduct);
}
const slimProduct = p => ({
  sku: p.sku, web: p.web || undefined, name: p.name, price: p.price, regularPrice: p.regularPrice, onSale: p.onSale, image: p.image, url: p.url,
  rating: p.rating, reviews: p.reviews, brand: p.brand, model: p.model, category: p.category, stock: p.stock,
});

// ---------- markdown (tiny, safe) ----------
function md(src) {
  const inline = s => esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
  const lines = String(src || '').split('\n');
  let html = '', list = null;
  const close = () => { if (list) { html += `</${list}>`; list = null; } };
  for (const line of lines) {
    let m;
    if ((m = line.match(/^\s*#{1,6}\s+(.*)/))) { close(); html += `<h4>${inline(m[1])}</h4>`; }
    else if ((m = line.match(/^\s*[-*•]\s+(.*)/))) { if (list !== 'ul') { close(); html += '<ul>'; list = 'ul'; } html += `<li>${inline(m[1])}</li>`; }
    else if ((m = line.match(/^\s*\d+[.)]\s+(.*)/))) { if (list !== 'ol') { close(); html += '<ol>'; list = 'ol'; } html += `<li>${inline(m[1])}</li>`; }
    else if (!line.trim()) { close(); }
    else { close(); html += `<p>${inline(line)}</p>`; }
  }
  close();
  return html;
}

// ---------- rendering ----------
const chatEl = $('#chat');

function productCard(p) {
  const el = document.createElement('div');
  el.className = 'card';
  el.dataset.pid = String(p.sku);
  const st = p.web ? StockBook.stock(p) : p.stock || { status: 'unk', label: 'Stock unknown' };
  const inList = current.shortlist.some(x => x.sku === p.sku);
  el.innerHTML = `
    ${p.image ? `<img src="${esc(p.image)}" alt="" loading="lazy">` : ''}
    <span class="stock ${esc(st.status)}">${esc(st.label)}</span>
    <div class="name">${esc(p.name)}</div>
    <div class="price">${p.web ? (p.price ? `~${money(p.price)}` : '<span class="muted">Price: check</span>') : money(p.price)}${p.onSale ? `<span class="was">${money(p.regularPrice)}</span>` : ''}</div>
    <div class="meta">
      ${idLabel(p) ? `<span class="sku" title="Tap to copy">${esc(idLabel(p))}</span>` : ''}
      ${p.rating ? `<span>★ ${Number(p.rating).toFixed(1)} (${Number(p.reviews || 0).toLocaleString()})</span>` : ''}
    </div>
    <div class="actions">
      <button data-act="star">${inList ? '★ Saved' : '☆ Save'}</button>
      <button data-act="ask">Pitch</button>
      ${p.web ? '' : `<a href="${esc(p.url)}" target="_blank" rel="noopener">Page</a>`}
    </div>
    ${p.web ? `<a class="check-link" href="${esc(bbLink(p))}" target="_blank" rel="noopener">Check stock on bestbuy.com ↗</a>
    <div class="actions stock-actions">
      <button data-st="in">✓ In</button><button data-st="low">Low</button><button data-st="out">✗ Out</button>
    </div>` : ''}`;
  const skuEl = $('.sku', el);
  if (skuEl) skuEl.onclick = () => copyText(String(isSku(p.sku) ? p.sku : p.model));
  el.querySelectorAll('[data-st]').forEach(b => { b.onclick = () => { StockBook.mark(p, b.dataset.st); refreshStockBadges(); toast('Saved to stock notebook'); }; });
  $('[data-act=star]', el).onclick = e => { toggleShortlist(p); e.target.textContent = current.shortlist.some(x => x.sku === p.sku) ? '★ Saved' : '☆ Save'; };
  $('[data-act=ask]', el).onclick = () => { document.querySelectorAll('dialog[open]').forEach(d => d.close()); closeDrawers(); send(`Give me a 20-second pitch for ${idLabel(p) || p.name} (${p.name}) tailored to this customer: 3 selling points in plain language, one honest trade-off, and what to pair with it.`); };
  return el;
}

/* Re-draw stock badges on web-mode cards after the notebook changes. */
function refreshStockBadges() {
  document.querySelectorAll('.card[data-pid]').forEach(el => {
    const p = findShownProduct(el.dataset.pid);
    if (!p?.web) return;
    const st = StockBook.stock(p);
    const b = $('.stock', el);
    b.className = 'stock ' + st.status; b.textContent = st.label;
  });
}
function findShownProduct(pid) {
  for (const m of [...current.messages, ...current.tips, { products: current.shortlist }, { products: lastLookup ? [lastLookup] : [] }]) {
    const p = (m.products || []).find(x => String(x.sku) === pid);
    if (p) return p;
  }
  return null;
}
let lastLookup = null;

function renderMessage(m) {
  if (m.role === 'user') {
    const el = document.createElement('div');
    el.className = 'msg user';
    el.innerHTML = (m.images?.length ? `<div class="imgs">${m.images.map(src => `<img src="${src}" alt="">`).join('')}</div>` : '') + esc(m.text || '').replace(/\n/g, '<br>');
    chatEl.appendChild(el);
    return;
  }
  const el = document.createElement('div');
  el.className = 'msg assistant' + (m.error ? ' error' : '');
  el.innerHTML = m.error ? esc(m.text) : md(m.text);
  if (!m.error) {
    const acts = document.createElement('div');
    acts.className = 'msg-actions';
    acts.innerHTML = '<button data-a="copy">Copy</button><button data-a="speak">🔊 Read</button>';
    $('[data-a=copy]', acts).onclick = () => copyText(m.text);
    $('[data-a=speak]', acts).onclick = () => speak(m.text);
    el.appendChild(acts);
  } else if (m.retry) {
    const b = document.createElement('button');
    b.textContent = 'Retry'; b.style.marginTop = '6px'; b.style.display = 'block';
    b.onclick = () => { current.messages = current.messages.filter(x => x !== m); renderChat(); send(m.retry, { resend: true }); };
    el.appendChild(b);
  }
  chatEl.appendChild(el);
  if (m.products?.length) {
    const row = document.createElement('div');
    row.className = 'cards';
    m.products.forEach(p => row.appendChild(productCard(p)));
    chatEl.appendChild(row);
  }
}

function renderWelcome() {
  const missing = [];
  if (!settings.geminiKey) missing.push('your <strong>Gemini API key</strong>');
  if (!settings.store) missing.push('your <strong>store</strong>');
  const webNote = source() === 'web'
    ? `<p>🔎 <strong>No Best Buy API key:</strong> products come from web search. Tap <em>Check stock</em> on a card to see your store's pickup availability on bestbuy.com, then tap ✓ In / ✗ Out — the app remembers it and shows verified in-stock items first. Snap shelf tags (▥ → 📸) to add what's on the floor.</p>` : '';
  chatEl.innerHTML = `<div class="welcome">
    <h2>What does the customer need?</h2>
    ${missing.length ? `<p>⚙ Setup: add ${missing.join(', ')} in Settings.</p>` : ''}
    ${webNote}
    <ul>
      <li>Type it like you'd say it: <em>"mom wants a laptop for email and photos, under $600"</em></li>
      <li>📷 Attach a photo — their old TV's model sticker, a cable, a room</li>
      <li>🎙 Listening mode gives live suggestions while you talk</li>
      <li>▥ Scan a barcode or type a SKU to check stock fast</li>
      <li>★ Save picks to the shortlist, compare, and text the list to the customer</li>
    </ul></div>`;
}

function renderChat() {
  chatEl.innerHTML = '';
  if (!current.messages.length) renderWelcome();
  else current.messages.forEach(renderMessage);
  chatEl.scrollTop = chatEl.scrollHeight;
}

function renderHeader() {
  $('#sessionName').textContent = current.name;
  const s = settings.store;
  $('#storeLine').textContent = (settings.demo ? 'DEMO · ' : source() === 'web' ? 'Web + stock notebook · ' : '') + (s ? `${s.name}${s.id ? ' #' + s.id : ''}` : 'No store set — tap ⚙');
  const n = current.shortlist.length;
  $('#shortlistCount').hidden = !n;
  $('#shortlistCount').textContent = n;
  document.querySelectorAll('input[name=stockMode]').forEach(r => { r.checked = r.value === settings.stockMode; });
  $('#budget').value = settings.budget || '';
}

function renderAll() {
  renderHeader(); renderChat(); renderSessions(); renderShortlist(); renderTips();
  $('#sessionNotes').value = current.notes || '';
}

let statusEl = null;
function setStatus(text) {
  if (!text) { statusEl?.remove(); statusEl = null; return; }
  if (!statusEl) {
    statusEl = document.createElement('div');
    statusEl.className = 'status';
    statusEl.innerHTML = '<span class="spinner"></span><span></span>';
    chatEl.appendChild(statusEl);
  }
  statusEl.lastChild.textContent = text;
  chatEl.scrollTop = chatEl.scrollHeight;
}

// ---------- sending ----------
let pending = []; // attached photos: { data, mime, thumb }
let busy = false;

async function send(text, { resend = false } = {}) {
  text = (text ?? $('#input').value).trim();
  if (busy || (!text && !pending.length)) return;
  busy = true; $('#btnSend').disabled = true;
  const photos = resend ? [] : pending;
  if (!resend) { pending = []; renderAttachments(); $('#input').value = ''; autoGrow(); }
  if (!current.messages.length) chatEl.innerHTML = '';
  const userMsg = { role: 'user', text, images: photos.map(p => p.thumb) };
  current.messages.push(userMsg);
  renderMessage(userMsg);
  if (current.messages.filter(m => m.role === 'user').length === 1 && /^Customer \d/.test(current.name) && text) {
    current.name = text.slice(0, 40) + (text.length > 40 ? '…' : '');
    renderHeader();
  }
  const parts = photos.map(p => ({ inlineData: { mimeType: p.mime, data: p.data } }));
  parts.push({ text: text || 'What is this? Find it or the closest in-stock alternatives.' });
  const history = [...current.history, { role: 'user', parts }];
  try {
    const r = await runAgent(history, { onStatus: setStatus });
    current.history = r.history;
    const msg = { role: 'assistant', text: r.text || '(no answer)', products: cardsFor(r.text, r.products) };
    current.messages.push(msg);
    setStatus(null);
    renderMessage(msg);
  } catch (e) {
    setStatus(null);
    const msg = { role: 'assistant', error: true, text: e.message, retry: text };
    current.messages.push(msg);
    renderMessage(msg);
  } finally {
    busy = false; $('#btnSend').disabled = false;
    saveSessions(); renderSessions();
    chatEl.scrollTop = chatEl.scrollHeight;
  }
}

// ---------- photos ----------
function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Could not read that image.')); };
    img.src = url;
  });
}
function resize(img, max, quality) {
  const scale = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
  const c = document.createElement('canvas');
  c.width = Math.round(img.naturalWidth * scale); c.height = Math.round(img.naturalHeight * scale);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  return c.toDataURL('image/jpeg', quality);
}
async function addFiles(files) {
  for (const f of files) {
    if (!f.type.startsWith('image/')) continue;
    if (pending.length >= 4) { toast('Up to 4 photos per message'); break; }
    try {
      const img = await loadImage(f);
      const full = resize(img, 1400, 0.85);
      pending.push({ mime: 'image/jpeg', data: full.split(',')[1], thumb: resize(img, 160, 0.7) });
    } catch (e) { toast(e.message); }
  }
  renderAttachments();
}
function renderAttachments() {
  const box = $('#attachPreview');
  box.innerHTML = '';
  pending.forEach((p, i) => {
    const d = document.createElement('div');
    d.className = 'thumb';
    d.innerHTML = `<img src="${p.thumb}" alt=""><button aria-label="Remove">✕</button>`;
    $('button', d).onclick = () => { pending.splice(i, 1); renderAttachments(); };
    box.appendChild(d);
  });
}

// ---------- text to speech ----------
function speak(text) {
  if (!('speechSynthesis' in window)) return toast('Read-aloud not supported here');
  speechSynthesis.cancel();
  const plain = String(text).replace(/[*#`]/g, '').replace(/SKU \d+/g, '');
  speechSynthesis.speak(new SpeechSynthesisUtterance(plain));
}

// ---------- listening mode ----------
const Listen = {
  active: false, rec: null, media: null, stream: null, timer: null, wake: null,
  interim: '', lastLen: 0, lastAt: 0, busy: false,

  async start() {
    if (!settings.geminiKey) { toast('Add your Gemini API key first'); openSettings(); return; }
    this.active = true;
    this.lastLen = (current.transcript || '').length;
    this.lastAt = Date.now();
    $('#livePanel').hidden = false;
    $('#btnListen').classList.add('on');
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    // iPhone home-screen apps don't reliably support Safari's speech recognition, so default to Gemini there.
    const useDevice = SR && (settings.speechEngine === 'device' || (settings.speechEngine === 'auto' && !(IS_IOS && IS_STANDALONE)));
    try {
      if (useDevice) this.startSR(SR); else await this.startRecorder();
    } catch (e) { toast('Microphone: ' + e.message); this.stop(); return; }
    this.timer = setInterval(() => this.maybeAnalyze(), 3000);
    if (settings.wakeLock) this.lockScreen();
    renderTranscript();
  },

  stop() {
    this.active = false;
    clearInterval(this.timer);
    try { this.rec?.stop(); } catch {}
    try { if (this.media?.state === 'recording') this.media.stop(); } catch {}
    this.stream?.getTracks().forEach(t => t.stop());
    this.rec = this.media = this.stream = null;
    this.interim = '';
    try { this.wake?.release(); } catch {}
    this.wake = null;
    $('#btnListen').classList.remove('on');
    $('#livePanel').hidden = !(current?.tips?.length);
    saveSessions();
  },

  // Built-in speech recognition (Chrome/Edge/Android, Safari)
  startSR(SR) {
    $('#liveEngine').textContent = '· on-device speech';
    const rec = new SR();
    rec.continuous = true; rec.interimResults = true; rec.lang = navigator.language || 'en-US';
    rec.onresult = e => {
      heard = true;
      let interim = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const r = e.results[i];
        if (r.isFinal) current.transcript = (current.transcript + ' ' + r[0].transcript.trim()).trim();
        else interim += r[0].transcript;
      }
      this.interim = interim;
      renderTranscript();
    };
    let heard = false;
    rec.onerror = e => {
      if (!['not-allowed', 'service-not-allowed', 'audio-capture'].includes(e.error)) return;
      this.rec = null;
      if (!heard && settings.speechEngine !== 'device') {
        // Built-in recognition is blocked (common on iPhone): fall back to Gemini transcription.
        this.startRecorder().catch(err => { toast('Microphone: ' + err.message); this.stop(); });
      } else { toast('Microphone permission denied'); this.stop(); }
    };
    rec.onend = () => { if (this.active && this.rec === rec) setTimeout(() => { try { rec.start(); } catch {} }, 250); };
    this.rec = rec;
    rec.start();
  },

  // Fallback: record short audio clips and let Gemini transcribe them.
  async startRecorder() {
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) throw new Error('not supported in this browser');
    $('#liveEngine').textContent = '· Gemini transcription';
    this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const mime = ['audio/webm', 'audio/mp4', 'audio/ogg'].find(t => MediaRecorder.isTypeSupported(t)) || '';
    const loop = () => {
      if (!this.active) return;
      const chunks = [];
      const mr = new MediaRecorder(this.stream, mime ? { mimeType: mime } : undefined);
      this.media = mr;
      mr.ondataavailable = e => e.data.size && chunks.push(e.data);
      mr.onstop = () => {
        const blob = new Blob(chunks, { type: mr.mimeType || mime || 'audio/webm' });
        if (this.active) loop();
        if (blob.size > 2000) this.transcribe(blob);
      };
      mr.start();
      setTimeout(() => { if (mr.state === 'recording') mr.stop(); }, 15000);
    };
    loop();
  },

  async transcribe(blob) {
    try {
      this.interim = '(transcribing…)'; renderTranscript();
      let audio = blob;
      try { audio = await toWav(blob); } catch {} // send the original clip if the browser can't decode it
      const data = await blobToBase64(audio);
      const r = await gemini({
        contents: [{ role: 'user', parts: [
          { inlineData: { mimeType: (audio.type || 'audio/webm').split(';')[0], data } },
          { text: 'Transcribe this audio from a retail store conversation verbatim. Output only the transcript text. If there is no clear speech, output nothing.' },
        ] }],
        generationConfig: { temperature: 0 },
      });
      const t = (r.candidates?.[0]?.content?.parts || []).filter(p => p.text && !p.thought).map(p => p.text).join(' ').trim();
      if (t) current.transcript = (current.transcript + ' ' + t).trim();
    } catch (e) { toast(e.message); }
    this.interim = ''; renderTranscript();
  },

  maybeAnalyze() {
    if (!this.active || this.busy) return;
    const fresh = (current.transcript || '').length - this.lastLen;
    if (fresh >= 60 && Date.now() - this.lastAt >= settings.interval * 1000) this.analyze();
  },

  async analyze(force = false) {
    if (this.busy) return;
    const text = (current.transcript || '').trim();
    if (!text) { if (force) toast('Nothing heard yet'); return; }
    this.busy = true; this.lastLen = text.length; this.lastAt = Date.now();
    $('#btnSuggestNow').disabled = true; $('#btnSuggestNow').textContent = 'Thinking…';
    const lastTip = current.tips?.[0]?.text || '';
    const prompt = `LIVE MODE. Below is an automatic transcript of an ongoing conversation between me (the associate) and a customer; speakers are not labeled and there may be transcription errors.
${lastTip ? `Your previous tip was:\n${lastTip}\n\nOnly give a new tip if the conversation has moved on or there's something new to add; otherwise reply with exactly NO_UPDATE.` : ''}
Give me a glanceable tip in this format (max ~70 words, search inventory first):
**Need:** what they want so far
**Ask:** 1 smart question to ask next
**Show:** 1-3 in-stock picks as Name (SKU) – $price – why
**Add-on:** one accessory or service idea

Transcript (most recent at the end):
"""${text.slice(-6000)}"""`;
    try {
      const r = await runAgent([{ role: 'user', parts: [{ text: prompt }] }], { extra: 'You are in live listening mode: be extremely brief.' });
      const t = (r.text || '').trim();
      if (t && !/^NO_UPDATE\.?$/i.test(t)) {
        current.tips.unshift({ at: Date.now(), text: t, products: cardsFor(t, r.products) });
        current.tips.length = Math.min(current.tips.length, 20);
        renderTips();
        if (navigator.vibrate) navigator.vibrate(60);
        saveSessions();
      }
    } catch (e) { toast(e.message); }
    this.busy = false;
    $('#btnSuggestNow').disabled = false; $('#btnSuggestNow').textContent = 'Suggest now';
  },

  async lockScreen() {
    try { if ('wakeLock' in navigator) this.wake = await navigator.wakeLock.request('screen'); } catch {}
  },
};
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && Listen.active && settings.wakeLock) Listen.lockScreen();
});

/* Decode any recorded clip (webm / Safari's mp4) and re-encode as 16 kHz mono WAV, which Gemini always accepts. */
async function toWav(blob) {
  const AC = window.AudioContext || window.webkitAudioContext;
  const ctx = new AC();
  let decoded;
  try { decoded = await ctx.decodeAudioData(await blob.arrayBuffer()); } finally { ctx.close?.(); }
  const rate = 16000;
  const off = new OfflineAudioContext(1, Math.ceil(decoded.duration * rate), rate);
  const src = off.createBufferSource();
  src.buffer = decoded; src.connect(off.destination); src.start();
  const pcm = (await off.startRendering()).getChannelData(0);
  const buf = new ArrayBuffer(44 + pcm.length * 2);
  const v = new DataView(buf);
  const str = (o, t) => [...t].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  str(0, 'RIFF'); v.setUint32(4, 36 + pcm.length * 2, true); str(8, 'WAVE'); str(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, 'data'); v.setUint32(40, pcm.length * 2, true);
  for (let i = 0; i < pcm.length; i++) v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, pcm[i])) * 0x7fff, true);
  return new Blob([buf], { type: 'audio/wav' });
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(',')[1]);
    r.onerror = reject;
    r.readAsDataURL(blob);
  });
}

function renderTranscript() {
  const el = $('#transcript');
  el.innerHTML = esc((current.transcript || '').slice(-3000)) + (Listen.interim ? ` <span class="interim">${esc(Listen.interim)}</span>` : '');
  el.scrollTop = el.scrollHeight;
}

function renderTips() {
  const box = $('#liveTips');
  box.innerHTML = '';
  $('#livePanel').hidden = !(Listen.active || current.tips?.length);
  if (!Listen.active && current.tips?.length) $('#liveEngine').textContent = '(stopped)';
  $('#livePanel .live-head strong').textContent = Listen.active ? 'Listening' : 'Live tips';
  $('#livePanel .dot').style.visibility = Listen.active ? 'visible' : 'hidden';
  $('#btnStopListen').textContent = Listen.active ? 'Stop' : 'Hide';
  (current.tips || []).forEach(tip => {
    const d = document.createElement('div');
    d.className = 'tip';
    d.innerHTML = `<div class="when">${new Date(tip.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</div>${md(tip.text)}
      <div class="msg-actions"><button data-a="chat">Move to chat</button></div>`;
    $('[data-a=chat]', d).onclick = () => {
      current.history.push({ role: 'user', parts: [{ text: `Context — transcript of my conversation with the customer so far:\n"""${(current.transcript || '').slice(-4000)}"""` }] });
      current.history.push({ role: 'model', parts: [{ text: tip.text }] });
      const msg = { role: 'assistant', text: tip.text, products: tip.products };
      if (!current.messages.length) chatEl.innerHTML = '';
      current.messages.push(msg); renderMessage(msg); saveSessions();
      chatEl.scrollTop = chatEl.scrollHeight;
      toast('Added to chat — ask follow-ups below');
    };
    if (tip.products?.length) {
      const row = document.createElement('div');
      row.className = 'cards';
      tip.products.forEach(p => row.appendChild(productCard(p)));
      d.appendChild(row);
    }
    box.appendChild(d);
  });
  renderTranscript();
}

// ---------- shortlist & compare ----------
function toggleShortlist(p) {
  const i = current.shortlist.findIndex(x => x.sku === p.sku);
  if (i >= 0) current.shortlist.splice(i, 1);
  else { current.shortlist.push(slimProduct(p)); toast('Saved to shortlist'); }
  saveSessions(); renderHeader(); renderShortlist();
}
const compareSel = new Set();
function renderShortlist() {
  const box = $('#shortlistItems');
  box.innerHTML = current.shortlist.length ? '' : '<p class="muted">Tap ☆ Save on any product to keep it here for this customer.</p>';
  current.shortlist.forEach(p => {
    const d = document.createElement('div');
    d.className = 'sl-item';
    d.innerHTML = `<input type="checkbox" ${compareSel.has(p.sku) ? 'checked' : ''} aria-label="Select to compare">
      ${p.image ? `<img src="${esc(p.image)}" alt="">` : ''}
      <div class="sl-main"><div>${esc(p.name)}</div><div class="muted">${money(p.price)} · ${esc(idLabel(p))} · ${esc((p.web ? StockBook.stock(p) : p.stock)?.label || '')}</div></div>
      <button aria-label="Remove">✕</button>`;
    $('input', d).onchange = e => { e.target.checked ? compareSel.add(p.sku) : compareSel.delete(p.sku); };
    $('button', d).onclick = () => { compareSel.delete(p.sku); toggleShortlist(p); };
    $('.sl-main', d).onclick = () => copyText(String(isSku(p.sku) ? p.sku : p.model || p.name));
    box.appendChild(d);
  });
}

let compareData = [];
async function openCompare() {
  let items = current.shortlist.filter(p => compareSel.has(p.sku));
  if (items.length < 2) items = current.shortlist.slice(0, 4);
  if (items.length < 2) return toast('Save at least 2 products to compare');
  items = items.slice(0, 4);
  closeDrawers();
  $('#compareAI').innerHTML = '';
  $('#compareTable').innerHTML = '<div class="status"><span class="spinner"></span>Loading specs…</div>';
  $('#compareDlg').showModal();
  compareData = await Promise.all(items.map(async p => {
    if (p.web) return { ...p, stock: StockBook.stock(p), raw: {} };
    const d = await Inventory.details(p.sku).catch(() => null);
    let stock = p.stock;
    try { stock = await stockFor(p.sku); } catch {}
    return { ...p, ...(d || {}), stock, raw: d?.raw || {} };
  }));
  const specNames = [];
  compareData.forEach(p => (p.raw.details || []).forEach(d => { if (!specNames.includes(d.name)) specNames.push(d.name); }));
  const common = specNames.filter(n => compareData.filter(p => (p.raw.details || []).some(d => d.name === n)).length >= 2).slice(0, 18);
  const spec = (p, n) => (p.raw.details || []).find(d => d.name === n)?.value ?? '—';
  const row = (label, f) => `<tr><th>${esc(label)}</th>${compareData.map(p => `<td>${f(p)}</td>`).join('')}</tr>`;
  $('#compareTable').innerHTML = `<table>
    ${row('', p => (p.image ? `<img src="${esc(p.image)}" alt="">` : ''))}
    ${row('Product', p => esc(p.name))}
    ${row('Price', p => `<strong>${money(p.price)}</strong>${p.onSale ? ` <s class="muted">${money(p.regularPrice)}</s>` : ''}`)}
    ${row('Stock', p => esc(p.stock?.label || '—'))}
    ${row('Rating', p => (p.rating ? `★ ${Number(p.rating).toFixed(1)} (${p.reviews})` : '—'))}
    ${row('Brand / model', p => esc([p.brand, p.model].filter(Boolean).join(' ')))}
    ${row('SKU / model', p => esc(idLabel(p)))}
    ${common.map(n => row(n, p => esc(spec(p, n)))).join('')}
    ${row('Highlights', p => `<ul>${(p.raw.features || []).slice(0, 4).map(f => `<li>${esc(String(f.feature).slice(0, 140))}</li>`).join('')}</ul>`)}
  </table>`;
}
async function compareAI() {
  const btn = $('#btnCompareAI');
  btn.disabled = true;
  $('#compareAI').innerHTML = '<div class="status"><span class="spinner"></span>Comparing…</div>';
  const recent = current.messages.filter(m => m.role === 'user').slice(-4).map(m => m.text).join(' | ');
  const data = compareData.map(p => ({
    sku: isSku(p.sku) ? p.sku : undefined, model: p.model, name: p.name, price: p.price, rating: p.rating, stock: p.stock?.label,
    features: (p.raw.features || []).slice(0, 6).map(f => f.feature),
    specs: Object.fromEntries((p.raw.details || []).slice(0, 25).map(d => [d.name, d.value])),
  }));
  try {
    const r = await gemini({
      contents: [{ role: 'user', parts: [{ text: `I'm a Best Buy associate. Compare these products for my customer and tell me which to recommend.
What the customer said / needs: ${recent || '(not specified)'}${current.notes ? `\nNotes: ${current.notes}` : ''}
Products (JSON): ${JSON.stringify(data)}
${compareData.some(p => p.web) ? 'Look up the specs on the web as needed. ' : ''}Answer in under 150 words: **Pick:** which one and why, then one line per product on who it's best for, then the single biggest difference to explain to the customer in plain language.` }] }],
      ...(compareData.some(p => p.web) ? { tools: [{ google_search: {} }] } : {}),
      generationConfig: { temperature: 0.3 },
    });
    const t = textOf(r);
    $('#compareAI').innerHTML = `<div class="msg assistant">${md(t)}</div>`;
  } catch (e) { $('#compareAI').innerHTML = `<div class="msg error">${esc(e.message)}</div>`; }
  btn.disabled = false;
}

async function shareShortlist() {
  if (!current.shortlist.length) return toast('Shortlist is empty');
  const store = settings.store ? ` at Best Buy ${settings.store.city}` : '';
  const text = `Products we looked at${store}:\n\n` + current.shortlist.map(p => `• ${p.name}\n  ${p.price ? money(p.price) + ' · ' : ''}${idLabel(p)}\n  ${p.url}`).join('\n\n');
  if (navigator.share) { try { await navigator.share({ title: 'Your product list', text }); return; } catch (e) { if (e.name === 'AbortError') return; } }
  copyText(text);
}

// ---------- sessions drawer ----------
function renderSessions() {
  const box = $('#sessionList');
  box.innerHTML = '';
  sessions.forEach(s => {
    const d = document.createElement('div');
    d.className = 'session-item' + (s === current ? ' active' : '');
    d.innerHTML = `<div class="s-main"><div class="s-name">${esc(s.name)}</div>
      <div class="muted">${new Date(s.updated).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })} · ${s.messages.filter(m => m.role === 'user').length} msgs${s.shortlist.length ? ` · ★${s.shortlist.length}` : ''}</div></div>
      <button data-a="rename">Rename</button><button data-a="del" class="danger">✕</button>`;
    $('.s-main', d).onclick = () => { switchSession(s); closeDrawers(); };
    $('[data-a=rename]', d).onclick = () => {
      const n = prompt('Customer name / label', s.name);
      if (n) { s.name = n.trim(); saveSessions(); renderSessions(); renderHeader(); }
    };
    $('[data-a=del]', d).onclick = () => {
      if (!confirm(`Delete "${s.name}"?`)) return;
      sessions = sessions.filter(x => x !== s);
      if (s === current) { current = sessions[0] || newSession(); }
      saveSessions(); renderAll();
    };
    box.appendChild(d);
  });
}

// ---------- drawers & dialogs ----------
let scrim = null;
function openDrawer(id) {
  closeDrawers();
  $(id).hidden = false;
  scrim = document.createElement('div');
  scrim.className = 'scrim';
  scrim.onclick = closeDrawers;
  document.body.appendChild(scrim);
}
function closeDrawers() {
  document.querySelectorAll('.drawer').forEach(d => { d.hidden = true; });
  scrim?.remove(); scrim = null;
}

function openSettings() {
  $('#setGemini').value = settings.geminiKey;
  $('#setModel').value = settings.model;
  $('#setBB').value = settings.bbKey;
  $('#setDemo').checked = settings.demo;
  $('#setZip').value = settings.zip;
  $('#setRadius').value = settings.radius;
  $('#setInterval').value = settings.interval;
  $('#setWakeLock').checked = settings.wakeLock;
  $('#setSpeech').value = settings.speechEngine;
  $('#storeResults').innerHTML = '';
  showCurrentStore();
  $('#settingsDlg').showModal();
}
function showCurrentStore() {
  const s = settings.store;
  $('#currentStore').textContent = s ? `Current: ${s.name} #${s.id} — ${s.city}, ${s.region} ${s.postalCode}` : 'No store selected yet — tap Find stores.';
}
async function findStores() {
  const box = $('#storeResults');
  settings.zip = $('#setZip').value.trim() || '32159';
  saveSettings();
  if (source() === 'web') {
    const name = prompt('Store name (city)', settings.zip === '32159' ? 'Lady Lake' : (settings.store?.city || ''));
    if (name) pickStore(webStore(name.trim()));
    return;
  }
  if (settings.demo) {
    box.innerHTML = '';
    const b = document.createElement('button');
    b.textContent = `${Demo.STORE.name} #${Demo.STORE.id}`;
    b.onclick = () => pickStore(Demo.STORE);
    box.appendChild(b);
    return;
  }
  box.innerHTML = '<span class="muted">Searching…</span>';
  try {
    const data = await bbFetch(`/stores(area(${encodeURIComponent(settings.zip)},50))`, { show: 'storeId,name,longName,address,city,region,postalCode,distance,storeType', pageSize: '15' });
    const stores = data?.stores || [];
    box.innerHTML = stores.length ? '' : '<span class="muted">No stores found near that ZIP.</span>';
    stores.forEach(s => {
      const b = document.createElement('button');
      b.innerHTML = `<strong>${esc(s.longName || s.name)}</strong> #${esc(s.storeId)}<br><span class="muted">${esc(s.address)}, ${esc(s.city)} · ${s.distance != null ? Math.round(s.distance) + ' mi' : ''} ${s.storeType ? '· ' + esc(s.storeType) : ''}</span>`;
      b.onclick = () => pickStore({ id: String(s.storeId), name: s.longName || s.name, city: s.city, region: s.region, postalCode: s.postalCode });
      box.appendChild(b);
    });
  } catch (e) { box.innerHTML = `<span class="muted" style="color:var(--bad)">${esc(e.message)}</span>`; }
}
const webStore = name => ({ id: '', name, city: name, region: settings.zip === '32159' ? 'FL' : '', postalCode: settings.zip });
function pickStore(s) {
  settings.store = s; saveSettings(); stockCache.clear();
  $('#storeResults').innerHTML = '';
  showCurrentStore(); renderHeader();
  toast('Store set: ' + s.name);
}
async function loadModels() {
  const key = $('#setGemini').value.trim();
  if (!key) return toast('Enter your Gemini key first');
  try {
    const res = await fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200', { headers: { 'x-goog-api-key': key } });
    const j = await res.json();
    if (!res.ok) throw new Error(j.error?.message || res.status);
    const names = (j.models || [])
      .filter(m => (m.supportedGenerationMethods || []).includes('generateContent') && /gemini/.test(m.name) && !/embedding|tts|image|live|audio/.test(m.name))
      .map(m => m.name.replace(/^models\//, ''));
    $('#modelList').innerHTML = names.map(n => `<option value="${esc(n)}">`).join('');
    toast(`${names.length} models found — tap the model box to pick`);
  } catch (e) { toast('Could not list models: ' + e.message); }
}

// ---------- scanner / SKU lookup ----------
let scanStream = null, scanLoop = null;
async function openScanner() {
  $('#scanResult').innerHTML = '';
  $('#tagResult').innerHTML = '';
  lastLookup = null;
  $('#scanInput').value = '';
  $('#scanDlg').showModal();
  const video = $('#scanVideo');
  if (!navigator.mediaDevices?.getUserMedia) {
    $('#scanStatus').textContent = 'Camera isn\'t available here — type the SKU or UPC.';
    video.hidden = true;
    return;
  }
  if (!('BarcodeDetector' in window)) return startZxing(video); // iPhone/iPad Safari
  try {
    const detector = new BarcodeDetector({ formats: ['upc_a', 'upc_e', 'ean_13', 'ean_8', 'code_128'] });
    scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
    video.srcObject = scanStream; video.hidden = false; await video.play();
    $('#scanStatus').textContent = 'Point at the barcode on the box or tag…';
    scanLoop = setInterval(async () => {
      try {
        const codes = await detector.detect(video);
        if (codes.length) { const v = codes[0].rawValue; stopScanner(); $('#scanInput').value = v; lookupCode(v); }
      } catch {}
    }, 300);
  } catch (e) {
    $('#scanStatus').textContent = 'Camera unavailable (' + e.message + ') — type the SKU or UPC.';
    video.hidden = true;
  }
}
// Barcode scanning via the bundled ZXing library for browsers without BarcodeDetector.
let zxReader = null;
function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src; s.onload = resolve; s.onerror = () => reject(new Error('could not load scanner'));
    document.head.appendChild(s);
  });
}
async function startZxing(video) {
  $('#scanStatus').textContent = 'Starting camera…';
  try {
    if (!window.ZXing) await loadScript('vendor/zxing.min.js');
    const Z = window.ZXing;
    const hints = new Map([[Z.DecodeHintType.POSSIBLE_FORMATS, [Z.BarcodeFormat.UPC_A, Z.BarcodeFormat.UPC_E, Z.BarcodeFormat.EAN_13, Z.BarcodeFormat.EAN_8, Z.BarcodeFormat.CODE_128]]]);
    zxReader = new Z.BrowserMultiFormatReader(hints, 300);
    video.hidden = false;
    await zxReader.decodeFromConstraints({ video: { facingMode: 'environment' } }, video, result => {
      if (!result || !zxReader) return;
      const v = result.getText();
      stopScanner(); $('#scanInput').value = v; lookupCode(v);
    });
    $('#scanStatus').textContent = 'Point at the barcode on the box or tag…';
  } catch (e) {
    stopScanner();
    $('#scanStatus').textContent = 'Camera unavailable (' + (e.message || e.name) + ') — type the SKU or UPC.';
  }
}

function stopScanner() {
  try { zxReader?.reset(); } catch {}
  zxReader = null;
  clearInterval(scanLoop); scanLoop = null;
  scanStream?.getTracks().forEach(t => t.stop()); scanStream = null;
  $('#scanVideo').hidden = true;
}
async function lookupCode(code) {
  code = String(code || '').replace(/\D/g, '');
  if (!code) return;
  const box = $('#scanResult');
  box.innerHTML = '<div class="status"><span class="spinner"></span>Looking up…</div>';
  try {
    const p = await Inventory.lookup(code);
    if (!p) { box.innerHTML = '<p class="muted">No product found for that code.</p>'; return; }
    if (p.web) p.stock = StockBook.stock(p);
    else try { p.stock = await stockFor(p.sku); } catch (e) { p.stock = { status: 'unk', label: 'Stock unknown' }; }
    box.innerHTML = '';
    lastLookup = slimProduct(p);
    const card = productCard(lastLookup);
    card.style.flex = 'none';
    box.appendChild(card);
    if (p.web) {
      const hold = document.createElement('button');
      hold.textContent = '✓ It\'s here on the floor — mark in stock';
      hold.style.marginTop = '8px'; hold.style.width = '100%';
      hold.onclick = () => { StockBook.mark(p, 'in', 'scan'); refreshStockBadges(); toast('Marked in stock'); };
      box.appendChild(hold);
    }
    if (p.stock.nearby?.length) {
      const n = document.createElement('p');
      n.className = 'muted'; n.textContent = 'In stock at: ' + p.stock.nearby.slice(0, 5).join(', ');
      box.appendChild(n);
    }
    const ask = document.createElement('button');
    ask.className = 'primary'; ask.textContent = 'Ask AI about this'; ask.style.marginTop = '8px';
    ask.onclick = () => { $('#scanDlg').close(); send(`Customer is looking at ${idLabel(p) || ''} (${p.name}). Give me key selling points, who it's for, a better/cheaper in-stock alternative if there is one, and what to pair with it.`); };
    box.appendChild(ask);
  } catch (e) { box.innerHTML = `<p style="color:var(--bad)">${esc(e.message)}</p>`; }
}

// ---------- shelf-tag reader ----------
async function readTags(file) {
  const box = $('#tagResult');
  box.innerHTML = '<div class="status"><span class="spinner"></span>Reading tags…</div>';
  try {
    const img = await loadImage(file);
    const items = await Web.readTags({ mimeType: 'image/jpeg', data: resize(img, 1600, 0.85).split(',')[1] });
    if (!items.length) { box.innerHTML = '<p class="muted">Couldn\'t read any products — try a closer, straighter photo.</p>'; return; }
    box.innerHTML = '<p class="muted">Found these — uncheck anything that\'s wrong:</p>';
    items.forEach((p, i) => {
      const d = document.createElement('label');
      d.className = 'tag-item';
      d.innerHTML = `<input type="checkbox" checked data-i="${i}"><span>${esc(p.name)}<br><span class="muted">${esc([idLabel(p), p.price && money(p.price)].filter(Boolean).join(' · '))}</span></span>`;
      box.appendChild(d);
    });
    const b = document.createElement('button');
    b.className = 'primary'; b.textContent = 'Mark checked items in stock';
    b.onclick = () => {
      const chosen = [...box.querySelectorAll('input[data-i]:checked')].map(c => items[c.dataset.i]);
      chosen.forEach(p => StockBook.mark(p, 'in', 'tag photo'));
      box.innerHTML = `<p class="muted">✓ Added ${chosen.length} item${chosen.length === 1 ? '' : 's'} to the stock notebook.</p>`;
      refreshStockBadges();
    };
    box.appendChild(b);
  } catch (e) { box.innerHTML = `<p style="color:var(--bad)">${esc(e.message)}</p>`; }
}

// ---------- stock notebook screen ----------
function renderBook() {
  const q = normId($('#bookFilter').value);
  const box = $('#bookList');
  const list = StockBook.items.filter(e => !q || normId(e.name + e.model + e.sku).includes(q));
  box.innerHTML = list.length ? '' : '<p class="muted">Nothing yet. Tap ✓ In / ✗ Out on product cards, scan a barcode, or read shelf tags.</p>';
  list.slice(0, 300).forEach(e => {
    const st = StockBook.stock(e);
    const d = document.createElement('div');
    d.className = 'book-item';
    d.innerHTML = `<div class="b-main"><div>${esc(e.name || e.model || e.sku)}</div>
      <div class="muted">${esc([e.sku ? 'SKU ' + e.sku : '', e.model ? 'Model ' + e.model : ''].filter(Boolean).join(' · '))}</div>
      <span class="stock ${st.status}">${esc(st.label)}</span></div>
      <button data-st="in">✓</button><button data-st="low">Low</button><button data-st="out">✗</button><button data-del class="danger">🗑</button>`;
    d.querySelectorAll('[data-st]').forEach(b => { b.onclick = () => { StockBook.mark(e, b.dataset.st); renderBook(); refreshStockBadges(); }; });
    $('[data-del]', d).onclick = () => { StockBook.remove(e.id); renderBook(); refreshStockBadges(); };
    box.appendChild(d);
  });
}
function openBook() {
  document.querySelectorAll('dialog[open]').forEach(d => d.close());
  closeDrawers();
  $('#bookFilter').value = '';
  renderBook();
  $('#bookDlg').showModal();
}

// ---------- quick prompts ----------
const QUICK = [
  ['Cheapest option', 'Show me the cheapest in-stock option that still does the job well.'],
  ['Best value', 'What is the best value pick here and why?'],
  ['Premium pick', 'What is the premium option if they want the best?'],
  ['Add-ons', 'What accessories should I suggest with this? Only in-stock items.'],
  ['Explain simply', 'Explain the difference between the top options in plain, non-technical language I can say to the customer.'],
  ['Questions to ask', 'What questions should I ask this customer to find the right product?'],
  ['On sale?', 'Which relevant items are on sale right now?'],
  ['Objection help', 'The customer thinks it is too expensive. Give me 3 honest ways to handle that, including cheaper in-stock alternatives.'],
];

// ---------- wiring ----------
function autoGrow() {
  const t = $('#input');
  t.style.height = 'auto';
  t.style.height = Math.min(140, t.scrollHeight) + 'px';
}

// iOS Safari doesn't shrink the page when the keyboard opens; follow the visual viewport instead.
function fitViewport() {
  if (!window.visualViewport) return;
  document.body.style.height = visualViewport.height + 'px';
  window.scrollTo(0, 0);
}

function init() {
  const lastId = LS.get('fa.current', null);
  current = sessions.find(s => s.id === lastId) || sessions[0] || newSession();
  sessions.forEach(s => { s.tips ||= []; s.shortlist ||= []; s.history ||= []; s.transcript ||= ''; });

  const chips = $('#quickChips');
  QUICK.forEach(([label, text]) => {
    const b = document.createElement('button');
    b.className = 'chip'; b.textContent = label;
    b.onclick = () => send(text);
    chips.appendChild(b);
  });

  $('#btnSend').onclick = () => send();
  $('#input').addEventListener('input', autoGrow);
  $('#input').addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey && !('ontouchstart' in window)) { e.preventDefault(); send(); }
  });
  $('#btnAttach').onclick = () => $('#fileInput').click();
  $('#fileInput').onchange = e => { addFiles([...e.target.files]); e.target.value = ''; };
  document.addEventListener('paste', e => {
    const files = [...(e.clipboardData?.files || [])].filter(f => f.type.startsWith('image/'));
    if (files.length) addFiles(files);
  });

  $('#btnListen').onclick = () => (Listen.active ? Listen.stop() : Listen.start());
  $('#btnStopListen').onclick = () => { if (Listen.active) Listen.stop(); else $('#livePanel').hidden = true; };
  $('#btnSuggestNow').onclick = () => Listen.analyze(true);

  document.querySelectorAll('input[name=stockMode]').forEach(r => {
    r.onchange = () => {
      settings.stockMode = r.value; saveSettings();
      if (r.value === 'store' && !settings.store) toast('Pick your store in Settings first');
    };
  });
  $('#budget').onchange = e => { settings.budget = e.target.value ? Number(e.target.value) : ''; saveSettings(); toast(settings.budget ? `Budget: ${money(settings.budget)}` : 'Budget cleared'); };

  $('#btnSessions').onclick = () => { renderSessions(); openDrawer('#sessionsDrawer'); };
  $('#btnShortlist').onclick = () => { renderShortlist(); openDrawer('#shortlistDrawer'); };
  document.querySelectorAll('[data-close]').forEach(b => { b.onclick = closeDrawers; });
  $('#btnNewSession').onclick = () => {
    settings.budget = ''; saveSettings();
    switchSession(newSession()); saveSessions(); closeDrawers();
    $('#input').focus();
  };
  $('#sessionNotes').oninput = e => { current.notes = e.target.value; saveSessions(); };
  $('#btnCompare').onclick = openCompare;
  $('#btnCompareAI').onclick = compareAI;
  $('#btnShare').onclick = shareShortlist;

  $('#btnSettings').onclick = openSettings;
  const bind = (id, key, fn = v => v) => { $(id).addEventListener('change', e => { settings[key] = fn(e.target.type === 'checkbox' ? e.target.checked : e.target.value); saveSettings(); renderHeader(); }); };
  bind('#setGemini', 'geminiKey', v => v.trim());
  bind('#setModel', 'model', v => v.trim() || DEFAULTS.model);
  bind('#setBB', 'bbKey', v => v.trim());
  $('#setBB').addEventListener('change', () => {
    stockCache.clear();
    if (!settings.bbKey && !settings.store) pickStore(webStore('Lady Lake'));
    if (!current.messages.length) renderWelcome();
  });
  bind('#setDemo', 'demo');
  bind('#setZip', 'zip', v => v.trim());
  bind('#setRadius', 'radius', v => Math.max(5, Number(v) || 25));
  bind('#setInterval', 'interval', v => Math.max(8, Number(v) || 20));
  bind('#setWakeLock', 'wakeLock');
  bind('#setSpeech', 'speechEngine');
  $('#setDemo').addEventListener('change', () => {
    stockCache.clear();
    if (settings.demo && !settings.store) pickStore(Demo.STORE);
    if (!settings.demo && settings.store?.id === Demo.STORE.id) { settings.store = source() === 'web' ? webStore('Lady Lake') : null; saveSettings(); showCurrentStore(); renderHeader(); }
  });
  $('#settingsDlg').addEventListener('close', () => { renderHeader(); if (!current.messages.length) renderWelcome(); });
  $('#btnFindStores').onclick = findStores;
  $('#btnLoadModels').onclick = loadModels;
  $('#btnClearData').onclick = () => {
    if (!confirm('Erase all keys, customers and history from this device?')) return;
    localStorage.clear(); location.reload();
  };

  // Buttons added inside dialogs (cards, notebook rows…) must not close the dialog; only value="close" buttons do.
  document.querySelectorAll('dialog form').forEach(f => f.addEventListener('submit', e => { if (!e.submitter?.value) e.preventDefault(); }));
  $('#btnScan').onclick = openScanner;
  $('#btnTags').onclick = () => $('#tagInput').click();
  $('#tagInput').onchange = e => { const f = e.target.files[0]; e.target.value = ''; if (f) { stopScanner(); readTags(f); } };
  $('#btnOpenBook').onclick = openBook;
  $('#btnBook').onclick = openBook;
  $('#bookFilter').oninput = renderBook;
  $('#btnBookPrune').onclick = () => {
    StockBook.items = StockBook.items.filter(e => Date.now() - e.at <= STOCK_FRESH_MS);
    StockBook.save(); renderBook(); refreshStockBadges();
  };
  $('#scanDlg').addEventListener('close', stopScanner);
  $('#btnScanLookup').onclick = () => lookupCode($('#scanInput').value);
  $('#scanInput').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); lookupCode(e.target.value); } });

  if (!settings.store && source() === 'web') { settings.store = webStore('Lady Lake'); saveSettings(); }
  if (window.visualViewport) { visualViewport.addEventListener('resize', fitViewport); fitViewport(); }
  if (IS_IOS && !IS_STANDALONE && !LS.get('fa.iosTip', false)) {
    LS.set('fa.iosTip', true);
    setTimeout(() => toast('Tip: tap Share → Add to Home Screen to use this like an app', 6000), 1500);
  }

  renderAll();
  saveSessions();
  if (!settings.geminiKey) setTimeout(openSettings, 300);

  if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('sw.js').catch(() => {});
}

init();
