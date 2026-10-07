# Deadline UF - spelrummet

Spelkod och frontend är implementerade. En riktig Supabase-databas behöver skapas, aktiveras och anslutas innan olika mobiler kan spela tillsammans. `timer.html` är oförändrad.

## Aktivera gratisversionen

1. Skapa ett separat Supabase-projekt i en **Free-organisation**, gärna i EU. Välj inte Pro eller betalda tillägg.
2. Kör hela `supabase/01_schema.sql` och därefter `supabase/02_demo.sql` i projektets SQL Editor. **Kör aldrig `tests/bootstrap.sql` eller andra testfiler i Supabase.**
3. Aktivera **Anonymous Sign-Ins** i Authentication-inställningarna. Varje spelare får då en skyddad session utan mejl eller lösenord.
4. Kopiera projektets **Project URL** och **publishable key** till `assets/spel-config.js`. Spara filen till main.
5. Öppna `spel.html`, skapa en lobby och dela QR-koden. Värden räknas in i spelarantalet. Alla använder egen mobil. När alla anslutit delar värden ut roller. Alla läser privat och trycker Redo; värden startar utredningen.

```js
window.DEADLINE_CONFIG = Object.freeze({
  supabaseUrl: "https://DITT-PROJEKT.supabase.co",
  supabasePublishableKey: "sb_publishable_DIN_OFFENTLIGA_NYCKEL",
  turnstileSiteKey: ""
});
```

**Lägg aldrig `service_role`, `sb_secret_...`, databaslösenord eller access tokens i frontend eller detta publika repo.** En publishable key är avsedd för frontend. Behörigheten kontrolleras separat med spelarens Auth-session.

## Före ett offentligt test

Aktivera CAPTCHA i Supabase Auth, exempelvis Cloudflare Turnstile. Dess **secret** sparas bara i Supabase-inställningarna; dess offentliga **site key** anges i konfigurationen ovan. Lägg till webbplatsens domän i Turnstile. Sidan stöder flödet, men inga CAPTCHA-nycklar är konfigurerade i repot.

Supabase begränsar nya anonyma inloggningar per IP-adress. Många testare på skolans wifi kan nå den gränsen. Återanvänd sessionerna. RPC:n begränsar även skapande och anslutning per användare. Det ersätter inte CAPTCHA eller ett fullständigt missbruksskydd.

## Funktioner och avgränsning

Lobby för 4-8 personer, gemensam kod/QR, privat personkort, redo-knapp, gemensam introduktion, serverstyrd 20-minuterstimer, gemensamma ledtrådar vid 0/5/10 minuter, privata låsta slutanklagelser och facit.

Fyra kärnroller plus upp till fyra extraroller. Mördarpersonan är fast; servern slumpar **vilken spelare som får vilken persona**, inte vem som är skyldig i berättelsen. Testfallet är förenklat och inte en färdig produkt.

Samma webbläsare återfår samma roll efter omladdning. En ny mobil eller rensad webbdata kan inte återta en roll med bara ett namn. Värden kan ta bort fel deltagare före rollutdelning. Därefter låses gruppen. Om värden försvinner före start krävs en ny omgång. När speltiden löpt ut kan vilken medlem som helst öppna facit.

Uppdatering ungefär var fjärde sekund, med paus i bakgrunden och längre intervall vid nätfel. Ingen Realtime-prenumeration, Edge Function eller appinstallation krävs. Offline-spel stöds inte. Ljud, privata ledtrådar under spelets gång, köp, licenser, värdbyte och flera färdiga fall ingår inte i version 1.

## Säkerhet och manus

Alla tabeller finns i `deadline_private`, med RLS och utan klienternas tabellbehörigheter. **Exponera inte det privata schemat i Data API.** Den publika funktionen `public.deadline` är security invoker och anropar en privat security definer-funktion. Den kontrollerar auth.uid(), medlemskap, värd, fas och spelarantal. Definer-funktioner har tom search_path och kvalificerade objektnamn. Raden för omgången låses vid ändringar så att samtidiga anslutningar/rollutdelningar inte överfyller gruppen eller delar om roller.

Klienten får bara sin egen hemliga roll, publicerade ledtrådar och tillåtna offentliga uppgifter. Namn renderas med textContent. Administratören kan läsa databasen; systemet stoppar inte skärmdumpar eller att spelare visar varandra sina mobiler.

**02_demo.sql är ett offentligt testmanus med spoilers.** Importera ert riktiga manus och facit privat i databasen. Lägg det inte i ett publikt GitHub-repo, inte heller tillfälligt: Git-historiken finns kvar.

## Lagring

Omgången är otillgänglig efter 24 timmar, men **raderas inte automatiskt**. Smeknamn, anonymt Auth-ID, roll och slutanklagelse lagras tills administratören städar. Auth-sessionen sparas i localStorage. Informera deltagarna. Manuell städning i spelprojektets SQL Editor:

```sql
delete from deadline_private.games where expires_at < now();
delete from deadline_private.rate_limits where bucket < now() - interval '2 days';
-- Valfritt, enbart i det separata spelprojektet:
delete from auth.users where is_anonymous is true and created_at < now() - interval '30 days';
```

## Kostnad och hosting

Koden aktiverar inga betalda tjänster. Free-projekt har kvoter och pausas efter en veckas inaktivitet. Kontrollera projektet före ett speltest. GitHub Pages används här för testprototypen. GitHubs regler tillåter inte Pages som gratis hosting för en kommersiell SaaS eller en transaktionsinriktad webbplats. Se över frontend-hosting innan ni säljer tillgång till spelplattformen; databasen behöver inte byggas om för ett byte.

## Tester

GitHub Actions-flödet **Test spelmotor** kör JavaScript-syntaxkontroll, isolerad PostgreSQL 17, behörighets- och speltester för 4-8 spelare, tidstyrning och samtidiga anslutningar. Inga riktiga Supabase-nycklar behövs. Kontrollera körningens resultat i Actions; att en testfil finns betyder inte att testet passerat.

Tester simulerar Auth-gränsen i SQL och ersätter inte ett test av riktig Supabase Auth, CAPTCHA och flera telefoner efter anslutning. Frontend kan köras lokalt med `python -m http.server 8000` och adressen `http://localhost:8000/spel.html` (inte file://).

## Officiella källor

- https://supabase.com/docs/guides/auth/auth-anonymous
- https://supabase.com/docs/guides/api/api-keys
- https://supabase.com/docs/guides/database/functions
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/auth/auth-captcha
- https://supabase.com/pricing
- https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
