-- Synthetic CI content only. Does not contain the real private Morkvik manuscript.
insert into deadline_private.cases(slug,title,introduction,solution,duration_seconds)
values ('morkvik-v1','CI test','Synthetic introduction','Synthetic solution',4200);
insert into deadline_private.roles(case_slug,slot,content)
select 'morkvik-v1',slot,content from deadline_private.roles where case_slug='demo-v1' and slot<=6;
insert into deadline_private.clues(case_slug,sequence,unlock_seconds,title,body)
select 'morkvik-v1',n,case when n<=6 then 0 else 900 end,'Synthetic clue '||n,'Synthetic evidence' from generate_series(1,12) n;
