# Throneyard — Launch Kit

Site doors open: **tomorrow** · GTA 6 rankings launch: **Thursday** · First ranked weekend: **Fri Nov 20, 6 PM ET → Sun Nov 22, 11:59 PM ET** (members start 24h early)

> A note on the waitlist number: the site's counter starts at 672,896 plus real sign-ups. That starting number isn't real sign-ups, so these posts don't quote it. Advertising it as a real figure could break advertising rules and cost you trust if someone checks.

---

## 1. Launch posts

### X / Threads

**Post 1 (doors open)**
> Throneyard is live. 
> The ranking platform for GTA 6.
> Run missions. Submit your clip. Get verified as human-played. Climb the boards in your city, your continent, the world.
> Claim your spot free 👉 throneyard.com

**Post 2 (Weekend 1 missions)**
> Weekend 1 missions drop Friday 6 PM ET:
> 🚨 Clean Getaway: lose max wanted, fastest wins
> ⏱ Last One Standing: survive max wanted
> 💰 Heist Speedrun
> 🏍 Stunt King
> Top your city → City Champion badge. Top the world → World Champion.
> throneyard.com

**Post 3 (community)**
> GTA is better with a crew.
> Find players for tonight's run, start a crew that reps your city, add friends and see who's really better.
> City Wars is on. Which city takes #1 this month? 👀
> throneyard.com/community.html

**Post 4 (PS5 vs Xbox)**
> PS5 or Xbox. Who runs GTA 6?
> Every verified run counts toward Platform Wars. The bar is live on throneyard.com.
> Pick a side. 🎮

### TikTok / Reels / Shorts script (15–20s)

- **0–2s (hook, text on screen):** "Think you're the best GTA player in your city?"
- **2–8s:** Gameplay clip of a wanted-level escape. Voice: "Throneyard ranks GTA 6 players by city, continent and the world."
- **8–14s:** Screen recording of the leaderboard and a profile with a gold name. Voice: "Submit your run, we verify it's real, and you climb. Win your city, get the badge."
- **14–18s:** "Weekend 1 starts Friday. Claim your spot free, link in bio."
- **Caption:** "Weekend 1 drops Friday Who's taking your city? #GTA6 #GTAVI #GTA6Community #gaming"

### Instagram caption

> The leaderboard GTA 6 deserves.
> ✅ Real runs only, every clip verified
> 🏙 City, Continental and World Champion badges
> 👥 Crews, friends and Find Players
> 🎮 PS5 vs Xbox Platform Wars
> Weekend 1 starts Friday 6 PM ET. Claim your spot free: link in bio.

---

## 2. Waitlist email ("Doors are open")

The site stores waitlist emails but doesn't send emails. Export them (Supabase → Table editor → `waitlist` → Export CSV) and send with Resend, Mailchimp or Brevo. Include an unsubscribe link: Canada's anti-spam law (CASL) and the US CAN-SPAM Act require it.

**Subject:** Your Throneyard spot is ready
**Preview text:** Weekend 1 missions drop Friday at 6 PM ET.

> Hey {{gamertag}},
>
> You claimed your spot. Now it's time to use it.
>
> **Throneyard is live.** Here's how to be ready for Weekend 1:
>
> 1. **Set up your player card:** gamertag, platform, city. That's what puts you on your city's board → throneyard.com/submit.html
> 2. **Find your squad:** join a crew or post in Find Players → throneyard.com/community.html
> 3. **Friday 6 PM ET:** Weekend 1 opens. Record your full run, submit it, and we verify it's human-played.
>
> **This month's honors:** City Champion, Continental Champion and World Champion badges, plus a spot at the top of the site and in the Discord.
>
> Want a head start? Throne Pass members ($5.99/mo) play every mission 24 hours early, get members-only bonus missions, priority review and a gold name on every board.
>
> See you on the boards,
> AQ, Throneyard
>
> *[Unsubscribe] · Throneyard · [YOUR MAILING ADDRESS]*

---

## 3. Discord server setup

### Roles (top to bottom)
| Role | Color | Who |
|---|---|---|
| Admin | Red | You |
| Reviewer | Orange | Anyone you trust to review runs |
| 🌍 World Champion | Gold `#F5C84B` | Current World Champion |
| 🌐 Continental Champion | Blue `#7CC4FF` | Current continental champions |
| 🏙 City Champion | Lime `#C8FF3D` | Current city champions |
| Throne Member | Gold outline | Paying members (give it manually from Stripe's customer list) |
| PS5 / Xbox | Gray | Self-assign |
| Verified Player | Default | Anyone with a player card |

### Channels
**📢 START HERE**
- `#welcome` (read-only): welcome message below
- `#rules` (read-only)
- `#announcements` (read-only): missions, champions, updates
- `#get-roles`: platform roles via reactions (Carl-bot or MEE6 reaction roles)

**🏆 COMPETE**
- `#top-players` (read-only): monthly champions showcase
- `#mission-clips`: share runs and highlights
- `#weekend-missions`: rules, questions and strategy for this weekend
- `#city-wars`: city vs city trash talk
- `#ps5-vs-xbox`

**👥 CONNECT**
- `#find-a-crew`
- `#lfg-ps5` / `#lfg-xbox`
- `#general`
- `#off-topic`

** BULL MEMBERS** (Throne Member role only)
- `#members-lounge`
- `#early-access`: talk Weekend missions before they open

**🔊 VOICE**
- `Squad 1`, `Squad 2`, `Squad 3`, `Crew Room`

### Welcome message (`#welcome`)
> **Welcome to Throneyard **
> The ranking platform and community for GTA 6.
>
> **How it works**
> 1. Make your player card at throneyard.com (gamertag, platform, city)
> 2. Every weekend, new missions drop Friday 6 PM ET
> 3. Record your full run and submit it. Every clip is checked for AI or edits
> 4. Climb your city, continent and world boards
>
> **Monthly honors:** City Champion, Continental Champion, World Champion
> **Find your people:** #find-a-crew · #lfg-ps5 · #lfg-xbox
> Grab your platform role in #get-roles, then say hi in #general 👋

### Rules (`#rules`)
> 1. Respect everyone. No harassment, hate, threats or doxxing.
> 2. Real runs only. Cheating, mods, edits or AI footage = ban from the boards.
> 3. No selling accounts, boosting, scams or spam links.
> 4. Keep clips in #mission-clips and LFG in the LFG channels.
> 5. Reviewers' decisions are final. Appeals go to an Admin by DM.
> 6. Throneyard isn't affiliated with Rockstar Games or Take-Two.

### Monthly routine
- **1st of the month:** the site automatically awards City and Continental badges, locks World Finalists and creates the World Final. Post the champions in `#top-players` and update champion roles.
- **9th:** the site crowns the World Champion automatically (once you've reviewed the World Final runs). Announce it.

---

## 4. Launch-day checklist
- [ ] Site uploaded and throneyard.com points to it
- [ ] Supabase → Authentication → URL Configuration: Site URL `https://throneyard.com`, redirect `https://throneyard.com/**`
- [ ] Discord sign-in enabled (Supabase → Auth → Providers → Discord)
- [ ] Stripe product ($5.99/mo), webhook and 4 secrets added; one test purchase in test mode
- [ ] Discord invite link in `assets/config.js`
- [ ] Signed in once and made admin
- [ ] Supabase Pro plan, with the upload limit raised for video clips
- [ ] Custom email sender (SMTP) set up for sign-in emails
- [ ] Posts scheduled, waitlist email ready to send

### Ready for big traffic (do these before launch)
- [ ] **Supabase Pro + bigger compute.** Pro alone is fine for a soft launch; for a viral day pick at least the Large compute add-on (Settings → Compute and Disk). You can upgrade during a spike in a couple of minutes, with a short restart.
- [ ] **Realtime → Settings: turn OFF "Allow public access".** Live chat now uses private channels, so only people allowed in a room get its messages.
- [ ] **Realtime connection limit.** Every open chat/notification tab is one connection. Pro starts at 500 at once; raise it in Realtime settings or ask Supabase support before a big push.
- [ ] **Custom SMTP (Resend, Postmark or similar).** Supabase's built-in email only sends a handful of sign-in emails per hour, so thousands of new sign-ups would get stuck without it. Then raise the email rate limit under Auth → Rate Limits.
- [ ] **Host behind a CDN.** Cloudflare Pages or Netlify serve the pages from their edge for free, so page loads never touch your database.
- [ ] **Open the chat page once after deploying, then tell Claude.** That wakes up Supabase's live-message service; Claude then confirms live chat is delivering with one check.
- [ ] **Watch video storage costs.** Clips are the biggest bill at scale (storage + downloads). The 500 MB clip limit is set in the site; lower it if costs climb.
