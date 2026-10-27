# ACBL Tracker

An iPhone app for following your USACBL fantasy basketball roster, night by night. Build your lineup, then watch each player's points, bonus games, DNPs and injuries as the NBA games play out. Scoring follows the league's rules.

It's a personal project, not an App Store app, so you install it yourself from this code. It's free, takes about 30 minutes the first time, and needs a Mac.

## What you need

- A **Mac** with **Xcode** (free in the Mac App Store; it's a big download). If the App Store says your macOS is too old, download Xcode 26 from [developer.apple.com/download/all](https://developer.apple.com/download/all/) instead; the project opens in Xcode 26 and later.
- An **iPhone** on iOS 17 or later, and a **cable**
- Your **Apple ID** (the regular, free one. No paid developer account needed)

## Install it on your iPhone

1. **Get the code.** Click the green **Code** button above, then **Download ZIP** and unzip it. (Or clone it with GitHub Desktop.)
2. **Open the project.** Double-click `ACBLTracker.xcodeproj`.
3. **Add your Apple ID to Xcode.** Xcode > Settings (Cmd+,) > Accounts > **+** > Apple ID.
4. **Set up signing.** Click the blue **ACBLTracker** project at the top of the left sidebar. Under **TARGETS**, select **ACBLTracker**, then the **Signing & Capabilities** tab.
   - Tick **Automatically manage signing**.
   - Set **Team** to your name (Personal Team).
   - Change **Bundle Identifier** to something unique, like `com.yourname.acbltracker`. If you leave the original, Xcode will refuse.
5. **Prepare your phone.**
   - Plug it in, unlock it, and tap **Trust** if asked.
   - Turn on **Settings > Privacy & Security > Developer Mode** (it appears after Xcode has seen the phone once). The phone restarts, and then you confirm.
6. **Run it.** At the top of Xcode, open the destination menu and pick your phone from the **iOS Devices** section (not a simulator). Press **Cmd+R**.
   - The first time, Xcode says *Extracting OS library symbols*. This can take 5 to 20 minutes. Keep the phone unlocked and plugged in until it finishes.
   - A Mac password prompt about `codesign` is normal. Enter your Mac login password and click **Always Allow**.
7. **Trust yourself on the phone.** If you get *Untrusted Developer*, go to **Settings > General > VPN & Device Management**, tap your Apple ID, and tap **Trust**. Then open the app.

## Using it

- **Lineup tab:** 2 guards, 2 forwards and 1 center as starters, 3 on the bench, 6 on the deep bench. Two game columns (G1, G2) per the league's first-two-games rule, with a team total under each.
- **Add players:** pull down to reveal the search bar, find a player, tap him, and pick the position your league lists him at. He goes into the first open spot.
- **Move players:** tap **Edit** and drag the handles to reorder across Starters, Bench and Deep bench. Starter spots only accept their position. Swipe a row left to **Replace** or **Remove**.
- **Email your lineup:** when you tap **Done** after changing the order, the app offers to draft the week's lineup email (also under the **...** menu > Email lineup). Enter the recipients once, check the preview, and tap **Draft in Gmail**. It opens a prefilled draft in the Gmail app (or your default mail app) and sends nothing until you do.
- **Weeks:** the arrows at the top step through the Tuesday-to-Monday league weeks. Each week keeps its own lineup, so past weeks show the roster you actually had. Past weeks are view-only and are saved on your phone once they're final.
- **Nightly tab:** pick a day and see what each of your players scored and whether it counted. Off-night games (a team's 3rd or later game of the week) are listed separately, and days with only off-night games say **off** in the day strip.
- **Games tab:** every NBA game on a day, with live scores. Tap a game for its box score (minutes, FG made-attempted, points); your players are starred.
- **Free Agents tab:** players not on any team in the league sheet's roster tab for the current week, averaging over 10 points in their last 3 games, sorted by that average. Shows last 3, last 5 and season averages. Pull down to re-read the sheet after a pickup.
- **Player screen:** tap any player name (Lineup, Games or Free Agents) for his full game log and Rotowire news from the past week. Season PPG shows next to names on the Lineup and Nightly tabs.
- **Rename your team:** tap the pencil on the top card.
- **Badges:** orange **+2** for a 30-39 point game, red **+5** for 40+. A red **DNP** tag means he didn't play; an orange **0** with "played" means he played and scored nothing. A red **+** next to a name means he's on the injury report.

## The 7-day limit

Apps installed with a free Apple ID stop opening after **7 days**. Your data stays on the phone. To renew, plug in, open the project in Xcode, and press **Cmd+R** again. Don't delete the app first, or you'll lose your roster and saved weeks.

**Or let your Mac renew it.** `renew.sh` rebuilds with a fresh 7-day signature and reinstalls over the existing app (data kept), over Wi-Fi if the phone is unlocked nearby. After the steps above have worked once:

1. Copy `renew.env.example` to `renew.env` and fill in your team ID, bundle ID and phone ID.
2. Run `./renew.sh --force` once to check it works.
3. Run `./renew.sh --schedule`. Your Mac then checks daily at noon and renews when 2 days or less are left, with a notification either way.

## Scoring rules

| Rule | How the app handles it |
|---|---|
| Points count from a team's first 2 NBA games each Tue-Mon week | Yes |
| Starters score full points | Yes |
| Starter bonus: 30-39 = +2, 40+ = +5 (not stacked) | Yes |
| Playing subs (the next 3 who play) score half, rounded up, no bonus | Yes |
| Starter DNP: the first sub at the same position moves in at full value | Yes, per game, bench first and then deep bench |
| A sub who moves up or sits: the next reserve becomes a playing sub, any position | Yes |
| No eligible replacement: that slot scores zero | Yes |
| NBA Cup championship game doesn't count | Detected from ESPN's game notes |

Judgment calls: a sub who moves up gets the starter bonus, and "did not play" means no stat line or 0 minutes in the box score.

## Good to know

- Data comes from **ESPN's unofficial public endpoints**. They can change without notice. If numbers look blank or wrong, check ESPN's box score and open an issue.
- This project isn't affiliated with the USACBL, ESPN or the NBA.
- Your roster is stored on your phone only. Nothing is shared between league members.
- Positions are the ones your league assigns, not ESPN's. Set each player's position when you add him.
- Lineups, saved weeks and the last scores live on the device. Deleting the app erases them.

## For developers

SwiftUI, iOS 17+. All ESPN parsing is in `ESPNClient.swift`; the scoring rules are in `ScoringEngine.swift`. Unit tests for the scoring engine, week history and drag-and-drop logic are in `ScoringEngineTests.swift` (add them to a Unit Testing Bundle target and press Cmd+U).
