# Throneyard — throneyard.com

A GTA 6 ranking platform and community. It's a static site (plain HTML, CSS and JS) running on your Supabase project `nuclear-bulls`.

## Pages

| Page | What it does |
|---|---|
| `/` (index.html) | Waitlist homepage: live counter, countdown to Thursday, sign-up with invite links, this weekend's top 10, missions, Discord showcase |
| `/leaderboard.html` | Rankings: Global / Country / City, by weekend or all time |
| `/submit.html` | Player sign-in (Discord or email link), player card setup, mission upload (recording + up to 6 screenshots), list of my submissions |
| `/highlights.html` | Featured verified runs anyone can watch, with GG, Fire and Crown reactions |
| `/chat.html` | Live chat: rooms, your city room, your crew room, friends-only DMs, online counts |
| `/community.html` | Find Players (LFG posts), Crews (crew leaderboard, join, start a crew: members), Friends (requests + "you vs your friends" monthly board) |
| `/player.html?u=TAG` | Public player profile: badges, stats, crew, bio, Discord handle, recent runs, Add friend, Give respect |
| `/admin.html` | Admins only: review queue (watch the clip, verify and score, or reject with a reason) and creating missions |

## Already done in Supabase

- Tables: `waitlist`, `profiles`, `missions`, `submissions`, `settings`, `admins`. Row-level security is on for every table.
- Waitlist emails can't be read from the browser. Visitors can only join and see the count.
- The counter shows `waitlist_base` (672,896) **plus real sign-ups**. To change the starting number:
  `update settings set value = '700000' where key = 'waitlist_base';`
- Launch time: `settings.launch_at` (currently Thu Nov 19, 2026, 12:00 PM ET).
- A private storage bucket `submissions`. Players can only upload to their own folder. Only the player and admins can view the files.
- Players can't change a submission's status or score. The database forces every new submission to "in review", and only admins can verify or reject.

## Steps you need to do (about 15 minutes)

### 1. Deploy the folder
Any static host works. The easiest:
- **Netlify:** app.netlify.com → Add new site → Deploy manually → drag this folder in.
- **Vercel / Cloudflare Pages:** create a project from this folder. There's no build step, and the output directory is the root.

Then connect **throneyard.com** in the host's domain settings.

### 2. Supabase auth URLs
Supabase dashboard → Authentication → URL Configuration:
- Site URL: `https://throneyard.com`
- Redirect URLs: `https://throneyard.com/**` (also add your host's preview URL while testing)

### 3. Discord sign-in
1. discord.com/developers → New Application → OAuth2. Copy the Client ID and Client Secret.
2. Add this redirect: `https://niyjmljlsqbqniqvlktv.supabase.co/auth/v1/callback`
3. Supabase → Authentication → Sign In / Providers → Discord → enable it and paste the ID and secret.

Email sign-in links already work. For launch-day volume, set up custom SMTP (Authentication → Emails), because Supabase's built-in email is rate-limited.

### 4. Discord invite button
In `assets/config.js`, set `DISCORD_INVITE_URL` to your server invite.

### 5. Make yourself admin
Sign in once on `/submit.html`. Then in the Supabase SQL editor run:
```sql
insert into admins (user_id) select id from auth.users where email = 'YOUR_EMAIL';
```
Then open `/admin.html` and create the Weekend 1 missions.

### 6. Monthly honors (badges, no cash)
| Badge | Who earns it |
|---|---|
| City Champion | #1 verified score in their city for the month |
| Continental Champion | #1 on their continent (all 6 continents, every country) |
| World Champion | Winner of the monthly World Final. Every country's #1 is invited, with at least 4 finalists |

Reigning champions show at the top of the homepage and rankings, and badges appear next to players' names on every board. Badges stack (e.g. "World Champion ×2").

**Each month, in Admin → Badges & World Final:**
1. Review all of the month's runs.
2. **Lock finalists** for the month.
3. **Missions** tab → create a mission with Type = **World Final** and "Final for month" set to that month. Only finalists can enter it.
4. After the final is reviewed, click **Award badges for this month**. This crowns City, Continental and World Champions. You can run it earlier for City and Continental only, then again after the final.

### 7. Throne Pass ($5.99/month, perks only)
| Perk | How it works |
|---|---|
| 24-hour early access | Members can submit to weekend missions 24h before they open (`member_early_hours`) |
| Members-only bonus missions | Tick "Members-only bonus mission" when creating a mission. These count toward rankings. |
| Priority review | Member runs sit at the top of Admin → Review queue, tagged "Priority · Member" |
| Gold name + Member badge | Shown on every leaderboard |
| 12 screenshots per run | Free players get 6 (`member_max_screenshots`, `free_max_screenshots`) |
| Members-only Discord role | **Manual for now:** create a "Throne Member" role and a members-only channel in Discord, and give the role to members (Stripe → Customers lists them). Automating this needs a Discord bot. |

**Connect Stripe** (checkout is deployed and waiting for keys):
1. Stripe → Product catalog → Add product "Throneyard Throne Pass", $5.99, Recurring, Monthly. Copy the **Price ID**.
2. Stripe → Developers → Webhooks → Add endpoint `https://niyjmljlsqbqniqvlktv.supabase.co/functions/v1/stripe-webhook` with events `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`. Copy the **Signing secret**.
3. Stripe → Settings → Billing → Customer portal: turn it on and allow cancelling.
4. Supabase → Edge Functions → Secrets: `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`, `SITE_URL=https://throneyard.com`.
5. Test with test-mode keys and card `4242 4242 4242 4242`.

### Database
All database updates (001–011) are **already applied** to your `nuclear-bulls` project. `supabase/RUN_ME_IN_SQL_EDITOR.sql` is kept only as a backup. Don't run it again.

### 8. Upload size
Recordings can be large. Supabase's Free plan caps uploads at **50 MB per file**. On Pro you can raise it under Storage → Settings, up to 500 GB. The site allows up to 500 MB (`MAX_VIDEO_MB` in submit.html).

## About AI detection

Right now, verification means **an admin watches each clip** in the review queue. The site also records each file's details for the reviewer (resolution, length, file date, size) and makes the player confirm the run is real and unedited.

For automatic AI and tamper detection, add a Supabase Edge Function that sends each new upload to a detection service (for example Hive, Sightengine or Reality Defender). The function would save the result into `submissions.file_checks`, and the admin page would show it. The database is already set up for this, so you only need the detection service's API key.

## Files
```
index.html  leaderboard.html  community.html  player.html  submit.html  admin.html  rules.html
supabase/functions/  ← Stripe functions for Throne Pass (deployed)
assets/config.js   ← Supabase URL/key, Discord invite
assets/app.js      ← shared code (client, header, countdown, leaderboard rows)
assets/styles.css
supabase/migrations/001_init.sql  ← the database setup (already applied)
```

## Community features
- **Find Players:** players post what they're running, platform and time. Posts expire after 7 days. Free: 1 active post; members: 3, pinned on top. Remove bad posts in Admin → Moderation.
- **Crews:** one crew per player. Joining is free; starting a crew is a member perk. Crew score = members' total verified points. If the owner leaves, the crew disbands. Admins can disband any crew in Admin → Moderation.
- **Friends:** requests by gamertag or from a profile; a monthly friends-only leaderboard.
- **Respect:** one respect per player per profile; the count shows on profiles.
- **Profiles:** every name on every board links to `/player.html?u=gamertag`.

## Automation (runs by itself)
| When | What happens |
|---|---|
| 1st of each month, ~6 AM ET | Awards last month's City and Continental Champion badges, locks World Finalists, and creates the World Final mission (first Saturday after the 2nd, 12 PM ET → Sunday 11:59 PM ET) |
| 9th of each month, ~6 AM ET | Re-awards last month so the World Champion is crowned. Review World Final runs before then. If you review later, click "Award badges" in Admin again. |

Jobs live in Supabase → Integrations → Cron (`nb-monthly-honors`, `nb-world-champion`).

## Weekend 1 (already loaded)
Fri Nov 20, 6 PM ET → Sun Nov 22, 11:59 PM ET: Clean Getaway, Last One Standing, Heist Speedrun, Stunt King, plus members-only Night Shift and Double Down. Each description has its scoring guide for reviewers. They were written before GTA 6 is out, so once you've played it, edit the rules in Supabase → Table editor → `missions` if anything doesn't fit the game.

## Wars & streaks
- **City Wars:** Rankings → City Wars. Each city's combined verified score this month, with its top player.
- **Platform Wars:** the PS5 vs Xbox bar on the City Wars tab.
- **Weekend streaks:** consecutive weekends with a verified run, shown on profiles (current and best) and on the Submit page.

See **LAUNCH_KIT.md** for launch posts, the waitlist email and the Discord server setup.

## Chat
- **Rooms:** General, Weekend Missions, Squad Up, City Wars, PS5, Xbox, plus the Throne Room for Throne Pass members. Edit the list in `settings` → `chat_rooms`.
- **City room:** everyone can read it, but only players from that city can post. **Crew room:** private to crew members.
- **DMs:** friends only. Blocking someone stops their DMs and hides their messages from you.
- **Safety:** 5 messages per 10 seconds per player (`chat_rate_limit`), a word filter (add words to `chat_blocked_words`, e.g. `["word1","word2"]`), and no links from accounts under 24 hours old (members excepted).
- **Moderation:** Admin → Moderation → Chat reports: delete the message, mute 24h or 7 days, unmute, or dismiss.
- **Database:** chat (008) and the security fixes (009) are already applied and tested.

## Notifications, Highlights & Challenges
- **Bell (top right when signed in):** live alerts for friend requests and accepts, runs verified or rejected, featured clips, new badges, crew joins, Respect and challenges. A pop-up shows new ones instantly.
- **Highlights:** in Admin → Review queue, set the filter to Verified and click **Feature in Highlights** on great runs. The player gets notified and the clip appears on `/highlights.html` for anyone to watch and react to.
- **1v1 Challenges:** Community → Challenges (or Challenge on a friend's profile). Pick an open weekend mission; the best verified score wins when it closes.
- **Get started checklist:** shows on the Submit page until a new player has done all six steps.
