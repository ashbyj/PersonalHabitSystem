with recursive calendar as (
	-- need all days represented so days with missing scores 
	-- are included with null values 
	select '2025-01-01' as calendar_date 
	union all
	select date(calendar_date, '+1 day') 
	from calendar 
	where calendar_date < '2029-12-31'
), 
day_detail as (
	select calendar.calendar_date 
		, domain.key as domain_name 
		, domain.value as domain_score 
		, case when strftime('%w', calendar.calendar_date) in ('0','6') 
			   then 0 else 1 end as weekday_flag 
	from calendar 
		left join day_score
			on day_score.date = calendar.calendar_date, 
			-- sqlite style of unpivot()
			json_each(json_object(
				'Time', day_score.score_time, 
				'Diet', day_score.score_food, 
				'Physiology', day_score.score_physiology,
				'Responsibilities', day_score.score_responsibilities
			)) domain 
)
select day_detail.calendar_date
	, day_detail.domain_name
	, day_detail.domain_score
	, day_detail.weekday_flag 
	-- sqlite style of lag() ignore null
	, (select previous.domain_score 
	   from day_detail previous 
	   where previous.domain_name = day_detail.domain_name 
	       and previous.calendar_date < day_detail.calendar_date
	       and previous.domain_score is not null 
       order by previous.calendar_date desc 
       limit 1) as previous_day_score 
	, (select previous.domain_score 
	   from day_detail previous 
	   where previous.domain_name = day_detail.domain_name 
	       and previous.calendar_date < day_detail.calendar_date
	       and previous.domain_score is not null 
	       and previous.weekday_flag = day_detail.weekday_flag
       order by previous.calendar_date desc 
       limit 1) as previous_comparable_day_score 
from day_detail