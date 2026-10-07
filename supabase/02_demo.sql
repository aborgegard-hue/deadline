-- PUBLIC DEMO: these spoilers are visible in the repository.
-- Technical test content, NOT the finished game. Import real cases privately.
begin;
insert into deadline_private.cases(slug,title,introduction,solution,duration_seconds) values
('demo-v1','TESTFALL / Sista mötet',
'Ni är gäster på ett kvällsevenemang. Arrangören Johan Voss har hittats död i arkivet klockan 21.20. En av era fiktiva personas är skyldig. Läs era roller privat, presentera era personas och granska bevisen tillsammans. Ingen behöver skådespela. Testet tar 20 minuter. Lämna varsin slutanklagelse innan ni öppnar facit.',
'Alex Berg är skyldig. Loggen visar passerkort A7 i arkivet 21.12–21.18. Den slutliga bevisningen knyter kortet till Alex och utesluter andra ingångar. Johan dog inom samma tidsintervall. Motivet i testberättelsen är det avslutade samarbetet. Detta är ett förenklat systemtest, inte ett färdigbalanserat mysterium.',1200)
on conflict(slug) do update set title=excluded.title,introduction=excluded.introduction,solution=excluded.solution,duration_seconds=excluded.duration_seconds;
insert into deadline_private.roles(case_slug,slot,content)
select 'demo-v1',slot,jsonb_build_object('name',name,'occupation',occupation,'background',background,'knows',knows,'secret',secret,'objective',objective,'is_murderer',is_murderer,'rules','Läs inte upp hela kortet. Du får undanhålla din hemlighet. Som oskyldig får du inte hitta på fakta eller ändra det du sett. Mördarens mål beskriver undantaget. Gemensamma bevis får aldrig ändras eller gömmas.')
from (values
(1,'Alex Berg','Affärspartner','Du och Johan drev ett projekt tillsammans. Johan ville avsluta samarbetet i kväll.','Du har passerkort A7. Bara du använde det i kväll.','Du är mördaren. Du gick in i arkivet 21.12 och lämnade det 21.18.','Undvik att bli utpekad. Du får ljuga om ditt alibi, men inte förfalska eller gömma gemensamma bevis.',true),
(2,'Robin Ek','Ekonomiansvarig','Du kontrollerar projektets ekonomi och grälade med Johan om ett försvunnet kvitto.','Du var i stora salen med Sam från 21.10 till 21.20.','Du slarvade bort kvittot och försökte dölja det.','Hitta mördaren utan att ditt slarv tar över diskussionen.',false),
(3,'Sam Lind','Fotograf','Du dokumenterade kvällens evenemang. Johan ville inte att en viss bild skulle publiceras.','Du fotograferade Robin i stora salen 21.14.','Du behöll bilden trots Johans protester. Den visar ett gräl före mordet.','Hitta mördaren och förklara vad ditt fotografi faktiskt visar.',false),
(4,'Kim Dahl','Assistent','Du planerade kvällen och hittade Johan i arkivet 21.20.','Arkivets nödutgång är larmad. Huvudingången registrerar varje passage.','Du läste ett privat brev där Johan avslutade ett affärssamarbete.','Hitta mördaren. Du väljer när du berättar om brevet.',false),
(5,'Liv Strand','Trädgårdsansvarig','Du kom till festen efter ditt arbetspass.','Du såg Johan och Alex diskutera häftigt strax före klockan 21.','Du hade bett Johan om ett förskott på din ersättning.','Hitta mördaren och skilj på ekonomiska problem och bevis.',false),
(6,'Charlie Nord','Evenemangsansvarig','Du ansvarade för gästlistan.','Robin och Sam stod tillsammans i stora salen under en del av kvällen.','Du släppte in en gäst utan biljett tidigare under dagen.','Hitta mördaren utan att ditt misstag förväxlas med mordet.',false),
(7,'Lo West','Säkerhetsansvarig','Du ansvarade för passerkorten under evenemanget.','Varje gäst tilldelades ett personligt passerkort. Den skriftliga listan är mer pålitlig än ditt minne.','Du kom sent till morgonmötet och ville inte berätta det.','Hitta mördaren med hjälp av loggarna, inte rykten.',false),
(8,'Mika Sjö','Journalist','Du intervjuade gästerna om projektet.','Johan hade sagt att han skulle bryta med en affärspartner.','Du spelade in intervjun utan att först fråga Johan.','Hitta mördaren och försök belägga uppgifterna du hör.',false)
) as r(slot,name,occupation,background,knows,secret,objective,is_murderer)
on conflict(case_slug,slot) do update set content=excluded.content;
insert into deadline_private.clues(case_slug,sequence,unlock_seconds,title,body) values
('demo-v1',1,0,'01 / Fyndplatsen','Johan hittades i arkivet 21.20. Rummet hade en huvudingång med kortläsare och en larmad nödutgång. Ingen gäst fanns inne i arkivet före Johan.'),
('demo-v1',2,300,'02 / Passageloggen','Johan gick in 21.10. Passerkort A7 registrerades in 21.12 och ut 21.18. Kim gick in 21.20. Inga andra passager finns. Diskutera vem som använde A7.'),
('demo-v1',3,600,'03 / Den slutliga kontrollen','A7 tillhör Alex Berg. Kameragranskningen bekräftar att Alex själv använde kortet och att ingen smet in bakom någon annan. Nödutgången var stängd hela tiden. Undersökningen placerar mordet mellan 21.11 och 21.17. Johan hade samma kväll avslutat samarbetet med Alex.')
on conflict(case_slug,sequence) do update set unlock_seconds=excluded.unlock_seconds,title=excluded.title,body=excluded.body;
commit;
