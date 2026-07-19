// Daily Digest Script
// GitHub Actions cron this এ চালায়। Supabase থেকে গতকালের RCVD/DLVD ডেটা এবং
// Critical Ageing (180+ days) item টেনে এনে Telegram + Email এ পাঠায়।
//
// প্রয়োজনীয় GitHub repo secrets (Settings -> Secrets and variables -> Actions):
//   SUPABASE_URL, SUPABASE_ANON_KEY
//   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
//   GMAIL_USER, GMAIL_APP_PASSWORD, DIGEST_EMAIL_TO

import nodemailer from "nodemailer";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const GMAIL_USER = process.env.GMAIL_USER;
const GMAIL_APP_PASSWORD = process.env.GMAIL_APP_PASSWORD;
const DIGEST_EMAIL_TO = process.env.DIGEST_EMAIL_TO;

function fmt(n) {
  const num = parseFloat(n) || 0;
  return num.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

// আজকের বদলে "গতকাল" (Asia/Dhaka, UTC+6) হিসেব করে, কারণ সকাল ৮টায় স্ক্রিপ্ট
// চলার সময় পুরো "গতকাল"-এর ডেটা সম্পূর্ণ হয়ে যায়।
function yesterdayISO() {
  const d = new Date();
  d.setUTCHours(d.getUTCHours() + 6);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().split("T")[0];
}

async function sb(path) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });
  if (!res.ok) {
    throw new Error(`Supabase error ${res.status}: ${await res.text()}`);
  }
  return res.json();
}

async function buildDigest() {
  const date = yesterdayISO();

  const rows = await sb(
    `transactions?select=type,qty,line_value,challan_no,items(description,buyers(name))` +
      `&txn_date=eq.${date}&type=in.(RCVD,DLVD)&order=id.asc`
  );

  const ageing = await sb(
    `v_ageing?select=*&age_days=gte.180&current_stock=gt.0&order=age_days.desc&limit=15`
  );

  let rcvdQty = 0,
    rcvdVal = 0,
    dlvdQty = 0,
    dlvdVal = 0;
  const lines = [];

  rows.forEach((r) => {
    const qty = parseFloat(r.qty) || 0;
    const val = parseFloat(r.line_value) || 0;
    if (r.type === "RCVD") {
      rcvdQty += qty;
      rcvdVal += val;
    } else {
      dlvdQty += qty;
      dlvdVal += val;
    }
    const buyer = r.items?.buyers?.name || "Unknown";
    const desc = r.items?.description || "Item";
    lines.push(
      `${r.type === "RCVD" ? "🟢" : "🔴"} ${r.type} ${fmt(qty)} — ${desc} (${buyer})`
    );
  });

  const textLines = [
    `📋 Daily Digest — ${date}`,
    "",
    `🟢 RCVD: ${fmt(rcvdQty)} qty / $${fmt(rcvdVal)}`,
    `🔴 DLVD: ${fmt(dlvdQty)} qty / $${fmt(dlvdVal)}`,
    `📦 Total Entries: ${rows.length}`,
    "",
    ...lines.slice(0, 30),
  ];

  if (rows.length > 30) {
    textLines.push(`…and ${rows.length - 30} more entries`);
  }

  if (ageing.length) {
    textLines.push("", `⏳ Critical Ageing (180+ days): ${ageing.length} item(s)`);
    ageing.slice(0, 10).forEach((a) => {
      textLines.push(
        `⚠️ ${a.description} (${a.buyer}) — ${a.age_days} days, stock: ${fmt(a.current_stock)}`
      );
    });
  }

  return { date, text: textLines.join("\n"), entryCount: rows.length };
}

async function sendTelegram(text) {
  if (!TELEGRAM_BOT_TOKEN || !TELEGRAM_CHAT_ID) {
    console.log("Telegram not configured, skipping.");
    return;
  }
  const res = await fetch(
    `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: TELEGRAM_CHAT_ID, text }),
    }
  );
  if (!res.ok) {
    console.error("Telegram send failed:", await res.text());
  } else {
    console.log("Telegram digest sent.");
  }
}

async function sendEmail(subject, text) {
  if (!GMAIL_USER || !GMAIL_APP_PASSWORD || !DIGEST_EMAIL_TO) {
    console.log("Email not configured, skipping.");
    return;
  }
  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user: GMAIL_USER, pass: GMAIL_APP_PASSWORD },
  });
  await transporter.sendMail({
    from: GMAIL_USER,
    to: DIGEST_EMAIL_TO,
    subject,
    text,
  });
  console.log("Email digest sent.");
}

async function main() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    throw new Error("SUPABASE_URL / SUPABASE_ANON_KEY missing — check repo secrets.");
  }

  const { date, text } = await buildDigest();
  await Promise.all([
    sendTelegram(text),
    sendEmail(`GMS Stock — Daily Digest (${date})`, text),
  ]);
  console.log("Done. Digest date:", date);
}

main().catch((err) => {
  console.error("Digest failed:", err);
  process.exit(1);
});
