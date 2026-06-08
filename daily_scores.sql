select day_score.date,
       day_score.score_avg,
       day_score.score_time, 
       day_score.score_food, 
       day_score.score_physiology, 
       day_score.score_responsibilities,
       day_score.streak_l1_after AS current_streak,
       day.energy
from day_score
	join day using (date)
