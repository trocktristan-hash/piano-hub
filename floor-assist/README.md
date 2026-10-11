# Floor Assist

A phone-friendly web app for the sales floor: describe what a customer needs (or snap a photo, or let it listen),
and Gemini searches the Best Buy catalog, keeping **only items in stock at your store**.

No build step and no server: plain HTML/JS. Keys, customers and history are stored only in the browser on your device.

## Setup (5 minutes)

1. **Gemini API key**: free at <https://aistudio.google.com/apikey>.
2. **Best Buy API key (optional)**: from <https://developer.bestbuy.com>. Best Buy only accepts business email
   addresses for this. With a key, store stock is checked automatically. **Without one, the app runs in web mode**
   (see below).
3. Open the app, then tap **⚙ Settings** and:
   - paste both keys
   - tap **Find stores** (ZIP is pre-filled with 32159, Lady Lake FL) and pick your store
   - optional: tap **Load list** to choose a different Gemini model (default `gemini-2.5-flash`)
4. Want to try it with sample data? Turn on **Demo inventory**.

### Web mode (no Best Buy API key)

Best Buy's live stock can't be read without the developer key, so web mode uses what you can check yourself:

1. **Products** come from Gemini + Google Search (real Best Buy listings, model numbers, approximate prices).
2. Each card has a yellow **Check stock on bestbuy.com ↗** button. It opens the bestbuy.com search for that SKU/model,
   or the Best Buy app if it's installed. **Set your "My Store" to Lady Lake once** on bestbuy.com/the app, and the
   results show whether it's available for pickup at your store.
3. Tap **✓ In / Low / ✗ Out** on the card. That goes into your **stock notebook** (☰ menu or ▥ scanner → 📋).
4. From then on, searches put verified in-stock items first and **hide anything marked out**. Unchecked items are
   labeled "Not checked yet", and the AI never claims they're in stock. Entries older than 7 days show "recheck".
5. Fill the notebook fast from the floor:
   - ▥ **Scan a box barcode**, then tap **"It's here on the floor — mark in stock"**.
   - ▥ → **📸 Read shelf tags**: photograph a row of shelf tags or boxes. Gemini reads the names/SKUs/prices,
     and you mark them all in stock in one tap.

The notebook is saved on your phone and builds up over time, so the more you use it, the better the filtering gets.

### Hosting it so it opens on your phone

It has to be served over **https** (the microphone and camera need it). The easiest way is GitHub Pages:
repo **Settings → Pages → Deploy from branch → `main` / root**. The app then lives at
`https://<user>.github.io/piano-hub/floor-assist/`. Open that on your phone and use **Add to Home Screen**
so it runs like an app.

### iPhone

1. Open the GitHub Pages link above in **Safari** (Add to Home Screen only works from Safari).
2. Tap **Share** (the square with an up arrow), then **Add to Home Screen**, then **Add**.
3. Open **Floor Assist** from your home screen and enter your keys and store in ⚙ Settings.
   The home-screen app has its own storage, separate from Safari, so set it up *inside the home-screen app*.
4. Allow the microphone and camera when asked. If you said no by mistake, go to
   iPhone **Settings → Apps → Safari → Microphone/Camera** and set them to *Ask* or *Allow*.

iPhone-specific details:
- **Listening mode** uses Gemini transcription in the home-screen app (Safari's built-in speech recognition doesn't
  work reliably there), so text shows up in ~15-second chunks. In the regular Safari tab it uses Apple's
  instant on-device recognition. You can choose either one under ⚙ Settings → Speech engine.
- Keep the app open and the screen on while listening: iOS pauses the microphone when the app is in the background
  or the phone locks. The app tries to keep the screen awake (iOS 16.4+).
- **Barcode scanning** works on iPhone through a bundled scanner library (`vendor/zxing.min.js`).
- 📷 lets you take a new photo or pick one from your library. HEIC photos are converted automatically.

For local testing: `cd floor-assist && python3 -m http.server 8000`, then open <http://localhost:8000>.

## Features

| | |
|---|---|
| **Describe the need** | e.g. "grandma wants a tablet for video calls, under $250". The AI runs inventory searches, checks stock, and answers with top picks, questions to ask, and add-ons. |
| **Stock filter** | *My store only* (default), *Nearby stores* (radius set in Settings), or *Anything*. Each product card shows a stock badge: In stock / Low stock / Not here (nearest store). In web mode, the badge comes from your stock notebook. |
| **Photos** | 📷 attach up to 4: a model-number sticker, a broken cable, a TV wall, a screenshot the customer shows you. You can also paste images. |
| **Listening mode** | 🎙 transcribes the conversation live and, every ~20 s (configurable) when there's new talk, pops up a short tip: their need, the next question to ask, in-stock picks, and an add-on. Tap **Suggest now** for an instant tip, or **Move to chat** to keep going in the chat. Uses the browser's speech recognition, falling back to Gemini audio transcription. Keeps the screen awake. |
| **Budget box** | Type a max $ in the top bar and every search is capped at it. |
| **Barcode / SKU lookup** | ▥ scan a UPC with the camera (iPhone and Android) or type a SKU/UPC to see price, stock here and at nearby stores, then **Ask AI about this**. |
| **Customers** | ☰ one session per customer, with notes the AI takes into account (e.g. "has an iPhone, hates subscriptions"). You can switch back when they return from the other aisle. |
| **Shortlist & compare** | ☆ save products, compare 2–4 side by side (price, stock, rating, common specs), then **AI: which fits this customer?** |
| **Share list** | Text or copy the shortlist (names, prices, SKUs, links) for the customer. |
| **Quick buttons** | Cheapest option, Best value, Premium pick, Add-ons, Explain simply, Questions to ask, On sale?, Objection help. |
| **Pitch** | One tap on a product card gives a 20-second pitch: 3 selling points, one honest trade-off, and what to pair with it. |
| **Read aloud** | 🔊 on any answer (handy with an earbud in). |
| **Installable / offline shell** | Works as a home-screen app, and the UI loads on weak store Wi-Fi. |

## Notes & limits

- **Tell customers** when listening mode is on, and follow store/company policy on recording and on using outside AI tools.
  Avoid putting customer personal info (phone, address, payment) into the chat.
- With an API key, stock comes from Best Buy's public store-pickup availability, refreshed every 10 minutes per item.
  In web mode, stock is only as current as your notebook; web prices are approximate (shown as "~$").
- Web mode uses Gemini's Google Search grounding, which has its own daily free limit on your Gemini key. Floor/backroom counts
  and open-box units aren't exposed by the public API.
- Best Buy's free API allows about 5 requests/second. The app paces itself and checks stock for up to 24 search results per query.
- Live speech recognition is instant in Chrome and the Safari tab. Home-screen iPhone apps and other browsers use Gemini transcription (~15 s delay).
