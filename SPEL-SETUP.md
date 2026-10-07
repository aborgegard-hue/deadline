# Deadline UF – spelrum (testversion)

Webbappen och databasprogrammet finns i detta repo. En Supabase-databas måste anslutas innan mobilerna kan spela tillsammans. `timer.html` är oförändrad. Startsidan länkar till `spel.html`.

## Aktivera

1. Använd ett separat projekt i en **Free-organisation** i Supabase. Ingen Pro-plan eller betald tilläggstjänst behövs för denna prototyp.
2. Kör `supabase/01_schema.sql` och sedan `supabase/02_demo.sql` i projektets SQL Editor. Kör **inte** filerna i `tests/` i ert riktiga projekt.
3. Aktivera **Anonymous Sign-Ins** i Authentication. Då får varje webbläsare en autentiserad spelarsession utan att spelaren skriver mejl eller lösenord.
4. Kopiera Project URL och en **publishable key** (`sb_publishable_...`) till `assets/spel-config.js`. Spara till `main`.
5. Öppna `spel.html`, skapa en lobby och dela QR-koden. Alla använder varsin mobil. Antalet inkluderar värden. När alla är med delar värden ut rollerna. Alla läser, trycker Redo och värden startar utredningen.

```js
window.DEADLINE_CONFIG = Object.freeze({
  supabaseUrl: "https://DITT-PROJEKT.supabase.co",
  supabasePublishableKey: "sb_publishable_DIN_OFFENTLIGA_NYCKEL",
  turnstileSiteKey: ""
});
```

**Lägg aldrig service_role, sb_secret_, databaslösenord eller personliga access tokens i frontend eller detta publika repo.** Publishable-nyckeln är avsedd för frontend. Åtkomst till speldata kräver dessutom spelarens autentiserade session och medlemskap i omgången.

## Före offentlig testning

Aktivera CAPTCHA i Supabase Auth, exempelvis Cloudflare Turnstile. Dess **secret** sparas bara i Supabase. Dess **site key** anges som `turnstileSiteKey` i konfigurationen. Ange webbplatsens domän hos Turnstile. Stödet är implementerat men inga CAPTCHA-nycklar är konfigurerade.

Supabase har separata gränser för anonyma inloggningar från samma IP-adress. Många testare på samma skol-wifi kan träffa den gränsen. Återanvänd befintliga sessioner. Databasfunktionen begränsar även skapande/anslutning per användare, men detta ersätter inte CAPTCHA eller ett fullständigt missbruksskydd.

## Funktioner

- Lobby och QR för 4–8 spelare, inklusive värden.
- Fyra kärnroller plus upp till fyra extraroller. En fast mördarpersona; servern blandar vilken spelare som får respektive persona.
- Privata personkort, redo-knapp, gemensam introduktion, 20-minuterstimer och ledtrådar vid 0, 5 och 10 minuter.
- Privata, låsta slutanklagelser. Värden kan visa facit när alla har svarat. Efter tidsgränsen kan varje deltagare avsluta, även om värden tappat anslutningen.
- Återanslutning i samma webbläsare efter omladdning. Fel deltagare kan tas bort före rollutdelning.
- Uppdateringar cirka var fjärde sekund, paus i bakgrunden och längre intervall vid nätfel. Ingen Realtime-tjänst eller Edge Function behövs.

Inte implementerat: byte till ny mobil, värdbyte, ljud, nya privata ledtrådar under spelet, flera färdiga fall, betalningar eller licensnycklar. Tappar värden sin session före spelstart behövs en ny omgång.

**Testfallet är ett enkelt tekniktest, inte ett färdigt eller balanserat mysterium.** `02_demo.sql` är offentligt och innehåller spoilers. Importera ert riktiga manus direkt i databasen, inte via det publika repot. Att radera en fil från GitHub tar inte bort den ur historiken.

## Säkerhetsmodell

Tabellerna ligger i `deadline_private`, har RLS aktiverat och saknar direkta klientbehörigheter. Exponera inte detta schema i Supabases API-inställningar. Webbappen anropar `public.deadline`, en security-invoker-funktion som i sin tur anropar en privat security-definer-funktion med tom search_path. Den kontrollerar `auth.uid()`, medlemskap, värdbehörighet, spelarantal och spelfas. Spelar-ID från klienten används aldrig som autentisering.

Anslutning och rollutdelning låser spelraden så att samtidiga anrop inte överfyller lobbyn eller ger dubbla roller. Endast den egna rollen och upplåsta gemensamma bevis returneras. Spelarnamn renderas med textContent, inte HTML. Den egna rollen tas bort från den synliga sidan när man döljer kortet eller byter flik.

Databasadministratören kan läsa alla uppgifter. Systemet hindrar inte skärmdumpar, samarbete mellan deltagare, läsning av det offentliga testmanuset eller tillgång via någon annans olåsta mobil.

## Lagring

Omgången blir otillgänglig efter 24 timmar. Det innebär **inte automatisk radering**. Databasen sparar smeknamn, anonymt Auth-ID, roll och röst tills administratören städar. Informera testdeltagarna. Auth-sessionen sparas i webbläsarens localStorage; rensad webbdata eller ny webbläsare innebär att den privata rollen inte kan återtas.

Manuell städning i SQL Editor i det separata spelprojektet:

```sql
delete from deadline_private.games where expires_at < now();
delete from deadline_private.rate_limits where bucket < now() - interval '2 days';
-- Valfritt: gamla anonyma konton i det separata spelprojektet.
delete from auth.users where is_anonymous is true and created_at < now() - interval '30 days';
```

## Tester

GitHub Actions-workflowen **Test spelmotor** kör JavaScript-syntax och tester mot en separat PostgreSQL 17-databas: alla spelarantal, privata roller, värdbehörigheter, faser, tidsstyrda bevis, röster, utgångna omgångar och samtidiga anrop. Den använder inte ert Supabase-konto. Se det faktiska resultatet i Actions; testfiler i sig betyder inte att testerna gått igenom.

Auth-gränsen simuleras i databastesterna. Riktig Supabase Auth, CAPTCHA, nätverksavbrott och flera fysiska mobiler måste också testas när projektet är anslutet. För lokal frontend: kör `python -m http.server 8000` från repot och öppna `http://localhost:8000/spel.html`. Använd inte file://.

## Gratisnivå och hosting

Supabase Free har kvoter och kan pausas efter en veckas inaktivitet. Kontrollera att projektet är aktivt före ett test. Koden aktiverar inga betalplaner. GitHub Pages används här för en testprototyp. Pages får inte användas som gratis hosting för en kommersiell SaaS-tjänst eller en transaktionsinriktad webbplats. Se över hosting innan detta blir en betald spelplattform; frontend kan flyttas utan att databasen behöver byggas om.

Officiell dokumentation:
- https://supabase.com/docs/guides/auth/auth-anonymous
- https://supabase.com/docs/guides/api/api-keys
- https://supabase.com/docs/guides/database/functions
- https://supabase.com/docs/guides/auth/auth-captcha
- https://supabase.com/pricing
- https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
